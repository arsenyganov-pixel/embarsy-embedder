"""grep-vs-semantic benchmark: methodology units + a full endpoint run where the
grep side is REAL (a temp workspace on disk) and Qdrant/embeddings are faked."""

import httpx
import pytest
from fastapi.testclient import TestClient

from embarsy_api import benchmark, main
from embarsy_api.benchmark import (
    concept_query,
    concept_words,
    grep_command,
    parse_grep_counts,
    paths_match,
    rank_of,
)
from embarsy_api.embeddings import EmbeddingService
from embarsy_api.main import app, get_embedding_service


# ── methodology units ────────────────────────────────────────────────────────

def test_concept_words_split_identifiers_and_drop_noise():
    text = """
    def refreshTokenExpiry(session_token, expiry_margin):
        # validate the signature before refresh
        return validateSignature(session_token) and expiry_margin > 0
    """
    words = concept_words(text)
    assert "token" in words and "expiry" in words and "signature" in words
    # keywords/glue never leak into the query
    assert "def" not in words and "return" not in words and "and" not in words
    # camelCase is split — the raw identifier itself is not a "word"
    assert "refreshtokenexpiry" not in words


def test_concept_query_requires_enough_signal():
    assert concept_query("def f(): return 1") is None
    q = concept_query("paymentGateway retryPolicy invoiceLedger reconcileBalance")
    assert q is not None and len(q.split()) >= 4


def test_paths_match_and_rank():
    assert paths_match("/abs/repo/auth/token.py", "auth/token.py")
    assert not paths_match("other/token.py", "auth/token.py")
    assert rank_of("auth/token.py", ["a/b.py", "x/auth/token.py"], top_k=5) == 2
    assert rank_of("auth/token.py", ["a/b.py"], top_k=5) is None


def test_detect_index_root_finds_child_project():
    # Indexer rooted at a CHILD of the chosen workspace: grep must be scoped there.
    lines = ["./embarsy-embedder/src/api/main.py", "./embarsy-embedder/tests/test_x.py"]
    truths = ["src/api/main.py", "tests/test_x.py"]
    assert benchmark.detect_index_root(lines, truths) == "embarsy-embedder"


def test_detect_index_root_keeps_matched_workspace():
    # Index root == workspace: no rescoping.
    assert benchmark.detect_index_root(["./src/api/main.py"], ["src/api/main.py"]) is None
    # No majority between conflicting roots: don't guess.
    lines = ["./a/src/main.py", "./b/src/other.py"]
    assert benchmark.detect_index_root(lines, ["src/main.py", "src/other.py"]) in (None, "a", "b")


def test_and_pipeline_is_reproducible_and_ordered():
    cmd = benchmark.and_pipeline_description(["token", "refresh", "ab"])
    # longest word first shrinks the candidate list fastest
    assert cmd.index("refresh") < cmd.index("token") < cmd.index("-ic -E")
    assert cmd.startswith("grep -ril -I ")


def test_paraphrase_query_swaps_exactly_one_word_deterministically():
    q, swapped = benchmark.paraphrase_query("process wait chunk grep timeout verify")
    # Exactly ONE swap: the first word with a table synonym (process → task). Every
    # other word — including ones that DO have synonyms (wait, chunk) — is left alone,
    # so the question stays anchored to its file.
    assert q == "task wait chunk grep timeout verify"
    assert len(swapped) == 1 and swapped[0] == {"from": "process", "to": "task"}
    # deterministic: same input, same output
    assert benchmark.paraphrase_query("process wait chunk grep timeout verify")[0] == q
    # nothing to swap -> query unchanged, swaps empty
    q2, s2 = benchmark.paraphrase_query("zzz qqq www")
    assert q2 == "zzz qqq www" and s2 == []


def test_synonym_dictionary_is_sound():
    # No word maps to itself (would be a silent no-op swap) and no group repeats a word.
    assert all(w != r for w, r in benchmark._SYNONYM_MAP.items())
    assert all(len(g) == len(set(g)) for g in benchmark._SYNONYM_GROUPS)
    # The expansion is substantial — the whole point of this change.
    assert len(benchmark._SYNONYM_MAP) > 400


