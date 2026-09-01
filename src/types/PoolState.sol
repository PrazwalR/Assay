// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per-pool state the swap path reads and writes, sized to a single storage slot.
/// @dev Bit budget, packed by the compiler in declaration order:
///
///        int24  lastTick        24    most recent tick, updated on every swap
///        int24  referenceTick   24    cached reference price, refreshed once per period
///        uint32 lastBlock       32    block number the current period belongs to
///        bool   referenceFresh   8    whether the cached reference is usable
///        int64  twapTickX32     64    Q32.32 EWMA of the block-open tick; PoolTwap's anchor
///        uint32 lastRefreshAt   32    wall clock of the last boundary refresh
///        uint32 distrustedUntil 32    wall clock until which the reference is not trusted
///        uint32 lastSampleBlock 32    block the TWAP last folded a sample in
///                              ---
///                              248 used, 8 free
///
///      Native packing rather than hand-rolled shifts, so sign extension is the compiler's
///      responsibility. `test_PoolState_OccupiesExactlyOneSlot` asserts the layout, so a
///      field pushed past the 256-bit budget fails loudly rather than costing a second
///      SLOAD/SSTORE on every swap.
struct PoolState {
    int24 lastTick;
    int24 referenceTick;
    uint32 lastBlock;
    bool referenceFresh;
    int64 twapTickX32;
    uint32 lastRefreshAt;
    uint32 referenceDistrustedUntil;
    uint32 lastSampleBlock;
}
