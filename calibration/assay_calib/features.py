from __future__ import annotations

import logging

import numpy as np
import pandas as pd

from .config import CalibrationConfig

log = logging.getLogger(__name__)

Q96 = 1 << 96
LOG_1_0001 = np.log(1.0001)

FEATURE_COLUMNS: tuple[str, ...] = (
    "is_first_of_block",
    "size_ratio",
    "direction_vs_drift",
    "signed_mispricing",
    "ofi_ewma",
)


def _sqrt_price_to_eth_usdc(sqrt_price_x96: pd.Series, dec0: int, dec1: int) -> pd.Series:
    """
    Convert sqrtPriceX96 to ETH price quoted in USDC.

    price_raw = (sqrtPriceX96 / 2**96)**2 is token1 per token0 in raw units. With
    token0=USDC(6) and token1=WETH(18), raw is wei-per-USDC-unit, so the human price
    is 10**(dec1-dec0) / price_raw.
    """
    ratio = sqrt_price_x96.astype("float64") / Q96
    price_raw = ratio * ratio
    return (10.0 ** (dec1 - dec0)) / price_raw


def build_frame(
    swaps: pd.DataFrame,
    block_times: pd.DataFrame,
    reference: pd.DataFrame,
    cfg: CalibrationConfig,
) -> pd.DataFrame:
    """
    Assemble the modelling frame.

    Every feature is computed from information strictly prior to the swap being scored.
    The `tick`, `sqrt_price_x96` and `liquidity` fields of a Swap event describe pool
    state *after* that swap executes, so they are shifted by one before use. Failing to
    shift would leak the swap's own price impact into its features and inflate AUC.
    """
    dec0, dec1 = cfg.pool.token0_decimals, cfg.pool.token1_decimals
    df = swaps.merge(block_times, on="block", how="left", validate="many_to_one")
    if df["timestamp"].isna().any():
        raise ValueError("missing block timestamps after merge")

    df = df.sort_values(["block", "log_index"]).reset_index(drop=True)

    df["pool_price_post"] = _sqrt_price_to_eth_usdc(df["sqrt_price_x96"], dec0, dec1)
    df["pool_price_pre"] = df["pool_price_post"].shift(1)
    df["tick_pre"] = df["tick"].shift(1)
    df["liquidity_pre"] = df["liquidity"].shift(1)
    df["sqrt_price_pre"] = df["sqrt_price_x96"].shift(1)

    amount0 = df["amount0"].astype("float64")
    amount1 = df["amount1"].astype("float64")
    df["notional_usd"] = amount0.abs() / 10.0**dec0
    df["qty_eth_signed"] = -amount1 / 10.0**dec1
    df["direction"] = np.sign(df["qty_eth_signed"])
    df["exec_price"] = (amount0.abs() * 10.0 ** (dec1 - dec0)) / amount1.abs()

    _attach_reference(df, reference)

    # 1. Top-of-block position. Observable on-chain as (state.lastBlock != block.number).
    df["is_first_of_block"] = (~df["block"].duplicated(keep="first")).astype("float64")

    # 2. Size as a fraction of active depth. In v3, L * sqrtP = virtual token1 reserve,
    #    so this is the fraction of the pool's ETH-side depth the order consumes.
    virtual_eth = (
        df["liquidity_pre"].astype("float64") * df["sqrt_price_pre"].astype("float64") / Q96
    ) / 10.0**dec1
    df["size_ratio"] = (df["qty_eth_signed"].abs() / virtual_eth).replace(
        [np.inf, -np.inf], np.nan
    )

    # 3. Trading with the recent move. Arbitrage is directional by construction.
    #    Drift is taken on price, not on raw ticks: for a token0=USDC pool a rising tick
    #    is a *falling* ETH price, so a tick-based drift silently inverts this feature.
    lookback = cfg.features.drift_lookback_swaps
    prior = df["pool_price_pre"]
    df["direction_vs_drift"] = df["direction"] * (prior / prior.shift(lookback) - 1.0)

    # 4. Signed mispricing against the reference venue: positive when the taker buys ETH
    #    while the pool is cheap relative to the reference, which is the arbitrage setup.
    df["signed_mispricing"] = df["direction"] * (
        (df["ref_price_at"] - df["pool_price_pre"]) / df["pool_price_pre"]
    )

    # 5. Agreement with accumulated order flow. PIN/VPIN holds that informed flow is
    #    persistent and one-directional, so the signal is whether this trade extends the
    #    prevailing imbalance, not the raw imbalance itself.
    alpha = 1.0 - 0.5 ** (1.0 / cfg.features.ofi_halflife_swaps)
    signed_notional = df["direction"] * df["notional_usd"]
    imbalance = (
        signed_notional.ewm(alpha=alpha, adjust=False).mean().shift(1)
        / df["notional_usd"].ewm(alpha=alpha, adjust=False).mean().shift(1)
    )
    df["ofi_ewma"] = df["direction"] * imbalance

    return df


