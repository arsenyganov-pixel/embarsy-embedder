from __future__ import annotations

import asyncio
import logging
import json
import random
import shlex
import re
import time
from collections import Counter
from pathlib import Path
from typing import Any, Literal, Optional, Union

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field

from embarsy_api import __version__
from embarsy_api import benchmark as bench
from embarsy_api.embeddings import (
    EmbeddingError,
    EmbeddingService,
    as_input_list,
    encode_float32_base64,
    to_well_formed,
)
from embarsy_api.metrics import (
    DEFAULT_MAX_CHART_POINTS,
    classify_qdrant_proxy_operation,
    metrics,
    parse_qdrant_activity_totals,
)
from embarsy_api.settings import Settings, get_settings

logger = logging.getLogger("embarsy_api")


class EmbeddingsRequest(BaseModel):
    input: Union[str, list[str]]
    model: Optional[str] = None
    encoding_format: Literal["float", "base64"] = "float"
    dimensions: Optional[int] = None


class BenchmarkRequest(BaseModel):
    collection: str
    workspace_path: str
    samples: int = 12
    top_k: int = 5
    # Paraphrase discipline: swap ONE word of each question for a fixed-table synonym
    # before the duel — the test literal search cannot ace by construction.
    paraphrase: bool = False


class EmbeddingObject(BaseModel):
    object: Literal["embedding"] = "embedding"
    embedding: Union[list[float], str]
    index: int


class UsageObject(BaseModel):
    prompt_tokens: int = 0
    total_tokens: int = 0


class EmbeddingsResponse(BaseModel):
    object: Literal["list"] = "list"
    data: list[EmbeddingObject]
    model: str
    usage: UsageObject = Field(default_factory=UsageObject)


app = FastAPI(
    title="Embarsy Qwen3 Embeddings API",
    description="Local OpenAI-compatible embeddings wrapper for Roo Code.",
    version=__version__,
)


# One shared HTTP client for everything that talks to Qdrant (proxy, Prometheus scrape,
# content inspection). Keep-alive connection pooling replaces the old client-per-request
# pattern, which paid a TCP setup + teardown for every single proxied call.
_http_client: httpx.AsyncClient | None = None


def shared_http_client() -> httpx.AsyncClient:
    global _http_client
    if _http_client is None or getattr(_http_client, "is_closed", False):
        _http_client = httpx.AsyncClient(timeout=10.0)
    return _http_client


@app.on_event("shutdown")
async def _close_shared_client() -> None:
    global _http_client
    if _http_client is not None and not _http_client.is_closed:
        await _http_client.aclose()
    _http_client = None
    metrics.flush()


@app.on_event("startup")
async def _migrate_quantization_on_startup() -> None:
    """Bring pre-existing unquantized collections onto the int8 layout at API start.

    Content-tab polling also migrates lazily, but users who never open Content would
    otherwise keep raw-float32 collections forever. Runs in the background with
    retries so a Qdrant that is still starting doesn't block or fail API startup.
    """
    async def migrate() -> None:
        settings = get_settings()
        headers = {"api-key": settings.qdrant_api_key} if settings.qdrant_api_key else None
        client = shared_http_client()
        for _ in range(30):  # keep trying for ~5 minutes, then give up quietly
            try:
                response = await client.get(
                    f"{settings.qdrant_base_url.rstrip('/')}/collections",
                    headers=headers,
                    timeout=5.0,
                )
                response.raise_for_status()
                names = [
                    c.get("name")
                    for c in response.json().get("result", {}).get("collections", [])
                    if isinstance(c.get("name"), str)
                ]
                for name in names:
                    info = await qdrant_collection_info(client, settings, headers, name)
                    await ensure_collection_quantization(client, settings, headers, name, info)
                return
            except httpx.HTTPError:
                await asyncio.sleep(10)

    asyncio.get_running_loop().create_task(migrate())


def require_api_key(
    settings: Settings = Depends(get_settings), authorization: Optional[str] = Header(default=None)
) -> None:
    if not settings.api_key:
        return
    expected = f"Bearer {settings.api_key}"
    if authorization != expected:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Embarsy API key",
            headers={"WWW-Authenticate": "Bearer"},
        )


def require_qdrant_api_key(
    settings: Settings = Depends(get_settings),
    qdrant_api_key: Optional[str] = Header(default=None, alias="api-key"),
) -> None:
    if not settings.qdrant_api_key:
        return
    if qdrant_api_key != settings.qdrant_api_key:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid Qdrant API key",
        )


def get_embedding_service(settings: Settings = Depends(get_settings)) -> EmbeddingService:
    return EmbeddingService(
        ollama_base_url=settings.ollama_base_url,
        model=settings.ollama_model,
        keep_alive=settings.ollama_keep_alive,
        dimension=settings.embedding_dimension,
        instruction=settings.embedding_instruction,
        timeout_seconds=settings.request_timeout_seconds,
    )


@app.get("/health")
async def health(settings: Settings = Depends(get_settings)) -> dict[str, Any]:
    return {
        "status": "ok",
        # The app compares this against its bundled API version: after an app update the
        # previous (orphaned) API process can still be serving :8000, and a mismatch here
        # is what surfaces the "Update" button on the Status screen.
        "version": __version__,
        "model": settings.ollama_model,
        "dimension": settings.embedding_dimension,
        "ollama_base_url": settings.ollama_base_url,
    }


@app.get("/metrics/embeddings", dependencies=[Depends(require_api_key)])
async def embeddings_metrics(
    scale_seconds: int = 3600,
    settings: Settings = Depends(get_settings),
) -> dict[str, object]:
    bounded_scale = max(60, min(scale_seconds, 7 * 24 * 60 * 60))
    await refresh_qdrant_activity(settings)
    return metrics.snapshot(scale_seconds=bounded_scale, max_points=DEFAULT_MAX_CHART_POINTS)


@app.get("/activity/requests", dependencies=[Depends(require_api_key)])
async def request_activity(
    limit: int = 1_000,
    since_seconds: int = 24 * 60 * 60,
    since_id: Optional[int] = None,  # noqa: UP045 — FastAPI evaluates this at runtime on Python 3.9
) -> dict[str, object]:
    bounded_limit = max(1, min(limit, 5_000))
    bounded_since_seconds = max(60, min(since_seconds, 24 * 60 * 60))
    return metrics.activity_snapshot(
        limit=bounded_limit,
        since_seconds=bounded_since_seconds,
        since_id=since_id,
    )


