/**
 * The only place fixture data lives.
 *
 * Everything here is a stand-in for something that cannot yet be *measured*. The pool is real
 * and live on Base Sepolia, but it has been traded twice — so its tick and its liquidity can be
 * read (see `hooks/useLivePool.ts`) while its volume, fee revenue and quote distribution cannot,
 * because two swaps is not a distribution. Those are what this file supplies.
 *
 * The reference price, the fee bounds, the pool tick and the signed drift are all live reads and
 * are not in this file.
 *
 * Two rules, both from DESIGN-SPEC.md §8–§9:
 *
 *  1. Everything reconciles. `poolPrice = REFERENCE / 1.0001^drift`, and every USD figure
 *     derives from that one price. A UI whose numbers do not add up reads as fake to exactly
 *     the audience this protocol needs.
 *  2. Nothing here is ever presented as live. Anything sourced from this file carries a
 *     marker in the UI.
 */

import { POOL } from "./config";

/** Fallback reference price, used only until the live oracle read resolves. */
export const FALLBACK_REFERENCE_USD = 3_412.6;

export type DataMode = "testnet" | "mainnet-mock";

/**
 * The real pool id, abbreviated for display. Re-exported from `config.ts` rather than duplicated
 * as a placeholder: the pool exists now, so showing a made-up id beside real figures would be
 * the one inconsistency this file is meant to prevent.
 */
export const POOL_ID = `${POOL.id.slice(0, 6)}…${POOL.id.slice(-4)}`;

export const NETWORKS = [
  {
    name: "Base Sepolia",
    note: "chain 84532 · hook deployed here",
    color: "#3B6BF5",
    state: "connected",
    available: true,
  },
  {
    name: "Unichain Sepolia",
    note: "chain 1301 · no Chainlink feed",
    color: "#E86FA8",
    state: "no reference",
    available: false,
  },
  {
    name: "Ethereum",
    note: "chain 1 · not deployed",
    color: "#8A93C6",
    state: "unavailable",
    available: false,
  },
  {
    name: "Arbitrum",
    note: "chain 42161 · not deployed",
    color: "#5B9CD6",
    state: "unavailable",
    available: false,
  },
] as const;

export const RANGES = [
  { label: "1H", factor: 1 / 24 },
  { label: "1D", factor: 1 },
  { label: "1W", factor: 6.4 },
  { label: "1M", factor: 26 },
  { label: "ALL", factor: 71 },
] as const;

export type RangeLabel = (typeof RANGES)[number]["label"];

/** Per-day baselines the range multiplier scales. */
export const MARKET_BASELINE: Record<
  DataMode,
  { tvlUsd: number; volumeUsd: number; feesUsd: number; swaps: number; donatedUsd: number; meanFeeBp: number; uptime: string; staleSpans: number }
> = {
  testnet: {
    tvlUsd: 1_240_000,
    volumeUsd: 184_200,
    feesUsd: 128.94,
    swaps: 412,
    donatedUsd: 41.18,
    meanFeeBp: 7.02,
    uptime: "99.20%",
    staleSpans: 3,
  },
  "mainnet-mock": {
    tvlUsd: 42_610_000,
    volumeUsd: 8_200_000,
    feesUsd: 5_742,
    swaps: 18_412,
    donatedUsd: 1_284,
    meanFeeBp: 7.0,
    uptime: "99.94%",
    staleSpans: 2,
  },
};

/** Share of volume by quoted fee, for the distribution bars. Sums to 100. */
export const FEE_DISTRIBUTION = [
  { label: "0.01% floor", share: 31.4, tone: "benign" },
  { label: "0.01 – 0.05%", share: 18.2, tone: "base" },
  { label: "0.05 – 0.10%", share: 24.7, tone: "base" },
  { label: "0.10 – 0.40%", share: 17.1, tone: "warm" },
  { label: "0.40 – 1.00%", share: 8.1, tone: "warm" },
  { label: "at the 1.00% cap", share: 0.5, tone: "hot" },
] as const;

/**
 * Scatter points for the Markets chart: one per notional `SwapAssayed`. `x` is position in the
 * window (0–1); `feePips` is the quote. Held as data rather than baked into SVG so the chart
 * component owns its own geometry.
 */
export const SCATTER: { x: number; feePips: number; capturing: boolean }[] = [
  { x: 0.03, feePips: 100, capturing: false },
  { x: 0.066, feePips: 500, capturing: false },
  { x: 0.09, feePips: 1_180, capturing: true },
  { x: 0.126, feePips: 100, capturing: false },
  { x: 0.149, feePips: 620, capturing: false },
  { x: 0.18, feePips: 1_900, capturing: true },
  { x: 0.213, feePips: 130, capturing: false },
  { x: 0.239, feePips: 2_820, capturing: true },
  { x: 0.269, feePips: 500, capturing: false },
  { x: 0.294, feePips: 100, capturing: false },
  { x: 0.326, feePips: 1_640, capturing: true },
  { x: 0.356, feePips: 480, capturing: false },
  { x: 0.383, feePips: 10_000, capturing: true },
  { x: 0.406, feePips: 110, capturing: false },
  { x: 0.431, feePips: 540, capturing: false },
  { x: 0.459, feePips: 980, capturing: true },
  { x: 0.491, feePips: 100, capturing: false },
  { x: 0.517, feePips: 1_760, capturing: true },
  { x: 0.544, feePips: 500, capturing: false },
  { x: 0.577, feePips: 120, capturing: false },
  { x: 0.604, feePips: 2_480, capturing: true },
  { x: 0.63, feePips: 520, capturing: false },
  { x: 0.66, feePips: 105, capturing: false },
  { x: 0.689, feePips: 10_000, capturing: true },
  { x: 0.716, feePips: 700, capturing: false },
  { x: 0.746, feePips: 1_540, capturing: true },
  { x: 0.777, feePips: 115, capturing: false },
  { x: 0.803, feePips: 495, capturing: false },
  { x: 0.833, feePips: 2_100, capturing: true },
  { x: 0.863, feePips: 108, capturing: false },
  { x: 0.889, feePips: 510, capturing: false },
  { x: 0.916, feePips: 1_420, capturing: true },
  { x: 0.946, feePips: 125, capturing: false },
  { x: 0.974, feePips: 500, capturing: false },
];
