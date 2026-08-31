import { MAX_SQRT_PRICE, MIN_SQRT_PRICE } from "./tokens";

/**
 * Turning a slippage tolerance into a price bound the chain will actually enforce.
 *
 * This exists because the interface was promising protection it never sent. The router
 * (`PoolSwapTest`) has no `amountOutMinimum` parameter at all, so the *only* bound available on
 * a v4 swap is `sqrtPriceLimitX96` — and the app was passing the absolute extremes, meaning
 * "execute at any price whatsoever". A "Minimum received" row was displayed above a swap that
 * could not revert no matter how badly it filled.
 *
 * On a pool this shallow that is not academic. The live pool holds roughly 38 USDC of depth, so
 * a 10 USDC swap moves the price about 20%. Unbounded, the user signs for whatever comes back.
 *
 * What the bound does: for exact-input, the swap consumes input until either the input runs out
 * or the price reaches this limit, whichever comes first. Hitting the limit produces a partial
 * fill with the remainder returned — never an execution worse than the limit. The *average*
 * price is strictly better than the limit, since the swap walks there from the current price,
 * so this errs toward filling rather than toward reverting.
 */

/**
 * 15 decimal digits of the multiplier, which is the most a JS `number` can carry into a `BigInt`
 * without losing integer precision (2^53 ≈ 9.007e15). More scale would silently round.
 */
const SCALE = 10n ** 15n;

export function sqrtPriceLimitX96(
  currentSqrtPriceX96: bigint,
  zeroForOne: boolean,
  slippage: number,
): bigint {
  // `sqrtPriceX96` is the square root of the price, so the tolerance applies under the root.
  const factor = Math.sqrt(zeroForOne ? 1 - slippage : 1 + slippage);
  const scaled = BigInt(Math.round(factor * Number(SCALE)));

  let limit = (currentSqrtPriceX96 * scaled) / SCALE;

  // A limit equal to the current price is "already exceeded" and reverts before any swapping
  // happens. Nudging by one unit keeps a zero or vanishing tolerance from bricking the trade.
  if (zeroForOne && limit >= currentSqrtPriceX96) limit = currentSqrtPriceX96 - 1n;
  if (!zeroForOne && limit <= currentSqrtPriceX96) limit = currentSqrtPriceX96 + 1n;

  // Uniswap rejects anything at or beyond its own bounds, so clamp rather than let a large
  // tolerance produce an out-of-range value the pool refuses outright.
  const floor = MIN_SQRT_PRICE + 1n;
  const ceiling = MAX_SQRT_PRICE - 1n;
  if (limit < floor) return floor;
  if (limit > ceiling) return ceiling;
  return limit;
}

/**
 * The price the swap is guaranteed not to execute beyond, as a human-readable ratio of the
 * current price. Used to show the user what their tolerance actually bought them.
 */
export function limitAsPriceRatio(
  currentSqrtPriceX96: bigint,
  limit: bigint,
): number {
  if (currentSqrtPriceX96 === 0n) return 1;
  const ratio = Number(limit) / Number(currentSqrtPriceX96);
  return ratio * ratio;
}