# Content inspection is expensive (1 + 2N Qdrant calls + Roo cache parsing), while its
# inputs change rarely — cache the response briefly. The app's delete flow busts the
# cache with max_age=0 so a just-deleted collection disappears immediately.
_content_cache: tuple[float, dict[str, object]] | None = None
_CONTENT_CACHE_TTL = 15.0


@app.get("/content/collections", dependencies=[Depends(require_api_key)])
async def content_collections(
    settings: Settings = Depends(get_settings),
    max_age: float = _CONTENT_CACHE_TTL,
) -> dict[str, object]:
    global _content_cache
    bounded_max_age = max(0.0, min(max_age, 60.0))
    now_monotonic = time.monotonic()
    if _content_cache is not None and now_monotonic - _content_cache[0] < bounded_max_age:
        return _content_cache[1]
    try:
        collections = await inspect_qdrant_collections(settings)
    except httpx.HTTPError as exc:
        logger.warning("Qdrant content inspection failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Qdrant content inspection failed. Start Qdrant and refresh Content.",
        ) from exc
    payload: dict[str, object] = {
        "now": int(time.time()),
        "collections": collections,
    }
    _content_cache = (now_monotonic, payload)
    return payload


# The Prometheus scrape imports Roo's direct-to-Qdrant counters; chart buckets are 5s
# wide, so scraping faster than the bucket width adds no chart fidelity — it only added
# a Qdrant round-trip to EVERY Monitoring poll (2s default cadence). Matching the bucket
# width keeps per-bucket attribution identical to the old every-poll behavior.
_last_scrape_monotonic = 0.0
_SCRAPE_MIN_INTERVAL = 5.0


async def refresh_qdrant_activity(settings: Settings) -> None:
    global _last_scrape_monotonic
    now_monotonic = time.monotonic()
    if now_monotonic - _last_scrape_monotonic < _SCRAPE_MIN_INTERVAL:
        return
    # Claim the slot before awaiting so concurrent polls don't scrape in parallel.
    _last_scrape_monotonic = now_monotonic

    url = f"{settings.qdrant_base_url.rstrip('/')}/metrics"
    headers = {"api-key": settings.qdrant_api_key} if settings.qdrant_api_key else None
    try:
        response = await shared_http_client().get(url, headers=headers, timeout=2.0)
        response.raise_for_status()
    except httpx.HTTPError as exc:
        logger.debug("Qdrant metrics refresh failed: %s", exc)
        return

    metrics.observe_qdrant_totals(parse_qdrant_activity_totals(response.text))


async def inspect_qdrant_collections(settings: Settings) -> list[dict[str, object]]:
    headers = {"api-key": settings.qdrant_api_key} if settings.qdrant_api_key else None
    workspace_cache_paths = load_roo_cache_workspace_hints()
    client = shared_http_client()
    response = await client.get(f"{settings.qdrant_base_url.rstrip('/')}/collections", headers=headers)
    response.raise_for_status()
    collection_names = [
        collection.get("name")
        for collection in response.json().get("result", {}).get("collections", [])
        if isinstance(collection.get("name"), str)
    ]

    rows = []
    for collection_name in collection_names:
        info = await qdrant_collection_info(client, settings, headers, collection_name)
        await ensure_collection_quantization(client, settings, headers, collection_name, info)
        samples = await qdrant_collection_samples(client, settings, headers, collection_name)
        rows.append(build_content_collection_row(
            collection_name,
            info,
            samples,
            cache_paths=workspace_cache_paths.get(collection_name, []),
        ))

    return sorted(rows, key=lambda row: str(row["display_name"]).lower())


# Collections already migrated (or confirmed migrated) this process run — avoids
# re-sending PATCHes on every Content poll.
_quantization_ensured: set[str] = set()


async def ensure_collection_quantization(
    client: httpx.AsyncClient,
    settings: Settings,
    headers: dict[str, str] | None,
    collection_name: str,
    info: dict[str, Any],
) -> None:
    """Migrate a pre-existing unquantized collection to the Embarsy storage default.

    Collections created before quantization injection (or written directly to :6333,
    bypassing the proxy) hold raw float32 vectors. Qdrant supports enabling
    quantization on a live collection — it re-optimizes segments in the background
    while search keeps working — so this brings old indexes onto the int8 layout
    without re-indexing. Failures only log: content inspection must never break.
    """
    if collection_name in _quantization_ensured:
        return
    config = info.get("config") if isinstance(info.get("config"), dict) else {}
    if config.get("quantization_config") is not None:
        _quantization_ensured.add(collection_name)
        return

    patch: dict[str, Any] = {"quantization_config": SCALAR_INT8_QUANTIZATION}
    vectors = config.get("params", {}).get("vectors", {})
    if isinstance(vectors, dict) and "size" in vectors and not vectors.get("on_disk"):
        # Single unnamed vector kept fully in RAM — move originals to disk; the int8
        # copy (always_ram) is what searches read.
        patch["vectors"] = {"": {"on_disk": True}}

    try:
        response = await client.patch(
            f"{settings.qdrant_base_url.rstrip('/')}/collections/{collection_name}",
            headers=headers,
            json=patch,
            timeout=10.0,
        )
        response.raise_for_status()
        _quantization_ensured.add(collection_name)
        logger.info("Enabled int8 scalar quantization for collection %s", collection_name)
    except httpx.HTTPError as exc:
        logger.warning("Quantization migration failed for %s: %s", collection_name, exc)


async def qdrant_collection_info(
    client: httpx.AsyncClient,
    settings: Settings,
    headers: dict[str, str] | None,
    collection_name: str,
) -> dict[str, Any]:
    response = await client.get(
        f"{settings.qdrant_base_url.rstrip('/')}/collections/{collection_name}",
        headers=headers,
    )
    response.raise_for_status()
    return response.json().get("result", {})


