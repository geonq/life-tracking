"""LifeOS sync server.

Stores the LifeOS app's Calendar snapshot and Tax documents as opaque JSON
blobs, exactly as the Swift app encodes them (iso8601 dates, sorted keys).
This server does not model CalendarItem/TaxDocument itself on purpose: the
Swift client already contains tested merge logic (CalendarSnapshot.merged in
ios/Shared/CalendarDomain.swift) and pushes an already-merged snapshot here.
This service is deliberately a dumb, authoritative store reachable over the
Tailscale tailnet, not a second place that re-implements merge semantics.

Run:
    python -m venv venv
    venv\\\\Scripts\\\\pip install -r requirements.txt
    set LIFEOS_TAILSCALE_ALLOWED_LOGIN=<exact tailnet login>
    venv\\\\Scripts\\\\python -m uvicorn main:app --host 127.0.0.1 --port 8421

The Python backend binds only to loopback (127.0.0.1:8421); private Tailscale
Serve terminates HTTPS and forwards to it. Never bind this backend to 0.0.0.0:
calendar and tax-document data must stay unreachable without the Serve layer.
"""
import asyncio
import json
import math
import mimetypes
import os
import re
import stat
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.parse import urlsplit

import httpx
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response

from enablebanking import EnableBankingService


def _is_allowed_upstream(value: str, expected_path: str) -> bool:
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except (TypeError, ValueError):
        return False
    return (
        parsed.scheme == "http"
        and parsed.hostname in {"127.0.0.1", "::1"}
        and port is not None
        and parsed.username is None
        and parsed.password is None
        and parsed.path == expected_path
        and not parsed.query
        and not parsed.fragment
    )


def _canonicalize_tailscale_login(value: str) -> str:
    """Return the canonical exact login, rejecting ambiguous header values."""
    if not isinstance(value, str) or not value or value != value.strip():
        raise ValueError("Tailscale login must be nonempty and have no surrounding whitespace")
    if any(char.isspace() or ord(char) < 0x20 or ord(char) == 0x7F for char in value):
        raise ValueError("Tailscale login contains whitespace or a control character")
    if "," in value or value.count("@") != 1:
        raise ValueError("Tailscale login must contain exactly one value")
    if not all(char.isalnum() or char in "._+-@" for char in value):
        raise ValueError("Tailscale login contains invalid characters")
    local, domain = value.split("@")
    if not local or not domain:
        raise ValueError("Tailscale login must contain a local and domain component")
    return value.casefold()


def _required_tailscale_login() -> str:
    raw_value = os.environ.get("LIFEOS_TAILSCALE_ALLOWED_LOGIN")
    if raw_value is None:
        raise RuntimeError("LIFEOS_TAILSCALE_ALLOWED_LOGIN must be configured")
    try:
        return _canonicalize_tailscale_login(raw_value)
    except ValueError as exc:
        raise RuntimeError("LIFEOS_TAILSCALE_ALLOWED_LOGIN is invalid") from exc


def _tailscale_login_from_raw_headers(headers) -> str | None:
    """Read exactly one Serve identity header without ASGI duplicate collapsing."""
    values = [
        value for name, value in headers
        if isinstance(name, bytes) and name.lower() == b"tailscale-user-login"
    ]
    if len(values) != 1:
        return None
    try:
        raw_value = values[0].decode("utf-8")
        return _canonicalize_tailscale_login(raw_value)
    except (UnicodeDecodeError, ValueError):
        return None


DATA_DIR = Path(os.environ.get("LIFEOS_DATA_DIR", Path(__file__).parent / "data"))
CALENDAR_PATH = DATA_DIR / "calendar.json"
DOCUMENTS_INDEX_PATH = DATA_DIR / "documents.json"
DOCUMENTS_DIR = DATA_DIR / "documents"

CLAUDE_INGEST_UPSTREAM = "http://127.0.0.1:8787/api/usage/claude-ingest"
CLAUDE_INGEST_MAX_BODY_SIZE = 16 * 1024
CLAUDE_INGEST_MAX_RESPONSE_SIZE = 16 * 1024
CLAUDE_INGEST_REQUEST_TIMEOUT = httpx.Timeout(2.0, connect=1.0)
CLAUDE_INGEST_TOTAL_TIMEOUT = 3.0
# Bound the complete inbound body read, including slow/chunked clients.
CLAUDE_INGEST_BODY_TIMEOUT = 2.0
CLAUDE_INGEST_SECRET_MAX_BYTES = 4096
CLAUDE_INGEST_SECRET_MIN_LENGTH = 32
CLAUDE_INGEST_SECRET_MAX_LENGTH = 256
CLAUDE_INGEST_SECRET_FILENAME = "claude-ingest.secret"

ALLOWED_TAILSCALE_LOGIN = _required_tailscale_login()

