import asyncio
import base64
import copy
import hashlib
import json
import os
import re
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import httpx
import pytest
from fastapi.testclient import TestClient
from starlette.requests import Request
from starlette.websockets import WebSocketDisconnect

os.environ["LIFEOS_TAILSCALE_ALLOWED_LOGIN"] = "test-user@example.com"
os.environ["LIFEOS_TAILSCALE_EDGE_TOKEN"] = "e" * 64

import main
from main import app

client = TestClient(app)
TAILSCALE_IDENTITY = {"Tailscale-User-Login": "test-user@example.com"}
EDGE_AUTH = {"X-LifeOS-Trusted-Edge": "e" * 64, **TAILSCALE_IDENTITY}
AUTH = dict(EDGE_AUTH)
USAGE_OBSERVED_AT = (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat().replace("+00:00", "Z")
VALID = {
    "generatedAt": USAGE_OBSERVED_AT,
    "windows": [{
        "provider": "codex",
        "window": "seven_day",
        "durationMinutes": 10080,
        "usedPercent": 2,
        "resetAt": "2026-08-15T07:00:59Z",
        "availability": "observed",
        "provenance": {
            "source": "codex-app-server",
            "observedAt": USAGE_OBSERVED_AT,
            "freshness": "fresh",
            "official": True,
            "quality": "observed",
            "connectorState": "healthy",
        },
    }],
    "estimates": [{
        "provider": "codex",
        "window": "seven_day",
        "projectedPercentAtReset": 4,
        "velocityPercentPerHour": 0.1,
        "confidence": "medium",
        "sampleSpanHours": 24,
        "explanation": "Observed trend",
        "official": False,
    }],
    "connectors": {
        "codex": "healthy",
        "claude": "unavailable",
        "glm": "unavailable",
        "deepseek": "unavailable",
        "google_ai_studio": "unavailable",
    },
}


def multipart_part(name, body, *, filename=None, content_type=None):
    headers = [f'Content-Disposition: form-data; name="{name}"']
    if filename is not None:
        headers[0] += f'; filename="{filename}"'
    if content_type is not None:
        headers.append(f"Content-Type: {content_type}")
    return "\r\n".join(headers).encode("ascii") + b"\r\n\r\n" + body


def multipart_body(parts, boundary="lifeos-test-boundary"):
    return b"".join(
        b"--" + boundary.encode("ascii") + b"\r\n" + part + b"\r\n"
        for part in parts
    ) + b"--" + boundary.encode("ascii") + b"--\r\n"


def streamed_request(body, *, boundary="lifeos-test-boundary", chunk_size=7, content_length=None):
    chunks = [body[index:index + chunk_size] for index in range(0, len(body), chunk_size)]
    if not chunks:
        chunks = [b""]
    messages = [
        {
            "type": "http.request",
            "body": chunk,
            "more_body": index < len(chunks) - 1,
        }
        for index, chunk in enumerate(chunks)
    ]
    headers = [(b"content-type", f"multipart/form-data; boundary={boundary}".encode("ascii"))]
    if content_length is not None:
        headers.append((b"content-length", str(content_length).encode("ascii")))

    async def receive():
        return messages.pop(0)

    return Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/documents",
            "headers": headers,
        },
        receive,
    )


def run_document_upload(body, **request_options):
    return asyncio.run(main.upload_document(streamed_request(body, **request_options)))


def tax_document_metadata(document_id, **overrides):
    metadata = {
        "id": document_id,
        "title": "Tax document",
        "documentType": "tax_return",
        "taxYear": None,
        "issuer": None,
        "taxpayerIdentifier": None,
        "referenceIdentifier": None,
        "dates": [],
        "amounts": [],
        "warnings": [],
        "confidence": "low",
    }
    metadata.update(overrides)
    return metadata


def tax_evidence(page=1, snippet="Source-backed evidence"):
    return {"page": page, "snippet": snippet}


def tax_candidate(value="Finanzamt Berlin", *, page=1, snippet=None):
    return {
        "value": value,
        "evidence": tax_evidence(page, value if snippet is None else snippet),
    }


def native_tax_document_metadata(document_id):
    return tax_document_metadata(
        document_id,
        title="Income tax assessment",
        documentType="tax_assessment",
        taxYear=2025,
        issuer=tax_candidate(),
        taxpayerIdentifier=tax_candidate("********01"),
        referenceIdentifier=tax_candidate("********34"),
        dates=[{
            "value": "2025-01-31",
            "evidence": tax_evidence(1, "Assessment date"),
        }],
        amounts=[{
            "value": "1234.56 EUR",
            "label": "Tax owed",
            "evidence": tax_evidence(1, "Tax owed 1234.56 EUR"),
        }],
        warnings=["Review source document"],
        confidence="high",
    )

FINANCE_PROVENANCE = {
    "source": "no-authorized-finance-source",
    "observedAt": "2026-08-08T12:00:00Z",
    "freshness": "unknown",
    "quality": "unavailable",
    "connectorState": "unavailable",
}
VALID_FINANCE = {
    "generatedAt": "2026-08-08T12:00:00Z",
    "currency": "EUR",
    **{
        key: {"availability": "unavailable", "provenance": copy.deepcopy(FINANCE_PROVENANCE)}
        for key in ("monthlyIncome", "fixedCosts", "discretionaryBuffer", "spent", "savingsGoal", "saved")
    },
}

CLIPPER_OBSERVED_AT = (datetime.now(timezone.utc) - timedelta(seconds=30)).isoformat().replace("+00:00", "Z")
VALID_CLIPPER_UNAVAILABLE = {
    "schemaVersion": 1,
    "availability": "unavailable",
    "generatedAt": CLIPPER_OBSERVED_AT,
    "currency": "EUR",
    "provenance": {
        "source": "no-authorized-clipper-source",
        "observedAt": CLIPPER_OBSERVED_AT,
        "freshness": "unknown",
        "quality": "unavailable",
        "connectorState": "unavailable",
    },
}

_CLIPPER_PROVENANCE = {
    "source": "hermes-test-source",
    "observedAt": CLIPPER_OBSERVED_AT,
    "freshness": "fresh",
    "quality": "observed",
    "connectorState": "healthy",
}
_CLIPPER_METRICS = {
    "views": {"availability": "observed", "value": 100, "provenance": _CLIPPER_PROVENANCE},
    "subscribers": {"availability": "observed", "value": 10, "provenance": _CLIPPER_PROVENANCE},
    "revenue": {"availability": "observed", "amountCents": 2500, "currency": "EUR", "provenance": _CLIPPER_PROVENANCE},
}
VALID_CLIPPER_OBSERVED = {
    "schemaVersion": 1,
    "availability": "observed",
    "generatedAt": CLIPPER_OBSERVED_AT,
    "currency": "EUR",
    "metrics": _CLIPPER_METRICS,
    "accounts": [],
    "trends": [],
    "breakdowns": [],
    "provenance": {**_CLIPPER_PROVENANCE},
}


class FakeResponse:
    def __init__(self, body, status_code=200, *, include_content_length=True, chunk_size=None, delay=0):
        self.status_code = status_code
        self.body = body
        self.headers = {"content-length": str(len(body))} if include_content_length else {}
        self.chunk_size = chunk_size or len(body)
        self.delay = delay

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    async def aiter_bytes(self):
        if self.delay:
            await asyncio.sleep(self.delay)
        for start in range(0, len(self.body), self.chunk_size):
            yield self.body[start:start + self.chunk_size]


class FakeClient:
    def __init__(self, response=None, error=None, **_):
        self.response = response
        self.error = error

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    def stream(self, *_args, **_kwargs):
        if self.error:
            raise self.error
        return self.response


