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
import base64
import binascii
import json
import hashlib
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
from supplement_catalog import SupplementCatalogInvalidQuery, SupplementCatalogService, SupplementCatalogUnavailable


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
SUPPLEMENT_CATALOG_PATH = Path(os.environ.get("LIFEOS_SUPPLEMENT_CATALOG_PATH", DATA_DIR / "supplements.sqlite3"))
supplement_catalog = SupplementCatalogService(SUPPLEMENT_CATALOG_PATH)

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
NUTRITION_BARCODE_UPSTREAM = os.environ.get(
    "LIFEOS_NUTRITION_BARCODE_UPSTREAM",
    "http://127.0.0.1:8787/api/nutrition/barcode",
)
NUTRITION_PHOTO_UPSTREAM = os.environ.get(
    "LIFEOS_NUTRITION_PHOTO_UPSTREAM",
    "http://127.0.0.1:8787/api/nutrition/photo-proposal",
)
if not _is_allowed_upstream(USAGE_UPSTREAM, "/api/usage"):
    raise RuntimeError("LIFEOS_USAGE_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(FINANCE_UPSTREAM, "/api/finance/summary"):
    raise RuntimeError("LIFEOS_FINANCE_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(CLIPPER_UPSTREAM, "/api/clipper/summary"):
    raise RuntimeError("LIFEOS_CLIPPER_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(NUTRITION_BARCODE_UPSTREAM, "/api/nutrition/barcode"):
    raise RuntimeError("LIFEOS_NUTRITION_BARCODE_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(NUTRITION_PHOTO_UPSTREAM, "/api/nutrition/photo-proposal"):
    raise RuntimeError("LIFEOS_NUTRITION_PHOTO_UPSTREAM must be an exact loopback HTTP endpoint")
# Maximum response size from upstream (1 MB)
USAGE_MAX_RESPONSE_SIZE = 1 * 1024 * 1024
# Strict per-operation timeout plus an outer wall-clock deadline.
USAGE_REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
USAGE_TOTAL_TIMEOUT = 6.0
CLIPPER_MAX_RESPONSE_SIZE = 1 * 1024 * 1024
CLIPPER_REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
CLIPPER_TOTAL_TIMEOUT = 6.0
NUTRITION_PHOTO_MAX_BODY_SIZE = 30 * 1024 * 1024
NUTRITION_PHOTO_MAX_RESPONSE_SIZE = 1 * 1024 * 1024
NUTRITION_PHOTO_MAX_IMAGE_BYTES = 20 * 1024 * 1024
NUTRITION_PHOTO_MAX_IMAGE_COUNT = 3
NUTRITION_PHOTO_MAX_IMAGE_DIMENSION = 12_000
NUTRITION_PHOTO_MAX_IMAGE_PIXELS = 40_000_000
NUTRITION_PHOTO_REQUEST_TIMEOUT = httpx.Timeout(40.0, connect=2.0)
NUTRITION_PHOTO_TOTAL_TIMEOUT = 45.0
NUTRITION_PHOTO_BODY_TIMEOUT = 45.0
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
CLAUDE_INGEST_OBSERVED_HEADER = "x-observed-at"


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


def _validate_clipper_provenance(value: object, *, top_level: bool) -> bool:
    if not isinstance(value, dict) or set(value) != _CLIPPER_PROVENANCE_FIELDS:
        return False
    if (
        not isinstance(value["source"], str)
        or not value["source"].strip()
        or not _is_clipper_observed_timestamp(value["observedAt"])
    ):
        return False
    if value["quality"] == "unavailable":
        return (
            value["freshness"] == "unknown"
            and value["connectorState"] not in {"healthy", "refresh_due"}
        )
    allowed_quality = {"observed", "partial"} if top_level else {"observed"}
    if value["quality"] not in allowed_quality or value["freshness"] not in {"fresh", "stale"}:
        return False
    try:
        observed_at = datetime.fromisoformat(value["observedAt"].replace("Z", "+00:00"))
        age = datetime.now(timezone.utc) - observed_at
    except (OverflowError, OSError, ValueError):
        return False
    expected_freshness = "fresh" if age <= timedelta(minutes=15) else "stale"
    expected_connector = "healthy" if expected_freshness == "fresh" else "refresh_due"
    return value["freshness"] == expected_freshness and value["connectorState"] == expected_connector


def _validate_clipper_metric(value: object, *, revenue: bool) -> bool:
    if not isinstance(value, dict) or "availability" not in value or "provenance" not in value:
        return False
    if value["availability"] == "unavailable":
        expected = {"availability", "provenance"} | ({"currency"} if revenue else set())
        return set(value) == expected and (not revenue or value["currency"] == "EUR") and _validate_clipper_provenance(value["provenance"], top_level=False)
    if value["availability"] != "observed":
        return False
    expected = {"availability", "provenance", "amountCents", "currency"} if revenue else {"availability", "provenance", "value"}
    if set(value) != expected or not _validate_clipper_provenance(value["provenance"], top_level=False):
        return False
    amount = value["amountCents"] if revenue else value["value"]
    return (
        isinstance(amount, int)
        and not isinstance(amount, bool)
        and 0 <= amount <= FINANCE_MAX_SAFE_CENTS
        and (not revenue or value["currency"] == "EUR")
    )


def _validate_clipper_metrics(value: object) -> bool:
    return (
        isinstance(value, dict)
        and set(value) == {"views", "subscribers", "revenue"}
        and _validate_clipper_metric(value["views"], revenue=False)
        and _validate_clipper_metric(value["subscribers"], revenue=False)
        and _validate_clipper_metric(value["revenue"], revenue=True)
    )


def _validate_clipper_breakdown(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"id", "label", "periodStart", "periodEnd", "metrics"}:
        return False
    if (
        not isinstance(value["id"], str) or not value["id"].strip()
        or not isinstance(value["label"], str) or not value["label"].strip()
        or not _is_iso8601(value["periodStart"]) or not _is_iso8601(value["periodEnd"])
        or not _validate_clipper_metrics(value["metrics"])
    ):
        return False
    try:
        return datetime.fromisoformat(value["periodEnd"].replace("Z", "+00:00")) > datetime.fromisoformat(value["periodStart"].replace("Z", "+00:00"))
    except (OverflowError, OSError, ValueError):
        return False


def _validate_clipper_bot(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"id", "name", "metrics", "breakdowns"}:
        return False
    if not isinstance(value["id"], str) or not value["id"].strip() or not isinstance(value["name"], str) or not value["name"].strip() or not _validate_clipper_metrics(value["metrics"]):
        return False
    breakdowns = value["breakdowns"]
    return isinstance(breakdowns, list) and all(_validate_clipper_breakdown(item) for item in breakdowns) and len({item["id"] for item in breakdowns}) == len(breakdowns)


def _validate_clipper_account(value: object) -> bool:
    if not isinstance(value, dict) or set(value) != {"id", "name", "metrics", "bots", "breakdowns"}:
        return False
    if not isinstance(value["id"], str) or not value["id"].strip() or not isinstance(value["name"], str) or not value["name"].strip() or not _validate_clipper_metrics(value["metrics"]):
        return False
    bots = value["bots"]
    breakdowns = value["breakdowns"]
    return (
        isinstance(bots, list) and all(_validate_clipper_bot(item) for item in bots)
        and len({item["id"] for item in bots}) == len(bots)
        and isinstance(breakdowns, list) and all(_validate_clipper_breakdown(item) for item in breakdowns)
        and len({item["id"] for item in breakdowns}) == len(breakdowns)
    )


def _clipper_metric_is_observed(metrics: dict) -> bool:
    return any(metrics[key].get("availability") == "observed" for key in ("views", "subscribers", "revenue"))


def _validate_clipper_unavailable_snapshot(data: object) -> bool:
    """Validate the unavailable branch of the shared Clipper contract."""
    if not isinstance(data, dict) or set(data) != _CLIPPER_SNAPSHOT_FIELDS:
        return False
    if _contains_sensitive_finance(data):
        return False
    if (
        isinstance(data["schemaVersion"], bool)
        or data["schemaVersion"] != 1
        or data["availability"] != "unavailable"
        or data["currency"] != "EUR"
        or not _is_clipper_observed_timestamp(data["generatedAt"])
    ):
        return False

    return _validate_clipper_provenance(data["provenance"], top_level=True)


def _validate_clipper_observed_snapshot(data: object) -> bool:
    if not isinstance(data, dict) or set(data) != {
        "schemaVersion", "availability", "generatedAt", "currency", "metrics",
        "accounts", "trends", "breakdowns", "provenance",
    }:
        return False
    if _contains_sensitive_finance(data) or data["schemaVersion"] != 1 or isinstance(data["schemaVersion"], bool) or data["availability"] != "observed" or data["currency"] != "EUR" or not _is_clipper_observed_timestamp(data["generatedAt"]):
        return False
    if not _validate_clipper_provenance(data["provenance"], top_level=True) or not _validate_clipper_metrics(data["metrics"]):
        return False
    accounts = data["accounts"]
    trends = data["trends"]
    breakdowns = data["breakdowns"]
    if not isinstance(accounts, list) or not all(_validate_clipper_account(item) for item in accounts) or len({item["id"] for item in accounts}) != len(accounts):
        return False
    if not isinstance(breakdowns, list) or not all(_validate_clipper_breakdown(item) for item in breakdowns) or len({item["id"] for item in breakdowns}) != len(breakdowns):
        return False
    if not isinstance(trends, list):
        return False
    for trend in trends:
        if not isinstance(trend, dict) or set(trend) != {"at", "metrics"} or not _is_clipper_observed_timestamp(trend["at"]) or not _validate_clipper_metrics(trend["metrics"]):
            return False
    has_detail = _clipper_metric_is_observed(data["metrics"]) or any(
        _clipper_metric_is_observed(account["metrics"])
        or any(_clipper_metric_is_observed(bot["metrics"]) or any(_clipper_metric_is_observed(item["metrics"]) for item in bot["breakdowns"]) for bot in account["bots"])
        or any(_clipper_metric_is_observed(item["metrics"]) for item in account["breakdowns"])
        for account in accounts
    )
    if not has_detail:
        return False

    generated = datetime.fromisoformat(data["generatedAt"].replace("Z", "+00:00"))
    timestamps = [data["provenance"]["observedAt"]]
    def add_metrics(metrics: dict) -> None:
        timestamps.extend(metrics[key]["provenance"]["observedAt"] for key in ("views", "subscribers", "revenue"))
    add_metrics(data["metrics"])
    for account in accounts:
        add_metrics(account["metrics"])
        for bot in account["bots"]:
            add_metrics(bot["metrics"])
            for item in bot["breakdowns"]: add_metrics(item["metrics"])
        for item in account["breakdowns"]: add_metrics(item["metrics"])
    for trend in trends:
        timestamps.append(trend["at"])
        add_metrics(trend["metrics"])
    for item in breakdowns: add_metrics(item["metrics"])
    try:
        return all(datetime.fromisoformat(value.replace("Z", "+00:00")) <= generated + timedelta(seconds=5) for value in timestamps)
    except (OverflowError, OSError, ValueError):
        return False


def _validate_clipper_snapshot(data: object) -> bool:
    if isinstance(data, dict) and data.get("availability") == "unavailable":
        return _validate_clipper_unavailable_snapshot(data)
    if isinstance(data, dict) and data.get("availability") == "observed":
        return _validate_clipper_observed_snapshot(data)
    return False


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


def _finance_consent_response(payload: dict, status_code: int) -> Response:
    """Return a compact Finance envelope within the native client's bound."""
    try:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        body = b'{"error":"finance unavailable"}'
        status_code = 503
    if len(body) > EnableBankingService.MAX_FINANCE_SUMMARY_SIZE:
        body = b'{"error":"finance unavailable"}'
        status_code = 503
    return Response(
        content=body,
        status_code=status_code,
        media_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


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
                    upstream_data = json.loads(
                        body,
                        object_pairs_hook=_reject_duplicate_keys,
                        parse_constant=_reject_nonfinite_constant,
                    )
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

    observed_header = request.headers.get(CLAUDE_INGEST_OBSERVED_HEADER)
    observed_at = None
    if observed_header is not None:
        if not isinstance(observed_header, str) or len(observed_header) > 64:
            return _claude_ingest_input_error(400)
        try:
            parsed_observed_at = datetime.fromisoformat(observed_header.replace("Z", "+00:00"))
            if parsed_observed_at.tzinfo is None or parsed_observed_at > datetime.now(timezone.utc) + timedelta(seconds=5):
                return _claude_ingest_input_error(400)
            observed_at = parsed_observed_at.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")
        except (TypeError, ValueError, OverflowError):
            return _claude_ingest_input_error(400)
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
                        **({"X-Observed-At": observed_at} if observed_at is not None else {}),
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


class _NutritionPhotoRequestError(Exception):
    def __init__(self, status_code: int) -> None:
        self.status_code = status_code


async def _read_nutrition_photo_body(request: Request) -> bytes:
    try:
        async with asyncio.timeout(NUTRITION_PHOTO_BODY_TIMEOUT):
            raw_length = request.headers.get("content-length")
            if raw_length is not None:
                try:
                    content_length = int(raw_length)
                except ValueError as exc:
                    raise _NutritionPhotoRequestError(400) from exc
                if content_length < 0 or content_length > NUTRITION_PHOTO_MAX_BODY_SIZE:
                    raise _NutritionPhotoRequestError(413)
            body = bytearray()
            async for chunk in request.stream():
                if len(body) + len(chunk) > NUTRITION_PHOTO_MAX_BODY_SIZE:
                    raise _NutritionPhotoRequestError(413)
                body.extend(chunk)
            return bytes(body)
    except TimeoutError as exc:
        raise _NutritionPhotoRequestError(408) from exc


def _photo_lineage(manifest: object) -> tuple[str, str, list[dict[str, str]]] | None:
    """Validate the photo bytes at the trusted gateway boundary.

    The client supplies a manifest for provenance, but its claimed digest,
    length, and MIME type are not trusted. Recompute those values here before
    forwarding any image to the provider. This keeps a forged manifest from
    binding a different byte payload to an apparently valid proposal.
    """
    if not isinstance(manifest, dict):
        return None
    meal_id = manifest.get("mealID")
    request_id = manifest.get("requestID")
    images = manifest.get("images")
    if (
        not isinstance(meal_id, str)
        or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})?", meal_id)
        or not isinstance(request_id, str)
        or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})?", request_id)
        or not isinstance(images, list)
        or not 1 <= len(images) <= NUTRITION_PHOTO_MAX_IMAGE_COUNT
    ):
        return None
    hashes: list[dict[str, str]] = []
    seen: set[str] = set()
    total_bytes = 0
    for image in images:
        if not isinstance(image, dict):
            return None
        image_id = image.get("imageID")
        mime_type = image.get("mimeType")
        byte_length = image.get("byteLength")
        encoded = image.get("inlineDataBase64")
        digest = image.get("sha256")
        if (
            not isinstance(image_id, str)
            or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})?", image_id)
            or mime_type not in {"image/jpeg", "image/png", "image/heic", "image/webp"}
            or image.get("sanitized") is not True
            or isinstance(byte_length, bool)
            or not isinstance(byte_length, int)
            or not 1 <= byte_length <= NUTRITION_PHOTO_MAX_IMAGE_BYTES
            or not isinstance(encoded, str)
            or not encoded
            or not isinstance(digest, str)
            or not re.fullmatch(r"[A-Fa-f0-9]{64}", digest)
            or image_id in seen
        ):
            return None
        try:
            decoded = base64.b64decode(encoded, validate=True)
        except (ValueError, binascii.Error):
            return None
        if (
            base64.b64encode(decoded).decode("ascii") != encoded
            or len(decoded) != byte_length
            or hashlib.sha256(decoded).hexdigest() != digest.casefold()
            or not _nutrition_photo_magic_matches(mime_type, decoded)
        ):
            return None
        width = image.get("width")
        height = image.get("height")
        if (
            isinstance(width, bool)
            or not isinstance(width, int)
            or not 1 <= width <= NUTRITION_PHOTO_MAX_IMAGE_DIMENSION
            or isinstance(height, bool)
            or not isinstance(height, int)
            or not 1 <= height <= NUTRITION_PHOTO_MAX_IMAGE_DIMENSION
            or width * height > NUTRITION_PHOTO_MAX_IMAGE_PIXELS
        ):
            return None
        total_bytes += byte_length
        if total_bytes > NUTRITION_PHOTO_MAX_IMAGE_BYTES:
            return None
        seen.add(image_id)
        hashes.append({"imageID": image_id, "sha256": digest.lower()})
    return meal_id, request_id, hashes


