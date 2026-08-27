// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Q32x32} from "../../src/libraries/Q32x32.sol";

contract Q32x32Test is Test {
    /// @dev Convexity is the property the whole EWMA bound rests on: if a blend can ever
    ///      leave the interval spanned by its inputs, the variance estimate is unbounded and
    ///      every downstream overflow argument collapses.
    function testFuzz_Blend_StaysWithinItsInputs(uint64 previous, uint64 sample, uint64 lambda) public pure {
        lambda = uint64(bound(lambda, 0, Q32x32.ONE));
        uint64 result = Q32x32.blend(previous, sample, lambda);

        uint64 low = previous < sample ? previous : sample;
        uint64 high = previous < sample ? sample : previous;
        assertGe(result, low, "blend fell below both inputs");
        assertLe(result, high, "blend rose above both inputs");
    }

    function testFuzz_BlendSigned_StaysWithinItsInputs(int64 previous, int64 sample, uint64 lambda)
        public
        pure
    {
        lambda = uint64(bound(lambda, 0, Q32x32.ONE));
        int64 result = Q32x32.blendSigned(previous, sample, lambda);

        int64 low = previous < sample ? previous : sample;
        int64 high = previous < sample ? sample : previous;
        assertGe(result, low, "blend fell below both inputs");
        assertLe(result, high, "blend rose above both inputs");
    }

    function test_Blend_AtLambdaZeroTakesTheSample() public pure {
        assertEq(Q32x32.blend(1000, 7000, 0), 7000);
    }

    function test_Blend_AtLambdaOneKeepsThePrevious() public pure {
        assertEq(Q32x32.blend(1000, 7000, Q32x32.ONE), 1000);
    }

    function test_Blend_HalfwayAveragesBothInputs() public pure {
        assertEq(Q32x32.blend(1000, 3000, Q32x32.ONE / 2), 2000);
    }

    /// @dev A saturating ratio is deliberate. This runs on the swap path, where reverting
    ///      would brick the pool, and a ratio above one only means the order exceeded
    ///      measured depth -- which the fee curve treats identically to exactly one.
    function testFuzz_Ratio_NeverExceedsOne(uint128 numerator, uint128 denominator) public pure {
        assertLe(Q32x32.ratio(numerator, denominator), Q32x32.ONE);
    }

    function test_Ratio_ZeroDenominatorYieldsZero() public pure {
        assertEq(Q32x32.ratio(1000, 0), 0);
    }

    function test_Ratio_HalfIsHalfOfOne() public pure {
        assertEq(Q32x32.ratio(1, 2), Q32x32.ONE / 2);
    }

    function test_Ratio_SaturatesWhenNumeratorExceedsDenominator() public pure {
        assertEq(Q32x32.ratio(5, 1), Q32x32.ONE);
    }
}
