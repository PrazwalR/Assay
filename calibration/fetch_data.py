from __future__ import annotations

import argparse
import logging
import sys

import pandas as pd

from assay_calib.config import CalibrationConfig, load_config
from assay_calib.fetch import (
    encode_big_ints,
    fetch_block_times,
    fetch_reference_prices,
    fetch_swaps,
    verify_pool_orientation,
)
from assay_calib.rpc import RpcClient

log = logging.getLogger("assay.fetch")

BLOCK_SECONDS = 12


def main() -> int:
    logging.basicConfig(
        level=logging.INFO, format="%(asctime)s %(levelname)-7s %(name)s: %(message)s"
    )
    parser = argparse.ArgumentParser(description="Fetch and cache raw data for the Assay gate")
    parser.add_argument("--days", type=float, default=None)
    parser.add_argument("--from-block", type=int, default=None)
    parser.add_argument("--to-block", type=int, default=None)
    args = parser.parse_args()
    if args.days is None and (args.from_block is None or args.to_block is None):
        parser.error("supply either --days or both --from-block and --to-block")

    base = load_config()
    cfg = CalibrationConfig(**{**base.__dict__, "days": args.days or base.days})
    client = RpcClient(cfg.rpc)
    verify_pool_orientation(client, cfg.pool)

    # An explicit range keeps a re-run on the same dataset. Deriving it from the live head
    # shifts the window every run, which silently refetches and breaks reproducibility.
    if args.from_block is not None and args.to_block is not None:
        from_block, to_block = args.from_block, args.to_block
    else:
        head = client.block_number()
        to_block = head - cfg.end_block_lag
        from_block = to_block - int(cfg.days * 86_400 / BLOCK_SECONDS)
    tag = f"{from_block}_{to_block}"
    cfg.data_dir.mkdir(parents=True, exist_ok=True)
    log.info("range [%d, %d] tag=%s", from_block, to_block, tag)

    swaps_path = cfg.data_dir / f"swaps_{tag}.parquet"
    if swaps_path.exists():
        swaps = pd.read_parquet(swaps_path)
        log.info("swaps cached: %d rows", len(swaps))
    else:
        swaps = fetch_swaps(client, cfg, from_block, to_block)
        encode_big_ints(swaps).to_parquet(swaps_path, index=False)
        log.info("swaps written: %d rows", len(swaps))

    blocks_path = cfg.data_dir / f"blocks_{tag}.parquet"
    if blocks_path.exists():
        block_times = pd.read_parquet(blocks_path)
        log.info("blocks cached: %d rows", len(block_times))
    else:
        block_times = fetch_block_times(client, swaps["block"].tolist())
        block_times.to_parquet(blocks_path, index=False)
        log.info("blocks written: %d rows", len(block_times))

    ref_path = cfg.data_dir / f"reference_{tag}.parquet"
    if not ref_path.exists():
        span = block_times["timestamp"]
        start_ms = int(span.min()) * 1000
        end_ms = (int(span.max()) + max(cfg.labels.horizons_seconds) + 120) * 1000
        reference = fetch_reference_prices(cfg, start_ms, end_ms)
        reference.to_parquet(ref_path, index=False)
        log.info("reference written: %d candles", len(reference))

    log.info("done. tag=%s rpc_requests=%d", tag, client.request_count)
    return 0


if __name__ == "__main__":
    sys.exit(main())