def test_benchmark_paraphrase_mode(workspace, monkeypatch):
    FakeEmbedder.calls = 0
    monkeypatch.setattr(main, "_http_client", FakeQdrantClient())
    headers = _override_settings()
    app.dependency_overrides[get_embedding_service] = lambda: FakeEmbedder(
        ollama_base_url="http://x", model="m", keep_alive="30m",
        dimension=4, instruction="i", timeout_seconds=5,
    )
    try:
        response = TestClient(app).post("/benchmark/retrieval", headers=headers, json={
            "collection": "ws-test",
            "workspace_path": str(workspace),
            "samples": 4,
            "top_k": 5,
            "paraphrase": True,
        })
    finally:
        app.dependency_overrides.clear()
    assert response.status_code == 200, response.text
    body = response.json()
    assert body["paraphrased"] is True
    for row in body["queries"]:
        # disclosure fields present; the used query differs exactly when swaps happened
        assert "original_query" in row and "swapped" in row
        if row["swapped"]:
            assert row["query"] != row["original_query"]
            for swap in row["swapped"]:
                assert swap["from"] in row["original_query"].split()
                assert swap["to"] in row["query"].split()
        else:
            assert row["query"] == row["original_query"]


def test_parse_grep_counts_ranks_by_matches():
    out = "./a.py:3\n./deep/b.py:7\n./zero.py:0\nnot-a-count-line\n"
    ranked = parse_grep_counts(out)
    assert ranked == [("deep/b.py", 7), ("a.py", 3)]


def test_grep_command_is_safe_and_excludes_junk():
    cmd = grep_command(["token", "c++weird"])
    assert cmd[0] == "/usr/bin/grep" and cmd[-1] == "."
    assert any("--exclude-dir=node_modules" in c for c in cmd)
    # regex metacharacters from identifiers are escaped
    pattern = cmd[cmd.index("-e") + 1]
    assert "c\\+\\+weird" in pattern


# ── full endpoint run ────────────────────────────────────────────────────────

def _chunk(*lines):
    body = "\n".join(lines)
    return body + "\n# " + "-" * 140  # clear the junk-filter length floor without adding words


FILES = {
    "auth/token_refresh.py": _chunk(
        "def refreshTokenExpiry():",
        "    validateSignature(sessionToken)",
        "    expiryMargin = renewGrace(sessionToken)",
    ),
    "billing/invoice_ledger.py": _chunk(
        "class InvoiceLedger:",
        "    def reconcileBalance(self, paymentGateway):",
        "        retryPolicy(paymentGateway, ledgerSnapshot)",
    ),
    "search/vector_ranker.py": _chunk(
        "def cosineSimilarity(queryVector, documentVector):",
        "    return rankCandidates(queryVector, documentVector)",
    ),
    "net/socket_pool.py": _chunk(
        "class SocketPool:",
        "    def acquireConnection(self, handshakeTimeout):",
        "        backoffJitter(handshakeTimeout, keepaliveProbe)",
    ),
}


class FakeQdrantClient:
    """Routes the two Qdrant POSTs the benchmark makes: random sample + vector search."""

    is_closed = False

    async def post(self, url, headers=None, json=None, timeout=None):
        if json and json.get("query") == {"sample": "random"}:
            points = [{"payload": {"file_path": path, "text": text}} for path, text in FILES.items()]
            return httpx.Response(200, json={"result": {"points": points}},
                                  request=httpx.Request("POST", url))
        # vector search: pretend the index always ranks the right file first —
        # which file is "right" is smuggled through the fake embedding vector.
        idx = int(json["query"][0])
        paths = list(FILES)
        ordered = [paths[idx]] + [p for p in paths if p != paths[idx]]
        points = [{"payload": {"file_path": p, "text": FILES[p]}} for p in ordered]
        return httpx.Response(200, json={"result": {"points": points}},
                              request=httpx.Request("POST", url))


class FakeEmbedder(EmbeddingService):
    calls = 0

    async def embed(self, inputs):
        # Encode "which file this query came from" in the vector's first component,
        # keyed off a distinctive concept word (robust to sampling order shuffles).
        type(self).calls += 1
        markers = ["token", "ledger", "cosine", "handshake"]
        vectors = []
        for text in inputs:
            index = next((i for i, m in enumerate(markers) if m in text), 0)
            vectors.append([float(index)] + [0.0] * 3)
        return vectors