class CapturingClient(FakeClient):
    def __init__(self, calls, response=None, error=None, **kwargs):
        super().__init__(response, error, **kwargs)
        self.calls = calls

    def stream(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        return super().stream(method, url, **kwargs)


class FakeIngestUpstreamResponse:
    def __init__(self, status_code=204, body=b"", *, include_content_length=True, chunk_size=None):
        self.status_code = status_code
        self.body = body
        self.headers = {"content-length": str(len(body))} if include_content_length else {}
        self.chunk_size = chunk_size or len(body) or 1

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    async def aiter_bytes(self):
        for start in range(0, len(self.body), self.chunk_size):
            yield self.body[start:start + self.chunk_size]


class FakeIngestClient:
    def __init__(self, calls, response=None, error=None, **kwargs):
        self.calls = calls
        self.response = response or FakeIngestUpstreamResponse()
        self.error = error
        self.options = kwargs

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    def stream(self, method, url, **kwargs):
        assert method == "POST"
        self.calls.append((url, kwargs))
        if self.error:
            raise self.error
        return self.response


def request_with(response=None, error=None):
    return patch("main.httpx.AsyncClient", lambda **kwargs: FakeClient(response, error, **kwargs))


CLAUDE_INGEST = "/usage/claude-ingest"
VALID_CLAUDE_INGEST = {
    "rate_limits": {
        "five_hour": {"used_percentage": 12.5, "resets_at": 1_786_777_259},
        "seven_day": {"used_percentage": 34, "resets_at": 1_787_000_000},
    }
}


def configure_ingest_secret(tmp_path, monkeypatch, value="s" * 32):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.delenv("CLAUDE_INGEST_SECRET_FILE", raising=False)
    path = tmp_path / main.CLAUDE_INGEST_SECRET_FILENAME
    path.write_bytes(value.encode("ascii"))
    if os.name == "posix":
        path.chmod(0o600)


def ingest_headers(**extra):
    return {**AUTH, "content-type": "application/json", **extra}


def test_atomic_writer_publishes_an_ordinary_file_and_cleans_up(tmp_path):
    target = tmp_path / "state.json"

    main._atomic_write_bytes(target, b"bounded")

    assert target.read_bytes() == b"bounded"
    assert [entry.name for entry in tmp_path.iterdir()] == ["state.json"]
    if os.name == "posix":
        assert target.stat().st_mode & 0o777 == 0o600


@pytest.mark.parametrize("writer_kind", ["calendar", "enablebanking"])
@pytest.mark.skipif(os.name == "nt", reason="POSIX descriptor-relative boundary")
def test_atomic_writer_keeps_temp_publish_and_cleanup_on_the_open_directory(
    tmp_path, monkeypatch, writer_kind
):
    storage = tmp_path / "storage"
    displaced = tmp_path / "displaced-storage"
    storage.mkdir()
    original_open = os.open
    swapped = False

    def open_and_replace_ancestor(path, flags, mode=0o777, *, dir_fd=None):
        nonlocal swapped
        descriptor = original_open(path, flags, mode, dir_fd=dir_fd)
        if (
            dir_fd is None
            and not swapped
            and os.path.abspath(os.fspath(path)) == os.path.abspath(os.fspath(storage))
        ):
            swapped = True
            os.replace(storage, displaced)
            storage.mkdir(mode=0o700)
        return descriptor

    monkeypatch.setattr(main.os, "open", open_and_replace_ancestor)
    target = storage / "state.json"
    if writer_kind == "calendar":
        writer = lambda: main._atomic_write_bytes(target, b"bounded")
    else:
        import enablebanking

        service = object.__new__(enablebanking.EnableBankingService)
        writer = lambda: service._atomic_write_json(target, {"value": "bounded"})

    with pytest.raises(OSError):
        writer()

    assert swapped
    assert list(storage.iterdir()) == []
    assert list(displaced.iterdir()) == []


@pytest.mark.parametrize("writer_kind", ["calendar", "enablebanking"])
@pytest.mark.skipif(os.name == "nt", reason="POSIX descriptor-relative boundary")
def test_atomic_writer_rejects_parent_replacement_before_temp_creation(
    tmp_path, monkeypatch, writer_kind
):
    storage = tmp_path / "storage"
    displaced = tmp_path / "displaced-storage"
    storage.mkdir()
    original_open = os.open
    swapped = False

    def open_after_parent_replacement(path, flags, mode=0o777, *, dir_fd=None):
        nonlocal swapped
        if (
            dir_fd is None
            and not swapped
            and os.path.abspath(os.fspath(path)) == os.path.abspath(os.fspath(storage))
        ):
            swapped = True
            os.replace(storage, displaced)
            storage.mkdir(mode=0o700)
        return original_open(path, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(main.os, "open", open_after_parent_replacement)
    target = storage / "state.json"
    if writer_kind == "calendar":
        writer = lambda: main._atomic_write_bytes(target, b"bounded")
    else:
        import enablebanking

        service = object.__new__(enablebanking.EnableBankingService)
        writer = lambda: service._atomic_write_json(target, {"value": "bounded"})

    with pytest.raises(OSError):
        writer()

    assert swapped
    # The descriptor identity check runs before O_EXCL creates a temporary
    # entry in the replacement directory.
    assert list(storage.iterdir()) == []
    assert list(displaced.iterdir()) == []


def test_windows_storage_contract_rejects_untrusted_mutation_acl():
    foreign = "S-1-5-21-400-500-600-700"
    management = "S-1-5-21-100-200-300-400"
    service = "S-1-5-80-111-222-333-444-555"
    with pytest.raises(OSError, match="unsafe_storage_contract"):
        main.validate_windows_acl_sddl(
            f"O:{foreign}G:SYD:(A;;FA;;;{foreign})",
            service,
            management,
        )

    # Conditional and other unsupported ACE types must fail closed because
    # this parser cannot prove their effective grant semantics.
    with pytest.raises(OSError, match="unsafe_storage_contract"):
        main.validate_windows_acl_sddl(
            f"O:{service}G:SYD:(XA;;FA;;;{foreign})",
            service,
            management,
        )

    # The deployment contract permits the recorded operator SID and the
    # current virtual service SID, but the observed owner is never trusted.
    main.validate_windows_acl_sddl(
        f"O:{management}G:SYD:(A;;FA;;;{management})(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;WD)",
        service,
        management,
    )

    # Read-only broad inheritance does not permit ancestor replacement and is
    # compatible with ordinary Windows system ancestors.
    main.validate_windows_acl_sddl("O:SYG:SYD:(A;;FR;;;WD)", "S-1-5-18")


def test_protected_storage_overload_returns_safe_service_unavailable(monkeypatch):
    async def overloaded(*args, **kwargs):
        raise main.ProtectedStorageOverloaded()

    monkeypatch.setattr(main, "_run_gateway_storage", overloaded)

    response = client.get("/calendar", headers=AUTH)

    assert response.status_code == 503
    assert response.json() == {"error": "storage_busy"}
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["retry-after"] == "1"


def test_usage_healthy_proxy():
    body = json.dumps(VALID).encode()
    with request_with(FakeResponse(body)):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 200
    assert response.json() == VALID
    assert response.headers["cache-control"] == "no-store"


def test_usage_forwards_local_service_bearer():
    calls = []
    body = json.dumps(VALID).encode()
    with patch(
        "main.httpx.AsyncClient",
        lambda **kwargs: CapturingClient(calls, FakeResponse(body), **kwargs),
    ):
        response = client.get("/usage", headers=AUTH)

    assert response.status_code == 200
    assert len(calls) == 1
    method, url, options = calls[0]
    assert method == "GET"
    assert url == main.USAGE_UPSTREAM
    assert options["headers"] == {"Authorization": "Bearer " + "l" * 64}


def test_identity_authorizes_with_obsolete_bearer_for_cutover_compatibility():
    body = json.dumps(VALID).encode()
    with request_with(FakeResponse(body)):
        response = client.get(
            "/usage",
            headers={**AUTH, "Authorization": "Bearer old-transitional-token"},
        )
    assert response.status_code == 200
    assert response.json() == VALID


def test_usage_missing_identity_and_old_bearer_are_rejected():
    assert client.get("/usage").status_code == 403
    assert client.get(
        "/usage", headers={"Authorization": "Bearer old-transitional-token"}
    ).status_code == 403


def test_http_requires_exact_single_tailscale_login():
    assert client.get(
        "/usage",
        headers={"Tailscale-User-Login": "other-user@example.com"},
    ).status_code == 403
    assert client.get(
        "/usage",
        headers={"Tailscale-User-Login": " test-user@example.com"},
    ).status_code == 403
    assert client.get(
        "/usage",
        headers={"Tailscale-User-Login": "test-user@example.com,other-user@example.com"},
    ).status_code == 403
    assert client.get(
        "/usage",
        headers={"Tailscale-User-Name": "Test User"},
    ).status_code == 403
    assert client.get(
        "/usage",
        headers=[
            ("Tailscale-User-Login", "test-user@example.com"),
            ("Tailscale-User-Login", "test-user@example.com"),
        ],
    ).status_code == 403


def test_canonical_serve_identity_without_trusted_edge_cannot_authorize():
    assert client.get("/usage", headers=TAILSCALE_IDENTITY).status_code == 403
    assert client.get(
        "/usage",
        headers={**TAILSCALE_IDENTITY, "X-LifeOS-Trusted-Edge": "wrong-" + "e" * 64},
    ).status_code == 403
    assert client.get(
        "/usage",
        headers=[
            ("Tailscale-User-Login", "test-user@example.com"),
            ("X-LifeOS-Trusted-Edge", "e" * 64),
            ("X-LifeOS-Trusted-Edge", "e" * 64),
        ],
    ).status_code == 403


def test_forged_alternate_identity_headers_cannot_authorize_protected_routes():
    forged_headers = [
        {"Authorization": "Bearer old-transitional-token"},
        {"X-Tailscale-User-Login": "test-user@example.com"},
        {"X-Forwarded-User": "test-user@example.com"},
        {"Remote-User": "test-user@example.com"},
        {"Tailscale-User-Name": "test-user@example.com"},
        {
            "Tailscale-User-Login": "other-user@example.com",
            "Tailscale-User-Name": "test-user@example.com",
            "Authorization": "Bearer old-transitional-token",
        },
    ]
    for headers in forged_headers:
        assert client.get("/health", headers=headers).status_code == 200
        assert client.get("/usage", headers=headers).status_code == 403

    assert client.get(
        "/usage",
        headers=[
            ("Tailscale-User-Login", "test-user@example.com"),
            ("Tailscale-User-Login", "other-user@example.com"),
        ],
    ).status_code == 403


def test_health_probe_remains_available_without_identity_or_bearer():
    assert client.get("/health").status_code == 200


def test_protected_routes_require_the_snapshot_host_contract_and_emit_nosniff(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "ALLOWED_HOSTS", frozenset({
        "machine.example.ts.net",
        "machine.example.ts.net:8420",
    }))
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")

    for host in ("machine.example.ts.net", "machine.example.ts.net:8420"):
        response = client.get("/calendar", headers={**AUTH, "Host": host})
        assert response.status_code == 200
        assert response.headers["x-content-type-options"] == "nosniff"

    for host in (
        "testserver",
        "machine.example.ts.net:8421",
        "machine.example.ts.net.evil.example",
        "machine.example.ts.net:8420.evil.example",
    ):
        response = client.get("/calendar", headers={**AUTH, "Host": host})
        assert response.status_code == 400
        assert response.headers["x-content-type-options"] == "nosniff"

    duplicate_host = client.get(
        "/calendar",
        headers=[*AUTH.items(), ("Host", "machine.example.ts.net:8420"),
                 ("Host", "machine.example.ts.net:8420")],
    )
    assert duplicate_host.status_code == 400
    assert duplicate_host.headers["x-content-type-options"] == "nosniff"


def test_browser_origin_policy_comes_from_the_enable_banking_redirect_origin(monkeypatch):
    monkeypatch.setenv(
        "ENABLE_BANKING_REDIRECT_URI",
        "https://GeonqServer.tail5f8789.ts.net:8420/finance/callback",
    )
    assert main._configured_browser_origins() == frozenset({
        "https://geonqserver.tail5f8789.ts.net:8420",
    })
    monkeypatch.setenv(
        "ENABLE_BANKING_REDIRECT_URI",
        "https://geonqserver.tail5f8789.ts.net:8420/finance/callback?unexpected=query",
    )
    assert main._configured_browser_origins() == frozenset()


@pytest.mark.parametrize(("method", "path"), [
    ("put", "/calendar"),
    ("post", "/documents"),
    ("post", "/finance/connect"),
    ("delete", "/finance/connect/test-institution"),
    ("put", "/finance/imported"),
    ("post", "/nutrition/photo-proposal"),
])
def test_cross_origin_mutations_are_rejected_before_route_body_handling(method, path):
    response = client.request(
        method.upper(),
        path,
        headers={
            **AUTH,
            "Origin": "https://evil.example",
            "Sec-Fetch-Site": "cross-site",
            "Content-Type": "application/json",
        },
        content=b"this body must not reach the route",
    )
    assert response.status_code == 403
    assert response.json() == {"detail": "Untrusted browser origin"}


def test_originless_native_calendar_mutation_remains_accepted(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    response = client.put(
        "/calendar",
        headers=calendar_write_headers(initial.headers["etag"], "originless-native"),
        json={"schemaVersion": 1, "items": [calendar_item("native")]},
    )
    assert response.status_code == 200


def test_allowed_browser_origin_can_mutate_with_same_origin_fetch_metadata(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "ALLOWED_BROWSER_ORIGINS", frozenset({
        "https://geonqserver.tail5f8789.ts.net:8420",
    }))
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    headers = calendar_write_headers(initial.headers["etag"], "trusted-browser")
    headers.update({
        "Origin": "https://GeonqServer.tail5f8789.ts.net:8420/",
        "Sec-Fetch-Site": "same-origin",
    })
    response = client.put(
        "/calendar",
        headers=headers,
        json={"schemaVersion": 1, "items": [calendar_item("browser")]},
    )
    assert response.status_code == 200


def test_enable_banking_callback_allows_provider_cross_site_navigation(monkeypatch):
    async def callback(_query):
        return SimpleNamespace(valid=True, linked=True)

    monkeypatch.setattr(main.enable_banking, "callback", callback)
    response = client.get(
        "/finance/callback?code=provider-code&state=one-time-state",
        headers={
            **AUTH,
            "Origin": "https://provider.example",
            "Sec-Fetch-Site": "cross-site",
        },
    )
    assert response.status_code == 200
    assert "Connected" in response.text


def calendar_item(title="Event", **overrides):
    return {
        "id": "01234567-89ab-cdef-0123-456789abcdef",
        "title": title, "status": "planned", "kind": "event",
        "start": "2026-09-08T08:00:00Z", "end": "2026-09-08T09:00:00Z",
        "createdAt": "2026-09-07T08:00:00Z", "updatedAt": "2026-09-07T08:00:00Z",
        **overrides,
    }


def calendar_items(count):
    return [
        calendar_item(
            title=f"Event {index}",
            id=f"00000000-0000-0000-0000-{index:012x}",
        )
        for index in range(count)
    ]


def test_calendar_uses_versioned_etag_if_match_and_bounded_idempotent_replay(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    assert initial.status_code == 200
    assert initial.json() == {"schemaVersion": 1, "items": []}
    assert re.fullmatch(r'"calendar-v1-r0-[0-9a-f]{64}"', initial.headers["etag"])
    assert initial.headers["x-lifeos-schema-version"] == "1"
    assert initial.headers["x-lifeos-revision"] == "0"

    first_body = {"schemaVersion": 1, "items": [calendar_item("event-1")]}
    first_headers = {
        **AUTH,
        "content-type": "application/json",
        "if-match": initial.headers["etag"],
        "idempotency-key": "calendar-write-1",
    }
    accepted = client.put("/calendar", headers=first_headers, content=json.dumps(first_body))
    assert accepted.status_code == 200
    assert accepted.json() == first_body
    assert accepted.headers["x-lifeos-revision"] == "1"
    assert accepted.headers["etag"] != initial.headers["etag"]
    assert (tmp_path / "calendar.json.meta.json").is_file()

    stale = client.put(
        "/calendar",
        headers={**first_headers, "idempotency-key": "calendar-stale"},
        content=json.dumps({"schemaVersion": 1, "items": [calendar_item("stale")]}),
    )
    assert stale.status_code == 412
    assert stale.content == accepted.content
    assert stale.headers["etag"] == accepted.headers["etag"]

    for _ in range(10):
        replay = client.put("/calendar", headers=first_headers, content=json.dumps(first_body))
        assert replay.status_code == 200
        assert replay.headers["x-lifeos-idempotent-replay"] == "true"
        assert replay.content == accepted.content

    reuse = client.put(
        "/calendar", headers=first_headers,
        content=json.dumps({"schemaVersion": 1, "items": [calendar_item("different")]}),
    )
    assert reuse.status_code == 409
    assert reuse.content == accepted.content


def test_calendar_idempotency_window_rolls_forward_and_survives_restart(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    monkeypatch.setattr(main, "CALENDAR_MAX_IDEMPOTENCY_RECORDS", 2)

    current = client.get("/calendar", headers=AUTH)
    accepted = []
    for index in range(3):
        body = {"schemaVersion": 1, "items": [calendar_item(f"rollover-{index}")]}
        headers = {
            **AUTH,
            "content-type": "application/json",
            "if-match": current.headers["etag"],
            "idempotency-key": f"rollover-write-{index}",
        }
        response = client.put("/calendar", headers=headers, json=body)
        assert response.status_code == 200
        accepted.append((headers, body, response))
        current = response

    assert current.headers["x-lifeos-revision"] == "3"
    state_body, _document, metadata = main._load_calendar_state()
    assert json.loads(state_body)["schemaVersion"] == 1
    assert [record["key"] for record in metadata["idempotency"]] == [
        "rollover-write-1",
        "rollover-write-2",
    ]
    assert [record["revision"] for record in metadata["idempotency"]] == [2, 3]

    # The newest retained key is still a replay after the journal rolled over;
    # replaying it does not create revision 4.
    replay = client.put(
        "/calendar",
        headers=accepted[2][0],
        json=accepted[2][1],
    )
    assert replay.status_code == 200
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replay.headers["x-lifeos-revision"] == "3"

    # The expired key is not silently accepted with its stale conditional
    # token.  A process restart sees the same bounded, durable window.
    expired = client.put(
        "/calendar",
        headers=accepted[0][0],
        json=accepted[0][1],
    )
    assert expired.status_code == 412
    assert expired.headers["x-lifeos-revision"] == "3"
    _restarted_body, _restarted_document, restarted_metadata = main._load_calendar_state()
    assert [record["key"] for record in restarted_metadata["idempotency"]] == [
        "rollover-write-1",
        "rollover-write-2",
    ]


def test_calendar_rejects_missing_identity_conditional_headers_and_torn_state(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    assert client.get("/calendar").status_code == 403
    initial = client.get("/calendar", headers=AUTH)
    body = json.dumps({"schemaVersion": 1, "items": []})
    assert client.put("/calendar", headers={**AUTH, "content-type": "application/json"}, content=body).status_code == 428
    assert client.put(
        "/calendar",
        headers={**AUTH, "content-type": "application/json", "if-match": initial.headers["etag"]},
        content=body,
    ).status_code == 400
    assert client.put(
        "/calendar",
        headers={**AUTH, "content-type": "application/json", "if-match": "W/\"weak\"", "idempotency-key": "bad"},
        content=body,
    ).status_code == 400
    assert client.put(
        "/calendar",
        headers={**AUTH, "content-type": "application/json", "if-match": '"calendar-v1-r9007199254740992-' + "a" * 64 + '"', "idempotency-key": "unsafe-revision"},
        content=body,
    ).status_code == 400

    # A truncated committed envelope is a bounded recovery failure. The
    # compatibility projection is deliberately not a fallback once the
    # authoritative state file exists.
    (tmp_path / "calendar.json.state.json").write_text("{\"schemaVersion\":1,\"bodyBase64\":")
    assert client.get("/calendar", headers=AUTH).status_code == 503


def test_calendar_ignores_an_interrupted_temporary_publish_and_keeps_last_commit(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    body = {"schemaVersion": 1, "items": [calendar_item("committed")]}
    accepted = client.put(
        "/calendar",
        headers={
            **AUTH,
            "content-type": "application/json",
            "if-match": initial.headers["etag"],
            "idempotency-key": "committed-write",
        },
        json=body,
    )
    assert accepted.status_code == 200
    state_path = tmp_path / "calendar.json.state.json"
    committed_state = state_path.read_bytes()
    (tmp_path / ".calendar.json.state.json.interrupted.tmp").write_bytes(b"{\"schemaVersion\":1")

    current = client.get("/calendar", headers=AUTH)
    assert current.status_code == 200
    assert current.json() == body
    assert state_path.read_bytes() == committed_state


def test_calendar_authoritative_commit_survives_projection_failure_and_replay_repairs_and_rebroadcasts(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    events = []

    async def capture(message):
        events.append(message)

    monkeypatch.setattr(main.broadcaster, "broadcast", capture)
    original_write = main._atomic_write_bytes
    projection_failed = False

    def fail_projection_once(path, data):
        nonlocal projection_failed
        if path == tmp_path / "calendar.json.meta.json" and not projection_failed:
            projection_failed = True
            raise OSError("projection unavailable")
        return original_write(path, data)

    monkeypatch.setattr(main, "_atomic_write_bytes", fail_projection_once)
    initial = client.get("/calendar", headers=AUTH)
    body = {"schemaVersion": 1, "items": [calendar_item("projection-recovery")]}
    headers = {
        **AUTH,
        "content-type": "application/json",
        "if-match": initial.headers["etag"],
        "idempotency-key": "projection-recovery-write",
    }

    accepted = client.put("/calendar", headers=headers, json=body)
    assert accepted.status_code == 200
    assert accepted.headers["x-lifeos-projection-repair"] == "pending"
    assert (tmp_path / "calendar.json.state.json").is_file()
    assert (tmp_path / "calendar.json.retry.json").is_file()
    assert not (tmp_path / "calendar.json.meta.json").is_file()

    replay = client.put("/calendar", headers=headers, json=body)
    assert replay.status_code == 200
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replay.headers.get("x-lifeos-projection-repair") is None
    assert (tmp_path / "calendar.json.meta.json").is_file()
    assert (tmp_path / "calendar.json").read_bytes() == accepted.content
    assert not (tmp_path / "calendar.json.retry.json").exists()
    assert events == [
        {"type": "calendar_changed", "revision": 1},
        {"type": "calendar_changed", "revision": 1},
    ]


def test_calendar_broadcast_failure_returns_success_and_replay_rebroadcasts(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    broadcast_calls = []

    async def fail_broadcast(_message):
        broadcast_calls.append("failed")
        raise RuntimeError("websocket fan-out unavailable")

    monkeypatch.setattr(main.broadcaster, "broadcast", fail_broadcast)
    initial = client.get("/calendar", headers=AUTH)
    body = {"schemaVersion": 1, "items": [calendar_item("broadcast-recovery")]}
    headers = {
        **AUTH,
        "content-type": "application/json",
        "if-match": initial.headers["etag"],
        "idempotency-key": "broadcast-recovery-write",
    }

    accepted = client.put("/calendar", headers=headers, json=body)
    assert accepted.status_code == 200
    assert len(broadcast_calls) == 1

    replayed = []

    async def capture_replay(message):
        replayed.append(message)

    monkeypatch.setattr(main.broadcaster, "broadcast", capture_replay)
    replay = client.put("/calendar", headers=headers, json=body)
    assert replay.status_code == 200
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replayed == [{"type": "calendar_changed", "revision": 1}]



def calendar_files(path):
    return {file.name: file.read_bytes() for file in path.iterdir() if file.is_file()}


def calendar_write_headers(etag, key="validation-write"):
    return {**AUTH, "content-type": "application/json", "if-match": etag, "idempotency-key": key}


@pytest.mark.parametrize("item", [
    None, True, 1, "event", [], {}, {"id": "not-a-uuid"},
    calendar_item(unknown=True), calendar_item(revision=2**63 - 1),
    calendar_item(title="  "), calendar_item(title=None), calendar_item(title="x" * 241), calendar_item(id="not-a-uuid"),
    calendar_item(status="unknown"), calendar_item(status=[]), calendar_item(kind={}),
    calendar_item(start="yesterday"), calendar_item(end="2026-09-08T08:00:00Z"),
    calendar_item(createdAt=123), calendar_item(updatedAt="2026-09-08"),
    calendar_item(deletedAt=False), calendar_item(icon=[]), calendar_item(systemIconName=2),
    calendar_item(timeZoneIdentifier={}), calendar_item(iconAsset={}),
    calendar_item(iconAsset={"format": "png", "bytes": "AAAA"}),
    calendar_item(recurrence=[]), calendar_item(recurrence={"frequency": "daily", "extra": 1}),
    calendar_item(recurrence={"frequency": "invalid"}),
    calendar_item(recurrence={"frequency": "daily", "interval": True}),
    calendar_item(recurrence={"frequency": "daily", "interval": 1.5}),
    calendar_item(recurrence={"frequency": "daily", "interval": 2**63 - 1}),
    calendar_item(recurrence={"frequency": "daily", "until": "NaN"}),
    calendar_item(title="\ud800"),
])
def test_calendar_rejects_malformed_items_without_mutating_authority(item, tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    seed = client.put("/calendar", headers=calendar_write_headers(initial.headers["etag"], "seed"),
                      json={"schemaVersion": 1, "items": [calendar_item()]})
    assert seed.status_code == 200
    before = calendar_files(tmp_path)
    # Include a valid item first: validation must be all-or-nothing.
    body = json.dumps({"schemaVersion": 1, "items": [calendar_item(), item]})
    rejected = client.put("/calendar", headers=calendar_write_headers(seed.headers["etag"]), content=body)
    assert rejected.status_code == 400
    assert calendar_files(tmp_path) == before
    # Rejection must not consume the idempotency key.
    accepted = client.put("/calendar", headers=calendar_write_headers(seed.headers["etag"]),
                         json={"schemaVersion": 1, "items": [calendar_item("Corrected")]})
    assert accepted.status_code == 200
    assert accepted.headers["x-lifeos-revision"] == "2"


@pytest.mark.parametrize("body,status", [
    (b'{"schemaVersion":true,"items":[]}', 400),
    (b'{"schemaVersion":1.0,"items":[]}', 400),
    (b'{"schemaVersion":1,"items":null}', 400),
    (b'{"schemaVersion":1,"items":[],"revision":9223372036854775807}', 400),
    (b'{"schemaVersion":1,"items":[null]}', 400),
    (b'{"schemaVersion":1,"items":[],"items":[]}', 400),
    (b'{"schemaVersion":1,"items":[' + b'[' * 1100 + b'0' + b']' * 1100 + b']}', 400),
    (b' ' * (main.CALENDAR_MAX_BODY_SIZE + 1), 413),
])
def test_calendar_invalid_documents_leave_fresh_authority_absent(body, status, tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    rejected = client.put("/calendar", headers=calendar_write_headers(initial.headers["etag"]), content=body)
    assert rejected.status_code == status
    assert calendar_files(tmp_path) == {}


@pytest.mark.parametrize("literal", ["NaN", "Infinity", "-Infinity", "1e999", "9223372036854775807"])
def test_calendar_rejects_nonfinite_and_unsafe_nested_numbers(literal, tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    item = calendar_item(recurrence={"frequency": "daily", "interval": "NUMBER"})
    body = json.dumps({"schemaVersion": 1, "items": [item]}).replace('"NUMBER"', literal)
    response = client.put("/calendar", headers=calendar_write_headers(initial.headers["etag"]), content=body)
    assert response.status_code == 400
    assert calendar_files(tmp_path) == {}


def test_calendar_valid_legacy_body_adopts_without_rewriting_and_replays(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    item = calendar_item(status="blocked", recurrence={"frequency": "weekly", "interval": 0})
    del item["kind"]
    body = json.dumps({"schemaVersion": 1, "items": [item]}).encode()
    main.CALENDAR_PATH.write_bytes(body)  # Valid legacy body without metadata.
    initial = client.get("/calendar", headers=AUTH)
    assert initial.status_code == 200 and initial.content == body
    assert initial.headers["x-lifeos-revision"] == "0"
    assert calendar_files(tmp_path) == {"calendar.json": body}
    item.update(kind="daily_schedule", icon=None, timeZoneIdentifier="Europe/Berlin", deletedAt=None)
    item["recurrence"] = {"frequency": "monthly", "until": None}
    body = json.dumps({"schemaVersion": 1, "items": [item]}).encode()
    headers = calendar_write_headers(initial.headers["etag"])
    accepted = client.put("/calendar", headers=headers, content=body)
    assert accepted.status_code == 200 and accepted.content == body
    before = calendar_files(tmp_path)
    replay = client.put("/calendar", headers=headers, content=body)
    assert replay.status_code == 200 and replay.content == body
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replay.headers["x-lifeos-revision"] == "1"
    assert calendar_files(tmp_path) == before


@pytest.mark.parametrize("revision", [str(main.CALENDAR_MAX_REVISION + 1), str(2**63 - 1), "9" * 5000])
def test_calendar_unsafe_etag_revisions_cannot_change_counter(revision, tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    etag = '"calendar-v1-r' + revision + '-' + 'a' * 64 + '"'
    response = client.put("/calendar", headers=calendar_write_headers(etag),
                          json={"schemaVersion": 1, "items": [calendar_item()]})
    assert response.status_code == 400
    assert calendar_files(tmp_path) == {}


def test_calendar_maximum_revision_allows_last_commit_and_replay_but_no_wrap(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    body = main._calendar_default_body()
    metadata = main._calendar_default_metadata(body)
    metadata["revision"] = main.CALENDAR_MAX_REVISION - 1
    main._calendar_state_path().write_text(json.dumps({
        "schemaVersion": 1, "bodyBase64": base64.b64encode(body).decode(), "metadata": metadata,
    }))
    initial = client.get("/calendar", headers=AUTH)
    headers = calendar_write_headers(initial.headers["etag"])
    document = {"schemaVersion": 1, "items": [calendar_item()]}
    accepted = client.put("/calendar", headers=headers, json=document)
    assert accepted.status_code == 200
    assert accepted.headers["x-lifeos-revision"] == str(main.CALENDAR_MAX_REVISION)
    before = calendar_files(tmp_path)
    replay = client.put("/calendar", headers=headers, json=document)
    assert replay.status_code == 200 and replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert calendar_files(tmp_path) == before
    exhausted = client.put("/calendar", headers=calendar_write_headers(accepted.headers["etag"], "new-key"), json=document)
    assert exhausted.status_code == 503
    assert exhausted.content == accepted.content
    assert exhausted.headers["etag"] == accepted.headers["etag"]
    assert calendar_files(tmp_path) == before
    stale = client.put("/calendar", headers=calendar_write_headers(initial.headers["etag"], "stale-key"), json=document)
    assert stale.status_code == 412 and calendar_files(tmp_path) == before
    reused = client.put("/calendar", headers=calendar_write_headers(accepted.headers["etag"]), json=document)
    assert reused.status_code == 409 and calendar_files(tmp_path) == before


@pytest.mark.parametrize("revision", [True, 1.0, -1, main.CALENDAR_MAX_REVISION + 1, 2**63 - 1])
def test_calendar_invalid_durable_revision_fails_closed_without_repair(revision, tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    body = main._calendar_default_body()
    metadata = main._calendar_default_metadata(body)
    metadata["revision"] = revision
    main._calendar_state_path().write_text(json.dumps({
        "schemaVersion": 1, "bodyBase64": base64.b64encode(body).decode(), "metadata": metadata,
    }))
    before = calendar_files(tmp_path)
    assert client.get("/calendar", headers=AUTH).status_code == 503
    response = client.put("/calendar", headers=calendar_write_headers(main._calendar_etag(0, main._calendar_digest(body))),
                          json={"schemaVersion": 1, "items": [calendar_item()]})
    assert response.status_code == 503
    assert calendar_files(tmp_path) == before



@pytest.mark.parametrize("field", ["id", "title", "status", "start", "end", "createdAt", "updatedAt"])
def test_calendar_requires_every_required_item_field(field):
    item = calendar_item()
    del item[field]
    with pytest.raises(main.HTTPException) as rejected:
        main._parse_calendar_document(json.dumps({"schemaVersion": 1, "items": [item]}).encode())
    assert rejected.value.status_code == 400


@pytest.mark.parametrize("overrides", [
    {"updatedAt": "2026-09-11T12:05:01Z"},
    {"createdAt": "2026-09-07T09:00:00Z", "updatedAt": "2026-09-07T08:00:00Z"},
    {"deletedAt": "2026-09-07T07:59:59Z"},
    {"deletedAt": "2026-09-07T08:00:01Z"},
])
def test_calendar_rejects_untrusted_clock_values(overrides):
    item = calendar_item(**overrides)
    with pytest.raises(main.HTTPException) as rejected:
        main._parse_calendar_document(
            json.dumps({"schemaVersion": 1, "items": [item]}).encode(),
            now=datetime(2026, 9, 11, 12, 0, tzinfo=timezone.utc),
        )
    assert rejected.value.status_code == 400


def test_calendar_allows_future_event_schedule_when_mutation_clock_is_bounded():
    item = calendar_item(
        start="2099-01-01T08:00:00Z",
        end="2099-01-01T09:00:00Z",
    )
    body = {"schemaVersion": 1, "items": [item]}
    assert main._parse_calendar_document(
        json.dumps(body).encode(),
        now=datetime(2026, 9, 11, 12, 0, tzinfo=timezone.utc),
    ) == body


@pytest.mark.parametrize("field", ["createdAt", "updatedAt", "deletedAt"])
@pytest.mark.parametrize("offset,accepted", [
    (main.CALENDAR_MAX_CLOCK_SKEW, True),
    (main.CALENDAR_MAX_CLOCK_SKEW + timedelta(microseconds=1), False),
])
def test_calendar_clock_skew_boundary_is_exact(field, offset, accepted):
    now = datetime(2026, 9, 11, 12, 0, tzinfo=timezone.utc)
    boundary = (now + offset).isoformat(timespec="microseconds").replace("+00:00", "Z")
    item = calendar_item()
    if field == "createdAt":
        item.update(createdAt=boundary, updatedAt=boundary)
    elif field == "updatedAt":
        item["updatedAt"] = boundary
    else:
        item.update(updatedAt=boundary, deletedAt=boundary)
    body = {"schemaVersion": 1, "items": [item]}

    if accepted:
        assert main._parse_calendar_document(json.dumps(body).encode(), now=now) == body
    else:
        with pytest.raises(main.HTTPException) as rejected:
            main._parse_calendar_document(json.dumps(body).encode(), now=now)
        assert rejected.value.status_code == 400


def test_calendar_enforces_item_count_without_dropping_existing_data(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    monkeypatch.setattr(main, "CALENDAR_MAX_ITEMS", 2)
    initial = client.get("/calendar", headers=AUTH)
    response = client.put("/calendar", headers=calendar_write_headers(initial.headers["etag"]),
                          json={"schemaVersion": 1, "items": [calendar_item()] * 3})
    assert response.status_code == 400 and calendar_files(tmp_path) == {}


def test_calendar_rejects_native_limit_overflow_before_persistence(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    seed = client.put(
        "/calendar",
        headers=calendar_write_headers(initial.headers["etag"], "count-seed"),
        json={"schemaVersion": 1, "items": [calendar_item("Existing event")]},
    )
    assert seed.status_code == 200
    before = calendar_files(tmp_path)

    overflow = {"schemaVersion": 1, "items": calendar_items(main.CALENDAR_MAX_ITEMS + 1)}
    rejected = client.put(
        "/calendar",
        headers=calendar_write_headers(seed.headers["etag"], "count-overflow"),
        json=overflow,
    )

    assert rejected.status_code == 400
    assert rejected.json() == {"error": "invalid_request"}
    assert calendar_files(tmp_path) == before
    current = client.get("/calendar", headers=AUTH)
    assert current.status_code == 200
    assert current.content == seed.content
    assert current.headers["x-lifeos-revision"] == seed.headers["x-lifeos-revision"]


@pytest.mark.parametrize("storage_kind", ["legacy", "state"])
def test_calendar_rejects_persisted_oversized_snapshot_without_truncating(
    storage_kind, tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    body = json.dumps(
        {"schemaVersion": 1, "items": calendar_items(main.CALENDAR_MAX_ITEMS + 1)},
        separators=(",", ":"),
    ).encode()
    assert len(body) < main.CALENDAR_MAX_BODY_SIZE

    if storage_kind == "legacy":
        main.CALENDAR_PATH.write_bytes(body)
    else:
        metadata = main._calendar_default_metadata(body)
        main._calendar_state_path().write_bytes(json.dumps(
            {
                "schemaVersion": main.CALENDAR_STATE_SCHEMA_VERSION,
                "bodyBase64": base64.b64encode(body).decode("ascii"),
                "metadata": metadata,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode())

    before = calendar_files(tmp_path)
    unavailable = client.get("/calendar", headers=AUTH)
    assert unavailable.status_code == 503
    assert unavailable.json() == {"error": "calendar_unavailable"}

    # A failed-closed read must also block a write rather than repairing,
    # truncating, or replacing the incompatible durable snapshot.
    etag = main._calendar_etag(0, main._calendar_digest(body))
    write = client.put(
        "/calendar",
        headers=calendar_write_headers(etag, f"oversized-{storage_kind}"),
        json={"schemaVersion": 1, "items": []},
    )
    assert write.status_code == 503
    assert write.json() == {"error": "calendar_unavailable"}
    assert calendar_files(tmp_path) == before


def test_calendar_maximum_incoming_etag_is_a_conflict_not_counter_assignment(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "CALENDAR_PATH", tmp_path / "calendar.json")
    initial = client.get("/calendar", headers=AUTH)
    etag = main._calendar_etag(main.CALENDAR_MAX_REVISION, "a" * 64)
    response = client.put("/calendar", headers=calendar_write_headers(etag),
                          json={"schemaVersion": 1, "items": [calendar_item()]})
    assert response.status_code == 412
    assert response.headers["etag"] == initial.headers["etag"]
    assert response.headers["x-lifeos-revision"] == "0"
    assert calendar_files(tmp_path) == {}


@pytest.mark.parametrize("branch", ["metadata", "idempotency", "tombstone"])
@pytest.mark.parametrize("revision", [True, 1.0, -1, main.CALENDAR_MAX_REVISION + 1, 2**63 - 1])
def test_calendar_all_persisted_revision_branches_are_bounded(branch, revision):
    body = main._calendar_default_body()
    metadata = main._calendar_default_metadata(body)
    metadata["revision"] = main.CALENDAR_MAX_REVISION
    if branch == "metadata":
        metadata["revision"] = revision
    elif branch == "idempotency":
        metadata["idempotency"] = [{"key": "record", "fingerprint": "a" * 64, "revision": revision}]
    else:
        metadata["tombstones"] = [{
            "schemaVersion": 1, "domain": "calendar", "entityID": "entry", "revision": revision,
            "idempotencyKey": "deleted", "authority": "gateway", "deletedAt": "2020-01-01T00:00:00Z",
        }]
    with pytest.raises(main._CalendarStateUnavailable):
        main._validate_calendar_metadata(metadata, body)


def test_calendar_icon_wire_contract_and_legacy_optional_hash():
    # A real single-pixel PNG accepted by both the gateway and native ImageIO.
    raw = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")
    asset = {"format": "png", "bytes": base64.b64encode(raw).decode()}
    document = {"schemaVersion": 1, "items": [calendar_item(iconAsset=asset)]}
    assert main._parse_calendar_document(json.dumps(document).encode()) == document
    asset.update(schemaVersion=1, contentHash=hashlib.sha256(raw).hexdigest())
    assert main._parse_calendar_document(json.dumps(document).encode()) == document

    invalid_images = (
        ("png", raw[:8]),
        ("png", raw[:-1]),
        ("jpeg", b"\xff\xd8"),
        ("jpeg", b"\xff\xd8\xff\xe0\x00\x10JFIF\x00"),
    )
    for image_format, invalid_raw in invalid_images:
        invalid = {"schemaVersion": 1, "items": [calendar_item(
            iconAsset={
                "format": image_format,
                "bytes": base64.b64encode(invalid_raw).decode(),
            }
        )]}
        with pytest.raises(main.HTTPException) as rejected:
            main._parse_calendar_document(json.dumps(invalid).encode())
        assert rejected.value.status_code == 400

    valid_jpeg = base64.b64decode(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAMCAgMCAgMDAwMEAwMEBQgFBQQEBQoHBwYIDAoMDAsKCwsNDhIQDQ4RDgsLEBYQERMUFRUVDA8XGBYUGBIUFRT/2wBDAQMEBAUEBQkFBQkUDQsNFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBT/wAARCAABAAEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oADAMBAAIRAxEAPwDwqiiiv3M/HD//2Q=="
    )
    jpeg_document = {"schemaVersion": 1, "items": [calendar_item(iconAsset={
        "format": "jpeg", "bytes": base64.b64encode(valid_jpeg).decode()
    })]}
    assert main._parse_calendar_document(json.dumps(jpeg_document).encode()) == jpeg_document

    # ImageIO-style sequential JPEGs may use a single non-interleaved scan
    # while retaining a 2x2 SOF sampling factor. The gateway must accept this
    # valid baseline form without invoking an unbounded decoder.
    imageio_style_jpeg = base64.b64decode(
        "/9j/4AAQSkZJRgABAQEAAQABAAD/2wBDAAMCAgICAgMCAgIDAwMDBAYEBAQEBAgGBgUGCQgKCgkICQkKDA8MCgsOCwkJDRENDg8QEBEQCgwSExIQEw8QEBD/wAALCAATABEBASIA/8QAFgABAQEAAAAAAAAAAAAAAAAAAAgJ/8QAHRAAAQMFAQAAAAAAAAAAAAAAABhUogEDBRVkkf/aAAgBAQAAPwCz1A9sgoHtkFA9sjNFQNX0goGr6QUDV9IhfeZZ/d9G8yz+76N5ln930//Z"
    )
    imageio_document = {"schemaVersion": 1, "items": [calendar_item(iconAsset={
        "format": "jpeg", "bytes": base64.b64encode(imageio_style_jpeg).decode()
    })]}
    assert main._parse_calendar_document(json.dumps(imageio_document).encode()) == imageio_document

    # libjpeg's documented sequential scan script can emit one non-interleaved
    # scan per component while retaining 4:2:0 sampling in the frame. This
    # 17x19 fixture decodes in Apple ImageIO and exercises component-relative
    # block counts at both non-multiple-of-eight dimensions.
    subsampled_multiscan_jpeg = base64.b64decode(
        "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAATABEDASIAAhEBAxEB/8QAHwAAAQUBAQEBAQEAAAAAAAAAAAECAwQFBgcICQoL/8QAtRAAAgEDAwIEAwUFBAQAAAF9AQIDAAQRBRIhMUEGE1FhByJxFDKBkaEII0KxwRVS0fAkM2JyggkKFhcYGRolJicoKSo0NTY3ODk6Q0RFRkdISUpTVFVWV1hZWmNkZWZnaGlqc3R1dnd4eXqDhIWGh4iJipKTlJWWl5iZmqKjpKWmp6ipqrKztLW2t7i5usLDxMXGx8jJytLT1NXW19jZ2uHi4+Tl5ufo6erx8vP09fb3+Pn6/9oACAEBAAA/APOPC3hL7n7v9K9T0zwoVtEAj+8wB4/H+lX/AOx9O/5+7T/v6v8AjTLS88O6J8t3fRPcLvHkW/719y9VIXhTnj5iP0NQeOPiemm6LHF4e0p/tFwNsct4wXY2fmOxDkgL0IYYJHHHPm//AAm/iH/oH6T/AN+ZP/i60fC1rB8n7taPEqrL4n8pxmOGNAi9lyMn9as/ZYP+ea1//8QAHwEAAwEBAQEBAQEBAQAAAAAAAAECAwQFBgcICQoL/8QAtREAAgECBAQDBAcFBAQAAQJ3AAECAxEEBSExBhJBUQdhcRMiMoEIFEKRobHBCSMzUvAVYnLRChYkNOEl8RcYGRomJygpKjU2Nzg5OkNERUZHSElKU1RVVldYWVpjZGVmZ2hpanN0dXZ3eHl6goOEhYaHiImKkpOUlZaXmJmaoqOkpaanqKmqsrO0tba3uLm6wsPExcbHyMnK0tPU1dbX2Nna4uPk5ebn6Onq8vP09fb3+Pn6/9oACAECEQA/AMKeJxtfLKnsov3la+y95pdemup4/wDYOL/mX3o+oqNvAv1X5nDdn//aAAgBAxEAPwDoyueK9n9Y5HyRV7vRfj/Vzm/1nzn/AJ8w/wDAmexxJUlHAwSe81f7pP8AM+Nuz//Z"
    )
    multiscan_document = {"schemaVersion": 1, "items": [calendar_item(iconAsset={
        "format": "jpeg", "bytes": base64.b64encode(subsampled_multiscan_jpeg).decode()
    })]}
    assert main._parse_calendar_document(json.dumps(multiscan_document).encode()) == multiscan_document

    marker_only = b"\xff\xd8\xff\xc0\x00\x11\x08\x00\x01\x00\x01\x01\x01\x11\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x00\xff\xd9"
    invalid = {"schemaVersion": 1, "items": [calendar_item(iconAsset={
        "format": "jpeg", "bytes": base64.b64encode(marker_only).decode()
    })]}
    with pytest.raises(main.HTTPException) as rejected:
        main._parse_calendar_document(json.dumps(invalid).encode())
    assert rejected.value.status_code == 400

    # The production validator explicitly claims PNG chunk integrity. Flip
    # the IDAT CRC while retaining the otherwise valid, bounded image.
    tampered = bytearray(raw)
    idat_offset = raw.index(b"IDAT")
    idat_length = int.from_bytes(raw[idat_offset - 4:idat_offset], "big")
    idat_crc_offset = idat_offset + 4 + idat_length
    tampered[idat_crc_offset] ^= 0x01
    invalid_crc = {"schemaVersion": 1, "items": [calendar_item(
        iconAsset={"format": "png", "bytes": base64.b64encode(tampered).decode()}
    )]}
    with pytest.raises(main.HTTPException) as rejected:
        main._parse_calendar_document(json.dumps(invalid_crc).encode())
    assert rejected.value.status_code == 400

    for override in ({"format": "jpeg"}, {"format": []}, {"bytes": "!"}, {"schemaVersion": True},
                     {"schemaVersion": 1.0}, {"contentHash": "f" * 64}, {"unknown": "path"}):
        invalid = {"schemaVersion": 1, "items": [calendar_item(iconAsset={**asset, **override})]}
        with pytest.raises(main.HTTPException):
            main._parse_calendar_document(json.dumps(invalid).encode())


def test_websocket_requires_identity():
    with pytest.raises(WebSocketDisconnect) as missing_identity:
        with client.websocket_connect("/ws", headers={"Authorization": "Bearer old-transitional-token"}):
            pass
    assert missing_identity.value.code == 4403

    with pytest.raises(WebSocketDisconnect) as wrong_identity:
        with client.websocket_connect(
            "/ws",
            headers={"Tailscale-User-Login": "other-user@example.com"},
        ):
            pass
    assert wrong_identity.value.code == 4403


def test_websocket_accepts_trusted_serve_identity():
    with client.websocket_connect("/ws", headers=AUTH) as websocket:
        websocket.close()


def test_websocket_requires_the_snapshot_host_contract(monkeypatch):
    monkeypatch.setattr(main, "ALLOWED_HOSTS", frozenset({"machine.example.ts.net:8420"}))
    with pytest.raises(WebSocketDisconnect) as rejected:
        with client.websocket_connect("/ws", headers={**AUTH, "Host": "testserver"}):
            pass
    assert rejected.value.code == 4403


def test_websocket_is_push_only_and_rejects_oversized_client_messages():
    with client.websocket_connect("/ws", headers=AUTH) as websocket:
        websocket.send_text("unexpected")
        with pytest.raises(WebSocketDisconnect) as rejected:
            websocket.receive_text()
    assert rejected.value.code == 1003

    with client.websocket_connect("/ws", headers=AUTH) as websocket:
        websocket.send_text("x" * (main.MAX_CLIENT_MESSAGE_BYTES + 1))
        with pytest.raises(WebSocketDisconnect) as rejected:
            websocket.receive_text()
    assert rejected.value.code == 1009


def test_websocket_rejects_binary_client_messages():
    with client.websocket_connect("/ws", headers=AUTH) as websocket:
        websocket.send_bytes(b"unexpected binary payload")
        with pytest.raises(WebSocketDisconnect) as rejected:
            websocket.receive_text()
    assert rejected.value.code == 1003


@pytest.mark.parametrize("message, expected", [
    ({"type": "websocket.receive"}, 1003),
    ({"type": "websocket.receive", "text": None, "bytes": None}, 1003),
    ({"type": "websocket.other"}, 1002),
    (object(), 1002),
])
def test_websocket_rejects_unknown_client_frames_with_bounded_codes(message, expected):
    assert main._websocket_client_message_close_code(message) == expected


def test_websocket_rejects_oversized_binary_client_messages():
    with client.websocket_connect("/ws", headers=AUTH) as websocket:
        websocket.send_bytes(b"x" * (main.MAX_CLIENT_MESSAGE_BYTES + 1))
        with pytest.raises(WebSocketDisconnect) as rejected:
            websocket.receive_text()
    assert rejected.value.code == 1009


def test_websocket_rejects_canonical_identity_without_trusted_edge():
    with pytest.raises(WebSocketDisconnect) as missing_edge:
        with client.websocket_connect("/ws", headers=TAILSCALE_IDENTITY):
            pass
    assert missing_edge.value.code == 4403


def test_websocket_rejects_cross_origin_browser_handshake():
    with pytest.raises(WebSocketDisconnect) as rejected:
        with client.websocket_connect(
            "/ws",
            headers={
                **AUTH,
                "Origin": "https://evil.example",
                "Sec-Fetch-Site": "cross-site",
            },
        ):
            pass
    assert rejected.value.code == 4403


def test_broadcaster_evicts_stalled_sends_without_blocking_other_clients():
    class HealthySocket:
        def __init__(self):
            self.messages = []

        async def send_json(self, message):
            self.messages.append(message)

        async def close(self, **_):
            return None

    class StalledSocket:
        def __init__(self):
            self.never = asyncio.Event()
            self.closed = False

        async def send_json(self, _message):
            await self.never.wait()

        async def close(self, **_):
            self.closed = True

    async def exercise():
        fanout = main.ChangeBroadcaster()
        fanout.SEND_TIMEOUT = 0.01
        fanout.BROADCAST_TIMEOUT = 0.02
        healthy = HealthySocket()
        stalled = StalledSocket()
        assert await fanout.register(healthy)
        assert await fanout.register(stalled)
        delivered = await asyncio.wait_for(
            fanout.broadcast({"type": "calendar_changed", "revision": 1}),
            timeout=0.2,
        )
        return delivered, healthy, stalled, fanout

    delivered, healthy, stalled, fanout = asyncio.run(exercise())
    assert delivered is False
    assert healthy.messages == [{"type": "calendar_changed", "revision": 1}]
    assert stalled.closed is True
    assert stalled not in fanout._sockets


def test_usage_malformed_payload():
    with request_with(FakeResponse(b"not-json")):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "usage unavailable"}

    malformed = json.dumps({"generatedAt": "now"}).encode()
    with request_with(FakeResponse(malformed)):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503


def test_usage_rejects_nested_contract_drift():
    invalid_payloads = []
    for path, value in [
        (("generatedAt",), "now"),
        (("windows", 0, "provider"), "openai"),
        (("windows", 0, "durationMinutes"), 300),
        (("windows", 0, "usedPercent"), 101),
        (("windows", 0, "availability"), "estimated"),
        (("windows", 0, "provenance", "official"), "yes"),
        (("windows", 0, "provenance", "connectorState"), "connected"),
        (("estimates", 0, "official"), True),
        (("estimates", 0, "confidence"), "certain"),
        (("windows", 0, "provider"), ["codex"]),
        (("windows", 0, "window"), {"name": "seven_day"}),
        (("windows", 0, "provenance", "freshness"), ["fresh"]),
        (("estimates", 0, "confidence"), {"value": "medium"}),
        (("connectors", "codex"), ["healthy"]),
    ]:
        payload = copy.deepcopy(VALID)
        target = payload
        for key in path[:-1]:
            target = target[key]
        target[path[-1]] = value
        invalid_payloads.append(payload)
    invalid_payloads.append({**copy.deepcopy(VALID), "unexpected": "field"})

    for payload in invalid_payloads:
        with request_with(FakeResponse(json.dumps(payload).encode())):
            response = client.get("/usage", headers=AUTH)
        assert response.status_code == 503
        assert response.json() == {"error": "usage unavailable"}


def test_usage_oversized_payload():
    body = json.dumps({**VALID, "windows": [{"value": "x" * (2 * 1024 * 1024)}]}).encode()
    responses = [
        FakeResponse(body),
        FakeResponse(body, include_content_length=False, chunk_size=64 * 1024),
    ]
    for upstream in responses:
        with request_with(upstream):
            response = client.get("/usage", headers=AUTH)
        assert response.status_code == 503
        assert response.json() == {"error": "usage unavailable"}


def test_usage_sensitive_key_rejection():
    payload = {**VALID, "windows": [{"nested": {"PaSsWoRd": "redacted"}}]}
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503


def test_usage_rejects_duplicate_json_keys_instead_of_echoing_raw_bytes():
    body = json.dumps(VALID).encode()
    marker = b'"source": "codex-app-server"'
    body = body.replace(marker, b'"source":"Bearer should-not-escape","source": "codex-app-server"', 1)
    with request_with(FakeResponse(body)):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503
    assert b"should-not-escape" not in response.content


def test_usage_rejects_sensitive_values_in_permitted_fields():
    payload = copy.deepcopy(VALID)
    payload["estimates"][0]["explanation"] = "Bearer should-not-escape"
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503
    assert b"should-not-escape" not in response.content


def test_usage_rejects_excessive_structure_depth_with_generic_error():
    payload = copy.deepcopy(VALID)
    nested = "leaf"
    for _ in range(500):
        nested = [nested]
    payload["unexpected"] = nested
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "usage unavailable"}


def test_usage_requires_exact_five_provider_connector_catalog():
    missing = copy.deepcopy(VALID["connectors"])
    missing.pop("google_ai_studio")
    extra = {**copy.deepcopy(VALID["connectors"]), "openai": "unavailable"}
    invalid = {**copy.deepcopy(VALID["connectors"]), "glm": "connected"}
    for connectors in (missing, extra, invalid):
        payload = {**copy.deepcopy(VALID), "connectors": connectors}
        with request_with(FakeResponse(json.dumps(payload).encode())):
            response = client.get("/usage", headers=AUTH)
        assert response.status_code == 503


def test_usage_accepts_valid_five_provider_payload():
    with request_with(FakeResponse(json.dumps(VALID).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 200
    assert set(response.json()["connectors"]) == {
        "codex", "claude", "glm", "deepseek", "google_ai_studio"
    }


def _usage_payload_with_window(**window_overrides):
    payload = copy.deepcopy(VALID)
    window = payload["windows"][0]
    for key, value in window_overrides.items():
        if key in {"official", "quality", "freshness", "observedAt", "connectorState"}:
            window["provenance"][key] = value
        else:
            window[key] = value
    return payload


def _usage_payload_with_estimate(**estimate_overrides):
    payload = copy.deepcopy(VALID)
    payload["estimates"][0].update(estimate_overrides)
    return payload


def _assert_usage_unavailable(payload):
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "usage unavailable"}


def test_usage_accepts_unavailable_window_truth_and_stale_connector_state():
    payload = _usage_payload_with_window(
        usedPercent="__absent__",
        resetAt="__absent__",
        availability="unavailable",
        official=False,
        quality="unavailable",
        freshness="stale",
        connectorState="revoked",
    )
    payload["windows"][0].pop("usedPercent")
    payload["windows"][0].pop("resetAt")
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 200


@pytest.mark.parametrize("field, value", [
    ("usedPercent", None),
    ("usedPercent", 2),
    ("resetAt", None),
    ("resetAt", "2026-08-15T07:00:59Z"),
])
def test_usage_rejects_unavailable_window_optional_values(field, value):
    payload = _usage_payload_with_window(
        availability="unavailable", official=False, quality="unavailable", connectorState="unavailable"
    )
    payload["windows"][0].pop("usedPercent", None)
    payload["windows"][0].pop("resetAt", None)
    payload["windows"][0][field] = value
    _assert_usage_unavailable(payload)


@pytest.mark.parametrize("field, value", [
    ("official", True),
    ("quality", "observed"),
    ("quality", "estimated"),
    ("connectorState", "healthy"),
    ("connectorState", "refresh_due"),
])
def test_usage_rejects_unavailable_window_contradictory_provenance(field, value):
    payload = _usage_payload_with_window(
        availability="unavailable", official=False, quality="unavailable", connectorState="unavailable"
    )
    payload["windows"][0].pop("usedPercent")
    payload["windows"][0].pop("resetAt")
    payload["windows"][0]["provenance"][field] = value
    _assert_usage_unavailable(payload)


@pytest.mark.parametrize("field, value", [
    ("usedPercent", None),
    ("official", False),
    ("quality", "unavailable"),
    ("quality", "estimated"),
])
def test_usage_rejects_observed_window_incomplete_truth(field, value):
    payload = _usage_payload_with_window(**{field: value})
    _assert_usage_unavailable(payload)


@pytest.mark.parametrize("field", ["observedAt", "official", "quality", "freshness", "connectorState"])
def test_usage_rejects_explicit_null_provenance_fields(field):
    payload = _usage_payload_with_window()
    payload["windows"][0]["provenance"][field] = None
    _assert_usage_unavailable(payload)


@pytest.mark.parametrize("freshness, connector_state", [
    ("stale", "healthy"),
    ("fresh", "refresh_due"),
    ("fresh", "rate_limited"),
    ("stale", "rate_limited"),
])
def test_usage_rejects_observed_window_contradictory_freshness_or_connector(freshness, connector_state):
    payload = _usage_payload_with_window(freshness=freshness, connectorState=connector_state)
    _assert_usage_unavailable(payload)


def test_usage_accepts_observed_rate_limited_and_stale_truth():
    rate_limited = _usage_payload_with_window(usedPercent=100, connectorState="rate_limited")
    rate_limited["connectors"]["codex"] = "rate_limited"
    with request_with(FakeResponse(json.dumps(rate_limited).encode())):
        assert client.get("/usage", headers=AUTH).status_code == 200

    stale_at = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat().replace("+00:00", "Z")
    stale = _usage_payload_with_window(
        freshness="stale", connectorState="refresh_due", observedAt=stale_at
    )
    stale["connectors"]["codex"] = "refresh_due"
    with request_with(FakeResponse(json.dumps(stale).encode())):
        assert client.get("/usage", headers=AUTH).status_code == 200


def test_usage_rejects_connector_state_that_contradicts_observed_window():
    stale_at = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat().replace("+00:00", "Z")
    payload = _usage_payload_with_window(freshness="stale", connectorState="refresh_due", observedAt=stale_at)
    payload["connectors"]["codex"] = "healthy"
    _assert_usage_unavailable(payload)


def test_usage_rejects_future_generated_and_provenance_timestamps():
    generated_future = copy.deepcopy(VALID)
    generated_future["generatedAt"] = (datetime.now(timezone.utc) + timedelta(seconds=10)).isoformat().replace("+00:00", "Z")
    _assert_usage_unavailable(generated_future)

    provenance_future = copy.deepcopy(VALID)
    provenance_future["windows"][0]["provenance"]["observedAt"] = (
        datetime.now(timezone.utc) + timedelta(seconds=10)
    ).isoformat().replace("+00:00", "Z")
    _assert_usage_unavailable(provenance_future)


def test_usage_accepts_timestamps_within_five_second_clock_skew():
    payload = copy.deepcopy(VALID)
    within_skew = (datetime.now(timezone.utc) + timedelta(seconds=2)).isoformat().replace("+00:00", "Z")
    payload["generatedAt"] = within_skew
    payload["windows"][0]["provenance"]["observedAt"] = within_skew
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 200


def test_usage_rejects_duplicate_window_and_estimate_provider_keys():
    duplicate_window = copy.deepcopy(VALID)
    duplicate_window["windows"].append(copy.deepcopy(duplicate_window["windows"][0]))
    _assert_usage_unavailable(duplicate_window)

    duplicate_estimate = copy.deepcopy(VALID)
    duplicate_estimate["estimates"].append(copy.deepcopy(duplicate_estimate["estimates"][0]))
    _assert_usage_unavailable(duplicate_estimate)


def test_usage_accepts_distinct_window_and_estimate_provider_keys():
    payload = copy.deepcopy(VALID)
    second_window = copy.deepcopy(payload["windows"][0])
    second_window["provider"] = "claude"
    second_window["provenance"]["source"] = "claude-statusline"
    payload["windows"].append(second_window)
    payload["connectors"]["claude"] = "healthy"
    second_estimate = copy.deepcopy(payload["estimates"][0])
    second_estimate["provider"] = "claude"
    payload["estimates"].append(second_estimate)
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 200


@pytest.mark.parametrize("field", [
    "projectedPercentAtReset", "estimatedExhaustionAt", "velocityPercentPerHour"
])
def test_usage_rejects_explicit_null_estimate_optionals(field):
    _assert_usage_unavailable(_usage_payload_with_estimate(**{field: None}))


def test_usage_stream_exception_is_generic_503():
    class BrokenResponse(FakeResponse):
        async def aiter_bytes(self):
            raise RuntimeError("upstream stream failed")
            yield b""  # pragma: no cover

    with request_with(BrokenResponse(b"")):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "usage unavailable"}


def test_usage_timeout_and_upstream_failure():
    with request_with(error=httpx.ReadTimeout("timeout")):
        assert client.get("/usage", headers=AUTH).status_code == 503
    with patch("main.USAGE_TOTAL_TIMEOUT", 0.001, create=True), request_with(
        FakeResponse(json.dumps(VALID).encode(), delay=0.02)
    ):
        response = client.get("/usage", headers=AUTH)
        assert response.status_code == 503
        assert response.json() == {"error": "usage unavailable"}
    with request_with(FakeResponse(b"upstream failure", status_code=502)):
        assert client.get("/usage", headers=AUTH).status_code == 503


def test_usage_method_rejection():
    assert client.post("/usage", headers=AUTH).status_code == 405
    assert client.put("/usage", headers=AUTH).status_code == 405
    assert client.delete("/usage", headers=AUTH).status_code == 405


def test_clipper_accepts_only_typed_unavailable_snapshot():
    with request_with(FakeResponse(json.dumps(VALID_CLIPPER_UNAVAILABLE).encode())):
        response = client.get("/clipper/summary", headers=AUTH)
    assert response.status_code == 200
    assert response.json() == VALID_CLIPPER_UNAVAILABLE
    assert response.headers["cache-control"] == "no-store"


def test_clipper_accepts_a_strict_observed_snapshot():
    with request_with(FakeResponse(json.dumps(VALID_CLIPPER_OBSERVED).encode())):
        response = client.get("/clipper/summary", headers=AUTH)
    assert response.status_code == 200
    assert response.json() == VALID_CLIPPER_OBSERVED


def test_clipper_requires_identity_and_get_only():
    assert client.get("/clipper/summary").status_code == 403
    assert client.post("/clipper/summary", headers=AUTH).status_code == 405
    assert client.get("/api/clipper/summary", headers=AUTH).status_code == 404


@pytest.mark.parametrize("payload", [
    {**VALID_CLIPPER_UNAVAILABLE, "availability": "observed"},
    {**VALID_CLIPPER_UNAVAILABLE, "metrics": {}},
    {**VALID_CLIPPER_UNAVAILABLE, "unexpected": "field"},
    {**VALID_CLIPPER_UNAVAILABLE, "generatedAt": "not-a-timestamp"},
    {
        **VALID_CLIPPER_UNAVAILABLE,
        "provenance": {**VALID_CLIPPER_UNAVAILABLE["provenance"], "connectorState": "healthy"},
    },
    {
        **VALID_CLIPPER_UNAVAILABLE,
        "provenance": {**VALID_CLIPPER_UNAVAILABLE["provenance"], "source": "Bearer should-not-escape"},
    },
])
def test_clipper_rejects_observed_unreviewed_malformed_or_sensitive_payloads(payload):
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get("/clipper/summary", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "clipper unavailable"}
    assert b"should-not-escape" not in response.content


def test_clipper_rejects_duplicate_keys_without_echoing_raw_bytes():
    body = json.dumps(VALID_CLIPPER_UNAVAILABLE).encode()
    body = body.replace(
        b'"source": "no-authorized-clipper-source"',
        b'"source":"Bearer should-not-escape","source": "no-authorized-clipper-source"',
        1,
    )
    with request_with(FakeResponse(body)):
        response = client.get("/clipper/summary", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "clipper unavailable"}
    assert b"should-not-escape" not in response.content


def test_clipper_rejects_oversized_response_and_upstream_failures(monkeypatch):
    import main

    oversized = json.dumps({"value": "x" * (main.CLIPPER_MAX_RESPONSE_SIZE + 1)}).encode()
    responses = [
        FakeResponse(oversized),
        FakeResponse(oversized, include_content_length=False, chunk_size=64 * 1024),
        FakeResponse(b"redirect", status_code=301),
        FakeResponse(b"failure", status_code=502),
    ]
    for upstream in responses:
        with request_with(upstream):
            response = client.get("/clipper/summary", headers=AUTH)
        assert response.status_code == 503
        assert response.json() == {"error": "clipper unavailable"}

    with request_with(error=httpx.ReadTimeout("secret must not escape")):
        response = client.get("/clipper/summary", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "clipper unavailable"}
    assert b"secret must not escape" not in response.content

    with patch("main.CLIPPER_TOTAL_TIMEOUT", 0.001), request_with(
        FakeResponse(json.dumps(VALID_CLIPPER_UNAVAILABLE).encode(), delay=0.02)
    ):
        response = client.get("/clipper/summary", headers=AUTH)
    assert response.status_code == 503


def test_clipper_upstream_allowlist_is_strict():
    import main

    assert main._is_allowed_upstream(
        "http://127.0.0.1:8787/api/clipper/summary", "/api/clipper/summary"
    )
    for value in (
        "http://localhost:8787/api/clipper/summary",
        "https://127.0.0.1:8787/api/clipper/summary",
        "http://127.0.0.1:8787/api/clipper/summary?token=value",
        "http://127.0.0.1:8787/api/other",
        "http://user:pass@127.0.0.1:8787/api/clipper/summary",
    ):
        assert not main._is_allowed_upstream(value, "/api/clipper/summary")


def test_claude_ingest_accepts_identity_only_and_forwards_allowlisted_json_to_exact_loopback(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    calls = []
    client_options = {}
    def make_client(**kwargs):
        client_options.update(kwargs)
        return FakeIngestClient(calls, **kwargs)
    with patch("main.httpx.AsyncClient", make_client):
        response = client.post(
            CLAUDE_INGEST,
            headers=ingest_headers(Authorization="Bearer source-client-secret"),
            content=json.dumps(VALID_CLAUDE_INGEST).encode(),
        )
    assert response.status_code == 204
    assert response.content == b""
    assert response.headers["cache-control"] == "no-store"
    assert len(calls) == 1
    url, options = calls[0]
    assert url == main.CLAUDE_INGEST_UPSTREAM == "http://127.0.0.1:8787/api/usage/claude-ingest"
    assert options["headers"]["Authorization"] == "Bearer " + "s" * 32
    assert options["headers"]["Content-Type"] == "application/json"
    assert re.fullmatch(r"[0-9a-f]{64}", options["headers"]["Idempotency-Key"])
    assert re.fullmatch(r"\d{4}-\d\d-\d\dT.*Z", options["headers"]["X-Observed-At"])
    assert json.loads(options["content"]) == VALID_CLAUDE_INGEST
    assert b"source-client-secret" not in options["content"]
    assert options["content"] != json.dumps(VALID_CLAUDE_INGEST).encode()
    assert client_options["follow_redirects"] is False
    assert client_options["timeout"] == main.CLAUDE_INGEST_REQUEST_TIMEOUT


def test_claude_ingest_forwards_only_a_validated_capture_timestamp(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    calls = []
    with patch("main.httpx.AsyncClient", lambda **kwargs: FakeIngestClient(calls, **kwargs)):
        response = client.post(
            CLAUDE_INGEST,
            headers=ingest_headers(**{"X-Observed-At": "2026-08-12T05:00:00+00:00"}),
            content=json.dumps(VALID_CLAUDE_INGEST).encode(),
        )
    assert response.status_code == 204
    assert calls[0][1]["headers"]["X-Observed-At"] == "2026-08-12T05:00:00Z"
    assert client.post(
        CLAUDE_INGEST,
        headers=ingest_headers(**{"X-Observed-At": "not-a-timestamp"}),
        content=json.dumps(VALID_CLAUDE_INGEST).encode(),
    ).status_code == 400


def test_claude_ingest_without_capture_time_derives_a_stable_replay_key(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    calls = []
    with patch("main.httpx.AsyncClient", lambda **kwargs: FakeIngestClient(calls, **kwargs)):
        first = client.post(
            CLAUDE_INGEST,
            headers=ingest_headers(),
            content=json.dumps(VALID_CLAUDE_INGEST).encode(),
        )
        second = client.post(
            CLAUDE_INGEST,
            headers=ingest_headers(),
            content=json.dumps(VALID_CLAUDE_INGEST).encode(),
        )
    assert first.status_code == second.status_code == 204
    assert len(calls) == 2
    first_key = calls[0][1]["headers"]["Idempotency-Key"]
    second_key = calls[1][1]["headers"]["Idempotency-Key"]
    assert first_key == second_key == hashlib.sha256(calls[0][1]["content"]).hexdigest()


def test_claude_ingest_rejects_duplicate_transport_headers(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    response = client.post(
        CLAUDE_INGEST,
        headers=[
            ("Tailscale-User-Login", "test-user@example.com"),
            ("X-LifeOS-Trusted-Edge", "e" * 64),
            ("content-type", "application/json"),
            ("content-type", "application/json"),
        ],
        content=json.dumps(VALID_CLAUDE_INGEST).encode(),
    )
    assert response.status_code == 415


def test_claude_ingest_identity_is_the_only_remote_auth_gate(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    body = json.dumps(VALID_CLAUDE_INGEST).encode()
    missing = client.post(CLAUDE_INGEST, content=body)
    assert missing.status_code == 403
    assert missing.headers["cache-control"] == "no-store"
    wrong = client.post(
        CLAUDE_INGEST,
        headers={"Tailscale-User-Login": "other-user@example.com", "Authorization": "Bearer " + "s" * 32,
                 "content-type": "application/json"},
        content=body,
    )
    assert wrong.status_code == 403
    assert wrong.headers["cache-control"] == "no-store"


def test_claude_ingest_exact_route_and_method_only():
    assert client.get(CLAUDE_INGEST, headers=AUTH).status_code == 405
    assert client.put(CLAUDE_INGEST, headers=AUTH).status_code == 405
    assert client.post("/api/usage/claude-ingest", headers=AUTH).status_code == 404
    assert client.post("/usage/claude-ingest/", headers=AUTH).status_code == 404


def test_claude_ingest_rejects_missing_or_wrong_content_type(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    body = json.dumps(VALID_CLAUDE_INGEST).encode()
    assert client.post(CLAUDE_INGEST, headers=AUTH, content=body).status_code == 415
    assert client.post(
        CLAUDE_INGEST,
        headers={**AUTH, "content-type": "text/plain"},
        content=body,
    ).status_code == 415


def test_claude_ingest_rejects_oversized_and_chunked_stream(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    oversized = b"{" + b"x" * main.CLAUDE_INGEST_MAX_BODY_SIZE + b"}"
    response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=oversized)
    assert response.status_code == 413
    assert response.json() == {"error": "request_too_large"}

    class ChunkedRequest:
        headers = {"content-type": "application/json"}

        async def stream(self):
            yield b"{" + b"x" * (main.CLAUDE_INGEST_MAX_BODY_SIZE // 2)
            yield b"y" * (main.CLAUDE_INGEST_MAX_BODY_SIZE // 2 + 1)

    with pytest.raises(main._ClaudeIngestRequestError) as error:
        asyncio.run(main._read_claude_ingest_body(ChunkedRequest()))
    assert error.value.status_code == 413


def test_claude_ingest_body_deadline_returns_bounded_timeout(monkeypatch):
    import main

    monkeypatch.setattr(main, "CLAUDE_INGEST_BODY_TIMEOUT", 0.001)

    class SlowRequest:
        headers = {"content-type": "application/json"}

        async def stream(self):
            await asyncio.sleep(0.02)
            yield b"{}"

    with pytest.raises(main._ClaudeIngestRequestError) as error:
        asyncio.run(main._read_claude_ingest_body(SlowRequest()))
    assert error.value.status_code == 408
    response = main._claude_ingest_input_error(error.value.status_code)
    assert response.status_code == 408
    assert response.body == b'{"error":"request_timeout"}'


def test_bounded_request_readers_reconcile_content_length_before_parsing(monkeypatch):
    import main

    # Keep the matrix cheap while exercising the same boundary comparison used
    # by each production-sized reader.
    monkeypatch.setattr(main.EnableBankingService, "BODY_LIMIT", 4)
    for name in (
        "FITNESS_OBSERVATION_MAX_BODY_SIZE",
        "FINANCE_IMPORTED_MAX_BODY_SIZE",
        "CALENDAR_MAX_BODY_SIZE",
        "CLAUDE_INGEST_MAX_BODY_SIZE",
        "NUTRITION_PHOTO_MAX_BODY_SIZE",
    ):
        monkeypatch.setattr(main, name, 4)

    class BodyRequest:
        def __init__(self, body, lengths):
            self.body = body
            self.scope = {
                "headers": [(b"content-length", str(length).encode("ascii")) for length in lengths]
            }

        async def stream(self):
            yield self.body[:1]
            yield self.body[1:]

    readers = [
        main._read_bounded_finance_request,
        main._read_bounded_fitness_observation_request,
        main._read_bounded_finance_imported_request,
        main._read_calendar_body,
        main._read_claude_ingest_body,
        main._read_nutrition_photo_body,
    ]
    cases = [
        ("declared longer than consumed", b"abc", [4], 400, None),
        ("declared shorter than consumed", b"abcd", [3], 400, None),
        ("duplicate declaration", b"abcd", [4, 4], 400, None),
        ("malformed declaration", b"abcd", ["2e0"], 400, None),
        ("absent declaration", b"abcd", [], None, b"abcd"),
        ("exact boundary declaration", b"abcd", [4], None, b"abcd"),
        ("oversized declaration", b"abcd", [5], 413, None),
    ]

    for reader in readers:
        for label, body, lengths, expected_status, expected_body in cases:
            request = BodyRequest(body, lengths)
            if expected_status is not None:
                with pytest.raises(Exception) as error:
                    asyncio.run(reader(request))
                assert getattr(error.value, "status_code", None) == expected_status, label
            else:
                assert asyncio.run(reader(request)) == expected_body, label


@pytest.mark.parametrize("body", [
    b"not-json",
    b'{"rate_limits":{"five_hour":{"used_percentage":1,"used_percentage":2}}}',
    b'{"rate_limits":{"five_hour":{"used_percentage":NaN}}}',
    b'{"rate_limits":{"five_hour":{"used_percentage":Infinity}}}',
    b'{"rate_limits":{"five_hour":{"used_percentage":-Infinity}}}',
    b'{"rate_limits":{"five_hour":{"used_percentage":"10"}}}',
    b'{"rate_limits":{"five_hour":{"used_percentage":true}}}',
    b'{"rate_limits":{"five_hour":{"resets_at":"1786777259"}}}',
    b'{"rate_limits":{"five_hour":{"resets_at":0}}}',
    b'{"rate_limits":{"five_hour":{"resets_at":-1}}}',
    b'{"rate_limits":{"five_hour":{"resets_at":null}}}',
])
def test_claude_ingest_rejects_non_json_duplicate_nonfinite_and_coerced_values(body, tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=body)
    assert response.status_code == 400
    assert response.json() == {"error": "invalid_request"}


@pytest.mark.parametrize("body", [
    {"secret": "do-not-forward"},
    {"rate_limits": {"five_hour": {"used_percentage": 1, "token": "sensitive"}}},
    {"rate_limits": {"five_hour": {"used_percentage": 1}, "private": {"used_percentage": 2}}},
])
def test_claude_ingest_rejects_extra_sensitive_siblings_without_echoing_them(body, tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=json.dumps(body).encode())
    assert response.status_code == 400
    assert response.json() == {"error": "invalid_request"}
    assert b"sensitive" not in response.content
    assert b"do-not-forward" not in response.content


def test_claude_ingest_rejects_when_no_observed_window_exists(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    for body in ({}, {"rate_limits": {}}, {"rate_limits": {"five_hour": {"resets_at": 1_786_777_259}}}):
        response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=json.dumps(body).encode())
        assert response.status_code == 422
        assert response.json() == {"error": "usage_unavailable"}


@pytest.mark.parametrize("value", [None, "short", "v" * 31, "v" * 32 + "\n", "x" * 4097])
def test_claude_ingest_fails_closed_for_missing_or_bad_secret_file(value, tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    path = tmp_path / main.CLAUDE_INGEST_SECRET_FILENAME
    if value is None:
        path.unlink(missing_ok=True)
    else:
        path.write_text(value)
        if os.name == "posix":
            path.chmod(0o600)
    monkeypatch.setenv("CLAUDE_INGEST_SECRET", "i" * 32)
    monkeypatch.setenv("CLAUDE_STATUSLINE_TOKEN", "j" * 32)
    response = client.post(
        CLAUDE_INGEST,
        headers=ingest_headers(),
        content=json.dumps(VALID_CLAUDE_INGEST).encode(),
    )
    assert response.status_code == 503
    assert response.json() == {"error": "ingest_unavailable"}
    assert b"i" * 32 not in response.content


def test_claude_ingest_uses_only_fixed_secret_path_and_ignores_path_override(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    override = tmp_path / "elsewhere.secret"
    override.write_text("i" * 32)
    monkeypatch.setenv("CLAUDE_INGEST_SECRET_FILE", str(override))
    assert main._read_ingest_secret() == "s" * 32


def test_claude_ingest_rejects_symlink_directory_and_handle_identity_mismatch(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    path = tmp_path / main.CLAUDE_INGEST_SECRET_FILENAME
    target = tmp_path / "target.secret"
    target.write_text("s" * 32)
    if os.name == "posix":
        target.chmod(0o600)
    path.unlink()
    try:
        path.symlink_to(target)
    except (OSError, NotImplementedError):
        pass
    else:
        assert path.is_symlink()
        assert main._read_ingest_secret() is None

    path.unlink(missing_ok=True)
    path.mkdir()
    assert main._read_ingest_secret() is None

    path.rmdir()
    path.write_text("s" * 32)
    if os.name == "posix":
        path.chmod(0o600)
    before = os.lstat(path)
    fake_after = SimpleNamespace(
        st_mode=before.st_mode,
        st_dev=before.st_dev,
        st_ino=before.st_ino + 1,
        st_size=before.st_size,
    )
    with patch.object(main.os, "fstat", return_value=fake_after):
        assert main._read_ingest_secret() is None


@pytest.mark.skipif(os.name != "posix", reason="POSIX mode bits are not portable")
def test_claude_ingest_rejects_group_or_world_accessible_secret(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    path = tmp_path / main.CLAUDE_INGEST_SECRET_FILENAME
    path.chmod(0o640)
    assert main._read_ingest_secret() is None


@pytest.mark.parametrize("status_code", [301, 307, 500, 502])
def test_claude_ingest_returns_generic_error_for_redirect_or_upstream_error(status_code, tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    calls = []
    with patch("main.httpx.AsyncClient", lambda **kwargs: FakeIngestClient(
        calls, response=FakeIngestUpstreamResponse(status_code), **kwargs
    )):
        response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=json.dumps(VALID_CLAUDE_INGEST).encode())
    assert response.status_code == 502
    assert response.json() == {"error": "ingest_unavailable"}
    assert response.headers["cache-control"] == "no-store"
    assert len(calls) == 1


def test_claude_ingest_returns_generic_error_for_upstream_timeout(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    calls = []
    with patch("main.httpx.AsyncClient", lambda **kwargs: FakeIngestClient(
        calls, error=httpx.ReadTimeout("secret must not escape"), **kwargs
    )):
        response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=json.dumps(VALID_CLAUDE_INGEST).encode())
    assert response.status_code == 502
    assert response.json() == {"error": "ingest_unavailable"}
    assert response.headers["cache-control"] == "no-store"
    assert b"secret must not escape" not in response.content


def test_claude_ingest_rejects_declared_oversized_upstream_response(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    upstream = FakeIngestUpstreamResponse(body=b"ok")
    upstream.headers["content-length"] = str(main.CLAUDE_INGEST_MAX_RESPONSE_SIZE + 1)
    calls = []
    with patch("main.httpx.AsyncClient", lambda **kwargs: FakeIngestClient(calls, response=upstream, **kwargs)):
        response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=json.dumps(VALID_CLAUDE_INGEST).encode())
    assert response.status_code == 502
    assert response.json() == {"error": "ingest_unavailable"}


def test_claude_ingest_rejects_chunked_oversized_upstream_response(tmp_path, monkeypatch):
    import main

    configure_ingest_secret(tmp_path, monkeypatch)
    upstream = FakeIngestUpstreamResponse(
        body=b"x" * (main.CLAUDE_INGEST_MAX_RESPONSE_SIZE + 1),
        include_content_length=False,
        chunk_size=1024,
    )
    calls = []
    with patch("main.httpx.AsyncClient", lambda **kwargs: FakeIngestClient(calls, response=upstream, **kwargs)):
        response = client.post(CLAUDE_INGEST, headers=ingest_headers(), content=json.dumps(VALID_CLAUDE_INGEST).encode())
    assert response.status_code == 502
    assert response.json() == {"error": "ingest_unavailable"}


def test_loopback_upstream_clients_disable_ambient_proxy_environment(tmp_path, monkeypatch):
    configure_ingest_secret(tmp_path, monkeypatch)
    options = []

    def make_client(**kwargs):
        options.append(kwargs)
        payload = VALID if len(options) == 1 else VALID_CLIPPER_UNAVAILABLE
        return FakeClient(FakeResponse(json.dumps(payload).encode()), **kwargs)

    with patch("main.httpx.AsyncClient", make_client):
        assert client.get("/usage", headers=AUTH).status_code == 200
        assert client.get("/clipper/summary", headers=AUTH).status_code == 200
    assert len(options) == 2
    assert all(item["trust_env"] is False for item in options)
    assert all(item["follow_redirects"] is False for item in options)


def test_nutrition_barcode_route_proxies_only_the_normalized_contract(monkeypatch):
    barcode = "3017620422003"
    fetched_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    payload = {
        "schemaVersion": 1,
        "state": "found",
        "barcode": barcode,
        "product": {"name": "Test product", "brand": "Test brand"},
        "nutritionState": "complete",
        "per100g": {"kcal": 100, "proteinGrams": 5, "carbsGrams": 10, "fatGrams": 2},
        "provenance": {
            "source": "openfoodfacts",
            "apiVersion": "v3.6",
            "apiURL": f"https://world.openfoodfacts.org/api/v3.6/product/{barcode}.json",
            "productURL": f"https://world.openfoodfacts.org/product/{barcode}",
            "fetchedAt": fetched_at,
            "databaseLicense": "ODbL-1.0",
            "contentLicense": "DbCL-1.0",
            "attribution": "Product data from Open Food Facts.",
            "dataQualityWarning": "Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed.",
        },
    }
    monkeypatch.setattr(main, "NUTRITION_BARCODE_UPSTREAM", "http://127.0.0.1:8787/api/nutrition/barcode")
    with request_with(FakeResponse(json.dumps(payload).encode())):
        response = client.get(f"/nutrition/barcode/{barcode}", headers=AUTH)
    assert response.status_code == 200
    assert response.json()["product"]["name"] == "Test product"
    assert b"raw" not in response.content
    assert response.headers["cache-control"] == "no-store"

    invalid = client.get("/nutrition/barcode/not-a-barcode", headers=AUTH)
    assert invalid.status_code == 400
    assert invalid.json() == {"error": "invalid_barcode"}

    malformed = {"schemaVersion": 1, "barcode": barcode, "raw": "provider payload"}
    with request_with(FakeResponse(json.dumps(malformed).encode())):
        response = client.get(f"/nutrition/barcode/{barcode}", headers=AUTH)
    assert response.status_code == 503
    assert b"provider payload" not in response.content


def _photo_manifest_for_gateway(data: bytes):
    encoded = base64.b64encode(data).decode("ascii")
    return {
        "schemaVersion": 1,
        "mealID": "meal-1",
        "requestID": "request-1",
        "capturedAt": "2026-08-26T12:00:00Z",
        "clientTimeZone": "Europe/Berlin",
        "inferenceConsent": True,
        "images": [{
            "imageID": "image-1",
            "mimeType": "image/png",
            "byteLength": len(data),
            "width": 1,
            "height": 1,
            "sanitized": True,
            "inlineDataBase64": encoded,
            "sha256": hashlib.sha256(data).hexdigest(),
        }],
    }


def test_photo_lineage_recomputes_digest_length_and_magic_before_forwarding():
    data = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
    manifest = _photo_manifest_for_gateway(data)
    assert main._photo_lineage(manifest) == (
        "meal-1",
        "request-1",
        [{"imageID": "image-1", "sha256": hashlib.sha256(data).hexdigest()}],
    )

    forged_digest = json.loads(json.dumps(manifest))
    forged_digest["images"][0]["sha256"] = "0" * 64
    assert main._photo_lineage(forged_digest) is None

    forged_length = json.loads(json.dumps(manifest))
    forged_length["images"][0]["byteLength"] += 1
    assert main._photo_lineage(forged_length) is None

    forged_magic = json.loads(json.dumps(manifest))
    forged_magic["images"][0]["mimeType"] = "image/jpeg"
    assert main._photo_lineage(forged_magic) is None

    forged_sanitized = json.loads(json.dumps(manifest))
    forged_sanitized["images"][0]["sanitized"] = False
    assert main._photo_lineage(forged_sanitized) is None

    forged_manifest_key = json.loads(json.dumps(manifest))
    forged_manifest_key["unexpected"] = "must not cross boundary"
    assert main._photo_lineage(forged_manifest_key) is None

    forged_image_key = json.loads(json.dumps(manifest))
    forged_image_key["images"][0]["unexpected"] = "must not cross boundary"
    assert main._photo_lineage(forged_image_key) is None

    with_context = json.loads(json.dumps(manifest))
    with_context["userContext"] = {"portionWeightGrams": 120.0}
    assert main._photo_lineage(with_context) is not None

    forged_context_key = json.loads(json.dumps(manifest))
    forged_context_key["userContext"] = {"secret": "must not cross boundary"}
    assert main._photo_lineage(forged_context_key) is None


def test_nutrition_photo_forwards_valid_request_with_local_service_bearer():
    data = base64.b64decode(
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
    )
    manifest = _photo_manifest_for_gateway(data)
    lineage = main._photo_lineage(manifest)
    assert lineage is not None
    request_body = json.dumps(manifest).encode()
    proposal = {
        "schemaVersion": 1,
        "mealID": lineage[0],
        "proposalID": "proposal-1",
        "requestID": lineage[1],
        "state": "needs_confirmation",
        "generatedAt": "2026-08-26T12:00:01Z",
        "provenance": {
            "provider": "google-ai-studio",
            "modelIdentifier": "food-model",
            "modelVersion": "food-model-v1",
            "policyVersion": "lifeos-food-photo-v1",
            "requestTimestamp": "2026-08-26T12:00:00Z",
            "sanitizedImageHashes": lineage[2],
        },
        "items": [{
            "itemID": "item-1",
            "estimatedLabel": "Plain yogurt",
            "labelSource": "recognized",
            "quantity": 1,
            "unit": "portion",
            "grams": {"estimate": 100, "min": 90, "max": 110},
            "calories": {"estimate": 100, "min": 90, "max": 110},
            "protein": {"estimate": 5, "min": 4, "max": 6},
            "carbs": {"estimate": 10, "min": 8, "max": 12},
            "fat": {"estimate": 2, "min": 1, "max": 3},
            "confidence": "medium",
            "flags": ["needs_confirmation"],
        }],
        "totals": {
            "grams": {"estimate": 100, "min": 90, "max": 110},
            "calories": {"estimate": 100, "min": 90, "max": 110},
            "protein": {"estimate": 5, "min": 4, "max": 6},
            "carbs": {"estimate": 10, "min": 8, "max": 12},
            "fat": {"estimate": 2, "min": 1, "max": 3},
        },
        "flags": ["needs_confirmation"],
        "uncertaintyNotes": ["Portion remains estimated."],
    }
    calls = []
    with patch(
        "main.httpx.AsyncClient",
        lambda **kwargs: CapturingClient(
            calls,
            FakeResponse(json.dumps(proposal).encode()),
            **kwargs,
        ),
    ):
        response = client.post(
            "/nutrition/photo-proposal",
            headers={**AUTH, "content-type": "application/json"},
            content=request_body,
        )

    assert response.status_code == 200
    assert response.json()["mealID"] == "meal-1"
    assert len(calls) == 1
    method, url, options = calls[0]
    assert method == "POST"
    assert url == main.NUTRITION_PHOTO_UPSTREAM
    assert options["headers"] == {
        "Content-Type": "application/json",
        "Authorization": "Bearer " + "l" * 64,
    }
    assert options["content"] == request_body


def test_finance_summary_without_linked_connection_is_unavailable():
    response = client.get("/finance/summary", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "finance unavailable"}
    assert response.headers["cache-control"] == "no-store"


def test_finance_summary_returns_validated_cached_observation_on_typed_refresh_failure(monkeypatch):
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    cached = copy.deepcopy(VALID_FINANCE)
    cached["generatedAt"] = observed_at
    for key in main.FINANCE_METRICS:
        cached[key]["provenance"]["observedAt"] = observed_at

    class CachedFinance:
        async def refresh_summary(self):
            raise main.EnableBankingUnavailable("provider unavailable", reason="transport")

        def load_cached_summary(self):
            return cached

        def runtime_status(self):
            return {
                "blocked": False,
                "failure": "transport",
                "partial": False,
                "lastSuccess": observed_at,
                "lastFailure": observed_at,
            }

    monkeypatch.setattr(main, "enable_banking", CachedFinance())
    response = client.get("/finance/summary", headers=AUTH)

    assert response.status_code == 200
    assert response.json() == cached
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["x-lifeos-banking-state"] == "transport"
    assert response.headers["x-lifeos-banking-partial"] == "false"


def test_finance_summary_does_not_serve_cache_after_unexpected_refresh_exception(monkeypatch):
    cached = copy.deepcopy(VALID_FINANCE)

    class UnexpectedFinance:
        async def refresh_summary(self):
            raise RuntimeError("unexpected parsing or storage failure")

        def load_cached_summary(self):
            return cached

    monkeypatch.setattr(main, "enable_banking", UnexpectedFinance())
    response = client.get("/finance/summary", headers=AUTH)

    assert response.status_code == 503
    assert response.json() == {"error": "finance unavailable"}
    assert "generatedAt" not in response.json()
    assert "provenance" not in response.text


@pytest.mark.parametrize("capacity_error", [main.ProtectedStorageOverloaded, main.ProtectedStorageUnavailable])
def test_finance_summary_preserves_typed_storage_capacity_response(monkeypatch, capacity_error):
    class BusyFinance:
        async def refresh_summary(self):
            raise capacity_error()

    monkeypatch.setattr(main, "enable_banking", BusyFinance())
    response = client.get("/finance/summary", headers=AUTH)

    assert response.status_code == 503
    assert response.json() == {"error": "storage_busy"}
    assert response.headers["cache-control"] == "no-store"
    assert response.headers["retry-after"] == "1"


def test_finance_response_bound_matches_native_read_limit():
    small = main._finance_consent_response({"status": "ok"}, 200)
    assert small.status_code == 200
    assert small.body == b'{"status":"ok"}'

    oversized = main._finance_consent_response(
        {"payload": "x" * main.EnableBankingService.MAX_FINANCE_SUMMARY_SIZE},
        200,
    )
    assert oversized.status_code == 503
    assert oversized.body == b'{"error":"finance unavailable"}'


def test_finance_summary_requires_identity_and_is_read_only():
    assert client.get("/finance/summary").status_code == 403
    assert client.post("/finance/summary", headers=AUTH).status_code == 405
    assert client.delete("/finance/connect/revolut_personal").status_code == 403


def test_finance_revoke_route_returns_only_provider_neutral_state(monkeypatch):
    class FakeFinance:
        def __init__(self):
            self.institution_id = None

        async def revoke(self, institution_id):
            self.institution_id = institution_id
            return 200, {"state": "revoked"}

    fake = FakeFinance()
    monkeypatch.setattr(main, "enable_banking", fake)

    response = client.delete("/finance/connect/revolut_personal", headers=AUTH)

    assert response.status_code == 200
    assert response.json() == {"state": "revoked"}
    assert fake.institution_id == "revolut_personal"
    assert response.headers["cache-control"] == "no-store"
    assert "session" not in response.text.lower()
    assert "provider" not in response.text.lower()


def test_finance_revoke_route_keeps_temporary_error_typed_and_sanitized(monkeypatch):
    class FakeFinance:
        async def revoke(self, _institution_id):
            return 503, {"error": "temporary_error"}

    monkeypatch.setattr(main, "enable_banking", FakeFinance())

    response = client.delete("/finance/connect/revolut_personal", headers=AUTH)

    assert response.status_code == 503
    assert response.json() == {"error": "temporary_error"}


@pytest.mark.parametrize("url, expected_path, valid", [
    ("http://127.0.0.1:8787/api/usage", "/api/usage", True),
    ("http://localhost:8790/api/finance/summary", "/api/finance/summary", False),
    ("https://127.0.0.1:8787/api/usage", "/api/usage", False),
    ("http://example.com:8787/api/usage", "/api/usage", False),
    ("http://127.0.0.1:8787/other", "/api/usage", False),
    ("http://user:pass@127.0.0.1:8787/api/usage", "/api/usage", False),
    ("http://127.0.0.1/api/usage?token=value", "/api/usage", False),
])
def test_read_only_upstreams_are_loopback_and_exact_path(url, expected_path, valid):
    import main

    assert main._is_allowed_upstream(url, expected_path) is valid


def test_finance_summary_rejects_fabricated_or_malformed_metrics():
    invalid = copy.deepcopy(VALID_FINANCE)
    invalid["spent"]["amountCents"] = 0
    with request_with(FakeResponse(json.dumps(invalid).encode())):
        response = client.get("/finance/summary", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "finance unavailable"}

    invalid = copy.deepcopy(VALID_FINANCE)
    invalid["spent"] = {
        "availability": "observed",
        "provenance": {
            **FINANCE_PROVENANCE,
            "quality": "observed",
            "connectorState": "healthy",
        },
    }
    with request_with(FakeResponse(json.dumps(invalid).encode())):
        response = client.get("/finance/summary", headers=AUTH)
    assert response.status_code == 503

    invalid = copy.deepcopy(VALID_FINANCE)
    invalid["spent"] = {
        "availability": "observed",
        "amountCents": 9_007_199_254_740_992,
        "provenance": {
            **FINANCE_PROVENANCE,
            "quality": "observed",
            "connectorState": "healthy",
        },
    }
    with request_with(FakeResponse(json.dumps(invalid).encode())):
        response = client.get("/finance/summary", headers=AUTH)
    assert response.status_code == 503


def test_finance_summary_accepts_account_only_observation_and_unavailable_omission():
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    provenance = {
        "source": "sparkasse_leipzig", "observedAt": observed_at,
        "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
    }
    payload = copy.deepcopy(VALID_FINANCE)
    payload["generatedAt"] = observed_at
    payload["accounts"] = {
        "availability": "observed",
        "accounts": [{
            "availability": "observed", "id": "account-1", "name": "Girokonto", "detail": "EUR",
            "balanceCents": 125_000, "source": "sparkasse_leipzig",
            "provenance": provenance,
        }],
        "provenance": provenance,
    }
    assert main._validate_finance_payload(payload)
    assert main._validate_finance_payload(VALID_FINANCE)

    unavailable = copy.deepcopy(VALID_FINANCE)
    unavailable["accounts"] = {
        "availability": "unavailable",
        "provenance": copy.deepcopy(FINANCE_PROVENANCE),
    }
    assert main._validate_finance_payload(unavailable)
    unavailable["accounts"]["accounts"] = []
    assert not main._validate_finance_payload(unavailable)


def test_finance_summary_rejects_account_overflow_source_mismatch_and_bad_provenance():
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    provenance = {
        "source": "revolut_personal", "observedAt": observed_at,
        "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
    }
    payload = copy.deepcopy(VALID_FINANCE)
    payload["generatedAt"] = observed_at
    payload["accounts"] = {
        "availability": "observed",
        "accounts": [{
            "availability": "observed", "id": "account-2", "name": "Personal", "detail": "EUR",
            "balanceCents": -4_200, "source": "revolut_personal", "provenance": provenance,
        }],
        "provenance": provenance,
    }
    overflow = copy.deepcopy(payload)
    overflow["accounts"]["accounts"][0]["balanceCents"] = main.FINANCE_MAX_SAFE_CENTS + 1
    assert not main._validate_finance_payload(overflow)

    source_mismatch = copy.deepcopy(payload)
    source_mismatch["accounts"]["accounts"][0]["source"] = "sparkasse_leipzig"
    assert not main._validate_finance_payload(source_mismatch)

    bad_provenance = copy.deepcopy(payload)
    bad_provenance["accounts"]["provenance"]["quality"] = "unavailable"
    assert not main._validate_finance_payload(bad_provenance)

    malformed_provenance = copy.deepcopy(payload)
    malformed_provenance["accounts"]["accounts"][0]["provenance"] = None
    assert not main._validate_finance_payload(malformed_provenance)


def test_finance_summary_accepts_mixed_account_and_transaction_snapshot_but_rejects_unknown_fields():
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    provenance = {
        "source": "revolut_personal", "observedAt": observed_at,
        "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
    }
    payload = copy.deepcopy(VALID_FINANCE)
    payload["generatedAt"] = observed_at
    payload["accounts"] = {
        "availability": "observed",
        "accounts": [{
            "availability": "observed", "id": "account-2", "name": "Personal", "detail": "EUR",
            "balanceCents": -4_200, "source": "revolut_personal", "provenance": provenance,
        }],
        "provenance": provenance,
    }
    payload["transactions"] = {
        "availability": "observed",
        "transactions": [{
            "id": "transaction-1", "merchant": "REWE", "title": "Groceries",
            "signedAmountCents": -2_450, "timestamp": observed_at,
            "account": "Personal", "source": "revolut_personal", "category": "Food",
            "provenance": provenance,
        }],
        "provenance": provenance,
    }
    assert main._validate_finance_payload(payload)

    malformed = copy.deepcopy(payload)
    malformed["transactions"]["transactions"][0]["iban"] = "DE00"
    assert not main._validate_finance_payload(malformed)


def test_finance_validator_is_total_for_missing_top_level_and_nested_values():
    for field in {
        "generatedAt", "currency", "monthlyIncome", "fixedCosts",
        "discretionaryBuffer", "spent", "savingsGoal", "saved",
    }:
        payload = copy.deepcopy(VALID_FINANCE)
        payload.pop(field)
        assert main._validate_finance_payload(payload) is False, field

    for malformed in (None, [], "not-an-object", {}, {"source": "x"}):
        payload = copy.deepcopy(VALID_FINANCE)
        payload["spent"]["provenance"] = malformed
        assert main._validate_finance_payload(payload) is False

    for field in main.FINANCE_PROVENANCE_FIELDS:
        for malformed in (None, [], {}):
            payload = copy.deepcopy(VALID_FINANCE)
            payload["spent"]["provenance"][field] = malformed
            assert main._validate_finance_payload(payload) is False

    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    observed_provenance = {
        "source": "revolut_personal", "observedAt": observed_at,
        "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
    }
    account = {
        "availability": "observed", "id": "account-1", "name": "Personal", "detail": "EUR",
        "balanceCents": 100, "source": "revolut_personal", "provenance": observed_provenance,
    }
    transaction = {
        "id": "transaction-1", "merchant": "REWE", "title": "Groceries",
        "signedAmountCents": -100, "timestamp": observed_at, "account": "Personal",
        "source": "revolut_personal", "category": "Food", "provenance": observed_provenance,
    }
    for snapshot_key, row in (("accounts", account), ("transactions", transaction)):
        payload = copy.deepcopy(VALID_FINANCE)
        payload["generatedAt"] = observed_at
        payload[snapshot_key] = {
            "availability": "observed",
            snapshot_key: [row],
            "provenance": observed_provenance,
        }
        payload[snapshot_key][snapshot_key][0]["provenance"] = None
        assert main._validate_finance_payload(payload) is False


def test_finance_validator_enforces_age_order_worst_freshness_and_source_reconciliation():
    now = datetime.now(timezone.utc)
    now_string = now.isoformat().replace("+00:00", "Z")
    old_string = (now - timedelta(minutes=16)).isoformat().replace("+00:00", "Z")
    fresh = {
        "source": "revolut_personal", "observedAt": now_string,
        "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
    }
    stale = {
        "source": "revolut_personal", "observedAt": old_string,
        "freshness": "stale", "quality": "observed", "connectorState": "refresh_due",
    }
    payload = copy.deepcopy(VALID_FINANCE)
    payload["generatedAt"] = now_string
    payload["accounts"] = {
        "availability": "observed",
        "accounts": [{
            "availability": "observed", "id": "account-1", "name": "Personal", "detail": "EUR",
            "balanceCents": 100, "source": "revolut_personal", "provenance": stale,
        }],
        "provenance": fresh,
    }
    assert not main._validate_finance_payload(payload)
    payload["accounts"]["provenance"] = stale
    assert main._validate_finance_payload(payload)

    account_source_mismatch = copy.deepcopy(payload)
    account_source_mismatch["accounts"]["provenance"]["source"] = "sparkasse_leipzig"
    assert not main._validate_finance_payload(account_source_mismatch)

    transaction = {
        "id": "transaction-1", "merchant": "REWE", "title": "Groceries",
        "signedAmountCents": -100, "timestamp": now_string, "account": "Personal",
        "source": "revolut_personal", "category": "Food", "provenance": stale,
    }
    payload["transactions"] = {
        "availability": "observed", "transactions": [transaction], "provenance": fresh,
    }
    assert not main._validate_finance_payload(payload)
    payload["transactions"]["provenance"] = stale
    assert main._validate_finance_payload(payload)

    transaction_source_mismatch = copy.deepcopy(payload)
    transaction_source_mismatch["transactions"]["provenance"]["source"] = "sparkasse_leipzig"
    assert not main._validate_finance_payload(transaction_source_mismatch)

    row_order_mismatch = copy.deepcopy(payload)
    row_order_mismatch["transactions"]["transactions"][0]["provenance"] = fresh
    row_order_mismatch["transactions"]["provenance"] = {
        **fresh, "observedAt": (now - timedelta(seconds=1)).isoformat().replace("+00:00", "Z")
    }
    assert not main._validate_finance_payload(row_order_mismatch)

    mixed_accounts = copy.deepcopy(payload)
    mixed_accounts["accounts"] = {
        "availability": "observed",
        "accounts": [
            {**mixed_accounts["accounts"]["accounts"][0], "provenance": fresh},
            {**mixed_accounts["accounts"]["accounts"][0], "id": "account-2", "source": "sparkasse_leipzig",
             "provenance": {**fresh, "source": "sparkasse_leipzig"}},
        ],
        "provenance": {**fresh, "source": "derived-account-snapshot"},
    }
    assert main._validate_finance_payload(mixed_accounts)


def test_finance_metrics_require_age_consistent_observed_provenance():
    observed_at = (datetime.now(timezone.utc) - timedelta(minutes=16)).isoformat().replace("+00:00", "Z")
    payload = copy.deepcopy(VALID_FINANCE)
    payload["generatedAt"] = observed_at
    payload["spent"] = {
        "availability": "observed", "amountCents": 100,
        "provenance": {
            "source": "revolut_personal", "observedAt": observed_at,
            "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
        },
    }
    assert not main._validate_finance_payload(payload)
    assert main._validate_persisted_finance_payload(payload)
    payload["spent"]["provenance"]["freshness"] = "stale"
    payload["spent"]["provenance"]["connectorState"] = "refresh_due"
    assert main._validate_finance_payload(payload)


def test_finance_validator_keeps_empty_observed_ledgers_truthful_and_rejects_sensitive_values():
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    provenance = {
        "source": "revolut_personal", "observedAt": observed_at,
        "freshness": "fresh", "quality": "observed", "connectorState": "healthy",
    }
    payload = copy.deepcopy(VALID_FINANCE)
    payload["generatedAt"] = observed_at
    payload["transactions"] = {
        "availability": "observed", "transactions": [], "provenance": provenance,
    }
    assert main._validate_finance_payload(payload)

    sensitive = copy.deepcopy(payload)
    sensitive["accounts"] = {
        "availability": "observed",
        "accounts": [{
            "availability": "observed", "id": "account-1", "name": "Personal", "detail": "Bearer should-not-escape",
            "balanceCents": 100, "source": "revolut_personal", "provenance": provenance,
        }],
        "provenance": provenance,
    }
    assert not main._validate_finance_payload(sensitive)


@pytest.mark.parametrize("document_id", [
    "not-a-uuid",
    "../../outside",
    "..\\\\outside",
    "00000000-0000-0000-0000-000000000000/../../outside",
])
def test_document_upload_rejects_invalid_and_traversal_ids(document_id, tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(document_id))},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert response.status_code == 400
    assert not (tmp_path / "documents").exists()


def test_document_upload_normalizes_unsafe_filename_extension(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "11111111-1111-4111-8111-111111111111"
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(document_id))},
        files={"file": ("tax.exe", b"safe", "application/octet-stream")},
    )
    assert response.status_code == 200
    index = json.loads((tmp_path / "documents.json").read_bytes())
    assert index[0]["_originalFile"] == "original.bin"
    assert not (tmp_path / "documents" / document_id / "original.exe").exists()


def test_document_upload_rejects_chunked_oversized_metadata_without_content_length(monkeypatch):
    import main

    monkeypatch.setattr(main, "DOCUMENT_METADATA_MAX_SIZE", 8)
    body = multipart_body([
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111")).encode(),
        ),
        multipart_part("file", b"safe", filename="tax.pdf", content_type="application/pdf"),
    ])

    response = run_document_upload(body, chunk_size=1)

    assert response.status_code == 413
    assert json.loads(response.body) == {"error": "request_too_large"}


def test_document_upload_accepts_chunked_request_without_content_length():
    metadata = json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111"))
    body = multipart_body([
        multipart_part("metadata", metadata.encode()),
        multipart_part("file", b"safe", filename="tax.pdf", content_type="application/pdf"),
    ])

    payload = asyncio.run(main._read_document_multipart(streamed_request(body, chunk_size=2)))
    try:
        assert payload.metadata == metadata
        assert payload.file.read() == b"safe"
    finally:
        payload.close()


def test_document_upload_rejects_a_slow_chunked_body_with_a_bounded_timeout(monkeypatch):
    import main

    monkeypatch.setattr(main, "DOCUMENT_BODY_TIMEOUT", 0.001)
    body = multipart_body([
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111")).encode(),
        ),
        multipart_part("file", b"safe", filename="tax.pdf", content_type="application/pdf"),
    ])
    messages = [{"type": "http.request", "body": body, "more_body": False}]

    async def slow_receive():
        await asyncio.sleep(0.02)
        return messages.pop(0)

    request = Request(
        {
            "type": "http",
            "method": "POST",
            "path": "/documents",
            "headers": [(b"content-type", b"multipart/form-data; boundary=lifeos-test-boundary")],
        },
        slow_receive,
    )

    response = asyncio.run(main.upload_document(request))

    assert response.status_code == 408
    assert json.loads(response.body) == {"error": "request_timeout"}


@pytest.mark.parametrize("header", [
    b"X" * 257 + b": value",
    b"Content-Disposition: " + b"X" * 4097,
])
def test_document_upload_rejects_oversized_part_headers(header):
    boundary = "lifeos-header-boundary"
    body = (
        b"--" + boundary.encode() + b"\r\n"
        + header + b"\r\n\r\n"
        + b"ignored\r\n--" + boundary.encode() + b"--\r\n"
    )

    response = run_document_upload(body, boundary=boundary, chunk_size=5)

    assert response.status_code == 413
    assert json.loads(response.body) == {"error": "request_too_large"}


@pytest.mark.parametrize("parts", [
    [
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111")).encode(),
        ),
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("22222222-2222-4222-8222-222222222222")).encode(),
        ),
    ],
    [
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111")).encode(),
        ),
        multipart_part("file", b"safe", filename="tax.pdf", content_type="application/pdf"),
        multipart_part("extra", b"unexpected"),
    ],
])
def test_document_upload_rejects_duplicate_or_extra_parts(parts):
    response = run_document_upload(multipart_body(parts), chunk_size=3)

    assert response.status_code == 400
    assert json.loads(response.body) == {"error": "invalid_request"}


def test_document_upload_rejects_oversized_file_before_storage(monkeypatch):
    import main

    monkeypatch.setattr(main, "DOCUMENT_MAX_UPLOAD_SIZE", 4)
    body = multipart_body([
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111")).encode(),
        ),
        multipart_part("file", b"12345", filename="tax.pdf", content_type="application/pdf"),
    ])

    response = run_document_upload(body, chunk_size=2)

    assert response.status_code == 413
    assert json.loads(response.body) == {"error": "request_too_large"}


def test_document_upload_rejects_oversized_aggregate_body_before_parser(monkeypatch):
    import main

    monkeypatch.setattr(main, "DOCUMENT_MAX_UPLOAD_SIZE", 8)
    monkeypatch.setattr(main, "DOCUMENT_METADATA_MAX_SIZE", 128)
    monkeypatch.setattr(main, "DOCUMENT_MULTIPART_OVERHEAD", 8)
    body = multipart_body([
        multipart_part(
            "metadata",
            json.dumps(tax_document_metadata("11111111-1111-4111-8111-111111111111")).encode(),
        ),
        multipart_part("file", b"12345678", filename="tax.pdf", content_type="application/pdf"),
    ])

    response = run_document_upload(body, chunk_size=5)

    assert response.status_code == 413
    assert json.loads(response.body) == {"error": "request_too_large"}


def test_document_upload_closes_file_when_multipart_parser_fails(monkeypatch):
    import main

    opened = []
    real_temporary_file = main.tempfile.TemporaryFile

    def tracked_temporary_file(*args, **kwargs):
        file = real_temporary_file(*args, **kwargs)
        opened.append(file)
        return file

    monkeypatch.setattr(main.tempfile, "TemporaryFile", tracked_temporary_file)
    boundary = "lifeos-malformed-boundary"
    body = (
        b"--" + boundary.encode() + b"\r\n"
        + multipart_part("file", b"partial", filename="tax.pdf", content_type="application/pdf")
        + b"\r\n--" + boundary.encode() + b"\r\n"
        + b"Bad Header\r\n\r\n"
    )

    response = run_document_upload(body, boundary=boundary, chunk_size=4)

    assert response.status_code == 400
    assert json.loads(response.body) == {"error": "invalid_request"}
    assert opened and all(file.closed for file in opened)


def test_document_upload_rejects_non_object_metadata(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(["not", "an", "object"])},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert response.status_code == 400
    assert not (tmp_path / "documents").exists()


def test_document_upload_rejects_corrupt_index_without_replacing_it(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    corrupt = b"not-json"
    main.DOCUMENTS_INDEX_PATH.write_bytes(corrupt)
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata("55555555-5555-4555-8555-555555555555"))},
        files={"file": ("return.pdf", b"new", "application/pdf")},
    )
    assert response.status_code == 503
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == corrupt
    assert not (tmp_path / "documents").exists()


def test_document_upload_rejects_serialized_index_threshold_before_file_publication(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    first_id = "66666666-6666-4666-8666-666666666666"
    first = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(first_id, title="first"))},
        files={"file": ("return.pdf", b"old", "application/pdf")},
    )
    assert first.status_code == 200
    before = main.DOCUMENTS_INDEX_PATH.read_bytes()
    monkeypatch.setattr(main, "DOCUMENT_INDEX_MAX_SIZE", len(before) + 1)
    second_id = "77777777-7777-4777-8777-777777777777"
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(second_id, title="x" * 128))},
        files={"file": ("return.pdf", b"new", "application/pdf")},
    )
    assert response.status_code == 413
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == before
    assert not (tmp_path / "documents" / second_id).exists()


def test_document_upload_rejects_entry_count_threshold_before_file_publication(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    monkeypatch.setattr(main, "DOCUMENT_INDEX_MAX_ENTRIES", 1)
    first_id = "88888888-8888-4888-8888-888888888888"
    assert client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(first_id))},
        files={"file": ("return.pdf", b"old", "application/pdf")},
    ).status_code == 200
    before = main.DOCUMENTS_INDEX_PATH.read_bytes()
    second_id = "99999999-9999-4999-8999-999999999999"
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(second_id))},
        files={"file": ("return.pdf", b"new", "application/pdf")},
    )
    assert response.status_code == 413
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == before
    assert not (tmp_path / "documents" / second_id).exists()


def test_document_upload_failed_index_publication_preserves_previous_file_and_index(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    assert client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(document_id))},
        files={"file": ("return.pdf", b"old", "application/pdf")},
    ).status_code == 200
    before_index = main.DOCUMENTS_INDEX_PATH.read_bytes()
    original_write = main._atomic_write_bytes

    def fail_index(path, data):
        if path == main.DOCUMENTS_INDEX_PATH:
            raise OSError("simulated index publication failure")
        return original_write(path, data)

    monkeypatch.setattr(main, "_atomic_write_bytes", fail_index)
    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(document_id))},
        files={"file": ("return.png", b"new", "image/png")},
    )
    assert response.status_code == 503
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == before_index
    assert (tmp_path / "documents" / document_id / "original.pdf").read_bytes() == b"old"
    assert not (tmp_path / "documents" / document_id / "original.png").exists()


def test_document_reupload_replaces_prior_original(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "33333333-3333-4333-8333-333333333333"
    for filename, content in (("return.pdf", b"old"), ("return.png", b"new")):
        response = client.post(
            "/documents",
            headers=AUTH,
            data={"metadata": json.dumps(tax_document_metadata(document_id))},
            files={"file": (filename, content, "application/octet-stream")},
        )
        assert response.status_code == 200
    originals = list((tmp_path / "documents" / document_id).glob("original.*"))
    assert [path.name for path in originals] == ["original.png"]
    assert client.get(f"/documents/{document_id}/file", headers=AUTH).content == b"new"


def test_document_upload_and_retrieval_safe_valid_path(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "22222222-2222-4222-8222-222222222222"
    content = b"validated tax document"
    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(tax_document_metadata(document_id, documentType="tax"))},
        files={"file": ("return.pdf", content, "application/pdf")},
    )
    assert uploaded.status_code == 200
    assert uploaded.json() == {"status": "ok", "id": document_id}

    retrieved = client.get(f"/documents/{document_id}/file", headers=AUTH)
    assert retrieved.status_code == 200
    assert retrieved.content == content
    assert retrieved.headers["content-type"] == "application/pdf"


@pytest.mark.parametrize("mutation", [
    lambda metadata: metadata.update(pages=["raw extracted page text"]),
    lambda metadata: metadata.update(unexpected="must be rejected"),
    lambda metadata: metadata.update(issuer={"value": "Issuer", "evidence": {"page": 1}}),
    lambda metadata: metadata.update(dates=[{
        "value": "2025-01-31",
        "evidence": tax_evidence(main.DOCUMENT_MAX_EVIDENCE_PAGE + 1),
    }]),
])
def test_document_upload_rejects_non_publication_metadata_without_storage(tmp_path, monkeypatch, mutation):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "12121212-1212-4121-8121-121212121212"
    metadata = native_tax_document_metadata(document_id)
    mutation(metadata)

    response = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )

    assert response.status_code == 400
    assert not (tmp_path / "documents.json").exists()
    assert not (tmp_path / "documents").exists()


def test_document_publication_redacts_identifiers_and_hides_internal_fields(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "13131313-1313-4131-8131-131313131313"
    metadata = native_tax_document_metadata(document_id)
    metadata["taxpayerIdentifier"] = tax_candidate("12345678901")

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert uploaded.status_code == 200

    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    publication = listed.json()[0]
    assert "_originalFile" not in publication
    assert "pages" not in publication
    assert publication["taxpayerIdentifier"]["value"] == "********01"
    assert "12345678901" not in listed.text


@pytest.mark.parametrize(("raw_identifier", "safe_identifier"), [
    ("AZ123456", "********56"),
    ("8642", "********42"),
    ("A7", "********"),
])
def test_document_upload_replaces_known_identifier_across_all_publication_text(
    tmp_path, monkeypatch, raw_identifier, safe_identifier
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "18181818-1818-4181-8181-181818181818"
    ordinary_date = "31.12.2025"
    ordinary_amount = "1.234,56 EUR"
    metadata = tax_document_metadata(
        document_id,
        title=f"Assessment {raw_identifier}",
        documentType=f"tax_assessment {raw_identifier}",
        issuer=tax_candidate(
            f"Finanzamt {raw_identifier}",
            snippet=f"Issuer evidence {raw_identifier}",
        ),
        taxpayerIdentifier=tax_candidate(
            raw_identifier,
            snippet=f"Taxpayer evidence {raw_identifier}",
        ),
        referenceIdentifier=tax_candidate(
            raw_identifier,
            snippet=f"Reference evidence {raw_identifier}",
        ),
        dates=[{
            "value": f"{ordinary_date} {raw_identifier}",
            "evidence": tax_evidence(1, f"Date evidence {raw_identifier}"),
        }],
        amounts=[{
            "value": f"{ordinary_amount} · {raw_identifier}",
            "label": f"Amount label {raw_identifier}",
            "evidence": tax_evidence(1, f"Amount evidence {raw_identifier}"),
        }],
        warnings=[f"Review {raw_identifier}"],
    )

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert uploaded.status_code == 200

    persisted = (tmp_path / "documents.json").read_text()
    reloaded, reloaded_body = main._load_document_index()
    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    publication = listed.json()[0]
    serialized_reload = json.dumps(reloaded, ensure_ascii=False)

    assert raw_identifier not in uploaded.text
    for serialized in (persisted, reloaded_body.decode("utf-8"), serialized_reload, listed.text):
        assert raw_identifier not in serialized
        assert safe_identifier in serialized
    assert publication["title"] == f"Assessment {safe_identifier}"
    assert publication["issuer"]["value"] == f"Finanzamt {safe_identifier}"
    assert publication["taxpayerIdentifier"]["value"] == safe_identifier
    assert publication["referenceIdentifier"]["value"] == safe_identifier
    assert publication["dates"][0]["value"] == f"{ordinary_date} {safe_identifier}"
    assert publication["amounts"][0]["value"] == f"{ordinary_amount} · {safe_identifier}"


@pytest.mark.parametrize(("raw_identifier", "safe_identifier"), [
    ("AZ123456", "********56"),
    ("8642", "********42"),
    ("A7", "********"),
])
def test_document_identifier_evidence_is_redacted_before_index_reload_and_publication(
    tmp_path, monkeypatch, raw_identifier, safe_identifier
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "17171717-1717-4171-8171-171717171717"
    evidence_snippet = f"Evidence begins {raw_identifier} and ends here"
    metadata = native_tax_document_metadata(document_id)
    metadata["taxpayerIdentifier"] = tax_candidate(raw_identifier, snippet=evidence_snippet)

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert uploaded.status_code == 200

    persisted = (tmp_path / "documents.json").read_text()
    reloaded, reloaded_body = main._load_document_index()
    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    publication = listed.json()[0]
    serialized_reload = json.dumps(reloaded, ensure_ascii=False)

    assert reloaded_body == persisted.encode("utf-8")
    for serialized in (persisted, serialized_reload, listed.text):
        assert raw_identifier not in serialized
        assert safe_identifier in serialized
    assert publication["taxpayerIdentifier"]["value"] == safe_identifier
    assert publication["taxpayerIdentifier"]["evidence"]["snippet"] == (
        f"Evidence begins {safe_identifier} and ends here"
    )


@pytest.mark.parametrize(("raw", "expected"), [
    ("*90", "********90"),
    ("**90", "********90"),
    ("***90", "********90"),
    ("12345678901", "********01"),
    ("12 345 678 901", "********01"),
    ("12/345/67890", "********90"),
    ("123 456 789 01", "********01"),
    ("12345678901*", "********01"),
    ("*2345678901", "********01"),
    ("12345*78901", "********01"),
    ("*90", "********90"),
    ("identifier-without-digits", "********"),
])
def test_tax_identifier_mask_contract_is_canonical(raw, expected):
    assert main._mask_tax_identifier_value(raw) == expected


def test_tax_text_keeps_ordinary_date_and_money_text_intact():
    ordinary = "Invoice date 31.12.2025; amount 1.234,56 EUR; short code 1234567890"
    assert main._redact_tax_text(ordinary) == ordinary
    assert main._redact_tax_text("Amount 12345678901.00") == "Amount 12345678901.00"
    assert main._redact_tax_text("Unlabelled 12345678901") == "Unlabelled ********01"
    assert main._redact_tax_text("Unlabelled 12 345 678 901") == "Unlabelled ********01"
    assert main._redact_tax_text("Unlabelled 12/345/67890") == "Unlabelled ********90"
    assert main._redact_tax_text("Unlabelled 123 456 789 01") == "Unlabelled ********01"
    assert main._redact_tax_text("Already masked *90") == "Already masked ********90"


@pytest.mark.parametrize("ordinary_text", ["Tax year 2026", "Page 1"])
def test_legacy_identifier_classifier_keeps_ordinary_numeric_context(ordinary_text):
    assert not main._legacy_text_contains_unproven_identifier(ordinary_text)
    assert not main._legacy_text_contains_unproven_identifier(
        ordinary_text,
        visible_suffixes={"26"},
        evidence=True,
    )


def test_document_index_migration_preserves_uncertain_masked_candidate_without_rewrite(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    document_id = "22222222-2222-4222-8222-222222222222"
    entry = native_tax_document_metadata(document_id)
    entry["_originalFile"] = "original.pdf"
    entry["title"] = "Tax year 2026"
    entry["taxpayerIdentifier"] = tax_candidate("********26", snippet="Page 1")
    entry["dates"] = [{
        "value": "31.12.2025",
        "evidence": tax_evidence(1, "Date 31.12.2025"),
    }]
    entry["amounts"] = [{
        "value": "1.234,56 EUR",
        "label": "Normal amount",
        "evidence": tax_evidence(1, "Amount 1.234,56 EUR"),
    }]
    original = json.dumps([entry]).encode("utf-8")
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    with pytest.raises(main._DocumentIndexError):
        main._load_document_index()

    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == original
    assert client.get("/documents", headers=AUTH).status_code == 503


def test_document_publication_redacts_unlabelled_identifiers_across_all_text_fields_and_persistence(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "16161616-1616-4161-8161-161616161616"
    raw = "12345678901"
    grouped = "12/345/67890"
    split_grouped = "123 456 789 01"
    mixed = "12345*78901"
    metadata = tax_document_metadata(
        document_id,
        title=f"Assessment {raw}",
        documentType=f"tax_assessment {grouped}",
        issuer=tax_candidate(f"Finanzamt {mixed}", snippet=f"Issuer {raw}"),
        taxpayerIdentifier=tax_candidate(raw, snippet=f"Taxpayer {grouped}"),
        referenceIdentifier=tax_candidate("*90", snippet=f"Reference {mixed}"),
        dates=[{
            "value": f"31.12.2025 ({raw})",
            "evidence": tax_evidence(1, f"Date {split_grouped}"),
        }],
        amounts=[{
            "value": f"1.234,56 EUR · {raw}",
            "label": f"Amount {mixed}",
            "evidence": tax_evidence(1, f"Amount 1.234,56 EUR {grouped}"),
        }],
        warnings=[f"Review {raw} and {grouped}"],
    )

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert uploaded.status_code == 200

    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    publication = listed.json()[0]
    persisted = (tmp_path / "documents.json").read_text()
    for text in (listed.text, persisted):
        for leaked in (raw, grouped, split_grouped, mixed):
            assert leaked not in text
        assert '"*90"' not in text
    assert "31.12.2025" in listed.text
    assert "1.234,56 EUR" in listed.text
    assert publication["title"] == "Assessment ********01"
    assert publication["documentType"] == "tax_assessment ********90"
    assert publication["issuer"]["value"] == "Finanzamt ********01"
    assert publication["issuer"]["evidence"]["snippet"] == "Issuer ********01"
    assert publication["taxpayerIdentifier"]["value"] == "********01"
    assert publication["taxpayerIdentifier"]["evidence"]["snippet"] == "Taxpayer ********90"
    assert publication["referenceIdentifier"]["value"] == "********90"
    assert publication["referenceIdentifier"]["evidence"]["snippet"] == (
        main.DOCUMENT_PRIVACY_PLACEHOLDER
    )
    assert publication["dates"][0]["value"] == "31.12.2025 (********01)"
    assert publication["dates"][0]["evidence"]["snippet"] == "Date ********01"
    assert publication["amounts"][0]["value"] == "1.234,56 EUR · ********01"
    assert publication["amounts"][0]["label"] == "Amount ********01"
    assert publication["amounts"][0]["evidence"]["snippet"] == "Amount 1.234,56 EUR ********90"
    assert publication["warnings"] == ["Review ********01 and ********90"]


@pytest.mark.parametrize("raw_identifier", ["12345678901*", "*2345678901", "12345*78901"])
def test_document_publication_remasks_mixed_identifier_tokens(tmp_path, monkeypatch, raw_identifier):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    document_id = "15151515-1515-4151-8151-151515151515"
    metadata = native_tax_document_metadata(document_id)
    metadata["taxpayerIdentifier"] = tax_candidate(raw_identifier)
    metadata["referenceIdentifier"] = tax_candidate(raw_identifier)

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )
    assert uploaded.status_code == 200
    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    publication = listed.json()[0]
    assert publication["taxpayerIdentifier"]["value"] == "********01"
    assert publication["referenceIdentifier"]["value"] == "********01"
    assert raw_identifier not in listed.text
    assert "12345678901" not in listed.text


@pytest.mark.parametrize("snippet", ["Page 8642", "8642 EUR", "SECRETREF", "secretref"])
def test_document_index_withholds_unverifiable_legacy_identifier_evidence(
    tmp_path, monkeypatch, snippet
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    document_id = "20202020-2020-4202-8202-202020202020"
    entry = native_tax_document_metadata(document_id)
    entry["_originalFile"] = "original-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.pdf"
    entry["taxpayerIdentifier"] = tax_candidate("********42", snippet=snippet)

    original = json.dumps(
        [entry],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    with pytest.raises(main._DocumentIndexError):
        main._load_document_index()

    persisted = main.DOCUMENTS_INDEX_PATH.read_bytes()
    assert persisted == original
    assert snippet.encode("utf-8") in persisted

    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 503
    assert snippet not in listed.text


def test_document_index_migration_preserves_safe_form_w2_entry(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")

    document_id = "19191919-1919-4191-8191-191919191919"
    entry = native_tax_document_metadata(document_id)
    entry["_originalFile"] = "original.pdf"
    entry["title"] = "Form W2"
    original = json.dumps([entry], separators=(",", ":")).encode()
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    entries, _body = main._load_document_index()

    assert [item["id"] for item in entries] == [document_id]
    assert entries[0]["title"] == "Form W2"
    assert entries[0]["_privacyVersion"] == main.DOCUMENT_PRIVACY_VERSION


def test_document_index_migration_preserves_safe_schedule_k1_entry(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")

    document_id = "23232323-2323-4232-8232-232323232323"
    entry = native_tax_document_metadata(document_id)
    entry["_originalFile"] = "original.pdf"
    entry["title"] = "Schedule K1"
    original = json.dumps([entry], separators=(",", ":")).encode()
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    entries, _body = main._load_document_index()

    assert [item["id"] for item in entries] == [document_id]
    assert entries[0]["title"] == "Schedule K1"


def test_document_upload_marks_current_privacy_contract_and_keeps_redacted_evidence(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    document_id = "25252525-2525-4252-8252-252525252525"
    metadata = native_tax_document_metadata(document_id)
    metadata["taxpayerIdentifier"] = tax_candidate(
        "12345678901",
        snippet="Taxpayer 12345678901",
    )

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )

    assert uploaded.status_code == 200
    entries, _body = main._load_document_index()
    assert entries[0]["_privacyVersion"] == main.DOCUMENT_PRIVACY_VERSION
    assert entries[0]["taxpayerIdentifier"]["evidence"]["snippet"] == (
        "Taxpayer ********01"
    )
    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    assert "_privacyVersion" not in listed.text


@pytest.mark.parametrize("snippet", ["Page 8642", "8642 EUR", "SECRETREF", "secretref"])
def test_document_upload_sanitizes_masked_identifier_evidence_before_versioning(
    tmp_path, monkeypatch, snippet
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    document_id = "27272727-2727-4272-8272-272727272727"
    metadata = native_tax_document_metadata(document_id)
    metadata["taxpayerIdentifier"] = tax_candidate("********42", snippet=snippet)

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )

    assert uploaded.status_code == 200
    listed = client.get("/documents", headers=AUTH)
    assert listed.status_code == 200
    assert snippet not in listed.text
    assert main.DOCUMENT_PRIVACY_PLACEHOLDER in listed.text
    assert json.loads(main.DOCUMENTS_INDEX_PATH.read_text())[0]["_privacyVersion"] == (
        main.DOCUMENT_PRIVACY_VERSION
    )


def test_document_upload_rejects_untrusted_cross_field_text_before_storage(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    document_id = "28282828-2828-4282-8282-282828282828"
    metadata = native_tax_document_metadata(document_id)
    metadata["title"] = "Form AZ123456"

    uploaded = client.post(
        "/documents",
        headers=AUTH,
        data={"metadata": json.dumps(metadata)},
        files={"file": ("return.pdf", b"safe", "application/pdf")},
    )

    assert uploaded.status_code == 400
    assert not main.DOCUMENTS_INDEX_PATH.exists()
    assert not main.DOCUMENTS_DIR.exists()


def test_document_index_rejects_untrusted_form_identifier_without_mutation(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    document_id = "24242424-2424-4242-8242-242424242424"
    entry = native_tax_document_metadata(document_id)
    entry["_originalFile"] = "original.pdf"
    entry["title"] = "Form AZ123456"
    entry["taxpayerIdentifier"] = tax_candidate("********56", snippet="Already masked")
    original = json.dumps([entry], separators=(",", ":")).encode()
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    response = client.get("/documents", headers=AUTH)

    assert response.status_code == 503
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == original


def test_document_index_rejects_unknown_privacy_version_without_mutation(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")

    document_id = "26262626-2626-4262-8262-262626262626"
    entry = native_tax_document_metadata(document_id)
    entry["_originalFile"] = "original.pdf"
    entry["_privacyVersion"] = main.DOCUMENT_PRIVACY_VERSION + 1
    original = json.dumps([entry], separators=(",", ":")).encode()
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    response = client.get("/documents", headers=AUTH)

    assert response.status_code == 503
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == original


def test_document_index_migration_preserves_original_bytes_when_privacy_is_uncertain(
    tmp_path, monkeypatch
):
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")

    safe_id = "19191919-1919-4191-8191-191919191919"
    unsafe_id = "21212121-2121-4212-8212-212121212121"
    safe_entry = native_tax_document_metadata(safe_id)
    safe_entry["_originalFile"] = "original.pdf"
    safe_entry["title"] = "Form W2"
    unsafe_entry = native_tax_document_metadata(unsafe_id)
    unsafe_entry["_originalFile"] = "original-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb.pdf"
    unsafe_entry["title"] = "Assessment 8642"
    unsafe_entry["taxpayerIdentifier"] = tax_candidate("********42", snippet="Already masked")

    original = json.dumps(
        [safe_entry, unsafe_entry],
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    response = client.get("/documents", headers=AUTH)

    assert response.status_code == 503
    assert response.json() == {"error": "documents_unavailable"}
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == original


def test_document_index_accepts_uppercase_foundation_uuid_spelling(tmp_path, monkeypatch):
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    entry = native_tax_document_metadata("abcdefab-cdef-4abc-8def-abcdefabcdef")
    entry["id"] = entry["id"].upper()
    entry["_originalFile"] = "original.pdf"
    main.DOCUMENTS_INDEX_PATH.write_bytes(json.dumps([entry]).encode())

    entries, _body = main._load_document_index()
    assert entries[0]["id"] == "abcdefab-cdef-4abc-8def-abcdefabcdef"


@pytest.mark.parametrize("unsafe_field", [
    ("pages", ["raw extracted page text"]),
    ("unexpected", "must be rejected"),
])
def test_document_index_rejects_raw_or_unknown_publication_fields_without_mutation(
    tmp_path, monkeypatch, unsafe_field
):
    monkeypatch.setattr(main, "DOCUMENTS_INDEX_PATH", tmp_path / "documents.json")
    entry = native_tax_document_metadata("14141414-1414-4141-8141-141414141414")
    entry["_originalFile"] = "original.pdf"
    entry[unsafe_field[0]] = unsafe_field[1]
    original = json.dumps([entry], separators=(",", ":")).encode()
    main.DOCUMENTS_INDEX_PATH.write_bytes(original)

    response = client.get("/documents", headers=AUTH)

    assert response.status_code == 503
    assert main.DOCUMENTS_INDEX_PATH.read_bytes() == original


def test_document_retrieval_rejects_oversized_existing_file(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DOCUMENTS_DIR", tmp_path / "documents")
    monkeypatch.setattr(main, "DOCUMENT_MAX_UPLOAD_SIZE", 3)
    document_id = "44444444-4444-4444-8444-444444444444"
    document_dir = tmp_path / "documents" / document_id
    document_dir.mkdir(parents=True)
    (document_dir / "original.pdf").write_bytes(b"1234")
    response = client.get(f"/documents/{document_id}/file", headers=AUTH)
    assert response.status_code == 413


def test_document_reader_is_bounded_and_identity_checked(tmp_path):
    import main

    path = tmp_path / "original.pdf"
    path.write_bytes(b"pdf")
    assert main._read_bounded_state_file(path, 3) == b"pdf"
    with pytest.raises(main._BoundedFileTooLarge):
        main._read_bounded_state_file(path, 2)
    target = tmp_path / "target.pdf"
    target.write_bytes(b"target")
    link = tmp_path / "link.pdf"
    try:
        link.symlink_to(target)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks are unavailable in this test environment")
    with pytest.raises(main._CalendarStateUnavailable):
        main._read_bounded_state_file(link, 64)


def test_document_reader_rejects_same_length_in_place_rewrite(tmp_path, monkeypatch):
    import main

    path = tmp_path / "original.pdf"
    original = b"a" * (128 * 1024)
    path.write_bytes(original)
    real_read = main.os.read
    read_count = 0

    def read_with_rewrite(descriptor, size):
        nonlocal read_count
        chunk = real_read(descriptor, size)
        if read_count == 0:
            path.write_bytes(b"b" * len(original))
        read_count += 1
        return chunk

    monkeypatch.setattr(main.os, "read", read_with_rewrite)
    with pytest.raises(main._CalendarStateUnavailable):
        main._read_bounded_state_file(path, len(original))


def test_document_retrieval_rejects_invalid_id():
    response = client.get("/documents/not-a-uuid/file", headers=AUTH)
    assert response.status_code == 400


def imported_finance_record(record_id="00000000-0000-4000-8000-000000000001", *, amount=-1890, category=None, description="Restaurant", source_revision=0):
    observed_at = "2026-06-06T12:00:00Z"
    return {
        "recordID": record_id,
        "sourceRevision": source_revision,
        "bookedAt": observed_at,
        "amountCents": amount,
        "description": description,
        "categoryOverride": category,
        "sourceCategory": "Food",
        "providerCode": None,
        "source": "tradeRepublicCSV",
        "importedAt": "2026-06-07T12:00:00Z",
        "kind": "cash",
        "investment": None,
    }


def imported_finance_request(base_revision, operations):
    return {"schemaVersion": 2, "baseRevision": base_revision, "operations": operations}


def imported_finance_headers(etag, key):
    return {
        **AUTH,
        "Content-Type": "application/json",
        "If-Match": etag,
        "Idempotency-Key": key,
    }


def test_imported_finance_authority_supports_readback_correction_override_and_tombstone(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", tmp_path / "finance-imported.json")
    initial = client.get("/finance/imported", headers=AUTH)
    assert initial.status_code == 200
    assert initial.json()["revision"] == 0
    record_id = "00000000-0000-4000-8000-000000000001"
    original = imported_finance_record(record_id)
    upsert = {"operation": "upsert", "record": original, "expectedSourceRevision": 0}

    first = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "import-1"),
        json=imported_finance_request(0, [upsert]),
    )
    assert first.status_code == 200
    assert first.json()["revision"] == 1
    assert len(first.json()["records"]) == 1

    replay = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "import-1"),
        json=imported_finance_request(0, [upsert]),
    )
    assert replay.status_code == 200
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replay.json()["revision"] == 1

    corrected = imported_finance_record(record_id, amount=-2575, description="Corrected merchant", source_revision=1)
    corrected_upsert = {
        "operation": "upsert",
        "record": corrected,
        "expectedSourceRevision": 1,
    }
    corrected_response = client.put(
        "/finance/imported",
        headers=imported_finance_headers(first.headers["etag"], "import-2"),
        json=imported_finance_request(1, [corrected_upsert]),
    )
    assert corrected_response.status_code == 200
    assert corrected_response.json()["revision"] == 2
    assert corrected_response.json()["records"][0]["amountCents"] == -2575

    override_response = client.put(
        "/finance/imported",
        headers=imported_finance_headers(corrected_response.headers["etag"], "import-3"),
        json=imported_finance_request(2, [{
            "operation": "categorySet",
            "recordID": record_id,
            "expectedSourceRevision": 2,
            "categoryOverride": "groceries",
        }]),
    )
    assert override_response.status_code == 200
    assert override_response.json()["records"][0]["categoryOverride"] == "groceries"

    deleted = client.put(
        "/finance/imported",
        headers=imported_finance_headers(override_response.headers["etag"], "import-4"),
        json=imported_finance_request(3, [{
            "operation": "delete",
            "recordID": record_id,
            "expectedSourceRevision": 2,
            "deletedAt": "2026-06-08T12:00:00Z",
        }]),
    )
    assert deleted.status_code == 200
    assert deleted.json()["records"] == []
    assert deleted.json()["tombstones"] == [{
        "recordID": record_id,
        "revision": 4,
        "deletedAt": "2026-06-08T12:00:00Z",
    }]

    stale = client.put(
        "/finance/imported",
        headers=imported_finance_headers(deleted.headers["etag"], "stale-write"),
        json=imported_finance_request(4, [upsert]),
    )
    assert stale.status_code == 409
    assert stale.headers["x-lifeos-conflict-reason"] == "deleted_record"
    assert stale.headers["etag"] == deleted.headers["etag"]
    assert stale.json()["revision"] == 4

    restored = client.put(
        "/finance/imported",
        headers=imported_finance_headers(deleted.headers["etag"], "restore-1"),
        json=imported_finance_request(4, [{
            "operation": "restore",
            "record": original,
            "expectedTombstoneRevision": 4,
        }]),
    )
    assert restored.status_code == 200
    assert restored.json()["revision"] == 5
    assert restored.json()["records"][0]["sourceRevision"] == 5
    assert restored.json()["tombstones"] == []


def test_imported_finance_authority_rejects_malformed_oversized_and_ambiguous_writes(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", tmp_path / "finance-imported.json")
    initial = client.get("/finance/imported", headers=AUTH)
    valid_headers = imported_finance_headers(initial.headers["etag"], "validation")
    invalid = client.put(
        "/finance/imported",
        headers=valid_headers,
        json={"schemaVersion": 99, "baseRevision": 0, "operations": []},
    )
    assert invalid.status_code == 400
    assert not (tmp_path / "finance-imported.json").exists()

    wrong_type = client.put(
        "/finance/imported",
        headers={**valid_headers, "Content-Type": "text/plain"},
        content=b"{}",
    )
    assert wrong_type.status_code == 415

    oversized = client.put(
        "/finance/imported",
        headers={**valid_headers, "Content-Length": str(main.FINANCE_IMPORTED_MAX_BODY_SIZE + 1)},
        content=b"{}",
    )
    assert oversized.status_code == 413

    valid = imported_finance_record(source_revision=0)
    for index, invalid_record in enumerate([
        {**valid, "description": " Restaurant"},
        {**valid, "description": "é" * 300},
        {**valid, "amountCents": 1.5},
        {**valid, "recordID": valid["recordID"].upper()},
        {**valid, "unknown": True},
    ]):
        response = client.put(
            "/finance/imported",
            headers=imported_finance_headers(initial.headers["etag"], f"invalid-{index}"),
            json=imported_finance_request(0, [{
                "operation": "upsert",
                "record": invalid_record,
                "expectedSourceRevision": 0,
            }]),
        )
        # Uppercase UUID is canonicalized and remains valid; all other
        # fixtures are rejected by the shared boundary validator.
        if index == 3:
            assert response.status_code == 200
        else:
            assert response.status_code == 400


def test_imported_finance_replays_exact_body_after_authority_advances(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", tmp_path / "finance-imported.json")
    initial = client.get("/finance/imported", headers=AUTH)
    original = imported_finance_record()
    first_request = imported_finance_request(0, [{
        "operation": "upsert",
        "record": original,
        "expectedSourceRevision": 0,
    }])
    first = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "lost-response"),
        json=first_request,
    )
    assert first.status_code == 200

    corrected = imported_finance_record(amount=-2_000, source_revision=1)
    second = client.put(
        "/finance/imported",
        headers=imported_finance_headers(first.headers["etag"], "advance-authority"),
        json=imported_finance_request(1, [{
            "operation": "upsert",
            "record": corrected,
            "expectedSourceRevision": 1,
        }]),
    )
    assert second.status_code == 200
    assert second.json()["revision"] == 2

    replay = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "lost-response"),
        json=first_request,
    )
    assert replay.status_code == 200
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replay.json()["revision"] == 2
    assert replay.json()["records"][0]["amountCents"] == -2_000

    misuse = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "lost-response"),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": imported_finance_record(amount=-2_001),
            "expectedSourceRevision": 0,
        }]),
    )
    assert misuse.status_code == 409
    assert misuse.headers["x-lifeos-conflict"] == "true"
    assert misuse.json()["revision"] == 2


def test_imported_finance_receipt_lookup_returns_only_exact_commit_state(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", tmp_path / "finance-imported.json")
    initial = client.get("/finance/imported", headers=AUTH)
    unknown = client.get("/finance/imported/receipt/never-committed", headers=AUTH)
    assert unknown.status_code == 200
    assert unknown.json() == {"state": "unknown", "revision": None}

    key = "receipt-proof-1"
    committed = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], key),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": imported_finance_record(source_revision=0),
            "expectedSourceRevision": 0,
        }]),
    )
    assert committed.status_code == 200

    proof = client.get(f"/finance/imported/receipt/{key}", headers=AUTH)
    assert proof.status_code == 200
    assert proof.json() == {"state": "committed", "revision": 1}
    assert "fingerprint" not in proof.json()
    assert "records" not in proof.json()
    assert proof.headers["cache-control"] == "no-store"

    invalid = client.get("/finance/imported/receipt/not a key", headers=AUTH)
    assert invalid.status_code == 400


def test_imported_finance_rejects_stale_source_and_category_preconditions_atomically(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", tmp_path / "finance-imported.json")
    initial = client.get("/finance/imported", headers=AUTH)
    record_id = "00000000-0000-4000-8000-000000000001"
    first = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "source-1"),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": imported_finance_record(record_id),
            "expectedSourceRevision": 0,
        }]),
    )
    corrected = imported_finance_record(record_id, amount=-2_100, source_revision=1)
    second = client.put(
        "/finance/imported",
        headers=imported_finance_headers(first.headers["etag"], "source-2"),
        json=imported_finance_request(1, [{
            "operation": "upsert",
            "record": corrected,
            "expectedSourceRevision": 1,
        }]),
    )
    assert second.status_code == 200
    assert second.json()["revision"] == 2

    stale_category = client.put(
        "/finance/imported",
        headers=imported_finance_headers(second.headers["etag"], "category-stale"),
        json=imported_finance_request(2, [{
            "operation": "categorySet",
            "recordID": record_id,
            "expectedSourceRevision": 1,
            "categoryOverride": "groceries",
        }]),
    )
    assert stale_category.status_code == 409
    assert stale_category.headers["x-lifeos-conflict-reason"] == "source_revision"

    stale_source = client.put(
        "/finance/imported",
        headers=imported_finance_headers(second.headers["etag"], "source-stale"),
        json=imported_finance_request(2, [{
            "operation": "upsert",
            "record": imported_finance_record(record_id, source_revision=1),
            "expectedSourceRevision": 1,
        }]),
    )
    assert stale_source.status_code == 409
    assert stale_source.headers["x-lifeos-conflict-reason"] == "source_revision"

    second_id = "00000000-0000-4000-8000-000000000002"
    atomic_failure = client.put(
        "/finance/imported",
        headers=imported_finance_headers(second.headers["etag"], "atomic-failure"),
        json=imported_finance_request(2, [
            {
                "operation": "upsert",
                "record": imported_finance_record(second_id),
                "expectedSourceRevision": 0,
            },
            {
                "operation": "categoryClear",
                "recordID": record_id,
                "expectedSourceRevision": 1,
            },
        ]),
    )
    assert atomic_failure.status_code == 409
    assert client.get("/finance/imported", headers=AUTH).json()["revision"] == 2
    assert second_id not in {row["recordID"] for row in client.get("/finance/imported", headers=AUTH).json()["records"]}


