import Link from "next/link";

import { DEMO_MODE } from "@/lib/demoMode";

/**
 * DESIGN-SPEC.md §9: "the candour is the brand." This sits above the header on every surface,
 * not buried in docs, because both facts materially change what a reader should conclude from
 * everything below it — and the second one is a negative result about this project's own
 * central claim.
 *
 * `DEMO_MODE` withholds it for a testnet walkthrough where the banner is chrome rather than
 * warning. It does not stop being true while hidden; `README.md` and `SECURITY.md` carry both
 * facts unconditionally. See `lib/demoMode.ts`.
 */
export function StatusBanner() {
  if (DEMO_MODE) return null;

  return (
    <div className="flex flex-col items-center gap-1 border-b border-warm/20 bg-[#15100A] px-5 py-[7px] text-center">
      <p className="flex items-center gap-2 text-[11.5px] font-medium leading-[1.4] text-warm">
        <span
          className="size-[5px] flex-none rounded-full bg-warm"
          style={{ animation: "assayPulse 2.4s ease-in-out infinite" }}
        />
        Unaudited. Base Sepolia only. Never having held value.
      </p>
      <p className="text-[11.5px] font-medium leading-[1.4] text-[#B9915A]">
        The adverse-selection gate does not currently pass — the mechanism is deployed, the
        evidence is not established.{" "}
        <Link
          href="/docs/risk"
          className="text-warm underline underline-offset-2 hover:text-warm"
        >
          Read the result
        </Link>
      </p>
    </div>
  );
}
