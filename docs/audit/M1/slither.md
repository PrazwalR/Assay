# Slither — P1

`slither . --config-file slither.config.json` → **0 results**.

Four findings were raised on the first run. Their disposition:

## Fixed

**`reentrancy-events` in `_afterInitialize`** — the `PoolRegistered` event was emitted after
the external call to `poolManager.updateDynamicLPFee`. No state is written after that call and
the PoolManager cannot re-enter the hook, so the practical risk was nil, but the event is now
emitted before the call. If the call reverts the whole transaction reverts and the event never
persists, so ordering is equivalent and the detector is satisfied rather than suppressed.

## Excluded with justification

**`naming-convention` on `BASE_FEE_PIPS`, `MIN_FEE_PIPS`, `MAX_FEE_PIPS`** — Slither expects
`mixedCase` for immutables. The project style guide mandates `SCREAMING_SNAKE_CASE` for
constants and immutables, matching Solidity's own convention for constants; Slither's rule
predates immutables being a distinct kind. The detector is excluded in `slither.config.json`
rather than the code being renamed.

This is the only excluded detector. It is excluded globally rather than inline because the
convention applies to every immutable the project will add.

## Reference oracle module

`slither . --config-file slither.config.json` → **0 results**.

Two findings were raised on the oracle adapter and both are triaged in the source rather
than suppressed globally.

**`timestamp` on the staleness comparison.** Whether a price reading is too old is a
wall-clock question, so `block.timestamp` is the only available answer. A proposer can move
it by a few seconds; that is immaterial against a bound measured in minutes or hours, and in
either direction the worst outcome is a reading marked unusable rather than a wrong price
being trusted.

**`unused-return` on `latestRoundData`.** `roundId`, `startedAt` and `answeredInRound` are
deliberately discarded. The `answeredInRound >= roundId` idiom applied to legacy aggregators
and is no longer meaningful for OCR feeds, so checking it would provide false assurance
rather than protection. `updatedAt` is the field that carries staleness and it is checked.


## Toxicity surcharge module

`slither . --config-file slither.config.json` → **0 results**.

Five findings were raised and all are triaged in the source rather than suppressed globally.

**`reentrancy-events` on the donation.** The event was emitted after `donate`. It now precedes
the call: if `donate` reverts the whole transaction reverts and the event never persists, so
the ordering is equivalent and the log cannot be observed mid-call. Same fix as the identical
finding on `_afterInitialize`.

**`unused-return` on `donate` (two call sites).** The returned `BalanceDelta` is exactly
`-amount` on the donated side, which is already known at the call site and is what the
returned hook delta credits back. Discarded deliberately.

**`incorrect-equality` on `overflowPips == 0` and `amount == 0`.** The detector targets
comparisons against balances or prices. These are exact comparisons against exactly-computed
integers, where zero is a meaningful short-circuit: no overflow to charge, or a swap too
small for the surcharge to round to a single unit. Both must return before any external call.
