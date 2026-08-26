// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {FeeBlend} from "../../src/libraries/FeeBlend.sol";
import {Mispricing} from "../../src/libraries/Mispricing.sol";

contract FeeBlendTest is Test {
    uint24 internal constant BASE = 500;
    uint24 internal constant MIN = 100;
    uint24 internal constant MAX = 10_000;
    uint24 internal constant SHARE = 5000; // half the captured drift

    function _quote(int256 ticks, bool fresh) internal pure returns (uint24) {
        return FeeBlend.quote(ticks, fresh, BASE, MIN, MAX, SHARE);
    }

    function test_AlignedPoolQuotesTheBaseFee() public pure {
        assertEq(_quote(0, true), BASE);
    }

    /// @dev Half of a 50 tick drift is 25 basis points, which is 2,500 pips on top of base.
    function test_CapturedDriftIsChargedAtTheConfiguredShare() public pure {
        assertEq(_quote(50, true), BASE + 2500);
    }

    function test_TradingAwayFromTheReferenceIsQuotedBelowBase() public pure {
        assertLt(_quote(-50, true), BASE);
    }

    function test_QuoteIsMonotoneInCapturedDrift() public pure {
        assertLt(_quote(10, true), _quote(20, true));
        assertLt(_quote(20, true), _quote(40, true));
    }

    function test_LargeDriftSaturatesAtTheCeiling() public pure {
        assertEq(_quote(Mispricing.MAX_MISPRICING_TICKS, true), MAX);
    }

    function test_LargeAdverseDriftSaturatesAtTheFloor() public pure {
        assertEq(_quote(-Mispricing.MAX_MISPRICING_TICKS, true), MIN);
    }

    /// @dev Without a trustworthy reference the hook cannot tell which flow it faces, so it
    ///      charges the ceiling. Degrading upward protects liquidity providers rather than
    ///      underpricing whatever arrived while the reference was dark.
    function test_StaleReferenceQuotesTheCeiling() public pure {
        assertEq(_quote(0, false), MAX);
        assertEq(_quote(500, false), MAX);
        assertEq(_quote(-500, false), MAX);
    }

    /// @dev The bound a router relies on after reading `feeBounds()`. If a quote can ever
    ///      escape it, every integration built on that promise is wrong.
    function testFuzz_QuoteAlwaysWithinBounds(
        int256 ticks,
        bool fresh,
        uint24 base,
        uint24 min,
        uint24 max,
        uint24 share
    ) public pure {
        min = uint24(bound(min, 1, 1_000_000));
        max = uint24(bound(max, min, 1_000_000));
        base = uint24(bound(base, min, max));
        share = uint24(bound(share, 1, 10_000));
        ticks = bound(ticks, -Mispricing.MAX_MISPRICING_TICKS, Mispricing.MAX_MISPRICING_TICKS);

        uint24 quoted = FeeBlend.quote(ticks, fresh, base, min, max, share);
        assertGe(quoted, min, "quote fell through the floor");
        assertLe(quoted, max, "quote broke through the ceiling");
    }

    /// @dev Runs inside beforeSwap, where a revert makes the pool untradeable for everyone.
    ///      Total over the whole int256 domain, not merely the part `Mispricing` can produce:
    ///      the parameter is a plain int256 and a library that trusts its caller's bounds is
    ///      one refactor away from reverting a swap.
    function testFuzz_QuoteNeverReverts(int256 ticks, bool fresh, uint24 share) public pure {
        uint24 quoted = FeeBlend.quote(ticks, fresh, BASE, MIN, MAX, uint24(bound(share, 1, 10_000)));
        assertGe(quoted, MIN);
        assertLe(quoted, MAX);
    }

    function test_DriftBeyondTheBoundSaturatesRatherThanReverting() public pure {
        assertEq(_quote(type(int256).max, true), MAX, "extreme positive drift must saturate");
        assertEq(_quote(type(int256).min, true), MIN, "extreme negative drift must saturate");
    }

    // --- ceiling overflow -----------------------------------------------------------------

    function _overflow(int256 ticks, bool fresh) internal pure returns (uint24) {
        return FeeBlend.ceilingOverflowPips(ticks, fresh, BASE, MAX, SHARE);
    }

    /// @dev The overwhelming majority of swaps never reach the cap, so the overflow must be
    ///      exactly zero for them. If it were not, every ordinary swap would pay a surcharge.
    function test_OrdinaryDriftHasNoOverflow() public pure {
        assertEq(_overflow(0, true), 0, "aligned pool");
        assertEq(_overflow(50, true), 0, "modest drift");
        assertEq(_overflow(-5000, true), 0, "trading away from the reference");
    }

    /// @dev With base 500 and half of a 400 tick drift, the uncapped formula wants
    ///      500 + 400*50 = 20,500 pips against a 10,000 ceiling.
    function test_OverflowIsTheAmountBeyondTheCeiling() public pure {
        assertEq(_overflow(400, true), 10_500);
    }

    function test_OverflowBeginsExactlyWhereTheQuoteSaturates() public pure {
        // raw == MAX at drift 190: 500 + 190*50 = 10,000.
        assertEq(_quote(190, true), MAX, "quote should already be at the ceiling");
        assertEq(_overflow(190, true), 0, "at the ceiling there is nothing beyond it");
        assertGt(_overflow(191, true), 0, "one tick further must overflow");
    }

    /// @dev A stale reference already routes through the ordinary path at the ceiling. There
    ///      is no trusted drift reading to attribute an overflow to, so charging one on top
    ///      would be inventing a surcharge from an unusable measurement.
    function test_StaleReferenceNeverOverflows() public pure {
        assertEq(_overflow(0, false), 0);
        assertEq(_overflow(200_000, false), 0);
    }

    function testFuzz_OverflowIsBounded(int256 ticks, bool fresh, uint24 share) public pure {
        uint24 overflow =
            FeeBlend.ceilingOverflowPips(ticks, fresh, BASE, MAX, uint24(bound(share, 1, 10_000)));
        assertLe(overflow, FeeBlend.MAX_OVERFLOW_PIPS, "overflow escaped its bound");
    }

    /// @dev Quote and overflow are two halves of one number. Whenever an overflow exists the
    ///      quote must be saturated, and their sum must equal what the uncapped formula asked
    ///      for -- otherwise value is being created or destroyed at the boundary.
    function testFuzz_QuotePlusOverflowReconstructsTheUncappedFee(int256 ticks) public pure {
        ticks = bound(ticks, 0, FeeBlend.MAX_DRIFT_TICKS);
        uint24 overflow = _overflow(ticks, true);
        if (overflow == 0 || overflow == FeeBlend.MAX_OVERFLOW_PIPS) return;

        assertEq(_quote(ticks, true), MAX, "an overflow implies a saturated quote");

        int256 uncapped = int256(uint256(BASE)) + (ticks * 100 * int256(uint256(SHARE))) / 10_000;
        assertEq(
            int256(uint256(MAX)) + int256(uint256(overflow)), uncapped, "halves must reconstruct the whole"
        );
    }

    /// @dev A higher capture share must never produce a cheaper quote for the same drift.
    function testFuzz_HigherShareNeverQuotesLess(int256 ticks, uint24 lowShare, uint24 highShare)
        public
        pure
    {
        ticks = bound(ticks, 0, Mispricing.MAX_MISPRICING_TICKS);
        lowShare = uint24(bound(lowShare, 1, 10_000));
        highShare = uint24(bound(highShare, lowShare, 10_000));

        assertLe(
            FeeBlend.quote(ticks, true, BASE, MIN, MAX, lowShare),
            FeeBlend.quote(ticks, true, BASE, MIN, MAX, highShare)
        );
    }
}