def _nutrition_photo_magic_matches(mime_type: str, data: bytes) -> bool:
    if mime_type == "image/jpeg":
        return data.startswith(b"\xff\xd8\xff")
    if mime_type == "image/png":
        return data.startswith(b"\x89PNG\r\n\x1a\n")
    if mime_type == "image/webp":
        return len(data) >= 12 and data[:4] == b"RIFF" and data[8:12] == b"WEBP"
    if mime_type == "image/heic":
        if len(data) < 12 or data[4:8] != b"ftyp":
            return False
        brands = [data[8:12]]
        brands.extend(data[index:index + 4] for index in range(16, len(data) - 3, 4))
        return any(brand in {b"heic", b"heix", b"hevc", b"hevx", b"mif1", b"msf1"} for brand in brands)
    return False


def _validate_nutrition_photo_proposal(data: object, lineage: tuple[str, str, list[dict[str, str]]]) -> bool:
    """Validate the response envelope before it leaves the private gateway.

    The Node adapter performs the complete contract validation. This second,
    intentionally small check prevents a misconfigured upstream from
    returning a different request's proposal or an arbitrary JSON document.
    """
    if not isinstance(data, dict):
        return False
    allowed = {
        "schemaVersion", "mealID", "proposalID", "requestID", "state",
        "generatedAt", "provenance", "items", "totals", "flags", "uncertaintyNotes",
    }
    if set(data) != allowed:
        return False
    if (
        data.get("schemaVersion") != 1
        or data.get("mealID") != lineage[0]
        or data.get("requestID") != lineage[1]
        or data.get("state") != "needs_confirmation"
        or not isinstance(data.get("items"), list)
        or not data["items"]
        or not isinstance(data.get("totals"), dict)
        or not isinstance(data.get("flags"), list)
        or "needs_confirmation" not in data["flags"]
    ):
        return False
    provenance = data.get("provenance")
    if not isinstance(provenance, dict):
        return False
    if set(provenance) != {
        "provider", "modelIdentifier", "modelVersion", "policyVersion",
        "requestTimestamp", "sanitizedImageHashes",
    }:
        return False
    received_hashes = provenance.get("sanitizedImageHashes")
    if received_hashes != lineage[2]:
        return False
    if _contains_sensitive({"proposal": data}):
        return False
    return True


