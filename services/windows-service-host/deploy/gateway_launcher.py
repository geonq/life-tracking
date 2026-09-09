"""Least-privilege gateway adapter used by the Windows service host.

The adapter owns the process boundary: it validates the path-only deployment
config and private Tailscale Serve route, reads the operator-managed edge-token
file only into this process, derives the local Tailscale login at runtime, and
bridges Tailscale's public app-capability assertion to the gateway's private
trusted-edge header before importing the reviewed FastAPI module.  It never
prints config, identity, or secret material.
"""

from __future__ import annotations

import argparse
import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import suppress
import ctypes
from datetime import datetime, timezone
from email.header import decode_header
import http.client
import importlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import struct
import sys
import threading
from typing import Any, NamedTuple
from urllib.parse import urlsplit
from ctypes import wintypes


EXPECTED_FIELDS = {
    "bindHost",
    "port",
    "apiBaseUrl",
    "dataDirectory",
    "calendarPath",
    "documentsPath",
    "claudeSecretPath",
    "tailscaleEdgeTokenPath",
    "tailscaleServePort",
    "funnel",
}
PRIVATE_PROXY = "http://127.0.0.1:8421"
TRUSTED_EDGE_APP_CAPABILITY = "lifeos.example/trusted-edge"
TRUSTED_EDGE_HEADER = b"x-lifeos-trusted-edge"
TAILSCALE_APP_CAPABILITIES_HEADER = b"tailscale-app-capabilities"
TAILSCALE_SERVICE_NAME_ENV = "LIFEOS_TAILSCALE_SERVICE_NAME"
DEFAULT_TAILSCALE_SERVICE_NAME = "Tailscale"
TAILSCALE_SNAPSHOT_PATH_ENV = "LIFEOS_TAILSCALE_SNAPSHOT_PATH"
# Reviewed service constants only: never take lease policy from HTTP input.
# Idle revocation detection is bounded by interval + read timeout.
TAILSCALE_RUNTIME_LEASE_SECONDS = 1.0
TAILSCALE_RUNTIME_READ_TIMEOUT_SECONDS = 0.5
TAILSCALE_SNAPSHOT_MAX_AGE_SECONDS = 90
TAILSCALE_SNAPSHOT_MAX_FUTURE_SECONDS = 5
LOCAL_READINESS_TIMEOUT_SECONDS = 1.0
BOUNDED_PROBE_MAX_WORKERS = 2
# A single waiter is enough to absorb the normal third simultaneous request
# without turning a stalled Windows query into an executor queue. Additional
# callers fail closed until one of the bounded worker slots is released.
BOUNDED_PROBE_MAX_WAITERS = 1
BOUNDED_PROBE_MAX_TRACKED_PROBES = (
    BOUNDED_PROBE_MAX_WORKERS + BOUNDED_PROBE_MAX_WAITERS + 1
)
BOUNDED_PROBE_MAX_CONSUMERS_PER_PROBE = (
    BOUNDED_PROBE_MAX_WORKERS + BOUNDED_PROBE_MAX_WAITERS + 1
)
SERVE_CONFIG_KEYS = frozenset({"Web", "TCP", "Services", "AllowFunnel", "Foreground"})
GATEWAY_LOOPBACK_PORT = 8421
WINDOWS_AF_INET = 2
WINDOWS_TCP_TABLE_OWNER_PID_ALL = 5
WINDOWS_ERROR_INSUFFICIENT_BUFFER = 122
WINDOWS_TCP_STATE_ESTABLISHED = 5
WINDOWS_SC_MANAGER_CONNECT = 0x0001
WINDOWS_SERVICE_QUERY_STATUS = 0x0004
WINDOWS_SC_STATUS_PROCESS_INFO = 0
WINDOWS_SERVICE_RUNNING = 4
WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT = 0x0400


class _WindowsTcpRowOwnerPid(ctypes.Structure):
    _fields_ = (
        ("state", wintypes.DWORD),
        ("local_address", wintypes.DWORD),
        ("local_port", ctypes.c_ubyte * 4),
        ("remote_address", wintypes.DWORD),
        ("remote_port", ctypes.c_ubyte * 4),
        ("owning_pid", wintypes.DWORD),
    )


class _WindowsServiceStatusProcess(ctypes.Structure):
    _fields_ = (
        ("service_type", wintypes.DWORD),
        ("current_state", wintypes.DWORD),
        ("controls_accepted", wintypes.DWORD),
        ("win32_exit_code", wintypes.DWORD),
        ("service_specific_exit_code", wintypes.DWORD),
        ("check_point", wintypes.DWORD),
        ("wait_hint", wintypes.DWORD),
        ("process_id", wintypes.DWORD),
        ("service_flags", wintypes.DWORD),
    )


class EdgeTokenConfigurationError(RuntimeError):
    """A safe, operator-actionable edge-token diagnostic."""


def _loopback_api_ready(api_base_url: str) -> bool:
    """Check the local API readiness contract without following redirects."""
    try:
        parsed = urlsplit(api_base_url)
        if (parsed.scheme != "http" or parsed.hostname != "127.0.0.1"
                or parsed.port != 8787 or parsed.path or parsed.query or parsed.fragment
                or parsed.username is not None or parsed.password is not None):
            return False
        connection = http.client.HTTPConnection("127.0.0.1", 8787, timeout=1.0)
        try:
            connection.request("GET", "/ready", headers={"Connection": "close"})
            response = connection.getresponse()
            if response.status != 200:
                return False
            body = response.read(1025)
            if len(body) > 1024:
                return False
            value = json.loads(body)
            return isinstance(value, dict) and value == {"readiness": "ready"}
        finally:
            connection.close()
    except (OSError, http.client.HTTPException, TypeError, ValueError, json.JSONDecodeError):
        return False


class _BoundedProbeHandle(NamedTuple):
    future: Any
    key: Any
    generation: int
    consumer_id: int


class _BoundedProbeSlot:
    __slots__ = ("future", "key", "generation", "consumers", "admission_closed")

    def __init__(self, future: Any, key: Any, generation: int) -> None:
        self.future = future
        self.key = key
        self.generation = generation
        self.consumers: set[int] = set()
        self.admission_closed = False


