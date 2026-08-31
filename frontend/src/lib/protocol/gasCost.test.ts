import { describe, expect, it } from "vitest";

import { formatGasCostUsd, gasCostUsd } from "./gasCost";
import { GAS } from "./config";

/**
 * Pinned against live readings taken while writing this:
 *
 *   cast gas-price --rpc-url https://mainnet.base.org        → 6000000 wei (0.006 gwei)
 *   cast base-fee  --rpc-url https://ethereum-rpc.publicnode.com → 47872371 wei (0.0479 gwei)
 *   Chainlink ETH/USD                                        → $2,453.65
 *
 * Gas prices move, so these assert magnitude rather than exact cents — the property that
 * matters is that the arithmetic is right, not that the market held still.
 */
const BASE_GAS_PRICE = 6_000_000n;
const MAINNET_GAS_PRICE = 47_872_371n;
const ETH_USD = 2_453.65;

describe("gasCostUsd", () => {
  it("prices the ordinary-swap hook overhead on Base at a fraction of a cent", () => {
    const cost = gasCostUsd(GAS.ordinarySwap, BASE_GAS_PRICE, ETH_USD);
    expect(cost).toBeCloseTo(0.00022, 5);
  });

  it("prices the same overhead on mainnet, still well under a cent", () => {
    const cost = gasCostUsd(GAS.ordinarySwap, MAINNET_GAS_PRICE, ETH_USD);
    expect(cost).toBeCloseTo(0.00175, 5);
  });

  it("prices the most expensive path — a block boundary with a live feed read", () => {
    const cost = gasCostUsd(GAS.blockBoundaryWithLiveFeed, BASE_GAS_PRICE, ETH_USD);
    expect(cost).toBeCloseTo(0.00075, 5);
    // The whole gas budget this project was designed around is worth less than a cent.
    expect(cost!).toBeLessThan(0.01);
  });

  it("scales linearly in gas, price and ETH", () => {
    const one = gasCostUsd(10_000, 1_000_000n, 2_000)!;
    expect(gasCostUsd(20_000, 1_000_000n, 2_000)).toBeCloseTo(one * 2, 12);
    expect(gasCostUsd(10_000, 2_000_000n, 2_000)).toBeCloseTo(one * 2, 12);
    expect(gasCostUsd(10_000, 1_000_000n, 4_000)).toBeCloseTo(one * 2, 12);
  });

  it("returns undefined rather than a made-up number when the gas price has not loaded", () => {
    expect(gasCostUsd(GAS.ordinarySwap, undefined, ETH_USD)).toBeUndefined();
  });
});

describe("formatGasCostUsd", () => {
  // The failure this guards: rounding a real sub-cent cost to "$0.00", which reads as free.
  it("keeps sub-cent costs legible instead of rounding them to zero", () => {
    expect(formatGasCostUsd(0.00022)).toBe("$0.00022");
    expect(formatGasCostUsd(0.000748)).toBe("$0.00075");
  });

  it("uses coarser precision as the number grows", () => {
    expect(formatGasCostUsd(0.42)).toBe("$0.420");
    expect(formatGasCostUsd(12.5)).toBe("$12.50");
  });

  it("shows a dash rather than a zero when the cost is unknown", () => {
    expect(formatGasCostUsd(undefined)).toBe("—");
  });
});
