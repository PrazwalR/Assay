"use client";

import { NETWORKS } from "@/lib/protocol/fixtures";

/**
 * Unavailable chains are listed rather than hidden. "Unichain Sepolia has no Chainlink feed"
 * is a more useful answer than an absence, and it makes the deployment's actual reach legible.
 */
export function NetworkModal() {
  return (
    <div className="px-5 pb-5 pt-4">
      <ul className="grid gap-2">
        {NETWORKS.map((network) => (
          <li key={network.name}>
            <div
              aria-disabled={!network.available}
              className={`grid grid-cols-[auto_1fr_auto] items-center gap-3 rounded-xl border border-border bg-surface-3 p-[13px] ${
                network.available ? "" : "opacity-50"
              }`}
            >
              <span
                className="size-[26px] flex-none rounded-lg"
                style={{ background: network.color }}
              />
              <span>
                <span className="block text-[13.5px] font-semibold leading-tight text-text">
                  {network.name}
                </span>
                <span className="mt-[3px] block font-mono text-[11.5px] leading-tight text-text-muted">
                  {network.note}
                </span>
              </span>
              <span
                className={`font-mono text-[11px] leading-none ${
                  network.available ? "text-benign" : "text-text-muted"
                }`}
              >
                {network.state}
              </span>
            </div>
          </li>
        ))}
      </ul>
    </div>
  );
}
