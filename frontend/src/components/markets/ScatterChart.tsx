"use client";

import { DEPLOYED } from "@/lib/protocol/config";
import { SCATTER, type RangeLabel } from "@/lib/protocol/fixtures";

const VIEW_W = 700;
const VIEW_H = 262;
/** Same headroom as the quote curve, so the ceiling reads as a ceiling and not as a crop. */
const PIPS_MAX = 11_000;

const toY = (pips: number) => VIEW_H - (pips / PIPS_MAX) * VIEW_H;

/**
 * One point per swap, positioned by fee. Colour encodes direction, which is the only encoding
 * that matters here: the visible fact should be that capturing flow sits high and opposing flow
 * sits along the floor, in the same window, at the same time.
 */
export function ScatterChart({ range }: { range: RangeLabel }) {
  const atCap = SCATTER.filter((point) => point.feePips >= DEPLOYED.maxFeePips).length;

  return (
    <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex items-baseline justify-between gap-4 px-5 pb-3 pt-[18px]">
        <div>
          <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Quoted fee, per swap
          </p>
          <p className="text-[14.5px] font-medium leading-[1.4]">
            Each point is one <span className="font-mono text-text-dim">SwapAssayed</span> event,
            coloured by direction
          </p>
        </div>
        <div className="flex flex-none gap-[14px]">
          <span className="flex items-center gap-[6px] font-mono text-[11px] leading-none text-text-muted">
            <span className="size-[6px] rounded-full bg-benign" />
            away
          </span>
          <span className="flex items-center gap-[6px] font-mono text-[11px] leading-none text-text-muted">
            <span className="size-[6px] rounded-full bg-warm" />
            capturing
          </span>
        </div>
      </header>

      <div className="relative h-[262px]">
        <svg
          viewBox={`0 0 ${VIEW_W} ${VIEW_H}`}
          preserveAspectRatio="none"
          className="absolute inset-0 block size-full"
          role="img"
          aria-label={`Scatter of quoted fees over the ${range} window. Opposing flow clusters at the floor; capturing flow spreads upward, with ${atCap} swaps at the cap.`}
        >
          <line
            x1={0}
            y1={toY(DEPLOYED.maxFeePips)}
            x2={VIEW_W}
            y2={toY(DEPLOYED.maxFeePips)}
            stroke="rgb(228 103 79 / 0.22)"
            strokeDasharray="4 4"
          />
          <line
            x1={0}
            y1={toY(DEPLOYED.baseFeePips)}
            x2={VIEW_W}
            y2={toY(DEPLOYED.baseFeePips)}
            stroke="rgb(79 195 232 / 0.2)"
            strokeDasharray="4 4"
          />
          <line
            x1={0}
            y1={toY(DEPLOYED.minFeePips)}
            x2={VIEW_W}
            y2={toY(DEPLOYED.minFeePips)}
            stroke="rgb(91 208 140 / 0.2)"
            strokeDasharray="4 4"
          />

          {SCATTER.map((point, index) => {
            const capped = point.feePips >= DEPLOYED.maxFeePips;
            return (
              <circle
                key={index}
                cx={point.x * VIEW_W}
                cy={toY(point.feePips)}
                r={capped ? 4.4 : point.capturing ? 3.4 : 3}
                fill={
                  capped
                    ? "var(--tone-hot)"
                    : point.capturing
                      ? "var(--tone-warm)"
                      : "var(--tone-benign)"
                }
              />
            );
          })}
        </svg>

        <span className="pointer-events-none absolute left-3 top-5 font-mono text-[10px] leading-none text-hot">
          1.00% ceiling
        </span>
        <span
          className="pointer-events-none absolute left-3 font-mono text-[10px] leading-none text-accent"
          style={{ top: toY(DEPLOYED.baseFeePips) - 13 }}
        >
          0.05% base
        </span>
        <span
          className="pointer-events-none absolute left-3 font-mono text-[10px] leading-none text-benign"
          style={{ top: toY(DEPLOYED.minFeePips) - 13 }}
        >
          0.01% floor
        </span>
      </div>

      <div className="flex items-center justify-between gap-3 border-t border-border px-5 py-3 font-mono text-[11px] leading-none text-text-muted">
        <span>−{range === "ALL" ? "71D" : range}</span>
        <span>
          {atCap} swaps hit the cap; the overflow was donated.
        </span>
        <span>now</span>
      </div>
    </section>
  );
}
