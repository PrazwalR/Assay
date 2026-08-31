# ETHSKILLS Audit — Assay v4 Hook

**Methodology:** `evm-audit-master` routing table. Checklists loaded: `evm-audit-defi-amm`
(Uniswap v4 hook items), `evm-audit-precision-math`. Severity per the master definitions.

**Scope:** `src/`. Context read first: `docs/ASSAY-CONTEXT.md`, whose §0 is authoritative —
six contracts the rest of that document describes do not exist and were not audited.

**Commit:** `321f827` plus uncommitted invariant suite. 158 tests passing, 0 compiler
warnings, slither clean, 100% coverage on `src/`.

---

## Summary

| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 0 |
| Low | 2 |
| Informational | 1 |

No exploit path was found that bricks the pool, loses funds, or lets an attacker reliably
profit. Two Low findings concern rounding direction contradicting a documented invariant.
One coverage gap on a Critical-consequence path was found and closed during the audit; it
was a gap in testing, not a defect in the code.

---

## [L-1] Surcharge rounding is LP-adverse for capture shares that are not multiples of 100

**Severity:** Low
**Category:** evm-audit-precision-math (items 1, 4, 5 — rounding must favour the protocol)
**Location:** `src/libraries/FeeBlend.sol:55`

```solidity
int256 surcharge = (drift * PIPS_PER_TICK * int256(uint256(captureShareBps))) / BPS_DENOMINATOR;
```

**Description.** Solidity signed division truncates toward zero. `drift` is positive exactly
when the swap is *capturing* the pool's drift — the toxic side — so truncation there lowers
the quoted fee. On the benign side (`drift < 0`) truncation toward zero raises it. Both move
value from the liquidity provider to the trader relative to exact arithmetic.

This contradicts invariant §5.8 of the context file: *"Rounding is directional and
consistent, always in the LP's favour."*

**Measured.** Sweeping `drift` over ±200:

| `captureShareBps` | result |
|---|---|
| **1000 (deployed)** | exact for all drift — `100 * 1000 / 10000 = 10` |
| 2500, 7500 | exact |
| 555 | truncates on 190 toxic-side and 190 benign-side values |
| 3333 | truncates on 198 of each |

**Proof of Concept.** With `captureShareBps = 3333` and `drift = 7` ticks, exact surcharge is
`7 * 100 * 3333 / 10000 = 233.31` pips; the contract computes `233`. The swap capturing that
drift is charged 0.31 pips less than the formula specifies. Repeating across every
drift-capturing swap transfers that difference to arbitrageurs.

**Why this is Low, not higher.** The deployed parameter makes the division exact, so no value
is currently leaking. The error is bounded at one pip (1e-6 of notional) and there is no
loop: extraction requires genuine swaps whose gas cost exceeds the saving at any realistic
size. This is a latent defect that activates on a configuration change, not a live one.

**Recommendation.** Round the fee away from zero on the capturing side, so the error is always
in the LP's favour:

```solidity
int256 numerator = drift * PIPS_PER_TICK * int256(uint256(captureShareBps));
// Round the fee up on the capturing side, down on the other: both favour the LP.
int256 surcharge = numerator >= 0
    ? (numerator + BPS_DENOMINATOR - 1) / BPS_DENOMINATOR
    : numerator / BPS_DENOMINATOR;
```

Alternatively constrain `captureShareBps` to multiples of 100 in `AssayConfigLib.validate`,
which makes the division exact by construction — cheaper on the hot path, at the cost of
parameter granularity.

---

## [L-2] Surcharge amount rounds down, favouring the swapper

**Severity:** Low
**Category:** evm-audit-precision-math (item 5 — rounding leaks value to traders)
**Location:** `src/libraries/ToxicitySurcharge.sol:58`

```solidity
return FullMath.mulDiv(notional, overflowPips, FeeBlend.MAX_OVERFLOW_PIPS);
```

**Description.** `FullMath.mulDiv` rounds down. The surcharge is the amount taken from the
swapper and donated to in-range liquidity providers, so rounding down under-collects. Same
invariant §5.8 violation as L-1, in the opposite library.

**Proof of Concept.** A swap with unspecified-side notional of 999 wei and
`overflowPips = 500_000` (50%) yields an exact surcharge of 499.5 wei; the contract donates
499. The half-wei remains with the swapper. `test_DustSwap_OwesASurchargeThatRoundsToNothing`
already documents the extreme of this, where the surcharge rounds to zero entirely.

**Why this is Low.** Bounded at one wei per swap, on a path that only fires during extreme
dislocation. Not extractable — the swapper cannot choose to sit on the boundary, and the
surcharge path costs far more gas than one wei of any token is worth.

**Recommendation.** `FullMath.mulDivRoundingUp` is already available through the same import.
The surcharge is a fee, and the checklist's rule for fees is to round up.

---

## [I-1] Coverage gap closed during the audit: surcharge on exact-output swaps

**Severity:** Informational (was a gap in tests, not a defect)
**Category:** evm-audit-defi-amm (items 5, 15 — delta settlement, all four swap combinations)
**Location:** `src/libraries/ToxicitySurcharge.sol:32`, `test/integration/ToxicitySurchargeFlow.t.sol`

**Description.** `unspecifiedAmount` branches on `amountSpecified < 0 == params.zeroForOne`,
so exact-output swaps select the opposite currency to exact-input. All four combinations were
covered at the unit level, but every integration test that actually reached `donate()` used
exact-input. The exact-output branch of the live donation path had never executed.

