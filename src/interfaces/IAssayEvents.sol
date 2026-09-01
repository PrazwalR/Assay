// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Events emitted by Assay. Indexed parameters are those an indexer or LP
///         dashboard needs to filter on.
interface IAssayEvents {
    /// @notice Emitted once per pool when the hook attaches and seeds the base fee.
    event PoolRegistered(PoolId indexed poolId, uint24 baseFeePips);

    /// @notice Emitted for every scored swap, giving per-swap attribution of the quoted fee.
    event SwapAssayed(PoolId indexed poolId, address indexed sender, uint24 feePips);

    /// @notice Emitted when the reference source starts or stops producing usable readings.
    /// @dev On transition only, not per swap.
    event ReferenceFreshnessChanged(PoolId indexed poolId, bool fresh);

    /// @notice Emitted when a swap's drift exceeded what a percentage fee could express and
    ///         the remainder was donated to in-range liquidity.
    /// @dev Rare by construction: needs a dislocation past `maxFeePips`.
    event ToxicitySurchargeDonated(PoolId indexed poolId, uint256 amount, bool inCurrency0);

    /// @notice Emitted when wall-clock time advanced far more than the block count explains,
    ///         which on a single-sequencer chain means production stopped.
    /// @dev Separate from `ReferenceFreshnessChanged`: this reacts to the chain having been
    ///      absent, not to anything observed about the feed.
    event ChainHaltDetected(
        PoolId indexed poolId, uint256 secondsElapsed, uint256 blocksElapsed, uint32 distrustedUntil
    );

    /// @notice Emitted when a usable reading was rejected for disagreeing with the pool's own
    ///         smoothed tick by more than the cap.
    /// @dev Distinct from `ReferenceFreshnessChanged` so "the feed went dark" can be told
    ///      apart from "the feed answered and this hook does not believe it".
    event ReferenceDeviationCapTripped(
        PoolId indexed poolId, int24 referenceTick, int24 twapTick, uint24 maxDeviationTicks
    );
}
