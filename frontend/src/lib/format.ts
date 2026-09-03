/**
 * Number formatting. Centralised because inconsistent formatting between two surfaces reads
 * as two different numbers, and every figure here is meant to reconcile.
 */

export const num = (value: number, decimals: number) =>
  value.toLocaleString("en-US", {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });

export const usd = (value: number) => `$${num(value, 2)}`;

/**
 * A token amount destined for the amount *input*, not for display.
 *
 * Two differences from `num`, both of which break the field otherwise: no grouping separators,
 * because `parseUnits("1,234.5")` throws; and trailing zeros stripped, because "0.00697000" is
 * correct but reads as machine output in a box the user is about to type into.
 */
export const inputAmount = (value: number, decimals: number) => {
  if (!Number.isFinite(value) || value <= 0) return "";
  const fixed = value.toFixed(decimals);
  return fixed.includes(".") ? fixed.replace(/0+$/, "").replace(/\.$/, "") : fixed;
};

/**
 * A token amount that may be far smaller than its display precision.
 *
 * `num(value, displayDecimals)` is right for balances and outputs, where the token's own
 * convention is what a trader expects to read. It is wrong for a fee: a 1 bp charge on a
 * 0.00189 WETH output is 0.000000189 WETH, which renders as "0.00000" at WETH's five places and
 * reads as *free* -- on the one panel whose entire subject is what the swap is being charged.
 *
 * So precision follows the magnitude rather than the token, the same way `formatGasCostUsd`
 * handles sub-cent gas. A genuine zero still prints as "0": nothing here invents a charge that
 * is not there.
 */
export const tokenAmount = (value: number, displayDecimals: number) => {
  if (value === 0) return "0";
  const magnitude = Math.abs(value);
  if (magnitude >= 10 ** -displayDecimals) return num(value, displayDecimals);
  // Below the token's own precision, keep three significant figures so the number stays a
  // number. `toPrecision` gives exponent form for very small values; expand it.
  return Number(value.toPrecision(3)).toLocaleString("en-US", { maximumFractionDigits: 20 });
};

/** Compact USD for metric tiles, where four significant figures is the useful resolution. */
export const usdCompact = (value: number) => {
  if (value >= 1e6) return `$${(value / 1e6).toFixed(2)}M`;
  if (value >= 1e3) return `$${(value / 1e3).toFixed(1)}K`;
  return `$${value.toFixed(2)}`;
};

export const int = (value: number) => Math.round(value).toLocaleString("en-US");

export const signed = (value: number) =>
  `${value > 0 ? "+" : ""}${value.toLocaleString("en-US")}`;

/** Fee pips to basis points, the unit a trader compares against other pools. */
export const pipsToBp = (pips: number) => `${(pips / 100).toFixed(2)} bp`;

/** Fee pips to a percentage, the unit shown on the swap card itself. */
export const pipsToPct = (pips: number) => `${(pips / 10_000).toFixed(4)}%`;

/**
 * Tick from price. A tick is a log price step of 1.0001, which is what makes tick differences
 * directly comparable as basis points without any transcendental arithmetic on chain.
 */
export const priceToTick = (price: number) => Math.round(Math.log(price) / Math.log(1.0001));

export const tickToPrice = (tick: number) => Math.pow(1.0001, tick);

/**
 * Formats a wagmi v3 balance. v3 returns `{ value: bigint, decimals }` with no `formatted`
 * field, so the conversion lives here rather than being repeated at each call site.
 */
export const formatBalance = (
  balance: { value: bigint; decimals: number; symbol: string } | undefined,
  places = 4,
) => {
  if (!balance) return "—";
  const whole = Number(balance.value) / 10 ** balance.decimals;
  return `${num(whole, places)} ${balance.symbol}`;
};