def _is_valid_nutrition_barcode(value: object) -> bool:
    if not isinstance(value, str) or not re.fullmatch(r"(?:\d{8}|\d{13})", value):
        return False
    check_digit = int(value[-1])
    total = 0
    weight = 3
    for character in reversed(value[:-1]):
        total += int(character) * weight
        weight = 1 if weight == 3 else 3
    return (10 - (total % 10)) % 10 == check_digit


def _validate_nutrition_barcode_provenance(value: object) -> bool:
    required = {
        "source", "apiVersion", "apiURL", "fetchedAt", "databaseLicense",
        "contentLicense", "attribution", "dataQualityWarning",
    }
    if not isinstance(value, dict) or not required.issubset(value) or not set(value).issubset(required | {"productURL"}):
        return False
    if (
        value["source"] != "openfoodfacts"
        or value["apiVersion"] != "v3.6"
        or value["databaseLicense"] != "ODbL-1.0"
        or value["contentLicense"] != "DbCL-1.0"
        or value["dataQualityWarning"] != "Open Food Facts data is volunteer-sourced; accuracy, completeness, and reliability are not guaranteed."
        or not isinstance(value["attribution"], str)
        or not 1 <= len(value["attribution"]) <= 500
        or not _is_usage_observed_timestamp(value["fetchedAt"])
    ):
        return False
    for key in ("apiURL", "productURL"):
        if key not in value:
            continue
        if not isinstance(value[key], str) or len(value[key]) > 2_048:
            return False
        try:
            parsed = urlsplit(value[key])
        except ValueError:
            return False
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            return False
    return True


