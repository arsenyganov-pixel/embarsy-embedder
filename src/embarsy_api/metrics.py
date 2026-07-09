from __future__ import annotations

import atexit
import time
import json
from collections import deque
from dataclasses import dataclass, field, replace
from pathlib import Path
from threading import Event, Lock, Thread
from typing import Literal

MetricOperation = Literal["embeddings", "qdrant_read", "qdrant_write"]
QdrantOperation = Literal["read", "write"]
ActivityKind = Literal["embedding", "qdrant"]
ActivityOperation = Literal["embedding", "read", "write"]
DEFAULT_ACTIVITY_WINDOW_SECONDS = 24 * 60 * 60
# Monitoring chart retention. The longest Monitoring scale is 7 days; at 5s buckets
# that is 7*24*3600/5 = 120_960 buckets.
DEFAULT_METRICS_WINDOW_SECONDS = 7 * 24 * 60 * 60
# Cap on points returned to the Monitoring chart. A dense 7-day window is ~120k 5s
# buckets; downsampling to this many coarser buckets keeps the JSON payload, decode
# and chart render cheap while preserving the shape of each series.
DEFAULT_MAX_CHART_POINTS = 500


@dataclass
class MetricsBucket:
    timestamp: int
    embeddings_requests: int = 0
    embeddings_vectors: int = 0
    embeddings_errors: int = 0
    embeddings_latency_ms_total: float = 0.0
    qdrant_reads: int = 0
    qdrant_writes: int = 0
    qdrant_errors: int = 0

    @property
    def embeddings_latency_ms_avg(self) -> float:
        if self.embeddings_requests == 0:
            return 0.0
        return self.embeddings_latency_ms_total / self.embeddings_requests

    def as_dict(self) -> dict[str, float | int]:
        return {
            "timestamp": self.timestamp,
            "embeddings_requests": self.embeddings_requests,
            "embeddings_vectors": self.embeddings_vectors,
            "embeddings_errors": self.embeddings_errors,
            "embeddings_latency_ms_avg": round(self.embeddings_latency_ms_avg, 2),
            "qdrant_reads": self.qdrant_reads,
            "qdrant_writes": self.qdrant_writes,
            "qdrant_errors": self.qdrant_errors,
        }


@dataclass
class MetricsSummary:
    embeddings_requests: int = 0
    embeddings_vectors: int = 0
    embeddings_errors: int = 0
    embeddings_latency_ms_total: float = 0.0
    qdrant_reads: int = 0
    qdrant_writes: int = 0
    qdrant_errors: int = 0
    started_at: int = field(default_factory=lambda: int(time.time()))

    @property
    def embeddings_latency_ms_avg(self) -> float:
        if self.embeddings_requests == 0:
            return 0.0
        return self.embeddings_latency_ms_total / self.embeddings_requests

    def as_dict(self) -> dict[str, float | int]:
        return {
            "started_at": self.started_at,
            "embeddings_requests": self.embeddings_requests,
            "embeddings_vectors": self.embeddings_vectors,
            "embeddings_errors": self.embeddings_errors,
            "embeddings_latency_ms_avg": round(self.embeddings_latency_ms_avg, 2),
            "qdrant_reads": self.qdrant_reads,
            "qdrant_writes": self.qdrant_writes,
            "qdrant_errors": self.qdrant_errors,
        }


@dataclass(frozen=True)
class QdrantActivityTotals:
    reads: int = 0
    writes: int = 0
    errors: int = 0


@dataclass(frozen=True)
class ActivityEvent:
    id: int
    timestamp: int
    kind: ActivityKind
    operation: ActivityOperation
    title: str
    detail: str
    count: int = 1
    error: bool = False

    def as_dict(self) -> dict[str, bool | int | str]:
        return {
            "id": self.id,
            "timestamp": self.timestamp,
            "kind": self.kind,
            "operation": self.operation,
            "title": self.title,
            "detail": self.detail,
            "count": self.count,
            "error": self.error,
        }


@dataclass(frozen=True)
class MetricsState:
    summary: MetricsSummary
    buckets: list[MetricsBucket]
    activity_events: list[ActivityEvent]
    last_observed_qdrant_totals: QdrantActivityTotals | None
    next_activity_id: int


