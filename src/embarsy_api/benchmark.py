"""grep-vs-semantic retrieval benchmark over the user's own indexed code.

Methodology (deliberately honest — the point is to convince, not to cheat):

- Questions are generated from the user's OWN indexed chunks: we sample random
  points from the Qdrant collection and extract each chunk's "concept words" —
  identifiers split by camelCase/snake_case, lowercased, minus language keywords
  and English glue. That approximates how a human asks about code ("validate
  token expiry refresh") without copying any literal string grep could cheat on.
- The GROUND TRUTH for a question is simply the file its chunk came from.
- Both engines get the exact same query. Semantic = embed + Qdrant search.
  Grep = a real `grep -riE` process over the real workspace, ranked the way a
  person (or an agent) triages grep output: files with the most matching lines
  first.
- A "hit" = the truth file appears in the engine's top-K distinct files.

Reported per engine: accuracy (hit@1 / hit@K), median latency to a ranked
answer, and NOISE — how many matching lines grep returns for a human to sift,
versus a fixed handful of ranked snippets from the semantic index. The noise
number is the heart of the RAG-vs-grep story.
"""

from __future__ import annotations

import re
import statistics
import time
from typing import Any, Optional

# Language keywords + English glue that carry no search intent. Deliberately broad:
# a leaked keyword makes grep look better than real life, not worse.
_STOPWORDS = frozenset("""
the and for not with this that from into your our their its are was were will
would can could should has have had been being all any each which what where
when how than then them they there here also just only more most some such
true false null none nil undefined new delete return yield break continue pass
raise throw throws try catch except finally import export package module from
def func function fn class struct enum interface trait impl protocol extension
public private protected internal static final const let var val mut async
await defer guard switch case default else elif type typedef namespace using
void int float double bool string char byte long short unsigned signed self
super init deinit override virtual abstract sealed readonly lazy weak strong
print println console log logger error warning info debug trace assert test
tests testing mock stub fake temp tmp foo bar baz value values item items data
list array dict map set get put post head patch options request response
result results index count length size name names key keys type types file
files path paths line lines code utils util helper helpers common core main
""".split())

_IDENTIFIER = re.compile(r"[A-Za-z][A-Za-z0-9_]{2,}")
_CAMEL_SPLIT = re.compile(r"(?<=[a-z0-9])(?=[A-Z])|(?<=[A-Z])(?=[A-Z][a-z])")


def concept_words(text: str, limit: int = 6) -> list[str]:
    """Distinctive lowercase concept words from a code chunk, frequency-ranked.

    camelCase/snake_case identifiers are split into plain words first, so the
    query reads like human vocabulary ("refresh token expiry") rather than code
    tokens ("refreshTokenExpiry") — the same words a developer would type into
    a search box.
    """
    counts: dict[str, int] = {}
    order: dict[str, int] = {}
    for raw in _IDENTIFIER.findall(text):
        for part in _CAMEL_SPLIT.split(raw.replace("_", " ")):
            for word in part.split():
                w = word.lower()
                if len(w) < 3 or len(w) > 24 or w in _STOPWORDS or w.isdigit():
                    continue
                counts[w] = counts.get(w, 0) + 1
                order.setdefault(w, len(order))
    ranked = sorted(counts, key=lambda w: (-counts[w], -len(w), order[w]))
    return ranked[:limit]


def concept_query(text: str, min_words: int = 4, max_words: int = 6) -> Optional[str]:
    words = concept_words(text, limit=max_words)
    if len(words) < min_words:
        return None
    return " ".join(words)


_JUNK_FILES = re.compile(
    r"(package-lock\.json|yarn\.lock|pnpm-lock\.yaml|Cargo\.lock|\.lock|\.min\.[a-z]+|\.svg|\.map|\.snap)$",
    re.IGNORECASE,
)


