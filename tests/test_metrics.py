import pytest

from embarsy_api.metrics import (
    EmbarsyMetrics,
    QdrantActivityTotals,
    classify_qdrant_proxy_operation,
    parse_qdrant_activity_totals,
)


def test_metrics_snapshot_tracks_embeddings_and_qdrant_activity():
    metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)

    metrics.record_embeddings(vectors=2, latency_seconds=0.25)
    metrics.record_embeddings(vectors=0, latency_seconds=0.1, error=True)
    metrics.record_qdrant("read")
    metrics.record_qdrant("write")
    metrics.record_qdrant("write", error=True)

    snapshot = metrics.snapshot(scale_seconds=60)
    summary = snapshot["summary"]
    series = snapshot["series"]

    assert summary["embeddings_requests"] == 2
    assert summary["embeddings_vectors"] == 2
    assert summary["embeddings_errors"] == 1
    assert summary["embeddings_latency_ms_avg"] == 175.0
    assert summary["qdrant_reads"] == 1
    assert summary["qdrant_writes"] == 2
    assert summary["qdrant_errors"] == 1
    assert len(series) == 1
    assert series[0]["embeddings_requests"] == 2


def test_metrics_default_retention_covers_7d_monitoring_scale():
    metrics = EmbarsyMetrics()

    assert metrics.max_buckets * metrics.bucket_seconds >= 7 * 24 * 60 * 60


def test_metrics_7d_scale_returns_data_older_than_24h(monkeypatch):
    import embarsy_api.metrics as metrics_module
    from embarsy_api.metrics import MetricsBucket

    now = 1_800_000_000
    monkeypatch.setattr(metrics_module.time, "time", lambda: now)
    metrics = EmbarsyMetrics()  # default retention now covers 7 days

    metrics._buckets.append(MetricsBucket(timestamp=now - 3 * 24 * 60 * 60, qdrant_reads=4))
    metrics._buckets.append(MetricsBucket(timestamp=now, qdrant_reads=1))

    within_24h = metrics.snapshot(scale_seconds=24 * 60 * 60)["series"]
    within_7d = metrics.snapshot(scale_seconds=7 * 24 * 60 * 60)["series"]

    assert len(within_24h) == 1  # only the "now" bucket falls in the 24h window
    assert len(within_7d) == 2   # the 3-days-ago bucket is visible only at 7d


def test_metrics_snapshot_downsamples_to_max_points(monkeypatch):
    import embarsy_api.metrics as metrics_module
    from embarsy_api.metrics import MetricsBucket

    now = 1_800_000_000
    monkeypatch.setattr(metrics_module.time, "time", lambda: now)
    metrics = EmbarsyMetrics()

    # 2000 dense 5s buckets; each: 2 requests, 20ms total latency (=> 10ms/request avg).
    for i in range(2000):
        metrics._buckets.append(MetricsBucket(
            timestamp=now - (2000 - i) * 5,
            qdrant_reads=1,
            embeddings_requests=2,
            embeddings_latency_ms_total=20.0,
        ))

    full = metrics.snapshot(scale_seconds=7 * 24 * 60 * 60)["series"]
    capped = metrics.snapshot(scale_seconds=7 * 24 * 60 * 60, max_points=200)["series"]

    assert len(full) == 2000          # no cap => full resolution
    assert len(capped) <= 201         # budget respected (allow one boundary group)
    assert sum(p["qdrant_reads"] for p in capped) == 2000          # counts summed, nothing lost
    assert all(p["embeddings_latency_ms_avg"] == 10.0 for p in capped)  # weighted avg preserved


def test_activity_snapshot_tracks_embedding_and_qdrant_events_newest_first():
    metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)

    metrics.record_embedding_request(
        inputs=["first indexed chunk", "second indexed chunk"],
        model="qwen3-embedding",
    )
    metrics.record_qdrant("write", method="PUT", path="/collections/ws/points")
    metrics.record_qdrant("read", method="POST", path="/collections/ws/points/query")

    events = metrics.activity_snapshot()["events"]

    assert [event["operation"] for event in events] == ["read", "write", "embedding"]
    assert events[2]["count"] == 2
    assert "first indexed chunk" in events[2]["detail"]
    assert events[1]["detail"] == "PUT /collections/ws/points"


def test_activity_snapshot_limit_is_bounded():
    metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10, max_activity_events=3)

    for index in range(5):
        metrics.record_embedding_request(inputs=[f"chunk {index}"], model="qwen3-embedding")

    events = metrics.activity_snapshot(limit=2)["events"]

    assert len(events) == 2
    assert events[0]["detail"].endswith("chunk 4")
    assert events[1]["detail"].endswith("chunk 3")