def _validate_nutrition_barcode_macros(value: object, *, per_100g: bool) -> bool:
    if not isinstance(value, dict):
        return False
    allowed = {"kcal", "proteinGrams", "carbsGrams", "fatGrams"}
    if not set(value).issubset(allowed) or not value:
        return False
    for key, number in value.items():
        maximum = 1_000 if per_100g and key == "kcal" else 100 if per_100g else 5_000 if key == "kcal" else 2_000
        if not _is_number(number) or number < 0 or number > maximum:
            return False
    return True


def _validate_nutrition_barcode_payload(data: object, expected_barcode: str) -> bool:
    if not isinstance(data, dict) or data.get("schemaVersion") != 1 or data.get("barcode") != expected_barcode:
        return False
    if not _validate_nutrition_barcode_provenance(data.get("provenance")):
        return False
    state = data.get("state")
    common = {"schemaVersion", "barcode", "provenance", "state"}
    if state == "not_found":
        return set(data) == common
    if state == "unavailable":
        if not set(data).issubset(common | {"reason", "retryAfterSeconds"}) or data.get("reason") not in {
            "upstream_timeout", "upstream_rate_limited", "upstream_unavailable",
            "upstream_redirect", "upstream_oversized", "invalid_response", "configuration_unavailable",
        }:
            return False
        retry_after = data.get("retryAfterSeconds")
        return retry_after is None or (
            isinstance(retry_after, int) and not isinstance(retry_after, bool) and 0 <= retry_after <= 3_600
        )
    if state != "found" or not set(data).issubset(common | {
        "product", "nutritionState", "per100g", "perServing", "qualityFlags"
    }):
        return False
    product = data.get("product")
    if not isinstance(product, dict) or not set(product).issubset({
        "name", "brand", "quantity", "servingSize", "countriesTags"
    }):
        return False
    for key in ("name", "brand", "quantity", "servingSize"):
        if key in product and (not isinstance(product[key], str) or not 1 <= len(product[key].strip()) <= 240):
            return False
    if "countriesTags" in product:
        tags = product["countriesTags"]
        if not isinstance(tags, list) or len(tags) > 50 or not all(
            isinstance(tag, str) and 1 <= len(tag.strip()) <= 120 for tag in tags
        ):
            return False
    per_100g = data.get("per100g")
    per_serving = data.get("perServing")
    if per_100g is None and per_serving is None:
        has_nutrition = False
    else:
        has_nutrition = True
        if per_100g is not None and not _validate_nutrition_barcode_macros(per_100g, per_100g=True):
            return False
        if per_serving is not None and not _validate_nutrition_barcode_macros(per_serving, per_100g=False):
            return False
    flags = data.get("qualityFlags", [])
    if not isinstance(flags, list) or len(flags) > 2 or len(set(flags)) != len(flags) or not all(
        flag in {"provider_quality_error", "provider_quality_warning"} for flag in flags
    ):
        return False
    nutrition_state = data.get("nutritionState")
    if nutrition_state not in {"complete", "partial", "unreliable", "unavailable"}:
        return False
    complete_basis = any(
        isinstance(basis, dict)
        and {"kcal", "proteinGrams", "carbsGrams", "fatGrams"}.issubset(basis)
        for basis in (per_100g, per_serving)
    )
    if nutrition_state == "unavailable":
        return not has_nutrition and not flags
    if not has_nutrition:
        return False
    if nutrition_state == "complete":
        return complete_basis and not flags
    if nutrition_state == "partial":
        return not complete_basis and not flags
    return nutrition_state == "unreliable" and bool(flags)


