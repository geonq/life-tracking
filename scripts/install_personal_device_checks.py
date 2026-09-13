"""Bounded checks used by the personal-device installer.

The module keeps the untrusted CoreDevice JSON and signed plist validation
outside the shell so both paths can be exercised with fixtures without
starting Xcode or installing an app.
"""

from __future__ import annotations

from datetime import datetime, timezone
import ctypes
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from typing import Any
from xml.parsers import expat


DEVICE_UDID = re.compile(r"(?=.*[0-9A-Fa-f])[0-9A-Fa-f-]{8,64}\Z")
PHYSICAL_TRANSPORTS = frozenset({"wired", "localnetwork", "network"})
POSITIVE_STATES = frozenset({"connected", "available"})
NEGATIVE_STATES = frozenset(
    {
        "disconnected",
        "unavailable",
        "offline",
        "notconnected",
        "notpaired",
        "unpaired",
        "unknown",
        "error",
        "failed",
        "failure",
        "inactive",
        "shutdown",
        "pairing",
        "pairingfailed",
        "notready",
    }
)
KNOWN_STATES = POSITIVE_STATES | NEGATIVE_STATES
KNOWN_PAIRING_STATES = frozenset({"paired"}) | NEGATIVE_STATES
KNOWN_BOOT_STATES = frozenset({"booted"}) | NEGATIVE_STATES
KNOWN_TRANSPORTS = PHYSICAL_TRANSPORTS | frozenset({"samemachine"})
KNOWN_REALITIES = frozenset({"physical", "simulator"})
KNOWN_PLATFORMS = frozenset({"ios", "ipados", "tvos", "watchos", "macos"})
KNOWN_DEVICE_TYPES = frozenset({"iphone", "ipad", "ipod", "applewatch", "mac"})
APP_GROUP_KEY = "com.apple.security.application-groups"
APP_GROUP_PATTERN = re.compile(r"(?=.{1,128}\Z)group\.[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*\Z")
MAX_METADATA_BYTES = 64 * 1024
MAX_PLIST_BYTES = 256 * 1024
MAX_DEVICE_JSON_BYTES = 4 * 1024 * 1024
MAX_COMMAND_OUTPUT_BYTES = 1024 * 1024
PROCESS_POLL_SECONDS = 0.1
PROC_PIDTBSDINFO = 3
PROC_PIDVNODEPATHINFO = 9
DARWIN_CWD_PATH_OFFSET = 152
TRUSTED_SYSTEM_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"
TRUSTED_XCRUN = "/usr/bin/xcrun"
TRUSTED_XCODEBUILD = "/usr/bin/xcodebuild"
TRUSTED_CODESIGN = "/usr/bin/codesign"
TRUSTED_SECURITY = "/usr/bin/security"
TRUSTED_PYTHON = "/usr/bin/python3"
TRUSTED_HELPER_PATH = "/Users/georgdomke/Developer/life-tracking/scripts/install_personal_device_checks.py"
KNOWN_BUNDLE_IDENTIFIERS = frozenset(
    {"com.hermes.lifeos.app", "com.hermes.lifeos.app.widget"}
)
PYTHON_SAFE_FLAGS = ("-S", "-B")
# Keep only values needed for the user's keychain/Xcode session and the
# fixture stubs. In particular, do not inherit developer-toolchain selectors
# such as DEVELOPER_DIR, TOOLCHAINS, SDKROOT, XCODE_XCCONFIG_FILE, or
# CODESIGN_ALLOCATE: xcrun and xcodebuild treat those as executable/config
# selection inputs.
PRESERVED_CHILD_ENVIRONMENT = frozenset(
    {
        "HOME",
        "LANG",
        "LC_ALL",
        "LC_CTYPE",
        "LC_MESSAGES",
        "LOGNAME",
        "TERM",
        "TMPDIR",
        "USER",
    }
)
# Empty in production. Fixture copies may replace this constant at build time
# so the command-flow tests can use temporary stubs without adding a runtime
# tool-selection escape hatch.
TEST_EXECUTABLES = frozenset()


class DeviceListError(ValueError):
    """Raised when CoreDevice JSON is malformed at the result boundary."""


class _RejectDuplicateDict(dict[str, Any]):
    """Dictionary used by plistlib to reject duplicate XML/binary keys."""

    def __setitem__(self, key: str, value: Any) -> None:
        if key in self:
            raise ValueError("duplicate plist key")
        super().__setitem__(key, value)