class _BoundedThreadProbe:
    """Run blocking probes with bounded recovery and no executor queue.

    A timed-out Python thread cannot be killed safely.  Keep that thread as a
    stale worker slot, allow one replacement slot for recovery, and admit at
    most one additional caller while both workers are occupied. Completed
    futures do not consume a worker slot, but their proof records remain until
    every consumer explicitly releases its handle. This keeps ``is_current``
    race-free without retaining an unbounded history or allowing the executor
    to grow a hidden queue.
    """

    def __init__(self, probe: Any, *, thread_name_prefix: str) -> None:
        self._probe = probe
        self._executor = ThreadPoolExecutor(
            max_workers=BOUNDED_PROBE_MAX_WORKERS,
            thread_name_prefix=thread_name_prefix,
        )
        self._lock = threading.RLock()
        self._next_generation = 0
        self._next_consumer_id = 0
        self._slots: list[_BoundedProbeSlot] = []
        self._waiters: list[tuple[asyncio.AbstractEventLoop, asyncio.Future[None]]] = []

    def _prune_finished_locked(self) -> bool:
        """Drop only completed probes with no live proof consumers.

        A finished future is deliberately retained while a consumer still has
        to call ``is_current``. Worker capacity is calculated independently
        from this list, so retaining a proof cannot block an unrelated probe.
        """
        before = len(self._slots)
        self._slots = [
            slot for slot in self._slots
            if not slot.future.done() or slot.consumers
        ]
        return len(self._slots) < before

    def _active_worker_count_locked(self) -> int:
        return sum(not slot.future.done() for slot in self._slots)

    def _slot_for_locked(self, handle: _BoundedProbeHandle) -> _BoundedProbeSlot | None:
        for slot in self._slots:
            if (slot.future is handle.future and slot.key is handle.key
                    and slot.generation == handle.generation):
                return slot
        return None

    def _issue_handle_locked(self, slot: _BoundedProbeSlot) -> _BoundedProbeHandle:
        consumer_id = self._next_consumer_id
        self._next_consumer_id += 1
        slot.consumers.add(consumer_id)
        return _BoundedProbeHandle(
            slot.future,
            slot.key,
            slot.generation,
            consumer_id,
        )

    def _submit_now_locked(self, key: Any) -> _BoundedProbeHandle | None:
        self._prune_finished_locked()
        # Coalesce only while the probe is in flight. A completed proof is
        # retained for its current consumer, but a later request gets a fresh
        # snapshot/transport check instead of consuming an old result.
        for slot in self._slots:
            if (slot.key is key and not slot.admission_closed and not slot.future.done()
                    and len(slot.consumers) < BOUNDED_PROBE_MAX_CONSUMERS_PER_PROBE):
                return self._issue_handle_locked(slot)
        # Preserve FIFO-like fairness for the one bounded admission waiter.
        # Coalescing an existing in-flight probe above remains safe; a new
        # unrelated caller must not take the slot before the waiter wakes.
        if self._waiters:
            return None
        if self._active_worker_count_locked() >= BOUNDED_PROBE_MAX_WORKERS:
            return None
        if len(self._slots) >= BOUNDED_PROBE_MAX_TRACKED_PROBES:
            return None
        generation = self._next_generation
        self._next_generation += 1
        future = self._executor.submit(self._probe, key)
        slot = _BoundedProbeSlot(future, key, generation)
        self._slots.append(slot)
        handle = self._issue_handle_locked(slot)
        # Register after the slot is visible. If the probe completes
        # immediately, the callback waits for this lock before pruning it.
        future.add_done_callback(self._on_done)
        return handle

    def submit(self, key: Any) -> _BoundedProbeHandle | None:
        """Try once without waiting; callers on an event loop use submit_async."""
        with self._lock:
            return self._submit_now_locked(key)

    @staticmethod
    def _resolve_waiter(future: asyncio.Future[None]) -> None:
        if not future.done():
            future.set_result(None)

    def _notify_waiters(self) -> None:
        with self._lock:
            waiters = tuple(self._waiters)
        for loop, future in waiters:
            try:
                loop.call_soon_threadsafe(self._resolve_waiter, future)
            except RuntimeError:
                # The owning event loop may have closed during test or process
                # teardown. There is no security decision to make here.
                continue

    def _on_done(self, _future: Any) -> None:
        with self._lock:
            self._prune_finished_locked()
        self._notify_waiters()

    def _remove_waiter(self, future: asyncio.Future[None]) -> None:
        with self._lock:
            self._waiters = [
                (loop, candidate) for loop, candidate in self._waiters
                if candidate is not future
            ]

    async def submit_async(
        self,
        key: Any,
        *,
        timeout: float,
    ) -> _BoundedProbeHandle | None:
        """Admit one bounded waiter without blocking the event loop.

        ``timeout`` covers both admission and execution. Only one pending
        admission is retained; callers beyond that bound fail closed. The
        executor receives work only after a worker slot is available, so it
        never accumulates work behind an unkillable timed-out thread.
        """
        if timeout <= 0:
            return None
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout
        while True:
            with self._lock:
                handle = self._submit_now_locked(key)
                if handle is not None:
                    return handle
                remaining = deadline - loop.time()
                if remaining <= 0 or len(self._waiters) >= BOUNDED_PROBE_MAX_WAITERS:
                    return None
                wake = loop.create_future()
                self._waiters.append((loop, wake))
            try:
                await asyncio.wait_for(asyncio.shield(wake), timeout=remaining)
            except asyncio.TimeoutError:
                return None
            except asyncio.CancelledError:
                raise
            finally:
                self._remove_waiter(wake)
                if not wake.done():
                    wake.cancel()

    def is_current(self, handle: _BoundedProbeHandle) -> bool:
        with self._lock:
            slot = self._slot_for_locked(handle)
            return slot is not None and handle.consumer_id in slot.consumers

    def mark_stale(self, handle: _BoundedProbeHandle) -> None:
        freed_capacity = False
        with self._lock:
            slot = self._slot_for_locked(handle)
            if slot is not None:
                # Staleness is consumer-local: one timed-out request must not
                # revoke a still-valid coalesced consumer of the same probe.
                slot.admission_closed = True
                slot.consumers.discard(handle.consumer_id)
                freed_capacity = self._prune_finished_locked()
        if freed_capacity:
            self._notify_waiters()

    def release(self, handle: _BoundedProbeHandle) -> None:
        """Release a proof handle after its consumer checked is_current."""
        freed_capacity = False
        with self._lock:
            slot = self._slot_for_locked(handle)
            if slot is not None:
                slot.consumers.discard(handle.consumer_id)
                freed_capacity = self._prune_finished_locked()
        if freed_capacity:
            self._notify_waiters()

    def shutdown(self, *, wait: bool = True) -> None:
        with self._lock:
            waiters = tuple(self._waiters)
            self._waiters.clear()
            self._slots.clear()
        for loop, future in waiters:
            try:
                loop.call_soon_threadsafe(self._resolve_waiter, future)
            except RuntimeError:
                continue
        self._executor.shutdown(wait=wait, cancel_futures=True)


async def _bounded_probe_result(
    reader: _BoundedThreadProbe,
    key: Any,
    timeout: float,
) -> bool:
    """Run one bounded probe with one end-to-end verification deadline."""
    loop = asyncio.get_running_loop()
    deadline = loop.time() + max(0.0, timeout)
    try:
        handle = await reader.submit_async(key, timeout=timeout)
    except Exception:
        return False
    if handle is None:
        return False
    try:
        remaining = deadline - loop.time()
        if remaining <= 0:
            reader.mark_stale(handle)
            return False
        try:
            result = await asyncio.wait_for(
                asyncio.shield(asyncio.wrap_future(handle.future)),
                timeout=remaining,
            )
        except asyncio.TimeoutError:
            reader.mark_stale(handle)
            return False
        except asyncio.CancelledError:
            reader.mark_stale(handle)
            raise
        except Exception:
            reader.mark_stale(handle)
            return False
        if not reader.is_current(handle):
            return False
        return bool(result)
    finally:
        reader.release(handle)


