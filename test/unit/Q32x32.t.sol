// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Q32x32} from "../../src/libraries/Q32x32.sol";

contract Q32x32Test is Test {
    /// @dev Convexity is the property the TWAP anchor's bound rests on: if a blend can ever
    ///      leave the interval spanned by its inputs, the anchor is unbounded and the
    ///      deviation cap that reads it stops meaning anything.
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

    function test_BlendSigned_AtLambdaZeroTakesTheSample() public pure {
        assertEq(Q32x32.blendSigned(1000, 7000, 0), 7000);
    }

    function test_BlendSigned_AtLambdaOneKeepsThePrevious() public pure {
        assertEq(Q32x32.blendSigned(1000, 7000, Q32x32.ONE), 1000);
    }

    function test_BlendSigned_HalfwayAveragesBothInputs() public pure {
        assertEq(Q32x32.blendSigned(1000, 3000, Q32x32.ONE / 2), 2000);
    }

    /// @dev The negative half of the domain, which the pool's tick anchor genuinely reaches
    ///      and which an unsigned blend could never have exercised.
    function test_BlendSigned_HalfwayAcrossZero() public pure {
        assertEq(Q32x32.blendSigned(-2000, 2000, Q32x32.ONE / 2), 0);
    }

    function test_BlendSigned_HalfwayBetweenTwoNegatives() public pure {
        assertEq(Q32x32.blendSigned(-3000, -1000, Q32x32.ONE / 2), -2000);
    }
}
