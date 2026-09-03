"use client";

import { useCallback } from "react";
import { formatUnits } from "viem";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { useSwapExecution } from "@/hooks/useSwapExecution";
import { useSwapQuote } from "@/hooks/useSwapQuote";
import { PrimaryCta } from "@/components/swap/PrimaryCta";
import { TxStatus } from "@/components/swap/TxStatus";
import { inputAmount, num, pipsToPct, usd } from "@/lib/format";
import { GAS } from "@/lib/protocol/config";
import { formatGasCostUsd, gasCostUsd } from "@/lib/protocol/gasCost";

export function SwapCard() {
  const { amountIn, setAmountIn, flipDirection, openModal } = useAssay();
  const { blockNumber, gasPriceWei, referenceUsd } = useLiveProtocol();
  const swap = useSwapQuote();

  const {
    tone,
    toneText,
    inToken,
    outToken,
    amount,
    amountInUnits,
    balanceIn,
    balanceInUnits,
    balanceOut,
    amountInUsd,
    netOut,
    netOutUsd,
    rate,
    minimumReceived,
    feePips,
    driftIsLive,
    referenceFresh,
    refetchBalances,
    priceLimit,
    priceImpact,
    exceedsLiquidity,
    slippage,
  } = swap;

  // A confirmed swap changes both balances and the pool's drift. Refetching immediately is what
  // keeps the next quote from being computed against the state before the swap.
  const onConfirmed = useCallback(() => refetchBalances(), [refetchBalances]);

  const execution = useSwapExecution({
    tokenInSymbol: inToken.symbol,
    amountIn: amountInUnits,
    balanceIn: balanceInUnits,
    priceLimit,
    onConfirmed,
  });

  // Gas in units is not something a trader can act on. Both inputs to the money figure are live
  // reads — the gas price from the chain, the ETH price from the same feed the hook prices
  // against — so this is a real cost, not an assumed one.
  // The costly path is the *first swap of a block*, which is when the hook refreshes its
  // reference — not whether the reference is stale. This pool trades rarely enough that a user
  // swap is almost always that first swap, so quoting the cheap path would understate it ~3x.
  const hookGas = GAS.blockBoundaryWithLiveFeed;
  const hookGasUsd = gasCostUsd(hookGas, gasPriceWei, referenceUsd);

  // Fractions are taken in base units, not on the displayed figure: MAX computed from a rounded
  // display value either leaves dust behind or asks for more than the wallet holds.
  const setFraction = (numerator: bigint, denominator: bigint) => {
    if (balanceInUnits === undefined) return;
    setAmountIn(formatUnits((balanceInUnits * numerator) / denominator, inToken.decimals));
  };

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
          <label
            htmlFor="amount-in"
            className="text-[11.5px] font-medium leading-none text-text-muted"
          >
            You pay
          </label>
          <span className="font-mono text-[11.5px] leading-none text-text-muted">
            Balance {balanceIn === undefined ? "—" : num(balanceIn, inToken.displayDecimals)}
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
              onClick={() => setFraction(1n, 2n)}
              className="h-[22px] rounded-[5px] bg-surface-5 px-2 font-mono text-[10.5px] font-medium leading-none text-text-dim hover:text-text"
            >
              50%
            </button>
            <button
              type="button"
              onClick={() => setFraction(1n, 1n)}
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
          onClick={() =>
            // Carry the quoted output into the input field, so the reversed pair keeps a
            // quotable amount instead of reinterpreting the old number as the other token.
            flipDirection(amount > 0 ? inputAmount(netOut, outToken.decimals) : undefined)
          }
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
            Balance {balanceOut === undefined ? "—" : num(balanceOut, outToken.displayDecimals)}
          </span>
        </div>
        <div className="flex items-center gap-3">
          <output
            className={`tnum min-w-0 flex-1 overflow-hidden text-ellipsis text-[30px] font-medium leading-[1.1] ${
              amount > 0 ? "text-text" : "text-text-ghost"
            }`}
          >
            {amount > 0 ? num(netOut, outToken.displayDecimals) : "0.00"}
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
          <span
            className="size-[6px] flex-none rounded-full"
            style={{ background: "var(--tone)" }}
          />
          <span
            className="text-[12.5px] font-medium leading-[1.35]"
            style={{ color: "var(--tone)" }}
          >
            {toneText}
          </span>
        </div>
        <span
          className="tnum flex-none text-[15px] font-semibold leading-none"
          style={{ color: "var(--tone)" }}
        >
          {pipsToPct(feePips)}
        </span>
      </div>

      <dl className="mt-[11px] grid gap-px overflow-hidden rounded-[11px] border border-border bg-border">
        <DetailRow label="Rate">
          1 {inToken.symbol} = {num(rate, rate > 100 ? 2 : 6)} {outToken.symbol}
        </DetailRow>
        <DetailRow label="Minimum received">
          {num(minimumReceived, outToken.displayDecimals)} {outToken.symbol}
        </DetailRow>
        <DetailRow label="Price impact">
          <span className={priceImpact > 0.02 ? "text-warm" : undefined}>
            {(priceImpact * 100).toFixed(2)}%
          </span>
        </DetailRow>
        <DetailRow label="Hook gas">
          {hookGas.toLocaleString("en-US")}
          <span className="ml-2 text-text-muted">{formatGasCostUsd(hookGasUsd)}</span>
        </DetailRow>
      </dl>

      <PrimaryCta
        stage={execution.stage}
        symbolIn={inToken.symbol}
        symbolOut={outToken.symbol}
        // Connecting is the one action the execution machine does not own: it opens a modal
        // rather than sending a transaction.
        onAct={execution.stage === "disconnected" ? () => openModal("wallet") : execution.act}
      />

      <TxStatus
        stage={execution.stage}
        isMining={execution.isMining}
        hash={execution.hash}
        error={execution.error}
      />

      {exceedsLiquidity ? (
        <div className="mt-3 rounded-[11px] border border-hot/30 bg-[#150E0C] px-[15px] py-[13px]">
          <p className="mb-[5px] text-[12.5px] font-semibold leading-tight text-hot">
            Larger than the pool
          </p>
          <p className="text-[12.5px] leading-[1.5] text-[#9A8480]">
            This trade would exhaust the seeded liquidity range, so the output above is an upper
            bound the pool cannot actually pay. The pool holds roughly 38 USDC of depth. Reduce
            the amount.
          </p>
        </div>
      ) : null}

      {execution.stage === "needs-approval" ? (
        <p className="mt-3 text-[11.5px] leading-[1.55] text-text-muted">
          v4 routes swaps through a callback an ordinary account cannot perform, so the trade goes
          via a router contract — and the router needs permission to pull your {inToken.symbol}.
          The approval is for this amount only, not unlimited.
        </p>
      ) : null}

      <div className="mt-3 flex items-center justify-center gap-2 font-mono text-[11px] leading-none text-text-muted">
        <span
          className={`size-[5px] rounded-full ${
            !driftIsLive ? "bg-text-muted" : referenceFresh ? "bg-benign" : "bg-warm"
          }`}
          style={{ animation: "assayPulse 2.6s ease-in-out infinite" }}
        />
        <span>
          {!driftIsLive
            ? "reading the pool…"
            : referenceFresh
              ? `quoted from the live curve · bounded at ${(slippage * 100).toFixed(1)}%`
              : "reference stale · degrading to maxFeePips"}
        </span>
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
        className="flex size-6 items-center justify-center rounded-full font-mono text-[8.5px] font-semibold leading-none text-bg"
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