def _current_gateway_dependencies_ready(
    api_base_url: str,
    snapshot_path: str | None,
    tailscale_service_name: str,
) -> bool:
    """Re-evaluate every dependency required for a running gateway."""
    try:
        serve, dns_name, _login = _read_tailscale_snapshot(snapshot_path)
        if not _serve_is_exact(serve, expected_dns_name=dns_name):
            return False
        if _is_windows_host() and _windows_tailscale_service_pid(tailscale_service_name) is None:
            return False
        return _loopback_api_ready(api_base_url)
    except Exception:
        return False


class LocalReadinessAdapter:
    """Expose a local-only readiness probe with live dependency evaluation."""

    def __init__(self, app: Any, readiness_check: Any) -> None:
        self._app = app
        self._readiness_check = readiness_check
        self._readiness_key = object()
        self._reader = _BoundedThreadProbe(
            lambda _key: bool(self._readiness_check()),
            thread_name_prefix="lifeos-readiness",
        )

    async def _dependencies_ready(self) -> bool:
        try:
            return await _bounded_probe_result(
                self._reader,
                self._readiness_key,
                LOCAL_READINESS_TIMEOUT_SECONDS,
            )
        except Exception:
            return False

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> Any:
        if scope.get("type") == "http" and scope.get("path") == "/ready":
            client = scope.get("client")
            address = client[0] if isinstance(client, (tuple, list)) and client else None
            if address not in {"127.0.0.1", "::1", "::ffff:127.0.0.1"}:
                await send({"type": "http.response.start", "status": 403,
                            "headers": [(b"cache-control", b"no-store")]})
                await send({"type": "http.response.body", "body": b"Readiness is local-only"})
                return None
            ready = await self._dependencies_ready()
            if not ready:
                body = b'{"readiness":"unavailable"}'
                await send({"type": "http.response.start", "status": 503,
                            "headers": [(b"cache-control", b"no-store"),
                                        (b"content-type", b"application/json"),
                                        (b"content-length", str(len(body)).encode("ascii"))]})
                await send({"type": "http.response.body", "body": body})
                return None
            body = b'{"readiness":"ready"}'
            await send({"type": "http.response.start", "status": 200,
                        "headers": [(b"cache-control", b"no-store"),
                                    (b"content-type", b"application/json"),
                                    (b"content-length", str(len(body)).encode("ascii"))]})
            await send({"type": "http.response.body", "body": body})
            return None
        return await self._app(scope, receive, send)


def _is_windows_host() -> bool:
    return os.name == "nt"


def _stat_identity(value: os.stat_result) -> tuple[int, int, int, int, int, int, int]:
    """Return the bounded identity facts used to bind a read to one object."""
    return (
        int(value.st_dev),
        int(value.st_ino),
        int(value.st_size),
        int(value.st_mtime_ns),
        int(value.st_ctime_ns),
        int(value.st_mode),
        int(getattr(value, "st_file_attributes", 0)),
    )


def _is_reparse_stat(value: os.stat_result) -> bool:
    return stat.S_ISLNK(value.st_mode) or bool(
        int(getattr(value, "st_file_attributes", 0)) & WINDOWS_FILE_ATTRIBUTE_REPARSE_POINT
    )


def _path_identity_chain(path: Path) -> tuple[tuple[str, tuple[int, int, int, int, int, int, int]], ...]:
    """Capture every existing component without resolving reparse points."""
    current = Path(os.path.abspath(os.fspath(path)))
    chain: list[tuple[str, tuple[int, int, int, int, int, int, int]]] = []
    leaf = current
    while True:
        try:
            observed = os.lstat(current)
        except FileNotFoundError:
            break
        except OSError as exc:
            raise RuntimeError("deployment path is unreadable") from exc
        # Windows reparse points are rejected at every level. On the macOS
        # development host, /var is a normal system symlink to /private/var;
        # retain its identity in the ancestor chain while still rejecting a
        # symlink at the actual configured file/directory leaf. The POSIX open
        # uses O_NOFOLLOW for that leaf.
        if _is_reparse_stat(observed) and (os.name == "nt" or current == leaf):
            raise RuntimeError("reparse deployment path")
        chain.append((os.path.normcase(os.path.abspath(os.fspath(current))), _stat_identity(observed)))
        parent = current.parent
        if parent == current:
            break
        current = parent
    return tuple(reversed(chain))


def _open_regular_file(path: Path) -> int:
    """Open one non-reparse regular file and return its owned file descriptor.

    Windows uses CreateFile with FILE_FLAG_OPEN_REPARSE_POINT so a final
    junction/symlink is opened as the reparse object and rejected by the fstat
    check instead of being followed.  The pre/post ancestor chain checks below
    cover path components; the descriptor remains the source of bytes and
    final-file identity for the entire read.
    """
    if os.name == "nt":
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        create_file = kernel32.CreateFileW
        create_file.argtypes = [
            wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD, wintypes.LPVOID,
            wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE,
        ]
        create_file.restype = wintypes.HANDLE
        handle = create_file(
            str(path),
            0x80000000,  # GENERIC_READ
            0x00000001,  # FILE_SHARE_READ; writers cannot replace/grow it
            None,
            3,           # OPEN_EXISTING
            0x00200000 | 0x08000000,  # OPEN_REPARSE_POINT | SEQUENTIAL_SCAN
            None,
        )
        invalid = ctypes.c_void_p(-1).value
        if handle in (None, invalid):
            raise OSError(ctypes.get_last_error(), "deployment file could not be opened")
        try:
            msvcrt = ctypes.CDLL("msvcrt")
            open_osfhandle = msvcrt._open_osfhandle
            open_osfhandle.argtypes = [ctypes.c_int64, ctypes.c_int]
            open_osfhandle.restype = ctypes.c_int
            descriptor = open_osfhandle(
                ctypes.cast(handle, ctypes.c_void_p).value,
                os.O_RDONLY | getattr(os, "O_BINARY", 0),
            )
            if descriptor < 0:
                kernel32.CloseHandle(handle)
                raise OSError("deployment file descriptor could not be created")
            return descriptor
        except Exception:
            # _open_osfhandle owns a successful handle; the exception path
            # above only closes handles it still owns.
            if 'descriptor' not in locals() or descriptor < 0:
                kernel32.CloseHandle(handle)
            raise

    flags = os.O_RDONLY
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(os.fspath(path), flags)


