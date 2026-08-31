# ASSAY — Auditor Context

**Read this file completely before analysing any code in this repository.**

This is the authoritative description of what this system is, what it is deliberately *not*,
and which properties matter. Findings that contradict a documented design decision in §6
without new reasoning will be rejected. Findings that ignore the v4 constraints in §4 will be
rejected.

---

## 0. IMPLEMENTATION STATUS — read this before §3, §5, §7 and §8

Sections 1–10 below describe the **full design**. A substantial part of it is not built. An
audit that reports findings against unbuilt components produces confident nonsense, so this
section is authoritative over the rest of the document wherever they disagree.

### Contracts that exist

| Path | Status |
|---|---|
| `src/AssayHook.sol` | built |
| `src/libraries/FeeBlend.sol` | built — quote and fee-cap overflow |
| `src/libraries/Mispricing.sol` | built — signed drift in ticks (not in §3's table) |
| `src/libraries/ToxicitySurcharge.sol` | built — overflow to token amount (not in §3's table) |
| `src/libraries/Q32x32.sol` | built — fixed point |
| `src/libraries/VarianceEwma.sol` | built, **but not called by the hook** |
| `src/libraries/OrderFlowImbalance.sol` | built, **but not called by the hook** |
| `src/libraries/PoolTwap.sol` | built and called by the hook — reference deviation cap |
| `src/oracle/ChainlinkReferenceAdapter.sol` | built |
| `src/config/AssayConfig.sol` | built |
| `src/types/PoolState.sol` | built |

### Contracts that DO NOT EXIST

`src/libraries/FeatureExtractor.sol`, `src/libraries/ToxicityScore.sol`,
`src/libraries/FeeCurve.sol`, `src/model/Coefficients.sol`, `src/rebate/RebateLedger.sol`,
`src/rebate/RouterAttestation.sol`.

**Do not report findings about them.** There is no rebate ledger, no ERC-6909 accounting, no
EIP-712 attestation, no logistic classifier on chain, and no `f*(v)` lookup table.

### What the hook actually does today

`beforeSwap` reads one packed storage slot, computes the signed tick distance between the
pool and a **cached** reference price, scales it by `captureShareBps`, clamps to
`[minFeePips, maxFeePips]`, and returns it with the v4 override flag. `afterSwap` advances
the cached tick, refreshes the reference at most once per block, and — only when the uncapped
formula exceeds `maxFeePips` — takes the excess via `poolManager.donate()` and returns it as
a positive `int128`.

A reference the oracle reports as fresh is checked a second time before being adopted: against
`PoolTwap`, an EWMA of the pool's own tick sampled once per block (never per swap, so a
same-block price walk cannot move it). A reading that disagrees with that average by more than
`maxReferenceDeviationTicks` is forced stale instead, and `ReferenceDeviationCapTripped` fires.
See `SECURITY.md` under "Reference deviation cap" for the full reasoning and residual limits.

There is no posterior probability, no six-feature vector, and no `sigmoid`. Calibration
measured the incremental value of the microstructure features over the reference signal alone
at **−0.008 and −0.002** across two independent windows, so they were removed from the swap
path rather than left to bill every swap for nothing. The libraries remain in the tree, pure
and tested, for a milestone that can show they earn their cost.

### Invariants from §5 that are consequently not applicable

- **3** (rebate ledger solvency) — no ledger exists.
- **7** (`pi` constant implies `f*(v)`) — there is no `pi` and no `f*(v)` curve.
- **10** (attestation single-use) — no attestations exist.
- **6** (variance manipulation-bounded) — variance is no longer computed on the swap path.
  The library retains its clamp and per-block-sampling design and its tests.

Invariants **1, 2, 4, 5, 8, 9** are live and are the ones that matter.

### Priority areas from §8, corrected

1. `beforeSwap` revert-freedom across the entire input and state space — **still the top item**
2. Fixed-point bounds in `Q32x32`, `FeeBlend`, `Mispricing`, `ToxicitySurcharge` at extremes
3. Delta settlement in `afterSwap`, specifically the `donate` + returned-delta pairing
4. Oracle adapter staleness and degradation
5. Multi-pool state isolation
6. ~~RebateLedger solvency~~ — not built
7. ~~RouterAttestation replay~~ — not built

### Known gaps, stated so silence is not mistaken for coverage

- **The reference deviation cap is reasoned, not calibrated.** §7 attack 6's mitigation is now
  implemented (`PoolTwap`, wired into `_advanceStateInPlace`), but its default bound (20,000
  ticks) comes from tick-space reasoning about the gap between real volatility and
  order-of-magnitude feed errors, not from fitted feed-failure data. It catches gross errors,
  not a subtly wrong value inside the tolerance. See `SECURITY.md`.
- **No pool allowlist in `beforeInitialize`.** §4 constraint 6 describes one. What exists
  instead is a currency-pair binding: the hook refuses any pool whose currencies do not match
  the pair its oracle declares.
- **The adverse-selection gate does not pass.** AUC 0.7485 against a 0.75 floor, 91 positive
  examples against a floor of 100, weakest walk-forward fold 0.469 against a floor of 0.60. See
  the Risk page in the app's docs (`frontend/src/components/docs/pages.tsx`, the `Risk`
  component; served at `/docs/risk`). The mechanism is implemented and deployed; the evidence
  that it improves LP outcomes is not established.

