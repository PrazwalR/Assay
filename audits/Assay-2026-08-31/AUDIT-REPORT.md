# Assay — EVM Audit (8-checklist parallel pass)

Date: 2026-08-31. Methodology: `austintgriffith/evm-audit-skills` — 8 domain checklists
(`general`, `precision-math`, `defi-amm`, `oracles`, `chain-specific`, `access-control`,
`dos`, `flashloans`) run as independent parallel agents against `src/`, synthesized here.
This is the third audit pass this project has had; the first two (`docs/audit/`) used a
different, more general methodology and fixed rounding-direction and decimal-scaling bugs
now confirmed still fixed (see Precision Math below). This pass found genuinely new issues
none of the prior passes surfaced — the architectural, oracle, and DoS-shaped findings below
are novel, not repeats.

Full per-checklist findings: `findings-evm-audit-*.md` in this directory.

## Findings, ranked

### High

**[H-1] Sequencer-outage staleness window under-charges informed flow — contradicts `SECURITY.md`'s stated defense**
Independently found by both the `oracles` and `chain-specific` agents (`ORACLE-1` /
`C-1`), from two different angles, without seeing each other's work — the convergence
itself is corroborating evidence. `SECURITY.md` accepts "no L2 sequencer uptime check" as
safe on the reasoning that a down sequencer freezes the oracle's `updatedAt`, so staleness
fires and the pool falls back to the fee ceiling. That's only true once the outage exceeds
`MAX_AGE_SECONDS` (3600s deployed). For any shorter outage — the realistic case for an
OP-Stack sequencer incident — everything freezes *together*: no blocks means no swaps
(`state.lastTick` frozen) and no Chainlink update (`updatedAt` frozen), so on resumption the
reference and the pool's own smoothed anchor still agree, the deviation cap doesn't trip,
`referenceFresh = true`, and an arbitrageur trading toward wherever the real price actually
moved during the outage is quoted near the *base* fee — the opposite of the hook's purpose.
Files: `src/AssayHook.sol:320-369`, `src/oracle/ChainlinkReferenceAdapter.sol:132-149`.

