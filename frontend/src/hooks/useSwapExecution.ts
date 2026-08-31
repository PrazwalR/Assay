"use client";

import { useCallback, useEffect, useState } from "react";
import {
  useAccount,
  useReadContract,
  useSwitchChain,
  useWaitForTransactionReceipt,
  useWriteContract,
} from "wagmi";

import { ERC20_ABI, SWAP_ROUTER_ABI } from "@/lib/protocol/abi";
import {
  BASE_SEPOLIA_CHAIN_ID,
  CONTRACTS,
  DYNAMIC_FEE_FLAG,
  POOL,
  ROUTERS,
} from "@/lib/protocol/config";
import { TOKENS, isZeroForOne, priceLimitFor } from "@/lib/protocol/tokens";

/**
 * Executing a swap, as an explicit state machine.
 *
 * A v4 swap from a browser is two transactions, not one: an ERC-20 approval to the router, then
 * the swap itself. Modelling that as a union rather than a pile of booleans is what keeps the
 * UI from showing "confirming" and "insufficient allowance" at the same time, and makes the
 * question the button has to answer — what do I do next — a single lookup.
 *
 * The router is a contract because it has to be. v4 routes everything through
 * `PoolManager.unlock` and a callback, which an externally-owned account cannot perform; the
 * router runs that dance and pulls the input token from `msg.sender`. That is why the allowance
 * is granted to the router and never to the PoolManager.
 */

export type SwapStage =
  | "disconnected"
  | "wrong-network"
  | "enter-amount"
  | "loading"
  | "insufficient-balance"
  | "needs-approval"
  | "approving"
  | "ready"
  | "swapping"
  | "confirmed"
  | "failed";

export interface SwapExecution {
  stage: SwapStage;
  /** True once the transaction is submitted and we are waiting on the chain, not the wallet. */
  isMining: boolean;
  /** Present in `failed`. Already trimmed to something a person can read. */
  error: string | undefined;
  /** Hash of whichever transaction is in flight or just settled. */
  hash: `0x${string}` | undefined;
  /** The action the primary button should take in the current stage, if any. */
  act: (() => void) | undefined;
  /** Clears a terminal state so the card returns to quoting. */
  reset: () => void;
}

/** Wallet rejections are long and stack-y; the first line is the part worth showing. */
function readableError(error: Error | null): string | undefined {
  if (!error) return undefined;
  if (/user rejected|denied transaction|rejected the request/i.test(error.message)) {
    return "Transaction rejected in your wallet.";
  }
  const first = error.message.split("\n")[0].trim();
  // Never return "": the stage reducer treats a falsy message as "no error", which turned a
  // revert whose reason decoded to nothing into a permanent spinner.
  if (!first) return "The transaction failed without a reason the wallet could decode.";
  return first.length > 160 ? `${first.slice(0, 157)}…` : first;
}

