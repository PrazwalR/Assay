// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Mispricing} from "./Mispricing.sol";

/// @notice Turns a swap's signed mispricing into the fee it should be quoted.
/// @dev A no-arbitrage band, not a fitted model. A *share* of the captured drift leaves the
///      trade worth doing; deterring arbitrage entirely leaves the pool stale, which drives
///      away the uninformed flow that is the LP's only revenue.
library FeeBlend {
    /// @dev Re-clamped rather than assumed of the caller, or the scaling below overflows.
    ///      Imported from `Mispricing`: two matching literals are not a guarantee.
    int256 internal constant MAX_DRIFT_TICKS = Mispricing.MAX_MISPRICING_TICKS;

    /// @dev One tick is one basis point, and fees are in hundredths of one.
    int256 internal constant PIPS_PER_TICK = 100;

    /// @dev Denominator for `captureShareBps`.
    int256 internal constant BPS_DENOMINATOR = 10_000;

    /// @dev 100% in pips: the scale the surcharge is measured against, not a bound on it.
    uint24 internal constant PIPS_DENOMINATOR = 1_000_000;

    /// @dev Ceiling on the surcharge, as a share of notional. 2% covers dislocations to ~35%
    ///      of price movement while bounding what manufactured drift can extract.
    uint24 internal constant MAX_OVERFLOW_PIPS = 20_000;

    /// @dev Shared by `quote` and `ceilingOverflowPips` so the two cannot diverge.
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

        // Toward +inf, so the fee is never below the exact value: Solidity truncates toward
        // zero, lowering it on the capturing side. Negatives already round up.
        int256 surcharge = scaled / BPS_DENOMINATOR;
        if (scaled > 0 && scaled % BPS_DENOMINATOR != 0) {
            surcharge += 1;
        }

        return int256(uint256(baseFeePips)) + surcharge;
    }

    /// @notice The fee to quote for a swap.
    /// @dev Total over its input domain: a revert in `beforeSwap` would make the pool
    ///      untradeable for every LP, so every path returns a value.
    /// @return feePips The quoted fee, always within [minFeePips, maxFeePips].
    function quote(
        int256 signedMispricingTicks,
        bool referenceFresh,
        uint24 baseFeePips,
        uint24 minFeePips,
        uint24 maxFeePips,
        uint24 captureShareBps
    ) internal pure returns (uint24 feePips) {
        // No trustworthy reference means no way to tell which flow this is, so it charges
        // the ceiling. Degrading *upward* protects LPs.
        if (!referenceFresh) return maxFeePips;

        int256 quoted = _rawQuotedPips(signedMispricingTicks, baseFeePips, captureShareBps);

        if (quoted < int256(uint256(minFeePips))) return minFeePips;
        if (quoted > int256(uint256(maxFeePips))) return maxFeePips;

        // Both bounds are uint24 and the value now lies between them, so the cast is exact.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(quoted));
    }

    /// @notice How far the *uncapped* formula wants to charge beyond `maxFeePips`.
    /// @dev `quote` discards everything past its cap; this is that remainder, recoverable as
    ///      a token amount. Zero on an ordinary swap and on a stale reference.
    /// @return overflowPips Excess over `maxFeePips`, bounded by `MAX_OVERFLOW_PIPS`.
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

        // Now in [1, MAX_OVERFLOW_PIPS], which fits uint24.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(uint256(overflow));
    }
}
