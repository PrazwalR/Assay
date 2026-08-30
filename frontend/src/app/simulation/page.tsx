import { SimulationView } from "@/components/simulation/SimulationView";

export const metadata = {
  title: "Simulation — Assay",
  description:
    "Watch an arbitrage execute against the live Assay pool on Base Sepolia, one step at a time. Real transactions, real gas, real events — only the mispricing is staged.",
};

export default function SimulationPage() {
  return <SimulationView />;
}