async def qdrant_collection_samples(
    client: httpx.AsyncClient,
    settings: Settings,
    headers: dict[str, str] | None,
    collection_name: str,
) -> list[dict[str, Any]]:
    response = await client.post(
        f"{settings.qdrant_base_url.rstrip('/')}/collections/{collection_name}/points/scroll",
        headers=headers,
        json={"limit": 25, "with_payload": True, "with_vector": False},
    )
    response.raise_for_status()
    points = response.json().get("result", {}).get("points", [])
    return [point for point in points if isinstance(point, dict)]


def build_content_collection_row(
    collection_name: str,
    info: dict[str, Any],
    samples: list[dict[str, Any]],
    *,
    cache_paths: list[str] | None = None,
) -> dict[str, object]:
    payloads = [point.get("payload", {}) for point in samples if isinstance(point.get("payload"), dict)]
    cache_paths = cache_paths or []
    sample_paths = [_payload_path(payload) for payload in payloads]
    all_paths = [path for path in sample_paths + cache_paths[:200] if path]
    # A resolved workspace name reads well in prose; the collection-id fallback does NOT —
    # the Collection column already shows the id, so the summary drops it entirely.
    resolved_name = workspace_display_name(collection_name, all_paths, payloads)
    display_name = resolved_name or f"{collection_name} collection"
    points_count = int(info.get("points_count") or info.get("vectors_count") or len(samples))
    indexed_summary = indexed_content_summary(resolved_name, all_paths, payloads, points_count)

    return {
        "collection_name": collection_name,
        "display_name": display_name,
        "points_count": points_count,
        "indexed_summary": indexed_summary,
        "preview": content_preview(all_paths, payloads, indexed_summary),
        "preview_tags": build_preview_tags(collection_name, display_name, all_paths, payloads, points_count),
    }


def build_preview_tags(
    collection_name: str,
    display_name: str,
    paths: list[str],
    payloads: list[dict[str, Any]],
    points_count: int,
) -> list[dict[str, str]]:
    """Structured, deduped, ordered chips for the Content "Preview" column.

    Built from the same clean lists indexed_content_summary / content_preview use,
    before they are flattened into prose — so the UI renders discrete tags instead of
    one overflowing sentence. Fixed order: count -> languages -> areas -> terms -> sample.
    The raw sample text is carried only as the sample chip's copy payload, never as a label.
    """
    unique_paths = list(dict.fromkeys(path for path in paths if path))
    tags: list[dict[str, str]] = []

    # Seed the dedup set with the workspace / collection name tokens so the repeated
    # display_name never becomes a chip (it already owns the Collection column).
    seen: set[str] = set()
    for base in (display_name, collection_name):
        for token in base.lower().replace("/", " ").split():
            if token:
                seen.add(token)

    def emit(kind: str, label: str, copy: str | None = None) -> None:
        tag = {"kind": kind, "label": label}
        if copy is not None:
            tag["copy"] = copy
        tags.append(tag)

    if unique_paths:
        count = len(unique_paths)
        emit("count", f"{count} file" if count == 1 else f"{count} files")

        for language in sorted({_language_for_path(path) for path in unique_paths})[:4]:
            key = language.lower()
            if not language or language == "files" or key in seen:  # "files" is the extensionless sentinel
                continue
            seen.add(key)
            emit("lang", language)

        for area in _domain_terms(unique_paths)[:5]:
            key = area.lower()
            if not area or key in seen:
                continue
            seen.add(key)
            emit("area", area)

        term_count = 0
        for term in sorted({_path_term(path) for path in unique_paths if path}):
            if term_count >= 4:  # cap surviving terms, but dedup over the whole set first
                break
            key = term.lower()
            leaf = key.rsplit("/", 1)[-1]
            parent = key.split("/", 1)[0]
            if not term or key in seen or leaf in seen or parent in seen:
                continue  # subsumed by an emitted language / area (e.g. term "components/app" under area "components")
            seen.add(key)
            seen.add(leaf)
            emit("term", term)
            term_count += 1
    else:
        emit("count", f"{points_count} point" if points_count == 1 else f"{points_count} points")

    sample = _payload_text_preview(payloads)
    if sample.strip():
        emit("sample", "Sample", copy=sample)

    return tags


def workspace_display_name(
    collection_name: str,
    sample_paths: list[str],
    payloads: list[dict[str, Any]],
) -> str:
    """Human workspace/project name, or "" when nothing better than the collection id
    exists — prose builders drop the name entirely rather than echo the id."""
    explicit_candidates = [
        payload.get(key)
        for payload in payloads
        for key in ("workspace", "workspace_name", "workspaceName", "project", "project_name", "repository")
        if isinstance(payload.get(key), str) and payload.get(key)
    ]
    if explicit_candidates:
        return _friendly_project_name(explicit_candidates[0])

    common_root = _common_project_root(sample_paths)
    if common_root:
        return _friendly_project_name(common_root)

    return ""


def load_roo_cache_workspace_hints() -> dict[str, list[str]]:
    storage_dir = Path.home() / "Library/Application Support/Code/User/globalStorage/zoocodeorganization.zoo-code"
    if not storage_dir.exists():
        return {}

    hints: dict[str, list[str]] = {}
    for cache_file in storage_dir.glob("roo-index-cache-*.json"):
        digest = cache_file.stem.removeprefix("roo-index-cache-")
        if len(digest) < 16:
            continue
        collection_name = f"ws-{digest[:16]}"
        workspace_paths = _workspace_paths_from_roo_cache(cache_file)
        if workspace_paths:
            hints[collection_name] = workspace_paths
    return hints


# Roo cache files are re-read on every content inspection but change rarely —
# memoize the parsed workspace paths keyed by (mtime, size).
_roo_cache_memo: dict[str, tuple[float, int, list[str]]] = {}


