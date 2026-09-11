"""LifeOS sync server.

Stores the LifeOS app's Calendar snapshot and Tax documents as opaque JSON
blobs, exactly as the Swift app encodes them (iso8601 dates, sorted keys).
Calendar item shape is validated here before authority changes; item merge
semantics remain in the Swift client (CalendarSnapshot.merged in
ios/Shared/CalendarDomain.swift), which pushes an already-merged snapshot.
This service is deliberately a dumb, authoritative store reachable over the
Tailscale tailnet, not a second place that re-implements merge semantics.

Run:
    python -m venv venv
    venv\\\\Scripts\\\\pip install --require-hashes -r requirements.lock
    set LIFEOS_TAILSCALE_ALLOWED_LOGIN=<exact tailnet login>
    set LIFEOS_TAILSCALE_EDGE_TOKEN=<random edge-only capability>
    venv\\\\Scripts\\\\python -m uvicorn main:app --host 127.0.0.1 --port 8421

The Python backend binds only to loopback (127.0.0.1:8421); private Tailscale
Serve terminates HTTPS and forwards to it. The reviewed Windows launcher also
proves that the exact loopback connection is owned by the Tailscale SCM
service before it injects the private edge header. Never bind this backend to
0.0.0.0: calendar and tax-document data must stay unreachable without the
Serve layer and its OS-bound local hop.
"""
import asyncio
import base64
import binascii
import errno
import json
import hashlib
import hmac
import inspect
import math
import mimetypes
import os
import re
import stat
import tempfile
import uuid
import zlib
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import BinaryIO, Callable
from urllib.parse import urlsplit

import httpx
import python_multipart as multipart
from python_multipart.exceptions import MultipartParseError
from python_multipart.multipart import parse_options_header
from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, JSONResponse, Response
from starlette.requests import ClientDisconnect

from enablebanking import (
    EnableBankingService,
    EnableBankingUnavailable,
    ProtectedStorageOverloaded,
    ProtectedStorageUnavailable,
    assert_protected_storage_path,
    run_protected_storage,
    validate_windows_acl_sddl,
)
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


TAILSCALE_EDGE_CAPABILITY_HEADER = b"x-lifeos-trusted-edge"
TAILSCALE_EDGE_TOKEN_ENV = "LIFEOS_TAILSCALE_EDGE_TOKEN"
LIFEOS_ALLOWED_HOSTS_ENV = "LIFEOS_ALLOWED_HOSTS"
TAILSCALE_EDGE_TOKEN_MIN_LENGTH = 32
TAILSCALE_EDGE_TOKEN_MAX_LENGTH = 256


def _configured_tailscale_edge_token() -> str | None:
    """Return a valid out-of-band edge capability, or fail closed.

    Tailscale Serve's identity header is authoritative only at the Serve
    boundary. Once Serve forwards to a loopback listener, a local process can
    forge that header. The capability is therefore injected by the reviewed
    launcher only after its Windows SCM/TCP owner proof succeeds and is never
    accepted directly from the phone. Keeping an invalid or missing value as
    ``None`` leaves ``/health`` useful for diagnostics while protected routes
    remain unavailable.
    """
    value = os.environ.get(TAILSCALE_EDGE_TOKEN_ENV)
    if value is None or not TAILSCALE_EDGE_TOKEN_MIN_LENGTH <= len(value) <= TAILSCALE_EDGE_TOKEN_MAX_LENGTH:
        return None
    if any(not 0x21 <= ord(char) <= 0x7E for char in value):
        return None
    return value


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


def _tailscale_edge_capability_from_raw_headers(headers) -> str | None:
    """Read exactly one trusted-edge capability without header collapsing."""
    values = [
        value for name, value in headers
        if isinstance(name, bytes) and name.lower() == TAILSCALE_EDGE_CAPABILITY_HEADER
    ]
    if len(values) != 1:
        return None
    try:
        value = values[0].decode("ascii")
    except UnicodeDecodeError:
        return None
    if not TAILSCALE_EDGE_TOKEN_MIN_LENGTH <= len(value) <= TAILSCALE_EDGE_TOKEN_MAX_LENGTH:
        return None
    if any(not 0x21 <= ord(char) <= 0x7E for char in value):
        return None
    return value


def _request_has_allowed_tailscale_identity(scope) -> bool:
    """Authorize only the canonical Serve identity on the trusted edge path.

    Authorization, Tailscale-User-Name, and generic forwarded-user headers are
    intentionally not identity sources. A canonical login header by itself is
    not sufficient because direct loopback callers can forge it; the trusted
    edge capability must be present in a separate, exact single header too.
    """
    headers = scope.get("headers", [])
    login = _tailscale_login_from_raw_headers(headers)
    capability = _tailscale_edge_capability_from_raw_headers(headers)
    return (
        login == ALLOWED_TAILSCALE_LOGIN
        and LIFEOS_TAILSCALE_EDGE_TOKEN is not None
        and capability is not None
        and hmac.compare_digest(capability, LIFEOS_TAILSCALE_EDGE_TOKEN)
    )


def _scope_header_values(scope, name: str) -> list[bytes]:
    wanted = name.lower().encode("ascii")
    return [
        value for header, value in scope.get("headers", [])
        if isinstance(header, bytes)
        and isinstance(value, bytes)
        and header.lower() == wanted
    ]


_HOST_LABEL_PATTERN = re.compile(r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")


def _canonical_host_header(value: object) -> str | None:
    """Canonicalize one HTTP Host value without accepting ambiguous syntax."""
    if not isinstance(value, str) or not value or len(value) > 512 or value != value.strip():
        return None
    if any(ord(char) < 0x21 or ord(char) == 0x7F for char in value) or any(
        char in ",/\\?#@" for char in value
    ):
        return None
    try:
        parsed = urlsplit(f"//{value}")
        port = parsed.port
    except (TypeError, ValueError):
        return None
    hostname = parsed.hostname
    if (
        not hostname
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or parsed.username is not None
        or parsed.password is not None
        or hostname.endswith(".")
    ):
        return None
    try:
        hostname = hostname.encode("idna").decode("ascii").casefold()
    except UnicodeError:
        return None
    if not all(_HOST_LABEL_PATTERN.fullmatch(label) for label in hostname.split(".")):
        return None
    if port is None:
        return hostname
    if not 1 <= port <= 65535:
        return None
    return f"{hostname}:{port}"


def _configured_allowed_hosts() -> frozenset[str]:
    """Read the launcher-owned exact Host contract.

    A missing contract leaves the app usable by the synthetic TestClient host
    used by the local unit suite only; the reviewed Windows launcher always
    installs a single hostname:Serve-port value before importing this module.
    A real loopback listener with no contract therefore rejects every Host.
    """
    raw = os.environ.get(LIFEOS_ALLOWED_HOSTS_ENV)
    if raw is None:
        return frozenset()
    values = raw.split(",")
    if not values or any(not value for value in values):
        raise RuntimeError(f"{LIFEOS_ALLOWED_HOSTS_ENV} is invalid")
    canonical = [_canonical_host_header(value) for value in values]
    if any(value is None for value in canonical) or len(set(canonical)) != len(canonical):
        raise RuntimeError(f"{LIFEOS_ALLOWED_HOSTS_ENV} is invalid")
    return frozenset(canonical)


def _request_has_allowed_host(scope) -> bool:
    values = _scope_header_values(scope, "host")
    if len(values) != 1:
        return False
    try:
        raw_value = values[0].decode("ascii")
    except UnicodeDecodeError:
        return False
    canonical = _canonical_host_header(raw_value)
    if canonical is None:
        return False
    if ALLOWED_HOSTS:
        return canonical in ALLOWED_HOSTS
    # Starlette's TestClient uses this non-network synthetic server when the
    # deployment contract is intentionally absent. No real uvicorn listener
    # can have this server tuple, so this compatibility branch cannot widen a
    # deployed route.
    server = scope.get("server")
    return canonical == "testserver" and (
        server == ("testserver", 80) or server == ["testserver", 80]
    )


def _canonical_browser_origin(value: str) -> str | None:
    """Canonicalize one exact HTTPS origin, rejecting path and credential data."""
    if not isinstance(value, str) or not value or len(value) > 512:
        return None
    try:
        parsed = urlsplit(value)
        port = parsed.port
    except (TypeError, ValueError):
        return None
    if (
        parsed.scheme.casefold() != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
        or any(ord(char) < 0x21 or ord(char) == 0x7F for char in value)
    ):
        return None
    hostname = parsed.hostname.casefold().rstrip(".")
    if not hostname:
        return None
    try:
        hostname = hostname.encode("idna").decode("ascii")
    except UnicodeError:
        return None
    if ":" in hostname:
        host = f"[{hostname}]"
    else:
        host = hostname
    if port is None or port == 443:
        return f"https://{host}"
    return f"https://{host}:{port}"


def _configured_browser_origins() -> frozenset[str]:
    """Use the configured Enable Banking redirect host as the sole web origin.

    The native app does not send an Origin header. A browser may use the
    public Tailscale Serve origin, which is already required as the exact
    Enable Banking redirect URI. No wildcard or Host-derived origin is safe.
    """
    redirect_uri = os.environ.get("ENABLE_BANKING_REDIRECT_URI")
    if not isinstance(redirect_uri, str) or not redirect_uri:
        return frozenset()
    try:
        parsed = urlsplit(redirect_uri)
        if (
            parsed.scheme.casefold() != "https"
            or not parsed.hostname
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
            or any(ord(char) < 0x21 or ord(char) == 0x7F for char in redirect_uri)
        ):
            return frozenset()
        origin = _canonical_browser_origin(
            f"https://{parsed.netloc}"
        )
    except (TypeError, ValueError):
        return frozenset()
    return frozenset({origin}) if origin is not None else frozenset()


ALLOWED_BROWSER_ORIGINS = _configured_browser_origins()
MUTATING_METHODS = frozenset({"POST", "PUT", "PATCH", "DELETE"})
CONSENT_CALLBACK_PATH = "/finance/callback"


def _is_browser_mutation_scope(scope) -> bool:
    path = scope.get("path")
    method = str(scope.get("method", "")).upper()
    return method in MUTATING_METHODS and (
        path in {"/calendar", "/documents", "/finance/connect", "/finance/imported", "/nutrition/photo-proposal", "/fitness/observation"}
        or (isinstance(path, str) and path.startswith("/finance/connect/"))
    )


def _request_has_allowed_browser_origin(scope) -> bool:
    """Reject browser cross-site requests while keeping native clients originless.

    Enable Banking returns through a provider-initiated top-level navigation;
    its callback is allowed to carry cross-site fetch metadata because the
    callback handler validates the one-time provider state before persistence.
    """
    if (
        scope.get("path") == CONSENT_CALLBACK_PATH
        and str(scope.get("method", "")).upper() == "GET"
    ):
        return True

    origin_values = _scope_header_values(scope, "origin")
    fetch_site_values = _scope_header_values(scope, "sec-fetch-site")
    if len(origin_values) > 1 or len(fetch_site_values) > 1:
        return False

    fetch_site: str | None = None
    if fetch_site_values:
        try:
            fetch_site = fetch_site_values[0].decode("ascii").casefold()
        except UnicodeDecodeError:
            return False
        if fetch_site not in {"same-origin", "same-site", "none"}:
            return False

    if not origin_values:
        return fetch_site != "cross-site"
    try:
        origin = origin_values[0].decode("ascii")
    except UnicodeDecodeError:
        return False
    canonical = _canonical_browser_origin(origin)
    return canonical is not None and canonical in ALLOWED_BROWSER_ORIGINS


def _document_transport_error(scope) -> JSONResponse | None:
    """Reject a declared oversized document request before multipart parsing."""
    if scope.get("path") != "/documents" or str(scope.get("method", "")).upper() != "POST":
        return None
    values = _scope_header_values(scope, "content-length")
    if len(values) > 1:
        return JSONResponse({"error": "invalid_request"}, status_code=400)
    if not values:
        return None
    try:
        declared_length = int(values[0].decode("ascii"))
    except (UnicodeDecodeError, ValueError):
        return JSONResponse({"error": "invalid_request"}, status_code=400)
    if declared_length < 0:
        return JSONResponse({"error": "invalid_request"}, status_code=400)
    maximum = DOCUMENT_MAX_UPLOAD_SIZE + DOCUMENT_METADATA_MAX_SIZE + DOCUMENT_MULTIPART_OVERHEAD
    if declared_length > maximum:
        return JSONResponse({"error": "request_too_large"}, status_code=413)
    return None


DATA_DIR = Path(os.environ.get("LIFEOS_DATA_DIR", Path(__file__).parent / "data"))
CALENDAR_PATH = DATA_DIR / "calendar.json"
DOCUMENTS_INDEX_PATH = DATA_DIR / "documents.json"
DOCUMENTS_DIR = DATA_DIR / "documents"
SUPPLEMENT_CATALOG_PATH = Path(os.environ.get("LIFEOS_SUPPLEMENT_CATALOG_PATH", DATA_DIR / "supplements.sqlite3"))
supplement_catalog = SupplementCatalogService(SUPPLEMENT_CATALOG_PATH)

FITNESS_OBSERVATION_SCHEMA_VERSION = 1
FITNESS_OBSERVATION_MAX_BODY_SIZE = 128 * 1024
FITNESS_OBSERVATION_MAX_RESPONSE_SIZE = 128 * 1024
FITNESS_OBSERVATION_MAX_METRICS = 32
FITNESS_OBSERVATION_MAX_DAYS = 31
FITNESS_OBSERVATION_MAX_VALUES_PER_DAY = 8
FITNESS_OBSERVATION_MAX_WORKOUTS = 64
FITNESS_OBSERVATION_STALE_AFTER = timedelta(minutes=15)
FITNESS_OBSERVATION_MAX_HISTORY = timedelta(days=31)
FITNESS_OBSERVATION_MAX_CURRENT_METRIC_AGE = timedelta(hours=48)
# HealthKit's Workout.duration is active duration and can be shorter than the
# wall-clock interval when the user pauses. One second only covers fractional
# second serialization/date rounding at the upper bound.
FITNESS_OBSERVATION_WORKOUT_DURATION_ROUNDING_TOLERANCE_SECONDS = 1.0
FITNESS_OBSERVATION_BODY_TIMEOUT = 8.0
FITNESS_OBSERVATION_PATH = DATA_DIR / "fitness-observation.json"
FITNESS_OBSERVATION_FIELDS = {
    "schemaVersion", "state", "generatedAt", "observedAt", "source", "provenance",
    "metrics", "days", "workouts",
}
FITNESS_OBSERVATION_STATES = {"observed", "stale", "unavailable", "permission_required"}
FITNESS_OBSERVATION_CURRENT_METRICS = {
    "heart_rate", "resting_heart_rate", "heart_rate_variability", "respiratory_rate",
    "oxygen_saturation", "vo2_max", "body_mass", "body_fat_percentage", "lean_body_mass",
}
FITNESS_OBSERVATION_DAILY_METRICS = {"steps", "active_energy", "water", "caffeine", "sleep_duration"}
FITNESS_OBSERVATION_UNITS = {
    "heart_rate": "bpm",
    "resting_heart_rate": "bpm",
    "heart_rate_variability": "ms",
    "respiratory_rate": "per_minute",
    "oxygen_saturation": "percent",
    "vo2_max": "ml_per_kg_min",
    "body_mass": "kg",
    "body_fat_percentage": "percent",
    "lean_body_mass": "kg",
    "steps": "count",
    "active_energy": "kcal",
    "water": "ml",
    "caffeine": "mg",
    "sleep_duration": "seconds",
}
FITNESS_OBSERVATION_VALUE_LIMITS = {
    "heart_rate": 1_000,
    "resting_heart_rate": 1_000,
    "heart_rate_variability": 10_000,
    "respiratory_rate": 1_000,
    "oxygen_saturation": 100,
    "vo2_max": 200,
    "body_mass": 1_000,
    "body_fat_percentage": 100,
    "lean_body_mass": 1_000,
    "steps": 1_000_000,
    "active_energy": 1_000_000,
    "water": 1_000_000,
    "caffeine": 1_000_000,
    "sleep_duration": 172_800,
}

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
LIFEOS_TAILSCALE_EDGE_TOKEN = _configured_tailscale_edge_token()
ALLOWED_HOSTS = _configured_allowed_hosts()

# Upstream configuration for read-only data endpoints. Finance is deliberately
# absent: `/finance/summary` is owned by the direct Enable Banking adapter
# below, so an unused environment override must not create a second or
# misleading source of truth.
USAGE_UPSTREAM = os.environ.get("LIFEOS_USAGE_UPSTREAM", "http://127.0.0.1:8787/api/usage")
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
if not _is_allowed_upstream(CLIPPER_UPSTREAM, "/api/clipper/summary"):
    raise RuntimeError("LIFEOS_CLIPPER_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(NUTRITION_BARCODE_UPSTREAM, "/api/nutrition/barcode"):
    raise RuntimeError("LIFEOS_NUTRITION_BARCODE_UPSTREAM must be an exact loopback HTTP endpoint")
if not _is_allowed_upstream(NUTRITION_PHOTO_UPSTREAM, "/api/nutrition/photo-proposal"):
    raise RuntimeError("LIFEOS_NUTRITION_PHOTO_UPSTREAM must be an exact loopback HTTP endpoint")
# Frozen transport bounds from the acceptance registry.  A smaller shared
# ceiling keeps every telemetry/control response within the native client
# contract; image input has its separate, explicitly validated aggregate cap.
CALENDAR_SCHEMA_VERSION = 1
CALENDAR_MAX_BODY_SIZE = 256 * 1024
CALENDAR_MAX_RESPONSE_SIZE = 256 * 1024
# Keep the gateway authority aligned with CalendarSnapshot.maximumItemCount.
CALENDAR_MAX_ITEMS = 1_024
CALENDAR_METADATA_MAX_SIZE = 4 * 1024 * 1024
CALENDAR_STATE_SCHEMA_VERSION = 1
CALENDAR_STATE_MAX_SIZE = 6 * 1024 * 1024
# The idempotency journal is intentionally a rolling replay window, not an
# ever-growing ledger.  Recent keys remain replayable across process restarts;
# once a key rolls out, the normal If-Match check still prevents a stale retry
# from creating a second revision.  Keeping the window bounded is what lets a
# long-lived Calendar continue accepting new writes.
CALENDAR_MAX_IDEMPOTENCY_RECORDS = 10_000
CALENDAR_MAX_REVISION = 9_007_199_254_740_991
CALENDAR_BODY_TIMEOUT = 8.0
CALENDAR_IDEMPOTENCY_KEY_PATTERN = re.compile(r"^[\x21-\x7e]{1,128}$")
CALENDAR_ETAG_PATTERN = re.compile(r'^"calendar-v1-r([0-9]+)-([0-9a-f]{64})"$')
SYNC_FINGERPRINT_PATTERN = re.compile(r"^[0-9a-f]{64}$")
# Manual imported finance is a separate, gateway-authoritative ledger. It is
# deliberately not part of the Enable Banking summary route: CSV rows carry
# user-confirmed history, while `/finance/summary` carries live connector
# observations. These bounds are mirrored by the native client and contracts.
FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION = 1
FINANCE_IMPORTED_SCHEMA_VERSION = 2
FINANCE_IMPORTED_MAX_RECORDS = 10_000
FINANCE_IMPORTED_MAX_TOMBSTONES = 10_000
FINANCE_IMPORTED_MAX_OPERATIONS = 512
FINANCE_IMPORTED_MAX_IDEMPOTENCY_RECORDS = 10_000
FINANCE_IMPORTED_MAX_BODY_SIZE = 512 * 1024
FINANCE_IMPORTED_MAX_RESPONSE_SIZE = 4 * 1024 * 1024
FINANCE_IMPORTED_MAX_STATE_SIZE = 8 * 1024 * 1024
FINANCE_IMPORTED_MAX_REVISION = CALENDAR_MAX_REVISION
FINANCE_IMPORTED_BODY_TIMEOUT = 8.0
FINANCE_IMPORTED_IDEMPOTENCY_KEY_PATTERN = CALENDAR_IDEMPOTENCY_KEY_PATTERN
FINANCE_IMPORTED_ETAG_PATTERN = re.compile(r'^"finance-imported-v2-r([0-9]+)-([0-9a-f]{64})"$')
FINANCE_IMPORTED_WHITESPACE = frozenset({
    0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020, 0x0085, 0x00A0, 0x1680,
    *range(0x2000, 0x200B), 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF,
})
FINANCE_IMPORTED_PATH = DATA_DIR / "finance-imported.json"
FINANCE_IMPORTED_SOURCES = frozenset({"tradeRepublicCSV", "genericCSV"})
FINANCE_IMPORTED_KINDS = frozenset({"cash", "investmentOrder"})
FINANCE_IMPORTED_CATEGORIES = frozenset({
    "groceries", "dining", "transport", "shopping", "bills", "subscriptions",
    "health", "travel", "transfers", "fees", "taxes", "investments", "income",
    "cash", "uncategorized",
})
USAGE_MAX_RESPONSE_SIZE = 256 * 1024
# Strict per-operation timeout plus an outer wall-clock deadline.
USAGE_REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
USAGE_TOTAL_TIMEOUT = 6.0
CLIPPER_MAX_RESPONSE_SIZE = 256 * 1024
CLIPPER_REQUEST_TIMEOUT = httpx.Timeout(5.0, connect=2.0)
CLIPPER_TOTAL_TIMEOUT = 6.0
NUTRITION_PHOTO_MAX_BODY_SIZE = 30 * 1024 * 1024
NUTRITION_PHOTO_MAX_RESPONSE_SIZE = 256 * 1024
NUTRITION_PHOTO_MAX_IMAGE_BYTES = 20 * 1024 * 1024
NUTRITION_PHOTO_MAX_IMAGE_COUNT = 3
NUTRITION_PHOTO_MAX_IMAGE_DIMENSION = 12_000
NUTRITION_PHOTO_MAX_IMAGE_PIXELS = 40_000_000
NUTRITION_PHOTO_REQUEST_TIMEOUT = httpx.Timeout(28.0, connect=2.0)
NUTRITION_PHOTO_TOTAL_TIMEOUT = 30.0
NUTRITION_PHOTO_BODY_TIMEOUT = 30.0
DOCUMENT_MAX_UPLOAD_SIZE = int(os.environ.get("LIFEOS_DOCUMENT_MAX_UPLOAD_SIZE", 64 * 1024 * 1024))
DOCUMENT_READ_CHUNK_SIZE = 1024 * 1024
DOCUMENT_BODY_TIMEOUT = 90.0
DOCUMENT_ALLOWED_EXTENSIONS = {".pdf", ".png", ".jpg", ".jpeg", ".heic"}
DOCUMENT_INDEX_MAX_SIZE = 256 * 1024
DOCUMENT_INDEX_MAX_ENTRIES = 512
DOCUMENT_METADATA_MAX_SIZE = 64 * 1024
DOCUMENT_METADATA_MAX_FIELDS = 128
DOCUMENT_MULTIPART_OVERHEAD = 128 * 1024
DOCUMENT_MULTIPART_HEADER_FIELD_MAX_SIZE = 256
DOCUMENT_MULTIPART_HEADER_VALUE_MAX_SIZE = 4 * 1024
DOCUMENT_MULTIPART_MAX_HEADERS_PER_PART = 16
DOCUMENT_INDEX_FILENAME_PATTERN = re.compile(
    r"^original(?:-[0-9a-f]{32})?\.(?:pdf|png|jpg|jpeg|heic|bin)$"
)
DOCUMENT_MAX_FIELD_CHARACTERS = 2_048
DOCUMENT_MAX_EVIDENCE_CHARACTERS = 512
DOCUMENT_MAX_DATES = 2_048
DOCUMENT_MAX_AMOUNTS = 2_048
DOCUMENT_MAX_WARNINGS = 64
DOCUMENT_MAX_EVIDENCE_PAGE = 200
DOCUMENT_PRIVACY_PLACEHOLDER = "Evidence withheld for privacy."
DOCUMENT_PRIVACY_VERSION = 1
DOCUMENT_PUBLICATION_KEYS = frozenset({
    "id", "title", "documentType", "taxYear", "issuer", "taxpayerIdentifier",
    "referenceIdentifier", "dates", "amounts", "warnings", "confidence",
})
DOCUMENT_INDEX_INTERNAL_KEYS = frozenset({"_originalFile", "_privacyVersion"})
DOCUMENT_REQUIRED_PUBLICATION_KEYS = DOCUMENT_PUBLICATION_KEYS - {"taxYear"}
DOCUMENT_CONFIDENCE_VALUES = frozenset({"low", "medium", "high"})

_TAX_GERMAN_LABEL = (
    r"(?:steuerliche[ \t]+(?:identifikationsnummer|id)|"
    r"steueridentifikationsnummer|identifikationsnummer|"
    r"steuer[ \t]*[-–—]?[ \t]*id(?:[ \t]*[-–—.]?[ \t]*nr\.?)?|"
    r"id[ \t]*[-–—.]?[ \t]*nr\.?|ident[ \t]*[-–—.]?[ \t]*nr\.?|"
    r"tax[ \t]+identification[ \t]+number|tax[ \t]+id(?:entifier)?|"
    r"taxpayer[ \t]+id(?:entifier)?|tin)"
)
_TAX_GENERIC_LABEL = (
    _TAX_GERMAN_LABEL[:-1]
    + r"|steuer[- ]?nummer|aktenzeichen|reference(?:[ \t]+identifier)?|identifier|id)"
)

# Values are deliberately bounded and made from identifier-like characters.
# The generic labelled branch requires a digit, which prevents prose such as
# ``ID is ...`` from being swallowed.  The two grouped branches cover the
# common German 11-digit rendering and mixed-mask variants without a nested
# unbounded quantifier.
_TAX_IDENTIFIER_VALUE = (
    r"(?:[0-9*]{2}(?:[ \t]{1,3}[0-9*]{3}){3}|"
    r"[0-9*]{11,32}|\*+[0-9]{2,30}|"
    r"(?:AZ|AKZ|REF|ID)[ \t]+[0-9A-Z*][0-9A-Z*./-]{0,30}|"
    r"(?=[0-9A-Z*./-]{0,30}[0-9])[0-9A-Z*][0-9A-Z*./-]{2,30})"
)

_TAX_GERMAN_IDENTIFIER_PATTERN = re.compile(
    rf"(?i)\b{_TAX_GERMAN_LABEL}\b[ \t]*[:#-]?[ \t]*"
    rf"(?P<value>{_TAX_IDENTIFIER_VALUE})(?![0-9A-Z*./-])"
)
_TAX_IDENTIFIER_PATTERN = re.compile(
    rf"(?i)\b{_TAX_GENERIC_LABEL}\b[ \t]*[:#-]?[ \t]*"
    rf"(?P<value>{_TAX_IDENTIFIER_VALUE})(?![0-9A-Z*./-])"
)

# A bare German tax identifier is exactly eleven decimal digits.  The mixed
# form is bounded at 32 characters so an attacker cannot turn redaction into
# a backtracking scan, and the replacement callback still requires exactly
# eleven digits before changing the token.  A separate grouped form avoids
# treating ordinary short numbers as identifiers.
_TAX_BARE_IDENTIFIER_PATTERN = re.compile(
    r"(?<![0-9])(?P<value>[0-9*]{11,32})(?![0-9])"
)
_TAX_GROUPED_IDENTIFIER_PATTERN = re.compile(
    r"(?<![0-9])(?P<value>"
    r"\*?[0-9*]{2}[ \t/.-]{1,3}[0-9*]{3}[ \t/.-]{1,3}[0-9*]{5}\*?"
    r"|\*?[0-9*]{2}(?:[ \t]{1,3}[0-9*]{3}){3}\*?"
    r"|\*?(?:[0-9*]{3}[ \t/.-]{1,3}){3}[0-9*]{2}\*?"
    r")(?![0-9])"
)
_TAX_MASKED_IDENTIFIER_PATTERN = re.compile(
    r"(?<![0-9*])\*{1,32}(?P<suffix>[0-9]{2})(?![0-9])"
)
_TAX_MASKED_IDENTIFIER_INPUT_PATTERN = re.compile(r"\*{1,32}(?:[0-9]{2})?")
_TAX_CANONICAL_MASK_PATTERN = re.compile(
    r"(?<![A-Za-z0-9*])\*{8}(?:[0-9]{2})?(?![A-Za-z0-9*])"
)
_TAX_LEGACY_IDENTIFIER_TOKEN_PATTERN = re.compile(
    r"(?<![A-Za-z0-9*])[A-Za-z0-9*]{2,32}(?![A-Za-z0-9*])"
)
_TAX_LEGACY_SUSPICIOUS_ALPHA_TOKEN_PATTERN = re.compile(
    r"(?<![A-Za-z0-9*])[A-Z]{6,32}(?![A-Za-z0-9*])"
)
_TAX_LEGACY_VALID_FORM_TOKENS = frozenset({
    "w2", "w-2", "w3", "w-3", "1040", "1040-sr", "1098", "1099",
})
_TAX_LEGACY_VALID_SCHEDULE_TOKENS = frozenset({
    "a", "c", "d", "e", "f", "k1", "k-1",
})
_TAX_LEGACY_NUMERIC_TOKEN_PATTERN = re.compile(
    r"(?<![A-Za-z0-9*])[0-9]{1,32}(?![0-9*])"
)
_TAX_LEGACY_ORDINARY_NUMBER_CONTEXT_PATTERN = re.compile(
    r"(?i)(?:"
    r"\b(?:tax\s+)?year|\byear|\bpage|\bseite|"
    r"\b(?:date|datum|amount|betrag|summe|total|owed)"
    r")[\s:#()/.\\-]*$"
)
_TAX_LEGACY_IDENTIFIER_CONTEXT_PATTERN = re.compile(
    r"(?i)(?:"
    r"\btaxpayer(?:\s+identifier|\s+id)?|\btax\s+(?:identifier|id)|"
    r"\b(?:identifier|reference|ref|aktenzeichen|steuernummer|id)"
    r")[\s:#()/.\\-]*$"
)
# These complete tokens are retained when checking an old entry. Their
# digits are ordinary date/money text, so they cannot establish that a
# masked candidate's original identifier was absent from the field.
_TAX_LEGACY_SAFE_NUMBER_PATTERN = re.compile(
    r"(?<![A-Za-z0-9])(?:"
    r"[0-9]{1,4}[./-][0-9]{1,2}[./-][0-9]{1,4}|"
    r"[0-9]{1,3}(?:[ .][0-9]{3})+(?:[.,][0-9]{1,2})?|"
    r"[0-9]+[.,][0-9]{1,2}"
    r")(?![A-Za-z0-9])",
    re.IGNORECASE,
)
_TAX_LEGACY_ALLOWED_EVIDENCE_WORDS = frozenset({
    "already", "amount", "and", "assessment", "backed", "begins", "date",
    "datum", "document", "evidence", "ending", "ends", "eur", "gbp",
    "finanzamt", "berlin", "here", "id", "identifier", "income", "issuer", "legacy", "masked",
    "normal", "owed", "page", "reference", "ref", "review", "seite",
    "source", "steuer", "steuernummer", "summe", "tax", "taxpayer", "total",
    "usd", "year",
})
_TAX_LEGACY_EVIDENCE_WORD_PATTERN = re.compile(
    r"(?i)[A-Za-zÄÖÜäöüß]+"
)
_TAX_LEGACY_ORDINARY_EVIDENCE_PAGE_PATTERN = re.compile(
    r"(?i)\b(?:page|seite)[ \t]*[:#-]?[ \t]*([0-9]{1,3})\b"
)
_TAX_LEGACY_ORDINARY_EVIDENCE_YEAR_PATTERN = re.compile(
    r"(?i)\b(?:tax[ \t]+year|year)[ \t]*[:#-]?[ \t]*([0-9]{4})\b"
)
_TAX_LEGACY_ORDINARY_EVIDENCE_IDENTIFIER_ENDING_PATTERN = re.compile(
    r"(?i)\bidentifier[ \t]+ending[ \t]*[:#-]?[ \t]*([0-9]{2})\b"
)

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
finance_imported_lock = asyncio.Lock()
fitness_observation_lock = asyncio.Lock()
calendar_revision = 0
documents_revision = 0


async def _run_gateway_storage(operation: Callable[..., object], /, *args, **kwargs):
    """Run one lock-protected gateway storage unit off the asyncio loop."""
    return await run_protected_storage(operation, *args, **kwargs)


app = FastAPI(title="LifeOS Sync Server")
app.router.redirect_slashes = False


@app.exception_handler(ProtectedStorageOverloaded)
@app.exception_handler(ProtectedStorageUnavailable)
async def protected_storage_capacity_error(
    _request: Request,
    _exc: ProtectedStorageOverloaded | ProtectedStorageUnavailable,
) -> JSONResponse:
    """Return one bounded response for protected-storage capacity failures."""
    return JSONResponse(
        {"error": "storage_busy"},
        status_code=503,
        headers={"Cache-Control": "no-store", "Retry-After": "1"},
    )


@app.middleware("http")
async def require_tailscale_identity(request: Request, call_next):
    path = request.scope.get("path")
    if path != "/health":
        if not _request_has_allowed_host(request.scope):
            return JSONResponse(
                {"detail": "Invalid or missing Host"},
                status_code=400,
                headers={"X-Content-Type-Options": "nosniff"},
            )
        if not _request_has_allowed_tailscale_identity(request.scope):
            response = JSONResponse(
                {"detail": "Invalid or missing Tailscale identity"},
                status_code=403,
                headers={"X-Content-Type-Options": "nosniff"},
            )
            if path in {"/usage/claude-ingest", "/usage/claude-ingest/"}:
                response.headers["Cache-Control"] = "no-store"
            return response
        if _is_browser_mutation_scope(request.scope) and not _request_has_allowed_browser_origin(request.scope):
            return JSONResponse(
                {"detail": "Untrusted browser origin"},
                status_code=403,
                headers={"X-Content-Type-Options": "nosniff"},
            )
        transport_error = _document_transport_error(request.scope)
        if transport_error is not None:
            transport_error.headers["X-Content-Type-Options"] = "nosniff"
            return transport_error
    response = await call_next(request)
    response.headers["X-Content-Type-Options"] = "nosniff"
    if path in {"/usage/claude-ingest", "/usage/claude-ingest/"}:
        response.headers["Cache-Control"] = "no-store"
    return response


class ChangeBroadcaster:
    """Push-only fan-out so clients don't have to poll. Costs ~nothing while idle:
    connections just sit parked until a write happens, no timers, no background loop."""

    MAX_CONNECTIONS = 16
    SEND_TIMEOUT = 0.25
    BROADCAST_TIMEOUT = 0.50

    def __init__(self) -> None:
        self._sockets: set[WebSocket] = set()
        self._lock = asyncio.Lock()

    async def register(self, ws: WebSocket) -> bool:
        async with self._lock:
            if ws not in self._sockets and len(self._sockets) >= self.MAX_CONNECTIONS:
                return False
            self._sockets.add(ws)
            return True

    async def unregister(self, ws: WebSocket) -> None:
        async with self._lock:
            self._sockets.discard(ws)

    async def _close_evicted(self, ws: WebSocket) -> None:
        try:
            await asyncio.wait_for(ws.close(code=1011), timeout=self.SEND_TIMEOUT)
        except Exception:
            pass

    async def broadcast(self, message: dict) -> bool:
        async with self._lock:
            targets = list(self._sockets)
        if not targets:
            return True

        tasks = {
            asyncio.create_task(
                asyncio.wait_for(ws.send_json(message), timeout=self.SEND_TIMEOUT)
            ): ws
            for ws in targets
        }
        _done, pending = await asyncio.wait(tasks, timeout=self.BROADCAST_TIMEOUT)
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

        dead = [
            ws for task, ws in tasks.items()
            if task.cancelled() or task.exception() is not None
        ]
        if dead:
            async with self._lock:
                for ws in dead:
                    self._sockets.discard(ws)
            await asyncio.gather(
                *(self._close_evicted(ws) for ws in dead),
                return_exceptions=True,
            )
        return not dead


broadcaster = ChangeBroadcaster()
MAX_CLIENT_MESSAGE_BYTES = 4 * 1024


def _websocket_client_message_close_code(message: object) -> int | None:
    """Return the bounded close code for one push-only client frame."""
    if not isinstance(message, dict):
        return 1002
    message_type = message.get("type")
    if message_type == "websocket.disconnect":
        return None
    if message_type != "websocket.receive":
        return 1002

    text = message.get("text")
    binary = message.get("bytes")
    if isinstance(text, str) and binary is None:
        size = len(text.encode("utf-8"))
    elif isinstance(binary, bytes) and text is None:
        size = len(binary)
    else:
        # ASGI requires exactly one of text/bytes for a receive frame. Treat
        # malformed or unknown frames as unsupported protocol input.
        return 1003
    return 1009 if size > MAX_CLIENT_MESSAGE_BYTES else 1003


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
    return _read_strict_secret(_ingest_secret_path())


def _read_strict_secret(path: Path) -> str | None:
    descriptor: int | None = None
    try:
        before_chain = _state_path_identity_chain(path)
        if not before_chain:
            return None
        assert_protected_storage_path(path, before_chain)
        before = os.lstat(path)
        if not stat.S_ISREG(before.st_mode) or stat.S_ISLNK(before.st_mode) or before.st_size > CLAUDE_INGEST_SECRET_MAX_BYTES:
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
        if len(value) != after.st_size:
            return None
        if _state_path_identity_chain(path) != before_chain:
            return None
    except (_CalendarStateUnavailable, OSError, ValueError):
        return None
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    return _validated_ingest_secret(value)


LOCAL_API_SECRET_ENV = "LIFEOS_LOCAL_API_SECRET_FILE"


def _configured_service_secret(environment: str) -> str | None:
    value = os.environ.get(environment)
    if not value or not Path(value).is_absolute():
        return None
    return _read_strict_secret(Path(value))


def _service_secret() -> str | None:
    """Read the local service capability; never derive it from client headers."""
    secret = _configured_service_secret(LOCAL_API_SECRET_ENV)
    if secret is None:
        return None
    for forbidden in (_read_ingest_secret(), LIFEOS_TAILSCALE_EDGE_TOKEN):
        if forbidden is not None and hmac.compare_digest(secret, forbidden):
            return None
    return secret


async def _service_secret_async() -> str | None:
    """Read the local service capability without blocking an async route."""
    return await _run_gateway_storage(_service_secret)


async def _enable_banking_storage_value(async_name: str, sync_name: str):
    """Read one Enable Banking storage value without bypassing its boundary.

    The synchronous fallback keeps narrow test doubles and older adapters
    compatible while still ensuring a real synchronous reader runs on the
    bounded executor.
    """
    async_reader = getattr(enable_banking, async_name, None)
    if callable(async_reader):
        value = async_reader()
        return await value if inspect.isawaitable(value) else value
    sync_reader = getattr(enable_banking, sync_name, None)
    if not callable(sync_reader):
        return None
    return await _run_gateway_storage(sync_reader)


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
    if not (
        isinstance(connectors, dict)
        and set(connectors) == PROVIDERS
        and all(_is_choice(state, CONNECTOR_STATES) for state in connectors.values())
    ):
        return False
    for provider in PROVIDERS:
        observed = [
            item for item in data["windows"]
            if item["provider"] == provider and item["availability"] == "observed"
        ]
        if not observed:
            continue
        expected = (
            "rate_limited" if any(item["provenance"]["connectorState"] == "rate_limited" for item in observed)
            else "refresh_due" if any(item["provenance"]["connectorState"] == "refresh_due" for item in observed)
            else "healthy"
        )
        if connectors[provider] != expected:
            return False
    return True


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
    "availability", "id", "name", "detail", "source", "provenance"
}
FINANCE_ACCOUNT_OBSERVED_FIELDS = FINANCE_ACCOUNT_FIELDS | {"balanceCents"}
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
        pair = (value["freshness"], value["connectorState"])
        if pair not in {("fresh", "healthy"), ("stale", "refresh_due")}:
            return False
        if not age_consistent:
            return True
        expected = _expected_finance_observed_pair(value)
        return expected is not None and pair == expected
    return (
        value["quality"] == "unavailable"
        and _is_choice(value["freshness"], {"unknown"})
        and _is_choice(value["connectorState"], CONNECTOR_STATES - {"healthy", "refresh_due"})
    )


def _validate_finance_observed_provenance(value, *, age_consistent: bool = True) -> bool:
    return _validate_finance_provenance(value, observed=True, age_consistent=age_consistent)


def _validate_finance_metric(value, *, age_consistent: bool = True) -> bool:
    if not isinstance(value, dict) or not _is_choice(value.get("availability"), {"observed", "unavailable"}):
        return False
    observed = value["availability"] == "observed"
    expected = {"availability", "provenance", "amountCents"} if observed else {"availability", "provenance"}
    if set(value) != expected or not _validate_finance_provenance(
        value.get("provenance"), observed=observed, age_consistent=observed and age_consistent
    ):
        return False
    return not observed or (
        isinstance(value["amountCents"], int)
        and not isinstance(value["amountCents"], bool)
        and 0 <= value["amountCents"] <= FINANCE_MAX_SAFE_CENTS
    )


def _validate_finance_account_observation(value, *, age_consistent: bool = True) -> bool:
    if not isinstance(value, dict) or not _is_choice(value.get("availability"), {"observed", "unavailable"}):
        return False
    observed = value["availability"] == "observed"
    expected_fields = FINANCE_ACCOUNT_OBSERVED_FIELDS if observed else FINANCE_ACCOUNT_FIELDS
    if set(value) != expected_fields:
        return False
    text_fields = ("id", "name", "detail", "source")
    if not all(isinstance(value[field], str) and value[field].strip() for field in text_fields):
        return False
    provenance = value.get("provenance")
    if not isinstance(provenance, dict):
        return False
    if value["source"] != provenance.get("source"):
        return False
    if observed:
        return (
            isinstance(value["balanceCents"], int)
            and not isinstance(value["balanceCents"], bool)
            and -FINANCE_MAX_SAFE_CENTS <= value["balanceCents"] <= FINANCE_MAX_SAFE_CENTS
            and _validate_finance_observed_provenance(provenance, age_consistent=age_consistent)
        )
    return _validate_finance_provenance(provenance, observed=False)


def _validate_finance_account_snapshot(value, *, age_consistent: bool = True) -> bool:
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
    if not accounts or not _validate_finance_observed_provenance(provenance, age_consistent=age_consistent):
        return False
    if not all(
        _validate_finance_account_observation(account, age_consistent=age_consistent)
        for account in accounts
    ):
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
        account["availability"] == "observed"
        and (
            account["provenance"]["freshness"] == "stale"
            or account["provenance"]["connectorState"] == "refresh_due"
        )
        for account in accounts
    )
    expected = ("stale", "refresh_due") if has_stale_account else ("fresh", "healthy")
    return (provenance["freshness"], provenance["connectorState"]) == expected


