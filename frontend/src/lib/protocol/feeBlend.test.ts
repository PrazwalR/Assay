import { readFileSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

import { DEPLOYED } from "./config";
import {
  BPS_DENOMINATOR,
  MAX_OVERFLOW_PIPS,
  ceilingOverflowPips,
  quote,
  rawQuotedPips,
} from "./feeBlend";

/**
 * The fixture is shared with the Solidity (`test/unit/FeeBlendFixture.t.sol`) and the Python
 * (`calibration/tests/test_backtest.py`). Reading the same file from a third language is the
 * whole point: three implementations pinned to one set of cases, so a change to any one of
 * them that is not mirrored in the others fails a test instead of silently diverging.
 *
 * Resolved relative to the repository root rather than copied, because a local copy is exactly
 * the drift this guards against.
 */
const FIXTURE = join(process.cwd(), "..", "test", "fixtures", "fee_blend.json");

interface Case {
  drift: number;
  share: number;
  quote: number;
  overflow: number;
}

const cases: Case[] = JSON.parse(readFileSync(FIXTURE, "utf8"));

// The fixture was generated against these bounds; only `share` varies per case.
const boundsFor = (share: number) => ({
  baseFeePips: 500,
  minFeePips: 100,
  maxFeePips: 10_000,
  captureShareBps: share,
});

describe("matches the shared Solidity fixture", () => {
  it("is present and populated", () => {
    expect(cases.length).toBeGreaterThan(0);
  });

  it.each(cases)(
    "drift $drift at share $share quotes $quote with overflow $overflow",
    ({ drift, share, quote: expected, overflow }) => {
      const params = boundsFor(share);
      expect(quote(drift, true, params)).toBe(expected);
      expect(ceilingOverflowPips(drift, true, params)).toBe(overflow);
    },
  );
});

describe("rounding direction", () => {
  // Regression for the audit finding fixed in the contract: signed division truncating toward
  // zero lowered the fee below its exact value on the capturing side. 1 tick at 3,333 bps is
  // exactly 33.33 pips of surcharge.
  const odd = { ...boundsFor(3_333) };

  it("rounds a positive surcharge up, never down", () => {
    expect(quote(1, true, odd)).toBe(500 + 34);
  });

  it("rounds toward positive infinity on the negative side too", () => {
    expect(quote(-1, true, odd)).toBe(500 - 33);
  });

  it("leaves an exactly-divisible share untouched", () => {
    const even = boundsFor(2_500);
    expect(quote(1, true, even)).toBe(500 + 25);
    expect(quote(-1, true, even)).toBe(500 - 25);
  });

  it("is never below the exact rational fee, and never a full pip above it", () => {
    for (let drift = -1_000; drift <= 1_000; drift += 7) {
      for (const share of [1, 555, 1_000, 3_333, 9_999, 10_000]) {
        const params = { ...boundsFor(share), baseFeePips: 500_000, maxFeePips: 1_000_000 };
        const scaledExact = params.baseFeePips * BPS_DENOMINATOR + drift * 100 * share;
        const scaledQuoted = rawQuotedPips(drift, params) * BPS_DENOMINATOR;

        expect(scaledQuoted).toBeGreaterThanOrEqual(scaledExact);
        expect(scaledQuoted - scaledExact).toBeLessThan(BPS_DENOMINATOR);
      }
    }
  });
});

describe("degradation and bounds", () => {
  it("quotes the ceiling when the reference is stale, rather than erroring", () => {
    expect(quote(0, false, DEPLOYED)).toBe(DEPLOYED.maxFeePips);
    expect(quote(-5_000, false, DEPLOYED)).toBe(DEPLOYED.maxFeePips);
  });

  it("reports no overflow when the reference is stale", () => {
    expect(ceilingOverflowPips(50_000, false, DEPLOYED)).toBe(0);
  });

  it("stays inside the advertised bounds for any drift", () => {
    for (let drift = -300_000; drift <= 300_000; drift += 1_237) {
      const fee = quote(drift, true, DEPLOYED);
      expect(fee).toBeGreaterThanOrEqual(DEPLOYED.minFeePips);
      expect(fee).toBeLessThanOrEqual(DEPLOYED.maxFeePips);
    }
  });

  it("bounds the reported overflow regardless of how extreme the drift is", () => {
    expect(ceilingOverflowPips(10_000_000, true, DEPLOYED)).toBe(MAX_OVERFLOW_PIPS);
  });

  it("clamps drift rather than letting an absurd reading run away", () => {
    expect(quote(200_000, true, DEPLOYED)).toBe(quote(999_999, true, DEPLOYED));
  });
});

describe("the deployed configuration", () => {
  it("quotes the base fee at the reference", () => {
    expect(quote(0, true, DEPLOYED)).toBe(DEPLOYED.baseFeePips);
  });

  it("adds ten pips per tick of captured drift", () => {
    expect(quote(1, true, DEPLOYED)).toBe(DEPLOYED.baseFeePips + 10);
    expect(quote(10, true, DEPLOYED)).toBe(DEPLOYED.baseFeePips + 100);
  });

  // The property the whole product rests on: same drift, opposite directions, different fees.
  it("quotes opposite directions differently against the same drift", () => {
    const capturing = quote(240, true, DEPLOYED);
    const opposing = quote(-240, true, DEPLOYED);
    expect(capturing).toBeGreaterThan(opposing);
  });
});
