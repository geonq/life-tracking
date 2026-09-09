from __future__ import annotations

import asyncio
import importlib.util
import json
import os
import re
import threading
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


def test_serve_exact_accepts_only_the_powershell_https_tcp_mirror_shape() -> None:
    paired = {**exact_web(), "TCP": {"8420": {"HTTPS": True}}}
    assert launcher._serve_is_exact(paired, expected_dns_name="machine.example.ts.net")

    unsafe_tcp_values = (
        {"8420": {"HTTPS": False}},
        {"8420": {"HTTPS": "true"}},
        {"8420": {"HTTPS": True, "TCPForward": "127.0.0.1:9000"}},
        {"8420": "https"},
        {8420: {"HTTPS": True}},
        {"8419-8421": {"HTTPS": True}},
        {"https://machine.example.ts.net:8420": {"HTTPS": True}},
    )
    for tcp in unsafe_tcp_values:
        assert not launcher._serve_is_exact({**exact_web(), "TCP": tcp})


def test_tailscale_dns_name_is_read_from_identity_payload() -> None:
    assert launcher._tailscale_dns_name({"Self": {"DNSName": "machine.example.ts.net."}}) == "machine.example.ts.net"


@pytest.mark.parametrize(("dependency_ready", "expected_status"), ((True, 200), (False, 503)))
def test_local_readiness_adapter_rechecks_dependencies_and_keeps_health_separate(
    dependency_ready: bool, expected_status: int
) -> None:
    calls = []

    async def app(scope, _receive, _send):
        calls.append(scope)

    adapter = launcher.LocalReadinessAdapter(app, lambda: dependency_ready)
    messages = []

    async def send(message):
        messages.append(message)

    asyncio.run(adapter({
        "type": "http",
        "path": "/ready",
        "client": ("127.0.0.1", 8787),
    }, None, send))

    assert messages[0]["status"] == expected_status
    assert messages[1]["body"] == (
        b'{"readiness":"ready"}' if dependency_ready else b'{"readiness":"unavailable"}'
    )
    assert calls == []


def test_local_readiness_adapter_returns_503_when_probe_times_out(monkeypatch) -> None:
    started = threading.Event()
    release = threading.Event()
    calls = 0

    def readiness_check() -> bool:
        nonlocal calls
        calls += 1
        started.set()
        release.wait(timeout=2)
        return True

    adapter = launcher.LocalReadinessAdapter(lambda *_: None, readiness_check)
    monkeypatch.setattr(launcher, "LOCAL_READINESS_TIMEOUT_SECONDS", 0.01)
    messages = []

    async def send(message):
        messages.append(message)

    async def exercise() -> None:
        request = asyncio.create_task(adapter({
            "type": "http",
            "path": "/ready",
            "client": ("127.0.0.1", 8787),
        }, None, send))
        assert await asyncio.to_thread(started.wait, 1)
        await request
        assert messages[0]["status"] == 503
        assert messages[1]["body"] == b'{"readiness":"unavailable"}'
        assert calls == 1

        release.set()
        inflight = adapter._inflight_readiness
        assert inflight is not None
        await asyncio.wait_for(asyncio.shield(inflight), 2)

    try:
        asyncio.run(exercise())
    finally:
        release.set()


def test_local_readiness_adapter_coalesces_concurrent_probes(monkeypatch) -> None:
    started = threading.Event()
    release = threading.Event()
    calls = 0

    def readiness_check() -> bool:
        nonlocal calls
        calls += 1
        started.set()
        release.wait(timeout=2)
        return True

    adapter = launcher.LocalReadinessAdapter(lambda *_: None, readiness_check)
    monkeypatch.setattr(launcher, "LOCAL_READINESS_TIMEOUT_SECONDS", 1.0)

    async def request() -> list:
        messages = []

        async def send(message):
            messages.append(message)

        await adapter({
            "type": "http",
            "path": "/ready",
            "client": ("127.0.0.1", 8787),
        }, None, send)
        return messages

    async def exercise() -> None:
        first = asyncio.create_task(request())
        assert await asyncio.to_thread(started.wait, 1)
        second = asyncio.create_task(request())
        await asyncio.sleep(0)
        assert calls == 1

        release.set()
        first_messages, second_messages = await asyncio.gather(first, second)
        assert first_messages[0]["status"] == 200
        assert second_messages[0]["status"] == 200
        assert calls == 1

    try:
        asyncio.run(exercise())
    finally:
        release.set()