# Upstream configuration for read-only data endpoints
USAGE_UPSTREAM = os.environ.get("LIFEOS_USAGE_UPSTREAM", "http://127.0.0.1:8787/api/usage")
FINANCE_UPSTREAM = os.environ.get("LIFEOS_FINANCE_UPSTREAM", "http://127.0.0.1:8787/api/finance/summary")
CLIPPER_UPSTREAM = os.environ.get("LIFEOS_CLIPPER_UPSTREAM", "http://127.0.0.1:8787/api/clipper/summary")
if not _is_allowed_upstream(USAGE_UPSTREAM, "/api/usage"):
    raise RuntimeError("LIFEOS_USAGE_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(FINANCE_UPSTREAM, "/api/finance/summary"):
    raise RuntimeError("LIFEOS_FINANCE_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(CLIPPER_UPSTREAM, "/api/clipper/summary"):
    raise RuntimeError("LIFEOS_CLIPPER_UPSTREAM must be an exact loopback HTTP endpoint")
# Maximum response size from upstream (1 MB)
USAGE_MAX_RESPONSE_SIZE = 1 * 1024 * 1024
# Strict per-operation timeout plus an outer wall-clock deadline.
USAGE_REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
USAGE_TOTAL_TIMEOUT = 6.0
CLIPPER_MAX_RESPONSE_SIZE = 1 * 1024 * 1024
CLIPPER_REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
CLIPPER_TOTAL_TIMEOUT = 6.0
DOCUMENT_MAX_UPLOAD_SIZE = int(os.environ.get("LIFEOS_DOCUMENT_MAX_UPLOAD_SIZE", 64 * 1024 * 1024))
DOCUMENT_READ_CHUNK_SIZE = 1024 * 1024
DOCUMENT_ALLOWED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".heic"}

# Sensitive keys that must not appear in the usage payload
SENSITIVE_KEYS = {
    "token", "secret", "password", "credential", "account", "email",
    "workspace", "thread", "prompt", "path", "home", "user", "credit"
}
SENSITIVE_VALUE_PATTERN = re.compile(
    r"(?:bearer\s+\S+|-----BEGIN\s+[^-]*PRIVATE KEY-----|"
    r"(?:sk|ghp|github_pat)_[A-Za-z0-9_-]{12,}|"
    r"[A-Za-z]:\\Users\\[^\\\s]+|/Users/[^/\s]+/|"
    r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,})",
    re.IGNORECASE,
)
USAGE_MAX_STRUCTURE_DEPTH = 32
USAGE_MAX_STRUCTURE_NODES = 10_000

calendar_lock = asyncio.Lock()
documents_lock = asyncio.Lock()
calendar_revision = 0
documents_revision = 0

app = FastAPI(title="LifeOS Sync Server")
app.router.redirect_slashes = False


@app.middleware("http")
async def require_tailscale_identity(request: Request, call_next):
    path = request.scope.get("path")
    if path != "/health":
        login = _tailscale_login_from_raw_headers(request.scope.get("headers", []))
        if login != ALLOWED_TAILSCALE_LOGIN:
            response = JSONResponse(
                {"detail": "Invalid or missing Tailscale identity"},
                status_code=403,
            )
            if path in {"/usage/claude-ingest", "/usage/claude-ingest/"}:
                response.headers["Cache-Control"] = "no-store"
            return response
    response = await call_next(request)
    if path in {"/usage/claude-ingest", "/usage/claude-ingest/"}:
        response.headers["Cache-Control"] = "no-store"
    return response


class ChangeBroadcaster:
    """Push-only fan-out so clients don't have to poll. Costs ~nothing while idle:
    connections just sit parked until a write happens, no timers, no background loop."""

    def __init__(self) -> None:
        self._sockets: set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def register(self, ws: WebSocket) -> None:
        async with self._lock:
            self._sockets.add(ws)

    async def unregister(self, ws: WebSocket) -> None:
        async with self._lock:
            self._sockets.discard(ws)

    async def broadcast(self, message: dict) -> None:
        async with self._lock:
            targets = list(self._sockets)
        dead: list[WebSocket] = []
        for ws in targets:
            try:
                await ws.send_json(message)
            except Exception:
                dead.append(ws)
        if dead:
            async with self._lock:
                for ws in dead:
                    self._sockets.discard(ws)


broadcaster = ChangeBroadcaster()


CONNECTOR_STATES = {"healthy", "refresh_due", "reauth_required", "revoked", "rate_limited", "unavailable"}
PROVIDERS = {"codex", "claude", "glm", "deepseek", "google_ai_studio"}
WINDOW_DURATIONS = {"five_hour": 300, "seven_day": 10080}


def _is_number(value) -> bool:
    return not isinstance(value, bool) and isinstance(value, (int, float)) and math.isfinite(value)


def _is_choice(value, choices) -> bool:
    return isinstance(value, str) and value in choices


def _is_iso8601(value) -> bool:
    if not isinstance(value, str):
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.tzinfo is not None
    except ValueError:
        return False


def _is_usage_observed_timestamp(value) -> bool:
    """Validate a Usage observed timestamp and reject values over 5s ahead."""
    if not _is_iso8601(value):
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return parsed.timestamp() <= datetime.now(timezone.utc).timestamp() + 5.0
    except (OverflowError, OSError, ValueError):
        return False


def _contains_sensitive(obj) -> bool:
    pending = [(obj, 0)]
    visited = 0
    while pending:
        value, depth = pending.pop()
        visited += 1
        if depth > USAGE_MAX_STRUCTURE_DEPTH or visited > USAGE_MAX_STRUCTURE_NODES:
            return True
        if isinstance(value, dict):
            for key, child in value.items():
                if isinstance(key, str) and any(term in key.lower() for term in SENSITIVE_KEYS):
                    return True
                pending.append((child, depth + 1))
        elif isinstance(value, list):
            pending.extend((child, depth + 1) for child in value)
        elif isinstance(value, str) and SENSITIVE_VALUE_PATTERN.search(value):
            return True
    return False


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON object key")
        result[key] = value
    return result


def _reject_nonfinite_constant(value):
    raise ValueError("non-finite JSON number")


def _is_finite_number(value) -> bool:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except (OverflowError, TypeError):
        return False


def _ingest_secret_path() -> Path:
    """Return the one allowed secret location; callers must not override it."""
    return Path(DATA_DIR) / CLAUDE_INGEST_SECRET_FILENAME


def _validated_ingest_secret(value: bytes) -> str | None:
    if not value or len(value) > CLAUDE_INGEST_SECRET_MAX_BYTES:
        return None
    try:
        secret = value.decode("ascii")
    except UnicodeDecodeError:
        return None
    if not CLAUDE_INGEST_SECRET_MIN_LENGTH <= len(secret) <= CLAUDE_INGEST_SECRET_MAX_LENGTH:
        return None
    if any(ord(char) < 0x21 or ord(char) > 0x7E for char in secret):
        return None
    return secret


