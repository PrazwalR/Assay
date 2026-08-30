"use client";

import { useAccount, useReadContracts } from "wagmi";

import { ERC20_ABI } from "@/lib/protocol/abi";
import { BASE_SEPOLIA_CHAIN_ID } from "@/lib/protocol/config";
import { CURRENCY0, CURRENCY1 } from "@/lib/protocol/tokens";

/**
 * Real ERC-20 balances for the connected wallet.
 *
 * Returned as raw `bigint` rather than a formatted number. Every amount in the swap path stays
 * in base units until the moment it is displayed: the two tokens have different decimals (6 and
 * 18), and converting early is how a comparison ends up between a number scaled one way and a
 * number scaled the other.
 */
export interface TokenBalances {
  isLoading: boolean;
  /** Base units. `undefined` when disconnected — which is not the same as zero. */
  currency0: bigint | undefined;
  currency1: bigint | undefined;
  /** Refetches after a swap or approval confirms, so the UI is not stale by one transaction. */
  refetch: () => void;
}

export function useTokenBalances(): TokenBalances {
  const { address } = useAccount();

  const { data, isLoading, refetch } = useReadContracts({
    contracts: [
      {
        address: CURRENCY0.address,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: address ? [address] : undefined,
        chainId: BASE_SEPOLIA_CHAIN_ID,
      },
      {
        address: CURRENCY1.address,
        abi: ERC20_ABI,
        functionName: "balanceOf",
        args: address ? [address] : undefined,
        chainId: BASE_SEPOLIA_CHAIN_ID,
      },
    ],
    query: { enabled: Boolean(address) },
  });

  return {
    isLoading,
    currency0: data?.[0]?.status === "success" ? data[0].result : undefined,
    currency1: data?.[1]?.status === "success" ? data[1].result : undefined,
    refetch: () => void refetch(),
  };
}