def test_activity_snapshot_keeps_last_24_hours_and_excludes_older_events(monkeypatch):
    import embarsy_api.metrics as metrics_module

    now = 1_800_000_000
    metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)

    monkeypatch.setattr(metrics_module.time, "time", lambda: now - 25 * 60 * 60)
    metrics.record_embedding_request(inputs=["old indexed chunk"], model="qwen3-embedding")

    monkeypatch.setattr(metrics_module.time, "time", lambda: now - 23 * 60 * 60)
    metrics.record_qdrant("write", method="PUT", path="/collections/ws/points")

    monkeypatch.setattr(metrics_module.time, "time", lambda: now)
    metrics.record_qdrant("read", method="POST", path="/collections/ws/points/query")

    events = metrics.activity_snapshot(limit=10, since_seconds=24 * 60 * 60)["events"]

    assert [event["operation"] for event in events] == ["read", "write"]
    assert all("old indexed chunk" not in event["detail"] for event in events)


def test_activity_default_retention_supports_busy_24h_request_activity():
    metrics = EmbarsyMetrics()

    assert metrics._activity_events.maxlen >= 24 * 60 * 60 // metrics.bucket_seconds


def test_qdrant_prometheus_metrics_are_parsed_as_activity_totals():
    totals = parse_qdrant_activity_totals(
        '\n'.join(
            [
                'rest_responses_total{method="PUT",'
                'endpoint="/collections/{collection_name}/points",status="200"} 25',
                'rest_responses_total{method="POST",'
                'endpoint="/collections/{collection_name}/points",status="200"} 1',
                'rest_responses_total{method="POST",'
                'endpoint="/collections/{collection_name}/points/query",status="200"} 3',
                'rest_responses_total{method="POST",'
                'endpoint="/collections/{collection_name}/points/query",status="500"} 2',
                'rest_responses_total{method="PUT",'
                'endpoint="/collections/{collection_name}/index",status="200"} 30',
            ]
        )
    )

    assert totals == QdrantActivityTotals(reads=5, writes=26, errors=2)


def test_qdrant_prometheus_metrics_parse_qdrant_1_18_response_counter_name():
    totals = parse_qdrant_activity_totals(
        '\n'.join(
            [
                'responses_total{method="PUT",'
                'endpoint="/collections/{collection_name}/points",status="200"} 11',
                'responses_total{method="POST",'
                'endpoint="/collections/{collection_name}/points/search",status="200"} 7',
                'responses_total{method="POST",'
                'endpoint="/collections/{collection_name}/points/count",status="500"} 1',
            ]
        )
    )

    assert totals == QdrantActivityTotals(reads=8, writes=11, errors=1)


def test_observed_qdrant_totals_update_summary_and_bucket_deltas():
    metrics = EmbarsyMetrics(bucket_seconds=5, max_buckets=10)

    metrics.observe_qdrant_totals(QdrantActivityTotals(reads=3, writes=26, errors=0))
    metrics.observe_qdrant_totals(QdrantActivityTotals(reads=5, writes=30, errors=1))

    snapshot = metrics.snapshot(scale_seconds=60)
    summary = snapshot["summary"]
    series = snapshot["series"]

    assert summary["qdrant_reads"] == 5
    assert summary["qdrant_writes"] == 30
    assert summary["qdrant_errors"] == 1
    assert sum(point["qdrant_reads"] for point in series) == 5
    assert sum(point["qdrant_writes"] for point in series) == 30
    assert sum(point["qdrant_errors"] for point in series) == 1


@pytest.mark.parametrize(
    ("method", "path", "expected_operation"),
    [
        ("GET", "/collections", "read"),
        ("GET", "/collections/ws/points/point-id", "read"),
        ("POST", "/collections/ws/points/query", "read"),
        ("POST", "/collections/ws/points/search", "read"),
        ("POST", "/collections/ws/points/scroll", "read"),
        ("POST", "/collections/ws/points/count", "read"),
        ("PUT", "/collections/ws/points", "write"),
        ("POST", "/collections/ws/points", "write"),
        ("DELETE", "/collections/ws/points/delete", "write"),
        ("PUT", "/collections/ws", "write"),
        ("POST", "/cluster/recover", None),
    ],
)
def test_qdrant_proxy_operation_classifier(method, path, expected_operation):
    assert classify_qdrant_proxy_operation(method, path) == expected_operation
