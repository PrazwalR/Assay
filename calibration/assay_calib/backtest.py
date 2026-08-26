"""
Counterfactual backtest of the Assay fee mechanism against a static fee.

The point of a counterfactual is that the *counterparty reacts*. Replaying historical swaps
and simply charging each one a higher fee measures nothing: it assumes an arbitrageur pays
whatever is asked and trades the same size regardless, which is precisely the assumption
the mechanism is built to exploit. Every number here would be inflated by that mistake, and
inflated most on exactly the flow the project claims to price.

So arbitrage is re-optimised under each fee schedule. An arbitrageur closes a mispricing
only as far as it stays profitable, and stops where the remaining gap equals their cost of
trading. Raise the fee and they trade a smaller size, which is the real mechanism by which
a fee reduces extraction -- and also the real cost, because a pool left further from the
reference quotes worse prices to everyone who arrives next.

Uninformed flow is modelled as fee-elastic but not fee-optimising: it is trading for reasons
outside the pool, so it responds to price but does not solve for an optimal size. The single
elasticity governing that response is the one parameter here that is not measured, and it is
swept rather than chosen.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

import numpy as np
import pandas as pd

from .config import CalibrationConfig

log = logging.getLogger(__name__)

# One tick is one basis point of price; a fee pip is a hundredth of a basis point.
_PIPS_PER_TICK = 100.0
_PIPS_DENOMINATOR = 1_000_000.0
_BPS_DENOMINATOR = 10_000.0


@dataclass(frozen=True)
class FeePolicy:
    """
    A fee schedule to evaluate.

    `capture_share_bps` of zero reproduces a static fee: the quote never responds to drift,
    which is the baseline every result here is measured against.
    """

    name: str
    base_fee_pips: float
    min_fee_pips: float
    max_fee_pips: float
    capture_share_bps: float

    def quote_pips(self, signed_mispricing: np.ndarray) -> np.ndarray:
        """
        Fee each swap is quoted, mirroring `FeeBlend.quote` on chain.

        `signed_mispricing` is a signed fraction of price, positive when the swap trades
        toward the reference. It is converted to ticks the same way the contract does, so a
        divergence between this and the Solidity is a bug in one of them rather than a
        difference of definition.
        """
        drift_ticks = signed_mispricing * _BPS_DENOMINATOR
        surcharge = drift_ticks * _PIPS_PER_TICK * self.capture_share_bps / _BPS_DENOMINATOR
        return np.clip(self.base_fee_pips + surcharge, self.min_fee_pips, self.max_fee_pips)


@dataclass(frozen=True)
class BacktestResult:
    policy: str
    lp_fee_revenue_usd: float
    lp_adverse_selection_usd: float
    uninformed_volume_usd: float
    arbitrage_volume_usd: float
    mean_residual_drift_bps: float

    @property
    def lp_net_usd(self) -> float:
        """What the liquidity providers actually keep: fees earned less value picked off."""
        return self.lp_fee_revenue_usd - self.lp_adverse_selection_usd


def _profitable_fraction(drift_pips: np.ndarray, fee_pips: np.ndarray) -> np.ndarray:
    """
    The share of a mispricing that remains worth closing at a given fee.

    An arbitrageur closes a gap only down to the point where the remainder equals their cost
    of trading. Price impact is close to linear in size over the small ranges an arbitrage
    covers, so that share is `1 - fee/drift` and the traded size scales with it.
    """
    with np.errstate(divide="ignore", invalid="ignore"):
        fraction = np.where(drift_pips > 0, 1.0 - fee_pips / drift_pips, 0.0)
    return np.clip(fraction, 0.0, 1.0)


def _arbitrage_leg(
    signed_mispricing: np.ndarray,
    notional_usd: np.ndarray,
    fee_pips: np.ndarray,
    static_fee_pips: float,
) -> tuple[np.ndarray, np.ndarray]:
    """
    Re-optimise each arbitrage under a given fee, anchored to what was actually observed.

    The historical notional already reflects an arbitrageur optimising against the pool's
    static fee, so the counterfactual is a *ratio*: how much less is worth trading at the new
    fee than at the fee that produced this data. Applying `1 - fee/drift` directly would
    instead shrink even the static policy below the volume that was actually observed, and
    every comparison would be measured against a baseline that never happened.

    Returns traded notional and the drift left standing, both zero-clipped: an arbitrage
    whose fee exceeds its drift is simply not taken.
    """
    drift_pips = np.abs(signed_mispricing) * _PIPS_DENOMINATOR

    under_policy = _profitable_fraction(drift_pips, fee_pips)
    under_static = _profitable_fraction(drift_pips, np.full_like(drift_pips, static_fee_pips))

    with np.errstate(divide="ignore", invalid="ignore"):
        scale = np.where(under_static > 0, under_policy / under_static, 0.0)
    scale = np.clip(scale, 0.0, 1.0)

    traded = notional_usd * scale
    residual_drift_pips = drift_pips * (1.0 - under_policy)
    return traded, residual_drift_pips


def run_policy(
    df: pd.DataFrame,
    policy: FeePolicy,
    label_column: str,
    uninformed_elasticity: float,
    static_fee_pips: float,
) -> BacktestResult:
    """
    Evaluate one fee policy over a historical swap frame.

    `label_column` marks which swaps are treated as informed. The split is taken from the
    markout labelling rather than assumed, so the result inherits that labelling's known
    limitations rather than papering over them.
    """
    informed = df[label_column].to_numpy().astype(bool)
    mispricing = df["signed_mispricing"].to_numpy()
    notional = df["notional_usd"].to_numpy()

    fee_pips = policy.quote_pips(mispricing)
    fee_fraction = fee_pips / _PIPS_DENOMINATOR

    # Informed flow: re-optimised size, and it extracts the drift it still manages to close.
    arb_notional, residual_pips = _arbitrage_leg(
        mispricing[informed], notional[informed], fee_pips[informed], static_fee_pips
    )
    arb_fee_revenue = float(np.sum(arb_notional * fee_fraction[informed]))

    # Half the gap, not all of it. Execution walks from the pool price toward the reference,
    # so the average price paid sits near the midpoint and the value taken per unit traded is
    # about half the initial mispricing. Charging the full gap would overstate what
    # liquidity providers lose by roughly a factor of two, and overstate it most on exactly
    # the flow this mechanism claims to price.
    arb_extraction = float(np.sum(arb_notional * np.abs(mispricing[informed]) / 2.0))

    # Uninformed flow: trades for reasons outside the pool, so it responds to the fee it is
    # quoted but does not solve for a size. A fee above the base drives some of it away.
    #
    # Retention is capped at 1. A quote below the base fee plausibly attracts flow that would
    # have gone elsewhere, but there is no evidence here for how much, and modelling it would
    # credit this mechanism with revenue on volume that never existed -- inventing exactly the
    # upside the result is meant to measure. Discounted flow is therefore assumed to be
    # retained and no more, which understates the mechanism rather than flattering it.
    excess_fee_bps = (fee_pips[~informed] - policy.base_fee_pips) / _PIPS_PER_TICK
    retention = np.clip(np.exp(-uninformed_elasticity * excess_fee_bps), 0.0, 1.0)
    uninformed_notional = notional[~informed] * retention
    uninformed_fee_revenue = float(np.sum(uninformed_notional * fee_fraction[~informed]))

    return BacktestResult(
        policy=policy.name,
        lp_fee_revenue_usd=arb_fee_revenue + uninformed_fee_revenue,
        lp_adverse_selection_usd=arb_extraction,
        uninformed_volume_usd=float(np.sum(uninformed_notional)),
        arbitrage_volume_usd=float(np.sum(arb_notional)),
        mean_residual_drift_bps=float(np.mean(residual_pips) / _PIPS_PER_TICK)
        if residual_pips.size
        else 0.0,
    )


def compare(
    df: pd.DataFrame,
    cfg: CalibrationConfig,
    label_column: str,
    capture_shares_bps: tuple[float, ...],
    uninformed_elasticity: float,
) -> list[BacktestResult]:
    """
    Evaluate the static baseline and a sweep of capture shares on identical flow.

    The sweep exists because `capture_share_bps` is the mechanism's one free parameter and
    has never been estimated. Reporting a single value would present a choice as a finding.
    """
    base = float(cfg.pool.fee_pips)
    policies = [FeePolicy("static", base, base, base, 0.0)]
    policies += [
        FeePolicy(f"assay_{int(share)}bps", base, base / 5.0, base * 20.0, share)
        for share in capture_shares_bps
    ]
    return [run_policy(df, policy, label_column, uninformed_elasticity, base) for policy in policies]
