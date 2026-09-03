"use client";

import { useCallback, useRef } from "react";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useSwapQuote } from "@/hooks/useSwapQuote";
import { CAP_BINDS_AT_TICKS } from "@/lib/protocol/config";
import { ceilingOverflowPips, rawQuotedPips } from "@/lib/protocol/feeBlend";
import { signed, tokenAmount } from "@/lib/format";

const METER_MIN = -300;
const METER_MAX = 1200;
const pct = (drift: number) =>
  ((Math.min(METER_MAX, Math.max(METER_MIN, drift)) - METER_MIN) / (METER_MAX - METER_MIN)) * 100;

/**
 * The fee, shown as the arithmetic that produced it rather than as a result.
 *
 * Every row is a real term in `FeeBlend.quote`, in the order the contract evaluates them. A
 * trader who disagrees with the number can see exactly which step they disagree with — which is
 * the only honest way to present a fee that changes per swap.
 */
export function FeeDerivation() {
  const { setDrift } = useAssay();
  // The live drift, not the demonstration walk. This panel sits beside the swap card and used
  // to contradict it — showing 100-3,700 pips next to the card's 790.
  //
  // `tone` comes from here too, for the same reason. It used to be destructured from
  // `useAssay()` -- the `Math.random()` walk -- while every number in the panel came from this
  // hook, so the colour of the drift figure, the meter and two derivation rows was driven by the
  // simulated walk and re-tinted every 2.2s while the numbers themselves sat still. A live floor
  // quote could render in the colour of a capturing one.
  const { drift, feePips, feePaidOut, outToken, driftIsLive, referenceFresh, tone } =
    useSwapQuote();
  // The rows must add up to the result. Using DEPLOYED here while the result row used
  // the live bounds meant they would silently disagree the moment the two diverged.
  const { bounds } = useLiveProtocol();
  const overflowPips = ceilingOverflowPips(drift, referenceFresh, bounds);
  const meter = useRef<HTMLDivElement>(null);

  const raw = rawQuotedPips(drift, bounds);
  const surcharge = raw - bounds.baseFeePips;

  const driftFromPointer = useCallback(
    (clientX: number) => {
      const rect = meter.current?.getBoundingClientRect();
      if (!rect) return;
      const ratio = Math.min(1, Math.max(0, (clientX - rect.left) / rect.width));
      setDrift(Math.round(METER_MIN + ratio * (METER_MAX - METER_MIN)));
    },
    [setDrift],
  );

  return (
    <section data-tone={tone} className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex items-center justify-between gap-4 px-5 pb-[14px] pt-4">
        <div>
          <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Why this fee
          </p>
          <p className="text-[14.5px] font-medium leading-[1.4] text-text">
            Signed drift against the cached reference
          </p>
        </div>
        <div className="flex-none text-right">
          <p className="tnum text-[30px] font-semibold leading-none" style={{ color: "var(--tone)" }}>
            {signed(drift)}
          </p>
          <p className="mt-[6px] font-mono text-[11px] leading-none text-text-muted">
            ticks · 1 tick = 1 bp
          </p>
        </div>
      </header>

      <div
        ref={meter}
        role="slider"
        tabIndex={0}
        aria-label="Signed drift in ticks"
        aria-valuemin={METER_MIN}
        aria-valuemax={METER_MAX}
        aria-valuenow={drift}
        aria-disabled={driftIsLive}
        onPointerDown={(event) => {
          // Dragging is a demonstration control. Once the chain answers, the drift shown is the
          // pool's own and dragging it would contradict the fee beside it.
          if (driftIsLive) return;
          event.currentTarget.setPointerCapture(event.pointerId);
          driftFromPointer(event.clientX);
        }}
        onPointerMove={(event) => {
          if (driftIsLive) return;
          if (event.buttons !== 0) driftFromPointer(event.clientX);
        }}
        onKeyDown={(event) => {
          if (driftIsLive) return;
          const step = event.shiftKey ? 100 : 10;
          if (event.key === "ArrowRight") {
            event.preventDefault();
            setDrift(Math.min(METER_MAX, drift + step));
          } else if (event.key === "ArrowLeft") {
            event.preventDefault();
            setDrift(Math.max(METER_MIN, drift - step));
          }
        }}
        className="relative mx-5 mb-4 h-[52px] cursor-ew-resize touch-none overflow-hidden rounded-[10px] border border-border bg-bg"
      >
        <div
          className="absolute inset-y-0 left-0 bg-gradient-to-r from-benign/15 to-transparent"
          style={{ width: `${pct(0)}%` }}
        />
        <div className="absolute inset-y-0 w-px bg-white/20" style={{ left: `${pct(0)}%` }} />
        <div
          className="absolute inset-y-0"
          style={{
            left: `${Math.min(pct(drift), pct(0))}%`,
            width: `${Math.abs(pct(drift) - pct(0))}%`,
            background: "var(--tone-wash-2)",
          }}
        />
        <div
          className="absolute inset-y-0 w-[2px] -translate-x-px"
          style={{
            left: `${pct(drift)}%`,
            background: "var(--tone)",
            boxShadow: "0 0 14px var(--tone)",
          }}
        />
        <div
          className="absolute inset-y-0 w-px bg-hot/35"
          style={{ left: `${pct(CAP_BINDS_AT_TICKS)}%` }}
        />
        <span className="absolute bottom-[5px] left-[6px] font-mono text-[9.5px] leading-none text-text-muted">
          {METER_MIN}
        </span>
        <span
          className="absolute top-[6px] font-mono text-[9.5px] leading-none text-text-muted"
          style={{ left: `calc(${pct(0)}% + 6px)` }}
        >
          0
        </span>
        <span
          className="absolute top-[6px] font-mono text-[9.5px] leading-none text-hot"
          style={{ left: `calc(${pct(CAP_BINDS_AT_TICKS)}% + 6px)` }}
        >
          cap {CAP_BINDS_AT_TICKS.toLocaleString("en-US")}
        </span>
        <span className="absolute bottom-[5px] right-[6px] font-mono text-[9.5px] leading-none text-text-muted">
          +{METER_MAX.toLocaleString("en-US")}
        </span>
      </div>

      <dl className="grid gap-px border-t border-border bg-border">
        <DerivationRow label="baseFeePips" value={bounds.baseFeePips.toLocaleString("en-US")} />
        <DerivationRow
          label={`⌈ drift × 100 pips/tick × ${(bounds.captureShareBps / 100).toFixed(2)}% ⌉`}
          value={signed(surcharge)}
          tone
        />
        <DerivationRow label="Uncapped quote" value={`${raw.toLocaleString("en-US")} pips`} />
        <DerivationRow
          label={`clamp( ${bounds.minFeePips} , ${bounds.maxFeePips.toLocaleString("en-US")} )`}
          value={`${feePips.toLocaleString("en-US")} pips`}
          tone
          emphasis
        />
      </dl>

      {overflowPips > 0 ? (
        <div
          className="flex items-start gap-[11px] border-t border-warm/20 bg-[#100E0A] px-5 py-[14px]"
          style={{ animation: "assayRise 0.24s ease" }}
        >
          <span className="mt-[5px] size-[6px] flex-none rounded-full bg-warm" />
          <div>
            <p className="mb-[5px] text-[12.5px] font-semibold leading-tight text-warm">
              Fee-cap overflow — {overflowPips.toLocaleString("en-US")} pips donated
            </p>
            <p className="max-w-[64ch] text-[12.5px] leading-[1.5] text-[#9A8B72]">
              The uncapped formula wants more than a percentage-of-notional fee can express. The
              remainder is taken in the unspecified currency and routed to in-range liquidity
              providers via <span className="font-mono">poolManager.donate()</span> — no escrow,
              no owner, no withdrawal path.
            </p>
          </div>
        </div>
      ) : null}

      <p className="border-t border-border px-5 py-3 font-mono text-[11.5px] leading-[1.5] text-text-muted">
        {driftIsLive ? "live drift, read from the hook" : "drift simulated"} · this swap pays{" "}
        {tokenAmount(feePaidOut, outToken.displayDecimals)} {outToken.symbol} in fees
      </p>
    </section>
  );
}

function DerivationRow({
  label,
  value,
  tone,
  emphasis,
}: {
  label: string;
  value: string;
  tone?: boolean;
  emphasis?: boolean;
}) {
  return (
    <div className="grid grid-cols-[1fr_auto] items-center gap-4 bg-surface px-5 py-3">
      <dt className="text-[13px] leading-[1.4] text-text-dim">{label}</dt>
      <dd
        className={`tnum leading-none ${emphasis ? "text-[15px] font-semibold" : "text-[13px]"}`}
        style={{ color: tone ? "var(--tone)" : "var(--color-text)" }}
      >
        {value}
      </dd>
    </div>
  );
}