def test_local_readiness_adapter_rejects_non_loopback_and_forwards_other_routes() -> None:
    forwarded = []

    async def app(scope, _receive, _send):
        forwarded.append(scope)

    adapter = launcher.LocalReadinessAdapter(app, lambda: True)
    forbidden = []

    async def send_forbidden(message):
        forbidden.append(message)

    asyncio.run(adapter({
        "type": "http",
        "path": "/ready",
        "client": ("192.0.2.10", 8787),
    }, None, send_forbidden))
    assert forbidden[0]["status"] == 403
    assert forwarded == []

    messages = []

    async def send_forwarded(message):
        messages.append(message)

    scope = {"type": "http", "path": "/health", "client": ("127.0.0.1", 8787)}
    asyncio.run(adapter(scope, None, send_forwarded))
    assert forwarded == [scope]
    assert messages == []


def test_current_gateway_dependencies_ready_rechecks_snapshot_service_and_api(
    monkeypatch,
) -> None:
    observed = {"serve": {"canonical": True}, "api": True, "service": 1234}

    monkeypatch.setattr(
        launcher,
        "_read_tailscale_snapshot",
        lambda path: (observed["serve"], "machine.example.ts.net", "operator@example.com"),
    )
    monkeypatch.setattr(
        launcher,
        "_serve_is_exact",
        lambda serve, expected_dns_name=None: serve is observed["serve"]
        and expected_dns_name == "machine.example.ts.net",
    )
    monkeypatch.setattr(launcher, "_is_windows_host", lambda: True)
    monkeypatch.setattr(
        launcher,
        "_windows_tailscale_service_pid",
        lambda name: observed["service"],
    )
    monkeypatch.setattr(launcher, "_loopback_api_ready", lambda url: observed["api"])

    assert launcher._current_gateway_dependencies_ready(
        "http://127.0.0.1:8787", "snapshot.json", "Tailscale"
    )

    observed["api"] = False
    assert not launcher._current_gateway_dependencies_ready(
        "http://127.0.0.1:8787", "snapshot.json", "Tailscale"
    )
    observed["api"] = True
    observed["service"] = None
    assert not launcher._current_gateway_dependencies_ready(
        "http://127.0.0.1:8787", "snapshot.json", "Tailscale"
    )
    observed["service"] = 1234
    observed["serve"] = {"changed": True}
    assert not launcher._current_gateway_dependencies_ready(
        "http://127.0.0.1:8787", "snapshot.json", "Tailscale"
    )


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


@pytest.fixture(autouse=True)
def runtime_snapshot(monkeypatch, tmp_path):
    path = write_snapshot(tmp_path, snapshot_payload(), name="runtime.json")
    monkeypatch.setenv("LIFEOS_TAILSCALE_SNAPSHOT_PATH", str(path))
    return path


def _valid_gateway_config(tmp_path: Path) -> dict:
    data = tmp_path / "data"
    documents = data / "documents"
    data.mkdir()
    documents.mkdir()
    secret = tmp_path / "claude.secret"
    secret.write_bytes(b"c" * 32)
    return {
        "bindHost": "127.0.0.1",
        "port": 8421,
        "apiBaseUrl": "http://127.0.0.1:8787",
        "dataDirectory": str(data),
        "calendarPath": str(data / "calendar.json"),
        "documentsPath": str(documents),
        "claudeSecretPath": str(secret),
        "tailscaleEdgeTokenPath": str(tmp_path / "tailscale-edge.token"),
        "tailscaleServePort": 8420,
        "funnel": False,
    }


def test_read_config_accepts_a_valid_config_without_mocking_path_validation(tmp_path: Path) -> None:
    config_path = tmp_path / "gateway.json"
    config_path.write_text(json.dumps(_valid_gateway_config(tmp_path)), encoding="utf-8")

    value = launcher._read_config(config_path)

    assert value["bindHost"] == "127.0.0.1"
    assert value["port"] == 8421
    assert value["dataDirectory"] == str(tmp_path / "data")