class EmbarsyMetrics:
    def __init__(
        self,
        bucket_seconds: int = 5,
        max_buckets: int | None = None,
        max_activity_events: int | None = None,
        state_file: Path | str | None = None,
        persist_min_interval: float = 30.0,
    ) -> None:
        self.bucket_seconds = bucket_seconds
        if max_buckets is None:
            max_buckets = DEFAULT_METRICS_WINDOW_SECONDS // bucket_seconds
        self.max_buckets = max_buckets
        if max_activity_events is None:
            max_activity_events = DEFAULT_ACTIVITY_WINDOW_SECONDS // bucket_seconds
        self._buckets: deque[MetricsBucket] = deque(maxlen=max_buckets)
        self._activity_events: deque[ActivityEvent] = deque(maxlen=max_activity_events)
        self._summary = MetricsSummary()
        self._lock = Lock()
        self._last_observed_qdrant_totals: QdrantActivityTotals | None = None
        self._next_activity_id = 1
        self._state_file = Path(state_file).expanduser() if state_file else None
        # Persistence is decoupled from the request path: record_* methods only set a
        # dirty flag, and a background thread serializes + writes the (multi-MB at 7-day
        # retention) state file at most once per interval — the old write-per-event model
        # rewrote the whole file up to 1x/second, which was the API's single biggest
        # source of disk traffic. The Monitoring endpoint reads in-memory state, so this
        # only affects how fresh the on-disk copy is after a crash; a clean shutdown
        # flushes via atexit.
        self._persist_min_interval = max(0.5, persist_min_interval)
        self._dirty = False
        self._flush_stop = Event()
        # Serializes the serialize+write section of flush(): the flusher thread, atexit,
        # and the FastAPI shutdown hook may all call flush() concurrently, and unserialized
        # writers sharing one .tmp path could atomically install torn JSON.
        self._flush_io_lock = Lock()
        # Identifies this in-memory state incarnation; not persisted, so it changes on
        # every process start. Clients use it to detect id resets (see activity_snapshot).
        self._boot_token = f"{int(time.time() * 1000):x}-{id(self):x}"
        self._load_state()
        if self._state_file is not None:
            Thread(target=self._flush_loop, name="metrics-flush", daemon=True).start()
            atexit.register(self.flush)

    def record_embeddings(
        self,
        *,
        vectors: int,
        latency_seconds: float,
        error: bool = False,
    ) -> None:
        latency_ms = latency_seconds * 1000
        with self._lock:
            bucket = self._current_bucket()
            bucket.embeddings_requests += 1
            bucket.embeddings_vectors += vectors
            bucket.embeddings_latency_ms_total += latency_ms
            self._summary.embeddings_requests += 1
            self._summary.embeddings_vectors += vectors
            self._summary.embeddings_latency_ms_total += latency_ms
            if error:
                bucket.embeddings_errors += 1
                self._summary.embeddings_errors += 1
            self._persist_state_locked()

    def record_embedding_request(
        self,
        *,
        inputs: list[str],
        model: str,
        error: bool = False,
    ) -> None:
        title = f"Embedding request · {len(inputs)} input{'s' if len(inputs) != 1 else ''}"
        detail = _preview_inputs(inputs)
        with self._lock:
            self._append_activity_event(
                kind="embedding",
                operation="embedding",
                title=title,
                detail=f"model={model} · {detail}",
                count=len(inputs),
                error=error,
            )
            self._persist_state_locked()

    def record_qdrant(
        self,
        operation: QdrantOperation,
        *,
        method: str | None = None,
        path: str | None = None,
        error: bool = False,
    ) -> None:
        with self._lock:
            bucket = self._current_bucket()
            if operation == "read":
                bucket.qdrant_reads += 1
                self._summary.qdrant_reads += 1
            else:
                bucket.qdrant_writes += 1
                self._summary.qdrant_writes += 1
            if error:
                bucket.qdrant_errors += 1
                self._summary.qdrant_errors += 1
            if method is not None and path is not None:
                self._append_activity_event(
                    kind="qdrant",
                    operation=operation,
                    title=f"Qdrant {operation}",
                    detail=f"{method.upper()} {_normalize_qdrant_path(path)}",
                    error=error,
                )
            self._persist_state_locked()

    def observe_qdrant_totals(self, totals: QdrantActivityTotals) -> None:
        """Import cumulative counters observed from Qdrant's Prometheus endpoint.

        Roo talks to Qdrant directly, bypassing the Embarsy API process. The API therefore imports
        Qdrant's own cumulative counters on every monitoring refresh and turns them into bucket
        deltas for the chart while keeping the summary equal to Qdrant's current total.
        """
        with self._lock:
            previous = self._last_observed_qdrant_totals
            if previous is None or _qdrant_totals_decreased(previous, totals):
                delta = totals
            else:
                delta = QdrantActivityTotals(
                    reads=totals.reads - previous.reads,
                    writes=totals.writes - previous.writes,
                    errors=totals.errors - previous.errors,
                )

            # Idle Monitoring polls observe the same totals over and over. Still create
            # the current bucket — the chart relies on explicit zero buckets to draw a
            # flat zero line through idle periods — but skip the no-op bookkeeping and
            # don't mark state dirty for the persister. (Skip ONLY on exact equality:
            # a Qdrant restart that resets counters to the same-looking zeros must
            # still fall through and update the observed baseline.)
            if previous is not None and totals == previous:
                self._current_bucket()
                return

            if self._state_file is None:
                self._summary.qdrant_reads = totals.reads
                self._summary.qdrant_writes = totals.writes
                self._summary.qdrant_errors = totals.errors
            else:
                self._summary.qdrant_reads += delta.reads
                self._summary.qdrant_writes += delta.writes
                self._summary.qdrant_errors += delta.errors
            self._last_observed_qdrant_totals = totals

            bucket = self._current_bucket()
            bucket.qdrant_reads += delta.reads
            bucket.qdrant_writes += delta.writes
            bucket.qdrant_errors += delta.errors
            self._persist_state_locked()

    def snapshot(
        self,
        *,
        scale_seconds: int | None = None,
        max_points: int | None = None,
    ) -> dict[str, object]:
        now = int(time.time())
        since = None if scale_seconds is None else now - scale_seconds
        with self._lock:
            buckets = [
                bucket
                for bucket in self._buckets
                if since is None or bucket.timestamp >= since
            ]
            if max_points is not None:
                buckets = _downsample_buckets(buckets, max_points, self.bucket_seconds)
            return {
                "now": now,
                "bucket_seconds": self.bucket_seconds,
                "summary": self._summary.as_dict(),
                "series": [bucket.as_dict() for bucket in buckets],
            }

    def activity_snapshot(
        self,
        *,
        limit: int = 80,
        since_seconds: int | None = None,
        since_id: int | None = None,
    ) -> dict[str, object]:
        """Recent activity, newest first.

        `since_id` makes the poll incremental: only events newer than the given id are
        returned, so a steady 2s UI poll moves ~zero bytes when nothing happened.
        `latest_id` lets the client detect an id reset (fresh state) and re-fetch fully.
        """
        bounded_limit = max(1, min(limit, self._activity_events.maxlen or limit))
        now = int(time.time())
        since = None if since_seconds is None else now - max(1, since_seconds)
        with self._lock:
            events = [
                event
                for event in self._activity_events
                if (since is None or event.timestamp >= since)
                and (since_id is None or event.id > since_id)
            ][-bounded_limit:]
            events.reverse()
            latest_id = self._activity_events[-1].id if self._activity_events else 0
            return {
                "now": now,
                # Changes on every API process start; a client holding a since_id from a
                # previous incarnation must drop it and re-fetch fully (ids may have been
                # re-minted after a state wipe).
                "boot_id": self._boot_token,
                "latest_id": latest_id,
                "events": [event.as_dict() for event in events],
            }

    def _current_bucket(self) -> MetricsBucket:
        timestamp = int(time.time() // self.bucket_seconds * self.bucket_seconds)
        if not self._buckets or self._buckets[-1].timestamp != timestamp:
            self._buckets.append(MetricsBucket(timestamp=timestamp))
        return self._buckets[-1]

    def _append_activity_event(
        self,
        *,
        kind: ActivityKind,
        operation: ActivityOperation,
        title: str,
        detail: str,
        count: int = 1,
        error: bool = False,
    ) -> None:
        self._activity_events.append(ActivityEvent(
            id=self._next_activity_id,
            timestamp=int(time.time()),
            kind=kind,
            operation=operation,
            title=title,
            detail=detail,
            count=count,
            error=error,
        ))
        self._next_activity_id += 1

    def _load_state(self) -> None:
        if self._state_file is None or not self._state_file.exists():
            return
        try:
            raw = json.loads(self._state_file.read_text(encoding="utf-8"))
            state = _decode_metrics_state(raw)
        except (OSError, json.JSONDecodeError, TypeError, ValueError):
            return

        self._summary = state.summary
        self._buckets.clear()
        self._buckets.extend(state.buckets[-self.max_buckets:])
        self._activity_events.clear()
        max_events = self._activity_events.maxlen or len(state.activity_events)
        self._activity_events.extend(state.activity_events[-max_events:])
        self._last_observed_qdrant_totals = state.last_observed_qdrant_totals
        self._next_activity_id = max(state.next_activity_id, 1)

    def _persist_state_locked(self) -> None:
        """Mark state dirty; the background flusher does the actual (expensive) write."""
        self._dirty = True

    def _flush_loop(self) -> None:
        while not self._flush_stop.wait(self._persist_min_interval):
            self.flush()

    def flush(self) -> None:
        """Serialize + write the state file if anything changed since the last flush.

        Only cheap copies happen under the lock (the deques hold references; older
        buckets never mutate once a newer bucket exists, and the possibly-live last
        bucket and summary are copied) — JSON encoding and the disk write run outside
        it, off the request path.
        """
        if self._state_file is None:
            return
        with self._flush_io_lock:
            self._flush_locked_io()

    def _flush_locked_io(self) -> None:
        with self._lock:
            if not self._dirty:
                return
            self._dirty = False
            buckets = list(self._buckets)
            if buckets:
                buckets[-1] = replace(buckets[-1])  # the only bucket that can still mutate
            summary = replace(self._summary)
            events = list(self._activity_events)
            totals = self._last_observed_qdrant_totals
            next_activity_id = self._next_activity_id

        try:
            self._state_file.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                "bucket_seconds": self.bucket_seconds,
                "summary": summary.as_dict(),
                "summary_latency_ms_total": summary.embeddings_latency_ms_total,
                "buckets": [
                    {
                        **bucket.as_dict(),
                        "embeddings_latency_ms_total": bucket.embeddings_latency_ms_total,
                    }
                    for bucket in buckets
                ],
                "activity_events": [event.as_dict() for event in events],
                "last_observed_qdrant_totals": _qdrant_totals_as_dict(totals),
                "next_activity_id": next_activity_id,
            }
            tmp_file = self._state_file.with_suffix(f"{self._state_file.suffix}.tmp")
            tmp_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
            tmp_file.replace(self._state_file)
        except (OSError, ValueError):
            # ValueError covers UnicodeEncodeError (ill-formed text that slipped past
            # ingress sanitization): a raise here would silently kill the daemon
            # flusher thread and stop persistence for the rest of the process.
            with self._lock:
                self._dirty = True  # retry on the next flush tick
            return


