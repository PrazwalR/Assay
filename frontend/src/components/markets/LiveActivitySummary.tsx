"use client";

import { useHookActivity } from "@/hooks/useHookActivity";
import { DEPLOYED } from "@/lib/protocol/config";

/**
 * The pool's traded history as a sentence fragment, read from the hook's own logs.
 *
 * This exists because the same two facts -- how many swaps the hook has priced, and the range
 * they were quoted across -- were previously written into prose on three surfaces by hand, and
 * had drifted apart: the landing page said nine swaps topping out at 4,700 pips, the markets
 * page said twelve topping out at 5,780, and the docs said twelve. The chain said fourteen,
 * topping out at 9,810. A number that describes a live pool cannot be typed into prose and
 * stay true, so it is read instead.
 */

function bps(pips: number): string {
  return `${(pips / 100).toFixed(2)} bps`;
}

export function LiveActivitySummary() {
  const { swaps, isLoading, error } = useHookActivity(DEPLOYED.minFeePips);

  if (isLoading) return <>has been traded a handful of times</>;

  // No invented figure when the read failed. The surrounding sentence still parses.
  if (error || swaps.length === 0) return <>has been traded a handful of times</>;

  const fees = swaps.map((s) => s.feePips);
  const low = Math.min(...fees);
  const high = Math.max(...fees);

  return (
    <>
      has been traded <strong className="font-semibold">{swaps.length} times</strong>, at quotes
      from {bps(low)} to {bps(high)}
    </>
  );
}
