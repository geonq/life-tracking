import asyncio
import json
import os
import time
from datetime import datetime, timezone

import pytest
from fastapi.testclient import TestClient

os.environ["LIFEOS_TAILSCALE_ALLOWED_LOGIN"] = "test-user@example.com"

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
        headers={"Tailscale-User-Login": "test-user@example.com"},
        json={"institutionId": "revolut_personal"},
    )

    assert response.status_code == 200
    assert set(response.json()) == {"consentUrl", "connectionId"}
    assert response.headers["cache-control"] == "no-store"


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


def test_refresh_fails_closed_on_aggregate_overflow(tmp_path, monkeypatch):
    adapter = service(tmp_path, monkeypatch)
    with pytest.raises(enablebanking.EnableBankingUnavailable):
        adapter._checked_add(main.FINANCE_MAX_SAFE_CENTS, 1)


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