@app.get("/nutrition/barcode/{barcode}")
async def get_nutrition_barcode(barcode: str) -> Response:
    """Proxy the normalized barcode contract through the authenticated gateway."""
    if not _is_valid_nutrition_barcode(barcode):
        return JSONResponse({"error": "invalid_barcode"}, status_code=400)
    upstream_url = f"{NUTRITION_BARCODE_UPSTREAM}/{barcode}"
    return await _proxy_validated_json(
        upstream_url,
        lambda payload: _validate_nutrition_barcode_payload(payload, barcode),
        "nutrition",
        max_response_size=256 * 1024,
        request_timeout=httpx.Timeout(5.0, connect=2.0),
        total_timeout=6.0,
    )


@app.post("/nutrition/photo-proposal")
async def post_nutrition_photo_proposal(request: Request) -> Response:
    if request.headers.get("content-type", "").lower().split(";", 1)[0].strip() != "application/json":
        return JSONResponse({"error": "invalid_request"}, status_code=415)
    try:
        body = await _read_nutrition_photo_body(request)
        manifest = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
        lineage = _photo_lineage(manifest)
        if lineage is None:
            raise _NutritionPhotoRequestError(400)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return JSONResponse({"error": "invalid_request"}, status_code=400)
    except _NutritionPhotoRequestError as exc:
        error = "request_too_large" if exc.status_code == 413 else "request_timeout" if exc.status_code == 408 else "invalid_request"
        return JSONResponse({"error": error}, status_code=exc.status_code)

    try:
        async with asyncio.timeout(NUTRITION_PHOTO_TOTAL_TIMEOUT):
            async with httpx.AsyncClient(
                timeout=NUTRITION_PHOTO_REQUEST_TIMEOUT,
                follow_redirects=False,
                trust_env=False,
            ) as client:
                async with client.stream(
                    "POST",
                    NUTRITION_PHOTO_UPSTREAM,
                    content=body,
                    headers={"Content-Type": "application/json"},
                ) as upstream:
                    if upstream.status_code != 200:
                        return JSONResponse({"error": "nutrition_unavailable"}, status_code=503)
                    content_length = upstream.headers.get("content-length")
                    if content_length is not None:
                        try:
                            declared_length = int(content_length)
                        except (TypeError, ValueError):
                            return JSONResponse({"error": "nutrition_unavailable"}, status_code=502)
                        if declared_length < 0 or declared_length > NUTRITION_PHOTO_MAX_RESPONSE_SIZE:
                            return JSONResponse({"error": "nutrition_unavailable"}, status_code=502)
                    response_body = bytearray()
                    async for chunk in upstream.aiter_bytes():
                        if len(response_body) + len(chunk) > NUTRITION_PHOTO_MAX_RESPONSE_SIZE:
                            return JSONResponse({"error": "nutrition_unavailable"}, status_code=502)
                        response_body.extend(chunk)
                    proposal = json.loads(
                        response_body,
                        object_pairs_hook=_reject_duplicate_keys,
                        parse_constant=_reject_nonfinite_constant,
                    )
                    if not _validate_nutrition_photo_proposal(proposal, lineage):
                        return JSONResponse({"error": "nutrition_unavailable"}, status_code=502)
                    canonical = json.dumps(proposal, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
                    return Response(
                        content=canonical,
                        media_type="application/json",
                        headers={"Cache-Control": "no-store"},
                    )
    except Exception:
        return JSONResponse({"error": "nutrition_unavailable"}, status_code=503)


@app.get("/supplements/catalog")
async def get_supplement_catalog(request: Request) -> Response:
    """Search the Windows reference catalog without exposing SQLite itself."""
    try:
        payload = supplement_catalog.search(
            request.query_params.get("q"),
            request.query_params.get("limit"),
        )
    except SupplementCatalogInvalidQuery:
        return JSONResponse({"error": "invalid_request"}, status_code=400)
    except SupplementCatalogUnavailable:
        return JSONResponse({"error": "supplement_catalog_unavailable"}, status_code=503)
    return Response(
        content=json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode(),
        media_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


@app.get("/usage")
async def get_usage() -> Response:
    return await _proxy_validated_json(USAGE_UPSTREAM, _validate_usage_payload, "usage")


@app.get("/finance/summary")
async def get_finance_summary() -> Response:
    try:
        payload = await enable_banking.refresh_summary()
    except Exception:
        # Never relabel a prior observation as a fresh HTTP 200 response after
        # a failed refresh. The existing contract has no explicit partial
        # state, so this boundary fails closed until a tested stale-envelope
        # transformation is introduced.
        return _finance_consent_response({"error": "finance unavailable"}, 503)
    return _finance_consent_response(payload, 200)


@app.get("/clipper/summary")
async def get_clipper_summary() -> Response:
    return await _proxy_validated_json(
        CLIPPER_UPSTREAM,
        _validate_clipper_snapshot,
        "clipper",
        max_response_size=CLIPPER_MAX_RESPONSE_SIZE,
        request_timeout=CLIPPER_REQUEST_TIMEOUT,
        total_timeout=CLIPPER_TOTAL_TIMEOUT,
    )


@app.post("/usage/claude-ingest")
async def post_claude_ingest(request: Request) -> Response:
    return await _proxy_claude_ingest(request)
