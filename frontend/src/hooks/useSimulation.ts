"use client";

import { useCallback, useMemo, useState } from "react";
import { decodeEventLog } from "viem";
import {
  useAccount,
  useConfig,
  usePublicClient,
  useWriteContract,
} from "wagmi";
import { waitForTransactionReceipt } from "wagmi/actions";

import { ERC20_ABI, SWAP_ROUTER_ABI } from "@/lib/protocol/abi";
import {
  BASE_SEPOLIA_CHAIN_ID,
  CONTRACTS,
  DYNAMIC_FEE_FLAG,
  POOL,
  ROUTERS,
} from "@/lib/protocol/config";
import { ASSAY_EVENT_ABI } from "@/lib/protocol/events";
import { priceLimitFor } from "@/lib/protocol/tokens";
import { buildScenario } from "@/lib/simulation/engine";
import type { ExecutedTx, Scenario, ScenarioInput, Stage, StageId } from "@/lib/simulation/types";
import { usePoolCurve } from "@/hooks/usePoolCurve";
import { useLivePool } from "@/hooks/useLivePool";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";

/**
 * Runs the simulation.
 *
 * The two legs are *real transactions*. Nothing here fakes a hash, a receipt, or an event — the
 * only thing the simulation controls is that we cause the mispricing ourselves rather than
 * waiting for the market to. Everything downstream of that is the protocol behaving normally,
 * observed slowly.
 *
 * The sequence is deliberately serialised: each transaction is awaited to a receipt before the
 * next is built, because the second leg's fee depends on the pool state the first leg leaves
 * behind. Firing them together would quote the arbitrage against a pool that has not moved yet.
 */

const STAGE_ORDER: { id: StageId; label: string; plain: string }[] = [
  {
    id: "opportunity",
    label: "Opportunity detected",
    plain:
      "The pool's price has drifted away from the reference the hook prices against. Anyone can trade against that gap and keep the difference.",
  },
  {
    id: "dislocate",
    label: "Market moves",
    plain:
      "A trade pushes the pool off its reference price. In reality the external market moves and the pool goes stale; here we open the same gap from the pool side, because we cannot move Chainlink.",
  },
  {
    id: "calculate",
    label: "Arbitrageur sizes the trade",
    plain:
      "The arbitrageur works out how much to trade, what it returns, what gas costs, and whether anything is left over.",
  },
  {
    id: "submit",
    label: "Transaction submitted",
    plain: "The arbitrage swap is signed and broadcast to Base Sepolia.",
  },
  {
    id: "confirm",
    label: "Mined and confirmed",
    plain:
      "The transaction is in a block. The hook priced it, charged the fee, and emitted its events.",
  },
  {
    id: "settle",
    label: "Pool state updated",
    plain: "Reserves moved, and the pool's price converged back toward the reference.",
  },
  {
    id: "result",
    label: "Result",
    plain: "What the arbitrageur kept, and what stayed with liquidity providers.",
  },
];

export type RunStatus = "idle" | "running" | "complete" | "failed";

