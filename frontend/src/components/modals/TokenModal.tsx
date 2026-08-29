"use client";

import { useMemo, useState } from "react";

import { useAssay } from "@/components/Providers";
import { useLiveProtocol } from "@/hooks/useLiveProtocol";
import { num, usd } from "@/lib/format";
import { TOKENS, TOKEN_PAIR } from "@/lib/protocol/fixtures";

export function TokenModal({ side }: { side: "tokenIn" | "tokenOut" }) {
  const { dataMode, setTokenIn, setTokenOut, closeModal } = useAssay();
  const { referenceUsd } = useLiveProtocol();
  const [query, setQuery] = useState("");

  const matches = useMemo(() => {
    const keys = TOKEN_PAIR[dataMode];
    const needle = query.trim().toLowerCase();
    return keys
      .map((key) => TOKENS[key])
      .filter((token) =>
        !needle ? true : `${token.symbol} ${token.name}`.toLowerCase().includes(needle),
      );
  }, [dataMode, query]);

  const pick = (key: string) => {
    if (side === "tokenIn") setTokenIn(key);
    else setTokenOut(key);
    closeModal();
  };

  return (
    <div>
      <div className="px-5 py-[14px]">
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search name or paste address"
          aria-label="Search tokens"
          autoFocus
          className="h-[42px] w-full rounded-[10px] border border-border-2 bg-surface-3 px-[14px] text-[13.5px] text-text outline-none focus:border-accent/45"
        />
      </div>

      {matches.length > 0 ? (
        <ul className="px-2 pb-[14px]">
          {matches.map((token) => {
            const priceUsd = token.priceUsd ?? referenceUsd;
            const testnet = token.badge === "testnet";
            return (
              <li key={token.key}>
                <button
                  type="button"
                  onClick={() => pick(token.key)}
                  className="grid w-full grid-cols-[auto_1fr_auto] items-center gap-3 rounded-[11px] p-3 text-left transition-colors hover:bg-surface-4"
                >
                  <span
                    className="flex size-8 items-center justify-center rounded-full font-mono text-[11px] font-semibold leading-none text-bg"
                    style={{ background: token.color }}
                  >
                    {token.glyph}
                  </span>
                  <span className="min-w-0">
                    <span className="flex items-center gap-[7px]">
                      <span className="text-[14px] font-semibold leading-tight text-text">
                        {token.symbol}
                      </span>
                      <span
                        className="rounded-[4px] px-[5px] py-[3px] font-mono text-[9.5px] font-medium leading-none"
                        style={{
                          background: testnet
                            ? "rgb(233 165 68 / 0.14)"
                            : "rgb(91 208 140 / 0.14)",
                          color: testnet ? "var(--tone-warm)" : "var(--tone-benign)",
                        }}
                      >
                        {token.badge}
                      </span>
                    </span>
                    <span className="mt-[3px] block text-[12px] leading-tight text-text-muted">
                      {token.name}
                    </span>
                  </span>
                  <span className="text-right">
                    <span className="tnum block text-[13px] leading-none text-text">
                      {num(token.balance, token.decimals)}
                    </span>
                    <span className="mt-[5px] block font-mono text-[11.5px] leading-none text-text-muted">
                      {usd(token.balance * priceUsd)}
                    </span>
                  </span>
                </button>
              </li>
            );
          })}
        </ul>
      ) : (
        <div className="px-6 pb-[52px] pt-11 text-center">
          <div className="mx-auto mb-4 size-10 rounded-[11px] border border-dashed border-border-hover" />
          <p className="mb-[7px] text-[14px] font-semibold leading-tight text-text">
            No token matches “{query}”
          </p>
          <p className="mx-auto max-w-[36ch] text-[12.5px] leading-[1.55] text-text-muted">
            The hook refuses any pool whose currencies do not match the pair its oracle
            declares, so only bound pairs are listed here.
          </p>
        </div>
      )}

      <p className="border-t border-border px-5 py-3 text-[11.5px] leading-[1.5] text-text-muted">
        Balances shown are fixtures — no pool is initialised, so there is nothing to hold a
        position in yet.
      </p>
    </div>
  );
}
