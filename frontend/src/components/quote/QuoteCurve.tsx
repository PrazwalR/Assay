"use client";

import { useCallback, useRef } from "react";

import { useAssay } from "@/components/Providers";
import { DEPLOYED } from "@/lib/protocol/config";
import { quote } from "@/lib/protocol/feeBlend";
import { pipsToBp, signed } from "@/lib/format";

/**
 * The quote surface: fee as a function of signed drift, with a live marker you can drag.
 *
 * The curve is *computed* from `quote()`, not drawn as a decorative path. That matters — this
 * is the visual that carries the product's central claim, and a hand-drawn approximation of it
 * would be a picture of a mechanism rather than the mechanism. The floor, the linear ramp and
 * the ceiling all appear because the formula puts them there.
 *
 * The second marker is the same drift in the opposite direction. Two swaps, one block, one
 * drift, two prices — a volatility-driven hook quotes them identically.
 */

const VIEW_W = 1000;
const VIEW_H = 340;
const DRIFT_MIN = -200;
const DRIFT_MAX = 1200;
/** Headroom above the 10,000-pip ceiling so the flat top is visibly a ceiling, not a crop. */
const PIPS_MAX = 11_000;

const toX = (drift: number) =>
  ((Math.min(DRIFT_MAX, Math.max(DRIFT_MIN, drift)) - DRIFT_MIN) / (DRIFT_MAX - DRIFT_MIN)) *
  VIEW_W;
const toY = (pips: number) => VIEW_H - (pips / PIPS_MAX) * VIEW_H;

/** Sampled from the real formula, so the shape cannot drift from what the contract charges. */
function curvePath(): string {
  const points: string[] = [];
  for (let drift = DRIFT_MIN; drift <= DRIFT_MAX; drift += 10) {
    points.push(`${toX(drift).toFixed(2)},${toY(quote(drift, true, DEPLOYED)).toFixed(2)}`);
  }
  return points.join(" ");
}

const PATH = curvePath();

