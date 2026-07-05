# Third-Party Notices

Embarsy itself is licensed under the PolyForm Strict License 1.0.0 (see
[LICENSE](LICENSE)). That license applies only to Embarsy's own source code.

Embarsy bundles and/or depends on the third-party components listed below.
Each remains under its own license, and those licenses are unaffected by
Embarsy's license. This file is a convenience summary — the authoritative
license texts ship with, or are published by, each respective project.

## Bundled runtime binaries (shipped inside Embarsy.app)

| Component | Purpose | License |
| --- | --- | --- |
| [Qdrant](https://github.com/qdrant/qdrant) | Local vector database | Apache License 2.0 |
| [Ollama](https://github.com/ollama/ollama) | Local embedding model runtime | MIT License |
| Qwen3 Embedding (`qwen3-embedding`) | Embedding model run by Ollama | Apache License 2.0 (as published by the Qwen team — verify at the model's distribution page) |

## Python backend (`embarsy-api`, frozen with PyInstaller)

| Component | License |
| --- | --- |
| [FastAPI](https://github.com/fastapi/fastapi) | MIT License |
| [Starlette](https://github.com/encode/starlette) | BSD 3-Clause |
| [Uvicorn](https://github.com/encode/uvicorn) | BSD 3-Clause |
| [Pydantic](https://github.com/pydantic/pydantic) / pydantic-settings | MIT License |
| [httpx](https://github.com/encode/httpx) | BSD 3-Clause |

The `embarsy-api` executable is produced with
[PyInstaller](https://github.com/pyinstaller/pyinstaller). PyInstaller's
bootloader is distributed under the GPL 2.0 **with a special exception** that
permits bundling it into applications released under any license, so it does
not impose GPL terms on Embarsy.

The complete Python dependency set is declared in
[`pyproject.toml`](pyproject.toml) and [`requirements.txt`](requirements.txt).

> Attribution here does not imply that any of these projects endorse Embarsy.
