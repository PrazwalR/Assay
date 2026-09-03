import { describe, expect, it } from "vitest";

import { num, tokenAmount } from "./format";

/**
 * The bug this pins: the swap page reported "0.00000 WETH in fees" for every ordinary swap.
 *
 * `feePaidOut` was correct -- it is a real re-quote at zero fee minus the actual output -- but it
 * was formatted at the token's own five decimal places. A 1 bp fee on a 0.00189 WETH output is
 * 0.000000189 WETH, four orders of magnitude below that precision, so the true number rendered as
 * zero on the one panel titled "Why this fee". It also looked static while the swap amount
 * changed, because every size rounded to the same zero.
 */
describe("tokenAmount", () => {
  it("keeps a fee smaller than the token's display precision legible", () => {
    // 1 bp on ~0.00189 WETH -- the exact case that rendered as "0.00000".
    expect(tokenAmount(0.000000189, 5)).toBe("0.000000189");
    expect(num(0.000000189, 5)).toBe("0.00000"); // what it used to do
  });

  it("scales with the swap size instead of collapsing every amount to zero", () => {
    const small = tokenAmount(0.000000189, 5);
    const tenTimesLarger = tokenAmount(0.00000189, 5);
    expect(small).not.toBe(tenTimesLarger);
  });

  it("defers to the token's own convention once the amount is large enough to show", () => {
    expect(tokenAmount(0.01358, 5)).toBe("0.01358");
    expect(tokenAmount(21.79, 2)).toBe("21.79");
  });

  it("never expands a true zero into a fabricated charge", () => {
    expect(tokenAmount(0, 5)).toBe("0");
  });

  it("does not fall back to exponent notation a trader cannot read", () => {
    expect(tokenAmount(0.000000000123, 5)).not.toMatch(/e/i);
  });

  it("carries the sign of a negative amount", () => {
    expect(tokenAmount(-0.000000189, 5)).toBe("-0.000000189");
  });
});
