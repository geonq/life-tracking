"""Loopback-only LifeOS relay seam.

The relay is intentionally a transport boundary, not a trust authority.  A
caller must inject a handler that verifies the signed LifeOS request and
returns a signed response.  No unsigned header, display name, query value, or
local process identity is accepted as authentication here.
"""

from __future__ import annotations

import argparse
import json
import socket
import threading
from dataclasses import dataclass
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Callable, Mapping, Sequence
from urllib.parse import urlsplit


MAX_REQUEST_BYTES = 2 * 1024 * 1024
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
MAX_CONCURRENT_REQUESTS = 4
READ_TIMEOUT_SECONDS = 5.0
SAFE_RESPONSE_CONTENT_TYPES = frozenset({"application/json", "application/json; charset=utf-8"})
ALLOWED_PATHS = frozenset(
    {
        "/replication/v1/challenge",
        "/replication/v1/hello",
        "/replication/v1/exchange",
        "/replication/v1/ack",
        "/replication/v1/blob",
        "/replication/v1/blob/read",
        "/replication/v1/data/manage",
        "/replication/v1/observation",
        "/replication/v1/observation/read",
        "/replication/v1/health",
    }
)
ADMIN_PATHS = frozenset({"/replication/v1/data/manage"})
SENSITIVE_HEADERS = frozenset(
    {
        "host",
        "content-length",
        "content-type",
        "x-lifeos-signature",
        "x-lifeos-session",
        "x-lifeos-request-id",
        "x-lifeos-nonce",
        "x-lifeos-epoch",
    }
)


@dataclass(frozen=True, slots=True)
class RelayConfig:
    host: str = "127.0.0.1"
    port: int = 0
    max_request_bytes: int = MAX_REQUEST_BYTES
    max_response_bytes: int = MAX_RESPONSE_BYTES
    max_concurrent_requests: int = MAX_CONCURRENT_REQUESTS
    read_timeout_seconds: float = READ_TIMEOUT_SECONDS
    allow_non_loopback: bool = False


@dataclass(frozen=True, slots=True)
class RelayResponse:
    status: int
    body: bytes
    content_type: str = "application/json"


RouteHandler = Callable[[str, str, Mapping[str, str], bytes], RelayResponse]


def _json(status: int, code: str) -> RelayResponse:
    return RelayResponse(status, json.dumps({"error": code}, separators=(",", ":")).encode("utf-8"))


def _single_headers(headers: Sequence[tuple[str, str]]) -> dict[str, str] | None:
    values: dict[str, list[str]] = {}
    for name, value in headers:
        lowered = name.casefold()
        values.setdefault(lowered, []).append(value)
    for name in SENSITIVE_HEADERS:
        if len(values.get(name, [])) != (1 if name in values else 0):
            return None
    return {name: entries[0] for name, entries in values.items()}


def _valid_content_type(value: str | None) -> bool:
    if value is None:
        return False
    return value.casefold() in {"application/json", "application/json; charset=utf-8"}


def _valid_response_content_type(value: object) -> bool:
    return isinstance(value, str) and value.casefold() in SAFE_RESPONSE_CONTENT_TYPES


def _is_admin_blob(path: str, body: bytes) -> bool:
    if path in ADMIN_PATHS:
        return True
    if path not in {"/replication/v1/blob", "/replication/v1/blob/read"}:
        return False
    try:
        decoded = json.loads(body)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return False
    tag = decoded.get("tag") if isinstance(decoded, dict) else None
    return isinstance(tag, str) and tag in {"admin.blob.put", "admin.blob.read"}


