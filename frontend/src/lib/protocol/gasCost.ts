/**
 * Gas units → money.
 *
 * A gas figure on its own is not information a trader can act on. "14,920 gas" means nothing
 * without a gas price and an ETH price, and both of those are things this app can read rather
 * than assume — the gas price from the chain it is pointed at, the ETH price from the same
 * Chainlink adapter the hook itself prices against.
 *
 * Assuming a gas price is how estimates end up wrong by two orders of magnitude: Base currently
 * runs around 0.006 gwei and Ethereum mainnet around 0.05 gwei, both far below the 10–30 gwei
 * that older references quote.
 */

/**
 * Cost in USD of `gasUnits` at a given gas price and ETH price.
 *
 * @param gasUnits Gas consumed.
 * @param gasPriceWei Gas price in wei, as `eth_gasPrice` reports it.
 * @param ethUsd ETH price in USD.
 */
export function gasCostUsd(
  gasUnits: number,
  gasPriceWei: bigint | undefined,
  ethUsd: number,
): number | undefined {
  if (gasPriceWei === undefined) return undefined;
  // 1e18 wei per ETH. `Number` is safe here: a gas price is far below 2^53 wei, and the product
  // with a gas figure in the tens of thousands stays exact well inside float precision.
  return (gasUnits * Number(gasPriceWei) * ethUsd) / 1e18;
}

/**
 * Formats a gas cost for display.
 *
 * Sub-cent costs are the normal case now, so rounding to two decimals would render almost every
 * real figure as "$0.00" — which reads as "free" or as a bug, not as "very cheap". Precision is
 * chosen so a small number stays a number.
 */
export function formatGasCostUsd(cost: number | undefined): string {
  if (cost === undefined) return "—";
  if (cost === 0) return "$0";
  if (cost < 0.01) return `$${cost.toFixed(5)}`;
  if (cost < 1) return `$${cost.toFixed(3)}`;
  return `$${cost.toFixed(2)}`;
}
