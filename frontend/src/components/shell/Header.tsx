"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { AssayMark } from "@/components/brand/AssayMark";
import { useAssay } from "@/components/Providers";
import { WalletButton } from "@/components/shell/WalletButton";

const NAV = [
  { href: "/", label: "Overview" },
  { href: "/swap", label: "Swap" },
  { href: "/markets", label: "Markets" },
  { href: "/simulation", label: "Simulation" },
  { href: "/docs", label: "Docs" },
] as const;

export function Header() {
  const pathname = usePathname();
  const { dataMode, toggleDataMode, openModal } = useAssay();

  const isActive = (href: string) =>
    href === "/" ? pathname === "/" : pathname.startsWith(href);

  return (
    <header className="sticky top-0 z-40 flex h-[60px] items-center gap-6 border-b border-border bg-bg/85 px-6 backdrop-blur-[14px]">
      <Link href="/" className="flex items-center gap-[9px] text-text">
        <AssayMark className="size-[22px]" title="Assay" />
        <span className="text-[15px] font-semibold leading-none tracking-[-0.01em]">Assay</span>
      </Link>

      <nav className="ml-2 flex items-center gap-[2px]">
        {NAV.map((item) => (
          <Link
            key={item.href}
            href={item.href}
            aria-current={isActive(item.href) ? "page" : undefined}
            className={`rounded-[7px] px-[11px] py-[7px] text-[13.5px] font-medium leading-none transition-colors hover:bg-white/5 ${
              isActive(item.href) ? "text-text" : "text-text-dim"
            }`}
          >
            {item.label}
          </Link>
        ))}
      </nav>

      <div className="flex-1" />

      {/*
        Spec §8: this toggle keeps the vision piece and the testnet reality in one build.
        "base sepolia live" genuinely reads the oracle, the fee bounds and the block number;
        pool-derived figures stay fixtures either way and are marked as such where shown.
      */}
      <button
        type="button"
        onClick={toggleDataMode}
        title="Switch data source"
        className="flex h-[34px] flex-none items-center gap-[7px] whitespace-nowrap rounded-lg border border-border-2 bg-surface-2 px-[11px] font-mono text-xs font-medium leading-none text-text-dim transition-colors hover:border-border-hover hover:text-text"
      >
        <span
          className={`size-[6px] flex-none rounded-full ${
            dataMode === "testnet" ? "bg-benign" : "bg-warm"
          }`}
        />
        {dataMode === "testnet" ? "base sepolia live" : "mainnet mock"}
      </button>

      <button
        type="button"
        onClick={() => openModal("network")}
        className="flex h-[34px] flex-none items-center gap-2 whitespace-nowrap rounded-lg border border-border-2 bg-surface-2 px-[11px] text-[12.5px] font-medium leading-none text-text transition-colors hover:border-border-hover"
      >
        <span className="size-[15px] flex-none rounded-[4px] bg-[#3B6BF5]" />
        Base Sepolia
        <span className="text-[9px] text-text-muted">▾</span>
      </button>

      <WalletButton />
    </header>
  );
}