---

## 1. What this is, in one paragraph

Assay is a Uniswap v4 hook that prices adverse selection **per swap** rather than per pool.
Inside `beforeSwap` it computes a posterior probability that the incoming order is informed,
from six on-chain microstructure signals; it sets the LP fee from the growth-optimal closed
form of the LVR no-arbitrage-band model, scaled by that posterior; and it skims a surcharge
from flow scored as toxic into a ledger that pays rebates to routers delivering flow scored
as benign.

It is a **pricing mechanism, not an access-control mechanism**. It never blocks, never
censors, and never takes custody of swap principal.

> *Status note: as of §0, the posterior, the six signals and the rebate ledger are not built.
> The hook prices from the signed mispricing alone.*

---

## 2. The economics, so findings are grounded

An AMM liquidity provider makes a standing offer at a price that only updates when someone
trades against it. When the external market moves, the pool is stale, and an arbitrageur
takes the difference. This is loss-versus-rebalancing (LVR). For a constant-product pool it
accrues at

```
LVR rate = (sigma^2 / 8) * V        [Milionis, Moallemi, Roughgarden, Zhang, arXiv:2208.06046]
```

independent of the fee in the frictionless limit. A proportional fee `f` does not reduce LVR;
it creates a no-arbitrage band so arbitrageurs only trade when mispricing exceeds `f`, which
reduces how often the loss is realised:

```
A(f, v) = (v/8) * 1 / (1 + sqrt(2*lambda_block/v) * f)      [arXiv:2305.14604]
```

With fee-elastic uninformed turnover `nu(f) = nu0 * exp(-alpha*f)`, LP drift relative to the
rebalancing benchmark is

```
m(f, v) = f * nu0 * exp(-alpha*f)  -  A(f, v)
f*(v)   = argmax over f in [f_min, f_max]                    [arXiv:2606.21769]
```

`f*(v)` is increasing in variance and independent of LP wealth and risk aversion.

**The gap Assay closes.** `m(f, v)` conditions on `v`, a property of the market, not of the
counterparty. Under perfect classification the problem decouples: charge `1/alpha` to benign
flow and push toward `f_max` on informed flow. `f*(v)` is the compromise forced by an
inability to distinguish them.

> *Status note: the shipped mechanism is the no-arbitrage band directly — the fee is a share
> of the drift a swap captures. `f*(v)` is not implemented because `nu0`, `alpha` and
> `lambda_block` have never been estimated from data, and inventing them would be worse than
> shipping a mechanism whose single parameter is honest.*

---

## 4. Uniswap v4 constraints that shape the code

Findings that ignore these are wrong, not insightful.

1. **Hook permissions live in the last 14 bits of the deployed address**, not in
   `getHookPermissions()`. The address is CREATE2-mined. Declaring a flag without
   implementing the callback bricks the pool; implementing a callback whose flag is absent
   means it is silently never called. Flags in use: `BEFORE_INITIALIZE`, `AFTER_INITIALIZE`,
   `BEFORE_SWAP`, `AFTER_SWAP`, `AFTER_SWAP_RETURNS_DELTA` — mask `0x30C4`. Any additional
   flag is a finding.
2. **Dynamic fee handshake.** Pool must be initialised with
   `key.fee == LPFeeLibrary.DYNAMIC_FEE_FLAG (0x800000)`. Per-swap override returns
   `fee | LPFeeLibrary.OVERRIDE_FEE_FLAG (0x400000)` as the third return value of
   `beforeSwap`. Fee units are hundredths of a bip; `MAX_LP_FEE = 1_000_000`.
3. **`sender` in `beforeSwap` is the router, not the trader.** It is never a user identity.
   Any logic that treats it as one is a critical finding.
4. **The zero-hookData path must work.** If a swap cannot execute without custom `hookData`,
   aggregators cannot route to the pool.
5. **Hook deltas must settle.** Any nonzero delta must settle before `unlock()` returns or
   the transaction reverts with `CurrencyNotSettled`. `afterSwap` may only return a delta on
   the **unspecified** token.
6. **One hook serves many pools.** All state is keyed by `PoolId`. Any cross-pool aggregate
   state is a critical finding.
7. **Everything in the callbacks is on the swap hot path.** Budgets and measurements are in
   `docs/gas.md`. Three paths are budgeted separately because a single number described only
   the cheapest.
