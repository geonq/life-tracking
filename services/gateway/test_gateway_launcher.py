from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import re
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from pathlib import Path

import pytest
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


IDENTITY = {"Self": {"DNSName": "machine.example.ts.net."}}
FIXTURE_LOGIN = "operator@example.com"


def snapshot_payload(**overrides) -> dict:
    payload = {
        "schemaVersion": 1,
        "observedAt": datetime.now(timezone.utc).isoformat(),
        "dnsName": "machine.example.ts.net",
        "login": FIXTURE_LOGIN,
        "serve": exact_web(),
        "identity": dict(IDENTITY),
    }
    payload.update(overrides)
    return payload


def write_snapshot(tmp_path: Path, payload, *, name: str = "tailscale-state.json") -> Path:
    path = tmp_path / name
    path.write_text(payload if isinstance(payload, str) else json.dumps(payload), encoding="utf-8")
    return path


SNAPSHOT_ENVIRONMENT_NAMES = (
    "LIFEOS_DATA_DIR", "LIFEOS_CALENDAR_PATH", "LIFEOS_DOCUMENTS_DIR",
    "CLAUDE_INGEST_SECRET_FILE", "LIFEOS_CLAUDE_SECRET_FILE",
    "LIFEOS_TAILSCALE_ALLOWED_LOGIN", "LIFEOS_TAILSCALE_EDGE_TOKEN",
    "LIFEOS_TAILSCALE_SERVICE_NAME", "LIFEOS_TAILSCALE_SNAPSHOT_PATH",
    "LIFEOS_GATEWAY_CONFIG_PATH", "PORT",
)


def run_launcher_with_snapshot(monkeypatch, tmp_path: Path, payload) -> None:
    """Drive launcher.run() end to end against one on-disk snapshot payload."""
    config = {
        "dataDirectory": str(tmp_path / "data"),
        "calendarPath": str(tmp_path / "data" / "calendar.json"),
        "documentsPath": str(tmp_path / "data" / "documents"),
        "claudeSecretPath": str(tmp_path / "secret"),
        "tailscaleEdgeTokenPath": str(tmp_path / "tailscale-edge.token"),
    }
    (tmp_path / "tailscale-edge.token").write_bytes(b"t" * 32)
    tailscale = tmp_path / "tailscale.exe"
    tailscale.write_bytes(b"MZ")
    snapshot = write_snapshot(tmp_path, payload)

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
        name: launcher.os.environ.get(name) for name in SNAPSHOT_ENVIRONMENT_NAMES
    }
    monkeypatch.setattr(launcher, "_read_config", lambda _path: dict(config))
    monkeypatch.setattr(launcher.importlib, "import_module", fake_import)
    monkeypatch.setattr(launcher.sys, "stdin", SimpleNamespace(buffer=SimpleNamespace(read=lambda: b"")))
    launcher.os.environ["LIFEOS_TAILSCALE_SNAPSHOT_PATH"] = str(snapshot)
    try:
        assert launcher.run(tmp_path / "gateway.json", tmp_path / "gateway.py", tailscale) == 0
        assert launcher.os.environ["LIFEOS_TAILSCALE_ALLOWED_LOGIN"] == FIXTURE_LOGIN
    finally:
        for name, value in original_environment.items():
            if value is None:
                launcher.os.environ.pop(name, None)
            else:
                launcher.os.environ[name] = value


def test_run_reads_the_system_snapshot_instead_of_querying_tailscale(monkeypatch, tmp_path) -> None:
    run_launcher_with_snapshot(monkeypatch, tmp_path, snapshot_payload())
    # The launcher must never shell out to Tailscale from the service account.
    assert not hasattr(launcher, "_run_tailscale")
    assert not hasattr(launcher, "_tailscale_login")


def test_run_accepts_the_powershell_roundtrip_timestamp_the_writer_actually_emits(monkeypatch, tmp_path) -> None:
    # tailscale_snapshot.ps1 writes (Get-Date).ToUniversalTime().ToString('o'),
    # which is the .NET round-trip format: SEVEN fractional-second digits and a
    # trailing Z. Every other fixture here uses datetime.isoformat(), which
    # emits six, so without this case nothing feeds the writer's real output to
    # the reader's real parser. datetime.fromisoformat() rejected more than six
    # digits before Python 3.11; the deployed runtime is
    # D:\Hermes\lifeos-runtime\python312\python.exe (3.12.10), which parses
    # it and truncates to microseconds. Pin the contract so a runtime or
    # format change fails here rather than at service start.
    now = datetime.now(timezone.utc)
    observed_at = f"{now.strftime('%Y-%m-%dT%H:%M:%S')}.{now.microsecond:06d}7Z"
    assert re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z", observed_at)
    payload = snapshot_payload(observedAt=observed_at)

    # The reader parses it, truncating the seventh digit rather than failing.
    snapshot = write_snapshot(tmp_path, payload, name="roundtrip.json")
    monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(snapshot))
    serve, dns_name, login = launcher._read_tailscale_snapshot()
    assert serve == exact_web()
    assert dns_name == "machine.example.ts.net"
    assert login == FIXTURE_LOGIN

    # ...and the launcher starts on it.
    run_launcher_with_snapshot(monkeypatch, tmp_path, payload)


