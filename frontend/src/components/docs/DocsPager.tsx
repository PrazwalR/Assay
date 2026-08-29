import Link from "next/link";

import { docNeighbours } from "@/lib/docs";

export function DocsPager({ slug }: { slug: string }) {
  const { previous, next } = docNeighbours(slug);
  if (!previous || !next) return null;

  return (
    <nav className="mt-14 grid gap-3 border-t border-border pt-6 sm:grid-cols-2">
      <Link
        href={`/docs/${previous.slug}`}
        className="rounded-xl border border-border-2 bg-surface px-4 py-3 transition-colors hover:border-border-hover"
      >
        <span className="block font-mono text-[10.5px] uppercase leading-none tracking-[0.1em] text-text-muted">
          Previous
        </span>
        <span className="mt-2 block text-[13.5px] font-medium leading-tight text-text">
          {previous.label}
        </span>
      </Link>
      <Link
        href={`/docs/${next.slug}`}
        className="rounded-xl border border-border-2 bg-surface px-4 py-3 text-right transition-colors hover:border-border-hover"
      >
        <span className="block font-mono text-[10.5px] uppercase leading-none tracking-[0.1em] text-text-muted">
          Next
        </span>
        <span className="mt-2 block text-[13.5px] font-medium leading-tight text-text">
          {next.label}
        </span>
      </Link>
    </nav>
  );
}
