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
}