def _read_ingest_secret() -> str | None:
    path = _ingest_secret_path()
    descriptor: int | None = None
    try:
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode):
            return None
        if os.name == "posix" and stat.S_IMODE(before.st_mode) & 0o077:
            return None
        nofollow = getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(path, os.O_RDONLY | nofollow)
        after = os.fstat(descriptor)
        if (
            not stat.S_ISREG(after.st_mode)
            or stat.S_ISLNK(after.st_mode)
            or (os.name == "posix" and stat.S_IMODE(after.st_mode) & 0o077)
            or (after.st_dev, after.st_ino, after.st_size)
            != (before.st_dev, before.st_ino, before.st_size)
        ):
            return None
        value = os.read(descriptor, CLAUDE_INGEST_SECRET_MAX_BYTES + 1)
    except (OSError, ValueError):
        return None
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    return _validated_ingest_secret(value)


CLAUDE_INGEST_WINDOWS = {"five_hour", "seven_day"}
CLAUDE_INGEST_FIELDS = {"used_percentage", "resets_at"}


def _sanitize_claude_ingest_payload(data: object) -> dict:
    """Reconstruct the tiny allowlisted statusline envelope; never proxy source bytes."""
    if not isinstance(data, dict) or not set(data).issubset({"rate_limits"}):
        raise ValueError("unexpected JSON field")
    limits = data.get("rate_limits", {})
    if not isinstance(limits, dict) or not set(limits).issubset(CLAUDE_INGEST_WINDOWS):
        raise ValueError("invalid rate_limits")
    sanitized: dict[str, dict[str, int | float]] = {}
    for window, value in limits.items():
        if not isinstance(value, dict) or not set(value).issubset(CLAUDE_INGEST_FIELDS):
            raise ValueError("unexpected rate-limit field")
        clean: dict[str, int | float] = {}
        if "used_percentage" in value:
            used = value["used_percentage"]
            if not _is_finite_number(used) or not 0 <= used <= 100:
                raise ValueError("invalid used percentage")
            clean["used_percentage"] = used
        if "resets_at" in value:
            reset = value["resets_at"]
            if not _is_finite_number(reset) or reset <= 0:
                raise ValueError("invalid reset timestamp")
            clean["resets_at"] = reset
        if clean:
            sanitized[window] = clean
    return {"rate_limits": sanitized}


def _validate_provenance(value) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "source", "observedAt", "freshness", "official", "quality", "connectorState"
    }:
        return False
    return (
        isinstance(value["source"], str) and bool(value["source"])
        and _is_usage_observed_timestamp(value["observedAt"])
        and _is_choice(value["freshness"], {"fresh", "stale", "unknown"})
        and isinstance(value["official"], bool)
        and _is_choice(value["quality"], {"observed", "estimated", "unavailable"})
        and _is_choice(value["connectorState"], CONNECTOR_STATES)
    )


def _validate_window(value) -> bool:
    if not isinstance(value, dict):
        return False
    required = {"provider", "window", "durationMinutes", "availability", "provenance"}
    if not required.issubset(value) or not set(value).issubset(required | {"usedPercent", "resetAt"}):
        return False
    if not _is_choice(value["provider"], PROVIDERS) or not _is_choice(value["window"], WINDOW_DURATIONS):
        return False
    if isinstance(value["durationMinutes"], bool) or value["durationMinutes"] != WINDOW_DURATIONS[value["window"]]:
        return False
    if not _is_choice(value["availability"], {"observed", "unavailable"}) or not _validate_provenance(value["provenance"]):
        return False
    provenance = value["provenance"]
    if "resetAt" in value and not _is_iso8601(value["resetAt"]):
        return False
    if value["availability"] == "unavailable":
        return (
            "usedPercent" not in value
            and "resetAt" not in value
            and provenance["official"] is False
            and provenance["quality"] == "unavailable"
            and provenance["connectorState"] not in {"healthy", "refresh_due"}
        )
    if "usedPercent" not in value or not _is_number(value["usedPercent"]):
        return False
    used = value["usedPercent"]
    if not 0 <= used <= 100 or not provenance["official"] or provenance["quality"] != "observed":
        return False
    expected_freshness = "fresh"
    try:
        observed_at = datetime.fromisoformat(provenance["observedAt"].replace("Z", "+00:00"))
        age_seconds = datetime.now(timezone.utc).timestamp() - observed_at.timestamp()
        if age_seconds < -5.0:
            expected_freshness = "unknown"
        elif age_seconds > 15 * 60:
            expected_freshness = "stale"
    except (OverflowError, OSError, ValueError):
        expected_freshness = "unknown"
    expected_connector = (
        "refresh_due" if expected_freshness == "stale"
        else "rate_limited" if used >= 100
        else "healthy"
    )
    return (
        expected_freshness != "unknown"
        and provenance["freshness"] == expected_freshness
        and provenance["connectorState"] == expected_connector
    )


def _validate_estimate(value) -> bool:
    if not isinstance(value, dict):
        return False
    required = {"provider", "window", "confidence", "sampleSpanHours", "explanation", "official"}
    optional = {"projectedPercentAtReset", "estimatedExhaustionAt", "velocityPercentPerHour"}
    if not required.issubset(value) or not set(value).issubset(required | optional):
        return False
    if not _is_choice(value["provider"], PROVIDERS) or not _is_choice(value["window"], WINDOW_DURATIONS):
        return False
    if not _is_choice(value["confidence"], {"low", "medium", "high", "insufficient"}):
        return False
    if not _is_number(value["sampleSpanHours"]) or value["sampleSpanHours"] < 0:
        return False
    if not isinstance(value["explanation"], str) or value["official"] is not False:
        return False
    if "projectedPercentAtReset" in value:
        projected = value["projectedPercentAtReset"]
        if not _is_number(projected) or not 0 <= projected <= 100:
            return False
    if "velocityPercentPerHour" in value:
        velocity = value["velocityPercentPerHour"]
        if not _is_number(velocity) or velocity < 0:
            return False
    if "estimatedExhaustionAt" in value and not _is_iso8601(value["estimatedExhaustionAt"]):
        return False
    return True


