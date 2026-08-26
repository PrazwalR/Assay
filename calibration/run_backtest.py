from __future__ import annotations

import argparse
import json
import logging
import sys
from pathlib import Path

import pandas as pd

from assay_calib.backtest import BacktestResult, compare
from assay_calib.config import CalibrationConfig, load_config
from assay_calib.features import attach_markouts, build_frame, clean
from assay_calib.fetch import decode_big_ints

log = logging.getLogger("assay.backtest")


def _load(data_dir: Path, tag: str) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    paths = {name: data_dir / f"{name}_{tag}.parquet" for name in ("swaps", "blocks", "reference")}
    missing = [p.name for p in paths.values() if not p.exists()]
    if missing:
        raise FileNotFoundError(f"missing cached data: {missing}. Run: python fetch_data.py --days N")
    return (
        decode_big_ints(pd.read_parquet(paths["swaps"])),
        pd.read_parquet(paths["blocks"]),
        pd.read_parquet(paths["reference"]),
    )


def _report(results: list[BacktestResult], elasticity: float, label: str, rows: int) -> None:
    baseline = results[0]

    print(f"\n{'=' * 100}")
    print("COUNTERFACTUAL BACKTEST -- arbitrage re-optimises its size under each fee schedule")
    print(f"{'=' * 100}")
    print(f"  label            {label}")
    print(f"  swaps            {rows:,}")
    print(f"  uninformed decay {elasticity:.3f} per basis point of excess fee")
    print()
    print(
        f"{'policy':<16}{'LP net':>14}{'vs static':>12}{'fees':>14}"
        f"{'picked off':>14}{'arb vol':>14}{'uninf vol':>14}{'resid bp':>10}"
    )
    print("-" * 100)
    for r in results:
        delta = r.lp_net_usd - baseline.lp_net_usd
        marker = "" if r is baseline else f"{delta:+,.0f}"
        print(
            f"{r.policy:<16}{r.lp_net_usd:>14,.0f}{marker:>12}"
            f"{r.lp_fee_revenue_usd:>14,.0f}{r.lp_adverse_selection_usd:>14,.0f}"
            f"{r.arbitrage_volume_usd:>14,.0f}{r.uninformed_volume_usd:>14,.0f}"
            f"{r.mean_residual_drift_bps:>10.2f}"
        )
    print("-" * 100)

    best = max(results, key=lambda r: r.lp_net_usd)
    if best is baseline:
        print("  No capture share beat the static fee on this flow.")
    else:
        gain = best.lp_net_usd - baseline.lp_net_usd
        pct = 100.0 * gain / abs(baseline.lp_net_usd) if baseline.lp_net_usd else float("nan")
        print(f"  Best: {best.policy} at {gain:+,.0f} USD ({pct:+.1f}% vs static)")
        print(f"  Cost: residual drift {best.mean_residual_drift_bps:.2f} bp vs "
              f"{baseline.mean_residual_drift_bps:.2f} bp, so the pool sits further from its reference.")
    print(f"{'=' * 100}")


def _sweep_elasticity(
    scored: pd.DataFrame, cfg: CalibrationConfig, label: str, shares: tuple[float, ...]
) -> None:
    """
    Show how the conclusion moves with the one parameter that was never measured.

    How sharply uninformed flow abandons a pool when its fee rises is the single input here
    that is assumed rather than estimated, and the whole result turns on it. Reporting one
    value would present a choice as a finding, so the range is swept and the point where the
    static fee wins is stated outright.
    """
    print(f"\n{'=' * 100}")
    print("SENSITIVITY -- the uninformed decay is assumed, not measured, so the result is swept")
    print(f"{'=' * 100}")
    print(f"{'decay/bp':>10}{'retention @20bp':>18}{'best policy':>18}{'LP net gain':>16}{'verdict':>14}")
    print("-" * 100)

    import math

    flipped_at = None
    for elasticity in (0.0, 0.02, 0.05, 0.10, 0.20, 0.35, 0.50):
        results = compare(scored, cfg, label, shares, elasticity)
        baseline, best = results[0], max(results, key=lambda r: r.lp_net_usd)
        gain = best.lp_net_usd - baseline.lp_net_usd
        wins = best is not baseline
        if not wins and flipped_at is None:
            flipped_at = elasticity
        print(
            f"{elasticity:>10.2f}{math.exp(-elasticity * 20):>18.1%}"
            f"{best.policy:>18}{gain:>16,.0f}{'assay' if wins else 'static':>14}"
        )
    print("-" * 100)
    if flipped_at is None:
        print("  Assay wins across every decay tested, including implausibly elastic flow.")
    else:
        print(f"  The static fee wins once the decay reaches {flipped_at:.2f} per basis point,")
        print(f"  at which a 20bp excess fee retains only {math.exp(-flipped_at * 20):.0%} of uninformed volume.")
    print(f"{'=' * 100}")


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(description="Assay counterfactual fee backtest")
    parser.add_argument("--tag", required=True, help="cached dataset tag")
    parser.add_argument(
        "--elasticity",
        type=float,
        default=0.05,
        help="uninformed volume decay per basis point of excess fee; swept, not estimated",
    )
    args = parser.parse_args()

    cfg = load_config()
    swaps, blocks, reference = _load(cfg.data_dir, args.tag)
    frame = attach_markouts(build_frame(swaps, blocks, reference, cfg), reference, cfg)

    label = (
        f"informed_std_{cfg.labels.primary_horizon_seconds}s"
        f"_k{cfg.labels.primary_threshold_multiple}"
    )
    scored = clean(frame, cfg, label)

    shares = (2_500.0, 5_000.0, 7_500.0, 10_000.0)
    results = compare(scored, cfg, label, shares, args.elasticity)
    _report(results, args.elasticity, label, len(scored))
    _sweep_elasticity(scored, cfg, label, shares)

    out = cfg.data_dir / f"backtest_{args.tag}.json"
    out.write_text(
        json.dumps(
            {
                "tag": args.tag,
                "label": label,
                "rows": len(scored),
                "uninformed_elasticity": args.elasticity,
                "results": [
                    {
                        "policy": r.policy,
                        "lp_net_usd": r.lp_net_usd,
                        "lp_fee_revenue_usd": r.lp_fee_revenue_usd,
                        "lp_adverse_selection_usd": r.lp_adverse_selection_usd,
                        "arbitrage_volume_usd": r.arbitrage_volume_usd,
                        "uninformed_volume_usd": r.uninformed_volume_usd,
                        "mean_residual_drift_bps": r.mean_residual_drift_bps,
                    }
                    for r in results
                ],
            },
            indent=2,
        )
    )
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
