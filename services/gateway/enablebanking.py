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
import errno
import hashlib
import hmac
import json
import os
import re
import secrets
import time
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Callable
from urllib.parse import parse_qsl, urlsplit
from zoneinfo import ZoneInfo

import httpx


BUSINESS_TIME_ZONE = ZoneInfo("Europe/Berlin")


class EnableBankingUnavailable(Exception):
    """The provider was unavailable or returned data that failed validation."""


class UnknownInstitution(Exception):
    """The requested catalog institution was not found in provider discovery."""


class ProviderSessionNotFound(EnableBankingUnavailable):
    """The provider no longer has the opaque session."""


@dataclass(frozen=True)
class CallbackResult:
    """Sanitized callback outcome consumed by the FastAPI route."""

    valid: bool
    linked: bool = False


class EnableBankingService:
    """Single-process Enable Banking AIS lifecycle with fail-closed mapping."""

    BODY_LIMIT = 4 * 1024
    MAX_RESPONSE_SIZE = 64 * 1024
    # A normal 180-day transaction page can exceed the small control-response
    # bound while remaining safely bounded. Account details, balances, auth,
    # and session responses continue to use MAX_RESPONSE_SIZE.
    MAX_TRANSACTION_RESPONSE_SIZE = 1 * 1024 * 1024
    # The final normalized envelope must fit the native client's bounded
    # read-only response contract. Provider pages may be larger while being
    # fetched, but the cached/returned snapshot may not be.
    # Finance is a telemetry/control response at the gateway boundary. Keep
    # the provider-neutral envelope within the same 256 KiB cap as Usage,
    # Calendar, Clipper, and Supplement responses.
    MAX_FINANCE_SUMMARY_SIZE = 256 * 1024
    MAX_TRANSACTION_PAGES = 64
    MAX_TRANSACTIONS_PER_ACCOUNT = 5_000
    MAX_ASPSP_RESPONSE_SIZE = 4 * 1024 * 1024
    FINANCE_METADATA_SCHEMA_VERSION = 1
    FINANCE_STATE_SCHEMA_VERSION = 1
    REVOCATION_STATE_SCHEMA_VERSION = 1
    MAX_FINANCE_METADATA_SIZE = 4 * 1024 * 1024
    MAX_FINANCE_STATE_SIZE = 6 * 1024 * 1024
    MAX_REVOCATION_STATE_SIZE = 8 * 1024 * 1024
    MAX_FINANCE_JOURNAL_RECORDS = 10_000
    MAX_FINANCE_REVISION = 9_007_199_254_740_991
    MAX_CALLBACK_QUERY_SIZE = 4 * 1024
    MAX_CALLBACK_FIELDS = 8
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
        "CLOSED": "revoked",
        "INVALID": "error",
        "REVOKED": "revoked",
        "PENDING_AUTHORIZATION": "link_opened",
        "RETURNED_FROM_BANK": "link_opened",
    }
    INSTITUTION_CATALOG = {
        "sparkasse_leipzig": (("DE", "Stadt- und Kreissparkasse Leipzig"),),
        "revolut_personal": (("LT", "Revolut"), ("GB", "Revolut")),
    }
    KNOWN_INSTITUTION_IDS = frozenset(INSTITUTION_CATALOG)
    # This is the only retired record that may be ignored during migration.
    # Unknown or malformed current records fail closed instead of producing a
    # misleading partial Finance snapshot.
    RETIRED_INSTITUTION_IDS = frozenset({"SANDBOXFINANCE_SINST_DE"})
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
        validate_persisted_finance_payload: Callable[[dict], bool] | None = None,
    ) -> None:
        self._data_dir = data_dir
        self._validate_finance_payload = validate_finance_payload
        self._validate_persisted_finance_payload = (
            validate_persisted_finance_payload or validate_finance_payload
        )
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
        descriptor: int | None = None
        try:
            body = json.dumps(
                payload,
                separators=(",", ":"),
                sort_keys=True,
                allow_nan=False,
            ).encode("utf-8")
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                0o600,
            )
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = None
                handle.write(body)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
            if os.name != "nt" and hasattr(os, "O_DIRECTORY"):
                directory_descriptor: int | None = None
                try:
                    directory_descriptor = os.open(
                        directory,
                        os.O_RDONLY | os.O_DIRECTORY,
                    )
                    os.fsync(directory_descriptor)
                except OSError as exc:
                    if exc.errno not in {errno.EINVAL, errno.ENOTSUP, errno.EISDIR}:
                        raise
                finally:
                    if directory_descriptor is not None:
                        os.close(directory_descriptor)
        finally:
            if descriptor is not None:
                os.close(descriptor)
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass

    def _connections_path(self) -> Path:
        return self._data_dir() / "enablebanking-connections.json"

    def _summary_path(self) -> Path:
        return self._data_dir() / "finance-summary.json"

    def _summary_metadata_path(self) -> Path:
        return Path(f"{self._summary_path()}.meta.json")

    def _summary_state_path(self) -> Path:
        return Path(f"{self._summary_path()}.state.json")

    def _revocation_state_path(self) -> Path:
        return self._data_dir() / "enablebanking-revocation.json"

    def _remove_file_durably(self, path: Path) -> None:
        try:
            path.unlink()
        except FileNotFoundError:
            return
        if os.name != "nt" and hasattr(os, "O_DIRECTORY"):
            directory_descriptor: int | None = None
            try:
                directory_descriptor = os.open(self._data_dir(), os.O_RDONLY | os.O_DIRECTORY)
                os.fsync(directory_descriptor)
            except OSError as exc:
                if exc.errno not in {errno.EINVAL, errno.ENOTSUP, errno.EISDIR}:
                    raise
            finally:
                if directory_descriptor is not None:
                    os.close(directory_descriptor)

    @staticmethod
    def _summary_digest(value: object) -> str:
        encoded = json.dumps(
            value,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        ).encode("utf-8")
        return hashlib.sha256(encoded).hexdigest()

    @classmethod
    def _is_safe_revision(cls, value: object) -> bool:
        return (
            isinstance(value, int)
            and not isinstance(value, bool)
            and 0 <= value <= cls.MAX_FINANCE_REVISION
        )

    @classmethod
    def _validate_summary_metadata(cls, value: object) -> dict:
        if not isinstance(value, dict) or set(value) != {
            "schemaVersion", "domain", "authority", "revision",
            "bodyDigest", "idempotency", "tombstones",
        }:
            raise EnableBankingUnavailable("invalid finance metadata")
        if (
            value["schemaVersion"] != cls.FINANCE_METADATA_SCHEMA_VERSION
            or value["domain"] != "finance"
            or value["authority"] != "gateway"
            or not cls._is_safe_revision(value["revision"])
            or not isinstance(value["bodyDigest"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", value["bodyDigest"])
            or not isinstance(value["idempotency"], list)
            or len(value["idempotency"]) > cls.MAX_FINANCE_JOURNAL_RECORDS
            or value["tombstones"] != []
        ):
            raise EnableBankingUnavailable("invalid finance metadata")

        seen_keys: set[str] = set()
        for record in value["idempotency"]:
            if not isinstance(record, dict) or set(record) != {"key", "fingerprint", "revision"}:
                raise EnableBankingUnavailable("invalid finance idempotency record")
            key = record["key"]
            if (
                not isinstance(key, str)
                or not re.fullmatch(r"[\x21-\x7e]{1,128}", key)
                or key in seen_keys
                or not isinstance(record["fingerprint"], str)
                or not re.fullmatch(r"[0-9a-f]{64}", record["fingerprint"])
                or not cls._is_safe_revision(record["revision"])
                or record["revision"] > value["revision"]
            ):
                raise EnableBankingUnavailable("invalid finance idempotency record")
            seen_keys.add(key)
        return value

    def _read_summary_metadata(self) -> dict | None:
        self._recover_pending_revocation()
        path = self._summary_metadata_path()
        try:
            path.lstat()
        except FileNotFoundError:
            return None
        raw = self._read_bounded_json_file(path, self.MAX_FINANCE_METADATA_SIZE)
        if raw is None:
            raise EnableBankingUnavailable("finance metadata unavailable")
        return self._validate_summary_metadata(raw)

    def _read_summary_state(self) -> tuple[dict, dict] | None:
        """Read the single committed Finance summary/metadata envelope."""
        self._recover_pending_revocation()
        path = self._summary_state_path()
        try:
            path.lstat()
        except FileNotFoundError:
            return None
        raw = self._read_bounded_json_file(path, self.MAX_FINANCE_STATE_SIZE)
        if not isinstance(raw, dict) or set(raw) != {
            "schemaVersion", "summary", "metadata",
        } or raw["schemaVersion"] != self.FINANCE_STATE_SCHEMA_VERSION:
            raise EnableBankingUnavailable("finance state unavailable")
        summary = raw["summary"]
        if not isinstance(summary, dict):
            raise EnableBankingUnavailable("finance state summary unavailable")
        metadata = self._validate_summary_metadata(raw["metadata"])
        if self._summary_digest(summary) != metadata["bodyDigest"]:
            raise EnableBankingUnavailable("finance state digest mismatch")
        if not self._validate_persisted_finance_payload(summary):
            raise EnableBankingUnavailable("finance state payload invalid")
        return summary, metadata

    def summary_revision(self) -> int | None:
        """Return the durable Finance revision, or none for legacy/no state."""
        try:
            state = self._read_summary_state()
            if state is not None:
                return int(state[1]["revision"])
            metadata = self._read_summary_metadata()
        except EnableBankingUnavailable:
            return None
        return None if metadata is None else int(metadata["revision"])

    def _next_summary_metadata(self, summary: dict) -> dict:
        digest = self._summary_digest(summary)
        committed = self._read_summary_state()
        previous = committed[1] if committed is not None else self._read_summary_metadata()
        if previous is None:
            revision = 0
            journal: list[dict] = []
        else:
            revision = int(previous["revision"])
            journal = list(previous["idempotency"])

        if previous is None or previous["bodyDigest"] != digest:
            if revision >= self.MAX_FINANCE_REVISION:
                raise EnableBankingUnavailable("finance revision exhausted")
            revision += 1
            key = f"finance-refresh-{digest}"
            journal = [
                *journal,
                {"key": key, "fingerprint": digest, "revision": revision},
            ][-self.MAX_FINANCE_JOURNAL_RECORDS:]
        return {
            "schemaVersion": self.FINANCE_METADATA_SCHEMA_VERSION,
            "domain": "finance",
            "authority": "gateway",
            "revision": revision,
            "bodyDigest": digest,
            "idempotency": journal,
            # Revocation removes the provider-owned rows from the cached
            # projection; no tombstone observation is fabricated for Finance.
            "tombstones": [],
        }

    def _validate_connection_records(self, records: object) -> list[dict]:
        if not isinstance(records, list):
            raise EnableBankingUnavailable("connection store contains a malformed record")
        result: list[dict] = []
        seen_connection_ids: set[str] = set()
        seen_institution_ids: set[str] = set()
        for value in records:
            if not isinstance(value, dict):
                raise EnableBankingUnavailable("connection store contains a malformed record")
            # Explicitly retired sandbox records are safe to skip. Every other
            # record must remain complete and recognized, or the aggregate is
            # rejected rather than silently publishing a valid subset.
            if value.get("institutionId") in self.RETIRED_INSTITUTION_IDS:
                continue
            if set(value) != {
                "connectionId", "institutionId", "sessionId", "linkedAt"
            }:
                raise EnableBankingUnavailable("connection store contains a malformed record")
            if not all(isinstance(value[field], str) and value[field] for field in value):
                raise EnableBankingUnavailable("connection store contains a malformed record")
            if not self.CONNECTION_ID_PATTERN.fullmatch(value["connectionId"]):
                raise EnableBankingUnavailable("connection store contains an invalid connection id")
            if not self.INSTITUTION_ID_PATTERN.fullmatch(value["institutionId"]):
                raise EnableBankingUnavailable("connection store contains an invalid institution id")
            if value["institutionId"] not in self.KNOWN_INSTITUTION_IDS:
                raise EnableBankingUnavailable("connection store contains an unknown institution")
            if not self.PROVIDER_ID_PATTERN.fullmatch(value["sessionId"]):
                raise EnableBankingUnavailable("connection store contains an invalid provider session")
            if value["connectionId"] in seen_connection_ids or value["institutionId"] in seen_institution_ids:
                raise EnableBankingUnavailable("connection store contains a duplicate connection")
            seen_connection_ids.add(value["connectionId"])
            seen_institution_ids.add(value["institutionId"])
            result.append(value)
        return result

    def _read_pending_revocation(self) -> dict | None:
        path = self._revocation_state_path()
        try:
            path.lstat()
        except FileNotFoundError:
            return None
        raw = self._read_bounded_json_file(path, self.MAX_REVOCATION_STATE_SIZE)
        if not isinstance(raw, dict) or set(raw) != {
            "schemaVersion", "institutionId", "connections", "summary", "summaryMetadata",
        }:
            raise EnableBankingUnavailable("finance revocation state unavailable")
        institution_id = raw["institutionId"]
        if (
            raw["schemaVersion"] != self.REVOCATION_STATE_SCHEMA_VERSION
            or not isinstance(institution_id, str)
            or not self.INSTITUTION_ID_PATTERN.fullmatch(institution_id)
            or institution_id not in self.KNOWN_INSTITUTION_IDS
        ):
            raise EnableBankingUnavailable("finance revocation state unavailable")
        connections = self._validate_connection_records(raw["connections"])
        summary = raw["summary"]
        metadata = raw["summaryMetadata"]
        if summary is None:
            if metadata is not None:
                raise EnableBankingUnavailable("finance revocation state unavailable")
        else:
            if (
                not isinstance(summary, dict)
                or not self._validate_persisted_finance_payload(summary)
                or not isinstance(metadata, dict)
            ):
                raise EnableBankingUnavailable("finance revocation state unavailable")
            metadata = self._validate_summary_metadata(metadata)
            if self._summary_digest(summary) != metadata["bodyDigest"]:
                raise EnableBankingUnavailable("finance revocation state digest mismatch")
        return {
            "schemaVersion": raw["schemaVersion"],
            "institutionId": institution_id,
            "connections": connections,
            "summary": summary,
            "summaryMetadata": metadata,
        }

    def _apply_revocation_state(self, state: dict) -> None:
        """Apply a durable revoke intent and clear it only after every projection is safe."""
        self._atomic_write_json(self._connections_path(), {"connections": state["connections"]})
        summary = state["summary"]
        if summary is None:
            for path in (
                self._summary_state_path(),
                self._summary_metadata_path(),
                self._summary_path(),
            ):
                self._remove_file_durably(path)
        else:
            metadata = state["summaryMetadata"]
            committed = {
                "schemaVersion": self.FINANCE_STATE_SCHEMA_VERSION,
                "summary": summary,
                "metadata": metadata,
            }
            state_body = json.dumps(
                committed,
                separators=(",", ":"),
                sort_keys=True,
                allow_nan=False,
            ).encode("utf-8")
            if len(state_body) > self.MAX_FINANCE_STATE_SIZE:
                raise EnableBankingUnavailable("finance state exceeds response bound")
            self._atomic_write_json(self._summary_state_path(), committed)
            self._atomic_write_json(self._summary_metadata_path(), metadata)
            self._atomic_write_json(self._summary_path(), summary)
        self._remove_file_durably(self._revocation_state_path())

    def _recover_pending_revocation(self) -> None:
        state = self._read_pending_revocation()
        if state is not None:
            self._apply_revocation_state(state)

    def _load_connections(self) -> list[dict]:
        self._recover_pending_revocation()
        raw = self._read_bounded_json_file(self._connections_path(), 256 * 1024)
        if not isinstance(raw, dict) or set(raw) != {"connections"} or not isinstance(raw["connections"], list):
            return []
        return self._validate_connection_records(raw["connections"])

    def _save_connection(self, connection: dict) -> None:
        existing = [
            value for value in self._load_connections()
            if value["connectionId"] != connection["connectionId"]
            and value["institutionId"] != connection["institutionId"]
        ]
        existing.append(connection)
        self._atomic_write_json(self._connections_path(), {"connections": existing[-32:]})

    def load_cached_summary(self) -> dict | None:
        try:
            committed = self._read_summary_state()
            if committed is not None:
                value, _metadata = committed
            else:
                value = self._read_bounded_json_file(self._summary_path(), self.MAX_FINANCE_SUMMARY_SIZE)
                if not isinstance(value, dict):
                    return None
                metadata = self._read_summary_metadata()
                if metadata is not None and self._summary_digest(value) != metadata["bodyDigest"]:
                    return None
        except (EnableBankingUnavailable, TypeError, ValueError):
            return None
        repaired = self._repair_cached_summary_categories(value)
        if self._validate_finance_payload(repaired):
            return repaired

        # A previously valid snapshot eventually becomes age-inconsistent:
        # its stored observations still say `fresh`, while the provider may
        # now be unreachable. Reconstruct only the reviewed provenance fields
        # as stale/refresh_due, retain every original amount/row/timestamp,
        # and validate the complete result again before exposing it. This
        # never turns malformed or partial disk state into a usable snapshot.
        stale = self._mark_cached_summary_stale(repaired)
        return stale if self._validate_persisted_finance_payload(stale) else None

    @classmethod
    def _repair_cached_summary_categories(cls, value: object) -> object:
        """Backfill safe merchant categories in older normalized snapshots.

        A valid cache may outlive the deployment that created it. Re-running
        only rows explicitly labeled ``Uncategorized`` lets a newer category
        vocabulary improve that cache without overwriting a provider label or
        a future user override. The result is still passed through the full
        finance validator before it can be returned.
        """
        if not isinstance(value, dict):
            return value
        transactions = value.get("transactions")
        if not isinstance(transactions, dict) or not isinstance(transactions.get("transactions"), list):
            return value

        changed = False
        repaired_rows: list[object] = []
        for row in transactions["transactions"]:
            if not isinstance(row, dict) or row.get("category") != "Uncategorized":
                repaired_rows.append(row)
                continue
            amount = row.get("signedAmountCents")
            merchant = row.get("merchant") or row.get("title")
            if not isinstance(amount, int) or isinstance(amount, bool) or not isinstance(merchant, str):
                repaired_rows.append(row)
                continue
            party_key = "debtor" if amount > 0 else "creditor"
            derived = cls._transaction_category({
                "credit_debit_indicator": "CRDT" if amount > 0 else "DBIT",
                party_key: {"name": merchant},
            })
            if derived == "Uncategorized":
                repaired_rows.append(row)
                continue
            repaired_rows.append({**row, "category": derived})
            changed = True

        if not changed:
            return value
        return {
            **value,
            "transactions": {
                **transactions,
                "transactions": repaired_rows,
            },
        }

    @classmethod
    def _mark_cached_summary_stale(cls, value: object) -> object:
        """Mark observed nested Finance provenance stale without relabeling data."""
        if isinstance(value, list):
            return [cls._mark_cached_summary_stale(item) for item in value]
        if not isinstance(value, dict):
            return value

        result = {
            key: cls._mark_cached_summary_stale(child)
            for key, child in value.items()
        }
        provenance = result.get("provenance")
        if isinstance(provenance, dict) and provenance.get("quality") == "observed":
            account_rows = result.get("accounts")
            has_observed_account = not isinstance(account_rows, list) or any(
                isinstance(account, dict) and account.get("availability") == "observed"
                for account in account_rows
            )
            if not has_observed_account:
                return result
            result["provenance"] = {
                **provenance,
                "freshness": "stale",
                "connectorState": "refresh_due",
            }
        return result

    @staticmethod
    def _unavailable_provenance(observed_at: str) -> dict:
        return {
            "source": "no-authorized-finance-source",
            "observedAt": observed_at,
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable",
        }

    @classmethod
    def _filtered_observed_provenance(
        cls,
        original: dict,
        *,
        source: str,
        rows: list[dict],
    ) -> dict:
        has_stale = any(
            row.get("provenance", {}).get("freshness") == "stale"
            or row.get("provenance", {}).get("connectorState") == "refresh_due"
            for row in rows
        )
        return {
            "source": source,
            "observedAt": original["observedAt"],
            "freshness": "stale" if has_stale else "fresh",
            "quality": "observed",
            "connectorState": "refresh_due" if has_stale else "healthy",
        }

    @staticmethod
    def _source_for_rows(rows: list[dict], derived_source: str) -> str:
        sources = {row["source"] for row in rows}
        return next(iter(sources)) if len(sources) == 1 else derived_source

    def _remove_institution_from_summary(self, summary: dict, institution_id: str) -> dict:
        """Remove one connector's observations without inventing replacement data."""
        if not self._validate_persisted_finance_payload(summary):
            raise EnableBankingUnavailable("cached finance summary unavailable")
        source = f"enablebanking:{institution_id}"
        result = dict(summary)
        generated_at = summary["generatedAt"]

        accounts_snapshot = summary.get("accounts")
        remaining_accounts: list[dict] = []
        if isinstance(accounts_snapshot, dict) and accounts_snapshot.get("availability") == "observed":
            rows = accounts_snapshot.get("accounts")
            if not isinstance(rows, list):
                raise EnableBankingUnavailable("cached finance accounts unavailable")
            remaining_accounts = [
                row for row in rows
                if isinstance(row, dict) and row.get("source") != source
            ]
            if remaining_accounts:
                account_source = self._source_for_rows(
                    remaining_accounts,
                    "derived-account-snapshot",
                )
                result["accounts"] = {
                    "availability": "observed",
                    "accounts": remaining_accounts,
                    "provenance": self._filtered_observed_provenance(
                        accounts_snapshot["provenance"],
                        source=account_source,
                        rows=[
                            row for row in remaining_accounts
                            if row.get("availability") == "observed"
                        ],
                    ),
                }
            else:
                result["accounts"] = {
                    "availability": "unavailable",
                    "provenance": self._unavailable_provenance(generated_at),
                }
        elif isinstance(accounts_snapshot, dict):
            result["accounts"] = {
                "availability": "unavailable",
                "provenance": self._unavailable_provenance(generated_at),
            }

        has_observed_account = any(
            row.get("availability") == "observed" for row in remaining_accounts
        )
        transactions_snapshot = summary.get("transactions")
        remaining_transactions: list[dict] = []
        has_transaction_observation = False
        if isinstance(transactions_snapshot, dict) and transactions_snapshot.get("availability") == "observed":
            rows = transactions_snapshot.get("transactions")
            if not isinstance(rows, list):
                raise EnableBankingUnavailable("cached finance transactions unavailable")
            remaining_transactions = [
                row for row in rows
                if isinstance(row, dict) and row.get("source") != source
            ]
            has_transaction_observation = has_observed_account
            if remaining_transactions:
                transaction_source = self._source_for_rows(
                    remaining_transactions,
                    "derived-transaction-snapshot",
                )
                result["transactions"] = {
                    "availability": "observed",
                    "transactions": remaining_transactions,
                    "provenance": self._filtered_observed_provenance(
                        transactions_snapshot["provenance"],
                        source=transaction_source,
                        rows=remaining_transactions,
                    ),
                }
            elif has_observed_account:
                result["transactions"] = {
                    "availability": "observed",
                    "transactions": [],
                    "provenance": {
                        **transactions_snapshot["provenance"],
                        "source": "derived-transaction-snapshot",
                    },
                }
            else:
                result["transactions"] = {
                    "availability": "unavailable",
                    "provenance": self._unavailable_provenance(generated_at),
                }
        elif isinstance(transactions_snapshot, dict):
            result["transactions"] = {
                "availability": "unavailable",
                "provenance": self._unavailable_provenance(generated_at),
            }

        if not has_observed_account or not has_transaction_observation:
            for key in (
                "monthlyIncome", "fixedCosts", "discretionaryBuffer",
                "spent", "savingsGoal", "saved",
            ):
                result[key] = {
                    "availability": "unavailable",
                    "provenance": self._unavailable_provenance(generated_at),
                }
        else:
            transaction_provenance = result["transactions"]["provenance"]
            observed_at = transaction_provenance["observedAt"]
            freshness = transaction_provenance["freshness"]
            connector_state = transaction_provenance["connectorState"]
            monthly_income = 0
            fixed_costs = 0
            spent = 0
            current_month = datetime.now(BUSINESS_TIME_ZONE).strftime("%Y-%m")
            for transaction in remaining_transactions:
                if not transaction["timestamp"].startswith(current_month):
                    continue
                amount = transaction["signedAmountCents"]
                if amount > 0:
                    monthly_income = self._checked_add(monthly_income, amount)
                elif amount < 0:
                    outflow = -amount
                    spent = self._checked_add(spent, outflow)
                    if transaction["category"] in {"Bills", "Subscriptions"}:
                        fixed_costs = self._checked_add(fixed_costs, outflow)
            metric_provenance = {
                "source": transaction_provenance["source"],
                "observedAt": observed_at,
                "freshness": freshness,
                "quality": "observed",
                "connectorState": connector_state,
            }
            for key, amount in (
                ("monthlyIncome", monthly_income),
                ("fixedCosts", fixed_costs),
                ("spent", spent),
            ):
                result[key] = {
                    "availability": "observed",
                    "amountCents": amount,
                    "provenance": metric_provenance,
                }
            for key in ("discretionaryBuffer", "savingsGoal", "saved"):
                value = summary.get(key)
                if not isinstance(value, dict) or value.get("availability") != "unavailable":
                    result[key] = {
                        "availability": "unavailable",
                        "provenance": self._unavailable_provenance(generated_at),
                    }

        if not self._validate_persisted_finance_payload(result):
            raise EnableBankingUnavailable("filtered finance summary failed validation")
        return result

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
                    raise ProviderSessionNotFound("provider session not found")
                data = await self._read_upstream_json(
                    upstream,
                    expected_statuses={200},
                    maximum_bytes=self.MAX_RESPONSE_SIZE,
                )
        if not isinstance(data, dict):
            raise EnableBankingUnavailable("invalid provider session")
        return data

    async def _delete_session(
        self,
        client: httpx.AsyncClient,
        credentials: dict,
        token: str,
        session_id: str,
    ) -> None:
        """Revoke one provider session without allowing provider text across the boundary."""
        if not self.PROVIDER_ID_PATTERN.fullmatch(session_id):
            raise EnableBankingUnavailable("invalid provider session id")
        async with asyncio.timeout(self.TOTAL_TIMEOUT):
            async with client.stream(
                "DELETE",
                f"{credentials['api_base_url']}/sessions/{session_id}",
                headers={"Authorization": f"Bearer {token}"},
            ) as upstream:
                # A missing session is already revoked from this adapter's
                # perspective.  410 is the equivalent durable "gone" result.
                if upstream.status_code in {404, 410}:
                    return
                if upstream.status_code in {200, 202, 204}:
                    return
                if upstream.status_code not in {400, 409}:
                    raise EnableBankingUnavailable("provider revoke unavailable")
                try:
                    data = await self._read_upstream_json(
                        upstream,
                        expected_statuses={400, 409},
                        maximum_bytes=self.MAX_RESPONSE_SIZE,
                    )
                except EnableBankingUnavailable as exc:
                    raise EnableBankingUnavailable("provider revoke unavailable") from exc
                provider_state = (
                    data.get("status", data.get("state"))
                    if isinstance(data, dict)
                    else None
                )
                if str(provider_state or "").strip().upper() in {"CLOSED", "REVOKED"}:
                    return
                raise EnableBankingUnavailable("provider revoke unavailable")

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
        maximum_bytes = (
            self.MAX_TRANSACTION_RESPONSE_SIZE
            if endpoint == "transactions"
            else self.MAX_RESPONSE_SIZE
        )
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
                    maximum_bytes=maximum_bytes,
                )
        if not isinstance(data, dict):
            raise EnableBankingUnavailable("invalid provider account response")
        return data

    def _session_state(self, raw: object) -> str:
        # Unknown provider states are not proof that authorization is still in
        # progress. Keep the lifecycle fail-closed until a reviewed provider
        # state is added to the map.
        return self.SESSION_STATUS_MAP.get(str(raw or "").strip().upper(), "error")

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

    def _active_flow_for_institution(self, institution_id: str) -> tuple[str, dict] | None:
        """Return the active in-process flow for this institution, if any.

        Consent initiation is intentionally idempotent for the same connector:
        the phone may lose the Safari presentation race or be relaunched after
        the gateway has created the flow.  Re-serving the already-issued opaque
        handoff lets the user recover without creating a second provider flow.
        A different connector remains blocked until the active flow reaches a
        terminal state.
        """
        for connection_id, flow in self.consent_flows.items():
            if (
                flow["state"] in self.ACTIVE_STATES
                and flow.get("institutionId") == institution_id
            ):
                return connection_id, flow
        return None

    def _validate_catalog_institution(self, institution_id: object) -> str | None:
        if not isinstance(institution_id, str) or not self.INSTITUTION_ID_PATTERN.fullmatch(institution_id):
            return "invalid_request"
        recognized = self._recognized_institutions()
        if (
            institution_id not in self.KNOWN_INSTITUTION_IDS
            or (recognized is not None and institution_id not in recognized)
        ):
            return "unknown_institution"
        return None

    def _prepare_revocation_state(self, institution_id: str, connections: list[dict]) -> dict:
        cached = self.load_cached_summary()
        summary = (
            None
            if cached is None
            else self._remove_institution_from_summary(cached, institution_id)
        )
        metadata = None if summary is None else self._next_summary_metadata(summary)
        state = {
            "schemaVersion": self.REVOCATION_STATE_SCHEMA_VERSION,
            "institutionId": institution_id,
            "connections": [
                connection for connection in connections
                if connection["institutionId"] != institution_id
            ],
            "summary": summary,
            "summaryMetadata": metadata,
        }
        encoded = json.dumps(
            state,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        ).encode("utf-8")
        if len(encoded) > self.MAX_REVOCATION_STATE_SIZE:
            raise EnableBankingUnavailable("finance revocation state exceeds response bound")
        return state

    async def revoke(self, institution_id: str) -> tuple[int, dict]:
        """Revoke a catalog institution and commit its local cleanup safely."""
        validation_error = self._validate_catalog_institution(institution_id)
        if validation_error is not None:
            return 400, {"error": validation_error}

        async with self.connections_lock:
            try:
                self._recover_pending_revocation()
                connections = self._load_connections()
            except Exception:
                return 503, {"error": "temporary_error"}
            connection = next(
                (
                    value for value in connections
                    if value["institutionId"] == institution_id
                ),
                None,
            )
            if connection is None:
                return 404, {"error": "not_connected"}
            try:
                state = self._prepare_revocation_state(institution_id, connections)
            except Exception:
                return 503, {"error": "temporary_error"}
            credentials = self._credentials()
            if credentials is None:
                return 503, {"error": "temporary_error"}
            try:
                async with self._http_client() as client:
                    token = await self._bearer(credentials)
                    await self._delete_session(
                        client,
                        credentials,
                        token,
                        connection["sessionId"],
                    )
            except Exception:
                # The provider must be confirmed before the local connection or
                # its cached observations are touched.
                return 503, {"error": "temporary_error"}
            try:
                # The intent is durable before either projection is changed.
                # Any interrupted application is completed by the next read.
                self._atomic_write_json(self._revocation_state_path(), state)
                self._apply_revocation_state(state)
            except Exception:
                return 503, {"error": "temporary_error"}

        async with self.consent_lock:
            existing_flow = self.consent_flows.get(connection["connectionId"])
            if existing_flow is None:
                self.consent_flows[connection["connectionId"]] = {
                    "state": "revoked",
                    "institutionId": institution_id,
                    "started": time.monotonic(),
                    "csrf_state": None,
                    "authorization_id": connection["connectionId"],
                    "session_id": None,
                }
            for flow in self.consent_flows.values():
                if flow.get("institutionId") == institution_id:
                    flow["state"] = "revoked"
                    flow["session_id"] = None
            self._prune_flows()
        return 200, {"state": "revoked"}

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
            existing = self._active_flow_for_institution(institution_id)
            if existing is not None:
                connection_id, flow = existing
                consent_url = flow.get("consent_url")
                if self._safe_consent_url(consent_url):
                    return 200, {"consentUrl": consent_url, "connectionId": connection_id}
                return 409, {"error": "already_linking"}
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
                "consent_url": consent_url,
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
        if cached_state in {"expired", "revoked"}:
            return {"state": cached_state}
        if cached_state in {"linked", "error"} and persisted is None:
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
        except ProviderSessionNotFound:
            state = "revoked"
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
        if not isinstance(query, str) or len(query) > self.MAX_CALLBACK_QUERY_SIZE:
            return CallbackResult(valid=False)
        try:
            pairs = parse_qsl(
                query,
                keep_blank_values=True,
                strict_parsing=True,
                max_num_fields=self.MAX_CALLBACK_FIELDS,
            )
        except ValueError:
            return CallbackResult(valid=False)
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
            matched_flow = dict(self.consent_flows[match]) if match is not None else None
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
            if "status" in session_response:
                session_state = self._session_state(session_response.get("status"))
                if session_state != "linked":
                    async with self.consent_lock:
                        flow = self.consent_flows.get(match)
                        if flow is not None and flow["state"] in self.ACTIVE_STATES:
                            flow["state"] = session_state
                            flow["session_id"] = None
                            self._prune_flows()
                    return CallbackResult(valid=True, linked=False)
            connection = {
                "connectionId": match,
                "institutionId": matched_flow["institutionId"],
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
            raw = Decimal(amount)
            parsed = raw.quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
        except (InvalidOperation, ValueError):
            raise EnableBankingUnavailable("invalid money value")
        if raw != parsed:
            raise EnableBankingUnavailable("money value has fractional cents")
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

    @classmethod
    def _transaction_category(cls, transaction: dict) -> str:
        aliases = {
            "food": "Groceries", "foods": "Groceries", "grocery": "Groceries", "groceries": "Groceries",
            "groceries and food": "Groceries", "lebensmittel": "Groceries", "supermarket": "Groceries", "supermarkt": "Groceries",
            "dining": "Dining", "restaurant": "Dining", "restaurants": "Dining",
            "food and dining": "Dining", "food dining": "Dining", "food drink": "Dining", "food drinks": "Dining", "essen": "Dining",
            "transport": "Transport", "transportation": "Transport",
            "public transport": "Transport", "mobility": "Transport", "verkehr": "Transport", "travel transport": "Transport",
            "shopping": "Shopping", "retail": "Shopping", "online shopping": "Shopping", "einkaufen": "Shopping",
            "bill": "Bills", "bills": "Bills", "utilities": "Bills",
            "household": "Bills", "home": "Bills", "housing": "Bills", "rent": "Bills", "utilities household": "Bills",
            "wohnen": "Bills", "miete": "Bills", "rechnungen": "Bills",
            "subscription": "Subscriptions", "subscriptions": "Subscriptions", "recurring": "Subscriptions", "abonnement": "Subscriptions", "abos": "Subscriptions",
            "health": "Health", "healthcare": "Health", "medical": "Health", "pharmacy": "Health", "medizin": "Health", "apotheke": "Health",
            "travel": "Travel", "reisen": "Travel", "reise": "Travel", "hotels": "Travel", "hotel": "Travel",
            "transfer": "Transfers", "transfers": "Transfers", "bank transfer": "Transfers", "bank transfers": "Transfers", "ueberweisung": "Transfers", "uberweisung": "Transfers",
            "fee": "Fees", "fees": "Fees", "charges": "Fees", "bank fee": "Fees", "bank fees": "Fees", "gebuehr": "Fees", "gebuehren": "Fees", "gebuhr": "Fees", "gebuhren": "Fees", "entgelt": "Fees",
            "tax": "Taxes", "taxes": "Taxes", "steuer": "Taxes", "steuern": "Taxes",
            "investment": "Investments", "investments": "Investments", "investing": "Investments", "brokerage": "Investments", "wertpapiere": "Investments", "aktien": "Investments", "etf": "Investments",
            "income": "Income", "salary": "Income", "salaries": "Income", "wages": "Income", "gehalt": "Income", "lohn": "Income", "rente": "Income", "pension": "Income",
            "cash": "Cash", "cash withdrawal": "Cash", "atm": "Cash", "bargeld": "Cash",
            "other": "Uncategorized", "unknown": "Uncategorized", "uncategorized": "Uncategorized",
        }
        is_inflow = str(transaction.get("credit_debit_indicator") or "").upper() == "CRDT"
        supplied = transaction.get("category") or transaction.get("transaction_category")
        if isinstance(supplied, str):
            key = cls._category_key(supplied)
            if key in aliases:
                mapped = aliases[key]
                # A provider occasionally labels an outgoing payment as income.
                # Direction is authoritative for that one category.
                if mapped != "Income" or is_inflow:
                    return mapped

        raw_mcc = str(transaction.get("merchant_category_code") or "")
        try:
            mcc = int(raw_mcc)
        except (TypeError, ValueError):
            mcc = 0
        categories = {
            "5411": "Groceries", "5422": "Groceries", "5441": "Groceries",
            "5451": "Groceries", "5462": "Groceries", "5499": "Groceries",
            "5541": "Transport", "5542": "Transport", "4111": "Transport",
            "4121": "Transport", "4131": "Transport", "4789": "Transport",
            "7512": "Transport", "5812": "Dining", "5813": "Dining", "5814": "Dining",
            "5912": "Health", "7011": "Travel", "4722": "Travel", "4511": "Travel",
            "8011": "Health",
        }
        if raw_mcc in categories or str(mcc) in categories:
            return categories.get(raw_mcc, categories[str(mcc)])
        if 3000 <= mcc <= 3999:
            return "Travel"
        if 8021 <= mcc <= 8099:
            return "Health"

        party_names = []
        for party_key in ("creditor", "debtor"):
            party = transaction.get(party_key)
            if isinstance(party, dict) and isinstance(party.get("name"), str):
                party_names.append(party["name"])
        context_fields = (
            "remittance_information_unstructured",
            "remittance_information_structured",
            "remittance_information",
            "additional_information",
            "reference",
            "end_to_end_id",
        )
        context_values = []
        for field in context_fields:
            value = transaction.get(field)
            if isinstance(value, str):
                context_values.append(value)
            elif isinstance(value, list):
                context_values.extend(item for item in value if isinstance(item, str))
        merchant_key = cls._category_key(" ".join(party_names + context_values))
        merchant_rules = (
            # Direction-sensitive rules run before generic merchant rules so a
            # refund/salary is not hidden under the merchant's usual category.
            ("Income", ("gehalt", "lohn", "salary", "payroll", "erstattung", "refund", "reimbursement", "gutschrift")),
            # Check transfers before `uber`: folded "Überweisung" contains the
            # short ride-hailing token.
            ("Transfers", ("überweisung", "ueberweisung", "bank transfer", "sepa transfer", "kontoübertrag")),
            ("Fees", ("gebühr", "gebuehr", "bank fee", "service fee", "entgelt", "commission")),
            ("Taxes", ("finanzamt", "steuer", "tax payment", "taxes")),
            ("Investments", ("trade republic", "scalable capital", "broker", "depot", "aktien", "etf", "securities")),
            ("Cash", ("geldautomat", "bargeldauszahlung", "cash withdrawal", "atm")),
            ("Groceries", ("rewe", "aldi", "lidl", "edeka", "kaufland", "penny", "netto", "denns", "alnatura", "supermarkt")),
            ("Dining", ("restaurant", "lieferando", "uber eats", "ubereats", "wolt", "mcdonald", "starbucks", "café", "cafe", "imbiss", "bistro")),
            ("Transport", ("deutsche bahn", "bvg", "uber", "bolt", "tankstelle", "shell", "aral", "esso", "parkhaus")),
            ("Subscriptions", ("netflix", "spotify", "disney", "amazon prime", "icloud", "youtube premium")),
            ("Bills", ("miete", "rent", "stromrechnung", "electricity", "stadtwerke", "vodafone", "telekom", "o2", "versicherung", "insurance", "internet", "wasser", "heizung")),
            ("Shopping", ("amazon", "zalando", "ikea", "mediamarkt", "saturn", "otto")),
            ("Health", ("apotheke", "pharmacy", "arzt", "doctor", "medical", "gesundheit", "zahnarzt", "dentist")),
            ("Travel", ("booking.com", "airbnb", "hotel", "expedia", "flughafen", "airport", "airline")),
        )
        for category, keywords in merchant_rules:
            if category == "Income" and not is_inflow:
                continue
            if any(cls._category_key(keyword) in merchant_key for keyword in keywords):
                return category
        return "Uncategorized"

    @staticmethod
    def _category_key(value: str) -> str:
        """Normalize provider text like Swift's diacritic-insensitive matcher."""
        folded = unicodedata.normalize("NFKD", value).encode("ascii", "ignore").decode("ascii")
        return re.sub(r"[^a-z0-9]+", " ", folded.casefold()).strip()

    def _normalize_transaction(
        self,
        transaction: object,
        *,
        institution_id: str,
        account_label: str,
        account_uid: str,
        observed_at: str,
    ) -> dict:
        if not isinstance(transaction, dict) or not isinstance(transaction.get("transaction_amount"), dict):
            raise EnableBankingUnavailable("invalid provider transaction row")
        amount = transaction["transaction_amount"]
        try:
            magnitude = abs(self._money_to_cents(
                amount.get("amount"), amount.get("currency"), self._max_safe_cents
            ))
        except EnableBankingUnavailable:
            raise EnableBankingUnavailable("invalid provider transaction amount")
        indicator = transaction.get("credit_debit_indicator")
        if indicator == "DBIT":
            signed_amount = -magnitude
            party_key = "creditor"
        elif indicator == "CRDT":
            signed_amount = magnitude
            party_key = "debtor"
        else:
            raise EnableBankingUnavailable("invalid provider transaction direction")
        party = transaction.get(party_key)
        merchant = self._provider_text(party.get("name") if isinstance(party, dict) else None)
        timestamp = (
            self._provider_date(transaction.get("booking_date"))
            or self._provider_date(transaction.get("value_date"))
            or self._provider_date(transaction.get("transaction_date"))
        )
        if timestamp is None:
            raise EnableBankingUnavailable("invalid provider transaction date")
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
    def _deduplicate_transactions(rows: list[dict]) -> list[dict]:
        """Collapse exact retries and reject conflicting stable identities."""
        by_id: dict[str, dict] = {}
        ordered: list[dict] = []
        for row in rows:
            transaction_id = row.get("id") if isinstance(row, dict) else None
            if not isinstance(transaction_id, str) or not transaction_id:
                raise EnableBankingUnavailable("normalized transaction has no stable id")
            existing = by_id.get(transaction_id)
            if existing is None:
                by_id[transaction_id] = row
                ordered.append(row)
            elif existing != row:
                raise EnableBankingUnavailable("conflicting duplicate provider transaction")
        return ordered

    @staticmethod
    def _deduplicate_accounts(rows: list[dict]) -> list[dict]:
        """Collapse exact repeated account observations and reject conflicts."""
        by_id: dict[str, dict] = {}
        ordered: list[dict] = []
        for row in rows:
            account_id = row.get("id") if isinstance(row, dict) else None
            if not isinstance(account_id, str) or not account_id:
                raise EnableBankingUnavailable("normalized account has no stable id")
            existing = by_id.get(account_id)
            if existing is None:
                by_id[account_id] = row
                ordered.append(row)
            elif existing != row:
                raise EnableBankingUnavailable("conflicting duplicate provider account")
        return ordered

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
                raise EnableBankingUnavailable("provider session contains an invalid account")
            details = account if isinstance(account, dict) else {}
            if not details.get("name") or not details.get("currency"):
                fetched = await self._get_account_json(
                    client, credentials, token, uid, "details"
                )
                if fetched:
                    details = fetched
            currency = details.get("currency")
            if not isinstance(currency, str) or not currency.strip():
                raise EnableBankingUnavailable("provider account has no valid currency")
            currency_code = currency.strip().upper()
            if not re.fullmatch(r"[A-Z]{3}", currency_code):
                raise EnableBankingUnavailable("provider account has an invalid currency")
            account_name = self._provider_text(details.get("name"), maximum=96)
            account_label = f"{connection['institutionId']} · {account_name or f'Account {index}'}"
            source = f"enablebanking:{connection['institutionId']}"
            account_id = "ebacct-" + hashlib.sha256(
                f"{connection['institutionId']}|{uid}".encode("utf-8")
            ).hexdigest()[:40]
            if currency_code != "EUR":
                # Keep the account in the observed account list so a mixed-currency
                # wallet does not disappear or black out its EUR accounts. The
                # balance is intentionally omitted: LifeOS has no FX conversion
                # authority, so this account must never enter an EUR aggregate.
                account_rows.append({
                    "availability": "unavailable",
                    "id": account_id,
                    "name": account_label,
                    "detail": f"{currency_code} · Enable Banking",
                    "source": source,
                    "provenance": {
                        "source": source,
                        "observedAt": observed_at,
                        "freshness": "unknown",
                        "quality": "unavailable",
                        "connectorState": "unavailable",
                    },
                })
                continue
            balances = await self._get_account_json(
                client, credentials, token, uid, "balances"
            )
            balance_items = balances.get("balances")
            if not isinstance(balance_items, list):
                raise EnableBankingUnavailable("provider account has no valid balances")
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
                raise EnableBankingUnavailable("provider account has no valid EUR balance")
            provenance = {
                "source": source,
                "observedAt": observed_at,
                "freshness": "fresh",
                "quality": "observed",
                "connectorState": "healthy",
            }
            account_rows.append({
                "availability": "observed",
                "id": account_id,
                "name": account_label,
                "detail": "EUR · Enable Banking",
                "balanceCents": balance_cents,
                "source": source,
                "provenance": provenance,
            })
            date_to = datetime.now(timezone.utc).date()
            date_from = date_to - timedelta(days=180)
            transaction_params = {
                "date_from": date_from.isoformat(),
                "date_to": date_to.isoformat(),
            }
            continuation_key: str | None = None
            seen_continuations: set[str] = set()
            account_transaction_count = 0
            for _ in range(self.MAX_TRANSACTION_PAGES):
                page_params = {
                    **transaction_params,
                    **({"continuation_key": continuation_key} if continuation_key is not None else {}),
                }
                transaction_payload = await self._get_account_json(
                    client, credentials, token, uid, "transactions", params=page_params
                )
                transactions = transaction_payload.get("transactions")
                if not isinstance(transactions, list):
                    raise EnableBankingUnavailable("invalid transaction page")
                account_transaction_count += len(transactions)
                if account_transaction_count > self.MAX_TRANSACTIONS_PER_ACCOUNT:
                    raise EnableBankingUnavailable("transaction history exceeds bound")
                for transaction in transactions:
                    normalized = self._normalize_transaction(
                        transaction,
                        institution_id=connection["institutionId"],
                        account_label=account_label,
                        account_uid=uid,
                        observed_at=observed_at,
                    )
                    if normalized is not None:
                        transaction_rows.append(normalized)
                next_continuation = transaction_payload.get("continuation_key")
                if next_continuation is None:
                    break
                if (
                    not isinstance(next_continuation, str)
                    or not next_continuation
                    or len(next_continuation) > 512
                    or any(ord(char) < 0x21 or ord(char) == 0x7F for char in next_continuation)
                    or next_continuation in seen_continuations
                ):
                    raise EnableBankingUnavailable("invalid transaction continuation")
                seen_continuations.add(next_continuation)
                continuation_key = next_continuation
            else:
                raise EnableBankingUnavailable("transaction pagination exceeds bound")
        if not account_rows:
            raise EnableBankingUnavailable("no usable EUR account balances")
        return account_rows, self._deduplicate_transactions(transaction_rows)

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
        async with self.connections_lock:
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
        all_accounts = self._deduplicate_accounts(all_accounts)
        all_transactions = self._deduplicate_transactions(all_transactions)
        all_accounts.sort(key=lambda row: row["id"])
        all_transactions.sort(key=lambda row: (row["timestamp"], row["id"]))
        account_sources = {row["source"] for row in all_accounts}
        account_source = (
            next(iter(account_sources))
            if len(account_sources) == 1
            else "derived-account-snapshot"
        )
        has_observed_eur_account = any(
            row["availability"] == "observed" for row in all_accounts
        )
        transaction_sources = {row["source"] for row in all_transactions}
        transaction_source = (
            next(iter(transaction_sources))
            if len(transaction_sources) == 1
            else "derived-transaction-snapshot"
        )
        if not has_observed_eur_account:
            # A wallet containing only unsupported currencies is an observed
            # account list, not an observed EUR ledger. Keep every aggregate
            # unavailable instead of turning the empty transaction set into
            # a misleading zero.
            transaction_source = "no-authorized-finance-source"
        current_month = datetime.now(BUSINESS_TIME_ZONE).strftime("%Y-%m")
        monthly_income = 0
        fixed_costs = 0
        spent = 0
        for transaction in all_transactions:
            if not transaction["timestamp"].startswith(current_month):
                continue
            amount = transaction["signedAmountCents"]
            if amount > 0:
                monthly_income = self._checked_add(monthly_income, amount)
            elif amount < 0:
                outflow = -amount
                spent = self._checked_add(spent, outflow)
                if transaction["category"] in {"Bills", "Subscriptions"}:
                    fixed_costs = self._checked_add(fixed_costs, outflow)
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
                monthly_income if has_observed_eur_account else None,
                source=transaction_source,
                observed_at=observed_at,
            ),
            "fixedCosts": self._metric(
                fixed_costs if has_observed_eur_account else None,
                source=transaction_source,
                observed_at=observed_at,
            ),
            "discretionaryBuffer": self._metric(
                None, source="no-authorized-finance-source", observed_at=observed_at
            ),
            "spent": self._metric(
                spent if has_observed_eur_account else None,
                source=transaction_source,
                observed_at=observed_at,
            ),
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
            } if has_observed_eur_account else {
                "availability": "unavailable",
                "provenance": {
                    "source": transaction_source,
                    "observedAt": observed_at,
                    "freshness": "unknown",
                    "quality": "unavailable",
                    "connectorState": "unavailable",
                },
            },
        }
        if not self._validate_finance_payload(summary):
            raise EnableBankingUnavailable("normalized finance payload failed validation")
        serialized = json.dumps(summary, separators=(",", ":"), sort_keys=True, allow_nan=False).encode("utf-8")
        if len(serialized) > self.MAX_FINANCE_SUMMARY_SIZE:
            raise EnableBankingUnavailable("normalized finance summary exceeds response bound")
        async with self.connections_lock:
            # Do not publish a provider response fetched for a connection set
            # that was concurrently relinked or revoked.
            if self._load_connections() != connections:
                raise EnableBankingUnavailable("connections changed during refresh")
            metadata = self._next_summary_metadata(summary)
            state = {
                "schemaVersion": self.FINANCE_STATE_SCHEMA_VERSION,
                "summary": summary,
                "metadata": metadata,
            }
            state_body = json.dumps(state, separators=(",", ":"), sort_keys=True, allow_nan=False).encode("utf-8")
            if len(state_body) > self.MAX_FINANCE_STATE_SIZE:
                raise EnableBankingUnavailable("finance state exceeds response bound")
            # The state envelope is the single commit point. The historical body
            # and metadata files are compatibility projections; a crash between
            # either projection rename cannot expose a torn Finance snapshot.
            self._atomic_write_json(self._summary_state_path(), state)
            self._atomic_write_json(self._summary_metadata_path(), metadata)
            self._atomic_write_json(self._summary_path(), summary)
        return summary