@pytest.mark.parametrize("reader", ["config", "secret"])
@pytest.mark.parametrize("replacement", [False, True])
def test_bounded_config_and_secret_reads_fail_closed_on_growth_or_replacement(
    monkeypatch, tmp_path: Path, reader: str, replacement: bool
) -> None:
    config = _valid_gateway_config(tmp_path)
    config_path = tmp_path / "gateway.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    edge_token_path = tmp_path / "tailscale-edge.token"
    edge_token_path.write_bytes(b"t" * 32)
    target = config_path if reader == "config" else Path(config["claudeSecretPath"])
    original_read = launcher.os.read
    mutated = False

    def read_and_mutate(descriptor: int, count: int) -> bytes:
        nonlocal mutated
        value = original_read(descriptor, count)
        descriptor_identity = os.fstat(descriptor)
        target_identity = target.stat()
        # Match the descriptor itself so a config EOF read cannot trigger the
        # secret fixture before the secret descriptor has supplied bytes.
        is_target_descriptor = (
            descriptor_identity.st_dev == target_identity.st_dev
            and descriptor_identity.st_ino == target_identity.st_ino
        )
        if not mutated and is_target_descriptor:
            mutated = True
            if replacement:
                replacement_path = target.with_suffix(target.suffix + ".replacement")
                replacement_path.write_bytes(b"x" * max(32, target_identity.st_size))
                replacement_path.replace(target)
            else:
                with target.open("ab") as stream:
                    stream.write(b"x" * 32)
        return value

    monkeypatch.setattr(launcher.os, "read", read_and_mutate)
    with pytest.raises(RuntimeError, match="invalid|changed|identity|oversized"):
        launcher._read_config(config_path)


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


@pytest.mark.parametrize("mutation", ["stale", "login", "dns", "malformed", "duplicate", "route", "capability", "funnel", "missing"])
def test_runtime_lease_revalidates_after_startup(monkeypatch, runtime_snapshot, mutation):
    now = datetime(2026, 9, 8, tzinfo=timezone.utc)
    class Clock(datetime):
        @classmethod
        def now(cls, tz=None):
            return now
    monkeypatch.setattr(launcher, "datetime", Clock)
    payload = snapshot_payload(observedAt=now.isoformat())
    runtime_snapshot.write_text(json.dumps(payload))
    calls = []
    async def app(scope, receive, send):
        calls.append(scope)
        await send({"type": "http.response.start", "status": 200, "headers": []})
        await send({"type": "http.response.body", "body": b"ok"})
    adapter = launcher.TrustedEdgeHeaderAdapter(app, "t" * 32, peer_verifier=lambda _: True)
    messages = []
    async def send(message):
        messages.append(message)
    scope = {"type": "http", "headers": [(b"tailscale-app-capabilities", json.dumps({
        launcher.TRUSTED_EDGE_APP_CAPABILITY: [{"src": ["*"]}]}).encode())]}
    async def exercise():
        nonlocal now
        await adapter(scope, None, send)
        assert messages[0]["status"] == 200
        assert (launcher.TRUSTED_EDGE_HEADER, b"t" * 32) in calls[0]["headers"]
        if mutation == "stale":
            now += timedelta(seconds=91)
        elif mutation == "login":
            payload["login"] = "other@example.com"
        elif mutation == "dns":
            payload["dnsName"] = "other.example.ts.net"
            payload["identity"] = {"Self": {"DNSName": "other.example.ts.net"}}
        elif mutation == "route":
            payload["serve"] = {}
        elif mutation == "capability":
            payload["serve"]["Web"]["machine.example.ts.net:8420"]["Handlers"]["/"]["AcceptAppCaps"] = []
        elif mutation == "funnel":
            payload["serve"]["AllowFunnel"] = {"machine.example.ts.net:8420": True}
        raw = json.dumps(payload)
        if mutation == "malformed":
            raw = "{broken"
        elif mutation == "duplicate":
            raw = raw.replace('"schemaVersion": 1', '"schemaVersion": 2, "schemaVersion": 1')
        runtime_snapshot.write_text(raw)
        if mutation == "missing":
            runtime_snapshot.unlink()
        messages.clear()
        await adapter(scope, None, send)
        assert messages[0]["status"] == 503
        assert len(calls) == 1
    try:
        asyncio.run(exercise())
    finally:
        adapter._reader.shutdown()


