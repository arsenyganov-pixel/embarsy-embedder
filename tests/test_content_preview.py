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


# ── "What seems indexed" prose ────────────────────────────────────────────────

from embarsy_api.main import content_preview, indexed_content_summary


def test_summary_reads_like_a_sentence_without_collection_ids():
    paths = ["app/Kernel.php", "app/Controller/UserController.php", "docs/README.md", "config/services.toml"]
    summary = indexed_content_summary("", paths, [{"file_path": p} for p in paths], 352_662)

    assert summary.startswith("Looks like a PHP project: 4 files")
    # Languages ordered by frequency: PHP (2) before Markdown/TOML (1 each).
    assert "mostly PHP" in summary
    assert "Key area" in summary
    assert "ws-" not in summary and "collection" not in summary


def test_summary_prefixes_resolved_workspace_name():
    paths = ["backend/main.go", "backend/api/router.go"]
    summary = indexed_content_summary("autohub", paths, [{"file_path": p} for p in paths], 10)

    assert summary.startswith("autohub — looks like a Go project: 2 files")


def test_summary_docs_only_workspace():
    paths = ["notes/a.md", "notes/b.md", "data/config.json"]
    summary = indexed_content_summary("", paths, [{"file_path": p} for p in paths], 5)

    assert summary.startswith("Looks like a docs & config workspace: 3 files, mostly Markdown and JSON")


def test_summary_without_file_metadata():
    summary = indexed_content_summary("", [], [{"text": "raw chunk body"}], 249)
    assert summary == "249 indexed text snippets — the sampled ones carry no file names. Sample: raw chunk body."

    bare = indexed_content_summary("", [], [], 1)
    assert bare == "1 point — the sampled payload has no readable file metadata."

    # A resolved name joins with a colon — never a second em-dash in the same sentence.
    named = indexed_content_summary("myproj", [], [], 3)
    assert named == "myproj: 3 points — the sampled payload has no readable file metadata."
    assert " — 3 points — " not in named


def test_pathless_preview_does_not_duplicate_the_sample():
    payloads = [{"text": "raw chunk body"}]
    summary = indexed_content_summary("", [], payloads, 249)
    preview = content_preview([], payloads, summary)
    assert preview.count("Sample:") == 1


def test_project_flavor_needs_real_dominance():
    # One stray helper script must not relabel a docs repository...
    paths = [f"notes/{i}.md" for i in range(20)] + ["scripts/build.py"]
    summary = indexed_content_summary("", paths, [{"file_path": p} for p in paths], 21)
    assert summary.startswith("Looks like a docs & config workspace")

    # ...and a two-file JS minority must not claim a mostly-HTML website.
    paths = [f"site/p{i}.html" for i in range(9)] + ["site/app.js", "site/init.js"]
    summary = indexed_content_summary("", paths, [{"file_path": p} for p in paths], 11)
    assert summary.startswith("Looks like a website")


def test_previously_unmapped_languages_get_friendly_labels():
    paths = ["src/main.rs", "src/lib.rs", "Cargo.toml"]
    summary = indexed_content_summary("", paths, [{"file_path": p} for p in paths], 3)
    assert summary.startswith("Looks like a Rust project")
    assert "RS" not in summary

    # A dominant language we have no label for stays neutral — never "a XY project".
    paths = ["a/one.zig", "a/two.zig", "b/three.zig"]
    summary = indexed_content_summary("", paths, [{"file_path": p} for p in paths], 3)
    assert summary.startswith("Looks like a code workspace")


def test_preview_extends_summary_without_repeating_names():
    paths = ["app/a.py", "app/b.py"]
    summary = indexed_content_summary("myproj", paths, [{"file_path": p} for p in paths], 2)
    preview = content_preview(paths, [{"file_path": p} for p in paths], summary)

    assert preview.startswith(summary)
    assert "Typical files:" in preview
    # The old builder repeated the display name twice ("... in myproj: ..."); never again.
    assert " in myproj" not in preview
