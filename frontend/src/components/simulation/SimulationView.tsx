"use client";

import { useState } from "react";
import { useAccount, useSwitchChain } from "wagmi";

import { useAssay } from "@/components/Providers";
import { useSimulation } from "@/hooks/useSimulation";
import { Origin } from "@/components/simulation/Origin";
import { BASE_SEPOLIA_CHAIN_ID, explorerTx } from "@/lib/protocol/config";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { DEMO_MODE } from "@/lib/demoMode";
import { pipsToBp, pipsToPct, signed, usd } from "@/lib/format";
import type { ExecutedTx, Scenario } from "@/lib/simulation/types";

/**
 * The simulation surface.
 *
 * Same protocol, same libraries, same pool — the only difference is that the execution is
 * slowed down and every intermediate state is exposed. Both legs are real transactions on Base
 * Sepolia; the one artificial ingredient is that we open the mispricing ourselves instead of
 * waiting for the market to, which the copy says outright rather than implying otherwise.
 */
export function SimulationView() {
  const [dislocationUsdc, setDislocationUsdc] = useState(1);
  const { openModal } = useAssay();
  const { switchChain } = useSwitchChain();
  const { isConnected } = useAccount();

  const sim = useSimulation({ dislocationUsdc, captureFraction: 1 });
  const { scenario, stages, status, txs, error } = sim;

  return (
    <main className="mx-auto max-w-[1240px] px-6 pb-[90px] pt-9">
      <header className="mb-7">
        <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Simulation · same protocol, execution exposed
        </p>
        <h1 className="mb-[10px] text-[32px] font-semibold leading-[1.15] tracking-[-0.025em]">
          Watch an arbitrage happen, one step at a time
        </h1>
        <p className="max-w-[72ch] text-[14.5px] leading-[1.6] text-text-dim text-pretty">
          Both legs below are real transactions against the real pool on Base Sepolia, priced by
          the deployed hook, with real gas and real events. The only thing staged is the
          mispricing itself: an external market move is what normally makes a pool stale, and we
          cannot move Chainlink — so the same gap is opened from the pool side instead.
        </p>
      </header>

      {!scenario ? (
        <Panel>
          <p className="text-[13.5px] leading-[1.6] text-text-dim">Reading the pool…</p>
        </Panel>
      ) : (
        <>
          <ScenarioPanel
            scenario={scenario}
            dislocationUsdc={dislocationUsdc}
            onSize={setDislocationUsdc}
            disabled={status === "running"}
          />

          <div className="mb-5 flex flex-wrap items-center gap-3">
            {!isConnected ? (
              <button
                type="button"
                onClick={() => openModal("wallet")}
                className="h-[50px] rounded-xl bg-text px-7 text-[14.5px] font-semibold text-bg transition-transform hover:-translate-y-px"
              >
                Connect a wallet to run it
              </button>
            ) : sim.wrongNetwork ? (
              <button
                type="button"
                onClick={() => switchChain({ chainId: BASE_SEPOLIA_CHAIN_ID })}
                className="h-[50px] rounded-xl bg-warm px-7 text-[14.5px] font-semibold text-bg"
              >
                Switch to Base Sepolia
              </button>
            ) : (
              <button
                type="button"
                onClick={status === "complete" || status === "failed" ? sim.reset : sim.run}
                disabled={status === "running" || !sim.canRun}
                className="flex h-[50px] items-center gap-3 rounded-xl bg-text px-7 text-[14.5px] font-semibold text-bg transition-transform enabled:hover:-translate-y-px disabled:cursor-not-allowed disabled:bg-surface-4 disabled:text-text-muted"
              >
                {status === "running" ? (
                  <span
                    aria-hidden
                    className="size-[15px] rounded-full border-2 border-current border-t-transparent"
                    style={{ animation: "assaySpin 0.9s linear infinite" }}
                  />
                ) : null}
                {status === "running"
                  ? "Running…"
                  : status === "complete"
                    ? "Run it again"
                    : status === "failed"
                      ? "Reset"
                      : "Start simulation"}
              </button>
            )}

            <p className="max-w-[46ch] text-[11.5px] leading-[1.55] text-text-muted">
              Two swaps and up to two approvals, signed in your wallet. Costs a few cents of
              testnet funds; nothing here touches mainnet.
            </p>
          </div>

          {scenario.unavailable ? (
            <Panel tone="warm">
              <p className="text-[13px] leading-[1.6] text-[#9A8B72]">{scenario.unavailable}</p>
            </Panel>
          ) : null}

          {error ? (
            <Panel tone="hot">
              <p className="mb-1 text-[12.5px] font-semibold text-hot">Run stopped</p>
              <p className="text-[12.5px] leading-[1.5] text-[#9A8480]">{error}</p>
            </Panel>
          ) : null}

          <div className="mb-5 grid gap-5 lg:grid-cols-[minmax(0,340px)_minmax(0,1fr)]">
            <Timeline stages={stages} />
            <div className="grid gap-5">
              <TransactionList txs={txs} />
              <PoolConvergence scenario={scenario} />
            </div>
          </div>

          <FeeComparison scenario={scenario} txs={txs} />
        </>
      )}
    </main>
  );
}

