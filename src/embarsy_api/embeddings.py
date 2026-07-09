from __future__ import annotations

import base64
import math
import re
import struct
from collections.abc import Sequence
from dataclasses import dataclass
from typing import Any

import httpx


class EmbeddingError(RuntimeError):
    """Raised when the local embedding backend cannot produce valid vectors."""


# Matches UNPAIRED UTF-16 surrogates only: json.loads combines valid escaped pairs
# (😀) into single astral characters, which are outside this range — so
# anything still in it is a broken half of an emoji/astral char.
_UNPAIRED_SURROGATES = re.compile("[\ud800-\udfff]")


def to_well_formed(text: str) -> str:
    """Replace unpaired UTF-16 surrogates with U+FFFD so the string is valid Unicode.

    Clients that slice text by UTF-16 code units (editors, chunkers) can cut an emoji
    in half; JSON happily transports the lone surrogate escape ("\\ud83d") and
    json.loads accepts it into a Python str — but every later UTF-8 encode (httpx
    re-packing the Ollama request, a JSONResponse, the metrics persister) raises
    UnicodeEncodeError and turns into a 500. Sanitizing at ingress fixes the whole
    class at once; the replacement character keeps the surrounding text intact.
    """
    return _UNPAIRED_SURROGATES.sub("�", text)


def as_input_list(value: str | list[str]) -> list[str]:
    """Normalize the OpenAI-style input field AND make every text well-formed —
    this is the single chokepoint all embedding inputs flow through."""
    if isinstance(value, str):
        return [to_well_formed(value)]
    return [to_well_formed(item) for item in value]


def prepare_embedding_text(text: str, instruction: str) -> str:
    """Apply one consistent Qwen3-style instruction template for documents and queries."""
    stripped = text.strip()
    return f"Instruct: {instruction.strip()}\nQuery: {stripped}"


def l2_normalize(vector: Sequence[float]) -> list[float]:
    norm = math.sqrt(sum(value * value for value in vector))
    if norm == 0:
        raise EmbeddingError("Ollama returned a zero vector; cannot L2-normalize it")
    return [float(value / norm) for value in vector]


def encode_float32_base64(vector: Sequence[float]) -> str:
    packed = struct.pack(f"<{len(vector)}f", *vector)
    return base64.b64encode(packed).decode("ascii")


@dataclass(frozen=True)
class EmbeddingService:
    ollama_base_url: str
    model: str
    keep_alive: str
    dimension: int
    instruction: str
    timeout_seconds: float

    @property
    def ollama_keep_alive_payload(self) -> str | int:
        stripped = self.keep_alive.strip()
        if stripped.lstrip("-").isdigit():
            return int(stripped)
        return stripped

    async def embed(self, inputs: list[str]) -> list[list[float]]:
        prepared = [prepare_embedding_text(text, self.instruction) for text in inputs]
        raw_vectors = await self._embed_batch(prepared)

        vectors: list[list[float]] = []
        for index, vector in enumerate(raw_vectors):
            if len(vector) != self.dimension:
                raise EmbeddingError(
                    f"Embedding #{index} has dimension {len(vector)}, expected {self.dimension}"
                )
            vectors.append(l2_normalize(vector))
        return vectors

    async def _embed_batch(self, prepared_inputs: list[str]) -> list[list[float]]:
        client = _ollama_client()
        base = self.ollama_base_url.rstrip("/")
        response = await client.post(
            f"{base}/api/embed",
            json={
                "model": self.model,
                "input": prepared_inputs,
                "keep_alive": self.ollama_keep_alive_payload,
            },
            timeout=self.timeout_seconds,
        )

        if response.status_code == 404:
            return await self._embed_legacy(client, prepared_inputs)

        try:
            response.raise_for_status()
        except httpx.HTTPStatusError as exc:
            raise EmbeddingError(f"Ollama /api/embed failed: {exc.response.text}") from exc

        payload = response.json()
        vectors = payload.get("embeddings")
        if not isinstance(vectors, list):
            raise EmbeddingError("Ollama /api/embed response does not contain embeddings[]")
        return [_coerce_vector(vector) for vector in vectors]

    async def _embed_legacy(
        self, client: httpx.AsyncClient, prepared_inputs: list[str]
    ) -> list[list[float]]:
        base = self.ollama_base_url.rstrip("/")
        vectors: list[list[float]] = []
        for prepared in prepared_inputs:
            response = await client.post(
                f"{base}/api/embeddings",
                json={
                    "model": self.model,
                    "prompt": prepared,
                    "keep_alive": self.ollama_keep_alive_payload,
                },
                timeout=self.timeout_seconds,
            )
            try:
                response.raise_for_status()
            except httpx.HTTPStatusError as exc:
                raise EmbeddingError(f"Ollama /api/embeddings failed: {exc.response.text}") from exc
            vectors.append(_coerce_vector(response.json().get("embedding")))
        return vectors


# Shared keep-alive client for Ollama — the old client-per-request pattern paid a TCP
# setup + teardown for every embedding call.
_client: httpx.AsyncClient | None = None


def _ollama_client() -> httpx.AsyncClient:
    global _client
    if _client is None or _client.is_closed:
        _client = httpx.AsyncClient()
    return _client


def _coerce_vector(value: Any) -> list[float]:
    if not isinstance(value, list):
        raise EmbeddingError("Embedding payload is not a list")
    try:
        return [float(item) for item in value]
    except (TypeError, ValueError) as exc:
        raise EmbeddingError("Embedding payload contains non-numeric values") from exc
