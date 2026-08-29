import { FeeDerivation } from "@/components/quote/FeeDerivation";
import { TwinQuote } from "@/components/quote/TwinQuote";
import { EventLog } from "@/components/swap/EventLog";
import { RoutePath } from "@/components/swap/RoutePath";
import { SwapCard } from "@/components/swap/SwapCard";

export const metadata = {
  title: "Swap — Assay",
  description:
    "Quote a swap against the live Base Sepolia reference price, and see the arithmetic that produced the fee.",
};

export default function SwapPage() {
  return (
    <main className="mx-auto max-w-[1240px] px-6 pb-[90px] pt-9">
      <div className="grid items-start gap-6 lg:grid-cols-[minmax(380px,460px)_minmax(0,1fr)]">
        <SwapCard />
        <div className="grid gap-4">
          <FeeDerivation />
          <TwinQuote />
          <RoutePath />
          <EventLog />
        </div>
      </div>
    </main>
  );
}
