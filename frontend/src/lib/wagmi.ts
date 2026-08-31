import { createConfig, http } from "wagmi";
import { baseSepolia } from "wagmi/chains";
import { injected } from "wagmi/connectors";

/**
 * Base Sepolia only — it is the one chain the hook is deployed to, and offering others would
 * imply a deployment that does not exist. The network modal lists the alternatives as
 * explicitly unavailable rather than hiding them, which is the more useful answer.
 *
 * `NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL` is optional: the public endpoint works for the reads this
 * app makes. It exists so a deployment can point at a provider with better rate limits without
 * a code change.
 */
export const wagmiConfig = createConfig({
  chains: [baseSepolia],
  connectors: [injected()],
  transports: {
    [baseSepolia.id]: http(process.env.NEXT_PUBLIC_BASE_SEPOLIA_RPC_URL),
  },
  ssr: true,
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
