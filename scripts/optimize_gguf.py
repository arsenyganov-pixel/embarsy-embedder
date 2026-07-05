#!/usr/bin/env python3
"""Create an Ollama Modelfile alias for the selected GGUF embedding model.

The heavy GGUF conversion is intentionally not duplicated here: the source model is
already pulled from Hugging Face via Ollama. This helper keeps the plan's explicit
`optimize_gguf.py` step as a reproducible place for future model-specific tuning.
"""

from __future__ import annotations

import argparse
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-model", required=True)
    parser.add_argument("--target-model", required=True)
    parser.add_argument("--output-dir", required=True)
    args = parser.parse_args()

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)
    path = output_dir / f"Modelfile.{args.target_model}"
    path.write_text(
        "\n".join(
            [
                f"FROM {args.source_model}",
                "PARAMETER num_ctx 8192",
                "PARAMETER temperature 0",
                "",
            ]
        ),
        encoding="utf-8",
    )
    print(path)


if __name__ == "__main__":
    main()

