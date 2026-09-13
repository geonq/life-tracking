#!/usr/bin/env python3
"""Forward one validated Claude usage snapshot over a narrowly trusted URL."""

from __future__ import annotations

import argparse
import datetime
import contextlib
import fcntl
import os
import re
import ssl
import stat
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

try:  # Support both ``python -m scripts.usage...`` and direct launchd paths.
    from .protocol import (
        MAX_SPOOL_BYTES,
        ProtocolError,
        canonical_json,
        parse_json,
        read_private_file,
        validate_payload,
    )
except ImportError:  # pragma: no cover - exercised by direct script launch.
    from protocol import (  # type: ignore[no-redef]
        MAX_SPOOL_BYTES,
        ProtocolError,
        canonical_json,
        parse_json,
        read_private_file,
        validate_payload,
    )


REQUEST_TIMEOUT_SECONDS = 5.0
UNAVAILABLE = "CLAUDE USAGE unavailable"
SENT = "CLAUDE USAGE sent"


def claim_path(spool_path: Path) -> Path:
    """Return the one fixed sibling used for an in-flight/retry snapshot."""

    return spool_path.with_name(f".{spool_path.name}.claim")


def _claim_lock_path(spool_path: Path) -> Path:
    return spool_path.with_name(f".{spool_path.name}.lock")


@contextlib.contextmanager
def _claim_lock(spool_path: Path):
    """Serialize uploader processes without blocking collector replacements."""

    lock_path = _claim_lock_path(spool_path)
    fd = -1
    try:
        lock_flags = os.O_CREAT | os.O_RDWR
        if hasattr(os, "O_NOFOLLOW"):
            lock_flags |= os.O_NOFOLLOW
        fd = os.open(
            os.fspath(lock_path),
            lock_flags,
            0o600,
        )
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise ProtocolError("claim lock is not regular")
        os.fchmod(fd, 0o600)
    except (OSError, ValueError) as exc:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
        raise ProtocolError("cannot create claim lock") from exc
    try:
        with os.fdopen(fd, "rb", closefd=True) as lock_file:
            fd = -1
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(lock_file.fileno(), fcntl.LOCK_UN)
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass


def validate_endpoint(value: Any) -> str:
    """Validate the exact HTTPS Tailscale Serve endpoint contract."""

    if not isinstance(value, str) or not value or any(ord(char) <= 0x20 or ord(char) == 0x7F for char in value):
        raise ProtocolError("invalid endpoint")
    try:
        parsed = urllib.parse.urlsplit(value)
        hostname = parsed.hostname
        effective_port = parsed.port if parsed.port is not None else 443
    except (ValueError, UnicodeError) as exc:
        raise ProtocolError("invalid endpoint") from exc

    if parsed.scheme.lower() != "https":
        raise ProtocolError("endpoint is not HTTPS")
    if hostname is None:
        raise ProtocolError("endpoint has no hostname")
    try:
        ascii_hostname = hostname.encode("ascii").decode("ascii").lower()
    except UnicodeError as exc:
        raise ProtocolError("endpoint hostname is not ASCII") from exc
    if not ascii_hostname.endswith(".ts.net"):
        raise ProtocolError("endpoint is outside trusted tailnet")
    labels = ascii_hostname.split(".")
    if len(labels) < 3 or any(
        not label
        or len(label) > 63
        or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", label)
        for label in labels
    ):
        raise ProtocolError("endpoint hostname is not a DNS name")
    if effective_port not in (8420, 443):
        raise ProtocolError("endpoint port is not allowed")
    if parsed.username is not None or parsed.password is not None:
        raise ProtocolError("endpoint userinfo is forbidden")
    # Check the raw URL too: urlsplit represents a trailing ``?``/``#`` as an
    # empty component, but it is still a query/fragment delimiter we do not
    # want in this exact endpoint contract.
    if parsed.query or parsed.fragment or "?" in value or "#" in value:
        raise ProtocolError("endpoint query/fragment is forbidden")
    if parsed.path != "/usage/claude-ingest":
        raise ProtocolError("endpoint path is not exact")
    return value


def load_endpoint(config_path: Path) -> str:
    raw = read_private_file(config_path, MAX_SPOOL_BYTES, require_mode_0600=True)
    config = parse_json(raw)
    if not isinstance(config, dict) or set(config) != {"endpoint"}:
        raise ProtocolError("invalid endpoint config")
    return validate_endpoint(config["endpoint"])


def load_spool(spool_path: Path) -> dict[str, Any]:
    raw = read_private_file(spool_path, MAX_SPOOL_BYTES, require_mode_0600=True)
    return validate_payload(parse_json(raw))


