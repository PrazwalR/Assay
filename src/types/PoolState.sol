// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per-pool state the swap path reads and writes, sized to a single storage slot.
/// @dev Bit budget, packed by the compiler in declaration order:
///
///      24 + 24 + 32 + 8 + 64 + 32 + 32 + 32 = 248 used, 8 free. A field pushed past 256 bits
///      costs a second SLOAD/SSTORE on every swap, so `test_PoolState_OccupiesExactlyOneSlot`
///      asserts the layout instead.
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
