// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";

import {PoolTwap} from "../../src/libraries/PoolTwap.sol";
import {Q32x32} from "../../src/libraries/Q32x32.sol";

contract PoolTwapTest is Test {
    function test_Seed_ThenTick_RoundTripsExactly() public pure {
        assertEq(PoolTwap.tick(PoolTwap.seed(0)), 0);
        assertEq(PoolTwap.tick(PoolTwap.seed(12_345)), 12_345);
        assertEq(PoolTwap.tick(PoolTwap.seed(-12_345)), -12_345);
        assertEq(PoolTwap.tick(PoolTwap.seed(TickMath.MIN_TICK)), TickMath.MIN_TICK);
        assertEq(PoolTwap.tick(PoolTwap.seed(TickMath.MAX_TICK)), TickMath.MAX_TICK);
    }

    function testFuzz_Seed_ThenTick_RoundTripsExactly(int24 poolTick) public pure {
        poolTick = int24(bound(int256(poolTick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        assertEq(PoolTwap.tick(PoolTwap.seed(poolTick)), poolTick);
    }

    /// @dev Lambda at ONE means "retain all history, ignore the sample" -- `Q32x32.blend`'s
    ///      own documented behaviour. The average must not move at all.
    function test_Update_AtLambdaOne_IgnoresTheSample() public pure {
        int64 twap = PoolTwap.seed(1000);
        int64 updated = PoolTwap.update(twap, 50_000, Q32x32.ONE);
        assertEq(updated, twap, "lambda == ONE must retain the previous average exactly");
    }

    /// @dev The one property this whole library exists for: a single block's sample, however
    ///      extreme, can only move the average by a small, lambda-bounded step. This is the
    ///      library-level statement of the same manipulation resistance the integration test
    ///      proves end to end through the hook.
    function test_Update_AtHighLambda_ExtremeSingleSampleMovesAverageOnlySlightly() public pure {
        int64 twap = PoolTwap.seed(0);
        // 0.99 in Q32.32, matching the deployed default: one block should move the tick
        // average by roughly 1% of the distance to an arbitrarily extreme sample.
        uint64 lambda = 4_252_017_623;

        int64 updated = PoolTwap.update(twap, TickMath.MAX_TICK, lambda);
        int24 movedTo = PoolTwap.tick(updated);

        assertGt(movedTo, 0, "a positive sample must move the average toward it, not away");
        assertLt(
            movedTo, 10_000, "one block at lambda 0.99 must not move the average anywhere near the sample"
        );
    }

    /// @dev Symmetric statement of the same property in the negative direction.
    function test_Update_AtHighLambda_ExtremeNegativeSampleMovesAverageOnlySlightly() public pure {
        int64 twap = PoolTwap.seed(0);
        uint64 lambda = 4_252_017_623;

        int64 updated = PoolTwap.update(twap, TickMath.MIN_TICK, lambda);
        int24 movedTo = PoolTwap.tick(updated);

        assertLt(movedTo, 0);
        assertGt(movedTo, -10_000);
    }

    /// @dev Folding the same tick repeatedly must converge the average to within one tick of
    ///      it, confirming the estimator tracks a sustained move rather than only resisting a
    ///      transient one.
    ///
    ///      Not exactly equal: `blendSigned`'s division truncates toward zero, so approaching
    ///      a positive target from below has a permanent fixed point one ULP short of it --
    ///      the same asymmetry `Q32x32.blendSigned` documents on its own signed division.
    ///      One tick is immaterial next to the multi-thousand-tick caps this feeds.
    function test_Update_RepeatedSampleConvergesWithinOneTick() public pure {
        int64 twap = PoolTwap.seed(0);
        uint64 lambda = 4_252_017_623; // 0.99

        for (uint256 i = 0; i < 2000; ++i) {
            twap = PoolTwap.update(twap, 5000, lambda);
        }

        assertApproxEqAbs(PoolTwap.tick(twap), int24(5000), 1, "must converge to within one tick");
    }

    function testFuzz_Update_NeverReverts(int64 twapTickX32, int24 poolTick, uint64 lambdaX32) public pure {
        lambdaX32 = uint64(bound(lambdaX32, 0, Q32x32.ONE));
        PoolTwap.update(twapTickX32, poolTick, lambdaX32);
    }

    function test_DeviationTicks_PositiveWhenReferenceAboveAnchor() public pure {
        int64 twap = PoolTwap.seed(1000);
        assertEq(PoolTwap.deviationTicks(twap, 1500), 500);
        assertEq(PoolTwap.deviationTicks(twap, 500), -500);
        assertEq(PoolTwap.deviationTicks(twap, 1000), 0);
    }

    function test_WithinBound_ZeroCapAlwaysPasses() public pure {
        int64 twap = PoolTwap.seed(0);
        assertTrue(PoolTwap.withinBound(twap, 0, 0));
        assertTrue(PoolTwap.withinBound(twap, TickMath.MAX_TICK, 0));
        assertTrue(PoolTwap.withinBound(twap, TickMath.MIN_TICK, 0));
    }

    function test_WithinBound_ExactlyAtCapPasses() public pure {
        int64 twap = PoolTwap.seed(1000);
        assertTrue(PoolTwap.withinBound(twap, 1500, 500), "exactly at the cap must pass");
        assertTrue(PoolTwap.withinBound(twap, 500, 500), "exactly at the cap must pass on the other side");
    }

    function test_WithinBound_OnePastCapFails() public pure {
        int64 twap = PoolTwap.seed(1000);
        assertFalse(PoolTwap.withinBound(twap, 1501, 500));
        assertFalse(PoolTwap.withinBound(twap, 499, 500));
    }

    function testFuzz_WithinBound_ZeroCapAlwaysPasses(int64 twapTickX32, int24 referenceTick) public pure {
        assertTrue(PoolTwap.withinBound(twapTickX32, referenceTick, 0));
    }

    function testFuzz_WithinBound_MatchesDeviationTicks(
        int64 twapTickX32,
        int24 referenceTick,
        uint24 maxDeviation
    ) public pure {
        int256 gap = PoolTwap.deviationTicks(twapTickX32, referenceTick);
        if (gap < 0) gap = -gap;
        bool expected = maxDeviation == 0 || gap <= int256(uint256(maxDeviation));
        assertEq(PoolTwap.withinBound(twapTickX32, referenceTick, maxDeviation), expected);
    }
}
