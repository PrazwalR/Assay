/**
 * TypeScript mirror of `src/libraries/FeeBlend.sol`.
 *
 * This is not a decorative reimplementation: it is what the UI quotes users, so a divergence
 * from the Solidity is a UI that lies about what the chain will charge. Three independent
 * implementations now exist (Solidity, Python, this one) and all three assert against the same
 * fixture — `test/fixtures/fee_blend.json` at the repository root. A change to the contract
 * that is not mirrored here fails `feeBlend.test.ts` rather than silently mispricing a display.
 *
 * Parameters are arguments rather than constants because the fixture exercises three different
 * capture shares. `DEPLOYED` in ./config.ts carries the values actually on chain.
 */

/** Largest drift a single reading can report, mirroring `Mispricing.MAX_MISPRICING_TICKS`. */
export const MAX_DRIFT_TICKS = 200_000;

/** One tick is one basis point of price; a fee pip is a hundredth of a basis point. */
export const PIPS_PER_TICK = 100;

/** Denominator for `captureShareBps`. */
export const BPS_DENOMINATOR = 10_000;

/** One hundred percent in pips — the scale the surcharge is measured against, not a bound. */
export const PIPS_DENOMINATOR = 1_000_000;

/** Ceiling on the reported cap overflow, mirroring `FeeBlend.MAX_OVERFLOW_PIPS`. */
export const MAX_OVERFLOW_PIPS = 20_000;

export interface FeeParams {
  baseFeePips: number;
  minFeePips: number;
  maxFeePips: number;
  captureShareBps: number;
}

const clamp = (value: number, low: number, high: number) =>
  Math.min(high, Math.max(low, value));

/**
 * The uncapped quote, in pips, before `minFeePips`/`maxFeePips` are applied.
 *
 * The rounding is the subtle part and is deliberate. Solidity's signed division truncates
 * toward zero, which on the capturing side lowers the fee below its exact value — the
 * liquidity-adverse direction, and a real audit finding fixed in the contract. Both languages
 * therefore round toward positive infinity: up on a positive surcharge, and (already, by
 * truncation) up on a negative one. `Math.trunc` matches Solidity exactly where `Math.floor`
 * would not, since the two differ on negative operands.
 */
export function rawQuotedPips(driftTicks: number, params: FeeParams): number {
  const drift = clamp(driftTicks, -MAX_DRIFT_TICKS, MAX_DRIFT_TICKS);
  const scaled = drift * PIPS_PER_TICK * params.captureShareBps;

  let surcharge = Math.trunc(scaled / BPS_DENOMINATOR);
  if (scaled > 0 && scaled % BPS_DENOMINATOR !== 0) surcharge += 1;

  return params.baseFeePips + surcharge;
}

/**
 * The fee a swap is quoted, always within `[minFeePips, maxFeePips]`.
 *
 * A stale reference quotes the ceiling rather than erroring. That is the contract's actual
 * behaviour — `beforeSwap` must never revert, so it degrades upward — and the UI must show the
 * same thing rather than an error state.
 */
export function quote(
  driftTicks: number,
  referenceFresh: boolean,
  params: FeeParams,
): number {
  if (!referenceFresh) return params.maxFeePips;
  return clamp(rawQuotedPips(driftTicks, params), params.minFeePips, params.maxFeePips);
}

/**
 * How far the uncapped formula wants to charge beyond `maxFeePips`.
 *
 * Zero on ordinary swaps. On an extreme dislocation the remainder is taken in the swap's
 * unspecified currency and donated to in-range liquidity, because a percentage-of-notional fee
 * cannot express it. Zero whenever the reference is stale: with no trusted drift reading there
 * is nothing to attribute an overflow to.
 */
export function ceilingOverflowPips(
  driftTicks: number,
  referenceFresh: boolean,
  params: FeeParams,
): number {
  if (!referenceFresh) return 0;
  const raw = rawQuotedPips(driftTicks, params);
  return clamp(raw - params.maxFeePips, 0, MAX_OVERFLOW_PIPS);
}
