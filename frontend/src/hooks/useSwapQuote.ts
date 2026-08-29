"use client";

import { useMemo } from "react";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { SLIPPAGE_OPTIONS } from "@/components/modals/SettingsModal";
import { TOKENS } from "@/lib/protocol/fixtures";
import { priceToTick, tickToPrice } from "@/lib/format";

/**
 * Everything the swap surface needs, derived once.
 *
 * The internal consistency rule from DESIGN-SPEC.md §8 is enforced here rather than trusted:
 * the pool price is *defined* as `reference / 1.0001^drift`, and every amount and USD figure
 * descends from it. There is no second source for any of these numbers, so they cannot
 * disagree with each other — a UI whose figures do not reconcile reads as fake to exactly the
 * audience this protocol needs.
 */
export function useSwapQuote() {
  const { drift, feePips, amountIn, tokenIn, tokenOut, slippageIndex, referenceFresh } = useAssay();
  const { referenceUsd } = useLiveProtocol();

  return useMemo(() => {
    const inToken = TOKENS[tokenIn];
    const outToken = TOKENS[tokenOut];

    // The pool sits `drift` ticks away from the reference; that gap is the whole signal.
    const poolPriceUsd = referenceUsd / tickToPrice(drift);

    const inPriceUsd = inToken.priceUsd ?? poolPriceUsd;
    const outPriceUsd = outToken.priceUsd ?? poolPriceUsd;

    const parsed = Number.parseFloat(amountIn);
    const amount = Number.isFinite(parsed) && parsed > 0 ? parsed : 0;

    // Rate in output units per input unit, from the two USD prices — so it reconciles with the
    // USD figures shown beneath each field by construction.
    const rate = outPriceUsd === 0 ? 0 : inPriceUsd / outPriceUsd;
    const grossOut = amount * rate;
    const netOut = grossOut * (1 - feePips / 1_000_000);

    const slippage = SLIPPAGE_OPTIONS[slippageIndex] ?? SLIPPAGE_OPTIONS[1];

    return {
      inToken,
      outToken,
      amount,
      insufficientBalance: amount > inToken.balance,
      poolPriceUsd,
      poolTick: priceToTick(poolPriceUsd),
      referenceTick: priceToTick(referenceUsd),
      amountInUsd: amount * inPriceUsd,
      rate,
      netOut,
      netOutUsd: netOut * outPriceUsd,
      minimumReceived: netOut * (1 - slippage),
      slippage,
      /** The fee actually deducted, in output units — what the percentage costs in real terms. */
      feePaidOut: grossOut - netOut,
      referenceFresh,
    };
  }, [
    drift,
    feePips,
    amountIn,
    tokenIn,
    tokenOut,
    slippageIndex,
    referenceUsd,
    referenceFresh,
  ]);
}