def test_imported_finance_state_reload_preserves_authority_and_replay_journal(tmp_path, monkeypatch):
    import importlib
    import main

    path = tmp_path / "finance-imported.json"
    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", path)
    initial = client.get("/finance/imported", headers=AUTH)
    first = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "reload-key"),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": imported_finance_record(),
            "expectedSourceRevision": 0,
        }]),
    )
    assert first.status_code == 200

    reloaded_main = importlib.reload(main)
    monkeypatch.setattr(reloaded_main, "FINANCE_IMPORTED_PATH", path)
    reloaded_client = TestClient(reloaded_main.app)
    replay = reloaded_client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "reload-key"),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": imported_finance_record(),
            "expectedSourceRevision": 0,
        }]),
    )
    assert replay.status_code == 200
    assert replay.headers["x-lifeos-idempotent-replay"] == "true"
    assert replay.json()["revision"] == 1


def test_imported_finance_legacy_state_is_explicitly_migrated_to_v2(tmp_path, monkeypatch):
    import main

    path = tmp_path / "finance-imported.json"
    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", path)
    legacy_record = imported_finance_record()
    legacy_record.pop("sourceRevision")
    legacy_snapshot = {
        "schemaVersion": 1,
        "domain": "finance",
        "ledger": "manual_import",
        "authority": "gateway",
        "revision": 1,
        "records": [legacy_record],
        "tombstones": [],
    }
    legacy_body = json.dumps(legacy_snapshot, separators=(",", ":"), ensure_ascii=False).encode()
    legacy_metadata = {
        "schemaVersion": 1,
        "domain": "finance",
        "authority": "gateway",
        "revision": 1,
        "bodyDigest": hashlib.sha256(legacy_body).hexdigest(),
        "idempotency": [],
    }
    path.write_bytes(json.dumps({
        "schemaVersion": 1,
        "bodyBase64": base64.b64encode(legacy_body).decode("ascii"),
        "metadata": legacy_metadata,
    }, sort_keys=True, separators=(",", ":")).encode())

    response = client.get("/finance/imported", headers=AUTH)
    assert response.status_code == 200
    assert response.json()["schemaVersion"] == 2
    assert response.json()["records"][0]["sourceRevision"] == 1
    migrated = json.loads(path.read_text())
    assert migrated["schemaVersion"] == 2
    assert json.loads(base64.b64decode(migrated["bodyBase64"]))["schemaVersion"] == 2

    after_migration = client.put(
        "/finance/imported",
        headers=imported_finance_headers(response.headers["etag"], "after-migration"),
        json=imported_finance_request(1, [{
            "operation": "categorySet",
            "recordID": legacy_record["recordID"],
            "expectedSourceRevision": 1,
            "categoryOverride": "groceries",
        }]),
    )
    assert after_migration.status_code == 200
    assert after_migration.json()["revision"] == 2
    assert after_migration.json()["records"][0]["categoryOverride"] == "groceries"


