"use client";

import { useAccount } from "wagmi";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useSwapQuote } from "@/hooks/useSwapQuote";
import { num, pipsToPct, usd } from "@/lib/format";
import { GAS } from "@/lib/protocol/config";
import { formatGasCostUsd, gasCostUsd } from "@/lib/protocol/gasCost";

export function SwapCard() {
  const {
    tone,
    toneText,
    feePips,
    amountIn,
    setAmountIn,
    flipDirection,
    openModal,
    referenceFresh,
    toggleReferenceFresh,
  } = useAssay();
  const { blockNumber, gasPriceWei, referenceUsd } = useLiveProtocol();
  const { isConnected } = useAccount();
  const swap = useSwapQuote();

  // Gas in units is not something a trader can act on. Both inputs to the money figure are live
  // reads — the gas price from the chain, the ETH price from the same feed the hook prices
  // against — so this is a real cost, not an assumed one.
  const hookGas = referenceFresh ? GAS.ordinarySwap : GAS.blockBoundary;
  const hookGasUsd = gasCostUsd(hookGas, gasPriceWei, referenceUsd);

  const {
    inToken,
    outToken,
    amount,
    insufficientBalance,
    amountInUsd,
    netOut,
    netOutUsd,
    rate,
    minimumReceived,
  } = swap;

  return (
    <section
      data-tone={tone}
      className="w-full max-w-[460px] justify-self-start rounded-[18px] border border-border-2 bg-surface p-[18px]"
      style={{ boxShadow: "0 24px 60px -30px rgb(0 0 0 / 0.9)" }}
    >
      <header className="mb-4 flex items-center justify-between px-[2px]">
        <div className="flex items-baseline gap-[10px]">
          <h1 className="text-[17px] font-semibold leading-none tracking-[-0.01em]">Swap</h1>
          <span className="font-mono text-[11.5px] leading-none text-text-muted">
            block {blockNumber ? blockNumber.toLocaleString("en-US") : "—"}
          </span>
        </div>
        <button
          type="button"
          onClick={() => openModal("settings")}
          title="Slippage and deadline"
          aria-label="Transaction settings"
          className="size-[30px] rounded-lg border border-border-2 bg-surface-4 font-mono text-[13px] leading-none text-text-dim transition-colors hover:border-border-hover hover:text-text"
        >
          ⚙
        </button>
      </header>

      <div className="rounded-2xl border border-border bg-surface-3 px-4 pb-[13px] pt-[15px] transition-colors focus-within:border-accent/40">
        <div className="mb-[9px] flex items-center justify-between">
          <label htmlFor="amount-in" className="text-[11.5px] font-medium leading-none text-text-muted">
            You pay
          </label>
          <span className="font-mono text-[11.5px] leading-none text-text-muted">
            Balance {num(inToken.balance, inToken.decimals)}
          </span>
        </div>
        <div className="flex items-center gap-3">
          <input
            id="amount-in"
            value={amountIn}
            onChange={(event) => setAmountIn(event.target.value.replace(/[^0-9.]/g, ""))}
            inputMode="decimal"
            placeholder="0.00"
            className="tnum min-w-0 flex-1 border-0 bg-transparent p-0 text-[30px] font-medium leading-[1.1] text-text outline-none"
          />
          <TokenButton
            symbol={inToken.symbol}
            glyph={inToken.glyph}
            color={inToken.color}
            onClick={() => openModal("tokenIn")}
          />
        </div>
        <div className="mt-[9px] flex items-center justify-between">
          <span className="font-mono text-[12px] leading-none text-text-muted">
            {usd(amountInUsd)}
          </span>
          <div className="flex gap-[5px]">
            <button
              type="button"
              onClick={() => setAmountIn((inToken.balance / 2).toFixed(inToken.decimals))}
              className="h-[22px] rounded-[5px] bg-surface-5 px-2 font-mono text-[10.5px] font-medium leading-none text-text-dim hover:text-text"
            >
              50%
            </button>
            <button
              type="button"
              onClick={() => setAmountIn(inToken.balance.toFixed(inToken.decimals))}
              className="h-[22px] rounded-[5px] bg-surface-5 px-2 font-mono text-[10.5px] font-medium leading-none text-text-dim hover:text-text"
            >
              MAX
            </button>
          </div>
        </div>
      </div>

      <div className="relative z-[2] -my-[9px] flex items-center gap-[10px] px-1">
        <div className="h-px flex-1 bg-border" />
        <button
          type="button"
          onClick={flipDirection}
          aria-label="Reverse direction"
          className="flex size-[34px] items-center justify-center rounded-[11px] border border-border-2 bg-surface-5 font-mono text-sm leading-none text-text transition-[transform,background-color,border-color] duration-[280ms] ease-[cubic-bezier(.34,1.56,.64,1)] hover:rotate-180 hover:scale-[1.08] hover:border-accent hover:bg-accent hover:text-bg"
        >
          ↓
        </button>
        <div className="h-px flex-1 bg-border" />
      </div>

      <div className="mt-[9px] rounded-2xl border border-border bg-surface-3 px-4 pb-[13px] pt-[15px]">
        <div className="mb-[9px] flex items-center justify-between">
          <span className="text-[11.5px] font-medium leading-none text-text-muted">
            You receive
          </span>
          <span className="font-mono text-[11.5px] leading-none text-text-muted">
            Balance {num(outToken.balance, outToken.decimals)}
          </span>
        </div>
        <div className="flex items-center gap-3">
          <output
            className={`tnum min-w-0 flex-1 overflow-hidden text-ellipsis text-[30px] font-medium leading-[1.1] ${
              amount > 0 ? "text-text" : "text-text-ghost"
            }`}
          >
            {amount > 0 ? num(netOut, outToken.decimals) : "0.00"}
          </output>
          <TokenButton
            symbol={outToken.symbol}
            glyph={outToken.glyph}
            color={outToken.color}
            onClick={() => openModal("tokenOut")}
          />
        </div>
        <p className="mt-[9px] font-mono text-[12px] leading-none text-text-muted">
          {usd(netOutUsd)}
        </p>
      </div>

      {/* The quote, and the one sentence explaining which flow it thinks this is. */}
      <div
        className="mt-[13px] flex items-center justify-between gap-3 rounded-[11px] border px-[14px] py-[11px]"
        style={{ background: "var(--tone-wash)", borderColor: "var(--tone-border)" }}
      >
        <div className="flex min-w-0 items-center gap-[9px]">
          <span className="size-[6px] flex-none rounded-full" style={{ background: "var(--tone)" }} />
          <span className="text-[12.5px] font-medium leading-[1.35]" style={{ color: "var(--tone)" }}>
            {toneText}
          </span>
        </div>
        <span className="tnum flex-none text-[15px] font-semibold leading-none" style={{ color: "var(--tone)" }}>
          {pipsToPct(feePips)}
        </span>
      </div>

      <dl className="mt-[11px] grid gap-px overflow-hidden rounded-[11px] border border-border bg-border">
        <DetailRow label="Rate">
          1 {inToken.symbol} = {num(rate, rate > 100 ? 2 : 6)} {outToken.symbol}
        </DetailRow>
        <DetailRow label="Minimum received">
          {num(minimumReceived, outToken.decimals)} {outToken.symbol}
        </DetailRow>
        <DetailRow label="Hook gas">
          {hookGas.toLocaleString("en-US")}
          <span className="ml-2 text-text-muted">{formatGasCostUsd(hookGasUsd)}</span>
        </DetailRow>
      </dl>

      {insufficientBalance ? (
        <ErrorPanel
          title="Insufficient balance"
          body={`You are trying to pay ${num(amount, inToken.decimals)} ${inToken.symbol} but hold ${num(inToken.balance, inToken.decimals)}. Reduce the amount, or use MAX.`}
        />
      ) : null}

      {!referenceFresh ? (
        <ErrorPanel
          title="Reference price is stale"
          body="The oracle has not produced a usable reading inside its staleness bound, so the hook cannot tell which flow it is facing. It quotes the 1.00% ceiling rather than reverting — the conservative direction. Wait for the next feed update, or swap knowing the ceiling applies."
        />
      ) : null}

      {/*
        The honest CTA. The prototype assumed a pool existed; none does, so offering "Swap"
        would be the one lie this interface cannot afford. Naming the gap is spec §9's rule
        applied to the most prominent control on the page.
      */}
      <button
        type="button"
        disabled
        className="mt-3 h-[50px] w-full cursor-not-allowed rounded-xl bg-surface-4 text-[14.5px] font-semibold text-text-muted"
      >
        {isConnected ? "No pool initialised — swaps are not live" : "Connect wallet"}
      </button>

      <p className="mt-3 text-[11.5px] leading-[1.55] text-text-muted">
        The hook is deployed and the reference is fresh, but no pool has been created against it
        yet, so there is nothing to swap. The quote above is computed from the real formula and
        the real reference price.
      </p>

      <div className="mt-3 flex items-center justify-center gap-2 font-mono text-[11px] leading-none text-text-muted">
        <span
          className={`size-[5px] rounded-full ${referenceFresh ? "bg-benign" : "bg-warm"}`}
          style={{ animation: "assayPulse 2.6s ease-in-out infinite" }}
        />
        <span>
          {referenceFresh
            ? "reference fresh · refreshed at most once per block"
            : "reference stale · degrading to maxFeePips"}
        </span>
        <button
          type="button"
          onClick={toggleReferenceFresh}
          className="text-accent underline underline-offset-2"
        >
          simulate
        </button>
      </div>
    </section>
  );
}

