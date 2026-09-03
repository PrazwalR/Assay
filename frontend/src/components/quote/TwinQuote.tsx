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

  // A spread is a distance, so it is reported as one. Signing it by which side happens to be
  // "this swap" produced a negative number whenever the trader was on the floor side, which
  // reads as an error rather than as the asymmetry this panel exists to show.
  const spread = Math.abs(feePips - twinFeePips) / 100;

  // Which card is the capturing one is a property of the drift, not of the layout. Both blurbs
  // used to be static, so on a trading-away swap the left card said "captures N ticks" beneath
  // a floor quote and the right card said "captures nothing, quoted below base" beneath the
  // higher number -- each describing the other one.
  const thisSwapCaptures = drift >= 0;

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
            {thisSwapCaptures ? "This swap · capturing" : "This swap · trading away"}
          </p>
          <p className="tnum mb-[9px] text-[26px] font-semibold leading-none" style={{ color: "var(--tone)" }}>
            {pipsToBp(feePips)}
          </p>
          <p className="text-[12px] leading-[1.5] text-text-dim">
            {thisSwapCaptures ? (
              <>
                Captures {Math.abs(drift).toLocaleString("en-US")} ticks of drift. Charged a
                share of what it picks off.
              </>
            ) : (
              <>Moves away from the reference, captures nothing, quoted at the floor.</>
            )}
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
            {thisSwapCaptures ? (
              <>Moves away from the reference, captures nothing, quoted at the floor.</>
            ) : (
              <>
                Captures {Math.abs(drift).toLocaleString("en-US")} ticks of drift. Charged a
                share of what it picks off.
              </>
            )}
          </p>
        </article>
      </div>

      {/* The citation used to read "measured at 100 bp against 1 bp". That test asserts an
          inequality -- `assertGt(capturingDrift, addingToDrift)` -- not those two figures, which
          are simply the configured ceiling and floor. Cite what it actually proves. */}
      <p className="mt-[14px] text-[12px] leading-[1.55] text-text-muted">
        Spread of <span className="tnum text-text-dim">{spread.toFixed(2)} bp</span> between two
        swaps a volatility-driven hook would quote identically. Both figures above are computed
        from the drift the hook itself reports.{" "}
        <span className="font-mono">test/integration/DynamicPricing.t.sol</span> pins the
        property on chain: in one block, against one reference, the swap capturing the drift is
        quoted strictly higher than the swap adding to it.
      </p>

      <p className="mt-2 font-mono text-[10.5px] leading-none text-text-muted">
        {driftIsLive ? "live drift, read from the hook" : "drift simulated — pool not read yet"}
      </p>
    </section>
  );
}
