"use client";

import { useHookActivity } from "@/hooks/useHookActivity";
import { DEPLOYED, explorerTx } from "@/lib/protocol/config";

/**
 * Every quote the hook has produced, plotted from its own `SwapAssayed` logs.
 *
 * This replaces a fixture scatter that drew invented points at invented positions. The pool has
 * few enough swaps that the real series is small -- which is exactly why the fixture existed, to
 * show "the shape this would take" -- but a small true chart beats a large invented one, and the
 * thing worth seeing is visible in fourteen points: quotes sit at the floor or climb well above
 * base, and almost nothing lands in between. That bimodality *is* the mechanism. A
 * volatility-driven hook produces a single cloud, because it cannot tell the two flows apart.
 *
 * Bars rather than a scatter: the x axis is swap order, not time. Spacing points by block number
 * would leave the seeded bursts overlapping and the gaps empty, which reads as a data problem
 * rather than as trading history.
 */

const VIEW_H = 262;
/** Same headroom as the quote curve, so the ceiling reads as a ceiling and not as a crop. */
const PIPS_MAX = 11_000;

const toY = (pips: number) => VIEW_H - (pips / PIPS_MAX) * VIEW_H;

export function LiveQuoteChart() {
  const { swaps, isLoading, error } = useHookActivity(DEPLOYED.minFeePips);

  // Oldest first: the chart reads left to right as the pool's history, while the feed beside it
  // reads newest first as a log. Same data, opposite orders, each right for its own shape.
  const series = [...swaps].reverse();
  const atFloor = series.filter((s) => s.tradedAway).length;
  const highest = series.reduce((max, s) => (s.feePips > max ? s.feePips : max), 0);
  // `swaps` is newest-first, so its head is the latest swap -- no index arithmetic, and defined
  // or not without an assertion.
  const latest = swaps[0];

  return (
    <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex items-baseline justify-between gap-4 px-5 pb-3 pt-[18px]">
        <div>
          <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Quoted fee, per swap
          </p>
          <p className="text-[14.5px] font-medium leading-[1.4]">
            Every <span className="font-mono text-text-dim">SwapAssayed</span> event this pool has
            emitted, in order
          </p>
        </div>
        <div className="flex flex-none gap-[14px]">
          <span className="flex items-center gap-[6px] font-mono text-[11px] leading-none text-text-muted">
            <span className="size-[6px] rounded-full bg-benign" />
            away
          </span>
          <span className="flex items-center gap-[6px] font-mono text-[11px] leading-none text-text-muted">
            <span className="size-[6px] rounded-full bg-accent" />
            capturing
          </span>
        </div>
      </header>

      {isLoading ? (
        <p className="px-5 pb-6 pt-2 text-[13px] text-text-muted">Reading the chain…</p>
      ) : error || series.length === 0 ? (
        <p className="px-5 pb-6 pt-2 text-[13px] text-text-muted">
          Could not read the hook&apos;s logs, so there is nothing to plot. No fixture is
          substituted.
        </p>
      ) : (
        <>
          <div className="relative h-[262px] px-5">
            <svg
              viewBox={`0 0 ${Math.max(series.length * 44, 240)} ${VIEW_H}`}
              preserveAspectRatio="none"
              className="absolute inset-x-5 inset-y-0 block h-full w-[calc(100%-2.5rem)]"
              role="img"
              aria-label={`Quoted fee for each of ${series.length} swaps. ${atFloor} sat at the ${
                DEPLOYED.minFeePips / 100
              } basis point floor; the highest quote was ${(highest / 100).toFixed(2)} basis points.`}
            >
              {[DEPLOYED.maxFeePips, DEPLOYED.baseFeePips, DEPLOYED.minFeePips].map((pips, i) => (
                <line
                  key={pips}
                  x1={0}
                  y1={toY(pips)}
                  x2={Math.max(series.length * 44, 240)}
                  y2={toY(pips)}
                  stroke={
                    ["rgb(228 103 79 / 0.22)", "rgb(79 195 232 / 0.2)", "rgb(91 208 140 / 0.2)"][i]
                  }
                  strokeDasharray="4 4"
                />
              ))}

              {series.map((swap, index) => {
                const x = index * 44 + 22;
                const y = toY(swap.feePips);
                const capped = swap.feePips >= DEPLOYED.maxFeePips;
                const fill = capped
                  ? "var(--color-hot)"
                  : swap.tradedAway
                    ? "var(--color-benign)"
                    : "var(--color-accent)";
                return (
                  <g key={`${swap.txHash}-${swap.logIndex}`}>
                    <line
                      x1={x}
                      y1={VIEW_H}
                      x2={x}
                      y2={y}
                      stroke={fill}
                      strokeOpacity={0.28}
                      strokeWidth={2}
                    />
                    <circle cx={x} cy={y} r={capped ? 5 : 4} fill={fill} />
                  </g>
                );
              })}
            </svg>

            <span className="pointer-events-none absolute left-7 top-5 font-mono text-[10px] leading-none text-hot">
              {(DEPLOYED.maxFeePips / 10_000).toFixed(2)}% ceiling
            </span>
            <span
              className="pointer-events-none absolute left-7 font-mono text-[10px] leading-none text-accent"
              style={{ top: toY(DEPLOYED.baseFeePips) - 13 }}
            >
              {(DEPLOYED.baseFeePips / 10_000).toFixed(2)}% base
            </span>
            <span
              className="pointer-events-none absolute left-7 font-mono text-[10px] leading-none text-benign"
              style={{ top: toY(DEPLOYED.minFeePips) - 13 }}
            >
              {(DEPLOYED.minFeePips / 10_000).toFixed(2)}% floor
            </span>
          </div>

          <p className="border-t border-border px-5 py-[13px] text-[12.5px] leading-[1.55] text-text-dim">
            {series.length} swaps, {atFloor} of them quoted at the floor because they traded away
            from the reference and captured nothing. The highest was{" "}
            <span className="tnum text-text">{(highest / 100).toFixed(2)} bp</span>, against a
            floor of {(DEPLOYED.minFeePips / 100).toFixed(2)} bp — a{" "}
            {Math.round(highest / DEPLOYED.minFeePips)}-fold spread on one pool. Every point links
            to its transaction in the feed below.{" "}
            {latest ? (
              <a
                href={explorerTx(latest.txHash)}
                target="_blank"
                rel="noreferrer"
                className="underline underline-offset-2 hover:text-accent"
              >
                Most recent ↗
              </a>
            ) : null}
          </p>
        </>
      )}
    </section>
  );
}
