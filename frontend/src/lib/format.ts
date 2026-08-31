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
