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

    /// @notice Emitted for every scored swap, giving per-swap attribution of the quoted fee
    ///         alongside the state it was derived from.
    /// @param poolId The pool the swap executed against.
    /// @param sender The address that called the PoolManager, which is the router and not
    ///        the trader. It must never be treated as an identity.
    /// @param feePips The fee quoted for this swap, in hundredths of a bip.
    /// @param varEwmaX32 Realised variance after this swap, Q32.32, in squared ticks.
    /// @param ofiEwmaX32 Order-flow imbalance after this swap, Q32.32, in [-1, 1].
    event SwapAssayed(
        PoolId indexed poolId, address indexed sender, uint24 feePips, uint64 varEwmaX32, int64 ofiEwmaX32
    );

    /// @notice Emitted when a block's tick move exceeded the configured clamp and was
    ///         truncated before entering the variance estimate.
    /// @dev Rare by construction. A burst of these is evidence of either genuine market
    ///      dislocation or an attempt to inflate the variance estimate, and both are worth
    ///      alerting on.
    /// @param poolId The pool whose move was clamped.
    /// @param observedDelta The tick delta actually observed across the block.
    /// @param clampedTo The bound it was truncated to.
    event TickDeltaClamped(PoolId indexed poolId, int256 observedDelta, int24 clampedTo);

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
}