function TokenButton({
  symbol,
  glyph,
  color,
  onClick,
}: {
  symbol: string;
  glyph: string;
  color: string;
  onClick: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className="flex h-[38px] flex-none items-center gap-2 rounded-[19px] border border-border-2 bg-surface-5 py-0 pl-[7px] pr-[10px] text-text transition-transform hover:scale-[1.03] hover:border-border-hover"
    >
      <span
        className="flex size-6 items-center justify-center rounded-full font-mono text-[9.5px] font-semibold leading-none text-bg"
        style={{ background: color }}
      >
        {glyph}
      </span>
      <span className="text-sm font-semibold leading-none">{symbol}</span>
      <span className="text-[9px] text-text-muted">▾</span>
    </button>
  );
}

function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="flex items-center justify-between gap-[14px] bg-surface px-[14px] py-[10px]">
      <dt className="text-[12.5px] leading-none text-text-muted">{label}</dt>
      <dd className="tnum text-[12.5px] leading-none text-text-dim">{children}</dd>
    </div>
  );
}

function ErrorPanel({ title, body }: { title: string; body: string }) {
  return (
    <div
      className="mt-3 rounded-[11px] border border-hot/30 bg-[#150E0C] px-[15px] py-[13px]"
      style={{ animation: "assayRise 0.24s ease" }}
    >
      <p className="mb-[5px] text-[12.5px] font-semibold leading-tight text-hot">{title}</p>
      <p className="text-[12.5px] leading-[1.5] text-[#9A8480]">{body}</p>
    </div>
  );
}
