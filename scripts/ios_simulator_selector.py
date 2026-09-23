#!/usr/bin/env python3
"""Select a deterministic iPhone simulator from ``simctl -j`` output."""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Mapping
from typing import Any, NamedTuple


_UDID = re.compile(r"[0-9A-Fa-f]{8}-(?:[0-9A-Fa-f]{4}-){3}[0-9A-Fa-f]{12}")
_RUNTIME_IDENTIFIER = re.compile(
    r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-([0-9]{1,3}-[0-9]{1,3}(?:-[0-9]{1,3})?)"
)
_VERSION_FORMAT = r"[0-9]{1,3}\.[0-9]{1,3}(?:\.[0-9]{1,3})?"
_RUNTIME_NAME = re.compile(rf"iOS ({_VERSION_FORMAT})")
_RUNTIME_VERSION = re.compile(_VERSION_FORMAT)
_DEVICE_NAME = re.compile(r"iPhone [A-Za-z0-9]+(?: [A-Za-z0-9]+)*(?: \([A-Za-z0-9 ]+\))?")


class _Candidate(NamedTuple):
    name: str
    udid: str
    state: str
    version: tuple[int, int, int]


def _parse_version(value: Any) -> tuple[int, int, int] | None:
    if not isinstance(value, str) or _RUNTIME_VERSION.fullmatch(value) is None:
        return None
    parts = tuple(int(part) for part in value.split("."))
    return parts[0], parts[1], parts[2] if len(parts) == 3 else 0


def _runtime_version(runtime: Any) -> tuple[int, ...] | None:
    if not isinstance(runtime, Mapping) or runtime.get("isAvailable") is not True:
        return None

    identifier = runtime.get("identifier")
    name = runtime.get("name")
    version = runtime.get("version")
    if not all(isinstance(value, str) for value in (identifier, name, version)):
        return None

    identifier_match = _RUNTIME_IDENTIFIER.fullmatch(identifier)
    name_match = _RUNTIME_NAME.fullmatch(name)
    parsed_version = _parse_version(version)
    if identifier_match is None or name_match is None or parsed_version is None:
        return None

    identifier_version = _parse_version(identifier_match.group(1).replace("-", "."))
    name_version = _parse_version(name_match.group(1))
    if identifier_version is None or name_version is None:
        return None
    # Runtime names and identifiers may omit the patch component even when
    # `version` includes it. The version field remains the ordering source.
    if identifier_version[:2] != name_version[:2] or name_version[:2] != parsed_version[:2]:
        return None
    return parsed_version


def _valid_device_name(value: Any) -> bool:
    return isinstance(value, str) and _DEVICE_NAME.fullmatch(value) is not None


def _generic_fallback_name(value: str) -> bool:
    model_tokens = value.split()[1:]
    return not any(token.strip("()").casefold() in {"pro", "se"} for token in model_tokens)


def select_simulator(payload: Mapping[str, Any]) -> tuple[str, str] | None:
    """Return ``(udid, state)`` under the preferred-model/runtime policy."""
    if not isinstance(payload, Mapping):
        return None
    runtimes = payload.get("runtimes")
    device_groups = payload.get("devices")
    if not isinstance(runtimes, list) or not isinstance(device_groups, Mapping):
        return None

    runtime_by_id: dict[str, tuple[int, int, int]] = {}
    for runtime in runtimes:
        if not isinstance(runtime, Mapping):
            continue
        identifier = runtime.get("identifier")
        version = _runtime_version(runtime)
        if version is not None and isinstance(identifier, str):
            runtime_by_id[identifier] = version

    candidates: list[_Candidate] = []
    for runtime_id, devices in device_groups.items():
        runtime_version = runtime_by_id.get(runtime_id) if isinstance(runtime_id, str) else None
        if runtime_version is None or not isinstance(devices, list):
            continue
        for device in devices:
            if not isinstance(device, Mapping) or device.get("isAvailable") is not True:
                continue
            name = device.get("name")
            udid = device.get("udid")
            state = device.get("state")
            if not _valid_device_name(name):
                continue
            if not isinstance(udid, str) or udid != udid.strip() or _UDID.fullmatch(udid) is None:
                continue
            if not isinstance(state, str) or state not in {"Booted", "Shutdown"}:
                continue
            candidates.append(_Candidate(name, udid, state, runtime_version))

    preferred = [candidate for candidate in candidates if candidate.name == "iPhone 17"]
    eligible = preferred or [
        candidate for candidate in candidates if _generic_fallback_name(candidate.name)
    ]
    if not eligible:
        return None

    newest_version = max(candidate.version for candidate in eligible)
    selected = min(
        (candidate for candidate in eligible if candidate.version == newest_version),
        key=lambda candidate: (candidate.udid.casefold(), candidate.udid),
    )
    return selected.udid, selected.state


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, UnicodeDecodeError) as error:
        print(f"Invalid simctl JSON: {error}", file=sys.stderr)
        return 2
    selection = select_simulator(payload)
    if selection is not None:
        print(f"{selection[0]}|{selection[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
