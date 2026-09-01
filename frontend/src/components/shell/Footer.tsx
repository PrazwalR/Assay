import Link from "next/link";

import { AssayMark } from "@/components/brand/AssayMark";
import { DEMO_MODE } from "@/lib/demoMode";
import { CONTRACTS, PERMISSION_MASK, explorerAddress, shortAddress } from "@/lib/protocol/config";

export function Footer() {
  return (
    <footer className="border-t border-border bg-bg">
      <div className="mx-auto flex max-w-[1240px] flex-wrap items-start justify-between gap-10 px-6 py-11">
        <div className="max-w-[38ch]">
          <div className="mb-3 flex items-center gap-[9px] text-text">
            <AssayMark className="size-[18px]" />
            <span className="text-[14px] font-semibold leading-none tracking-[-0.01em]">
              Assay
            </span>
          </div>
          <p className="text-[12.5px] leading-[1.6] text-text-muted">
            A Uniswap v4 hook that prices adverse selection per swap. Research software: it has
            never held value and has not been independently audited.
          </p>
        </div>

        <div>
          <h2 className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Deployment
          </h2>
          <dl className="grid gap-2 font-mono text-[11.5px] leading-none">
            <div className="flex items-center gap-3">
              <dt className="text-text-muted">hook</dt>
              <dd>
                <a href={explorerAddress(CONTRACTS.hook)} target="_blank" rel="noreferrer">
                  {shortAddress(CONTRACTS.hook)} ↗
                </a>
              </dd>
            </div>
            <div className="flex items-center gap-3">
              <dt className="text-text-muted">oracle</dt>
              <dd>
                <a
                  href={explorerAddress(CONTRACTS.oracleAdapter)}
                  target="_blank"
                  rel="noreferrer"
                >
                  {shortAddress(CONTRACTS.oracleAdapter)} ↗
                </a>
              </dd>
            </div>
            <div className="flex items-center gap-3">
              <dt className="text-text-muted">mask</dt>
              <dd className="text-text-dim">{PERMISSION_MASK}</dd>
            </div>
          </dl>
        </div>

        <div>
          <h2 className="mb-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted">
            Read
          </h2>
          <ul className="grid gap-2 text-[12.5px] leading-none">
            <li>
              <Link href="/docs/mechanism">The fee formula</Link>
            </li>
            <li>
              <Link href="/docs/invariants">Invariants</Link>
            </li>
            {!DEMO_MODE && (
              <>
                <li>
                  <Link href="/docs/risk">Risk &amp; known gaps</Link>
                </li>
                <li>
                  <Link href="/docs/not-built">What is not built</Link>
                </li>
              </>
            )}
          </ul>
        </div>
      </div>
    </footer>
  );
}
