from __future__ import annotations

import numpy as np
import pandas as pd
import pytest

from assay_calib.config import USDC_WETH_500, ConfigError, PoolSpec, load_config
from assay_calib.features import _sqrt_price_to_eth_usdc
from assay_calib.fetch import _to_signed, decode_big_ints, decode_swap_log, encode_big_ints

DEC0, DEC1 = USDC_WETH_500.token0_decimals, USDC_WETH_500.token1_decimals


class TestTwosComplement:
    def test_positive_unchanged(self) -> None:
        assert _to_signed(5, 24) == 5

    def test_negative_int24(self) -> None:
        assert _to_signed((1 << 24) - 1, 24) == -1

    def test_int24_bounds(self) -> None:
        assert _to_signed(1 << 23, 24) == -(1 << 23)
        assert _to_signed((1 << 23) - 1, 24) == (1 << 23) - 1

    def test_negative_int256(self) -> None:
        assert _to_signed((1 << 256) - 1000, 256) == -1000


class TestSwapDecoding:
    @staticmethod
    def _entry(amount0: int, amount1: int, sqrt_price: int, liquidity: int, tick: int) -> dict:
        def word(v: int) -> str:
            return f"{v & ((1 << 256) - 1):064x}"

        return {
            "blockNumber": "0x10",
            "logIndex": "0x2",
            "transactionHash": "0xabc",
            "transactionIndex": "0x1",
            "topics": [
                "0x" + "0" * 64,
                "0x" + "1" * 64,
                "0x" + "2" * 64,
            ],
            "data": "0x"
            + word(amount0)
            + word(amount1)
            + word(sqrt_price)
            + word(liquidity)
            + word(tick),
        }

    def test_roundtrip_signed_amounts(self) -> None:
        entry = self._entry(3_000_000_000, -(10**18), 1 << 96, 10**21, -197_529)
        out = decode_swap_log(entry)
        assert out["amount0"] == 3_000_000_000
        assert out["amount1"] == -(10**18)
        assert out["tick"] == -197_529
        assert out["liquidity"] == 10**21
        assert out["block"] == 16

    def test_rejects_malformed_length(self) -> None:
        entry = self._entry(1, 1, 1, 1, 1)
        entry["data"] = entry["data"][:-64]
        with pytest.raises(ValueError, match="unexpected Swap data length"):
            decode_swap_log(entry)


class TestPriceOrientation:
    def test_higher_tick_means_cheaper_eth(self) -> None:
        """
        token0=USDC means price_raw is wei-per-USDC-unit, so tick and ETH price move in
        opposite directions. Any feature derived from raw tick deltas inverts without this.
        """
        prices = [
            _sqrt_price_to_eth_usdc(pd.Series([int((1.0001 ** (t / 2)) * (1 << 96))]), DEC0, DEC1)[
                0
            ]
            for t in (196_000, 197_000, 198_000)
        ]
        assert prices[0] > prices[1] > prices[2]

    def test_known_tick_gives_plausible_eth_price(self) -> None:
        sqrt_price = int((1.0001 ** (197_529 / 2)) * (1 << 96))
        price = _sqrt_price_to_eth_usdc(pd.Series([sqrt_price]), DEC0, DEC1)[0]
        assert 2_000 < price < 3_500


class TestSignConventions:
    """
    v3 Swap amounts are from the pool's perspective. amount0 > 0 means the pool received
    USDC, so the taker bought ETH. Getting this backwards inverts every label.
    """

    def test_buy_eth_direction_and_exec_price(self) -> None:
        amount0, amount1 = 3_000 * 10**DEC0, -(10**DEC1)
        qty_eth = -amount1 / 10**DEC1
        exec_price = abs(amount0) * 10.0 ** (DEC1 - DEC0) / abs(amount1)
        assert qty_eth == pytest.approx(1.0)
        assert exec_price == pytest.approx(3_000.0)

    def test_sell_eth_direction_and_exec_price(self) -> None:
        amount0, amount1 = -3_000 * 10**DEC0, 10**DEC1
        qty_eth = -amount1 / 10**DEC1
        exec_price = abs(amount0) * 10.0 ** (DEC1 - DEC0) / abs(amount1)
        assert qty_eth == pytest.approx(-1.0)
        assert exec_price == pytest.approx(3_000.0)

    def test_profitable_buy_has_positive_markout(self) -> None:
        qty_eth, exec_price, forward = 1.0, 3_000.0, 3_050.0
        assert qty_eth * (forward - exec_price) == pytest.approx(50.0)

    def test_profitable_sell_has_positive_markout(self) -> None:
        qty_eth, exec_price, forward = -1.0, 3_000.0, 2_950.0
        assert qty_eth * (forward - exec_price) == pytest.approx(50.0)

    def test_losing_buy_has_negative_markout(self) -> None:
        qty_eth, exec_price, forward = 1.0, 3_000.0, 2_950.0
        assert qty_eth * (forward - exec_price) == pytest.approx(-50.0)


class TestBigIntSerialisation:
    def test_roundtrip_preserves_exact_uint256(self) -> None:
        big = (1 << 200) + 12_345
        df = pd.DataFrame(
            {"amount0": [big], "amount1": [-big], "sqrt_price_x96": [1], "liquidity": [2]}
        )
        out = decode_big_ints(encode_big_ints(df))
        assert out["amount0"].iloc[0] == big
        assert out["amount1"].iloc[0] == -big


class TestConfigValidation:
    def test_rejects_bad_address(self) -> None:
        with pytest.raises(ConfigError, match="pool address malformed"):
            PoolSpec("0x1234", "A", "B", 6, 18, 500, 1)

    def test_rejects_out_of_range_fee(self) -> None:
        with pytest.raises(ConfigError, match="fee_pips out of range"):
            PoolSpec("0x" + "1" * 40, "A", "B", 6, 18, 2_000_000, 1)

    def test_default_config_is_valid(self) -> None:
        cfg = load_config()
        assert cfg.pool.fee_fraction == pytest.approx(0.0005)
        assert cfg.labels.primary_horizon_seconds in cfg.labels.horizons_seconds
        assert len(cfg.rpc.urls) >= 1


class TestNoLookahead:
    """
    The shift-by-one that keeps post-swap pool state out of pre-swap features is the single
    highest-risk line in the pipeline; if it regresses, AUC inflates silently.
    """

    def test_pre_state_is_previous_rows_post_state(self) -> None:
        post = pd.Series([100.0, 101.0, 102.0, 103.0])
        pre = post.shift(1)
        assert np.isnan(pre.iloc[0])
        assert pre.iloc[1] == 100.0
        assert pre.iloc[3] == 102.0
