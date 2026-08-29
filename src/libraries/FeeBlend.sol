// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Turns a swap's signed mispricing into the fee it should be quoted.
/// @dev The mechanism is the no-arbitrage band, not a fitted model. An arbitrageur profits
///      only when the drift they capture exceeds what they pay to capture it, so a fee set
///      as a share of that drift takes back part of what would otherwise be extracted while
///      leaving the trade worth doing. That matters: a fee large enough to deter arbitrage
///      entirely leaves the pool stale, which drives away the uninformed flow that is the
///      liquidity provider's only revenue.
///
///      Flow trading *away* from the reference captures nothing, so its mispricing is
///      negative and it is quoted below the base fee. That is the entire per-swap
///      discrimination: two swaps in one block, against the same drift, in opposite
///      directions, are quoted differently.
///
///      This is deliberately not the growth-optimal curve f*(v) from the design. That curve
///      needs three parameters that have not been estimated from data, and inventing them
///      would be worse than shipping a mechanism whose single parameter is honest.
library FeeBlend {
    /// @dev Bound applied to the drift before it is scaled. `Mispricing` already clamps to
    ///      this, but the parameter is a plain int256 and this function runs on the swap
    ///      path, so the bound is enforced here too rather than assumed of the caller. Without
    ///      it the scaling below overflows near the extremes of the type and reverts the swap.
    int256 internal constant MAX_DRIFT_TICKS = 200_000;

    /// @dev One tick is one basis point of price, and fees are quoted in hundredths of a
    ///      basis point, so a tick of drift is worth 100 pips of fee.
    int256 internal constant PIPS_PER_TICK = 100;

    /// @dev Denominator for `captureShareBps`.
    int256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev Ceiling on the value `ceilingOverflowPips` can report, independent of
    ///      `maxFeePips`. Bounding it here, rather than trusting the caller to bound what it
    ///      does with the result, keeps a later token-amount multiplication provably safe
    ///      regardless of how extreme the input drift is -- the same defence this codebase
    ///      has needed in three other libraries already.
    uint24 internal constant MAX_OVERFLOW_PIPS = 1_000_000;

    /// @dev The share-of-drift computation shared by `quote` and `ceilingOverflowPips`, kept
    ///      in one place so the two can never compute the surcharge differently.
    function _rawQuotedPips(int256 signedMispricingTicks, uint24 baseFeePips, uint24 captureShareBps)
        private
        pure
        returns (int256)
    {
        int256 drift = signedMispricingTicks;
        if (drift > MAX_DRIFT_TICKS) {
            drift = MAX_DRIFT_TICKS;
        } else if (drift < -MAX_DRIFT_TICKS) {
            drift = -MAX_DRIFT_TICKS;
        }

        int256 scaled = drift * PIPS_PER_TICK * int256(uint256(captureShareBps));

        // Rounded toward positive infinity so the quoted fee is never below the exact value.
        // Solidity's signed division truncates toward zero, which lowers the fee on the
        // capturing side -- the toxic side -- and is therefore the liquidity-adverse
        // direction. Truncation toward zero already rounds a negative surcharge upward, so
        // only the positive case needs correcting.
        int256 surcharge = scaled / BPS_DENOMINATOR;
        if (scaled > 0 && scaled % BPS_DENOMINATOR != 0) {
            surcharge += 1;
        }

        return int256(uint256(baseFeePips)) + surcharge;
    }

    /// @notice The fee to quote for a swap.
    /// @dev Total over its whole input domain. This runs inside `beforeSwap`, where a revert
    ///      would make the pool untradeable for everyone, so every path returns a value.
    /// @param signedMispricingTicks Drift this swap captures; negative when it trades away.
    /// @param referenceFresh Whether the mispricing reading can be trusted.
    /// @param baseFeePips Fee quoted when the pool sits at its reference.
    /// @param minFeePips Floor on any quote.
    /// @param maxFeePips Ceiling on any quote.
    /// @param captureShareBps Share of captured drift to charge, in basis points.
    /// @return feePips The quoted fee, always within [minFeePips, maxFeePips].
    function quote(
        int256 signedMispricingTicks,
        bool referenceFresh,
        uint24 baseFeePips,
        uint24 minFeePips,
        uint24 maxFeePips,
        uint24 captureShareBps
    ) internal pure returns (uint24 feePips) {
        // Without a trustworthy reference the hook cannot tell which flow it is facing, so
        // it charges the ceiling. Degrading upward is the conservative direction: it errs
        // toward protecting liquidity providers rather than toward underpricing whatever
        // arrived while the reference was dark. It never reverts.
        if (!referenceFresh) return maxFeePips;

        int256 quoted = _rawQuotedPips(signedMispricingTicks, baseFeePips, captureShareBps);

        if (quoted < int256(uint256(minFeePips))) return minFeePips;
        if (quoted > int256(uint256(maxFeePips))) return maxFeePips;

        // Both bounds are uint24 and the value now lies between them, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(quoted));
    }

    /// @notice How far the *uncapped* formula wants to charge beyond `maxFeePips`.
    /// @dev `quote` expresses the surcharge as a percentage of the swap's own notional, and
    ///      that percentage is capped at `maxFeePips` for reasons unrelated to how toxic any
    ///      given swap is -- an LP fee above a few percent is not a sane pool parameter
    ///      regardless of what the mispricing formula would ask for. On an ordinary swap the
    ///      cap is never reached and this returns zero. On an extreme dislocation (a rare
    ///      tail event, not the common case) the formula wants to charge more than a
    ///      percentage-of-notional fee can express, and everything past the cap is silently
    ///      discarded by `quote` alone.
    ///
    ///      This is that discarded remainder, in the same pips units, so a caller can recover
    ///      it as an absolute amount and route it to liquidity providers directly rather than
    ///      losing it to the cap. It is zero whenever the reference is stale: with no trusted
    ///      drift reading there is nothing to attribute an overflow to, and `quote` is already
    ///      charging the ceiling through the ordinary path in that case.
    /// @param signedMispricingTicks Drift this swap captures; negative when it trades away.
    /// @param referenceFresh Whether the mispricing reading can be trusted.
    /// @param baseFeePips Fee quoted when the pool sits at its reference.
    /// @param maxFeePips Ceiling `quote` applies.
    /// @param captureShareBps Share of captured drift to charge, in basis points.
    /// @return overflowPips The amount by which the uncapped formula exceeds `maxFeePips`,
    ///         zero if it does not, bounded by `MAX_OVERFLOW_PIPS` regardless of input.
    function ceilingOverflowPips(
        int256 signedMispricingTicks,
        bool referenceFresh,
        uint24 baseFeePips,
        uint24 maxFeePips,
        uint24 captureShareBps
    ) internal pure returns (uint24 overflowPips) {
        if (!referenceFresh) return 0;

        int256 raw = _rawQuotedPips(signedMispricingTicks, baseFeePips, captureShareBps);
        int256 ceiling = int256(uint256(maxFeePips));
        if (raw <= ceiling) return 0;

        int256 overflow = raw - ceiling;
        if (overflow > int256(uint256(MAX_OVERFLOW_PIPS))) {
            overflow = int256(uint256(MAX_OVERFLOW_PIPS));
        }

        // overflow is now in [1, MAX_OVERFLOW_PIPS], which fits uint24 (max 16,777,215).
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(overflow));
    }
}
