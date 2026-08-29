"use client";

import { useAssay } from "@/components/Providers";

export const SLIPPAGE_OPTIONS = [0.001, 0.005, 0.01];

export function SettingsModal() {
  const { slippageIndex, setSlippageIndex } = useAssay();

  return (
    <div className="px-5 pb-5 pt-4">
      <p className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
        Slippage tolerance
      </p>
      <div className="grid grid-cols-3 gap-2">
        {SLIPPAGE_OPTIONS.map((value, index) => {
          const active = index === slippageIndex;
          return (
            <button
              key={value}
              type="button"
              onClick={() => setSlippageIndex(index)}
              className={`h-[38px] rounded-[10px] border font-mono text-[12.5px] font-medium transition-colors ${
                active
                  ? "border-accent/40 bg-accent/10 text-accent"
                  : "border-border-2 bg-surface-3 text-text-dim hover:border-border-hover"
              }`}
            >
              {(value * 100).toFixed(1)}%
            </button>
          );
        })}
      </div>

      <p className="mt-4 text-[12.5px] leading-[1.55] text-text-muted">
        Slippage bounds the price move you will accept between quoting and execution. It is
        separate from the hook&apos;s fee, which is quoted per swap and is never a surprise:
        <span className="font-mono text-text-dim"> feeBounds()</span> advertises the worst case
        before you trade.
      </p>
    </div>
  );
}
