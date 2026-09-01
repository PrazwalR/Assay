# Gas

Three reachable paths, each budgeted and measured separately. A single number was never
honest: it described only the cheapest path, and CI measured only that one.

Source: `test/gas/HookOverhead.t.sol`. Both paths are warmed before measurement so the
figures exclude one-off cold account and storage access, which otherwise swamps the delta.

## Current

| path | measured | budget | headroom |
| --- | --- | --- | --- |
| ordinary swap | 16,180 | 20,000 | 19% |
| block boundary, mock feed | 36,349 | — | — |
| **block boundary, live feed** | **52,849** | 55,000 | 4% |
| extreme dislocation (surcharge) | 28,617 | 55,000 | 48% |

Re-measured after moving the reference refresh from `afterSwap` into `beforeSwap`. That
move is why the ordinary path rose from 14,920: `beforeSwap` now writes the state slot
rather than only reading it. It is the price of quoting a swap against a reference it can
actually see -- see `test/exploit/ReferenceLag.t.sol`.

The live-feed boundary headroom is now 4%, down from 8%. That is the number to watch: the
budget is a real ceiling, and the next change to this path will need to buy its own room.
The surcharge path fell to 28,617 because capping `MAX_OVERFLOW_PIPS` at 2% of notional
removed most of the work it used to do on an extreme dislocation.


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
- **`PoolState` is 248 of 256 bits.** Only 8 bits remain, so a new field almost certainly needs
  a second slot, which silently adds an `SLOAD` and an `SSTORE` to the hot path.
  `test_PoolState_OccupiesOneStorageSlot` asserts the layout.
- **Gas tests are excluded from `forge coverage`.** Coverage instrumentation inflates gas, so
  the assertions would measure the instrumented build rather than the shipped one.
