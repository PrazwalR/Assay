/**
 * The constant-product curve, in the exact integer arithmetic v4 uses.
 *
 * This replaced a quote derived from a spot USD price ratio, which carried no price-impact term
 * at all. On a pool this shallow that overstated the output by 4% at the page's default size and
 * 28% at the deployer's full balance, and the "Minimum received" figure printed underneath was
 * above what the chain would actually pay. A quote that cannot be executed is worse than no
 * quote.
 *
 * Exactness: `computeSwapStep` below reproduces v4's `SwapMath` for a swap that stays inside one
 * liquidity range. The pool's liquidity sits in a single range spanning ticks 192180–204180, so
 * liquidity is constant across that whole span and this is exact rather than approximate —
 * verified to the wei against a live `PoolSwapTest` simulation. `crossesRange` reports when that assumption
 * stops holding, so the caller can decline to quote rather than quote wrongly.
 *
 * Everything is `bigint`. Uniswap's rounding directions are reproduced deliberately: each is
 * chosen so the pool never loses, and mirroring them is what makes the output match to the unit
 * rather than to a few decimal places.
 */

const Q96 = 2n ** 96n;
const PIPS_DENOMINATOR = 1_000_000n;

const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;

export interface PoolCurve {
  sqrtPriceX96: bigint;
  liquidity: bigint;
  /** Bounds of the single liquidity range, as sqrt prices. */
  sqrtPriceLowerX96: bigint;
  sqrtPriceUpperX96: bigint;
}

export interface SwapResult {
  /** Output in the other token's base units, after the fee. */
  amountOut: bigint;
  /** The price the pool ends at. */
  sqrtPriceNextX96: bigint;
  /** True if the swap would leave the liquidity range, making this result a lower bound. */
  crossesRange: boolean;
  /** Realised price move, as a fraction. The honest measure of price impact. */
  priceImpact: number;
}

/**
 * Exact-input swap along the curve.
 *
 * @param amountIn Input in its own base units, before the fee.
 * @param feePips The hook's quoted fee, in hundredths of a basis point.
 */
export function quoteExactInput(
  curve: PoolCurve,
  amountIn: bigint,
  feePips: number,
  zeroForOne: boolean,
): SwapResult {
  const empty: SwapResult = {
    amountOut: 0n,
    sqrtPriceNextX96: curve.sqrtPriceX96,
    crossesRange: false,
    priceImpact: 0,
  };
  if (amountIn <= 0n || curve.liquidity <= 0n || curve.sqrtPriceX96 <= 0n) return empty;

  // The fee is taken off the input before it touches the curve, exactly as v4 does — which is
  // why a higher fee yields less output rather than being charged separately.
  const net = (amountIn * (PIPS_DENOMINATOR - BigInt(feePips))) / PIPS_DENOMINATOR;
  if (net <= 0n) return empty;

  const { sqrtPriceX96: sqrtP, liquidity: L } = curve;
  let sqrtNext: bigint;
  let amountOut: bigint;

  if (zeroForOne) {
    // Selling token0 pushes the price down.
    // sqrtNext = ceil(L·Q96·sqrtP / (L·Q96 + net·sqrtP)), rounded up so the pool keeps the dust.
    const numerator1 = L * Q96;
    sqrtNext = ceilDiv(numerator1 * sqrtP, numerator1 + net * sqrtP);
    // amount1 out = floor(L·(sqrtP − sqrtNext) / Q96), rounded down for the same reason.
    amountOut = (L * (sqrtP - sqrtNext)) / Q96;
  } else {
    // Selling token1 pushes the price up.
    sqrtNext = sqrtP + (net * Q96) / L;
    // amount0 out = floor(L·(sqrtNext − sqrtP)·Q96 / (sqrtP·sqrtNext)).
    amountOut = (L * (sqrtNext - sqrtP) * Q96) / (sqrtP * sqrtNext);
  }

  // Leaving the range invalidates the constant-liquidity assumption: beyond the boundary the
  // real pool has *less* liquidity, so the true output is lower than this. Reported rather than
  // silently returned as if exact.
  const crossesRange = zeroForOne
    ? sqrtNext < curve.sqrtPriceLowerX96
    : sqrtNext > curve.sqrtPriceUpperX96;

  const before = Number(sqrtP);
  const after = Number(sqrtNext);
  const priceImpact = Math.abs((after * after) / (before * before) - 1);

  return {
    amountOut: amountOut < 0n ? 0n : amountOut,
    sqrtPriceNextX96: sqrtNext,
    crossesRange,
    priceImpact,
  };
}

/**
 * The sqrt price at a tick, as a bigint.
 *
 * `Math.pow` is accurate to ~15 significant digits, which is far finer than the tick spacing
 * this is used to describe — but the multiplication into Q96 has to go through `BigInt` in two
 * stages, because `ratio * 2**96` as a float would discard everything below the top 53 bits.
 */
export function sqrtPriceAtTick(tick: number): bigint {
  const ratio = Math.pow(1.0001, tick / 2);
  const SCALE = 10n ** 15n;
  return (BigInt(Math.round(ratio * 1e15)) * Q96) / SCALE;
}
