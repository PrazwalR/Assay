import { MarketsView } from "@/components/markets/MarketsView";

export const metadata = {
  title: "Markets — Assay",
  description:
    "What the Assay pool surface reports once a pool is live. No pool has been initialised yet, so every figure here is a labelled fixture.",
};

export default function MarketsPage() {
  return <MarketsView />;
}
