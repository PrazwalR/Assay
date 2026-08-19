from __future__ import annotations

import itertools
import logging
import random
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any

import requests

from .config import RpcSpec

log = logging.getLogger(__name__)


class RpcError(RuntimeError):
    pass


class TruncationError(RpcError):
    """Raised when a log query is suspected of silently dropping results."""


class RpcClient:
    """
    JSON-RPC client that rotates across several public endpoints.

    No single free endpoint sustains the request rate this pipeline needs, and each
    rate-limits independently. Spreading load across endpoints and failing over to the
    next one on error keeps throughput up without a paid plan; the endpoints were checked
    to return identical results for the same block before being used interchangeably.
    """

    def __init__(self, spec: RpcSpec) -> None:
        self._spec = spec
        self._session = requests.Session()
        self._session.mount(
            "https://", requests.adapters.HTTPAdapter(pool_connections=32, pool_maxsize=32)
        )
        self._session.headers.update({"content-type": "application/json"})
        self._cursor = itertools.count()
        self.request_count = 0

    def _post(self, payload: Any, urls: tuple[str, ...] | None = None) -> Any:
        last_error: Exception | None = None
        start = next(self._cursor)
        urls = urls or self._spec.urls
        for attempt in range(self._spec.max_retries):
            url = urls[(start + attempt) % len(urls)]
            try:
                self.request_count += 1
                resp = self._session.post(
                    url,
                    json=payload,
                    timeout=self._spec.request_timeout_seconds,
                )
                if resp.status_code == 429:
                    raise RpcError("rate limited (HTTP 429)")
                resp.raise_for_status()
                body = resp.json()
                self._raise_on_rpc_error(body)
                time.sleep(self._spec.inter_request_sleep)
                return body
            except Exception as exc:  # noqa: BLE001 - retried and re-raised below
                last_error = exc
                sleep_for = self._spec.backoff_seconds * (2**attempt)
                log.debug(
                    "rpc %s attempt %d/%d failed (%s); retrying in %.1fs",
                    url, attempt + 1, self._spec.max_retries, exc, sleep_for,
                )
                time.sleep(sleep_for + random.random() * 0.5)
        raise RpcError(f"rpc failed after {self._spec.max_retries} attempts") from last_error

    @staticmethod
    def _raise_on_rpc_error(body: Any) -> None:
        entries = body if isinstance(body, list) else [body]
        for entry in entries:
            if isinstance(entry, dict) and entry.get("error"):
                raise RpcError(str(entry["error"]))

    def call(self, method: str, params: list[Any]) -> Any:
        body = self._post({"jsonrpc": "2.0", "id": 1, "method": method, "params": params})
        return body["result"]

    def concurrent_call(
        self, method: str, param_sets: list[list[Any]], progress_every: int = 2_000
    ) -> list[Any]:
        """
        Issue many single calls concurrently, preserving input order.

        JSON-RPC batching is not usable here: the public drpc endpoint rejects batches
        larger than 3 with a per-entry error while still returning HTTP-level shape, so a
        naive length check passes and the caller silently receives errors instead of data.
        Concurrency at `max_workers` achieves the same throughput without that trap.
        """
        results: list[Any] = [None] * len(param_sets)

        def fetch(index: int) -> None:
            body = self._post(
                {"jsonrpc": "2.0", "id": 1, "method": method, "params": param_sets[index]}
            )
            results[index] = body["result"]

        with ThreadPoolExecutor(max_workers=self._spec.max_workers) as pool:
            futures = {pool.submit(fetch, i): i for i in range(len(param_sets))}
            for done, future in enumerate(as_completed(futures), start=1):
                future.result()
                if done % progress_every == 0:
                    log.info("concurrent %s: %d/%d", method, done, len(param_sets))

        missing = [i for i, r in enumerate(results) if r is None]
        if missing:
            raise RpcError(f"{len(missing)} calls returned null, first at index {missing[0]}")
        return results

    def block_number(self) -> int:
        return int(self.call("eth_blockNumber", []), 16)

    def get_logs(self, address: str, topic0: str, from_block: int, to_block: int) -> list[dict]:
        body = self._post(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "eth_getLogs",
                "params": [
                    {
                        "address": address,
                        "topics": [topic0],
                        "fromBlock": hex(from_block),
                        "toBlock": hex(to_block),
                    }
                ],
            },
            urls=self._spec.log_urls,
        )
        return body["result"]

    def get_logs_verified(
        self, address: str, topic0: str, from_block: int, to_block: int, split: int = 4
    ) -> list[dict]:
        """
        Fetch logs and prove the result was not silently truncated.

        Providers commonly cap result sets without signalling it, which would hand the
        model an incomplete and biased sample. Re-fetching the same span in `split`
        sub-ranges must reproduce the same count; anything else is a truncated read.
        """
        whole = self.get_logs(address, topic0, from_block, to_block)
        span = to_block - from_block + 1
        if span < split * 2:
            return whole

        step = span // split
        parts: list[dict] = []
        for i in range(split):
            lo = from_block + i * step
            hi = to_block if i == split - 1 else lo + step - 1
            parts.extend(self.get_logs(address, topic0, lo, hi))

        if len(parts) != len(whole):
            raise TruncationError(
                f"log truncation detected on [{from_block},{to_block}]: "
                f"single query returned {len(whole)}, split query returned {len(parts)}"
            )
        return whole
