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

interface IWETH {
    function deposit() external payable;
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IERC20Minimal {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @notice Adds depth to the already-initialised pool and trades it, so the hook has priced
///         more than the two swaps its deploy script produced.
/// @dev Attaches to the pool `SetupPool` created and to the routers deployed alongside it,
///      read from the environment -- a second pair would fragment the approvals.
///
///      Liquidity is sized from the balance held, less a reserve to fund the swaps.
///      Swaps alternate direction, so each returns the token the next spends and the tick
///      stays near where it started rather than walking the position out of range.
contract SeedActivity is Script {
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    int24 internal constant TICK_SPACING = 60;
    int24 internal constant RANGE_MULTIPLE = 100;

    function run() external {
        IPoolManager poolManager = IPoolManager(AddressConstants.getPoolManagerAddress(block.chainid));

        Currency currency0 = Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY0"));
        Currency currency1 = Currency.wrap(vm.envAddress("ASSAY_ORACLE_CURRENCY1"));

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(vm.envAddress("ASSAY_HOOK"))
        });
        PoolId poolId = key.toId();

        PoolModifyLiquidityTest liquidityRouter =
            PoolModifyLiquidityTest(vm.envAddress("ASSAY_LIQUIDITY_ROUTER"));
        PoolSwapTest swapRouter = PoolSwapTest(vm.envAddress("ASSAY_SWAP_ROUTER"));

        // Read from the environment so a rerun with different depth needs no edit.
        uint256 addAmount0 = vm.envUint("ASSAY_TOPUP_AMOUNT0");
        uint256 wrapAmount1 = vm.envUint("ASSAY_TOPUP_WRAP1");
        uint256 swapAmount0 = vm.envUint("ASSAY_SWAP_AMOUNT0");
        uint256 swapAmount1 = vm.envUint("ASSAY_SWAP_AMOUNT1");

        (uint160 sqrtPriceBefore, int24 tickBefore,,) = poolManager.getSlot0(poolId);
        uint128 liquidityBefore = poolManager.getLiquidity(poolId);

        console2.log("chain id         ", block.chainid);
        console2.log("tick before      ", tickBefore);
        console2.log("liquidity before ", liquidityBefore);

        vm.startBroadcast();

        _prepareFunds(currency0, currency1, wrapAmount1, address(liquidityRouter), address(swapRouter));
        _addLiquidity(liquidityRouter, key, sqrtPriceBefore, tickBefore, addAmount0);

        // Seven alternating swaps, starting currency0-in: the side that trades toward a
        // reference below the pool. Amounts are env-sourced and far inside int256.
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, true, int256(swapAmount0));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, false, int256(swapAmount1));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, true, int256(swapAmount0 * 3 / 2));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, false, int256(swapAmount1 * 3 / 2));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, true, int256(swapAmount0 / 2));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, false, int256(swapAmount1 / 2));
        // forge-lint: disable-next-line(unsafe-typecast)
        _swap(swapRouter, key, true, int256(swapAmount0));

        vm.stopBroadcast();

        _report(poolManager, poolId, liquidityBefore);
    }

    /// @dev Re-approves both routers even though `SetupPool` set them to max, so this runs
    ///      against a wallet that never ran that script.
    function _prepareFunds(
        Currency currency0,
        Currency currency1,
        uint256 wrapAmount1,
        address liquidityRouter,
        address swapRouter
    ) private {
        if (wrapAmount1 > 0) {
            IWETH(Currency.unwrap(currency1)).deposit{value: wrapAmount1}();
        }

        IERC20Minimal(Currency.unwrap(currency0)).approve(liquidityRouter, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(liquidityRouter, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency0)).approve(swapRouter, type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(swapRouter, type(uint256).max);
    }

    /// @dev Same tick range as the seed position, so depth concentrates where it trades.
    function _addLiquidity(
        PoolModifyLiquidityTest liquidityRouter,
        PoolKey memory key,
        uint160 sqrtPriceX96,
        int24 currentTick,
        uint256 amount0
    ) private {
        // Divide-then-multiply snaps each bound to a tick-spacing boundary, as
        // `modifyLiquidity` requires. Multiplying first would defeat it.
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 lower = ((currentTick - TICK_SPACING * RANGE_MULTIPLE) / TICK_SPACING) * TICK_SPACING;
        // forge-lint: disable-next-line(divide-before-multiply)
        int24 upper = ((currentTick + TICK_SPACING * RANGE_MULTIPLE) / TICK_SPACING) * TICK_SPACING;

        // Sized from currency0 alone and left to `getLiquidityForAmounts` to pair: passing a
        // currency1 budget larger than the ratio needs would silently size the position by
        // whichever side binds, which is not always the one intended.
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount0(
            sqrtPriceX96, TickMath.getSqrtPriceAtTick(upper), amount0
        );
        require(liquidity > 0, "SeedActivity: top-up rounds to zero liquidity");

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

        console2.log("tick lower       ", lower);
        console2.log("tick upper       ", upper);
        console2.log("liquidity added  ", liquidity);
    }

    /// @dev Exact-input, bounded by liquidity rather than by a price limit this script picked.
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

    /// @dev Final state in its own frame, so its locals do not compete for stack slots.
    function _report(IPoolManager poolManager, PoolId poolId, uint128 liquidityBefore) private view {
        (, int24 tickNow,,) = poolManager.getSlot0(poolId);
        uint128 liquidityNow = poolManager.getLiquidity(poolId);
        console2.log("");
        console2.log("tick after       ", tickNow);
        console2.log("liquidity after  ", liquidityNow);
        console2.log("liquidity delta  ", liquidityNow - liquidityBefore);
    }
}
