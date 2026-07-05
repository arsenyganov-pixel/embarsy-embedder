from __future__ import annotations

import argparse
import json
from typing import Any

import uvicorn

from embarsy_api.main import app
from embarsy_api.settings import Settings, get_settings


def build_server_config(settings: Settings, *, printable: bool = False) -> dict[str, Any]:
    return {
        "app": "embarsy_api.main:app" if printable else app,
        "host": settings.host,
        "port": settings.api_port,
        "factory": False,
        "log_level": "info",
    }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="embarsy-api",
        description="Local OpenAI-compatible embeddings API for Embarsy.app.",
    )
    parser.add_argument(
        "--print-config",
        action="store_true",
        help="Print effective server config and exit without starting the server.",
    )
    parser.add_argument(
        "--version",
        action="version",
        version="embarsy-api 0.1.0",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    settings = get_settings()

    if args.print_config:
        server_config = build_server_config(settings, printable=True)
        printable = {key: value for key, value in server_config.items() if key != "factory"}
        print(json.dumps(printable, sort_keys=True))
        return 0

    server_config = build_server_config(settings)
    printable_config = build_server_config(settings, printable=True)
    print(
        "Starting Embarsy API "
        f"on {printable_config['host']}:{printable_config['port']} "
        f"with {printable_config['app']}",
        flush=True,
    )
    uvicorn.run(**server_config)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