def _validate_usage_payload(data: dict) -> bool:
    """Validate the shared usage contract and reject any sensitive or extra fields."""
    if not isinstance(data, dict) or set(data) != {"generatedAt", "windows", "estimates", "connectors"}:
        return False
    if _contains_sensitive(data) or not _is_usage_observed_timestamp(data["generatedAt"]):
        return False
    if not isinstance(data["windows"], list) or not all(_validate_window(item) for item in data["windows"]):
        return False
    if not isinstance(data["estimates"], list) or not all(_validate_estimate(item) for item in data["estimates"]):
        return False
    window_keys = [(item["provider"], item["window"]) for item in data["windows"]]
    if len(window_keys) != len(set(window_keys)):
        return False
    estimate_keys = [(item["provider"], item["window"]) for item in data["estimates"]]
    if len(estimate_keys) != len(set(estimate_keys)):
        return False
    connectors = data["connectors"]
    return (
        isinstance(connectors, dict)
        and set(connectors) == PROVIDERS
        and all(_is_choice(state, CONNECTOR_STATES) for state in connectors.values())
    )


FINANCE_MAX_SAFE_CENTS = 9_007_199_254_740_991
FINANCE_MAX_CLOCK_SKEW = timedelta(seconds=5)
FINANCE_STALE_AFTER = timedelta(minutes=15)
FINANCE_DATETIME_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)
FINANCE_METRICS = {
    "monthlyIncome", "fixedCosts", "discretionaryBuffer", "spent", "savingsGoal", "saved"
}
FINANCE_PROVENANCE_FIELDS = {
    "source", "observedAt", "freshness", "quality", "connectorState"
}
FINANCE_ACCOUNT_FIELDS = {
    "id", "name", "detail", "balanceCents", "source", "provenance"
}
FINANCE_ACCOUNT_SNAPSHOT_FIELDS = {"availability", "accounts", "provenance"}
FINANCE_TRANSACTION_FIELDS = {
    "id", "merchant", "title", "signedAmountCents", "timestamp",
    "account", "source", "category", "provenance"
}
FINANCE_TRANSACTION_SNAPSHOT_FIELDS = {"availability", "transactions", "provenance"}
FINANCE_DERIVED_ACCOUNT_SOURCE = "derived-account-snapshot"
FINANCE_DERIVED_TRANSACTION_SOURCE = "derived-transaction-snapshot"


def _contains_sensitive_finance(obj) -> bool:
    """Apply value scanning without treating the reviewed `account` fields as secrets.

    Exact allowlists below reject unknown/sensitive fields; this scan still rejects
    secret-bearing values and pathological structures.
    """
    pending = [(obj, 0)]
    visited = 0
    safe_account_keys = {"account", "accounts"}
    while pending:
        value, depth = pending.pop()
        visited += 1
        if depth > USAGE_MAX_STRUCTURE_DEPTH or visited > USAGE_MAX_STRUCTURE_NODES:
            return True
        if isinstance(value, dict):
            for key, child in value.items():
                if (
                    isinstance(key, str)
                    and key not in safe_account_keys
                    and any(term in key.lower() for term in SENSITIVE_KEYS)
                ):
                    return True
                pending.append((child, depth + 1))
        elif isinstance(value, list):
            pending.extend((child, depth + 1) for child in value)
        elif isinstance(value, str) and SENSITIVE_VALUE_PATTERN.search(value):
            return True
    return False


def _parse_finance_timestamp(value):
    if not isinstance(value, str) or not FINANCE_DATETIME_PATTERN.fullmatch(value):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except (AttributeError, OverflowError, OSError, TypeError, ValueError):
        return None
    return parsed if parsed.tzinfo is not None else None


def _is_finance_observed_timestamp(value) -> bool:
    parsed = _parse_finance_timestamp(value)
    if parsed is None:
        return False
    try:
        return parsed <= datetime.now(timezone.utc) + FINANCE_MAX_CLOCK_SKEW
    except (OverflowError, OSError, TypeError, ValueError):
        return False


def _expected_finance_observed_pair(value):
    observed_at = _parse_finance_timestamp(value.get("observedAt")) if isinstance(value, dict) else None
    if observed_at is None:
        return None
    try:
        age = datetime.now(timezone.utc) - observed_at
    except (OverflowError, OSError, TypeError, ValueError):
        return None
    if age < -FINANCE_MAX_CLOCK_SKEW:
        return None
    return ("fresh", "healthy") if age <= FINANCE_STALE_AFTER else ("stale", "refresh_due")


def _validate_finance_provenance(value, *, observed: bool, age_consistent: bool = False) -> bool:
    if not isinstance(value, dict) or set(value) != FINANCE_PROVENANCE_FIELDS:
        return False
    if (
        not isinstance(value["source"], str)
        or not value["source"].strip()
        or not _is_finance_observed_timestamp(value["observedAt"])
    ):
        return False
    if observed:
        if (
            value["quality"] != "observed"
            or not _is_choice(value["freshness"], {"fresh", "stale"})
            or not _is_choice(value["connectorState"], {"healthy", "refresh_due"})
        ):
            return False
        if not age_consistent:
            return True
        expected = _expected_finance_observed_pair(value)
        return expected is not None and (value["freshness"], value["connectorState"]) == expected
    return (
        value["quality"] == "unavailable"
        and _is_choice(value["freshness"], {"unknown"})
        and _is_choice(value["connectorState"], CONNECTOR_STATES - {"healthy", "refresh_due"})
    )


def _validate_finance_observed_provenance(value, *, age_consistent: bool = True) -> bool:
    return _validate_finance_provenance(value, observed=True, age_consistent=age_consistent)


