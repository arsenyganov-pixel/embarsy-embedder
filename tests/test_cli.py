import json

from embarsy_api.cli import build_server_config, main
from embarsy_api.main import app
from embarsy_api.settings import Settings, get_settings


def test_build_server_config_uses_settings_values():
    settings = Settings(EMBARSY_HOST="127.0.0.2", EMBARSY_API_PORT=18000)

    config = build_server_config(settings)

    assert config["app"] is app
    assert config["host"] == "127.0.0.2"
    assert config["port"] == 18000
    assert config["factory"] is False


def test_print_config_outputs_json(monkeypatch, capsys):
    get_settings.cache_clear()
    monkeypatch.setenv("EMBARSY_HOST", "127.0.0.3")
    monkeypatch.setenv("EMBARSY_API_PORT", "18001")

    try:
        exit_code = main(["--print-config"])
    finally:
        get_settings.cache_clear()

    assert exit_code == 0
    payload = json.loads(capsys.readouterr().out)
    assert payload["app"] == "embarsy_api.main:app"
    assert payload["host"] == "127.0.0.3"
    assert payload["port"] == 18001
