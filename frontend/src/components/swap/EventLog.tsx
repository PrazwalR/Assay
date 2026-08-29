"use client";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useSwapQuote } from "@/hooks/useSwapQuote";
import { num } from "@/lib/format";
import { POOL_ID, ROUTER_SENDERS } from "@/lib/protocol/fixtures";
import { DEPLOYED } from "@/lib/protocol/config";

/**
 * What the hook would emit for this quote.
 *
 * The event names and their argument shapes are the real ones from `IAssayEvents.sol` — but no
 * pool exists, so none of these have actually been emitted. The panel says so rather than
 * dressing fixtures as history, which would be the exact failure the status banner warns about.
 *
 * `sender` is the router that called the PoolManager. It is never the trader, and the copy here
 * says so, because treating it as an identity is the mistake this event invites.
 */
export function EventLog() {
  const { feePips, twinFeePips, overflowPips, referenceFresh, tone } = useAssay();
  const { blockNumber } = useLiveProtocol();
  const { feePaidOut, outToken } = useSwapQuote();

  const block = blockNumber ? Number(blockNumber) : 0;
  const at = (offset: number) => (block ? `block ${(block - offset).toLocaleString("en-US")}` : "—");

  const events = [
    {
      name: "SwapAssayed",
      tone: "current" as const,
      args: `feePips ${feePips.toLocaleString("en-US")} · sender ${ROUTER_SENDERS[0]} (router)`,
      when: at(0),
    },
    {
      name: "SwapAssayed",
      tone: "benign" as const,
      args: `feePips ${twinFeePips.toLocaleString("en-US")} · sender ${ROUTER_SENDERS[1]} (router)`,
      when: at(0),
    },
    overflowPips > 0
      ? {
          name: "ToxicitySurchargeDonated",
          tone: "warm" as const,
          args: `amount ${num(feePaidOut, outToken.decimals)} · inCurrency0 false`,
          when: at(1),
        }
      : {
          name: "ReferenceFreshnessChanged",
          tone: "neutral" as const,
          args: `fresh ${referenceFresh} · transition only, not per swap`,
          when: at(1),
        },
    {
      name: "PoolRegistered",
      tone: "neutral" as const,
      args: `baseFeePips ${DEPLOYED.baseFeePips} · poolId ${POOL_ID}`,
      when: "genesis",
    },
  ];

  const colorFor = (kind: "current" | "benign" | "warm" | "neutral") => {
    if (kind === "current") return { color: "var(--tone)", background: "var(--tone-wash-2)" };
    if (kind === "benign")
      return { color: "var(--tone-benign)", background: "rgb(91 208 140 / 0.12)" };
    if (kind === "warm") return { color: "var(--tone-warm)", background: "rgb(233 165 68 / 0.12)" };
    return { color: "var(--color-text-dim)", background: "rgb(233 236 239 / 0.07)" };
  };

  return (
    <section data-tone={tone} className="rounded-2xl border border-border-2 bg-surface px-5 py-[18px]">
      <header className="mb-[14px] flex items-center justify-between gap-4">
        <p className="font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Hook events, this pool
        </p>
        <p className="font-mono text-[11.5px] leading-none text-warm">not yet emitted</p>
      </header>

      <ul>
        {events.map((event, index) => (
          <li
            key={`${event.name}-${index}`}
            className="grid grid-cols-[auto_1fr_auto] items-center gap-3 border-t border-border py-[9px]"
          >
            <span
              className="rounded-[4px] px-[6px] py-1 font-mono text-[10.5px] font-medium leading-none"
              style={colorFor(event.tone)}
            >
              {event.name}
            </span>
            <span className="overflow-hidden text-ellipsis whitespace-nowrap font-mono text-[12px] leading-[1.4] text-text-dim">
              {event.args}
            </span>
            <span className="font-mono text-[11px] leading-none text-text-muted">{event.when}</span>
          </li>
        ))}
      </ul>

      <p className="mt-3 border-t border-border pt-3 text-[11.5px] leading-[1.55] text-text-muted">
        These are the real event signatures from{" "}
        <span className="font-mono">IAssayEvents.sol</span>, populated with this quote — not a
        log of swaps that happened. No pool has been initialised, so the hook has emitted
        nothing. <span className="font-mono">sender</span> is the router, never the trader.
      </p>
    </section>
  );
}
