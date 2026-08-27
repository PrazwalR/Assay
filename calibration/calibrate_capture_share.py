"""
Choose `captureShareBps`, the one free parameter of the fee mechanism.

The obvious approach -- run the backtest and take whichever share scored highest -- is the
same mistake the P0 gate had to be rewritten to avoid. The best share depends on how sharply
uninformed flow leaves when fees rise, and that elasticity has never been measured. Reporting
the argmax under one guess at it would present a choice as a finding.

So this searches for robustness rather than for a maximum: across the whole plausible range
of that unmeasured elasticity, and across both independent windows of flow, which share has
the least bad worst case. A parameter that is merely optimal under a favourable assumption is
worth less than one that is defensible under an unfavourable one, because the assumption is
the part nobody can check.
"""

from __future__ import annotations

import argparse
import json
import logging
import sys

import pandas as pd

from assay_calib.backtest import FeePolicy, run_policy
from assay_calib.config import CalibrationConfig, load_config
from assay_calib.features import attach_markouts, build_frame, clean
from assay_calib.fetch import decode_big_ints

log = logging.getLogger("assay.calibrate")

# The range considered, including values where the static fee wins: truncating it to the
# region where the mechanism looks good would be assuming the conclusion.
#
# The upper end is bounded by evidence rather than taste. Uniswap runs ETH/USDC at both a 5bp
# and a 30bp tier and both carry real volume, so a 25bp fee difference plainly does not
# eliminate flow. An elasticity of 0.35/bp would predict the 30bp tier holds 0.016% of the
# 5bp tier's volume, and 0.50/bp predicts 0.0004%; neither is true. Values above roughly
# 0.12/bp are therefore ruled out by the tier structure existing at all.
#
# The exact bound needs the tier volumes measured, which has not been done -- so the default
# ceiling is set loosely above the implied range and is overridable.
_ELASTICITIES = (0.0, 0.02, 0.05, 0.08, 0.10, 0.12, 0.15, 0.20, 0.30, 0.40, 0.50)
_SHARES = tuple(float(s) for s in range(1_000, 10_001, 500))


def _load_scored(cfg: CalibrationConfig, tag: str) -> tuple[pd.DataFrame, str]:
    paths = {
        name: cfg.data_dir / f"{name}_{tag}.parquet" for name in ("swaps", "blocks", "reference")
    }
    missing = [p.name for p in paths.values() if not p.exists()]
    if missing:
        raise FileNotFoundError(f"missing cached data: {missing}")

    frame = attach_markouts(
        build_frame(
            decode_big_ints(pd.read_parquet(paths["swaps"])),
            pd.read_parquet(paths["blocks"]),
            pd.read_parquet(paths["reference"]),
            cfg,
        ),
        pd.read_parquet(paths["reference"]),
        cfg,
    )
    label = (
        f"informed_std_{cfg.labels.primary_horizon_seconds}s"
        f"_k{cfg.labels.primary_threshold_multiple}"
    )
    return clean(frame, cfg, label), label


def _gain_grid(
    scored: pd.DataFrame, cfg: CalibrationConfig, label: str, elasticities: tuple[float, ...]
) -> dict[float, dict[float, float]]:
    """LP net gain over the static fee, for each capture share at each elasticity."""
    base = float(cfg.pool.fee_pips)
    static = FeePolicy("static", base, base, base, 0.0)

    grid: dict[float, dict[float, float]] = {}
    for elasticity in elasticities:
        baseline = run_policy(scored, static, label, elasticity, base).lp_net_usd
        row: dict[float, float] = {}
        for share in _SHARES:
            policy = FeePolicy(f"assay_{int(share)}", base, base / 5.0, base * 20.0, share)
            row[share] = run_policy(scored, policy, label, elasticity, base).lp_net_usd - baseline
        grid[elasticity] = row
    return grid


