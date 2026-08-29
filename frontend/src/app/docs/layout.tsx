import { DocsSidebar } from "@/components/docs/DocsSidebar";

export default function DocsLayout({ children }: LayoutProps<"/docs">) {
  return (
    <div className="mx-auto grid max-w-[1400px] items-start gap-11 px-6 lg:grid-cols-[236px_minmax(0,1fr)]">
      <DocsSidebar />
      {children}
    </div>
  );
}
