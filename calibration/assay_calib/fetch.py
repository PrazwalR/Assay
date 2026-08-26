from __future__ import annotations

import logging
import time

import pandas as pd
import requests

from .config import CalibrationConfig, PoolSpec
from .rpc import RpcClient, RpcError

log = logging.getLogger(__name__)

# keccak256("Swap(address,address,int256,int256,uint160,uint128,int24)")
SWAP_TOPIC0 = "0xc42079f94a6350d7e6235f29174924f928cc2ac818eb64fed8004e115fbcca67"

_SELECTOR_TOKEN0 = "0x0dfe1681"
_SELECTOR_TOKEN1 = "0xd21220a7"
_SELECTOR_DECIMALS = "0x313ce567"
_SELECTOR_FEE = "0xddca3f43"

# Columns exceeding int64. Parquet has no native 256-bit integer, so these round-trip as
# decimal strings to keep the stored data exact; conversion to float64 happens only in
# feature computation, where every use is a ratio and the 1e-16 relative loss is immaterial.
BIG_INT_COLUMNS = ("amount0", "amount1", "sqrt_price_x96", "liquidity")


def encode_big_ints(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    for col in BIG_INT_COLUMNS:
        if col in out.columns:
            out[col] = out[col].map(str)
    return out


def decode_big_ints(df: pd.DataFrame) -> pd.DataFrame:
    out = df.copy()
    for col in BIG_INT_COLUMNS:
        if col not in out.columns:
            continue
        if not pd.api.types.is_integer_dtype(out[col]):
            out[col] = out[col].map(lambda v: int(v) if v is not None else None)
    return out


def _to_signed(word: int, bits: int) -> int:
    bound = 1 << (bits - 1)
    return word - (1 << bits) if word >= bound else word


def _word(data_hex: str, index: int) -> int:
    start = index * 64
    return int(data_hex[start : start + 64], 16)


_INT24_MIN, _INT24_MAX = -(1 << 23), (1 << 23) - 1


def _decode_tick(word: int) -> int:
    """
    Decode the int24 tick.

    ABI encoding sign-extends int24 across the full 256-bit word, so the value must be
    interpreted as int256 and only then range-checked. Interpreting the low 24 bits
    directly yields a large positive number for every negative tick.
    """
    tick = _to_signed(word, 256)
    if not _INT24_MIN <= tick <= _INT24_MAX:
        raise ValueError(f"decoded tick {tick} outside int24 range")
    return tick


def decode_swap_log(entry: dict) -> dict:
    """Decode a Uniswap v3 Swap event into native Python integers."""
    data = entry["data"][2:]
    if len(data) != 5 * 64:
        raise ValueError(f"unexpected Swap data length {len(data)} in tx {entry['transactionHash']}")
    return {
        "block": int(entry["blockNumber"], 16),
        "log_index": int(entry["logIndex"], 16),
        "tx_hash": entry["transactionHash"],
        "tx_index": int(entry["transactionIndex"], 16),
        "sender": "0x" + entry["topics"][1][-40:],
        "recipient": "0x" + entry["topics"][2][-40:],
        "amount0": _to_signed(_word(data, 0), 256),
        "amount1": _to_signed(_word(data, 1), 256),
        "sqrt_price_x96": _word(data, 2),
        "liquidity": _word(data, 3),
        "tick": _decode_tick(_word(data, 4)),
    }


def verify_pool_orientation(client: RpcClient, pool: PoolSpec) -> None:
    """
    Assert the configured token orientation matches the chain.

    Every price in this pipeline is derived from token0/token1 ordering and decimals.
    Getting it backwards silently inverts every price and every label, so it is checked
    against the deployed contract rather than assumed.
    """
    token0 = "0x" + client.call("eth_call", [{"to": pool.address, "data": _SELECTOR_TOKEN0}, "latest"])[-40:]
    token1 = "0x" + client.call("eth_call", [{"to": pool.address, "data": _SELECTOR_TOKEN1}, "latest"])[-40:]
    dec0 = int(client.call("eth_call", [{"to": token0, "data": _SELECTOR_DECIMALS}, "latest"]), 16)
    dec1 = int(client.call("eth_call", [{"to": token1, "data": _SELECTOR_DECIMALS}, "latest"]), 16)
    fee = int(client.call("eth_call", [{"to": pool.address, "data": _SELECTOR_FEE}, "latest"]), 16)

    if dec0 != pool.token0_decimals or dec1 != pool.token1_decimals:
        raise RpcError(
            f"decimals mismatch: chain says token0={dec0} token1={dec1}, "
            f"config says {pool.token0_decimals}/{pool.token1_decimals}"
        )
    if fee != pool.fee_pips:
        raise RpcError(f"fee mismatch: chain says {fee}, config says {pool.fee_pips}")
    log.info(
        "pool verified: token0=%s (%d dec), token1=%s (%d dec), fee=%d pips",
        token0, dec0, token1, dec1, fee,
    )


def fetch_swaps(client: RpcClient, cfg: CalibrationConfig, from_block: int, to_block: int) -> pd.DataFrame:
    """Pull every Swap event in [from_block, to_block], verifying against truncation."""
    rows: list[dict] = []
    chunk = cfg.rpc.log_chunk_blocks
    total_chunks = (to_block - from_block) // chunk + 1
    verify_every = max(1, total_chunks // 10)

    for i, lo in enumerate(range(from_block, to_block + 1, chunk)):
        hi = min(lo + chunk - 1, to_block)
        if i % verify_every == 0:
            entries = client.get_logs_verified(cfg.pool.address, SWAP_TOPIC0, lo, hi)
        else:
            entries = client.get_logs(cfg.pool.address, SWAP_TOPIC0, lo, hi)
        rows.extend(decode_swap_log(e) for e in entries)
        if i % 10 == 0:
            log.info("swaps: chunk %d/%d, %d rows so far", i + 1, total_chunks, len(rows))

    df = pd.DataFrame(rows)
    if df.empty:
        raise RpcError(f"no swaps found in [{from_block},{to_block}]")
    df = df.sort_values(["block", "log_index"]).reset_index(drop=True)
    return df


def fetch_block_times(client: RpcClient, blocks: list[int]) -> pd.DataFrame:
    """Fetch timestamp and base fee for each block, batched."""
    unique = sorted(set(blocks))
    log.info("fetching timestamps for %d distinct blocks", len(unique))
    results = client.concurrent_call(
        "eth_getBlockByNumber", [[hex(b), False] for b in unique]
    )
    rows = []
    for block, res in zip(unique, results, strict=True):
        if res is None:
            raise RpcError(f"block {block} returned null")
        rows.append(
            {
                "block": block,
                "timestamp": int(res["timestamp"], 16),
                "base_fee_wei": int(res.get("baseFeePerGas", "0x0"), 16),
            }
        )
    return pd.DataFrame(rows)


def fetch_reference_prices(cfg: CalibrationConfig, start_ms: int, end_ms: int) -> pd.DataFrame:
    """
    Pull reference candles at the configured resolution.

    Only `close_time` and `close` are retained. A candle's close is the price at that
    candle's end, so aligning a swap to the candle that closed at or before it keeps the
    reference strictly in the past; that alignment is enforced in features.py.
    """
    spec = cfg.reference
    rows: list[dict] = []
    cursor = start_ms
    session = requests.Session()
    pages = 0

    while cursor < end_ms:
        resp = session.get(
            spec.base_url,
            params={
                "symbol": spec.symbol,
                "interval": spec.candle_interval,
                "startTime": cursor,
                "endTime": end_ms,
                "limit": spec.page_limit,
            },
            timeout=cfg.rpc.request_timeout_seconds,
        )
        resp.raise_for_status()
        batch = resp.json()
        if not batch:
            break
        for candle in batch:
            rows.append({"close_time_ms": int(candle[6]), "ref_price": float(candle[4])})
        cursor = int(batch[-1][6]) + 1
        pages += 1
        if pages % 50 == 0:
            log.info("reference: %d pages, %d candles so far", pages, len(rows))
        time.sleep(spec.request_sleep_seconds)

    if not rows:
        raise RuntimeError("reference price fetch returned no candles")

    df = pd.DataFrame(rows).drop_duplicates("close_time_ms").sort_values("close_time_ms")
    log.info(
        "reference: %d candles at %s, %s to %s",
        len(df),
        spec.candle_interval,
        pd.to_datetime(df["close_time_ms"].iloc[0], unit="ms"),
        pd.to_datetime(df["close_time_ms"].iloc[-1], unit="ms"),
    )
    return df.reset_index(drop=True)
