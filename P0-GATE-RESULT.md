# P0 — Adverse-Selection AUC Gate

**Verdict: FAIL, on both windows.** The gate is not met. This document is generated from
`data/p0_gate_result_<tag>.json`; where the two disagree, the JSON is authoritative.

> An earlier revision of this file reported **PASS at AUC 0.781**. That figure came from
> reference data at 1-minute resolution, under which a "30 second" markout actually resolved
> to the next minute boundary and so measured a 30-to-90 second horizon. After the reference
> was refetched at 1-second resolution the same label scores **0.7485**, and two of the five
> gate criteria fail. The document was not regenerated at the time. It is corrected here.

## What was tested

Uniswap v3 USDC/WETH 0.05% on Ethereum mainnet, two non-overlapping three-day windows, with
1-second Binance reference candles. The verdict is a conjunction of five criteria applied to
a single label declared in configuration before the data is read — not the best of a sweep.

| | active window | quiet window |
| --- | --- | --- |
| tag | `25769104_25790704` | `25747503_25769103` |
| raw swaps | 12,252 | 7,274 |
| dataset hash | `430f798c19b0b3a3` | `eb63f4d2b73b7c6c` |
| label | `informed_std_30s_k5` | `informed_std_30s_k5` |

## The verdict

| criterion | active | quiet |
| --- | --- | --- |
| out-of-sample AUC ≥ 0.65 | **PASS** 0.7485 | **PASS** 0.9933 |
| margin over shuffled control ≥ 0.05 | **PASS** 0.277 | **PASS** 0.399 |
| weakest walk-forward fold ≥ 0.60 | **FAIL** 0.469 | PASS 0.991 |
| test positives ≥ 100 | **FAIL** 91 | **FAIL** 24 |
| every feature informative in the predicted direction | PASS 0.526 | **FAIL** 0.003 |
| **verdict** | **FAIL** | **FAIL** |

Both windows fail, for different reasons. The active window has a signal that does not hold
across time folds. The quiet window has almost no informed flow to find — 24 positives — and
one feature running almost perfectly backwards, which is what an AUC of 0.003 means.

## The finding that matters more than the verdict

The microstructure features add nothing over reading a price oracle.

| feature set | active | quiet |
| --- | --- | --- |
| `oracle_only` (signed mispricing alone) | 0.7564 | 0.9955 |
| `onchain_only` (four features, no oracle) | 0.7255 | 0.9086 |
| `full` (all five) | 0.7485 | 0.9933 |
| **microstructure adds over oracle** | **−0.0078** | **−0.0022** |

Negative on both. Swept across every horizon and threshold combination, the incremental
value is negative in 10 of 12 cells; the two positives are +0.002 and +0.010, which is noise.

The quiet window's 0.9955 from a single feature is not a strong result — it is close to a
tautology. Short-horizon markout is `[market move] + [mispricing captured]`, and when the
reference barely moves the first term vanishes and the label collapses into the feature.
Measured reference volatility was 2.64 bps in the quiet window against 6.66 bps in the
active one, and `corr(mispricing, markout)` rises from +0.05 to +0.29 accordingly.

## What this does and does not support

**Supported.** Toxicity is detectable per swap: AUC 0.75 against a shuffled control at 0.47
is a real signal, and the signed mispricing is genuinely a per-swap quantity — two swaps in
one block trading opposite directions get opposite values. That is the property a
volatility-conditioned fee structurally cannot have, and it is what the deployed hook prices.

**Not supported.** That the signal is regime-stable, that the six-feature microstructure
model earns its place, or that the mechanism is oracle-free. All three were claimed in
earlier revisions of this document and all three are refuted by the measurements above.

## Why the gate is not simply loosened

Every criterion that fails is failing for a reason worth respecting:

- **91 and 24 test positives.** At `k=5` the label keeps only swaps earning five times the
  fee, which is 1.3% of flow. Thirty days of data would clear the floor honestly; lowering
  the floor would not.
- **Weakest fold 0.469.** A signal below chance in one fold of four is not a stable signal.
- **Univariate 0.003.** A feature ranking almost perfectly backwards is evidence of either a
  regime the theory does not describe or a labelling artefact, and it should be understood
  rather than gated away.

## Reproduce

```bash
cd calibration
uv venv .venv && uv pip install --python .venv/bin/python -r requirements.lock
.venv/bin/python fetch_data.py --from-block 25769104 --to-block 25790704
.venv/bin/python run_gate.py --tag 25769104_25790704   # exits non-zero on FAIL
```

## Where this leaves the project

The hook is deployed and works: it quotes a per-swap fee from signed mispricing, with a
measured 100× spread between two swaps in the same block trading opposite directions. What
is not established is that doing so improves liquidity-provider outcomes on this pool, at
this horizon, with this labelling.

The blocking work is the labelling, not the mechanism. A 30-second markout is partly
tautological with the mispricing feature by construction. Until that is separated — a longer
horizon, or a label that nets out the drift present at execution — the gate cannot
distinguish a real signal from a definition.
