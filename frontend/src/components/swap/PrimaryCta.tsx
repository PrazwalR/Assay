"use client";

import type { SwapStage } from "@/hooks/useSwapExecution";

/**
 * The button, as a lookup keyed by stage.
 *
 * Every state the swap can be in resolves to exactly one label, one appearance and one action.
 * Written as a table rather than a chain of conditionals because the failure this prevents is a
 * button that says "Swap" while the machine is mid-approval — and a table cannot express that,
 * where nested ternaries can and eventually do.
 */

interface Appearance {
  label: (symbolIn: string, symbolOut: string) => string;
  background: string;
  foreground: string;
  actionable: boolean;
  busy?: boolean;
}

const STAGES: Record<SwapStage, Appearance> = {
  disconnected: {
    label: () => "Connect wallet",
    background: "var(--color-text)",
    foreground: "var(--color-bg)",
    actionable: true,
  },
  "wrong-network": {
    label: () => "Switch to Base Sepolia",
    background: "var(--tone-warm)",
    foreground: "var(--color-bg)",
    actionable: true,
  },
  loading: {
    label: () => "Reading the pool…",
    background: "var(--color-surface-4)",
    foreground: "var(--color-text-muted)",
    actionable: false,
    busy: true,
  },
  "enter-amount": {
    label: () => "Enter an amount",
    background: "var(--color-surface-4)",
    foreground: "var(--color-text-muted)",
    actionable: false,
  },
  "insufficient-balance": {
    label: (symbolIn) => `Insufficient ${symbolIn} balance`,
    background: "#150E0C",
    foreground: "var(--tone-hot)",
    actionable: false,
  },
  "needs-approval": {
    label: (symbolIn) => `Approve ${symbolIn}`,
    background: "var(--color-accent)",
    foreground: "var(--color-bg)",
    actionable: true,
  },
  approving: {
    label: (symbolIn) => `Approving ${symbolIn}…`,
    background: "var(--color-surface-4)",
    foreground: "var(--color-text-dim)",
    actionable: false,
    busy: true,
  },
  ready: {
    label: (symbolIn, symbolOut) => `Swap ${symbolIn} for ${symbolOut}`,
    background: "var(--color-text)",
    foreground: "var(--color-bg)",
    actionable: true,
  },
  swapping: {
    label: () => "Swapping…",
    background: "var(--color-surface-4)",
    foreground: "var(--color-text-dim)",
    actionable: false,
    busy: true,
  },
  confirmed: {
    label: () => "Swap confirmed — quote another",
    background: "var(--tone-benign)",
    foreground: "var(--color-bg)",
    actionable: true,
  },
  failed: {
    label: () => "Try again",
    background: "#150E0C",
    foreground: "var(--tone-hot)",
    actionable: true,
  },
};

export function PrimaryCta({
  stage,
  symbolIn,
  symbolOut,
  onAct,
}: {
  stage: SwapStage;
  symbolIn: string;
  symbolOut: string;
  onAct: (() => void) | undefined;
}) {
  const appearance = STAGES[stage];
  const disabled = !appearance.actionable || !onAct;

  return (
    <button
      type="button"
      onClick={onAct}
      disabled={disabled}
      aria-busy={appearance.busy}
      className="mt-3 flex h-[50px] w-full items-center justify-center gap-[10px] rounded-xl text-[14.5px] font-semibold transition-transform enabled:hover:-translate-y-px disabled:cursor-not-allowed"
      style={{ background: appearance.background, color: appearance.foreground }}
    >
      {appearance.busy ? (
        <span
          aria-hidden
          className="size-[15px] rounded-full border-2 border-current border-t-transparent"
          style={{ animation: "assaySpin 0.9s linear infinite" }}
        />
      ) : null}
      {appearance.label(symbolIn, symbolOut)}
    </button>
  );
}
