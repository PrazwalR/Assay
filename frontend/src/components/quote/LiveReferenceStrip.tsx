"use client";

import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useLivePool } from "@/hooks/useLivePool";
import { CONTRACTS, explorerAddress, shortAddress } from "@/lib/protocol/config";
import { pipsToBp, pipsToPct, signed, usd } from "@/lib/format";
import { quote } from "@/lib/protocol/feeBlend";


/**
 * The genuinely-live strip. Everything in it comes from a real contract read on Base Sepolia,
 * which is precisely why it is separated from the fixture-backed figures elsewhere: a "live"
 * badge that sometimes means live and sometimes means plausible is worth nothing.
 *
 * The badge is driven by `isLive`, which is false while loading and false on any read failure,
 * so it is never shown optimistically.
 */
export function LiveReferenceStrip() {
  const { isLive, isLoading, referenceUsd, referenceFresh, bounds, boundsMatchConfig, blockNumber } =
    useLiveProtocol();
  const pool = useLivePool();

  // The live drift, and what the hook would charge the two directions against it right now.
  // This is the product's whole claim reduced to two numbers, and both come off the chain.
  const drift = pool.driftZeroForOne;
  const towardFee = drift === undefined ? undefined : quote(drift, pool.referenceFresh, bounds);
  const awayFee = drift === undefined ? undefined : quote(-drift, pool.referenceFresh, bounds);

  return (
    <div className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <div className="flex flex-wrap items-center justify-between gap-4 px-6 pb-4 pt-5">
        <div>
          <p className="mb-[9px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Read from the chain, right now
          </p>
          <p className="max-w-[56ch] text-[15px] font-medium leading-[1.45] text-text">
            The reference price, the fee bounds and the block below are live contract reads —
            not fixtures.
          </p>
        </div>
        <span
          className={`flex flex-none items-center gap-2 rounded-lg border px-[11px] py-2 font-mono text-[11.5px] font-medium leading-none ${
            isLive
              ? "border-benign/25 bg-benign/[0.06] text-benign"
              : "border-border-2 bg-surface-2 text-text-muted"
          }`}
        >
          <span
            className={`size-[6px] rounded-full ${isLive ? "bg-benign" : "bg-text-muted"}`}
            style={isLive ? { animation: "assayPulse 2.4s ease-in-out infinite" } : undefined}
          />
          {isLoading ? "reading…" : isLive ? "live" : "unavailable"}
        </span>
      </div>

      <dl className="grid gap-px border-t border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
        <div className="bg-surface px-6 py-5">
          <dt className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Reference price
          </dt>
          <dd className="tnum text-[25px] leading-none">{usd(referenceUsd)}</dd>
          <dd className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            ETH/USD via Chainlink
          </dd>
        </div>

        <div className="bg-surface px-6 py-5">
          <dt className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Reference state
          </dt>
          <dd
            className={`text-[25px] font-medium leading-none ${
              referenceFresh ? "text-benign" : "text-warm"
            }`}
          >
            {referenceFresh ? "fresh" : "stale"}
          </dd>
          <dd className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            {referenceFresh
              ? "inside its staleness bound"
              : "quoting the ceiling, not reverting"}
          </dd>
        </div>

        <div className="bg-surface px-6 py-5">
          <dt className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Advertised range
          </dt>
          <dd className="tnum text-[25px] leading-none">
            {pipsToPct(bounds.minFeePips)} – {pipsToPct(bounds.maxFeePips)}
          </dd>
          <dd className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            {boundsMatchConfig ? (
              <>base {pipsToPct(bounds.baseFeePips)}</>
            ) : (
              <span className="text-warm">differs from this build&apos;s constants</span>
            )}
          </dd>
        </div>

        <div className="bg-surface px-6 py-5">
          <dt className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Block
          </dt>
          <dd className="tnum text-[25px] leading-none">
            {blockNumber ? blockNumber.toLocaleString("en-US") : "—"}
          </dd>
          <dd className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            Base Sepolia · 84532
          </dd>
        </div>
      </dl>

      {/*
        The live pool. Kept in the same panel as the reference because the two only mean
        anything together: a fee is the gap between them, priced.
      */}
      <div className="grid gap-px border-t border-border bg-border sm:grid-cols-3">
        <div className="bg-surface px-6 py-5">
          <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Pool drift
          </p>
          <p className="tnum text-[25px] leading-none">
            {drift === undefined ? "—" : `${signed(drift)} ticks`}
          </p>
          <p className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            {pool.poolTick === undefined
              ? "reading…"
              : `pool ${signed(pool.poolTick)} · ref ${signed(pool.referenceTick ?? 0)}`}
          </p>
        </div>

        <div className="bg-surface px-6 py-5">
          <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Toward the reference
          </p>
          <p className="tnum text-[25px] leading-none text-warm">
            {towardFee === undefined ? "—" : pipsToBp(towardFee)}
          </p>
          <p className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            captures the drift
          </p>
        </div>

        <div className="bg-surface px-6 py-5">
          <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
            Away from it
          </p>
          <p className="tnum text-[25px] leading-none text-benign">
            {awayFee === undefined ? "—" : pipsToBp(awayFee)}
          </p>
          <p className="mt-[7px] font-mono text-[11.5px] leading-none text-text-muted">
            captures nothing
          </p>
        </div>
      </div>

      <p className="border-t border-border px-6 py-3 text-[12px] leading-[1.5] text-text-dim">
        Those two figures are the entire product. Same pool, same instant, same drift — quoted
        differently because one trade takes value from liquidity providers and the other does
        not. A volatility-driven hook cannot tell them apart, because volatility is a property of
        the block and not of the order.
      </p>

      <p className="border-t border-border px-6 py-3 font-mono text-[11.5px] leading-[1.5] text-text-muted">
        hook{" "}
        <a href={explorerAddress(CONTRACTS.hook)} target="_blank" rel="noreferrer">
          {shortAddress(CONTRACTS.hook)} ↗
        </a>{" "}
        · oracle{" "}
        <a href={explorerAddress(CONTRACTS.oracleAdapter)} target="_blank" rel="noreferrer">
          {shortAddress(CONTRACTS.oracleAdapter)} ↗
        </a>
      </p>
    </div>
  );
}
