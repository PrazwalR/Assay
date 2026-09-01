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
or a misconfiguration on a chain this hook has no independent view of. `_advanceReferenceInPlace`
checks a fresh reading a second time against `PoolTwap`, an exponentially weighted average of
the pool's own tick that is sampled once per block rather than once per swap. A reading
that disagrees with that average by more than `maxReferenceDeviationTicks` is treated exactly
like a stale one: `referenceFresh` is forced false, the rejected value is never adopted, and
`ReferenceDeviationCapTripped` fires so an operator can tell "the feed went dark" apart from
"the feed answered, but this hook does not believe it."

Sampling the *block-open* tick specifically -- the pool's tick as of the end of the previous
block, captured before the current block's own swaps can touch it -- is what makes the check
resistant to being defeated from inside the same transaction that needs a bad reading to look
consistent with the pool's price. `test_Exploit_SameBlockPriceManipulationCannotMoveTheTwapAnchor`
proves a same-block swap that moves the pool's spot tick hard leaves the anchor completely
unchanged. The sample is gated on its own block tracker, separate from the oracle refresh, so
an oracle that keeps failing cannot re-open the fold mid-block and walk the anchor with a tick
the current block set — `test_Regression_TwapDoesNotFoldSameBlockTickWhileOracleIsStuck`.

**Residual limitation, stated rather than left implicit:** the default cap (20,000 ticks,
which is a price ratio of ~7.4x, not the ~2.7x an earlier version of this note claimed) is reasoned from tick-space bounds -- the gap between plausible real-market volatility
and the order-of-magnitude errors a decimals mistake or compromised feed produces -- not
calibrated against real feed-failure data. It catches gross errors, not a subtly wrong value
that happens to sit inside the tolerance. See `.env`'s own comment on
`ASSAY_MAX_REFERENCE_DEVIATION_TICKS` for the full reasoning, including the specific numbers
that gap is built from.

## Oracle: gaps analysed and accepted, not fixed

Three items from an external checklist-driven review of `ChainlinkReferenceAdapter` and its
read path. Recorded here as explicit decisions rather than left as unexamined omissions.

**No L2 sequencer uptime feed.** The hook deploys to Base, an OP-stack L2, where the usual
mitigation is reading Chainlink's sequencer uptime feed and enforcing a grace period after a
restart. This adapter does not.

An earlier version of this document argued the omission was safe because a down sequencer
stops the aggregator updating, so the staleness check fires and the pool over-charges. That
reasoning only holds once the outage exceeds `MAX_AGE_SECONDS`. A shorter outage — the
common case — freezes the pool's tick and the feed's `updatedAt` at the same instant, so on
resumption the two still agree with each other while both disagree with the world, and the
drift reads as zero at exactly the moment it is largest. That is under-charging, not
over-charging, and it was wrong.

The hook now detects the condition directly, without a second external call: wall clock and
block production should advance together, and a halt is the one shape where they do not.
When that is observed the reference is distrusted for a fixed window, `ChainHaltDetected`
fires, and quotes hold at the ceiling until the feed can post a reading from after the halt.
A quiet pool is explicitly not misread as a halt — an untraded hour still advances ~1,800
Base blocks. This is narrower than reading the uptime feed and does not replace it.

**Aggregator min/max circuit breakers are not checked.** When a feed's true price moves
outside its configured `[minAnswer, maxAnswer]`, some aggregators report the bound instead of
reverting, and this adapter would accept that as a fresh, correct reading. On the feed this is
deployed against, both bounds are non-binding `int192` sentinel defaults — `minAnswer = 1`
(~$1e-8), `maxAnswer` near `9.6e44` — orders of magnitude outside any price ETH could reach.
Not exploitable against this feed. If this adapter is ever pointed at a different aggregator,
its min/max bounds should be checked before assuming this analysis still holds.

**The oracle `try/catch` can be forced into its catch branch by gas metering.** EIP-150
forwards 63/64 of remaining gas to a sub-call, so a caller who meters precisely can starve
the oracle read and force `catch`. Two things now bound this. Both external calls on the read
path carry explicit gas stipends, so a callee that burns gas rather than reverting cannot
take the swapper's whole budget and strand the rest of the swap. And a call that failed
outright no longer retires the block's refresh — the next swap retries on its own gas — so
one metered dust swap per block can no longer hold the pool at the ceiling while the feed is
healthy. The residual is that the swap doing the metering pays the ceiling itself, which is
the safe direction and is not a position anyone profits from.

## Known limitations

- **Splitting one trade into many reduces the drift charge.** The fee is quoted from the
  drift remaining at each swap, and every swap records the tick it left behind, so piece *i*
  of a split trade is priced against a drift piece *i-1* already closed. Measured at 20
  pieces against one equivalent swap: the splitter keeps an extra 0.095% of notional. Fixing
  it means quoting every swap in a block against one block-open tick, which needs an `int24`
  the packed pool state has no room for (248 of 256 bits used) — a second slot would cost
  ~2,900 gas on a boundary path already at 4% headroom. Accepted and measured rather than
  half-fixed; `test/exploit/SplitSwap.t.sol` pins the number so a regression is visible.
- **The toxicity surcharge can be avoided by ending a swap where liquidity is zero.**
  `_donateCeilingOverflow` skips the donation when `getLiquidity` at the post-swap tick is
  zero, because `donate` would revert — but the swapper chooses that tick via
  `sqrtPriceLimitX96`. Landing in a gap between positions, or just outside a band the swap
  consumed, waives the surcharge. Fully consuming a band is the natural shape of a large
  arbitrage, so this fires without the attacker trying. The surcharge is capped at 2% of
  notional, which bounds what is avoided, but it is genuinely avoidable.
- **The reference is only as fresh as the last swap.** It is refreshed once per block, in
  `beforeSwap`, so a pool nobody trades holds whatever tick its last swap cached. The
  adapter's own staleness bound governs the read, not the age of the cache. The first swap
  after a quiet period does refresh before quoting, so it is charged correctly — but
  `poolState().referenceFresh` read between swaps can describe an arbitrarily old reading.
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
