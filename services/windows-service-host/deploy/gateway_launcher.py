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
import ctypes
from email.header import decode_header
import importlib
import json
import os
from pathlib import Path
import re
import socket
import struct
import subprocess
import sys
import threading
from typing import Any
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


def _is_windows_host() -> bool:
    return os.name == "nt"


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
        if component.is_symlink():
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
        raw = path.read_bytes()
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


def _read_config(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError("gateway config invalid") from exc
    if not isinstance(value, dict) or set(value) != EXPECTED_FIELDS:
        raise RuntimeError("gateway config fields invalid")
    if value["bindHost"] != "127.0.0.1" or type(value["port"]) is not int or value["port"] != 8421 or type(value["tailscaleServePort"]) is not int or value["tailscaleServePort"] != 8420 or type(value["funnel"]) is not bool or value["funnel"] is not False:
        raise RuntimeError("gateway config is not loopback-only")
    if value["apiBaseUrl"] != "http://127.0.0.1:8787":
        raise RuntimeError("gateway API is not loopback-only")
    value["dataDirectory"] = str(_safe_path(value["dataDirectory"], directory=True))
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
    if secret_path.stat().st_size > 4096:
        raise RuntimeError("gateway secret is oversized")
    secret = secret_path.read_bytes().decode("ascii")
    if not 32 <= len(secret) <= 256 or not re.fullmatch(r"[\x21-\x7e]+", secret):
        raise RuntimeError("gateway secret invalid")
    return value


def _run_tailscale(executable: Path, *args: str) -> dict[str, Any]:
    try:
        result = subprocess.run([str(executable), *args], check=True, capture_output=True, text=True, shell=False, timeout=8)
        if len(result.stdout) > 65536:
            raise RuntimeError("tailscale response oversized")
        parsed = json.loads(result.stdout)
    except Exception as exc:
        raise RuntimeError("tailscale query failed") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("tailscale response invalid")
    return parsed


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
    ) -> None:
        self._app = app
        self._token_header = token.encode("ascii")
        self._peer_verifier = peer_verifier or (
            lambda scope: _is_tailscale_service_peer(scope, tailscale_service_name)
        )

    async def __call__(self, scope: dict[str, Any], receive: Any, send: Any) -> Any:
        if scope.get("type") not in {"http", "websocket"}:
            return await self._app(scope, receive, send)
        original_headers = scope.get("headers", [])
        headers: list[tuple[bytes, bytes]] = []
        for name, value in original_headers:
            lowered = name.lower()
            if lowered in {TRUSTED_EDGE_HEADER, TAILSCALE_APP_CAPABILITIES_HEADER}:
                continue
            headers.append((name, value))
        try:
            transport_is_tailscale = bool(self._peer_verifier(scope))
        except Exception:
            # A missing SCM/TCP query is an authentication failure, never a
            # reason to pass through a caller-supplied identity assertion.
            transport_is_tailscale = False
        if transport_is_tailscale and _has_trusted_edge_app_capability(original_headers):
            headers.append((TRUSTED_EDGE_HEADER, self._token_header))
        forwarded_scope = dict(scope)
        forwarded_scope["headers"] = headers
        return await self._app(forwarded_scope, receive, send)


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
        for endpoint in tcp:
            port_range = _endpoint_port_range(str(endpoint))
            if port_range is None or port_range[0] <= 8420 <= port_range[1]:
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


def _tailscale_login(executable: Path, status: dict[str, Any]) -> str:
    self_node = status.get("Self")
    login = None
    if isinstance(self_node, dict):
        users = status.get("User")
        user_id = self_node.get("UserID")
        profile = users.get(str(user_id)) if isinstance(users, dict) and user_id is not None else None
        if isinstance(profile, dict):
            login = profile.get("LoginName")
        if not isinstance(login, str) or not login:
            profile = self_node.get("UserProfile")
            if isinstance(profile, dict):
                login = profile.get("LoginName")
        addresses = self_node.get("TailscaleIPs")
        if not isinstance(login, str) or not login:
            if isinstance(addresses, list) and addresses and isinstance(addresses[0], str):
                whois = _run_tailscale(executable, "whois", "--json", addresses[0])
                profile = whois.get("UserProfile")
                if isinstance(profile, dict):
                    login = profile.get("LoginName")
    if not isinstance(login, str) or not login or len(login) > 256 or re.search(r"[\x00-\x1f\x7f]", login):
        raise RuntimeError("tailscale login unavailable")
    return login


def run(config_path: Path, entry_point: Path, tailscale: Path) -> int:
    config = _read_config(config_path)
    edge_token = _read_edge_token(Path(config["tailscaleEdgeTokenPath"]))
    tailscale_service_name = _configured_tailscale_service_name()
    # Serve configuration and node identity are different Tailscale JSON
    # payloads.  Do not pass ServeConfig to the identity resolver: doing so
    # makes a valid mapping fail closed before the gateway can start.
    serve_status = _run_tailscale(tailscale, "serve", "status", "--json")
    identity_status = _run_tailscale(tailscale, "status", "--json")
    expected_dns_name = _tailscale_dns_name(identity_status)
    if not _serve_is_exact(serve_status, expected_dns_name=expected_dns_name):
        raise RuntimeError("private Serve mapping invalid")
    login = _tailscale_login(tailscale, identity_status)
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
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=8421, log_level="warning"))

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
