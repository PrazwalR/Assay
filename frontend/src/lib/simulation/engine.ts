import type { FeeParams } from "@/lib/protocol/feeBlend";
import { DEPLOYED, GAS } from "@/lib/protocol/config";
import { quote } from "@/lib/protocol/feeBlend";
import { quoteExactInput, type PoolCurve } from "@/lib/protocol/swapMath";
import { gasCostUsd } from "@/lib/protocol/gasCost";
import type {
  ArbitrageLeg,
  Economics,
  PoolSnapshot,
  Scenario,
  ScenarioInput,
} from "./types";

/**
 * The simulation engine.
 *
 * This computes nothing of its own. Every figure comes from the same modules the live swap card
 * quotes from — `quoteExactInput` walks the real curve in v4's integer arithmetic, `quote` is
 * the port of `FeeBlend.sol` pinned to the shared Solidity fixture, `gasCostUsd` takes a live
 * gas price. That is the point of §20's layering: the simulation is an observability layer over
 * the protocol, not a second implementation of it. Swap the engine's inputs for chain reads and
 * the numbers do not change shape.
 *
 * What is genuinely modelled, and nothing more:
 *  - the *second* pool state, reached by applying a trade the user has not yet signed;
 *  - the arbitrageur's decision to take it.
 *
 * Both become real the moment the transactions are submitted, which is why the timeline
 * re-reads the chain afterwards rather than trusting these projections.
 */

const Q96 = 2n ** 96n;

/** USDC has 6 decimals, WETH 18 — the pool's two currencies, in that order. */
const USDC = 10 ** 6;
const WETH = 10 ** 18;

/**
 * ETH price implied by a tick.
 *
 * currency0 is USDC (6dp) and currency1 is WETH (18dp), so the pool's raw price is WETH-wei per
 * USDC-unit and a *higher* tick means a *cheaper* ETH. Verified against the chain: the cached
 * reference tick 198261 corresponds to $2,455, and a $2,514 reading sits at tick 198,023.
 */
export const ethUsdAtTick = (tick: number) => Math.pow(1.0001, -tick) * 1e12;

export const tickAtEthUsd = (usd: number) => Math.round(Math.log(1e12 / usd) / Math.log(1.0001));

/**
 * The hook's own sign convention, mirroring `Mispricing.signedTicks`: positive means this
 * direction trades *toward* the reference and therefore captures drift from liquidity.
 * Verified against the deployed hook, which returns +29 / −29 at pool tick 198290 against
 * reference tick 198261.
 */
export const signedDrift = (referenceTick: number, poolTick: number, zeroForOne: boolean) =>
  zeroForOne ? poolTick - referenceTick : referenceTick - poolTick;

/**
 * Virtual reserves at a price, from the curve. These are what a constant-product pool "holds"
 * at this point on its range — the quantity the before/after panel animates.
 */
function reservesAt(curve: PoolCurve, sqrtPriceX96: bigint): { reserve0: bigint; reserve1: bigint } {
  if (sqrtPriceX96 === 0n) return { reserve0: 0n, reserve1: 0n };
  return {
    // x = L / √P, y = L · √P
    reserve0: (curve.liquidity * Q96) / sqrtPriceX96,
    reserve1: (curve.liquidity * sqrtPriceX96) / Q96,
  };
}

function snapshot(curve: PoolCurve, sqrtPriceX96: bigint): PoolSnapshot {
  const ratio = Number(sqrtPriceX96) / Number(Q96);
  const tick = Math.round(Math.log(ratio * ratio) / Math.log(1.0001));
  return {
    sqrtPriceX96,
    tick,
    ...reservesAt(curve, sqrtPriceX96),
    priceUsd: ethUsdAtTick(tick),
  };
}

/**
 * Builds the whole scenario from the pool's live state.
 *
 * @param curve      The pool's real price and liquidity, read via `extsload`.
 * @param referenceTick The hook's cached reference tick — what it prices drift against.
 * @param gasPriceWei Live gas price, so the profitability figures are real money.
 */