def is_benchmarkable(path: str, text: str) -> bool:
    """Skip samples that make silly questions: lockfiles/minified/generated blobs
    and chunks too short to carry intent. Keeps the query set representative of
    what a developer actually asks about."""
    return not _JUNK_FILES.search(path) and len(text) >= 160


def paths_match(candidate: str, truth: str) -> bool:
    """Robust file identity across absolute/relative path spellings.

    When either side carries directory context, at least TWO tail components must
    agree — otherwise a root-level `index.js` would be credited for
    `src/components/index.js` (filename collisions are common in real repos)."""
    a = [p for p in candidate.replace("\\", "/").split("/") if p]
    b = [p for p in truth.replace("\\", "/").split("/") if p]
    if not a or not b:
        return False
    if a[-1] != b[-1]:
        return False
    tail = min(len(a), len(b), 3)
    if tail < 2 and max(len(a), len(b)) >= 2:
        return False
    return a[-tail:] == b[-tail:]


def find_truths_command(truths: list[str]) -> list[str]:
    """One `find` pass that locates every sampled truth file under the workspace.

    This is the benchmark's fairness gate: if the collection was built from a
    different folder (or the index is stale), grep would lose by definition and
    the comparison would be meaningless. Indexers store paths relative to
    arbitrary roots (sometimes a CHILD of the chosen folder), so we match by the
    last two path components — the same identity rule paths_match uses."""
    prune = ["(", "-name", ".git", "-o", "-name", "node_modules", "-o", "-name", ".venv",
             "-o", "-name", "venv", "-o", "-name", "dist", "-o", "-name", "build",
             "-o", "-name", ".build", ")", "-prune", "-o"]
    tests: list[str] = []
    for truth in truths:
        parts = [p for p in truth.replace("\\", "/").split("/") if p]
        if not parts:
            continue
        if tests:
            tests.append("-o")
        if len(parts) >= 2:
            tests += ["-path", "*/" + "/".join(parts[-2:])]
        else:
            tests += ["-name", parts[-1]]
    return ["/usr/bin/find", ".", *prune, "-type", "f", "(", *tests, ")", "-print"]


def detect_index_root(find_lines: list[str], truths: list[str]) -> Optional[str]:
    """Where the indexed tree actually lives under the chosen workspace.

    Indexers store paths relative to THEIR root, which may be a CHILD of the
    workspace the user picked. Grep must race over the same corpus the index
    covers — otherwise it scans N unrelated sibling projects and the duel is
    rigged. For every located truth file, strip the truth's relative path off
    the find hit's tail; the remainder is a root candidate. Majority vote wins;
    None = keep the workspace itself."""
    votes: dict[str, int] = {}
    for truth in truths:
        t_parts = [p for p in truth.replace("\\", "/").split("/") if p]
        if not t_parts:
            continue
        for line in find_lines:
            l_parts = [p for p in line.replace("\\", "/").split("/") if p and p != "."]
            if len(l_parts) >= len(t_parts) and l_parts[-len(t_parts):] == t_parts:
                root = "/".join(l_parts[:-len(t_parts)])
                votes[root] = votes.get(root, 0) + 1
                break
    if not votes:
        return None
    root, count = max(votes.items(), key=lambda kv: kv[1])
    if count * 2 < sum(votes.values()):  # no clear majority — don't guess
        return None
    return root or None


def truths_found(find_output: str, truths: list[str]) -> set[str]:
    """Which of the sampled truth files the find pass located."""
    lines = [line[2:] if line.startswith("./") else line
             for line in find_output.splitlines() if line.strip()]
    return {truth for truth in truths if any(paths_match(line, truth) for line in lines)}


