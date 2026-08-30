"use client";

import { useState } from "react";
import { useAccount, useBalance, useConnect, useDisconnect } from "wagmi";

import { useAssay } from "@/components/Providers";
import { BASE_SEPOLIA_CHAIN_ID, explorerAddress, shortAddress } from "@/lib/protocol/config";
import { formatBalance } from "@/lib/format";

export function WalletModal() {
  const { closeModal } = useAssay();
  const { address, isConnected } = useAccount();
  const { connectors, connect, isPending, error } = useConnect();
  const { disconnect } = useDisconnect();
  const { data: balance } = useBalance({
    address,
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: { enabled: Boolean(address) },
  });
  const [copied, setCopied] = useState(false);

  const copy = async () => {
    if (!address) return;
    await navigator.clipboard.writeText(address);
    setCopied(true);
    setTimeout(() => setCopied(false), 1400);
  };

  if (!isConnected || !address) {
    return (
      <div className="px-5 pb-5 pt-4">
        <ul className="grid gap-2">
          {connectors.map((connector) => (
            <li key={connector.uid}>
              <button
                type="button"
                disabled={isPending}
                onClick={() => connect({ connector })}
                className="grid w-full grid-cols-[auto_1fr_auto] items-center gap-3 rounded-xl border border-border bg-surface-3 p-[13px] text-left transition-colors hover:border-border-hover hover:bg-surface-4 disabled:opacity-60"
              >
                <span className="flex size-[30px] items-center justify-center rounded-lg bg-[#C3C8D4] font-mono text-[11px] font-semibold leading-none text-bg">
                  {connector.name.slice(0, 2).toUpperCase()}
                </span>
                <span>
                  <span className="block text-[13.5px] font-semibold leading-tight text-text">
                    {connector.name}
                  </span>
                  <span className="mt-[3px] block text-[12px] leading-tight text-text-muted">
                    Injected provider
                  </span>
                </span>
                <span className="font-mono text-[11px] leading-none text-benign">detected</span>
              </button>
            </li>
          ))}
        </ul>

        {error ? (
          <p className="mt-3 rounded-[11px] border border-hot/30 bg-[#150E0C] p-3 text-[12.5px] leading-[1.5] text-[#9A8480]">
            {error.message}
          </p>
        ) : null}

        <p className="mt-4 text-[11.5px] leading-[1.55] text-text-muted">
          Connecting is real and reads your live Base Sepolia balance. Swapping from the
          browser is not wired yet — the pool exists and is tradeable, but this interface does
          not build the v4 unlock and settle callbacks.
        </p>
      </div>
    );
  }

  return (
    <div className="px-5 pb-5 pt-4">
      <div className="rounded-xl border border-border bg-surface-3 p-4">
        <div className="flex items-center justify-between gap-3">
          <span className="tnum text-[14px] text-text">{shortAddress(address)}</span>
          <button
            type="button"
            onClick={copy}
            className={`font-mono text-[11.5px] leading-none transition-colors ${
              copied ? "text-benign" : "text-text-dim hover:text-text"
            }`}
          >
            {copied ? "✓ copied" : "copy"}
          </button>
        </div>
        <p className="tnum mt-3 text-[22px] text-text">
          {formatBalance(balance)}
        </p>
        <a
          href={explorerAddress(address)}
          target="_blank"
          rel="noreferrer"
          className="mt-3 inline-block font-mono text-[11.5px] leading-none"
        >
          View on Basescan ↗
        </a>
      </div>

      <button
        type="button"
        onClick={() => {
          disconnect();
          closeModal();
        }}
        className="mt-3 h-[42px] w-full rounded-xl border border-border-2 bg-surface-2 text-[13.5px] font-semibold text-text transition-colors hover:border-border-hover"
      >
        Disconnect
      </button>
    </div>
  );
}
