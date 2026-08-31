// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "v4-core/interfaces/IHooks.sol";
import {Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {PoolId} from "v4-core/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {AssayHook} from "../../src/AssayHook.sol";
import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {FeeBlend} from "../../src/libraries/FeeBlend.sol";
import {Mispricing} from "../../src/libraries/Mispricing.sol";
import {IAssayEvents} from "../../src/interfaces/IAssayEvents.sol";

interface IERC20Like {
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @notice Tests against the real deployed contracts on a Base Sepolia fork -- the real
///         PoolManager, the real ChainlinkReferenceAdapter bytecode reading the real
///         Chainlink feed, and the real AssayHook bytecode pricing a real pool.
/// @dev Every other test in this suite runs against a locally-deployed PoolManager, a mock
///      aggregator, and a freshly-compiled hook. That's the right default for exhaustive
///      fuzz/invariant coverage, but it cannot catch a bug that exists only in the gap
///      between what the tests assume and what's actually deployed -- which is exactly how
///      the ChainlinkReferenceAdapter revert-on-low-answer bug (audit finding, GitHub #5)
///      survived every existing fuzz test: every fixture used a `PRICE_NUMERATOR` twelve
///      orders of magnitude smaller than the one actually deployed, so the code path was
///      never reached. `test_LiveOracleAdapter_RevertsOnLowAnswer_RegressionForIssue5` below
///      reproduces that finding directly against the deployed bytecode at its real address.
///
///      Requires network access (`BASE_SEPOLIA_RPC_URL`, defaulted in `.env` to the public
///      endpoint). Skipped from `forge coverage` for the same reason gas tests are: a fork
///      test measures against live chain state, not the instrumented build.
contract LiveBaseSepoliaForkTest is Test, IAssayEvents {
    address internal constant HOOK = 0x4A20EB2C6B928d4c153E4cDe2D7011ead9fCb0c4;
    address internal constant ORACLE_ADAPTER = 0xFA99bbD088EEc136b626aE98003240F12e851f98;
    address internal constant SWAP_ROUTER = 0x689E091c7411dB859915E3D8e9b37aee1dC343Ef;
    address internal constant CHAINLINK_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    int24 internal constant TICK_SPACING = 60;

    // The one deployed config value with no live getter (`captureShareBps` is a private
    // immutable). Matches `.env` and is cross-checked indirectly: if this were wrong, the
    // fee-prediction assertion in `test_LiveSwap_MatchesLocalFeeBlendPrediction` would fail.
    uint24 internal constant CAPTURE_SHARE_BPS = 1000;

    AssayHook internal hook;
    ChainlinkReferenceAdapter internal oracle;
    PoolSwapTest internal swapRouter;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        vm.createSelectFork("base_sepolia");

        hook = AssayHook(HOOK);
        oracle = ChainlinkReferenceAdapter(ORACLE_ADAPTER);
        swapRouter = PoolSwapTest(SWAP_ROUTER);

        poolKey = PoolKey({
            currency0: Currency.wrap(USDC),
            currency1: Currency.wrap(WETH),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });
        poolId = poolKey.toId();
    }

    /// @dev Sanity, not precision: the bound is roughly $20-$430,000 ETH/USD, wide enough to
    ///      never trip on ordinary market movement but tight enough to catch the class of
    ///      order-of-magnitude decimal/numerator error this codebase has twice caught by
    ///      hand this session (see config.ts's own commit history). A tight bound around
    ///      today's price would start failing the day ETH moves 2%.
    function test_LiveOracle_ReturnsFreshRealPrice() public view {
        (uint160 sqrtPriceX96, bool fresh) = oracle.referenceSqrtPriceX96();

        assertTrue(fresh, "live Chainlink read must be fresh");
        assertGt(sqrtPriceX96, TickMath.MIN_SQRT_PRICE, "sqrt price below v4's valid range");
        assertLt(sqrtPriceX96, TickMath.MAX_SQRT_PRICE, "sqrt price above v4's valid range");

        int24 tick = TickMath.getTickAtSqrtPrice(sqrtPriceX96);
        assertGt(tick, 150_000, "reference tick implausibly low -- likely a decimal-scaling bug");
        assertLt(tick, 250_000, "reference tick implausibly high -- likely a decimal-scaling bug");
    }

    /// @dev The strongest integration check available: predicts the fee a swap will be
    ///      quoted using the same pure library the hook itself calls, computed from a
    ///      snapshot of the hook's real, on-chain, pre-swap state -- then executes an actual
    ///      swap through the real deployed router against the real deployed hook and asserts
    ///      the `SwapAssayed` event matches the prediction exactly. This is the one thing no
    ///      mock-based test can give: proof the deployed bytecode agrees with the local
    ///      source it was supposedly compiled from.
    function test_LiveSwap_MatchesLocalFeeBlendPrediction() public {
        PoolState memory state = hook.poolState(poolId);
        (uint24 baseFeePips, uint24 minFeePips, uint24 maxFeePips) = hook.feeBounds();

        bool zeroForOne = true; // sell USDC for WETH
        uint24 predictedFeePips = FeeBlend.quote(
            Mispricing.signedTicks(state.referenceTick, state.lastTick, zeroForOne),
            state.referenceFresh,
            baseFeePips,
            minFeePips,
            maxFeePips,
            CAPTURE_SHARE_BPS
        );

        address trader = makeAddr("fork-test-trader");
        uint256 amountIn = 100_000; // 0.1 USDC -- small relative to the pool's shallow depth
        deal(USDC, trader, amountIn);

        vm.startPrank(trader);
        IERC20Like(USDC).approve(SWAP_ROUTER, amountIn);

        vm.expectEmit(true, true, false, true, HOOK);
        emit SwapAssayed(poolId, SWAP_ROUTER, predictedFeePips);

        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        vm.stopPrank();
    }

    /// @dev Regression test for the audit finding filed as GitHub #5: the adapter's
    ///      "never reverts" contract is false in isolation -- `_toSqrtPriceX96`'s
    ///      `FullMath.mulDiv` reverts for any feed answer at or below
    ///      `floor(PRICE_NUMERATOR / 2^64)`, which for the deployed numerator (1e20) is 5.
    ///      The live feed's own real `minAnswer()` is 1, inside that revert range. This
    ///      mocks only the feed's return value -- everything else (the adapter's own
    ///      deployed bytecode, its real immutable `PRICE_NUMERATOR`) is the genuine article.
    function test_LiveOracleAdapter_RevertsOnLowAnswer_RegressionForIssue5() public {
        vm.mockCall(
            CHAINLINK_FEED,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), int256(1), block.timestamp, block.timestamp, uint80(1))
        );

        vm.expectRevert();
        oracle.referenceSqrtPriceX96();
    }
}
