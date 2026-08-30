import type { DataOrigin } from "@/lib/simulation/types";

/**
 * The provenance badge.
 *
 * §21's requirement, and the one this feature cannot compromise on: a viewer must be able to
 * tell at a glance whether a number was computed or read from a chain. Two visually distinct
 * treatments, never blended, and never omitted from a panel that shows figures of both kinds.
 */
export function Origin({ origin, className = "" }: { origin: DataOrigin; className?: string }) {
  const live = origin === "live-testnet";
  return (
    <span
      className={`inline-flex flex-none items-center gap-[6px] rounded-[5px] border px-[7px] py-[3px] font-mono text-[9.5px] font-medium uppercase leading-none tracking-[0.08em] ${className}`}
      style={
        live
          ? {
              borderColor: "rgb(91 208 140 / 0.3)",
              background: "rgb(91 208 140 / 0.08)",
              color: "var(--tone-benign)",
            }
          : {
              borderColor: "var(--color-border-2)",
              background: "var(--color-surface-2)",
              color: "var(--color-text-muted)",
            }
      }
    >
      <span
        className="size-[5px] rounded-full"
        style={{ background: live ? "var(--tone-benign)" : "var(--color-text-muted)" }}
      />
      {live ? "live · base sepolia" : "projected"}
    </span>
  );
}
