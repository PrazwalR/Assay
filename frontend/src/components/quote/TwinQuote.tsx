"use client";

import { useSwapQuote } from "@/hooks/useSwapQuote";
import { pipsToBp } from "@/lib/format";

/**
 * The product thesis, as two numbers side by side.
 *
 * Same block, same pool, same drift, opposite directions — and a spread between them. A
 * volatility-driven hook has no way to produce this difference, because volatility is a
 * property of the block and not of the order. Measured on chain in
 * `test/integration/DynamicPricing.t.sol`.
 */
export function TwinQuote() {
  // "Right now" has to mean the live pool, not a random walk running beside it -- and when
  // it is not live, the panel has to say so rather than assert a reading it does not have.
  const { drift, feePips, twinFeePips, tone, driftIsLive } = useSwapQuote();
  const spread = (feePips - twinFeePips) / 100;

  return (
    <section data-tone={tone} className="rounded-2xl border border-border-2 bg-surface px-5 py-[18px]">
      <header className="mb-4">
        <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Same block, same pool
        </p>
        <h2 className="text-[14.5px] font-medium leading-[1.4]">
          What the opposite direction is quoted right now
        </h2>
      </header>

      <div className="grid gap-[14px] sm:grid-cols-2">
        <article
          className="rounded-xl border px-4 py-[14px]"
          style={{ background: "var(--tone-wash)", borderColor: "var(--tone-border)" }}
        >
          <p
            className="mb-3 font-mono text-[11px] font-medium uppercase leading-none tracking-[0.08em]"
            style={{ color: "var(--tone)" }}
          >
            {drift >= 0 ? "This swap · capturing" : "This swap · trading away"}
          </p>
          <p className="tnum mb-[9px] text-[26px] font-semibold leading-none" style={{ color: "var(--tone)" }}>
            {pipsToBp(feePips)}
          </p>
          <p className="text-[12px] leading-[1.5] text-text-dim">
            Captures {Math.abs(drift).toLocaleString("en-US")} ticks of drift. Charged a share of
            what it picks off.
          </p>
        </article>

        <article className="rounded-xl border border-benign/20 bg-benign/[0.05] px-4 py-[14px]">
          <p className="mb-3 font-mono text-[11px] font-medium uppercase leading-none tracking-[0.08em] text-benign">
            Opposite direction
          </p>
          <p className="tnum mb-[9px] text-[26px] font-semibold leading-none text-benign">
            {pipsToBp(twinFeePips)}
          </p>
          <p className="text-[12px] leading-[1.5] text-text-dim">
            Trades away from the reference, captures nothing, quoted below base.
          </p>
        </article>
      </div>

      <p className="mt-[14px] text-[12px] leading-[1.55] text-text-muted">
        Spread of <span className="tnum text-text-dim">{spread.toFixed(2)} bp</span> between two
        swaps a volatility-driven hook would quote identically. Measured in{" "}
        <span className="font-mono">test/integration/DynamicPricing.t.sol</span> at 100 bp
        against 1 bp.
      </p>

      <p className="mt-2 font-mono text-[10.5px] leading-none text-text-muted">
        {driftIsLive ? "live drift, read from the hook" : "drift simulated — pool not read yet"}
      </p>
    </section>
  );
}
