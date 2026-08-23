import asyncio
import copy
import json
import os
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace
from unittest.mock import patch

import httpx
import pytest
from fastapi.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

os.environ["LIFEOS_TAILSCALE_ALLOWED_LOGIN"] = "test-user@example.com"

import main
from main import app

client = TestClient(app)
TAILSCALE_IDENTITY = {"Tailscale-User-Login": "test-user@example.com"}
AUTH = dict(TAILSCALE_IDENTITY)
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


def test_usage_healthy_proxy():
    body = json.dumps(VALID).encode()
    with request_with(FakeResponse(body)):
        response = client.get("/usage", headers=AUTH)
    assert response.status_code == 200
    assert response.json() == VALID
    assert response.headers["cache-control"] == "no-store"


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


def test_health_probe_remains_available_without_identity_or_bearer():
    assert client.get("/health").status_code == 200


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


def test_websocket_accepts_identity_only():
    with client.websocket_connect("/ws", headers=AUTH) as websocket:
        websocket.close()


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
    with request_with(FakeResponse(json.dumps(rate_limited).encode())):
        assert client.get("/usage", headers=AUTH).status_code == 200

    stale_at = (datetime.now(timezone.utc) - timedelta(minutes=20)).isoformat().replace("+00:00", "Z")
    stale = _usage_payload_with_window(
        freshness="stale", connectorState="refresh_due", observedAt=stale_at
    )
    with request_with(FakeResponse(json.dumps(stale).encode())):
        assert client.get("/usage", headers=AUTH).status_code == 200


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
    assert options["headers"] == {
        "Authorization": "Bearer " + "s" * 32,
        "Content-Type": "application/json",
    }
    assert json.loads(options["content"]) == VALID_CLAUDE_INGEST
    assert b"source-client-secret" not in options["content"]
    assert options["content"] != json.dumps(VALID_CLAUDE_INGEST).encode()
    assert client_options["follow_redirects"] is False
    assert client_options["timeout"] == main.CLAUDE_INGEST_REQUEST_TIMEOUT


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


def test_finance_summary_without_linked_connection_is_unavailable():
    response = client.get("/finance/summary", headers=AUTH)
    assert response.status_code == 503
    assert response.json() == {"error": "finance unavailable"}
    assert response.headers["cache-control"] == "no-store"


def test_finance_summary_requires_identity_and_is_read_only():
    assert client.get("/finance/summary").status_code == 403
    assert client.post("/finance/summary", headers=AUTH).status_code == 405


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
            "id": "account-1", "name": "Girokonto", "detail": "EUR",
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
            "id": "account-2", "name": "Personal", "detail": "EUR",
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
            "id": "account-2", "name": "Personal", "detail": "EUR",
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
        "id": "account-1", "name": "Personal", "detail": "EUR",
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
            "id": "account-1", "name": "Personal", "detail": "EUR",
            "balanceCents": 100, "source": "revolut_personal", "provenance": stale,
        }],
        "provenance": fresh,
    }
    assert not main._validate_finance_payload(payload)
    payload["accounts"]["provenance"] = {**stale, "observedAt": now_string}
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
    payload["transactions"]["provenance"] = {**stale, "observedAt": now_string}
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
            "id": "account-1", "name": "Personal", "detail": "Bearer should-not-escape",
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
        data={"metadata": json.dumps({"id": document_id})},
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
        data={"metadata": json.dumps({"id": document_id})},
        files={"file": ("tax.exe", b"safe", "application/octet-stream")},
    )
    assert response.status_code == 200
    index = json.loads((tmp_path / "documents.json").read_bytes())
    assert index[0]["_originalFile"] == "original.bin"
    assert not (tmp_path / "documents" / document_id / "original.exe").exists()


def test_document_upload_rejects_oversized_streamed_upload(tmp_path, monkeypatch):
    import main

    monkeypatch.setattr(main, "DOCUMENT_MAX_UPLOAD_SIZE", 3)

    class StreamedUpload:
        filename = "tax.pdf"

        def __init__(self):
            self.chunks = iter((b"12", b"345"))

        async def read(self, _chunk_size):
            return next(self.chunks, b"")

    async def exercise_bounded_reader():
        with pytest.raises(main.HTTPException) as error:
            await main._read_bounded_upload(StreamedUpload())
        assert error.value.status_code == 413

    asyncio.run(exercise_bounded_reader())


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
            data={"metadata": json.dumps({"id": document_id})},
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
        data={"metadata": json.dumps({"id": document_id, "kind": "tax"})},
        files={"file": ("return.pdf", content, "application/pdf")},
    )
    assert uploaded.status_code == 200
    assert uploaded.json() == {"status": "ok", "id": document_id}

    retrieved = client.get(f"/documents/{document_id}/file", headers=AUTH)
    assert retrieved.status_code == 200
    assert retrieved.content == content
    assert retrieved.headers["content-type"] == "application/pdf"


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


def test_document_retrieval_rejects_invalid_id():
    response = client.get("/documents/not-a-uuid/file", headers=AUTH)
    assert response.status_code == 400
