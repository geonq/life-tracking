#!/usr/bin/env python3
"""Extract Claude Code rate limits into a private, single-slot spool."""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

try:  # Support both ``python -m scripts.usage...`` and direct launchd paths.
    from .protocol import (
        MAX_INPUT_BYTES,
        ProtocolError,
        canonical_json,
        parse_json,
        read_capped_stream,
        valid_percentage,
        valid_reset_epoch,
        validate_payload,
    )
except ImportError:  # pragma: no cover - exercised by direct script launch.
    from protocol import (  # type: ignore[no-redef]
        MAX_INPUT_BYTES,
        ProtocolError,
        canonical_json,
        parse_json,
        read_capped_stream,
        valid_percentage,
        valid_reset_epoch,
        validate_payload,
    )


UNAVAILABLE = "CLAUDE USAGE unavailable"


def extract_rate_limits(document: Any) -> dict[str, Any]:
    """Return only allowlisted, valid fields from a Claude status payload.

    Unknown top-level/nested fields are deliberately ignored.  A malformed
    root or rate-limit container is treated as a bad sample; a malformed
    optional window/field simply contributes no value, never a coerced value.
    """

    if not isinstance(document, dict):
        raise ProtocolError("status payload is not an object")

    output: dict[str, Any] = {"rate_limits": {}}
    if "rate_limits" not in document:
        return output
    source = document["rate_limits"]
    if not isinstance(source, dict):
        raise ProtocolError("rate limits is not an object")

    for window_name in ("five_hour", "seven_day"):
        source_window = source.get(window_name)
        if not isinstance(source_window, dict):
            continue
        clean_window: dict[str, Any] = {}
        used = source_window.get("used_percentage")
        reset = source_window.get("resets_at")
        if "used_percentage" in source_window and valid_percentage(used):
            clean_window["used_percentage"] = used
        if "resets_at" in source_window and valid_reset_epoch(reset):
            clean_window["resets_at"] = reset
        if clean_window:
            output["rate_limits"][window_name] = clean_window

    return validate_payload(output)


def _write_atomic(path: Path, payload: dict[str, Any]) -> None:
    """Atomically replace ``path`` with canonical JSON mode 0600 contents."""

    parent = path.parent
    parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    encoded = canonical_json(payload)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        dir=os.fspath(parent),
    )
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as temporary:
            fd = -1
            temporary.write(encoded)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.replace(temporary_name, os.fspath(path))
        # Persist the directory entry when the platform permits opening the
        # directory for fsync.  The replacement itself remains atomic even if
        # this best-effort durability step is unavailable.
        try:
            directory_flags = os.O_RDONLY
            if hasattr(os, "O_DIRECTORY"):
                directory_flags |= os.O_DIRECTORY
            directory_fd = os.open(os.fspath(parent), directory_flags)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    finally:
        if fd != -1:
            try:
                os.close(fd)
            except OSError:
                pass
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def status_line(payload: dict[str, Any]) -> str:
    parts: list[str] = []
    limits = payload["rate_limits"]
    for window_name, label in (("five_hour", "5h"), ("seven_day", "7d")):
        window = limits.get(window_name, {})
        if "used_percentage" in window:
            # str() preserves the parsed numeric value without a lossy cast.
            parts.append(f"{label} {window['used_percentage']}%")
    if not parts:
        return UNAVAILABLE
    return "CLAUDE USAGE " + " · ".join(parts)


def _stdin_bytes() -> bytes:
    stream = getattr(sys.stdin, "buffer", sys.stdin)
    return read_capped_stream(stream, MAX_INPUT_BYTES)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spool", required=True, type=Path)
    args = parser.parse_args(argv)

    try:
        raw = _stdin_bytes()
        document = parse_json(raw)
        payload = extract_rate_limits(document)
        _write_atomic(args.spool, payload)
        print(status_line(payload))
    except Exception:
        # This command is called from a status-line process.  Do not expose
        # parse errors, paths, transcript data, or network-like diagnostics.
        print(UNAVAILABLE)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
