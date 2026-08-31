import asyncio
import copy
import hashlib
import json
import os
import time
from datetime import datetime, timedelta, timezone

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
            "status": "AUTHORIZED",
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
            "status": "AUTHORIZED",
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
            "status": "AUTHORIZED",
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
        FakeResponse({"status": "AUTHORIZED", "accounts": [{"uid": "not-a-provider-account"}]}),
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
            "status": "AUTHORIZED",
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
        FakeResponse({"status": "AUTHORIZED", "accounts": [{"uid": account_uid, "name": "Main", "currency": "EUR"}]}),
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
        FakeResponse({"status": "AUTHORIZED", "accounts": [{"uid": account_uid, "name": "Main", "currency": "EUR"}]}),
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
        FakeResponse({"status": "AUTHORIZED", "accounts": [{"uid": account_uid, "name": "Main", "currency": "EUR"}]}),
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
