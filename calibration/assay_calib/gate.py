from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np
import pandas as pd
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import confusion_matrix, roc_auc_score
from scipy.stats import spearmanr
from sklearn.preprocessing import StandardScaler

from .config import CalibrationConfig
from .features import FEATURE_COLUMNS

log = logging.getLogger(__name__)

# Sign each coefficient must take if the microstructure theory holds. A fitted sign that
# contradicts this is evidence of a labelling or alignment bug, not a discovery.
EXPECTED_SIGNS: dict[str, int] = {
    "is_first_of_block": +1,
    "size_ratio": +1,
    "direction_vs_drift": +1,
    "signed_mispricing": +1,
    "ofi_ewma": +1,
}


@dataclass(frozen=True)
class GateResult:
    label_column: str
    n_train: int
    n_test: int
    base_rate: float
    auc_train: float
    auc_test: float
    coefficients: dict[str, float]
    confusion: dict[str, int]
    threshold: float
    spearman_markout: float

    @property
    def sign_agreement(self) -> dict[str, bool]:
        return {
            name: np.sign(value) == EXPECTED_SIGNS[name]
            for name, value in self.coefficients.items()
            if name in EXPECTED_SIGNS
        }

    def passed(self, cfg: CalibrationConfig) -> bool:
        return self.auc_test >= cfg.gate.min_auc


def _winsorize(frame: pd.DataFrame, lower: float = 0.005, upper: float = 0.995) -> pd.DataFrame:
    """Clip extreme feature values so a handful of outliers cannot dominate the fit."""
    bounds = frame.quantile([lower, upper])
    return frame.clip(bounds.iloc[0], bounds.iloc[1], axis=1)


def run_gate(
    df: pd.DataFrame,
    cfg: CalibrationConfig,
    label_column: str,
    markout_column: str | None = None,
) -> GateResult:
    """
    Fit the logistic classifier and evaluate it out of sample.

    The split is chronological, not random. Swap flow is serially correlated, so a random
    split puts near-identical neighbouring swaps on both sides and reports an optimistic
    score that would not survive deployment.
    """
    df = df.sort_values(["block", "log_index"]).reset_index(drop=True)
    split_at = int(len(df) * (1.0 - cfg.gate.test_fraction))
    train, test = df.iloc[:split_at], df.iloc[split_at:]

    x_train = _winsorize(train[list(FEATURE_COLUMNS)].astype("float64"))
    x_test = test[list(FEATURE_COLUMNS)].astype("float64").clip(
        x_train.min(), x_train.max(), axis=1
    )
    y_train = train[label_column].to_numpy()
    y_test = test[label_column].to_numpy()

    if len(np.unique(y_train)) < 2 or len(np.unique(y_test)) < 2:
        raise ValueError(f"label {label_column} is degenerate in a split; cannot fit")

    scaler = StandardScaler().fit(x_train)
    model = LogisticRegression(
        class_weight="balanced",
        max_iter=2000,
        random_state=cfg.gate.random_seed,
    ).fit(scaler.transform(x_train), y_train)

    p_train = model.predict_proba(scaler.transform(x_train))[:, 1]
    p_test = model.predict_proba(scaler.transform(x_test))[:, 1]

    threshold = float(np.quantile(p_test, 1.0 - y_test.mean()))
    tn, fp, fn, tp = confusion_matrix(y_test, (p_test >= threshold).astype(int)).ravel()

    # Threshold-free check: g(pi) needs the score to *rank* flow by how costly it is, so
    # rank correlation against realised markout measures the thing the fee blend consumes.
    spearman = float("nan")
    if markout_column is not None and markout_column in test.columns:
        realised = test[markout_column].to_numpy()
        finite = np.isfinite(realised)
        if finite.sum() > 2:
            spearman = float(spearmanr(p_test[finite], -realised[finite]).statistic)

    return GateResult(
        label_column=label_column,
        n_train=len(train),
        n_test=len(test),
        base_rate=float(np.mean(np.concatenate([y_train, y_test]))),
        auc_train=float(roc_auc_score(y_train, p_train)),
        auc_test=float(roc_auc_score(y_test, p_test)),
        coefficients=dict(zip(FEATURE_COLUMNS, model.coef_[0], strict=True)),
        confusion={"tn": int(tn), "fp": int(fp), "fn": int(fn), "tp": int(tp)},
        threshold=float(threshold),
        spearman_markout=spearman,
    )


def univariate_auc(df: pd.DataFrame, cfg: CalibrationConfig, label_column: str) -> dict[str, float]:
    """
    Out-of-sample AUC of each feature used alone.

    A feature scoring near 0.50 contributes nothing and is gas spent for no benefit on the
    hot path; one scoring below 0.50 is carrying signal in the opposite direction to theory
    and needs its construction checked before it is trusted.
    """
    df = df.sort_values(["block", "log_index"]).reset_index(drop=True)
    split_at = int(len(df) * (1.0 - cfg.gate.test_fraction))
    test = df.iloc[split_at:]
    y = test[label_column].to_numpy()
    if len(np.unique(y)) < 2:
        return {}

    scores: dict[str, float] = {}
    for name in FEATURE_COLUMNS:
        x = test[name].to_numpy(dtype="float64")
        finite = np.isfinite(x)
        if finite.sum() < 10 or len(np.unique(y[finite])) < 2:
            continue
        scores[name] = float(roc_auc_score(y[finite], x[finite]))
    return scores


def walk_forward_auc(
    df: pd.DataFrame, cfg: CalibrationConfig, label_column: str, folds: int = 5
) -> list[float]:
    """
    AUC across consecutive time folds, each trained only on data preceding it.

    A model that has learned adverse selection should score consistently across folds. One
    that has merely learned the sample's price direction scores well where the trend
    persists and collapses where it reverses, so the spread across folds separates a real
    signal from regime fitting far more reliably than a single split.
    """
    df = df.sort_values(["block", "log_index"]).reset_index(drop=True)
    scores: list[float] = []
    edges = np.linspace(0, len(df), folds + 2, dtype=int)

    for i in range(1, folds + 1):
        train = df.iloc[: edges[i]]
        test = df.iloc[edges[i] : edges[i + 1]]
        if len(test) < 50 or len(train) < 100:
            continue
        y_train, y_test = train[label_column].to_numpy(), test[label_column].to_numpy()
        if len(np.unique(y_train)) < 2 or len(np.unique(y_test)) < 2:
            continue

        x_train = _winsorize(train[list(FEATURE_COLUMNS)].astype("float64"))
        x_test = test[list(FEATURE_COLUMNS)].astype("float64").clip(
            x_train.min(), x_train.max(), axis=1
        )
        scaler = StandardScaler().fit(x_train)
        model = LogisticRegression(
            class_weight="balanced", max_iter=2000, random_state=cfg.gate.random_seed
        ).fit(scaler.transform(x_train), y_train)
        scores.append(
            float(roc_auc_score(y_test, model.predict_proba(scaler.transform(x_test))[:, 1]))
        )
    return scores


def permutation_auc(df: pd.DataFrame, cfg: CalibrationConfig, label_column: str) -> float:
    """
    Refit against a shuffled label to establish the no-signal baseline.

    If the real AUC is not clearly above this, the apparent signal is an artefact of the
    fitting procedure rather than the data.
    """
    shuffled = df.copy()
    rng = np.random.default_rng(cfg.gate.random_seed)
    shuffled[label_column] = rng.permutation(shuffled[label_column].to_numpy())
    return run_gate(shuffled, cfg, label_column).auc_test
