/**
 * The drift → tone mapping, in one place.
 *
 * Tone is a presentation concern, not a protocol one — the contract has no notion of "warm".
 * But it must be derived consistently everywhere, because a swap shown as benign on one
 * surface and warm on another reads as a bug in the pricing rather than in the palette.
 * Components read `data-tone` and let CSS resolve the colours (see globals.css); they never
 * re-derive the mapping themselves.
 */

export type Tone = "benign" | "base" | "warm" | "hot";

/** Thresholds from DESIGN-SPEC.md §2. */
export function toneFor(driftTicks: number, referenceFresh: boolean): Tone {
  if (!referenceFresh) return "hot";
  if (driftTicks < 0) return "benign";
  if (driftTicks <= 40) return "base";
  if (driftTicks <= 500) return "warm";
  return "hot";
}

/**
 * The sentence shown beside the quote. Phrased as what the swap is doing, not as a severity —
 * a swap trading away from the reference is not "good", it simply captures nothing.
 */
export function toneLabel(driftTicks: number, referenceFresh: boolean): string {
  if (!referenceFresh) return "Reference stale — quoting the ceiling";
  if (driftTicks < 0) return "Trades away from reference — below base";
  if (driftTicks <= 2) return "At reference — base fee";
  if (driftTicks <= 40) return "Slight drift — modest surcharge";
  if (driftTicks <= 500) return "Captures drift — surcharged";
  return "Top-of-block capture — near the ceiling";
}