@pytest.mark.parametrize("kind", ["websocket", "http"])
@pytest.mark.parametrize("idle", [False, True])
def test_runtime_stream_continuation_and_expiry(monkeypatch, runtime_snapshot, kind, idle):
    async def exercise():
        messages = []
        continued = asyncio.Event()
        cancelled = asyncio.Event()
        ticks = asyncio.Queue()
        real_sleep = asyncio.sleep
        async def tick(_interval):
            assert _interval == launcher.TAILSCALE_RUNTIME_LEASE_SECONDS
            await ticks.get()
        monkeypatch.setattr(launcher.asyncio, "sleep", tick)
        async def send(message):
            messages.append(message)
        async def app(scope, receive, send):
            try:
                if kind == "websocket":
                    await send({"type": "websocket.accept"})
                    await send({"type": "websocket.send", "text": "valid"})
                else:
                    await send({"type": "http.response.start", "status": 200, "headers": []})
                    await send({"type": "http.response.body", "body": b"valid", "more_body": True})
                continued.set()
                if idle:
                    await asyncio.Event().wait()
                else:
                    await proceed.wait()
                    await send({"type": "websocket.send", "text": "forbidden"} if kind == "websocket"
                               else {"type": "http.response.body", "body": b"forbidden", "more_body": True})
            finally:
                cancelled.set()
        proceed = asyncio.Event()
        adapter = launcher.TrustedEdgeHeaderAdapter(app, "t" * 32, peer_verifier=lambda _: True)
        task = asyncio.create_task(adapter({"type": kind, "headers": []}, None, send))
        try:
            await asyncio.wait_for(continued.wait(), 2)
            assert len(messages) == 2
            runtime_snapshot.write_text(json.dumps(snapshot_payload(
                observedAt=(datetime.now(timezone.utc) - timedelta(seconds=91)).isoformat())))
            if idle:
                ticks.put_nowait(None)
            else:
                proceed.set()
            if kind == "http":
                with pytest.raises(RuntimeError, match="trusted edge lease expired"):
                    await asyncio.wait_for(task, 2)
                assert len(messages) == 2  # no successful terminal body
            else:
                await asyncio.wait_for(task, 2)
                assert messages[-1] == {"type": "websocket.close", "code": 4403}
            assert cancelled.is_set()
            assert not any(m.get("text") == "forbidden" or m.get("body") == b"forbidden" for m in messages)
        finally:
            task.cancel()
            await asyncio.gather(task, return_exceptions=True)
            adapter._reader.shutdown()
            monkeypatch.setattr(launcher.asyncio, "sleep", real_sleep)
    asyncio.run(exercise())


def test_runtime_lease_timeout_fails_closed_without_queueing_reads(monkeypatch, runtime_snapshot):
    from concurrent.futures import Future
    pending = Future()
    submissions = []
    adapter = launcher.TrustedEdgeHeaderAdapter(None, "t" * 32)
    adapter._reader.shutdown()
    adapter._reader = SimpleNamespace(submit=lambda fn: submissions.append(fn) or pending)
    monkeypatch.setattr(launcher, "TAILSCALE_RUNTIME_READ_TIMEOUT_SECONDS", 0.001)
    async def exercise():
        assert not await adapter._lease_valid()
        assert not await adapter._lease_valid()
        assert len(submissions) == 1
        assert not pending.cancelled()
        pending.set_result(False)
    asyncio.run(exercise())


def test_runtime_receive_rejects_revoked_snapshot_before_delivery(runtime_snapshot):
    delivered = []
    messages = []
    async def receive():
        runtime_snapshot.write_text(json.dumps(snapshot_payload(serve={})))
        return {"type": "websocket.receive", "text": "must not arrive"}
    async def send(message):
        messages.append(message)
    async def app(scope, receive, send):
        await send({"type": "websocket.accept"})
        delivered.append(await receive())
    adapter = launcher.TrustedEdgeHeaderAdapter(app, "t" * 32, peer_verifier=lambda _: True)
    try:
        asyncio.run(adapter({"type": "websocket", "headers": []}, receive, send))
        assert not delivered
        assert messages[-1] == {"type": "websocket.close", "code": 4403}
    finally:
        adapter._reader.shutdown()
