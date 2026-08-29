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
    /// @param params The swap being priced.
    /// @param delta The balance delta the core swap produced, before any hook adjustment.
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
            // Two's-complement negation: unary minus on type(int128).min overflows, and this
            // runs on the swap path where a revert is unacceptable. `magnitude` mirrors
            // OrderFlowImbalance's identical guard for the same reason. Both branches
            // reinterpret the full 128-bit word and neither truncates.
            // forge-lint: disable-next-line(unsafe-typecast)
            magnitude = raw < 0 ? uint256(uint128(~raw)) + 1 : uint256(uint128(raw));
        }
        return (!specifiedIsToken0, magnitude);
    }

    /// @notice The surcharge amount to donate, in the unspecified currency.
    /// @dev Total over its input domain: `overflowPips` is already bounded by
    ///      `FeeBlend.MAX_OVERFLOW_PIPS`, and `FullMath.mulDiv` carries a 512-bit
    ///      intermediate, so this cannot overflow regardless of `notional`.
    /// @param notional The unspecified side's swap magnitude, from `unspecifiedAmount`.
    /// @param overflowPips The cap overflow from `FeeBlend.ceilingOverflowPips`, in pips.
    /// @return amount The amount to take from the swapper and donate to liquidity providers.
    function surchargeAmount(uint256 notional, uint24 overflowPips) internal pure returns (uint256 amount) {
        // The denominator is FeeBlend's own overflow ceiling, imported rather than repeated.
        // The guarantee that the surcharge never exceeds `notional` -- which is what makes
        // the int128 cast at the call site exact -- holds only while these two are equal, and
        // two matching literals in two files is not a guarantee.
        //
        // Rounded up: this is a fee, and a fee that rounds down leaks value to the swapper on
        // every swap that reaches this path. The bound still holds, because rounding up a
        // quotient whose exact value is at most `notional` cannot exceed `notional` unless
        // the division was already exact, in which case there is nothing to round.
        return FullMath.mulDivRoundingUp(notional, overflowPips, FeeBlend.MAX_OVERFLOW_PIPS);
    }
}
