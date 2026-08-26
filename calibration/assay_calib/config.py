from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


class ConfigError(ValueError):
    pass


@dataclass(frozen=True)
class PoolSpec:
    """A Uniswap v3 pool and the token orientation needed to price its swaps."""

    address: str
    token0_symbol: str
    token1_symbol: str
    token0_decimals: int
    token1_decimals: int
    fee_pips: int
    deployed_block: int

    def __post_init__(self) -> None:
        if not self.address.startswith("0x") or len(self.address) != 42:
            raise ConfigError(f"pool address malformed: {self.address}")
        if not 0 < self.fee_pips <= 1_000_000:
            raise ConfigError(f"fee_pips out of range: {self.fee_pips}")
        for d in (self.token0_decimals, self.token1_decimals):
            if not 0 <= d <= 36:
                raise ConfigError(f"implausible token decimals: {d}")

    @property
    def fee_fraction(self) -> float:
        return self.fee_pips / 1_000_000


@dataclass(frozen=True)
class RpcSpec:
    urls: tuple[str, ...]
    log_urls: tuple[str, ...]
    log_chunk_blocks: int
    max_workers: int
    max_retries: int
    backoff_seconds: float
    request_timeout_seconds: float
    inter_request_sleep: float

    def __post_init__(self) -> None:
        if not self.urls:
            raise ConfigError("at least one rpc url required")
        if not self.log_urls:
            raise ConfigError("at least one log-capable rpc url required")
        for u in (*self.urls, *self.log_urls):
            if not u.startswith("https://"):
                raise ConfigError(f"rpc url must be https: {u}")
        if not 1 <= self.log_chunk_blocks <= 10_000:
            raise ConfigError(f"log_chunk_blocks out of range: {self.log_chunk_blocks}")
        if not 1 <= self.max_workers <= 64:
            raise ConfigError(f"max_workers out of range: {self.max_workers}")
        if self.max_retries < 1:
            raise ConfigError("max_retries must be >= 1")


@dataclass(frozen=True)
class ReferenceSpec:
    """The venue and candle resolution the markout label is measured against."""

    venue: str
    symbol: str
    base_url: str
    candle_interval: str
    candle_interval_seconds: int
    page_limit: int
    request_sleep_seconds: float

    def __post_init__(self) -> None:
        if not self.base_url.startswith("https://"):
            raise ConfigError(f"reference base url must be https: {self.base_url}")
        if self.candle_interval_seconds < 1:
            raise ConfigError("candle_interval_seconds must be >= 1")
        if not 1 <= self.page_limit <= 1_000:
            raise ConfigError(f"page_limit out of range: {self.page_limit}")
        if self.request_sleep_seconds < 0:
            raise ConfigError("request_sleep_seconds must be non-negative")


@dataclass(frozen=True)
class LabelSpec:
    """Forward-markout labelling parameters."""

    horizons_seconds: tuple[int, ...]
    primary_horizon_seconds: int
    primary_threshold_multiple: int
    threshold_multiples: tuple[int, ...]

    def __post_init__(self) -> None:
        if not self.horizons_seconds:
            raise ConfigError("at least one markout horizon required")
        if any(h <= 0 for h in self.horizons_seconds):
            raise ConfigError(f"markout horizons must be positive: {self.horizons_seconds}")
        if self.primary_horizon_seconds not in self.horizons_seconds:
            raise ConfigError(
                f"primary horizon {self.primary_horizon_seconds} not in {self.horizons_seconds}"
            )
        if self.primary_threshold_multiple not in self.threshold_multiples:
            raise ConfigError(
                f"primary threshold {self.primary_threshold_multiple} not in "
                f"{self.threshold_multiples}"
            )
        if not self.threshold_multiples or any(k < 1 for k in self.threshold_multiples):
            raise ConfigError(
                f"threshold multiples must all be >= 1: {self.threshold_multiples}"
            )

    def validate_against(self, reference: ReferenceSpec) -> None:
        """
        Reject horizons the reference data cannot express.

        A markout resolves to the first candle closing at or after the target time, so a
        horizon shorter than the candle interval silently becomes a longer and variable
        one: a "30 second" markout against 1-minute candles is really 30 to 90 seconds
        depending on where in the minute the swap landed. The label would then be named
        for a measurement the data does not support.
        """
        shortest = min(self.horizons_seconds)
        if shortest < reference.candle_interval_seconds:
            raise ConfigError(
                f"shortest markout horizon {shortest}s is below the reference candle "
                f"interval {reference.candle_interval_seconds}s; the label cannot resolve "
                f"a horizon finer than the data"
            )


@dataclass(frozen=True)
class FeatureSpec:
    """EWMA decays and lookbacks for the microstructure features."""

    ofi_halflife_swaps: float
    drift_lookback_swaps: int
    min_notional_usd: float

    def __post_init__(self) -> None:
        if self.ofi_halflife_swaps <= 0:
            raise ConfigError("ofi_halflife_swaps must be positive")
        if self.drift_lookback_swaps < 1:
            raise ConfigError("drift_lookback_swaps must be >= 1")
        if self.min_notional_usd < 0:
            raise ConfigError("min_notional_usd must be non-negative")


