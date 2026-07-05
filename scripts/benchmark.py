#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import time

import httpx


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--url", default="http://127.0.0.1:8000/v1/embeddings")
    parser.add_argument("--batch-size", type=int, default=16)
    parser.add_argument("--rounds", type=int, default=5)
    args = parser.parse_args()

    headers = {}
    api_key = os.getenv("EMBARSY_API_KEY", "")
    if api_key:
        headers["Authorization"] = f"Bearer {api_key}"

    payload = {
        "model": os.getenv("OLLAMA_MODEL", "qwen3-embedding"),
        "input": [
            f"Find code path for authentication and error handling #{i}"
            for i in range(args.batch_size)
        ],
    }

    total_embeddings = 0
    started = time.perf_counter()
    with httpx.Client(timeout=300) as client:
        for _ in range(args.rounds):
            response = client.post(args.url, json=payload, headers=headers)
            response.raise_for_status()
            total_embeddings += len(response.json()["data"])
    elapsed = time.perf_counter() - started
    print(
        f"embeddings={total_embeddings} "
        f"seconds={elapsed:.2f} "
        f"emb_per_sec={total_embeddings / elapsed:.2f}"
    )


if __name__ == "__main__":
    main()