def test_imported_finance_duplicate_key_with_different_fingerprint_is_conflict(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "FINANCE_IMPORTED_PATH", tmp_path / "finance-imported.json")
    initial = client.get("/finance/imported", headers=AUTH)
    first = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "same-key"),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": imported_finance_record(),
            "expectedSourceRevision": 0,
        }]),
    )
    assert first.status_code == 200
    different = imported_finance_record(amount=-1999)
    conflict = client.put(
        "/finance/imported",
        headers=imported_finance_headers(initial.headers["etag"], "same-key"),
        json=imported_finance_request(0, [{
            "operation": "upsert",
            "record": different,
            "expectedSourceRevision": 0,
        }]),
    )
    assert conflict.status_code == 409
    assert conflict.headers["x-lifeos-conflict"] == "true"
    assert conflict.json()["revision"] == 1


def _fitness_iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _fitness_payload(now=None):
    now = now or datetime.now(timezone.utc)
    generated = now - timedelta(seconds=20)
    observed = now - timedelta(seconds=30)
    return {
        "schemaVersion": 1,
        "state": "observed",
        "generatedAt": _fitness_iso(generated),
        "observedAt": _fitness_iso(observed),
        "source": "healthkit",
        "provenance": "iphone_healthkit_projection",
        "metrics": [{
            "metric": "heart_rate",
            "value": 61.5,
            "unit": "bpm",
            "observedAt": _fitness_iso(observed),
        }],
        "days": [],
        "workouts": [],
    }


