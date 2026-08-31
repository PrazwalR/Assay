## Verification of prior-pass fixes (confirmed, not new findings)

Two rounding-direction bugs reported in `docs/audit/ethskills-audit-report.md` (pass 1, L-1 and L-2) were re-derived by hand against current source and confirmed fixed and correctly generalized:

- **L-1 (fee surcharge truncation)**: `FeeBlend._rawQuotedPips` now adds `+1` only when `scaled > 0` and there's a remainder — verified with `drift=7, captureShareBps=3333`: exact surcharge `233.31`, code computes `233` then `+1` → `234`, correctly rounding toward `+∞`. Benign side (`drift=-7`) correctly needs no correction.
- **L-2 (surcharge-amount rounding)**: `ToxicitySurcharge.surchargeAmount` now calls `FullMath.mulDivRoundingUp`, confirmed in current source.
- Cross-checked `FeeBlend.quote`/`ceilingOverflowPips` against `test/fixtures/fee_blend.json` by hand; both route through the same shared `_rawQuotedPips` helper so cannot structurally diverge.
- Pass-2's M-1 (`PRICE_NUMERATOR` decimal-mismatch) fix is present and matches its regression test.
- `ChainlinkReferenceAdapter.PRICE_NUMERATOR = 10^(currency1Decimals - currency0Decimals + feedDecimals)` verified by full algebraic derivation against the deployed USDC(6)/WETH(18)/8-decimal-feed shape — no inversion bug found.

## Findings

## [L-1] `FeeBlend.MAX_DRIFT_TICKS` duplicates `Mispricing.MAX_MISPRICING_TICKS` as an unlinked literal
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `src/libraries/FeeBlend.sol:25` (`MAX_DRIFT_TICKS`) vs `src/libraries/Mispricing.sol:18` (`MAX_MISPRICING_TICKS`)
**Description**: Both constants are declared as the literal `200_000` in two different files, with no import connecting them. `FeeBlend.sol`'s own docstring says the bound exists as defense-in-depth because "`Mispricing` already clamps to this" — the two values are meant to always agree, but nothing enforces that. The codebase already recognized this exact anti-pattern once and fixed it (`ToxicitySurcharge.surchargeAmount` imports `FeeBlend.MAX_OVERFLOW_PIPS` rather than redeclaring it) — that fix was not applied to this pair.
**Proof of Concept**: Not exploitable today — both constants currently equal `200_000`. Future-facing: if `Mispricing.MAX_MISPRICING_TICKS` is later widened without updating `FeeBlend.MAX_DRIFT_TICKS`, `Mispricing` would report larger signed drift than `FeeBlend` prices for, silently capping the fee/surcharge below what the widened range was calibrated for — a quiet mispricing that wouldn't surface as a revert or test failure.
**Recommendation**: Import the bound from one source of truth, matching the pattern already used for `MAX_OVERFLOW_PIPS`:
```solidity
import {Mispricing} from "./Mispricing.sol";
int256 internal constant MAX_DRIFT_TICKS = Mispricing.MAX_MISPRICING_TICKS;
```

## [L-2] `uint32(block.number)` narrowing in pool state has no overflow guard
**Severity**: Low
**Category**: evm-audit-precision-math
**Location**: `src/AssayHook.sol:241` (`_afterInitialize`), `src/AssayHook.sol:330-331` (`_advanceStateInPlace`)
**Description**: `PoolState.lastBlock` is `uint32`, narrowed from `block.number` with a bare cast, no `SafeCast`. The hook has no admin key and no upgrade path, so this can't be patched post-deployment.
**Proof of Concept**: At `block.number == 2**32`, the cast wraps to `0` and could alias with earlier state, causing one block-boundary refresh to be skipped. Self-correcting on the next swap. At Base's ~2s cadence, `2**32` blocks is ~272 years away.
**Recommendation**: Use `SafeCast.toUint32(block.number)` so a chain that ever reaches this height reverts loudly instead of silently aliasing, or document the ~272-year assumption as an accepted bound.

**Summary**: No Critical, High, or Medium precision-math findings. The fee-formula rounding direction was independently re-derived with concrete numbers and confirmed correct everywhere it's used. The two Low findings are latent maintenance-risk patterns, not active bugs.
