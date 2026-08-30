"use client";

import { useMemo } from "react";
import { formatUnits, parseUnits } from "viem";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useLivePool } from "@/hooks/useLivePool";
import { usePoolCurve } from "@/hooks/usePoolCurve";
import { useTokenBalances } from "@/hooks/useTokenBalances";
import { SLIPPAGE_OPTIONS } from "@/components/modals/SettingsModal";
import { CURRENCY0, TOKENS, isZeroForOne } from "@/lib/protocol/tokens";
import { quote } from "@/lib/protocol/feeBlend";
import { quoteExactInput } from "@/lib/protocol/swapMath";
import { sqrtPriceLimitX96 } from "@/lib/protocol/slippage";

/**
 * The swap quote, derived from the pool's actual curve.
 *
 * Three defects shaped how this is written, all of them found by pointing the arithmetic at the
 * chain and comparing:
 *
 *  1. The output used to come from a spot USD ratio with no price-impact term. On a pool this
 *     shallow that overstated the output by 4% at the default size and 28% at a full balance,
 *     and the "Minimum received" line printed beneath it was above what the pool would pay.
 *     Output now walks the real curve (`quoteExactInput`), which reproduces chain simulations
 *     to the wei.
 *  2. `poolPriceUsd` divided where it should have multiplied. In this pool currency0 is USDC and
 *     currency1 is WETH, so the raw price is WETH-per-USDC and a *higher* tick means a *lower*
 *     ETH price — confirmed against the chain, where the cached reference tick 198261 is $2,455
 *     and a live $2,514 reading sits at tick 198,023. The sign error inflated every USD figure
 *     by `1.0001^(2·drift)`.
 *  3. The USD reference was read live while the drift was measured against the hook's *cached*
 *     reference tick, which can be many hours old. Mixing them silently assumed they were the
 *     same tick. USD figures are now anchored to the pool's own tick, which is the price a swap
 *     actually executes at, and the drift is used only for the fee — which is what it means.
 */
export function useSwapQuote() {
  const { drift: simulatedDrift, amountIn, tokenIn, tokenOut, slippageIndex } = useAssay();
  const { referenceUsd, bounds } = useLiveProtocol();
  const pool = useLivePool();
  const { curve, tick: poolTick, isLive: curveIsLive } = usePoolCurve();
  const balances = useTokenBalances();

  return useMemo(() => {
    const inToken = TOKENS[tokenIn] ?? CURRENCY0;
    const outToken = TOKENS[tokenOut] ?? CURRENCY0;
    const zeroForOne = isZeroForOne(inToken.symbol);

    // Drift decides the fee, and only the fee. It is the hook's own signed measurement.
    const chainDrift = pool.driftZeroForOne;
    const driftIsLive = chainDrift !== undefined;
    const drift = driftIsLive ? (zeroForOne ? chainDrift : -chainDrift) : simulatedDrift;
    const referenceFresh = driftIsLive ? pool.referenceFresh : true;
    const feePips = quote(drift, referenceFresh, bounds);

    // USD is anchored to the pool's own tick, not to the drift. currency1 (WETH) per currency0
    // (USDC) means ETH gets cheaper as the tick rises, hence the negative exponent.
    const ethUsdFromPool =
      poolTick === undefined ? referenceUsd : Math.pow(1.0001, -poolTick) * 1e12;
    const ethUsd = curveIsLive ? ethUsdFromPool : referenceUsd;

    const inPriceUsd = inToken.priceUsd ?? ethUsd;
    const outPriceUsd = outToken.priceUsd ?? ethUsd;

    // A half-typed number like "1." is not an amount yet, and is not an error either.
    let amountInUnits = 0n;
    try {
      amountInUnits = amountIn ? parseUnits(amountIn, inToken.decimals) : 0n;
    } catch {
      amountInUnits = 0n;
    }

    const amount = Number(formatUnits(amountInUnits, inToken.decimals));
    const balanceInUnits = zeroForOne ? balances.currency0 : balances.currency1;
    const balanceOutUnits = zeroForOne ? balances.currency1 : balances.currency0;

    // The curve, or nothing. A quote without the pool's real state would be a guess, and this
    // interface has already shipped one of those.
    const swap = curve
      ? quoteExactInput(curve, amountInUnits, feePips, zeroForOne)
      : undefined;

    const netOutUnits = swap?.amountOut ?? 0n;
    const netOut = Number(formatUnits(netOutUnits, outToken.decimals));
    const slippage = SLIPPAGE_OPTIONS[slippageIndex] ?? SLIPPAGE_OPTIONS[1];

    // Floored, not rounded. A minimum that rounds up is not a minimum — the displayed figure
    // was previously above what the chain would pay for exactly this reason.
    const minimumReceivedUnits =
      (netOutUnits * BigInt(Math.round((1 - slippage) * 1_000_000))) / 1_000_000n;
    const minimumReceived = Number(formatUnits(minimumReceivedUnits, outToken.decimals));

    // The bound actually sent to the chain, so what is displayed and what is enforced agree.
    const priceLimit = curve
      ? sqrtPriceLimitX96(curve.sqrtPriceX96, zeroForOne, slippage)
      : undefined;

    // Realised rate, from the curve — not spot. This is what the user will actually get.
    const rate = amount > 0 && netOut > 0 ? netOut / amount : 0;

    return {
      inToken,
      outToken,
      zeroForOne,
      drift,
      driftIsLive,
      referenceFresh,
      feePips,

      amount,
      amountInUnits,
      balanceInUnits,
      balanceOutUnits,
      balanceIn:
        balanceInUnits === undefined
          ? undefined
          : Number(formatUnits(balanceInUnits, inToken.decimals)),
      balanceOut:
        balanceOutUnits === undefined
          ? undefined
          : Number(formatUnits(balanceOutUnits, outToken.decimals)),
      insufficientBalance: balanceInUnits !== undefined && amountInUnits > balanceInUnits,

      /** False until the pool's curve has loaded. Nothing should be quoted or signed before it. */
      quoteIsLive: curveIsLive && Boolean(swap),
      poolTick,
      referenceTick: pool.referenceTick,
      ethUsd,
      amountInUsd: amount * inPriceUsd,
      rate,
      netOut,
      netOutUsd: netOut * outPriceUsd,
      minimumReceived,
      slippage,
      priceLimit,
      priceImpact: swap?.priceImpact ?? 0,
      /** True when the trade would exhaust the seeded range, making the output a lower bound. */
      exceedsLiquidity: swap?.crossesRange ?? false,
      /** The fee in output units, derived by re-quoting at zero fee — not from a USD ratio. */
      feePaidOut: curve
        ? Number(
            formatUnits(
              quoteExactInput(curve, amountInUnits, 0, zeroForOne).amountOut - netOutUnits,
              outToken.decimals,
            ),
          )
        : 0,
      refetchBalances: balances.refetch,
    };
  }, [
    simulatedDrift,
    amountIn,
    tokenIn,
    tokenOut,
    slippageIndex,
    referenceUsd,
    bounds,
    pool.driftZeroForOne,
    pool.referenceFresh,
    pool.referenceTick,
    curve,
    poolTick,
    curveIsLive,
    balances.currency0,
    balances.currency1,
    balances.refetch,
  ]);
}
