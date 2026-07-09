"""Lone-surrogate hardening: a client that slices text by UTF-16 code units can send
an emoji cut in half (an unpaired \ud83d escape). json.loads accepts it, but every
later UTF-8 encode (httpx to Ollama, JSONResponse, the metrics persister) used to
raise UnicodeEncodeError and turn into a 500 / a dead flusher thread."""

import json

from fastapi.testclient import TestClient

from embarsy_api import main
from embarsy_api.embeddings import EmbeddingService, as_input_list, to_well_formed
from embarsy_api.main import app, build_content_collection_row, get_embedding_service
from embarsy_api.metrics import EmbarsyMetrics

LONE = "adress \ud83d here"          # broken half of an emoji
PAIRED = "ok \N{GRINNING FACE} ok"   # a real, well-formed emoji


def test_to_well_formed_replaces_lone_and_keeps_real_emoji():
    assert to_well_formed(LONE) == "adress � here"
    # json.loads combines valid escaped pairs into one astral char — must survive.
    assert to_well_formed(PAIRED) == PAIRED
    decoded = json.loads(r'"😀"')
    assert to_well_formed(decoded) == decoded


def test_as_input_list_sanitizes_every_item():
    assert as_input_list(LONE) == ["adress � here"]
    assert as_input_list([LONE, PAIRED]) == ["adress � here", PAIRED]
    for text in as_input_list([LONE]):
        text.encode("utf-8")  # must never raise


class RecordingService(EmbeddingService):
    """Captures what would be sent to Ollama and returns fake unit vectors."""
    received: list[str] = []

    async def embed(self, inputs):
        type(self).received = list(inputs)
        for text in inputs:
            text.encode("utf-8")  # the exact operation that used to explode
        return [[1.0] + [0.0] * 1023 for _ in inputs]


def test_embeddings_endpoint_survives_lone_surrogate():
    app.dependency_overrides[get_embedding_service] = lambda: RecordingService(
        ollama_base_url="http://x", model="m", keep_alive="30m",
        dimension=1024, instruction="i", timeout_seconds=5,
    )
    try:
        # Raw body: the lone surrogate must travel as a JSON escape, like real clients send it.
        response = TestClient(app).post(
            "/v1/embeddings",
            content=b'{"input": "adress \\ud83d here", "model": "bad \\ud83d model"}',
            headers={"content-type": "application/json"},
        )
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200, response.text
    assert RecordingService.received == ["adress � here"]
    # The echoed model name must be safe to serialize too.
    assert response.json()["model"] == "bad � model"


def test_content_row_with_surrogate_payload_is_utf8_serializable():
    row = build_content_collection_row(
        "ws-x",
        {"points_count": 3},
        [{"payload": {"file_path": "a/b\ud83d.py", "text": "chunk \ud83d body"}}],
    )
    # The exact operation JSONResponse performs on the way out:
    json.dumps(row, ensure_ascii=False).encode("utf-8")


def test_metrics_flush_survives_illformed_event(tmp_path):
    m = EmbarsyMetrics(bucket_seconds=5, max_buckets=10,
                       state_file=tmp_path / "s.json", persist_min_interval=999)
    # Bypass ingress sanitization on purpose — the flusher must not die even then.
    m.record_embedding_request(inputs=[LONE], model="m")
    m.flush()          # must not raise (UnicodeEncodeError is swallowed, dirty re-set)
    m.flush()          # and a second call must be equally safe
