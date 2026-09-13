#!/usr/bin/env python3
"""Send one Hermes-produced Clipper snapshot to the local LifeOS API.

Hermes owns platform authentication and snapshot construction. This helper
owns only the narrow local handoff: bounded private-file reads, exact loopback
endpoint validation, deterministic retry identity, and a redirect-free POST.
It never logs the snapshot or the API response.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import ssl
import stat
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any


MAX_SNAPSHOT_BYTES = 1 * 1024 * 1024
MAX_SECRET_BYTES = 4096
SECRET_MIN_LENGTH = 32
SECRET_MAX_LENGTH = 256
DEFAULT_ENDPOINT = "http://127.0.0.1:8787/api/clipper/ingest"
SENT = "CLIPPER sent"
UNAVAILABLE = "CLIPPER unavailable"


class ProtocolError(ValueError):
    pass


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    output: dict[str, Any] = {}
    for key, value in pairs:
        if key in output:
            raise ProtocolError("duplicate JSON key")
        output[key] = value
    return output


def _reject_constant(value: str) -> Any:
    raise ProtocolError("non-finite JSON number")


def _read_private(path: Path, limit: int) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(os.fspath(path), flags)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
            raise ProtocolError("private file is not regular")
        if os.name == "posix" and stat.S_IMODE(metadata.st_mode) != 0o600:
            raise ProtocolError("private file permissions are not restrictive")
        if metadata.st_size > limit:
            raise ProtocolError("private file is too large")
        value = os.read(descriptor, limit + 1)
        if len(value) > limit or len(value) != metadata.st_size:
            raise ProtocolError("private file changed while reading")
        return value
    except (OSError, ValueError) as exc:
        if isinstance(exc, ProtocolError):
            raise
        raise ProtocolError("private file unavailable") from exc
    finally:
        if descriptor != -1:
            try:
                os.close(descriptor)
            except OSError:
                pass


def validate_endpoint(value: str) -> str:
    try:
        parsed = urllib.parse.urlsplit(value)
        port = parsed.port
    except (TypeError, ValueError, UnicodeError) as exc:
        raise ProtocolError("invalid endpoint") from exc
    if (
        parsed.scheme != "http"
        or parsed.hostname != "127.0.0.1"
        or port != 8787
        or parsed.path != "/api/clipper/ingest"
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        raise ProtocolError("endpoint is not the exact local Clipper ingest route")
    return value


def load_snapshot(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = _read_private(path, MAX_SNAPSHOT_BYTES)
    try:
        snapshot = json.loads(
            raw,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except (ProtocolError, json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
        raise ProtocolError("invalid snapshot JSON") from exc
    if not isinstance(snapshot, dict) or snapshot.get("availability") != "observed":
        raise ProtocolError("snapshot must be observed Clipper data")
    try:
        canonical = json.dumps(snapshot, allow_nan=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    except (TypeError, ValueError, OverflowError) as exc:
        raise ProtocolError("snapshot cannot be encoded") from exc
    if len(canonical) > MAX_SNAPSHOT_BYTES:
        raise ProtocolError("snapshot is too large")
    return snapshot, canonical


def load_secret(path: Path) -> str:
    raw = _read_private(path, MAX_SECRET_BYTES)
    try:
        secret = raw.decode("ascii")
    except UnicodeDecodeError as exc:
        raise ProtocolError("secret is not ASCII") from exc
    if not SECRET_MIN_LENGTH <= len(secret) <= SECRET_MAX_LENGTH or not all(0x21 <= ord(char) <= 0x7E for char in secret):
        raise ProtocolError("secret has invalid shape")
    return secret


class _RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers):
        return None


def _opener() -> urllib.request.OpenerDirector:
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        _RejectRedirectHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )


def post_snapshot(snapshot_path: Path, secret_path: Path, endpoint: str = DEFAULT_ENDPOINT, opener: Any = None) -> bool:
    try:
        _snapshot, body = load_snapshot(snapshot_path)
        secret = load_secret(secret_path)
        endpoint = validate_endpoint(endpoint)
        key = "hermes-" + hashlib.sha256(body).hexdigest()
        request = urllib.request.Request(
            endpoint,
            data=body,
            headers={
                "Authorization": f"Bearer {secret}",
                "Content-Type": "application/json",
                "Idempotency-Key": key,
                "Content-Length": str(len(body)),
            },
            method="POST",
        )
    except Exception:
        return False
    response = None
    try:
        response = (opener or _opener()).open(request, timeout=5.0)
        # Do not read or expose response bytes. The route's status is the only
        # receipt Hermes needs; retries use the same deterministic key.
        return 200 <= int(response.getcode()) < 300
    except Exception:
        return False
    finally:
        if response is not None:
            try:
                response.close()
            except Exception:
                pass


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--secret-file", required=True, type=Path)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    args = parser.parse_args(argv)
    if post_snapshot(args.snapshot, args.secret_file, args.endpoint):
        print(SENT)
        return 0
    print(UNAVAILABLE)
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
