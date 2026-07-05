import asyncio
import base64
import math
import struct

import pytest
from fastapi.testclient import TestClient

from embarsy_api.embeddings import EmbeddingService, prepare_embedding_text
from embarsy_api.main import app, get_embedding_service


def vector_with_norm_5() -> list[float]:
    return [0.6, 0.8, *([0.0] * 1022)]


class FakeEmbeddingService:
    async def embed(self, inputs: list[str]) -> list[list[float]]:
        return [vector_with_norm_5() for _ in inputs]


@pytest.fixture(autouse=True)
def override_service():
    app.dependency_overrides[get_embedding_service] = lambda: FakeEmbeddingService()
    yield
    app.dependency_overrides.clear()


def test_health_returns_expected_dimension():
    client = TestClient(app)

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json()["dimension"] == 1024


@pytest.mark.parametrize("endpoint", ["/v1/embeddings", "/embeddings"])
def test_embeddings_float_response_has_1024_dimensions_and_unit_norm(endpoint):
    client = TestClient(app)

    response = client.post(endpoint, json={"input": "find auth logic"})

    assert response.status_code == 200
    embedding = response.json()["data"][0]["embedding"]
    assert len(embedding) == 1024
    assert math.sqrt(sum(value * value for value in embedding)) == pytest.approx(1.0)


@pytest.mark.parametrize("endpoint", ["/v1/embeddings", "/embeddings"])
def test_embeddings_batch_preserves_indices(endpoint):
    client = TestClient(app)

    response = client.post(endpoint, json={"input": ["first", "second"]})

    data = response.json()["data"]

    assert response.status_code == 200
    assert [item["index"] for item in data] == [0, 1]
    assert len(data) == 2


def test_activity_endpoint_includes_recent_embedding_request(monkeypatch):
    from embarsy_api import main
    from embarsy_api.metrics import EmbarsyMetrics

    activity_metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)
    monkeypatch.setattr(main, "metrics", activity_metrics)
    client = TestClient(app)

    response = client.post("/embeddings", json={"input": "current indexed chunk"})
    activity_response = client.get("/activity/requests")

    events = activity_response.json()["events"]
    assert response.status_code == 200
    assert activity_response.status_code == 200
    assert len(events) == 1
    assert events[0]["operation"] == "embedding"
    assert "current indexed chunk" in events[0]["detail"]


@pytest.mark.parametrize("endpoint", ["/v1/embeddings", "/embeddings"])
def test_embeddings_base64_encodes_1024_float32_values(endpoint):
    client = TestClient(app)

    response = client.post(
        endpoint, json={"input": "find repositories", "encoding_format": "base64"}
    )

    encoded = response.json()["data"][0]["embedding"]
    raw = base64.b64decode(encoded)
    values = struct.unpack("<1024f", raw)

    assert response.status_code == 200
    assert len(raw) == 1024 * 4
    assert math.sqrt(sum(value * value for value in values)) == pytest.approx(1.0, rel=1e-6)


@pytest.mark.parametrize("endpoint", ["/v1/embeddings", "/embeddings"])
def test_embeddings_rejects_requested_wrong_dimension(endpoint):
    client = TestClient(app)

    response = client.post(endpoint, json={"input": "test", "dimensions": 1536})

    assert response.status_code == 400
    assert response.json()["detail"] == "Only dimensions=1024 is supported"


def test_instruction_template_is_consistent_for_queries_and_documents():
    instruction = "code_search"

    query_text = prepare_embedding_text("where is auth handled?", instruction)
    document_text = prepare_embedding_text("def authenticate(user): pass", instruction)

    assert query_text.startswith("Instruct: code_search\nQuery: ")
    assert document_text.startswith("Instruct: code_search\nQuery: ")


def test_numeric_keep_alive_is_sent_as_number():
    service = EmbeddingService(
        ollama_base_url="http://127.0.0.1:11434",
        model="qwen3-embedding",
        keep_alive="-1",
        dimension=1024,
        instruction="code_search",
        timeout_seconds=1.0,
    )

    assert service.ollama_keep_alive_payload == -1


def test_duration_keep_alive_is_sent_as_string():
    service = EmbeddingService(
        ollama_base_url="http://127.0.0.1:11434",
        model="qwen3-embedding",
        keep_alive="30m",
        dimension=1024,
        instruction="code_search",
        timeout_seconds=1.0,
    )

    assert service.ollama_keep_alive_payload == "30m"


def test_service_rejects_wrong_dimension(monkeypatch):
    async def fake_embed_batch(_self: EmbeddingService, _inputs: list[str]) -> list[list[float]]:
        return [[1.0, 2.0, 3.0]]

    monkeypatch.setattr(EmbeddingService, "_embed_batch", fake_embed_batch)
    service = EmbeddingService(
        ollama_base_url="http://127.0.0.1:11434",
        model="qwen3-embedding",
        keep_alive="30m",
        dimension=1024,
        instruction="code_search",
        timeout_seconds=1.0,
    )

    with pytest.raises(Exception, match="expected 1024"):
        asyncio.run(service.embed(["test"]))