def _validate_finance_metric(value) -> bool:
    if not isinstance(value, dict) or not _is_choice(value.get("availability"), {"observed", "unavailable"}):
        return False
    observed = value["availability"] == "observed"
    expected = {"availability", "provenance", "amountCents"} if observed else {"availability", "provenance"}
    if set(value) != expected or not _validate_finance_provenance(
        value.get("provenance"), observed=observed, age_consistent=observed
    ):
        return False
    return not observed or (
        isinstance(value["amountCents"], int)
        and not isinstance(value["amountCents"], bool)
        and 0 <= value["amountCents"] <= FINANCE_MAX_SAFE_CENTS
    )


def _validate_finance_account_observation(value) -> bool:
    if not isinstance(value, dict) or set(value) != FINANCE_ACCOUNT_FIELDS:
        return False
    text_fields = ("id", "name", "detail", "source")
    if not all(isinstance(value[field], str) and value[field].strip() for field in text_fields):
        return False
    provenance = value.get("provenance")
    if not isinstance(provenance, dict):
        return False
    return (
        isinstance(value["balanceCents"], int)
        and not isinstance(value["balanceCents"], bool)
        and -FINANCE_MAX_SAFE_CENTS <= value["balanceCents"] <= FINANCE_MAX_SAFE_CENTS
        and _validate_finance_observed_provenance(provenance, age_consistent=True)
        and value["source"] == provenance["source"]
    )


def _validate_finance_account_snapshot(value) -> bool:
    if not isinstance(value, dict) or not _is_choice(value.get("availability"), {"observed", "unavailable"}):
        return False
    provenance = value.get("provenance")
    if value["availability"] == "unavailable":
        return (
            set(value) == {"availability", "provenance"}
            and _validate_finance_provenance(provenance, observed=False)
        )
    if set(value) != FINANCE_ACCOUNT_SNAPSHOT_FIELDS or not isinstance(value.get("accounts"), list):
        return False
    accounts = value["accounts"]
    if not accounts or not _validate_finance_observed_provenance(provenance, age_consistent=False):
        return False
    if not all(_validate_finance_account_observation(account) for account in accounts):
        return False
    snapshot_observed_at = _parse_finance_timestamp(provenance["observedAt"])
    if snapshot_observed_at is None:
        return False
    account_observed_at = [
        _parse_finance_timestamp(account["provenance"]["observedAt"])
        for account in accounts
    ]
    if any(observed_at is None or observed_at > snapshot_observed_at for observed_at in account_observed_at):
        return False
    account_sources = {account["source"] for account in accounts}
    if not (
        len(account_sources) == 1 and next(iter(account_sources)) == provenance["source"]
        or provenance["source"] == FINANCE_DERIVED_ACCOUNT_SOURCE
    ):
        return False
    has_stale_account = any(
        account["provenance"]["freshness"] == "stale"
        or account["provenance"]["connectorState"] == "refresh_due"
        for account in accounts
    )
    expected = ("stale", "refresh_due") if has_stale_account else ("fresh", "healthy")
    return (provenance["freshness"], provenance["connectorState"]) == expected


def _validate_finance_transaction_observation(value) -> bool:
    if not isinstance(value, dict) or set(value) != FINANCE_TRANSACTION_FIELDS:
        return False
    text_fields = ("id", "merchant", "title", "account", "source", "category")
    if not all(isinstance(value[field], str) and value[field].strip() for field in text_fields):
        return False
    provenance = value.get("provenance")
    if not isinstance(provenance, dict) or not _validate_finance_observed_provenance(provenance, age_consistent=True):
        return False
    return (
        isinstance(value["signedAmountCents"], int)
        and not isinstance(value["signedAmountCents"], bool)
        and -FINANCE_MAX_SAFE_CENTS <= value["signedAmountCents"] <= FINANCE_MAX_SAFE_CENTS
        and _is_finance_observed_timestamp(value["timestamp"])
        and value["source"] == provenance["source"]
    )


def _validate_finance_transaction_snapshot(value) -> bool:
    if not isinstance(value, dict) or not _is_choice(value.get("availability"), {"observed", "unavailable"}):
        return False
    provenance = value.get("provenance")
    if value["availability"] == "unavailable":
        return (
            set(value) == {"availability", "provenance"}
            and _validate_finance_provenance(provenance, observed=False)
        )
    if set(value) != FINANCE_TRANSACTION_SNAPSHOT_FIELDS or not isinstance(value.get("transactions"), list):
        return False
    rows = value["transactions"]
    if not _validate_finance_observed_provenance(provenance, age_consistent=not rows):
        return False
    if not all(_validate_finance_transaction_observation(row) for row in rows):
        return False
    row_sources = {row["source"] for row in rows}
    if row_sources and not (
        len(row_sources) == 1 and next(iter(row_sources)) == provenance["source"]
        or provenance["source"] == FINANCE_DERIVED_TRANSACTION_SOURCE
    ):
        return False
    if rows:
        has_stale_row = any(
            row["provenance"]["freshness"] == "stale"
            or row["provenance"]["connectorState"] == "refresh_due"
            for row in rows
        )
        expected = ("stale", "refresh_due") if has_stale_row else ("fresh", "healthy")
        if (provenance["freshness"], provenance["connectorState"]) != expected:
            return False
        envelope_observed_at = _parse_finance_timestamp(provenance["observedAt"])
        row_observed_at = [
            _parse_finance_timestamp(row["provenance"]["observedAt"])
            for row in rows
        ]
        if envelope_observed_at is None or any(observed_at is None for observed_at in row_observed_at):
            return False
        if envelope_observed_at < max(row_observed_at):
            return False
    return True