export function QuoteCurve() {
  const { drift, setDrift, feePips, twinFeePips, tone, reducedMotion } = useAssay();
  const surface = useRef<HTMLDivElement>(null);

  const driftFromPointer = useCallback((clientX: number) => {
    const rect = surface.current?.getBoundingClientRect();
    if (!rect) return;
    const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
    setDrift(Math.round(DRIFT_MIN + ratio * (DRIFT_MAX - DRIFT_MIN)));
  }, [setDrift]);

  const onPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    event.currentTarget.setPointerCapture(event.pointerId);
    driftFromPointer(event.clientX);
  };

  const onPointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    if (event.buttons === 0) return;
    driftFromPointer(event.clientX);
  };

  // Keyboard parity: the drag is the primary interaction, so it needs a non-pointer path.
  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    const step = event.shiftKey ? 100 : 10;
    if (event.key === "ArrowRight") {
      event.preventDefault();
      setDrift(Math.min(DRIFT_MAX, drift + step));
    } else if (event.key === "ArrowLeft") {
      event.preventDefault();
      setDrift(Math.max(DRIFT_MIN, drift - step));
    }
  };

  const twinDrift = -Math.abs(drift);
  const markX = toX(drift);
  const markY = toY(feePips);
  const twinX = toX(twinDrift);
  const twinY = toY(twinFeePips);

  return (
    <div data-tone={tone} className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <div className="flex flex-wrap items-baseline justify-between gap-5 px-6 pb-4 pt-5">
        <div>
          <p className="mb-[9px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            The quote surface
          </p>
          <p className="max-w-[52ch] text-[15px] font-medium leading-[1.45] text-text">
            Fee as a function of signed drift. Two swaps in one block, against the same drift, in
            opposite directions.
          </p>
        </div>
        <div className="flex gap-7">
          <div>
            <p className="mb-[7px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
              Capturing
            </p>
            <p className="tnum text-2xl font-semibold leading-none" style={{ color: "var(--tone)" }}>
              {pipsToBp(feePips)}
            </p>
          </div>
          <div>
            <p className="mb-[7px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
              Opposing
            </p>
            <p className="tnum text-2xl font-semibold leading-none text-benign">
              {pipsToBp(twinFeePips)}
            </p>
          </div>
        </div>
      </div>

      <div
        ref={surface}
        role="slider"
        tabIndex={0}
        aria-label="Signed drift in ticks"
        aria-valuemin={DRIFT_MIN}
        aria-valuemax={DRIFT_MAX}
        aria-valuenow={drift}
        aria-valuetext={`${signed(drift)} ticks, quoted ${pipsToBp(feePips)}`}
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onKeyDown={onKeyDown}
        className="relative h-[340px] touch-none border-t border-border cursor-ew-resize"
      >
        <svg
          viewBox={`0 0 ${VIEW_W} ${VIEW_H}`}
          preserveAspectRatio="none"
          className="absolute inset-0 block size-full"
        >
          {[60, 130, 200, 270].map((y) => (
            <line key={y} x1={0} y1={y} x2={VIEW_W} y2={y} stroke="rgb(233 236 239 / 0.055)" />
          ))}
          <line
            x1={toX(0)}
            y1={0}
            x2={toX(0)}
            y2={VIEW_H}
            stroke="rgb(233 236 239 / 0.11)"
            strokeDasharray="3 4"
          />

          {/* Drawn twice: a wide neutral underlay for legibility, the accent hairline on top. */}
          <polyline points={PATH} fill="none" stroke="rgb(233 236 239 / 0.16)" strokeWidth={6} strokeLinejoin="round" />
          <polyline
            points={PATH}
            fill="none"
            stroke="var(--color-accent)"
            strokeWidth={1.75}
            strokeLinejoin="round"
            strokeDasharray={reducedMotion ? undefined : 240}
            style={reducedMotion ? undefined : { animation: "assayFlow 2.2s ease-out" }}
          />

          <line x1={twinX} y1={0} x2={twinX} y2={VIEW_H} stroke="rgb(91 208 140 / 0.22)" />
          <circle cx={twinX} cy={twinY} r={5} fill="var(--color-bg)" stroke="var(--color-benign)" strokeWidth={2} />

          <line x1={markX} y1={0} x2={markX} y2={VIEW_H} stroke="rgb(233 236 239 / 0.16)" />
          {!reducedMotion && (
            <circle
              cx={markX}
              cy={markY}
              r={11}
              fill="var(--tone)"
              opacity={0.18}
              style={{ animation: "assayRipple 1.8s ease-out infinite" }}
            />
          )}
          <circle cx={markX} cy={markY} r={5.5} fill="var(--tone)" />
        </svg>

        <p className="pointer-events-none absolute left-[14px] top-3 font-mono text-[10.5px] font-medium leading-none text-text-muted">
          1.00% ceiling — maxFeePips {DEPLOYED.maxFeePips.toLocaleString("en-US")}
        </p>
        <p className="pointer-events-none absolute bottom-3 left-[14px] font-mono text-[10.5px] font-medium leading-none text-text-muted">
          0.01% floor — minFeePips {DEPLOYED.minFeePips}
        </p>
        <p className="pointer-events-none absolute bottom-3 right-[14px] font-mono text-[10.5px] font-medium leading-none text-text-muted">
          drift +{DRIFT_MAX.toLocaleString("en-US")} ticks →
        </p>

        <div
          className="pointer-events-none absolute top-[18px] -translate-x-1/2 whitespace-nowrap rounded-[7px] border border-border-hover bg-[#15181A] px-[9px] py-[6px] text-left font-mono text-[11.5px] font-medium leading-[1.5]"
          style={{ left: `${(markX / VIEW_W) * 100}%` }}
        >
          <span className="block text-text-dim">drift {signed(drift)} ticks</span>
          <span className="block" style={{ color: "var(--tone)" }}>
            fee {feePips.toLocaleString("en-US")} pips
          </span>
        </div>
      </div>

      <p className="border-t border-border px-6 py-3 text-[12px] leading-[1.5] text-text-muted">
        Drag anywhere on the surface, or focus it and use ← →. The curve is evaluated from the
        same <span className="font-mono text-text-dim">FeeBlend</span> port the swap card quotes
        from, so what you see here is what the contract charges.
      </p>
    </div>
  );
}
