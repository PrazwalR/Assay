"use client";

import { useState } from "react";

import { useAssay } from "@/components/Providers";
import { ScatterChart } from "@/components/markets/ScatterChart";
import { DEPLOYED, PERMISSION_MASK } from "@/lib/protocol/config";
import { int, usdCompact } from "@/lib/format";
import {
  FEE_DISTRIBUTION,
  MARKET_BASELINE,
  POOL_ID,
  RANGES,
  type RangeLabel,
} from "@/lib/protocol/fixtures";
import { CURRENCY0, CURRENCY1 } from "@/lib/protocol/tokens";

/**
 * Markets.
 *
 * The pool is real, but two swaps is not a distribution, so every aggregate here is still a
 * fixture. Rather than scatter a dozen individual markers, the whole surface carries one
 * unmissable disclosure at the top — and the numbers still reconcile with each other, so the
 * shape of the thing being described is honest even though the magnitudes are illustrative.
 */
export function MarketsView() {
  const { dataMode } = useAssay();
  const [range, setRange] = useState<RangeLabel>("1D");

  const factor = RANGES.find((entry) => entry.label === range)?.factor ?? 1;
  const baseline = MARKET_BASELINE[dataMode];

  return (
    <main className="mx-auto max-w-[1240px] px-6 pb-[90px] pt-9">
      <div className="mb-6 flex flex-wrap items-end justify-between gap-6">
        <div>
          <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Markets · one pool, one oracle pair
          </p>
          <h1 className="mb-[10px] text-[32px] font-semibold leading-[1.15] tracking-[-0.025em]">
            Quoted fees, by the flow that earned them
          </h1>
          <p className="max-w-[66ch] text-[14.5px] leading-[1.6] text-text-dim text-pretty">
            The hook refuses any pool whose currencies do not match the pair its oracle declares,
            so there is exactly one market to describe. Everything below would be derived from{" "}
            <span className="font-mono">SwapAssayed</span> events.
          </p>
        </div>
        <div className="flex flex-none gap-2">
          {RANGES.map((entry) => {
            const active = entry.label === range;
            return (
              <button
                key={entry.label}
                type="button"
                onClick={() => setRange(entry.label)}
                aria-pressed={active}
                className={`h-[30px] min-w-[44px] rounded-lg border px-[11px] font-mono text-xs font-medium leading-none transition-colors ${
                  active
                    ? "border-accent/40 bg-accent/10 text-accent"
                    : "border-border-2 bg-surface-2 text-text-dim hover:border-border-hover"
                }`}
              >
                {entry.label}
              </button>
            );
          })}
        </div>
      </div>

      {/* The disclosure that governs everything below it. */}
      <div className="mb-5 flex items-start gap-3 rounded-2xl border border-warm/20 bg-[#100E0A] px-5 py-4">
        <span className="mt-[6px] size-[6px] flex-none rounded-full bg-warm" />
        <p className="max-w-[86ch] text-[13px] leading-[1.6] text-[#9A8B72]">
          <strong className="font-semibold text-warm">
            The pool is real; this page&apos;s aggregates are not yet.
          </strong>{" "}
          The USDC/WETH pool is live on Base Sepolia with real liquidity, and it has been traded
          twice — both times from the deploy script, which quoted 0.05% and 0.31% for the two
          directions. Two swaps is not a distribution. Every aggregate below (volume, TVL trend,
          the scatter, the histogram) remains an illustrative fixture showing the shape this
          surface reports once there is enough history to measure. The pool identity, the fee
          bounds and the reference are real.
        </p>
      </div>

      <dl className="mb-5 grid gap-px overflow-hidden rounded-2xl border border-border bg-border sm:grid-cols-2 lg:grid-cols-5">
        <Metric label="TVL" value={usdCompact(baseline.tvlUsd)} note="+0.82% 24h" noteTone="benign" />
        <Metric
          label="Volume"
          value={usdCompact(baseline.volumeUsd * factor)}
          note={`${int(baseline.swaps * factor)} swaps`}
        />
        <Metric
          label="LP fees"
          value={usdCompact(baseline.feesUsd * factor)}
          note={`${usdCompact(baseline.donatedUsd * factor)} donated`}
        />
        <Metric
          label="Mean quote"
          value={`${baseline.meanFeeBp.toFixed(2)} bp`}
          note="volume-weighted"
          valueTone="accent"
        />
        <Metric
          label="Reference uptime"
          value={baseline.uptime}
          note={`${baseline.staleSpans} stale spans`}
          noteTone="warm"
        />
      </dl>

      <div className="mb-5 grid gap-5 lg:grid-cols-2">
        <ScatterChart range={range} />

        <section className="rounded-2xl border border-border-2 bg-surface px-5 py-[18px]">
          <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Distribution of quotes
          </p>
          <h2 className="mb-5 text-[14.5px] font-medium leading-[1.4]">
            Share of volume by quoted fee
          </h2>

          <div className="grid gap-[14px]">
            {FEE_DISTRIBUTION.map((bucket) => (
              <div key={bucket.label}>
                <div className="mb-[7px] flex items-baseline justify-between font-mono text-xs leading-none text-text-dim">
                  <span>{bucket.label}</span>
                  <span className="text-text">{bucket.share.toFixed(1)}%</span>
                </div>
                <div className="h-[7px] overflow-hidden rounded-[4px] bg-surface-3">
                  <div
                    className="h-full"
                    style={{
                      // Floor the width so a sub-1% bucket is still visible as a mark rather
                      // than vanishing — an empty track reads as "no data", not "very little".
                      width: `${Math.max(bucket.share, 2)}%`,
                      background: `var(--tone-${bucket.tone})`,
                    }}
                  />
                </div>
              </div>
            ))}
          </div>

          <p className="mt-[22px] rounded-[11px] border border-border bg-bg px-[14px] py-[13px] text-[12.5px] leading-[1.55] text-text-dim">
            Half of all volume would be quoted at or below the base fee. A volatility-driven hook
            charges every one of those swaps the same rate.
          </p>
        </section>
      </div>

      <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
        <header className="flex items-center justify-between gap-4 border-b border-border px-5 pb-[15px] pt-[17px]">
          <p className="font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Pool
          </p>
          <p className="font-mono text-[11.5px] leading-none text-text-muted">
            poolId {POOL_ID} · mask {PERMISSION_MASK} · dynamic fee
          </p>
        </header>

        <div className="grid grid-cols-[1.6fr_repeat(5,1fr)] gap-4 border-b border-border bg-bg px-5 py-[11px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
          <span>Pair</span>
          <span className="text-right">TVL</span>
          <span className="text-right">Volume</span>
          <span className="text-right">Fees</span>
          <span className="text-right">Mean quote</span>
          <span className="text-right">Reference</span>
        </div>

        <div className="grid grid-cols-[1.6fr_repeat(5,1fr)] items-center gap-4 px-5 py-4">
          <div className="flex items-center gap-[11px]">
            <span className="flex">
              <span
                className="size-6 rounded-full border-2 border-surface"
                style={{ background: CURRENCY0.color }}
              />
              <span
                className="-ml-[9px] size-6 rounded-full border-2 border-surface"
                style={{ background: CURRENCY1.color }}
              />
            </span>
            <span>
              <span className="block text-sm font-semibold leading-tight">
                {CURRENCY0.symbol} / {CURRENCY1.symbol}
              </span>
              <span className="mt-1 block font-mono text-[11px] leading-none text-text-muted">
                Base Sepolia · chain 84532
              </span>
            </span>
          </div>
          <span className="tnum text-right text-[13.5px] leading-none">
            {usdCompact(baseline.tvlUsd)}
          </span>
          <span className="tnum text-right text-[13.5px] leading-none">
            {usdCompact(baseline.volumeUsd * factor)}
          </span>
          <span className="tnum text-right text-[13.5px] leading-none">
            {usdCompact(baseline.feesUsd * factor)}
          </span>
          <span className="tnum text-right text-[13.5px] leading-none text-accent">
            {baseline.meanFeeBp.toFixed(2)} bp
          </span>
          <span className="text-right font-mono text-xs leading-none text-benign">fresh</span>
        </div>

        <div className="flex items-center gap-[11px] border-t border-border bg-bg px-5 py-[15px]">
          <span className="size-[34px] flex-none rounded-[9px] border border-dashed border-border-hover" />
          <div className="flex-1">
            <p className="text-[13px] font-medium leading-tight text-text-dim">No other pools</p>
            <p className="mt-[3px] text-[12px] leading-[1.45] text-text-muted">
              A second market needs a second oracle adapter and a second mined hook address —
              configuration is immutable, so recalibrating {DEPLOYED.captureShareBps} bps means a
              new deployment, not an admin call.
            </p>
          </div>
        </div>
      </section>
    </main>
  );
}

function Metric({
  label,
  value,
  note,
  valueTone,
  noteTone,
}: {
  label: string;
  value: string;
  note: string;
  valueTone?: "accent";
  noteTone?: "benign" | "warm";
}) {
  return (
    <div className="bg-surface px-5 py-[19px]">
      <dt className="mb-[11px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
        {label}
      </dt>
      <dd className={`tnum text-[25px] leading-none ${valueTone === "accent" ? "text-accent" : ""}`}>
        {value}
      </dd>
      <dd
        className={`mt-[7px] font-mono text-[11.5px] leading-none ${
          noteTone === "benign"
            ? "text-benign"
            : noteTone === "warm"
              ? "text-warm"
              : "text-text-muted"
        }`}
      >
        {note}
      </dd>
    </div>
  );
}