**[H-2] JIT liquidity + single-swap tick manipulation extracts inflated fee/surcharge from the next swap**
`defi-amm` agent, `M-1`. The reference-deviation cap only gates whether a *new Chainlink
reading* is adopted — it never inspects the *live pool tick* the fee and surcharge formulas
actually consume (`state.lastTick`, set by whichever swap executed immediately before).
Nothing bounds that gap except `Mispricing.MAX_MISPRICING_TICKS` (200,000 — ten times looser
than the 20,000-tick cap the docs describe as "the" defense). A JIT liquidity provider who
can order their own swap ahead of a known pending one can manufacture a large apparent drift
for that third-party swap, collect its inflated `donate()`-routed surcharge as the dominant
in-range LP, then exit. This is exactly the gap `SECURITY.md` itself flags as unaudited
("cross-swap fee manipulation via the tick recorded in `afterSwap`... not audited by a third
party") — now given a concrete mechanism. Files: `src/AssayHook.sol:259-308,385-442`,
`src/libraries/Mispricing.sol:27-44`.

**[H-3] No gas stipend on the oracle read lets a hostile/compromised feed force every block-boundary swap to revert**
`dos` agent, `DOS-1`, empirically verified with a since-deleted PoC (binary-searched: swap
needs ≈1,034,375 gas to succeed against a gas-burning oracle — 19x the documented 55,000
budget). `REFERENCE_ORACLE`/`FEED` are immutable with no replacement path. If either is or
becomes hostile (e.g. a Chainlink proxy repointed by its own admin to malicious logic — see
`AC-2`), it can burn ~63/64 of forwarded gas before reverting, starving `_afterSwap` for any
realistic transaction gas limit. This is a de facto pool-wide DoS for the duration of the
compromise, with no admin lever to respond (by design — see `AC-1`). Files:
`src/AssayHook.sol:176-185`, `src/oracle/ChainlinkReferenceAdapter.sol:132-149`.

### Medium

**[M-1] `feeBounds()` and `SECURITY.md`'s advertised guarantee omit the toxicity-surcharge donation**
`defi-amm` agent, `M-2`. `feeBounds()` — documented as telling integrators "the worst fee a
swap can be quoted" — covers only the LP fee, not the separate `donate()` surcharge, bounded
independently at up to 100% of notional (`MAX_OVERFLOW_PIPS`). Compounds with **H-2**: an
integrator sizing slippage from `feeBounds()` alone is exposed to an undisclosed surcharge
that a JIT attacker can also inflate. Files: `src/AssayHook.sol:102-110,385-442`.

**[M-2] `ChainlinkReferenceAdapter.referenceSqrtPriceX96()` can revert on small positive feed answers, reachable via the live feed's own `minAnswer`**
`oracles` agent, `ORACLE-2`, empirically verified (Foundry PoC, boundary at
`floor(PRICE_NUMERATOR/2^64) = 5` for the deployed numerator; the live feed's on-chain
`minAnswer()` is `1`). The post-processing math sits outside the function's own `try/catch`,
so this violates the adapter's documented "never reverts" contract — masked today only by
`AssayHook`'s *outer* try/catch, an accidental second layer, not a designed guarantee. No
existing fuzz test exercises the deployed numerator's magnitude. Files:
`src/oracle/ChainlinkReferenceAdapter.sol:132-166`.

**[M-3] Gas-griefing the once-per-block reference read pins the pool at `maxFeePips` indefinitely**
`general` agent, `G-1`. Shares its root cause (no gas stipend on the same two calls) with
**H-3**, but is a different threat model: here the *swapper* self-selects a low gas limit to
force their own transaction's nested call to starve, cheaply and repeatably, keeping every
swap that block priced at the ceiling rather than by drift. One fix (explicit gas stipends,
see H-3's recommendation) addresses both M-3 and H-3 simultaneously. Files:
`src/AssayHook.sol:176-185,320-369`.

### Low / Info (not filed as issues — recorded for the record)

- **[L] `evm_version=cancun` portability trap** if redeployed unmodified to a pre-Cancun
  chain — not applicable to the current Base Sepolia deployment (`chain-specific`, `L-1`).
- **[L] Deviation-cap tick↔price math is off in `.env`/`SECURITY.md`**: 20,000 ticks ≈
  7.39x, documented as ≈2.7x — the deployed cap is more permissive than the team believes,
  though still well under the order-of-magnitude threshold that actually matters
  (`oracles`/`flashloans`, `ORACLE-3`/`INFO-2`).
- **[L] `FeeBlend.MAX_DRIFT_TICKS` duplicates `Mispricing.MAX_MISPRICING_TICKS`** as an
  unlinked literal — the codebase already fixed this exact pattern once elsewhere
  (`precision-math`, `L-1`).
- **[L] No admin/pause path to respond to a live incident** — the direct tradeoff of the
  "no admin key" design already validated by the CROPS review; flagged for explicit sign-off,
  not a defect (`access-control`, `AC-1`).
- **[L] `int128(uint128(amount))` downcast** not provably exact at its own documented
  boundary — unreachable at realistic token supplies (`general`, `G-2`).
- **[L] Chainlink staleness check skips its own bound check if `updatedAt` is ever in the
  future** — dormant against a well-behaved feed today (`general`, `G-3`).
- **[Info] `uint32(block.number)` wraparound** — independently confirmed negligible (~272
  years) by two agents (`precision-math` `L-2`, `chain-specific` `I-1`).
- **[Info]** `docs/gas.md` measures L2 execution gas only, not Base's L1 data fee — not a
  defect (`chain-specific`, `I-2`). Chainlink feed-proxy admin trust is standard and
  undefended-against by design (`access-control`, `AC-2`). Multi-block EWMA-anchor drift is
  theoretically possible but requires sustained non-flash capital, not flash-loan-reachable
  (`flashloans`, `INFO-1`).

## Cross-cutting observations (Phase 4)

- **H-3 and M-3 are the same missing-gas-stipend defect from two threat models** (hostile
  oracle vs. self-inflicted griefing by the swapper). A single fix — explicit `{gas: ...}`
  stipends on both external calls in the oracle-read path — resolves both.
- **M-1 and H-2 compound.** An integrator relying on `feeBounds()` for slippage protection is
  exposed to an undisclosed surcharge (M-1) that a JIT attacker can additionally inflate
  through tick manipulation the deviation cap doesn't cover (H-2) — the realistic worst case
  is worse than either finding read in isolation.
- **H-1 and H-2 are two independent ways to defeat the core "100bp vs 1bp, same block" claim**
  the whole project's README leads with — one via a chain-level condition outside the
  protocol's control (sequencer downtime), one via active manipulation within it (JIT
  liquidity). Neither was surfaced by the prior two audit passes, which focused on rounding,
  decimal-scaling, and `startedAt` validation. This pass's domain-specific checklists (AMM,
  oracle, DoS) reached architectural surface the general-purpose passes didn't probe.
- **M-2 is currently masked by accidental defense-in-depth**, not a designed guarantee — the
  adapter's own "never reverts" contract is false in isolation; it only holds because
  `AssayHook` happens to wrap the whole call in a second `try/catch`. Worth fixing at the
  source regardless of the outer mask, since the adapter is a reusable component whose
  documented contract other integrators might rely on directly.
- **State-machine consistency**: confirmed across all 8 passes that `PoolState` writes are
  correctly ordered before the one external call (`donate()`) that could reenter, and that no
  path leaves the hook holding a custodial balance. The three High findings are all about
  *what the state is used for*, not about state corruption or reentrancy.

## Not filed as GitHub issues

Per the audit methodology, only Medium severity and above are filed. The six Low findings and
five Info findings above are recorded here and in the per-checklist files but not filed.