export function buildScenario(
  curve: PoolCurve | undefined,
  referenceTick: number | undefined,
  gasPriceWei: bigint | undefined,
  input: ScenarioInput,
  /**
   * The hook's own bounds and freshness, read from chain. Defaulted to the compiled
   * constants so the pure tests stay terse, but the app passes the live values: a stale
   * reference makes the contract charge the ceiling, and a panel labelled "the fee the hook
   * will quote" has to agree with that rather than with this build's assumptions.
   */
  bounds: FeeParams = DEPLOYED,
  referenceFresh: boolean = true,
): Scenario | undefined {
  if (!curve || referenceTick === undefined) return undefined;

  const initial = snapshot(curve, curve.sqrtPriceX96);
  const referenceUsd = ethUsdAtTick(referenceTick);

  // --- Leg 1: push the pool off its reference -------------------------------------------
  //
  // Selling USDC drives the tick down, which *raises* the ETH price the pool quotes — the pool
  // becomes expensive relative to the reference, and the profitable correction is to sell ETH
  // back into it. This direction is also what the arbitrageur can afford: it produces the WETH
  // the second leg spends, so one account can perform both.
  //
  // In reality the *market* moves and the pool goes stale. We cannot move Chainlink, so the gap
  // is opened from the pool side instead. The economics of the resulting arbitrage are identical;
  // the UI says which side moved rather than implying the oracle did.
  const dislocationIn = BigInt(Math.max(1, Math.round(input.dislocationUsdc * USDC)));
  const dislocationDrift = signedDrift(referenceTick, initial.tick, true);
  const dislocationFee = quote(dislocationDrift, referenceFresh, bounds);
  const dislocationSwap = quoteExactInput(curve, dislocationIn, dislocationFee, true);

  if (dislocationSwap.amountOut === 0n) {
    return undefined;
  }
  if (dislocationSwap.crossesRange) {
    return {
      ...emptyScenario(input, initial, referenceUsd, referenceTick),
      unavailable:
        "That dislocation is larger than the pool's seeded range. Reduce the size — this pool holds roughly 38 USDC of depth.",
    };
  }

  const dislocated = snapshot(curve, dislocationSwap.sqrtPriceNextX96);
  const dislocatedCurve: PoolCurve = { ...curve, sqrtPriceX96: dislocationSwap.sqrtPriceNextX96 };

  const dislocationLeg: ArbitrageLeg = {
    zeroForOne: true,
    amountIn: dislocationIn,
    amountOut: dislocationSwap.amountOut,
    feePips: dislocationFee,
    driftTicks: dislocationDrift,
    priceImpact: dislocationSwap.priceImpact,
  };

  // --- Leg 2: the arbitrage -------------------------------------------------------------
  //
  // The pool now sits below the reference tick, so a oneForZero swap (selling WETH) walks the
  // tick back up toward it — capturing the drift on the way, which is exactly what the hook
  // surcharges. Sizing it from the WETH the first leg produced keeps this the trade an
  // arbitrageur would actually place rather than an arbitrary amount.
  const arbitrageDrift = signedDrift(referenceTick, dislocated.tick, false);
  const arbitrageFee = quote(arbitrageDrift, referenceFresh, bounds);

  // The WETH the previous leg produced is the natural size: it is exactly what is needed to
  // walk the price back, scaled by how much of the gap the arbitrageur chooses to close.
  const arbitrageIn = BigInt(
    Math.round(Number(dislocationSwap.amountOut) * Math.min(1, Math.max(0.01, input.captureFraction))),
  );
  const arbitrageSwap = quoteExactInput(dislocatedCurve, arbitrageIn, arbitrageFee, false);

  const restored = snapshot(curve, arbitrageSwap.sqrtPriceNextX96);

  const arbitrageLeg: ArbitrageLeg = {
    zeroForOne: false,
    amountIn: arbitrageIn,
    amountOut: arbitrageSwap.amountOut,
    feePips: arbitrageFee,
    driftTicks: arbitrageDrift,
    priceImpact: arbitrageSwap.priceImpact,
  };

  // --- Economics ------------------------------------------------------------------------
  //
  // Priced at the reference, not at the pool: the arbitrageur's alternative is the external
  // market, and that is what makes the trade worth doing at all.
  const wethIn = Number(arbitrageIn) / WETH;
  const usdcOut = Number(arbitrageSwap.amountOut) / USDC;
  const costUsd = wethIn * referenceUsd;
  const proceedsUsd = usdcOut;
  const grossProfitUsd = proceedsUsd - costUsd;

  // Two transactions: the swap itself, and its approval. The boundary path is the honest one —
  // the hook refreshes its oracle read on the first swap of a block, which a demo always is.
  const gasUnits = GAS.blockBoundaryWithLiveFeed + 46_000;
  const gasUsd = gasCostUsd(gasUnits, gasPriceWei, referenceUsd) ?? 0;

  // What the hook's surcharge actually routed to liquidity, and what a flat-fee pool would have
  // taken from the same trade. This pair is the comparison the whole feature exists to make.
  const feeToLpUsd = (proceedsUsd * arbitrageLeg.feePips) / 1_000_000;
  const flatFeeToLpUsd = (proceedsUsd * DEPLOYED.baseFeePips) / 1_000_000;

  const economics: Economics = {
    costUsd,
    proceedsUsd,
    grossProfitUsd,
    gasUsd,
    netProfitUsd: grossProfitUsd - gasUsd,
    feeToLpUsd,
    flatFeeToLpUsd,
  };

  return {
    input,
    initial,
    dislocated,
    restored,
    referenceUsd,
    referenceTick,
    spreadBefore: Math.abs(dislocated.priceUsd / referenceUsd - 1),
    spreadAfter: Math.abs(restored.priceUsd / referenceUsd - 1),
    dislocationLeg,
    arbitrageLeg,
    economics,
  };
}

function emptyScenario(
  input: ScenarioInput,
  initial: PoolSnapshot,
  referenceUsd: number,
  referenceTick: number,
): Scenario {
  const leg: ArbitrageLeg = {
    zeroForOne: true,
    amountIn: 0n,
    amountOut: 0n,
    feePips: DEPLOYED.baseFeePips,
    driftTicks: 0,
    priceImpact: 0,
  };
  return {
    input,
    initial,
    dislocated: initial,
    restored: initial,
    referenceUsd,
    referenceTick,
    spreadBefore: 0,
    spreadAfter: 0,
    dislocationLeg: leg,
    arbitrageLeg: leg,
    economics: {
      costUsd: 0,
      proceedsUsd: 0,
      grossProfitUsd: 0,
      gasUsd: 0,
      netProfitUsd: 0,
      feeToLpUsd: 0,
      flatFeeToLpUsd: 0,
    },
  };
}