def _report_window(name: str, grid: dict[float, dict[float, float]]) -> dict[float, float]:
    """Prints the per-elasticity optimum and returns each share's worst case."""
    print(f"\n{'=' * 92}")
    print(f"WINDOW: {name}")
    print(f"{'=' * 92}")
    print(
        f"{'elasticity':>12}{'best share':>14}{'gain at best':>16}"
        f"{'gain @5000':>14}{'gain @7500':>14}"
    )
    print("-" * 92)

    worst_case: dict[float, float] = {share: float("inf") for share in _SHARES}
    for elasticity, row in grid.items():
        best_share = max(row, key=row.get)
        print(
            f"{elasticity:>12.2f}{int(best_share):>14,}{row[best_share]:>16,.0f}"
            f"{row[5_000.0]:>14,.0f}{row[7_500.0]:>14,.0f}"
        )
        for share, gain in row.items():
            worst_case[share] = min(worst_case[share], gain)
    print("-" * 92)
    return worst_case


def main() -> int:
    logging.basicConfig(level=logging.WARNING, format="%(levelname)-7s %(name)s: %(message)s")
    parser = argparse.ArgumentParser(description="Calibrate captureShareBps")
    parser.add_argument("--tags", nargs="+", required=True, help="two or more cached dataset tags")
    parser.add_argument(
        "--max-elasticity",
        type=float,
        default=0.15,
        help=(
            "largest uninformed decay per bp considered plausible. Above ~0.12 the implied "
            "volume ratio between the 5bp and 30bp ETH/USDC tiers contradicts both existing."
        ),
    )
    args = parser.parse_args()

    considered = tuple(e for e in _ELASTICITIES if e <= args.max_elasticity)
    if not considered:
        parser.error(f"--max-elasticity {args.max_elasticity} excludes every value tested")

    cfg = load_config()
    combined_worst: dict[float, float] = {share: float("inf") for share in _SHARES}

    for tag in args.tags:
        scored, label = _load_scored(cfg, tag)
        grid = _gain_grid(scored, cfg, label, considered)
        worst = _report_window(f"{tag}  ({len(scored):,} swaps, label {label})", grid)
        for share, gain in worst.items():
            combined_worst[share] = min(combined_worst[share], gain)

    print(f"\n{'=' * 92}")
    print("ROBUST CHOICE -- worst case for each share across every elasticity and window")
    print(f"  elasticities considered: {', '.join(f'{e:.2f}' for e in considered)}")
    print(f"{'=' * 92}")
    print(f"{'share (bps)':>14}{'worst-case gain':>20}{'':>6}")
    print("-" * 92)
    for share in _SHARES:
        gain = combined_worst[share]
        marker = "  <-- best worst case" if gain == max(combined_worst.values()) else ""
        print(f"{int(share):>14,}{gain:>20,.0f}{marker}")
    print("-" * 92)

    robust = max(combined_worst, key=combined_worst.get)
    guarantee = combined_worst[robust]

    if guarantee <= 0:
        print("  No share is profitable under every assumption tested. The least bad is")
        print(
            f"  {int(robust):,} bps, which still loses {abs(guarantee):,.0f} USD in its worst case."
        )
        print("  The static fee is the defensible choice on this evidence.")
    else:
        print(f"  Recommended: {int(robust):,} bps")
        print(f"  Guarantees at least {guarantee:,.0f} USD over the static fee across every")
        print("  elasticity and both windows tested -- chosen for its worst case, not its best.")
    print(f"{'=' * 92}")

    out = cfg.data_dir / "capture_share_calibration.json"
    out.write_text(
        json.dumps(
            {
                "tags": args.tags,
                "elasticities": list(considered),
                "max_elasticity": args.max_elasticity,
                "shares": list(_SHARES),
                "worst_case_gain_usd": {str(int(s)): combined_worst[s] for s in _SHARES},
                "recommended_capture_share_bps": int(robust),
                "worst_case_guarantee_usd": guarantee,
            },
            indent=2,
        )
    )
    print(f"wrote {out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
