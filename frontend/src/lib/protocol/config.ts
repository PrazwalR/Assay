import type { FeeParams } from "./feeBlend";

/**
 * Immutable facts about the deployment. Sourced from `.env`, `src/config/AssayConfig.sol`, and
 * `script/DeployAssay.s.sol` — not invented, and not duplicated anywhere else in the app.
 *
 * `feeBounds()` is read live from the hook at runtime (see hooks/useLiveProtocol.ts); the
 * values here are the fallback for server rendering and the first paint, and are asserted
 * against the live read so a drift between the two is visible rather than silent.
 */

export const BASE_SEPOLIA_CHAIN_ID = 84_532;

export const CONTRACTS = {
  /**
   * Deployed from the current source: 10,811 bytes on chain against 10,811 compiled, so the
   * deviation cap and everything else the audit covers is what is actually running. The
   * previous deployment at 0xa3A9901c… was 9,625 bytes and predated that work.
   */
  hook: "0x4A20EB2C6B928d4c153E4cDe2D7011ead9fCb0c4",
  oracleAdapter: "0xFA99bbD088EEc136b626aE98003240F12e851f98",
  chainlinkEthUsd: "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1",
} as const;

/**
 * The live pool. USDC/WETH on Base Sepolia, dynamic fee, tick spacing 60 — the only pool that
 * exists, because the hook refuses any pair its oracle does not price.
 */
export const POOL = {
  id: "0xbb01cc76d59b8baa0df9cabb9751df62d23adc3b4ad38f59822cd09be74707c2",
  currency0: "0x036CbD53842c5426634e7929541eC2318f3dCF7e",
  currency1: "0x4200000000000000000000000000000000000006",
  tickSpacing: 60,
} as const;

/**
 * Routers deployed alongside the pool. v4 has no canonical public swap router on this chain, and
 * a browser cannot drive `PoolManager.unlock` itself — the caller has to be a contract. These
 * are the v4-core reference implementations, deployed by `script/SetupPool.s.sol`.
 */
export const POOL_MANAGER = "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408" as const;

/**
 * The single seeded position's tick range, from `script/SetupPool.s.sol`. Liquidity is constant
 * across it, which is what makes a single-range curve quote exact rather than approximate.
 */
export const POOL_RANGE = { tickLower: 192_240, tickUpper: 204_240 } as const;

export const ROUTERS = {
  swap: "0x689E091c7411dB859915E3D8e9b37aee1dC343Ef",
  liquidity: "0xA0a08ed6bBa5c790c8FF296DE5006ffC672d8599",
} as const;

/**
 * v4's dynamic-fee sentinel. A pool key carrying this in its `fee` field is one whose fee the
 * hook overrides per swap — and the key must be reconstructed exactly, including this, or it
 * hashes to a different pool id and the swap hits a pool that does not exist.
 */
export const DYNAMIC_FEE_FLAG = 0x800000;

export const explorerTx = (hash: string) => `${EXPLORER}/tx/${hash}`;

/** The deployed `AssayConfig`. `captureShareBps` is calibrated; the rest are chosen bounds. */
export const DEPLOYED: FeeParams = {
  baseFeePips: 500,
  minFeePips: 100,
  maxFeePips: 10_000,
  captureShareBps: 1_000,
};

/** Hook permission bits, encoded in the mined CREATE2 address. */
export const PERMISSION_MASK = "0x30C4";

/**
 * Drift at which each bound starts binding, derived rather than hardcoded so they cannot fall
 * out of step with `DEPLOYED`. At 1,000 bps each tick adds 10 pips, so the 10,000-pip ceiling
 * binds at 950 ticks and the 100-pip floor at −40.
 */
const pipsPerTickAtShare = (100 * DEPLOYED.captureShareBps) / 10_000;
export const CAP_BINDS_AT_TICKS = Math.ceil(
  (DEPLOYED.maxFeePips - DEPLOYED.baseFeePips) / pipsPerTickAtShare,
);
export const FLOOR_BINDS_AT_TICKS = Math.floor(
  (DEPLOYED.minFeePips - DEPLOYED.baseFeePips) / pipsPerTickAtShare,
);

/**
 * Measured gas, from `docs/gas.md` and the assertions in `test/gas/HookOverhead.t.sol`.
 * Budgets are the documented ceilings, not aspirations.
 */
export const GAS = {
  ordinarySwap: 14_920,
  ordinaryBudget: 20_000,
  blockBoundary: 34_337,
  blockBoundaryWithLiveFeed: 50_837,
  blockBoundaryBudget: 55_000,
  extremeDislocation: 49_253,
  extremeBudget: 55_000,
  chainlinkRead: 20_774,
} as const;

export const EXPLORER = "https://sepolia.basescan.org";

export const explorerAddress = (address: string) => `${EXPLORER}/address/${address}`;

/** Shortens an address for display. Never used as an identity — see `sender` in the event log. */
export const shortAddress = (address: string) =>
  `${address.slice(0, 6)}…${address.slice(-4)}`;