/* ------------------------------------------------------------------------------------------ */

function ScenarioPanel({
  scenario,
  dislocationUsdc,
  onSize,
  disabled,
}: {
  scenario: Scenario;
  dislocationUsdc: number;
  onSize: (n: number) => void;
  disabled: boolean;
}) {
  // The hook's own base fee, not this build's copy of it. The quote beside it is priced against
  // the live bounds, so reading the constant here would compare two different pools.
  const { bounds } = useLiveProtocol();
  return (
    <section className="mb-5 overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex flex-wrap items-center justify-between gap-4 px-6 pb-4 pt-5">
        <div>
          <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            The scenario
          </p>
          <p className="text-[15px] font-medium leading-[1.45] text-text">
            What the arbitrageur would see, computed from the pool as it stands right now
          </p>
        </div>
        <Origin origin="projected" />
      </header>

      <div className="flex flex-wrap items-center gap-2 border-t border-border px-6 py-3">
        <span className="font-mono text-[11px] uppercase tracking-[0.1em] text-text-muted">
          Dislocation size
        </span>
        {[0.5, 1, 2].map((size) => (
          <button
            key={size}
            type="button"
            disabled={disabled}
            onClick={() => onSize(size)}
            className={`h-[30px] rounded-lg border px-3 font-mono text-xs font-medium transition-colors disabled:opacity-50 ${
              dislocationUsdc === size
                ? "border-accent/40 bg-accent/10 text-accent"
                : "border-border-2 bg-surface-2 text-text-dim hover:border-border-hover"
            }`}
          >
            {size} USDC
          </button>
        ))}
      </div>

      <dl className="grid gap-px border-t border-border bg-border sm:grid-cols-2 lg:grid-cols-4">
        <Metric
          label="Pool price after the move"
          value={usd(scenario.dislocated.priceUsd)}
          note={`reference ${usd(scenario.referenceUsd)}`}
        />
        <Metric
          label="Spread opened"
          value={`${(scenario.spreadBefore * 100).toFixed(2)}%`}
          note={`${signed(scenario.arbitrageLeg.driftTicks)} ticks of drift`}
          tone="warm"
        />
        <Metric
          label="Fee the hook will quote"
          value={pipsToPct(scenario.arbitrageLeg.feePips)}
          note={`${pipsToBp(scenario.arbitrageLeg.feePips)} · base is ${pipsToBp(bounds.baseFeePips)}`}
          tone="accent"
        />
        <Metric
          label="Arbitrageur's net"
          value={usd(scenario.economics.netProfitUsd)}
          note={`gross ${usd(scenario.economics.grossProfitUsd)} less ${usd(scenario.economics.gasUsd)} gas`}
          tone={scenario.economics.netProfitUsd > 0 ? "benign" : "hot"}
        />
      </dl>
    </section>
  );
}

