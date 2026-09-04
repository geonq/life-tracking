from __future__ import annotations

import asyncio
import importlib.util
import json
import os
from types import SimpleNamespace
from pathlib import Path

from fastapi.testclient import TestClient


ROOT = Path(__file__).resolve().parent
LAUNCHER_PATH = ROOT / "windows-service-host" / "deploy" / "gateway_launcher.py"
if not LAUNCHER_PATH.is_file():
    # The source tree nests this test under services/gateway, while the
    # source-bound Windows candidate keeps the production gateway flat.
    LAUNCHER_PATH = ROOT.parent / "windows-service-host" / "deploy" / "gateway_launcher.py"
SPEC = importlib.util.spec_from_file_location("lifeos_gateway_launcher", LAUNCHER_PATH)
assert SPEC is not None and SPEC.loader is not None
launcher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(launcher)


def exact_web(proxy: str = "http://127.0.0.1:8421") -> dict:
    return {"Web": {"machine.example.ts.net:8420": {"Handlers": {"/": {
        "Proxy": proxy,
        "AcceptAppCaps": [launcher.TRUSTED_EDGE_APP_CAPABILITY],
    }}}}}


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
        "https://machine.example.ts.net:8420": {"Handlers": {"/": {
            "Proxy": "http://127.0.0.1:8421",
            "AcceptAppCaps": [launcher.TRUSTED_EDGE_APP_CAPABILITY],
        }}},
    }}, expected_dns_name="machine.example.ts.net")
    assert not launcher._serve_is_exact(exact_web(), expected_dns_name="another.example.ts.net")
    assert launcher._serve_is_exact({"Web": {
        "machine.example.ts.net:8420": {"Handlers": {"/": {
            "Proxy": "http://127.0.0.1:8421",
            "AcceptAppCaps": [launcher.TRUSTED_EDGE_APP_CAPABILITY],
        }}},
        "machine.example.ts.net:8443": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:9999"}}},
    }})
    assert not launcher._serve_is_exact({"Web": {
        "https://machine.example.ts.net:8420/not-lifeos": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8421"}}},
    }})
    assert not launcher._serve_is_exact({"Web": {"machine.example.ts.net:8420": {"Handlers": {"/": {"Proxy": "http://127.0.0.1:8421", "Path": "/tmp"}}}}})
    assert launcher._serve_is_exact({**exact_web(), "Services": {"svc:other": {"TCP": {"443": {"TCPForward": "127.0.0.1:443"}}}}})
    assert not launcher._serve_is_exact({**exact_web(), "AllowFunnel": {"machine.example.ts.net:8420": True}})


def test_tailscale_dns_name_is_read_from_identity_payload() -> None:
    assert launcher._tailscale_dns_name({"Self": {"DNSName": "machine.example.ts.net."}}) == "machine.example.ts.net"


def test_run_queries_serve_and_identity_separately_before_starting_uvicorn(monkeypatch, tmp_path) -> None:
    config = {
        "dataDirectory": str(tmp_path / "data"),
        "calendarPath": str(tmp_path / "data" / "calendar.json"),
        "documentsPath": str(tmp_path / "data" / "documents"),
        "claudeSecretPath": str(tmp_path / "secret"),
        "tailscaleEdgeTokenPath": str(tmp_path / "tailscale-edge.token"),
    }
    (tmp_path / "tailscale-edge.token").write_bytes(b"t" * 32)
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
            "LIFEOS_TAILSCALE_ALLOWED_LOGIN", "LIFEOS_TAILSCALE_EDGE_TOKEN",
            "LIFEOS_TAILSCALE_SERVICE_NAME",
            "LIFEOS_GATEWAY_CONFIG_PATH", "PORT",
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


