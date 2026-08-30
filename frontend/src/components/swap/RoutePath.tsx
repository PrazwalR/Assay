"use client";

import { AssayMark } from "@/components/brand/AssayMark";
import { useAssay } from "@/components/Providers";
import { useSwapQuote } from "@/hooks/useSwapQuote";
import { CONTRACTS, explorerAddress, shortAddress } from "@/lib/protocol/config";
import { signed } from "@/lib/format";

export function RoutePath() {
  const { feePips, dataMode } = useAssay();
  const { inToken, outToken, poolTick, referenceTick } = useSwapQuote();

  return (
    <section className="rounded-2xl border border-border-2 bg-surface px-5 py-[18px]">
      <header className="mb-[15px] flex items-center justify-between gap-4">
        <p className="font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Execution path
        </p>
        <p className="font-mono text-[11.5px] leading-none text-text-muted">1 hop · v4 singleton</p>
      </header>

      <div className="mb-4 flex flex-wrap items-center gap-[10px]">
        <RouteToken symbol={inToken.symbol} glyph={inToken.glyph} color={inToken.color} />
        <span className="font-mono text-[13px] leading-none text-text-ghost">──</span>
        {/* The accent is reserved; this node is one of the few places spec §2 grants it. */}
        <div className="flex h-[34px] items-center gap-[9px] rounded-[9px] border border-accent/25 bg-accent/[0.09] px-[13px]">
          <AssayMark className="size-[14px] text-accent" />
          <span className="font-mono text-[12.5px] font-medium leading-none text-accent">
            AssayHook · {feePips.toLocaleString("en-US")} pips
          </span>
        </div>
        <span className="font-mono text-[13px] leading-none text-text-ghost">──</span>
        <RouteToken symbol={outToken.symbol} glyph={outToken.glyph} color={outToken.color} />
      </div>

      <dl className="grid gap-px overflow-hidden rounded-[10px] border border-border bg-border">
        <RouteRow label="hook">
          <a href={explorerAddress(CONTRACTS.hook)} target="_blank" rel="noreferrer">
            {shortAddress(CONTRACTS.hook)} ↗
          </a>
        </RouteRow>
        <RouteRow label="reference">
          <span className="text-text-dim">
            {dataMode === "testnet"
              ? `${shortAddress(CONTRACTS.oracleAdapter)} · cached`
              : "Chainlink ETH/USD · cached"}
          </span>
        </RouteRow>
        <RouteRow label="pool tick / reference tick">
          <span className="tnum text-text-dim">
            {poolTick === undefined || referenceTick === undefined
              ? "reading…"
              : `${signed(poolTick)} / ${signed(referenceTick)}`}
          </span>
        </RouteRow>
      </dl>

      <p className="mt-3 text-[11.5px] leading-[1.5] text-text-muted">
        Both ticks are read from the deployed hook&apos;s own state. Their difference, signed by
        the direction of this swap, is the entire input to the fee above.
      </p>
    </section>
  );
}

function RouteToken({ symbol, glyph, color }: { symbol: string; glyph: string; color: string }) {
  return (
    <div className="flex h-[34px] items-center gap-2 rounded-[17px] border border-border-2 bg-surface-4 py-0 pl-2 pr-3">
      <span
        className="flex size-5 items-center justify-center rounded-full font-mono text-[8px] font-semibold leading-none text-bg"
        style={{ background: color }}
      >
        {glyph}
      </span>
      <span className="text-[12.5px] font-medium leading-none">{symbol}</span>
    </div>
  );
}

function RouteRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-[14px] bg-bg px-[13px] py-[10px]">
      <dt className="font-mono text-[12px] leading-none text-text-muted">{label}</dt>
      <dd className="font-mono text-[12px] leading-none">{children}</dd>
    </div>
  );
}