def _decode_metrics_state(raw: dict[str, object]) -> MetricsState:
    summary_raw = _dict(raw.get("summary"))
    summary = MetricsSummary(
        embeddings_requests=_int(summary_raw.get("embeddings_requests")),
        embeddings_vectors=_int(summary_raw.get("embeddings_vectors")),
        embeddings_errors=_int(summary_raw.get("embeddings_errors")),
        embeddings_latency_ms_total=_float(raw.get("summary_latency_ms_total")),
        qdrant_reads=_int(summary_raw.get("qdrant_reads")),
        qdrant_writes=_int(summary_raw.get("qdrant_writes")),
        qdrant_errors=_int(summary_raw.get("qdrant_errors")),
        started_at=_int(summary_raw.get("started_at")),
    )

    buckets = [
        MetricsBucket(
            timestamp=_int(bucket_raw.get("timestamp")),
            embeddings_requests=_int(bucket_raw.get("embeddings_requests")),
            embeddings_vectors=_int(bucket_raw.get("embeddings_vectors")),
            embeddings_errors=_int(bucket_raw.get("embeddings_errors")),
            embeddings_latency_ms_total=_float(bucket_raw.get("embeddings_latency_ms_total")),
            qdrant_reads=_int(bucket_raw.get("qdrant_reads")),
            qdrant_writes=_int(bucket_raw.get("qdrant_writes")),
            qdrant_errors=_int(bucket_raw.get("qdrant_errors")),
        )
        for bucket_raw in [_dict(value) for value in _list(raw.get("buckets"))]
    ]

    events = [
        ActivityEvent(
            id=_int(event_raw.get("id")),
            timestamp=_int(event_raw.get("timestamp")),
            kind=_literal(event_raw.get("kind"), {"embedding", "qdrant"}, "embedding"),
            operation=_literal(event_raw.get("operation"), {"embedding", "read", "write"}, "embedding"),
            title=_str(event_raw.get("title")),
            detail=_str(event_raw.get("detail")),
            count=_int(event_raw.get("count"), default=1),
            error=bool(event_raw.get("error")),
        )
        for event_raw in [_dict(value) for value in _list(raw.get("activity_events"))]
    ]

    qdrant_totals_raw = raw.get("last_observed_qdrant_totals")
    qdrant_totals = None
    if isinstance(qdrant_totals_raw, dict):
        qdrant_totals = QdrantActivityTotals(
            reads=_int(qdrant_totals_raw.get("reads")),
            writes=_int(qdrant_totals_raw.get("writes")),
            errors=_int(qdrant_totals_raw.get("errors")),
        )

    return MetricsState(
        summary=summary,
        buckets=buckets,
        activity_events=events,
        last_observed_qdrant_totals=qdrant_totals,
        next_activity_id=_int(raw.get("next_activity_id"), default=len(events) + 1),
    )


