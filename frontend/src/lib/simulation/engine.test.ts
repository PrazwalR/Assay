import { describe, expect, it } from "vitest";

import { buildScenario, ethUsdAtTick, tickAtEthUsd } from "./engine";
import { sqrtPriceAtTick, type PoolCurve } from "@/lib/protocol/swapMath";

/**
 * Pinned to the live pool, read via `extsload`:
 *   sqrtPriceX96 1601381653348999796675376568351253 (tick 198290), liquidity 781101333179
 * and the hook's cached reference tick 198261.
 *
 * These assert the scenario is *coherent* — that the story the timeline tells is one the chain
 * would actually produce. A scenario whose second leg does not move the price back toward the
 * reference is not an arbitrage, however good it looks animated.
 */
const CURVE: PoolCurve = {
  sqrtPriceX96: 1_601_381_653_348_999_796_675_376_568_351_253n,
  liquidity: 781_101_333_179n,
  sqrtPriceLowerX96: sqrtPriceAtTick(192_240),
  sqrtPriceUpperX96: sqrtPriceAtTick(204_240),
};
const REFERENCE_TICK = 198_261;
const GAS_PRICE = 6_000_000n;

const INPUT = { dislocationUsdc: 1, captureFraction: 1 };

describe("tick ↔ price", () => {
  it("treats a higher tick as a cheaper ETH, matching the pool's orientation", () => {
    expect(ethUsdAtTick(198_290)).toBeLessThan(ethUsdAtTick(198_261));
  });

  it("round-trips", () => {
    const usd = ethUsdAtTick(198_290);
    expect(tickAtEthUsd(usd)).toBe(198_290);
  });

  it("puts the live pool near its observed price", () => {
    // The pool read $2,447.76 at tick 198290 when this was written.
    expect(ethUsdAtTick(198_290)).toBeGreaterThan(2_300);
    expect(ethUsdAtTick(198_290)).toBeLessThan(2_600);
  });
});

describe("buildScenario", () => {
  const scenario = buildScenario(CURVE, REFERENCE_TICK, GAS_PRICE, INPUT)!;

  it("builds from live pool state", () => {
    expect(scenario).toBeDefined();
    expect(scenario.unavailable).toBeUndefined();
  });

  it("actually dislocates the pool — the first leg moves it away from the reference", () => {
    expect(scenario.spreadBefore).toBeGreaterThan(0);
    // Selling USDC drives the tick down, which raises the pool's quoted ETH price.
    expect(scenario.dislocated.tick).toBeLessThan(scenario.initial.tick);
    expect(scenario.dislocated.priceUsd).toBeGreaterThan(scenario.initial.priceUsd);
  });

  it("closes the gap — the arbitrage leg moves the price back toward the reference", () => {
    expect(scenario.spreadAfter).toBeLessThan(scenario.spreadBefore);
    expect(scenario.restored.tick).toBeGreaterThan(scenario.dislocated.tick);
  });

  it("surcharges the arbitrage far above the leg that created the gap", () => {
    // The thesis: the leg capturing the drift pays materially more than the one that opened it.
    //
    // Note the dislocating leg is not itself below base — the live pool already sits +29 ticks
    // in that direction, so it captures a little too and pays ~790 pips. The claim that holds,
    // and the one the comparison panel makes, is the *ratio* between the two.
    expect(scenario.arbitrageLeg.feePips).toBeGreaterThan(scenario.dislocationLeg.feePips * 2);
    expect(scenario.arbitrageLeg.driftTicks).toBeGreaterThan(scenario.dislocationLeg.driftTicks);
    // And the arbitrage is unambiguously capturing.
    expect(scenario.arbitrageLeg.driftTicks).toBeGreaterThan(0);
  });

  it("charges liquidity providers more than a flat-fee pool would on the same trade", () => {
    // This is the comparison the feature exists to make, and it must hold by construction.
    expect(scenario.economics.feeToLpUsd).toBeGreaterThan(scenario.economics.flatFeeToLpUsd);
  });

  it("prices gas as real money", () => {
    expect(scenario.economics.gasUsd).toBeGreaterThan(0);
    expect(scenario.economics.gasUsd).toBeLessThan(1);
  });

  it("reports reserves that move in opposite directions across the dislocation", () => {
    // Selling USDC into the pool: its USDC goes up, its WETH goes down.
    expect(scenario.dislocated.reserve0).toBeGreaterThan(scenario.initial.reserve0);
    expect(scenario.dislocated.reserve1).toBeLessThan(scenario.initial.reserve1);
  });

  it("refuses rather than over-quoting a dislocation larger than the pool", () => {
    const tooBig = buildScenario(CURVE, REFERENCE_TICK, GAS_PRICE, {
      dislocationUsdc: 100_000,
      captureFraction: 1,
    });
    expect(tooBig?.unavailable).toBeDefined();
  });

  it("scales: a bigger dislocation opens a wider spread", () => {
    const small = buildScenario(CURVE, REFERENCE_TICK, GAS_PRICE, { ...INPUT, dislocationUsdc: 0.5 })!;
    const large = buildScenario(CURVE, REFERENCE_TICK, GAS_PRICE, { ...INPUT, dislocationUsdc: 3 })!;
    expect(large.spreadBefore).toBeGreaterThan(small.spreadBefore);
    expect(large.arbitrageLeg.feePips).toBeGreaterThan(small.arbitrageLeg.feePips);
  });

  it("returns nothing without live pool state, rather than inventing a pool", () => {
    expect(buildScenario(undefined, REFERENCE_TICK, GAS_PRICE, INPUT)).toBeUndefined();
    expect(buildScenario(CURVE, undefined, GAS_PRICE, INPUT)).toBeUndefined();
  });
});
