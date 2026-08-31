# Assay — frontend

The interface for [Assay](../README.md), a Uniswap v4 hook that prices adverse selection per
swap. Next.js 16 (App Router) / React 19 / Tailwind v4 / wagmi v3 / viem, deployed against the
live hook and pool on Base Sepolia.

Four surfaces: Overview, Swap (real approve-then-swap execution against the live pool),
Markets, and Docs. A fifth, Simulation, stages a real, controlled arbitrage — two real
transactions, not a replay — to make the mechanism's effect on a fee visible end to end.

## Running it

```bash
pnpm install
pnpm dev        # http://localhost:3000
```

`.env.example` documents the two optional environment variables: a custom Base Sepolia RPC
endpoint (the app works against the public one without it) and the site URL used to build an
absolute OG image link for social previews.

## Verifying it

```bash
pnpm test        # feeBlend, swap math, slippage, and simulation-engine unit tests,
                  # each pinned against either a shared fixture or a live on-chain read
pnpm typecheck
pnpm lint
pnpm build
```

## What's live vs. projected

Every figure in the UI is provenance-tagged. Reference price, fee bounds, pool tick,
liquidity, and block number are genuine reads against the deployed contracts on Base Sepolia.
Volume, historical fee revenue, and the quote distribution are not — the pool has traded only a
handful of times, and a handful of swaps is not a distribution — so those stay in
`src/lib/protocol/fixtures.ts`, the one place mock data lives, and are marked as such wherever
they're shown.

See the root [`README.md`](../README.md) for the mechanism itself, deployed addresses, and
`docs/` for the in-app documentation.
