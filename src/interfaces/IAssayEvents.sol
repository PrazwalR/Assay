// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Events emitted by Assay. Indexed parameters are those an indexer or LP
///         dashboard needs to filter on.
interface IAssayEvents {
    /// @notice Emitted once per pool when the hook attaches and seeds the base fee.
    /// @param poolId The pool the hook was attached to.
    /// @param baseFeePips The fee seeded via `updateDynamicLPFee`, in hundredths of a bip.
    event PoolRegistered(PoolId indexed poolId, uint24 baseFeePips);

    /// @notice Emitted for every scored swap, giving per-swap attribution of the quoted fee.
    /// @param poolId The pool the swap executed against.
    /// @param sender The address that called the PoolManager, which is the router and not
    ///        the trader. It must never be treated as an identity.
    /// @param feePips The fee quoted for this swap, in hundredths of a bip.
    event SwapAssayed(PoolId indexed poolId, address indexed sender, uint24 feePips);

    /// @notice Emitted when the reference price source starts or stops producing usable
    ///         readings for a pool.
    /// @dev Emitted only on transition, not per swap. A pool that goes stale is quoting
    ///      without a view of its own drift, which is the condition an operator most needs
    ///      to know about.
    /// @param poolId The pool whose reference changed state.
    /// @param fresh Whether the reference is now usable.
    event ReferenceFreshnessChanged(PoolId indexed poolId, bool fresh);

    /// @notice Emitted when a swap's drift exceeded what the percentage-of-notional fee
    ///         could express, and the remainder was taken and donated to in-range liquidity.
    /// @dev Rare by construction: it requires a dislocation large enough that the uncapped
    ///      fee formula exceeds `maxFeePips`, which does not happen on ordinary swaps.
    /// @param poolId The pool the donation was made to.
    /// @param amount The amount donated, in the swap's unspecified currency.
    /// @param inCurrency0 Whether that currency was `key.currency0`.
    event ToxicitySurchargeDonated(PoolId indexed poolId, uint256 amount, bool inCurrency0);

    /// @notice Emitted when the reference source reported a usable reading, but it was
    ///         rejected for disagreeing with the pool's own smoothed tick by more than the
    ///         configured cap. The pool is treated as if the reference were stale.
    /// @dev Distinct from `ReferenceFreshnessChanged` so an operator can tell "the feed went
    ///      dark" apart from "the feed answered, but this hook does not believe it" -- the
    ///      second is the more actionable one to page someone about.
    /// @param poolId The pool whose reference was rejected.
    /// @param referenceTick The rejected reading.
    /// @param twapTick The pool's own smoothed tick it was checked against.
    /// @param maxDeviationTicks The configured cap that was exceeded.
    event ReferenceDeviationCapTripped(
        PoolId indexed poolId, int24 referenceTick, int24 twapTick, uint24 maxDeviationTicks
    );
}
