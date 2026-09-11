// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/types/PoolId.sol";

/// @notice Events emitted by Assay. Indexed parameters are those worth filtering on.
interface IAssayEvents {
    /// @notice Emitted once per pool when the hook attaches and seeds the base fee.
    event PoolRegistered(PoolId indexed poolId, uint24 baseFeePips);

    /// @notice Emitted for every scored swap, attributing the quoted fee.
    event SwapAssayed(PoolId indexed poolId, address indexed sender, uint24 feePips);

    /// @notice Emitted when the reference source starts or stops producing usable readings.
    /// @dev On transition only, not per swap.
    event ReferenceFreshnessChanged(PoolId indexed poolId, bool fresh);

    /// @notice Emitted when the fee-cap overflow was donated to in-range liquidity.
    event ToxicitySurchargeDonated(PoolId indexed poolId, uint256 amount, bool inCurrency0);

    /// @notice Emitted when wall clock advanced far more than the block count explains.
    event ChainHaltDetected(
        PoolId indexed poolId, uint256 secondsElapsed, uint256 blocksElapsed, uint32 distrustedUntil
    );

    /// @notice Emitted when a reading was rejected for disagreeing with the pool's own tick.
    /// @dev Distinct from `ReferenceFreshnessChanged`: a dark feed vs one the hook distrusts.
    event ReferenceDeviationCapTripped(
        PoolId indexed poolId, int24 referenceTick, int24 twapTick, uint24 maxDeviationTicks
    );
}