Had the currency selection been wrong there, the hook would donate one currency while
returning a delta denominated in the other, leaving the delta unsettled and reverting the
transaction — a swap-path revert, the highest-severity failure class in this system.

**Resolution.** Added `test_ExactOutputSwap_SurchargesWithoutStrandingADelta` and
`test_ExactOutputOppositeDirection_SurchargesWithoutStrandingADelta`, asserting the donation
fires, reaches fee growth, leaves `getNonzeroDeltaCount() == 0`, and leaves the hook holding
no balance. **Both pass** — the currency selection is correct on all four combinations. The
defect was in coverage, not in the contract.

---

## Verified clean

Each checked against code, not assumed.

**`evm-audit-defi-amm`**

| # | Item | Result |
|---|---|---|
| 1 | Permission bits mined into the address | Mask `0x30C4`, asserted in `AssayHookPermissions.t.sol` against `getHookPermissions`, and every unused flag asserted false |
| 2 | `beforeSwap` return types | `(bytes4, BeforeSwapDelta, uint24)` — correct |
| 3 | `BeforeSwapDelta` sign confusion | Not applicable: returns `ZERO_DELTA`, never takes principal |
| 4 | Delta ordering depends on `zeroForOne` | Handled in `ToxicitySurcharge.unspecifiedAmount`; all four combinations tested (see I-1) |
| 5 | Unsettled deltas revert `unlock()` | `donate` debits the hook, the returned positive `int128` credits it back; net zero. Asserted by `invariant_NoUnsettledDeltas` over 8,192 calls |
| 6 | Async hooks steal custody | Not applicable — no async path, no custody |
| 7 | Hook attached to an attacker's pool | `beforeInitialize` refuses any pool whose currencies differ from the oracle's declared pair. Both halves of the check individually tested |
| 8 | Upgradeable hooks cannot gain permissions | Not applicable — immutable, no proxy |
| 9 | Missing `onlyPoolManager` | `BaseHook`'s external wrappers carry the modifier; the hook only overrides internal `_`-prefixed functions |
| 10 | Dynamic fee manipulation via front-running | Analysed below |
| 11 | Unbounded loops | None. No array iteration anywhere in `src/` |
| 12 | `lpFeeOverride` DoS | `maxFeePips <= MAX_LP_FEE` enforced at construction; `FeeBlend.quote` clamps to it. `invariant_QuotedFeeAlwaysWithinAdvertisedBounds` confirms over 8,192 calls, and removing the ceiling makes it fail with v4's `LPFeeTooLarge` |
| 13 | `unlockCallback` arbitrary calls | Not applicable — the hook implements no `unlockCallback` |
| 14 | JIT liquidity on hook-managed positions | Analysed below |
| 15 | All four swap combinations | See I-1 |

**`evm-audit-precision-math`** — items 17 (downcast), 18 (negative-to-unsigned), 20/31
(unchecked blocks), 24 (off-by-one at boundaries) all checked. Every cast in `src/` carries a
written bound proof; every `unchecked` block states the invariant making it safe. Item 18 in
particular is handled correctly: `ToxicitySurcharge` uses two's-complement negation
(`~x + 1`) rather than unary minus, which would overflow on `type(int128).min`.

---

## Analysed, not exploitable

**Cross-swap fee manipulation (checklist item 10).** `state.lastTick` is written from the
post-swap tick in `afterSwap`, so swap N prices swap N+1. To lower the fee on a
drift-capturing swap, an attacker must first move the pool toward the reference — but that
move *is itself* a drift-capturing swap, charged at the elevated rate. The manipulation pays
the expensive fee to obtain the cheap one. Splitting an order in the away-from-reference
direction gains nothing either, since each piece already receives the floor.

**JIT liquidity around the surcharge (checklist item 14).** A searcher could add liquidity
immediately before a surcharge-triggering swap, capture the pro-rata donation, and withdraw.
They would also be the counterparty to that swap and absorb the adverse selection the
surcharge exists to compensate. Holding share `s` of in-range liquidity, they receive `s·S`
of a surcharge `S` while bearing `s` of the loss it prices. The mechanism degrades to
economically neutral rather than to exploitable. This is a general v4 property, not specific
to this hook.

**Self-dealing on the surcharge.** Documented in `SECURITY.md`: net cost `(1-s)·S`. At `s=1`
the surcharge is free, but the attacker is then the only liquidity provider and the adverse
selection being priced is damage to themselves.

---

## Not verified, and why

Stated explicitly rather than passed over in silence.

- **Live-chain behaviour against a real Chainlink feed.** All oracle tests use
  `MockAggregatorV3`. The adapter's decimal scaling was checked once against the deployed
  Base Sepolia aggregator and agreed to 0.000000%, but staleness and reversion paths have
  only been exercised against the mock.
- **Deviation cap against a pool TWAP.** Not implemented — see context §0. A compromised feed
  within its staleness window mis-prices fees, bounded only by `maxFeePips`. This is a known
  gap, not a finding.
- **Reentrancy through a malicious ERC-20.** `donate()` is an external call from `afterSwap`,
  and `_poolState` is written before it. The v4 `PoolManager` is the only callee and its
  `beforeDonate`/`afterDonate` permissions are both false, so this hook cannot be re-entered
  through that path. Not tested against a token with a transfer callback.
- **The calibration pipeline.** Out of scope per context §9 except for supply-chain risk;
  `pip-audit` reports no known vulnerabilities against the pinned lock.