# Synonym groups for the paraphrase mode — genuine, interchangeable developer and
# general-English vocabulary. A word is swapped to the NEXT word in its group
# (cyclic), so the choice is fixed by the table itself: no runtime cherry-picking,
# fully auditable. A word belongs to the FIRST group that lists it (setdefault).
# Words the table doesn't know — code tokens and proper nouns (qdrant, http, json,
# str, isinstance, …) that have no synonym — are left untouched. The swap is applied
# identically to BOTH engines' input, so the choice of synonym cannot rig the duel
# toward either side; a bad synonym would only hurt the semantic index too.
_SYNONYM_GROUPS = [
    # ── verbs: lifecycle & control flow ──
    ["get", "fetch", "retrieve", "obtain"],
    ["set", "assign"],
    ["add", "insert", "append", "attach"],
    ["remove", "delete", "erase", "discard", "drop"],
    ["create", "generate", "produce", "build", "construct", "make"],
    ["update", "modify", "change", "alter", "edit"],
    ["refresh", "renew", "reload"],
    ["start", "launch", "boot", "begin", "initiate"],
    ["initialize", "init", "setup"],
    ["stop", "halt", "shutdown", "end", "finish"],
    ["run", "execute", "invoke", "perform"],
    ["restart", "reboot"],
    ["resume", "continue", "proceed"],
    ["cancel", "abort"],
    ["kill", "terminate"],
    ["pause", "wait", "block"],
    ["sleep", "delay"],
    ["check", "verify", "validate", "confirm", "ensure"],
    ["search", "find", "lookup", "locate"],
    ["watch", "monitor", "observe", "track"],
    ["install", "provision"],
    ["deploy", "release", "ship", "publish"],
    ["send", "dispatch", "emit", "transmit"],
    ["receive", "accept", "consume"],
    ["load", "read"],
    ["save", "persist", "store", "write"],
    ["copy", "duplicate", "clone", "replicate"],
    ["move", "relocate", "transfer"],
    ["sort", "order", "arrange", "rank"],
    ["filter", "select"],
    ["merge", "combine", "join", "unite"],
    ["split", "divide", "partition", "separate"],
    ["convert", "transform", "translate"],
    ["encode", "serialize", "marshal"],
    ["decode", "deserialize", "unmarshal"],
    ["parse", "interpret"],
    ["compress", "shrink"],
    ["expand", "grow", "enlarge"],
    ["open", "unlock"],
    ["close", "shut"],
    ["lock", "secure"],
    ["connect", "link"],
    ["disconnect", "detach"],
    ["register", "enroll"],
    ["resolve", "settle", "determine"],
    ["calculate", "compute", "derive"],
    ["count", "total", "tally"],
    ["measure", "gauge"],
    ["compare", "match"],
    ["handle", "manage"],
    ["schedule", "plan", "queue"],
    ["notify", "alert", "warn"],
    ["request", "query", "call"],
    ["respond", "reply", "answer"],
    ["authenticate", "authorize"],
    ["encrypt", "cipher"],
    ["decrypt", "decipher"],
    ["hash", "digest"],
    ["clear", "reset", "wipe", "purge"],
    ["clean", "sanitize"],
    ["allocate", "reserve"],
    ["acquire", "claim"],
    ["show", "display", "render", "present"],
    ["print", "output"],
    ["log", "record", "trace"],
    ["format", "layout"],
    # ── nouns: data & io ──
    ["error", "failure", "fault", "defect"],
    ["errors", "failures", "faults"],
    ["exception", "exc"],
    ["warning", "caution"],
    ["config", "configuration", "settings", "options"],
    ["preference", "preferences"],
    ["folder", "directory"],
    ["file", "document"],
    ["path", "route", "location"],
    ["url", "uri", "address"],
    ["link", "hyperlink"],
    ["endpoint", "route"],
    ["response", "reply", "answer"],
    ["result", "outcome", "output"],
    ["results", "outcomes", "outputs"],
    ["data", "information", "info"],
    ["content", "body", "payload"],
    ["contents", "bodies"],
    ["text", "string"],
    ["value", "val"],
    ["name", "label", "title", "heading"],
    ["names", "labels", "titles"],
    ["version", "revision"],
    ["status", "state", "condition"],
    ["service", "daemon"],
    ["services", "daemons"],
    ["server", "host", "node"],
    ["client", "consumer"],
    ["clients", "consumers"],
    ["user", "account", "member"],
    ["users", "accounts", "members"],
    ["session", "connection"],
    ["token", "credential"],
    ["tokens", "credentials"],
    ["secret", "credential"],
    ["secrets", "credentials"],
    ["password", "passphrase"],
    ["health", "liveness"],
    ["metric", "measurement", "stat"],
    ["metrics", "measurements", "stats"],
    ["event", "signal", "notification"],
    ["events", "signals", "notifications"],
    ["message", "note", "notice"],
    ["messages", "notes", "notices"],
    ["summary", "overview", "digest"],
    ["detail", "specifics"],
    ["details", "specifics"],
    ["chunk", "fragment", "segment", "block"],
    ["chunks", "fragments", "segments", "blocks"],
    ["snippet", "excerpt"],
    ["snippets", "excerpts"],
    ["embedding", "vector"],
    ["embeddings", "vectors"],
    ["vector", "embedding"],
    ["vectors", "embeddings"],
    ["collection", "corpus"],
    ["collections", "corpora"],
    ["index", "catalog"],
    ["question", "query"],
    ["questions", "queries"],
    ["answer", "response", "reply"],
    ["latency", "delay", "lag"],
    ["duration", "interval", "period"],
    ["timeout", "deadline"],
    ["limit", "cap", "bound", "ceiling"],
    ["maximum", "max"],
    ["minimum", "min"],
    ["rank", "position", "placement"],
    ["score", "rating", "grade"],
    ["size", "dimension", "magnitude"],
    ["dimension", "size"],
    ["width", "breadth"],
    ["color", "colour", "hue", "shade"],
    ["style", "theme", "appearance"],
    ["layout", "arrangement"],
    ["schema", "structure"],
    ["pattern", "template"],
    ["component", "module", "element", "part"],
    ["components", "modules", "elements", "parts"],
    ["package", "bundle", "library"],
    ["bundle", "package"],
    ["dependency", "requirement", "prerequisite"],
    ["dependencies", "requirements", "prerequisites"],
    ["function", "method", "routine", "procedure"],
    ["method", "function", "routine"],
    ["operation", "action"],
    ["operations", "actions"],
    ["property", "attribute", "field"],
    ["properties", "attributes", "fields"],
    ["parameter", "argument", "arg"],
    ["parameters", "arguments", "args"],
    ["param", "arg"],
    ["params", "args"],
    ["input", "argument"],
    ["inputs", "arguments"],
    ["variable", "var"],
    ["constant", "const"],
    ["object", "instance", "entity"],
    ["entity", "object", "record"],
    ["record", "row", "entry"],
    ["records", "rows", "entries"],
    ["row", "record", "entry"],
    ["rows", "records", "entries"],
    ["column", "field"],
    ["table", "grid"],
    ["list", "array", "sequence"],
    ["queue", "backlog"],
    ["stack", "pile"],
    ["cache", "buffer"],
    ["store", "repository", "storage"],
    ["database", "datastore"],
    ["pool", "group"],
    ["thread", "worker"],
    ["process", "task", "job"],
    ["processes", "tasks", "jobs"],
    ["task", "job", "unit"],
    ["tasks", "jobs"],
    ["agent", "worker", "bot"],
    ["agents", "workers", "bots"],
    ["duel", "contest", "match"],
    ["duels", "contests", "matches"],
    ["workspace", "project"],
    ["repository", "repo"],
    ["benchmark", "evaluation"],
    ["test", "trial"],
    ["mock", "stub", "fake", "dummy"],
    ["fixture", "sample"],
    ["sample", "specimen", "example"],
    ["samples", "specimens", "examples"],
    ["example", "sample", "instance"],
    ["source", "origin"],
    ["destination", "target", "sink"],
    ["target", "goal"],
    ["default", "fallback"],
    ["fallback", "backup"],
    ["backup", "copy"],
    ["snapshot", "capture"],
    ["button", "control"],
    ["screen", "page", "view"],
    ["view", "display"],
    ["views", "displays"],
    ["manager", "controller", "coordinator"],
    ["managers", "controllers"],
    ["handler", "processor"],
    ["command", "instruction", "directive"],
    ["commands", "instructions"],
    ["system", "platform"],
    ["systems", "platforms"],
    ["stack", "layer"],
    ["point", "node"],
    ["points", "nodes"],
    ["date", "day"],
    ["timestamp", "datetime"],
    ["time", "moment"],
    ["seconds", "secs"],
    ["ranked", "ordered", "sorted"],
    ["indexed", "cataloged"],
    ["integrity", "consistency", "soundness"],
    ["resolved", "settled"],
    ["dependency", "prerequisite"],
    ["dimension", "extent"],
    ["schema", "blueprint"],
    ["output", "result"],
    ["outputs", "results"],
    # ── adjectives / states ──
    ["fast", "quick", "rapid", "swift"],
    ["slow", "sluggish"],
    ["large", "big", "huge"],
    ["small", "tiny", "little"],
    ["active", "running", "live"],
    ["running", "active", "live"],
    ["inactive", "disabled", "idle"],
    ["idle", "inactive"],
    ["enabled", "on"],
    ["disabled", "off"],
    ["valid", "correct", "legal"],
    ["invalid", "incorrect", "illegal"],
    ["empty", "blank", "void"],
    ["complete", "finished", "done"],
    ["partial", "incomplete"],
    ["pending", "queued", "waiting"],
    ["ready", "available", "prepared"],
    ["available", "ready", "free"],
    ["current", "present"],
    ["previous", "prior", "former"],
    ["next", "following", "subsequent"],
    ["initial", "first"],
    ["final", "last"],
    ["primary", "main", "principal"],
    ["secondary", "auxiliary"],
    ["global", "shared"],
    ["local", "private"],
    ["public", "open"],
    ["internal", "private"],
    ["external", "outer"],
    ["remote", "external"],
    ["optional", "nullable"],
    ["required", "mandatory", "needed"],
    ["unique", "distinct"],
    ["semantic", "meaning"],
    ["foreground", "front"],
    ["background", "rear"],
    # ── domain vocabulary (present in real indexed projects) ──
    ["vehicle", "car", "auto", "automobile"],
    ["vehicles", "cars", "autos"],
    ["dealer", "merchant", "seller", "vendor"],
    ["dealers", "merchants", "sellers", "vendors"],
    ["appraisal", "valuation", "assessment"],
    ["license", "licence", "permit"],
    ["billing", "invoicing"],
    ["invoice", "bill"],
    ["payment", "transaction"],
    ["price", "cost", "amount"],
    ["customer", "buyer"],
    ["site", "location"],
    ["registration", "signup", "enrollment"],
    ["acquisition", "procurement"],
    ["monitoring", "tracking"],
    ["employee", "staff"],
    # ── remaining common words with a genuine synonym ──
    ["activity", "action"],
    ["totals", "sums"],
    ["requests", "queries", "calls"],
    ["editor", "ide"],
    ["history", "log"],
    ["bucket", "bin"],
    ["id", "identifier"],
    ["ids", "identifiers"],
]
_SYNONYM_MAP: dict[str, str] = {}
for _group in _SYNONYM_GROUPS:
    for _i, _word in enumerate(_group):
        _SYNONYM_MAP.setdefault(_word, _group[(_i + 1) % len(_group)])


