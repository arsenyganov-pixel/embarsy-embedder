"""A 401 on a localhost service is almost always "your editor still holds the key from a
previous install". These tests pin the behaviour that turns that into a self-explaining
error plus a signal the Status screen can surface — including the two traps an adversarial
review caught: a swapped key must NOT be blamed on a reinstall, and an unrelated 401 must
not resurrect the banner."""

import time

import pytest
from fastapi.testclient import TestClient

from embarsy_api import main
from embarsy_api.main import app
from embarsy_api.settings import Settings, get_settings

CURRENT_API_KEY = "a" * 48      # Embarsy mints 24-byte hex secrets for the API key
CURRENT_QDRANT_KEY = "b" * 64   # ...and 32-byte hex for the Qdrant key
STALE_API_KEY = "c" * 48        # right shape for this slot, wrong installation
STALE_QDRANT_KEY = "d" * 64


@pytest.fixture()
def client():
    settings = Settings(EMBARSY_API_KEY=CURRENT_API_KEY, QDRANT_API_KEY=CURRENT_QDRANT_KEY)
    app.dependency_overrides[get_settings] = lambda: settings
    # Counters are module-level and rolling — reset so tests don't leak into each other.
    main._auth_failures.update({"api": 0, "qdrant": 0, "last_at": 0.0, "stale_last_at": 0.0})
    try:
        yield TestClient(app)
    finally:
        app.dependency_overrides.clear()


def test_looks_like_embarsy_key_matches_only_embarsy_shaped_secrets():
    assert main._looks_like_embarsy_key("0" * 48)
    assert main._looks_like_embarsy_key("f" * 64)
    assert not main._looks_like_embarsy_key("sk-proj-not-hex-and-wrong-length")
    assert not main._looks_like_embarsy_key("0" * 47)      # off-by-one width
    assert not main._looks_like_embarsy_key("z" * 48)      # right width, not hex
    assert not main._looks_like_embarsy_key("")


def test_stale_api_key_explains_the_reinstall(client):
    response = client.get("/activity/requests", headers={"Authorization": f"Bearer {STALE_API_KEY}"})
    assert response.status_code == 401
    detail = response.json()["detail"]
    assert "previous Embarsy install" in detail
    assert "Status" in detail  # tells the user where to copy the current key from


def test_garbage_key_gets_the_generic_but_still_actionable_message(client):
    response = client.get("/activity/requests", headers={"Authorization": "Bearer nonsense"})
    assert response.status_code == 401
    detail = response.json()["detail"]
    assert "previous Embarsy install" not in detail  # don't claim what we can't tell
    assert "Status" in detail


def test_stale_qdrant_key_explains_the_reinstall(client):
    response = client.get("/qdrant/collections", headers={"api-key": STALE_QDRANT_KEY})
    assert response.status_code == 401
    assert "previous Embarsy install" in response.json()["detail"]


# ── the swap: we hold both secrets, so say exactly which field is wrong ──────────

def test_qdrant_key_pasted_into_the_api_field_is_named_as_such(client):
    """Blaming a reinstall here would send the user to re-copy the very keys they just
    copied — and repeat the swap."""
    response = client.get(
        "/activity/requests", headers={"Authorization": f"Bearer {CURRENT_QDRANT_KEY}"}
    )
    assert response.status_code == 401
    detail = response.json()["detail"]
    assert "That is your Qdrant API key" in detail
    assert "previous Embarsy install" not in detail
    # A swap is not a stale key: it must not arm the Status banner.
    assert client.get("/health").json()["auth_failures"]["looks_stale"] is False


def test_api_key_pasted_into_the_qdrant_field_is_named_as_such(client):
    response = client.get("/qdrant/collections", headers={"api-key": CURRENT_API_KEY})
    assert response.status_code == 401
    detail = response.json()["detail"]
    assert "That is your Embarsy API key" in detail
    assert "previous Embarsy install" not in detail


def test_wrong_width_for_the_slot_is_not_called_a_previous_install(client):
    """A 64-char hex in the API slot isn't an old API key — that slot's keys are 48 chars."""
    response = client.get("/activity/requests", headers={"Authorization": f"Bearer {STALE_QDRANT_KEY}"})
    assert "previous Embarsy install" not in response.json()["detail"]


# ── the banner signal ───────────────────────────────────────────────────────────

def test_health_reports_rejected_keys_for_the_status_banner(client):
    assert client.get("/health").json()["auth_failures"] == {
        "api": 0, "qdrant": 0, "last_at": 0.0, "stale_last_at": 0.0, "looks_stale": False,
    }

    client.get("/activity/requests", headers={"Authorization": f"Bearer {STALE_API_KEY}"})
    client.get("/qdrant/collections", headers={"api-key": STALE_QDRANT_KEY})

    failures = client.get("/health").json()["auth_failures"]
    assert failures["api"] == 1 and failures["qdrant"] == 1
    assert failures["looks_stale"] is True      # both were stale-shaped for their slot
    assert failures["stale_last_at"] > 0        # lets the app expire the banner


def test_unrelated_401_does_not_refresh_the_stale_timestamp(client):
    """The banner windows off stale_last_at. If a plain no-key 401 bumped it, a browser tab
    or a stray curl would resurrect the banner hours after the user fixed their editor."""
    client.get("/activity/requests", headers={"Authorization": f"Bearer {STALE_API_KEY}"})
    stale_at = client.get("/health").json()["auth_failures"]["stale_last_at"]
    assert stale_at > 0

    time.sleep(0.01)
    client.get("/activity/requests")                       # no key at all
    client.get("/activity/requests", headers={"Authorization": "Bearer nonsense"})

    failures = client.get("/health").json()["auth_failures"]
    assert failures["stale_last_at"] == stale_at           # untouched by unrelated 401s
    assert failures["last_at"] > stale_at                  # ...which are still counted


def test_correct_key_is_not_counted_as_a_failure(client):
    client.get("/activity/requests", headers={"Authorization": f"Bearer {CURRENT_API_KEY}"})
    failures = client.get("/health").json()["auth_failures"]
    assert failures["api"] == 0 and failures["looks_stale"] is False