def _remove_claim(claim: Path) -> None:
    """Remove only the claim path; never unlink the collector's latest slot."""

    try:
        os.unlink(os.fspath(claim))
    except FileNotFoundError:
        pass


def _prepare_claim(spool: Path) -> tuple[Path, dict[str, Any]] | None:
    """Select a valid claim, atomically claim the latest slot, or return none.

    The caller holds ``_claim_lock`` for the complete prepare/send/delete
    lifecycle.  A corrupt claim is discarded before a newer slot is considered;
    all retries and replacements remain bounded to one claim plus one slot.
    """

    claim = claim_path(spool)
    while True:
        if os.path.lexists(os.fspath(claim)):
            try:
                return claim, load_spool(claim)
            except Exception:
                # A malformed, oversized, symlinked, or non-private claim must
                # not block a newer collector slot.
                _remove_claim(claim)
                continue

        if not os.path.lexists(os.fspath(spool)):
            return None
        try:
            # Unlike replacing the claim, replacing the absent slot with the
            # fixed claim cannot overwrite a prior retry: the lock serializes
            # uploaders, and the collector never writes the claim path.
            os.replace(os.fspath(spool), os.fspath(claim))
        except FileNotFoundError:
            # A collector may have completed a replacement between the
            # existence check and rename. Re-evaluate paths safely.
            continue


class RejectRedirectHandler(urllib.request.HTTPRedirectHandler):
    """Make every redirect a hard failure instead of following it."""

    def redirect_request(self, req: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any) -> None:
        return None

    @staticmethod
    def _reject(request: urllib.request.Request, code: int, message: str, headers: Any, response: Any) -> Any:
        raise urllib.error.HTTPError(request.full_url, code, message, headers, response)

    def http_error_301(self, request: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any) -> Any:
        return self._reject(request, code, msg, headers, fp)

    def http_error_302(self, request: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any) -> Any:
        return self._reject(request, code, msg, headers, fp)

    def http_error_303(self, request: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any) -> Any:
        return self._reject(request, code, msg, headers, fp)

    def http_error_307(self, request: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any) -> Any:
        return self._reject(request, code, msg, headers, fp)

    def http_error_308(self, request: urllib.request.Request, fp: Any, code: int, msg: str, headers: Any) -> Any:
        return self._reject(request, code, msg, headers, fp)


def _opener() -> urllib.request.OpenerDirector:
    # Do not inherit ambient proxy settings for a private tailnet destination.
    # HTTPSHandler uses the platform trust store and performs certificate/
    # hostname verification; the endpoint validator supplies the root policy.
    return urllib.request.build_opener(
        urllib.request.ProxyHandler({}),
        RejectRedirectHandler(),
        urllib.request.HTTPSHandler(context=ssl.create_default_context()),
    )


def post_payload(payload: dict[str, Any], endpoint: str, opener: Any = None, observed_at: str | None = None) -> bool:
    try:
        endpoint = validate_endpoint(endpoint)
        payload = validate_payload(payload)
        body = canonical_json(payload)
        headers = {"Content-Type": "application/json"}
        if observed_at is not None:
            headers["X-Observed-At"] = observed_at
        request = urllib.request.Request(
            endpoint,
            data=body,
            headers=headers,
            method="POST",
        )
    except Exception:
        return False

    selected_opener = opener if opener is not None else _opener()
    response = None
    try:
        response = selected_opener.open(request, timeout=REQUEST_TIMEOUT_SECONDS)
        code = response.getcode()
        return isinstance(code, int) and 200 <= code < 300
    except Exception as exc:
        if isinstance(exc, urllib.error.HTTPError):
            try:
                exc.close()
            except Exception:
                pass
        return False
    finally:
        if response is not None:
            try:
                response.close()
            except Exception:
                pass


def process_once(spool_path: Path, config_path: Path, opener: Any = None) -> str:
    """Send at most one claim and consume it only after a successful POST."""

    try:
        with _claim_lock(spool_path):
            prepared = _prepare_claim(spool_path)
            if prepared is None:
                return UNAVAILABLE
            claim, payload = prepared
            observed_at = datetime.datetime.fromtimestamp(claim.stat().st_mtime, datetime.timezone.utc).isoformat().replace("+00:00", "Z")
            try:
                endpoint = load_endpoint(config_path)
            except Exception:
                # The valid claim remains available for a later config retry.
                return UNAVAILABLE
            if not post_payload(payload, endpoint, opener, observed_at):
                # Network and non-2xx server failures retain this claim.
                return UNAVAILABLE
            _remove_claim(claim)
            return SENT
    except Exception:
        return UNAVAILABLE


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spool", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path)
    args = parser.parse_args(argv)

    # A launchd job should be nonfatal and must not print endpoint/config
    # contents or response bodies into a log.
    print(process_once(args.spool, args.config))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
