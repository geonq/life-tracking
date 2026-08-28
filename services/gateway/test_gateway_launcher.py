from __future__ import annotations

import importlib.util
from types import SimpleNamespace
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
LAUNCHER_PATH = ROOT / "windows-service-host" / "deploy" / "gateway_launcher.py"
SPEC = importlib.util.spec_from_file_location("lifeos_gateway_launcher", LAUNCHER_PATH)
assert SPEC is not None and SPEC.loader is not None
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


def exact_web(proxy: str = "http://127.0.0.1:8421") -> dict:
    return {"Web": {"machine.example.ts.net:8420": {"Handlers": {"/": {"Proxy": proxy}}}}}


def test_serve_empty_requires_all_route_bearing_forms_to_be_empty() -> None:
    assert launcher._serve_is_empty({})
    assert launcher._serve_is_empty({"Web": {}, "TCP": {}, "Services": {}, "AllowFunnel": {}})
    assert not launcher._serve_is_empty({"TCP": {"8420": {"TCPForward": "127.0.0.1:8421"}}})
    assert not launcher._serve_is_empty({"Services": {"svc:internal": {"Tun": True}}})
    assert not launcher._serve_is_empty({"Web": {"machine.example.ts.net:8420": {"Handlers": {"/": {"Text": "owned by another app"}}}}})


def test_serve_exact_requires_only_the_canonical_lifeos_web_mapping() -> None:
    assert launcher._serve_is_exact(exact_web())
    assert launcher._serve_is_exact(exact_web(), expected_dns_name="machine.example.ts.net")
    assert launcher._serve_is_exact({"Web": {
        "https://machine.example.ts.net:8420": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8421"}}},
    }}, expected_dns_name="machine.example.ts.net")
    assert not launcher._serve_is_exact(exact_web(), expected_dns_name="another.example.ts.net")
    assert not launcher._serve_is_exact({"Web": {
        "machine.example.ts.net:8420": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8421"}}},
        "machine.example.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}},
    }})
    assert not launcher._serve_is_exact({"Web": {
        "https://machine.example.ts.net:8420/not-lifeos": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8421"}}},
    }})
    assert not launcher._serve_is_exact({"Web": {"machine.example.ts.net:8420": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8421", "Path": "/tmp"}}}}})
    assert not launcher._serve_is_exact({**exact_web(), "Services": {"svc:other": {"TCP": {"443": {"TCPForward": "127.0.0.1:443"}}}}})
    assert not launcher._serve_is_exact({**exact_web(), "AllowFunnel": {"machine.example.ts.net:8420": True}})


def test_tailscale_dns_name_is_read_from_identity_payload() -> None:
    assert launcher._tailscale_dns_name({"Self": {"DNSName": "machine.example.ts.net."}}) == "machine.example.ts.net"


def test_run_queries_serve_and_identity_separately_before_starting_uvicorn(monkeypatch, tmp_path) -> None:
    config = {
        "dataDirectory": str(tmp_path / "data"),
        "calendarPath": str(tmp_path / "data" / "calendar.json"),
        "documentsPath": str(tmp_path / "data" / "documents"),
        "claudeSecretPath": str(tmp_path / "secret"),
    }
    serve = exact_web()
    identity = {
        "Self": {"DNSName": "machine.example.ts.net.", "UserID": "u"},
        "User": {"u": {"LoginName": "operator@example.com"}},
    }
    calls: list[tuple[str, ...]] = []

    def fake_tailscale(_executable: Path, *args: str) -> dict:
        calls.append(args)
        return serve if args[:2] == ("serve", "status") else identity

    class FakeServer:
        ran = False

        def __init__(self, _config) -> None:
            pass

        def run(self) -> None:
            self.ran = True

    fake_gateway = SimpleNamespace(app=object())
    fake_uvicorn = SimpleNamespace(Config=lambda *args, **kwargs: (args, kwargs), Server=FakeServer)

    def fake_import(name: str):
        if name == "gateway":
            return fake_gateway
        if name == "uvicorn":
            return fake_uvicorn
        raise AssertionError(name)

    original_environment = {
        name: launcher.os.environ.get(name)
        for name in (
            "LIFEOS_DATA_DIR", "LIFEOS_CALENDAR_PATH", "LIFEOS_DOCUMENTS_DIR",
            "CLAUDE_INGEST_SECRET_FILE", "LIFEOS_CLAUDE_SECRET_FILE",
            "LIFEOS_TAILSCALE_ALLOWED_LOGIN", "LIFEOS_GATEWAY_CONFIG_PATH", "PORT",
        )
    }
    monkeypatch.setattr(launcher, "_read_config", lambda _path: dict(config))
    monkeypatch.setattr(launcher, "_run_tailscale", fake_tailscale)
    monkeypatch.setattr(launcher.importlib, "import_module", fake_import)
    monkeypatch.setattr(launcher.sys, "stdin", SimpleNamespace(buffer=SimpleNamespace(read=lambda: b"")))
    try:
        assert launcher.run(tmp_path / "gateway.json", tmp_path / "gateway.py", tmp_path / "tailscale.exe") == 0
    finally:
        for name, value in original_environment.items():
            if value is None:
                launcher.os.environ.pop(name, None)
            else:
                launcher.os.environ[name] = value

    assert calls == [("serve", "status", "--json"), ("status", "--json")]
