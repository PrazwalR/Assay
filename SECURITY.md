# Security

## Status

**This code is unaudited and has never held value.** It is deployed to Base Sepolia only.
Do not deploy it to a network where it would custody real funds without an independent
review.

## Reporting a vulnerability

Open a private security advisory on the repository rather than a public issue. Include the
affected file and line, the conditions required to reach the code, and the impact. A proof
of concept as a Foundry test is the most useful form.

## Threat model

The hook quotes a fee and takes a surcharge on extreme dislocation. It holds no custody of
swap principal, takes no liquidity permissions, and cannot prevent a liquidity provider from
withdrawing.

The properties the code is built to hold, each covered by tests under `test/`:

- `beforeSwap` and `afterSwap` never revert for a well-formed swap on any pool state. A
  revert on the swap path is a denial of service against every liquidity provider in the
  pool, so every failure degrades to a quoted fee instead.
- Every quoted fee lies within the `[minFeePips, maxFeePips]` range that `feeBounds()`
  advertises, so a router reading it before quoting is not misled.
- The surcharge nets to exactly zero for the hook: `donate` debits it and the returned delta
  repays it, leaving the swapper as the sole funder and the hook holding no balance.
- Only pools whose currencies match the reference oracle's declared pair may attach.
- A reference that is stale, reverting, or out of range degrades to the maximum fee rather
  than to a wrong price presented as correct.
- A reference the oracle itself reports as fresh is checked a second time against `PoolTwap`,
  a smoothed average of the pool's own tick sampled once per block. One that disagrees by
  more than the configured cap is treated exactly like a stale reading -- see "Reference
  deviation cap" below.

## Analysed and found not exploitable

**Self-dealing on the surcharge.** The surcharge is funded by the swapper and donated
pro-rata to in-range liquidity, so an attacker who is also a liquidity provider recovers
their own share of it. Holding share `s` of in-range liquidity, they pay `S` and receive
`s * S`, a net cost of `(1 - s) * S`. At `s = 1` the surcharge is free — but the attacker is
then the only liquidity provider, so the adverse selection being priced is damage to
themselves and there is no counterparty left to extract from. The mechanism degrades to
economically neutral rather than to exploitable.

**Removing the direction sign.** `Mispricing.signedTicks` flips sign on `zeroForOne`, and
that single flip is the entire per-swap mechanism: without it the hook prices the pool's
drift rather than the order's relationship to it, which is what every volatility-based hook
already does. Mutation testing confirms seven tests fail if it is removed.

**Pool binding.** Disabling either half of the currency check in `_beforeInitialize` fails a
test written specifically for that half. Mutation testing found the `currency0` half
initially unprotected — every existing case also mismatched on `currency1`, masking it — and
`test_Exploit_MismatchedCurrency0AloneIsRefused` now covers it.

## Reference deviation cap

A Chainlink reading that passes every check `ChainlinkReferenceAdapter` performs on its own
(fresh, positive, decimals-validated, in range) can still be wrong: a compromised aggregator,
or a misconfiguration on a chain this hook has no independent view of. `_advanceStateInPlace`
checks a fresh reading a second time against `PoolTwap`, an exponentially weighted average of
the pool's own tick that is sampled once per block rather than once per swap -- the same
anti-manipulation reasoning `VarianceEwma` uses, applied to a different estimator. A reading
that disagrees with that average by more than `maxReferenceDeviationTicks` is treated exactly
like a stale one: `referenceFresh` is forced false, the rejected value is never adopted, and
`ReferenceDeviationCapTripped` fires so an operator can tell "the feed went dark" apart from
"the feed answered, but this hook does not believe it."

Sampling the *block-open* tick specifically -- the pool's tick as of the end of the previous
block, captured before the current block's own swaps can touch it -- is what makes the check
resistant to being defeated from inside the same transaction that needs a bad reading to look
consistent with the pool's price. `test_Exploit_SameBlockPriceManipulationCannotMoveTheTwapAnchor`
proves a same-block swap that moves the pool's spot tick hard leaves the anchor completely
unchanged.

**Residual limitation, stated rather than left implicit:** the default cap (20,000 ticks,
~2.7x) is reasoned from tick-space bounds -- the gap between plausible real-market volatility
and the order-of-magnitude errors a decimals mistake or compromised feed produces -- not
calibrated against real feed-failure data. It catches gross errors, not a subtly wrong value
that happens to sit inside the tolerance. See `.env`'s own comment on
`ASSAY_MAX_REFERENCE_DEVIATION_TICKS` for the full reasoning, including the specific numbers
that gap is built from.

## Oracle: gaps analysed and accepted, not fixed

Three items from an external checklist-driven review of `ChainlinkReferenceAdapter` and its
read path. Recorded here as explicit decisions rather than left as unexamined omissions.

**No L2 sequencer uptime check.** The hook deploys to Base, an OP-stack L2, where the usual
mitigation is reading Chainlink's sequencer uptime feed and enforcing a grace period after a
restart. This adapter does not. The classic failure that check prevents — a lending protocol
liquidating against a stale price right after a restart — does not apply here in the same
direction: the aggregator itself cannot be updated while the sequencer is down, so
`updatedAt` stops advancing, the existing staleness check already fires, and `FeeBlend.quote`
falls back to `maxFeePips`. The pool over-charges after a restart rather than under-charging,
which is the safe side of the mistake. The residual cost is real but bounded: swaps between
sequencer restart and the first feed update pay the ceiling fee rather than a fair one. Adding
a second external call to the refresh path — in a system whose gas budget is already the
binding constraint — to catch a condition the staleness check already handles conservatively
was judged not worth its cost.

**Aggregator min/max circuit breakers are not checked.** When a feed's true price moves
outside its configured `[minAnswer, maxAnswer]`, some aggregators report the bound instead of
reverting, and this adapter would accept that as a fresh, correct reading. On the feed this is
deployed against, both bounds are non-binding `int192` sentinel defaults — `minAnswer = 1`
(~$1e-8), `maxAnswer` near `9.6e44` — orders of magnitude outside any price ETH could reach.
Not exploitable against this feed. If this adapter is ever pointed at a different aggregator,
its min/max bounds should be checked before assuming this analysis still holds.

**The oracle `try/catch` can be forced into its catch branch by gas metering.** EIP-150
forwards 63/64 of remaining gas to a sub-call; a caller who meters precisely can starve the
oracle read while leaving the outer frame enough gas to continue, forcing `catch` and marking
the reference stale for the rest of that block. The griefing direction is upward only: the
attacker pays the ceiling fee on the swap that triggers it, and every other swap in the block
that round over-pays rather than under-pays. There is no position from which this is
profitable, so it is accepted rather than mitigated.

## Known limitations

- `captureShareBps` is calibrated conservatively but its underlying elasticity is bounded
  rather than measured. See the Risk page in the app's docs (`frontend/src/components/docs/pages.tsx`,
  the `Risk` component; served at `/docs/risk`).
- The adverse-selection gate does not currently pass: AUC came in at 0.7485 against a 0.75
  floor, on 91 positive examples against a floor of 100, with the weakest walk-forward fold at
  0.469 against a floor of 0.60. The mechanism is correct; the evidence that it improves
  liquidity-provider outcomes is not yet established. Full writeup at the Risk page above.
- **No independent adversarial review has been completed.** Reentrancy through `donate`, and
  cross-swap fee manipulation via the tick recorded in `afterSwap`, have been reasoned about
  and partially mutation-tested but not audited by a third party.
