"use client";

import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";

import { useAssay } from "@/components/Providers";
import { searchDocs } from "@/lib/docs";

export function SearchModal() {
  const router = useRouter();
  const { closeModal } = useAssay();
  const [query, setQuery] = useState("");

  const hits = useMemo(() => searchDocs(query), [query]);

  const open = (slug: string) => {
    router.push(`/docs/${slug}`);
    closeModal();
  };

  return (
    <div>
      <div className="px-5 py-[14px]">
        <input
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search documentation"
          aria-label="Search documentation"
          autoFocus
          className="h-[42px] w-full rounded-[10px] border border-border-2 bg-surface-3 px-[14px] text-[13.5px] text-text outline-none focus:border-accent/45"
        />
      </div>

      {hits.length > 0 ? (
        <ul className="px-2 pb-[14px]">
          {hits.map((page) => (
            <li key={page.slug}>
              <button
                type="button"
                onClick={() => open(page.slug)}
                className="w-full rounded-[11px] p-3 text-left transition-colors hover:bg-surface-4"
              >
                <span className="flex items-baseline gap-[9px]">
                  <span className="text-[13.5px] font-semibold leading-tight text-text">
                    {page.label}
                  </span>
                  <span className="font-mono text-[10.5px] uppercase leading-none tracking-[0.1em] text-text-muted">
                    {page.group}
                  </span>
                </span>
                <span className="mt-[5px] block font-mono text-[11.5px] leading-tight text-text-muted">
                  {page.toc.join(" · ")}
                </span>
              </button>
            </li>
          ))}
        </ul>
      ) : (
        <div className="px-6 pb-11 pt-9 text-center">
          <p className="mb-[7px] text-[14px] font-semibold leading-tight text-text">
            Nothing matches “{query}”
          </p>
          <p className="mx-auto max-w-[38ch] text-[12.5px] leading-[1.55] text-text-muted">
            The documentation covers the mechanism, the v4 constraints, the invariants, and what
            is deliberately not built. It is not large.
          </p>
        </div>
      )}
    </div>
  );
}