def _validate_finance_payload(data: dict) -> bool:
    allowed = {"generatedAt", "currency"} | FINANCE_METRICS | {"accounts", "transactions"}
    if (
        not isinstance(data, dict)
        or not set(data).issubset(allowed)
        or not {"generatedAt", "currency"}.issubset(data)
        or not FINANCE_METRICS.issubset(data)
    ):
        return False
    return (
        not _contains_sensitive_finance(data)
        and _is_finance_observed_timestamp(data["generatedAt"])
        and data["currency"] == "EUR"
        and all(_validate_finance_metric(data[key]) for key in FINANCE_METRICS)
        and ("accounts" not in data or data["accounts"] is None or _validate_finance_account_snapshot(data["accounts"]))
        and ("transactions" not in data or data["transactions"] is None or _validate_finance_transaction_snapshot(data["transactions"]))
    )


_CLIPPER_SNAPSHOT_FIELDS = {
    "schemaVersion", "availability", "generatedAt", "currency", "provenance"
}
_CLIPPER_PROVENANCE_FIELDS = {
    "source", "observedAt", "freshness", "quality", "connectorState"
}
_CLIPPER_DATETIME_PATTERN = re.compile(
    r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$"
)


def _is_clipper_observed_timestamp(value) -> bool:
    """Match the contract's offset ISO timestamp and five-second future bound."""
    if not isinstance(value, str) or not _CLIPPER_DATETIME_PATTERN.fullmatch(value):
        return False
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return False
    if parsed.tzinfo is None:
        return False
    try:
        return parsed.timestamp() <= datetime.now(timezone.utc).timestamp() + 5.0
    except (OverflowError, OSError, ValueError):
        return False


def _validate_clipper_unavailable_snapshot(data: object) -> bool:
    """Accept only the unavailable branch of the reviewed Clipper contract.

    Observed metrics, accounts, trends, and breakdowns intentionally remain
    outside this gateway's accepted surface until a connector is separately
    reviewed.  Reconstructing the exact unavailable shape also prevents an
    otherwise-valid-looking payload from carrying unreviewed sibling fields.
    """
    if not isinstance(data, dict) or set(data) != _CLIPPER_SNAPSHOT_FIELDS:
        return False
    if _contains_sensitive(data):
        return False
    if (
        isinstance(data["schemaVersion"], bool)
        or data["schemaVersion"] != 1
        or data["availability"] != "unavailable"
        or data["currency"] != "EUR"
        or not _is_clipper_observed_timestamp(data["generatedAt"])
    ):
        return False

    provenance = data["provenance"]
    if not isinstance(provenance, dict) or set(provenance) != _CLIPPER_PROVENANCE_FIELDS:
        return False
    connector_state = provenance["connectorState"]
    return (
        isinstance(provenance["source"], str)
        and bool(provenance["source"].strip())
        and _is_clipper_observed_timestamp(provenance["observedAt"])
        and provenance["freshness"] == "unknown"
        and provenance["quality"] == "unavailable"
        and _is_choice(connector_state, CONNECTOR_STATES - {"healthy", "refresh_due"})
    )


enable_banking = EnableBankingService(
    data_dir=lambda: DATA_DIR,
    validate_finance_payload=_validate_finance_payload,
    max_safe_cents=FINANCE_MAX_SAFE_CENTS,
)


async def _read_bounded_finance_request(request: Request) -> bytes:
    """Read the only mutating finance request without accepting an unbounded body."""
    raw_length = request.headers.get("content-length")
    if raw_length is not None:
        try:
            content_length = int(raw_length)
        except ValueError as exc:
            raise ValueError("invalid content length") from exc
        if content_length < 0 or content_length > enable_banking.BODY_LIMIT:
            raise ValueError("finance request too large")
    body = bytearray()
    async for chunk in request.stream():
        if len(body) + len(chunk) > enable_banking.BODY_LIMIT:
            raise ValueError("finance request too large")
        body.extend(chunk)
    return bytes(body)


def _finance_consent_response(payload: dict, status_code: int) -> JSONResponse:
    return JSONResponse(payload, status_code=status_code, headers={"Cache-Control": "no-store"})


def _finance_callback_page(linked: bool) -> Response:
    message = "Connected — you can close this page." if linked else "Connection failed — you can close this page."
    body = "<html><body><script>window.close()</script>" + message + "</body></html>"
    return Response(
        content=body.encode("utf-8"),
        media_type="text/html; charset=utf-8",
        headers={"Cache-Control": "no-store"},
    )


@app.post("/finance/connect")
async def post_finance_connect(request: Request) -> Response:
    try:
        body = await _read_bounded_finance_request(request)
        payload = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
    except (TimeoutError, OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return _finance_consent_response({"error": "invalid_request"}, 400)
    institution_id = payload.get("institutionId") if isinstance(payload, dict) else None
    if (
        not isinstance(payload, dict)
        or set(payload) != {"institutionId"}
        or not isinstance(institution_id, str)
    ):
        return _finance_consent_response({"error": "invalid_request"}, 400)
    status_code, result = await enable_banking.start(institution_id)
    return _finance_consent_response(result, status_code)


@app.get("/finance/connect/status/{connection_id}")
async def get_finance_connect_status(connection_id: str) -> Response:
    result = await enable_banking.status(connection_id)
    return _finance_consent_response(result, 400 if "error" in result else 200)


@app.get("/finance/callback")
async def get_finance_callback(request: Request) -> Response:
    result = await enable_banking.callback(request.url.query)
    if not result.valid:
        return _finance_consent_response({"error": "invalid_request"}, 400)
    return _finance_callback_page(result.linked)


@app.websocket("/ws")
async def ws_changes(websocket: WebSocket) -> None:
    identity = _tailscale_login_from_raw_headers(websocket.scope.get("headers", []))
    if identity != ALLOWED_TAILSCALE_LOGIN:
        await websocket.close(code=4403)
        return
    await websocket.accept()
    await broadcaster.register(websocket)
    try:
        while True:
            # No client->server messages are expected; this just detects disconnects.
            await websocket.receive_text()
    except WebSocketDisconnect:
        pass
    finally:
        await broadcaster.unregister(websocket)


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    tmp.write_bytes(data)
    os.replace(tmp, path)  # atomic on Windows (ReplaceFileW) and POSIX


def _safe_document_id(value) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise HTTPException(status_code=400, detail="metadata.id must be a UUID") from exc


async def _read_bounded_upload(file: UploadFile) -> bytes:
    body = bytearray()
    while chunk := await file.read(DOCUMENT_READ_CHUNK_SIZE):
        if len(body) + len(chunk) > DOCUMENT_MAX_UPLOAD_SIZE:
            raise HTTPException(status_code=413, detail="Document exceeds upload limit")
        body.extend(chunk)
    return bytes(body)


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/calendar")
async def get_calendar() -> Response:
    async with calendar_lock:
        if not CALENDAR_PATH.exists():
            body = b"{}"
        else:
            body = CALENDAR_PATH.read_bytes()
        return Response(
            content=body,
            media_type="application/json",
            headers={"X-LifeOS-Revision": str(calendar_revision)},
        )


@app.put("/calendar")
async def put_calendar(request: Request) -> Response:
    body = await request.body()
    try:
        json.loads(body)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail=f"Body is not valid JSON: {exc}") from exc
    global calendar_revision
    async with calendar_lock:
        _atomic_write_bytes(CALENDAR_PATH, body)
        calendar_revision += 1
        revision = calendar_revision
    await broadcaster.broadcast({"type": "calendar_changed", "revision": revision})
    return Response(
        content=b'{"status":"ok"}',
        media_type="application/json",
        headers={"X-LifeOS-Revision": str(revision)},
    )