def _downsample_buckets(
    buckets: list[MetricsBucket],
    max_points: int,
    base_bucket_seconds: int,
) -> list[MetricsBucket]:
    """Aggregate fine buckets into at most ~max_points coarser buckets for charting.

    Counts are summed; latency stays a request-weighted average because both the
    latency total and the request count are summed and the average is derived from
    them. Input must be time-ordered ascending; output preserves that order.
    """
    if max_points <= 0 or len(buckets) <= max_points:
        return buckets

    span = max(buckets[-1].timestamp - buckets[0].timestamp, base_bucket_seconds)
    # Smallest coarse width (a multiple of the base bucket) that keeps the number of
    # groups within budget: coarse_seconds >= span / max_points.
    unit = max(1, (span + max_points * base_bucket_seconds - 1) // (max_points * base_bucket_seconds))
    coarse_seconds = unit * base_bucket_seconds

    grouped: dict[int, MetricsBucket] = {}
    order: list[int] = []
    for bucket in buckets:
        key = bucket.timestamp // coarse_seconds * coarse_seconds
        aggregate = grouped.get(key)
        if aggregate is None:
            aggregate = MetricsBucket(timestamp=key)
            grouped[key] = aggregate
            order.append(key)
        aggregate.embeddings_requests += bucket.embeddings_requests
        aggregate.embeddings_vectors += bucket.embeddings_vectors
        aggregate.embeddings_errors += bucket.embeddings_errors
        aggregate.embeddings_latency_ms_total += bucket.embeddings_latency_ms_total
        aggregate.qdrant_reads += bucket.qdrant_reads
        aggregate.qdrant_writes += bucket.qdrant_writes
        aggregate.qdrant_errors += bucket.qdrant_errors

    return [grouped[key] for key in order]


def _preview_inputs(inputs: list[str], *, max_items: int = 3, max_chars: int = 220) -> str:
    previews = [_single_line_preview(value, max_chars=max_chars) for value in inputs[:max_items]]
    suffix = "" if len(inputs) <= max_items else f" · +{len(inputs) - max_items} more"
    return " | ".join(previews) + suffix


def _single_line_preview(value: str, *, max_chars: int) -> str:
    compact = " ".join(value.split())
    if len(compact) <= max_chars:
        return compact
    return f"{compact[:max_chars - 1]}…"


def parse_qdrant_activity_totals(prometheus_text: str) -> QdrantActivityTotals:
    reads = 0
    writes = 0
    errors = 0

    for line in prometheus_text.splitlines():
        if not _is_qdrant_response_metric(line):
            continue

        labels_text, _, value_text = line.partition("} ")
        labels = _parse_prometheus_labels(labels_text.partition("{")[2])
        try:
            value = int(float(value_text.strip()))
        except ValueError:
            continue

        method = labels.get("method", "").upper()
        endpoint = labels.get("endpoint", "")
        status = labels.get("status", "")

        is_read = _is_qdrant_read(method, endpoint)
        is_write = _is_qdrant_write(method, endpoint)
        if is_read:
            reads += value
        elif is_write:
            writes += value

        if (is_read or is_write) and status.startswith(("4", "5")):
            errors += value

    return QdrantActivityTotals(reads=reads, writes=writes, errors=errors)


def classify_qdrant_proxy_operation(method: str, path: str) -> QdrantOperation | None:
    """Classify proxied Qdrant HTTP requests for Embarsy Monitoring accounting.

    Qdrant's own Prometheus metric labels are version-dependent, while the local proxy sees
    every Roo request before it reaches Qdrant. This classifier intentionally works with real
    request paths such as `/collections/ws-id/points/query`, not only templated labels.
    """
    normalized_method = method.upper()
    normalized_path = _normalize_qdrant_path(path)

    if normalized_method in {"GET", "HEAD"}:
        return "read"

    if _is_qdrant_read(normalized_method, normalized_path):
        return "read"

    if normalized_method in {"PUT", "POST", "PATCH", "DELETE"} and normalized_path.startswith(
        "/collections"
    ):
        return "write"

    return None


def _parse_prometheus_labels(labels_text: str) -> dict[str, str]:
    labels: dict[str, str] = {}
    for raw_label in labels_text.split(','):
        key, separator, raw_value = raw_label.partition('=')
        if not separator:
            continue
        labels[key] = raw_value.strip().strip('"')
    return labels


def _is_qdrant_response_metric(line: str) -> bool:
    return line.startswith("rest_responses_total{") or line.startswith("responses_total{")


def _is_qdrant_read(method: str, endpoint: str) -> bool:
    read_markers = ("/query", "/search", "/scroll", "/recommend", "/discover", "/count")
    return method in {"GET", "POST"} and "/points" in endpoint and any(
        marker in endpoint for marker in read_markers
    )


def _is_qdrant_write(method: str, endpoint: str) -> bool:
    if _is_qdrant_read(method, endpoint):
        return False
    return method in {"PUT", "POST", "PATCH", "DELETE"} and (
        "/points" in endpoint or endpoint.endswith("/collections/{collection_name}")
    )


def _normalize_qdrant_path(path: str) -> str:
    path_without_query = path.partition("?")[0]
    if not path_without_query.startswith("/"):
        path_without_query = f"/{path_without_query}"
    return path_without_query.rstrip("/") or "/"


def _qdrant_totals_decreased(
    previous: QdrantActivityTotals,
    current: QdrantActivityTotals,
) -> bool:
    return (
        current.reads < previous.reads
        or current.writes < previous.writes
        or current.errors < previous.errors
    )


def _qdrant_totals_as_dict(totals: QdrantActivityTotals | None) -> dict[str, int] | None:
    if totals is None:
        return None
    return {"reads": totals.reads, "writes": totals.writes, "errors": totals.errors}


def _dict(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _list(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def _int(value: object, *, default: int = 0) -> int:
    try:
        return int(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _float(value: object, *, default: float = 0.0) -> float:
    try:
        return float(value)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return default


def _str(value: object) -> str:
    return value if isinstance(value, str) else ""


def _literal(value: object, allowed: set[str], default: str) -> str:
    return value if isinstance(value, str) and value in allowed else default


metrics = EmbarsyMetrics(state_file=Path("metrics-state.json"))
