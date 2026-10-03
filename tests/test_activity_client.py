"""Tests for the client label Activity shows next to each request.

The value arrives in a request header, so it is untrusted input: these check that it is
cleaned before it can reach a log line or the UI, and that an undeclared client stays
empty rather than being guessed at.
"""

from embarsy_api.main import _client_label


class _Req:
    def __init__(self, **headers):
        self.headers = {k.lower(): v for k, v in headers.items()}


def test_editor_and_tool_are_combined():
    req = _Req(**{"x-embarsy-client": "claude-code", "x-embarsy-tool": "index"})
    assert _client_label(req) == "claude-code · index"


def test_either_half_alone_still_labels():
    assert _client_label(_Req(**{"x-embarsy-client": "codex"})) == "codex"
    assert _client_label(_Req(**{"x-embarsy-tool": "search"})) == "search"


def test_nothing_declared_stays_empty():
    """An empty label is the honest answer: clients that talk to the proxy directly cannot
    be named, and every Node client's User-Agent is the useless string "node"."""
    assert _client_label(_Req()) == ""
    assert _client_label(_Req(**{"user-agent": "node"})) == ""


def test_control_characters_and_markup_are_stripped():
    """A header is caller-supplied; it must not be able to forge a log line or inject
    markup into the Activity list."""
    req = _Req(**{"x-embarsy-client": "claude\r\n[store] fake log line"})
    label = _client_label(req)
    assert "\r" not in label and "\n" not in label
    assert "[" not in label and "]" not in label

    assert "<" not in _client_label(_Req(**{"x-embarsy-client": "<b>bold</b>"}))


def test_label_is_length_capped():
    req = _Req(**{"x-embarsy-client": "c" * 500, "x-embarsy-tool": "t" * 500})
    label = _client_label(req)
    # Each half is capped independently; the separator is the only extra.
    assert len(label) <= 48 * 2 + 3


def test_a_header_of_only_punctuation_reads_as_undeclared():
    assert _client_label(_Req(**{"x-embarsy-client": "!!!@@@###"})) == ""
