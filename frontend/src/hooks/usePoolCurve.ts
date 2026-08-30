"use client";

import { keccak256, encodePacked, toHex } from "viem";
import { useReadContracts } from "wagmi";

import { BASE_SEPOLIA_CHAIN_ID, POOL, POOL_MANAGER, POOL_RANGE } from "@/lib/protocol/config";
import { POOL_MANAGER_ABI } from "@/lib/protocol/abi";
import { sqrtPriceAtTick, type PoolCurve } from "@/lib/protocol/swapMath";

/**
 * The pool's actual price and liquidity, read straight from the PoolManager's storage.
 *
 * v4 keeps pool state in a singleton and exposes it through `extsload` rather than through
 * getters, so this computes the storage slots the way `StateLibrary` does:
 *
 *   base      = keccak256(poolId ++ bytes32(6))    // POOLS_SLOT = 6
 *   base + 0  = slot0        (sqrtPriceX96 | tick | protocolFee | lpFee, packed)
 *   base + 3  = liquidity    // LIQUIDITY_OFFSET = 3
 *
 * Both slots were verified against the live pool: slot0 decodes to tick 198290 matching the
 * hook's own `lastTick`, and liquidity to 781101333179 matching what the deploy script added.
 *
 * This is what makes an honest quote possible. Without the real price and liquidity there is no
 * curve to walk, and the interface can only guess from a spot ratio — which is exactly the
 * defect that made it overstate output by a quarter on a large trade.
 */

const POOLS_SLOT = 6n;

function poolStateSlot(poolId: `0x${string}`, offset: bigint): `0x${string}` {
  const base = BigInt(
    keccak256(encodePacked(["bytes32", "bytes32"], [poolId, toHex(POOLS_SLOT, { size: 32 })])),
  );
  return toHex(base + offset, { size: 32 });
}

export interface LivePoolCurve {
  isLive: boolean;
  curve: PoolCurve | undefined;
  /** The pool's own tick, decoded from slot0 — the price the swap will actually execute at. */
  tick: number | undefined;
}

export function usePoolCurve(): LivePoolCurve {
  const { data } = useReadContracts({
    contracts: [
      {
        address: POOL_MANAGER,
        abi: POOL_MANAGER_ABI,
        functionName: "extsload",
        args: [poolStateSlot(POOL.id, 0n)],
        chainId: BASE_SEPOLIA_CHAIN_ID,
      },
      {
        address: POOL_MANAGER,
        abi: POOL_MANAGER_ABI,
        functionName: "extsload",
        args: [poolStateSlot(POOL.id, 3n)],
        chainId: BASE_SEPOLIA_CHAIN_ID,
      },
    ],
    // Fast enough that a quote is never badly stale, slow enough not to hammer a public RPC.
    query: { refetchInterval: 12_000 },
  });

  const slot0 = data?.[0]?.status === "success" ? data[0].result : undefined;
  const liquidityWord = data?.[1]?.status === "success" ? data[1].result : undefined;

  if (slot0 === undefined || liquidityWord === undefined) {
    return { isLive: false, curve: undefined, tick: undefined };
  }

  const packed = BigInt(slot0);
  const sqrtPriceX96 = packed & ((1n << 160n) - 1n);
  // The tick is a signed 24-bit field; the high bit means negative.
  const rawTick = (packed >> 160n) & ((1n << 24n) - 1n);
  const tick = Number(rawTick >= 1n << 23n ? rawTick - (1n << 24n) : rawTick);

  const liquidity = BigInt(liquidityWord);

  // A pool with no price is a pool that was never initialised; quoting against it is meaningless.
  if (sqrtPriceX96 === 0n) return { isLive: false, curve: undefined, tick: undefined };

  return {
    isLive: true,
    tick,
    curve: {
      sqrtPriceX96,
      liquidity,
      sqrtPriceLowerX96: sqrtPriceAtTick(POOL_RANGE.tickLower),
      sqrtPriceUpperX96: sqrtPriceAtTick(POOL_RANGE.tickUpper),
    },
  };
}
