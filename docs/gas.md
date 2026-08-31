# Gas

Three reachable paths, each budgeted and measured separately. A single number was never
honest: it described only the cheapest path, and CI measured only that one.

Source: `test/gas/HookOverhead.t.sol`. Both paths are warmed before measurement so the
figures exclude one-off cold account and storage access, which otherwise swamps the delta.

## Current

| path | measured | budget | headroom |
| --- | --- | --- | --- |
| ordinary swap | 14,920 | 20,000 | 25% |
| block boundary, mock feed | 34,337 | — | — |
| **block boundary, live feed** | **50,837** | 55,000 | 8% |
| extreme dislocation (surcharge) | 49,253 | 55,000 | 10% |

Re-measured against `test/gas/HookOverhead.t.sol` directly (`forge test --match-path
test/gas/HookOverhead.t.sol -vv`) rather than assumed from the table below: every path costs
more than it did at the "after" snapshot in **What changed, and why**, because the
reference-deviation-cap module was added afterward and its check sits on the same
`afterSwap` path the variance removal shrank. Contract size moved with it: 9,625 bytes at
that snapshot, 10,811 bytes now (`forge inspect src/AssayHook.sol:AssayHook
deployedBytecode`, matches the deployed address). The live-feed path's headroom is the one
worth watching — it dropped from a comfortable 14% to 8% of budget, not because anything
regressed, but because two real features now share one gas budget that was sized for one.

**The live-feed figure is the one that matters.** Tests read a mock aggregator; a real
Chainlink read measured **20,774 gas** against the deployed Base Sepolia adapter
(`cast estimate`, less the 21,000 transaction base cost). The boundary test adds that
premium before asserting, so the budget is checked against production cost rather than the
mock's.

This is why the reference is cached and refreshed at most once per block. Reading it on the
quote path would put every swap on the boundary number.

## What changed, and why

Removing realised variance and order-flow imbalance from the swap path cut **3,268 gas from
every swap** and 1,713 bytes from the contract:

| | before | after |
| --- | --- | --- |
| ordinary swap | 17,840 | 14,572 |
| block boundary | 34,795 | 30,901 |
| surcharge | 51,847 | 48,582 |
| contract size | 11,338 | 9,625 |

They were removed because calibration measured their incremental value over the reference
signal at −0.008 and −0.002 across two independent windows. They were charging every swap
for a computation that made the classifier no better. The libraries remain in the tree, pure
and tested, for a milestone that can show they earn the cost.

Recovered specifically: one `getLiquidity` external call (415), the order-flow arithmetic
(~350), two `SwapAssayed` event words (512), and the per-block variance update.

## Constraints this analysis produced

- **The reference read dominates the boundary path.** At ~20,774 gas it is larger than
  everything else the hook does combined. Any future work to cut hook gas should start there,
  not with the arithmetic.
- **Lookup tables must live in bytecode, not storage.** A cold `SLOAD` is 2,100 gas; a
  `bytes constant` read via `CODECOPY` is roughly 3 gas per word.
- **`PoolState` is 88 of 256 bits.** Fields can be added without a second slot, but a field
  pushed past 256 silently adds an `SLOAD` and an `SSTORE` to the hot path.
  `test_PoolState_OccupiesOneStorageSlot` asserts the layout.
- **Gas tests are excluded from `forge coverage`.** Coverage instrumentation inflates gas, so
  the assertions would measure the instrumented build rather than the shipped one.
