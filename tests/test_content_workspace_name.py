"""Tests for the project name the Content table shows in "What seems indexed".

The name is what users actually scan the column for — a collection id (`ws-9b30e…`)
tells them nothing about which service they are looking at.
"""

from embarsy_api.main import (
    build_content_collection_row,
    workspace_folder_path,
    indexed_content_summary,
    workspace_display_name,
)


def _samples(paths):
    return [{"payload": {"filePath": path, "codeChunk": "x"}} for path in paths]


def test_absolute_cache_paths_and_relative_payloads_still_resolve_a_name():
    """The regression that left every Roo-indexed collection nameless.

    Cache paths are absolute, payload paths are workspace-relative; concatenating them
    and taking a common prefix always yields "", because the very first segment differs
    ("" from the leading slash vs "src").
    """
    relative = ["src/Maxposter/Bundle/BriefBundle/Handler/GetToggleHandler.php"]
    cache = [
        "/Users/me/WORKSPACE/TECH/Autohub/service-autohub-monolith/src/Maxposter/Bundle/BriefBundle/Handler/GetToggleHandler.php",
        "/Users/me/WORKSPACE/TECH/Autohub/service-autohub-monolith/src/Maxposter/AppBundle/DB2Entity/DromCatalogModel.php",
    ]

    assert workspace_display_name("ws-9b30e5956638fd4a", relative, [], cache_paths=cache) == "service-autohub-monolith"
    # ...and the old mixed-list call site is what used to break it.
    assert workspace_display_name("ws-9b30e5956638fd4a", relative + cache, []) == ""


def test_nested_layout_resolves_to_the_project_not_the_first_container():
    """`/…/WORKSPACE/TECH/Autohub/service-x` must not answer "TECH"."""
    cache = ["/Users/me/WORKSPACE/TECH/Automation/team-x-alerts-reader/src/index.ts"]
    assert workspace_display_name("ws-1", ["src/index.ts"], [], cache_paths=cache) == "team-x-alerts-reader"


def test_nested_match_never_outranks_the_real_root():
    """A short sample (`README.md`) matches the README of some deep subpackage too.

    Taking the first such match makes the row lead with that subpackage's name — worse
    than showing nothing, because the true name is then demoted to a "key area". Only
    ancestors of the cache's own common prefix may win, which rules the nested one out.
    """
    root = "/Users/me/WORKSPACE/Autohub/service-autohub-monolith"
    cache = [
        f"{root}/README.md",
        f"{root}/app/DoctrineMigrationsHeavy/README.md",
        f"{root}/app/autoload.php",
        f"{root}/src/Maxposter/AppBundle/Entity/Car.php",
    ]
    # README.md first is the order that used to lose.
    samples = ["README.md", "src/Maxposter/AppBundle/Entity/Car.php", "app/autoload.php"]
    assert workspace_display_name("ws-9b30e5956638fd4a", samples, [], cache_paths=cache) == "service-autohub-monolith"
    # Order must not decide the answer.
    assert workspace_display_name("ws-9b30e5956638fd4a", samples[::-1], [], cache_paths=cache) == "service-autohub-monolith"


def test_pathless_payloads_fall_back_to_the_deepest_shared_directory():
    cache = ["/Users/me/tools/billing-api/main.go", "/Users/me/tools/billing-api/util.go"]
    assert workspace_display_name("ws-2", [], [], cache_paths=cache) == "billing-api"


def test_a_container_directory_is_never_announced_as_the_project():
    """Nothing corroborates the fallback root, so a `src` there is a folder pretending to
    be a service. Withheld for the same reason the relative branch refuses to say `rpc`."""
    cache = ["/Users/me/code/billing-api/src/a.py", "/Users/me/code/billing-api/src/b.py"]
    assert workspace_display_name("ws-2", [], [], cache_paths=cache) == ""


def test_a_dot_in_the_project_directory_name_does_not_hand_back_its_parent():
    """The root is found by walking UP from the deepest shared directory, so a root
    mistaken for a file name is lost for good — and `example.com` looks exactly like one."""
    for project in ("example.com", ".agents", "foo.github.io"):
        root = f"/Users/me/projects/{project}"
        cache = [f"{root}/src/a.js", f"{root}/src/b.js", f"{root}/README.md"]
        assert workspace_display_name("ws-5", ["src/a.js"], [], cache_paths=cache) == project


def test_dot_segments_in_a_relative_path_still_match():
    """`./src/a.php` never equals a stored path verbatim; unresolved it would silently
    demote the answer to the fallback and name the project `src`."""
    cache = ["/Users/me/proj/src/a.php", "/Users/me/proj/src/b.php"]
    for sample in ("./src/a.php", "src/../src/a.php", "src/a.php"):
        assert workspace_display_name("ws-6", [sample], [], cache_paths=cache) == "proj"


def test_stated_payload_name_is_taken_verbatim_not_cut_at_a_container():
    """A name the indexer wrote down is evidence, not a path to be parsed."""
    for stated, expected in [("monorepo/apps/web", "web"), ("acme/app", "app"), ("app", "app"), ("apps", "apps")]:
        payloads = [{"file_path": "src/a.py", "project": stated}]
        assert workspace_display_name("ws-3", ["src/a.py"], payloads) == expected


