"""Tests for the Content "Preview" chip tags emitted by the collections endpoint."""

from embarsy_api.main import build_preview_tags


def _payloads(paths, *, text=None):
    payloads = [{"file_path": p} for p in paths]
    if text is not None:
        payloads.insert(0, {"text": text})
    return payloads


def test_workspace_tags_order_dedup_and_sentinel():
    paths = [
        "webapp/components/Button.tsx",   # -> term "components/Button.tsx" (subsumed by area "components")
        "webapp/components/Modal.tsx",
        "webapp/handoff/spec.json",
        "docs/README.md",
        "Makefile",                       # extensionless -> _language_for_path == "files" (sentinel); term "Makefile" survives
    ]
    tags = build_preview_tags(
        "ws-4fb1ad704f0040ba",
        "ws-4fb1ad704f0040ba collection",
        paths,
        _payloads(paths, text="hello sample body"),
        points_count=10021,
    )
    kinds = [t["kind"] for t in tags]
    labels = [t["label"] for t in tags]

    # Fixed order: count -> lang(s) -> area(s) -> term(s) -> sample, always contiguous groups.
    assert kinds[0] == "count"
    assert kinds[-1] == "sample"
    order = {"count": 0, "lang": 1, "area": 2, "term": 3, "sample": 4}
    assert kinds == sorted(kinds, key=lambda k: order[k]), kinds

    # Count reflects unique file paths, not the vector count.
    assert labels[0] == f"{len(dict.fromkeys(paths))} files"

    # The extensionless "files" sentinel is never a language chip.
    assert "files" not in [t["label"] for t in tags if t["kind"] == "lang"]
    assert "Markdown" in labels and "JSON" in labels and "TypeScript" in labels  # real languages survive

    # The repeated display_name / collection_name never becomes a chip.
    for bogus in ("collection", "ws-4fb1ad704f0040ba", "ws-4fb1ad704f0040ba collection"):
        assert bogus not in labels

    # A term subsumed by an emitted area is dropped; a genuinely new segment survives.
    assert "components/Button.tsx" not in labels           # subsumed by area "components"
    assert "components" in labels                           # the area itself
    assert "Makefile" in [t["label"] for t in tags if t["kind"] == "term"]


def test_sample_chip_carries_full_text_verbatim():
    text = "def f():\n    return 1  # a sample, with: commas. And a period. Sample: trap"
    tags = build_preview_tags("ws-x", "ws-x collection", ["a/b/main.py"], _payloads(["a/b/main.py"], text=text), 3)
    sample = [t for t in tags if t["kind"] == "sample"]
    assert len(sample) == 1
    assert sample[0]["label"] == "Sample"
    # copy is the whitespace-collapsed, 180-char-capped text_preview (never split on its own punctuation).
    assert sample[0]["copy"] == " ".join(text.split())[:180]


def test_extensionless_file_under_dotted_dir_is_not_a_language():
    # A dotted parent directory must not leak into the "extension": my.config/server has no real
    # extension, so it is the "files" sentinel (filtered), never a garbage lang chip like "CONFIG/SERVER".
    paths = ["my.config/server", "dir.d/run", "app/main.py"]
    tags = build_preview_tags("ws-c", "ws-c collection", paths, _payloads(paths), 3)
    langs = [t["label"] for t in tags if t["kind"] == "lang"]
    assert langs == ["Python"]
    assert not any("/" in t["label"] for t in tags if t["kind"] == "lang")


def test_non_workspace_and_empty():
    # No file paths -> point count + optional sample only, never overflowing prose.
    tags = build_preview_tags("ws-y", "ws-y collection", [], [{"text": "raw chunk"}], 1)
    assert [t["kind"] for t in tags] == ["count", "sample"]
    assert tags[0]["label"] == "1 point"

    # No payload text at all -> just the count chip.
    assert build_preview_tags("ws-z", "ws-z collection", [], [], 42) == [{"kind": "count", "label": "42 points"}]
