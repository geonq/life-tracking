import asyncio
import copy
import hashlib
import json
import os
import threading
import time
from datetime import datetime, timedelta, timezone

import httpx
import pytest
from fastapi.testclient import TestClient

os.environ["LIFEOS_TAILSCALE_ALLOWED_LOGIN"] = "test-user@example.com"
os.environ["LIFEOS_TAILSCALE_EDGE_TOKEN"] = "e" * 64

import enablebanking
import main

client = TestClient(main.app)


class FakeResponse:
    def __init__(self, payload, status_code=200):
        self.status_code = status_code
        self.body = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.headers = {"content-length": str(len(self.body))}

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    async def aiter_bytes(self):
        yield self.body


class QueueClient:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    async def __aenter__(self):
        return self

    async def __aexit__(self, *_):
        return None

    def stream(self, method, url, **kwargs):
        self.calls.append((method, url, kwargs))
        response = self.responses.pop(0)
        if isinstance(response, Exception):
            raise response
        return response


def service(tmp_path, monkeypatch):
    key = tmp_path / "private.key"
    cert = tmp_path / "public.crt"
    key.write_bytes(b"test-private-key")
    key.chmod(0o600)
    cert.write_bytes(b"test-public-certificate")
    monkeypatch.setenv("ENABLE_BANKING_APP_ID", "test-app-id")
    monkeypatch.setenv("ENABLE_BANKING_PRIVATE_KEY_PATH", str(key))
    monkeypatch.setenv("ENABLE_BANKING_CERTIFICATE_PATH", str(cert))
    monkeypatch.setenv("ENABLE_BANKING_API_BASE_URL", "https://api.enablebanking.com")
    monkeypatch.setenv(
        "ENABLE_BANKING_REDIRECT_URI",
        "https://geonqserver.tail5f8789.ts.net:8420/finance/callback",
    )
    result = enablebanking.EnableBankingService(
        data_dir=lambda: tmp_path,
        validate_finance_payload=main._validate_finance_payload,
        max_safe_cents=main.FINANCE_MAX_SAFE_CENTS,
        validate_persisted_finance_payload=main._validate_persisted_finance_payload,
    )
    monkeypatch.setattr(result, "_build_jwt", lambda *_: "test.jwt.signature")
    return result


def run(coro):
    return asyncio.run(coro)