8. **`onlyPoolManager` on every callback.**

---

## 5. Invariants — these are the properties that matter

Ranked by consequence. See §0 for which are applicable.

1. **`beforeSwap` never reverts for any well-formed swap**, in any pool state, including
   uninitialised oracle, stale oracle, zero liquidity, extreme ticks. A revert here bricks
   the pool. The one permitted revert path is `beforeInitialize` rejecting a
   non-dynamic-fee pool or one whose currencies do not match the oracle's declared pair —
   which happens at pool creation, not at swap time.
2. **`f_min <= quotedFee <= f_max <= MAX_LP_FEE`** for all inputs.
3. *(not applicable — no rebate ledger)*
4. **All hook deltas settle; `NonzeroDeltaCount` reaches zero.**
5. **No cross-pool state contamination.**
6. *(not applicable on the swap path — variance is no longer computed there)*
7. *(not applicable — no posterior)*
8. **Rounding is directional and consistent, always in the LP's favour.**
9. **LP liquidity is never trapped.** There is no hook on add or remove liquidity,
   structurally.
10. *(not applicable — no attestations)*

---

## 6. Deliberate design decisions — do not report these as findings

| Decision | Rationale |
|---|---|
| Never reverts on toxic flow | A hook that censors is a hook nobody integrates, and blocking arbitrage entirely leaves the pool stale, degrading execution for everyone. Assay prices; it does not block. |
| No async / no-op swap, no custody of principal | Custody is the highest-severity finding class in v4 hook audits. Accepted cost: flow cannot be internalised. |
| Stale oracle degrades to `f_max`, does not revert | See invariant 1. Failing closed on a swap path is worse than quoting conservatively. |
| Configuration is immutable, no governance | An updatable parameter set is an admin key over every swap price in the pool. Recalibration means deploying a new hook. |
| Fee is quoted from a quantity the trader must pay to fake | Spoofing resistance is economic. Trading away from the reference to get the low fee means forgoing the drift. |
| No admin pause, no upgradeability | Deliberate. The hook is immutable once deployed. |
| Variance and order-flow imbalance removed from the swap path | Measured incremental value of −0.008 and −0.002 over the reference signal alone. Keeping them would bill every swap for a computation that made the quote no better. |
| Surcharge donated pro-rata rather than escrowed | An escrow needs an owner and a withdrawal path. `donate` routes value straight to in-range LPs with no custody and no admin. |

---

## 7. Threat model — attacks already anticipated

Report **new** attacks, or demonstrate that a listed mitigation is insufficient — with the
test that breaks it. Regression tests live under `test/exploit/`.

| # | Attack | Mitigation | Test |
|---|---|---|---|
| 1 | Intra-block variance inflation | Per-block sampling, tick-delta clamp | library retains it; not on swap path |
| 2 | Attaching the hook to a foreign pool | Currency-pair binding in `beforeInitialize`, both halves covered | `UnboundPool.t.sol` |
| 3 | Unsettled delta bricking every swap | `donate` + returned positive delta net to zero | `ToxicitySurchargeFlow.t.sol` |
| 4 | Surcharge donation with zero in-range liquidity | `Pool.donate` reverts there; guarded and skipped | `ToxicitySurchargeFlow.t.sol` |
| 5 | Self-dealing: attacker is the sole in-range LP and recovers their own surcharge | Net cost `(1-s)*S`; at `s=1` there is no other LP to extract from, so it degrades to neutral rather than exploitable | analysed in `SECURITY.md` |
| 6 | Oracle manipulation of the mispricing signal | Staleness bound, degrade to `f_max`. Deviation cap against `PoolTwap` — see §0. | `HostileOracle.t.sol`, `ReferenceDeviationCap.t.sol` |
| 7 | Arithmetic overflow at type extremes | Written bounds proofs, fuzz at extremes | `Q32x32.t.sol`, `Estimators.t.sol` |

Prior context worth knowing: Bunni, then the largest LP-optimisation hook on v4, was
exploited for roughly $8.4M in September 2025 through a rounding flaw in liquidity
distribution logic, despite audits. Rounding deserves disproportionate attention.

---

## 9. Out of scope

- The economic *correctness* of the fee model. Audit whether the code computes what §2 and
  §0 specify.
- The off-chain calibration pipeline's statistical validity. Audit it for supply-chain and
  reproducibility risk only.
- Anything under `test/`, except that mocks must not be reachable from `src/`.
- Frontend. There isn't one.

---

## 10. References

- LVR: https://arxiv.org/abs/2208.06046
- LVR with fees, no-arbitrage band: https://arxiv.org/abs/2305.14604
- Optimal dynamic fee, closed form: https://arxiv.org/abs/2606.21769
- v4-core: https://github.com/Uniswap/v4-core