def _reject_duplicate_json_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise DeviceListError("duplicate device JSON key")
        result[key] = value
    return result


def _reject_json_constant(value: str) -> object:
    raise DeviceListError(f"unsupported JSON constant: {value}")


def _state_key(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return re.sub(r"[\s_-]+", "", value.strip().casefold())


def _mapping(value: object) -> dict[str, Any] | None:
    return value if isinstance(value, dict) else None


def _valid_udid(value: object) -> str | None:
    if not isinstance(value, str):
        return None
    candidate = value.strip()
    return candidate if DEVICE_UDID.fullmatch(candidate) else None


def _has_negative_state(values: tuple[object, ...]) -> bool:
    return any(_state_key(value) in NEGATIVE_STATES for value in values)


def _known_or_missing(mapping: dict[str, Any], key: str, allowed: frozenset[str]) -> bool:
    if key not in mapping:
        return True
    value = mapping[key]
    if not isinstance(value, str):
        return False
    normalized = _state_key(value)
    return bool(normalized) and normalized in allowed


def connected_iphone_udids(payload: object) -> tuple[str, ...]:
    """Return unique UDIDs with coherent physical, connected iPhone evidence.

    CoreDevice may list simulators and paired-but-unavailable devices beside a
    connected phone. A candidate needs explicit iPhone/iOS hardware, physical
    transport, paired and booted state, developer services, and a positive
    connection state. A negative state for a known UDID disqualifies that UDID
    even if another record happens to mention it positively.
    """

    root = _mapping(payload)
    result = _mapping(root.get("result")) if root else None
    devices = result.get("devices") if result else None
    if not isinstance(devices, list):
        raise DeviceListError("invalid device result")

    candidates: dict[str, str] = {}
    rejected: set[str] = set()
    for device in devices:
        device_map = _mapping(device)
        if not device_map:
            continue
        hardware = _mapping(device_map.get("hardwareProperties"))
        hardware_for_id = hardware or {}
        nested_udid = _valid_udid(hardware_for_id.get("udid"))
        top_level_udid = _valid_udid(device_map.get("udid"))
        if nested_udid and top_level_udid and nested_udid.casefold() != top_level_udid.casefold():
            nested_key = nested_udid.casefold()
            top_level_key = top_level_udid.casefold()
            rejected.add(nested_key)
            rejected.add(top_level_key)
            candidates.pop(nested_key, None)
            candidates.pop(top_level_key, None)
            continue
        identifiable_udid = nested_udid or top_level_udid
        if not identifiable_udid:
            continue
        key = identifiable_udid.casefold()
        if not nested_udid:
            rejected.add(key)
            candidates.pop(key, None)
            continue
        udid = nested_udid
        connection = _mapping(device_map.get("connectionProperties"))
        properties = _mapping(device_map.get("deviceProperties"))
        if not hardware or not connection or not properties:
            rejected.add(key)
            candidates.pop(key, None)
            continue

        required_fields = (
            (device_map, "state"),
            (connection, "transportType"),
            (connection, "tunnelState"),
            (connection, "pairingState"),
            (properties, "bootState"),
            (properties, "ddiServicesAvailable"),
            (hardware, "platform"),
            (hardware, "deviceType"),
            (hardware, "reality"),
        )
        if any(field not in mapping for mapping, field in required_fields):
            rejected.add(key)
            candidates.pop(key, None)
            continue

        state_values = (
            device_map.get("state"),
            connection.get("tunnelState"),
            connection.get("pairingState"),
            properties.get("bootState"),
            connection.get("transportType"),
            hardware.get("reality"),
        )
        if (
            not _known_or_missing(device_map, "state", KNOWN_STATES)
            or not _known_or_missing(connection, "tunnelState", KNOWN_STATES)
            or not _known_or_missing(connection, "pairingState", KNOWN_PAIRING_STATES)
            or not _known_or_missing(properties, "bootState", KNOWN_BOOT_STATES)
            or not _known_or_missing(connection, "transportType", KNOWN_TRANSPORTS)
            or not _known_or_missing(hardware, "reality", KNOWN_REALITIES)
            or not _known_or_missing(hardware, "platform", KNOWN_PLATFORMS)
            or not _known_or_missing(hardware, "deviceType", KNOWN_DEVICE_TYPES)
            or not isinstance(properties.get("ddiServicesAvailable"), bool)
            or _has_negative_state(state_values)
        ):
            rejected.add(key)
            candidates.pop(key, None)
            continue

        if _state_key(hardware.get("platform")) != "ios":
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if _state_key(hardware.get("deviceType")) != "iphone":
            rejected.add(key)
            candidates.pop(key, None)
            continue
        reality = _state_key(hardware.get("reality"))
        transport = _state_key(connection.get("transportType"))
        if reality != "physical":
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if transport not in PHYSICAL_TRANSPORTS:
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if _state_key(connection.get("pairingState")) != "paired":
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if _state_key(properties.get("bootState")) != "booted":
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if properties.get("ddiServicesAvailable") is not True:
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if not (
            _state_key(connection.get("tunnelState")) in POSITIVE_STATES
            or _state_key(device_map.get("state")) in POSITIVE_STATES
        ):
            rejected.add(key)
            candidates.pop(key, None)
            continue
        if key in rejected:
            continue
        if key in candidates:
            rejected.add(key)
            candidates.pop(key, None)
            continue
        candidates.setdefault(key, udid)

    return tuple(udid for key, udid in candidates.items() if key not in rejected)


def _read_plist(path: str) -> dict[str, Any] | None:
    try:
        file_path = Path(path)
        if file_path.stat().st_size > MAX_PLIST_BYTES:
            return None
        with file_path.open("rb") as handle:
            value = plistlib.loads(
                handle.read(MAX_PLIST_BYTES + 1),
                dict_type=_RejectDuplicateDict,
            )
    except (OSError, UnicodeDecodeError, plistlib.InvalidFileException,
            ValueError, TypeError, OverflowError, expat.ExpatError):
        return None
    return value if isinstance(value, dict) else None


def load_device_json(path: str) -> object:
    file_path = Path(path)
    try:
        if file_path.stat().st_size > MAX_DEVICE_JSON_BYTES:
            raise DeviceListError("device JSON too large")
        with file_path.open("rb") as handle:
            raw = handle.read(MAX_DEVICE_JSON_BYTES + 1)
    except OSError as error:
        raise DeviceListError("cannot read device JSON") from error
    if len(raw) > MAX_DEVICE_JSON_BYTES:
        raise DeviceListError("device JSON too large")
    try:
        return json.loads(
            raw.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DeviceListError("invalid device JSON") from error


def _read_text(path: str) -> str | None:
    try:
        file_path = Path(path)
        if file_path.stat().st_size > MAX_METADATA_BYTES:
            return None
        with file_path.open("rb") as handle:
            data = handle.read(MAX_METADATA_BYTES + 1)
        if len(data) > MAX_METADATA_BYTES:
            return None
        return data.decode("utf-8")
    except (OSError, UnicodeDecodeError):
        return None


def _darwin_process_snapshot() -> dict[int, tuple[int, int]]:
    """Return pid -> (parent pid, real uid) using macOS libproc."""

    if sys.platform != "darwin":
        return {}
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        list_all = libproc.proc_listallpids
        list_all.argtypes = [ctypes.c_void_p, ctypes.c_int]
        list_all.restype = ctypes.c_int
        pid_count = list_all(None, 0)
        if pid_count <= 0:
            return {}
        pid_array = (ctypes.c_int * pid_count)()
        actual_count = list_all(pid_array, ctypes.sizeof(pid_array))
        if actual_count <= 0:
            return {}
        pid_info = libproc.proc_pidinfo
        pid_info.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        pid_info.restype = ctypes.c_int
        snapshot: dict[int, tuple[int, int]] = {}
        for index in range(min(actual_count, pid_count)):
            pid = int(pid_array[index])
            if pid <= 0:
                continue
            buffer = ctypes.create_string_buffer(1024)
            result_size = pid_info(pid, PROC_PIDTBSDINFO, 0, buffer, len(buffer))
            if result_size < 44:
                continue
            reported_pid = int.from_bytes(buffer.raw[12:16], "little")
            parent_pid = int.from_bytes(buffer.raw[16:20], "little")
            real_uid = int.from_bytes(buffer.raw[28:32], "little")
            if reported_pid == pid and real_uid == os.getuid():
                snapshot[pid] = (parent_pid, real_uid)
        return snapshot
    except (OSError, AttributeError, ctypes.ArgumentError, ValueError):
        return {}


def _darwin_processes_with_cwd(target_cwd: str) -> set[int]:
    """Find our-user processes that still hold the invocation cwd.

    A child can create a new session, so its process group no longer identifies
    it. The invocation gets a private 0700 cwd; inherited cwd is an additional
    stable handle that remains queryable after the original command exits.
    """

    if sys.platform != "darwin":
        return set()
    snapshot = _darwin_process_snapshot()
    if not snapshot:
        return set()
    try:
        libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
        pid_info = libproc.proc_pidinfo
        pid_info.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int]
        pid_info.restype = ctypes.c_int
        expected = os.path.realpath(target_cwd)
        cwd_path_offset = DARWIN_CWD_PATH_OFFSET
        cwd_path_length = 1024
        buffer_size = 2 * (cwd_path_offset + cwd_path_length)
        found: set[int] = set()
        for pid in snapshot:
            buffer = ctypes.create_string_buffer(buffer_size)
            result_size = pid_info(pid, PROC_PIDVNODEPATHINFO, 0, buffer, len(buffer))
            if result_size < cwd_path_offset + 1:
                continue
            raw_path = buffer.raw[cwd_path_offset : cwd_path_offset + cwd_path_length]
            current_cwd = raw_path.split(b"\0", 1)[0].decode("utf-8", errors="replace")
            if current_cwd and os.path.realpath(current_cwd) == expected:
                found.add(pid)
        return found
    except (OSError, AttributeError, ctypes.ArgumentError, ValueError):
        return set()


def _descendant_pids(root_pid: int) -> set[int]:
    snapshot = _darwin_process_snapshot()
    children: dict[int, list[int]] = {}
    for pid, (parent_pid, _uid) in snapshot.items():
        children.setdefault(parent_pid, []).append(pid)
    descendants: set[int] = set()
    pending = [root_pid]
    while pending:
        parent_pid = pending.pop()
        for child_pid in children.get(parent_pid, ()):
            if child_pid not in descendants:
                descendants.add(child_pid)
                pending.append(child_pid)
    return descendants


def _send_signal(pid: int, signum: signal.Signals) -> None:
    if pid <= 0 or pid == os.getpid():
        return
    try:
        os.kill(pid, signum)
    except (OSError, ProcessLookupError):
        pass


def _absolute_path(value: object) -> bool:
    return isinstance(value, str) and "\0" not in value and Path(value).is_absolute()


def _decimal_timeout(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[1-9][0-9]{0,3}", value) is not None


def _valid_bundle_identifier(value: object) -> bool:
    return isinstance(value, str) and value in KNOWN_BUNDLE_IDENTIFIERS


def _valid_team_argument(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"DEVELOPMENT_TEAM=[A-Z0-9]{10}", value) is not None


def _valid_app_group_argument(value: object) -> bool:
    return (
        isinstance(value, str)
        and re.fullmatch(
            r"APP_GROUP_IDENTIFIER=group\.[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)*",
            value,
        )
        is not None
    )


def _command_is_permitted(command: list[str]) -> bool:
    if not command:
        return False
    executable = command[0]
    if executable in TEST_EXECUTABLES:
        return True
    if executable == TRUSTED_XCRUN:
        if command == [TRUSTED_XCRUN, "--find", "devicectl"]:
            return True
        if len(command) == 11 and command[1:4] == ["devicectl", "--quiet", "--timeout"]:
            return (
                _decimal_timeout(command[4])
                and command[5] == "--json-output"
                and _absolute_path(command[6])
                and command[7] == "--log-output"
                and _absolute_path(command[8])
                and command[9:] == ["list", "devices"]
            )
        if len(command) == 15 and command[1:4] == ["devicectl", "--quiet", "--timeout"]:
            return (
                _decimal_timeout(command[4])
                and command[5] == "--json-output"
                and _absolute_path(command[6])
                and command[7] == "--log-output"
                and _absolute_path(command[8])
                and command[9:13] == ["device", "install", "app", "--device"]
                and bool(DEVICE_UDID.fullmatch(command[13]))
                and _absolute_path(command[14])
            )
        return False
    if executable == TRUSTED_XCODEBUILD:
        if len(command) != 21:
            return False
        return (
            command[1] == "-project"
            and _absolute_path(command[2])
            and command[3:5] == ["-scheme", "LifeOS"]
            and command[5:7] == ["-configuration", "Debug"]
            and command[7] == "-destination"
            and isinstance(command[8], str)
            and command[8].startswith("id=")
            and bool(DEVICE_UDID.fullmatch(command[8][3:]))
            and command[9] == "-derivedDataPath"
            and _absolute_path(command[10])
            and command[11:15] == ["-parallel-testing-enabled", "NO", "-jobs", "1"]
            and command[15:18] == [
                "-quiet",
                "CODE_SIGN_STYLE=Automatic",
                "CODE_SIGNING_REQUIRED=YES",
            ]
            and _valid_team_argument(command[18])
            and _valid_app_group_argument(command[19])
            and command[20] == "build"
        )
    if executable == TRUSTED_CODESIGN:
        if len(command) == 5 and command[1:4] == ["--verify", "--deep", "--strict"]:
            return _absolute_path(command[4])
        if len(command) == 4 and command[1:3] == ["--verify", "--strict"]:
            return _absolute_path(command[3])
        if len(command) == 4 and command[1:3] == ["--display", "--verbose=4"]:
            return _absolute_path(command[3])
        return len(command) == 5 and command[1:4] == ["-d", "--entitlements", ":-"] and _absolute_path(command[4])
    if executable == TRUSTED_SECURITY:
        return len(command) == 7 and command[1:4] == ["cms", "-D", "-i"] and command[5] == "-o" and _absolute_path(command[4]) and _absolute_path(command[6])
    if executable == TRUSTED_PYTHON:
        if (
            len(command) < 5
            or tuple(command[1:3]) != PYTHON_SAFE_FLAGS
            or command[3] != TRUSTED_HELPER_PATH
            or Path(command[3]).is_symlink()
            or not Path(command[3]).is_file()
        ):
            return False
        if command[4] == "--devices":
            return len(command) == 6 and _absolute_path(command[5])
        if command[4] == "--validate-info-plist":
            return (
                len(command) == 7
                and _absolute_path(command[5])
                and _valid_bundle_identifier(command[6])
            )
        if command[4] == "--validate-bundle":
            return (
                len(command) == 12
                and all(_absolute_path(value) for value in command[5:8])
                and _valid_team_argument(f"DEVELOPMENT_TEAM={command[8]}")
                and _valid_bundle_identifier(command[9])
                and bool(DEVICE_UDID.fullmatch(command[10]))
                and _valid_app_group_argument(f"APP_GROUP_IDENTIFIER={command[11]}")
            )
        return False
    return False


def _sanitized_environment() -> dict[str, str]:
    environment = {
        key: os.environ[key]
        for key in PRESERVED_CHILD_ENVIRONMENT
        if key in os.environ
    }
    # The fixture command-flow tests use environment variables to communicate
    # with temporary stubs. They are absent from the production environment.
    environment.update(
        {
            key: value
            for key, value in os.environ.items()
            if key.startswith("LIFEOS_STUB_")
        }
    )
    environment["PATH"] = TRUSTED_SYSTEM_PATH
    environment["PYTHONNOUSERSITE"] = "1"
    environment["PYTHONSAFEPATH"] = "1"
    return environment


def _terminate_process_group(
    process: subprocess.Popen[object],
    extra_pids: set[int] | None = None,
    grace_seconds: float = 0.5,
) -> None:
    """Terminate the isolated group and descendants that escaped its group."""

    extra_pids = extra_pids or set()

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        if process.poll() is None:
            _send_signal(process.pid, signal.SIGTERM)
    for pid in extra_pids:
        _send_signal(pid, signal.SIGTERM)
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        pass
    if extra_pids:
        time.sleep(grace_seconds)
    # The group can outlive its leader or contain a TERM-ignoring child. A
    # second kill is required after the grace period regardless of leader state.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except (OSError, ProcessLookupError):
        pass
    for pid in extra_pids:
        _send_signal(pid, signal.SIGKILL)
    try:
        process.wait(timeout=grace_seconds)
    except subprocess.TimeoutExpired:
        pass


def run_bounded(timeout_seconds: int, command: list[str]) -> int:
    """Run an allowlisted command in an isolated group with best-effort cleanup."""

    if timeout_seconds <= 0 or not _command_is_permitted(command):
        return 2
    process: subprocess.Popen[object] | None = None
    previous_handlers: dict[int, Any] = {}
    descendant_pids: set[int] = set()
    readers: list[threading.Thread] = []
    cleaned = False
    sandbox_dir: str | None = None
    pending_signal: int | None = None

    def copy_bounded(stream: Any, destination_fd: int) -> None:
        emitted = 0
        while True:
            chunk = stream.read(8192)
            if not chunk:
                return
            if emitted >= MAX_COMMAND_OUTPUT_BYTES:
                continue
            chunk = chunk[: MAX_COMMAND_OUTPUT_BYTES - emitted]
            try:
                os.write(destination_fd, chunk)
                emitted += len(chunk)
            except (BrokenPipeError, OSError):
                return

    def refresh_process_handles(root_pid: int, *, include_cwd: bool = False) -> None:
        descendant_pids.update(_descendant_pids(root_pid))
        if include_cwd and sandbox_dir is not None:
            descendant_pids.update(_darwin_processes_with_cwd(sandbox_dir))

    def cleanup_command(root_pid: int) -> bool:
        refresh_process_handles(root_pid, include_cwd=True)
        assert process is not None
        _terminate_process_group(process, descendant_pids)
        if sandbox_dir is None:
            return False
        remaining = _darwin_processes_with_cwd(sandbox_dir) - {process.pid}
        for pid in remaining:
            _send_signal(pid, signal.SIGKILL)
        if remaining:
            time.sleep(0.05)
        return bool(_darwin_processes_with_cwd(sandbox_dir) - {process.pid})

    def handle_signal(signum: int, _frame: object) -> None:
        nonlocal pending_signal
        if process is not None:
            cleanup_command(process.pid)
            raise SystemExit(128 + signum)
        # Popen can have created the child while its return value is still
        # being assigned. Defer cleanup until the PID is available instead of
        # exiting with an untracked child.
        pending_signal = pending_signal or signum

    try:
        # Install handlers before spawning the command so cancellation cannot
        # arrive during an unprotected startup interval.
        for signum in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            previous_handlers[signum] = signal.getsignal(signum)
            signal.signal(signum, handle_signal)
        try:
            sandbox_dir = tempfile.mkdtemp(prefix="lifeos-command-")
            os.chmod(sandbox_dir, 0o700)
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
                cwd=sandbox_dir,
                env=_sanitized_environment(),
            )
        except OSError:
            if pending_signal is not None:
                raise SystemExit(128 + pending_signal)
            return 127
        if pending_signal is not None:
            cleanup_command(process.pid)
            cleaned = True
            raise SystemExit(128 + pending_signal)
        assert process.stdout is not None
        assert process.stderr is not None
        readers = [
            threading.Thread(target=copy_bounded, args=(process.stdout, 1), daemon=True),
            threading.Thread(target=copy_bounded, args=(process.stderr, 2), daemon=True),
        ]
        for reader in readers:
            reader.start()
        try:
            deadline = time.monotonic() + timeout_seconds
            while process.poll() is None:
                # Poll in the supervising thread as well as the watcher. This
                # closes the common fast-fork window before wait() would hand
                # scheduling entirely to the child.
                refresh_process_handles(process.pid)
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise subprocess.TimeoutExpired(command, timeout_seconds)
                time.sleep(min(PROCESS_POLL_SECONDS, remaining))
            return_code = process.returncode
            assert return_code is not None
        except subprocess.TimeoutExpired:
            cleanup_failed = cleanup_command(process.pid)
            return 125 if cleanup_failed else 124
        # A command may exit while leaving a descendant in its process group
        # or in a new session. Clean both the isolated group and observed tree.
        cleanup_failed = cleanup_command(process.pid)
        if cleanup_failed:
            return 125
        cleaned = True
        return return_code if return_code >= 0 else 128 + (-return_code)
    finally:
        if process is not None and not cleaned:
            cleanup_command(process.pid)
        for reader in readers:
            reader.join(timeout=1.0)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        if sandbox_dir is not None:
            shutil.rmtree(sandbox_dir, ignore_errors=True)


def _codesign_fields(metadata: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in metadata.splitlines():
        for key in ("Identifier", "TeamIdentifier"):
            prefix = f"{key}="
            if line.startswith(prefix):
                fields[key] = line[len(prefix) :].strip()
    return fields


def _contains_placeholder(value: str) -> bool:
    lowered = value.casefold()
    return any(
        marker in lowered
        for marker in (
            "placeholder",
            "replace",
            "example",
            "your",
            "teamid",
            "change-me",
            "changeme",
            "todo",
        )
    )


def _valid_app_groups(value: object, expected: str) -> tuple[str, ...] | None:
    if not isinstance(value, list) or not value:
        return None
    groups: list[str] = []
    for group in value:
        if (
            not isinstance(group, str)
            or not APP_GROUP_PATTERN.fullmatch(group)
            or _contains_placeholder(group)
            or group in groups
        ):
            return None
        groups.append(group)
    return tuple(groups) if expected in groups else None


def _profile_is_valid(
    profile: dict[str, Any],
    expected_team: str,
    expected_bundle_id: str,
    selected_udid: str,
    expected_app_group: str,
    signed_groups: tuple[str, ...],
) -> bool:
    team_ids = profile.get("TeamIdentifier")
    if not isinstance(team_ids, list) or expected_team.casefold() not in {
        value.casefold() for value in team_ids if isinstance(value, str)
    }:
        return False

    provisioned_devices = profile.get("ProvisionedDevices")
    if not isinstance(provisioned_devices, list):
        return False
    selected = selected_udid.casefold()
    if selected not in {
        value.casefold() for value in provisioned_devices if isinstance(value, str)
    }:
        return False

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        return False
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=timezone.utc)
    if expiration <= datetime.now(timezone.utc):
        return False

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        return False
    if entitlements.get("application-identifier") != f"{expected_team}.{expected_bundle_id}":
        return False
    if entitlements.get("com.apple.developer.team-identifier") != expected_team:
        return False
    profile_groups = _valid_app_groups(entitlements.get(APP_GROUP_KEY), expected_app_group)
    return profile_groups is not None and set(signed_groups).issubset(profile_groups)


def validate_signed_bundle(
    metadata_path: str,
    entitlements_path: str,
    profile_path: str,
    expected_team: str,
    expected_bundle_id: str,
    selected_udid: str,
    expected_app_group: str,
) -> str | None:
    """Return a sanitized failure category, or ``None`` when all checks pass."""

    metadata = _read_text(metadata_path)
    entitlements = _read_plist(entitlements_path)
    profile = _read_plist(profile_path)
    if metadata is None or entitlements is None:
        return "signing"
    fields = _codesign_fields(metadata)
    if fields.get("Identifier") != expected_bundle_id or fields.get("TeamIdentifier") != expected_team:
        return "signing"
    if entitlements.get("application-identifier") != f"{expected_team}.{expected_bundle_id}":
        return "signing"
    if entitlements.get("com.apple.developer.team-identifier") != expected_team:
        return "signing"
    signed_groups = _valid_app_groups(entitlements.get(APP_GROUP_KEY), expected_app_group)
    if signed_groups is None:
        return "app-group"
    if profile is None or not _profile_is_valid(
        profile,
        expected_team,
        expected_bundle_id,
        selected_udid,
        expected_app_group,
        signed_groups,
    ):
        return "profile"
    return None


def validate_info_plist(path: str, expected_bundle_id: str) -> bool:
    """Validate a bundle identity without accepting duplicate plist keys."""

    info = _read_plist(path)
    return bool(
        info is not None
        and isinstance(info.get("CFBundleIdentifier"), str)
        and info.get("CFBundleIdentifier") == expected_bundle_id
    )


def _main(argv: list[str]) -> int:
    if len(argv) >= 5 and argv[1] == "--run-bounded" and argv[3] == "--":
        try:
            timeout_seconds = int(argv[2])
        except ValueError:
            return 2
        return run_bounded(timeout_seconds, argv[4:])

    if len(argv) == 3 and argv[1] == "--devices":
        try:
            payload = load_device_json(argv[2])
            for udid in connected_iphone_udids(payload):
                print(udid)
            return 0
        except (OSError, UnicodeDecodeError, json.JSONDecodeError, DeviceListError):
            return 1

    if len(argv) == 9 and argv[1] == "--validate-bundle":
        failure = validate_signed_bundle(*argv[2:])
        return {
            None: 0,
            "signing": 10,
            "profile": 11,
            "app-group": 12,
        }[failure]

    if len(argv) == 4 and argv[1] == "--validate-info-plist":
        return 0 if validate_info_plist(argv[2], argv[3]) else 10

    return 2


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv))
