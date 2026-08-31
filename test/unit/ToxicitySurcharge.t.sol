// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {BalanceDelta, toBalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {FeeBlend} from "../../src/libraries/FeeBlend.sol";
import {ToxicitySurcharge} from "../../src/libraries/ToxicitySurcharge.sol";

/// @dev `unspecifiedAmount` takes calldata, so it is reached through an external wrapper.
contract SurchargeHarness {
    function unspecified(SwapParams calldata params, BalanceDelta delta)
        external
        pure
        returns (bool currency0IsUnspecified, uint256 magnitude)
    {
        return ToxicitySurcharge.unspecifiedAmount(params, delta);
    }
}

contract ToxicitySurchargeTest is Test {
    SurchargeHarness internal harness;

    function setUp() public {
        harness = new SurchargeHarness();
    }

    function _params(bool zeroForOne, int256 amountSpecified) internal pure returns (SwapParams memory) {
        return SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: 0});
    }

    /// @dev v4 identifies the specified currency as token0 exactly when
    ///      `amountSpecified < 0 == zeroForOne`. The surcharge must land on the *other* side,
    ///      matching how an ordinary LP fee is taken. Getting this backwards would charge the
    ///      wrong token, so each of the four cases is pinned.
    function test_ExactInputZeroForOne_UnspecifiedIsCurrency1() public view {
        // Selling token0 exactly: specified is token0, so unspecified is token1.
        (bool c0, uint256 magnitude) =
            harness.unspecified(_params(true, -1 ether), toBalanceDelta(-1 ether, 3 ether));
        assertFalse(c0, "unspecified side should be currency1");
        assertEq(magnitude, 3 ether);
    }

    function test_ExactOutputZeroForOne_UnspecifiedIsCurrency0() public view {
        // Buying token1 exactly: specified is token1, so unspecified is token0.
        (bool c0, uint256 magnitude) =
            harness.unspecified(_params(true, 1 ether), toBalanceDelta(-3 ether, 1 ether));
        assertTrue(c0, "unspecified side should be currency0");
        assertEq(magnitude, 3 ether);
    }

    function test_ExactInputOneForZero_UnspecifiedIsCurrency0() public view {
        (bool c0, uint256 magnitude) =
            harness.unspecified(_params(false, -1 ether), toBalanceDelta(3 ether, -1 ether));
        assertTrue(c0, "unspecified side should be currency0");
        assertEq(magnitude, 3 ether);
    }

    function test_ExactOutputOneForZero_UnspecifiedIsCurrency1() public view {
        (bool c0, uint256 magnitude) =
            harness.unspecified(_params(false, 1 ether), toBalanceDelta(1 ether, -3 ether));
        assertFalse(c0, "unspecified side should be currency1");
        assertEq(magnitude, 3 ether);
    }

    /// @dev Unary minus on type(int128).min overflows. This runs on the swap path, so the
    ///      magnitude path is exercised at the extreme rather than assumed unreachable.
    function test_MostNegativeDelta_YieldsExactMagnitude() public view {
        (, uint256 magnitude) = harness.unspecified(_params(true, -1), toBalanceDelta(0, type(int128).min));
        assertEq(magnitude, uint256(1) << 127, "two's-complement negation must be exact");
    }

    function testFuzz_UnspecifiedAmount_NeverReverts(bool zeroForOne, int256 spec, int128 a0, int128 a1)
        public
        view
    {
        harness.unspecified(_params(zeroForOne, spec), toBalanceDelta(a0, a1));
    }

    function test_SurchargeAmount_IsPipsOfNotional() public pure {
        // 10,500 pips of 1 ether is 1.05% of it.
        assertEq(ToxicitySurcharge.surchargeAmount(1 ether, 10_500), 0.0105 ether);
    }

    function test_SurchargeAmount_ZeroOverflowTakesNothing() public pure {
        assertEq(ToxicitySurcharge.surchargeAmount(1 ether, 0), 0);
    }

    /// @dev Regression test for the pass-1 L-2 finding. The exact surcharge here is three
    ///      millionths of a wei. `FullMath.mulDiv` returned zero, which forgave the fee
    ///      outright; the swapper is charged the smallest unit the ledger can express.
    function test_SurchargeAmount_RoundsUpRatherThanForgivingTheRemainder() public pure {
        assertEq(ToxicitySurcharge.surchargeAmount(3, 1), 1);
    }

    /// @dev The rounding direction, stated over the whole domain: the amount taken is never
    ///      less than the exact share of notional the overflow calls for. Compared in scaled
    ///      integers so the exact value is never itself rounded. `notional` is a uint128 and
    ///      `overflowPips` is at most `PIPS_DENOMINATOR`, so neither product overflows.
    function testFuzz_SurchargeAmount_NeverRoundsDown(uint128 notional, uint24 overflowPips) public pure {
        overflowPips = uint24(bound(overflowPips, 0, FeeBlend.MAX_OVERFLOW_PIPS));
        uint256 amount = ToxicitySurcharge.surchargeAmount(notional, overflowPips);

        assertGe(
            amount * FeeBlend.PIPS_DENOMINATOR,
            uint256(notional) * overflowPips,
            "surcharge fell below the exact share of notional"
        );
    }

    /// @dev The bound that keeps the donation from ever exceeding the swap itself. A
    ///      surcharge larger than the notional it is charged on could not be settled.
    function testFuzz_SurchargeAmount_NeverExceedsNotional(uint128 notional, uint24 overflowPips)
        public
        pure
    {
        overflowPips = uint24(bound(overflowPips, 0, FeeBlend.MAX_OVERFLOW_PIPS));
        assertLe(ToxicitySurcharge.surchargeAmount(notional, overflowPips), notional);
    }
}
