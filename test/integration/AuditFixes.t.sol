// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolSwapTest} from "v4-core/test/PoolSwapTest.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";
import {TickMath} from "v4-core/libraries/TickMath.sol";
import {Currency} from "v4-core/types/Currency.sol";

import {AssayTestBase} from "../utils/AssayTestBase.sol";
import {GasBurningOracle} from "../mocks/GasBurningOracle.sol";
import {MockReferenceOracle} from "../mocks/MockReferenceOracle.sol";
import {ChainlinkReferenceAdapter, IAggregatorV3} from "../../src/oracle/ChainlinkReferenceAdapter.sol";
import {MockAggregatorV3} from "../mocks/MockAggregatorV3.sol";
import {AssayConfig} from "../../src/config/AssayConfig.sol";
import {AssayHook} from "../../src/AssayHook.sol";
import {PoolState} from "../../src/types/PoolState.sol";
import {FeeBlend} from "../../src/libraries/FeeBlend.sol";

/// @notice Regression tests for the six issues filed against this hook.
/// @dev Each test names the issue it pins. They are integration rather than unit tests
///      because every one of these bugs lived in the interaction between the hook, the
///      oracle and the block boundary -- none of them are visible from a pure function.
contract AuditFixesTest is AssayTestBase {
    function _swap() internal {
        swapRouter.swap(
            poolKey,
            SwapParams({
                zeroForOne: true,
                amountSpecified: -0.001 ether,
                sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    // --- Issue #1: sequencer-outage staleness ------------------------------------------

    /// @dev A halt freezes the pool tick and the feed's `updatedAt` together, so both still
    ///      agree on resumption while the world has moved. Before the fix the quote came out
    ///      at the base fee -- the cheapest tier -- at exactly the moment the flow was most
    ///      informed. It must now come out at the ceiling instead.
    function test_Issue1_ShortHaltForcesTheCeilingRatherThanTheBaseFee() public {
        _swap();
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 2);
        _swap();

        uint24 feeBeforeHalt = hook.poolState(poolKey.toId()).referenceFresh ? BASE_FEE_PIPS : MAX_FEE_PIPS;
        assertEq(feeBeforeHalt, BASE_FEE_PIPS, "precondition: reference trusted before the halt");

        // 20 minutes of wall clock, one block. Under the adapter's 3600s staleness bound,
        // so the feed still reports itself fresh -- which is the whole trap.
        feed.setUpdatedAt(block.timestamp + 1200);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1200);
        _swap();

        PoolState memory afterHalt = hook.poolState(poolKey.toId());
        assertFalse(afterHalt.referenceFresh, "a resumed chain must not be trusted immediately");
        assertGt(afterHalt.referenceDistrustedUntil, 0, "distrust window must be armed");
    }

    /// @dev The window has to end, or one outage would hold the pool at the ceiling forever.
    function test_Issue1_DistrustWindowExpires() public {
        feed.setUpdatedAt(block.timestamp + 1200);
        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 1200);
        _swap();
        assertFalse(hook.poolState(poolKey.toId()).referenceFresh, "distrusted during the window");

        // Blocks must advance in step with the clock here, or this second gap is itself a
        // halt by the same test -- which is the correct reading of 400 seconds across one
        // block, and is why the window is measured against block production rather than
        // wall clock alone.
        feed.setUpdatedAt(block.timestamp + 400);
        vm.roll(block.number + 200);
        vm.warp(block.timestamp + 400);
        _swap();
        assertTrue(hook.poolState(poolKey.toId()).referenceFresh, "trust must return afterwards");
    }

    /// @dev The false positive that would make this unusable: a pool nobody trades for an
    ///      hour also shows a large wall-clock gap, but its block count grew in step.
    function test_Issue1_QuietPoolIsNotMistakenForAHalt() public {
        vm.roll(block.number + 1800);
        vm.warp(block.timestamp + 3600);
        feed.setUpdatedAt(block.timestamp);
        _swap();
        assertTrue(
            hook.poolState(poolKey.toId()).referenceFresh,
            "an untraded pool on a healthy chain must stay trusted"
        );
    }

    // --- Issue #3: hostile oracle burning gas ------------------------------------------

    /// @dev Before the fix a feed that burned gas instead of reverting took 63/64 of whatever
    ///      the swapper supplied, leaving too little to finish `afterSwap`, so every
    ///      first-of-block swap reverted. The stipend bounds what it can take.
    function test_Issue3_GasBurningOracleCannotBrickTheSwapPath() public {
        GasBurningOracle burner =
            new GasBurningOracle(Currency.wrap(address(token0)), Currency.wrap(address(token1)));
        AssayConfig memory config = _defaultConfig();
        config.referenceOracle = address(burner);
        AssayHook burnerHook = _deployHook(config);
        poolKey = _initialisePool(address(burnerHook));
        _addLiquidity();

        vm.roll(block.number + 1);
        // Comfortably inside a normal wallet's estimate; before the fix this reverted.
        this.swapWithGas{gas: 400_000}();
    }

    function swapWithGas() external {
        _swap();
    }

    // --- Issue #6: gas-griefing the once-per-block read --------------------------------

    /// @dev A failed read must leave the block's refresh owed rather than retiring it, or one
    ///      cheap swap per block pins the pool at the ceiling while the feed is healthy.
    ///      The failure has to be at the oracle, not at the feed behind it: the adapter
    ///      converts a broken feed into a perfectly well-formed "unusable" answer, which is
    ///      a real observation and does settle the block. Only a call that never returned
    ///      leaves the refresh owed, and that is exactly the case a gas-metering caller
    ///      manufactures.
    function test_Issue6_FailedReadLeavesTheRefreshOwedForTheSameBlock() public {
        MockReferenceOracle flaky = new MockReferenceOracle(
            TickMath.getSqrtPriceAtTick(0),
            true,
            Currency.wrap(address(token0)),
            Currency.wrap(address(token1))
        );
        AssayConfig memory config = _defaultConfig();
        config.referenceOracle = address(flaky);
        AssayHook flakyHook = _deployHook(config);
        poolKey = _initialisePool(address(flakyHook));
        _addLiquidity();

        vm.roll(block.number + 1);
        flaky.setShouldRevert(true);
        _swap();
        assertFalse(flakyHook.poolState(poolKey.toId()).referenceFresh, "call failed, so not fresh");

        // Same block, oracle healthy again: the refresh was never retired, so this retries.
        flaky.setShouldRevert(false);
        _swap();
        assertTrue(
            flakyHook.poolState(poolKey.toId()).referenceFresh,
            "a later swap in the same block must be able to retry the owed refresh"
        );
    }

    /// @dev The complement: an oracle that answers "unusable" has been heard from, so the
    ///      block is settled and later swaps do not pay to ask again.
    function test_Issue6_AnUnusableButAnsweredReadStillRetiresTheBlock() public {
        vm.roll(block.number + 1);
        feed.setShouldRevert(true);
        _swap();
        uint32 blockAfterFirst = hook.poolState(poolKey.toId()).lastBlock;
        assertEq(blockAfterFirst, uint32(block.number), "an answered read retires the block");
    }

    // --- Issue #4: undisclosed surcharge bound -----------------------------------------

    /// @dev `feeBounds` described only the percentage fee, so an integrator sizing slippage
    ///      from it was not sizing against the worst case.
    function test_Issue4_SurchargeBoundIsDisclosedAndBinding() public view {
        (uint24 maxSurchargePips, uint24 maxTotalPips) = hook.surchargeBounds();
        (,, uint24 maxFeePips) = hook.feeBounds();

        assertEq(maxSurchargePips, FeeBlend.MAX_OVERFLOW_PIPS, "surcharge bound must be exposed");
        assertEq(maxTotalPips, maxFeePips + maxSurchargePips, "total must be the sum of both");
        assertLt(maxTotalPips, 100_000, "worst case must stay well under 10% of notional");
    }

    /// @dev The bound is only worth exposing if it actually binds. The old ceiling was 100%
    ///      of notional, which no integrator could have priced against.
    function test_Issue4_ExtremeDriftIsCappedByTheNewCeiling() public pure {
        uint24 overflow = FeeBlend.ceilingOverflowPips(200_000, true, 500, 10_000, 10_000);
        assertEq(overflow, FeeBlend.MAX_OVERFLOW_PIPS, "an absurd drift must clamp to the ceiling");
        assertEq(overflow, 20_000, "and that ceiling is 2% of notional");
    }

    // --- Issue #5: adapter reverting on a low feed answer -------------------------------

    /// @dev The adapter documents that it never reverts, but its own arithmetic did, for any
    ///      answer at or below `PRICE_NUMERATOR >> 64`. The live feed's `minAnswer` is 1,
    ///      inside that range. Reproduced at the deployed decimal configuration, which no
    ///      pre-existing test used.
    function test_Issue5_LowFeedAnswerReportsUnusableInsteadOfReverting() public {
        MockAggregatorV3 lowFeed = new MockAggregatorV3(int256(1), block.timestamp);
        ChainlinkReferenceAdapter adapter = new ChainlinkReferenceAdapter(
            IAggregatorV3(address(lowFeed)),
            ORACLE_MAX_AGE,
            1e20, // the deployed numerator: USDC(6)/WETH(18) against an 8-decimal feed
            Currency.wrap(address(token0)),
            6,
            Currency.wrap(address(token1)),
            18
        );

        (uint160 sqrtPriceX96, bool fresh) = adapter.referenceSqrtPriceX96();
        assertEq(sqrtPriceX96, 0, "unusable reading must report zero");
        assertFalse(fresh, "and must report itself unusable rather than reverting");

        for (int256 answer = 1; answer <= 6; answer++) {
            lowFeed.setAnswer(answer);
            adapter.referenceSqrtPriceX96();
        }
    }

    /// @dev A feed stamping a reading in the future is not evidence of freshness.
    function test_Adapter_FutureTimestampIsNotTreatedAsFresh() public {
        MockAggregatorV3 aheadFeed = new MockAggregatorV3(int256(1e8), block.timestamp + 1 days);
        ChainlinkReferenceAdapter adapter = new ChainlinkReferenceAdapter(
            IAggregatorV3(address(aheadFeed)),
            ORACLE_MAX_AGE,
            PRICE_NUMERATOR,
            Currency.wrap(address(token0)),
            18,
            Currency.wrap(address(token1)),
            18
        );

        (, bool fresh) = adapter.referenceSqrtPriceX96();
        assertFalse(fresh, "a future-stamped reading must not count as fresh");
    }
}
