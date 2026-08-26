// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {Mispricing} from "../../src/libraries/Mispricing.sol";

contract MispricingTest is Test {
    /// @dev The sign convention is the whole point: it is what makes this a per-swap
    ///      quantity rather than a pool-level one. Two swaps in the same block against the
    ///      same drift must receive opposite values.
    function test_SignedTicks_OppositeDirectionsGetOppositeSigns() public pure {
        int256 sellingToken0 = Mispricing.signedTicks(-500, 0, true);
        int256 buyingToken0 = Mispricing.signedTicks(-500, 0, false);

        assertGt(sellingToken0, 0, "a swap toward a lower reference captures drift");
        assertEq(sellingToken0, -buyingToken0, "opposite directions must mirror exactly");
    }

    function test_SignedTicks_AlignedPoolHasNoDrift() public pure {
        assertEq(Mispricing.signedTicks(1000, 1000, true), 0);
        assertEq(Mispricing.signedTicks(1000, 1000, false), 0);
    }

    function test_SignedTicks_ReferenceAbovePoolFavoursBuyingToken0() public pure {
        assertGt(Mispricing.signedTicks(700, 200, false), 0);
        assertLt(Mispricing.signedTicks(700, 200, true), 0);
    }

    function test_SignedTicks_ClampsAnAbsurdReading() public pure {
        int256 extreme = Mispricing.signedTicks(type(int24).max, type(int24).min, false);
        assertEq(extreme, Mispricing.MAX_MISPRICING_TICKS, "an absurd gap must be bounded");
    }

    /// @dev Runs on the swap path, so it must be total over the whole input domain.
    function testFuzz_SignedTicks_NeverRevertsAndStaysBounded(
        int24 referenceTick,
        int24 poolTick,
        bool zeroForOne
    ) public pure {
        int256 result = Mispricing.signedTicks(referenceTick, poolTick, zeroForOne);
        assertLe(result, Mispricing.MAX_MISPRICING_TICKS);
        assertGe(result, -Mispricing.MAX_MISPRICING_TICKS);
    }

    function testFuzz_SignedTicks_IsAntisymmetricInDirection(int24 referenceTick, int24 poolTick)
        public
        pure
    {
        assertEq(
            Mispricing.signedTicks(referenceTick, poolTick, true),
            -Mispricing.signedTicks(referenceTick, poolTick, false),
            "direction must only flip the sign"
        );
    }
}
