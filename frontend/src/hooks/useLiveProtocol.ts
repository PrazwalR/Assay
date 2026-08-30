"use client";

import { useBlockNumber, useGasPrice, useReadContract } from "wagmi";

import { HOOK_ABI, ORACLE_ADAPTER_ABI } from "@/lib/protocol/abi";
import { BASE_SEPOLIA_CHAIN_ID, CONTRACTS, DEPLOYED } from "@/lib/protocol/config";
import { FALLBACK_REFERENCE_USD } from "@/lib/protocol/fixtures";
import type { FeeParams } from "@/lib/protocol/feeBlend";
import { referenceUsdFrom } from "@/lib/protocol/reference";

/**
 * The genuinely live surface — and its exact boundary.
 *
 * These reads work against the real deployment on Base Sepolia and are verified to respond.
 * The pool's own state is read separately in `useLivePool`. What remains a fixture is anything
 * requiring *history* — volume, fee revenue, the quote distribution — because the pool has been
 * traded twice and two swaps is not a distribution.
 *
 * `isLive` is what components gate their "live" badge on. It is false while loading and false
 * on any read failure, so the badge is never shown optimistically.
 */

export interface LiveProtocol {
  /** True only when every read below actually returned. */
  isLive: boolean;
  isLoading: boolean;
  /** Reference price in USD. Falls back to the fixture value until the read resolves. */
  referenceUsd: number;
  /** Whether the oracle itself reports its reading as usable. */
  referenceFresh: boolean;
  /** Fee bounds as reported by the deployed hook, not as assumed by this build. */
  bounds: FeeParams;
  /** True when the live bounds disagree with the compiled-in constants — worth surfacing. */
  boundsMatchConfig: boolean;
  blockNumber: bigint | undefined;
  /** Live gas price in wei. Assumed values are how gas estimates end up 100x wrong. */
  gasPriceWei: bigint | undefined;
}

export function useLiveProtocol(): LiveProtocol {
  const { data: blockNumber } = useBlockNumber({
    chainId: BASE_SEPOLIA_CHAIN_ID,
    watch: true,
  });

  const { data: gasPriceWei } = useGasPrice({
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: { refetchInterval: 30_000 },
  });

  const { data: feeBounds, isLoading: boundsLoading } = useReadContract({
    address: CONTRACTS.hook,
    abi: HOOK_ABI,
    functionName: "feeBounds",
    chainId: BASE_SEPOLIA_CHAIN_ID,
  });

  const { data: priceNumerator } = useReadContract({
    address: CONTRACTS.oracleAdapter,
    abi: ORACLE_ADAPTER_ABI,
    functionName: "PRICE_NUMERATOR",
    chainId: BASE_SEPOLIA_CHAIN_ID,
  });

  const { data: reference, isLoading: referenceLoading } = useReadContract({
    address: CONTRACTS.oracleAdapter,
    abi: ORACLE_ADAPTER_ABI,
    functionName: "referenceSqrtPriceX96",
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: { refetchInterval: 12_000 },
  });

  const bounds: FeeParams = feeBounds
    ? {
        baseFeePips: Number(feeBounds[0]),
        minFeePips: Number(feeBounds[1]),
        maxFeePips: Number(feeBounds[2]),
        // Not exposed by the deployed hook; it is a constructor immutable with no getter.
        captureShareBps: DEPLOYED.captureShareBps,
      }
    : DEPLOYED;

  const boundsMatchConfig =
    bounds.baseFeePips === DEPLOYED.baseFeePips &&
    bounds.minFeePips === DEPLOYED.minFeePips &&
    bounds.maxFeePips === DEPLOYED.maxFeePips;

  const referenceFresh = reference ? reference[1] : false;
  const referenceUsd =
    reference && reference[1]
      ? referenceUsdFrom(reference[0], priceNumerator, FALLBACK_REFERENCE_USD)
      : FALLBACK_REFERENCE_USD;

  return {
    isLive: Boolean(feeBounds) && Boolean(reference) && Boolean(priceNumerator),
    isLoading: boundsLoading || referenceLoading,
    referenceUsd,
    referenceFresh,
    bounds,
    boundsMatchConfig,
    blockNumber,
    gasPriceWei,
  };
}
