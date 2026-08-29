/**
 * Prose primitives for the docs.
 *
 * Deliberately explicit components rather than a global `.prose` stylesheet: the docs mix
 * running text with tables, callouts and code, and each needs to opt in to the type scale in
 * DESIGN-SPEC.md §3 rather than inherit a generic one.
 */

export function Lede({ children }: { children: React.ReactNode }) {
  return (
    <p className="mb-8 max-w-[70ch] text-[17px] leading-[1.7] text-text-2 text-pretty">
      {children}
    </p>
  );
}

export function H2({ id, children }: { id: string; children: React.ReactNode }) {
  return (
    <h2
      id={id}
      className="mb-4 mt-12 scroll-mt-24 text-[22px] font-semibold leading-[1.25] tracking-[-0.02em] first:mt-0"
    >
      {children}
    </h2>
  );
}

export function P({ children }: { children: React.ReactNode }) {
  return (
    <p className="mb-4 max-w-[70ch] text-[14.5px] leading-[1.7] text-text-dim text-pretty">
      {children}
    </p>
  );
}

export function Ul({ children }: { children: React.ReactNode }) {
  return (
    <ul className="mb-4 max-w-[70ch] list-disc space-y-2 pl-5 text-[14.5px] leading-[1.7] text-text-dim marker:text-text-ghost">
      {children}
    </ul>
  );
}

export function Code({ children }: { children: React.ReactNode }) {
  return (
    <code className="rounded-[4px] bg-surface-3 px-[5px] py-[2px] font-mono text-[13px] text-text">
      {children}
    </code>
  );
}

export function CodeBlock({ children }: { children: string }) {
  return (
    <pre className="mb-5 overflow-x-auto rounded-xl border border-border bg-bg p-4 font-mono text-[13.5px] leading-[2] text-text-dim">
      <code>{children}</code>
    </pre>
  );
}

export function Callout({
  tone = "neutral",
  title,
  children,
}: {
  tone?: "neutral" | "warm";
  title: string;
  children: React.ReactNode;
}) {
  const warm = tone === "warm";
  return (
    <aside
      className={`mb-5 max-w-[70ch] rounded-xl border px-5 py-4 ${
        warm ? "border-warm/20 bg-[#100E0A]" : "border-border-2 bg-surface"
      }`}
    >
      <p
        className={`mb-2 text-[13px] font-semibold leading-tight ${warm ? "text-warm" : "text-text"}`}
      >
        {title}
      </p>
      <div className={`text-[13.5px] leading-[1.65] ${warm ? "text-[#9A8B72]" : "text-text-dim"}`}>
        {children}
      </div>
    </aside>
  );
}

export function DataTable({
  head,
  rows,
}: {
  head: string[];
  rows: (string | React.ReactNode)[][];
}) {
  return (
    <div className="mb-5 max-w-[70ch] overflow-x-auto rounded-xl border border-border">
      <table className="w-full border-collapse text-left">
        <thead>
          <tr className="bg-bg">
            {head.map((cell) => (
              <th
                key={cell}
                className="whitespace-nowrap border-b border-border px-4 py-3 font-mono text-[10.5px] font-medium uppercase leading-none tracking-[0.1em] text-text-muted"
              >
                {cell}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, index) => (
            <tr key={index} className="border-b border-border last:border-0">
              {row.map((cell, cellIndex) => (
                <td
                  key={cellIndex}
                  className="px-4 py-3 align-top text-[13.5px] leading-[1.6] text-text-dim"
                >
                  {cell}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