def _workspace_paths_from_roo_cache(cache_file: Path) -> list[str]:
    try:
        stat = cache_file.stat()
    except OSError:
        return []
    memo_key = str(cache_file)
    memo = _roo_cache_memo.get(memo_key)
    if memo is not None and memo[0] == stat.st_mtime and memo[1] == stat.st_size:
        return memo[2]

    try:
        raw = json.loads(cache_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(raw, dict):
        return []

    paths = [to_well_formed(key) for key in raw.keys() if isinstance(key, str)]
    _roo_cache_memo[memo_key] = (stat.st_mtime, stat.st_size, paths)
    return paths


# Markup, data and prose formats never define what kind of project this is — only real
# code languages do. Used to pick the "Looks like a … project" opener.
_NON_CODE_LANGUAGES = {"Markdown", "JSON", "YAML", "TOML", "HTML", "CSS", "SVG", "TXT", "XML", "CSV", "LOCK", "files"}

_PROJECT_LABELS = {
    "Python": "a Python project",
    "Swift": "a Swift project",
    "Go": "a Go project",
    "PHP": "a PHP project",
    "TypeScript": "a TypeScript project",
    "JavaScript": "a JavaScript project",
    "Rust": "a Rust project",
    "Java": "a Java project",
    "Kotlin": "a Kotlin project",
    "Ruby": "a Ruby project",
    "C#": "a C# project",
    "C++": "a C++ project",
    "Scala": "a Scala project",
    "SH": "a shell-scripts workspace",
}


def _project_flavor(language_counts: Counter[str]) -> str:
    """Friendly guess of what the indexed workspace is, from its dominant CODE language.

    Claims a project type only when that language is actually characteristic of the
    sample (>=2 files and >=20% share) — one stray helper script must not relabel a
    docs repository, and a 2-file JS minority must not claim a mostly-HTML website.
    """
    total = sum(language_counts.values())
    if total and language_counts.most_common(1)[0][0] == "HTML":
        return "a website"

    code_counts = {
        language: count
        for language, count in language_counts.items()
        if language not in _NON_CODE_LANGUAGES
    }
    if code_counts:
        dominant, dominant_count = max(code_counts.items(), key=lambda item: item[1])
        if dominant_count >= 2 and dominant_count * 5 >= total:
            # Unknown languages fall back to neutral copy — never "a RS project".
            return _PROJECT_LABELS.get(dominant, "a code workspace")
        if sum(code_counts.values()) * 10 >= total:
            return "a mixed-language workspace"
    return "a docs & config workspace"


def indexed_content_summary(
    workspace_name: str,
    paths: list[str],
    payloads: list[dict[str, Any]],
    points_count: int,
) -> str:
    """Short human summary for the Content table's "What seems indexed" column.

    Reads like a sentence, not a record dump: no collection ids (the Collection column
    already shows them), languages ordered by how often they actually occur, and a
    "Looks like a … project" opener inferred from the dominant code language.
    `workspace_name` is "" when no real name could be resolved — then it is omitted.
    """
    unique_paths = list(dict.fromkeys(path for path in paths if path))

    if unique_paths:
        language_counts = Counter(_language_for_path(path) for path in unique_paths)
        prose_languages = [lang for lang, _ in language_counts.most_common() if lang != "files"][:4]
        file_count = len(unique_paths)
        lead = f"{workspace_name} — looks" if workspace_name else "Looks"
        head = f"{lead} like {_project_flavor(language_counts)}: {file_count} file{'s' if file_count != 1 else ''}"
        if prose_languages:
            head += f", mostly {_human_list(prose_languages)}"
        sentences = [head + "."]
        domains = _domain_terms(unique_paths)[:5]
        if domains:
            label = "Key areas" if len(domains) > 1 else "Key area"
            sentences.append(f"{label}: {_human_list(domains)}.")
        return " ".join(sentences)

    # Colon (not another dash) before the name: both sentences below already use an
    # em-dash, and "myproj — 3 points — no metadata" reads as broken punctuation.
    name_prefix = f"{workspace_name}: " if workspace_name else ""
    text_preview = _payload_text_preview(payloads)
    point_word = "snippet" if points_count == 1 else "snippets"
    if text_preview:
        # Scope the claim honestly: only the sampled points were checked for file names.
        return (
            f"{name_prefix}{points_count} indexed text {point_word} — the sampled ones "
            f"carry no file names. Sample: {text_preview[:120]}."
        )

    return (
        f"{name_prefix}{points_count} point{'s' if points_count != 1 else ''} — "
        "the sampled payload has no readable file metadata."
    )


def content_preview(
    sample_paths: list[str],
    payloads: list[dict[str, Any]],
    indexed_summary: str,
) -> str:
    """Expanded-row text: the summary plus concrete examples — nothing repeated."""
    terms = sorted({_path_term(path) for path in sample_paths if path})[:5]
    text_preview = _payload_text_preview(payloads)
    preview = indexed_summary
    if terms:
        preview += f" Typical files: {', '.join(terms)}."
    # The pathless summary already embeds the sample — never print it twice.
    if text_preview and "Sample:" not in indexed_summary:
        preview += f" Sample: {text_preview}"
    return preview


def _domain_terms(paths: list[str]) -> list[str]:
    ignored = {
        "Users", "avganov", "WORKSPACE", "TECH", "[WORKSPACE]", "[TECH]",
        "Autohub", "Automation", "src", "Sources", "tests", "Tests",
    }
    terms: dict[str, int] = {}
    for path in paths:
        for part in _normalize_path(path).split("/")[-5:-1]:
            if not part or part in ignored or part.startswith("."):
                continue
            terms[part] = terms.get(part, 0) + 1
    return [term for term, _ in sorted(terms.items(), key=lambda item: (-item[1], item[0].lower()))]


def _human_list(values: list[str]) -> str:
    if not values:
        return ""
    if len(values) == 1:
        return values[0]
    if len(values) == 2:
        return f"{values[0]} and {values[1]}"
    return ", ".join(values[:-1]) + f" and {values[-1]}"


def _payload_path(payload: dict[str, Any]) -> str:
    for key in ("file_path", "filePath", "path", "source", "uri", "relative_path", "relativePath"):
        value = payload.get(key)
        if isinstance(value, str) and value:
            return to_well_formed(value)
    return ""


def _payload_text_preview(payloads: list[dict[str, Any]]) -> str:
    for payload in payloads:
        for key in ("text", "content", "chunk", "preview"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return to_well_formed(" ".join(value.split())[:180])
    return ""


def _common_project_root(paths: list[str]) -> str:
    candidates = [path for path in paths if path]
    if not candidates:
        return ""


    split_paths = [_normalize_path(path).split("/") for path in candidates]
    common_parts = []
    for parts in zip(*split_paths):
        if len(set(parts)) != 1:
            break
        common_parts.append(parts[0])

    if not common_parts:
        return ""

    if common_parts[-1].count(".") and len(common_parts) > 1:
        common_parts.pop()
    return "/".join(common_parts)


def _friendly_project_name(path: str) -> str:
    normalized = _normalize_path(path)
    parts = [part for part in normalized.split("/") if part and part not in {"[WORKSPACE]", "[TECH]"}]
    preferred_markers = {"Autohub", "Automation", "TECH", "WORKSPACE"}
    for index, part in enumerate(parts):
        if part in preferred_markers and index + 1 < len(parts):
            return parts[index + 1]
    return parts[-1] if parts else path


def _normalize_path(path: str) -> str:
    return path.replace("\\", "/").rstrip("/")


def _language_for_path(path: str) -> str:
    leaf = _normalize_path(path).rsplit("/", 1)[-1]   # extension lives in the filename, not a dotted parent dir
    extension = leaf.rsplit(".", 1)[-1].lower() if "." in leaf else ""
    return {
        "py": "Python",
        "swift": "Swift",
        "md": "Markdown",
        "ts": "TypeScript",
        "tsx": "TypeScript",
        "js": "JavaScript",
        "jsx": "JavaScript",
        "php": "PHP",
        "go": "Go",
        "rs": "Rust",
        "java": "Java",
        "kt": "Kotlin",
        "kts": "Kotlin",
        "rb": "Ruby",
        "cs": "C#",
        "cpp": "C++",
        "cc": "C++",
        "scala": "Scala",
        "html": "HTML",
        "css": "CSS",
        "json": "JSON",
        "yaml": "YAML",
        "yml": "YAML",
        "toml": "TOML",
    }.get(extension, extension.upper() if extension else "files")


def _path_term(path: str) -> str:
    normalized = _normalize_path(path)
    parts = [part for part in normalized.split("/") if part]
    if len(parts) >= 2:
        return "/".join(parts[-2:])
    return parts[-1] if parts else normalized


# Embarsy-managed vector storage default, applied to every collection unless the client
# configured quantization explicitly: searches run on an in-RAM int8 copy (4x smaller,
# SIMD-accelerated) while full-precision originals stay on disk and are only read to
# rescore the top candidates — no practical recall loss for cosine text embeddings.
SCALAR_INT8_QUANTIZATION: dict[str, Any] = {
    "scalar": {"type": "int8", "quantile": 0.99, "always_ram": True}
}

# `PUT collections/<name>` is Qdrant's collection-CREATE call (updates use PATCH).
_COLLECTION_CREATE_PATH = re.compile(r"^collections/[^/]+/?$")


def inject_default_quantization(method: str, path: str, body: bytes) -> bytes:
    """Add Embarsy's quantization default to proxied collection-creation requests.

    Editors (Roo/Zoo, older bridge versions) create collections without any
    quantization; injecting it here means every collection created through the proxy
    gets the optimal storage layout with zero client changes. Anything that is not a
    parseable collection-creation body passes through untouched, and an explicit
    client-provided quantization_config always wins.
    """
    if method.upper() != "PUT" or not _COLLECTION_CREATE_PATH.match(path):
        return body
    try:
        payload = json.loads(body or b"{}")
    except ValueError:
        return body
    if not isinstance(payload, dict) or "vectors" not in payload:
        return body
    if payload.get("quantization_config") is not None:
        return body

    payload["quantization_config"] = SCALAR_INT8_QUANTIZATION
    vectors = payload.get("vectors")
    if isinstance(vectors, dict):
        if "size" in vectors:
            # Single unnamed vector config — keep originals on disk unless the client chose.
            vectors.setdefault("on_disk", True)
        else:
            for named in vectors.values():
                if isinstance(named, dict) and "size" in named:
                    named.setdefault("on_disk", True)
    return json.dumps(payload).encode()


# ── grep-vs-semantic benchmark ────────────────────────────────────────────────

@app.post("/benchmark/retrieval", dependencies=[Depends(require_api_key)])
async def run_retrieval_benchmark(
    request: BenchmarkRequest,
    settings: Settings = Depends(get_settings),
    service: EmbeddingService = Depends(get_embedding_service),
) -> dict[str, object]:
    """Run the same self-generated concept queries through BOTH engines — the
    semantic index and a real grep over the workspace — and report accuracy,
    latency and noise. See embarsy_api/benchmark.py for the methodology."""
    if not settings.api_key:
        # Without a key this endpoint would let anything on localhost use grep as a
        # filesystem word-presence oracle over any readable folder.
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Benchmark requires the Embarsy API key to be configured.",
        )
    workspace = Path(request.workspace_path).expanduser()
    if not workspace.is_dir():
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Workspace folder not found: {workspace}",
        )
    samples = max(4, min(request.samples, 20))
    top_k = max(1, min(request.top_k, 10))
    headers = {"api-key": settings.qdrant_api_key} if settings.qdrant_api_key else None
    client = shared_http_client()
    qdrant = settings.qdrant_base_url.rstrip("/")

    # 1) Sample random indexed chunks (ground truth = the file each chunk came from).
    candidates = await _sample_collection_points(client, qdrant, headers, request.collection, samples * 5)
    random.shuffle(candidates)  # the old-Qdrant scroll fallback is deterministic otherwise
    provisional: list[tuple[str, str]] = []  # (query, truth_file)
    seen_files: set[str] = set()
    for payload in candidates:
        truth = _payload_path(payload)
        text = (payload.get("text") or payload.get("content")
                or payload.get("chunk") or payload.get("codeChunk") or "")
        if not truth or not isinstance(text, str) or truth in seen_files:
            continue
        if not bench.is_benchmarkable(truth, text):
            continue
        query = bench.concept_query(to_well_formed(text))
        if query is None:
            continue
        seen_files.add(truth)
        provisional.append((query, truth))
        if len(provisional) >= samples * 2:
            break

    # Fairness gate: grep can only compete for files that actually live under the
    # chosen folder. A mismatched workspace (or stale index) must fail loudly, not
    # hand the semantic side a fake sweep. One find pass verifies all samples.
    verified, workspace_verified, find_hits = await _verify_truths_in_workspace(workspace, [t for _, t in provisional])
    picked = [(q, t) for q, t in provisional if t in verified][:samples]
    missing_in_workspace = len(provisional) - sum(1 for _, t in provisional if t in verified)
    if len(picked) < 4:
        if missing_in_workspace > len(picked):
            raise HTTPException(
                status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
                detail=(
                    f"This collection does not match the folder {workspace} — "
                    f"{missing_in_workspace} sampled files are not there (wrong project, or a stale index). "
                    "Pick the folder this collection indexes."
                ),
            )
        raise HTTPException(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            detail="Not enough indexed chunks with file metadata to benchmark this collection.",
        )

    # Fairness: grep must race over the same corpus the collection indexes. When the
    # chosen workspace is a SUPERSET of the indexed tree (indexers often root at a
    # child folder), scanning the extra siblings would rig the duel against grep.
    index_root = bench.detect_index_root(find_hits, [t for _, t in picked])
    grep_root = (workspace / index_root) if index_root else workspace
    if not grep_root.is_dir():
        grep_root = workspace

    # 2) Warm up the embedding model so its one-off load time doesn't pollute latency.
    try:
        await service.embed([picked[0][0]])
    except EmbeddingError as exc:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail=f"Embedding backend unavailable for benchmark: {exc}",
        ) from exc

    # 3) The duel: same query, both engines.
    rows: list[dict[str, object]] = []
    skipped_errors = 0
    for query, truth in picked:
        original_query = query
        swapped: list[dict[str, str]] = []
        if request.paraphrase:
            query, swapped = bench.paraphrase_query(query)
        try:
            semantic = await _semantic_run(client, qdrant, headers, request.collection, service, query, top_k)
        except (EmbeddingError, httpx.HTTPError) as exc:
            # A transient backend hiccup must not throw away the completed rows.
            logger.warning("Benchmark query skipped (semantic error): %s", exc)
            skipped_errors += 1
            continue
        grep = await _grep_run(query.split(), grep_root, top_k)
        row = {"query": query, "truth_file": truth,
               "semantic": semantic | {"rank": bench.rank_of(truth, semantic.pop("_files"), top_k)},
               "grep": grep | {"rank": bench.rank_of(truth, grep.pop("_files"), top_k)}}
        if request.paraphrase:
            # Full disclosure: what the question was before the synonym swaps.
            row["original_query"] = original_query
            row["swapped"] = swapped
        rows.append(row)
    if not rows:
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Embedding backend failed for every benchmark query. Check that the stack is running.",
        )

    completed_greps = [row for row in rows if not row["grep"]["timed_out"]]
    return {
        "collection": request.collection,
        "workspace_path": str(workspace),
        "samples": len(rows),
        "top_k": top_k,
        "skipped_errors": skipped_errors,
        "workspace_verified": workspace_verified,
        "grep_root": str(grep_root),
        "paraphrased": request.paraphrase,
        "queries": rows,
        "summary": {
            "semantic": {
                "hit_top1": sum(1 for row in rows if row["semantic"]["rank"] == 1),
                "hit_topk": sum(1 for row in rows if row["semantic"]["rank"] is not None),
                "median_latency_ms": bench.median_ms([row["semantic"]["latency_ms"] for row in rows]),
                "median_candidates": top_k,
            },
            "grep": {
                "hit_top1": sum(1 for row in rows if row["grep"]["rank"] == 1),
                "hit_topk": sum(1 for row in rows if row["grep"]["rank"] is not None),
                # A killed grep never produced a ranked answer — mixing its 15s cap
                # into the median would inflate it; the timeout count is the honest
                # signal for those rows.
                "median_latency_ms": bench.median_ms(
                    [row["grep"]["latency_ms"] for row in completed_greps]
                ),
                # Noise median over runs that actually matched something; a timed-out
                # or zero-match run saying "0 lines to sift" would flatter grep.
                "median_matched_lines": bench.median_ms(
                    [row["grep"]["matched_lines"] for row in completed_greps
                     if row["grep"]["files_with_matches"] > 0]
                ),
                "zero_result_queries": sum(
                    1 for row in completed_greps if row["grep"]["files_with_matches"] == 0
                ),
                "timeouts": sum(1 for row in rows if row["grep"]["timed_out"]),
            },
        },
    }