class RelayApplication:
    """Bounded dispatch layer with an explicit authenticated handler seam."""

    def __init__(self, config: RelayConfig | None = None, handler: RouteHandler | None = None):
        self.config = config or RelayConfig()
        if self.config.max_request_bytes < 1 or self.config.max_request_bytes > MAX_REQUEST_BYTES:
            raise ValueError("invalid request cap")
        if self.config.max_response_bytes < 1 or self.config.max_response_bytes > MAX_RESPONSE_BYTES:
            raise ValueError("invalid response cap")
        if not 1 <= self.config.max_concurrent_requests <= MAX_CONCURRENT_REQUESTS:
            raise ValueError("invalid concurrency cap")
        if not 0.1 <= self.config.read_timeout_seconds <= 30.0:
            raise ValueError("invalid read timeout")
        self.handler = handler

    def dispatch(
        self,
        method: str,
        target: str,
        headers: Sequence[tuple[str, str]],
        body: bytes = b"",
    ) -> RelayResponse:
        parsed = urlsplit(target)
        if parsed.query or parsed.fragment or parsed.path != target:
            return _json(400, "invalidTarget")
        path = parsed.path
        if path not in ALLOWED_PATHS:
            return _json(404, "routeUnavailable")
        if method not in {"GET", "POST"}:
            return _json(405, "methodUnavailable")
        normalized = _single_headers(headers)
        if normalized is None:
            return _json(400, "ambiguousHeaders")
        if not isinstance(body, bytes):
            return _json(400, "invalidBody")
        if len(body) > self.config.max_request_bytes:
            return _json(413, "capacity")
        if method == "POST" and not _valid_content_type(normalized.get("content-type")):
            return _json(415, "contentTypeRequired")
        if method == "GET" and path != "/replication/v1/health":
            return _json(405, "methodUnavailable")
        if path == "/replication/v1/health":
            if method != "GET" or body:
                return _json(400, "invalidHealthRequest")
            return RelayResponse(200, b'{"status":"relay","version":1}')
        if _is_admin_blob(path, body):
            return _json(403, "adminDenied")
        if self.handler is None:
            return _json(503, "handlerUnavailable")
        try:
            response = self.handler(method, path, normalized, body)
        except Exception:
            return _json(503, "handlerUnavailable")
        if (
            not isinstance(response, RelayResponse)
            or not isinstance(response.status, int)
            or not 100 <= response.status <= 599
            or not isinstance(response.body, bytes)
            or not _valid_response_content_type(response.content_type)
            or len(response.body) > self.config.max_response_bytes
        ):
            return _json(502, "responseInvalid")
        return response


class _RequestHandler(BaseHTTPRequestHandler):
    server_version = "LifeOSRelay/1"
    protocol_version = "HTTP/1.1"

    def _application(self) -> RelayApplication:
        return self.server.lifeos_application  # type: ignore[attr-defined]

    def setup(self) -> None:
        super().setup()
        self.connection.settimeout(self._application().config.read_timeout_seconds)

    def _write(self, response: RelayResponse) -> None:
        self.send_response(response.status)
        self.send_header("Content-Type", response.content_type)
        self.send_header("Content-Length", str(len(response.body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(response.body)
        self.close_connection = True

    def _headers(self) -> list[tuple[str, str]]:
        return [(str(name), str(value)) for name, value in self.headers.raw_items()]

    def _raw_header_values(self, name: str) -> list[str]:
        wanted = name.casefold()
        return [str(value) for header, value in self.headers.raw_items() if str(header).casefold() == wanted]

    def _body(self) -> bytes | None:
        transfer_encodings = self._raw_header_values("Transfer-Encoding")
        if transfer_encodings:
            self._write(_json(400, "transferEncodingUnsupported"))
            return None
        lengths = self._raw_header_values("Content-Length")
        if len(lengths) > 1:
            self._write(_json(400, "ambiguousContentLength"))
            return None
        if not lengths:
            self._write(_json(411, "contentLengthRequired"))
            return None
        try:
            length = int(lengths[0], 10)
        except ValueError:
            self._write(_json(400, "invalidContentLength"))
            return None
        if length < 0 or length > self._application().config.max_request_bytes:
            self._write(_json(413, "capacity"))
            return None
        body = self.rfile.read(length)
        if len(body) != length:
            self._write(_json(400, "truncatedBody"))
            return None
        return body

    def do_GET(self) -> None:  # noqa: N802
        self._write(self._application().dispatch("GET", self.path, self._headers(), b""))

    def do_POST(self) -> None:  # noqa: N802
        body = self._body()
        if body is not None:
            self._write(self._application().dispatch("POST", self.path, self._headers(), body))

    def log_message(self, _format: str, *_args: object) -> None:
        return


class _RelayServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def __init__(self, server_address, handler_class, max_workers: int):
        self._request_slots = threading.BoundedSemaphore(max_workers)
        super().__init__(server_address, handler_class)

    def process_request(self, request, client_address):  # noqa: N802
        if not self._request_slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self._request_slots.release()
            raise

    def process_request_thread(self, request, client_address):  # noqa: N802
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_slots.release()


class _RelayIPv6Server(_RelayServer):
    address_family = socket.AF_INET6


def create_server(config: RelayConfig | None = None, handler: RouteHandler | None = None) -> _RelayServer:
    application = RelayApplication(config, handler)
    if application.config.host not in {"127.0.0.1", "::1"} and not application.config.allow_non_loopback:
        raise ValueError("non-loopback relay binding requires explicit override")
    server_type = _RelayIPv6Server if application.config.host == "::1" else _RelayServer
    server = server_type(
        (application.config.host, application.config.port),
        _RequestHandler,
        application.config.max_concurrent_requests,
    )
    server.lifeos_application = application  # type: ignore[attr-defined]
    return server


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the opt-in LifeOS loopback relay")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8788)
    parser.add_argument("--allow-non-loopback", action="store_true")
    args = parser.parse_args()
    server = create_server(RelayConfig(args.host, args.port, allow_non_loopback=args.allow_non_loopback))
    try:
        server.serve_forever()
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
