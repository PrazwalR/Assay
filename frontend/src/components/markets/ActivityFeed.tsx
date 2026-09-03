"use client";

import Link from "next/link";

import { useHookActivity } from "@/hooks/useHookActivity";
import { DEPLOYED, explorerTx } from "@/lib/protocol/config";

/** Enough to show the mechanism alternating; the rest is a block explorer's job. */
const SHOWN = 8;

/**
 * The last few swaps the hook priced, from its own `SwapAssayed` logs.
 *
 * Deliberately three columns. The fee and what it implies are the only things this surface
 * needs to carry -- a full ledger belongs on an explorer, and the reasoning belongs in
 * `/docs/mechanism`. `sender` is omitted on purpose: it is the router on every row, never the
 * trader, so a column for it would be identical noise repeated N times.
 */
export function ActivityFeed() {
  const { swaps, isLoading, error, truncated } = useHookActivity(DEPLOYED.minFeePips);
  const shown = swaps.slice(0, SHOWN);

  return (
    <section className="mt-5 overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex items-baseline justify-between gap-3 border-b border-border-2 px-5 py-[14px]">
        <h2 className="text-[14px] font-semibold leading-none">Recent swaps</h2>
        <span className="font-mono text-[11.5px] leading-none text-text-muted">
          {isLoading ? "reading chain…" : `${swaps.length} priced${truncated ? "+" : ""}`}
        </span>
      </header>

      {error ? (
        <p className="px-5 py-5 text-[13px] text-text-muted">Could not read the hook&apos;s logs.</p>
      ) : isLoading ? (
        <p className="px-5 py-5 text-[13px] text-text-muted">Reading the chain…</p>
      ) : shown.length === 0 ? (
        <p className="px-5 py-5 text-[13px] text-text-muted">No swaps in the scanned window.</p>
      ) : (
        <ul className="divide-y divide-border-2/60">
          {shown.map((s) => (
            <li
              key={`${s.txHash}-${s.logIndex}`}
              className="flex items-center justify-between gap-4 px-5 py-[11px]"
            >
              <span className="tnum w-[92px] shrink-0 font-mono text-[13.5px]">
                {(s.feePips / 100).toFixed(2)}
                <span className="ml-1 text-[11px] text-text-muted">bps</span>
              </span>
              <span
                className={`flex-1 text-[13px] ${s.tradedAway ? "text-text-muted" : "font-medium text-warm"}`}
              >
                {s.tradedAway ? "traded away" : "captured drift"}
              </span>
              <a
                href={explorerTx(s.txHash)}
                target="_blank"
                rel="noreferrer"
                className="shrink-0 font-mono text-[12px] text-text-muted underline underline-offset-2 hover:text-warm"
              >
                {s.txHash.slice(0, 8)}… ↗
              </a>
            </li>
          ))}
        </ul>
      )}

      <p className="border-t border-border-2 px-5 py-[11px] text-[12px] leading-none text-text-muted">
        {truncated ? "Live, not fixtures — most recent only." : "Live, not fixtures."}{" "}
        <Link href="/docs/mechanism" className="underline underline-offset-2">
          How the fee is set
        </Link>
      </p>
    </section>
  );
}
