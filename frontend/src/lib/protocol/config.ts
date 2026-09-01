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
   * Deployed from the audited source: reference now refreshes in `beforeSwap`, the surcharge
   * is capped at 2% of notional, the oracle read carries a gas stipend, and a stuck chain is
   * detected and distrusted. 12,203 bytes on chain against 12,203 compiled. The previous
   * deployment at 0x4A20EB2C… predates all of it — see `audits/` and `SECURITY.md`.
   */
  hook: "0xc825ad661BA0398eF9Cf809E6635528C9aa370c4",
  oracleAdapter: "0x56757460c56104aBD30a7783e7Ac0dcE380F0d38",
  chainlinkEthUsd: "0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1",
} as const;

/**
 * The live pool. USDC/WETH on Base Sepolia, dynamic fee, tick spacing 60 — the only pool that
 * exists, because the hook refuses any pair its oracle does not price.
 */
export const POOL = {
  id: "0x1b4f8ca171d62e2acd6c815e4607e9ff771d48a2e540ec7cc12e0e1c984684ee",
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
export const POOL_RANGE = { tickLower: 192_180, tickUpper: 204_180 } as const;

export const ROUTERS = {
  swap: "0x0DFA8a0e1CaC977015cc7D214380AeB24FE766d5",
  liquidity: "0x853639EabeEa5a9DacC60D2e568674857F4e6A00",
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
  ordinarySwap: 16_180,
  ordinaryBudget: 20_000,
  blockBoundary: 36_349,
  blockBoundaryWithLiveFeed: 52_849,
  blockBoundaryBudget: 55_000,
  extremeDislocation: 28_617,
  extremeBudget: 55_000,
  chainlinkRead: 20_774,
} as const;

export const EXPLORER = "https://sepolia.basescan.org";

export const explorerAddress = (address: string) => `${EXPLORER}/address/${address}`;

/** Shortens an address for display. Never used as an identity — see `sender` in the event log. */
export const shortAddress = (address: string) =>
  `${address.slice(0, 6)}…${address.slice(-4)}`;