def test_edge_token_read_and_header_bridge_are_value_safe(tmp_path) -> None:
    token = "s" * 32
    present = tmp_path / "tailscale-edge.token"
    present.write_bytes(token.encode("ascii"))
    assert launcher._read_edge_token(present) == token

    missing = tmp_path / "missing.token"
    try:
        launcher._read_edge_token(missing)
    except launcher.EdgeTokenConfigurationError as exc:
        assert "missing" in str(exc)
        assert token not in str(exc)
    else:
        raise AssertionError("missing edge token did not fail closed")

    invalid = tmp_path / "invalid.token"
    invalid.write_bytes((b"i" * 31) + b"\n")
    try:
        launcher._read_edge_token(invalid)
    except launcher.EdgeTokenConfigurationError as exc:
        assert "invalid" in str(exc)
        assert token not in str(exc)
    else:
        raise AssertionError("invalid edge token did not fail closed")

    captured: dict = {}

    async def app(scope, _receive, _send):
        captured.update(scope)

    cap_header = json.dumps({launcher.TRUSTED_EDGE_APP_CAPABILITY: [{"src": ["*"]}]}).encode("ascii")
    adapter = launcher.TrustedEdgeHeaderAdapter(app, token, peer_verifier=lambda _scope: True)
    asyncio.run(adapter({"type": "http", "headers": [
        (b"Tailscale-User-Login", b"operator@example.com"),
        (b"Tailscale-App-Capabilities", cap_header),
        (b"X-LifeOS-Trusted-Edge", b"attacker-value"),
    ]}, None, None))
    assert (b"Tailscale-User-Login", b"operator@example.com") in captured["headers"]
    assert (launcher.TRUSTED_EDGE_HEADER, token.encode("ascii")) in captured["headers"]
    assert all(name.lower() != launcher.TAILSCALE_APP_CAPABILITIES_HEADER for name, _ in captured["headers"])

    captured.clear()
    asyncio.run(adapter({"type": "http", "headers": [
        (b"Tailscale-App-Capabilities", b"{}"),
        (b"X-LifeOS-Trusted-Edge", b"attacker-value"),
    ]}, None, None))
    assert all(name.lower() not in {launcher.TRUSTED_EDGE_HEADER, launcher.TAILSCALE_APP_CAPABILITIES_HEADER} for name, _ in captured["headers"])


def test_windows_peer_verifier_requires_the_current_tailscale_service_pid(monkeypatch) -> None:
    scope = {
        "type": "http",
        "client": ("127.0.0.1", 51000),
        "server": ("127.0.0.1", launcher.GATEWAY_LOOPBACK_PORT),
    }
    monkeypatch.setattr(launcher, "_is_windows_host", lambda: True)
    monkeypatch.setattr(launcher, "_windows_tcp_peer_pid", lambda _scope: 1001)
    monkeypatch.setattr(launcher, "_windows_tailscale_service_pid", lambda _name: 2002)
    assert not launcher._is_tailscale_service_peer(scope, "Tailscale")

    monkeypatch.setattr(launcher, "_windows_tailscale_service_pid", lambda _name: 1001)
    assert launcher._is_tailscale_service_peer(scope, "Tailscale")

    monkeypatch.setattr(launcher, "_windows_tcp_peer_pid", lambda _scope: None)
    assert not launcher._is_tailscale_service_peer(scope, "Tailscale")

    def query_failure(_scope):
        raise OSError("connection query unavailable")

    monkeypatch.setattr(launcher, "_windows_tcp_peer_pid", query_failure)
    assert not launcher._is_tailscale_service_peer(scope, "Tailscale")


def test_forged_local_caller_cannot_authorize_through_gateway_adapter(monkeypatch) -> None:
    token = "e" * 64
    os.environ.setdefault("LIFEOS_TAILSCALE_ALLOWED_LOGIN", "operator@example.com")
    os.environ.setdefault("LIFEOS_TAILSCALE_EDGE_TOKEN", token)
    import main

    monkeypatch.setattr(main, "ALLOWED_TAILSCALE_LOGIN", "operator@example.com")
    monkeypatch.setattr(main, "LIFEOS_TAILSCALE_EDGE_TOKEN", token)
    protected_app = launcher.TrustedEdgeHeaderAdapter(
        main.app,
        token,
        peer_verifier=lambda _scope: False,
    )
    response = TestClient(protected_app).get(
        "/usage",
        headers={
            "Tailscale-User-Login": "operator@example.com",
            "Tailscale-App-Capabilities": json.dumps({
                launcher.TRUSTED_EDGE_APP_CAPABILITY: [{"src": ["*"]}],
            }),
            "X-LifeOS-Trusted-Edge": token,
        },
    )
    assert response.status_code == 403


def test_adapter_fails_closed_when_peer_query_raises() -> None:
    captured: dict = {}

    async def app(scope, _receive, _send):
        captured.update(scope)

    adapter = launcher.TrustedEdgeHeaderAdapter(
        app,
        "t" * 32,
        peer_verifier=lambda _scope: (_ for _ in ()).throw(RuntimeError("unknown peer")),
    )
    cap_header = json.dumps({launcher.TRUSTED_EDGE_APP_CAPABILITY: [{"src": ["*"]}]}).encode("ascii")
    asyncio.run(adapter({"type": "http", "headers": [
        (b"Tailscale-User-Login", b"operator@example.com"),
        (b"Tailscale-App-Capabilities", cap_header),
    ]}, None, None))
    assert all(name.lower() != launcher.TRUSTED_EDGE_HEADER for name, _ in captured["headers"])
