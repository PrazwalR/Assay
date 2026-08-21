// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {OrderFlowImbalance} from "../../src/libraries/OrderFlowImbalance.sol";
import {Q32x32} from "../../src/libraries/Q32x32.sol";
import {VarianceEwma} from "../../src/libraries/VarianceEwma.sol";

contract VarianceEwmaTest is Test {
    uint64 internal constant LAMBDA = 4_037_269_258; // 0.94
    int24 internal constant CLAMP = 1000;

    function test_Update_FromZeroTakesTheWeightedSample() public pure {
        (uint64 updated,) = VarianceEwma.update(0, 100, 0, CLAMP, LAMBDA);
        // (1 - 0.94) * 100^2 = 600, in Q32.32
        assertApproxEqAbs(updated >> 32, 600, 1);
    }

    function test_Update_IsSymmetricInDirection() public pure {
        (uint64 up,) = VarianceEwma.update(0, 100, 0, CLAMP, LAMBDA);
        (uint64 down,) = VarianceEwma.update(0, -100, 0, CLAMP, LAMBDA);
        assertEq(up, down, "variance must not depend on the sign of the move");
    }

    function test_Update_FlagsAndTruncatesAnExcessiveMove() public pure {
        (uint64 clampedResult, bool clamped) = VarianceEwma.update(0, 50_000, 0, CLAMP, LAMBDA);
        (uint64 atBound, bool notClamped) = VarianceEwma.update(0, CLAMP, 0, CLAMP, LAMBDA);

        assertTrue(clamped, "excessive move was not flagged");
        assertFalse(notClamped, "a move at the bound must not be flagged");
        assertEq(clampedResult, atBound, "clamped move must contribute exactly the bound");
    }

    /// @dev The bound that makes every downstream overflow argument valid. If this can be
    ///      violated the packed state is corruptible by market data alone.
    function testFuzz_Update_NeverExceedsTheVarianceCeiling(
        uint64 previous,
        int24 tickNow,
        int24 tickLast,
        int24 clamp,
        uint64 lambda
    ) public pure {
        previous = uint64(bound(previous, 0, Q32x32.MAX_VARIANCE));
        clamp = int24(bound(clamp, 1, VarianceEwma.MAX_TICK_DELTA_CLAMP));
        lambda = uint64(bound(lambda, 1, Q32x32.ONE - 1));

        (uint64 updated,) = VarianceEwma.update(previous, tickNow, tickLast, clamp, lambda);
        assertLe(updated, Q32x32.MAX_VARIANCE, "variance escaped its ceiling");
    }

    /// @dev A larger realised move must never produce a smaller variance estimate.
    function testFuzz_Update_IsMonotoneInTheMove(int24 smallMove, int24 largeMove) public pure {
        smallMove = int24(bound(smallMove, 0, CLAMP));
        largeMove = int24(bound(largeMove, smallMove, CLAMP));

        (uint64 small,) = VarianceEwma.update(0, smallMove, 0, CLAMP, LAMBDA);
        (uint64 large,) = VarianceEwma.update(0, largeMove, 0, CLAMP, LAMBDA);
        assertGe(large, small, "a larger move produced less variance");
    }

    /// @dev Repeatedly feeding the same move must converge on that move's squared magnitude,
    ///      which is what makes the estimate interpretable as a variance at all.
    function test_Update_ConvergesToTheRepeatedSample() public pure {
        uint64 variance = 0;
        for (uint256 i = 0; i < 500; ++i) {
            (variance,) = VarianceEwma.update(variance, 100, 0, CLAMP, LAMBDA);
        }
        assertApproxEqRel(variance >> 32, 10_000, 0.01e18);
    }
}