export function useSwapExecution(params: {
  tokenInSymbol: string;
  /** Input amount in the input token's base units. Zero means "nothing entered". */
  amountIn: bigint;
  balanceIn: bigint | undefined;
  /**
   * The price bound to enforce, from the live curve and the user's slippage tolerance.
   * `undefined` means the pool state has not loaded — in which case no swap is offered at all.
   * The router has no `amountOutMinimum`, so this is the only protection that exists; sending
   * the unbounded extreme (as this once did) means the displayed minimum is unenforceable.
   */
  priceLimit: bigint | undefined;
  onConfirmed: () => void;
}): SwapExecution {
  const { tokenInSymbol, amountIn, balanceIn, priceLimit, onConfirmed } = params;
  const { address, isConnected, chainId } = useAccount();
  const { switchChain } = useSwitchChain();

  // What the user last asked for. Set only in event handlers, never synced from an effect —
  // which is what lets every stage below be derived rather than mirrored into more state.
  const [intent, setIntent] = useState<"approve" | "swap" | null>(null);

  // False for a fixed window after an approval confirms, regardless of how fast the allowance
  // refetch lands. Needed because `approved` is derived from `allowance`, and even an
  // immediate refetch is a real network round trip — during it, `isSuccess` is already true
  // but `approved` is still stale-false, which without this flag falls through to
  // "needs-approval" and shows a clickable Approve button for that window. Starts `true`
  // ("no cooldown pending") and is set `false` in `approve()` itself — an event handler, not
  // an effect — so the effect below only ever needs to flip it back, from inside a timer
  // callback, never synchronously in its own body.
  const [approveCooldownElapsed, setApproveCooldownElapsed] = useState(true);

  const tokenIn = TOKENS[tokenInSymbol];
  const zeroForOne = isZeroForOne(tokenInSymbol);

  const { data: allowance, refetch: refetchAllowance } = useReadContract({
    address: tokenIn.address,
    abi: ERC20_ABI,
    functionName: "allowance",
    args: address ? [address, ROUTERS.swap] : undefined,
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: {
      enabled: Boolean(address),
      // Polls only while an approval is outstanding. That is how the machine notices the
      // approval landed, without an effect pushing state around to say so.
      refetchInterval: intent === "approve" ? 3_000 : false,
    },
  });

  const { writeContract, data: hash, error: writeError, reset: resetWrite } = useWriteContract();
  const {
    isLoading: isMining,
    isSuccess,
    error: receiptError,
  } = useWaitForTransactionReceipt({ hash, chainId: BASE_SEPOLIA_CHAIN_ID });

  const approved = allowance !== undefined && amountIn > 0n && allowance >= amountIn;

  // The one genuine external sync: a confirmed swap changes balances the chain owns, and this
  // tells the rest of the app to go and re-read them. It sets no state of its own.
  useEffect(() => {
    if (intent === "swap" && isSuccess) onConfirmed();
  }, [intent, isSuccess, onConfirmed]);

  // Without this, `allowance` only updates on its 3s poll tick, which is on its own clock, not
  // triggered by confirmation. Refetching immediately closes most of the gap; the cooldown
  // timer below closes the rest of it, since even an immediate refetch is a real round trip.
  useEffect(() => {
    if (intent === "approve" && isSuccess) void refetchAllowance();
  }, [intent, isSuccess, refetchAllowance]);

  // A fixed backstop, not a timing guess: whatever the refetch's actual latency turns out to
  // be, the button stays locked for this whole window regardless. The `approveCooldownElapsed`
  // guard keeps this from rescheduling once it has already fired for the current approval; the
  // state update itself happens inside the timer's callback, never synchronously in the effect
  // body. Re-fetches once more at the end in case the first attempt raced a node that hadn't
  // indexed the new allowance yet.
  useEffect(() => {
    if (intent !== "approve" || !isSuccess || approveCooldownElapsed) return;
    const timer = setTimeout(() => {
      setApproveCooldownElapsed(true);
      void refetchAllowance();
    }, 4_000);
    return () => clearTimeout(timer);
  }, [intent, isSuccess, approveCooldownElapsed, refetchAllowance]);

  const approve = useCallback(() => {
    setIntent("approve");
    setApproveCooldownElapsed(false);
    writeContract({
      address: tokenIn.address,
      abi: ERC20_ABI,
      functionName: "approve",
      args: [ROUTERS.swap, amountIn],
      chainId: BASE_SEPOLIA_CHAIN_ID,
    });
  }, [writeContract, tokenIn.address, amountIn]);

  const swap = useCallback(() => {
    // Refuse rather than fall back to an unbounded swap. A trade with no price bound on a pool
    // this shallow can fill arbitrarily badly and cannot revert.
    if (priceLimit === undefined) return;
    setIntent("swap");
    writeContract({
      address: ROUTERS.swap,
      abi: SWAP_ROUTER_ABI,
      functionName: "swap",
      args: [
        {
          currency0: POOL.currency0,
          currency1: POOL.currency1,
          // Must be the dynamic-fee sentinel, not the quoted fee: the key is hashed to find the
          // pool, so any other value addresses a pool that does not exist.
          fee: DYNAMIC_FEE_FLAG,
          tickSpacing: POOL.tickSpacing,
          hooks: CONTRACTS.hook,
        },
        {
          zeroForOne,
          // Negative is exact-input in v4. Positive would mean "give me exactly this much out",
          // which is a different trade and a different settlement path.
          amountSpecified: -amountIn,
          // Never the unbounded extreme. `swap` is unreachable while this is undefined.
          sqrtPriceLimitX96: priceLimit ?? priceLimitFor(zeroForOne),
        },
        { takeClaims: false, settleUsingBurn: false },
        "0x",
      ],
      chainId: BASE_SEPOLIA_CHAIN_ID,
    });
  }, [writeContract, zeroForOne, amountIn, priceLimit]);

  const reset = useCallback(() => {
    setIntent(null);
    setApproveCooldownElapsed(true);
    resetWrite();
    void refetchAllowance();
  }, [resetWrite, refetchAllowance]);

  const error = readableError(writeError) ?? readableError(receiptError);

  const stage = ((): SwapStage => {
    if (!isConnected) return "disconnected";
    // Only when nothing is in flight. Switching networks mid-transaction previously replaced the
    // whole panel, hiding a pending swap behind a "Switch network" button.
    if (chainId !== BASE_SEPOLIA_CHAIN_ID && intent === null) return "wrong-network";
    // `!== undefined` deliberately: an empty-string message is still a failure, and `if (error)`
    // let one through into a permanent silent hang.
    if (error !== undefined) return "failed";
    if (intent === "swap") return isSuccess ? "confirmed" : "swapping";
    // Only while an approval is genuinely outstanding. Previously this branch tested `!approved`
    // alone, which meant any later edit — flipping direction, changing token, clearing the
    // amount — re-entered a stage with no action and no exit but a page reload.
    // `!approveCooldownElapsed` covers the gap `isSuccess` alone misses: `approved` derives
    // from `allowance`, and even an immediate refetch is a real network round trip. Without
    // this, that round trip read as "needs-approval" and showed a clickable Approve button
    // that would fire a second on-chain approval before the first had visibly landed.
    if (intent === "approve" && !approved && (isMining || !isSuccess || !approveCooldownElapsed)) {
      return "approving";
    }
    if (amountIn <= 0n) return "enter-amount";
    if (balanceIn !== undefined && amountIn > balanceIn) return "insufficient-balance";
    // Distinguished from "no amount entered": a failed or pending allowance read used to render
    // "Enter an amount" over a filled field, with no error and no way to retry.
    if (allowance === undefined) return "loading";
    if (priceLimit === undefined) return "loading";
    if (!approved) return "needs-approval";
    return "ready";
  })();

  const act = ((): (() => void) | undefined => {
    if (stage === "wrong-network") return () => switchChain({ chainId: BASE_SEPOLIA_CHAIN_ID });
    if (stage === "needs-approval") return approve;
    if (stage === "ready") return swap;
    if (stage === "failed" || stage === "confirmed") return reset;
    return undefined;
  })();

  return {
    stage,
    isMining,
    error,
    hash,
    act,
    reset,
  };
}
