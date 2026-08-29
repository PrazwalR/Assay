import { notFound } from "next/navigation";

import { DOC_BODIES } from "@/components/docs/pages";
import { DocsPager } from "@/components/docs/DocsPager";
import { DOC_PAGES, findDoc } from "@/lib/docs";

export function generateStaticParams() {
  return DOC_PAGES.map((page) => ({ slug: page.slug }));
}

export async function generateMetadata(props: PageProps<"/docs/[slug]">) {
  const { slug } = await props.params;
  const page = findDoc(slug);
  if (!page) return {};
  return {
    title: `${page.label} — Assay docs`,
    description: page.toc.join(" · "),
  };
}

export default async function DocPage(props: PageProps<"/docs/[slug]">) {
  const { slug } = await props.params;
  const page = findDoc(slug);
  const Body = DOC_BODIES[slug];
  if (!page || !Body) notFound();

  return (
    <article className="min-w-0 py-[30px] pb-24">
      <nav className="mb-[22px] flex items-center gap-2 font-mono text-xs leading-none text-text-muted">
        <span>Docs</span>
        <span className="text-text-ghost">/</span>
        <span className="text-text-dim">{page.label}</span>
      </nav>

      <h1 className="mb-6 text-[34px] font-semibold leading-[1.15] tracking-[-0.03em]">
        {page.label}
      </h1>

      <Body />
      <DocsPager slug={slug} />
    </article>
  );
}
