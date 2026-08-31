import { describe, expect, it } from "vitest";

import { referenceUsdFrom } from "./reference";

/**
 * Pinned against a real reading taken from the deployed adapter on Base Sepolia:
 *
 *   cast call 0x68E65451A97261B451f186e9B9099c3fBF7efc90 "referenceSqrtPriceX96()(uint160,bool)"
 *     → 1598754263643166729418216196930566, true
 *   cast call 0x68E65451A97261B451f186e9B9099c3fBF7efc90 "PRICE_NUMERATOR()(uint256)"
 *     → 100000000000000000000
 *   cast call 0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1 "latestRoundData()(...)"
 *     → answer 245581550000  (8 decimals ⇒ $2,455.82)
 *
 * The decoded figure must reproduce that answer. Without this, a conversion bug shows up as a
 * plausible-looking number under a "live" badge, which is the one failure this UI must not have.
 */
const SQRT_PRICE_X96 = 1_598_754_263_643_166_729_418_216_196_930_566n;
const PRICE_NUMERATOR = 100_000_000_000_000_000_000n;
const FEED_ANSWER_USD = 2_455.8155;
const FALLBACK = 3_412.6;

describe("referenceUsdFrom", () => {
  it("reproduces the feed's own answer from a real on-chain reading", () => {
    const usd = referenceUsdFrom(SQRT_PRICE_X96, PRICE_NUMERATOR, FALLBACK);
    // Within a cent: the square root is lossy, but not to any degree a reader would notice.
    expect(usd).toBeCloseTo(FEED_ANSWER_USD, 1);
  });

  it("lands in a plausible range rather than off by orders of magnitude", () => {
    // The bug this replaces returned 2.4e-9 and rendered as "$0.00". A magnitude assertion
    // catches that class of error even if the exact expectation above is ever re-pinned.
    const usd = referenceUsdFrom(SQRT_PRICE_X96, PRICE_NUMERATOR, FALLBACK);
    expect(usd).toBeGreaterThan(100);
    expect(usd).toBeLessThan(100_000);
  });

  it("falls back rather than inventing a price when the numerator has not loaded", () => {
    expect(referenceUsdFrom(SQRT_PRICE_X96, undefined, FALLBACK)).toBe(FALLBACK);
  });

  it("falls back on a zero price rather than dividing by zero", () => {
    expect(referenceUsdFrom(0n, PRICE_NUMERATOR, FALLBACK)).toBe(FALLBACK);
  });
});