def _validate_finance_transaction_observation(value, *, age_consistent: bool = True) -> bool:
    if not isinstance(value, dict) or set(value) != FINANCE_TRANSACTION_FIELDS:
        return False
    text_fields = ("id", "merchant", "title", "account", "source", "category")
    if not all(isinstance(value[field], str) and value[field].strip() for field in text_fields):
        return False
    provenance = value.get("provenance")
    if not isinstance(provenance, dict) or not _validate_finance_observed_provenance(
        provenance, age_consistent=age_consistent
    ):
        return False
    return (
        isinstance(value["signedAmountCents"], int)
        and not isinstance(value["signedAmountCents"], bool)
        and -FINANCE_MAX_SAFE_CENTS <= value["signedAmountCents"] <= FINANCE_MAX_SAFE_CENTS
        and _is_finance_observed_timestamp(value["timestamp"])
        and value["source"] == provenance["source"]
    )


def _validate_finance_transaction_snapshot(value, *, age_consistent: bool = True) -> bool:
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
    if not _validate_finance_observed_provenance(
        provenance, age_consistent=age_consistent and not rows
    ):
        return False
    if not all(
        _validate_finance_transaction_observation(row, age_consistent=age_consistent)
        for row in rows
    ):
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


def _validate_finance_payload(data: dict, *, age_consistent: bool = True) -> bool:
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
        and all(_validate_finance_metric(data[key], age_consistent=age_consistent) for key in FINANCE_METRICS)
        and ("accounts" not in data or data["accounts"] is None or _validate_finance_account_snapshot(data["accounts"], age_consistent=age_consistent))
        and ("transactions" not in data or data["transactions"] is None or _validate_finance_transaction_snapshot(data["transactions"], age_consistent=age_consistent))
    )


def _validate_persisted_finance_payload(data: dict) -> bool:
    """Validate durable Finance shape without treating wall-clock age as corruption."""
    return _validate_finance_payload(data, age_consistent=False)


def _parse_fitness_timestamp(value):
    if not _is_iso8601(value):
        return None
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00" if value.endswith("Z") else value)
        return parsed.astimezone(timezone.utc) if parsed.tzinfo is not None else None
    except (AttributeError, OverflowError, OSError, TypeError, ValueError):
        return None


def _validate_fitness_value(value, *, daily: bool, generated_at: datetime, now: datetime) -> bool:
    if not isinstance(value, dict) or set(value) != {"metric", "value", "unit", "observedAt"}:
        return False
    metric = value["metric"]
    if not _is_choice(metric, FITNESS_OBSERVATION_CURRENT_METRICS | FITNESS_OBSERVATION_DAILY_METRICS):
        return False
    if (metric in FITNESS_OBSERVATION_DAILY_METRICS) != daily:
        return False
    if value["unit"] != FITNESS_OBSERVATION_UNITS[metric]:
        return False
    if not _is_number(value["value"]) or not 0 <= value["value"] <= FITNESS_OBSERVATION_VALUE_LIMITS[metric]:
        return False
    observed_at = _parse_fitness_timestamp(value["observedAt"])
    if observed_at is None:
        return False
    if not daily and observed_at < generated_at - FITNESS_OBSERVATION_MAX_CURRENT_METRIC_AGE:
        return False
    return (
        generated_at - FITNESS_OBSERVATION_MAX_HISTORY <= observed_at <= generated_at + timedelta(seconds=5)
        and observed_at <= now + timedelta(seconds=5)
    )


def _validate_fitness_observation_payload(
    data: dict,
    *,
    now: datetime | None = None,
    enforce_freshness: bool = True,
    allow_non_observed: bool = False,
) -> bool:
    """Validate the bounded cross-device Fitness contract at the gateway."""
    if not isinstance(data, dict) or set(data) != FITNESS_OBSERVATION_FIELDS:
        return False
    if isinstance(data["schemaVersion"], bool) or data["schemaVersion"] != FITNESS_OBSERVATION_SCHEMA_VERSION:
        return False
    if not isinstance(data["state"], str) or data["state"] not in FITNESS_OBSERVATION_STATES:
        return False
    if data["source"] != "healthkit" or data["provenance"] != "iphone_healthkit_projection":
        return False
    now = now or datetime.now(timezone.utc)
    if now.tzinfo is None:
        return False
    generated_at = _parse_fitness_timestamp(data["generatedAt"])
    observed_at = _parse_fitness_timestamp(data["observedAt"])
    if generated_at is None or observed_at is None:
        return False
    generated_age = now - generated_at
    if generated_age < timedelta(seconds=-5) or generated_age > FITNESS_OBSERVATION_MAX_HISTORY:
        return False
    if observed_at > generated_at + timedelta(seconds=5) or observed_at > now + timedelta(seconds=5):
        return False

    metrics = data["metrics"]
    days = data["days"]
    workouts = data["workouts"]
    if not isinstance(metrics, list) or not isinstance(days, list) or not isinstance(workouts, list):
        return False
    if (
        len(metrics) > FITNESS_OBSERVATION_MAX_METRICS
        or len(days) > FITNESS_OBSERVATION_MAX_DAYS
        or len(workouts) > FITNESS_OBSERVATION_MAX_WORKOUTS
    ):
        return False

    state = data["state"]
    if state == "observed":
        if enforce_freshness and generated_age > FITNESS_OBSERVATION_STALE_AFTER:
            return False
        if not metrics and not any(isinstance(day, dict) and day.get("values") for day in days) and not workouts:
            return False
    elif not allow_non_observed or metrics or days or workouts:
        return False

    seen_metrics = set()
    for value in metrics:
        if not _validate_fitness_value(value, daily=False, generated_at=generated_at, now=now):
            return False
        if value["metric"] in seen_metrics:
            return False
        seen_metrics.add(value["metric"])

    seen_days = set()
    for day in days:
        if not isinstance(day, dict) or set(day) != {"date", "values"}:
            return False
        day_date = _parse_fitness_timestamp(day["date"])
        values = day["values"]
        if (
            day_date is None
            or day_date in seen_days
            or not generated_at - FITNESS_OBSERVATION_MAX_HISTORY <= day_date <= generated_at + timedelta(seconds=5)
            or day_date > now + timedelta(seconds=5)
            or not isinstance(values, list)
            or len(values) > FITNESS_OBSERVATION_MAX_VALUES_PER_DAY
        ):
            return False
        seen_days.add(day_date)
        seen_day_metrics = set()
        for value in values:
            if not _validate_fitness_value(value, daily=True, generated_at=generated_at, now=now):
                return False
            if value["metric"] in seen_day_metrics:
                return False
            seen_day_metrics.add(value["metric"])

    seen_workouts = set()
    for workout in workouts:
        if not isinstance(workout, dict) or set(workout) not in (
            {"activityTypeRawValue", "startAt", "endAt", "durationSeconds"},
            {"activityTypeRawValue", "startAt", "endAt", "durationSeconds", "activeEnergyKilocalories"},
        ):
            return False
        activity = workout["activityTypeRawValue"]
        start_at = _parse_fitness_timestamp(workout["startAt"])
        end_at = _parse_fitness_timestamp(workout["endAt"])
        duration = workout["durationSeconds"]
        energy = workout.get("activeEnergyKilocalories")
        if (
            isinstance(activity, bool)
            or not isinstance(activity, int)
            or not 0 <= activity <= 1_000_000
            or start_at is None
            or end_at is None
            or end_at <= start_at
            or start_at < generated_at - FITNESS_OBSERVATION_MAX_HISTORY
            or end_at > generated_at + timedelta(seconds=5)
            or start_at > now + timedelta(seconds=5)
            or end_at > now + timedelta(seconds=5)
            or not _is_number(duration)
            or not 0 < duration <= FITNESS_OBSERVATION_MAX_HISTORY.total_seconds()
            or duration > (
                (end_at - start_at).total_seconds()
                + FITNESS_OBSERVATION_WORKOUT_DURATION_ROUNDING_TOLERANCE_SECONDS
            )
            or (energy is not None and (not _is_number(energy) or not 0 <= energy <= 1_000_000))
        ):
            return False
        identity = (activity, start_at, end_at)
        if identity in seen_workouts:
            return False
        seen_workouts.add(identity)

    item_dates = [
        _parse_fitness_timestamp(value["observedAt"])
        for value in metrics
    ] + [
        _parse_fitness_timestamp(value["observedAt"])
        for day in days for value in day["values"]
    ] + [
        _parse_fitness_timestamp(workout["endAt"])
        for workout in workouts
    ]
    return all(item_date is not None and item_date <= observed_at + timedelta(seconds=1) for item_date in item_dates)


