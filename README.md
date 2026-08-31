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

Unaudited, and never having held value. Base Sepolia only. All four addresses below are
source-verified on Basescan.

| | |
| --- | --- |
| AssayHook | [`0x4A20EB2C6B928d4c153E4cDe2D7011ead9fCb0c4`](https://sepolia.basescan.org/address/0x4A20EB2C6B928d4c153E4cDe2D7011ead9fCb0c4) |
| ChainlinkReferenceAdapter | [`0xFA99bbD088EEc136b626aE98003240F12e851f98`](https://sepolia.basescan.org/address/0xFA99bbD088EEc136b626aE98003240F12e851f98) |
| Pool id (USDC/WETH, inside PoolManager) | `0xbb01cc76d59b8baa0df9cabb9751df62d23adc3b4ad38f59822cd09be74707c2` |
| PoolManager | [`0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408`](https://sepolia.basescan.org/address/0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408) |
| Swap router | [`0x689E091c7411dB859915E3D8e9b37aee1dC343Ef`](https://sepolia.basescan.org/address/0x689E091c7411dB859915E3D8e9b37aee1dC343Ef) |
| Liquidity router | [`0xA0a08ed6bBa5c790c8FF296DE5006ffC672d8599`](https://sepolia.basescan.org/address/0xA0a08ed6bBa5c790c8FF296DE5006ffC672d8599) |
| Permission mask | `0x30C4` |

The deployed runtime bytecode is 10,811 bytes and reproduces byte-for-byte from this
checkout, which is why `foundry.toml` disables `bytecode_hash` and `cbor_metadata`. Two
earlier builds are superseded at this address: `0x188FAc39…30C4` predates removing the
variance and order-flow subsystem, and `0xa3A9901c…B5b0c4` (9,625 bytes) predates the
reference-deviation cap. Each change altered the bytecode and therefore the mined CREATE2
address. None of the superseded deployments held value.

**The adverse-selection gate does not currently pass.** AUC came in at 0.7485 against a 0.75
floor, on 91 positive examples against a floor of 100, with the weakest walk-forward fold at
0.469 against a floor of 0.60. The mechanism works and is deployed; the evidence that it
improves liquidity-provider outcomes is not established. Full writeup on the Risk page in the
app's docs (`frontend/src/components/docs/pages.tsx`, the `Risk` component; served at
`/docs/risk`).

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

## Tests

```
forge test                            156 tests
forge test --match-path "test/invariant/*"   7 stateful properties, 8,192 calls each
```

Unit tests assert what happens in orderings someone thought to write down. The invariant
suite fuzzes the *ordering itself* — swaps, liquidity changes, block advances and reference
price events in any sequence — and asserts properties that must hold after all of them:
quoted fees stay inside the bounds `feeBounds()` advertises, the hook never accumulates a
token balance, no delta is left unsettled, and liquidity can always be withdrawn.

It runs with `fail_on_revert = true`, so a revert anywhere in a sequence aborts the run
rather than being absorbed. Four of the five real bugs found in this project came from state
interactions across calls, which is what this reaches and a fixed test sequence does not.

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