function Timeline({ stages }: { stages: ReturnType<typeof useSimulation>["stages"] }) {
  return (
    <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="px-5 pb-3 pt-[18px]">
        <p className="font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Execution timeline
        </p>
      </header>
      <ol className="border-t border-border">
        {stages.map((stage) => {
          const done = stage.status === "done";
          const active = stage.status === "active";
          const failed = stage.status === "failed";
          return (
            <li key={stage.id} className="flex gap-3 border-b border-border px-5 py-[14px] last:border-0">
              <span
                aria-hidden
                className="mt-[2px] flex size-[18px] flex-none items-center justify-center rounded-full border text-[10px] font-semibold"
                style={{
                  borderColor: failed
                    ? "var(--tone-hot)"
                    : done
                      ? "var(--tone-benign)"
                      : active
                        ? "var(--color-accent)"
                        : "var(--color-border-2)",
                  background: done ? "var(--tone-benign)" : "transparent",
                  color: done ? "var(--color-bg)" : failed ? "var(--tone-hot)" : "var(--color-accent)",
                  animation: active ? "assayPulse 1.6s ease-in-out infinite" : undefined,
                }}
              >
                {done ? "✓" : failed ? "✕" : ""}
              </span>
              <div className="min-w-0">
                <p
                  className={`text-[13px] font-medium leading-tight ${
                    done || active ? "text-text" : "text-text-muted"
                  }`}
                >
                  {stage.label}
                </p>
                {(active || done) && (
                  <p className="mt-[5px] text-[12px] leading-[1.5] text-text-dim">{stage.plain}</p>
                )}
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function TransactionList({ txs }: { txs: ReturnType<typeof useSimulation>["txs"] }) {
  return (
    <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex items-center justify-between gap-3 px-5 pb-3 pt-[18px]">
        <p className="font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Transactions
        </p>
        {txs.length > 0 ? <Origin origin="live-testnet" /> : null}
      </header>

      {txs.length === 0 ? (
        <p className="border-t border-border px-5 py-4 text-[12.5px] leading-[1.5] text-text-muted">
          Nothing submitted yet. Every hash, receipt and event shown here will come from the
          chain — none of it is generated by this page.
        </p>
      ) : (
        <ul className="border-t border-border">
          {txs.map((tx) => (
            <li key={tx.hash} className="border-b border-border px-5 py-[14px] last:border-0">
              <div className="flex flex-wrap items-baseline justify-between gap-2">
                <span className="text-[13px] font-medium text-text">{tx.label}</span>
                <span
                  className="font-mono text-[11px] leading-none"
                  style={{
                    color:
                      tx.status === "success"
                        ? "var(--tone-benign)"
                        : tx.status === "reverted"
                          ? "var(--tone-hot)"
                          : "var(--color-text-muted)",
                  }}
                >
                  {tx.status}
                </span>
              </div>
              <a
                href={explorerTx(tx.hash)}
                target="_blank"
                rel="noreferrer"
                className="mt-2 block font-mono text-[11.5px] leading-none"
              >
                {`${tx.hash.slice(0, 12)}…${tx.hash.slice(-10)}`} ↗
              </a>
              {tx.gasUsed !== undefined ? (
                <p className="tnum mt-2 text-[11.5px] leading-none text-text-muted">
                  gas {tx.gasUsed.toLocaleString("en-US")} · block{" "}
                  {tx.blockNumber?.toLocaleString("en-US")}
                </p>
              ) : null}
              {tx.events.length > 0 ? (
                <ul className="mt-3 grid gap-1">
                  {tx.events.map((event, i) => (
                    <li
                      key={i}
                      className="rounded-[6px] bg-bg px-[10px] py-2 font-mono text-[11px] leading-[1.5] text-text-dim"
                    >
                      <span className="text-accent">{event.name}</span>
                      {event.name === "SwapAssayed" && event.args.feePips ? (
                        <span> · feePips {Number(event.args.feePips).toLocaleString("en-US")}</span>
                      ) : null}
                    </li>
                  ))}
                </ul>
              ) : null}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}

function PoolConvergence({ scenario }: { scenario: Scenario }) {
  const rows = [
    { label: "Before the move", snap: scenario.initial },
    { label: "Mispriced", snap: scenario.dislocated },
    { label: "After the arbitrage", snap: scenario.restored },
  ];
  return (
    <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex items-center justify-between gap-3 px-5 pb-3 pt-[18px]">
        <p className="font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
          Price convergence
        </p>
        <Origin origin="projected" />
      </header>
      <table className="w-full border-collapse border-t border-border text-left">
        <thead>
          <tr className="bg-bg">
            {["", "Pool price", "Tick", "Spread"].map((h) => (
              <th
                key={h}
                className="border-b border-border px-5 py-[10px] font-mono text-[10px] uppercase tracking-[0.1em] text-text-muted"
              >
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => {
            const spread = Math.abs(row.snap.priceUsd / scenario.referenceUsd - 1);
            return (
              <tr key={row.label} className="border-b border-border last:border-0">
                <td className="px-5 py-3 text-[12.5px] text-text-dim">{row.label}</td>
                <td className="tnum px-5 py-3 text-[13px]">{usd(row.snap.priceUsd)}</td>
                <td className="tnum px-5 py-3 text-[13px] text-text-dim">{signed(row.snap.tick)}</td>
                <td
                  className="tnum px-5 py-3 text-[13px]"
                  style={{ color: spread > 0.01 ? "var(--tone-warm)" : "var(--tone-benign)" }}
                >
                  {(spread * 100).toFixed(2)}%
                </td>
              </tr>
            );
          })}
        </tbody>
      </table>
      <p className="border-t border-border px-5 py-3 text-[11.5px] leading-[1.5] text-text-muted">
        Reference {usd(scenario.referenceUsd)} · the arbitrage closes the gap from{" "}
        {(scenario.spreadBefore * 100).toFixed(2)}% to {(scenario.spreadAfter * 100).toFixed(2)}%.
      </p>
    </section>
  );
}

/** The `feePips` the hook actually emitted for one leg, if that leg has run. */
function emittedFeePips(tx: ExecutedTx | undefined): number | undefined {
  const event = tx?.events.find((e) => e.name === "SwapAssayed");
  if (!event) return undefined;
  const raw = Number(event.args.feePips);
  return Number.isFinite(raw) ? raw : undefined;
}

/**
 * @param txs Receipts from the run, so this panel reports what the chain emitted rather than what
 *        was projected. It previously took `scenario` alone while telling the reader both figures
 *        "come out of a `SwapAssayed` event you can read on Basescan" -- true of the mechanism,
 *        false of the numbers on screen, which were recomputed projections in every state.
 */
function FeeComparison({ scenario, txs }: { scenario: Scenario; txs: ExecutedTx[] }) {
  const { bounds } = useLiveProtocol();
  const { economics, arbitrageLeg } = scenario;
  const ratio = economics.flatFeeToLpUsd > 0 ? economics.feeToLpUsd / economics.flatFeeToLpUsd : 0;

  // Prefer what the chain emitted. `send` records the two legs under these labels in order, and
  // each carries its decoded `SwapAssayed`; before a run there is nothing to prefer and the
  // projection stands, labelled as one.
  const arbitrageEmitted = emittedFeePips(txs.find((t) => t.label === "Arbitrage swap"));
  const dislocationEmitted = emittedFeePips(txs.find((t) => t.label === "Dislocate the pool"));
  const executed = arbitrageEmitted !== undefined && dislocationEmitted !== undefined;

  const arbitrageFee = arbitrageEmitted ?? arbitrageLeg.feePips;
  const dislocationFee = dislocationEmitted ?? scenario.dislocationLeg.feePips;

  return (
    <section className="overflow-hidden rounded-2xl border border-border-2 bg-surface">
      <header className="flex flex-wrap items-center justify-between gap-3 px-6 pb-4 pt-5">
        <div>
          <p className="mb-2 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            {executed ? "What just happened" : "What would happen"}
          </p>
          <p className="max-w-[64ch] text-[15px] font-medium leading-[1.45] text-text">
            The same trade, priced by Assay and by a flat-fee pool
          </p>
        </div>
        <Origin origin={executed ? "live-testnet" : "projected"} />
      </header>

      <table className="w-full border-collapse border-t border-border text-left">
        <thead>
          <tr className="bg-bg">
            {["Metric", "Flat-fee pool", "Assay"].map((h) => (
              <th
                key={h}
                className="border-b border-border px-6 py-[10px] font-mono text-[10px] uppercase tracking-[0.1em] text-text-muted"
              >
                {h}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          <Row
            label="Fee quoted on the arbitrage"
            flat={pipsToBp(bounds.baseFeePips)}
            assay={pipsToBp(arbitrageFee)}
          />
          <Row
            label="Kept by liquidity providers"
            flat={usd(economics.flatFeeToLpUsd)}
            assay={usd(economics.feeToLpUsd)}
          />
          <Row
            label="Drift the swap captured"
            flat="not measured"
            assay={`${signed(arbitrageLeg.driftTicks)} ticks`}
          />
        </tbody>
      </table>

      <div className="border-t border-border px-6 py-4">
        <p className="mb-2 text-[14px] font-semibold leading-tight text-text">
          {ratio > 1
            ? `On this trade the hook routed ${ratio.toFixed(1)}× more to liquidity providers.`
            : "On this trade the hook charged at or below the flat fee."}
        </p>
        <p className="max-w-[76ch] text-[12.5px] leading-[1.6] text-text-dim text-pretty">
          A flat-fee pool charges every swap the same rate, so it cannot tell this trade apart
          from the one that created the gap moments earlier. Assay prices the drift each swap
          captures, so the arbitrage {executed ? "paid" : "would pay"} {pipsToBp(arbitrageFee)}{" "}
          while the trade that opened the gap {executed ? "paid" : "would pay"}{" "}
          {pipsToBp(dislocationFee)} —{" "}
          {executed ? (
            <>
              and both figures are read from the{" "}
              <span className="font-mono">SwapAssayed</span> events those two transactions
              emitted, which you can check on Basescan.
            </>
          ) : (
            <>
              and both are what the hook will emit as a{" "}
              <span className="font-mono">SwapAssayed</span> event when you run it.
            </>
          )}
        </p>
        {!DEMO_MODE && (
          <p className="mt-3 max-w-[76ch] rounded-[10px] border border-warm/20 bg-[#100E0A] px-4 py-3 text-[12px] leading-[1.6] text-[#9A8B72]">
            <strong className="font-semibold text-warm">What this does not claim.</strong> That
            liquidity providers are better off overall is a separate question, and this
            project&apos;s own adverse-selection gate does not currently pass — see the risk page.
            What is shown here is narrower and verifiable: two swaps against the same pool,
            moments apart, priced differently according to what each one took.
          </p>
        )}
      </div>
    </section>
  );
}

/* ------------------------------------------------------------------------------------------ */

function Row({ label, flat, assay }: { label: string; flat: string; assay: string }) {
  return (
    <tr className="border-b border-border last:border-0">
      <td className="px-6 py-3 text-[12.5px] text-text-dim">{label}</td>
      <td className="tnum px-6 py-3 text-[13px] text-text-muted">{flat}</td>
      <td className="tnum px-6 py-3 text-[13px] text-accent">{assay}</td>
    </tr>
  );
}

function Metric({
  label,
  value,
  note,
  tone,
}: {
  label: string;
  value: string;
  note: string;
  tone?: "accent" | "warm" | "benign" | "hot";
}) {
  const colors = {
    accent: "var(--color-accent)",
    warm: "var(--tone-warm)",
    benign: "var(--tone-benign)",
    hot: "var(--tone-hot)",
  } as const;
  return (
    <div className="bg-surface px-6 py-5">
      <dt className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted">
        {label}
      </dt>
      <dd className="tnum text-[24px] leading-none" style={tone ? { color: colors[tone] } : undefined}>
        {value}
      </dd>
      <dd className="mt-[7px] font-mono text-[11px] leading-none text-text-muted">{note}</dd>
    </div>
  );
}

function Panel({ tone, children }: { tone?: "warm" | "hot"; children: React.ReactNode }) {
  const border =
    tone === "warm" ? "border-warm/20" : tone === "hot" ? "border-hot/30" : "border-border-2";
  const bg = tone === "warm" ? "bg-[#100E0A]" : tone === "hot" ? "bg-[#150E0C]" : "bg-surface";
  return <div className={`mb-5 rounded-2xl border ${border} ${bg} px-6 py-4`}>{children}</div>;
}