@dataclass(frozen=True)
class GateSpec:
    """
    The pass/fail criterion for P0.

    The verdict is a conjunction applied to one pre-declared label, not the best of a
    sweep. Searching 18 label variants and reporting whichever scored highest would be
    selection on the test set, and would make the reported AUC an upper order statistic
    rather than an estimate. The sweep is still produced, but only as exploratory output.
    """

    min_auc: float
    test_fraction: float
    random_seed: int
    min_permutation_margin: float
    min_fold_auc: float
    min_test_positives: int
    require_theory_signs: bool
    winsorize_lower: float
    winsorize_upper: float
    max_iter: int
    walk_forward_folds: int
    min_fold_test_rows: int
    min_fold_train_rows: int

    def __post_init__(self) -> None:
        if not 0.5 < self.min_auc < 1.0:
            raise ConfigError(f"min_auc must be in (0.5, 1.0): {self.min_auc}")
        if not 0.0 < self.test_fraction < 0.5:
            raise ConfigError(f"test_fraction must be in (0, 0.5): {self.test_fraction}")
        if not 0.0 <= self.min_permutation_margin < 0.5:
            raise ConfigError(
                f"min_permutation_margin must be in [0, 0.5): {self.min_permutation_margin}"
            )
        if not 0.0 < self.min_fold_auc < 1.0:
            raise ConfigError(f"min_fold_auc must be in (0, 1): {self.min_fold_auc}")
        if self.min_test_positives < 1:
            raise ConfigError(f"min_test_positives must be >= 1: {self.min_test_positives}")
        if not 0.0 <= self.winsorize_lower < self.winsorize_upper <= 1.0:
            raise ConfigError(
                f"winsorize bounds must satisfy 0 <= lower < upper <= 1: "
                f"{self.winsorize_lower}, {self.winsorize_upper}"
            )
        if self.max_iter < 1:
            raise ConfigError(f"max_iter must be >= 1: {self.max_iter}")
        if self.walk_forward_folds < 2:
            raise ConfigError(f"walk_forward_folds must be >= 2: {self.walk_forward_folds}")
        if self.min_fold_test_rows < 1 or self.min_fold_train_rows < 1:
            raise ConfigError("fold row minimums must be >= 1")


@dataclass(frozen=True)
class CalibrationConfig:
    pool: PoolSpec
    rpc: RpcSpec
    labels: LabelSpec
    features: FeatureSpec
    gate: GateSpec
    reference: ReferenceSpec
    days: float
    data_dir: Path
    end_block_lag: int = field(default=300)

    def __post_init__(self) -> None:
        if self.days <= 0:
            raise ConfigError(f"days must be positive: {self.days}")
        if self.end_block_lag < 0:
            raise ConfigError("end_block_lag must be non-negative")
        self.labels.validate_against(self.reference)


# Only venues with a working fetch implementation. Listing one here that fetch.py does not
# handle means a config validates cleanly and then fails deep into a data pull, after
# minutes of RPC work -- the opposite of failing fast.
_CANDLE_SECONDS = {"1s": 1, "1m": 60, "5m": 300}
_VENUE_BASE_URLS = {"binance": "https://api.binance.com/api/v3/klines"}

# Canonical Uniswap v3 USDC/WETH 0.05% pool. token0/token1 orientation is asserted
# against the chain in fetch.verify_pool_orientation before any pricing is done.
USDC_WETH_500 = PoolSpec(
    address="0x88e6A0c2dDD26FEEb64F039a2c41296FcB3f5640",
    token0_symbol="USDC",
    token1_symbol="WETH",
    token0_decimals=6,
    token1_decimals=18,
    fee_pips=500,
    deployed_block=12_376_729,
)


