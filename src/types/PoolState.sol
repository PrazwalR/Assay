// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Per-pool state the swap path reads and writes, sized to a single storage slot.
/// @dev Bit budget, packed by the compiler in declaration order:
///
///        int24  lastTick        24    most recent tick, updated on every swap
///        int24  blockOpenTick   24    tick as the current observation period opened
///        int24  referenceTick   24    cached reference price, refreshed once per period
///        uint32 lastBlock       32    block number the current period belongs to
///        uint64 varEwmaX32      64    realised variance, Q32.32, in squared ticks
///        int64  ofiEwmaX32      64    order-flow imbalance, Q32.32, in [-1, 1]
///        bool   referenceFresh   8    whether the cached reference is usable
///                              ---
///                              240 used, 16 free
///
///      Native packing is used rather than hand-rolled shifts so that sign extension of the
///      two signed fields is the compiler's responsibility. `test_PoolState_OccupiesOneSlot`
///      asserts the layout, so a field added past the 256-bit budget fails loudly.
///
///      Variance is carried in squared *ticks*, not squared log returns. The conversion
///      factor ln(1.0001)^2 is folded into the offline-generated fee curve, where it costs
///      nothing; keeping ticks on chain preserves full integer precision on delta^2 instead
///      of scaling a very small number into the fractional bits.
///      Two ticks are carried, not one. `lastTick` follows every swap so that it always
///      holds the price as the period ends; `blockOpenTick` holds the price as the period
///      began. Variance therefore samples a completed period's *net* move.
///
///      Recording a single tick taken after a period's first swap is exploitable: an
///      attacker displaces the price, leaves the recorded tick displaced, unwinds within the
///      same period where no sample is taken, and the next period measures the displacement
///      a second time -- charging two maximal samples for a round trip that moved the price
///      nowhere. `test_Exploit_RoundTripAcrossLiveBlocksCannotAmplifyVariance` covers it.
///      The reference price is cached rather than read on demand. Reading a Chainlink feed
///      costs roughly 25,000 to 40,000 gas cold, against a 40,000 gas budget for the hook's
///      entire marginal cost; refreshing once per block in `afterSwap` and serving the
///      quote path from this slot makes the read free where it matters.
struct PoolState {
    int24 lastTick;
    int24 blockOpenTick;
    int24 referenceTick;
    uint32 lastBlock;
    uint64 varEwmaX32;
    int64 ofiEwmaX32;
    bool referenceFresh;
}
