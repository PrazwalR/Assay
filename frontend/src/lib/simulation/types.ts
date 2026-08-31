/**
 * Simulation types.
 *
 * The single most important idea here is `DataOrigin`. Every number this feature displays is
 * tagged with where it came from, and the UI renders that tag beside it. A judge — or anyone —
 * must be able to tell at a glance whether a figure was computed or read from a chain, without
 * being told. Blurring the two is the one failure this whole feature cannot survive.
 */

export type DataOrigin =
  /** Computed by the engine from the real protocol libraries. Not yet on chain. */
  | "projected"
  /** Read from, or produced by, a real transaction on Base Sepolia. */
  | "live-testnet";

export type StageId =
  | "idle"
  | "dislocate"
  | "opportunity"
  | "calculate"
  | "construct"
  | "submit"
  | "confirm"
  | "settle"
  | "result";

export type StageStatus = "pending" | "active" | "done" | "failed";

export interface Stage {
  id: StageId;
  /** Short label for the timeline rail. */
  label: string;
  /** One plain sentence, for someone with no blockchain background. */
  plain: string;
  status: StageStatus;
  /** Set once a stage produces or consumes a real transaction. */
  txHash?: `0x${string}`;
  error?: string;
}

/** What the operator can vary. Kept small: every knob has to stay internally consistent. */
export interface ScenarioInput {
  /**
   * How far to push the pool off its reference, in USDC of size. The engine derives the
   * resulting drift from the real curve rather than being told a percentage — so the
   * dislocation shown is the dislocation the chain will actually produce.
   */
  dislocationUsdc: number;
  /** Fraction of the restorable drift the arbitrageur takes. 1 = close the gap fully. */
  captureFraction: number;
}

export interface PoolSnapshot {
  sqrtPriceX96: bigint;
  tick: number;
  /** Virtual reserves implied by the curve at this price, in each token's base units. */
  reserve0: bigint;
  reserve1: bigint;
  /** USDC per WETH. */
  priceUsd: number;
}

export interface ArbitrageLeg {
  /** True when selling currency0 (USDC) for currency1 (WETH). */
  zeroForOne: boolean;
  amountIn: bigint;
  amountOut: bigint;
  /** The hook's quote for this leg, in pips. */
  feePips: number;
  /** Drift the leg is priced against, signed for its own direction. */
  driftTicks: number;
  priceImpact: number;
}

export interface Economics {
  /** Value the arbitrageur puts in, in USD. */
  costUsd: number;
  /** Value they take out, in USD. */
  proceedsUsd: number;
  /** Proceeds less cost, before gas. */
  grossProfitUsd: number;
  gasUsd: number;
  netProfitUsd: number;
  /** What the hook charged, in USD — the part that stays with liquidity. */
  feeToLpUsd: number;
  /** The same trade priced by a flat-fee hook, for the comparison panel. */
  flatFeeToLpUsd: number;
}

export interface Scenario {
  input: ScenarioInput;

  /** Before anything happens. */
  initial: PoolSnapshot;
  /** After the dislocating trade — the mispriced state the arbitrageur sees. */
  dislocated: PoolSnapshot;
  /** After the arbitrage closes the gap. */
  restored: PoolSnapshot;

  /** The reference the hook prices against, in USD and ticks. */
  referenceUsd: number;
  referenceTick: number;

  /** Spread between pool and reference, as a fraction, before and after the arbitrage. */
  spreadBefore: number;
  spreadAfter: number;

  dislocationLeg: ArbitrageLeg;
  arbitrageLeg: ArbitrageLeg;
  economics: Economics;

  /** True when the engine could not build a coherent scenario from the live pool. */
  unavailable?: string;
}

/** A real transaction the simulation submitted, and what came back. */
export interface ExecutedTx {
  label: string;
  hash: `0x${string}`;
  status: "pending" | "success" | "reverted";
  gasUsed?: bigint;
  effectiveGasPrice?: bigint;
  blockNumber?: bigint;
  /** Decoded Assay events, in emission order. */
  events: DecodedEvent[];
}

export interface DecodedEvent {
  name: string;
  args: Record<string, string>;
}
