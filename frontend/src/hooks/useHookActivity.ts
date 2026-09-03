"use client";

import { useEffect, useMemo, useState } from "react";
import { createPublicClient, http } from "viem";
import { baseSepolia } from "viem/chains";

import { CONTRACTS, HOOK_DEPLOY_BLOCK, POOL } from "@/lib/protocol/config";
import { ASSAY_EVENT_ABI } from "@/lib/protocol/events";

/**
 * Log scanning uses its own endpoint, not the app-wide one.
 *
 * A wide `eth_getLogs` and a point read are different products as far as an RPC provider is
 * concerned. `NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL` is set on the deployment to an Alchemy key,
 * which is the better endpoint for the `eth_call` reads the rest of the app makes -- and whose
 * free tier caps `eth_getLogs` at a **10 block range**, rejecting every chunk here with
 * `-32600`. That is why the activity feed worked on localhost, which falls back to the public
 * endpoint, and failed on the deployment.
 *
 * Base's public endpoint answers a 9,999-block range, so the scan is pinned to it and only
 * overridden by a variable set specifically for logs. Scanning 100,000 blocks ten at a time is
 * not a fallback worth writing -- it is 10,000 requests.
 */
const LOGS_RPC_URL = process.env.NEXT_PUBLIC_LOGS_RPC_URL ?? "https://sepolia.base.org";

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

/**
 * Ceiling on how many `eth_getLogs` round-trips one scan may cost.
 *
 * The scan starts at `HOOK_DEPLOY_BLOCK` rather than a rolling window back from head, because
 * a rolling window silently drops the pool's earliest swaps -- which is most of them, since
 * this pool is traded in bursts rather than continuously. An earlier revision looked back
 * three chunks and, once the chain had advanced ~80,000 blocks past deployment, showed 2 of
 * the 14 swaps on chain while the header still counted only what it had found.
 *
 * Base produces ~43,200 blocks a day, so this budget covers roughly nine days past deployment
 * before it binds. When it does bind the scan reports `truncated`, and the UI says so, rather
 * than presenting a partial history as a complete one. The real fix past that point is an
 * indexer, not a larger number here.
 */
const MAX_CHUNKS = 40;

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
  /**
   * True when the scan hit `MAX_CHUNKS` before reaching the head, so `swaps` is the tail of the
   * hook's history rather than all of it. Surfaced so the UI can stop calling it complete.
   */
  truncated: boolean;
}

export function useHookActivity(minFeePips: number): HookActivity {
  const client = useMemo(
    () => createPublicClient({ chain: baseSepolia, transport: http(LOGS_RPC_URL) }),
    [],
  );
  const [state, setState] = useState<HookActivity>({
    swaps: [],
    isLoading: true,
    error: undefined,
    truncated: false,
  });

  useEffect(() => {
    if (!client) return;
    let cancelled = false;

    (async () => {
      try {
        const latest = await client.getBlockNumber();

        // Start at deployment, not at a rolling offset from head: everything before the hook
        // existed is empty by construction, and anchoring to head is what previously hid the
        // pool's earliest swaps. `MAX_CHUNKS` bounds the cost instead.
        const from = HOOK_DEPLOY_BLOCK;

        const event = ASSAY_EVENT_ABI.find((e) => e.name === "SwapAssayed");
        if (!event) throw new Error("SwapAssayed missing from the event ABI");

        const collected: AssayedSwap[] = [];
        let chunks = 0;
        let truncated = false;
        let failed = 0;
        for (let start = from; start <= latest; start += CHUNK) {
          if (chunks >= MAX_CHUNKS) {
            truncated = true;
            break;
          }
          chunks += 1;
          const end = start + CHUNK - 1n > latest ? latest : start + CHUNK - 1n;

          // One bad window must not discard the windows that worked. A rate limit or a
          // provider-specific range rule can reject a single chunk, and losing every real swap
          // over it -- which is what the whole-scan try/catch used to do -- turns a partial
          // answer into "Could not read the hook's logs."
          let logs;
          try {
            logs = await client.getLogs({
              address: CONTRACTS.hook,
              event,
              args: { poolId: POOL.id },
              fromBlock: start,
              toBlock: end,
            });
          } catch {
            failed += 1;
            truncated = true;
            continue;
          }

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
        // Only a scan that returned nothing at all is an error. A partial one is a result, and
        // says so through `truncated`.
        const total = chunks - failed;
        setState({
          swaps: collected,
          isLoading: false,
          error: total === 0 ? "every log request was rejected" : undefined,
          truncated,
        });
      } catch (caught) {
        if (cancelled) return;
        setState({
          swaps: [],
          isLoading: false,
          error: caught instanceof Error ? caught.message.split("\n")[0] : String(caught),
          truncated: false,
        });
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [client, minFeePips]);

  return state;
}
