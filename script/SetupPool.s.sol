// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/types/PoolOperation.sol";
import {PoolModifyLiquidityTest} from "v4-core/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "v4-periphery/src/libraries/LiquidityAmounts.sol";
import {AddressConstants} from "hookmate/constants/AddressConstants.sol";

import {AssayHook} from "../src/AssayHook.sol";
import {IReferencePriceOracle} from "../src/interfaces/IReferencePriceOracle.sol";

interface IWETH {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

/// @notice Creates the first real pool against a deployed AssayHook, seeds it, and trades it.
/// @dev Until this runs there is no pool anywhere that names the hook, so the hook has never
///      priced a real swap and has emitted no events. Everything downstream of that — the
///      Markets surface, the event log, any indexer — has nothing to read.
///
///      Three properties this script is careful about:
///
///      1. **The pool is initialised at the oracle's own price.** Reading
///         `referenceSqrtPriceX96()` and initialising there means drift starts at zero, so the
///         first swaps are priced at the base fee rather than against an invented dislocation.
///      2. **Liquidity is computed from the balances actually held**, not from a guessed
///         `liquidityDelta`. Picking a delta and hoping the balance covers it is how this
///         reverts after the pool is already created.
///      3. **Swaps go both ways.** One direction captures drift and the other does not, and
///         that asymmetry is the entire thing being demonstrated — a single swap would prove
///         only that the hook does not revert.
contract SetupPool is Script {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    /// @dev Wide enough that the small seed position stays in range across the swaps below,
    ///      narrow enough that the same capital gives usable depth. Must be a multiple of the
    ///      tick spacing or `modifyLiquidity` reverts.
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant RANGE_MULTIPLE = 100;

    function run() external {
        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));
        AssayHook hook = AssayHook(vm.envAddress("ASSAY_HOOK"));

        Currency currency0 = Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY0"));
        Currency currency1 = Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY1"));

        // Amounts to commit, in each token's own units. Read from the environment so a rerun
        // with different depth does not need a code change.
        uint256 amount0 = vm.envUint("ASSAY_SEED_AMOUNT0");
        uint256 amount1 = vm.envUint("ASSAY_SEED_AMOUNT1");

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        PoolId poolId = key.toId();

        // Initialise at the reference, not at a chosen price: the hook's entire signal is the
        // gap between the two, and seeding a gap would mean the first swap paid a surcharge for
        // a dislocation this script invented.
        (uint160 sqrtPriceX96, bool fresh) = IReferencePriceOracle(
                address(uint160(vm.envAddress("ASSAY_REFERENCE_ORACLE")))
            ).referenceSqrtPriceX96();
        require(fresh, "SetupPool: reference is not usable; refusing to seed a pool blind");

        console2.log("chain id        ", block.chainid);
        console2.log("pool manager    ", address(poolManager));
        console2.log("hook            ", address(hook));
        console2.log("init sqrtPriceX96", sqrtPriceX96);
        console2.log("init tick       ", TickMath.getTickAtSqrtPrice(sqrtPriceX96));

        vm.startBroadcast();

        // Routers. v4 has no canonical public swap router on this chain, and the core test
        // routers are the reference implementations of the unlock/settle dance — deploying our
        // own is more honest than pointing at an address that might not be what it claims.
        PoolModifyLiquidityTest liquidityRouter = new PoolModifyLiquidityTest(poolManager);
        PoolSwapTest swapRouter = new PoolSwapTest(poolManager);

        _prepareFunds(currency0, currency1, amount1, address(liquidityRouter), address(swapRouter));

        poolManager.initialize(key, sqrtPriceX96);
        _seed(liquidityRouter, key, sqrtPriceX96, amount0, amount1);

        // Both directions, so the log carries the asymmetry rather than a single data point.
        // Sized as a small fraction of the position: enough to move the tick and be priced,
        // not enough to walk out of range and strand the position.
        // Both seed amounts are deployer-supplied and far below 2**255, so the cast cannot
        // wrap; a value large enough to matter would have failed at the balance check first.
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, true, int256(amount0 / 20));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, false, int256(amount1 / 20));

        vm.stopBroadcast();

        _report(poolManager, poolId, address(liquidityRouter), address(swapRouter));
    }

    /// @dev Final state, in its own frame. Reading slot0 and liquidity alongside two router
    ///      addresses is four more stack slots than `run` has left.
    function _report(IPoolManager poolManager, PoolId poolId, address liquidityRouter, address swapRouter)
        private
        view
    {
        (uint160 finalPrice, int24 finalTick,,) = poolManager.getSlot0(poolId);
        console2.log("");
        console2.log("final sqrtPriceX96", finalPrice);
        console2.log("final tick      ", finalTick);
        console2.log("liquidity now   ", poolManager.getLiquidity(poolId));
        console2.log("");
        console2.log("liquidity router", liquidityRouter);
        console2.log("swap router     ", swapRouter);
    }

    /// @dev Wraps the ETH the position needs and approves both routers. Its own frame so its
    ///      locals do not compete for stack slots with the liquidity arithmetic.
    function _prepareFunds(
        Currency currency0,
        Currency currency1,
        uint256 amount1,
        address liquidityRouter,
        address swapRouter
    ) private {
        // The pool needs WETH and the deployer holds ETH. Wrap exactly the shortfall, no more —
        // leftover wrapped ETH is not lost, but it is not useful either.
        IWETH weth = IWETH(Currency.unwrap(currency1));
        uint256 held = weth.balanceOf(msg.sender);
        if (held < amount1) weth.deposit{value: amount1 - held}();

        IERC20Minimal(Currency.unwrap(currency0)).approve(liquidityRouter, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(liquidityRouter, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(swapRouter, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(swapRouter, type(uint256).max);
    }

    /// @dev Adds the seed position, sizing it from the balances on hand.
    function _seed(
        PoolModifyLiquidityTest liquidityRouter,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        uint256 amount0,
        uint256 amount1
    ) private {
        int24 currentTick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        // Divide-then-multiply is deliberate here and is not a precision loss: it snaps each
        // bound down to a tick-spacing boundary, which `modifyLiquidity` requires. Multiplying
        // first would defeat the entire purpose of the expression.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 lower = ((currentTick - TICK_SPACING * RANGE_MULTIPLE) / TICK_SPACING) * TICK_SPACING;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 upper = ((currentTick + TICK_SPACING * RANGE_MULTIPLE) / TICK_SPACING) * TICK_SPACING;

        // Derived from the balances on hand rather than chosen. The inverse — pick a delta,
        // hope the balance covers it — reverts after the pool already exists, leaving a live
        // empty pool and a half-finished deployment.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(lower),
            TickMath.getSqrtPriceAtTick(upper),
            amount0,
            amount1
        );
        require(liquidity > 0, "SetupPool: seed amounts round to zero liquidity");

        liquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: lower,
                tickUpper: upper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        console2.log("tick lower      ", lower);
        console2.log("tick upper      ", upper);
        console2.log("liquidity       ", liquidity);
    }

    /// @dev `amountSpecified` is negated to an exact-input swap, and the price limit is set to
    ///      the extreme so the swap is bounded by liquidity rather than by a limit this script
    ///      picked. A limit that binds would silently trade less than intended.
    function _swap(PoolSwapTest router, PoolKey memory key, bool zeroForOne, int256 amount) private {
        router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -amount,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }
}
