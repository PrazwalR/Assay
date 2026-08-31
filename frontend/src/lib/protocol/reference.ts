/**
 * Reference-price decoding, extracted from the hook so it can be tested without React.
 *
 * This got it wrong once — a naive `1 / price` on the square-root price, which ignores that the
 * adapter's ratio carries both tokens' decimal scaling. For the deployed 6/18-decimal pair that
 * is wrong by twelve orders of magnitude, and it displayed `$0.00` while still claiming "live".
 * The test beside this file pins it against a real on-chain reading.
 */

const Q96 = 2 ** 96;

/**
 * Chainlink USD feeds report 8 decimals, and the adapter's `PRICE_NUMERATOR` is built as
 * `10 ** (dec1 - dec0 + feedDecimals)` — so recovering the feed's own answer from the numerator
 * requires knowing this. Verified against the deployed ETH/USD aggregator, whose `decimals()`
 * returns 8.
 */
export const FEED_DECIMALS = 8;

/**
 * Recovers the feed's USD answer from the adapter's square-root price.
 *
 *   price  = (sqrtPriceX96 / 2^96)^2      raw token ratio, decimals included
 *   answer = PRICE_NUMERATOR / price      the feed's own integer answer
 *   usd    = answer / 10^FEED_DECIMALS
 */
export function referenceUsdFrom(
  sqrtPriceX96: bigint,
  priceNumerator: bigint | undefined,
  fallback: number,
): number {
  if (!priceNumerator) return fallback;

  const sqrtPrice = Number(sqrtPriceX96) / Q96;
  const rawRatio = sqrtPrice * sqrtPrice;
  if (rawRatio === 0) return fallback;

  return Number(priceNumerator) / rawRatio / 10 ** FEED_DECIMALS;
}
