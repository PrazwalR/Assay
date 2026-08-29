import Link from "next/link";

import { QuoteCurve } from "@/components/quote/QuoteCurve";
import { LiveReferenceStrip } from "@/components/quote/LiveReferenceStrip";
import {
  CAP_BINDS_AT_TICKS,
  DEPLOYED,
  FLOOR_BINDS_AT_TICKS,
  GAS,
  PERMISSION_MASK,
} from "@/lib/protocol/config";

export default function OverviewPage() {
  return (
    <main>
      <section className="mx-auto max-w-[1240px] px-6 pt-[76px]">
        <p className="mb-7 inline-flex items-center gap-2 rounded-[20px] border border-border-2 bg-surface-2 py-[5px] pl-2 pr-[11px] font-mono text-[11.5px] font-medium leading-none text-text-dim">
          <span className="size-[5px] rounded-full bg-accent" />
          Uniswap v4 hook · permission mask {PERMISSION_MASK}
        </p>

        <h1 className="mb-[22px] max-w-[16em] text-[clamp(38px,5.4vw,74px)] font-semibold leading-[1.03] tracking-[-0.035em] text-balance">
          Volatility is the same for everyone in a block. Adverse selection is not.
        </h1>

        <p className="mb-9 max-w-[60ch] text-[17px] leading-[1.6] text-text-dim text-pretty">
          Every dynamic-fee hook shipping today sets the fee from volatility — so a retail swap
          and a top-of-block arbitrage pay the same rate, though one is the liquidity
          provider&apos;s entire revenue and the other is their entire loss. Assay prices each
          swap on the drift it captures against a cached reference, signed by direction.
        </p>

        <div className="mb-16 flex flex-wrap gap-3">
          <Link
            href="/swap"
            className="flex h-11 items-center rounded-[9px] bg-text px-5 text-sm font-semibold text-bg transition-transform hover:-translate-y-px hover:shadow-[0_6px_22px_rgb(231_234_236/0.16)]"
          >
            Open the exchange
          </Link>
          <Link
            href="/docs/mechanism"
            className="flex h-11 items-center rounded-[9px] border border-border-2 bg-surface-2 px-5 text-sm font-semibold text-text transition-colors hover:border-border-hover"
          >
            Read the mechanism
          </Link>
        </div>
      </section>

      <section className="mx-auto max-w-[1240px] px-6 pb-[84px]">
        <QuoteCurve />
      </section>

      <section className="mx-auto max-w-[1240px] px-6 pb-[84px]">
        <LiveReferenceStrip />
      </section>

      <section className="mx-auto max-w-[1240px] px-6 pb-[84px]">
        <div className="mb-6">
          <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            The mechanism, in three facts
          </p>
          <h2 className="max-w-[24ch] text-[26px] font-semibold leading-[1.2] tracking-[-0.02em]">
            One parameter, one signal, and a bound on every quote.
          </h2>
        </div>

        <div className="grid gap-5 sm:grid-cols-2 lg:grid-cols-3">
          <article className="rounded-2xl border border-border-2 bg-surface p-6">
            <p className="tnum mb-3 text-[28px] leading-none text-accent">
              {DEPLOYED.captureShareBps / 100}%
            </p>
            <h3 className="mb-2 text-[15px] font-semibold leading-tight">
              of captured drift, charged as fee
            </h3>
            <p className="text-[13px] leading-[1.6] text-text-dim">
              The one free parameter, calibrated for the least bad worst case across two
              independent windows of flow rather than the best case under one assumption. At this
              share each tick of drift adds ten pips.
            </p>
          </article>

          <article className="rounded-2xl border border-border-2 bg-surface p-6">
            <p className="tnum mb-3 text-[28px] leading-none text-text">
              {FLOOR_BINDS_AT_TICKS} … {CAP_BINDS_AT_TICKS.toLocaleString("en-US")}
            </p>
            <h3 className="mb-2 text-[15px] font-semibold leading-tight">
              ticks between the floor and the cap
            </h3>
            <p className="text-[13px] leading-[1.6] text-text-dim">
              Below {Math.abs(FLOOR_BINDS_AT_TICKS)} ticks of adverse drift the quote sits at the
              0.01% floor; above {CAP_BINDS_AT_TICKS.toLocaleString("en-US")} it saturates at the
              1.00% ceiling. Everything a router reads from{" "}
              <span className="font-mono text-text">feeBounds()</span> holds.
            </p>
          </article>

          <article className="rounded-2xl border border-border-2 bg-surface p-6">
            <p className="tnum mb-3 text-[28px] leading-none text-benign">
              {GAS.ordinarySwap.toLocaleString("en-US")}
            </p>
            <h3 className="mb-2 text-[15px] font-semibold leading-tight">
              gas on an ordinary swap
            </h3>
            <p className="text-[13px] leading-[1.6] text-text-dim">
              Against a {GAS.ordinaryBudget.toLocaleString("en-US")} budget. The reference is
              cached in one packed slot and refreshed at most once per block, so the common path
              makes no external call at all.
            </p>
          </article>
        </div>
      </section>

      <section className="mx-auto max-w-[1240px] px-6 pb-[100px]">
        <div className="rounded-2xl border border-warm/20 bg-[#100E0A] p-8">
          <h2 className="mb-3 text-[20px] font-semibold leading-tight tracking-[-0.02em] text-warm">
            What this does not yet show
          </h2>
          <p className="mb-4 max-w-[70ch] text-[14px] leading-[1.65] text-[#9A8B72] text-pretty">
            The hook is deployed to Base Sepolia and the reference oracle is live — the price
            above is read from it. But <strong className="font-semibold">no pool has been
            initialised against the hook yet</strong>, so there is no trading history, no TVL and
            no swap events to show. Every pool-derived figure on this site is a labelled fixture.
          </p>
          <p className="max-w-[70ch] text-[14px] leading-[1.65] text-[#9A8B72] text-pretty">
            Separately, the adverse-selection gate does not currently pass: the mechanism is
            implemented and the arithmetic is tested, but the evidence that it improves liquidity
            provider outcomes is not established.{" "}
            <Link href="/docs/risk" className="text-warm underline underline-offset-2">
              The full result is in the docs
            </Link>
            , because a claim this project cannot support is not one it should make on a landing
            page.
          </p>
        </div>
      </section>
    </main>
  );
}