def test_snapshot_freshness_window_is_pinned_to_the_reviewed_values() -> None:
    # Deployment.Common.ps1's Assert-TailscaleSnapshotFile mirrors these, and
    # the SYSTEM task republishes every 60 seconds. Asserting the literals
    # rather than the module attribute means silently widening the window --
    # to an hour, say -- fails a test instead of only a source grep.
    assert launcher.TAILSCALE_SNAPSHOT_MAX_AGE_SECONDS == 90
    assert launcher.TAILSCALE_SNAPSHOT_MAX_FUTURE_SECONDS == 5


def test_snapshot_reader_returns_the_serve_dns_and_login(monkeypatch, tmp_path) -> None:
    snapshot = write_snapshot(tmp_path, snapshot_payload())
    monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(snapshot))
    serve, dns_name, login = launcher._read_tailscale_snapshot()
    assert serve == exact_web()
    assert dns_name == "machine.example.ts.net"
    assert login == FIXTURE_LOGIN
    assert launcher._serve_is_exact(serve, expected_dns_name=dns_name)


def test_snapshot_reader_fails_closed_on_every_invalid_snapshot(monkeypatch, tmp_path) -> None:
    monkeypatch.delenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", raising=False)
    with pytest.raises(RuntimeError, match="tailscale snapshot path is not configured"):
        launcher._read_tailscale_snapshot()

    monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(tmp_path / "missing.json"))
    with pytest.raises(RuntimeError, match="required deployment file is missing"):
        launcher._read_tailscale_snapshot()

    oversized = write_snapshot(tmp_path, snapshot_payload(login="x" * (256 * 1024)), name="oversized.json")
    monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(oversized))
    with pytest.raises(RuntimeError, match="tailscale snapshot is oversized"):
        launcher._read_tailscale_snapshot()

    unreadable = write_snapshot(tmp_path, "{not json", name="unreadable.json")
    monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(unreadable))
    with pytest.raises(RuntimeError, match="tailscale snapshot is unreadable"):
        launcher._read_tailscale_snapshot()

    stale_offset = datetime.now(timezone.utc) - timedelta(seconds=launcher.TAILSCALE_SNAPSHOT_MAX_AGE_SECONDS + 5)
    future_offset = datetime.now(timezone.utc) + timedelta(seconds=launcher.TAILSCALE_SNAPSHOT_MAX_FUTURE_SECONDS + 5)
    naive = datetime.now(timezone.utc).replace(tzinfo=None).isoformat()
    extra_field = snapshot_payload()
    extra_field["unexpected"] = True
    missing_field = snapshot_payload()
    del missing_field["identity"]
    dns_mismatch = snapshot_payload(dnsName="other.example.ts.net")
    cases = (
        ("schema", extra_field, "tailscale snapshot schema is invalid"),
        ("missing-key", missing_field, "tailscale snapshot schema is invalid"),
        ("version", snapshot_payload(schemaVersion=2), "tailscale snapshot schema is invalid"),
        ("payload-not-dict", [1, 2, 3], "tailscale snapshot schema is invalid"),
        ("timestamp-type", snapshot_payload(observedAt=17), "tailscale snapshot timestamp is invalid"),
        ("timestamp-naive", snapshot_payload(observedAt=naive), "tailscale snapshot timestamp is invalid"),
        ("timestamp-garbage", snapshot_payload(observedAt="not-a-time"), "tailscale snapshot timestamp is invalid"),
        ("stale", snapshot_payload(observedAt=stale_offset.isoformat()), "tailscale snapshot is stale"),
        ("future", snapshot_payload(observedAt=future_offset.isoformat()), "tailscale snapshot is stale"),
        ("serve-type", snapshot_payload(serve=[]), "tailscale snapshot payload is invalid"),
        ("identity-type", snapshot_payload(identity="machine"), "tailscale snapshot payload is invalid"),
        ("dns-mismatch", dns_mismatch, "tailscale snapshot identity does not match its DNS name"),
        # tailscale_snapshot.ps1 writes dnsName already TrimEnd('.')-normalized,
        # so an un-normalized value is a snapshot this gateway did not expect.
        ("dns-trailing-dot", snapshot_payload(dnsName="machine.example.ts.net."), "tailscale snapshot identity does not match its DNS name"),
        ("login-empty", snapshot_payload(login=""), "tailscale snapshot login is invalid"),
        ("login-shape", snapshot_payload(login="operator@example.com@example.com"), "tailscale snapshot login is invalid"),
        ("login-percent", snapshot_payload(login="operator%40example.com@example.com"), "tailscale snapshot login is invalid"),
        # The identity payload is pruned by the writer, so a missing Self is a
        # snapshot no reviewed writer produced.
        ("identity-empty", snapshot_payload(identity={}), "tailscale DNS name unavailable"),
    )
    for name, payload, message in cases:
        path = write_snapshot(tmp_path, payload, name=f"{name}.json")
        monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(path))
        with pytest.raises(RuntimeError, match=message):
            launcher._read_tailscale_snapshot()


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
