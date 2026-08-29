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
///                              ---
///                              152 used, 104 free
///
///      Native packing is used rather than hand-rolled shifts so that sign extension of the
///      signed fields is the compiler's responsibility. `test_PoolState_OccupiesExactlyOneSlot`
///      asserts the layout, so a field added past the 256-bit budget fails loudly.
///
///      The reference price is cached rather than read on demand. Reading a Chainlink feed
///      costs roughly 20,000 gas measured against the live Base Sepolia aggregator, so it is
///      refreshed at most once per block and the quote path is served from this slot.
struct PoolState {
    int24 lastTick;
    int24 referenceTick;
    uint32 lastBlock;
    bool referenceFresh;
    int64 twapTickX32;
}