@pytest.fixture()
def workspace(tmp_path):
    for rel, text in FILES.items():
        f = tmp_path / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(text)
    (tmp_path / "node_modules").mkdir()
    (tmp_path / "node_modules" / "junk.js").write_text("token " * 500)
    return tmp_path


def _override_settings():
    from embarsy_api.settings import Settings, get_settings
    settings = Settings(EMBARSY_API_KEY="bench-key")
    app.dependency_overrides[get_settings] = lambda: settings
    return {"Authorization": "Bearer bench-key"}


def test_benchmark_endpoint_end_to_end(workspace, monkeypatch):
    FakeEmbedder.calls = 0
    monkeypatch.setattr(main, "_http_client", FakeQdrantClient())
    headers = _override_settings()
    app.dependency_overrides[get_embedding_service] = lambda: FakeEmbedder(
        ollama_base_url="http://x", model="m", keep_alive="30m",
        dimension=4, instruction="i", timeout_seconds=5,
    )
    try:
        response = TestClient(app).post("/benchmark/retrieval", headers=headers, json={
            "collection": "ws-test",
            "workspace_path": str(workspace),
            "samples": 4,
            "top_k": 5,
        })
    finally:
        app.dependency_overrides.clear()

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["samples"] == 4
    # The fairness gate ran (and the log may claim so) only when this is True.
    assert body["workspace_verified"] is True
    # Fixture files live directly under the workspace — grep scope stays there.
    assert body["grep_root"] == str(workspace)

    semantic = body["summary"]["semantic"]
    grep = body["summary"]["grep"]
    # The faked index always ranks the truth file #1.
    assert semantic["hit_top1"] == 4 and semantic["hit_topk"] == 4
    # REAL grep over the temp workspace: concept words appear in the files, so it
    # must find them too — and junk dirs are excluded from its results.
    assert grep["hit_topk"] >= 3
    assert grep["timeouts"] == 0
    for row in body["queries"]:
        assert row["grep"]["latency_ms"] >= 0
        for path in row["grep"]["top_files"]:
            assert "node_modules" not in path
        # Log-transparency fields: the exact reproducible command, ranked matches
        # with line counts, and the semantic timing/context breakdown. The fixture
        # words co-occur in their truth files, so the competent AND strategy runs.
        assert row["grep"]["strategy"] == "and"
        assert row["grep"]["command"].startswith("grep -ril -I ")
        assert "xargs grep -ic -E" in row["grep"]["command"]
        assert all(m["lines"] > 0 for m in row["grep"]["top_matches"])
        assert [m["path"] for m in row["grep"]["top_matches"]] == row["grep"]["top_files"]
        assert row["semantic"]["embed_ms"] >= 0
        assert row["semantic"]["search_ms"] >= 0
        assert row["semantic"]["snippet_chars"] > 0
        assert row["grep"]["truncated_output"] is False


def test_benchmark_rejects_missing_workspace():
    headers = _override_settings()
    try:
        response = TestClient(app).post("/benchmark/retrieval", headers=headers, json={
            "collection": "ws-test",
            "workspace_path": "/definitely/not/a/real/folder",
        })
    finally:
        app.dependency_overrides.clear()
    assert response.status_code == 400


def test_benchmark_refuses_without_api_key():
    response = TestClient(app).post("/benchmark/retrieval", json={
        "collection": "ws-test", "workspace_path": "/tmp",
    })
    assert response.status_code == 403


def test_benchmark_detects_workspace_collection_mismatch(tmp_path, monkeypatch):
    """The fairness gate: indexed files absent from the chosen folder must fail
    loudly instead of handing the semantic side a fake sweep."""
    FakeEmbedder.calls = 0
    monkeypatch.setattr(main, "_http_client", FakeQdrantClient())
    headers = _override_settings()
    (tmp_path / "unrelated.txt").write_text("nothing from the collection lives here")
    try:
        response = TestClient(app).post("/benchmark/retrieval", headers=headers, json={
            "collection": "ws-test",
            "workspace_path": str(tmp_path),
            "samples": 4,
        })
    finally:
        app.dependency_overrides.clear()
    assert response.status_code == 422
    assert "does not match" in response.json()["detail"]