def paraphrase_query(query: str) -> "tuple[str, list[dict[str, str]]]":
    """Swap exactly ONE query word for its table synonym (the first word that has
    one, in query order).

    This is the paraphrase discipline: literal search can't match a word that is no
    longer in the file, while an embedding should still land near the meaning. One
    swap keeps the question anchored to its file — swapping more words drifts the
    query away from the ground truth and stops measuring paraphrase understanding.
    The swap is deterministic (table order) and returned for full disclosure."""
    words = query.split()
    out: list[str] = []
    swapped: list[dict[str, str]] = []
    for word in words:
        replacement = _SYNONYM_MAP.get(word)
        if replacement and replacement != word and not swapped:
            out.append(replacement)
            swapped.append({"from": word, "to": replacement})
        else:
            out.append(word)
    return " ".join(out), swapped


def rank_of(truth: str, files: list[str], top_k: int) -> Optional[int]:
    """1-based rank of the truth file within the first top_k distinct files."""
    for position, path in enumerate(files[:top_k], start=1):
        if paths_match(path, truth):
            return position
    return None


_EXCLUDE_DIRS = [
    ".git", "node_modules", ".venv", "venv", "__pycache__",
    "dist", "build", ".build", "target", ".idea", ".vscode",
]


def exclude_dir_flags(extra: Optional[list[str]] = None) -> list[str]:
    return [f"--exclude-dir={d}" for d in _EXCLUDE_DIRS + (extra or [])]


