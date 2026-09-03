// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FullMath} from "v4-core/libraries/FullMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/types/PoolOperation.sol";

import {FeeBlend} from "./FeeBlend.sol";

/// @notice Turns a fee-cap overflow, in pips, into an absolute amount in the swap's
///         unspecified currency.
/// @dev `FeeBlend.quote` cannot express a surcharge beyond `maxFeePips`, because it charges
///      as a percentage of the swap's own notional and that percentage is capped. This
///      library recovers the discarded remainder as a real token amount, mirroring exactly
///      how v4's own LP fee is computed from a swap's delta -- the same identification of
///      "the unspecified currency" that `v4-core`'s reference `FeeTakingHook` uses.
library ToxicitySurcharge {
    /// @dev Identifies which side of a swap's delta is the unspecified currency and returns
    ///      its magnitude. The specified currency is the one named by `amountSpecified`; the
    ///      unspecified currency is the other one, and its post-swap delta magnitude is the
    ///      swap's notional in that currency -- the same quantity an ordinary LP fee is a
    ///      percentage of.
    /// @return currency0IsUnspecified Whether currency0 is the unspecified side.
    /// @return magnitude The unspecified side's notional, always non-negative.
    function unspecifiedAmount(SwapParams calldata params, BalanceDelta delta)
        internal
        pure
        returns (bool currency0IsUnspecified, uint256 magnitude)
    {
        bool specifiedIsToken0 = (params.amountSpecified < 0 == params.zeroForOne);
        int128 raw = specifiedIsToken0 ? delta.amount1() : delta.amount0();

        unchecked {
            // Two's-complement negation rather than unary minus: `-raw` overflows on
            // type(int128).min, and this runs on the swap path where a revert is unacceptable.
            // Both branches reinterpret the full 128-bit word, so neither truncates.
            // forge-lint: disable-next-line(unsafe-typecast)
            magnitude = raw < 0 ? uint256(uint128(~raw)) + 1 : uint256(uint128(raw));
        }
        return (!specifiedIsToken0, magnitude);
    }

    /// @notice The surcharge amount to donate, in the unspecified currency.
    /// @dev Total over its input domain: `overflowPips` is already bounded by
    ///      `FeeBlend.MAX_OVERFLOW_PIPS`, the denominator is `PIPS_DENOMINATOR`, and
    ///      `FullMath.mulDiv` carries a 512-bit
    ///      intermediate, so this cannot overflow regardless of `notional`.
    function surchargeAmount(uint256 notional, uint24 overflowPips) internal pure returns (uint256 amount) {
        // `overflowPips` is bounded by FeeBlend.MAX_OVERFLOW_PIPS (20,000) against a
        // PIPS_DENOMINATOR of 1,000,000, so the surcharge is at most 2% of `notional`. That is
        // what keeps the int128 cast at the call site exact. Both constants are imported from
        // FeeBlend rather than restated, because the bound is a relationship between them and
        // two matching literals in two files is not a guarantee.
        //
        // Rounded up: this is a fee, and one that rounds down leaks value to the swapper on
        // every swap reaching this path. Rounding up cannot break the 2% bound -- it adds at
        // most one unit to a quotient already far below `notional`.
        return FullMath.mulDivRoundingUp(notional, overflowPips, FeeBlend.PIPS_DENOMINATOR);
    }
}