def _read_bounded_regular_file(path: Path, *, max_bytes: int, description: str) -> bytes:
    """Read at most max_bytes+1 from one descriptor-bound regular file."""
    if max_bytes <= 0:
        raise RuntimeError(f"{description} has an invalid bounded read size")
    _safe_path(str(path), file=True, directory=False)
    before_chain = _path_identity_chain(path)
    if not before_chain:
        raise RuntimeError(f"{description} is missing")
    before_leaf = before_chain[-1][1]
    descriptor = _open_regular_file(path)
    try:
        opened = os.fstat(descriptor)
        if _is_reparse_stat(opened) or not stat.S_ISREG(opened.st_mode):
            raise RuntimeError(f"{description} is not a regular file")
        if _stat_identity(opened) != before_leaf:
            raise RuntimeError(f"{description} changed while it was being opened")
        if opened.st_size > max_bytes:
            raise RuntimeError(f"{description} is oversized")

        chunks: list[bytes] = []
        total = 0
        while total <= max_bytes:
            chunk = os.read(descriptor, min(65536, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > max_bytes:
                raise RuntimeError(f"{description} is oversized")

        closed_view = os.fstat(descriptor)
        if _stat_identity(closed_view) != _stat_identity(opened) or total != opened.st_size:
            raise RuntimeError(f"{description} changed while it was being read")
        after_chain = _path_identity_chain(path)
        if after_chain != before_chain:
            raise RuntimeError(f"{description} path identity changed while it was being read")
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _configured_tailscale_service_name() -> str:
    value = os.environ.get(TAILSCALE_SERVICE_NAME_ENV, DEFAULT_TAILSCALE_SERVICE_NAME)
    if not isinstance(value, str) or re.fullmatch(r"[A-Za-z0-9_.-]{1,80}", value) is None:
        raise RuntimeError("Tailscale service name is invalid")
    return value


def _windows_tailscale_service_pid(service_name: str) -> int | None:
    """Return the running SCM PID for the configured Tailscale service.

    The gateway cannot treat a TCP loopback address or an HTTP header as proof
    of ingress: every local process can forge both.  Windows SCM owns the
    service identity, so the request path is accepted only when the socket's
    owning PID is the currently running Tailscale service PID.
    """
    if not _is_windows_host():
        return None
    try:
        advapi32 = ctypes.WinDLL("Advapi32.dll", use_last_error=True)
        open_sc_manager = advapi32.OpenSCManagerW
        open_sc_manager.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p, wintypes.DWORD]
        open_sc_manager.restype = wintypes.HANDLE
        open_service = advapi32.OpenServiceW
        open_service.argtypes = [wintypes.HANDLE, ctypes.c_wchar_p, wintypes.DWORD]
        open_service.restype = wintypes.HANDLE
        query_status = advapi32.QueryServiceStatusEx
        query_status.argtypes = [
            wintypes.HANDLE,
            wintypes.DWORD,
            ctypes.c_void_p,
            wintypes.DWORD,
            ctypes.POINTER(wintypes.DWORD),
        ]
        query_status.restype = wintypes.BOOL
        close_service_handle = advapi32.CloseServiceHandle
        close_service_handle.argtypes = [wintypes.HANDLE]
        close_service_handle.restype = wintypes.BOOL

        manager = open_sc_manager(None, None, WINDOWS_SC_MANAGER_CONNECT)
        if not manager:
            return None
        try:
            service = open_service(manager, service_name, WINDOWS_SERVICE_QUERY_STATUS)
            if not service:
                return None
            try:
                status = _WindowsServiceStatusProcess()
                bytes_needed = wintypes.DWORD()
                if not query_status(
                    service,
                    WINDOWS_SC_STATUS_PROCESS_INFO,
                    ctypes.byref(status),
                    ctypes.sizeof(status),
                    ctypes.byref(bytes_needed),
                ):
                    return None
                if status.current_state != WINDOWS_SERVICE_RUNNING or status.process_id <= 0:
                    return None
                return int(status.process_id)
            finally:
                close_service_handle(service)
        finally:
            close_service_handle(manager)
    except (AttributeError, OSError, TypeError, ValueError):
        return None


def _windows_ipv4_from_dword(value: int) -> str | None:
    try:
        return socket.inet_ntoa(struct.pack("<I", int(value)))
    except (OSError, struct.error, TypeError, ValueError):
        return None


def _windows_tcp_peer_pid(scope: dict[str, Any]) -> int | None:
    """Resolve the owner PID of this exact loopback TCP connection.

    ``GetExtendedTcpTable`` is queried by the connection's local/remote
    address and ephemeral port.  A missing, ambiguous, non-loopback, or
    non-established row fails closed.  The public Tailscale Serve proxy is
    documented to target 127.0.0.1, so IPv4-only matching is intentional.
    """
    if not _is_windows_host():
        return None
    client = scope.get("client")
    server = scope.get("server")
    if (
        not isinstance(client, (tuple, list))
        or len(client) < 2
        or not isinstance(server, (tuple, list))
        or len(server) < 2
        or client[0] != "127.0.0.1"
        or server[0] != "127.0.0.1"
    ):
        return None
    try:
        remote_port = int(client[1])
        local_port = int(server[1])
    except (TypeError, ValueError):
        return None
    if not 1 <= remote_port <= 65535 or local_port != GATEWAY_LOOPBACK_PORT:
        return None

    try:
        iphlpapi = ctypes.WinDLL("iphlpapi.dll", use_last_error=True)
        get_extended_tcp_table = iphlpapi.GetExtendedTcpTable
        get_extended_tcp_table.argtypes = [
            ctypes.c_void_p,
            ctypes.POINTER(wintypes.DWORD),
            wintypes.BOOL,
            wintypes.ULONG,
            wintypes.ULONG,
            wintypes.ULONG,
        ]
        get_extended_tcp_table.restype = wintypes.DWORD

        size = wintypes.DWORD(0)
        result = get_extended_tcp_table(
            None,
            ctypes.byref(size),
            False,
            WINDOWS_AF_INET,
            WINDOWS_TCP_TABLE_OWNER_PID_ALL,
            0,
        )
        if result not in (0, WINDOWS_ERROR_INSUFFICIENT_BUFFER) or size.value < ctypes.sizeof(wintypes.DWORD):
            return None
        table = ctypes.create_string_buffer(size.value)
        result = get_extended_tcp_table(
            ctypes.cast(table, ctypes.c_void_p),
            ctypes.byref(size),
            False,
            WINDOWS_AF_INET,
            WINDOWS_TCP_TABLE_OWNER_PID_ALL,
            0,
        )
        if result != 0:
            return None

        count = ctypes.cast(table, ctypes.POINTER(wintypes.DWORD)).contents.value
        row_size = ctypes.sizeof(_WindowsTcpRowOwnerPid)
        available_rows = (size.value - ctypes.sizeof(wintypes.DWORD)) // row_size
        if count > available_rows:
            return None
        # The accepted gateway socket is the forward tuple (8421 -> client
        # ephemeral port). The process that initiated the local connection is
        # represented by the reverse tuple (client ephemeral port -> 8421).
        # Only the reverse owner can prove that Tailscale opened this hop.
        peer_matches: set[int] = set()
        gateway_matches: set[int] = set()
        offset = ctypes.sizeof(wintypes.DWORD)
        for _ in range(count):
            row = _WindowsTcpRowOwnerPid.from_buffer_copy(table, offset)
            offset += row_size
            if row.state != WINDOWS_TCP_STATE_ESTABLISHED:
                continue
            local_address = _windows_ipv4_from_dword(row.local_address)
            remote_address = _windows_ipv4_from_dword(row.remote_address)
            local_row_port = int.from_bytes(bytes(row.local_port), "big")
            remote_row_port = int.from_bytes(bytes(row.remote_port), "big")
            if (
                local_address == "127.0.0.1"
                and remote_address == "127.0.0.1"
                and row.owning_pid > 0
            ):
                if local_row_port == remote_port and remote_row_port == local_port:
                    peer_matches.add(int(row.owning_pid))
                elif local_row_port == local_port and remote_row_port == remote_port:
                    gateway_matches.add(int(row.owning_pid))
        # Require both endpoint records. A missing reverse row is ambiguous:
        # accepting the gateway's own PID would destroy the peer boundary.
        if len(peer_matches) != 1 or len(gateway_matches) != 1:
            return None
        return next(iter(peer_matches))
    except (AttributeError, OSError, struct.error, TypeError, ValueError):
        return None


def _is_tailscale_service_peer(scope: dict[str, Any], service_name: str) -> bool:
    """Prove that a request arrived through the Tailscale service transport."""
    if not _is_windows_host():
        return False
    try:
        peer_pid = _windows_tcp_peer_pid(scope)
        service_pid = _windows_tailscale_service_pid(service_name)
    except (OSError, TypeError, ValueError):
        return False
    return peer_pid is not None and service_pid is not None and peer_pid == service_pid


def _safe_path(value: Any, *, file: bool, directory: bool) -> Path:
    if not isinstance(value, str) or not value or not Path(value).is_absolute() or "\x00" in value:
        raise RuntimeError("invalid deployment path")
    path = Path(value)
    for component in (path, *path.parents):
        try:
            observed = os.lstat(component)
        except FileNotFoundError:
            continue
        except OSError as exc:
            raise RuntimeError("deployment path is unreadable") from exc
        if _is_reparse_stat(observed) and (os.name == "nt" or component == path):
            raise RuntimeError("reparse deployment path")
    if file and not path.is_file():
        raise RuntimeError("required deployment file is missing")
    if directory and not path.is_dir():
        raise RuntimeError("required deployment directory is missing")
    return path


def _read_edge_token(path: Path) -> str:
    """Read and validate the operator-managed token without exposing it.

    The file is never copied, serialized, placed in a command argument, or
    included in a diagnostic.  The returned string exists only in this
    gateway process because ``main.py`` consumes the environment contract.
    """
    try:
        if not path.is_file():
            raise EdgeTokenConfigurationError(
                "LIFEOS_TAILSCALE_EDGE_TOKEN source file is missing; create the "
                "operator-managed token file before starting the gateway."
            )
        raw = _read_bounded_regular_file(path, max_bytes=256, description="LIFEOS_TAILSCALE_EDGE_TOKEN source")
    except EdgeTokenConfigurationError:
        raise
    except OSError as exc:
        raise EdgeTokenConfigurationError(
            "LIFEOS_TAILSCALE_EDGE_TOKEN source is unreadable; the token value "
            "was not displayed."
        ) from exc
    if not 32 <= len(raw) <= 256 or any(byte < 0x21 or byte > 0x7E for byte in raw):
        raise EdgeTokenConfigurationError(
            "LIFEOS_TAILSCALE_EDGE_TOKEN source is invalid; expected 32-256 "
            "printable ASCII bytes with no newline; the token value was not displayed."
        )
    try:
        return raw.decode("ascii")
    except UnicodeDecodeError as exc:
        # The byte check above makes this defensive, but keep the failure
        # diagnostic safe if the validation contract changes later.
        raise EdgeTokenConfigurationError(
            "LIFEOS_TAILSCALE_EDGE_TOKEN source is invalid; expected printable "
            "ASCII bytes; the token value was not displayed."
        ) from exc


def _read_tailscale_snapshot(snapshot_path: str | None = None) -> tuple[dict[str, Any], str, str]:
    """Read the SYSTEM-produced Tailscale state without crossing LocalAPI ACLs.

    The gateway service runs as a virtual service account and intentionally
    cannot query Tailscale's user-scoped LocalAPI.  A SYSTEM scheduled task
    writes this bounded, non-secret snapshot into the ACL-protected host
    directory.  Freshness and exact schema checks keep it from becoming a
    long-lived identity assertion.

    The whole file comes from that one trusted writer, so nothing in it is
    independently corroborated here: the ``dnsName``/``identity`` cross-check
    below is a consistency check on a single payload, not a second source.  It
    catches a malformed or truncated write, which is a real failure mode; it
    does not make the identity half trustworthy on its own.  Only the ACL on
    the state directory keeps the gateway out of the writer role.
    """
    raw_path = snapshot_path or os.environ.get(TAILSCALE_SNAPSHOT_PATH_ENV)
    if not isinstance(raw_path, str) or not raw_path:
        raise RuntimeError("tailscale snapshot path is not configured")
    path = _safe_path(raw_path, file=True, directory=False)
    try:
        raw = _read_bounded_regular_file(
            path, max_bytes=256 * 1024, description="tailscale snapshot"
        )
        def unique_object(pairs):
            result = {}
            for key, item in pairs:
                if key in result:
                    raise ValueError("duplicate field")
                result[key] = item
            return result
        value = json.loads(raw, object_pairs_hook=unique_object,
                           parse_constant=lambda _: (_ for _ in ()).throw(ValueError("invalid number")))
    except RuntimeError:
        raise
    except Exception as exc:
        raise RuntimeError("tailscale snapshot is unreadable") from exc
    expected_fields = {"schemaVersion", "observedAt", "dnsName", "login", "serve", "identity"}
    if not isinstance(value, dict) or set(value) != expected_fields or type(value.get("schemaVersion")) is not int or value.get("schemaVersion") != 1:
        raise RuntimeError("tailscale snapshot schema is invalid")
    observed_at = value.get("observedAt")
    if not isinstance(observed_at, str):
        raise RuntimeError("tailscale snapshot timestamp is invalid")
    try:
        parsed_at = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
        if parsed_at.tzinfo is None:
            raise ValueError("timestamp is missing timezone")
        parsed_at = parsed_at.astimezone(timezone.utc)
    except (TypeError, ValueError, OverflowError) as exc:
        raise RuntimeError("tailscale snapshot timestamp is invalid") from exc
    age = (datetime.now(timezone.utc) - parsed_at).total_seconds()
    if age < -TAILSCALE_SNAPSHOT_MAX_FUTURE_SECONDS or age > TAILSCALE_SNAPSHOT_MAX_AGE_SECONDS:
        raise RuntimeError("tailscale snapshot is stale")
    serve = value.get("serve")
    identity = value.get("identity")
    if not isinstance(serve, dict) or not isinstance(identity, dict):
        raise RuntimeError("tailscale snapshot payload is invalid")
    expected_dns_name = value.get("dnsName")
    if not isinstance(expected_dns_name, str) or expected_dns_name.casefold() != _tailscale_dns_name(identity).casefold():
        raise RuntimeError("tailscale snapshot identity does not match its DNS name")
    login = value.get("login")
    if not isinstance(login, str) or not re.fullmatch(r"[A-Za-z0-9._+\-]+@[A-Za-z0-9.-]+", login) or login.count("@") != 1:
        raise RuntimeError("tailscale snapshot login is invalid")
    return serve, expected_dns_name.rstrip("."), login


def _read_config(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(
            _read_bounded_regular_file(path, max_bytes=64 * 1024, description="gateway config")
            .decode("utf-8")
        )
    except Exception as exc:
        raise RuntimeError("gateway config invalid") from exc
    if not isinstance(value, dict) or set(value) != EXPECTED_FIELDS:
        raise RuntimeError("gateway config fields invalid")
    if value["bindHost"] != "127.0.0.1" or type(value["port"]) is not int or value["port"] != 8421 or type(value["tailscaleServePort"]) is not int or value["tailscaleServePort"] != 8420 or type(value["funnel"]) is not bool or value["funnel"] is not False:
        raise RuntimeError("gateway config is not loopback-only")
    if value["apiBaseUrl"] != "http://127.0.0.1:8787":
        raise RuntimeError("gateway API is not loopback-only")
    value["dataDirectory"] = str(_safe_path(value["dataDirectory"], file=False, directory=True))
    value["calendarPath"] = str(_safe_path(value["calendarPath"], file=False, directory=False))
    value["documentsPath"] = str(_safe_path(value["documentsPath"], file=False, directory=True))
    value["claudeSecretPath"] = str(_safe_path(value["claudeSecretPath"], file=True, directory=False))
    value["tailscaleEdgeTokenPath"] = str(_safe_path(value["tailscaleEdgeTokenPath"], file=False, directory=False))
    if Path(value["tailscaleEdgeTokenPath"]).name.casefold() != "tailscale-edge.token":
        raise EdgeTokenConfigurationError(
            "LIFEOS_TAILSCALE_EDGE_TOKEN source path is not the canonical "
            "operator-managed token file."
        )
    secret_path = Path(value["claudeSecretPath"])
    try:
        secret = _read_bounded_regular_file(
            secret_path, max_bytes=4096, description="gateway secret"
        ).decode("ascii")
    except UnicodeDecodeError as exc:
        raise RuntimeError("gateway secret invalid") from exc
    if not 32 <= len(secret) <= 256 or not re.fullmatch(r"[\x21-\x7e]+", secret):
        raise RuntimeError("gateway secret invalid")
    return value


def _truthy_private_flags(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"Funnel", "AllowFunnel"} and child is True:
                found.append(key)
            found.extend(_truthy_private_flags(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(_truthy_private_flags(child))
    return found


def _is_empty_serve_value(value: Any) -> bool:
    if value is None or value is False:
        return True
    if isinstance(value, (dict, list)):
        return not value
    if isinstance(value, str):
        return not value
    return False


def _serve_is_empty(status: dict[str, Any]) -> bool:
    """Return true only for a structurally empty ServeConfig.

    ServeConfig has more route-bearing forms than HTTP Proxy: TCP, Services,
    Tun/foreground configs, and non-proxy HTTP handlers. Unknown non-empty
    fields are rejected so a future schema addition cannot be mistaken for an
    empty configuration and erased by ``serve reset``.
    """
    if not isinstance(status, dict):
        return False
    for key, value in status.items():
        if key not in SERVE_CONFIG_KEYS:
            if not _is_empty_serve_value(value):
                return False
            continue
        if not _is_empty_serve_value(value):
            return False
    return True


def _serve_has_only_empty_non_web_fields(status: dict[str, Any]) -> bool:
    for key, value in status.items():
        if key not in SERVE_CONFIG_KEYS:
            if not _is_empty_serve_value(value):
                return False
        elif key != "Web" and not _is_empty_serve_value(value):
            return False
    return True


def _tailscale_dns_name(status: dict[str, Any]) -> str:
    self_node = status.get("Self")
    dns_name = self_node.get("DNSName") if isinstance(self_node, dict) else None
    if not isinstance(dns_name, str):
        raise RuntimeError("tailscale DNS name unavailable")
    dns_name = dns_name.rstrip(".")
    if not dns_name or len(dns_name) > 253 or re.search(r"[\x00-\x20\x7f/\\:@?#]", dns_name):
        raise RuntimeError("tailscale DNS name invalid")
    return dns_name


def _endpoint_port_range(endpoint: str) -> tuple[int, int] | None:
    """Return a Serve endpoint's port/range, or None when it is not inspectable."""
    if not isinstance(endpoint, str) or not endpoint or re.search(r"[\x00-\x20\x7f]", endpoint):
        return None
    match = re.search(
        r"(?i)(?:^|:)(?P<start>[0-9]{1,5})(?:-(?P<end>[0-9]{1,5}))?(?:$|[/])",
        endpoint,
    )
    if match is None:
        return None
    start = int(match.group("start"))
    end = int(match.group("end") or match.group("start"))
    if start < 1 or end > 65535 or end < start:
        return None
    return start, end


def _web_endpoint_is_exact(endpoint: str, config: Any, expected_dns_name: str | None) -> bool:
    try:
        parsed_endpoint = urlsplit(endpoint if "://" in endpoint else f"//{endpoint}")
        if "://" in endpoint and parsed_endpoint.scheme != "https":
            return False
        if parsed_endpoint.username or parsed_endpoint.password or parsed_endpoint.query or parsed_endpoint.fragment:
            return False
        if parsed_endpoint.path not in ("", "/") or parsed_endpoint.port != 8420 or not parsed_endpoint.hostname:
            return False
    except ValueError:
        return False
    if expected_dns_name is not None and parsed_endpoint.hostname.rstrip(".").lower() != expected_dns_name.rstrip(".").lower():
        return False
    if not isinstance(config, dict) or set(config) != {"Handlers"}:
        return False
    handlers = config["Handlers"]
    if not isinstance(handlers, dict) or set(handlers) != {"/"}:
        return False
    handler = handlers["/"]
    if not isinstance(handler, dict) or set(handler) != {"Proxy", "AcceptAppCaps"}:
        return False
    return handler["Proxy"] == PRIVATE_PROXY and _accepts_trusted_edge_capability(handler["AcceptAppCaps"])


def _accepts_trusted_edge_capability(value: Any) -> bool:
    if isinstance(value, str):
        values = [value]
    elif isinstance(value, list):
        values = value
    else:
        return False
    return len(values) == 1 and values[0] == TRUSTED_EDGE_APP_CAPABILITY


def _decode_app_capabilities_header(value: bytes | str) -> Any:
    if isinstance(value, bytes):
        raw = value.decode("ascii")
    elif isinstance(value, str):
        raw = value
    else:
        return None
    if len(raw) > 8192:
        return None
    try:
        # Tailscale may RFC2047-Q encode a header containing non-ASCII grant
        # parameters. Decode that envelope before parsing the JSON object.
        parts = decode_header(raw)
        raw = "".join(
            part.decode(charset or "ascii") if isinstance(part, bytes) else part
            for part, charset in parts
        )
        return json.loads(raw)
    except (UnicodeDecodeError, LookupError, TypeError, ValueError, json.JSONDecodeError):
        return None


def _has_trusted_edge_app_capability(headers: list[tuple[bytes, bytes]]) -> bool:
    values = [value for name, value in headers if name.lower() == TAILSCALE_APP_CAPABILITIES_HEADER]
    if len(values) != 1:
        return False
    capabilities = _decode_app_capabilities_header(values[0])
    if not isinstance(capabilities, dict):
        return False
    grants = capabilities.get(TRUSTED_EDGE_APP_CAPABILITY)
    return isinstance(grants, list) and bool(grants) and all(isinstance(grant, dict) for grant in grants)


class TrustedEdgeHeaderAdapter:
    """Translate a Serve proof only across the verified Windows edge hop.

    Tailscale's capability header is meaningful at the Serve boundary, but it
    is ordinary HTTP after Serve connects to loopback.  The adapter therefore
    requires both the capability and the Windows TCP-owner proof before it can
    mint the private header consumed by ``main.py``.
    """

    def __init__(
        self,
        app: Any,
        token: str,
        *,
        peer_verifier: Any | None = None,
        tailscale_service_name: str = DEFAULT_TAILSCALE_SERVICE_NAME,
        expected_identity: tuple[str, str] | None = None,
    ) -> None:
        self._snapshot_path = os.environ.get(TAILSCALE_SNAPSHOT_PATH_ENV)
        if expected_identity is None:
            _, dns, login = _read_tailscale_snapshot(self._snapshot_path)
            expected_identity = (dns, login)
        self._expected_identity = expected_identity
        self._reader = _BoundedThreadProbe(
            self._run_lease_probe,
            thread_name_prefix="edge-lease",
        )
        self._app = app
        self._token_header = token.encode("ascii")
        self._peer_verifier = peer_verifier or (
            lambda scope: _is_tailscale_service_peer(scope, tailscale_service_name)
        )

    def _snapshot_valid(self) -> bool:
        try:
            serve, dns, login = _read_tailscale_snapshot(self._snapshot_path)
            return ((dns, login) == self._expected_identity
                    and _serve_is_exact(serve, expected_dns_name=dns))
        except Exception:
            return False

    def _run_lease_probe(self, scope: dict[str, Any] | None) -> bool:
        if not self._snapshot_valid():
            return False
        try:
            # This is deliberately part of the bounded blocking probe.  On
            # Windows it re-queries both the TCP owner and the current SCM
            # service PID, so a restarted or replaced Tailscale process
            # revokes an established stream.
            return bool(self._peer_verifier(scope))
        except Exception:
            return False

    async def _lease_valid(self, scope: dict[str, Any] | None = None) -> bool:
        try:
            return await _bounded_probe_result(
                self._reader,
                scope,
                TAILSCALE_RUNTIME_READ_TIMEOUT_SECONDS,
            )
        except Exception:
            return False

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> Any:
        if scope.get("type") not in {"http", "websocket"}:
            return await self._app(scope, receive, send)
        started = False
        finished = False

        async def deny():
            nonlocal finished
            if finished:
                return
            finished = True
            if scope["type"] == "websocket":
                await send({"type": "websocket.close", "code": 4403})
            elif not started:
                await send({"type": "http.response.start", "status": 503,
                            "headers": [(b"cache-control", b"no-store")]})
                await send({"type": "http.response.body", "body": b"Edge unavailable"})
            else:
                # Never present a revoked partial HTTP stream as complete.
                raise RuntimeError("trusted edge lease expired")

        # _lease_valid performs the exact snapshot and bounded transport proof.
        # Its successful result is the proof used below; never invoke the
        # potentially blocking verifier on the event loop a second time.
        transport_is_tailscale = await self._lease_valid(scope)
        if not transport_is_tailscale:
            return await deny()
        original_headers = scope.get("headers", [])
        headers: list[tuple[bytes, bytes]] = []
        for name, value in original_headers:
            lowered = name.lower()
            if lowered in {TRUSTED_EDGE_HEADER, TAILSCALE_APP_CAPABILITIES_HEADER}:
                continue
            headers.append((name, value))
        if transport_is_tailscale and _has_trusted_edge_app_capability(original_headers):
            headers.append((TRUSTED_EDGE_HEADER, self._token_header))
        forwarded_scope = dict(scope)
        forwarded_scope["headers"] = headers
        revoked = False

        class LeaseExpired(Exception):
            pass

        async def check():
            nonlocal revoked
            if revoked or not await self._lease_valid(scope):
                revoked = True
                raise LeaseExpired()

        async def guarded_receive():
            await check()
            message = await receive()
            await check()
            return message

        async def guarded_send(message):
            nonlocal started, finished
            await check()
            await send(message)
            if message["type"] in {"http.response.start", "websocket.accept"}:
                started = True
            if (message["type"] == "websocket.close" or
                message["type"] == "http.response.body" and not message.get("more_body", False)):
                finished = True

        async def watch():
            while True:
                await asyncio.sleep(TAILSCALE_RUNTIME_LEASE_SECONDS)
                await check()

        application = asyncio.create_task(self._app(forwarded_scope, guarded_receive, guarded_send))
        watchdog = asyncio.create_task(watch())
        try:
            done, _ = await asyncio.wait({application, watchdog}, return_when=asyncio.FIRST_COMPLETED)
            if watchdog in done:
                await watchdog
            return await application
        except LeaseExpired:
            application.cancel()
            with suppress(asyncio.CancelledError, LeaseExpired):
                await application
            return await deny()
        finally:
            for task in (application, watchdog):
                task.cancel()
            await asyncio.gather(application, watchdog, return_exceptions=True)


def _services_use_port(value: Any, port: int) -> bool | None:
    """Inspect service endpoint keys; None means the shape is ambiguous."""
    if value is None or value is False or value == "":
        return False
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() == "endpoints":
                if not isinstance(child, dict):
                    return None
                for endpoint in child:
                    port_range = _endpoint_port_range(str(endpoint))
                    if port_range is None:
                        return None
                    if port_range[0] <= port <= port_range[1]:
                        return True
                continue
            nested = _services_use_port(child, port)
            if nested is None or nested:
                return nested
        return False
    if isinstance(value, list):
        for child in value:
            nested = _services_use_port(child, port)
            if nested is None or nested:
                return nested
        return False
    # Non-endpoint service metadata is unrelated to the port decision and is
    # preserved by the additive command. An actual ``endpoints`` field above
    # remains strict so malformed endpoint maps fail closed.
    return False


def _is_exact_tcp_https_mirror(value: Any) -> bool:
    """Return whether a TCP entry is the one supported HTTPS mirror."""
    return (
        isinstance(value, dict)
        and set(value) == {"HTTPS"}
        and type(value["HTTPS"]) is bool
        and value["HTTPS"] is True
    )


def _serve_is_exact(status: dict[str, Any], expected_dns_name: str | None = None) -> bool:
    if not isinstance(status, dict):
        return False
    if _truthy_private_flags(status):
        return False
    for key, value in status.items():
        if key not in SERVE_CONFIG_KEYS and not _is_empty_serve_value(value):
            return False
    if not _is_empty_serve_value(status.get("AllowFunnel")) or not _is_empty_serve_value(status.get("Foreground")):
        return False
    tcp = status.get("TCP")
    if not _is_empty_serve_value(tcp):
        if not isinstance(tcp, dict):
            return False
        for endpoint, config in tcp.items():
            port_range = _endpoint_port_range(str(endpoint))
            if port_range is None:
                return False
            if port_range[0] <= 8420 <= port_range[1] and (
                not isinstance(endpoint, str) or endpoint != "8420" or not _is_exact_tcp_https_mirror(config)
            ):
                return False
    services = status.get("Services")
    if not _is_empty_serve_value(services):
        if not isinstance(services, (dict, list)):
            return False
        service_collision = _services_use_port(services, 8420)
        if service_collision is None or service_collision:
            return False
    web = status.get("Web")
    if not isinstance(web, dict):
        return False
    targets: list[tuple[str, Any]] = []
    for endpoint, config in web.items():
        if not isinstance(endpoint, str):
            return False
        port_range = _endpoint_port_range(endpoint)
        if port_range is None:
            return False
        if port_range[0] <= 8420 <= port_range[1]:
            targets.append((endpoint, config))
    if len(targets) != 1:
        return False
    return _web_endpoint_is_exact(targets[0][0], targets[0][1], expected_dns_name)


def run(config_path: Path, entry_point: Path, tailscale: Path) -> int:
    config = _read_config(config_path)
    edge_token = _read_edge_token(Path(config["tailscaleEdgeTokenPath"]))
    tailscale_service_name = _configured_tailscale_service_name()
    # The installer still binds the Tailscale executable into the service
    # command line.  This validates that argument only -- absolute, no reparse
    # point, present on disk -- so a malformed or removed path fails at startup
    # instead of being silently ignored.  It is not evidence about ingress: the
    # per-request proof binds to the *running* Tailscale SCM service through
    # QueryServiceStatusEx and GetExtendedTcpTable, which this file says
    # nothing about.
    _safe_path(str(tailscale), file=True, directory=False)
    # The service account cannot access Tailscale's LocalAPI directly.  The
    # SYSTEM snapshot task supplies the Serve payload and node identity while
    # this process retains the exact route, DNS, login, and freshness checks.
    serve_status, expected_dns_name, login = _read_tailscale_snapshot()
    if not _serve_is_exact(serve_status, expected_dns_name=expected_dns_name):
        raise RuntimeError("private Serve mapping invalid")
    data_dir = Path(config["dataDirectory"])
    os.environ.update(
        {
            "LIFEOS_DATA_DIR": str(data_dir),
            "LIFEOS_CALENDAR_PATH": config["calendarPath"],
            "LIFEOS_DOCUMENTS_DIR": config["documentsPath"],
            "CLAUDE_INGEST_SECRET_FILE": config["claudeSecretPath"],
            "LIFEOS_CLAUDE_SECRET_FILE": config["claudeSecretPath"],
            "LIFEOS_TAILSCALE_ALLOWED_LOGIN": login,
            # This is an in-process gateway contract only. It is never put in
            # a config file, manifest, command argument, log, or Serve header.
            "LIFEOS_TAILSCALE_EDGE_TOKEN": edge_token,
            "LIFEOS_TAILSCALE_SERVICE_NAME": tailscale_service_name,
            "LIFEOS_GATEWAY_CONFIG_PATH": str(config_path),
            "PORT": "8421",
        }
    )
    sys.path.insert(0, str(entry_point.parent))
    module = importlib.import_module(entry_point.stem)
    app = getattr(module, "app", None)
    if app is None:
        raise RuntimeError("gateway app missing")
    # The public capability is accepted only after the Windows transport
    # verifier attributes this exact loopback connection to the Tailscale SCM
    # service. The adapter strips all caller-supplied proof headers and adds
    # the private token only for that verified edge hop.
    app = TrustedEdgeHeaderAdapter(
        app,
        edge_token,
        tailscale_service_name=tailscale_service_name,
        expected_identity=(expected_dns_name, login),
    )
    # `/health` remains the liveness contract served by the reviewed gateway;
    # this launcher-owned local probe is a separate readiness contract. It is
    # reachable only after all launcher preflight (including the fresh,
    # authenticated Tailscale snapshot) has completed.
    app = LocalReadinessAdapter(
        app,
        lambda: _current_gateway_dependencies_ready(
            str(config["apiBaseUrl"]),
            os.environ.get(TAILSCALE_SNAPSHOT_PATH_ENV),
            tailscale_service_name,
        ),
    )
    # Reviewed gateway modules may expose these constants.  Set them after
    # import as a defence-in-depth bridge while retaining the env contract.
    for name in ("DATA_DIR", "LIFEOS_DATA_DIR"):
        if hasattr(module, name):
            setattr(module, name, data_dir)
    for name in ("CLAUDE_SECRET_PATH", "CLAUDE_INGEST_SECRET_FILE", "LIFEOS_CLAUDE_SECRET_FILE", "CLAUDE_INGEST_SECRET_FILENAME"):
        if hasattr(module, name):
            setattr(module, name, Path(config["claudeSecretPath"]))
    for name in ("_ingest_secret_path", "ingest_secret_path", "_claude_secret_path", "claude_secret_path"):
        resolver = getattr(module, name, None)
        if callable(resolver):
            setattr(module, name, lambda _resolver=None, path=Path(config["claudeSecretPath"]): path)
    for name in ("CALENDAR_PATH", "LIFEOS_CALENDAR_PATH"):
        if hasattr(module, name):
            setattr(module, name, Path(config["calendarPath"]))
            if Path(getattr(module, name)) != Path(config["calendarPath"]):
                raise RuntimeError("calendar path contract mismatch")
    for name in ("DOCUMENTS_DIR", "LIFEOS_DOCUMENTS_DIR"):
        if hasattr(module, name):
            setattr(module, name, Path(config["documentsPath"]))
            if Path(getattr(module, name)) != Path(config["documentsPath"]):
                raise RuntimeError("documents path contract mismatch")
    uvicorn = importlib.import_module("uvicorn")
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=8421, log_level="warning", proxy_headers=False))

    def stop_on_stdin_eof() -> None:
        try:
            sys.stdin.buffer.read()
        except Exception:
            pass
        server.should_exit = True

    threading.Thread(target=stop_on_stdin_eof, name="lifeos-stdin-stop", daemon=True).start()
    server.run()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config", required=True)
    parser.add_argument("--entry-point", required=True)
    parser.add_argument("--tailscale", required=True)
    args = parser.parse_args()
    try:
        return run(Path(args.config), Path(args.entry_point), Path(args.tailscale))
    except EdgeTokenConfigurationError as exc:
        # This diagnostic is deliberately value-free; it is safe for the
        # service host's stderr capture and gives the operator a repair path.
        sys.stderr.write(f"{exc}\n")
        return 1
    except Exception:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