def test_fitness_observation_requires_tailscale_identity_for_read_and_write():
    assert client.get("/fitness/observation").status_code == 403
    assert client.post("/fitness/observation", json=_fitness_payload()).status_code == 403


def test_fitness_observation_round_trips_valid_live_payload(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    payload = _fitness_payload()

    written = client.post("/fitness/observation", headers=AUTH, json=payload)
    assert written.status_code == 200
    assert path.exists()

    read = client.get("/fitness/observation", headers=AUTH)
    assert read.status_code == 200
    assert read.headers["x-lifeos-fitness-state"] == "observed"
    assert read.json()["metrics"] == payload["metrics"]


def test_fitness_observation_accepts_paused_workout_active_duration(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    now = datetime.now(timezone.utc)
    payload = _fitness_payload(now)
    workout_end = now - timedelta(seconds=30)
    payload["workouts"] = [{
        "activityTypeRawValue": 37,
        "startAt": _fitness_iso(workout_end - timedelta(minutes=60)),
        "endAt": _fitness_iso(workout_end),
        "durationSeconds": 50 * 60,
    }]

    written = client.post("/fitness/observation", headers=AUTH, json=payload)

    assert written.status_code == 200
    assert written.json() == {"status": "ok", "result": "stored"}
    response = client.get("/fitness/observation", headers=AUTH)
    assert response.status_code == 200
    assert response.json()["workouts"] == payload["workouts"]


def test_fitness_observation_ignores_reversed_arrival_and_keeps_newer_generation(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    now = datetime.now(timezone.utc)
    newer = _fitness_payload(now)
    newer["metrics"][0]["value"] = 72.0
    older = _fitness_payload(now - timedelta(minutes=1))
    older["metrics"][0]["value"] = 58.0

    first = client.post("/fitness/observation", headers=AUTH, json=newer)
    second = client.post("/fitness/observation", headers=AUTH, json=older)

    assert first.status_code == 200
    assert first.json() == {"status": "ok", "result": "stored"}
    assert second.status_code == 200
    assert second.json() == {
        "status": "ok",
        "result": "ignored",
        "reason": "older_observation",
    }
    current = client.get("/fitness/observation", headers=AUTH)
    assert current.status_code == 200
    assert current.json()["metrics"][0]["value"] == 72.0


def test_fitness_observation_equal_generation_is_idempotent(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    payload = _fitness_payload()

    first = client.post("/fitness/observation", headers=AUTH, json=payload)
    replay = client.post("/fitness/observation", headers=AUTH, json=copy.deepcopy(payload))

    assert first.status_code == 200
    assert replay.status_code == 200
    assert replay.json() == {
        "status": "ok",
        "result": "already_current",
        "reason": "idempotent_replay",
    }
    assert len(replay.content) <= 128


def test_fitness_observation_get_marks_old_observation_stale_and_clears_values(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    payload = _fitness_payload(datetime.now(timezone.utc) - timedelta(minutes=16))
    path.write_text(json.dumps(payload))

    response = client.get("/fitness/observation", headers=AUTH)
    assert response.status_code == 200
    body = response.json()
    assert body["state"] == "stale"
    assert body["metrics"] == []
    assert body["days"] == []
    assert body["workouts"] == []
    assert response.headers["x-lifeos-fitness-state"] == "stale"


def test_fitness_observation_rejects_stale_publish_and_malformed_payloads(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    stale = _fitness_payload(datetime.now(timezone.utc) - timedelta(minutes=16))
    assert client.post("/fitness/observation", headers=AUTH, json=stale).status_code == 422
    assert not path.exists()

    unknown = copy.deepcopy(_fitness_payload())
    unknown["unexpected"] = True
    assert client.post("/fitness/observation", headers=AUTH, json=unknown).status_code == 422

    wrong_unit = copy.deepcopy(_fitness_payload())
    wrong_unit["metrics"][0]["unit"] = "ms"
    assert client.post("/fitness/observation", headers=AUTH, json=wrong_unit).status_code == 422

    malformed_state = copy.deepcopy(_fitness_payload())
    malformed_state["state"] = []
    malformed_state_response = client.post("/fitness/observation", headers=AUTH, json=malformed_state)
    assert malformed_state_response.status_code == 422
    assert malformed_state_response.json() == {"error": "fitness_observation_invalid"}

    future = copy.deepcopy(_fitness_payload())
    future["generatedAt"] = _fitness_iso(datetime.now(timezone.utc) + timedelta(minutes=1))
    assert client.post("/fitness/observation", headers=AUTH, json=future).status_code == 422

    nonfinite = json.dumps(_fitness_payload()).replace("61.5", "NaN").encode()
    assert client.post(
        "/fitness/observation",
        headers={**AUTH, "content-type": "application/json"},
        content=nonfinite,
    ).status_code == 422


@pytest.mark.parametrize("boundary_timestamp", [
    "0001-01-01T00:00:00+01:00",
    "9999-12-31T23:59:59-01:00",
])
def test_fitness_observation_rejects_timezone_conversion_overflow_as_controlled_422(boundary_timestamp):
    payload = _fitness_payload()
    payload["generatedAt"] = boundary_timestamp
    payload["observedAt"] = boundary_timestamp

    response = client.post("/fitness/observation", headers=AUTH, json=payload)

    assert response.status_code == 422
    assert response.json() == {"error": "fitness_observation_invalid"}


def test_fitness_observation_enforces_request_and_response_limits(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    oversized_request = b"x" * (main.FITNESS_OBSERVATION_MAX_BODY_SIZE + 1)
    response = client.post(
        "/fitness/observation",
        headers={**AUTH, "content-type": "application/json"},
        content=oversized_request,
    )
    assert response.status_code == 413

    path.write_bytes(b"x" * (main.FITNESS_OBSERVATION_MAX_RESPONSE_SIZE + 1))
    assert client.get("/fitness/observation", headers=AUTH).status_code == 503


def test_fitness_observation_preserves_explicit_unavailable_state(tmp_path, monkeypatch):
    path = tmp_path / "fitness-observation.json"
    monkeypatch.setattr(main, "FITNESS_OBSERVATION_PATH", path)
    payload = _fitness_payload()
    payload["state"] = "unavailable"
    payload["metrics"] = []
    path.write_text(json.dumps(payload))

    response = client.get("/fitness/observation", headers=AUTH)
    assert response.status_code == 200
    assert response.json()["state"] == "unavailable"
    assert response.json()["metrics"] == []


# Ephemeral local service capability only. Never read operator credentials or use network.
@pytest.fixture(autouse=True)
def service_credentials(tmp_path_factory, monkeypatch):
    import main

    tmp_path = tmp_path_factory.mktemp("gateway-service-auth")
    monkeypatch.setattr(main, "DATA_DIR", tmp_path)
    path = tmp_path / main.LOCAL_API_SECRET_ENV
    path.write_text("l" * 64)
    path.chmod(0o600)
    monkeypatch.setenv(main.LOCAL_API_SECRET_ENV, str(path))
    return {main.LOCAL_API_SECRET_ENV: path}
