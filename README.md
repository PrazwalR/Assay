# Assay

A Uniswap v4 hook that prices adverse selection **per swap** rather than per pool — live on
Base Sepolia, source-verified, unaudited.

This document is written for two readers. If you trade, read **[For Traders](#for-traders)**
and skip the Solidity. If you build, **[For Engineers](#for-engineers)** has the mechanism,
the math, the security posture, and how to run it yourself. Everyone should read
**[Status](#status)** first — it is short, and it is the part that matters most.

---

## Status

**Unaudited. Deployed to Base Sepolia only. Has never held real value.** Do not point this at
a network where it would custody funds without an independent security review.

| | |
| --- | --- |
| AssayHook | [`0xc825ad661BA0398eF9Cf809E6635528C9aa370c4`](https://sepolia.basescan.org/address/0xc825ad661BA0398eF9Cf809E6635528C9aa370c4) |
| ChainlinkReferenceAdapter | [`0x56757460c56104aBD30a7783e7Ac0dcE380F0d38`](https://sepolia.basescan.org/address/0x56757460c56104aBD30a7783e7Ac0dcE380F0d38) |
| Pool id (USDC/WETH, inside PoolManager) | `0x1b4f8ca171d62e2acd6c815e4607e9ff771d48a2e540ec7cc12e0e1c984684ee` |
| PoolManager | [`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |
| Swap router | [`0x0DFA8a0e1CaC977015cc7D214380AeB24FE766d5`](https://sepolia.basescan.org/address/0x0DFA8a0e1CaC977015cc7D214380AeB24FE766d5) |
| Liquidity router | [`0x853639EabeEa5a9DacC60D2e568674857F4e6A00`](https://sepolia.basescan.org/address/0x853639EabeEa5a9DacC60D2e568674857F4e6A00) |
| Permission mask | `0x30C4` |

All four contract addresses are source-verified on Basescan — click through and read the
running code yourself rather than trusting this document. The current source compiles to
12,203 bytes of runtime bytecode, reproducing byte-for-byte from this checkout
(`test/fork/LiveBaseSepolia.t.sol` checks this against the live chain, not just at build time).

**The adverse-selection gate does not currently pass.** The pre-declared bar for this project
was that the mechanism demonstrably improves liquidity-provider outcomes, measured against a
classifier trained on real swap data. The gate is a conjunction of five criteria and it fails
on two of them: 91 positive examples against a floor of 100, and the weakest walk-forward fold
at 0.469 against a floor of 0.60. The headline AUC of 0.7485 **clears** its own 0.65 floor
(`calibration/assay_calib/config.py`) — earlier revisions of this file described that floor as
0.75, which was never the configured value. Small sample, not enough evidence either way.

The mechanism is implemented, tested, and running; the claim that it's worth deploying
with real capital is not established, and this document does not make that claim. Full
writeup on the Risk page in the app's docs (`frontend/src/components/docs/pages.tsx`, the
`Risk` component; served at `/docs/risk`).

Two known limitations are accepted rather than fixed, for reasons and with numbers in
[`SECURITY.md`](SECURITY.md): splitting one trade into many slightly reduces the fee charged
(measured at 0.095% of notional), and the toxicity surcharge can be avoided by ending a swap
where liquidity is zero. Both are bounded by the 2% surcharge cap.

---

## For Traders

### What this actually changes about your swap

Every dynamic-fee AMM hook shipping today prices a swap from **volatility** — how much the
pool has been moving lately. That number is the same for everyone in the same block. A
retail trader swapping $50 and a bot capturing a $50,000 arbitrage opportunity, in the same
block, against the same pool, pay the *same rate*. That's backwards: the arbitrage is the
one taking money from liquidity providers; the retail trade is usually just liquidity
providers' actual revenue.

Uniswap v4 lets a hook return a different fee for **each individual swap**, not just each
pool. Assay uses that: it prices a swap on how much of an existing price gap *that specific
swap* closes, in *that specific direction*. Two swaps in the same block, trading opposite
directions against the same gap, get quoted differently — one pays more, one pays less, even
though the pool's volatility is identical for both.

**In practice, if you're not an arbitrageur, this rarely affects you.** Most retail swaps
trade close to the pool's own current price and are quoted near the base fee (0.05%). The
higher fee only bites a trade that is *closing a real, measurable gap* between this pool's
price and a live Chainlink reference — which is exactly the trade an LP would otherwise lose
money on.

### A worked example

Say the pool is trading USDC/WETH near its reference price — a quiet moment, no gap. You
swap $100 of USDC for WETH. The formula (below) evaluates to roughly the base fee:

```
fee = clamp(500 + drift-adjustment, 100, 10,000)   [pips, hundredths of a bip]
drift-adjustment ≈ 0 pips  (pool is at reference, nothing to capture)
fee ≈ 500 pips = 0.05%
```

You pay about **$0.05** on a $100 swap. Ordinary.

Now say a real-world price move happened — WETH moved 2% and this pool hasn't caught up yet.
An arbitrageur's swap, sized to close that entire gap, might see:

```
drift ≈ 950+ ticks captured  ->  drift-adjustment saturates the formula
fee = 10,000 pips = 1.00%  (the ceiling)
```

On a large arbitrage, that ceiling fee plus a capped surcharge (see [The Surcharge](#the-surcharge))
takes back a meaningful share of what the arbitrageur would otherwise have extracted
from liquidity providers — money that, in every other dynamic-fee hook today, the LP simply
loses. You, trading the same pool minutes later at a normal size with no gap to close, are
back to the base fee.

### Is my swap safe?

Three things worth knowing before you connect a wallet:

1. **This has never held real value and is not audited.** It's a testnet deployment for a
   hookathon submission. Treat it as a demo, not a product.
2. **Slippage protection is real.** The frontend computes an actual `sqrtPriceLimitX96` bound
   from your slippage tolerance and sends it on-chain — the router cannot fill you at a worse
   price than you set, full stop.
3. **The worst-case fee is disclosed, not hidden.** Call `feeBounds()` for the LP fee range
   and `surchargeBounds()` for the separate, additional surcharge ceiling — together they are
   the true maximum this hook can take from a swap. See [The Surcharge](#the-surcharge) for
   why these are two different numbers.

### Trying it

Not hosted yet — the contracts above are live, but the frontend isn't deployed publicly as of
this writing. Until it is, run it yourself against the live deployment:

```bash
cd frontend && pnpm install && pnpm dev   # http://localhost:3000, Base Sepolia only
```

Connect, pick USDC or WETH, enter an amount, and the interface shows you the live fee before
you sign anything, computed from the same formula documented below, read from the same chain
state the hook itself reads. Every number on the swap screen that claims to be live is
actually live — see [`frontend/README.md`](frontend/README.md) for exactly what that means
and doesn't mean for the pages that show projected figures instead.

---

## For Engineers

### The mechanism

```
beforeSwap   refresh the reference at most once per block -> signed drift -> fee, clamped
afterSwap    record the tick this swap left behind, and on extreme dislocation
             donate the fee-cap overflow to in-range LPs
```

The fee formula is a no-arbitrage band, not a fitted model. An arbitrageur only profits while
the drift they capture exceeds what they pay to capture it, so charging a *fraction* of that
drift takes back part of the extraction while leaving the trade worth doing for them —
deterring arbitrage entirely would leave the pool stale, which drives away the uninformed
flow that is a liquidity provider's actual revenue.

Flow trading *away* from the reference captures nothing, so its drift is negative and it is
quoted *below* the base fee. That sign — not a lookup table, not a separate code path, one
signed subtraction — is the entire per-swap discrimination. Measured directly in
`test/integration/DynamicPricing.t.sol`: **100 bp against 1 bp**, same block, same pool.

#### The formula, exactly

```solidity
// src/libraries/FeeBlend.sol
signedDrift  = zeroForOne ? poolTick - referenceTick : referenceTick - poolTick
rawFeePips   = baseFeePips + ceil(signedDrift * 100 * captureShareBps / 10_000)
feePips      = clamp(rawFeePips, minFeePips, maxFeePips)
```

- **`poolTick`** — this pool's own current tick (roughly, log-price), tracked by v4 itself.
- **`referenceTick`** — an independent price, read from Chainlink, cached and refreshed at
  most once per block (see [Gas](#gas) for why).
- **`signedDrift`** — how many ticks *this specific swap, in this specific direction* would
  close. One tick is one basis point of price, which is why the `* 100` scales ticks into
  pips directly with no further conversion.
- **`captureShareBps`** — the one calibrated parameter. Deployed at 1,000 (10%): a swap that
  closes 100% of a gap is charged for 10% of it, as a fee on top of the base rate.
- Rounding is toward `+∞` — the protocol's favor, never the trader's — so the quoted fee is
  never *below* what the exact formula computes, only ever rounded up by a fraction of a pip.

Deployed bounds: `baseFeePips = 500` (0.05%), `minFeePips = 100` (0.01%),
`maxFeePips = 10,000` (1.00%), `captureShareBps = 1,000` (10%). At this configuration the
ceiling binds at 950 ticks of captured drift (~10% price move) and the floor at −40 ticks.

#### The surcharge

A percentage-of-notional fee cannot express an arbitrarily large gap — at some point the
*uncapped* formula wants to charge more than `maxFeePips`, and clamping alone would just
silently discard that difference. Instead, `afterSwap` recovers the discarded remainder as a
real token amount and donates it to whichever liquidity is currently in-range, via v4's
`donate()`. This only fires on genuinely extreme dislocations (past 950 ticks at the deployed
config) — an ordinary swap never reaches it.

The surcharge is capped separately from the LP fee, at 2% of the swap's notional
(`FeeBlend.MAX_OVERFLOW_PIPS`). That number used to be 100% of notional — a bound in name
only that no integrator could size slippage against — until this session's audit found it and
fixed it. `surchargeBounds()` exposes the real ceiling; `feeBounds()` alone is not the worst
case a swap can pay. See [`SECURITY.md`](SECURITY.md) for the full reasoning and the two
known-and-accepted gaps this surcharge still has.

#### The reference-deviation cap

The reference could be wrong — a compromised Chainlink aggregator, a misconfigured feed, an
oracle nobody at this project controls. `PoolTwap` maintains an exponentially-weighted
average of the pool's *own* tick, sampled once per block, independent of what the reference
says. A fresh oracle reading that disagrees with that average by more than
`maxReferenceDeviationTicks` (deployed at 20,000 ticks, roughly a 7.4x price ratio) is
rejected outright — treated exactly like a stale reference, never adopted, and
`ReferenceDeviationCapTripped` fires so an operator can tell "the feed went dark" apart from
"the feed answered and this hook does not believe it."

The sample is taken at block-open specifically — the pool's tick as it stood at the end of
the *previous* block — which is what makes the check resistant to being defeated from inside
the same transaction that needs a manipulated reading to look consistent with the pool's
price. `test_Exploit_SameBlockPriceManipulationCannotMoveTheTwapAnchor` proves a same-block
swap that moves the pool's spot tick hard leaves the anchor completely unchanged, and
`test_Regression_TwapDoesNotFoldSameBlockTickWhileOracleIsStuck` proves the same holds even
while the oracle call itself is failing — a real bug this project shipped and then caught in
its own audit pass (see [History](#history)).

#### The halt detector

An L2 sequencer outage freezes the pool's tick and the feed's `updatedAt` at the same
instant, so on resumption both still agree with each other while both disagree with the
world — the drift reads as zero at exactly the moment it is largest. `AssayHook` compares
wall-clock time against block production at each boundary; when they diverge by more than a
generous grace window, the reference is distrusted for a fixed period afterward regardless of
what the feed reports, and `ChainHaltDetected` fires. A quiet pool is not mistaken for a
halt — an untraded hour on Base still advances ~1,800 blocks, an ordinary ratio.

### Architecture

```
src/
  AssayHook.sol                          orchestration; every formula is delegated
  config/AssayConfig.sol                 construction-time parameters + validation
  types/PoolState.sol                    the one packed storage slot (248 of 256 bits)
  libraries/Mispricing.sol               signed drift, in ticks
  libraries/FeeBlend.sol                 drift -> fee, and the fee-cap overflow
  libraries/ToxicitySurcharge.sol        overflow -> real token amount
  libraries/PoolTwap.sol                 the pool's own smoothed tick, and the deviation cap
  libraries/Q32x32.sol                   fixed-point (Q32.32) primitives
  oracle/ChainlinkReferenceAdapter.sol   a Chainlink feed, presented as a v4 sqrt price
  interfaces/                            IAssayErrors, IAssayEvents, IReferencePriceOracle
script/                                  Foundry deploy scripts (oracle, hook, pool + seed)
test/
  unit/                                  one file per library, pure-function edge cases
  integration/                           real PoolManager, real swaps, real state machine
  invariant/                             stateful fuzzing across arbitrary call sequences
  exploit/                               adversarial scenarios with a name and a number
  fork/                                  against the live deployment above, not a local copy
  gas/                                   the three budgeted paths, measured and asserted
calibration/                             the Python pipeline that measures whether any of
                                          this actually works — the P0 gate lives here
frontend/                                Next.js app; see frontend/README.md
audits/                                  the 8-checklist parallel audit pass, in full
```

Every formula lives in a pure library. `AssayHook.sol` reads state, delegates, writes state,
and returns values — the only arithmetic in the hook itself is the `|` that sets v4's
fee-override flag and the block-boundary comparisons that gate a refresh. That separation is
what makes the math independently fuzzable without a `PoolManager`, and it is why the same
`FeeBlend`/`Mispricing` port runs three times in this repo — Solidity, TypeScript
(`frontend/src/lib/protocol/feeBlend.ts`), and Python (`calibration/`) — all three pinned
against one shared fixture, `test/fixtures/fee_blend.json`, so a future change to one that
isn't mirrored in the others fails a test instead of silently mispricing a display.

Realised variance and order-flow imbalance were previously maintained on the swap path and
have been removed entirely: calibration measured their incremental value over the reference
signal alone at −0.008 and −0.002 across two independent windows — they were billing every
swap to make the classifier no better. Recoverable from git history if a milestone can show
they earn their cost.

### Security

The full model — what's analyzed and found safe, what's accepted and why, what's genuinely
open — lives in [`SECURITY.md`](SECURITY.md); this is the shape of it, not a substitute for
reading it.

**No custody, no admin key, no upgrade path, anywhere.** `_beforeSwap` always returns a zero
delta — the hook never takes custody of swap principal, the highest-severity finding class in
v4 hook audits generally. Every piece of state besides `_poolState` is `private immutable`,
set once in the constructor. There is no owner, no pauser, no proxy. That is a deliberate
trade: it eliminates a compromised-admin-key failure mode entirely, at the cost of no lever to
pull if a deeper flaw is found later — a liquidity provider is their own circuit breaker, and
they can always withdraw regardless of hook state (no liquidity-related hook permissions are
set at all).

**This has been through three audit passes.** Two general-purpose ETHSKILLS passes
(`docs/audit/`), and one 8-checklist parallel pass (`audits/Assay-2026-08-31/`) covering
general correctness, precision math, AMM-specific patterns, oracle security, chain-specific
quirks, access control, denial-of-service, and flash-loan attack vectors — eight independent
specialist reviews synthesized into one report. All three passes were agent-driven; no
third-party human review has been done.

That pass found the most consequential bug in this project's history (below), plus five others.
Five of the six are fixed with a regression test each in `test/integration/AuditFixes.t.sol`.
**One remains open:** the JIT-liquidity tick-manipulation finding (H-2). The reference-deviation
cap gates which oracle readings are *adopted*; it does not bound the live `lastTick` the fee
formula actually consumes, and `Mispricing.MAX_MISPRICING_TICKS` (200,000) is ten times looser
than the deviation cap (20,000). No regression test covers it.

### History

The audit's headline finding, because it changed the actual behavior of the deployed
contract: **the fee mechanism was inverted for the swap that mattered most.** The reference
used to refresh in `afterSwap`, so a swap was quoted against whatever the *previous* swap had
left cached. The arbitrageur reacting first to a real oracle move — the trade that actually
captures the entire dislocation — was quoted against the stale pre-move reference, and priced
accordingly. Measured on a 20% oracle move, before the fix: the first reactor paid **490
pips — below the 500 base fee**, a discount, for capturing the whole gap; the swap arriving
after them paid the 10,000-pip ceiling for a gap that had already been taken. Fixed by moving
the reference refresh into `beforeSwap`; see `test/exploit/ReferenceLag.t.sol` for the
numbers before and after, and the commit history for the full account, including a regression
the fix itself introduced and a second pass caught before it shipped
(`test_Regression_TwapDoesNotFoldSameBlockTickWhileOracleIsStuck`).

One clarification, because an earlier revision of this file got it wrong: **the failing P0 gate
is not measuring this bug, and re-running it would not change the numbers.** The calibration
pipeline reads historical Uniswap v3 swaps on Ethereum mainnet against Binance candles — it
never loads this hook, this pool, or this chain. It answers the prior question of whether
adverse selection is predictable per swap at all. What actually blocks the gate is the
labelling: a 30-second markout is partly tautological with the mispricing feature by
construction, so a longer horizon or a drift-netting label is the work, not a re-run.

### Gas

Three reachable paths, each budgeted and measured separately in
`test/gas/HookOverhead.t.sol` — a single number only ever described the cheapest one.

| path | measured | budget | headroom |
| --- | --- | --- | --- |
| ordinary swap | 16,180 | 20,000 | 19% |
| block boundary, mock feed | 36,349 | — | — |
| **block boundary, live feed** | **52,849** | 55,000 | 4% |
| extreme dislocation (surcharge) | 28,617 | 55,000 | 48% |

A live Chainlink read measures ~20,774 gas against the deployed Base Sepolia aggregator,
which is why the reference is cached and refreshed at most once per block rather than read on
every swap — and why the ordinary-swap and block-boundary paths are budgeted and watched
separately at all. Full detail, including why the boundary headroom dropped from 8% to 4%
when the reference-refresh fix above landed, in [`docs/gas.md`](docs/gas.md).

### Tests

```bash
forge test                                    193 tests, 26 suites
forge test --match-path "test/invariant/*"    7 stateful properties, 8,192 calls each
forge test --match-path "test/fork/*"         3 tests against the live deployment above
```

Unit and integration tests assert what happens in orderings someone thought to write down.
The invariant suite fuzzes the *ordering itself* — swaps, liquidity changes, block advances,
and reference price events in any sequence — and asserts properties that must hold after all
of them: every quoted fee stays inside the bounds `feeBounds()`/`surchargeBounds()` advertise,
the hook never accumulates a token balance, no delta is left unsettled, liquidity can always
be withdrawn. It runs with `fail_on_revert = true`, so a revert anywhere in a sequence aborts
the run rather than being silently absorbed — most of the real bugs found in this project came
from state interactions across calls, which is exactly what this reaches and a fixed test
sequence does not.

The fork suite is the strongest check available and the only one that runs against the
literal bytecode above rather than a fresh local compile: it predicts a swap's fee from the
same pure library the hook calls, reading real on-chain state, then executes an actual swap
through the real deployed router and asserts the real `SwapAssayed` event matches the
prediction exactly. It requires network access and is excluded from the default `forge test`
run and from CI's blocking path for that reason — see the comments in
`.github/workflows/ci.yml`.

### Build

```bash
forge build && forge test
cd calibration && uv venv .venv \
  && uv pip install --python .venv/bin/python -r requirements.lock \
  && .venv/bin/python -m pytest tests/ -q
cd frontend && pnpm install && pnpm test && pnpm typecheck && pnpm build
```

### Deploying

Needs `.env` (copy `.env.example`; never commit the filled-in version — it holds a private
key). Deploy the oracle first, then the hook, then create and seed the pool:

```bash
forge script script/DeployOracle.s.sol:DeployOracle \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY --broadcast
# set ASSAY_REFERENCE_ORACLE in .env to the address it prints, then:
forge script script/DeployAssay.s.sol:DeployAssay \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY --broadcast
# set ASSAY_HOOK in .env to the address it prints (this is a mined CREATE2 address,
# not the next nonce -- it changes whenever the compiled bytecode does), then:
forge script script/SetupPool.s.sol \
  --rpc-url base_sepolia --private-key $DEPLOYER_PRIVATE_KEY --broadcast
```

Then verify all four contracts (`forge verify-contract`, one per deployed address — the two
routers are v4-core reference implementations and Basescan may recognize them as already
verified from a prior deployment's identical bytecode), update
`frontend/src/lib/protocol/config.ts` and `test/fork/LiveBaseSepolia.t.sol` to the new
addresses, and run the fork suite against the new deployment before calling it done — a
passing `forge test --match-path "test/fork/*"` is the actual evidence the deployment matches
the source, not the broadcast succeeding.

### Contributing

Read [`SECURITY.md`](SECURITY.md) and `audits/Assay-2026-08-31/AUDIT-REPORT.md` before
touching `src/`. If you find something, a Foundry test reproducing it is worth more than a
description of it — see `test/exploit/` for the house style.

---

## Licence

MIT — see [`LICENSE`](LICENSE).