def _attach_reference(df: pd.DataFrame, reference: pd.DataFrame) -> None:
    """
    Attach reference prices at the swap time and at each markout horizon.

    `ref_price_at` uses the last candle to have *closed at or before* the swap, so it is
    strictly past information and safe as a feature input. Horizon columns look forward
    and are label-only.
    """
    close_ms = reference["close_time_ms"].to_numpy()
    price = reference["ref_price"].to_numpy()
    swap_ms = df["timestamp"].to_numpy() * 1000

    at_idx = np.searchsorted(close_ms, swap_ms, side="right") - 1
    df["ref_price_at"] = np.where(at_idx >= 0, price[np.clip(at_idx, 0, None)], np.nan)


def attach_markouts(
    df: pd.DataFrame, reference: pd.DataFrame, cfg: CalibrationConfig
) -> pd.DataFrame:
    """
    Label each swap by forward markout against the reference venue.

    Two variants are produced. `markout_std` is the practitioner standard, measuring
    profit against the price actually executed. `markout_drift` measures only the
    subsequent market move, which cancels the USDC/USDT venue basis present in
    `exec_price`; it exists so the gate result can be checked for robustness to that
    basis rather than assumed immune to it.
    """
    close_ms = reference["close_time_ms"].to_numpy()
    price = reference["ref_price"].to_numpy()
    swap_ms = df["timestamp"].to_numpy() * 1000
    notional = df["notional_usd"].to_numpy()
    fee_usd = notional * cfg.pool.fee_fraction
    q = df["qty_eth_signed"].to_numpy()

    for horizon in cfg.labels.horizons_seconds:
        target_ms = swap_ms + horizon * 1000
        idx = np.searchsorted(close_ms, target_ms, side="left")
        valid = idx < len(price)
        fwd = np.where(valid, price[np.clip(idx, None, len(price) - 1)], np.nan)

        for variant, base in (
            ("std", df["exec_price"].to_numpy()),
            ("drift", df["ref_price_at"].to_numpy()),
        ):
            markout = q * (fwd - base)
            markout = np.where(valid, markout, np.nan)
            df[f"markout_{variant}_{horizon}s"] = markout
            # Continuous target in basis points of notional: threshold-free, and the
            # quantity g(pi) actually needs to rank correctly.
            df[f"markout_bps_{variant}_{horizon}s"] = markout / notional * 1e4
            for k in cfg.labels.threshold_multiples:
                label = np.where(valid, (markout > k * fee_usd).astype("float64"), np.nan)
                df[f"informed_{variant}_{horizon}s_k{k}"] = label

    return df


def clean(df: pd.DataFrame, cfg: CalibrationConfig, label_column: str) -> pd.DataFrame:
    """Drop rows that cannot be scored, and report exactly what was dropped and why."""
    before = len(df)
    required = [*FEATURE_COLUMNS, label_column, "notional_usd", "exec_price"]
    out = df.dropna(subset=required)
    dropped_na = before - len(out)

    out = out[out["notional_usd"] >= cfg.features.min_notional_usd]
    dropped_dust = before - dropped_na - len(out)

    log.info(
        "clean: %d -> %d rows (dropped %d incomplete, %d below $%.0f notional)",
        before, len(out), dropped_na, dropped_dust, cfg.features.min_notional_usd,
    )
    return out.reset_index(drop=True)