@app.get("/documents")
async def list_documents() -> Response:
    async with documents_lock:
        if not DOCUMENTS_INDEX_PATH.exists():
            body = b"[]"
        else:
            body = DOCUMENTS_INDEX_PATH.read_bytes()
        return Response(content=body, media_type="application/json")


@app.post("/documents")
async def upload_document(
    file: UploadFile = File(...),
    metadata: str = Form(...),
) -> JSONResponse:
    """`metadata` is the client's TaxDocument JSON (must include an `id` field)."""
    try:
        meta = json.loads(metadata)
    except json.JSONDecodeError as exc:
        raise HTTPException(status_code=400, detail=f"metadata is not valid JSON: {exc}") from exc
    if not isinstance(meta, dict):
        raise HTTPException(status_code=400, detail="metadata must be a JSON object")
    raw_doc_id = meta.get("id")
    if not raw_doc_id:
        raise HTTPException(status_code=400, detail="metadata.id is required")
    doc_id = _safe_document_id(raw_doc_id)
    meta["id"] = doc_id

    original_bytes = await _read_bounded_upload(file)
    candidate_suffix = Path(file.filename or "").suffix.lower()
    suffix = candidate_suffix if candidate_suffix in DOCUMENT_ALLOWED_EXTENSIONS else ".bin"

    global documents_revision
    async with documents_lock:
        doc_dir = DOCUMENTS_DIR / doc_id
        doc_dir.mkdir(parents=True, exist_ok=True)
        destination = doc_dir / f"original{suffix}"
        _atomic_write_bytes(destination, original_bytes)
        for prior in doc_dir.glob("original.*"):
            if prior != destination:
                prior.unlink(missing_ok=True)

        index = []
        if DOCUMENTS_INDEX_PATH.exists():
            try:
                decoded_index = json.loads(DOCUMENTS_INDEX_PATH.read_bytes())
                if isinstance(decoded_index, list):
                    index = [entry for entry in decoded_index if isinstance(entry, dict)]
            except json.JSONDecodeError:
                index = []
        index = [entry for entry in index if entry.get("id") != doc_id]
        meta["_originalFile"] = f"original{suffix}"
        index.append(meta)
        _atomic_write_bytes(DOCUMENTS_INDEX_PATH, json.dumps(index, sort_keys=True).encode())
        documents_revision += 1
        revision = documents_revision

    await broadcaster.broadcast({"type": "documents_changed", "revision": revision})
    return JSONResponse({"status": "ok", "id": doc_id})


@app.get("/documents/{doc_id}/file")
async def get_document_file(doc_id: str) -> Response:
    safe_id = _safe_document_id(doc_id)
    async with documents_lock:
        doc_dir = DOCUMENTS_DIR / safe_id
        if not doc_dir.exists():
            raise HTTPException(status_code=404, detail="Unknown document id")
        candidates = sorted(path for path in doc_dir.glob("original.*") if path.is_file())
        if not candidates:
            raise HTTPException(status_code=404, detail="Original file missing")
        selected = candidates[0]
        if selected.stat().st_size > DOCUMENT_MAX_UPLOAD_SIZE:
            raise HTTPException(status_code=413, detail="Document exceeds retrieval limit")
        body = selected.read_bytes()
        if len(body) > DOCUMENT_MAX_UPLOAD_SIZE:
            raise HTTPException(status_code=413, detail="Document exceeds retrieval limit")
    media_type = mimetypes.guess_type(selected.name)[0] or "application/octet-stream"
    return Response(content=body, media_type=media_type)