async def _sample_collection_points(
    client: httpx.AsyncClient,
    qdrant: str,
    headers: dict[str, str] | None,
    collection: str,
    limit: int,
) -> list[dict[str, Any]]:
    """Random points with payloads; falls back to a plain scroll on older Qdrant."""
    try:
        response = await client.post(
            f"{qdrant}/collections/{collection}/points/query",
            headers=headers,
            json={"query": {"sample": "random"}, "limit": limit, "with_payload": True},
            timeout=15.0,
        )
        response.raise_for_status()
        points = response.json().get("result", {}).get("points", [])
    except httpx.HTTPError:
        try:
            response = await client.post(
                f"{qdrant}/collections/{collection}/points/scroll",
                headers=headers,
                json={"limit": limit, "with_payload": True, "with_vector": False},
                timeout=15.0,
            )
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise HTTPException(
                status_code=status.HTTP_404_NOT_FOUND,
                detail=f"Collection '{collection}' is not available in Qdrant (HTTP {exc.response.status_code}).",
            ) from exc
        points = response.json().get("result", {}).get("points", [])
    return [p.get("payload", {}) for p in points if isinstance(p.get("payload"), dict)]


async def _semantic_run(
    client: httpx.AsyncClient,
    qdrant: str,
    headers: dict[str, str] | None,
    collection: str,
    service: EmbeddingService,
    query: str,
    top_k: int,
) -> dict[str, Any]:
    timer = bench.StageTimer()
    vectors = await service.embed([query])
    embed_ms = timer.ms()
    search_timer = bench.StageTimer()
    try:
        response = await client.post(
            f"{qdrant}/collections/{collection}/points/query",
            headers=headers,
            json={"query": vectors[0], "limit": 30, "with_payload": True},
            timeout=15.0,
        )
        response.raise_for_status()
        points = response.json().get("result", {}).get("points", [])
    except httpx.HTTPStatusError:
        # Pre-Query-API Qdrant: same search through the legacy endpoint. Restart the
        # stage timer — the doomed probe of the modern endpoint is our implementation
        # detail and must not be billed to the reported search time.
        search_timer = bench.StageTimer()
        response = await client.post(
            f"{qdrant}/collections/{collection}/points/search",
            headers=headers,
            json={"vector": vectors[0], "limit": 30, "with_payload": True},
            timeout=15.0,
        )
        response.raise_for_status()
        points = response.json().get("result", [])
    search_ms = search_timer.ms()
    latency = round(embed_ms + search_ms, 1)
    files: list[str] = []
    snippet_chars = 0  # context an agent actually receives: the top-K snippets
    for point in points if isinstance(points, list) else []:
        payload = point.get("payload") if isinstance(point.get("payload"), dict) else {}
        path = _payload_path(payload)
        if path and path not in files:
            files.append(path)
            if len(files) <= top_k:
                text = (payload.get("text") or payload.get("content")
                        or payload.get("chunk") or payload.get("codeChunk") or "")
                snippet_chars += len(text) if isinstance(text, str) else 0
    return {
        "latency_ms": latency,
        "embed_ms": embed_ms,
        "search_ms": search_ms,
        "snippet_chars": snippet_chars,
        "_files": files,
        "top_files": files[:top_k],
    }