def _env_float(name: str, default: float) -> float:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return float(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be a number, got {raw!r}") from exc


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except ValueError as exc:
        raise ConfigError(f"{name} must be an integer, got {raw!r}") from exc


def _load_reference() -> ReferenceSpec:
    """
    Build the reference-price spec.

    The candle interval is a labelling decision, not a transport detail: it sets the finest
    markout horizon the data can express, so it lives in config and is checked against the
    declared horizons rather than sitting as a literal inside a request body.
    """
    interval = os.environ.get("ASSAY_REFERENCE_INTERVAL", "1s")
    if interval not in _CANDLE_SECONDS:
        raise ConfigError(
            f"unsupported candle interval {interval!r}; expected one of {sorted(_CANDLE_SECONDS)}"
        )
    venue = os.environ.get("ASSAY_REFERENCE_VENUE", "binance")
    if venue not in _VENUE_BASE_URLS:
        raise ConfigError(
            f"unknown reference venue {venue!r}; expected one of {sorted(_VENUE_BASE_URLS)}"
        )
    return ReferenceSpec(
        venue=venue,
        symbol=os.environ.get("ASSAY_REFERENCE_SYMBOL", "ETHUSDT"),
        base_url=_VENUE_BASE_URLS[venue],
        candle_interval=interval,
        candle_interval_seconds=_CANDLE_SECONDS[interval],
        page_limit=_env_int("ASSAY_REFERENCE_PAGE_LIMIT", 1_000),
        request_sleep_seconds=_env_float("ASSAY_REFERENCE_SLEEP_SECONDS", 0.12),
    )


def load_config() -> CalibrationConfig:
    """Build the config from the environment, failing fast on anything malformed."""
    repo_root = Path(__file__).resolve().parents[2]
    return CalibrationConfig(
        pool=USDC_WETH_500,
        rpc=RpcSpec(
            urls=tuple(
                os.environ.get(
                    "ASSAY_RPC_URLS",
                    "https://eth.drpc.org,https://rpc.flashbots.net,"
                    "https://eth.merkle.io,https://ethereum-rpc.publicnode.com",
                ).split(",")
            ),
            # Only endpoints verified to serve complete eth_getLogs. flashbots returns an
            # empty result set with no error and merkle does not implement the method, so
            # including them here would silently truncate the dataset.
            log_urls=tuple(
                os.environ.get("ASSAY_RPC_LOG_URLS", "https://eth.drpc.org").split(",")
            ),
            log_chunk_blocks=_env_int("ASSAY_LOG_CHUNK_BLOCKS", 1_000),
            max_workers=_env_int("ASSAY_RPC_MAX_WORKERS", 12),
            max_retries=_env_int("ASSAY_RPC_MAX_RETRIES", 5),
            backoff_seconds=_env_float("ASSAY_RPC_BACKOFF_SECONDS", 1.5),
            request_timeout_seconds=_env_float("ASSAY_RPC_TIMEOUT_SECONDS", 90.0),
            inter_request_sleep=_env_float("ASSAY_RPC_SLEEP_SECONDS", 0.0),
        ),
        labels=LabelSpec(
            horizons_seconds=(30, 300, 3_600),
            # The primary label is declared here, before the data is read, and is the only
            # one the verdict considers. Theory picks it: CEX-DEX arbitrage captures a stale
            # price rather than forecasting, so the signal belongs at the shortest horizon,
            # and the threshold must exceed the fee by enough that ordinary price noise does
            # not clear it. A label chosen after inspecting the sweep would be selection on
            # the test set.
            primary_horizon_seconds=_env_int("ASSAY_PRIMARY_HORIZON_SECONDS", 30),
            primary_threshold_multiple=_env_int("ASSAY_PRIMARY_THRESHOLD_MULTIPLE", 5),
            threshold_multiples=(1, 2, 5),
        ),
        features=FeatureSpec(
            ofi_halflife_swaps=_env_float("ASSAY_OFI_HALFLIFE_SWAPS", 50.0),
            drift_lookback_swaps=_env_int("ASSAY_DRIFT_LOOKBACK_SWAPS", 20),
            min_notional_usd=_env_float("ASSAY_MIN_NOTIONAL_USD", 100.0),
        ),
        gate=GateSpec(
            min_auc=_env_float("ASSAY_GATE_MIN_AUC", 0.65),
            test_fraction=_env_float("ASSAY_GATE_TEST_FRACTION", 0.3),
            random_seed=_env_int("ASSAY_SEED", 20260819),
            # The classifier must beat its own shuffled-label control by a real margin, or
            # the score is an artefact of the fitting procedure rather than the data.
            min_permutation_margin=_env_float("ASSAY_GATE_MIN_PERMUTATION_MARGIN", 0.05),
            # Every walk-forward fold must clear this. A signal that holds in some periods
            # and collapses in others is tracking the sample's price regime.
            min_fold_auc=_env_float("ASSAY_GATE_MIN_FOLD_AUC", 0.60),
            min_test_positives=_env_int("ASSAY_GATE_MIN_TEST_POSITIVES", 100),
            require_theory_signs=_env_int("ASSAY_GATE_REQUIRE_SIGNS", 1) == 1,
            winsorize_lower=_env_float("ASSAY_GATE_WINSORIZE_LOWER", 0.005),
            winsorize_upper=_env_float("ASSAY_GATE_WINSORIZE_UPPER", 0.995),
            max_iter=_env_int("ASSAY_GATE_MAX_ITER", 2_000),
            walk_forward_folds=_env_int("ASSAY_GATE_WALK_FORWARD_FOLDS", 5),
            min_fold_test_rows=_env_int("ASSAY_GATE_MIN_FOLD_TEST_ROWS", 50),
            min_fold_train_rows=_env_int("ASSAY_GATE_MIN_FOLD_TRAIN_ROWS", 100),
        ),
        reference=_load_reference(),
        days=_env_float("ASSAY_DAYS", 7.0),
        data_dir=Path(os.environ.get("ASSAY_DATA_DIR", str(repo_root / "data"))),
    )