async def _proxy_validated_json(
    upstream_url: str,
    validator,
    error_label: str,
    *,
    max_response_size: int | None = None,
    request_timeout: httpx.Timeout | None = None,
    total_timeout: float | None = None,
) -> Response:
    max_response_size = USAGE_MAX_RESPONSE_SIZE if max_response_size is None else max_response_size
    request_timeout = USAGE_REQUEST_TIMEOUT if request_timeout is None else request_timeout
    total_timeout = USAGE_TOTAL_TIMEOUT if total_timeout is None else total_timeout
    error = json.dumps({"error": f"{error_label} unavailable"}, separators=(",", ":")).encode()
    try:
        async with asyncio.timeout(total_timeout):
            async with httpx.AsyncClient(
                timeout=request_timeout,
                follow_redirects=False,
                trust_env=False,
            ) as client:
                async with client.stream("GET", upstream_url) as upstream:
                    if upstream.status_code != 200:
                        return Response(content=error, media_type="application/json", status_code=503)
                    content_length = upstream.headers.get("content-length")
                    if content_length is not None:
                        declared_length = int(content_length)
                        if declared_length < 0 or declared_length > max_response_size:
                            return Response(content=error, media_type="application/json", status_code=503)
                    body = bytearray()
                    async for chunk in upstream.aiter_bytes():
                        if len(body) + len(chunk) > max_response_size:
                            return Response(content=error, media_type="application/json", status_code=503)
                        body.extend(chunk)
                    upstream_data = json.loads(body, object_pairs_hook=_reject_duplicate_keys)
                    if not validator(upstream_data):
                        return Response(content=error, media_type="application/json", status_code=503)
                    canonical = json.dumps(
                        upstream_data, sort_keys=True, separators=(",", ":"), allow_nan=False
                    ).encode()
                    return Response(content=canonical, media_type="application/json", headers={"Cache-Control": "no-store"})
    except Exception:
        return Response(content=error, media_type="application/json", status_code=503)


class _ClaudeIngestRequestError(Exception):
    def __init__(self, status_code: int) -> None:
        self.status_code = status_code


async def _read_claude_ingest_body(request: Request) -> bytes:
    try:
        async with asyncio.timeout(CLAUDE_INGEST_BODY_TIMEOUT):
            raw_length = request.headers.get("content-length")
            if raw_length is not None:
                try:
                    content_length = int(raw_length)
                except ValueError as exc:
                    raise _ClaudeIngestRequestError(400) from exc
                if content_length < 0 or content_length > CLAUDE_INGEST_MAX_BODY_SIZE:
                    raise _ClaudeIngestRequestError(413)
            body = bytearray()
            async for chunk in request.stream():
                if len(body) + len(chunk) > CLAUDE_INGEST_MAX_BODY_SIZE:
                    raise _ClaudeIngestRequestError(413)
                body.extend(chunk)
            return bytes(body)
    except TimeoutError as exc:
        raise _ClaudeIngestRequestError(408) from exc


def _claude_ingest_input_error(status_code: int) -> JSONResponse:
    error = "request_too_large" if status_code == 413 else "request_timeout" if status_code == 408 else "invalid_request"
    return JSONResponse({"error": error}, status_code=status_code)


async def _proxy_claude_ingest(request: Request) -> Response:
    if request.headers.get("content-type", "").lower().split(";", 1)[0].strip() != "application/json":
        return JSONResponse({"error": "invalid_request"}, status_code=415)
    secret = _read_ingest_secret()
    if secret is None:
        return JSONResponse({"error": "ingest_unavailable"}, status_code=503)
    try:
        body = await _read_claude_ingest_body(request)
        parsed = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
        sanitized = _sanitize_claude_ingest_payload(parsed)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return _claude_ingest_input_error(400)
    except _ClaudeIngestRequestError as exc:
        return _claude_ingest_input_error(exc.status_code)

    observed = any("used_percentage" in window for window in sanitized["rate_limits"].values())
    if not observed:
        return JSONResponse({"error": "usage_unavailable"}, status_code=422)
    forwarded = json.dumps(sanitized, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    try:
        async with asyncio.timeout(CLAUDE_INGEST_TOTAL_TIMEOUT):
            async with httpx.AsyncClient(
                timeout=CLAUDE_INGEST_REQUEST_TIMEOUT,
                follow_redirects=False,
                trust_env=False,
            ) as client:
                async with client.stream(
                    "POST",
                    CLAUDE_INGEST_UPSTREAM,
                    content=forwarded,
                    headers={
                        "Authorization": f"Bearer {secret}",
                        "Content-Type": "application/json",
                    },
                ) as upstream:
                    if not 200 <= upstream.status_code < 300:
                        return JSONResponse({"error": "ingest_unavailable"}, status_code=502)
                    content_length = upstream.headers.get("content-length")
                    if content_length is not None:
                        try:
                            declared_length = int(content_length)
                        except (TypeError, ValueError):
                            return JSONResponse({"error": "ingest_unavailable"}, status_code=502)
                        if declared_length < 0 or declared_length > CLAUDE_INGEST_MAX_RESPONSE_SIZE:
                            return JSONResponse({"error": "ingest_unavailable"}, status_code=502)
                    response_size = 0
                    async for chunk in upstream.aiter_bytes():
                        response_size += len(chunk)
                        if response_size > CLAUDE_INGEST_MAX_RESPONSE_SIZE:
                            return JSONResponse({"error": "ingest_unavailable"}, status_code=502)
    except Exception:
        return JSONResponse({"error": "ingest_unavailable"}, status_code=502)
    return Response(status_code=204)


@app.get("/usage")
async def get_usage() -> Response:
    return await _proxy_validated_json(USAGE_UPSTREAM, _validate_usage_payload, "usage")


@app.get("/finance/summary")
async def get_finance_summary() -> Response:
    try:
        payload = await enable_banking.refresh_summary()
    except Exception:
        payload = enable_banking.load_cached_summary()
        if payload is None:
            return _finance_consent_response({"error": "finance unavailable"}, 503)
    return _finance_consent_response(payload, 200)


@app.get("/clipper/summary")
async def get_clipper_summary() -> Response:
    return await _proxy_validated_json(
        CLIPPER_UPSTREAM,
        _validate_clipper_unavailable_snapshot,
        "clipper",
        max_response_size=CLIPPER_MAX_RESPONSE_SIZE,
        request_timeout=CLIPPER_REQUEST_TIMEOUT,
        total_timeout=CLIPPER_TOTAL_TIMEOUT,
    )


@app.post("/usage/claude-ingest")
async def post_claude_ingest(request: Request) -> Response:
    return await _proxy_claude_ingest(request)