def _fitness_observation_bytes(payload: dict) -> bytes:
    try:
        body = json.dumps(
            payload,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (TypeError, UnicodeError, ValueError, OverflowError, RecursionError) as exc:
        raise ValueError("fitness observation cannot be serialized") from exc
    if len(body) > FITNESS_OBSERVATION_MAX_RESPONSE_SIZE:
        raise ValueError("fitness observation exceeds limit")
    return body


def _stale_fitness_observation(payload: dict) -> dict:
    return {
        **payload,
        "state": "stale",
        "metrics": [],
        "days": [],
        "workouts": [],
    }


def _load_valid_fitness_observation(*, now: datetime) -> dict | None:
    """Read the current bounded observation for ordering, failing closed on bad state."""
    try:
        body = _read_bounded_state_file(
            FITNESS_OBSERVATION_PATH,
            FITNESS_OBSERVATION_MAX_RESPONSE_SIZE,
        )
    except (_BoundedFileTooLarge, _CalendarStateUnavailable, OSError):
        return None
    if body is None:
        return None
    try:
        payload = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
            parse_int=_calendar_integer,
        )
    except (
        UnicodeDecodeError,
        UnicodeEncodeError,
        json.JSONDecodeError,
        ValueError,
        TypeError,
        OverflowError,
        RecursionError,
    ):
        return None
    return payload if _validate_fitness_observation_payload(
        payload,
        now=now,
        enforce_freshness=False,
        allow_non_observed=True,
    ) else None


def _fitness_observation_order_key(payload: dict) -> tuple[datetime, datetime]:
    """Order lifecycle publications by generation, then evidence observation time."""
    generated_at = _parse_fitness_timestamp(payload["generatedAt"])
    observed_at = _parse_fitness_timestamp(payload["observedAt"])
    if generated_at is None or observed_at is None:
        raise ValueError("invalid fitness observation ordering timestamps")
    return generated_at, observed_at


def _fitness_publication_response(*, result: str, reason: str | None = None) -> Response:
    """Return a tiny, cache-free publication result with no observation data."""
    payload = {"status": "ok", "result": result}
    if reason is not None:
        payload["reason"] = reason
    return JSONResponse(
        payload,
        headers={
            "Cache-Control": "no-store",
            "X-LifeOS-Fitness-Publication": result,
        },
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
    validate_persisted_finance_payload=_validate_persisted_finance_payload,
)


async def _read_bounded_finance_request(request: Request) -> bytes:
    """Read the mutating Finance JSON request without accepting an unbounded body."""
    return await _read_bounded_request_body(
        request,
        maximum=enable_banking.BODY_LIMIT,
        timeout=8.0,
        error_factory=lambda status_code: _bounded_http_error(
            status_code,
            too_large_detail="finance request too large",
            timeout_detail="finance request timeout",
        ),
    )


async def _read_bounded_fitness_observation_request(request: Request) -> bytes:
    return await _read_bounded_request_body(
        request,
        maximum=FITNESS_OBSERVATION_MAX_BODY_SIZE,
        timeout=FITNESS_OBSERVATION_BODY_TIMEOUT,
        error_factory=lambda status_code: _bounded_http_error(
            status_code,
            too_large_detail="fitness observation body exceeds limit",
            timeout_detail="fitness observation request timeout",
        ),
    )


def _finance_consent_response(payload: dict, status_code: int, *, revision: int | None = None) -> Response:
    """Return a compact Finance envelope within the native client's bound."""
    try:
        body = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        body = b'{"error":"finance unavailable"}'
        status_code = 503
    if len(body) > EnableBankingService.MAX_FINANCE_SUMMARY_SIZE:
        body = b'{"error":"finance unavailable"}'
        status_code = 503
    headers = {"Cache-Control": "no-store"}
    if revision is not None:
        headers["X-LifeOS-Revision"] = str(revision)
        headers["X-LifeOS-Schema-Version"] = "1"
    return Response(
        content=body,
        status_code=status_code,
        media_type="application/json",
        headers=headers,
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
    if _calendar_header(request, "content-type") != "application/json":
        return _finance_consent_response({"error": "content_type"}, 415)
    try:
        body = await _read_bounded_finance_request(request)
        payload = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
    except HTTPException as exc:
        error = "request_too_large" if exc.status_code == 413 else "request_timeout" if exc.status_code == 408 else "invalid_request"
        return _finance_consent_response({"error": error}, exc.status_code)
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


@app.delete("/finance/connect/{institution_id}")
async def delete_finance_connect(institution_id: str) -> Response:
    status_code, result = await enable_banking.revoke(institution_id)
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
    if not _request_has_allowed_host(websocket.scope):
        await websocket.close(code=4403)
        return
    if not _request_has_allowed_tailscale_identity(websocket.scope):
        await websocket.close(code=4403)
        return
    if not _request_has_allowed_browser_origin(websocket.scope):
        await websocket.close(code=4403)
        return
    await websocket.accept()
    if not await broadcaster.register(websocket):
        await websocket.close(code=4429)
        return
    try:
        while True:
            # No client->server messages are expected; this just detects disconnects.
            try:
                message = await websocket.receive()
            except RuntimeError:
                await websocket.close(code=1002)
                break
            close_code = _websocket_client_message_close_code(message)
            if close_code is None:
                break
            await websocket.close(code=close_code)
            break
    except WebSocketDisconnect:
        pass
    finally:
        await broadcaster.unregister(websocket)


def _atomic_publish(path: Path, write_content: Callable[[BinaryIO], None]) -> None:
    """Atomically publish content through the protected state path contract."""
    path = Path(os.path.abspath(os.fspath(path)))
    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    parent_chain = _state_path_identity_chain(parent)
    target_chain = _state_path_identity_chain(path)
    try:
        target_metadata = os.lstat(path)
    except FileNotFoundError:
        target_metadata = None
    if target_metadata is not None and (
        not stat.S_ISREG(target_metadata.st_mode)
        or _state_is_reparse(target_metadata)
    ):
        raise OSError(errno.ELOOP, "atomic write target is not a regular file")

    temporary_name = f".{path.name}.{uuid.uuid4().hex}.tmp"
    tmp = parent / temporary_name
    absolute_path_bound = False
    try:
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        descriptor = None
        directory = None
        if os.name != "nt":
            if not hasattr(os, "O_DIRECTORY"):
                raise OSError(errno.ENOTSUP, "descriptor-relative atomic write unavailable")
            directory_flags = os.O_RDONLY | os.O_DIRECTORY
            fixed_system_alias = parent in {Path("/var"), Path("/tmp")}
            if _state_path_identity_chain(parent) != parent_chain:
                raise OSError(errno.EAGAIN, "atomic write directory changed")
            # Ordinary paths use the final component captured before open().
            # /var and /tmp are the only fixed aliases intentionally followed;
            # capture their resolved target before opening the descriptor.
            expected_parent = (
                _state_path_component_identity(os.stat(parent))
                if fixed_system_alias
                else parent_chain[-1][1]
            )
            directory_flags |= (0 if fixed_system_alias else getattr(os, "O_NOFOLLOW", 0)) | getattr(os, "O_CLOEXEC", 0)
            directory = os.open(parent, directory_flags)
            opened_parent = os.fstat(directory)
            if (
                not stat.S_ISDIR(opened_parent.st_mode)
                or _state_is_reparse(opened_parent)
                or _state_path_component_identity(opened_parent) != expected_parent
            ):
                raise OSError(errno.EAGAIN, "atomic write directory changed")
        else:
            assert_protected_storage_path(parent, parent_chain)
            absolute_path_bound = True
        temporary_flags = flags | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0)
        if directory is not None:
            # Keep every POSIX operation anchored to the open directory. The
            # mutable absolute parent path is not used for temp creation.
            descriptor = os.open(temporary_name, temporary_flags, 0o600, dir_fd=directory)
        else:
            descriptor = os.open(tmp, temporary_flags, 0o600)
        try:
            with os.fdopen(descriptor, "wb") as handle:
                descriptor = -1
                write_content(handle)
                handle.flush()
                os.fsync(handle.fileno())
        finally:
            if descriptor != -1:
                os.close(descriptor)
        if _state_path_identity_chain(parent) != parent_chain or _state_path_identity_chain(path) != target_chain:
            raise OSError(errno.EAGAIN, "atomic write path changed")
        if directory is not None:
            os.replace(temporary_name, path.name, src_dir_fd=directory, dst_dir_fd=directory)
            committed = os.stat(path.name, dir_fd=directory, follow_symlinks=False)
        else:
            assert_protected_storage_path(parent, parent_chain)
            os.replace(tmp, path)
            committed = os.lstat(path)
        if not stat.S_ISREG(committed.st_mode) or _state_is_reparse(committed):
            raise OSError(errno.ELOOP, "atomic write target changed")
        if _state_path_identity_chain(parent) != parent_chain:
            raise OSError(errno.EAGAIN, "atomic write directory changed")
        if directory is not None:
            try:
                os.fsync(directory)
            except OSError as exc:
                if exc.errno not in {errno.EINVAL, errno.ENOTSUP, errno.EISDIR}:
                    raise
    finally:
        if 'directory' in locals() and directory not in (None, -1):
            try:
                try:
                    os.unlink(temporary_name, dir_fd=directory)
                except FileNotFoundError:
                    pass
            finally:
                os.close(directory)
        elif absolute_path_bound:
            # A path-based Windows cleanup is allowed only while the complete
            # protected contract still names the same storage boundary.
            try:
                assert_protected_storage_path(parent, parent_chain)
                if _state_path_identity_chain(parent) != parent_chain:
                    raise OSError(errno.EAGAIN, "atomic write directory changed")
                tmp.unlink()
            except (FileNotFoundError, OSError, ValueError):
                pass


def _atomic_write_bytes(path: Path, data: bytes) -> None:
    """Publish one bounded byte string atomically and durably."""
    _atomic_publish(path, lambda handle: handle.write(data))


def _atomic_write_stream(path: Path, source: BinaryIO, maximum: int) -> None:
    """Publish a bounded seekable stream without materializing it in memory."""
    if maximum < 0:
        raise ValueError("stream maximum must be nonnegative")

    def write_content(handle: BinaryIO) -> None:
        copied = 0
        while True:
            chunk = source.read(DOCUMENT_READ_CHUNK_SIZE)
            if not chunk:
                break
            if not isinstance(chunk, bytes):
                raise TypeError("document stream returned non-bytes")
            copied += len(chunk)
            if copied > maximum:
                raise ValueError("document stream exceeds limit")
            handle.write(chunk)

    _atomic_publish(path, write_content)


class _CalendarStateUnavailable(Exception):
    """Durable Calendar state was missing, malformed, or torn."""


class _BoundedFileTooLarge(_CalendarStateUnavailable):
    """A regular file exceeded the caller's bounded read limit."""


def _calendar_metadata_path() -> Path:
    return Path(f"{CALENDAR_PATH}.meta.json")


def _calendar_state_path() -> Path:
    return Path(f"{CALENDAR_PATH}.state.json")


def _calendar_retry_path() -> Path:
    """Durable marker for a committed revision needing projection work."""
    return Path(f"{CALENDAR_PATH}.retry.json")


WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT = 0x0400


def _state_stat_identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    """Return the bounded identity facts used to bind a state read."""
    return (
        int(value.st_dev),
        int(value.st_ino),
        int(value.st_size),
        int(value.st_mode),
        int(value.st_mtime_ns),
        int(value.st_ctime_ns),
        int(getattr(value, "st_file_attributes", 0)),
    )


def _state_path_component_identity(value: os.stat_result) -> tuple[int, int, int, int]:
    """Return identity that remains stable while a directory's contents change."""
    return (
        int(value.st_dev),
        int(value.st_ino),
        int(value.st_mode),
        int(getattr(value, "st_file_attributes", 0)),
    )


def _state_is_reparse(value: os.stat_result) -> bool:
    return stat.S_ISLNK(value.st_mode) or bool(
        int(getattr(value, "st_file_attributes", 0)) & WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT
    )


def _state_path_identity_chain(path: Path) -> tuple[tuple[str, tuple[int, int, int, int]], ...]:
    """Capture existing path components without resolving a reparse point."""
    current = Path(os.path.abspath(os.fspath(path)))
    leaf = current
    chain: list[tuple[str, tuple[int, int, int, int]]] = []
    while True:
        try:
            observed = os.lstat(current)
        except FileNotFoundError:
            break
        except OSError as exc:
            raise _CalendarStateUnavailable from exc
        # POSIX development paths may contain a system ancestor symlink such
        # as /var -> /private/var. Reject the configured leaf everywhere and
        # reject every reparse component on Windows.
        is_fixed_system_alias = os.name != "nt" and current in {Path("/var"), Path("/tmp")}
        if _state_is_reparse(observed) and (
            current == leaf or os.name == "nt" or not is_fixed_system_alias
        ):
            raise _CalendarStateUnavailable
        chain.append(
            (
                os.path.normcase(os.path.abspath(os.fspath(current))),
                _state_path_component_identity(observed),
            )
        )
        parent = current.parent
        if parent == current:
            break
        current = parent
    return tuple(reversed(chain))


def _assert_state_path_identity_chain(
    expected: tuple[tuple[str, tuple[int, int, int, int]], ...],
    path: Path,
) -> None:
    if _state_path_identity_chain(path) != expected:
        raise _CalendarStateUnavailable


def _read_bounded_state_file(path: Path, maximum: int) -> bytes | None:
    """Read a bounded state file from one identity-checked descriptor.

    The body never grows beyond ``maximum``. A one-byte probe detects a file
    that grows after the initial size check without allocating the excess.
    Atomic writers may replace the pathname after the descriptor is closed;
    the final identity-chain check then rejects that race as torn state.
    """
    if maximum <= 0:
        raise _CalendarStateUnavailable
    descriptor: int | None = None
    try:
        before_chain = _state_path_identity_chain(path)
        if not before_chain:
            return None
        assert_protected_storage_path(path, before_chain)
        before = path.lstat()
        before_identity = _state_stat_identity(before)
        if (
            not stat.S_ISREG(before.st_mode)
            or _state_is_reparse(before)
            or before.st_size < 0
        ):
            raise _CalendarStateUnavailable
        if before.st_size > maximum:
            raise _BoundedFileTooLarge

        flags = os.O_RDONLY
        flags |= getattr(os, "O_CLOEXEC", 0)
        flags |= getattr(os, "O_NOFOLLOW", 0)
        flags |= getattr(os, "O_BINARY", 0)
        descriptor = os.open(os.fspath(path), flags)
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or _state_is_reparse(opened)
            or _state_stat_identity(opened) != before_identity
        ):
            raise _CalendarStateUnavailable
        if opened.st_size > maximum:
            raise _BoundedFileTooLarge

        body = bytearray()
        while len(body) < maximum:
            chunk = os.read(descriptor, min(64 * 1024, maximum - len(body)))
            if not chunk:
                break
            body.extend(chunk)
        if len(body) == maximum and os.read(descriptor, 1):
            raise _BoundedFileTooLarge

        after = os.fstat(descriptor)
        if (
            not stat.S_ISREG(after.st_mode)
            or _state_is_reparse(after)
            or _state_stat_identity(after) != before_identity
            or len(body) != before_identity[2]
        ):
            raise _CalendarStateUnavailable
        _assert_state_path_identity_chain(before_chain, path)
        return bytes(body)
    except _CalendarStateUnavailable:
        raise
    except (FileNotFoundError, OSError, ValueError) as exc:
        raise _CalendarStateUnavailable from exc
    finally:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass


class _FinanceImportedStateUnavailable(Exception):
    """The manual imported-finance authority snapshot is missing or unsafe."""


class _FinanceImportedLimitExceeded(Exception):
    """A valid delta would exceed the bounded authority snapshot."""


class _FinanceImportedOperationConflict(Exception):
    """A valid operation's immutable per-record precondition is no longer true."""

    def __init__(self, reason: str):
        super().__init__(reason)
        self.reason = reason


def _finance_imported_uuid(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
        value,
    ):
        raise ValueError("invalid imported finance record id")
    try:
        return str(uuid.UUID(value)).lower()
    except (ValueError, AttributeError) as exc:
        raise ValueError("invalid imported finance record id") from exc


def _finance_imported_timestamp(value: object) -> str:
    if not isinstance(value, str) or not FINANCE_DATETIME_PATTERN.fullmatch(value):
        raise ValueError("invalid imported finance timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed > datetime.now(timezone.utc) + timedelta(seconds=5):
            raise ValueError("future imported finance timestamp")
    except (TypeError, ValueError, OverflowError, OSError) as exc:
        raise ValueError("invalid imported finance timestamp") from exc
    return value


def _finance_imported_text(value: object, maximum: int, *, nullable: bool = False) -> str | None:
    if value is None and nullable:
        return None
    if not isinstance(value, str) or not value or ord(value[0]) in FINANCE_IMPORTED_WHITESPACE or ord(value[-1]) in FINANCE_IMPORTED_WHITESPACE:
        raise ValueError("invalid imported finance text")
    try:
        if len(value.encode("utf-8")) > maximum:
            raise ValueError("imported finance text exceeds UTF-8 byte limit")
    except UnicodeEncodeError as exc:
        raise ValueError("invalid imported finance text") from exc
    return value


def _finance_imported_cents(value: object, *, nullable: bool = False) -> int | None:
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, int) or abs(value) > CALENDAR_MAX_REVISION:
        raise ValueError("invalid imported finance cents")
    return value


def _finance_imported_revision(value: object, *, positive: bool = False) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("invalid imported finance revision")
    minimum = 1 if positive else 0
    if value < minimum or value > FINANCE_IMPORTED_MAX_REVISION:
        raise ValueError("invalid imported finance revision")
    return value


def _validate_finance_imported_investment(value: object) -> dict | None:
    if value is None:
        return None
    required = {"symbol", "assetClass", "quantity", "unitPriceCents", "tradeType", "currency"}
    if not isinstance(value, dict) or set(value) != required or value.get("currency") != "EUR":
        raise ValueError("invalid imported finance investment details")
    return {
        "symbol": _finance_imported_text(value["symbol"], 64, nullable=True),
        "assetClass": _finance_imported_text(value["assetClass"], 64, nullable=True),
        "quantity": _finance_imported_text(value["quantity"], 128, nullable=True),
        "unitPriceCents": _finance_imported_cents(value["unitPriceCents"], nullable=True),
        "tradeType": _finance_imported_text(value["tradeType"], 64, nullable=True),
        "currency": "EUR",
    }


def _validate_finance_imported_record(value: object, *, legacy: bool = False, snapshot_revision: int | None = None) -> dict:
    base_fields = {
        "recordID", "bookedAt", "amountCents", "description", "categoryOverride",
        "sourceCategory", "providerCode", "source", "importedAt", "kind", "investment",
    }
    required = base_fields if legacy else base_fields | {"sourceRevision"}
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid imported finance record")
    source_revision = 0 if legacy else _finance_imported_revision(value["sourceRevision"])
    if snapshot_revision is not None:
        if source_revision <= 0 or source_revision > snapshot_revision:
            raise ValueError("invalid imported finance source revision")
    category_override = value["categoryOverride"]
    if category_override is not None and (
        not isinstance(category_override, str) or category_override not in FINANCE_IMPORTED_CATEGORIES
    ):
        raise ValueError("invalid imported finance category override")
    record = {
        "recordID": _finance_imported_uuid(value["recordID"]),
        "sourceRevision": source_revision,
        "bookedAt": _finance_imported_timestamp(value["bookedAt"]),
        "amountCents": _finance_imported_cents(value["amountCents"]),
        "description": _finance_imported_text(value["description"], 512),
        "categoryOverride": category_override,
        "sourceCategory": _finance_imported_text(value["sourceCategory"], 128, nullable=True),
        "providerCode": _finance_imported_text(value["providerCode"], 64, nullable=True),
        "source": value["source"],
        "importedAt": _finance_imported_timestamp(value["importedAt"]),
        "kind": value["kind"],
        "investment": _validate_finance_imported_investment(value["investment"]),
    }
    if record["source"] not in FINANCE_IMPORTED_SOURCES or record["kind"] not in FINANCE_IMPORTED_KINDS:
        raise ValueError("invalid imported finance source or kind")
    if record["kind"] == "cash" and record["investment"] is not None:
        raise ValueError("cash row cannot carry investment details")
    return record


def _validate_finance_imported_tombstone(value: object, *, maximum_revision: int) -> dict:
    required = {"recordID", "revision", "deletedAt"}
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid imported finance tombstone")
    record_revision = _finance_imported_revision(value["revision"], positive=True)
    if record_revision > maximum_revision:
        raise ValueError("invalid imported finance tombstone revision")
    return {
        "recordID": _finance_imported_uuid(value["recordID"]),
        "revision": record_revision,
        "deletedAt": _finance_imported_timestamp(value["deletedAt"]),
    }


def _normalize_finance_imported_snapshot(value: object, *, legacy: bool = False) -> dict:
    required = {"schemaVersion", "domain", "ledger", "authority", "revision", "records", "tombstones"}
    expected_version = FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION if legacy else FINANCE_IMPORTED_SCHEMA_VERSION
    if not isinstance(value, dict) or set(value) != required:
        raise ValueError("invalid imported finance snapshot")
    revision = value["revision"]
    if (
        type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != expected_version
        or value["domain"] != "finance"
        or value["ledger"] != "manual_import"
        or value["authority"] != "gateway"
        or isinstance(revision, bool)
        or not isinstance(revision, int)
        or revision < 0
        or revision > FINANCE_IMPORTED_MAX_REVISION
        or not isinstance(value["records"], list)
        or len(value["records"]) > FINANCE_IMPORTED_MAX_RECORDS
        or not isinstance(value["tombstones"], list)
        or len(value["tombstones"]) > FINANCE_IMPORTED_MAX_TOMBSTONES
    ):
        raise ValueError("invalid imported finance snapshot")
    if legacy and revision == 0 and value["records"]:
        raise ValueError("legacy imported finance records require a positive revision")

    records: list[dict] = []
    record_ids: set[str] = set()
    for raw_record in value["records"]:
        record = _validate_finance_imported_record(
            raw_record,
            legacy=legacy,
            snapshot_revision=revision if not legacy else None,
        )
        if legacy:
            record["sourceRevision"] = revision
        if record["recordID"] in record_ids:
            raise ValueError("duplicate imported finance record id")
        record_ids.add(record["recordID"])
        records.append(record)

    tombstones: list[dict] = []
    tombstone_ids: set[str] = set()
    for raw_tombstone in value["tombstones"]:
        tombstone = _validate_finance_imported_tombstone(raw_tombstone, maximum_revision=revision)
        if tombstone["recordID"] in tombstone_ids or tombstone["recordID"] in record_ids:
            raise ValueError("duplicate or live imported finance tombstone id")
        tombstone_ids.add(tombstone["recordID"])
        tombstones.append(tombstone)

    records.sort(key=lambda record: record["recordID"])
    tombstones.sort(key=lambda tombstone: tombstone["recordID"])
    return {
        "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
        "domain": "finance",
        "ledger": "manual_import",
        "authority": "gateway",
        "revision": revision,
        "records": records,
        "tombstones": tombstones,
    }


def _parse_finance_imported_snapshot(body: bytes, *, allow_legacy: bool = False) -> dict:
    if len(body) > FINANCE_IMPORTED_MAX_RESPONSE_SIZE:
        raise ValueError("imported finance snapshot exceeds limit")
    try:
        decoded = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
            parse_int=_calendar_integer,
        )
        if not isinstance(decoded, dict):
            raise ValueError("invalid imported finance snapshot")
        raw_version = decoded.get("schemaVersion")
        if raw_version == FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION and allow_legacy:
            snapshot = _normalize_finance_imported_snapshot(decoded, legacy=True)
        else:
            snapshot = _normalize_finance_imported_snapshot(decoded)
        # Reject lone surrogates and ensure the normalized form is publishable.
        json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
        return snapshot
    except (UnicodeDecodeError, UnicodeEncodeError, json.JSONDecodeError, ValueError, TypeError, OverflowError, RecursionError) as exc:
        raise ValueError("invalid imported finance snapshot") from exc


