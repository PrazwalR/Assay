from __future__ import annotations

import argparse
import hashlib
import json
import logging
import sys
from pathlib import Path

import numpy as np
import pandas as pd

from assay_calib.config import CalibrationConfig, load_config
from assay_calib.features import (
    FEATURE_COLUMNS,
    attach_markouts,
    build_frame,
    clean,
)
from assay_calib.fetch import decode_big_ints
from assay_calib.gate import (
    EXPECTED_SIGNS,
    GateResult,
    permutation_auc,
    run_gate,
    univariate_auc,
    walk_forward_auc,
)

log = logging.getLogger("assay.gate")

BLOCK_SECONDS = 12


def _load_cached(data_dir: Path, tag: str) -> tuple[pd.DataFrame, pd.DataFrame, pd.DataFrame]:
    paths = {
        name: data_dir / f"{name}_{tag}.parquet" for name in ("swaps", "blocks", "reference")
    }
    missing = [p.name for p in paths.values() if not p.exists()]
    if missing:
        raise FileNotFoundError(
            f"missing cached data: {missing}. Run: python fetch_data.py --days N"
        )
    return (
        decode_big_ints(pd.read_parquet(paths["swaps"])),
        pd.read_parquet(paths["blocks"]),
        pd.read_parquet(paths["reference"]),
    )


def _dataset_hash(df: pd.DataFrame) -> str:
    return hashlib.sha256(
        pd.util.hash_pandas_object(df[list(FEATURE_COLUMNS)], index=False).values.tobytes()
    ).hexdigest()[:16]


def _print_matrix(rows: list[dict], cfg: CalibrationConfig) -> None:
    print(f"\n{'=' * 92}")
    print("SIGNAL MATRIX -- out-of-sample AUC by markout horizon and threshold")
    print(f"{'=' * 92}")
    print(
        f"{'variant':<7}{'horizon':>9}{'k':>4}{'base_rate':>11}"
        f"{'AUC_test':>10}{'AUC_shuf':>10}{'spearman':>10}{'n_test':>9}"
    )
    print("-" * 92)
    for r in rows:
        if r.get("error"):
            print(f"{r['variant']:<7}{r['horizon']:>9}{r['k']:>4}   {r['error']}")
            continue
        print(
            f"{r['variant']:<7}{r['horizon']:>9}{r['k']:>4}{r['base_rate']:>11.4f}"
            f"{r['auc_test']:>10.4f}{r['auc_shuffled']:>10.4f}"
            f"{r['spearman']:>10.4f}{r['n_test']:>9,}"
        )
    print("-" * 92)
    print(f"gate threshold: AUC_test >= {cfg.gate.min_auc}")


def _print_coefficients(result: GateResult) -> None:
    print(f"\ncoefficients for {result.label_column} (standardised)")
    agreement = result.sign_agreement
    for name, value in result.coefficients.items():
        mark = "ok " if agreement.get(name) else "!! "
        print(f"  {mark}{name:22} {value:+.4f}   theory expects {EXPECTED_SIGNS[name]:+d}")
    c = result.confusion
    prec = c["tp"] / (c["tp"] + c["fp"]) if c["tp"] + c["fp"] else 0.0
    rec = c["tp"] / (c["tp"] + c["fn"]) if c["tp"] + c["fn"] else 0.0
    print(f"  confusion  tn={c['tn']:,} fp={c['fp']:,} fn={c['fn']:,} tp={c['tp']:,}")
    print(f"  precision={prec:.4f} recall={rec:.4f}")


