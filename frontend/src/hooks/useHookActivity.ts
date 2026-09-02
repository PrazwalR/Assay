"use client";

import { useEffect, useState } from "react";
import { usePublicClient } from "wagmi";

import { BASE_SEPOLIA_CHAIN_ID, CONTRACTS, HOOK_DEPLOY_BLOCK, POOL } from "@/lib/protocol/config";
import { ASSAY_EVENT_ABI } from "@/lib/protocol/events";

/**
 * Every swap this hook has ever priced, read from its own `SwapAssayed` logs.
 *
 * This exists because there is nowhere else to see it. A v4 hook is never the `to` address of
 * a transaction -- the PoolManager calls it internally during the swap -- so a block explorer's
 * "Transactions" tab for the hook is structurally empty and always will be. The activity is
 * real, it is just only visible as events.
 *
 * The fee alone identifies which side of the mechanism a swap landed on, with no extra reads:
 * at the floor it traded away from the reference and captured nothing; above the base fee it
 * traded toward the reference and paid for the drift it took.
 */

/**
 * Widest span the public Base Sepolia endpoint answers in one `eth_getLogs`.
 *
 * The endpoint rejects a range of exactly 10,000 with "eth_getLogs is limited to a 10,000
 * range", so the usable span is 9,999 blocks and this is the count, not the bound. Verified
 * against the live endpoint in both directions.
 */
const CHUNK = 9_999n;

/** How far back to look, in chunks. Three covers roughly a day of Base blocks. */
const MAX_CHUNKS = 3;

export interface AssayedSwap {
  txHash: `0x${string}`;
  blockNumber: bigint;
  logIndex: number;
  sender: `0x${string}`;
  feePips: number;
  /** True when the quote sits at the floor, meaning the swap traded away from the reference. */
  tradedAway: boolean;
}

export interface HookActivity {
  swaps: AssayedSwap[];
  isLoading: boolean;
  error: string | undefined;
}

export function useHookActivity(minFeePips: number): HookActivity {
  const client = usePublicClient({ chainId: BASE_SEPOLIA_CHAIN_ID });
  const [state, setState] = useState<HookActivity>({
    swaps: [],
    isLoading: true,
    error: undefined,
  });

  useEffect(() => {
    if (!client) return;
    let cancelled = false;

    (async () => {
      try {
        const latest = await client.getBlockNumber();

        // Never scan below the hook's own deployment: there is nothing there, and the span
        // would grow without bound as the chain advances.
        const floor =
          latest > CHUNK * BigInt(MAX_CHUNKS) ? latest - CHUNK * BigInt(MAX_CHUNKS) : 0n;
        const from = floor > HOOK_DEPLOY_BLOCK ? floor : HOOK_DEPLOY_BLOCK;

        const event = ASSAY_EVENT_ABI.find((e) => e.name === "SwapAssayed");
        if (!event) throw new Error("SwapAssayed missing from the event ABI");

        const collected: AssayedSwap[] = [];
        for (let start = from; start <= latest; start += CHUNK) {
          const end = start + CHUNK - 1n > latest ? latest : start + CHUNK - 1n;
          const logs = await client.getLogs({
            address: CONTRACTS.hook,
            event,
            args: { poolId: POOL.id },
            fromBlock: start,
            toBlock: end,
          });

          for (const log of logs) {
            const feePips = Number(log.args.feePips ?? 0);
            collected.push({
              txHash: log.transactionHash,
              blockNumber: log.blockNumber,
              logIndex: log.logIndex,
              sender: log.args.sender as `0x${string}`,
              feePips,
              tradedAway: feePips <= minFeePips,
            });
          }
        }

        if (cancelled) return;
        // Newest first. Block then log index, because a whole sequence can share one block --
        // which is exactly what happens when swaps are batched, and ordering within the block
        // is the part that shows the mechanism alternating.
        collected.sort((a, b) =>
          a.blockNumber === b.blockNumber
            ? b.logIndex - a.logIndex
            : Number(b.blockNumber - a.blockNumber),
        );
        setState({ swaps: collected, isLoading: false, error: undefined });
      } catch (caught) {
        if (cancelled) return;
        setState({
          swaps: [],
          isLoading: false,
          error: caught instanceof Error ? caught.message.split("\n")[0] : String(caught),
        });
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [client, minFeePips]);

  return state;
}