def _finance_imported_snapshot_bytes(snapshot: dict) -> bytes:
    try:
        body = json.dumps(snapshot, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (UnicodeError, TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise ValueError("imported finance snapshot cannot be serialized") from exc
    if len(body) > FINANCE_IMPORTED_MAX_RESPONSE_SIZE:
        raise ValueError("imported finance snapshot exceeds limit")
    return body


def _parse_finance_imported_request(body: bytes) -> dict:
    if len(body) > FINANCE_IMPORTED_MAX_BODY_SIZE:
        raise HTTPException(status_code=413, detail="imported finance request exceeds limit")
    try:
        decoded = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
            parse_int=_calendar_integer,
        )
        required = {"schemaVersion", "baseRevision", "operations"}
        if not isinstance(decoded, dict) or set(decoded) != required:
            raise ValueError("invalid imported finance request")
        base_revision = _finance_imported_revision(decoded["baseRevision"])
        operations_value = decoded["operations"]
        if (
            type(decoded["schemaVersion"]) is not int
            or decoded["schemaVersion"] != FINANCE_IMPORTED_SCHEMA_VERSION
            or not isinstance(operations_value, list)
            or len(operations_value) > FINANCE_IMPORTED_MAX_OPERATIONS
        ):
            raise ValueError("invalid imported finance request")

        operations: list[dict] = []
        record_ids: set[str] = set()
        for operation in operations_value:
            if not isinstance(operation, dict) or not isinstance(operation.get("operation"), str):
                raise ValueError("invalid imported finance operation")
            kind = operation["operation"]
            if kind == "upsert":
                if set(operation) != {"operation", "record", "expectedSourceRevision"}:
                    raise ValueError("invalid imported finance upsert")
                expected_source_revision = _finance_imported_revision(operation["expectedSourceRevision"])
                record = _validate_finance_imported_record(operation["record"])
                if record["sourceRevision"] != expected_source_revision:
                    raise ValueError("source precondition must match record source revision")
                record_id = record["recordID"]
                normalized = {
                    "operation": "upsert",
                    "record": record,
                    "expectedSourceRevision": expected_source_revision,
                }
            elif kind == "categorySet":
                if set(operation) != {"operation", "recordID", "expectedSourceRevision", "categoryOverride"}:
                    raise ValueError("invalid imported finance category set")
                record_id = _finance_imported_uuid(operation["recordID"])
                expected_source_revision = _finance_imported_revision(operation["expectedSourceRevision"])
                category = operation["categoryOverride"]
                if not isinstance(category, str) or category not in FINANCE_IMPORTED_CATEGORIES:
                    raise ValueError("invalid imported finance category override")
                normalized = {
                    "operation": "categorySet",
                    "recordID": record_id,
                    "expectedSourceRevision": expected_source_revision,
                    "categoryOverride": category,
                }
            elif kind == "categoryClear":
                if set(operation) != {"operation", "recordID", "expectedSourceRevision"}:
                    raise ValueError("invalid imported finance category clear")
                record_id = _finance_imported_uuid(operation["recordID"])
                expected_source_revision = _finance_imported_revision(operation["expectedSourceRevision"])
                normalized = {
                    "operation": "categoryClear",
                    "recordID": record_id,
                    "expectedSourceRevision": expected_source_revision,
                }
            elif kind == "delete":
                if set(operation) != {"operation", "recordID", "expectedSourceRevision", "deletedAt"}:
                    raise ValueError("invalid imported finance delete")
                record_id = _finance_imported_uuid(operation["recordID"])
                expected_source_revision = _finance_imported_revision(operation["expectedSourceRevision"])
                normalized = {
                    "operation": "delete",
                    "recordID": record_id,
                    "expectedSourceRevision": expected_source_revision,
                    "deletedAt": _finance_imported_timestamp(operation["deletedAt"]),
                }
            elif kind == "restore":
                if set(operation) != {"operation", "record", "expectedTombstoneRevision"}:
                    raise ValueError("invalid imported finance restore")
                expected_tombstone_revision = _finance_imported_revision(operation["expectedTombstoneRevision"], positive=True)
                record = _validate_finance_imported_record(operation["record"])
                if record["sourceRevision"] != 0:
                    raise ValueError("restore record must not carry a new authority revision")
                record_id = record["recordID"]
                normalized = {
                    "operation": "restore",
                    "record": record,
                    "expectedTombstoneRevision": expected_tombstone_revision,
                }
            else:
                raise ValueError("unknown imported finance operation")
            if record_id in record_ids:
                raise ValueError("duplicate imported finance operation id")
            record_ids.add(record_id)
            operations.append(normalized)
        return {
            "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
            "baseRevision": base_revision,
            "operations": operations,
        }
    except HTTPException:
        raise
    except (UnicodeDecodeError, UnicodeEncodeError, json.JSONDecodeError, ValueError, TypeError, OverflowError, RecursionError) as exc:
        raise HTTPException(status_code=400, detail="invalid imported finance request") from exc


def _finance_imported_digest(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def _finance_imported_etag(revision: int, digest: str) -> str:
    return f'"finance-imported-v2-r{revision}-{digest}"'


def _valid_finance_imported_etag(value: object) -> bool:
    if not isinstance(value, str):
        return False
    match = FINANCE_IMPORTED_ETAG_PATTERN.fullmatch(value)
    if match is None:
        return False
    revision_text = match.group(1)
    if len(revision_text) > len(str(FINANCE_IMPORTED_MAX_REVISION)):
        return False
    try:
        revision = int(revision_text)
    except (TypeError, ValueError):
        return False
    return revision <= FINANCE_IMPORTED_MAX_REVISION and str(revision) == revision_text


def _finance_imported_default_snapshot() -> dict:
    return {
        "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
        "domain": "finance",
        "ledger": "manual_import",
        "authority": "gateway",
        "revision": 0,
        "records": [],
        "tombstones": [],
    }


def _finance_imported_default_metadata(body: bytes, *, revision: int = 0) -> dict:
    return {
        "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
        "domain": "finance",
        "authority": "gateway",
        "revision": revision,
        "bodyDigest": _finance_imported_digest(body),
        "idempotency": [],
    }


def _finance_imported_idempotency_window(records: list[dict], new_record: dict) -> list[dict]:
    return [*records, new_record][-max(1, FINANCE_IMPORTED_MAX_IDEMPOTENCY_RECORDS):]


def _validate_finance_imported_metadata(value: object, body: bytes, *, schema_version: int = FINANCE_IMPORTED_SCHEMA_VERSION) -> dict:
    required = {"schemaVersion", "domain", "authority", "revision", "bodyDigest", "idempotency"}
    if not isinstance(value, dict) or set(value) != required:
        raise _FinanceImportedStateUnavailable
    revision = value["revision"]
    if (
        type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != schema_version
        or value["domain"] != "finance"
        or value["authority"] != "gateway"
        or isinstance(revision, bool)
        or not isinstance(revision, int)
        or revision < 0
        or revision > FINANCE_IMPORTED_MAX_REVISION
        or not isinstance(value["bodyDigest"], str)
        or not SYNC_FINGERPRINT_PATTERN.fullmatch(value["bodyDigest"])
        or value["bodyDigest"] != _finance_imported_digest(body)
        or not isinstance(value["idempotency"], list)
        or len(value["idempotency"]) > FINANCE_IMPORTED_MAX_IDEMPOTENCY_RECORDS
    ):
        raise _FinanceImportedStateUnavailable
    keys: set[str] = set()
    for record in value["idempotency"]:
        if not isinstance(record, dict) or set(record) != {"key", "fingerprint", "revision"}:
            raise _FinanceImportedStateUnavailable
        key = record["key"]
        record_revision = record["revision"]
        if (
            not isinstance(key, str)
            or not FINANCE_IMPORTED_IDEMPOTENCY_KEY_PATTERN.fullmatch(key)
            or key in keys
            or not isinstance(record["fingerprint"], str)
            or not SYNC_FINGERPRINT_PATTERN.fullmatch(record["fingerprint"])
            or isinstance(record_revision, bool)
            or not isinstance(record_revision, int)
            or record_revision < 0
            or record_revision > revision
        ):
            raise _FinanceImportedStateUnavailable
        keys.add(key)
    return value


def _finance_imported_state_bytes(body: bytes, metadata: dict) -> bytes:
    envelope = {
        "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
        "bodyBase64": base64.b64encode(body).decode("ascii"),
        "metadata": metadata,
    }
    try:
        encoded = json.dumps(envelope, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise ValueError("imported finance state cannot be serialized") from exc
    if len(encoded) > FINANCE_IMPORTED_MAX_STATE_SIZE:
        raise ValueError("imported finance state exceeds limit")
    return encoded


def _decode_finance_imported_state(state_body: bytes) -> tuple[bytes, dict, dict]:
    try:
        decoded = json.loads(
            state_body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
        if not isinstance(decoded, dict) or set(decoded) != {"schemaVersion", "bodyBase64", "metadata"}:
            raise ValueError("invalid imported finance state envelope")
        state_version = decoded["schemaVersion"]
        if type(state_version) is not int or state_version not in {
            FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION,
            FINANCE_IMPORTED_SCHEMA_VERSION,
        }:
            raise ValueError("invalid imported finance state version")
        encoded_body = decoded["bodyBase64"]
        if not isinstance(encoded_body, str) or not encoded_body:
            raise ValueError("invalid imported finance state body")
        body = base64.b64decode(encoded_body.encode("ascii"), validate=True)
        if len(body) > FINANCE_IMPORTED_MAX_RESPONSE_SIZE or base64.b64encode(body).decode("ascii") != encoded_body:
            raise ValueError("invalid imported finance state body")
        if state_version == FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION:
            # Version 1 used whole-record upserts without per-record source
            # revisions. It is safe to migrate a valid snapshot only by
            # assigning every live source row the conservative authority
            # revision of that snapshot and dropping the obsolete replay
            # journal. The old v1 ETag/body cannot be replayed against v2.
            legacy_snapshot = _parse_finance_imported_snapshot(body, allow_legacy=True)
            _validate_finance_imported_metadata(
                decoded["metadata"],
                body,
                schema_version=FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION,
            )
            snapshot = legacy_snapshot
            body = _finance_imported_snapshot_bytes(snapshot)
            metadata = _finance_imported_default_metadata(body, revision=snapshot["revision"])
            return body, snapshot, metadata

        snapshot = _parse_finance_imported_snapshot(body)
        metadata = _validate_finance_imported_metadata(decoded["metadata"], body)
        if metadata["revision"] != snapshot["revision"]:
            raise ValueError("imported finance revision mismatch")
        return body, snapshot, metadata
    except (UnicodeDecodeError, UnicodeEncodeError, ValueError, binascii.Error, json.JSONDecodeError, RecursionError) as exc:
        raise _FinanceImportedStateUnavailable from exc


def _load_finance_imported_state() -> tuple[bytes, dict, dict]:
    try:
        state_body = _read_bounded_state_file(FINANCE_IMPORTED_PATH, FINANCE_IMPORTED_MAX_STATE_SIZE)
    except (_CalendarStateUnavailable, OSError) as exc:
        raise _FinanceImportedStateUnavailable from exc
    if state_body is None:
        snapshot = _finance_imported_default_snapshot()
        body = _finance_imported_snapshot_bytes(snapshot)
        return body, snapshot, _finance_imported_default_metadata(body)
    body, snapshot, metadata = _decode_finance_imported_state(state_body)
    # `_decode_finance_imported_state` returns a v2 body for a v1 envelope.
    # Persist that conversion before exposing it so a crash cannot repeatedly
    # reinterpret a legacy replay journal as current authority state.
    try:
        decoded_version = json.loads(
            state_body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        ).get("schemaVersion")
        if decoded_version == FINANCE_IMPORTED_LEGACY_SCHEMA_VERSION:
            _atomic_write_bytes(FINANCE_IMPORTED_PATH, _finance_imported_state_bytes(body, metadata))
    except (UnicodeDecodeError, UnicodeEncodeError, ValueError, TypeError, OSError, binascii.Error, json.JSONDecodeError, RecursionError) as exc:
        raise _FinanceImportedStateUnavailable from exc
    return body, snapshot, metadata


def _finance_imported_response(
    body: bytes,
    revision: int,
    *,
    status_code: int = 200,
    replay: bool = False,
    conflict: bool = False,
    noop: bool = False,
    conflict_reason: str | None = None,
) -> Response:
    headers = {
        "Cache-Control": "no-store",
        "ETag": _finance_imported_etag(revision, _finance_imported_digest(body)),
        "X-LifeOS-Revision": str(revision),
        "X-LifeOS-Schema-Version": str(FINANCE_IMPORTED_SCHEMA_VERSION),
    }
    if replay:
        headers["X-LifeOS-Idempotent-Replay"] = "true"
    if conflict:
        headers["X-LifeOS-Conflict"] = "true"
    if conflict_reason is not None:
        headers["X-LifeOS-Conflict-Reason"] = conflict_reason
    if noop:
        headers["X-LifeOS-Noop"] = "true"
    return Response(content=body, status_code=status_code, media_type="application/json", headers=headers)


async def _read_bounded_finance_imported_request(request: Request) -> bytes:
    return await _read_bounded_request_body(
        request,
        maximum=FINANCE_IMPORTED_MAX_BODY_SIZE,
        timeout=FINANCE_IMPORTED_BODY_TIMEOUT,
        error_factory=lambda status_code: _bounded_http_error(
            status_code,
            too_large_detail="imported finance request exceeds limit",
            timeout_detail="imported finance request timeout",
        ),
    )


def _calendar_integer(value: str) -> int:
    # Bound conversion before int(): this also avoids interpreter-specific
    # limits becoming an uncaught exception on hostile integer literals.
    if len(value.lstrip("-")) > len(str(CALENDAR_MAX_REVISION)):
        raise ValueError("unsafe calendar integer")
    number = int(value)
    if abs(number) > CALENDAR_MAX_REVISION:
        raise ValueError("unsafe calendar integer")
    return number


def _calendar_float(value: str) -> float:
    number = float(value)
    if not math.isfinite(number):
        raise ValueError("non-finite calendar number")
    return number


def _calendar_timestamp(value: object) -> datetime:
    if not isinstance(value, str) or not FINANCE_DATETIME_PATTERN.fullmatch(value):
        raise ValueError("invalid calendar timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    # Conversion verifies representability at timezone boundaries, too.
    return parsed.astimezone(timezone.utc)


CALENDAR_MAX_CLOCK_SKEW = timedelta(minutes=5)


def _calendar_now_utc() -> datetime:
    return datetime.now(timezone.utc)


CALENDAR_ICON_MAX_BYTES = 256 * 1024
CALENDAR_ICON_MAX_DIMENSION = 2_048
CALENDAR_ICON_MAX_PIXELS = 4_000_000
CALENDAR_ICON_MAX_DECOMPRESSED_BYTES = 34 * 1024 * 1024


def _png_scanline_lengths(width: int, height: int, bits_per_pixel: int, interlace: int) -> list[int]:
    bytes_per_scanline = (width * bits_per_pixel + 7) // 8 + 1
    if interlace == 0:
        return [bytes_per_scanline] * height

    # Adam7 pass geometry from the PNG specification.  The resulting list is
    # bounded by seven passes over the native 2,048-pixel dimension limit.
    passes = ((0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4),
              (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2))
    lengths: list[int] = []
    for x_start, y_start, x_step, y_step in passes:
        pass_width = max(0, (width - x_start + x_step - 1) // x_step)
        pass_height = max(0, (height - y_start + y_step - 1) // y_step)
        if pass_width and pass_height:
            pass_scanline = (pass_width * bits_per_pixel + 7) // 8 + 1
            lengths.extend([pass_scanline] * pass_height)
    return lengths


def _validate_png_structure(raw: bytes) -> bool:
    signature = b"\x89PNG\r\n\x1a\n"
    if not raw.startswith(signature):
        return False

    offset = len(signature)
    saw_ihdr = False
    saw_idat = False
    idat_closed = False
    saw_iend = False
    saw_plte = False
    idat = bytearray()
    width = height = bits_per_pixel = interlace = bit_depth = color_type = 0

    while offset < len(raw):
        if len(raw) - offset < 12:
            return False
        length = int.from_bytes(raw[offset:offset + 4], "big")
        chunk_type = raw[offset + 4:offset + 8]
        data_start = offset + 8
        data_end = data_start + length
        chunk_end = data_end + 4
        if (
            any(not (0x41 <= byte <= 0x5A or 0x61 <= byte <= 0x7A) for byte in chunk_type)
            or data_end < data_start
            or chunk_end > len(raw)
        ):
            return False
        data = raw[data_start:data_end]
        if (binascii.crc32(chunk_type + data) & 0xFFFFFFFF) != int.from_bytes(raw[data_end:chunk_end], "big"):
            return False
        # APNG frame-control/data chunks would make ImageIO expose more than
        # one image.  They are rejected even though they are ancillary PNG
        # chunks and otherwise have valid CRCs.
        if chunk_type in {b"acTL", b"fcTL", b"fdAT"}:
            return False
        if chunk_type[:1].isupper() and chunk_type not in {b"IHDR", b"PLTE", b"IDAT", b"IEND"}:
            return False
        if not saw_ihdr:
            if chunk_type != b"IHDR" or length != 13:
                return False
            saw_ihdr = True
            width = int.from_bytes(data[0:4], "big")
            height = int.from_bytes(data[4:8], "big")
            bit_depth = data[8]
            color_type = data[9]
            if (
                width <= 0 or height <= 0
                or width > CALENDAR_ICON_MAX_DIMENSION
                or height > CALENDAR_ICON_MAX_DIMENSION
                or width * height > CALENDAR_ICON_MAX_PIXELS
                or data[10] != 0
                or data[11] != 0
                or data[12] not in {0, 1}
            ):
                return False
            allowed_bit_depths = {
                0: {1, 2, 4, 8, 16},
                2: {8, 16},
                3: {1, 2, 4, 8},
                4: {8, 16},
                6: {8, 16},
            }
            if color_type not in allowed_bit_depths or bit_depth not in allowed_bit_depths[color_type]:
                return False
            channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
            bits_per_pixel = channels * bit_depth
            interlace = data[12]
        elif chunk_type == b"IHDR" or saw_iend:
            return False

        if chunk_type == b"PLTE":
            if saw_plte or saw_idat or length == 0 or length > 768 or length % 3:
                return False
            saw_plte = True
        elif chunk_type == b"IDAT":
            if idat_closed:
                return False
            saw_idat = True
            if not data:
                return False
            idat.extend(data)
        elif saw_idat:
            idat_closed = True

        if chunk_type == b"IEND":
            if length != 0 or not saw_idat:
                return False
            saw_iend = True
            offset = chunk_end
            break
        offset = chunk_end

    if not saw_ihdr or not saw_idat or not saw_iend or offset != len(raw):
        return False

    # Indexed PNGs must have a palette, and its entry count cannot exceed the
    # representable index range.  This catches structurally complete but
    # undecodable palette images without loading a decoder.
    if color_type == 3:
        if not saw_plte or len(raw) < 8:
            return False
        # The palette length was checked while parsing; inspect IHDR's depth
        # and the first PLTE chunk without retaining another large object.
        palette_length = None
        cursor = 8
        while cursor < len(raw):
            chunk_length = int.from_bytes(raw[cursor:cursor + 4], "big")
            chunk_type = raw[cursor + 4:cursor + 8]
            if chunk_type == b"PLTE":
                palette_length = chunk_length // 3
                break
            cursor += 12 + chunk_length
        if palette_length is None or palette_length > (1 << bit_depth):
            return False

    row_lengths = _png_scanline_lengths(width, height, bits_per_pixel, interlace)
    expected_output = sum(row_lengths)
    if not row_lengths or expected_output > CALENDAR_ICON_MAX_DECOMPRESSED_BYTES:
        return False
    try:
        decompressor = zlib.decompressobj()
        decoded = decompressor.decompress(bytes(idat), expected_output + 1)
        if len(decoded) > expected_output or decompressor.unused_data or decompressor.unconsumed_tail:
            return False
        remaining = expected_output - len(decoded)
        flushed = decompressor.flush(remaining + 1)
        if len(flushed) > remaining or not decompressor.eof or len(decoded) + len(flushed) != expected_output:
            return False
        output_offset = 0
        for scanline_length in row_lengths:
            if output_offset < len(decoded):
                filter_byte = decoded[output_offset]
            else:
                filter_byte = flushed[output_offset - len(decoded)]
            if filter_byte > 4:
                return False
            output_offset += scanline_length
    except (zlib.error, ValueError, OverflowError):
        return False
    return True


def _validate_jpeg_structure(raw: bytes) -> bool:
    """Validate one bounded baseline JPEG without invoking a decoder.

    ImageIO rejects marker-only fakes, so checking SOI/SOF/SOS/EOI is not a
    sufficient publication boundary. This parser validates the quantization
    and Huffman tables and consumes every baseline Huffman block, including
    stuffed bytes, restart intervals, and sequential multi-scan images. It
    deliberately rejects progressive, arithmetic, and abbreviated streams.
    """
    if len(raw) < 4 or raw[:2] != b"\xff\xd8":
        return False

    def parse_huffman_table(segment: bytes, offset: int):
        if offset + 16 > len(segment):
            return None
        counts = segment[offset:offset + 16]
        symbol_count = sum(counts)
        symbols_start = offset + 16
        symbols_end = symbols_start + symbol_count
        if not 1 <= symbol_count <= 162 or symbols_end > len(segment):
            return None
        symbols = segment[symbols_start:symbols_end]
        table: dict[tuple[int, int], int] = {}
        code = 0
        symbol_offset = 0
        for bit_length, count in enumerate(counts, start=1):
            if code + count > (1 << bit_length):
                return None
            for _ in range(count):
                table[(bit_length, code)] = symbols[symbol_offset]
                symbol_offset += 1
                code += 1
            code <<= 1
        return table, symbols_end

    def consume_scan(
        entropy_chunks: list[bytes],
        restart_markers: list[int],
        total_units: int,
        scan_blocks: list[tuple[dict[tuple[int, int], int], dict[tuple[int, int], int]]],
        restart_interval: int,
    ) -> bool:
        if total_units <= 0 or not scan_blocks:
            return False
        if restart_interval:
            expected_chunks = (total_units + restart_interval - 1) // restart_interval
            if len(entropy_chunks) != expected_chunks or len(restart_markers) != expected_chunks - 1:
                return False
            if any(marker != 0xD0 + (index % 8) for index, marker in enumerate(restart_markers)):
                return False
            unit_counts = [
                min(restart_interval, total_units - index * restart_interval)
                for index in range(expected_chunks)
            ]
        else:
            if restart_markers or len(entropy_chunks) != 1:
                return False
            unit_counts = [total_units]

        for chunk, unit_count in zip(entropy_chunks, unit_counts):
            if not chunk:
                return False
            bit_offset = 0

            def read_bits(count: int) -> int | None:
                nonlocal bit_offset
                if count < 0 or bit_offset + count > len(chunk) * 8:
                    return None
                result = 0
                for _ in range(count):
                    byte = chunk[bit_offset // 8]
                    result = (result << 1) | ((byte >> (7 - bit_offset % 8)) & 1)
                    bit_offset += 1
                return result

            def read_huffman(table: dict[tuple[int, int], int]) -> int | None:
                code = 0
                for bit_length in range(1, 17):
                    bit = read_bits(1)
                    if bit is None:
                        return None
                    code = (code << 1) | bit
                    symbol = table.get((bit_length, code))
                    if symbol is not None:
                        return symbol
                return None

            def consume_block(
                dc_table: dict[tuple[int, int], int],
                ac_table: dict[tuple[int, int], int],
            ) -> bool:
                dc_size = read_huffman(dc_table)
                if dc_size is None or dc_size > 11 or read_bits(dc_size) is None:
                    return False
                coefficient = 1
                while coefficient < 64:
                    symbol = read_huffman(ac_table)
                    if symbol is None:
                        return False
                    if symbol == 0:
                        break
                    if symbol == 0xF0:
                        if coefficient + 16 > 64:
                            return False
                        coefficient += 16
                        continue
                    run = symbol >> 4
                    ac_size = symbol & 0x0F
                    if ac_size == 0 or ac_size > 10 or coefficient + run >= 64:
                        return False
                    coefficient += run
                    if read_bits(ac_size) is None:
                        return False
                    coefficient += 1
                return True

            for _ in range(unit_count):
                for dc_table, ac_table in scan_blocks:
                    if not consume_block(dc_table, ac_table):
                        return False
            remaining = len(chunk) * 8 - bit_offset
            if remaining < 0 or remaining > 7:
                return False
            if remaining:
                padding_mask = (1 << remaining) - 1
                if chunk[-1] & padding_mask != padding_mask:
                    return False
        return True

    position = 2
    quantization_tables: dict[int, bytes] = {}
    huffman_tables: dict[tuple[int, int], dict[tuple[int, int], int]] = {}
    frame: dict | None = None
    seen_components: set[int] = set()
    scan_count = 0
    restart_interval = 0
    sof_markers = {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7,
        0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF,
    }

    while position < len(raw):
        if raw[position] != 0xFF:
            return False
        while position < len(raw) and raw[position] == 0xFF:
            position += 1
        if position >= len(raw):
            return False
        marker = raw[position]
        position += 1

        if marker == 0xD9:
            return (
                frame is not None
                and scan_count > 0
                and seen_components == frame["component_ids"]
                and position == len(raw)
            )
        if marker in {0xD8, *range(0xD0, 0xD8), 0x00, 0x01}:
            return False
        if position + 2 > len(raw):
            return False
        segment_length = int.from_bytes(raw[position:position + 2], "big")
        if segment_length < 2 or position + segment_length > len(raw):
            return False
        segment = raw[position + 2:position + segment_length]
        position += segment_length

        if marker in sof_markers:
            if marker != 0xC0 or frame is not None or len(segment) < 6:
                return False
            precision = segment[0]
            height = int.from_bytes(segment[1:3], "big")
            width = int.from_bytes(segment[3:5], "big")
            component_count = segment[5]
            if (
                precision != 8 or width <= 0 or height <= 0
                or width > CALENDAR_ICON_MAX_DIMENSION
                or height > CALENDAR_ICON_MAX_DIMENSION
                or width * height > CALENDAR_ICON_MAX_PIXELS
                or not 1 <= component_count <= 4
                or len(segment) != 6 + 3 * component_count
            ):
                return False
            components = []
            component_ids: set[int] = set()
            offset = 6
            for _ in range(component_count):
                component_id = segment[offset]
                sampling = segment[offset + 1]
                quantization_id = segment[offset + 2]
                horizontal = sampling >> 4
                vertical = sampling & 0x0F
                if (
                    component_id in component_ids
                    or not 1 <= horizontal <= 4
                    or not 1 <= vertical <= 4
                ):
                    return False
                component_ids.add(component_id)
                components.append((component_id, horizontal, vertical, quantization_id))
                offset += 3
            frame = {
                "width": width,
                "height": height,
                "components": components,
                "component_ids": component_ids,
            }
            continue

        if marker == 0xDB:
            offset = 0
            while offset < len(segment):
                if offset + 1 > len(segment):
                    return False
                info = segment[offset]
                offset += 1
                precision = info >> 4
                table_id = info & 0x0F
                if precision not in {0, 1} or table_id > 3:
                    return False
                value_bytes = 128 if precision else 64
                if offset + value_bytes > len(segment):
                    return False
                values = [
                    int.from_bytes(
                        segment[offset + index:offset + index + (2 if precision else 1)],
                        "big",
                    )
                    for index in range(0, value_bytes, 2 if precision else 1)
                ]
                if any(value <= 0 for value in values):
                    return False
                quantization_tables[table_id] = segment[offset:offset + value_bytes]
                offset += value_bytes
            if offset != len(segment) or not quantization_tables:
                return False
            continue

        if marker == 0xC4:
            offset = 0
            while offset < len(segment):
                info = segment[offset]
                offset += 1
                table_class = info >> 4
                table_id = info & 0x0F
                if table_class not in {0, 1} or table_id > 3:
                    return False
                parsed = parse_huffman_table(segment, offset)
                if parsed is None:
                    return False
                table, offset = parsed
                huffman_tables[(table_class, table_id)] = table
            if offset != len(segment) or not huffman_tables:
                return False
            continue

        if marker == 0xDD:
            if len(segment) != 2:
                return False
            restart_interval = int.from_bytes(segment, "big")
            continue

        if marker == 0xDA:
            if frame is None or len(segment) < 4:
                return False
            component_count = segment[0]
            if not 1 <= component_count <= len(frame["components"]):
                return False
            if len(segment) != 4 + 2 * component_count or segment[-3:] != b"\x00\x3f\x00":
                return False
            frame_by_id = {component[0]: component for component in frame["components"]}
            scan_components = []
            scan_ids: set[int] = set()
            offset = 1
            for _ in range(component_count):
                component_id = segment[offset]
                table_selectors = segment[offset + 1]
                dc_id = table_selectors >> 4
                ac_id = table_selectors & 0x0F
                component = frame_by_id.get(component_id)
                if (
                    component_id in scan_ids
                    or component_id in seen_components
                    or component is None
                    or component[3] not in quantization_tables
                    or (0, dc_id) not in huffman_tables
                    or (1, ac_id) not in huffman_tables
                ):
                    return False
                scan_components.append((
                    component_id,
                    component[1],
                    component[2],
                    huffman_tables[(0, dc_id)],
                    huffman_tables[(1, ac_id)],
                ))
                scan_ids.add(component_id)
                offset += 2

            if len(scan_components) == 1:
                # A non-interleaved sequential scan uses the scan component's
                # dimensions on the frame's maximum-sampling grid. Using the
                # full frame dimensions for a subsampled component rejects
                # valid ImageIO/cjpeg multiscan JPEGs.
                component = scan_components[0]
                max_h = max(item[1] for item in frame["components"])
                max_v = max(item[2] for item in frame["components"])
                total_units = (
                    (frame["width"] * component[1] + 8 * max_h - 1) // (8 * max_h)
                ) * ((frame["height"] * component[2] + 8 * max_v - 1) // (8 * max_v))
                scan_blocks = [(component[3], component[4])]
            else:
                max_h = max(component[1] for component in frame["components"])
                max_v = max(component[2] for component in frame["components"])
                total_units = (
                    (frame["width"] + 8 * max_h - 1) // (8 * max_h)
                ) * ((frame["height"] + 8 * max_v - 1) // (8 * max_v))
                scan_blocks = [
                    (component[3], component[4])
                    for component in scan_components
                    for _ in range(component[1] * component[2])
                ]
            entropy_chunks: list[bytes] = []
            restart_markers: list[int] = []
            entropy = bytearray()
            entropy_start = position
            while position < len(raw):
                if raw[position] != 0xFF:
                    entropy.append(raw[position])
                    position += 1
                    continue
                marker_start = position
                position += 1
                while position < len(raw) and raw[position] == 0xFF:
                    position += 1
                if position >= len(raw):
                    return False
                entropy_marker = raw[position]
                position += 1
                if entropy_marker == 0x00:
                    entropy.append(0xFF)
                    continue
                if 0xD0 <= entropy_marker <= 0xD7:
                    entropy_chunks.append(bytes(entropy))
                    entropy.clear()
                    restart_markers.append(entropy_marker)
                    continue
                position = marker_start
                break
            if position <= entropy_start or not entropy:
                return False
            entropy_chunks.append(bytes(entropy))
            if not consume_scan(entropy_chunks, restart_markers, total_units, scan_blocks, restart_interval):
                return False
            seen_components.update(scan_ids)
            scan_count += 1
            continue

        # APPn/COM and other metadata segments are bounded by the outer image
        # size. Unsupported coding markers have already been rejected above.
        if marker in {0xCC, 0xDC, 0xDE, 0xDF}:
            return False

    return False


def _validate_calendar_icon_asset(value: object) -> None:
    # CalendarIconAsset's legacy decoder permits omitted/null version/hash.
    if not isinstance(value, dict) or not {"format", "bytes"}.issubset(value) or set(value) - {
        "schemaVersion", "contentHash", "format", "bytes",
    }:
        raise ValueError("invalid calendar icon asset")
    version = value.get("schemaVersion")
    if version is not None and (type(version) is not int or version != 1):
        raise ValueError("invalid calendar icon version")
    if not _is_choice(value["format"], {"png", "jpeg"}) or not isinstance(value["bytes"], str):
        raise ValueError("invalid calendar icon encoding")
    try:
        raw = base64.b64decode(value["bytes"].encode("ascii"), validate=True)
    except (UnicodeEncodeError, binascii.Error):
        raise ValueError("invalid calendar icon bytes") from None
    if not raw or len(raw) > CALENDAR_ICON_MAX_BYTES or base64.b64encode(raw).decode("ascii") != value["bytes"]:
        raise ValueError("invalid calendar icon bytes")
    valid = _validate_png_structure(raw) if value["format"] == "png" else _validate_jpeg_structure(raw)
    if not valid:
        raise ValueError("invalid calendar icon structure")
    digest = value.get("contentHash")
    if digest is not None and (not isinstance(digest, str) or digest != hashlib.sha256(raw).hexdigest()):
        raise ValueError("invalid calendar icon digest")


def _validate_calendar_item(value: object, *, now: datetime | None = None) -> None:
    required = {"id", "title", "status", "start", "end", "createdAt", "updatedAt"}
    optional = {"kind", "icon", "iconAsset", "systemIconName", "timeZoneIdentifier", "recurrence", "deletedAt"}
    if not isinstance(value, dict) or not required.issubset(value) or set(value) - required - optional:
        raise ValueError("invalid calendar item fields")
    identifier = value["id"]
    if not isinstance(identifier, str) or not re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", identifier
    ):
        raise ValueError("invalid calendar item id")
    if (
        not isinstance(value["title"], str)
        or not value["title"].strip()
        or len(value["title"].strip().encode("utf-8")) > 240
    ):
        raise ValueError("invalid calendar title")
    if not _is_choice(value["status"], {"planned", "in_progress", "done", "aborted", "blocked"}):
        raise ValueError("invalid calendar progress")
    kind = value.get("kind")
    if kind is not None and not _is_choice(kind, {"event", "todo", "dailySchedule", "daily_schedule"}):
        raise ValueError("invalid calendar kind")
    if _calendar_timestamp(value["end"]) <= _calendar_timestamp(value["start"]):
        raise ValueError("invalid calendar interval")
    created_at = _calendar_timestamp(value["createdAt"])
    updated_at = _calendar_timestamp(value["updatedAt"])
    deleted_at = _calendar_timestamp(value["deletedAt"]) if value.get("deletedAt") is not None else None
    validation_now = _calendar_now_utc() if now is None else now
    if validation_now.tzinfo is None:
        raise ValueError("invalid calendar validation clock")
    clock_limit = validation_now.astimezone(timezone.utc) + CALENDAR_MAX_CLOCK_SKEW
    if any(timestamp > clock_limit for timestamp in (created_at, updated_at, deleted_at) if timestamp is not None):
        raise ValueError("calendar clock is too far in the future")
    if created_at > updated_at:
        raise ValueError("calendar clock ordering is invalid")
    if deleted_at is not None and not created_at <= deleted_at <= updated_at:
        raise ValueError("calendar deletion clock ordering is invalid")
    # Optional icon/timezone strings are normalized by the native decoder
    # (unsupported symbols/zones are discarded). Preserve that legacy policy.
    for field in ("icon", "systemIconName", "timeZoneIdentifier"):
        if value.get(field) is not None and not isinstance(value[field], str):
            raise ValueError("invalid calendar optional text")
    if value.get("iconAsset") is not None:
        _validate_calendar_icon_asset(value["iconAsset"])
    recurrence = value.get("recurrence")
    if recurrence is not None:
        if not isinstance(recurrence, dict) or "frequency" not in recurrence or set(recurrence) - {"frequency", "interval", "until"}:
            raise ValueError("invalid calendar recurrence")
        if not _is_choice(recurrence["frequency"], {"daily", "weekly", "monthly", "yearly"}):
            raise ValueError("invalid calendar frequency")
        interval = recurrence.get("interval")
        # Swift explicitly defaults omitted/null to 1 and clamps <=0 to 1.
        if interval is not None and (type(interval) is not int or abs(interval) > CALENDAR_MAX_REVISION):
            raise ValueError("invalid calendar recurrence interval")
        if recurrence.get("until") is not None:
            _calendar_timestamp(recurrence["until"])


def _parse_calendar_document(body: bytes, *, now: datetime | None = None) -> dict:
    if len(body) > CALENDAR_MAX_BODY_SIZE:
        raise HTTPException(status_code=413, detail="calendar body exceeds limit")
    try:
        decoded = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
            parse_int=_calendar_integer,
            parse_float=_calendar_float,
        )
        if (
            not isinstance(decoded, dict)
            or set(decoded) != {"schemaVersion", "items"}
            or type(decoded["schemaVersion"]) is not int
            or decoded["schemaVersion"] != CALENDAR_SCHEMA_VERSION
            or not isinstance(decoded["items"], list)
            or len(decoded["items"]) > CALENDAR_MAX_ITEMS
        ):
            raise ValueError("invalid calendar resource")
        validation_now = _calendar_now_utc() if now is None else now
        identifiers = set()
        for item in decoded["items"]:
            _validate_calendar_item(item, now=validation_now)
            identifier = item["id"].lower()
            if identifier in identifiers:
                raise ValueError("duplicate calendar item id")
            identifiers.add(identifier)
        # Reject escaped lone surrogates that Swift cannot decode as UTF-8.
        json.dumps(decoded, ensure_ascii=False, allow_nan=False).encode("utf-8")
    except (UnicodeError, ValueError, TypeError, OverflowError, RecursionError) as exc:
        raise HTTPException(status_code=400, detail="invalid calendar resource") from exc
    return decoded


def _calendar_digest(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def _calendar_etag(revision: int, digest: str) -> str:
    return f'"calendar-v1-r{revision}-{digest}"'


def _valid_calendar_etag(value: object) -> bool:
    if not isinstance(value, str):
        return False
    match = CALENDAR_ETAG_PATTERN.fullmatch(value)
    if match is None:
        return False
    revision_text = match.group(1)
    if len(revision_text) > len(str(CALENDAR_MAX_REVISION)):
        return False
    try:
        revision = int(revision_text)
    except (TypeError, ValueError):
        return False
    return revision <= CALENDAR_MAX_REVISION and str(revision) == revision_text


def _calendar_default_body() -> bytes:
    return b'{"schemaVersion":1,"items":[]}'


def _calendar_default_metadata(body: bytes) -> dict:
    return {
        "schemaVersion": 1,
        "domain": "calendar",
        "authority": "gateway",
        "revision": 0,
        "bodyDigest": _calendar_digest(body),
        "idempotency": [],
        # Calendar deletion tombstones live in the versioned opaque item
        # payload.  The gateway preserves them without inventing timestamps or
        # identifiers it cannot validate as the client's source of truth.
        "tombstones": [],
    }


def _calendar_idempotency_window(records: list[dict], new_record: dict) -> list[dict]:
    """Return the newest bounded replay records in revision order.

    The authority envelope stores only the latest replay window.  The current
    Calendar body remains the source of truth; a retained record is used to
    recognize a safe retry and avoid incrementing the authority revision a
    second time.  Expired keys are deliberately not retained forever because
    an unbounded idempotency ledger would eventually make Calendar read-only.
    """
    window_size = max(1, CALENDAR_MAX_IDEMPOTENCY_RECORDS)
    return [*records, new_record][-window_size:]


def _validate_calendar_metadata(value: object, body: bytes) -> dict:
    if not isinstance(value, dict) or set(value) != {
        "schemaVersion", "domain", "authority", "revision", "bodyDigest", "idempotency", "tombstones",
    }:
        raise _CalendarStateUnavailable
    revision = value["revision"]
    if (
        type(value["schemaVersion"]) is not int
        or value["schemaVersion"] != 1
        or isinstance(revision, bool)
        or not isinstance(revision, int)
        or revision < 0
        or revision > CALENDAR_MAX_REVISION
        or value["domain"] != "calendar"
        or value["authority"] != "gateway"
        or not isinstance(value["bodyDigest"], str)
        or not SYNC_FINGERPRINT_PATTERN.fullmatch(value["bodyDigest"])
        or value["bodyDigest"] != _calendar_digest(body)
        or not isinstance(value["idempotency"], list)
        or len(value["idempotency"]) > CALENDAR_MAX_IDEMPOTENCY_RECORDS
        or not isinstance(value["tombstones"], list)
        or len(value["tombstones"]) > CALENDAR_MAX_IDEMPOTENCY_RECORDS
    ):
        raise _CalendarStateUnavailable

    keys: set[str] = set()
    for record in value["idempotency"]:
        if not isinstance(record, dict) or set(record) != {"key", "fingerprint", "revision"}:
            raise _CalendarStateUnavailable
        key = record["key"]
        record_revision = record["revision"]
        if (
            not isinstance(key, str)
            or not CALENDAR_IDEMPOTENCY_KEY_PATTERN.fullmatch(key)
            or key in keys
            or not isinstance(record["fingerprint"], str)
            or not SYNC_FINGERPRINT_PATTERN.fullmatch(record["fingerprint"])
            or isinstance(record_revision, bool)
            or not isinstance(record_revision, int)
            or record_revision < 0
            or record_revision > revision
        ):
            raise _CalendarStateUnavailable
        keys.add(key)

    tombstone_ids: set[str] = set()
    for tombstone in value["tombstones"]:
        if not isinstance(tombstone, dict) or set(tombstone) != {
            "schemaVersion", "domain", "entityID", "revision", "idempotencyKey", "authority", "deletedAt",
        }:
            raise _CalendarStateUnavailable
        entity_id = tombstone["entityID"]
        tombstone_revision = tombstone["revision"]
        deleted_at = tombstone["deletedAt"]
        if (
            type(tombstone["schemaVersion"]) is not int
            or tombstone["schemaVersion"] != 1
            or tombstone["domain"] != "calendar"
            or tombstone["authority"] != "gateway"
            or not isinstance(entity_id, str)
            or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9._:-]{0,127})?", entity_id)
            or entity_id in tombstone_ids
            or isinstance(tombstone_revision, bool)
            or not isinstance(tombstone_revision, int)
            or not 0 < tombstone_revision <= revision
            or not isinstance(tombstone["idempotencyKey"], str)
            or not CALENDAR_IDEMPOTENCY_KEY_PATTERN.fullmatch(tombstone["idempotencyKey"])
            or tombstone["idempotencyKey"] in keys
            or not isinstance(deleted_at, str)
            or not _is_usage_observed_timestamp(deleted_at)
        ):
            raise _CalendarStateUnavailable
        tombstone_ids.add(entity_id)
        keys.add(tombstone["idempotencyKey"])
    return value


def _decode_calendar_state(state_body: bytes) -> tuple[bytes, dict, dict]:
    """Decode the single committed Calendar envelope.

    The legacy body/metadata files remain compatibility projections for
    operators and migration.  Once a state envelope exists, it is the only
    authority consulted by the gateway, so a torn projection cannot become a
    second or partially committed Calendar state.
    """
    try:
        decoded = json.loads(
            state_body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
        if not isinstance(decoded, dict) or set(decoded) != {
            "schemaVersion", "bodyBase64", "metadata",
        } or type(decoded["schemaVersion"]) is not int or decoded["schemaVersion"] != CALENDAR_STATE_SCHEMA_VERSION:
            raise ValueError("invalid calendar state envelope")
        encoded_body = decoded["bodyBase64"]
        if not isinstance(encoded_body, str) or not encoded_body:
            raise ValueError("invalid calendar state body")
        body = base64.b64decode(encoded_body.encode("ascii"), validate=True)
        if len(body) > CALENDAR_MAX_BODY_SIZE or base64.b64encode(body).decode("ascii") != encoded_body:
            raise ValueError("invalid calendar state body")
        document = _parse_calendar_document(body)
        metadata = _validate_calendar_metadata(decoded["metadata"], body)
        return body, document, metadata
    except (UnicodeDecodeError, UnicodeEncodeError, ValueError, binascii.Error, HTTPException, RecursionError) as exc:
        raise _CalendarStateUnavailable from exc


def _load_calendar_state() -> tuple[bytes, dict, dict]:
    """Return body, decoded document, and validated authority metadata."""
    state_body = _read_bounded_state_file(_calendar_state_path(), CALENDAR_STATE_MAX_SIZE)
    if state_body is not None:
        return _decode_calendar_state(state_body)

    calendar_body = _read_bounded_state_file(CALENDAR_PATH, CALENDAR_MAX_BODY_SIZE)
    metadata_body = _read_bounded_state_file(_calendar_metadata_path(), CALENDAR_METADATA_MAX_SIZE)
    if calendar_body is None and metadata_body is None:
        calendar_body = _calendar_default_body()
        return calendar_body, _parse_calendar_document(calendar_body), _calendar_default_metadata(calendar_body)
    if calendar_body is None:
        raise _CalendarStateUnavailable
    document = _parse_calendar_document(calendar_body)
    # A pre-versioning Calendar body is safe to adopt at revision zero after
    # strict validation. Metadata without its body is instead a torn publish.
    if metadata_body is None:
        return calendar_body, document, _calendar_default_metadata(calendar_body)
    try:
        decoded_metadata = json.loads(
            metadata_body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise _CalendarStateUnavailable from exc
    metadata = _validate_calendar_metadata(decoded_metadata, calendar_body)
    return calendar_body, document, metadata


def _calendar_metadata_bytes(metadata: dict) -> bytes:
    body = json.dumps(metadata, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    if len(body) > CALENDAR_METADATA_MAX_SIZE:
        raise ValueError("calendar metadata exceeds limit")
    return body


def _calendar_retry_intent_bytes(revision: int, body: bytes) -> bytes:
    return json.dumps(
        {"bodyDigest": _calendar_digest(body), "revision": revision},
        sort_keys=True,
        separators=(",", ":"),
        allow_nan=False,
    ).encode("utf-8")


def _write_calendar_retry_intent(revision: int, body: bytes) -> bool:
    """Persist the retry source before committing a new authority revision."""
    try:
        _atomic_write_bytes(_calendar_retry_path(), _calendar_retry_intent_bytes(revision, body))
    except (OSError, ValueError):
        return False
    return True


def _read_calendar_retry_intent() -> dict | None:
    """Read the auxiliary retry marker without making it a source of truth."""
    try:
        raw = _read_bounded_state_file(_calendar_retry_path(), 512)
        if raw is None:
            return None
        value = json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
        if not isinstance(value, dict) or set(value) != {"bodyDigest", "revision"}:
            return None
        revision = value["revision"]
        if (
            isinstance(revision, bool)
            or not isinstance(revision, int)
            or revision < 0
            or revision > CALENDAR_MAX_REVISION
            or not isinstance(value["bodyDigest"], str)
            or not SYNC_FINGERPRINT_PATTERN.fullmatch(value["bodyDigest"])
        ):
            return None
        return value
    except (_CalendarStateUnavailable, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        return None


def _clear_calendar_retry_intent() -> None:
    try:
        _calendar_retry_path().unlink()
    except (FileNotFoundError, OSError):
        # The marker is only a retry hint. Failure to remove it is safe: the
        # next read/replay will retry the same durable authority revision.
        pass


def _repair_calendar_projections(body: bytes, metadata: dict) -> bool:
    """Repair compatibility projections from the authoritative state envelope."""
    try:
        metadata_body = _calendar_metadata_bytes(metadata)
        _atomic_write_bytes(_calendar_metadata_path(), metadata_body)
        _atomic_write_bytes(CALENDAR_PATH, body)
    except (OSError, ValueError):
        return False
    return True


async def _broadcast_calendar_revision(revision: int) -> bool:
    """Never turn a committed Calendar revision into an HTTP failure."""
    try:
        delivered = await broadcaster.broadcast({"type": "calendar_changed", "revision": revision})
    except Exception:
        # The durable retry marker remains in place. A replay or a subsequent
        # authoritative read repeats the notification without losing state.
        return False
    # Test doubles from the existing suite predate the boolean result. Treat
    # their implicit None as successful while real bounded fan-out reports a
    # failed delivery explicitly and keeps the retry marker durable.
    return delivered is not False


def _calendar_response(
    body: bytes,
    revision: int,
    *,
    status_code: int = 200,
    replay: bool = False,
    projection_pending: bool = False,
) -> Response:
    headers = {
        "Cache-Control": "no-store",
        "ETag": _calendar_etag(revision, _calendar_digest(body)),
        "X-LifeOS-Revision": str(revision),
        "X-LifeOS-Schema-Version": str(CALENDAR_SCHEMA_VERSION),
    }
    if replay:
        headers["X-LifeOS-Idempotent-Replay"] = "true"
    if projection_pending:
        headers["X-LifeOS-Projection-Repair"] = "pending"
    return Response(content=body, status_code=status_code, media_type="application/json", headers=headers)


def _calendar_header(request: Request, name: str) -> str | None:
    values = _raw_header_values(request, name)
    if len(values) != 1:
        return None
    try:
        return values[0].decode("latin-1")
    except UnicodeDecodeError:
        return None


def _raw_header_values(request: Request, name: str) -> list[bytes]:
    wanted = name.lower().encode("ascii")
    scope = getattr(request, "scope", None)
    if isinstance(scope, dict):
        return [
            value for header, value in scope.get("headers", [])
            if isinstance(header, bytes) and header.lower() == wanted and isinstance(value, bytes)
        ]
    # Keep the helper usable with narrow request doubles in unit tests. Real
    # Starlette requests always take the raw-scope branch above, which retains
    # duplicate-header visibility for the security checks.
    headers = getattr(request, "headers", {})
    value = headers.get(name) if hasattr(headers, "get") else None
    if isinstance(value, str):
        return [value.encode("latin-1")]
    if isinstance(value, bytes):
        return [value]
    return []


def _bounded_http_error(status_code: int, *, too_large_detail: str, timeout_detail: str) -> HTTPException:
    detail = (
        too_large_detail if status_code == 413
        else timeout_detail if status_code == 408
        else "invalid content length"
    )
    return HTTPException(status_code=status_code, detail=detail)


async def _read_bounded_request_body(
    request: Request,
    *,
    maximum: int,
    timeout: float,
    error_factory: Callable[[int], Exception],
) -> bytes:
    """Read one bounded request and require Content-Length to match the stream.

    A missing Content-Length remains valid for streamed/native callers. When it
    is present, one strict decimal declaration is required and the consumed
    byte count must match it before any route parser sees the body.
    """
    try:
        async with asyncio.timeout(timeout):
            length_values = _raw_header_values(request, "content-length")
            if len(length_values) > 1:
                raise error_factory(400)

            declared_length: int | None = None
            if length_values:
                try:
                    raw_length = length_values[0].decode("ascii")
                except UnicodeDecodeError as exc:
                    raise error_factory(400) from exc
                if re.fullmatch(r"[0-9]+", raw_length) is None:
                    raise error_factory(400)
                try:
                    declared_length = int(raw_length)
                except (OverflowError, ValueError) as exc:
                    raise error_factory(400) from exc
                if declared_length > maximum:
                    raise error_factory(413)

            body = bytearray()
            async for chunk in request.stream():
                if len(body) + len(chunk) > maximum:
                    raise error_factory(413)
                body.extend(chunk)
            if declared_length is not None and declared_length != len(body):
                raise error_factory(400)
            return bytes(body)
    except TimeoutError as exc:
        raise error_factory(408) from exc


async def _read_calendar_body(request: Request) -> bytes:
    return await _read_bounded_request_body(
        request,
        maximum=CALENDAR_MAX_BODY_SIZE,
        timeout=CALENDAR_BODY_TIMEOUT,
        error_factory=lambda status_code: _bounded_http_error(
            status_code,
            too_large_detail="calendar body exceeds limit",
            timeout_detail="calendar request timeout",
        ),
    )


def _safe_document_id(value) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (ValueError, TypeError, AttributeError) as exc:
        raise HTTPException(status_code=400, detail="metadata.id must be a UUID") from exc


class _DocumentMultipartError(Exception):
    """A bounded, intentionally non-descriptive multipart request failure."""

    def __init__(self, status_code: int) -> None:
        if status_code not in {400, 408, 413, 503}:
            raise ValueError("unsupported document multipart status")
        super().__init__()
        self.status_code = status_code


class _DocumentMultipartPayload:
    """The two accepted document fields and a seekable bounded temp file."""

    def __init__(self, metadata: str, filename: str, file: BinaryIO) -> None:
        self.metadata = metadata
        self.filename = filename
        self.file = file

    def close(self) -> None:
        try:
            self.file.close()
        except OSError:
            pass


class _BoundedDocumentMultipartParser:
    """Stream exactly one metadata field and one file into bounded storage.

    Starlette's implicit ``Request.form()`` path constructs a complete list of
    parsed fields before the route runs.  This parser uses the installed
    python-multipart callback API directly so raw bytes, headers, fields, and
    the file are checked while the ASGI stream is being consumed.
    """

    def __init__(self, request: Request) -> None:
        content_type_values = _raw_header_values(request, "content-type")
        if len(content_type_values) != 1 or len(content_type_values[0]) > 4096:
            raise _DocumentMultipartError(400)
        try:
            content_type, parameters = parse_options_header(content_type_values[0])
        except (TypeError, ValueError, UnicodeError, AssertionError):
            raise _DocumentMultipartError(400) from None
        if content_type != b"multipart/form-data":
            raise _DocumentMultipartError(400)

        boundary = parameters.get(b"boundary")
        if (
            not isinstance(boundary, bytes)
            or not 1 <= len(boundary) <= 70
            or b"\r" in boundary
            or b"\n" in boundary
        ):
            raise _DocumentMultipartError(400)
        charset = parameters.get(b"charset", b"utf-8")
        if not isinstance(charset, bytes) or not 1 <= len(charset) <= 64:
            raise _DocumentMultipartError(400)
        try:
            self._charset = charset.decode("ascii")
        except UnicodeDecodeError:
            raise _DocumentMultipartError(400) from None

        self._raw_limit = (
            DOCUMENT_MAX_UPLOAD_SIZE
            + DOCUMENT_METADATA_MAX_SIZE
            + DOCUMENT_MULTIPART_OVERHEAD
        )
        if self._raw_limit < 0:
            raise _DocumentMultipartError(413)
        self._part_count = 0
        self._headers: dict[bytes, bytes] = {}
        self._partial_header_field = bytearray()
        self._partial_header_value = bytearray()
        self._current_kind: str | None = None
        self._metadata_bytes = bytearray()
        self._metadata: str | None = None
        self._filename = ""
        self._file: BinaryIO | None = None
        self._file_size = 0
        self._file_seen = False
        self._metadata_seen = False
        self._ended = False
        self._parser = multipart.MultipartParser(
            boundary,
            {
                "on_part_begin": self._on_part_begin,
                "on_part_data": self._on_part_data,
                "on_part_end": self._on_part_end,
                "on_header_field": self._on_header_field,
                "on_header_value": self._on_header_value,
                "on_header_end": self._on_header_end,
                "on_headers_finished": self._on_headers_finished,
                "on_end": self._on_end,
            },
            max_size=self._raw_limit,
        )

    @staticmethod
    def _callback_bytes(data: bytes, start: int, end: int) -> bytes:
        if not isinstance(data, bytes) or not isinstance(start, int) or not isinstance(end, int):
            raise _DocumentMultipartError(400)
        return data[start:end]

    def _on_part_begin(self) -> None:
        self._part_count += 1
        if self._part_count > 2:
            raise _DocumentMultipartError(400)
        self._headers = {}
        self._partial_header_field.clear()
        self._partial_header_value.clear()
        self._current_kind = None

    def _on_header_field(self, data: bytes, start: int, end: int) -> None:
        chunk = self._callback_bytes(data, start, end)
        if len(self._partial_header_field) + len(chunk) > DOCUMENT_MULTIPART_HEADER_FIELD_MAX_SIZE:
            raise _DocumentMultipartError(413)
        self._partial_header_field.extend(chunk)

    def _on_header_value(self, data: bytes, start: int, end: int) -> None:
        chunk = self._callback_bytes(data, start, end)
        if len(self._partial_header_value) + len(chunk) > DOCUMENT_MULTIPART_HEADER_VALUE_MAX_SIZE:
            raise _DocumentMultipartError(413)
        self._partial_header_value.extend(chunk)

    def _on_header_end(self) -> None:
        field = bytes(self._partial_header_field).lower()
        value = bytes(self._partial_header_value)
        if not field or field in self._headers:
            raise _DocumentMultipartError(400)
        if len(self._headers) >= DOCUMENT_MULTIPART_MAX_HEADERS_PER_PART:
            raise _DocumentMultipartError(413)
        self._headers[field] = value
        self._partial_header_field.clear()
        self._partial_header_value.clear()

    def _decode_header_value(self, value: bytes) -> str:
        try:
            return value.decode(self._charset)
        except (LookupError, UnicodeDecodeError):
            return value.decode("latin-1")

    def _on_headers_finished(self) -> None:
        content_disposition = self._headers.get(b"content-disposition")
        if content_disposition is None:
            raise _DocumentMultipartError(400)
        try:
            disposition, options = parse_options_header(content_disposition)
        except (TypeError, ValueError, UnicodeError, AssertionError):
            raise _DocumentMultipartError(400) from None
        name = options.get(b"name")
        has_filename = b"filename" in options
        if disposition != b"form-data" or name not in {b"file", b"metadata"}:
            raise _DocumentMultipartError(400)

        if has_filename:
            if name != b"file" or self._file_seen:
                raise _DocumentMultipartError(400)
            self._file_seen = True
            self._filename = self._decode_header_value(options[b"filename"])
            try:
                self._file = tempfile.TemporaryFile(mode="w+b")
            except OSError:
                raise _DocumentMultipartError(503) from None
            self._current_kind = "file"
            return

        if name != b"metadata" or self._metadata_seen:
            raise _DocumentMultipartError(400)
        self._metadata_seen = True
        self._current_kind = "metadata"

    def _on_part_data(self, data: bytes, start: int, end: int) -> None:
        chunk = self._callback_bytes(data, start, end)
        if self._current_kind == "metadata":
            if len(self._metadata_bytes) + len(chunk) > DOCUMENT_METADATA_MAX_SIZE:
                raise _DocumentMultipartError(413)
            self._metadata_bytes.extend(chunk)
            return
        if self._current_kind != "file" or self._file is None:
            raise _DocumentMultipartError(400)
        if self._file_size + len(chunk) > DOCUMENT_MAX_UPLOAD_SIZE:
            raise _DocumentMultipartError(413)
        try:
            written = self._file.write(chunk)
        except (OSError, ValueError):
            raise _DocumentMultipartError(503) from None
        if written != len(chunk):
            raise _DocumentMultipartError(503)
        self._file_size += len(chunk)

    def _on_part_end(self) -> None:
        if self._current_kind == "metadata":
            self._metadata = self._decode_header_value(bytes(self._metadata_bytes))
        elif self._current_kind != "file":
            raise _DocumentMultipartError(400)
        self._current_kind = None

    def _on_end(self) -> None:
        self._ended = True

    def close(self) -> None:
        if self._file is not None:
            try:
                self._file.close()
            except OSError:
                pass
            self._file = None

    async def read(self, request: Request) -> _DocumentMultipartPayload:
        try:
            async with asyncio.timeout(DOCUMENT_BODY_TIMEOUT):
                return await self._read_impl(request)
        except TimeoutError:
            self.close()
            raise _DocumentMultipartError(408) from None

    async def _read_impl(self, request: Request) -> _DocumentMultipartPayload:
        try:
            length_values = _raw_header_values(request, "content-length")
            if len(length_values) > 1:
                raise _DocumentMultipartError(400)
            declared_length: int | None = None
            if length_values:
                try:
                    raw_length = length_values[0].decode("ascii")
                except UnicodeDecodeError:
                    raise _DocumentMultipartError(400) from None
                if re.fullmatch(r"[0-9]+", raw_length) is None:
                    raise _DocumentMultipartError(400)
                try:
                    declared_length = int(raw_length)
                except (OverflowError, ValueError):
                    raise _DocumentMultipartError(400) from None
                if declared_length > self._raw_limit:
                    raise _DocumentMultipartError(413)

            raw_size = 0
            async for chunk in request.stream():
                if not isinstance(chunk, bytes):
                    raise _DocumentMultipartError(400)
                raw_size += len(chunk)
                if raw_size > self._raw_limit:
                    raise _DocumentMultipartError(413)
                try:
                    consumed = self._parser.write(chunk)
                except _DocumentMultipartError:
                    raise
                except MultipartParseError:
                    raise _DocumentMultipartError(400) from None
                if consumed != len(chunk):
                    raise _DocumentMultipartError(413)

            if declared_length is not None and declared_length != raw_size:
                raise _DocumentMultipartError(400)
            if (
                not self._ended
                or self._current_kind is not None
                or not self._file_seen
                or not self._metadata_seen
                or self._metadata is None
                or self._file is None
            ):
                raise _DocumentMultipartError(400)
            try:
                self._file.flush()
                self._file.seek(0)
            except (OSError, ValueError):
                raise _DocumentMultipartError(503) from None
            file = self._file
            self._file = None
            return _DocumentMultipartPayload(self._metadata, self._filename, file)
        except _DocumentMultipartError:
            self.close()
            raise
        except asyncio.CancelledError:
            self.close()
            raise
        except ClientDisconnect:
            self.close()
            raise _DocumentMultipartError(400) from None
        except (
            MultipartParseError,
            OSError,
            TypeError,
            ValueError,
            UnicodeError,
            KeyError,
            IndexError,
            AssertionError,
        ):
            self.close()
            raise _DocumentMultipartError(400) from None


async def _read_document_multipart(request: Request) -> _DocumentMultipartPayload:
    parser = _BoundedDocumentMultipartParser(request)
    return await parser.read(request)


def _document_multipart_error_response(status_code: int) -> JSONResponse:
    if status_code == 408:
        error = "request_timeout"
    elif status_code == 413:
        error = "request_too_large"
    elif status_code == 503:
        error = "documents_unavailable"
    else:
        error = "invalid_request"
    return JSONResponse({"error": error}, status_code=status_code)


class _DocumentIndexError(Exception):
    """The durable document index is missing, malformed, or unsafe."""


class _DocumentIndexTooLarge(_DocumentIndexError):
    """A new document index cannot fit the published response contract."""


class _LegacyDocumentPrivacyError(_DocumentIndexError):
    """A legacy entry cannot be published without exposing unknown data."""


def _valid_document_index_filename(value: object) -> bool:
    return isinstance(value, str) and DOCUMENT_INDEX_FILENAME_PATTERN.fullmatch(value) is not None


def _serialize_document_index(index: list[dict]) -> bytes:
    if len(index) > DOCUMENT_INDEX_MAX_ENTRIES:
        raise _DocumentIndexTooLarge("document index entry limit exceeded")
    try:
        body = json.dumps(
            index,
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (UnicodeError, TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise _DocumentIndexError("document index cannot be serialized") from exc
    if len(body) > DOCUMENT_INDEX_MAX_SIZE:
        raise _DocumentIndexTooLarge("document index size limit exceeded")
    return body


def _document_index_id(value: object) -> str:
    try:
        return _canonical_document_id(value)
    except ValueError as exc:
        raise _DocumentIndexError("document index id is invalid") from exc


def _canonical_document_id(value: object) -> str:
    if type(value) is not str:
        raise ValueError("document id is not a string")
    if re.fullmatch(
        r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}", value
    ) is None:
        raise ValueError("document id is invalid")
    try:
        canonical = str(uuid.UUID(value))
    except (ValueError, AttributeError) as exc:
        raise ValueError("document id is invalid") from exc
    return canonical


def _bounded_document_string(value: object, maximum: int) -> str:
    if type(value) is not str or len(value) > maximum:
        raise ValueError("document string exceeds its bound")
    return value


def _mask_tax_identifier(value: str) -> str:
    trimmed = value.strip()
    if not trimmed:
        return trimmed
    digits = "".join(character for character in trimmed if "0" <= character <= "9")
    if len(digits) < 2:
        # Never expose a non-digit suffix from malformed identifier input.
        return "*" * 8
    return "*" * 8 + digits[-2:]


def _replace_tax_identifier_match(match: re.Match[str]) -> str:
    whole = match.group(0)
    start = match.start("value") - match.start()
    return whole[:start] + _mask_tax_identifier(match.group("value"))


def _replace_bare_tax_identifier_match(match: re.Match[str], source: str) -> str:
    value = match.group("value")
    digits = "".join(character for character in value if "0" <= character <= "9")
    compact = "".join(character for character in value if character == "*" or "0" <= character <= "9")
    marker_count = compact.count("*")
    is_grouped_identifier = _TAX_GROUPED_IDENTIFIER_PATTERN.fullmatch(value) is not None
    # A star can stand in for a hidden identifier digit (for example
    # ``*2345678901`` or ``12345*78901``), while a trailing star may be a
    # legacy redaction marker after all eleven digits.  A plain 12-digit
    # number remains ordinary numeric text.
    is_eleven_digit_identifier = len(digits) == 11 or (
        len(compact) == 11 and marker_count >= 1 and len(digits) >= 2
    )
    if not is_grouped_identifier and not is_eleven_digit_identifier:
        return value

    # An amount with an explicit decimal fraction is ordinary numeric text,
    # not an unlabelled 11-digit identifier.  Tax-labelled values are handled
    # before this callback and are always redacted.
    end = match.end()
    suffix = source[end:end + 4]
    if "*" not in value and re.match(r"[.,][0-9]{1,2}(?![0-9])", suffix):
        return value
    return _mask_tax_identifier(value)


def _redact_tax_text(value: str) -> str:
    redacted = _TAX_GERMAN_IDENTIFIER_PATTERN.sub(_replace_tax_identifier_match, value)
    redacted = _TAX_IDENTIFIER_PATTERN.sub(_replace_tax_identifier_match, redacted)
    redacted = _TAX_GROUPED_IDENTIFIER_PATTERN.sub(
        lambda match: _replace_bare_tax_identifier_match(match, redacted),
        redacted,
    )
    redacted = _TAX_BARE_IDENTIFIER_PATTERN.sub(
        lambda match: _replace_bare_tax_identifier_match(match, redacted),
        redacted,
    )
    # Canonicalize already-masked values everywhere, including generic
    # evidence and titles, so publication has one stable mask contract.
    redacted = _TAX_MASKED_IDENTIFIER_PATTERN.sub(
        lambda match: "*" * 8 + match.group("suffix"),
        redacted,
    )
    return redacted


def _mask_tax_identifier_value(value: str) -> str:
    trimmed = value.strip()
    redacted = _redact_tax_text(trimmed)
    if redacted != trimmed:
        return redacted
    return _mask_tax_identifier(trimmed)


def _collect_document_identifier_replacements(value: object) -> dict[str, str]:
    """Collect bounded raw identifier values before any field is normalized."""
    if not isinstance(value, dict):
        return {}
    replacements: dict[str, str] = {}
    for field in ("taxpayerIdentifier", "referenceIdentifier"):
        candidate = value.get(field)
        if not isinstance(candidate, dict):
            continue
        raw_value = candidate.get("value")
        if type(raw_value) is not str or len(raw_value) > DOCUMENT_MAX_FIELD_CHARACTERS:
            continue
        safe_value = _mask_tax_identifier_value(raw_value)
        for source in {raw_value, raw_value.strip()}:
            if source and source != safe_value:
                replacements[source] = safe_value
    return replacements


def _replace_document_identifier_mappings(
    value: object,
    replacements: dict[str, str],
    *,
    top_level: bool = False,
) -> object:
    """Replace known raw identifiers in every native publication text leaf."""
    if isinstance(value, str):
        replaced = value
        for source, safe_value in sorted(
            replacements.items(), key=lambda item: len(item[0]), reverse=True
        ):
            replaced = re.sub(
                re.escape(source),
                lambda _match: safe_value,
                replaced,
                flags=re.IGNORECASE,
            )
        return replaced
    if isinstance(value, list):
        return [
            _replace_document_identifier_mappings(item, replacements)
            for item in value
        ]
    if isinstance(value, dict):
        return {
            key: item if top_level and key == "id" else _replace_document_identifier_mappings(item, replacements)
            for key, item in value.items()
        }
    return value


def _document_text_values(value: object, *, in_evidence: bool = False):
    """Yield bounded publication text leaves with their evidence context."""
    if isinstance(value, str):
        yield value, in_evidence
    elif isinstance(value, list):
        for item in value:
            yield from _document_text_values(item, in_evidence=in_evidence)
    elif isinstance(value, dict):
        for key, item in value.items():
            if key == "id":
                continue
            yield from _document_text_values(
                item,
                in_evidence=in_evidence or key == "evidence",
            )


def _legacy_text_contains_unproven_identifier(
    value: str,
    *,
    visible_suffixes: set[str] | frozenset[str] = frozenset(),
    evidence: bool = False,
) -> bool:
    """Detect legacy identifier text without treating ordinary numbers as secrets."""
    redacted = _redact_tax_text(value)
    residual = _TAX_CANONICAL_MASK_PATTERN.sub("", redacted)
    residual = _TAX_MASKED_IDENTIFIER_PATTERN.sub("", residual)
    safe_spans = [match.span() for match in _TAX_LEGACY_SAFE_NUMBER_PATTERN.finditer(residual)]

    # Opaque all-caps tokens are common identifier/reference spellings. They
    # remain unproven even when another part of the same snippet is masked.
    if _TAX_LEGACY_SUSPICIOUS_ALPHA_TOKEN_PATTERN.search(residual):
        return True

    for match in _TAX_LEGACY_IDENTIFIER_TOKEN_PATTERN.finditer(residual):
        token = match.group(0)
        if any(character.isalpha() for character in token) and any(character.isdigit() for character in token):
            prefix = residual[:match.start()]
            label_match = re.search(
                r"(?i)\b(form|schedule)[ \t]+$",
                prefix[-64:],
            )
            if label_match:
                valid_tokens = (
                    _TAX_LEGACY_VALID_FORM_TOKENS
                    if label_match.group(1).casefold() == "form"
                    else _TAX_LEGACY_VALID_SCHEDULE_TOKENS
                )
                if token.casefold() in valid_tokens:
                    continue
            return True

    for match in _TAX_LEGACY_NUMERIC_TOKEN_PATTERN.finditer(residual):
        prefix = residual[:match.start()]
        page_context = re.search(
            r"(?i)\b(?:page|seite)[ \t]*[:#()/.\\-]*$",
            prefix[-64:],
        )
        if page_context:
            try:
                if int(match.group(0)) <= DOCUMENT_MAX_EVIDENCE_PAGE:
                    continue
            except ValueError:
                pass
            return True
        if _TAX_LEGACY_ORDINARY_NUMBER_CONTEXT_PATTERN.search(prefix[-64:]):
            continue
        if any(start <= match.start() and match.end() <= end for start, end in safe_spans):
            continue
        # A visible suffix is the only identifier fact retained by a masked
        # candidate. A legacy field outside an ordinary date/amount context
        # that contains a longer token ending in that suffix cannot be proven
        # safe from context alone.
        if any(
            suffix and match.group(0) != suffix and match.group(0).endswith(suffix)
            for suffix in visible_suffixes
        ):
            return True
        if _TAX_LEGACY_IDENTIFIER_CONTEXT_PATTERN.search(prefix[-64:]):
            return True
        # Evidence is published verbatim and may contain a bare legacy
        # identifier such as ``8642``.  A non-evidence numeric token is only
        # suspicious when it matches the visible suffix of a masked candidate;
        # this keeps tax years, page numbers, and ordinary prose available.
        if evidence:
            return True
    return False


def _document_evidence_is_clearly_ordinary(
    value: str,
    *,
    visible_suffixes: set[str] | frozenset[str] = frozenset(),
) -> bool:
    """Allow only bounded, ordinary evidence vocabulary after redaction."""
    redacted = _redact_tax_text(value)
    if _legacy_text_contains_unproven_identifier(
        redacted,
        visible_suffixes=visible_suffixes,
        evidence=True,
    ):
        return False
    residual = _TAX_LEGACY_ORDINARY_EVIDENCE_PAGE_PATTERN.sub("", redacted)
    residual = _TAX_LEGACY_ORDINARY_EVIDENCE_YEAR_PATTERN.sub("", residual)
    residual = _TAX_LEGACY_ORDINARY_EVIDENCE_IDENTIFIER_ENDING_PATTERN.sub("", residual)
    residual = _TAX_LEGACY_SAFE_NUMBER_PATTERN.sub("", residual)
    residual = _TAX_CANONICAL_MASK_PATTERN.sub("", residual)
    residual = _TAX_MASKED_IDENTIFIER_PATTERN.sub("", residual)
    for match in _TAX_LEGACY_EVIDENCE_WORD_PATTERN.finditer(residual):
        if match.group(0).casefold() not in _TAX_LEGACY_ALLOWED_EVIDENCE_WORDS:
            return False
    residual = _TAX_LEGACY_EVIDENCE_WORD_PATTERN.sub("", residual)
    separators = frozenset("·•,:;|/()[]{}#.+-–—")
    return all(
        character.isspace() or character in separators
        for character in residual
    )


def _sanitize_document_evidence_fields(
    value: object,
    *,
    visible_suffixes: set[str] | frozenset[str] = frozenset(),
    in_evidence: bool = False,
) -> object:
    if isinstance(value, str):
        if not in_evidence:
            return value
        safe = _redact_tax_text(value)
        if not _document_evidence_is_clearly_ordinary(
            safe,
            visible_suffixes=visible_suffixes,
        ):
            return DOCUMENT_PRIVACY_PLACEHOLDER
        return safe
    if isinstance(value, list):
        return [
            _sanitize_document_evidence_fields(
                item,
                visible_suffixes=visible_suffixes,
                in_evidence=in_evidence,
            )
            for item in value
        ]
    if isinstance(value, dict):
        return {
            key: _sanitize_document_evidence_fields(
                item,
                visible_suffixes=visible_suffixes,
                in_evidence=in_evidence or key == "evidence",
            )
            for key, item in value.items()
        }
    return value


def _migrate_legacy_document_privacy(
    original: dict,
    normalized: dict,
    *,
    legacy: bool,
) -> dict:
    """Repair legacy privacy differences while preserving current evidence."""
    masked_candidates = []
    visible_suffixes: set[str] = set()
    for field in ("taxpayerIdentifier", "referenceIdentifier"):
        candidate = original.get(field)
        if not isinstance(candidate, dict):
            continue
        raw_value = candidate.get("value")
        if (
            type(raw_value) is not str
            or _TAX_MASKED_IDENTIFIER_INPUT_PATTERN.fullmatch(raw_value.strip()) is None
        ):
            continue
        safe_candidate = normalized.get(field)
        if not isinstance(safe_candidate, dict):
            continue
        masked_candidates.append((field, safe_candidate))
        safe_value = safe_candidate.get("value")
        if type(safe_value) is str and re.fullmatch(r"\*{8}[0-9]{2}", safe_value):
            visible_suffixes.add(safe_value[-2:])

    for field, candidate in masked_candidates:
        evidence = candidate.get("evidence")
        snippet = evidence.get("snippet") if isinstance(evidence, dict) else None
        if type(snippet) is not str:
            continue
        if legacy:
            if (
                snippet == DOCUMENT_PRIVACY_PLACEHOLDER
                or _TAX_CANONICAL_MASK_PATTERN.fullmatch(snippet.strip()) is not None
            ):
                continue
            # A masked candidate does not prove what its legacy source snippet
            # contained. Do not rewrite uncertain legacy bytes during a read.
            raise _LegacyDocumentPrivacyError(
                "legacy identifier evidence cannot be established"
            )

    for text, in_evidence in _document_text_values(normalized):
        if in_evidence and not legacy:
            continue
        if in_evidence and not _document_evidence_is_clearly_ordinary(
            text,
            visible_suffixes=visible_suffixes,
        ):
            raise _LegacyDocumentPrivacyError(
                "legacy document evidence cannot be established"
            )
        if _legacy_text_contains_unproven_identifier(
            text,
            visible_suffixes=visible_suffixes,
            evidence=in_evidence,
        ):
            raise _LegacyDocumentPrivacyError("legacy document privacy cannot be established")
    return normalized


def _sanitize_uploaded_document_privacy(original: dict, normalized: dict) -> dict:
    """Sanitize masked upload evidence before the entry can be versioned."""
    visible_suffixes: set[str] = set()
    for field in ("taxpayerIdentifier", "referenceIdentifier"):
        candidate = original.get(field)
        if not isinstance(candidate, dict):
            continue
        raw_value = candidate.get("value")
        if (
            type(raw_value) is not str
            or _TAX_MASKED_IDENTIFIER_INPUT_PATTERN.fullmatch(raw_value.strip()) is None
        ):
            continue
        safe_candidate = normalized.get(field)
        if not isinstance(safe_candidate, dict):
            continue
        safe_value = safe_candidate.get("value")
        if type(safe_value) is str and re.fullmatch(r"\*{8}[0-9]{2}", safe_value):
            visible_suffixes.add(safe_value[-2:])
        evidence = safe_candidate.get("evidence")
        if not isinstance(evidence, dict):
            continue
        snippet = evidence.get("snippet")
        if (
            type(snippet) is str
            and (
                snippet == DOCUMENT_PRIVACY_PLACEHOLDER
                or _TAX_CANONICAL_MASK_PATTERN.fullmatch(snippet.strip()) is not None
            )
        ):
            continue
        normalized[field] = {
            **safe_candidate,
            "evidence": {
                **evidence,
                "snippet": DOCUMENT_PRIVACY_PLACEHOLDER,
            },
        }

    normalized = _sanitize_document_evidence_fields(
        normalized,
        visible_suffixes=visible_suffixes,
    )

    # Cross-field text is never made safe by the presence of a mask in an
    # unrelated field. Reject it before the upload can create a trusted entry.
    for text, in_evidence in _document_text_values(normalized):
        if in_evidence:
            continue
        if _legacy_text_contains_unproven_identifier(
            text,
            visible_suffixes=visible_suffixes,
            evidence=False,
        ):
            raise _LegacyDocumentPrivacyError(
                "document publication privacy cannot be established"
            )
    return normalized


def _validate_document_evidence(value: object, *, redact: bool = True) -> dict:
    if not isinstance(value, dict) or set(value) != {"page", "snippet"}:
        raise ValueError("document evidence fields are invalid")
    page = value["page"]
    if type(page) is not int or not 1 <= page <= DOCUMENT_MAX_EVIDENCE_PAGE:
        raise ValueError("document evidence page is invalid")
    snippet = _bounded_document_string(value["snippet"], DOCUMENT_MAX_EVIDENCE_CHARACTERS)
    if redact:
        snippet = _redact_tax_text(snippet)
    return {
        "page": page,
        "snippet": snippet,
    }


def _validate_document_candidate(value: object, *, identifier: bool) -> dict | None:
    if value is None:
        return None
    if not isinstance(value, dict) or set(value) != {"value", "evidence"}:
        raise ValueError("document candidate fields are invalid")
    raw_value = _bounded_document_string(value["value"], DOCUMENT_MAX_FIELD_CHARACTERS)
    safe_value = _mask_tax_identifier_value(raw_value) if identifier else _redact_tax_text(raw_value)
    if identifier:
        # Validate the page and bound the snippet before touching its contents.
        # The candidate is authoritative here: generic redaction cannot detect
        # every valid identifier spelling (for example, ``AZ123456``).
        evidence = _validate_document_evidence(value["evidence"], redact=False)
        snippet = evidence["snippet"]
        exact_forms = {form for form in (raw_value, raw_value.strip()) if form}
        for exact_form in sorted(exact_forms, key=len, reverse=True):
            snippet = snippet.replace(exact_form, safe_value)
        evidence["snippet"] = _redact_tax_text(snippet)
    else:
        evidence = _validate_document_evidence(value["evidence"])
    return {"value": safe_value, "evidence": evidence}


def _validate_document_dates(value: object) -> list[dict]:
    if not isinstance(value, list) or len(value) > DOCUMENT_MAX_DATES:
        raise ValueError("document dates exceed their bound")
    dates = []
    for date in value:
        if not isinstance(date, dict) or set(date) != {"value", "evidence"}:
            raise ValueError("document date fields are invalid")
        dates.append({
            "value": _redact_tax_text(_bounded_document_string(date["value"], DOCUMENT_MAX_FIELD_CHARACTERS)),
            "evidence": _validate_document_evidence(date["evidence"]),
        })
    return dates


def _validate_document_amounts(value: object) -> list[dict]:
    if not isinstance(value, list) or len(value) > DOCUMENT_MAX_AMOUNTS:
        raise ValueError("document amounts exceed their bound")
    amounts = []
    for amount in value:
        if not isinstance(amount, dict) or set(amount) != {"value", "label", "evidence"}:
            raise ValueError("document amount fields are invalid")
        amounts.append({
            "value": _redact_tax_text(_bounded_document_string(amount["value"], DOCUMENT_MAX_FIELD_CHARACTERS)),
            "label": _redact_tax_text(_bounded_document_string(amount["label"], DOCUMENT_MAX_FIELD_CHARACTERS)),
            "evidence": _validate_document_evidence(amount["evidence"]),
        })
    return amounts


def _validate_document_publication(value: object, *, normalize: bool) -> dict:
    if not isinstance(value, dict):
        raise ValueError("document publication is not an object")
    replacements = _collect_document_identifier_replacements(value)
    if replacements:
        value = _replace_document_identifier_mappings(value, replacements, top_level=True)
    if set(value) - DOCUMENT_PUBLICATION_KEYS or not DOCUMENT_REQUIRED_PUBLICATION_KEYS.issubset(value):
        raise ValueError("document publication fields are invalid")

    normalized = {
        "id": _canonical_document_id(value["id"]),
        "title": _redact_tax_text(
            _bounded_document_string(value["title"], DOCUMENT_MAX_FIELD_CHARACTERS)
        ),
        "documentType": _redact_tax_text(
            _bounded_document_string(value["documentType"], DOCUMENT_MAX_FIELD_CHARACTERS)
        ),
        "issuer": _validate_document_candidate(value["issuer"], identifier=False),
        "taxpayerIdentifier": _validate_document_candidate(value["taxpayerIdentifier"], identifier=True),
        "referenceIdentifier": _validate_document_candidate(value["referenceIdentifier"], identifier=True),
        "dates": _validate_document_dates(value["dates"]),
        "amounts": _validate_document_amounts(value["amounts"]),
        "warnings": [],
        "confidence": value["confidence"],
    }
    if "taxYear" in value:
        tax_year = value["taxYear"]
        if tax_year is not None and (
            type(tax_year) is not int or not -(2**63) <= tax_year <= 2**63 - 1
        ):
            raise ValueError("document tax year is invalid")
        normalized["taxYear"] = tax_year
    warnings = value["warnings"]
    if not isinstance(warnings, list) or len(warnings) > DOCUMENT_MAX_WARNINGS:
        raise ValueError("document warnings exceed their bound")
    normalized["warnings"] = [
        _redact_tax_text(_bounded_document_string(warning, DOCUMENT_MAX_FIELD_CHARACTERS))
        for warning in warnings
    ]
    confidence = value["confidence"]
    if confidence is not None and confidence not in DOCUMENT_CONFIDENCE_VALUES:
        raise ValueError("document confidence is invalid")

    if not normalize and normalized != value:
        raise ValueError("document publication is not canonical or privacy-safe")
    return normalized


def _validate_document_index_entry(value: object, *, migrate_legacy: bool = False) -> dict:
    if not isinstance(value, dict) or "_originalFile" not in value:
        raise ValueError("document index entry is invalid")
    if set(value) - DOCUMENT_PUBLICATION_KEYS - DOCUMENT_INDEX_INTERNAL_KEYS:
        raise ValueError("document index entry fields are invalid")
    if "_privacyVersion" in value and (
        type(value["_privacyVersion"]) is not int
        or value["_privacyVersion"] != DOCUMENT_PRIVACY_VERSION
    ):
        raise ValueError("document privacy version is invalid")
    original_file = value["_originalFile"]
    if not _valid_document_index_filename(original_file):
        raise ValueError("document index file name is invalid")
    publication = {
        key: item
        for key, item in value.items()
        if key not in DOCUMENT_INDEX_INTERNAL_KEYS
    }
    # Native Foundation's UUID encoder emits uppercase hexadecimal characters.
    # Accept that case-only spelling at this durable boundary, while still
    # rejecting every other non-canonical or privacy-unsafe difference.
    normalized = _validate_document_publication(publication, normalize=True)
    comparable = dict(publication)
    comparable["id"] = normalized["id"]
    if not migrate_legacy and normalized != comparable:
        raise ValueError("document index entry is not canonical or privacy-safe")
    if migrate_legacy:
        normalized = _migrate_legacy_document_privacy(
            publication,
            normalized,
            legacy="_privacyVersion" not in value,
        )
    normalized["_privacyVersion"] = DOCUMENT_PRIVACY_VERSION
    normalized["_originalFile"] = original_file
    return normalized


def _serialize_public_document_index(index: list[dict]) -> bytes:
    try:
        body = json.dumps(
            [{
                key: value
                for key, value in entry.items()
                if key not in DOCUMENT_INDEX_INTERNAL_KEYS
            } for entry in index],
            ensure_ascii=False,
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        ).encode("utf-8")
    except (UnicodeError, TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise _DocumentIndexError("document publication cannot be serialized") from exc
    if len(body) > DOCUMENT_INDEX_MAX_SIZE:
        raise _DocumentIndexTooLarge("document publication size limit exceeded")
    return body


def _load_document_index() -> tuple[list[dict], bytes | None]:
    """Load canonical entries, applying migration as one all-or-nothing write."""
    try:
        body = _read_bounded_state_file(DOCUMENTS_INDEX_PATH, DOCUMENT_INDEX_MAX_SIZE)
    except (OSError, _CalendarStateUnavailable) as exc:
        raise _DocumentIndexError("document index is unavailable") from exc
    if body is None:
        return [], None
    try:
        decoded = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise _DocumentIndexError("document index is malformed") from exc
    if not isinstance(decoded, list) or len(decoded) > DOCUMENT_INDEX_MAX_ENTRIES:
        raise _DocumentIndexError("document index entry limit exceeded")
    identifiers: set[str] = set()
    validated_entries = []
    for entry in decoded:
        # Validate every entry before rewriting any bytes. An uncertain legacy
        # entry aborts the migration, so GET can never delete it or publish a
        # partially repaired index.
        try:
            validated = _validate_document_index_entry(entry, migrate_legacy=True)
        except (TypeError, ValueError, UnicodeError, OverflowError, RecursionError) as exc:
            raise _DocumentIndexError("document index entry is invalid") from exc
        identifier = validated["id"]
        if identifier in identifiers:
            raise _DocumentIndexError("document index contains duplicate ids")
        identifiers.add(identifier)
        validated_entries.append(validated)
    # Validate the canonical publication form as well as the raw read bound.
    repaired_body = _serialize_document_index(validated_entries)
    if repaired_body != body:
        try:
            _atomic_write_bytes(DOCUMENTS_INDEX_PATH, repaired_body)
        except (OSError, ValueError) as exc:
            raise _DocumentIndexError("document index migration failed") from exc
        body = repaired_body
    return validated_entries, body


def _parse_document_metadata(value: object) -> dict:
    if not isinstance(value, str):
        raise HTTPException(status_code=400, detail="metadata must be a JSON object")
    try:
        encoded = value.encode("utf-8")
    except UnicodeEncodeError as exc:
        raise HTTPException(status_code=400, detail="metadata is not valid JSON") from exc
    if len(encoded) > DOCUMENT_METADATA_MAX_SIZE:
        raise HTTPException(status_code=413, detail="metadata exceeds limit")
    try:
        meta = json.loads(
            value,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
        )
    except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        raise HTTPException(status_code=400, detail="metadata is not valid JSON") from exc
    if not isinstance(meta, dict):
        raise HTTPException(status_code=400, detail="metadata must be a JSON object")
    if len(meta) > DOCUMENT_METADATA_MAX_FIELDS:
        raise HTTPException(status_code=413, detail="metadata field limit exceeded")
    try:
        original_meta = meta
        meta = _validate_document_publication(original_meta, normalize=True)
        meta = _sanitize_uploaded_document_privacy(original_meta, meta)
    except _LegacyDocumentPrivacyError as exc:
        raise HTTPException(
            status_code=400,
            detail="metadata privacy could not be established",
        ) from exc
    except (TypeError, ValueError, UnicodeError, OverflowError, RecursionError) as exc:
        raise HTTPException(status_code=400, detail="metadata is not a valid TaxDocument") from exc
    try:
        canonical_size = len(
            json.dumps(meta, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)
            .encode("utf-8")
        )
    except (UnicodeError, TypeError, ValueError, OverflowError, RecursionError) as exc:
        raise HTTPException(status_code=400, detail="metadata is not valid JSON") from exc
    if canonical_size > DOCUMENT_METADATA_MAX_SIZE:
        raise HTTPException(status_code=413, detail="metadata exceeds limit")
    return meta


def _document_original_files(doc_dir: Path) -> list[Path]:
    """Return only safe regular original files; reject suspicious state."""
    try:
        directory = doc_dir.lstat()
    except FileNotFoundError:
        return []
    except OSError as exc:
        raise _DocumentIndexError("document directory is unavailable") from exc
    if stat.S_ISLNK(directory.st_mode) or not stat.S_ISDIR(directory.st_mode):
        raise _DocumentIndexError("document directory is unsafe")
    files: list[Path] = []
    try:
        for path in doc_dir.iterdir():
            if not path.name.startswith("original"):
                continue
            if not path.name.startswith("original.") and not path.name.startswith("original-"):
                continue
            if not _valid_document_index_filename(path.name):
                raise _DocumentIndexError("document file name is invalid")
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode) or not stat.S_ISREG(metadata.st_mode):
                raise _DocumentIndexError("document file is unsafe")
            files.append(path)
    except OSError as exc:
        raise _DocumentIndexError("document directory is unavailable") from exc
    return sorted(files)


def _document_destination_name(suffix: str, existing: list[Path]) -> str:
    preferred = f"original{suffix}"
    if all(path.name != preferred for path in existing):
        return preferred
    return f"original-{uuid.uuid4().hex}{suffix}"


def _read_and_repair_calendar_storage() -> tuple[bytes, int, bool, bool]:
    """Read Calendar authority and repair its projections as one storage unit."""
    body, _document, metadata = _load_calendar_state()
    revision = metadata["revision"]
    retry_intent = _read_calendar_retry_intent()
    retry_matches = retry_intent is not None and (
        retry_intent["revision"] == revision
        and retry_intent["bodyDigest"] == _calendar_digest(body)
    )
    if retry_intent is not None and not retry_matches:
        _clear_calendar_retry_intent()

    # A state envelope is the authority. Rebuilding these compatibility
    # projections on every authoritative read makes a failed post-commit
    # projection self-healing even when the client does not replay PUT.
    projection_pending = False
    if _calendar_state_path().is_file():
        projection_pending = not _repair_calendar_projections(body, metadata)
        if projection_pending:
            _write_calendar_retry_intent(revision, body)
    return body, revision, retry_matches or projection_pending, projection_pending


def _write_calendar_storage(
    body: bytes,
    if_match: str,
    idempotency_key: str,
    fingerprint: str,
) -> tuple[Response, int | None, bool]:
    """Apply one Calendar conditional write and projection repair transaction."""
    current_body, _current_document, metadata = _load_calendar_state()
    current_revision = metadata["revision"]
    current_etag = _calendar_etag(current_revision, _calendar_digest(current_body))
    previous = next((record for record in metadata["idempotency"] if record["key"] == idempotency_key), None)
    if previous is not None:
        if previous["fingerprint"] != fingerprint:
            return _calendar_response(current_body, current_revision, status_code=409), None, False
        # Replays are also the durable recovery path for a projection or
        # broadcast interrupted after the original authority commit.
        projection_pending = not _repair_calendar_projections(current_body, metadata)
        response = _calendar_response(
            current_body,
            current_revision,
            replay=True,
            projection_pending=projection_pending,
        )
        if projection_pending:
            _write_calendar_retry_intent(current_revision, current_body)
        return response, current_revision, projection_pending

    if if_match != current_etag:
        return _calendar_response(current_body, current_revision, status_code=412), None, False
    if current_revision >= CALENDAR_MAX_REVISION:
        return _calendar_response(current_body, current_revision, status_code=503), None, False

    revision = current_revision + 1
    idempotency_record = {
        "key": idempotency_key,
        "fingerprint": fingerprint,
        "revision": revision,
    }
    next_metadata = {
        "schemaVersion": 1,
        "domain": "calendar",
        "authority": "gateway",
        "revision": revision,
        "bodyDigest": _calendar_digest(body),
        "idempotency": _calendar_idempotency_window(
            metadata["idempotency"], idempotency_record
        ),
        # The opaque Calendar document owns item tombstones. Keeping this
        # list empty is deliberate: the gateway cannot invent a deletion
        # timestamp or identity it did not receive from the client.
        "tombstones": metadata["tombstones"],
    }
    try:
        _calendar_metadata_bytes(next_metadata)
        state_body = json.dumps({
            "schemaVersion": CALENDAR_STATE_SCHEMA_VERSION,
            "bodyBase64": base64.b64encode(body).decode("ascii"),
            "metadata": next_metadata,
        }, sort_keys=True, separators=(",", ":"), allow_nan=False).encode("utf-8")
    except (TypeError, ValueError):
        return _calendar_response(current_body, current_revision, status_code=503), None, False
    if len(state_body) > CALENDAR_STATE_MAX_SIZE:
        return _calendar_response(current_body, current_revision, status_code=503), None, False

    # The retry intent is durable before the state commit. If state commit
    # succeeds, it records exactly which authority revision must be projected
    # and rebroadcast.
    if not _write_calendar_retry_intent(revision, body):
        return JSONResponse({"error": "calendar_unavailable"}, status_code=503), None, False
    try:
        # The state envelope is the single commit point. The historical body
        # and metadata files are projections for migration/inspection; a crash
        # between either projection rename leaves the committed envelope
        # available and never exposes a torn pair.
        _atomic_write_bytes(_calendar_state_path(), state_body)
    except (OSError, ValueError):
        return JSONResponse({"error": "calendar_unavailable"}, status_code=503), None, False

    projection_pending = not _repair_calendar_projections(body, next_metadata)
    response = _calendar_response(body, revision, projection_pending=projection_pending)
    if projection_pending:
        # Keep the marker even when the first repair attempt fails; the
        # committed envelope remains the retry source.
        _write_calendar_retry_intent(revision, body)
    return response, revision, projection_pending


def _store_document_upload(
    doc_id: str,
    meta: dict,
    original_file: BinaryIO,
    suffix: str,
) -> int:
    """Publish one document and its index as one lock-protected storage unit."""
    global documents_revision

    try:
        index, _existing_index_body = _load_document_index()
    except _DocumentIndexError as exc:
        raise HTTPException(status_code=503, detail="documents are unavailable") from exc

    doc_dir = DOCUMENTS_DIR / doc_id
    had_directory = doc_dir.exists()
    if had_directory:
        try:
            existing_files = _document_original_files(doc_dir)
        except _DocumentIndexError as exc:
            raise HTTPException(status_code=503, detail="documents are unavailable") from exc
    else:
        existing_files = []
    destination_name = _document_destination_name(suffix, existing_files)
    destination = doc_dir / destination_name
    next_index = [entry for entry in index if _document_index_id(entry.get("id")) != doc_id]
    meta = dict(meta)
    meta["_originalFile"] = destination_name
    meta["_privacyVersion"] = DOCUMENT_PRIVACY_VERSION
    next_index.append(meta)
    try:
        next_index_body = _serialize_document_index(next_index)
    except _DocumentIndexTooLarge as exc:
        raise HTTPException(status_code=413, detail="document index exceeds limit") from exc
    except _DocumentIndexError as exc:
        raise HTTPException(status_code=503, detail="documents are unavailable") from exc

    file_published = False
    index_published = False
    try:
        doc_dir.mkdir(parents=True, exist_ok=True)
        _atomic_write_stream(destination, original_file, DOCUMENT_MAX_UPLOAD_SIZE)
        file_published = True
        # The index is the commit point. Files are published first so a crash
        # between the two operations leaves the old index usable.
        _atomic_write_bytes(DOCUMENTS_INDEX_PATH, next_index_body)
        index_published = True
    except (OSError, ValueError) as exc:
        # `_atomic_write_bytes` can report a directory-fsync failure after the
        # atomic replace. Re-read the bounded target to distinguish a committed
        # index from a failed publication before rolling back.
        if not index_published:
            try:
                index_published = _read_bounded_state_file(
                    DOCUMENTS_INDEX_PATH,
                    DOCUMENT_INDEX_MAX_SIZE,
                ) == next_index_body
            except (OSError, _CalendarStateUnavailable):
                index_published = False
        if index_published:
            file_published = True
        else:
            try:
                file_published = destination.is_file() and not destination.is_symlink()
            except OSError:
                file_published = False
        if not index_published and file_published:
            try:
                destination.unlink(missing_ok=True)
            except OSError:
                pass
        if not index_published and not had_directory:
            try:
                doc_dir.rmdir()
            except OSError:
                pass
        if not index_published:
            raise HTTPException(status_code=503, detail="documents are unavailable") from exc

    for prior in existing_files:
        if prior != destination:
            try:
                prior.unlink(missing_ok=True)
            except OSError:
                # The committed index points at destination; an orphan is
                # harmless and can be pruned by the next upload.
                pass
    documents_revision += 1
    return documents_revision


def _read_document_file_storage(safe_id: str) -> tuple[bytes, str]:
    """Resolve and read one document through the bounded protected reader."""
    doc_dir = DOCUMENTS_DIR / safe_id
    if not doc_dir.exists():
        raise HTTPException(status_code=404, detail="Unknown document id")
    try:
        index, _body = _load_document_index()
        entry = next((item for item in index if _document_index_id(item.get("id")) == safe_id), None)
        candidates = _document_original_files(doc_dir)
    except _DocumentIndexError as exc:
        raise HTTPException(status_code=503, detail="documents are unavailable") from exc
    if entry is not None:
        selected_name = entry.get("_originalFile")
        if not _valid_document_index_filename(selected_name):
            raise HTTPException(status_code=503, detail="documents are unavailable")
        selected = doc_dir / selected_name
        if selected not in candidates:
            raise HTTPException(status_code=404, detail="Original file missing")
    elif _body is not None:
        raise HTTPException(status_code=404, detail="Unknown document id")
    elif not candidates:
        raise HTTPException(status_code=404, detail="Original file missing")
    else:
        selected = candidates[0]
    try:
        body = _read_bounded_state_file(selected, DOCUMENT_MAX_UPLOAD_SIZE)
    except _BoundedFileTooLarge as exc:
        raise HTTPException(status_code=413, detail="Document exceeds retrieval limit") from exc
    except (_CalendarStateUnavailable, OSError) as exc:
        raise HTTPException(status_code=503, detail="documents are unavailable") from exc
    if body is None:
        raise HTTPException(status_code=404, detail="Original file missing")
    return body, selected.name


@app.get("/health")
async def health() -> dict:
    return {"status": "ok"}


@app.get("/calendar")
async def get_calendar() -> Response:
    async with calendar_lock:
        try:
            body, revision, should_rebroadcast, projection_pending = await _run_gateway_storage(
                _read_and_repair_calendar_storage,
            )
        except (HTTPException, _CalendarStateUnavailable, OSError, ValueError):
            return JSONResponse({"error": "calendar_unavailable"}, status_code=503)

    if should_rebroadcast:
        broadcasted = await _broadcast_calendar_revision(revision)
        if broadcasted and not projection_pending:
            await _run_gateway_storage(_clear_calendar_retry_intent)
    return _calendar_response(body, revision, projection_pending=projection_pending)


@app.put("/calendar")
async def put_calendar(request: Request) -> Response:
    if _calendar_header(request, "content-type") != "application/json":
        return JSONResponse({"error": "content_type"}, status_code=415)
    if_match = _calendar_header(request, "if-match")
    idempotency_key = _calendar_header(request, "idempotency-key")
    if if_match is None:
        return JSONResponse({"error": "missing_if_match"}, status_code=428)
    if idempotency_key is None:
        return JSONResponse({"error": "missing_idempotency_key"}, status_code=400)
    if not _valid_calendar_etag(if_match):
        return JSONResponse({"error": "invalid_if_match"}, status_code=400)
    if not CALENDAR_IDEMPOTENCY_KEY_PATTERN.fullmatch(idempotency_key):
        return JSONResponse({"error": "invalid_idempotency_key"}, status_code=400)
    try:
        body = await _read_calendar_body(request)
        _parse_calendar_document(body)
    except HTTPException as exc:
        return JSONResponse({"error": "request_timeout" if exc.status_code == 408 else "body_too_large" if exc.status_code == 413 else "invalid_request"}, status_code=exc.status_code)

    fingerprint = hashlib.sha256(f"{if_match}\x00".encode("ascii") + body).hexdigest()
    async with calendar_lock:
        try:
            response, response_revision, projection_pending = await _run_gateway_storage(
                _write_calendar_storage,
                body,
                if_match,
                idempotency_key,
                fingerprint,
            )
        except (HTTPException, _CalendarStateUnavailable, OSError, ValueError):
            return JSONResponse({"error": "calendar_unavailable"}, status_code=503)

    if response_revision is not None:
        broadcasted = await _broadcast_calendar_revision(response_revision)
    else:
        broadcasted = False
    if broadcasted and not projection_pending:
        await _run_gateway_storage(_clear_calendar_retry_intent)
    return response


@app.get("/documents")
async def list_documents() -> Response:
    async with documents_lock:
        try:
            index, _body = await _run_gateway_storage(_load_document_index)
        except _DocumentIndexError:
            return JSONResponse({"error": "documents_unavailable"}, status_code=503)
        try:
            body = _serialize_public_document_index(index)
        except _DocumentIndexError:
            return JSONResponse({"error": "documents_unavailable"}, status_code=503)
        return Response(content=body, media_type="application/json")


@app.post("/documents")
async def upload_document(request: Request) -> JSONResponse:
    """`metadata` is the client's TaxDocument JSON (must include an `id` field)."""
    try:
        payload = await _read_document_multipart(request)
    except _DocumentMultipartError as exc:
        return _document_multipart_error_response(exc.status_code)

    try:
        meta = _parse_document_metadata(payload.metadata)
        doc_id = meta["id"]
        candidate_suffix = Path(payload.filename).suffix.lower()
        suffix = candidate_suffix if candidate_suffix in DOCUMENT_ALLOWED_EXTENSIONS else ".bin"

        async with documents_lock:
            try:
                revision = await _run_gateway_storage(
                    _store_document_upload,
                    doc_id,
                    meta,
                    payload.file,
                    suffix,
                )
            except HTTPException:
                raise

        try:
            # Persistence is already committed; bounded fan-out must not turn
            # a successful upload into an HTTP failure.
            await broadcaster.broadcast({"type": "documents_changed", "revision": revision})
        except Exception:
            pass
        return JSONResponse({"status": "ok", "id": doc_id})
    finally:
        payload.close()


@app.get("/documents/{doc_id}/file")
async def get_document_file(doc_id: str) -> Response:
    safe_id = _safe_document_id(doc_id)
    async with documents_lock:
        try:
            body, selected_name = await _run_gateway_storage(
                _read_document_file_storage,
                safe_id,
            )
        except HTTPException:
            raise
    media_type = mimetypes.guess_type(selected_name)[0] or "application/octet-stream"
    return Response(content=body, media_type=media_type)


async def _proxy_validated_json(
    upstream_url: str,
    validator,
    error_label: str,
    *,
    max_response_size: int | None = None,
    request_timeout: httpx.Timeout | None = None,
    total_timeout: float | None = None,
    local_auth: bool = False,
) -> Response:
    max_response_size = USAGE_MAX_RESPONSE_SIZE if max_response_size is None else max_response_size
    request_timeout = USAGE_REQUEST_TIMEOUT if request_timeout is None else request_timeout
    total_timeout = USAGE_TOTAL_TIMEOUT if total_timeout is None else total_timeout
    error = json.dumps({"error": f"{error_label} unavailable"}, separators=(",", ":")).encode()
    secret = await _service_secret_async() if local_auth else None
    if local_auth and secret is None:
        return Response(content=error, media_type="application/json", status_code=503)
    headers = {"Authorization": f"Bearer {secret}"} if local_auth else {}
    try:
        async with asyncio.timeout(total_timeout):
            async with httpx.AsyncClient(
                timeout=request_timeout,
                follow_redirects=False,
                trust_env=False,
            ) as client:
                async with client.stream("GET", upstream_url, headers=headers) as upstream:
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
    return await _read_bounded_request_body(
        request,
        maximum=CLAUDE_INGEST_MAX_BODY_SIZE,
        timeout=CLAUDE_INGEST_BODY_TIMEOUT,
        error_factory=_ClaudeIngestRequestError,
    )


def _claude_ingest_input_error(status_code: int) -> JSONResponse:
    error = "request_too_large" if status_code == 413 else "request_timeout" if status_code == 408 else "invalid_request"
    return JSONResponse({"error": error}, status_code=status_code)


async def _proxy_claude_ingest(request: Request) -> Response:
    if _calendar_header(request, "content-type") != "application/json":
        return JSONResponse({"error": "invalid_request"}, status_code=415)
    secret = await _run_gateway_storage(_read_ingest_secret)
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

    if len(_raw_header_values(request, CLAUDE_INGEST_OBSERVED_HEADER)) > 1:
        return _claude_ingest_input_error(400)
    if len(_raw_header_values(request, "idempotency-key")) > 1:
        return _claude_ingest_input_error(400)
    observed_header = _calendar_header(request, CLAUDE_INGEST_OBSERVED_HEADER)
    supplied_idempotency_key = _calendar_header(request, "idempotency-key")
    if supplied_idempotency_key is not None and not CALENDAR_IDEMPOTENCY_KEY_PATTERN.fullmatch(supplied_idempotency_key):
        return _claude_ingest_input_error(400)
    observed_at = datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
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
    # A caller-supplied key is authoritative.  With an explicit capture time,
    # the timestamp participates in the derived key so distinct observations
    # remain distinct.  If the transport has no capture time, keep the key
    # stable across gateway retries even though the gateway supplies a fresh
    # receipt timestamp for the upstream schema.
    idempotency_key = supplied_idempotency_key or (
        hashlib.sha256(forwarded + b"\x00" + observed_at.encode("ascii")).hexdigest()
        if observed_header is not None
        else hashlib.sha256(forwarded).hexdigest()
    )
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
                        "Idempotency-Key": idempotency_key,
                        "X-Observed-At": observed_at,
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
    return await _read_bounded_request_body(
        request,
        maximum=NUTRITION_PHOTO_MAX_BODY_SIZE,
        timeout=NUTRITION_PHOTO_BODY_TIMEOUT,
        error_factory=_NutritionPhotoRequestError,
    )


def _photo_lineage(manifest: object) -> tuple[str, str, list[dict[str, str]]] | None:
    """Validate the photo bytes at the trusted gateway boundary.

    The client supplies a manifest for provenance, but its claimed digest,
    length, and MIME type are not trusted. Recompute those values here before
    forwarding any image to the provider. This keeps a forged manifest from
    binding a different byte payload to an apparently valid proposal.
    """
    if not isinstance(manifest, dict):
        return None
    required_manifest_keys = {
        "schemaVersion", "mealID", "requestID", "capturedAt",
        "clientTimeZone", "inferenceConsent", "images",
    }
    allowed_manifest_keys = required_manifest_keys | {"userContext"}
    if not required_manifest_keys.issubset(manifest) or set(manifest) - allowed_manifest_keys:
        return None
    if "userContext" in manifest:
        user_context = manifest["userContext"]
        allowed_context_keys = {
            "plateDiameterMm", "knownReference", "portionWeightGrams",
            "packageLabelContext", "note",
        }
        if not isinstance(user_context, dict) or set(user_context) - allowed_context_keys:
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
        if set(image) != {
            "imageID", "mimeType", "byteLength", "width", "height",
            "sanitized", "inlineDataBase64", "sha256",
        }:
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
        request_timeout=httpx.Timeout(4.0, connect=1.0),
        total_timeout=5.0,
    )


@app.post("/nutrition/photo-proposal")
async def post_nutrition_photo_proposal(request: Request) -> Response:
    if _calendar_header(request, "content-type") != "application/json":
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

    secret = await _service_secret_async()
    if secret is None:
        return JSONResponse({"error": "nutrition_unavailable"}, status_code=503)
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
                    headers={"Content-Type": "application/json", "Authorization": f"Bearer {secret}"},
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
    try:
        encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    except (TypeError, ValueError):
        return JSONResponse({"error": "supplement_catalog_unavailable"}, status_code=503)
    if len(encoded) > CALENDAR_MAX_RESPONSE_SIZE:
        return JSONResponse({"error": "supplement_catalog_unavailable"}, status_code=503)
    return Response(
        content=encoded,
        media_type="application/json",
        headers={"Cache-Control": "no-store"},
    )


@app.get("/usage")
async def get_usage() -> Response:
    return await _proxy_validated_json(USAGE_UPSTREAM, _validate_usage_payload, "usage", local_auth=True)


def _finance_imported_source_observation(record: dict) -> tuple:
    """Return only provider-observed fields; category and authority metadata are excluded."""
    return (
        record["bookedAt"],
        record["amountCents"],
        record["description"],
        record["sourceCategory"],
        record["providerCode"],
        record["source"],
        record["kind"],
        json.dumps(record["investment"], sort_keys=True, separators=(",", ":"), ensure_ascii=False),
    )


def _apply_finance_imported_operations(snapshot: dict, operations: list[dict], next_revision: int) -> dict:
    """Apply one validated delta in O(n) using identity dictionaries.

    Every branch checks the operation's captured record/tombstone precondition
    before mutating the copies. The caller publishes the returned snapshot only
    after the whole batch succeeds, so one conflict or limit failure preserves
    the previous authority state byte-for-byte.
    """
    records = {record["recordID"]: dict(record) for record in snapshot["records"]}
    tombstones = {tombstone["recordID"]: dict(tombstone) for tombstone in snapshot["tombstones"]}
    current_revision = snapshot["revision"]

    for operation in operations:
        kind = operation["operation"]
        if kind == "upsert":
            incoming = dict(operation["record"])
            record_id = incoming["recordID"]
            expected_source_revision = operation["expectedSourceRevision"]
            existing = records.get(record_id)
            if record_id in tombstones:
                raise _FinanceImportedOperationConflict("deleted_record")
            if existing is None:
                if expected_source_revision != 0:
                    raise _FinanceImportedOperationConflict("source_revision")
                incoming["sourceRevision"] = next_revision
                records[record_id] = incoming
            else:
                if existing["sourceRevision"] != expected_source_revision:
                    raise _FinanceImportedOperationConflict("source_revision")
                # importedAt is the first local confirmation, not a provider
                # observation. Category is edited through its own operation.
                incoming["importedAt"] = existing["importedAt"]
                if incoming["categoryOverride"] != existing["categoryOverride"]:
                    raise _FinanceImportedOperationConflict("category_operation_required")
                incoming["categoryOverride"] = existing["categoryOverride"]
                if _finance_imported_source_observation(existing) != _finance_imported_source_observation(incoming):
                    incoming["sourceRevision"] = next_revision
                    records[record_id] = incoming
        elif kind in {"categorySet", "categoryClear"}:
            record_id = operation["recordID"]
            existing = records.get(record_id)
            if existing is None or record_id in tombstones:
                raise _FinanceImportedOperationConflict("deleted_record" if record_id in tombstones else "missing_record")
            if existing["sourceRevision"] != operation["expectedSourceRevision"]:
                raise _FinanceImportedOperationConflict("source_revision")
            next_category = operation.get("categoryOverride") if kind == "categorySet" else None
            if existing["categoryOverride"] != next_category:
                updated = dict(existing)
                updated["categoryOverride"] = next_category
                records[record_id] = updated
        elif kind == "delete":
            record_id = operation["recordID"]
            existing = records.get(record_id)
            if record_id in tombstones:
                raise _FinanceImportedOperationConflict("deleted_record")
            if existing is None:
                if operation["expectedSourceRevision"] != 0:
                    raise _FinanceImportedOperationConflict("missing_record")
                # A local-first add followed by a local delete may reach the
                # authority as a tombstone without ever publishing the row.
                # Expected revision zero is the explicit create-tombstone
                # precondition; it cannot delete or resurrect an authority
                # row that the caller has not observed.
                tombstones[record_id] = {
                    "recordID": record_id,
                    "revision": next_revision,
                    "deletedAt": operation["deletedAt"],
                }
            else:
                if existing["sourceRevision"] != operation["expectedSourceRevision"]:
                    raise _FinanceImportedOperationConflict("source_revision")
                records.pop(record_id)
                tombstones[record_id] = {
                    "recordID": record_id,
                    "revision": next_revision,
                    "deletedAt": operation["deletedAt"],
                }
        elif kind == "restore":
            incoming = dict(operation["record"])
            record_id = incoming["recordID"]
            existing_tombstone = tombstones.get(record_id)
            if existing_tombstone is None:
                raise _FinanceImportedOperationConflict("missing_tombstone")
            if existing_tombstone["revision"] != operation["expectedTombstoneRevision"]:
                raise _FinanceImportedOperationConflict("tombstone_revision")
            if record_id in records:
                raise _FinanceImportedOperationConflict("live_record")
            incoming["sourceRevision"] = next_revision
            records[record_id] = incoming
            tombstones.pop(record_id)
        else:
            raise _FinanceImportedOperationConflict("unknown_operation")

        if len(records) > FINANCE_IMPORTED_MAX_RECORDS or len(tombstones) > FINANCE_IMPORTED_MAX_TOMBSTONES:
            raise _FinanceImportedLimitExceeded

    changed = records != {record["recordID"]: dict(record) for record in snapshot["records"]}
    changed = changed or tombstones != {tombstone["recordID"]: dict(tombstone) for tombstone in snapshot["tombstones"]}
    return {
        "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
        "domain": "finance",
        "ledger": "manual_import",
        "authority": "gateway",
        "revision": next_revision if changed else current_revision,
        "records": sorted(records.values(), key=lambda record: record["recordID"]),
        "tombstones": sorted(tombstones.values(), key=lambda tombstone: tombstone["recordID"]),
    }


def _read_finance_imported_storage() -> tuple[bytes, dict, dict]:
    """Load the imported-finance authority as one protected storage unit."""
    return _load_finance_imported_state()


def _read_finance_imported_receipt_storage(idempotency_key: str) -> dict:
    """Resolve one imported-finance receipt from one validated state read."""
    _body, snapshot, metadata = _load_finance_imported_state()
    record = next(
        (item for item in metadata["idempotency"] if item["key"] == idempotency_key),
        None,
    )
    return (
        {"state": "committed", "revision": record["revision"]}
        if record is not None
        else {"state": "unknown", "revision": None}
    )


def _write_finance_imported_storage(
    body: bytes,
    parsed_request: dict,
    fingerprint: str,
    if_match: str,
    idempotency_key: str,
) -> Response:
    """Apply one imported-finance delta while keeping read/modify/write atomic."""
    current_body, current_snapshot, metadata = _load_finance_imported_state()
    current_revision = current_snapshot["revision"]
    current_etag = _finance_imported_etag(current_revision, _finance_imported_digest(current_body))
    previous = next((record for record in metadata["idempotency"] if record["key"] == idempotency_key), None)
    if previous is not None:
        if previous["fingerprint"] != fingerprint:
            return _finance_imported_response(current_body, current_revision, status_code=409, conflict=True)
        return _finance_imported_response(current_body, current_revision, replay=True)
    if if_match != current_etag or parsed_request["baseRevision"] != current_revision:
        return _finance_imported_response(current_body, current_revision, status_code=412, conflict=True)
    if current_revision >= FINANCE_IMPORTED_MAX_REVISION:
        return _finance_imported_response(current_body, current_revision, status_code=503)

    next_revision = current_revision + 1
    try:
        next_snapshot = _apply_finance_imported_operations(
            current_snapshot,
            parsed_request["operations"],
            next_revision,
        )
    except _FinanceImportedOperationConflict as exc:
        return _finance_imported_response(
            current_body,
            current_revision,
            status_code=409,
            conflict=True,
            conflict_reason=exc.reason,
        )
    except _FinanceImportedLimitExceeded:
        return JSONResponse({"error": "finance_imported_limit"}, status_code=413)
    changed = next_snapshot["revision"] != current_revision
    try:
        next_body = current_body if not changed else _finance_imported_snapshot_bytes(next_snapshot)
    except ValueError:
        return JSONResponse({"error": "finance_imported_limit"}, status_code=413)
    idempotency_record = {
        "key": idempotency_key,
        "fingerprint": fingerprint,
        "revision": next_snapshot["revision"],
    }
    next_metadata = {
        "schemaVersion": FINANCE_IMPORTED_SCHEMA_VERSION,
        "domain": "finance",
        "authority": "gateway",
        "revision": next_snapshot["revision"],
        "bodyDigest": _finance_imported_digest(next_body),
        "idempotency": _finance_imported_idempotency_window(metadata["idempotency"], idempotency_record),
    }
    try:
        # A no-op still publishes its bounded replay record atomically, so a
        # retry cannot consume another revision after process restart.
        next_metadata["bodyDigest"] = _finance_imported_digest(next_body)
        state_body = _finance_imported_state_bytes(next_body, next_metadata)
        _atomic_write_bytes(FINANCE_IMPORTED_PATH, state_body)
    except (OSError, TypeError, ValueError, OverflowError, RecursionError):
        return JSONResponse({"error": "finance_imported_unavailable"}, status_code=503)

    return _finance_imported_response(
        next_body,
        next_snapshot["revision"],
        noop=not changed,
    )


@app.get("/finance/imported")
async def get_finance_imported() -> Response:
    """Return the bounded, gateway-authoritative manual-import ledger."""
    async with finance_imported_lock:
        try:
            body, snapshot, _metadata = await _run_gateway_storage(
                _read_finance_imported_storage,
            )
        except (_FinanceImportedStateUnavailable, OSError, ValueError):
            return JSONResponse({"error": "finance_imported_unavailable"}, status_code=503)
        if snapshot["revision"] < 0 or len(body) > FINANCE_IMPORTED_MAX_RESPONSE_SIZE:
            return JSONResponse({"error": "finance_imported_unavailable"}, status_code=503)
        return _finance_imported_response(body, snapshot["revision"])


@app.get("/finance/imported/receipt/{idempotency_key}")
async def get_finance_imported_receipt(idempotency_key: str) -> Response:
    """Return only the durable commit state for one imported-ledger key."""
    if not FINANCE_IMPORTED_IDEMPOTENCY_KEY_PATTERN.fullmatch(idempotency_key):
        return JSONResponse({"error": "invalid_idempotency_key"}, status_code=400)
    async with finance_imported_lock:
        try:
            payload = await _run_gateway_storage(
                _read_finance_imported_receipt_storage,
                idempotency_key,
            )
        except (_FinanceImportedStateUnavailable, OSError, ValueError):
            return JSONResponse({"error": "finance_imported_unavailable"}, status_code=503)
        return JSONResponse(payload, headers={"Cache-Control": "no-store"})


@app.put("/finance/imported")
async def put_finance_imported(request: Request) -> Response:
    """Conditionally apply a bounded manual-ledger delta exactly once."""
    if _calendar_header(request, "content-type") != "application/json":
        return JSONResponse({"error": "content_type"}, status_code=415)
    if_match = _calendar_header(request, "if-match")
    idempotency_key = _calendar_header(request, "idempotency-key")
    if if_match is None:
        return JSONResponse({"error": "missing_if_match"}, status_code=428)
    if idempotency_key is None:
        return JSONResponse({"error": "missing_idempotency_key"}, status_code=400)
    if not _valid_finance_imported_etag(if_match):
        return JSONResponse({"error": "invalid_if_match"}, status_code=400)
    if not FINANCE_IMPORTED_IDEMPOTENCY_KEY_PATTERN.fullmatch(idempotency_key):
        return JSONResponse({"error": "invalid_idempotency_key"}, status_code=400)

    try:
        body = await _read_bounded_finance_imported_request(request)
        parsed_request = _parse_finance_imported_request(body)
    except HTTPException as exc:
        error = "request_timeout" if exc.status_code == 408 else "request_too_large" if exc.status_code == 413 else "invalid_request"
        return JSONResponse({"error": error}, status_code=exc.status_code)

    # The idempotency key binds one exact request body for its entire replay
    # lifetime. If a response was lost and another writer advanced the
    # authority, the original If-Match is intentionally allowed to replay;
    # including it in this fingerprint would turn a safe retry into a second
    # write or a false conflict.
    fingerprint = hashlib.sha256(body).hexdigest()
    async with finance_imported_lock:
        try:
            response = await _run_gateway_storage(
                _write_finance_imported_storage,
                body,
                parsed_request,
                fingerprint,
                if_match,
                idempotency_key,
            )
        except (_FinanceImportedStateUnavailable, OSError, ValueError):
            return JSONResponse({"error": "finance_imported_unavailable"}, status_code=503)
        return response


@app.get("/finance/summary")
async def get_finance_summary() -> Response:
    try:
        payload = await enable_banking.refresh_summary()
    except (ProtectedStorageOverloaded, ProtectedStorageUnavailable):
        raise
    except EnableBankingUnavailable:
        # Keep the last validated banking observation available during a
        # provider outage. `load_cached_summary` preserves its source time and
        # converts only age-inconsistent observed provenance to stale/
        # refresh_due; malformed or incomplete cache state still fails closed.
        try:
            payload = await _enable_banking_storage_value(
                "load_cached_summary_async",
                "load_cached_summary",
            )
        except (ProtectedStorageOverloaded, ProtectedStorageUnavailable):
            raise
        except Exception:
            payload = None
    except Exception:
        # An exception outside the typed refresh failure path has no recorded
        # provenance. Serving the cache here would make a successful HTTP 200
        # look like a truthful refresh result when it is not.
        return _finance_consent_response({"error": "finance unavailable"}, 503)
    if payload is not None:
        try:
            revision = await _enable_banking_storage_value(
                "summary_revision_async",
                "summary_revision",
            )
        except (ProtectedStorageOverloaded, ProtectedStorageUnavailable):
            raise
        except Exception:
            return _finance_consent_response({"error": "finance unavailable"}, 503)
    else:
        revision = None
    response = _finance_consent_response(payload if payload is not None else {"error": "finance unavailable"}, 200 if payload is not None else 503, revision=revision if payload is not None else None)
    if getattr(enable_banking, "runtime_status_async", None) or getattr(enable_banking, "runtime_status", None):
        try:
            status = await _enable_banking_storage_value(
                "runtime_status_async",
                "runtime_status",
            )
        except (ProtectedStorageOverloaded, ProtectedStorageUnavailable):
            raise
        except Exception:
            return _finance_consent_response({"error": "finance unavailable"}, 503)
        response.headers["X-LifeOS-Banking-State"] = "consent" if status["blocked"] else status["failure"] or ("partial" if status["partial"] else "healthy")
        response.headers["X-LifeOS-Banking-Partial"] = "true" if status["partial"] else "false"
        for field, header in (("lastSuccess", "X-LifeOS-Banking-Last-Success"), ("lastFailure", "X-LifeOS-Banking-Last-Failure")):
            if status[field] is not None:
                response.headers[header] = status[field]
    return response


def _read_fitness_observation_storage() -> tuple[bytes, dict]:
    """Read, validate, and canonicalize the fitness observation off-loop."""
    body = _read_bounded_state_file(
        FITNESS_OBSERVATION_PATH,
        FITNESS_OBSERVATION_MAX_RESPONSE_SIZE,
    )
    if body is None:
        raise _CalendarStateUnavailable
    try:
        payload = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
            parse_int=_calendar_integer,
        )
    except (UnicodeDecodeError, UnicodeEncodeError, json.JSONDecodeError, ValueError, TypeError, OverflowError, RecursionError) as exc:
        raise _CalendarStateUnavailable from exc
    now = datetime.now(timezone.utc)
    if not _validate_fitness_observation_payload(
        payload,
        now=now,
        enforce_freshness=False,
        allow_non_observed=True,
    ):
        raise _CalendarStateUnavailable
    generated_at = _parse_fitness_timestamp(payload["generatedAt"])
    if generated_at is None:
        raise _CalendarStateUnavailable
    if payload["state"] == "observed" and now - generated_at > FITNESS_OBSERVATION_STALE_AFTER:
        payload = _stale_fitness_observation(payload)
        if not _validate_fitness_observation_payload(
            payload,
            now=now,
            enforce_freshness=False,
            allow_non_observed=True,
        ):
            raise _CalendarStateUnavailable
    try:
        response_body = _fitness_observation_bytes(payload)
    except ValueError as exc:
        raise _CalendarStateUnavailable from exc
    return response_body, payload


def _write_fitness_observation_storage(
    payload: dict,
    canonical_body: bytes,
    now: datetime,
) -> Response:
    """Compare and publish one fitness observation as one protected unit."""
    durable = _load_valid_fitness_observation(now=now)
    if durable is not None:
        try:
            incoming_key = _fitness_observation_order_key(payload)
            durable_key = _fitness_observation_order_key(durable)
        except ValueError as exc:
            raise _CalendarStateUnavailable from exc
        if incoming_key < durable_key:
            return _fitness_publication_response(result="ignored", reason="older_observation")
        if incoming_key == durable_key:
            try:
                durable_body = _fitness_observation_bytes(durable)
            except ValueError as exc:
                raise _CalendarStateUnavailable from exc
            return _fitness_publication_response(
                result="already_current",
                reason="idempotent_replay" if durable_body == canonical_body else "equal_generation",
            )
    _atomic_write_bytes(FITNESS_OBSERVATION_PATH, canonical_body)
    return _fitness_publication_response(result="stored")


@app.get("/fitness/observation")
async def get_fitness_observation() -> Response:
    async with fitness_observation_lock:
        try:
            response_body, payload = await _run_gateway_storage(
                _read_fitness_observation_storage,
            )
        except (_BoundedFileTooLarge, _CalendarStateUnavailable, OSError):
            return JSONResponse({"error": "fitness_observation_unavailable"}, status_code=503)
    return Response(
        content=response_body,
        media_type="application/json",
        headers={
            "Cache-Control": "no-store",
            "X-LifeOS-Fitness-State": payload["state"],
        },
    )


@app.post("/fitness/observation")
async def post_fitness_observation(request: Request) -> Response:
    if _calendar_header(request, "content-type") != "application/json":
        return JSONResponse({"error": "content_type"}, status_code=415)
    try:
        body = await _read_bounded_fitness_observation_request(request)
        payload = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_nonfinite_constant,
            parse_int=_calendar_integer,
        )
    except HTTPException as exc:
        error = "request_too_large" if exc.status_code == 413 else "request_timeout" if exc.status_code == 408 else "invalid_request"
        return JSONResponse({"error": error}, status_code=exc.status_code)
    except (UnicodeDecodeError, UnicodeEncodeError, json.JSONDecodeError, ValueError, TypeError, OverflowError, RecursionError):
        return JSONResponse({"error": "invalid_request"}, status_code=422)

    now = datetime.now(timezone.utc)
    if not _validate_fitness_observation_payload(payload, now=now, enforce_freshness=True):
        return JSONResponse({"error": "fitness_observation_invalid"}, status_code=422)
    try:
        canonical_body = _fitness_observation_bytes(payload)
    except ValueError:
        return JSONResponse({"error": "fitness_observation_invalid"}, status_code=422)
    async with fitness_observation_lock:
        try:
            return await _run_gateway_storage(
                _write_fitness_observation_storage,
                payload,
                canonical_body,
                now,
            )
        except (_CalendarStateUnavailable, OSError, ValueError):
            return JSONResponse({"error": "fitness_observation_unavailable"}, status_code=503)


@app.get("/clipper/summary")
async def get_clipper_summary() -> Response:
    return await _proxy_validated_json(
        CLIPPER_UPSTREAM,
        _validate_clipper_snapshot,
        "clipper",
        max_response_size=CLIPPER_MAX_RESPONSE_SIZE,
        request_timeout=CLIPPER_REQUEST_TIMEOUT,
        total_timeout=CLIPPER_TOTAL_TIMEOUT,
        local_auth=True,
    )


@app.post("/usage/claude-ingest")
async def post_claude_ingest(request: Request) -> Response:
    return await _proxy_claude_ingest(request)