def test_async_runtime_status_offloads_delayed_protected_storage(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    started = threading.Event()
    release = threading.Event()
    worker_names = []
    expected = {"blocked": False, "failure": None}

    def delayed_runtime_status():
        worker_names.append(threading.current_thread().name)
        started.set()
        release.wait(timeout=1)
        return expected

    monkeypatch.setattr(adapter, "runtime_status", delayed_runtime_status)

    async def scenario():
        task = asyncio.create_task(adapter.runtime_status_async())
        deadline = time.monotonic() + 1
        ticks = 0
        while not started.is_set() and time.monotonic() < deadline:
            ticks += 1
            await asyncio.sleep(0)
        assert started.is_set()
        # The delayed protected operation must leave the event loop runnable.
        while not task.done() and ticks < 10:
            ticks += 1
            await asyncio.sleep(0)
        release.set()
        assert await task == expected
        assert ticks >= 2
        assert len(worker_names) == 1
        assert worker_names[0].startswith("lifeos-protected-storage_")

    run(scenario())


def test_repeated_cancellation_keeps_domain_lock_until_storage_finishes(monkeypatch):
    domain_lock = asyncio.Lock()
    first_started = threading.Event()
    second_requested = threading.Event()
    second_entered = threading.Event()
    release_first = threading.Event()
    first_finished = threading.Event()
    active = 0
    maximum_active = 0
    active_lock = threading.Lock()
    events = []

    def first_write():
        nonlocal active, maximum_active
        with active_lock:
            active += 1
            maximum_active = max(maximum_active, active)
            events.append("first-start")
        first_started.set()
        assert release_first.wait(timeout=2)
        with active_lock:
            active -= 1
            events.append("first-finish")
        first_finished.set()
        return "first"

    def second_write():
        nonlocal active, maximum_active
        with active_lock:
            active += 1
            maximum_active = max(maximum_active, active)
            events.append("second-start")
        with active_lock:
            active -= 1
            events.append("second-finish")
        return "second"

    async def writer(operation):
        async with domain_lock:
            return await enablebanking.run_protected_storage(operation)

    async def scenario():
        first = asyncio.create_task(writer(first_write))
        deadline = time.monotonic() + 1
        while not first_started.is_set() and time.monotonic() < deadline:
            await asyncio.sleep(0.001)
        assert first_started.is_set()

        async def waiting_writer():
            second_requested.set()
            async with domain_lock:
                second_entered.set()
                return await enablebanking.run_protected_storage(second_write)

        second = asyncio.create_task(waiting_writer())
        while not second_requested.is_set():
            await asyncio.sleep(0)
        await asyncio.sleep(0)
        assert not second_entered.is_set()

        first.cancel()
        await asyncio.sleep(0)
        first.cancel()
        await asyncio.sleep(0)
        assert not first.done()
        assert not first_finished.is_set()
        assert not second_entered.is_set()

        release_first.set()
        with pytest.raises(asyncio.CancelledError):
            await first
        assert first_finished.is_set()
        assert await asyncio.wait_for(second, timeout=1) == "second"
        assert second_entered.is_set()
        assert maximum_active == 1
        assert events == ["first-start", "first-finish", "second-start", "second-finish"]

    run(scenario())


def test_protected_storage_rejects_when_admission_budget_is_full(monkeypatch):
    slots = threading.BoundedSemaphore(1)
    started = threading.Event()
    release = threading.Event()
    monkeypatch.setattr(enablebanking, "_PROTECTED_STORAGE_SLOTS", slots)

    def delayed_write():
        started.set()
        assert release.wait(timeout=2)
        return "done"

    async def scenario():
        first = asyncio.create_task(enablebanking.run_protected_storage(delayed_write))
        deadline = time.monotonic() + 1
        while not started.is_set() and time.monotonic() < deadline:
            await asyncio.sleep(0.001)
        assert started.is_set()
        with pytest.raises(enablebanking.ProtectedStorageOverloaded):
            await enablebanking.run_protected_storage(lambda: "rejected")
        release.set()
        assert await first == "done"

    run(scenario())


def test_protected_storage_shutdown_drains_without_cancelling(monkeypatch):
    calls = []

    class FakeExecutor:
        def shutdown(self, *, wait, cancel_futures):
            calls.append((wait, cancel_futures))

    monkeypatch.setattr(enablebanking, "_PROTECTED_STORAGE_EXECUTOR", FakeExecutor())
    monkeypatch.setattr(enablebanking, "_PROTECTED_STORAGE_EXECUTOR_CLOSED", False)

    enablebanking.shutdown_protected_storage_executor()
    enablebanking.shutdown_protected_storage_executor()

    assert calls == [(True, False)]


def test_protected_storage_submission_failure_is_typed_and_releases_slot(monkeypatch):
    class ClosedExecutor:
        def submit(self, *_args, **_kwargs):
            raise RuntimeError("cannot schedule new futures after shutdown")

    slots = threading.BoundedSemaphore(1)
    monkeypatch.setattr(enablebanking, "_PROTECTED_STORAGE_SLOTS", slots)
    monkeypatch.setattr(enablebanking, "_PROTECTED_STORAGE_EXECUTOR", ClosedExecutor())
    monkeypatch.setattr(enablebanking, "_PROTECTED_STORAGE_EXECUTOR_CLOSED", False)

    async def scenario():
        with pytest.raises(enablebanking.ProtectedStorageUnavailable):
            await enablebanking.run_protected_storage(lambda: "never runs")

    run(scenario())
    assert slots.acquire(blocking=False), "submission failure must return admission capacity"
    slots.release()


def test_credentials_accept_exact_allowlisted_https_destinations(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)

    credentials = adapter._credentials()

    assert credentials is not None
    assert credentials["api_base_url"] == "https://api.enablebanking.com"
    assert credentials["redirect_uri"] == (
        "https://geonqserver.tail5f8789.ts.net:8420/finance/callback"
    )


def test_runtime_credentials_do_not_require_registration_certificate(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    monkeypatch.delenv("ENABLE_BANKING_CERTIFICATE_PATH", raising=False)

    credentials = adapter._credentials()

    assert credentials is not None
    assert "certificate_path" not in credentials


def test_provider_client_keeps_tls_verification_and_omits_registration_certificate(
    tmp_path, monkeypatch,
):
    adapter = service(tmp_path, monkeypatch)
    captured = {}

    def fake_async_client(**kwargs):
        captured.update(kwargs)
        return object()

    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", fake_async_client)

    adapter._http_client()

    assert captured["verify"] is True
    assert "cert" not in captured


@pytest.mark.parametrize(
    ("environment_name", "value"),
    [
        ("ENABLE_BANKING_API_BASE_URL", "http://api.enablebanking.com"),
        ("ENABLE_BANKING_API_BASE_URL", "https://api.enablebanking.com/"),
        ("ENABLE_BANKING_API_BASE_URL", "https://api.enablebanking.com.evil.example"),
        ("ENABLE_BANKING_API_BASE_URL", "https://evil.example"),
        ("ENABLE_BANKING_API_BASE_URL", "https://api.enablebanking.com?next=https://evil.example"),
        ("ENABLE_BANKING_REDIRECT_URI", "http://geonqserver.tail5f8789.ts.net:8420/finance/callback"),
        ("ENABLE_BANKING_REDIRECT_URI", "https://evil.example/finance/callback"),
        ("ENABLE_BANKING_REDIRECT_URI", "https://geonqserver.tail5f8789.ts.net:8420/callback"),
        ("ENABLE_BANKING_REDIRECT_URI", "https://geonqserver.tail5f8789.ts.net:8420/finance/callback/"),
        ("ENABLE_BANKING_REDIRECT_URI", "https://geonqserver.tail5f8789.ts.net:8420/finance/callback?next=https://evil.example"),
        ("ENABLE_BANKING_REDIRECT_URI", "https://geonqserver.tail5f8789.ts.net:8420/finance/callback#fragment"),
    ],
)
def test_credentials_reject_unallowlisted_or_unsafe_https_destinations(
    tmp_path, monkeypatch, environment_name, value,
):
    adapter = service(tmp_path, monkeypatch)
    monkeypatch.setenv(environment_name, value)

    assert adapter._credentials() is None


@pytest.mark.parametrize(
    ("environment_name", "value"),
    [
        ("ENABLE_BANKING_API_BASE_URL", "https://evil.example"),
        ("ENABLE_BANKING_REDIRECT_URI", "https://evil.example/finance/callback"),
    ],
)
def test_start_rejects_unallowlisted_destination_before_network(
    tmp_path, monkeypatch, environment_name, value,
):
    adapter = service(tmp_path, monkeypatch)
    monkeypatch.setenv(environment_name, value)
    monkeypatch.setattr(
        enablebanking.httpx,
        "AsyncClient",
        lambda **_: (_ for _ in ()).throw(AssertionError("unsafe configuration must not call provider")),
    )

    assert run(adapter.start("revolut_personal")) == (
        503,
        {"error": "finance_connect_unavailable"},
    )


@pytest.mark.parametrize(
    "consent_url",
    [
        "http://auth.enablebanking.com/ais/start?sessionid=provider-session",
        "https://evil.example/ais/start?sessionid=provider-session",
        "https://auth.enablebanking.com.evil.example/ais/start?sessionid=provider-session",
        "https://auth.enablebanking.com:443/ais/start?sessionid=provider-session",
        "https://auth.enablebanking.com/other?sessionid=provider-session",
        "https://auth.enablebanking.com/ais/start?sessionid=provider-session&redirect_uri=https%3A%2F%2Fevil.example",
        "https://auth.enablebanking.com/ais/start?sessionid=provider-session#fragment",
    ],
)
def test_consent_url_requires_exact_provider_destination(consent_url):
    assert not enablebanking.EnableBankingService._safe_consent_url(consent_url)


def test_consent_url_accepts_exact_provider_handoff():
    assert enablebanking.EnableBankingService._safe_consent_url(
        "https://auth.enablebanking.com/ais/start?sessionid=provider-session"
    )


def test_start_rejects_provider_consent_destination_without_creating_a_flow(
    tmp_path, monkeypatch,
):
    adapter = service(tmp_path, monkeypatch)
    holder = QueueClient([
        FakeResponse({"aspsps": [{"name": "Revolut", "country": "LT"}]}),
        FakeResponse({
            "url": "https://evil.example/ais/start?sessionid=provider-session",
            "authorization_id": "authorization-1",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    assert run(adapter.start("revolut_personal")) == (
        503,
        {"error": "finance_connect_unavailable"},
    )
    assert adapter.consent_flows == {}


def test_start_never_treats_an_institution_id_as_a_destination(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    monkeypatch.setattr(
        enablebanking.httpx,
        "AsyncClient",
        lambda **_: (_ for _ in ()).throw(AssertionError("invalid institution must not call provider")),
    )

    assert run(adapter.start("https://evil.example/finance/callback")) == (
        400,
        {"error": "invalid_request"},
    )


def fixture_finance_summary(institutions):
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    accounts = []
    transactions = []
    for index, institution_id in enumerate(institutions, start=1):
        source = f"enablebanking:{institution_id}"
        provenance = {
            "source": source,
            "observedAt": observed_at,
            "freshness": "fresh",
            "quality": "observed",
            "connectorState": "healthy",
        }
        accounts.append({
            "availability": "observed",
            "id": f"ebacct-fixture-{index}",
            "name": f"{institution_id} · Main",
            "detail": "EUR · Enable Banking",
            "balanceCents": index * 100_000,
            "source": source,
            "provenance": provenance,
        })
        transactions.append({
            "id": f"ebtx-fixture-{index}",
            "merchant": "REWE",
            "title": "REWE",
            "signedAmountCents": -100 * index,
            "timestamp": observed_at,
            "account": f"{institution_id} · Main",
            "source": source,
            "category": "Groceries",
            "provenance": provenance,
        })
    transaction_provenance = {
        "source": "derived-transaction-snapshot",
        "observedAt": observed_at,
        "freshness": "fresh",
        "quality": "observed",
        "connectorState": "healthy",
    }
    unavailable = {
        "availability": "unavailable",
        "provenance": {
            "source": "no-authorized-finance-source",
            "observedAt": observed_at,
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable",
        },
    }
    return {
        "generatedAt": observed_at,
        "currency": "EUR",
        "monthlyIncome": {
            "availability": "observed",
            "amountCents": 0,
            "provenance": transaction_provenance,
        },
        "fixedCosts": {
            "availability": "observed",
            "amountCents": 0,
            "provenance": transaction_provenance,
        },
        "discretionaryBuffer": copy.deepcopy(unavailable),
        "spent": {
            "availability": "observed",
            "amountCents": sum(100 * index for index, _ in enumerate(institutions, start=1)),
            "provenance": transaction_provenance,
        },
        "savingsGoal": copy.deepcopy(unavailable),
        "saved": copy.deepcopy(unavailable),
        "accounts": {
            "availability": "observed",
            "accounts": accounts,
            "provenance": {
                "source": "derived-account-snapshot",
                "observedAt": observed_at,
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy",
            },
        },
        "transactions": {
            "availability": "observed",
            "transactions": transactions,
            "provenance": transaction_provenance,
        },
    }


def write_cached_summary(adapter, summary):
    adapter._atomic_write_json(adapter._runtime_path(), {
        **adapter.runtime_status(), "consentExpiresAt": "2099-01-01T00:00:00Z",
    })
    metadata = adapter._next_summary_metadata(summary)
    adapter._atomic_write_json(adapter._summary_state_path(), {
        "schemaVersion": adapter.FINANCE_STATE_SCHEMA_VERSION,
        "summary": summary,
        "metadata": metadata,
    })
    adapter._atomic_write_json(adapter._summary_metadata_path(), metadata)
    adapter._atomic_write_json(adapter._summary_path(), summary)


def test_start_resolves_sparkasse_and_returns_opaque_handoff(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    holder = QueueClient([
        FakeResponse({"aspsps": [{"name": "Stadt- und Kreissparkasse Leipzig", "country": "DE"}]}),
        FakeResponse({
            "url": "https://auth.enablebanking.com/ais/start?sessionid=provider-session",
            "authorization_id": "authorization-1",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    status, body = run(adapter.start("sparkasse_leipzig"))

    assert status == 200
    assert set(body) == {"consentUrl", "connectionId"}
    assert body["consentUrl"].startswith("https://")
    assert body["connectionId"].startswith("eb-")
    assert holder.calls[0][0:2] == ("GET", "https://api.enablebanking.com/aspsps")
    assert holder.calls[0][2]["params"] == {"country": "DE"}
    auth_body = json.loads(holder.calls[1][2]["content"])
    assert auth_body["aspsp"] == {
        "name": "Stadt- und Kreissparkasse Leipzig",
        "country": "DE",
    }
    assert "test-private-key" not in json.dumps(body)


def test_fastapi_connect_route_exposes_connection_id_contract(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    holder = QueueClient([
        FakeResponse({"aspsps": [{"name": "Revolut", "country": "LT"}]}),
        FakeResponse({
            "url": "https://auth.enablebanking.com/ais/start?sessionid=provider-session",
            "authorization_id": "authorization-1",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)
    monkeypatch.setattr(main, "enable_banking", adapter)

    response = client.post(
        "/finance/connect",
        headers={
            "Tailscale-User-Login": "test-user@example.com",
            "X-LifeOS-Trusted-Edge": "e" * 64,
        },
        json={"institutionId": "revolut_personal"},
    )

    assert response.status_code == 200
    assert set(response.json()) == {"consentUrl", "connectionId"}
    assert response.headers["cache-control"] == "no-store"


def test_start_replays_same_connector_flow_without_creating_provider_duplicate(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    holder = QueueClient([
        FakeResponse({"aspsps": [{"name": "Revolut", "country": "LT"}]}),
        FakeResponse({
            "url": "https://auth.enablebanking.com/ais/start?sessionid=provider-session",
            "authorization_id": "authorization-1",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    first_status, first_body = run(adapter.start("revolut_personal"))
    second_status, second_body = run(adapter.start("revolut_personal"))

    assert first_status == second_status == 200
    assert second_body == first_body
    assert len(holder.calls) == 2


def test_start_keeps_other_connector_blocked_while_a_flow_is_active(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    holder = QueueClient([
        FakeResponse({"aspsps": [{"name": "Revolut", "country": "LT"}]}),
        FakeResponse({
            "url": "https://auth.enablebanking.com/ais/start?sessionid=provider-session",
            "authorization_id": "authorization-1",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    assert run(adapter.start("revolut_personal"))[0] == 200
    assert run(adapter.start("sparkasse_leipzig")) == (409, {"error": "already_linking"})
    assert len(holder.calls) == 2


def test_start_rejects_consent_url_fragment_and_expires_flow(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    holder = QueueClient([
        FakeResponse({"aspsps": [{"name": "Revolut", "country": "LT"}]}),
        FakeResponse({
            "url": "https://auth.enablebanking.com/ais/start?sessionid=x#fragment",
            "authorization_id": "authorization-1",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)
    status, body = run(adapter.start("revolut_personal"))
    assert (status, body) == (503, {"error": "finance_connect_unavailable"})
    assert adapter.consent_flows == {}

    adapter.consent_flows["expired-flow"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": 0,
        "csrf_state": "unused",
        "authorization_id": "unused",
        "session_id": None,
    }
    assert run(adapter.status("expired-flow")) == {"state": "expired"}


def test_unknown_provider_session_state_fails_closed(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    assert adapter._session_state("A_NEW_PROVIDER_STATE") == "error"
    assert adapter._session_state(None) == "error"


def test_closed_and_revoked_provider_states_remain_revoked(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    assert adapter._session_state("CLOSED") == "revoked"
    assert adapter._session_state("REVOKED") == "revoked"

    adapter.consent_flows["eb-revoked"] = {
        "state": "revoked",
        "institutionId": "revolut_personal",
        "started": time.monotonic(),
        "csrf_state": None,
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    monkeypatch.setattr(
        enablebanking.httpx,
        "AsyncClient",
        lambda **_: (_ for _ in ()).throw(AssertionError("revoked status must not refresh")),
    )
    assert run(adapter.status("eb-revoked")) == {"state": "revoked"}


def test_expired_status_does_not_silently_refresh_persisted_connection(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-expired",
        "institutionId": "revolut_personal",
        "sessionId": "session-expired",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    adapter.consent_flows["eb-expired"] = {
        "state": "expired",
        "institutionId": "revolut_personal",
        "started": time.monotonic(),
        "csrf_state": None,
        "authorization_id": "authorization-1",
        "session_id": "session-expired",
    }
    monkeypatch.setattr(
        enablebanking.httpx,
        "AsyncClient",
        lambda **_: (_ for _ in ()).throw(AssertionError("expired status must not refresh")),
    )

    assert run(adapter.status("eb-expired")) == {"state": "expired"}


def test_callback_does_not_link_closed_provider_session(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-flow"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-token",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    holder = QueueClient([
        FakeResponse({"session_id": "session-closed", "status": "CLOSED"}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    result = run(adapter.callback("code=authorization-code&state=csrf-token"))

    assert result == enablebanking.CallbackResult(valid=True, linked=False)
    assert run(adapter.status("eb-flow")) == {"state": "revoked"}
    assert not (tmp_path / "enablebanking-connections.json").exists()


def test_revoke_sends_authenticated_delete_and_filters_only_revoked_cache_rows(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-revolut",
        "institutionId": "revolut_personal",
        "sessionId": "session-revolut",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    adapter._save_connection({
        "connectionId": "eb-sparkasse",
        "institutionId": "sparkasse_leipzig",
        "sessionId": "session-sparkasse",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    summary = fixture_finance_summary(["revolut_personal", "sparkasse_leipzig"])
    assert main._validate_finance_payload(summary)
    write_cached_summary(adapter, summary)
    holder = QueueClient([FakeResponse(b"", status_code=204)])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    status, body = run(adapter.revoke("revolut_personal"))

    assert (status, body) == (200, {"state": "revoked"})
    assert holder.calls[0][0:2] == (
        "DELETE",
        "https://api.enablebanking.com/sessions/session-revolut",
    )
    assert holder.calls[0][2]["headers"] == {
        "Authorization": "Bearer test.jwt.signature",
    }
    assert json.loads((tmp_path / "enablebanking-connections.json").read_text()) == {
        "connections": [{
            "connectionId": "eb-sparkasse",
            "institutionId": "sparkasse_leipzig",
            "sessionId": "session-sparkasse",
            "linkedAt": "2026-08-01T00:00:00Z",
        }]
    }
    cached = json.loads((tmp_path / "finance-summary.json").read_text())
    assert main._validate_persisted_finance_payload(cached)
    assert all(
        row["source"] == "enablebanking:sparkasse_leipzig"
        for row in cached["accounts"]["accounts"] + cached["transactions"]["transactions"]
    )
    assert cached["spent"]["amountCents"] == 200
    assert "session-revolut" not in json.dumps(cached)
    assert "test.jwt.signature" not in json.dumps(cached)
    assert not (tmp_path / "enablebanking-revocation.json").exists()
    assert run(adapter.status("eb-revolut")) == {"state": "revoked"}


def test_revoke_persists_sanitized_tombstone_across_restart(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-restart",
        "institutionId": "revolut_personal",
        "sessionId": "session-never-in-tombstone",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    holder = QueueClient([FakeResponse(b"", status_code=204)])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    assert run(adapter.revoke("revolut_personal")) == (200, {"state": "revoked"})

    tombstone_path = tmp_path / "enablebanking-revoked.json"
    tombstones = json.loads(tombstone_path.read_text())
    assert set(tombstones) == {"schemaVersion", "tombstones"}
    assert tombstones["schemaVersion"] == 1
    assert tombstones["tombstones"] and set(tombstones["tombstones"][0]) == {
        "connectionId", "institutionId", "revokedAt",
    }
    assert tombstones["tombstones"][0]["connectionId"] == "eb-restart"
    assert "session-never-in-tombstone" not in tombstone_path.read_text()

    restarted = service(tmp_path, monkeypatch)
    monkeypatch.setattr(
        restarted,
        "_get_session",
        lambda *_: (_ for _ in ()).throw(AssertionError("revoked tombstone must not refresh")),
    )
    assert run(restarted.status("eb-restart")) == {"state": "revoked"}


def test_revoke_allows_a_new_consent_flow_for_the_same_institution(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-original",
        "institutionId": "revolut_personal",
        "sessionId": "session-original",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    revoke_client = QueueClient([FakeResponse(b"", status_code=204)])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: revoke_client)
    assert run(adapter.revoke("revolut_personal")) == (200, {"state": "revoked"})

    relink_client = QueueClient([
        FakeResponse({"aspsps": [{"name": "Revolut", "country": "LT"}]}),
        FakeResponse({
            "url": "https://auth.enablebanking.com/ais/start?sessionid=new-session",
            "authorization_id": "authorization-new",
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: relink_client)

    status, body = run(adapter.start("revolut_personal"))

    assert status == 200
    assert body["connectionId"] != "eb-original"
    assert len(relink_client.calls) == 2


def test_interrupted_revocation_intent_recovers_all_local_projections(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-revolut",
        "institutionId": "revolut_personal",
        "sessionId": "session-revolut",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    adapter._save_connection({
        "connectionId": "eb-sparkasse",
        "institutionId": "sparkasse_leipzig",
        "sessionId": "session-sparkasse",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    write_cached_summary(
        adapter,
        fixture_finance_summary(["revolut_personal", "sparkasse_leipzig"]),
    )
    pending = adapter._prepare_revocation_state(
        "revolut_personal",
        adapter._load_connections(),
    )
    adapter._atomic_write_json(adapter._revocation_state_path(), pending)

    restarted = service(tmp_path, monkeypatch)
    connections = restarted._load_connections()
    cached = restarted.load_cached_summary()

    assert [connection["institutionId"] for connection in connections] == [
        "sparkasse_leipzig"
    ]
    assert cached is not None
    assert "enablebanking:revolut_personal" not in json.dumps(cached)
    assert "enablebanking:sparkasse_leipzig" in json.dumps(cached)
    assert not restarted._revocation_state_path().exists()


@pytest.mark.parametrize(
    "provider_response",
    [
        FakeResponse(b"", status_code=404),
        FakeResponse({"status": "CLOSED"}, status_code=409),
        FakeResponse({"status": "REVOKED"}, status_code=400),
    ],
)
def test_revoke_treats_missing_or_closed_provider_session_as_idempotent(
    provider_response, tmp_path, monkeypatch
):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-revoke",
        "institutionId": "revolut_personal",
        "sessionId": "session-revoke",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    holder = QueueClient([provider_response])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    status, body = run(adapter.revoke("revolut_personal"))

    assert (status, body) == (200, {"state": "revoked"})
    assert json.loads((tmp_path / "enablebanking-connections.json").read_text()) == {
        "connections": []
    }


@pytest.mark.parametrize(
    "failure",
    [
        FakeResponse({"detail": "provider token must not escape"}, status_code=503),
        httpx.ConnectError("fixture network failure"),
    ],
)
def test_revoke_transient_failure_preserves_connection_and_cache(
    failure, tmp_path, monkeypatch
):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-revoke",
        "institutionId": "revolut_personal",
        "sessionId": "session-revoke",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    write_cached_summary(adapter, fixture_finance_summary(["revolut_personal"]))
    paths = [
        tmp_path / "enablebanking-connections.json",
        tmp_path / "finance-summary.json",
        tmp_path / "finance-summary.json.meta.json",
        tmp_path / "finance-summary.json.state.json",
    ]
    before = {path: path.read_bytes() for path in paths}
    holder = QueueClient([failure])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    status, body = run(adapter.revoke("revolut_personal"))

    assert (status, body) == (503, {"error": "temporary_error"})
    assert {path: path.read_bytes() for path in paths} == before
    assert not (tmp_path / "enablebanking-revocation.json").exists()
    assert "provider token must not escape" not in json.dumps(body)


def test_revoke_202_is_temporary_and_preserves_connection_and_cache(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-pending-revoke",
        "institutionId": "revolut_personal",
        "sessionId": "session-pending-revoke",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    write_cached_summary(adapter, fixture_finance_summary(["revolut_personal"]))
    paths = [
        tmp_path / "enablebanking-connections.json",
        tmp_path / "finance-summary.json",
        tmp_path / "finance-summary.json.meta.json",
        tmp_path / "finance-summary.json.state.json",
    ]
    before = {path: path.read_bytes() for path in paths}
    holder = QueueClient([FakeResponse({"status": "PENDING"}, status_code=202)])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    assert run(adapter.revoke("revolut_personal")) == (
        503,
        {"error": "temporary_error"},
    )
    assert {path: path.read_bytes() for path in paths} == before
    assert not (tmp_path / "enablebanking-revocation.json").exists()
    assert not (tmp_path / "enablebanking-revoked.json").exists()


@pytest.mark.parametrize(
    "provider_response, expected_status",
    [
        (FakeResponse({"status": "CLOSED"}, status_code=200), 200),
        (FakeResponse({"status": "PENDING"}, status_code=200), 503),
    ],
)
def test_revoke_200_requires_explicit_final_provider_state(
    provider_response, expected_status, tmp_path, monkeypatch
):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-200-revoke",
        "institutionId": "revolut_personal",
        "sessionId": "session-200-revoke",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    holder = QueueClient([provider_response])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    status, body = run(adapter.revoke("revolut_personal"))

    assert status == expected_status
    if expected_status == 200:
        assert body == {"state": "revoked"}
        assert json.loads((tmp_path / "enablebanking-connections.json").read_text()) == {
            "connections": []
        }
    else:
        assert body == {"error": "temporary_error"}
        persisted = json.loads(
            (tmp_path / "enablebanking-connections.json").read_text()
        )
        assert persisted["connections"][0]["connectionId"] == "eb-200-revoke"
        assert not (tmp_path / "enablebanking-revoked.json").exists()


def test_revoke_rejects_malformed_or_unknown_institution_without_network(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    monkeypatch.setattr(
        enablebanking.httpx,
        "AsyncClient",
        lambda **_: (_ for _ in ()).throw(AssertionError("invalid institution must not call provider")),
    )

    assert run(adapter.revoke("../revolut_personal")) == (400, {"error": "invalid_request"})
    assert run(adapter.revoke("unknown_institution")) == (400, {"error": "unknown_institution"})


def test_callback_exchanges_code_and_persists_only_opaque_connection(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-flow"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-token",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    holder = QueueClient([FakeResponse({"session_id": "session-1", "accounts": []})])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    result = run(adapter.callback("code=authorization-code&state=csrf-token"))

    assert result.valid and result.linked
    persisted = json.loads((tmp_path / "enablebanking-connections.json").read_text())
    assert persisted == {
        "connections": [{
            "connectionId": "eb-flow",
            "institutionId": "sparkasse_leipzig",
            "sessionId": "session-1",
            "linkedAt": persisted["connections"][0]["linkedAt"],
        }]
    }
    assert "authorization-code" not in (tmp_path / "enablebanking-connections.json").read_text()


def test_callback_duplicate_first_failure_does_not_trigger_fallback_exchange(
    tmp_path, monkeypatch
):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-coalesced-failure"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-coalesced-failure",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    entered, release = asyncio.Event(), asyncio.Event()
    exchange_calls = []
    save_calls = []
    complete_calls = []
    original_save = adapter._save_connection
    original_complete = adapter._complete_callback_locked

    async def exchange(_client, _credentials, _token, code):
        exchange_calls.append(code)
        entered.set()
        await release.wait()
        if len(exchange_calls) == 1:
            raise httpx.ConnectError("provider failure")
        return {"session_id": "session-fallback-must-not-exist", "accounts": []}

    def save(connection):
        save_calls.append(connection)
        return original_save(connection)

    def complete(flow, **kwargs):
        complete_calls.append(kwargs["state"])
        return original_complete(flow, **kwargs)

    monkeypatch.setattr(adapter, "_exchange_code", exchange)
    monkeypatch.setattr(adapter, "_save_connection", save)
    monkeypatch.setattr(adapter, "_complete_callback_locked", complete)
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: QueueClient([]))
    query = "code=authorization-code&state=csrf-coalesced-failure"

    async def scenario():
        duplicate = asyncio.create_task(adapter.callback(query))
        await entered.wait()
        original = asyncio.create_task(adapter.callback(query))
        release.set()
        return await asyncio.gather(duplicate, original)

    results = run(scenario())

    # A retrying second exchange would be able to return success in this
    # double. The claimed operation makes the first provider result the one
    # durable outcome instead, avoiding both a code replay and an orphaned
    # local connection.
    assert results == [
        enablebanking.CallbackResult(valid=True, linked=False),
        enablebanking.CallbackResult(valid=True, linked=False),
    ]
    assert exchange_calls == ["authorization-code"]
    assert save_calls == []
    assert complete_calls == ["error"]
    assert adapter.consent_flows["eb-coalesced-failure"]["state"] == "error"
    assert not (tmp_path / "enablebanking-connections.json").exists()


def test_callback_original_first_success_is_shared_and_persisted_once(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-coalesced-success"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-coalesced-success",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    entered, release = asyncio.Event(), asyncio.Event()
    exchange_calls = []
    save_calls = []
    original_save = adapter._save_connection

    async def exchange(_client, _credentials, _token, code):
        exchange_calls.append(code)
        entered.set()
        await release.wait()
        return {"session_id": "session-coalesced", "accounts": []}

    def save(connection):
        save_calls.append(connection)
        return original_save(connection)

    monkeypatch.setattr(adapter, "_exchange_code", exchange)
    monkeypatch.setattr(adapter, "_save_connection", save)
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: QueueClient([]))
    query = "code=authorization-code&state=csrf-coalesced-success"

    async def scenario():
        original = asyncio.create_task(adapter.callback(query))
        await entered.wait()
        duplicate = asyncio.create_task(adapter.callback(query))
        await asyncio.sleep(0)
        assert exchange_calls == ["authorization-code"]
        release.set()
        return await asyncio.gather(original, duplicate), await adapter.callback(query)

    results, replay = run(scenario())

    expected = enablebanking.CallbackResult(valid=True, linked=True)
    assert results == [expected, expected]
    assert replay == expected
    assert exchange_calls == ["authorization-code"]
    assert len(save_calls) == 1
    assert json.loads((tmp_path / "enablebanking-connections.json").read_text()) == {
        "connections": [{
            "connectionId": "eb-coalesced-success",
            "institutionId": "sparkasse_leipzig",
            "sessionId": "session-coalesced",
            "linkedAt": save_calls[0]["linkedAt"],
        }]
    }


def test_callback_error_cancels_inflight_outcome_without_provider_replay(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-callback-error"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-callback-error",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    entered, release = asyncio.Event(), asyncio.Event()
    exchange_calls = []
    save_calls = []
    original_save = adapter._save_connection

    async def exchange(_client, _credentials, _token, code):
        exchange_calls.append(code)
        entered.set()
        await release.wait()
        return {"session_id": "session-after-cancel", "accounts": []}

    def save(connection):
        save_calls.append(connection)
        return original_save(connection)

    monkeypatch.setattr(adapter, "_exchange_code", exchange)
    monkeypatch.setattr(adapter, "_save_connection", save)
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: QueueClient([]))

    async def scenario():
        owner = asyncio.create_task(
            adapter.callback("code=authorization-code&state=csrf-callback-error")
        )
        await entered.wait()
        cancelled = await adapter.callback(
            "error=access_denied&state=csrf-callback-error"
        )
        assert cancelled == enablebanking.CallbackResult(valid=True, linked=False)
        assert adapter.consent_flows["eb-callback-error"]["state"] == "error"
        release.set()
        return cancelled, await owner

    cancelled, owner = run(scenario())

    assert cancelled == owner == enablebanking.CallbackResult(valid=True, linked=False)
    assert exchange_calls == ["authorization-code"]
    assert save_calls == []
    assert not (tmp_path / "enablebanking-connections.json").exists()


def test_cancelled_callback_waiter_does_not_cancel_claimed_exchange(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-callback-waiter"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-callback-waiter",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    entered, release = asyncio.Event(), asyncio.Event()
    exchange_calls = []
    save_calls = []
    original_save = adapter._save_connection

    async def exchange(_client, _credentials, _token, code):
        exchange_calls.append(code)
        entered.set()
        await release.wait()
        return {"session_id": "session-after-waiter-cancel", "accounts": []}

    def save(connection):
        save_calls.append(connection)
        return original_save(connection)

    monkeypatch.setattr(adapter, "_exchange_code", exchange)
    monkeypatch.setattr(adapter, "_save_connection", save)
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: QueueClient([]))
    query = "code=authorization-code&state=csrf-callback-waiter"

    async def scenario():
        cancelled_waiter = asyncio.create_task(adapter.callback(query))
        await entered.wait()
        cancelled_waiter.cancel()
        with pytest.raises(asyncio.CancelledError):
            await cancelled_waiter
        remaining_waiter = asyncio.create_task(adapter.callback(query))
        await asyncio.sleep(0)
        assert exchange_calls == ["authorization-code"]
        release.set()
        return await remaining_waiter

    result = run(scenario())

    assert result == enablebanking.CallbackResult(valid=True, linked=True)
    assert exchange_calls == ["authorization-code"]
    assert len(save_calls) == 1
    assert adapter.consent_flows["eb-callback-waiter"]["state"] == "linked"


def test_callback_expiry_wins_over_inflight_provider_success(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter.consent_flows["eb-callback-expiry"] = {
        "state": "created",
        "institutionId": "sparkasse_leipzig",
        "started": time.monotonic(),
        "csrf_state": "csrf-callback-expiry",
        "authorization_id": "authorization-1",
        "session_id": None,
    }
    entered, release = asyncio.Event(), asyncio.Event()
    exchange_calls = []
    save_calls = []
    original_save = adapter._save_connection

    async def exchange(_client, _credentials, _token, code):
        exchange_calls.append(code)
        entered.set()
        await release.wait()
        return {"session_id": "session-after-expiry", "accounts": []}

    def save(connection):
        save_calls.append(connection)
        return original_save(connection)

    monkeypatch.setattr(adapter, "_exchange_code", exchange)
    monkeypatch.setattr(adapter, "_save_connection", save)
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: QueueClient([]))

    async def scenario():
        owner = asyncio.create_task(
            adapter.callback("code=authorization-code&state=csrf-callback-expiry")
        )
        await entered.wait()
        adapter.consent_flows["eb-callback-expiry"]["started"] = (
            time.monotonic() - adapter.FLOW_TTL_SECONDS - 1
        )
        status = await adapter.status("eb-callback-expiry")
        release.set()
        return status, await owner

    status, owner = run(scenario())

    assert status == {"state": "expired"}
    assert owner == enablebanking.CallbackResult(valid=True, linked=False)
    assert exchange_calls == ["authorization-code"]
    assert save_calls == []
    assert adapter.consent_flows["eb-callback-expiry"]["state"] == "expired"
    assert not (tmp_path / "enablebanking-connections.json").exists()


def test_revoke_wins_deterministic_callback_persistence_race(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-existing",
        "institutionId": "revolut_personal",
        "sessionId": "session-existing",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    adapter.consent_flows["eb-callback"] = {
        "state": "created",
        "institutionId": "revolut_personal",
        "started": time.monotonic(),
        "csrf_state": "csrf-race",
        "authorization_id": "authorization-race",
        "session_id": None,
    }
    exchanged = asyncio.Event()
    release_exchange = asyncio.Event()
    exchange_calls = []

    async def exchange(_client, _credentials, _token, _code):
        exchange_calls.append(_code)
        exchanged.set()
        await release_exchange.wait()
        return {"session_id": "session-after-revoke", "accounts": []}

    async def delete(_client, _credentials, _token, _session_id):
        return None

    monkeypatch.setattr(adapter, "_exchange_code", exchange)
    monkeypatch.setattr(adapter, "_delete_session", delete)
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: QueueClient([]))

    async def scenario():
        callback_task = asyncio.create_task(
            adapter.callback("code=authorization-code&state=csrf-race")
        )
        await exchanged.wait()
        revoke_task = asyncio.create_task(adapter.revoke("revolut_personal"))
        revoke_result = await revoke_task
        release_exchange.set()
        callback_result = await callback_task
        return revoke_result, callback_result

    revoke_result, callback_result = run(scenario())

    assert revoke_result == (200, {"state": "revoked"})
    assert callback_result == enablebanking.CallbackResult(valid=True, linked=False)
    assert exchange_calls == ["authorization-code"]
    assert json.loads((tmp_path / "enablebanking-connections.json").read_text()) == {
        "connections": []
    }
    assert "session-after-revoke" not in "".join(
        path.read_text() for path in tmp_path.glob("*.json")
    )


def test_refresh_normalizes_realistic_account_and_transaction_shapes(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    (tmp_path / "enablebanking-connections.json").write_text(json.dumps({
        "connections": [
            {
                "connectionId": "legacy-sandbox-flow",
                "institutionId": "SANDBOXFINANCE_SINST_DE",
                "sessionId": "legacy-sandbox-session",
                "linkedAt": "2026-01-01T00:00:00Z",
            },
            {
                "connectionId": "eb-flow",
                "institutionId": "revolut_personal",
                "sessionId": "session-1",
                "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            },
        ]
    }))
    account_uid = "01234567-89ab-cdef-0123-456789abcdef"
    today = datetime.now(timezone.utc).date().isoformat()
    holder = QueueClient([
        FakeResponse({
            "status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"},
            "accounts": [{"uid": account_uid, "name": "Main account", "currency": "EUR"}],
        }),
        FakeResponse({"balances": [{
            "balance_type": "CLAV",
            "balance_amount": {"amount": "1234.56", "currency": "EUR"},
        }]}),
        FakeResponse({"transactions": [{
            "transaction_id": "tx-1",
            "transaction_amount": {"amount": "12.34", "currency": "EUR"},
            "credit_debit_indicator": "DBIT",
            "creditor": {"name": "REWE"},
            "booking_date": today,
            "merchant_category_code": "5411",
        }]}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    summary = run(adapter.refresh_summary())

    assert summary["accounts"]["accounts"][0]["balanceCents"] == 123456
    assert summary["transactions"]["transactions"][0]["signedAmountCents"] == -1234
    assert summary["transactions"]["transactions"][0]["category"] == "Groceries"
    assert main._validate_finance_payload(summary)
    cached = json.loads((tmp_path / "finance-summary.json").read_text())
    assert cached == summary
    metadata = json.loads((tmp_path / "finance-summary.json.meta.json").read_text())
    assert metadata["schemaVersion"] == 1
    assert metadata["domain"] == "finance"
    assert metadata["authority"] == "gateway"
    assert metadata["revision"] == 1
    assert metadata["bodyDigest"] == hashlib.sha256(
        json.dumps(summary, separators=(",", ":"), sort_keys=True, allow_nan=False).encode()
    ).hexdigest()
    assert metadata["idempotency"] == [{
        "key": f"finance-refresh-{metadata['bodyDigest']}",
        "fingerprint": metadata["bodyDigest"],
        "revision": 1,
    }]
    assert metadata["tombstones"] == []
    state_path = tmp_path / "finance-summary.json.state.json"
    committed_state = state_path.read_bytes()
    (tmp_path / ".finance-summary.json.state.json.interrupted.tmp").write_bytes(
        b'{"schemaVersion":1,"summary":'
    )
    assert adapter.summary_revision() == 1
    assert adapter.load_cached_summary() == summary
    assert state_path.read_bytes() == committed_state

    tampered = copy.deepcopy(summary)
    tampered["spent"]["amountCents"] += 1
    partial_state = json.loads(committed_state)
    partial_state["summary"] = tampered
    state_path.write_text(json.dumps(partial_state))
    assert adapter.load_cached_summary() is None


def test_refresh_preserves_mixed_currency_accounts_without_converting_them(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    eur_uid = "01234567-89ab-cdef-0123-456789abcdef"
    usd_uid = "11234567-89ab-cdef-0123-456789abcdef"
    today = datetime.now(timezone.utc).date().isoformat()
    holder = QueueClient([
        FakeResponse({
            "status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"},
            "accounts": [
                {"uid": eur_uid, "name": "Main account", "currency": "EUR"},
                {"uid": usd_uid, "name": "Dollar savings", "currency": "USD"},
            ],
        }),
        FakeResponse({"balances": [{
            "balance_type": "CLAV",
            "balance_amount": {"amount": "1234.56", "currency": "EUR"},
        }]}),
        FakeResponse({"transactions": [{
            "transaction_id": "tx-eur",
            "transaction_amount": {"amount": "12.34", "currency": "EUR"},
            "credit_debit_indicator": "DBIT",
            "creditor": {"name": "REWE"},
            "booking_date": today,
        }]}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    summary = run(adapter.refresh_summary())

    accounts = summary["accounts"]["accounts"]
    assert len(accounts) == 2
    observed = next(account for account in accounts if account["availability"] == "observed")
    unavailable = next(account for account in accounts if account["availability"] == "unavailable")
    assert observed["balanceCents"] == 123456
    assert unavailable["detail"] == "USD · Enable Banking"
    assert "balanceCents" not in unavailable
    assert unavailable["provenance"]["quality"] == "unavailable"
    assert main._validate_finance_payload(summary)
    assert len(holder.responses) == 0


def test_refresh_keeps_all_unsupported_currency_ledgers_unavailable(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    holder = QueueClient([
        FakeResponse({
            "status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"},
            "accounts": [{
                "uid": "21234567-89ab-cdef-0123-456789abcdef",
                "name": "Dollar savings",
                "currency": "USD",
            }],
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    summary = run(adapter.refresh_summary())

    assert summary["monthlyIncome"]["availability"] == "unavailable"
    assert summary["fixedCosts"]["availability"] == "unavailable"
    assert summary["spent"]["availability"] == "unavailable"
    assert summary["transactions"]["availability"] == "unavailable"
    assert main._validate_finance_payload(summary)
    assert len(holder.responses) == 0


def test_refresh_fails_closed_when_provider_returns_malformed_account(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    holder = QueueClient([
        FakeResponse({"status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"}, "accounts": [{"uid": "not-a-provider-account"}]}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())


def test_refresh_fails_closed_when_provider_returns_an_invalid_currency_code(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    holder = QueueClient([
        FakeResponse({
            "status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"},
            "accounts": [{
                "uid": "01234567-89ab-cdef-0123-456789abcdef",
                "name": "Main",
                "currency": "EURO",
            }],
        }),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())


def test_relinking_same_institution_replaces_stored_connection(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-original",
        "institutionId": "revolut_personal",
        "sessionId": "session-original",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    adapter._save_connection({
        "connectionId": "eb-relinked",
        "institutionId": "revolut_personal",
        "sessionId": "session-relinked",
        "linkedAt": "2026-08-28T00:00:00Z",
    })

    connections = adapter._load_connections()

    matching = [c for c in connections if c["institutionId"] == "revolut_personal"]
    assert len(matching) == 1
    assert matching[0]["connectionId"] == "eb-relinked"
    assert matching[0]["sessionId"] == "session-relinked"


def test_refresh_fails_closed_when_persisted_store_mixes_valid_and_malformed_records(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-good",
        "institutionId": "revolut_personal",
        "sessionId": "session-good",
        "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    path = tmp_path / "enablebanking-connections.json"
    payload = json.loads(path.read_text())
    payload["connections"].append({
        "connectionId": "eb-bad",
        "institutionId": "sparkasse_leipzig",
        "linkedAt": "2026-08-26T00:00:00Z",
    })
    path.write_text(json.dumps(payload))
    cached = tmp_path / "finance-summary.json"
    cached.write_text('{"sentinel":"prior"}')

    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())
    assert cached.read_text() == '{"sentinel":"prior"}'


@pytest.mark.parametrize(
    "replacement",
    [
        b"{not-json",
        b"[]",
        b"null",
        b'{"connections":[{"connectionId":"missing-fields"}]}' ,
    ],
)
def test_connection_store_corruption_blocks_save_and_preserves_bytes(
    replacement, tmp_path, monkeypatch,
):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-preserve",
        "institutionId": "revolut_personal",
        "sessionId": "session-preserve",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    path = tmp_path / "enablebanking-connections.json"
    path.write_bytes(replacement)

    with pytest.raises(enablebanking.ConnectionStoreUnavailable) as error:
        adapter._save_connection({
            "connectionId": "eb-new",
            "institutionId": "sparkasse_leipzig",
            "sessionId": "session-new",
            "linkedAt": "2026-08-02T00:00:00Z",
        })

    assert error.value.reason == "storage"
    assert str(error.value) == "finance connection storage unavailable"
    assert path.read_bytes() == replacement


def test_oversized_connection_store_blocks_mutation_without_reading_or_replacing_it(
    tmp_path, monkeypatch,
):
    adapter = service(tmp_path, monkeypatch)
    path = tmp_path / "enablebanking-connections.json"
    oversized = b"x" * (adapter.CONNECTION_STORE_MAX_BYTES + 1)
    path.write_bytes(oversized)

    with pytest.raises(enablebanking.ConnectionStoreUnavailable):
        adapter._save_connection({
            "connectionId": "eb-oversized",
            "institutionId": "revolut_personal",
            "sessionId": "session-oversized",
            "linkedAt": "2026-08-02T00:00:00Z",
        })

    assert path.read_bytes() == oversized


def test_bounded_json_reader_rejects_growth_after_descriptor_open(tmp_path, monkeypatch):
    path = tmp_path / "finance-summary.json"
    path.write_bytes(b"{}")
    real_read = enablebanking.os.read
    read_count = 0

    def read_with_growth(descriptor, size):
        nonlocal read_count
        chunk = real_read(descriptor, size)
        if read_count == 0:
            path.write_bytes(b"{" + b"x" * 16 + b"}")
        read_count += 1
        return chunk

    monkeypatch.setattr(enablebanking.os, "read", read_with_growth)
    assert enablebanking.EnableBankingService._read_bounded_json_file(path, 8) is None


def test_bounded_json_reader_rejects_symlink_and_oversized_files(tmp_path):
    target = tmp_path / "target.json"
    target.write_text("{}", encoding="utf-8")
    link = tmp_path / "finance-summary.json"
    try:
        link.symlink_to(target)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks are unavailable in this test environment")
    assert enablebanking.EnableBankingService._read_bounded_json_file(link, 8) is None
    link.unlink()
    link.write_bytes(b"x" * 9)
    assert enablebanking.EnableBankingService._read_bounded_json_file(link, 8) is None


def test_connection_store_symlink_and_directory_are_not_empty_storage(
    tmp_path, monkeypatch,
):
    adapter = service(tmp_path, monkeypatch)
    path = tmp_path / "enablebanking-connections.json"
    target = tmp_path / "connection-target.json"
    target.write_text('{"connections":[]}', encoding="utf-8")
    try:
        path.symlink_to(target)
    except (OSError, NotImplementedError):
        pytest.skip("symlinks are unavailable in this test environment")

    with pytest.raises(enablebanking.ConnectionStoreUnavailable):
        adapter._save_connection({
            "connectionId": "eb-symlink",
            "institutionId": "revolut_personal",
            "sessionId": "session-symlink",
            "linkedAt": "2026-08-02T00:00:00Z",
        })
    assert path.is_symlink()
    assert target.read_text(encoding="utf-8") == '{"connections":[]}'

    path.unlink()
    path.mkdir()
    with pytest.raises(enablebanking.ConnectionStoreUnavailable):
        adapter._load_connections()
    assert path.is_dir()


def test_unreadable_connection_store_blocks_mutation_without_replacement(
    tmp_path, monkeypatch,
):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-unreadable",
        "institutionId": "revolut_personal",
        "sessionId": "session-unreadable",
        "linkedAt": "2026-08-01T00:00:00Z",
    })
    path = tmp_path / "enablebanking-connections.json"
    before = path.read_bytes()
    original_open = enablebanking.os.open

    def deny_connection_store(value, flags, mode=0o777, *, dir_fd=None):
        if str(value) == str(path):
            raise PermissionError("connection store is unreadable")
        return original_open(value, flags, mode, dir_fd=dir_fd)

    monkeypatch.setattr(enablebanking.os, "open", deny_connection_store)
    with pytest.raises(enablebanking.ConnectionStoreUnavailable):
        adapter._save_connection({
            "connectionId": "eb-new-unreadable",
            "institutionId": "sparkasse_leipzig",
            "sessionId": "session-new-unreadable",
            "linkedAt": "2026-08-02T00:00:00Z",
        })
    assert path.read_bytes() == before


def test_cached_summary_becomes_truthfully_stale_after_provider_outage(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    observed_at = (datetime.now(timezone.utc) - main.FINANCE_STALE_AFTER - timedelta(minutes=1)).isoformat().replace("+00:00", "Z")
    # Start from a complete, provider-shaped summary and age every observed
    # provenance field without changing its data values.
    summary = {
        "generatedAt": observed_at,
        "currency": "EUR",
        "monthlyIncome": {"availability": "observed", "amountCents": 1000, "provenance": {"source": "revolut_personal", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"}},
        "fixedCosts": {"availability": "observed", "amountCents": 100, "provenance": {"source": "revolut_personal", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"}},
        "discretionaryBuffer": {"availability": "unavailable", "provenance": {"source": "no-authorized-finance-source", "observedAt": observed_at, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"}},
        "spent": {"availability": "observed", "amountCents": 200, "provenance": {"source": "revolut_personal", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"}},
        "savingsGoal": {"availability": "unavailable", "provenance": {"source": "no-authorized-finance-source", "observedAt": observed_at, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"}},
        "saved": {"availability": "unavailable", "provenance": {"source": "no-authorized-finance-source", "observedAt": observed_at, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"}},
    }
    cached = tmp_path / "finance-summary.json"
    cached.write_text(json.dumps(summary))
    metadata = adapter._next_summary_metadata(summary)
    adapter._atomic_write_json(adapter._summary_state_path(), {
        "schemaVersion": adapter.FINANCE_STATE_SCHEMA_VERSION,
        "summary": summary,
        "metadata": metadata,
    })
    adapter._atomic_write_json(adapter._summary_metadata_path(), metadata)

    adapter._atomic_write_json(adapter._runtime_path(), {
        **adapter.runtime_status(), "consentExpiresAt": "2099-01-01T00:00:00Z",
    })
    loaded = adapter.load_cached_summary()

    assert loaded is not None
    assert loaded["generatedAt"] == observed_at
    for key in ("monthlyIncome", "fixedCosts", "spent"):
        assert loaded[key]["provenance"]["freshness"] == "stale"
        assert loaded[key]["provenance"]["connectorState"] == "refresh_due"
    assert main._validate_finance_payload(loaded)


def test_finance_revision_journal_rolls_forward_without_eventual_write_lockout(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    monkeypatch.setattr(adapter, "MAX_FINANCE_JOURNAL_RECORDS", 2)

    metadata = None
    for index in range(3):
        metadata = adapter._next_summary_metadata({"revisionMarker": index})
        adapter._atomic_write_json(adapter._summary_metadata_path(), metadata)

    assert metadata is not None
    assert metadata["revision"] == 3
    assert [record["revision"] for record in metadata["idempotency"]] == [2, 3]


def test_cached_summary_backfills_new_merchant_categories_without_overwriting_labels(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    })
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
    row = {
        "id": "ebtx-cache-category",
        "merchant": "EDEKA Gerstmann",
        "title": "EDEKA Gerstmann",
        "signedAmountCents": -589,
        "timestamp": observed_at,
        "account": "revolut_personal · Main",
        "source": "enablebanking:revolut_personal",
        "category": "Uncategorized",
        "provenance": {
            "source": "enablebanking:revolut_personal",
            "observedAt": observed_at,
            "freshness": "fresh",
            "quality": "observed",
            "connectorState": "healthy",
        },
    }
    summary = {
        "generatedAt": observed_at,
        "currency": "EUR",
        "monthlyIncome": {"availability": "observed", "amountCents": 0, "provenance": {"source": "enablebanking:revolut_personal", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"}},
        "fixedCosts": {"availability": "observed", "amountCents": 0, "provenance": {"source": "enablebanking:revolut_personal", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"}},
        "discretionaryBuffer": {"availability": "unavailable", "provenance": {"source": "no-authorized-finance-source", "observedAt": observed_at, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"}},
        "spent": {"availability": "observed", "amountCents": 589, "provenance": {"source": "enablebanking:revolut_personal", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"}},
        "savingsGoal": {"availability": "unavailable", "provenance": {"source": "no-authorized-finance-source", "observedAt": observed_at, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"}},
        "saved": {"availability": "unavailable", "provenance": {"source": "no-authorized-finance-source", "observedAt": observed_at, "freshness": "unknown", "quality": "unavailable", "connectorState": "unavailable"}},
        "transactions": {
            "availability": "observed",
            "transactions": [row],
            "provenance": {"source": "derived-transaction-snapshot", "observedAt": observed_at, "freshness": "fresh", "quality": "observed", "connectorState": "healthy"},
        },
    }
    (tmp_path / "finance-summary.json").write_text(json.dumps(summary))

    adapter._atomic_write_json(adapter._runtime_path(), {
        **adapter.runtime_status(), "consentExpiresAt": "2099-01-01T00:00:00Z",
    })
    loaded = adapter.load_cached_summary()

    assert loaded is not None
    assert loaded["transactions"]["transactions"][0]["category"] == "Groceries"
    assert main._validate_finance_payload(loaded)


def test_transaction_category_uses_provider_label_mcc_and_merchant_fallback(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    assert adapter._transaction_category({"category": "Health", "merchant_category_code": "5411"}) == "Health"
    assert adapter._transaction_category({"merchant_category_code": "5814"}) == "Dining"
    assert adapter._transaction_category({"creditor": {"name": "REWE Markt"}}) == "Groceries"
    assert adapter._transaction_category({"merchant_category_code": "9999"}) == "Uncategorized"
    assert adapter._transaction_category({
        "credit_debit_indicator": "DBIT",
        "creditor": {"name": "Hausverwaltung"},
        "remittance_information_unstructured": ["Miete August"],
    }) == "Bills"
    assert adapter._transaction_category({
        "credit_debit_indicator": "DBIT",
        "creditor": {"name": "Überweisung an Freunde"},
    }) == "Transfers"
    assert adapter._transaction_category({
        "credit_debit_indicator": "CRDT",
        "debtor": {"name": "Employer"},
        "remittance_information_unstructured": ["Gehalt"],
    }) == "Income"
    assert adapter._transaction_category({
        "credit_debit_indicator": "DBIT",
        "category": "Income",
        "creditor": {"name": "Salary correction"},
    }) == "Uncategorized"


def test_transaction_category_normalizes_provider_labels_direction_and_mcc_padding(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    assert adapter._transaction_category({"category": "Food & Dining"}) == "Dining"
    assert adapter._transaction_category({"category": "Gebühren"}) == "Fees"
    assert adapter._transaction_category({"category": "Überweisung"}) == "Transfers"
    assert adapter._transaction_category({"credit_debit_indicator": "crdt", "category": "Rente"}) == "Income"
    assert adapter._transaction_category({"merchant_category_code": "05411"}) == "Groceries"
    assert adapter._transaction_category({
        "credit_debit_indicator": "DBIT",
        "creditor": {"name": "Uber Eats"},
    }) == "Dining"


def test_refresh_fails_closed_on_aggregate_overflow(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        adapter._checked_add(main.FINANCE_MAX_SAFE_CENTS, 1)


def test_provider_money_rejects_fractional_cents_instead_of_rounding(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    assert adapter._money_to_cents("12.340", "EUR", main.FINANCE_MAX_SAFE_CENTS) == 1234
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        adapter._money_to_cents("12.345", "EUR", main.FINANCE_MAX_SAFE_CENTS)


def test_refresh_follows_bounded_transaction_continuation_pages(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    account_uid = "01234567-89ab-cdef-0123-456789abcdef"
    today = datetime.now(timezone.utc).date().isoformat()
    transaction = {
        "transaction_id": "tx-page",
        "transaction_amount": {"amount": "1.00", "currency": "EUR"},
        "credit_debit_indicator": "DBIT",
        "creditor": {"name": "REWE"},
        "booking_date": today,
    }
    holder = QueueClient([
        FakeResponse({"status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"}, "accounts": [{"uid": account_uid, "name": "Main", "currency": "EUR"}]}),
        FakeResponse({"balances": [{"balance_type": "CLAV", "balance_amount": {"amount": "10.00", "currency": "EUR"}}]}),
        FakeResponse({"continuation_key": "page-2", "transactions": [transaction]}),
        FakeResponse({"transactions": [transaction]}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    summary = run(adapter.refresh_summary())

    assert len(summary["transactions"]["transactions"]) == 1
    transaction_calls = [call for call in holder.calls if call[1].endswith("/transactions")]
    assert transaction_calls[0][2]["params"]["date_from"] == transaction_calls[1][2]["params"]["date_from"]
    assert transaction_calls[0][2]["params"]["date_to"] == transaction_calls[1][2]["params"]["date_to"]
    assert transaction_calls[1][2]["params"]["continuation_key"] == "page-2"


def test_duplicate_accounts_are_collapsed_but_conflicts_fail_closed(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    row = {
        "availability": "observed",
        "id": "ebacct-duplicate",
        "name": "revolut_personal · Main",
        "detail": "EUR · Enable Banking",
        "balanceCents": 1000,
        "source": "enablebanking:revolut_personal",
        "provenance": {"source": "enablebanking:revolut_personal", "observedAt": "2026-08-26T00:00:00Z", "freshness": "fresh", "quality": "observed", "connectorState": "healthy"},
    }
    assert adapter._deduplicate_accounts([row, dict(row)]) == [row]
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        adapter._deduplicate_accounts([row, dict(row, balanceCents=2000)])


def test_refresh_rejects_repeated_transaction_continuation_key(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    account_uid = "01234567-89ab-cdef-0123-456789abcdef"
    holder = QueueClient([
        FakeResponse({"status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"}, "accounts": [{"uid": account_uid, "name": "Main", "currency": "EUR"}]}),
        FakeResponse({"balances": [{"balance_type": "CLAV", "balance_amount": {"amount": "10.00", "currency": "EUR"}}]}),
        FakeResponse({"continuation_key": "same", "transactions": []}),
        FakeResponse({"continuation_key": "same", "transactions": []}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())


def test_refresh_fails_closed_on_malformed_transaction_row(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "eb-flow",
        "institutionId": "revolut_personal",
        "sessionId": "session-1",
        "linkedAt": "2026-01-01T00:00:00Z",
    })
    account_uid = "01234567-89ab-cdef-0123-456789abcdef"
    holder = QueueClient([
        FakeResponse({"status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"}, "accounts": [{"uid": account_uid, "name": "Main", "currency": "EUR"}]}),
        FakeResponse({"balances": [{"balance_type": "CLAV", "balance_amount": {"amount": "10.00", "currency": "EUR"}}]}),
        FakeResponse({"transactions": [{"transaction_id": "missing-amount"}]}),
    ])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())


def test_duplicate_provider_rows_are_collapsed_but_conflicts_fail_closed(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    row = {
        "id": "ebtx-duplicate",
        "merchant": "REWE",
        "title": "REWE",
        "signedAmountCents": -1234,
        "timestamp": "2026-08-26T00:00:00Z",
        "account": "revolut_personal · Main",
        "source": "enablebanking:revolut_personal",
        "category": "Groceries",
        "provenance": {"source": "enablebanking:revolut_personal", "observedAt": "2026-08-26T00:00:00Z", "freshness": "fresh", "quality": "observed", "connectorState": "healthy"},
    }
    assert adapter._deduplicate_transactions([row, dict(row)]) == [row]
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        adapter._deduplicate_transactions([row, dict(row, signedAmountCents=-999)])


def test_transaction_response_uses_larger_but_bounded_payload_limit(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    large_transaction = {
        "transaction_id": "tx-large",
        "transaction_amount": {"amount": "1.00", "currency": "EUR"},
        "credit_debit_indicator": "DBIT",
        "creditor": {"name": "Merchant"},
        "booking_date": "2026-08-24",
        "remittance_information": ["x" * 70_000],
    }
    holder = QueueClient([FakeResponse({"transactions": [large_transaction]})])
    monkeypatch.setattr(enablebanking.httpx, "AsyncClient", lambda **_: holder)

    payload = run(adapter._get_account_json(
        holder,
        {"api_base_url": "https://api.enablebanking.com"},
        "test-token",
        "01234567-89ab-cdef-0123-456789abcdef",
        "transactions",
    ))

    assert len(json.dumps(payload)) > adapter.MAX_RESPONSE_SIZE
    assert adapter.MAX_TRANSACTION_RESPONSE_SIZE == 1 * 1024 * 1024


def test_jwt_builder_uses_required_rs256_claims(tmp_path, monkeypatch):
    import jwt
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    adapter = service(tmp_path, monkeypatch)
    monkeypatch.setattr(
        adapter,
        "_build_jwt",
        enablebanking.EnableBankingService._build_jwt.__get__(adapter),
    )
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.PKCS8,
        encryption_algorithm=serialization.NoEncryption(),
    )

    token = adapter._build_jwt("test-app-id", private_pem)
    header = jwt.get_unverified_header(token)
    claims = jwt.decode(
        token,
        private_key.public_key(),
        algorithms=["RS256"],
        audience="api.enablebanking.com",
        issuer="enablebanking.com",
    )

    assert header == {"alg": "RS256", "kid": "test-app-id", "typ": "JWT"}
    assert claims["exp"] - claims["iat"] == adapter.JWT_TTL_SECONDS


# Runtime reliability fixtures exercise provider-shaped input; never production data.
def reliability_adapter(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    adapter._save_connection({"connectionId": "runtime-flow", "institutionId": "revolut_personal",
                              "sessionId": "runtime-session", "linkedAt": "2026-01-01T00:00:00Z"})
    return adapter


def reliability_responses(*, second_account=False):
    accounts = [{"uid": "01234567-89ab-cdef-0123-456789abcdef", "name": "Main", "currency": "EUR"}]
    if second_account:
        accounts.append({"uid": "11234567-89ab-cdef-0123-456789abcdef", "name": "Second", "currency": "EUR"})
    return [FakeResponse({"status": "AUTHORIZED", "access": {"valid_until": "2099-01-01T00:00:00Z"}, "accounts": accounts}),
            FakeResponse({"balances": [{"balance_amount": {"amount": "10.00", "currency": "EUR"}}]}),
            FakeResponse({"transactions": []})]


def test_runtime_coalesces_and_shields_cancelled_waiter(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses())
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    original = adapter._fetch_connection
    async def scenario():
        entered, release = asyncio.Event(), asyncio.Event()
        async def blocked(*args, **kwargs):
            entered.set()
            await release.wait()
            return await original(*args, **kwargs)
        monkeypatch.setattr(adapter, "_fetch_connection", blocked)
        first = asyncio.create_task(adapter.refresh_summary())
        await entered.wait()
        second = asyncio.create_task(adapter.refresh_summary())
        await asyncio.sleep(0)
        first.cancel()
        with pytest.raises(asyncio.CancelledError):
            await first
        release.set()
        result = await second
        assert result["accounts"]["accounts"][0]["balanceCents"] == 1000
    run(scenario())
    assert len(holder.calls) == 3
    assert adapter.runtime_status()["lastSuccess"] is not None
    assert adapter.runtime_status()["completedAccounts"] == 1


@pytest.mark.parametrize("failure,reason", [
    (httpx.ConnectError("sensitive provider text"), "transport"),
    (FakeResponse({}, 401), "auth"),
    (FakeResponse(b'{bad-json'), "malformed"),
    (FakeResponse({"status": "EXPIRED"}), "consent"),
    (FakeResponse({}, 404), "consent"),
])
def test_runtime_failure_preserves_commit_and_retry(tmp_path, monkeypatch, failure, reason):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses() + [failure] + reliability_responses())
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    first = run(adapter.refresh_summary())
    before = adapter._summary_state_path().read_bytes()
    with pytest.raises(enablebanking.EnableBankingUnavailable) as error:
        run(adapter.refresh_summary())
    assert error.value.reason == reason
    assert adapter._summary_state_path().read_bytes() == before
    status = adapter.runtime_status()
    assert status["lastSuccess"] == first["generatedAt"]
    assert status["lastFailure"] is not None
    assert status["failure"] == reason
    assert "sensitive" not in adapter._runtime_path().read_text()
    restarted = service(tmp_path, monkeypatch)
    assert (restarted.load_cached_summary() is None) == (reason == "consent")
    last_failure = status["lastFailure"]
    result = run(adapter.refresh_summary())
    assert adapter.runtime_status()["lastFailure"] == last_failure
    assert adapter.runtime_status()["failure"] is None
    assert adapter.load_cached_summary() == result
    assert len(result["accounts"]["accounts"]) == 1


def test_runtime_partial_account_failure_does_not_publish_subset(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses() + reliability_responses(second_account=True)
                         + [FakeResponse({"balances": "malformed"})])
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    first = run(adapter.refresh_summary())
    before = adapter._summary_state_path().read_bytes()
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())
    assert adapter._summary_state_path().read_bytes() == before
    assert adapter.runtime_status()["partial"] is True
    assert adapter.runtime_status()["completedAccounts"] == 1
    assert adapter.load_cached_summary() == first


def test_runtime_revocation_during_fetch_wins(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses())
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    original = adapter._fetch_connection
    async def revoke_during_fetch(*args, **kwargs):
        result = await original(*args, **kwargs)
        adapter._atomic_write_json(adapter._connections_path(), {"connections": []})
        return result
    monkeypatch.setattr(adapter, "_fetch_connection", revoke_during_fetch)
    with pytest.raises(enablebanking.EnableBankingUnavailable) as error:
        run(adapter.refresh_summary())
    assert error.value.reason == "consent"
    assert not adapter._summary_state_path().exists()
    assert service(tmp_path, monkeypatch).load_cached_summary() is None


def test_runtime_persisted_expiry_blocks_cache_without_provider(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses())
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    run(adapter.refresh_summary())
    status = adapter.runtime_status()
    status["consentExpiresAt"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
    adapter._atomic_write_json(adapter._runtime_path(), status)
    assert service(tmp_path, monkeypatch).load_cached_summary() is None


def test_runtime_route_reports_failure_with_cached_observation(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses() + [FakeResponse({}, 503)])
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    run(adapter.refresh_summary())
    monkeypatch.setattr(main, "enable_banking", adapter)
    response = run(main.get_finance_summary())
    assert response.status_code == 200
    assert response.headers["X-LifeOS-Banking-State"] == "transport"
    assert response.headers["X-LifeOS-Banking-Last-Success"]
    assert response.headers["X-LifeOS-Banking-Last-Failure"]
    assert adapter.runtime_status()["providers"] == {"revolut_personal": "transport"}


def test_runtime_expired_provider_access_never_commits(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    responses = reliability_responses()
    payload = json.loads(responses[0].body)
    payload["access"] = {"valid_until": "2020-01-01T00:00:00Z"}
    holder = QueueClient([FakeResponse(payload)])
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    with pytest.raises(enablebanking.EnableBankingUnavailable) as error:
        run(adapter.refresh_summary())
    assert error.value.reason == "consent"
    assert not adapter._summary_state_path().exists()


def test_runtime_success_survives_projection_write_failure(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses())
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    original = adapter._atomic_write_json
    def fail_projection(path, payload):
        if path in {adapter._runtime_path(), adapter._summary_path(), adapter._summary_metadata_path()}:
            raise OSError("projection unavailable")
        original(path, payload)
    monkeypatch.setattr(adapter, "_atomic_write_json", fail_projection)
    summary = run(adapter.refresh_summary())
    restarted = service(tmp_path, monkeypatch)
    assert restarted.runtime_status()["lastSuccess"] == summary["generatedAt"]
    assert restarted.load_cached_summary() == summary


@pytest.mark.parametrize("provider_state", ["EXPIRED", "REVOKED", "CLOSED", "LOCAL_EXPIRY"])
@pytest.mark.parametrize("late_failure", [False, True])
def test_status_consent_wins_inflight_refresh_commit_and_failure(
    tmp_path, monkeypatch, provider_state, late_failure,
):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses() + reliability_responses())
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    run(adapter.refresh_summary())
    before = adapter._summary_state_path().read_bytes()
    original = adapter._fetch_connection

    async def scenario():
        entered, release = asyncio.Event(), asyncio.Event()

        async def delayed(*args, **kwargs):
            result = await original(*args, **kwargs)
            entered.set()
            await release.wait()
            if late_failure:
                raise httpx.ConnectError("sensitive provider text")
            return result

        monkeypatch.setattr(adapter, "_fetch_connection", delayed)
        refresh = asyncio.create_task(adapter.refresh_summary())
        await entered.wait()

        async def terminal_session(*args):
            return {"status": provider_state}

        monkeypatch.setattr(adapter, "_get_session", terminal_session)
        if provider_state == "LOCAL_EXPIRY":
            status = adapter.runtime_status()
            status["consentExpiresAt"] = (datetime.now(timezone.utc) - timedelta(seconds=1)).isoformat()
            adapter._atomic_write_json(adapter._runtime_path(), status)
            assert adapter.load_cached_summary() is None
        else:
            assert await adapter.status("runtime-flow") == {
                "state": "expired" if provider_state == "EXPIRED" else "revoked",
            }
        release.set()
        with pytest.raises(enablebanking.EnableBankingUnavailable) as error:
            await refresh
        assert error.value.reason == "consent"

    run(scenario())
    assert adapter._summary_state_path().read_bytes() == before
    assert adapter.runtime_status()["blocked"] is True
    assert adapter.runtime_status()["failure"] == "consent"
    assert adapter.load_cached_summary() is None
    assert service(tmp_path, monkeypatch).load_cached_summary() is None
    assert not adapter._partial_path().exists()
    assert "sensitive" not in adapter._runtime_path().read_text()


@pytest.mark.parametrize("failure_first", [False, True])
def test_partial_observations_preserve_complete_accounts_across_provider_failure(
    tmp_path, monkeypatch, failure_first,
):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    adapter._save_connection({
        "connectionId": "sparkasse-flow", "institutionId": "sparkasse_leipzig",
        "sessionId": "sparkasse-session", "linkedAt": "2026-01-01T00:00:00Z",
    })
    responses = [FakeResponse({}, 503)]
    responses = responses + reliability_responses() if failure_first else reliability_responses() + responses
    monkeypatch.setattr(adapter, "_http_client", lambda: QueueClient(responses))
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())
    partial = json.loads(adapter._partial_path().read_text())
    assert partial["partial"] is True
    assert partial["failure"] == "transport"
    assert len(partial["observations"]) == 1
    assert partial["observations"][0]["account"]["balanceCents"] == 1000
    assert partial["observations"][0]["transactions"] == []
    assert set(partial["providers"].values()) == {"observed", "transport"}
    assert adapter.load_cached_summary() is None
    assert not adapter._summary_state_path().exists()


def test_partial_page_failure_keeps_balance_but_never_a_page_prefix(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    initial = reliability_responses()
    refresh = reliability_responses(second_account=True)
    page = {
        "transaction_id": "page-one", "transaction_amount": {"amount": "1.00", "currency": "EUR"},
        "credit_debit_indicator": "DBIT", "booking_date": datetime.now(timezone.utc).date().isoformat(),
        "creditor": {"name": "REWE"},
    }
    responses = initial + refresh[:2] + [
        FakeResponse({"transactions": [page], "continuation_key": "next"}),
        httpx.ConnectError("sensitive provider text"),
        refresh[1], refresh[2],
    ]
    holder = QueueClient(responses)
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    first = run(adapter.refresh_summary())
    before = adapter._summary_state_path().read_bytes()
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        run(adapter.refresh_summary())
    partial = json.loads(adapter._partial_path().read_text())
    assert len(partial["observations"]) == 2
    failed, complete = partial["observations"]
    assert failed["account"]["balanceCents"] == 1000
    assert failed["transactions"] is None
    assert failed["failure"] == "transport"
    assert complete["transactions"] == []
    assert complete["failure"] is None
    assert adapter.runtime_status()["completedAccounts"] == 1
    assert adapter._summary_state_path().read_bytes() == before
    assert service(tmp_path, monkeypatch).load_cached_summary() == first
    assert "sensitive" not in adapter._partial_path().read_text()
    assert "page-one" not in adapter._partial_path().read_text()
    assert not holder.responses


def test_partial_route_reports_coverage_and_retry_removes_journal(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(
        reliability_responses() + reliability_responses(second_account=True)
        + [FakeResponse({}, 503)] + reliability_responses()
    )
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    monkeypatch.setattr(main, "enable_banking", adapter)
    first = run(adapter.refresh_summary())
    revision = adapter.summary_revision()
    response = run(main.get_finance_summary())
    assert response.status_code == 200
    assert json.loads(response.body) == first
    assert response.headers["X-LifeOS-Banking-State"] == "transport"
    assert response.headers["X-LifeOS-Banking-Partial"] == "true"
    assert adapter.summary_revision() == revision
    assert len(json.loads(adapter._partial_path().read_text())["observations"]) == 1
    response = run(main.get_finance_summary())
    assert response.status_code == 200
    assert response.headers["X-LifeOS-Banking-State"] == "healthy"
    assert response.headers["X-LifeOS-Banking-Partial"] == "false"
    assert not adapter._partial_path().exists()


def test_partial_journal_uses_summary_validation_and_records_rejection(tmp_path, monkeypatch):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    holder = QueueClient(reliability_responses(second_account=True) + [FakeResponse({}, 503)])
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    validated = []

    def reject(payload):
        validated.append(payload)
        return False

    monkeypatch.setattr(adapter, "_validate_finance_payload", reject)
    with pytest.raises(enablebanking.EnableBankingUnavailable) as error:
        run(adapter.refresh_summary())
    assert error.value.reason == "malformed"
    assert len(validated) == 1
    assert validated[0]["monthlyIncome"]["availability"] == "unavailable"
    assert not adapter._partial_path().exists()
    assert adapter.runtime_status()["failure"] == "malformed"

@pytest.mark.parametrize("access", ["missing", None, {}, {"valid_until": None}, {"valid_until": "bad"}, {"valid_until": 123}, {"valid_until": "2099-01-01"}])
def test_unverified_consent_blocks_cache_across_failure_and_restart(tmp_path, monkeypatch, access):
    adapter = reliability_adapter(tmp_path, monkeypatch)
    responses = reliability_responses()
    payload = json.loads(responses[0].body)
    if access == "missing":
        payload.pop("access")
    else:
        payload["access"] = access
    holder = QueueClient(responses + [FakeResponse(payload), httpx.ConnectError("private provider data")])
    monkeypatch.setattr(adapter, "_http_client", lambda: holder)
    run(adapter.refresh_summary())
    before = adapter._summary_state_path().read_bytes()
    for _ in range(2):
        with pytest.raises(enablebanking.EnableBankingUnavailable) as error:
            run(adapter.refresh_summary())
        assert error.value.reason == "consent"
        assert adapter.load_cached_summary() is None
        assert service(tmp_path, monkeypatch).load_cached_summary() is None
        assert adapter._summary_state_path().read_bytes() == before
    assert len(holder.calls) == 5
    assert not adapter._partial_path().exists()


def test_cache_requires_recorded_consent_expiry(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    write_cached_summary(adapter, fixture_finance_summary(["revolut_personal"]))
    status = adapter.runtime_status()
    for expiry in [None, "bad", "2099-01-01"]:
        adapter._atomic_write_json(adapter._runtime_path(), {**status, "consentExpiresAt": expiry})
        assert adapter.load_cached_summary() is None


@pytest.mark.parametrize("kind", ["symlink", "directory", "empty", "oversized", "permissions", "fifo"])
def test_private_key_fails_closed(tmp_path, monkeypatch, kind):
    adapter = service(tmp_path, monkeypatch)
    path = tmp_path / "unsafe-key"
    if kind == "symlink":
        path.symlink_to(tmp_path / "private.key")
    elif kind == "directory":
        path.mkdir()
    elif kind == "fifo":
        if os.name != "posix":
            pytest.skip("POSIX FIFO")
        os.mkfifo(path, 0o600)
    else:
        path.write_bytes(b"" if kind == "empty" else b"x" * (adapter.SECRET_FILE_MAX_BYTES + 1 if kind == "oversized" else 32))
        path.chmod(0o644 if kind == "permissions" else 0o600)
        if kind == "permissions" and os.name != "posix":
            pytest.skip("Windows ACLs are enforced by provisioning, not mode bits")
    with pytest.raises(enablebanking.EnableBankingUnavailable, match="private key unusable"):
        adapter._read_private_key(str(path))
    assert adapter._read_private_key(str(tmp_path / "private.key")) == b"test-private-key"

@pytest.mark.parametrize("replacement", ["regular", "symlink"])
def test_private_key_rejects_path_swap_before_open(tmp_path, monkeypatch, replacement):
    adapter = service(tmp_path, monkeypatch)
    path = tmp_path / "private.key"
    alternate = tmp_path / "alternate"
    alternate.write_bytes(b"replacement-private-key")
    alternate.chmod(0o600)
    real_open = os.open
    def swapped_open(name, flags, *args, **kwargs):
        path.unlink()
        if replacement == "symlink":
            path.symlink_to(alternate)
        else:
            alternate.rename(path)
        return real_open(name, flags, *args, **kwargs)
    monkeypatch.setattr(enablebanking.os, "open", swapped_open)
    with pytest.raises(enablebanking.EnableBankingUnavailable, match="private key unusable"):
        adapter._read_private_key(str(path))
