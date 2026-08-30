"use client";

import type { SwapStage } from "@/hooks/useSwapExecution";
import { explorerTx } from "@/lib/protocol/config";

/**
 * The panel under the button, carrying whatever the transaction is currently doing.
 *
 * Distinguishes waiting-on-the-wallet from waiting-on-the-chain, because they need different
 * things from the user: one needs them to go look at their wallet, the other needs them to do
 * nothing at all. Collapsing the two into "pending" is what makes people click twice.
 */
export function TxStatus({
  stage,
  isMining,
  hash,
  error,
}: {
  stage: SwapStage;
  isMining: boolean;
  hash: `0x${string}` | undefined;
  error: string | undefined;
}) {
  const link = hash ? (
    <a
      href={explorerTx(hash)}
      target="_blank"
      rel="noreferrer"
      className="font-mono text-[11.5px] underline underline-offset-2"
    >
      {`${hash.slice(0, 10)}…${hash.slice(-8)}`} ↗
    </a>
  ) : null;

  if (stage === "failed") {
    return (
      <Panel tone="hot" title="Transaction failed">
        {error ?? "The transaction did not go through."} {link}
      </Panel>
    );
  }

  if (stage === "confirmed") {
    return (
      <Panel tone="benign" title="Confirmed on Base Sepolia">
        The swap is on chain, and the hook emitted a{" "}
        <span className="font-mono">SwapAssayed</span> event carrying the fee it quoted. {link}
      </Panel>
    );
  }

  if (stage === "approving" || stage === "swapping") {
    const what = stage === "approving" ? "approval" : "swap";
    return (
      <Panel tone="neutral" title={isMining ? `Waiting for the chain` : `Confirm in your wallet`}>
        {isMining
          ? `The ${what} is submitted and waiting to be mined. Nothing more to do here.`
          : `Your wallet is asking you to sign the ${what}.`}{" "}
        {link}
      </Panel>
    );
  }

  return null;
}

function Panel({
  tone,
  title,
  children,
}: {
  tone: "hot" | "benign" | "neutral";
  title: string;
  children: React.ReactNode;
}) {
  const styles = {
    hot: { border: "rgb(228 103 79 / 0.3)", background: "#150E0C", title: "var(--tone-hot)", body: "#9A8480" },
    benign: { border: "rgb(91 208 140 / 0.28)", background: "#0B1310", title: "var(--tone-benign)", body: "#8FA898" },
    neutral: { border: "var(--color-border-2)", background: "var(--color-surface-3)", title: "var(--color-text)", body: "var(--color-text-dim)" },
  }[tone];

  return (
    <div
      className="mt-3 rounded-[11px] border px-[15px] py-[13px]"
      style={{
        borderColor: styles.border,
        background: styles.background,
        animation: "assayRise 0.24s ease",
      }}
    >
      <p className="mb-[5px] text-[12.5px] font-semibold leading-tight" style={{ color: styles.title }}>
        {title}
      </p>
      <p className="text-[12.5px] leading-[1.5]" style={{ color: styles.body }}>
        {children}
      </p>
    </div>
  );
}
