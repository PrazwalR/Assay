/**
 * Documentation index.
 *
 * The page bodies are React (they carry live figures and links), so this file holds only the
 * navigation graph — what exists, in what order, under what heading. The sidebar, the prev/next
 * pager, the per-page table of contents and ⌘K search all derive from this one array, so a page
 * cannot appear in one and be missing from another.
 *
 * That single derivation is also what makes `DEMO_MODE` safe to express here: filtering the
 * exported array withholds a page from the sidebar, the pager, search and `generateStaticParams`
 * at once, so a hidden page cannot be reachable from one surface and missing from another.
 */

import { DEMO_HIDDEN_DOCS, DEMO_MODE } from "@/lib/demoMode";

export interface DocPage {
  slug: string;
  label: string;
  group: string;
  /** Section headings within the page, mirrored by the `<h2>`s the page renders. */
  toc: string[];
}

/** Every page that exists in the repository, in navigation order. */
export const ALL_DOC_PAGES: DocPage[] = [
  {
    slug: "introduction",
    label: "Introduction",
    group: "Getting started",
    toc: ["The problem", "Deployment"],
  },
  {
    slug: "mechanism",
    label: "The fee formula",
    group: "Protocol",
    toc: ["Deployed parameters", "Why 1,000 bps", "The fee-cap overflow"],
  },
  {
    slug: "v4-constraints",
    label: "v4 constraints",
    group: "Protocol",
    toc: ["Permissions", "Dynamic fee handshake", "Hot path"],
  },
  {
    slug: "invariants",
    label: "Invariants",
    group: "Assurance",
    toc: ["Live properties", "Not applicable"],
  },
  {
    slug: "risk",
    label: "Risk & known gaps",
    group: "Assurance",
    toc: ["Known gaps", "Anticipated attacks"],
  },
  {
    slug: "not-built",
    label: "What is not built",
    group: "Assurance",
    toc: ["Measured and removed", "Contracts that do not exist"],
  },
];

/**
 * The pages this build presents. Identical to `ALL_DOC_PAGES` unless `DEMO_MODE` is on, in
 * which case the Assurance pages it names are withheld — from the nav, the pager, search and
 * the statically generated routes alike, since all four read this array.
 */
export const DOC_PAGES: DocPage[] = DEMO_MODE
  ? ALL_DOC_PAGES.filter((page) => !DEMO_HIDDEN_DOCS.includes(page.slug))
  : ALL_DOC_PAGES;

export const findDoc = (slug: string) => DOC_PAGES.find((page) => page.slug === slug);

/** Wraps at both ends, so the pager is never a dead end. */
export function docNeighbours(slug: string) {
  const index = DOC_PAGES.findIndex((page) => page.slug === slug);
  if (index === -1) return { previous: undefined, next: undefined };
  return {
    previous: DOC_PAGES[(index - 1 + DOC_PAGES.length) % DOC_PAGES.length],
    next: DOC_PAGES[(index + 1) % DOC_PAGES.length],
  };
}

export function searchDocs(query: string): DocPage[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return DOC_PAGES;
  return DOC_PAGES.filter((page) =>
    `${page.label} ${page.group} ${page.toc.join(" ")}`.toLowerCase().includes(needle),
  );
}
