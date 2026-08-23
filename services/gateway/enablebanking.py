"""Bounded Enable Banking AIS adapter for the LifeOS gateway.

This module owns provider-specific authorization and normalization.  It is
deliberately kept outside the FastAPI route file so the gateway's identity
middleware and provider-neutral finance validator remain the integration
boundary.  Only opaque connection metadata and normalized observations are
written to disk; credentials, authorization codes, and provider payloads are
never persisted or returned to the client.
"""

from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qsl, urlsplit

import httpx


class EnableBankingUnavailable(Exception):
    """The provider was unavailable or returned data that failed validation."""


class UnknownInstitution(Exception):
    """The requested catalog institution was not found in provider discovery."""


@dataclass(frozen=True)
class CallbackResult:
    """Sanitized callback outcome consumed by the FastAPI route."""

    valid: bool
    linked: bool = False


class EnableBankingService:
    """Single-process Enable Banking AIS lifecycle with fail-closed mapping."""

    BODY_LIMIT = 4 * 1024
    MAX_RESPONSE_SIZE = 64 * 1024
    MAX_ASPSP_RESPONSE_SIZE = 4 * 1024 * 1024
    REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
    TOTAL_TIMEOUT = 8.0
    FLOW_TTL_SECONDS = 60 * 60
    MAX_FLOWS = 32
    JWT_TTL_SECONDS = 300
    JWT_CACHE_MARGIN_SECONDS = 60
    SECRET_FILE_MAX_BYTES = 64 * 1024
    ACCESS_VALIDITY_SECONDS = 90 * 24 * 60 * 60
    CONNECTION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,127}$")
    PROVIDER_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,127}$")
    INSTITUTION_ID_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._\-]{0,127}$")
    ACTIVE_STATES = frozenset({"created", "link_opened"})
    SESSION_STATUS_MAP = {
        "AUTHORIZED": "linked",
        "EXPIRED": "expired",
        "CANCELLED": "error",
        "CLOSED": "error",
        "INVALID": "error",
        "REVOKED": "error",
        "PENDING_AUTHORIZATION": "link_opened",
        "RETURNED_FROM_BANK": "link_opened",
    }
    INSTITUTION_CATALOG = {
        "sparkasse_leipzig": (("DE", "Stadt- und Kreissparkasse Leipzig"),),
        "revolut_personal": (("LT", "Revolut"), ("GB", "Revolut")),
    }
    SENSITIVE_PROVIDER_TEXT = re.compile(
        r"(?:bearer\s+\S+|-----BEGIN\s+[^-]*PRIVATE KEY-----|"
        r"[A-Z]{2}\d{2}[A-Z0-9]{10,34}|(?<!\d)\d{8,}(?!\d))",
        re.IGNORECASE,
    )

    def __init__(
        self,
        *,
        data_dir: Callable[[], Path],
        validate_finance_payload: Callable[[dict], bool],
        max_safe_cents: int,
    ) -> None:
        self._data_dir = data_dir
        self._validate_finance_payload = validate_finance_payload
        self._max_safe_cents = max_safe_cents
        self.consent_lock = asyncio.Lock()
        self.connections_lock = asyncio.Lock()
        self.consent_flows: dict[str, dict] = {}
        self._jwt_cache: dict[str, object] = {
            "app_id": None,
            "token": None,
            "expires_at": 0.0,
        }

    @staticmethod
    def _safe_https_url(value: object) -> bool:
        if not isinstance(value, str) or not value or len(value) > 2048:
            return False
        try:
            parsed = urlsplit(value)
        except ValueError:
            return False
        return (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and not parsed.query
            and not parsed.fragment
            and not any(ord(char) < 0x21 or ord(char) == 0x7F for char in value)
        )

    @classmethod
    def _safe_consent_url(cls, value: object) -> bool:
        if not isinstance(value, str) or not value or len(value) > 2048:
            return False
        try:
            parsed = urlsplit(value)
        except ValueError:
            return False
        return (
            parsed.scheme == "https"
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and not parsed.fragment
            and not any(ord(char) < 0x21 or ord(char) == 0x7F for char in value)
        )

    @classmethod
    def _credentials(cls) -> dict | None:
        names = (
            "ENABLE_BANKING_APP_ID",
            "ENABLE_BANKING_PRIVATE_KEY_PATH",
            "ENABLE_BANKING_CERTIFICATE_PATH",
            "ENABLE_BANKING_API_BASE_URL",
            "ENABLE_BANKING_REDIRECT_URI",
        )
        values = {name: os.environ.get(name) for name in names}
        if not all(isinstance(value, str) and value.strip() for value in values.values()):
            return None
        if not cls._safe_https_url(values["ENABLE_BANKING_API_BASE_URL"]):
            return None
        if not cls._safe_https_url(values["ENABLE_BANKING_REDIRECT_URI"]):
            return None
        try:
            for name in ("ENABLE_BANKING_PRIVATE_KEY_PATH", "ENABLE_BANKING_CERTIFICATE_PATH"):
                path = Path(values[name])
                if not path.is_file() or path.is_symlink() or path.stat().st_size > cls.SECRET_FILE_MAX_BYTES:
                    return None
        except (OSError, ValueError):
            return None
        return {
            "app_id": values["ENABLE_BANKING_APP_ID"],
            "private_key_path": values["ENABLE_BANKING_PRIVATE_KEY_PATH"],
            "certificate_path": values["ENABLE_BANKING_CERTIFICATE_PATH"],
            "api_base_url": values["ENABLE_BANKING_API_BASE_URL"].rstrip("/"),
            "redirect_uri": values["ENABLE_BANKING_REDIRECT_URI"],
        }

    @staticmethod
    def _recognized_institutions() -> set[str] | None:
        raw = os.environ.get("LIFEOS_FINANCE_INSTITUTIONS")
        if raw is None or not raw.strip():
            return None
        return {item.strip() for item in raw.split(",") if item.strip()}

    @staticmethod
    def _read_bounded_json_file(path: Path, maximum_bytes: int) -> object | None:
        try:
            if not path.is_file() or path.is_symlink() or path.stat().st_size > maximum_bytes:
                return None
            return json.loads(
                path.read_text(encoding="utf-8"),
                object_pairs_hook=EnableBankingService._reject_duplicate_keys,
                parse_constant=EnableBankingService._reject_nonfinite_constant,
            )
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
            return None

    def _atomic_write_json(self, path: Path, payload: object) -> None:
        directory = self._data_dir()
        directory.mkdir(parents=True, exist_ok=True)
        temporary = directory / f".{path.name}.{secrets.token_hex(8)}.tmp"
        try:
            temporary.write_text(
                json.dumps(payload, separators=(",", ":"), sort_keys=True),
                encoding="utf-8",
            )
            os.replace(temporary, path)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def _connections_path(self) -> Path:
        return self._data_dir() / "enablebanking-connections.json"

    def _summary_path(self) -> Path:
        return self._data_dir() / "finance-summary.json"

    def _load_connections(self) -> list[dict]:
        raw = self._read_bounded_json_file(self._connections_path(), 256 * 1024)
        if not isinstance(raw, dict) or set(raw) != {"connections"} or not isinstance(raw["connections"], list):
            return []
        result: list[dict] = []
        for value in raw["connections"]:
            if not isinstance(value, dict) or set(value) != {
                "connectionId", "institutionId", "sessionId", "linkedAt"
            }:
                continue
            if not all(isinstance(value[field], str) and value[field] for field in value):
                continue
            if not self.CONNECTION_ID_PATTERN.fullmatch(value["connectionId"]):
                continue
            if not self.INSTITUTION_ID_PATTERN.fullmatch(value["institutionId"]):
                continue
            if not self.PROVIDER_ID_PATTERN.fullmatch(value["sessionId"]):
                continue
            result.append(value)
        return result

    def _save_connection(self, connection: dict) -> None:
        existing = [
            value for value in self._load_connections()
            if value["connectionId"] != connection["connectionId"]
        ]
        existing.append(connection)
        self._atomic_write_json(self._connections_path(), {"connections": existing[-32:]})

    def load_cached_summary(self) -> dict | None:
        value = self._read_bounded_json_file(self._summary_path(), 4 * 1024 * 1024)
        return value if isinstance(value, dict) and self._validate_finance_payload(value) else None

    def _http_client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            timeout=self.REQUEST_TIMEOUT,
            follow_redirects=False,
            trust_env=False,
        )

    @classmethod
    async def _read_upstream_json(
        cls,
        upstream,
        *,
        expected_statuses: set[int],
        maximum_bytes: int,
    ) -> object:
        if upstream.status_code not in expected_statuses:
            raise EnableBankingUnavailable("unexpected provider status")
        declared = upstream.headers.get("content-length")
        if declared is not None:
            try:
                if int(declared) < 0 or int(declared) > maximum_bytes:
                    raise EnableBankingUnavailable("provider response too large")
            except (TypeError, ValueError) as exc:
                raise EnableBankingUnavailable("invalid provider content length") from exc
        body = bytearray()
        async for chunk in upstream.aiter_bytes():
            if len(body) + len(chunk) > maximum_bytes:
                raise EnableBankingUnavailable("provider response too large")
            body.extend(chunk)
        try:
            return json.loads(
                bytes(body).decode("utf-8"),
                object_pairs_hook=EnableBankingService._reject_duplicate_keys,
                parse_constant=EnableBankingService._reject_nonfinite_constant,
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise EnableBankingUnavailable("invalid provider json") from exc

    @staticmethod
    def _reject_duplicate_keys(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate provider json key")
            result[key] = value
        return result

    @staticmethod
    def _reject_nonfinite_constant(value):
        raise ValueError("non-finite provider json number")

    def _read_private_key(self, path: str) -> bytes:
        try:
            with open(path, "rb") as handle:
                value = handle.read(self.SECRET_FILE_MAX_BYTES + 1)
        except OSError as exc:
            raise EnableBankingUnavailable("private key unreadable") from exc
        if not value or len(value) > self.SECRET_FILE_MAX_BYTES:
            raise EnableBankingUnavailable("private key unusable")
        return value

    def _build_jwt(self, app_id: str, private_key: bytes) -> str:
        try:
            import jwt
        except ImportError as exc:
            raise EnableBankingUnavailable("jwt dependency unavailable") from exc
        issued_at = int(time.time())
        try:
            return jwt.encode(
                {
                    "iss": "enablebanking.com",
                    "aud": "api.enablebanking.com",
                    "iat": issued_at,
                    "exp": issued_at + self.JWT_TTL_SECONDS,
                },
                private_key,
                algorithm="RS256",
                headers={"typ": "JWT", "alg": "RS256", "kid": app_id},
            )
        except Exception as exc:
            raise EnableBankingUnavailable("jwt signing failed") from exc

    async def _bearer(self, credentials: dict) -> str:
        now = time.monotonic()
        if (
            self._jwt_cache["token"] is not None
            and self._jwt_cache["app_id"] == credentials["app_id"]
            and now < self._jwt_cache["expires_at"]
        ):
            return str(self._jwt_cache["token"])
        token = self._build_jwt(
            credentials["app_id"],
            self._read_private_key(credentials["private_key_path"]),
        )
        self._jwt_cache = {
            "app_id": credentials["app_id"],
            "token": token,
            "expires_at": now + self.JWT_TTL_SECONDS - self.JWT_CACHE_MARGIN_SECONDS,
        }
        return token

    async def _resolve_aspsp(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        institution_id: str,
    ) -> tuple[str, str]:
        candidates = self.INSTITUTION_CATALOG.get(institution_id, ((None, institution_id),))
        async with asyncio.timeout(self.TOTAL_TIMEOUT):
            for country, name in candidates:
                async with client.stream(
                    "GET",
                    f"{credentials['api_base_url']}/aspsps",
                    params={"country": country} if country else {},
                    headers={"Authorization": f"Bearer {token}"},
                ) as upstream:
                    data = await self._read_upstream_json(
                        upstream,
                        expected_statuses={200},
                        maximum_bytes=self.MAX_ASPSP_RESPONSE_SIZE,
                    )
                entries = data.get("aspsps") if isinstance(data, dict) else None
                if not isinstance(entries, list):
                    raise EnableBankingUnavailable("invalid ASPSP list")
                for entry in entries:
                    if not isinstance(entry, dict):
                        continue
                    entry_name = entry.get("name")
                    entry_country = entry.get("country")
                    if not isinstance(entry_name, str) or not isinstance(entry_country, str):
                        continue
                    if entry_name.casefold() == name.casefold() and (
                        country is None or entry_country.casefold() == country.casefold()
                    ):
                        return entry_country, entry_name
        raise UnknownInstitution(institution_id)

    async def _start_authorization(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        *,
        state: str,
        country: str,
        name: str,
    ) -> tuple[str, str]:
        valid_until = (
            datetime.now(timezone.utc) + timedelta(seconds=self.ACCESS_VALIDITY_SECONDS)
        ).strftime("%Y-%m-%dT%H:%M:%SZ")
        body = json.dumps(
            {
                "access": {"valid_until": valid_until, "balances": True, "transactions": True},
                "aspsp": {"name": name, "country": country},
                "state": state,
                "redirect_url": credentials["redirect_uri"],
            },
            separators=(",", ":"),
        ).encode("utf-8")
        async with asyncio.timeout(self.TOTAL_TIMEOUT):
            async with client.stream(
                "POST",
                f"{credentials['api_base_url']}/auth",
                content=body,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
            ) as upstream:
                data = await self._read_upstream_json(
                    upstream,
                    expected_statuses={200},
                    maximum_bytes=self.MAX_RESPONSE_SIZE,
                )
        consent_url = data.get("url") if isinstance(data, dict) else None
        authorization_id = data.get("authorization_id") if isinstance(data, dict) else None
        if not self._safe_consent_url(consent_url):
            raise EnableBankingUnavailable("unsafe consent URL")
        if not isinstance(authorization_id, str) or not self.PROVIDER_ID_PATTERN.fullmatch(authorization_id):
            raise EnableBankingUnavailable("invalid authorization id")
        return consent_url, authorization_id

    async def _exchange_code(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        code: str,
    ) -> dict:
        body = json.dumps({"code": code}, separators=(",", ":")).encode("utf-8")
        async with asyncio.timeout(self.TOTAL_TIMEOUT):
            async with client.stream(
                "POST",
                f"{credentials['api_base_url']}/sessions",
                content=body,
                headers={
                    "Authorization": f"Bearer {token}",
                    "Content-Type": "application/json",
                },
            ) as upstream:
                data = await self._read_upstream_json(
                    upstream,
                    expected_statuses={200},
                    maximum_bytes=self.MAX_RESPONSE_SIZE,
                )
        session_id = data.get("session_id") if isinstance(data, dict) else None
        if not isinstance(session_id, str) or not self.PROVIDER_ID_PATTERN.fullmatch(session_id):
            raise EnableBankingUnavailable("missing provider session id")
        accounts = data.get("accounts") if isinstance(data, dict) else None
        if accounts is not None and not isinstance(accounts, list):
            raise EnableBankingUnavailable("invalid session accounts")
        return data

    async def _get_session(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        session_id: str,
    ) -> dict:
        if not self.PROVIDER_ID_PATTERN.fullmatch(session_id):
            raise EnableBankingUnavailable("invalid provider session id")
        async with asyncio.timeout(self.TOTAL_TIMEOUT):
            async with client.stream(
                "GET",
                f"{credentials['api_base_url']}/sessions/{session_id}",
                headers={"Authorization": f"Bearer {token}"},
            ) as upstream:
                if upstream.status_code == 404:
                    raise EnableBankingUnavailable("provider session not found")
                data = await self._read_upstream_json(
                    upstream,
                    expected_statuses={200},
                    maximum_bytes=self.MAX_RESPONSE_SIZE,
                )
        if not isinstance(data, dict):
            raise EnableBankingUnavailable("invalid provider session")
        return data

    async def _get_account_json(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        account_uid: str,
        endpoint: str,
        *,
        params: dict | None = None,
    ) -> dict:
        if not re.fullmatch(r"[0-9a-fA-F-]{16,128}", account_uid):
            raise EnableBankingUnavailable("invalid provider account id")
        async with asyncio.timeout(self.TOTAL_TIMEOUT):
            async with client.stream(
                "GET",
                f"{credentials['api_base_url']}/accounts/{account_uid}/{endpoint}",
                params=params or {},
                headers={"Authorization": f"Bearer {token}"},
            ) as upstream:
                data = await self._read_upstream_json(
                    upstream,
                    expected_statuses={200},
                    maximum_bytes=self.MAX_RESPONSE_SIZE,
                )
        if not isinstance(data, dict):
            raise EnableBankingUnavailable("invalid provider account response")
        return data

    def _session_state(self, raw: object) -> str:
        return self.SESSION_STATUS_MAP.get(str(raw or "").strip().upper(), "link_opened")

    def _expire_flows(self) -> None:
        now = time.monotonic()
        for flow in self.consent_flows.values():
            if flow["state"] in self.ACTIVE_STATES and now - flow["started"] > self.FLOW_TTL_SECONDS:
                flow["state"] = "expired"

    def _prune_flows(self) -> None:
        terminal = [
            key for key, flow in self.consent_flows.items()
            if flow["state"] not in self.ACTIVE_STATES
        ]
        excess = len(self.consent_flows) - self.MAX_FLOWS
        for key in sorted(terminal, key=lambda item: self.consent_flows[item]["started"])[:max(excess, 0)]:
            del self.consent_flows[key]

    async def start(self, institution_id: str) -> tuple[int, dict]:
        credentials = self._credentials()
        if credentials is None:
            return 503, {"error": "finance_connect_unavailable"}
        if not self.INSTITUTION_ID_PATTERN.fullmatch(institution_id):
            return 400, {"error": "invalid_request"}
        recognized = self._recognized_institutions()
        if recognized is not None and institution_id not in recognized:
            return 400, {"error": "unknown_institution"}
        async with self.consent_lock:
            self._expire_flows()
            if any(flow["state"] in self.ACTIVE_STATES for flow in self.consent_flows.values()):
                return 409, {"error": "already_linking"}
            try:
                async with self._http_client() as client:
                    token = await self._bearer(credentials)
                    country, name = await self._resolve_aspsp(
                        client, credentials, token, institution_id
                    )
                    state = secrets.token_urlsafe(32)
                    consent_url, authorization_id = await self._start_authorization(
                        client,
                        credentials,
                        token,
                        state=state,
                        country=country,
                        name=name,
                    )
            except UnknownInstitution:
                return 400, {"error": "unknown_institution"}
            except Exception:
                return 503, {"error": "finance_connect_unavailable"}
            connection_id = "eb-" + uuid.uuid4().hex
            self.consent_flows[connection_id] = {
                "state": "created",
                "institutionId": institution_id,
                "started": time.monotonic(),
                "csrf_state": state,
                "authorization_id": authorization_id,
                "session_id": None,
            }
            self._prune_flows()
        return 200, {"consentUrl": consent_url, "connectionId": connection_id}

    async def status(self, connection_id: str) -> dict:
        if not self.CONNECTION_ID_PATTERN.fullmatch(connection_id):
            return {"error": "invalid_request"}
        async with self.consent_lock:
            self._expire_flows()
            flow = self.consent_flows.get(connection_id)
            cached_state = flow["state"] if flow is not None else None
        persisted = next(
            (
                item for item in self._load_connections()
                if item["connectionId"] == connection_id
            ),
            None,
        )
        if flow is None and persisted is not None:
            flow = {"state": "linked", "session_id": persisted["sessionId"]}
            cached_state = "linked"
        if cached_state in {"linked", "expired", "error"} and persisted is None:
            return {"state": cached_state}
        credentials = self._credentials()
        if credentials is None:
            return {"state": cached_state if cached_state is not None else "error"}
        if flow is not None and not flow.get("session_id"):
            return {"state": cached_state}
        session_id = flow["session_id"] if flow is not None else connection_id
        try:
            async with self._http_client() as client:
                state = self._session_state(
                    (
                        await self._get_session(
                            client,
                            credentials,
                            await self._bearer(credentials),
                            session_id,
                        )
                    ).get("status")
                )
        except Exception:
            state = cached_state if cached_state is not None else "error"
        async with self.consent_lock:
            existing = self.consent_flows.get(connection_id)
            if existing is not None:
                existing["state"] = state
                self._prune_flows()
            elif state != "error":
                self.consent_flows[connection_id] = {
                    "state": state,
                    "institutionId": persisted["institutionId"] if persisted else "",
                    "started": time.monotonic(),
                    "csrf_state": None,
                    "authorization_id": connection_id,
                    "session_id": session_id,
                }
        return {"state": state}

    async def callback(self, query: str) -> CallbackResult:
        pairs = parse_qsl(query, keep_blank_values=True)
        values: dict[str, str] = {}
        for key, value in pairs:
            if key not in {"code", "state", "error", "error_description"}:
                return CallbackResult(valid=False)
            if key in values or len(value) > 512:
                return CallbackResult(valid=False)
            values[key] = value
        state = values.get("state", "")
        code = values.get("code", "")
        error = values.get("error", "")
        if not state or len(state) > 512 or bool(error) == bool(code):
            return CallbackResult(valid=False)
        async with self.consent_lock:
            self._expire_flows()
            match = next(
                (
                    connection_id for connection_id, flow in self.consent_flows.items()
                    if flow["state"] in self.ACTIVE_STATES
                    and hmac.compare_digest(str(flow.get("csrf_state") or ""), state)
                ),
                None,
            )
        if match is None:
            return CallbackResult(valid=False)
        credentials = self._credentials()
        if error or credentials is None:
            async with self.consent_lock:
                if self.consent_flows.get(match, {}).get("state") in self.ACTIVE_STATES:
                    self.consent_flows[match]["state"] = "error"
                    self._prune_flows()
            return CallbackResult(valid=True, linked=False)
        try:
            async with self._http_client() as client:
                session_response = await self._exchange_code(
                    client, credentials, await self._bearer(credentials), code
                )
            session_id = session_response["session_id"]
            connection = {
                "connectionId": match,
                "institutionId": self.consent_flows[match]["institutionId"],
                "sessionId": session_id,
                "linkedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            }
            async with self.connections_lock:
                self._save_connection(connection)
        except Exception:
            async with self.consent_lock:
                if self.consent_flows.get(match, {}).get("state") in self.ACTIVE_STATES:
                    self.consent_flows[match]["state"] = "error"
                    self._prune_flows()
            return CallbackResult(valid=True, linked=False)
        async with self.consent_lock:
            flow = self.consent_flows.get(match)
            if flow is not None and flow["state"] in self.ACTIVE_STATES:
                flow["session_id"] = session_id
                flow["state"] = "linked"
                self._prune_flows()
        return CallbackResult(valid=True, linked=True)

    @staticmethod
    def _money_to_cents(amount: object, currency: object, max_safe_cents: int) -> int:
        if currency != "EUR" or not isinstance(amount, str) or len(amount) > 64:
            raise EnableBankingUnavailable("unsupported money value")
        try:
            parsed = Decimal(amount).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        except (InvalidOperation, ValueError):
            raise EnableBankingUnavailable("invalid money value")
        cents = int(parsed * 100)
        if abs(cents) > max_safe_cents:
            raise EnableBankingUnavailable("money value out of range")
        return cents

    @classmethod
    def _provider_text(cls, value: object, maximum: int = 160) -> str | None:
        if not isinstance(value, str):
            return None
        cleaned = " ".join(value.split())
        if not cleaned or len(cleaned) > maximum or cls.SENSITIVE_PROVIDER_TEXT.search(cleaned):
            return None
        return cleaned

    @staticmethod
    def _provider_date(value: object) -> str | None:
        if not isinstance(value, str):
            return None
        try:
            parsed = datetime.strptime(value[:10], "%Y-%m-%d").replace(tzinfo=timezone.utc)
        except ValueError:
            return None
        return parsed.isoformat().replace("+00:00", "Z")

    @staticmethod
    def _transaction_category(transaction: dict) -> str:
        categories = {
            "5411": "Groceries", "5541": "Transport", "5812": "Dining",
            "5814": "Dining", "5912": "Health", "7011": "Travel", "8011": "Health",
        }
        return categories.get(str(transaction.get("merchant_category_code") or ""), "Uncategorized")

    def _normalize_transaction(
        self,
        transaction: object,
        *,
        institution_id: str,
        account_label: str,
        account_uid: str,
        observed_at: str,
    ) -> dict | None:
        if not isinstance(transaction, dict) or not isinstance(transaction.get("transaction_amount"), dict):
            return None
        amount = transaction["transaction_amount"]
        try:
            magnitude = abs(self._money_to_cents(
                amount.get("amount"), amount.get("currency"), self._max_safe_cents
            ))
        except EnableBankingUnavailable:
            return None
        indicator = transaction.get("credit_debit_indicator")
        if indicator == "DBIT":
            signed_amount = -magnitude
            party_key = "creditor"
        elif indicator == "CRDT":
            signed_amount = magnitude
            party_key = "debtor"
        else:
            return None
        party = transaction.get(party_key)
        merchant = self._provider_text(party.get("name") if isinstance(party, dict) else None)
        timestamp = (
            self._provider_date(transaction.get("booking_date"))
            or self._provider_date(transaction.get("value_date"))
            or self._provider_date(transaction.get("transaction_date"))
        )
        if timestamp is None:
            return None
        raw_identity = transaction.get("transaction_id") or transaction.get("entry_reference")
        if not isinstance(raw_identity, str) or not raw_identity:
            raw_identity = json.dumps(transaction, sort_keys=True, separators=(",", ":"))
        stable_id = "ebtx-" + hashlib.sha256(
            f"{institution_id}|{account_uid}|{raw_identity}".encode("utf-8")
        ).hexdigest()[:40]
        source = f"enablebanking:{institution_id}"
        provenance = {
            "source": source,
            "observedAt": observed_at,
            "freshness": "fresh",
            "quality": "observed",
            "connectorState": "healthy",
        }
        return {
            "id": stable_id,
            "merchant": merchant or "Bank transaction",
            "title": merchant or "Bank transaction",
            "signedAmountCents": signed_amount,
            "timestamp": timestamp,
            "account": account_label,
            "source": source,
            "category": self._transaction_category(transaction),
            "provenance": provenance,
        }

    @staticmethod
    def _account_uid(account: object) -> str | None:
        value = account.get("uid") if isinstance(account, dict) else account
        return value if isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F-]{16,128}", value) else None

    async def _fetch_connection(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        connection: dict,
        *,
        observed_at: str,
    ) -> tuple[list[dict], list[dict]]:
        session = await self._get_session(client, credentials, token, connection["sessionId"])
        if str(session.get("status") or "").upper() != "AUTHORIZED":
            raise EnableBankingUnavailable("provider session is not authorized")
        session_accounts = session.get("accounts")
        if not isinstance(session_accounts, list) or not session_accounts:
            raise EnableBankingUnavailable("provider session has no accounts")
        account_rows: list[dict] = []
        transaction_rows: list[dict] = []
        for index, account in enumerate(session_accounts, start=1):
            uid = self._account_uid(account)
            if uid is None:
                continue
            details = account if isinstance(account, dict) else {}
            if not details.get("name") or not details.get("currency"):
                fetched = await self._get_account_json(
                    client, credentials, token, uid, "details"
                )
                if fetched:
                    details = fetched
            currency = details.get("currency")
            if currency != "EUR":
                continue
            account_name = self._provider_text(details.get("name"), maximum=96)
            account_label = f"{connection['institutionId']} · {account_name or f'Account {index}'}"
            balances = await self._get_account_json(
                client, credentials, token, uid, "balances"
            )
            balance_items = balances.get("balances")
            if not isinstance(balance_items, list):
                continue
            preferred = sorted(
                (item for item in balance_items if isinstance(item, dict)),
                key=lambda item: 0 if item.get("balance_type") == "CLAV" else 1,
            )
            balance_cents = None
            for item in preferred:
                amount = item.get("balance_amount")
                if not isinstance(amount, dict):
                    continue
                try:
                    balance_cents = self._money_to_cents(
                        amount.get("amount"), amount.get("currency"), self._max_safe_cents
                    )
                except EnableBankingUnavailable:
                    continue
                break
            if balance_cents is None:
                continue
            source = f"enablebanking:{connection['institutionId']}"
            provenance = {
                "source": source,
                "observedAt": observed_at,
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy",
            }
            account_rows.append({
                "id": "ebacct-" + hashlib.sha256(
                    f"{connection['institutionId']}|{uid}".encode("utf-8")
                ).hexdigest()[:40],
                "name": account_label,
                "detail": "EUR · Enable Banking",
                "balanceCents": balance_cents,
                "source": source,
                "provenance": provenance,
            })
            date_to = datetime.now(timezone.utc).date()
            date_from = date_to - timedelta(days=180)
            transaction_payload = await self._get_account_json(
                client,
                credentials,
                token,
                uid,
                "transactions",
                params={"date_from": date_from.isoformat(), "date_to": date_to.isoformat()},
            )
            transactions = transaction_payload.get("transactions")
            if not isinstance(transactions, list):
                continue
            for transaction in transactions[:500]:
                normalized = self._normalize_transaction(
                    transaction,
                    institution_id=connection["institutionId"],
                    account_label=account_label,
                    account_uid=uid,
                    observed_at=observed_at,
                )
                if normalized is not None:
                    transaction_rows.append(normalized)
        if not account_rows:
            raise EnableBankingUnavailable("no usable EUR account balances")
        return account_rows, transaction_rows

    def _metric(self, amount_cents: int | None, *, source: str, observed_at: str) -> dict:
        if amount_cents is None:
            return {
                "availability": "unavailable",
                "provenance": {
                    "source": source,
                    "observedAt": observed_at,
                    "freshness": "unknown",
                    "quality": "unavailable",
                    "connectorState": "unavailable",
                },
            }
        if amount_cents < 0 or amount_cents > self._max_safe_cents:
            raise EnableBankingUnavailable("metric out of range")
        return {
            "availability": "observed",
            "amountCents": amount_cents,
            "provenance": {
                "source": source,
                "observedAt": observed_at,
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy",
            },
        }

    def _checked_add(self, current: int, value: int) -> int:
        result = current + value
        if abs(result) > self._max_safe_cents:
            raise EnableBankingUnavailable("aggregate overflow")
        return result

    async def refresh_summary(self) -> dict:
        credentials = self._credentials()
        if credentials is None:
            raise EnableBankingUnavailable("missing Enable Banking configuration")
        connections = self._load_connections()
        if not connections:
            raise EnableBankingUnavailable("no linked connections")
        observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
        all_accounts: list[dict] = []
        all_transactions: list[dict] = []
        async with self._http_client() as client:
            token = await self._bearer(credentials)
            for connection in connections:
                accounts, transactions = await self._fetch_connection(
                    client,
                    credentials,
                    token,
                    connection,
                    observed_at=observed_at,
                )
                all_accounts.extend(accounts)
                all_transactions.extend(transactions)
        if not all_accounts:
            raise EnableBankingUnavailable("no linked account data")
        account_sources = {row["source"] for row in all_accounts}
        account_source = (
            next(iter(account_sources))
            if len(account_sources) == 1
            else "derived-account-snapshot"
        )
        transaction_sources = {row["source"] for row in all_transactions}
        transaction_source = (
            next(iter(transaction_sources))
            if len(transaction_sources) == 1
            else "derived-transaction-snapshot"
        )
        current_month = datetime.now(timezone.utc).strftime("%Y-%m")
        monthly_income = 0
        spent = 0
        for transaction in all_transactions:
            if not transaction["timestamp"].startswith(current_month):
                continue
            amount = transaction["signedAmountCents"]
            if amount > 0:
                monthly_income = self._checked_add(monthly_income, amount)
            elif amount < 0:
                spent = self._checked_add(spent, -amount)
        observed_provenance = {
            "source": transaction_source,
            "observedAt": observed_at,
            "freshness": "fresh",
            "quality": "observed",
            "connectorState": "healthy",
        }
        summary = {
            "generatedAt": observed_at,
            "currency": "EUR",
            "monthlyIncome": self._metric(
                monthly_income, source=transaction_source, observed_at=observed_at
            ),
            "fixedCosts": self._metric(
                None, source="no-authorized-finance-source", observed_at=observed_at
            ),
            "discretionaryBuffer": self._metric(
                None, source="no-authorized-finance-source", observed_at=observed_at
            ),
            "spent": self._metric(spent, source=transaction_source, observed_at=observed_at),
            "savingsGoal": self._metric(
                None, source="no-authorized-finance-source", observed_at=observed_at
            ),
            "saved": self._metric(
                None, source="no-authorized-finance-source", observed_at=observed_at
            ),
            "accounts": {
                "availability": "observed",
                "accounts": all_accounts,
                "provenance": {
                    "source": account_source,
                    "observedAt": observed_at,
                    "freshness": "fresh",
                    "quality": "observed",
                    "connectorState": "healthy",
                },
            },
            "transactions": {
                "availability": "observed",
                "transactions": all_transactions,
                "provenance": observed_provenance,
            },
        }
        if not self._validate_finance_payload(summary):
            raise EnableBankingUnavailable("normalized finance payload failed validation")
        self._atomic_write_json(self._summary_path(), summary)
        return summary
