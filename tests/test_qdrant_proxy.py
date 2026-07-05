import httpx
from fastapi.testclient import TestClient

from embarsy_api import main
from embarsy_api.metrics import EmbarsyMetrics
from embarsy_api.settings import Settings, get_settings


class FakeAsyncClient:
    last_request: dict[str, object] = {}
    response = httpx.Response(200, json={"result": []}, headers={"x-qdrant-version": "test"})

    def __init__(self, *args, **kwargs):
        self.args = args
        self.kwargs = kwargs

    async def __aenter__(self):
        return self

    async def __aexit__(self, exc_type, exc, traceback):
        return False

    async def request(self, method, url, **kwargs):
        self.__class__.last_request = {
            "method": method,
            "url": url,
            "params": kwargs.get("params"),
            "content": kwargs.get("content"),
            "headers": kwargs.get("headers"),
        }
        return self.__class__.response


def test_qdrant_proxy_forwards_request_and_counts_read(monkeypatch):
    proxy_metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)
    settings = Settings(QDRANT_BASE_URL="http://qdrant.local", QDRANT_API_KEY="secret")
    main.app.dependency_overrides[get_settings] = lambda: settings
    monkeypatch.setattr(main, "metrics", proxy_metrics)
    monkeypatch.setattr(main.httpx, "AsyncClient", FakeAsyncClient)
    FakeAsyncClient.response = httpx.Response(200, json={"result": []})

    try:
        response = TestClient(main.app).post(
            "/qdrant/collections/ws/points/query?limit=3",
            headers={"api-key": "secret", "content-type": "application/json"},
            json={"vector": [0.1, 0.2]},
        )
    finally:
        main.app.dependency_overrides.clear()

    assert response.status_code == 200
    assert FakeAsyncClient.last_request["method"] == "POST"
    assert FakeAsyncClient.last_request["url"] == "http://qdrant.local/collections/ws/points/query"
    assert FakeAsyncClient.last_request["headers"]["api-key"] == "secret"
    assert b'"vector"' in FakeAsyncClient.last_request["content"]
    assert proxy_metrics.snapshot()["summary"]["qdrant_reads"] == 1
    assert proxy_metrics.snapshot()["summary"]["qdrant_writes"] == 0
    event = proxy_metrics.activity_snapshot()["events"][0]
    assert event["operation"] == "read"
    assert event["detail"] == "POST /collections/ws/points/query"


def test_qdrant_proxy_counts_write_errors(monkeypatch):
    proxy_metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)
    settings = Settings(QDRANT_BASE_URL="http://qdrant.local", QDRANT_API_KEY="secret")
    main.app.dependency_overrides[get_settings] = lambda: settings
    monkeypatch.setattr(main, "metrics", proxy_metrics)
    monkeypatch.setattr(main.httpx, "AsyncClient", FakeAsyncClient)
    FakeAsyncClient.response = httpx.Response(500, json={"status": "error"})

    try:
        response = TestClient(main.app).put(
            "/qdrant/collections/ws/points",
            headers={"api-key": "secret"},
            json={"points": []},
        )
    finally:
        main.app.dependency_overrides.clear()

    assert response.status_code == 500
    summary = proxy_metrics.snapshot()["summary"]
    assert summary["qdrant_reads"] == 0
    assert summary["qdrant_writes"] == 1
    assert summary["qdrant_errors"] == 1
    event = proxy_metrics.activity_snapshot()["events"][0]
    assert event["operation"] == "write"
    assert event["error"] is True


def test_qdrant_proxy_rejects_wrong_api_key():
    settings = Settings(QDRANT_BASE_URL="http://qdrant.local", QDRANT_API_KEY="secret")
    main.app.dependency_overrides[get_settings] = lambda: settings

    try:
        response = TestClient(main.app).get(
            "/qdrant/collections",
            headers={"api-key": "wrong"},
        )
    finally:
        main.app.dependency_overrides.clear()

    assert response.status_code == 401
