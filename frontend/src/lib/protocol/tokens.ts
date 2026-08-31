import { POOL } from "./config";

/**
 * The two tokens the pool actually holds.
 *
 * These replaced fixture stand-ins once the pool went live. Decimals are the important field
 * and they differ — USDC is 6 and WETH is 18 — so every amount crossing the wire has to be
 * scaled by the right one. Getting that wrong is a swap off by a factor of a trillion, which is
 * why nothing in this app parses an amount without consulting this table.
 */

export interface Token {
  address: `0x${string}`;
  symbol: string;
  name: string;
  glyph: string;
  color: string;
  decimals: number;
  /** How many fraction digits to show. Not the same as `decimals`: 18 would be unreadable. */
  displayDecimals: number;
  /** Fixed USD price, or null to derive from the live reference. */
  priceUsd: number | null;
}

export const CURRENCY0: Token = {
  address: POOL.currency0,
  symbol: "USDC",
  name: "USD Coin (Base Sepolia)",
  glyph: "USDC",
  color: "#6FB3E8",
  decimals: 6,
  displayDecimals: 2,
  priceUsd: 1,
};

export const CURRENCY1: Token = {
  address: POOL.currency1,
  symbol: "WETH",
  name: "Wrapped Ether",
  glyph: "WETH",
  color: "#C3C8D4",
  decimals: 18,
  displayDecimals: 5,
  priceUsd: null,
};

export const TOKENS: Record<string, Token> = {
  [CURRENCY0.symbol]: CURRENCY0,
  [CURRENCY1.symbol]: CURRENCY1,
};

export const TOKEN_KEYS = [CURRENCY0.symbol, CURRENCY1.symbol] as const;

/**
 * v4 encodes swap direction as `zeroForOne`, meaning "selling currency0". Deriving it from the
 * chosen token rather than tracking it separately means the two can never disagree — and that
 * flag is what flips the sign of the drift, so a disagreement would invert the entire fee.
 */
export const isZeroForOne = (tokenInSymbol: string) => tokenInSymbol === CURRENCY0.symbol;

/** Uniswap's price bounds, from `TickMath`. A swap is limited by liquidity, not by these. */
export const MIN_SQRT_PRICE = 4295128739n;
export const MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342n;

/** The limit to pass for an unbounded swap in a given direction. */
export const priceLimitFor = (zeroForOne: boolean) =>
  zeroForOne ? MIN_SQRT_PRICE + 1n : MAX_SQRT_PRICE - 1n;
