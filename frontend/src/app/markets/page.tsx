import { MarketsView } from "@/components/markets/MarketsView";

export const metadata = {
  title: "Markets — Assay",
  description:
    "The live Assay pool on Base Sepolia. The pool and its fee bounds are real; the aggregate figures are still fixtures until there is enough trading history to measure.",
};

export default function MarketsPage() {
  return <MarketsView />;
}
