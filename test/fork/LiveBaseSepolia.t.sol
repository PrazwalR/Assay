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
import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
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
    address internal constant HOOK = 0xc825ad661BA0398eF9Cf809E6635528C9aa370c4;
    address internal constant ORACLE_ADAPTER = 0x56757460c56104aBD30a7783e7Ac0dcE380F0d38;
    address internal constant SWAP_ROUTER = 0x0DFA8a0e1CaC977015cc7D214380AeB24FE766d5;
    address internal constant CHAINLINK_FEED = 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1;
    address internal constant USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address internal constant WETH = 0x4200000000000000000000000000000000000006;
    int24 internal constant TICK_SPACING = 60;

    // The one deployed config value with no live getter (`captureShareBps` is a private
    // immutable). Matches `.env` and is cross-checked indirectly: if this were wrong, the
    // fee-prediction assertion in `test_LiveSwap_MatchesLocalFeeBlendPrediction` would fail.
    uint24 internal constant CAPTURE_SHARE_BPS = 1000;
    uint24 internal constant MAX_REFERENCE_DEVIATION_TICKS = 20_000;
    uint64 internal constant TWAP_LAMBDA_X32 = 4_252_017_623;

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
    ///      quoted using the same pure library the hook itself calls, then executes an actual
    ///      swap through the real deployed router and asserts the `SwapAssayed` event matches
    ///      exactly. This is the one thing no mock-based test can give: proof the deployed
    ///      bytecode agrees with the local source.
    ///
    ///      The reference now refreshes in `beforeSwap` (the fix for the reference-lag audit
    ///      finding), so predicting from a `poolState()` snapshot taken before the swap is
    ///      only correct if nothing refreshes in between -- which cannot be assumed on a live
    ///      fork, where real time keeps passing between reads. `vm.roll` makes the refresh
    ///      unconditional and deterministic instead of racing it: this swap is guaranteed to
    ///      be the first of a new block, so the prediction reads the oracle directly, exactly
    ///      as `_advanceReferenceInPlace` would, rather than a snapshot that might already be
    ///      stale by the time the swap actually executes.
    function test_LiveSwap_MatchesLocalFeeBlendPrediction() public {
        vm.roll(block.number + 1);

        PoolState memory state = hook.poolState(poolId);
        (uint24 baseFeePips, uint24 minFeePips, uint24 maxFeePips) = hook.feeBounds();

        (uint160 freshSqrtPriceX96, bool freshOk) = oracle.referenceSqrtPriceX96();
        int24 freshReferenceTick = TickMath.getTickAtSqrtPrice(freshSqrtPriceX96);

        // Replicates the deviation cap `_advanceReferenceInPlace` applies to that fresh
        // reading before adopting it: fold the pool's own tick into the REAL existing anchor
        // -- not a fresh one -- then check the fresh reading agrees with the result.
        int64 anchorAfterFold = PoolTwap.update(state.twapTickX32, state.lastTick, TWAP_LAMBDA_X32);
        bool withinCap =
            PoolTwap.withinBound(anchorAfterFold, freshReferenceTick, MAX_REFERENCE_DEVIATION_TICKS);
        bool referenceFresh = freshOk && withinCap;
        int24 referenceTick = referenceFresh ? freshReferenceTick : state.referenceTick;

        bool zeroForOne = true; // sell USDC for WETH
        uint24 predictedFeePips = FeeBlend.quote(
            Mispricing.signedTicks(referenceTick, state.lastTick, zeroForOne),
            referenceFresh,
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
                // `amountIn` is a small literal set above, far inside int256.
                // forge-lint: disable-next-line(unsafe-typecast)
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

        (uint160 sqrtPriceX96, bool fresh) = oracle.referenceSqrtPriceX96();
        assertEq(sqrtPriceX96, 0, "an unusable reading must report zero, not revert");
        assertFalse(fresh, "and must report itself unusable");
    }
}