contract OrderFlowImbalanceTest is Test {
    using Q32x32 for uint64;

    uint64 internal constant LAMBDA = 4_235_837_212; // 50-swap half-life

    function test_Update_BuyingPushesImbalancePositive() public pure {
        int64 updated = OrderFlowImbalance.update(0, 1 ether, 100 ether, LAMBDA);
        assertGt(updated, 0, "a buy must raise imbalance");
    }

    function test_Update_SellingPushesImbalanceNegative() public pure {
        int64 updated = OrderFlowImbalance.update(0, -1 ether, 100 ether, LAMBDA);
        assertLt(updated, 0, "a sell must lower imbalance");
    }

    function test_Update_IsAntisymmetricInDirection() public pure {
        int64 buy = OrderFlowImbalance.update(0, 1 ether, 100 ether, LAMBDA);
        int64 sell = OrderFlowImbalance.update(0, -1 ether, 100 ether, LAMBDA);
        assertEq(buy, -sell, "equal and opposite flow must cancel");
    }

    function test_Update_ZeroLiquidityContributesNothing() public pure {
        assertEq(OrderFlowImbalance.update(0, 1 ether, 0, LAMBDA), 0);
    }

    function testFuzz_Update_StaysWithinPlusMinusOne(int128 signedAmount, uint128 reserve, uint64 previous)
        public
        pure
    {
        int64 prior = int64(
            int256(
                bound(int256(uint256(previous)), -int256(uint256(Q32x32.ONE)), int256(uint256(Q32x32.ONE)))
            )
        );
        int64 updated = OrderFlowImbalance.update(prior, signedAmount, reserve, LAMBDA);

        assertLe(updated, int64(Q32x32.ONE), "imbalance exceeded +1");
        assertGe(updated, -int64(Q32x32.ONE), "imbalance fell below -1");
    }

    /// @dev Unary negation of type(int256).min overflows. Reachable inputs are int128-bounded
    ///      today, but the signature is not, so the magnitude path is exercised at the extreme.
    ///
    ///      This previously asserted only `<= 0` and passed vacuously at exactly 0: the
    ///      magnitude survived the negation and was then destroyed by an unchecked shift
    ///      inside `ratio`, so a maximal sell read as no flow at all. The assertion is now
    ///      exact so the same regression cannot hide again.
    function test_Update_HandlesMostNegativeInput() public pure {
        int64 updated = OrderFlowImbalance.update(0, type(int256).min, type(uint256).max, LAMBDA);
        int64 expected = Q32x32.blendSigned(0, -int64(Q32x32.ONE) / 2, LAMBDA);
        assertEq(updated, expected, "a sell of half the depth must register as half the depth");
        assertLt(updated, 0, "most-negative input must read as a sell");
    }

    /// @dev Regression: `(numerator << 32)` silently discarded the high bits above 2**224,
    ///      returning a value that was too *small* -- under-reporting toxicity, the
    ///      LP-adverse direction. Saturation now happens before any shift.
    function test_Update_HugeMagnitudeSaturatesRatherThanWrapping() public pure {
        int64 full = OrderFlowImbalance.update(0, int256(1) << 224, 1, LAMBDA);
        int64 expected = Q32x32.blendSigned(0, int64(Q32x32.ONE), LAMBDA);
        assertEq(full, expected, "a size far exceeding depth must saturate at full depth");
    }

    /// @dev Regression: the library trusted the caller's clamp. An out-of-range bound made
    ///      `uint64(squared) << 32` wrap, so a 54x larger move produced a 26% *smaller*
    ///      variance, inverting monotonicity without reverting.
    function test_Update_SelfDefendsAgainstAnOutOfRangeClamp() public pure {
        (uint64 unbounded,) = VarianceEwma.update(0, 887_272, -887_272, type(int24).max, LAMBDA);
        (uint64 atCeiling,) =
            VarianceEwma.update(0, 887_272, -887_272, VarianceEwma.MAX_TICK_DELTA_CLAMP, LAMBDA);
        assertEq(unbounded, atCeiling, "an out-of-range clamp must fall back to the ceiling");
        assertLe(unbounded, Q32x32.MAX_VARIANCE, "variance escaped its ceiling");
    }

    function testFuzz_Update_SignAlwaysMatchesFlowDirection(int128 signedAmount, uint128 reserve)
        public
        pure
    {
        vm.assume(signedAmount != 0 && reserve > 0);
        int64 updated = OrderFlowImbalance.update(0, signedAmount, reserve, LAMBDA);

        if (updated != 0) {
            assertEq(updated > 0, signedAmount > 0, "imbalance sign contradicts flow direction");
        }
    }
}
