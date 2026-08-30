"use client";

import { useReadContract } from "wagmi";

import { HOOK_ABI } from "@/lib/protocol/abi";
import { BASE_SEPOLIA_CHAIN_ID, CONTRACTS, POOL } from "@/lib/protocol/config";

/**
 * The pool's real state, read from the deployed hook.
 *
 * This became possible only once a pool existed. Before that the drift shown on this site was a
 * random walk — a demonstration of the mechanism rather than a reading of it. Now the two swaps
 * that created the pool's history are on chain, and `signedMispricing` returns the same signed
 * tick distance the hook itself would quote against.
 *
 * `isLive` is false while loading and false on failure, so nothing is ever labelled live
 * optimistically. Callers fall back to the interactive walk when it is false, which keeps the
 * page useful without ever claiming the fallback is a reading.
 */
export interface LivePool {
  isLive: boolean;
  /** Pool tick as of the last swap the hook observed. */
  poolTick: number | undefined;
  /** The cached reference tick the hook is pricing against. */
  referenceTick: number | undefined;
  referenceFresh: boolean;
  /** Signed drift for a zeroForOne swap. Negating it gives the other direction. */
  driftZeroForOne: number | undefined;
}

export function useLivePool(): LivePool {
  const { data: state } = useReadContract({
    address: CONTRACTS.hook,
    abi: HOOK_ABI,
    functionName: "poolState",
    args: [POOL.id],
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: { refetchInterval: 12_000 },
  });

  const { data: mispricing } = useReadContract({
    address: CONTRACTS.hook,
    abi: HOOK_ABI,
    functionName: "signedMispricing",
    args: [POOL.id, true],
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: { refetchInterval: 12_000 },
  });

  return {
    isLive: Boolean(state) && Boolean(mispricing),
    poolTick: state ? Number(state.lastTick) : undefined,
    referenceTick: state ? Number(state.referenceTick) : undefined,
    referenceFresh: state ? state.referenceFresh : false,
    driftZeroForOne: mispricing ? Number(mispricing[0]) : undefined,
  };
}