def alternation(words: list[str]) -> str:
    return "|".join(re.escape(w) for w in words)


def and_order(words: list[str]) -> list[str]:
    """Deterministic AND-stage order: longest word first — longer identifiers are
    usually rarer, so the candidate list shrinks fastest."""
    return sorted(set(words), key=lambda w: (-len(w), w))


def and_pipeline_description(words: list[str]) -> str:
    """Human-reproducible shell equivalent of the staged AND strategy the
    benchmark executes (stages run as separate processes for timeout control)."""
    ordered = and_order(words)
    first = f"grep -ril -I {' '.join(exclude_dir_flags())} -e {shlex_quote(ordered[0])} ."
    filters = " | ".join(f"xargs grep -il -e {shlex_quote(w)}" for w in ordered[1:])
    count = f"xargs grep -ic -E {shlex_quote(alternation(words))}"
    return " | ".join(x for x in [first, filters, count] if x)


def shlex_quote(text: str) -> str:
    import shlex
    return shlex.quote(text)


def grep_command(words: list[str], extra_exclude_dirs: Optional[list[str]] = None) -> list[str]:
    """The OR fallback: case-insensitive alternation of the query words, counting
    matching lines per file in one recursive pass. Used when the AND intersection
    comes up empty. Binaries and dependency/build dirs are excluded so grep isn't
    punished for scanning junk."""
    pattern = alternation(words)
    # Absolute system grep: deterministic BSD behavior regardless of what shadows
    # `grep` on the user's PATH (ugrep/ripgrep aliases would skew timing).
    cmd = ["/usr/bin/grep", "-r", "-i", "-E", "-c", "-I", "-s"]
    cmd += exclude_dir_flags(extra_exclude_dirs)
    cmd += ["-e", pattern, "."]
    return cmd


def parse_grep_counts(output: str) -> list[tuple[str, int]]:
    """grep -rc output → [(path, matching_lines)] ranked the way a human
    triages grep results: most matches first; ties broken by path depth (shorter
    paths first — a neutral heuristic, not alphabetical luck)."""
    ranked: list[tuple[str, int]] = []
    for line in output.splitlines():
        path, sep, count_text = line.rpartition(":")
        if not sep:
            continue
        try:
            count = int(count_text)
        except ValueError:
            continue
        if count > 0:
            ranked.append((path[2:] if path.startswith("./") else path, count))
    ranked.sort(key=lambda item: (-item[1], item[0].count("/"), item[0]))
    return ranked


def median_ms(values: list[float]) -> float:
    return round(statistics.median(values), 1) if values else 0.0


class StageTimer:
    def __init__(self) -> None:
        self.started = time.monotonic()

    def ms(self) -> float:
        return round((time.monotonic() - self.started) * 1000, 1)