export function useSimulation(input: ScenarioInput) {
  const { curve, tick: poolTick } = usePoolCurve();
  const pool = useLivePool();
  const { gasPriceWei } = useLiveProtocol();
  const { address, chainId, isConnected } = useAccount();
  const { writeContractAsync } = useWriteContract();
  const config = useConfig();
  const publicClient = usePublicClient({ chainId: BASE_SEPOLIA_CHAIN_ID });

  const [status, setStatus] = useState<RunStatus>("idle");
  const [activeStage, setActiveStage] = useState<StageId>("idle");
  const [completed, setCompleted] = useState<StageId[]>([]);
  const [txs, setTxs] = useState<ExecutedTx[]>([]);
  const [error, setError] = useState<string | undefined>();

  /**
   * Projected from live pool state. Recomputed on every read, so the panel a user stares at
   * before pressing the button reflects the pool as it is now, not as it was on page load.
   */
  const scenario: Scenario | undefined = useMemo(
    () => buildScenario(curve, pool.referenceTick, gasPriceWei, input),
    [curve, pool.referenceTick, gasPriceWei, input],
  );

  const stages: Stage[] = useMemo(
    () =>
      STAGE_ORDER.map((s) => ({
        ...s,
        status:
          completed.includes(s.id)
            ? ("done" as const)
            : activeStage === s.id
              ? status === "failed"
                ? ("failed" as const)
                : ("active" as const)
              : ("pending" as const),
      })),
    [completed, activeStage, status],
  );

  /** Submits one transaction and waits for it, recording what actually came back. */
  const send = useCallback(
    async (
      label: string,
      request: Parameters<typeof writeContractAsync>[0],
    ): Promise<ExecutedTx> => {
      const hash = await writeContractAsync(request);
      setTxs((current) => [...current, { label, hash, status: "pending", events: [] }]);

      const receipt = await waitForTransactionReceipt(config, {
        hash,
        chainId: BASE_SEPOLIA_CHAIN_ID,
      });

      // Decode only the hook's own logs. Everything else in the receipt belongs to the
      // PoolManager and the tokens, and is not what this panel is about.
      const events = receipt.logs.flatMap((log) => {
        if (log.address.toLowerCase() !== CONTRACTS.hook.toLowerCase()) return [];
        try {
          const decoded = decodeEventLog({ abi: ASSAY_EVENT_ABI, ...log });
          const args = decoded.args as Record<string, unknown>;
          return [
            {
              name: decoded.eventName,
              args: Object.fromEntries(
                Object.entries(args).map(([k, v]) => [k, String(v)]),
              ),
            },
          ];
        } catch {
          return [];
        }
      });

      const executed: ExecutedTx = {
        label,
        hash,
        status: receipt.status === "success" ? "success" : "reverted",
        gasUsed: receipt.gasUsed,
        effectiveGasPrice: receipt.effectiveGasPrice,
        blockNumber: receipt.blockNumber,
        events,
      };
      setTxs((current) => current.map((t) => (t.hash === hash ? executed : t)));

      if (executed.status === "reverted") throw new Error(`${label} reverted on chain.`);
      return executed;
    },
    [writeContractAsync, config],
  );

  /** Grants the router an allowance if it does not already have enough. */
  const ensureAllowance = useCallback(
    async (token: `0x${string}`, amount: bigint, label: string) => {
      if (!publicClient || !address) return;
      const current = (await publicClient.readContract({
        address: token,
        abi: ERC20_ABI,
        functionName: "allowance",
        args: [address, ROUTERS.swap],
      })) as bigint;
      if (current >= amount) return;
      await send(label, {
        address: token,
        abi: ERC20_ABI,
        functionName: "approve",
        args: [ROUTERS.swap, amount],
        chainId: BASE_SEPOLIA_CHAIN_ID,
      });
    },
    [publicClient, address, send],
  );

  const swapRequest = useCallback(
    (zeroForOne: boolean, amountIn: bigint) =>
      ({
        address: ROUTERS.swap,
        abi: SWAP_ROUTER_ABI,
        functionName: "swap",
        args: [
          {
            currency0: POOL.currency0,
            currency1: POOL.currency1,
            fee: DYNAMIC_FEE_FLAG,
            tickSpacing: POOL.tickSpacing,
            hooks: CONTRACTS.hook,
          },
          {
            zeroForOne,
            amountSpecified: -amountIn,
            // Deliberately unbounded *here only*: the simulation's whole purpose is to move the
            // price and observe it, so a slippage guard would abort the very thing being shown.
            // The live swap card sends a real bound; these two paths differ on purpose.
            sqrtPriceLimitX96: priceLimitFor(zeroForOne),
          },
          { takeClaims: false, settleUsingBurn: false },
          "0x",
        ],
        chainId: BASE_SEPOLIA_CHAIN_ID,
      }) as Parameters<typeof writeContractAsync>[0],
    [],
  );

  const advance = (id: StageId) => {
    setCompleted((c) => (c.includes(id) ? c : [...c, id]));
  };

  const run = useCallback(async () => {
    if (!scenario || scenario.unavailable) return;
    setStatus("running");
    setError(undefined);
    setTxs([]);
    setCompleted([]);

    try {
      setActiveStage("opportunity");
      advance("opportunity");

      // --- Leg 1: open the gap -----------------------------------------------------------
      setActiveStage("dislocate");
      await ensureAllowance(
        POOL.currency0,
        scenario.dislocationLeg.amountIn,
        "Approve USDC",
      );
      await send("Dislocate the pool", swapRequest(true, scenario.dislocationLeg.amountIn));
      advance("dislocate");

      setActiveStage("calculate");
      advance("calculate");

      // --- Leg 2: the arbitrage ----------------------------------------------------------
      setActiveStage("submit");
      await ensureAllowance(POOL.currency1, scenario.arbitrageLeg.amountIn, "Approve WETH");
      await send("Arbitrage swap", swapRequest(false, scenario.arbitrageLeg.amountIn));
      advance("submit");

      setActiveStage("confirm");
      advance("confirm");

      setActiveStage("settle");
      advance("settle");

      setActiveStage("result");
      advance("result");
      setStatus("complete");
    } catch (caught) {
      const message = caught instanceof Error ? caught.message : String(caught);
      setError(
        /user rejected|denied transaction|rejected the request/i.test(message)
          ? "Transaction rejected in your wallet."
          : message.split("\n")[0],
      );
      setStatus("failed");
    }
  }, [scenario, ensureAllowance, send, swapRequest]);

  const reset = useCallback(() => {
    setStatus("idle");
    setActiveStage("idle");
    setCompleted([]);
    setTxs([]);
    setError(undefined);
  }, []);

  return {
    scenario,
    stages,
    status,
    activeStage,
    txs,
    error,
    run,
    reset,
    poolTick,
    /** Every precondition for a real run, so the button can say which one is missing. */
    canRun:
      isConnected &&
      chainId === BASE_SEPOLIA_CHAIN_ID &&
      Boolean(scenario) &&
      !scenario?.unavailable,
    isConnected,
    wrongNetwork: isConnected && chainId !== BASE_SEPOLIA_CHAIN_ID,
  };
}