def test_a_stated_container_name_falls_through_instead_of_suppressing_the_paths():
    """An indexer aimed straight at a `src` folder reports "src". That must neither be
    announced as the project nor block the cache paths from answering."""
    payloads = [{"file_path": "core/a.py", "workspace": "src"}]
    cache = ["/Users/me/code/billing-api/core/a.py", "/Users/me/code/billing-api/README.md"]
    assert workspace_display_name("ws-7", ["core/a.py"], payloads, cache_paths=cache) == "billing-api"
    # ...and with nothing else to go on, no name at all rather than "src".
    assert workspace_display_name("ws-7", [], payloads) == ""


def test_container_segments_match_regardless_of_case():
    """Swift `Sources` and Go `internal` are the same kind of directory as `src`."""
    for path in ("proj/Tests/a.go", "proj/Sources/A.swift", "proj/Src/a.c"):
        assert workspace_display_name("ws-4", [path], []) == "proj"


def test_relative_only_root_is_cut_at_the_first_source_container():
    """Without a cache the common root overshoots downward; the deepest shared directory
    names a layer ("schema"), never the project."""
    paths = [
        "Autohub/autohub-api-system-tests/internal/generated/api/schema/a/dto.go",
        "Autohub/autohub-api-system-tests/internal/generated/api/schema/b/dto.go",
    ]
    assert workspace_display_name("tech", paths, []) == "autohub-api-system-tests"


def test_relative_root_entirely_inside_a_container_yields_no_name():
    """Better to show nothing than to name a service "internal"."""
    paths = ["internal/rpc/a/handler.go", "internal/rpc/b/handler.go"]
    assert workspace_display_name("ws-3", paths, []) == ""


def test_explicit_payload_name_outranks_every_path_heuristic():
    payloads = [{"file_path": "src/a.py", "workspace": "/Users/me/code/billing-api"}]
    cache = ["/Users/me/code/something-else/src/a.py"]
    assert workspace_display_name("ws-4", ["src/a.py"], payloads, cache_paths=cache) == "billing-api"


def test_resolved_name_opens_the_summary_and_is_not_repeated_as_a_key_area():
    paths = ["service-autohub-call/internal/rpc/handler.go", "service-autohub-call/internal/model/call.go"]
    summary = indexed_content_summary("service-autohub-call", paths, [], points_count=19921)

    assert summary.startswith("service-autohub-call — looks like ")
    areas = summary.split("Key area", 1)[1] if "Key area" in summary else ""
    assert "service-autohub-call" not in areas, summary


def test_row_display_name_prefers_the_workspace_over_the_collection_id():
    cache = ["/Users/me/projects/service-autohub-call/internal/rpc/handler.go"]
    row = build_content_collection_row(
        "ws-ffeca201eeccc3a4",
        {"points_count": 19921},
        _samples(["internal/rpc/handler.go"]),
        cache_paths=cache,
    )
    assert row["display_name"] == "service-autohub-call"
    assert "ws-ffeca201eeccc3a4" not in str(row["indexed_summary"])


def test_nameless_collection_keeps_the_id_fallback_and_omits_the_name_from_prose():
    """A multi-project workspace root has no single honest name — the prose must simply
    start with "Looks like", never with an echoed collection id."""
    row = build_content_collection_row(
        "cc-automation",
        {"points_count": 19921},
        _samples(["projA/internal/a.go", "projB/src/b.ts"]),
    )
    assert row["display_name"] == "cc-automation collection"
    assert str(row["indexed_summary"]).startswith("Looks like ")


# ── the folder behind the name (Finder link) ──────────────────────────────────

def test_folder_path_comes_from_the_cache_root():
    cache = ["/Users/me/projects/billing-api/src/a.py", "/Users/me/projects/billing-api/README.md"]
    assert workspace_folder_path(["src/a.py"], [], cache_paths=cache) == "/Users/me/projects/billing-api"


def test_folder_path_prefers_what_the_indexer_stored():
    payloads = [{"file_path": "src/a.py", "workspace_path": "/Users/me/code/billing-api"}]
    cache = ["/Users/me/elsewhere/other/src/a.py"]
    assert workspace_folder_path(["src/a.py"], payloads, cache_paths=cache) == "/Users/me/code/billing-api"


def test_a_name_without_a_folder_yields_no_path():
    """`workspace_display_name` can name a project from relative paths alone; a LINK must
    not be invented from the same guess — there is no such folder to open."""
    paths = ["Autohub/autohub-api-system-tests/internal/generated/api/schema/a/dto.go",
             "Autohub/autohub-api-system-tests/internal/generated/api/schema/b/dto.go"]
    assert workspace_display_name("tech", paths, []) == "autohub-api-system-tests"
    assert workspace_folder_path(paths, []) == ""


def test_a_relative_stated_path_is_refused():
    """Only an absolute path can be revealed; a relative one would open whatever the app's
    working directory happens to be."""
    payloads = [{"file_path": "a.py", "workspace_path": "code/billing-api"}]
    assert workspace_folder_path(["a.py"], payloads) == ""


def test_row_carries_the_folder_for_the_app_to_reveal():
    cache = ["/Users/me/projects/service-autohub-call/internal/rpc/handler.go"]
    row = build_content_collection_row(
        "ws-ffeca201eeccc3a4",
        {"points_count": 19921},
        [{"payload": {"filePath": "internal/rpc/handler.go"}}],
        cache_paths=cache,
    )
    assert row["workspace_path"] == "/Users/me/projects/service-autohub-call"
    # The name the link is labelled with must be the folder it opens.
    assert row["display_name"] == "service-autohub-call"
    assert str(row["workspace_path"]).rsplit("/", 1)[-1] == row["display_name"]
