"use client";

import { useAccount, useBalance } from "wagmi";

import { useAssay } from "@/components/Providers";
import { BASE_SEPOLIA_CHAIN_ID, shortAddress } from "@/lib/protocol/config";
import { formatBalance } from "@/lib/format";

/**
 * Real wallet state — a real address, a real balance, from a real connector. The one thing it
 * does not do is submit a swap: the pool is real, but this interface does not build the v4
 * unlock and settle callbacks a swap needs.
 */
export function WalletButton() {
  const { openModal } = useAssay();
  const { address, isConnected } = useAccount();
  const { data: balance } = useBalance({
    address,
    chainId: BASE_SEPOLIA_CHAIN_ID,
    query: { enabled: Boolean(address) },
  });

  if (!isConnected || !address) {
    return (
      <button
        type="button"
        onClick={() => openModal("wallet")}
        className="h-[34px] flex-none rounded-lg bg-text px-[14px] text-[12.5px] font-semibold leading-none text-bg transition-transform hover:-translate-y-px hover:shadow-[0_4px_16px_rgb(231_234_236/0.16)]"
      >
        Connect wallet
      </button>
    );
  }

  return (
    <button
      type="button"
      onClick={() => openModal("wallet")}
      className="flex h-[34px] flex-none items-center gap-[10px] rounded-lg border border-border-2 bg-surface-2 py-0 pl-3 pr-[6px] text-text transition-colors hover:border-border-hover"
    >
      <span className="tnum text-[12.5px] font-medium leading-none">
        {shortAddress(address)}
      </span>
      <span className="flex h-6 items-center rounded-[5px] bg-surface-5 px-2 font-mono text-[11.5px] font-medium leading-none text-text-dim">
        {formatBalance(balance)}
      </span>
    </button>
  );
}
