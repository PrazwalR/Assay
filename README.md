# Assay

A Uniswap v4 hook that prices adverse selection **per swap** rather than per pool.

Every dynamic-fee hook shipping today sets the fee from volatility. Volatility is a property
of the market, so it is identical for everyone in a block: a retail swap and a top-of-block
arbitrage pay the same rate, though one is the liquidity provider's entire revenue and the
other is their entire loss. Since v4, `beforeSwap` can return a fee for one specific swap.

Assay uses that. The fee is a share of the price drift a swap captures against a cached
reference, signed by direction — so two swaps in the same block trading opposite directions
are quoted differently. Measured in `test/integration/DynamicPricing.t.sol`: **100 bp against
1 bp**, same block, same pool.

## Status

Unaudited, and never having held value. Base Sepolia only.

| | |
| --- | --- |
| AssayHook | [`0xa3A9901c03bB63232abaA7493AA4a21b71B5b0c4`](https://sepolia.basescan.org/address/0xa3A9901c03bB63232abaA7493AA4a21b71B5b0c4) |
| ChainlinkReferenceAdapter | [`0x68E65451A97261B451f186e9B9099c3fBF7efc90`](https://sepolia.basescan.org/address/0x68E65451A97261B451f186e9B9099c3fBF7efc90) |
| Permission mask | `0x30C4` |

The deployed runtime bytecode is 9,625 bytes and reproduces byte-for-byte from this
checkout, which is why `foundry.toml` disables `bytecode_hash` and `cbor_metadata`. An
earlier build at `0x188FAc39…30C4` is superseded: removing the variance and order-flow
subsystem changed the bytecode and therefore the mined CREATE2 address.

**The adverse-selection gate does not currently pass.** The mechanism works and is deployed;
the evidence that it improves liquidity-provider outcomes is not established. See
[`P0-GATE-RESULT.md`](P0-GATE-RESULT.md), which reports the failure and why, rather than the
earlier claim it replaces.

## How it works

```
beforeSwap   read one storage slot -> signed drift vs cached reference -> fee, clamped
afterSwap    advance the tick, refresh the reference at most once per block,
             and on extreme dislocation donate the fee-cap overflow to in-range LPs
```

The fee formula is the no-arbitrage band, not a fitted model. An arbitrageur profits only
while the drift they capture exceeds what they pay for it, so charging a *fraction* of that
drift takes back part of the extraction while leaving the trade worth doing. Deterring
arbitrage entirely would leave the pool stale, which drives away the uninformed flow that is
the liquidity provider's only revenue.

Flow trading *away* from the reference captures nothing, so its drift is negative and it is
quoted below the base fee. That sign is the entire per-swap discrimination.

## Layout

```
src/
  AssayHook.sol                  orchestration; every formula is delegated
  libraries/Mispricing.sol       signed drift, in ticks
  libraries/FeeBlend.sol         drift -> fee, and the fee-cap overflow
  libraries/ToxicitySurcharge.sol  overflow -> token amount
  libraries/Q32x32.sol           fixed point
  libraries/VarianceEwma.sol     realised variance   (not on the swap path; see below)
  libraries/OrderFlowImbalance.sol  order-flow imbalance  (likewise)
  oracle/ChainlinkReferenceAdapter.sol   a feed, presented as a v4 sqrt price
calibration/                     the Python pipeline that measures whether any of this works
```

`VarianceEwma` and `OrderFlowImbalance` are **not** on the swap path. Calibration measured
their incremental value over the reference signal alone at −0.008 and −0.002 across two
independent windows, so they were removed from the hook rather than left to bill every swap
for nothing. The libraries remain, pure and tested, for a milestone that can show they earn
their cost.

## Gas

Three reachable paths, each budgeted and measured separately, because a single number only
ever described the cheapest one.

| path | measured | budget |
| --- | --- | --- |
| ordinary swap | 14,572 | 20,000 |
| block boundary (reference refresh) | 30,901 + ~16,500 live-feed premium | 55,000 |
| extreme dislocation (surcharge) | 48,582 | 55,000 |

A live Chainlink read measures 20,774 gas against the Base Sepolia aggregator, which is why
the reference is cached and refreshed at most once per block rather than read per swap.

## Build

```bash
forge build && forge test
cd calibration && uv venv .venv \
  && uv pip install --python .venv/bin/python -r requirements.lock \
  && .venv/bin/python -m pytest tests/ -q
```

Deployment needs `.env` (see `.env.example`); deploy the oracle adapter first, then the hook:

```bash
forge script script/DeployOracle.s.sol:DeployOracle --rpc-url base_sepolia --broadcast
# set ASSAY_REFERENCE_ORACLE to the address it prints, then
forge script script/DeployAssay.s.sol:DeployAssay  --rpc-url base_sepolia --broadcast
```

## Security

See [`SECURITY.md`](SECURITY.md). Unaudited. Known limitations are listed there rather than
omitted.

## Licence

MIT — see [`LICENSE`](LICENSE).