async def _verify_truths_in_workspace(workspace: Path, truths: list[str]) -> "tuple[set[str], bool]":
    """Single find pass locating the sampled files under the workspace.

    Fails OPEN on timeout (giant repos): the gate exists to catch gross
    mismatches, and a slow find must not block an honest benchmark. The second
    element says whether the gate actually ran — the log must not claim a
    verification that was skipped. The third element is the raw find hits,
    used to detect where the indexed tree lives under the workspace."""
    if not truths:
        return set(), True, []
    process = await asyncio.create_subprocess_exec(
        *bench.find_truths_command(truths),
        cwd=str(workspace),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        stdout, _ = await asyncio.wait_for(process.communicate(), timeout=20.0)
    except asyncio.TimeoutError:
        process.kill()
        await process.wait()
        logger.warning("Workspace verification find pass timed out — skipping the gate")
        return set(truths), False, []
    except asyncio.CancelledError:
        process.kill()
        await process.wait()
        raise
    lines = [line for line in stdout.decode("utf-8", errors="replace").splitlines() if line.strip()]
    return bench.truths_found("\n".join(lines), truths), True, lines


_GREP_TIMEOUT_S = 15.0
_GREP_STDOUT_CAP = 8 * 1024 * 1024  # grep -rc emits a line per scanned file — cap the buffer


async def _grep_run(words: list[str], workspace: Path, top_k: int) -> dict[str, Any]:
    """grep at its competent best, not a strawman.

    Strategy (what a developer or agent actually does with a multi-word query):
    1) AND-intersect: files containing EVERY query word — the classic
       `grep -ril w1 . | xargs grep -il w2 | ...` pipeline, longest word first.
    2) Rank the candidates by total matching lines of the words (density).
    3) Only if the intersection is empty, fall back to the one-pass OR
       alternation ranked by matching-line count.
    One 15 s wall-clock budget covers the whole strategy."""
    timer = bench.StageTimer()
    deadline = time.monotonic() + _GREP_TIMEOUT_S
    ordered = bench.and_order(words)
    pattern = bench.alternation(words)
    timed_out = False
    truncated = False
    candidates: Optional[list[str]] = None

    # Stage 1: AND-intersection.
    for index, word in enumerate(ordered):
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
            break
        if candidates is None:
            cmd = ["/usr/bin/grep", "-r", "-i", "-l", "-I", "-s",
                   *bench.exclude_dir_flags(), "-e", re.escape(word), "."]
            text, stage_timeout, stage_truncated = await _run_grep_capped(cmd, workspace, remaining)
            timed_out = timed_out or stage_timeout
            truncated = truncated or stage_truncated
            candidates = [line for line in text.splitlines() if line.strip()]
        else:
            filtered: list[str] = []
            for batch_start in range(0, len(candidates), _GREP_BATCH):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    timed_out = True
                    break
                batch = candidates[batch_start:batch_start + _GREP_BATCH]
                cmd = ["/usr/bin/grep", "-i", "-l", "-I", "-s", "-e", re.escape(word), *batch]
                text, stage_timeout, stage_truncated = await _run_grep_capped(cmd, workspace, remaining)
                timed_out = timed_out or stage_timeout
                truncated = truncated or stage_truncated
                filtered += [line for line in text.splitlines() if line.strip()]
            candidates = filtered
        if timed_out or not candidates:
            break

    strategy = "and"
    ranked: list[tuple[str, int]] = []
    if timed_out:
        candidates = candidates or []
    elif candidates:
        # Stage 2: rank the AND set by how densely the query words hit each file.
        count_lines: list[str] = []
        for batch_start in range(0, len(candidates), _GREP_BATCH):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            batch = candidates[batch_start:batch_start + _GREP_BATCH]
            # /dev/null forces the `path:count` prefix even for a single file.
            cmd = ["/usr/bin/grep", "-i", "-c", "-E", pattern, *batch, "/dev/null"]
            text, stage_timeout, stage_truncated = await _run_grep_capped(cmd, workspace, remaining)
            timed_out = timed_out or stage_timeout
            truncated = truncated or stage_truncated
            count_lines += text.splitlines()
        ranked = [(path, count) for path, count in bench.parse_grep_counts("\n".join(count_lines))
                  if path != "/dev/null"]
    else:
        # Stage 3: nothing contains every word — the honest fallback is the
        # one-pass OR alternation a developer would broaden to.
        strategy = "or"
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            timed_out = True
        else:
            text, stage_timeout, stage_truncated = await _run_grep_capped(
                bench.grep_command(words), workspace, remaining)
            timed_out = timed_out or stage_timeout
            truncated = truncated or stage_truncated
            if (stage_timeout or stage_truncated) and "\n" in text:
                # A cut-off buffer almost certainly ends mid-line: "handlers.py:487"
                # cut at ":4" would parse as a valid count — drop the partial tail.
                text = text.rsplit("\n", 1)[0]
            ranked = bench.parse_grep_counts(text)

    latency = timer.ms()
    files = [path for path, _ in ranked]
    command = (bench.and_pipeline_description(words) if strategy == "and"
               else shlex.join(bench.grep_command(words)))
    return {
        "latency_ms": latency,
        "strategy": strategy,
        # The reproducible equivalent of what ran (AND stages execute as separate
        # processes for timeout control; results are identical).
        "command": command,
        "_files": files,
        "top_files": files[:top_k],
        "top_matches": [{"path": path, "lines": count} for path, count in ranked[:top_k]],
        "files_with_matches": len(ranked),
        "matched_lines": sum(count for _, count in ranked),
        "timed_out": timed_out,
        # Output overflowed the 8 MB capture cap: counts are lower bounds.
        "truncated_output": truncated,
    }


_GREP_BATCH = 400  # files per filter/count exec — safely under ARG_MAX


async def _run_grep_capped(command: list[str], cwd: Path, timeout_s: float) -> "tuple[str, bool, bool]":
    """Run one grep pass with the shared drain/cap/kill discipline.

    Returns (stdout_text, timed_out, truncated). Never leaves a process behind:
    kills on timeout and on task cancellation."""
    timed_out = False
    chunks: list[bytes] = []
    received = 0
    process = await asyncio.create_subprocess_exec(
        *command,
        cwd=str(cwd),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL,
    )
    try:
        async def _drain() -> None:
            nonlocal received
            assert process.stdout is not None
            while True:
                chunk = await process.stdout.read(65536)
                if not chunk:
                    break
                if received < _GREP_STDOUT_CAP:
                    chunks.append(chunk)
                    received += len(chunk)
                # past the cap: keep draining so grep never blocks on a full pipe

        await asyncio.wait_for(_drain(), timeout=max(timeout_s, 0.05))
        await process.wait()
    except asyncio.TimeoutError:
        timed_out = True
    except asyncio.CancelledError:
        # Client disconnected / task cancelled — never leave a grep grinding away.
        process.kill()
        await process.wait()
        raise
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()
    return b"".join(chunks).decode("utf-8", errors="replace"), timed_out, received >= _GREP_STDOUT_CAP


@app.api_route(
    "/qdrant/{path:path}",
    methods=["GET", "POST", "PUT", "PATCH", "DELETE"],
    dependencies=[Depends(require_qdrant_api_key)],
)
async def proxy_qdrant_request(
    path: str,
    request: Request,
    settings: Settings = Depends(get_settings),
) -> Response:
    operation = classify_qdrant_proxy_operation(request.method, f"/{path}")
    upstream_url = f"{settings.qdrant_base_url.rstrip('/')}/{path}"
    headers = _proxy_qdrant_headers(request, settings)
    body = inject_default_quantization(request.method, path, await request.body())

    try:
        upstream_response = await shared_http_client().request(
            request.method,
            upstream_url,
            params=request.query_params,
            content=body,
            headers=headers,
            timeout=settings.request_timeout_seconds,
        )
    except httpx.HTTPError as exc:
        if operation is not None:
            metrics.record_qdrant(operation, method=request.method, path=f"/{path}", error=True)
        logger.warning("Qdrant proxy request failed: %s", exc)
        return JSONResponse(
            status_code=status.HTTP_502_BAD_GATEWAY,
            content={
                "error": {
                    "message": str(exc),
                    "type": "qdrant_proxy_error",
                    "code": "qdrant_proxy_error",
                }
            },
        )

    if operation is not None:
        metrics.record_qdrant(
            operation,
            method=request.method,
            path=f"/{path}",
            error=upstream_response.status_code >= 400,
        )

    return Response(
        content=upstream_response.content,
        status_code=upstream_response.status_code,
        headers=_response_headers(upstream_response),
        media_type=upstream_response.headers.get("content-type"),
    )


def _proxy_qdrant_headers(request: Request, settings: Settings) -> dict[str, str]:
    excluded_headers = {"host", "content-length", "connection", "api-key"}
    headers = {
        key: value
        for key, value in request.headers.items()
        if key.lower() not in excluded_headers
    }
    if settings.qdrant_api_key:
        headers["api-key"] = settings.qdrant_api_key
    return headers


def _response_headers(response: httpx.Response) -> dict[str, str]:
    excluded_headers = {"content-encoding", "content-length", "connection", "transfer-encoding"}
    return {
        key: value
        for key, value in response.headers.items()
        if key.lower() not in excluded_headers
    }


async def build_embeddings_response(
    request: EmbeddingsRequest,
    service: EmbeddingService,
    settings: Settings,
) -> EmbeddingsResponse:
    if request.dimensions is not None and request.dimensions != settings.embedding_dimension:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"Only dimensions={settings.embedding_dimension} is supported",
        )

    inputs = as_input_list(request.input)  # also sanitizes to well-formed Unicode
    model = to_well_formed(request.model) if request.model else settings.ollama_model
    metrics.record_embedding_request(
        inputs=inputs,
        model=model,
    )
    started = time.monotonic()
    try:
        vectors = await service.embed(inputs)
    except EmbeddingError as exc:
        metrics.record_embeddings(
            vectors=0,
            latency_seconds=time.monotonic() - started,
            error=True,
        )
        logger.warning("Embedding backend error: %s", exc)
        return JSONResponse(
            status_code=status.HTTP_502_BAD_GATEWAY,
            content={
                "error": {
                    "message": str(exc),
                    "type": "embedding_backend_error",
                    "code": "embedding_backend_error",
                }
            },
        )

    latency_seconds = time.monotonic() - started
    metrics.record_embeddings(vectors=len(vectors), latency_seconds=latency_seconds)

    data = [
        EmbeddingObject(
            index=index,
            embedding=encode_float32_base64(vector)
            if request.encoding_format == "base64"
            else vector,
        )
        for index, vector in enumerate(vectors)
    ]
    rough_tokens = sum(max(1, len(text) // 4) for text in inputs)
    response = EmbeddingsResponse(
        data=data,
        model=model,
        usage=UsageObject(prompt_tokens=rough_tokens, total_tokens=rough_tokens),
    )
    app.state.last_embedding_latency_seconds = latency_seconds
    return response


@app.post(
    "/v1/embeddings",
    response_model=EmbeddingsResponse,
    dependencies=[Depends(require_api_key)],
)
@app.post(
    "/embeddings",
    response_model=EmbeddingsResponse,
    dependencies=[Depends(require_api_key)],
)
async def create_embeddings(
    request: EmbeddingsRequest,
    service: EmbeddingService = Depends(get_embedding_service),
    settings: Settings = Depends(get_settings),
) -> EmbeddingsResponse:
    return await build_embeddings_response(request, service, settings)
