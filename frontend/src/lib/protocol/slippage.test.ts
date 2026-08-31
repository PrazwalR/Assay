import { describe, expect, it } from "vitest";

import { limitAsPriceRatio, sqrtPriceLimitX96 } from "./slippage";
import { MAX_SQRT_PRICE, MIN_SQRT_PRICE } from "./tokens";

/**
 * Pinned against the live pool, read via `extsload` on the PoolManager:
 *
 *   slot  = keccak256(poolId ++ bytes32(6))
 *   slot0 = 0x0000000001f40000000306920000000000004ef44730f2caba3306d8c3643a15
 *         → sqrtPriceX96 1601381653348999796675376568351253, tick 198290
 *
 * The bug this guards: the app previously sent MIN+1 / MAX-1 as the limit, meaning "any price",
 * while displaying a "Minimum received" row. A regression to that would make every assertion
 * about direction below fail.
 */
const LIVE_SQRT_PRICE = 1_601_381_653_348_999_796_675_376_568_351_253n;

describe("sqrtPriceLimitX96", () => {
  it("bounds a zeroForOne swap below the current price", () => {
    const limit = sqrtPriceLimitX96(LIVE_SQRT_PRICE, true, 0.005);
    expect(limit).toBeLessThan(LIVE_SQRT_PRICE);
    // 0.5% on the price is ~0.25% on its square root.
    expect(limitAsPriceRatio(LIVE_SQRT_PRICE, limit)).toBeCloseTo(0.995, 5);
  });

  it("bounds a oneForZero swap above the current price", () => {
    const limit = sqrtPriceLimitX96(LIVE_SQRT_PRICE, false, 0.005);
    expect(limit).toBeGreaterThan(LIVE_SQRT_PRICE);
    expect(limitAsPriceRatio(LIVE_SQRT_PRICE, limit)).toBeCloseTo(1.005, 5);
  });

  it("is never the unbounded extreme — the defect this replaces", () => {
    for (const zeroForOne of [true, false]) {
      for (const slippage of [0.001, 0.005, 0.01, 0.05]) {
        const limit = sqrtPriceLimitX96(LIVE_SQRT_PRICE, zeroForOne, slippage);
        expect(limit).not.toBe(MIN_SQRT_PRICE + 1n);
        expect(limit).not.toBe(MAX_SQRT_PRICE - 1n);
      }
    }
  });

  it("tightens monotonically as tolerance falls", () => {
    const loose = sqrtPriceLimitX96(LIVE_SQRT_PRICE, true, 0.01);
    const tight = sqrtPriceLimitX96(LIVE_SQRT_PRICE, true, 0.001);
    // A tighter tolerance stops the price falling as far, so its limit sits higher.
    expect(tight).toBeGreaterThan(loose);
  });

  it("never returns the current price, which would revert before swapping", () => {
    for (const zeroForOne of [true, false]) {
      expect(sqrtPriceLimitX96(LIVE_SQRT_PRICE, zeroForOne, 0)).not.toBe(LIVE_SQRT_PRICE);
    }
    expect(sqrtPriceLimitX96(LIVE_SQRT_PRICE, true, 0)).toBeLessThan(LIVE_SQRT_PRICE);
    expect(sqrtPriceLimitX96(LIVE_SQRT_PRICE, false, 0)).toBeGreaterThan(LIVE_SQRT_PRICE);
  });

  it("stays inside Uniswap's own bounds even for an absurd tolerance", () => {
    const down = sqrtPriceLimitX96(LIVE_SQRT_PRICE, true, 0.999999);
    const up = sqrtPriceLimitX96(LIVE_SQRT_PRICE, false, 1_000_000);
    expect(down).toBeGreaterThanOrEqual(MIN_SQRT_PRICE + 1n);
    expect(up).toBeLessThanOrEqual(MAX_SQRT_PRICE - 1n);
  });

  it("holds at the edges of the representable price range", () => {
    const nearFloor = sqrtPriceLimitX96(MIN_SQRT_PRICE + 1_000n, true, 0.5);
    expect(nearFloor).toBeGreaterThanOrEqual(MIN_SQRT_PRICE + 1n);
    const nearCeiling = sqrtPriceLimitX96(MAX_SQRT_PRICE - 1_000n, false, 0.5);
    expect(nearCeiling).toBeLessThanOrEqual(MAX_SQRT_PRICE - 1n);
  });
});