def _describe_labels(frame: pd.DataFrame, cfg: CalibrationConfig) -> None:
    print(f"\n{'=' * 92}")
    print("MARKOUT DISTRIBUTION (bps of notional, 'std' variant)")
    print(f"{'=' * 92}")
    print(f"{'horizon':>9}{'mean':>10}{'median':>10}{'p10':>10}{'p90':>10}{'std':>10}{'n':>9}")
    for h in cfg.labels.horizons_seconds:
        col = f"markout_bps_std_{h}s"
        v = frame[col].to_numpy()
        v = v[np.isfinite(v)]
        if v.size == 0:
            continue
        print(
            f"{h:>9}{v.mean():>10.2f}{np.median(v):>10.2f}"
            f"{np.percentile(v, 10):>10.2f}{np.percentile(v, 90):>10.2f}"
            f"{v.std():>10.2f}{v.size:>9,}"
        )
    print(f"\nfee is {cfg.pool.fee_fraction * 1e4:.1f} bps -- a label only carries information")
    print("if realised markout is separable from noise at that scale")


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    )
    parser = argparse.ArgumentParser(description="Assay P0 adverse-selection AUC gate")
    parser.add_argument("--tag", required=True, help="cached dataset tag, e.g. 25769042_25790642")
    args = parser.parse_args()

    cfg = load_config()
    swaps, block_times, reference = _load_cached(cfg.data_dir, args.tag)
    log.info("loaded %d swaps, %d blocks, %d candles", len(swaps), len(block_times), len(reference))

    frame = build_frame(swaps, block_times, reference, cfg)
    frame = attach_markouts(frame, reference, cfg)
    _describe_labels(frame, cfg)

    summary_folds: dict[str, list[float]] = {}
    rows: list[dict] = []
    best: tuple[float, GateResult] | None = None
    for variant in ("std", "drift"):
        for horizon in cfg.labels.horizons_seconds:
            for k in cfg.labels.threshold_multiples:
                label = f"informed_{variant}_{horizon}s_k{k}"
                markout = f"markout_bps_{variant}_{horizon}s"
                scored = clean(frame, cfg, label)
                entry = {"variant": variant, "horizon": horizon, "k": k}
                try:
                    result = run_gate(scored, cfg, label, markout)
                    entry.update(
                        base_rate=result.base_rate,
                        auc_test=result.auc_test,
                        auc_train=result.auc_train,
                        auc_shuffled=permutation_auc(scored, cfg, label),
                        spearman=result.spearman_markout,
                        n_test=result.n_test,
                        coefficients=result.coefficients,
                        sign_agreement={k2: bool(v) for k2, v in result.sign_agreement.items()},
                        passed=bool(result.passed(cfg)),
                    )
                    if best is None or result.auc_test > best[0]:
                        best = (result.auc_test, result)
                except ValueError as exc:
                    entry["error"] = str(exc)
                rows.append(entry)

    _print_matrix(rows, cfg)
    if best is not None:
        _print_coefficients(best[1])
        label = best[1].label_column
        uni = univariate_auc(clean(frame, cfg, label), cfg, label)
        if uni:
            print(f"\nunivariate out-of-sample AUC for {label}")
            print("  (0.50 = no signal; below 0.50 = signal runs opposite to theory)")
            for name, score in sorted(uni.items(), key=lambda kv: -abs(kv[1] - 0.5)):
                print(f"    {name:22} {score:.4f}")

        print(f"\nwalk-forward AUC across time folds for {label}")
        folds = walk_forward_auc(clean(frame, cfg, label), cfg, label)
        if folds:
            spread = max(folds) - min(folds)
            print("    " + "  ".join(f"{f:.3f}" for f in folds))
            print(f"    mean={np.mean(folds):.4f}  min={min(folds):.4f}  spread={spread:.4f}")
            print("    a wide spread means the fit tracks the sample's price regime,")
            print("    not adverse selection")
        summary_folds[label] = folds

    passed = [r for r in rows if r.get("passed")]
    print(f"\n{'=' * 92}")
    if best is None:
        print("P0 GATE: INCONCLUSIVE -- no label variant could be fitted")
    else:
        print(f"P0 GATE: best out-of-sample AUC = {best[0]:.4f} on {best[1].label_column}")
        print(f"         {len(passed)}/{len(rows)} label variants clear AUC >= {cfg.gate.min_auc}")
        print(f"         VERDICT: {'PASS' if passed else 'FAIL'}")
    print(f"{'=' * 92}")

    primary = f"informed_std_{cfg.labels.primary_horizon_seconds}s_k1"
    summary = {
        "pool": cfg.pool.address,
        "tag": args.tag,
        "n_swaps_raw": int(len(swaps)),
        "dataset_hash": _dataset_hash(clean(frame, cfg, primary)),
        "gate_min_auc": cfg.gate.min_auc,
        "best_auc_test": best[0] if best else None,
        "best_label": best[1].label_column if best else None,
        "verdict": "PASS" if passed else "FAIL",
        "walk_forward": summary_folds,
        "matrix": rows,
    }
    out = cfg.data_dir / f"p0_gate_result_{args.tag}.json"
    out.write_text(json.dumps(summary, indent=2, default=float))
    print(f"wrote {out}")
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
