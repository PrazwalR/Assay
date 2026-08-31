import { describe, expect, it } from "vitest";

import { quoteExactInput, sqrtPriceAtTick, type PoolCurve } from "./swapMath";

/**
 * Pinned to the live pool and to a real `PoolSwapTest` simulation.
 *
 *   extsload slot0 → sqrtPriceX96 1601381653348999796675376568351253 (tick 198290)
 *   extsload +3    → liquidity    781101333179
 *   cast call swap(... amountSpecified -100000 ...) → amount1 +40716067933021
 *
 * The last line is the assertion that matters: if this file's arithmetic and the chain's ever
 * disagree, the interface is quoting something the pool will not honour — which is exactly the
 * defect this module was written to fix.
 */
const CURVE: PoolCurve = {
  sqrtPriceX96: 1_601_381_653_348_999_796_675_376_568_351_253n,
  liquidity: 781_101_333_179n,
  sqrtPriceLowerX96: sqrtPriceAtTick(192_240),
  sqrtPriceUpperX96: sqrtPriceAtTick(204_240),
};

/** The hook's quote at the pool's live +29 tick drift. */
const FEE_ZERO_FOR_ONE = 790;

describe("quoteExactInput", () => {
  it("reproduces a live chain simulation to the wei", () => {
    const result = quoteExactInput(CURVE, 100_000n, FEE_ZERO_FOR_ONE, true);
    expect(result.amountOut).toBe(40_716_067_933_021n);
  });

  it("prices impact, which the spot-ratio quote it replaced did not", () => {
    // 11 USDC against ~38 USDC of depth is a large trade. The old quote said 0.004493 WETH.
    const result = quoteExactInput(CURVE, 11_000_000n, FEE_ZERO_FOR_ONE, true);
    const weth = Number(result.amountOut) / 1e18;
    expect(weth).toBeCloseTo(0.003496, 6);
    // Which is a quarter less than the naive answer — the whole reason this module exists.
    expect(weth).toBeLessThan(0.0045 * 0.85);
    expect(result.priceImpact).toBeGreaterThan(0.2);
  });

  it("scales sub-linearly: doubling the input yields less than double the output", () => {
    const one = quoteExactInput(CURVE, 1_000_000n, FEE_ZERO_FOR_ONE, true).amountOut;
    const two = quoteExactInput(CURVE, 2_000_000n, FEE_ZERO_FOR_ONE, true).amountOut;
    expect(two).toBeLessThan(one * 2n);
    expect(two).toBeGreaterThan(one);
  });

  it("moves the price down selling token0 and up selling token1", () => {
    const down = quoteExactInput(CURVE, 1_000_000n, FEE_ZERO_FOR_ONE, true);
    expect(down.sqrtPriceNextX96).toBeLessThan(CURVE.sqrtPriceX96);

    const up = quoteExactInput(CURVE, 10_000_000_000_000_000n, 210, false);
    expect(up.sqrtPriceNextX96).toBeGreaterThan(CURVE.sqrtPriceX96);
  });

  it("charges the fee by reducing the output", () => {
    const cheap = quoteExactInput(CURVE, 1_000_000n, 100, true).amountOut;
    const dear = quoteExactInput(CURVE, 1_000_000n, 10_000, true).amountOut;
    expect(dear).toBeLessThan(cheap);
  });

  it("flags a swap that would leave the liquidity range rather than over-quoting it", () => {
    // Far beyond the ~38 USDC of depth: the constant-liquidity assumption stops holding.
    const huge = quoteExactInput(CURVE, 10_000_000_000n, FEE_ZERO_FOR_ONE, true);
    expect(huge.crossesRange).toBe(true);
  });

  it("stays inside the range for ordinary sizes", () => {
    expect(quoteExactInput(CURVE, 1_000_000n, FEE_ZERO_FOR_ONE, true).crossesRange).toBe(false);
    expect(quoteExactInput(CURVE, 5_000_000n, FEE_ZERO_FOR_ONE, true).crossesRange).toBe(false);
  });

  it("returns nothing rather than throwing on degenerate input", () => {
    expect(quoteExactInput(CURVE, 0n, FEE_ZERO_FOR_ONE, true).amountOut).toBe(0n);
    expect(quoteExactInput(CURVE, -5n, FEE_ZERO_FOR_ONE, true).amountOut).toBe(0n);
    expect(quoteExactInput({ ...CURVE, liquidity: 0n }, 1_000n, 500, true).amountOut).toBe(0n);
    // A fee of 100% consumes the entire input.
    expect(quoteExactInput(CURVE, 1_000n, 1_000_000, true).amountOut).toBe(0n);
  });
});

describe("sqrtPriceAtTick", () => {
  it("agrees with the pool's own tick to within a tick", () => {
    // The live pool reports tick 198290 alongside its sqrtPriceX96; the two must correspond.
    const derived = sqrtPriceAtTick(198_290);
    const actual = CURVE.sqrtPriceX96;
    const ratio = Number(derived) / Number(actual);
    expect(ratio).toBeGreaterThan(0.99995);
    expect(ratio).toBeLessThan(1.00005);
  });

  it("is monotonic in tick", () => {
    expect(sqrtPriceAtTick(198_291)).toBeGreaterThan(sqrtPriceAtTick(198_290));
    expect(sqrtPriceAtTick(-1_000)).toBeLessThan(sqrtPriceAtTick(0));
  });
});
