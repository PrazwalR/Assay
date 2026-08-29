"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";

import { useAssay } from "@/components/Providers";
import { DOC_PAGES } from "@/lib/docs";

export function DocsSidebar() {
  const pathname = usePathname();
  const { openModal } = useAssay();

  // Grouped once, up front. Emitting headings by mutating a variable mid-render works right up
  // until React renders the list twice, which it is free to do.
  const groups = DOC_PAGES.reduce<{ group: string; pages: typeof DOC_PAGES }[]>((acc, page) => {
    const last = acc.at(-1);
    if (last && last.group === page.group) last.pages.push(page);
    else acc.push({ group: page.group, pages: [page] });
    return acc;
  }, []);

  return (
    <aside className="sticky top-[76px] hidden py-[30px] lg:block">
      <button
        type="button"
        onClick={() => openModal("search")}
        className="mb-[26px] flex h-[34px] w-full items-center justify-between gap-[10px] rounded-lg border border-border-2 bg-surface-2 px-[10px] text-[12.5px] text-text-muted transition-colors hover:border-border-hover hover:text-text-dim"
      >
        <span>Search docs</span>
        <span className="rounded-[4px] bg-surface-5 px-[5px] py-[3px] font-mono text-[10.5px] font-medium leading-none text-text-dim">
          ⌘K
        </span>
      </button>

      <nav>
        {groups.map(({ group, pages }) => (
          <section key={group}>
            <h2 className="mb-[9px] mt-[22px] pl-[10px] font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.12em] text-text-muted first:mt-0">
              {group}
            </h2>
            {pages.map((page) => {
              const href = `/docs/${page.slug}`;
              const active = pathname === href;
              return (
                <Link
                  key={page.slug}
                  href={href}
                  aria-current={active ? "page" : undefined}
                  className={`block rounded-[7px] border-l-2 px-[10px] py-[6px] text-[13px] leading-[1.5] transition-colors ${
                    active
                      ? "border-accent bg-accent/[0.07] font-semibold text-text"
                      : "border-transparent text-text-dim hover:text-text"
                  }`}
                >
                  {page.label}
                </Link>
              );
            })}
          </section>
        ))}
      </nav>
    </aside>
  );
}
