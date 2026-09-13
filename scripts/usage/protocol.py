"""Small, strict wire-format helpers shared by the usage forwarder programs.

This module intentionally has no application dependencies.  The only data
shape it accepts is the two Claude Code rate-limit windows and their numeric
fields; callers never need to carry the rest of Claude's status-line payload.
"""

from __future__ import annotations

import json
import math
import os
import stat
from pathlib import Path
from typing import Any, BinaryIO


MAX_INPUT_BYTES = 64 * 1024
MAX_SPOOL_BYTES = 16 * 1024
WINDOWS = ("five_hour", "seven_day")
WINDOW_FIELDS = ("used_percentage", "resets_at")


class ProtocolError(ValueError):
    """Raised when untrusted input is not the expected strict JSON shape."""


def _duplicate_key(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ProtocolError("duplicate JSON key")
        result[key] = value
    return result


def _reject_constant(value: str) -> Any:
    # json.loads otherwise accepts NaN and Infinity even though they are not
    # JSON and they cannot be emitted by strict JSON encoders.
    raise ProtocolError("non-finite JSON constant")


def parse_json(raw: bytes) -> Any:
    """Parse JSON once, rejecting duplicate object keys and non-JSON numbers."""

    try:
        return json.loads(
            raw,
            object_pairs_hook=_duplicate_key,
            parse_constant=_reject_constant,
        )
    except (ProtocolError, json.JSONDecodeError, UnicodeDecodeError, TypeError) as exc:
        raise ProtocolError("invalid JSON") from exc


def _finite_number(value: Any) -> bool:
    # bool is an int subclass, but accepting it would be silent type coercion.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return False
    try:
        return math.isfinite(value)
    except (OverflowError, TypeError, ValueError):
        return False


def valid_percentage(value: Any) -> bool:
    return _finite_number(value) and 0 <= value <= 100


def valid_reset_epoch(value: Any) -> bool:
    return _finite_number(value) and value > 0


def validate_payload(value: Any) -> dict[str, Any]:
    """Validate the exact spool/post shape and return a shallow safe copy."""

    if not isinstance(value, dict) or set(value) != {"rate_limits"}:
        raise ProtocolError("unexpected payload fields")
    limits = value["rate_limits"]
    if not isinstance(limits, dict):
        raise ProtocolError("invalid rate limits")

    clean_limits: dict[str, dict[str, Any]] = {}
    for window, window_value in limits.items():
        if window not in WINDOWS or not isinstance(window_value, dict):
            raise ProtocolError("invalid rate limit window")
        if any(field not in WINDOW_FIELDS for field in window_value):
            raise ProtocolError("unexpected rate limit field")
        clean_window: dict[str, Any] = {}
        for field, field_value in window_value.items():
            if field == "used_percentage":
                if not valid_percentage(field_value):
                    raise ProtocolError("invalid percentage")
            elif not valid_reset_epoch(field_value):
                raise ProtocolError("invalid reset epoch")
            clean_window[field] = field_value
        clean_limits[window] = clean_window

    # Insertion order is deliberately canonicalized by canonical_json below;
    # the returned object contains no references to untrusted nested objects.
    return {"rate_limits": clean_limits}


def canonical_json(value: dict[str, Any]) -> bytes:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            separators=(",", ":"),
            sort_keys=True,
        ).encode("utf-8")
    except (TypeError, ValueError, OverflowError) as exc:
        raise ProtocolError("cannot encode payload") from exc


def read_capped_stream(stream: BinaryIO, limit: int) -> bytes:
    """Read at most ``limit + 1`` bytes, returning an error on oversize input."""

    data = bytearray()
    while len(data) <= limit:
        requested = min(8192, limit + 1 - len(data))
        chunk = stream.read(requested)
        if not chunk:
            break
        if isinstance(chunk, str):
            chunk = chunk.encode("utf-8")
        if not isinstance(chunk, (bytes, bytearray, memoryview)):
            raise ProtocolError("invalid input stream")
        if len(chunk) > requested:
            raise ProtocolError("oversize input")
        data.extend(chunk)
        if len(data) > limit:
            raise ProtocolError("oversize input")
    return bytes(data)


def read_private_file(path: Path, limit: int, *, require_mode_0600: bool = False) -> bytes:
    """Read one regular, bounded file without following a final symlink."""

    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(os.fspath(path), flags)
    except (OSError, ValueError) as exc:
        raise ProtocolError("cannot read local file") from exc

    try:
        metadata = os.fstat(fd)
        if not stat.S_ISREG(metadata.st_mode):
            raise ProtocolError("local file is not regular")
        if require_mode_0600 and stat.S_IMODE(metadata.st_mode) != 0o600:
            raise ProtocolError("spool permissions are not private")
        with os.fdopen(fd, "rb", closefd=True) as stream:
            fd = -1
            return read_capped_stream(stream, limit)
    except ProtocolError:
        raise
    except (OSError, ValueError) as exc:
        raise ProtocolError("cannot read local file") from exc
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
