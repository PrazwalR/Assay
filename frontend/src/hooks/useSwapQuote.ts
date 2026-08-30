"use client";

import { useMemo } from "react";
import { formatUnits, parseUnits } from "viem";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useLivePool } from "@/hooks/useLivePool";
import { useTokenBalances } from "@/hooks/useTokenBalances";
import { SLIPPAGE_OPTIONS } from "@/components/modals/SettingsModal";
import { CURRENCY0, TOKENS, isZeroForOne } from "@/lib/protocol/tokens";
import { quote } from "@/lib/protocol/feeBlend";
import { tickToPrice } from "@/lib/format";

/**
 * Everything the swap surface needs, derived once from real inputs.
 *
 * Two rules hold here and are the reason the figures reconcile. Amounts stay in base units until
 * the moment they are displayed — the two tokens have different decimals, and converting early
 * is how a comparison ends up between differently-scaled numbers. And the price is *defined* as
 * `reference / 1.0001^drift`, with every USD figure descending from it, so there is no second
 * source for any number and they cannot disagree.
 *
 * The drift is the pool's real drift when the chain answers, and the interactive control only
 * when it does not. That ordering matters: this is a quote, and a quote sourced from a slider
 * while the chain is available would be a demonstration wearing a quote's clothes.
 */
export function useSwapQuote() {
  const { drift: simulatedDrift, amountIn, tokenIn, tokenOut, slippageIndex } = useAssay();
  const { referenceUsd, bounds } = useLiveProtocol();
  const pool = useLivePool();
  const balances = useTokenBalances();

  return useMemo(() => {
    const inToken = TOKENS[tokenIn] ?? CURRENCY0;
    const outToken = TOKENS[tokenOut] ?? CURRENCY0;
    const zeroForOne = isZeroForOne(inToken.symbol);

    // The pool's own drift, signed for the direction actually being traded. Falls back to the
    // interactive value only when the chain has not answered.
    const chainDrift = pool.driftZeroForOne;
    const drift =
      chainDrift === undefined ? simulatedDrift : zeroForOne ? chainDrift : -chainDrift;
    const driftIsLive = chainDrift !== undefined;

    const referenceFresh = driftIsLive ? pool.referenceFresh : true;
    const feePips = quote(drift, referenceFresh, bounds);

    const poolPriceUsd = referenceUsd / tickToPrice(drift * (zeroForOne ? -1 : 1));
    const inPriceUsd = inToken.priceUsd ?? poolPriceUsd;
    const outPriceUsd = outToken.priceUsd ?? poolPriceUsd;

    // Parsing can throw on a partial entry like "1." — a half-typed number is not an error the
    // user should see, it is simply not an amount yet.
    let amountInUnits = 0n;
    try {
      amountInUnits = amountIn ? parseUnits(amountIn, inToken.decimals) : 0n;
    } catch {
      amountInUnits = 0n;
    }

    const amount = Number(formatUnits(amountInUnits, inToken.decimals));
    const balanceInUnits = zeroForOne ? balances.currency0 : balances.currency1;
    const balanceOutUnits = zeroForOne ? balances.currency1 : balances.currency0;

    const rate = outPriceUsd === 0 ? 0 : inPriceUsd / outPriceUsd;
    const grossOut = amount * rate;
    const netOut = grossOut * (1 - feePips / 1_000_000);
    const slippage = SLIPPAGE_OPTIONS[slippageIndex] ?? SLIPPAGE_OPTIONS[1];

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
      balanceIn: balanceInUnits === undefined ? undefined : Number(formatUnits(balanceInUnits, inToken.decimals)),
      balanceOut: balanceOutUnits === undefined ? undefined : Number(formatUnits(balanceOutUnits, outToken.decimals)),
      insufficientBalance: balanceInUnits !== undefined && amountInUnits > balanceInUnits,

      poolPriceUsd,
      poolTick: pool.poolTick,
      referenceTick: pool.referenceTick,
      amountInUsd: amount * inPriceUsd,
      rate,
      netOut,
      netOutUsd: netOut * outPriceUsd,
      minimumReceived: netOut * (1 - slippage),
      slippage,
      /** The fee actually deducted, in output units — what the percentage costs in real terms. */
      feePaidOut: grossOut - netOut,
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
    pool.poolTick,
    pool.referenceTick,
    balances.currency0,
    balances.currency1,
    balances.refetch,
  ]);
}
