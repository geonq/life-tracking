"""Bounded, durable replication primitives used by the LifeOS gateway.

This module deliberately stops at an already-verified boundary.  HTTP framing,
signature verification, and platform key custody belong to the callers.  The
store only accepts typed records whose caller has already authenticated them,
then makes their effects durable and idempotent.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import re
import secrets
import sqlite3
import struct
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Final, Mapping

try:
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey, Ed25519PublicKey
except ImportError:  # The Mac test environment may not have Windows runtime wheels.
    Ed25519PrivateKey = None  # type: ignore[assignment,misc]
    Ed25519PublicKey = None  # type: ignore[assignment,misc]


MAX_PAYLOAD_BYTES: Final = 1_048_576
MAX_PAGE_SIZE: Final = 256
MAX_EXCHANGE_ITEMS: Final = 128
MAX_DEPENDENCY_ROWS: Final = 256
MAX_ACKNOWLEDGEMENTS_PER_PAGE: Final = 128
MAX_RETAINED_ACKNOWLEDGEMENTS: Final = 4_096
REPLAY_RETENTION_NS: Final = 10 * 60 * 1_000_000_000
MAX_REPLAY_RECORDS: Final = 4_096
MAX_REPLAY_BYTES: Final = 64 * 1024 * 1024
MAX_BLOB_BYTES: Final = 33_554_432
MAX_BLOB_CHUNK_BYTES: Final = 262_144
MAX_INLINE_PAYLOAD_BYTES: Final = 65_536
MAX_OBSERVATION_BYTES: Final = 131_072
MAX_IDENTIFIER_BYTES: Final = 256
SQLITE_MAX_INTEGER: Final = 2**63 - 1
UINT64_MAX: Final = 2**64 - 1
MAX_SIGNED_FRAME_BYTES: Final = 2_097_152
MAX_FRAME_PATH_BYTES: Final = 64
FRAME_PATHS: Final = frozenset(
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
_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")
_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
_UNSIGNED_RE = re.compile(r"^(0|[1-9][0-9]*)$")
_BASE64URL_RE = re.compile(r"^[A-Za-z0-9_-]*$")


class ReplicationError(Exception):
    """Stable, content-free errors for the transport layer."""

    def __init__(self, code: str):
        self.code = code
        super().__init__(code)


@dataclass(frozen=True, slots=True)
class VerifiedExchange:
    """An authenticated exchange after HTTP/signature validation."""

    request_id: str
    dataset_id: str
    stream_id: str
    member_id: str
    epoch: int
    operation_id: str
    payload: bytes
    body_hash: str


@dataclass(frozen=True, slots=True)
class ExchangeResult:
    receipt_id: str
    request_id: str
    operation_ids: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class OperationRecord:
    operation_id: str
    dataset_id: str
    stream_id: str
    member_id: str
    epoch: int
    request_id: str
    payload: bytes
    body_hash: str


@dataclass(frozen=True, slots=True)
class OperationPage:
    items: tuple[OperationRecord, ...]
    next_after: int


@dataclass(frozen=True, slots=True)
class VerifiedAck:
    request_id: str
    receipt_id: str
    dataset_id: str
    member_id: str
    epoch: int


@dataclass(frozen=True, slots=True)
class CheckpointRequest:
    request_id: str
    dataset_id: str
    stream_id: str
    member_id: str
    epoch: int
    head_hash: str


@dataclass(frozen=True, slots=True)
class CheckpointReceipt:
    request_id: str
    dataset_id: str
    stream_id: str
    head_hash: str


@dataclass(frozen=True, slots=True)
class ObservationRecord:
    dataset_id: str
    origin_id: str
    sequence: int
    body_hash: str
    body: bytes


@dataclass(frozen=True, slots=True)
class VerifiedFrame:
    """A structurally and cryptographically verified legacy sync frame."""

    dataset_id: str
    epoch: str
    endpoint_id: str
    sender_id: str
    key_id: str
    request_id: str
    nonce: bytes
    method: str
    path: str
    status: int
    body: bytes


@dataclass(frozen=True, slots=True)
class TrustedMember:
    """One explicitly enrolled replication signer."""

    member_id: str
    key_id: str
    public_key: bytes
    active: bool


@dataclass(frozen=True, slots=True)
class ReplicationTrust:
    """The gateway's public trust boundary plus its response signer."""

    dataset_id: str
    epoch: str
    endpoint_id: str
    server_key_id: str
    server_private_key: bytes
    members: tuple[TrustedMember, ...]

    @property
    def members_by_id(self) -> dict[str, TrustedMember]:
        return {member.member_id: member for member in self.members}


@dataclass(frozen=True, slots=True)
class ChallengeLease:
    session_id: str
    nonce: bytes
    expires_at: int


@dataclass(frozen=True, slots=True)
class ExchangeOperationInput:
    operation_id: str
    dataset_id: str
    store_id: str
    origin_id: str
    epoch: int
    sequence: int
    operation_hash: str
    payload: bytes
    body_hash: str
    record: Mapping[str, Any]


@dataclass(frozen=True, slots=True)
class ExchangeAcknowledgementInput:
    mutation_id: str
    dataset_id: str
    store_id: str
    replica_id: str
    operation_hash: str
    payload: bytes
    body_hash: str
    record: Mapping[str, Any]


def _frame_error(code: str = "invalidFrame") -> ReplicationError:
    return ReplicationError(code)


def _strict_base64url(value: object, field: str, *, exact_bytes: int | None = None, maximum_bytes: int | None = None) -> bytes:
    if not isinstance(value, str) or "=" in value or not _BASE64URL_RE.fullmatch(value):
        raise _frame_error(f"invalid{field[:1].upper()}{field[1:]}")
    if len(value) % 4 == 1:
        raise _frame_error(f"invalid{field[:1].upper()}{field[1:]}")
    padded = value + "=" * ((4 - len(value) % 4) % 4)
    try:
        decoded = base64.b64decode(padded, altchars=b"-_", validate=True)
    except (ValueError, binascii.Error) as exc:
        raise _frame_error(f"invalid{field[:1].upper()}{field[1:]}") from exc
    if exact_bytes is not None and len(decoded) != exact_bytes:
        raise _frame_error(f"invalid{field[:1].upper()}{field[1:]}")
    if maximum_bytes is not None and len(decoded) > maximum_bytes:
        raise _frame_error("capacity")
    if base64.urlsafe_b64encode(decoded).rstrip(b"=").decode("ascii") != value:
        raise _frame_error(f"invalid{field[:1].upper()}{field[1:]}")
    return decoded


def _canonical_frame_value(frame: Mapping[str, object]) -> bytes:
    try:
        encoded = json.dumps(
            frame,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
            allow_nan=False,
        ).encode("utf-8")
        # Foundation's JSONSerialization escapes solidus characters as \/.
        # SyncWireCodec uses that output for the signed frame preimage, so the
        # gateway must emit the same bytes rather than Python's default raw /.
        encoded = encoded.replace(b"/", b"\\/")
    except (TypeError, UnicodeEncodeError, ValueError) as exc:
        raise _frame_error() from exc
    return encoded


def _frame_signing_bytes(frame: Mapping[str, object]) -> bytes:
    unsigned = dict(frame)
    unsigned.pop("signature", None)
    canonical = _canonical_frame_value(unsigned)
    if len(canonical) > MAX_SIGNED_FRAME_BYTES:
        raise ReplicationError("capacity")
    return b"LifeOS/frame/v1\0" + struct.pack(">I", len(canonical)) + canonical


def _base64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")


def _uuid(value: object, field: str) -> str:
    if (
        not isinstance(value, str)
        or not _UUID_RE.fullmatch(value)
        or uuid.UUID(value).urn.split(":")[-1] != value
    ):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _positive_unsigned(value: object, field: str) -> str:
    if not isinstance(value, str) or not _UNSIGNED_RE.fullmatch(value) or value == "0" or len(value) > 20:
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    if int(value) > UINT64_MAX:
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _strict_json_object(body: bytes, maximum_bytes: int) -> dict[str, Any]:
    if not isinstance(body, bytes) or len(body) > maximum_bytes:
        raise ReplicationError("capacity")
    try:
        decoded = json.loads(
            body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
            parse_int=_parse_json_int,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ReplicationError) as exc:
        if isinstance(exc, ReplicationError):
            raise
        raise _frame_error() from exc
    if not isinstance(decoded, dict):
        raise _frame_error()
    return decoded


def load_replication_trust(config_body: bytes, server_seed: bytes) -> ReplicationTrust:
    """Load and validate the explicit gateway trust file.

    The JSON file contains public enrollment records only. The server signing
    seed is supplied separately by the deployment's protected secret file and
    is checked against the configured server key ID before use.
    """
    if Ed25519PrivateKey is None or Ed25519PublicKey is None:
        raise ReplicationError("cryptoUnavailable")
    if not isinstance(server_seed, bytes) or len(server_seed) != 32:
        raise ReplicationError("invalidServerKey")
    decoded = _strict_json_object(config_body, 64 * 1024)
    if set(decoded) != {"schemaVersion", "datasetID", "epoch", "endpointID", "serverKeyID", "members"}:
        raise ReplicationError("invalidTrust")
    schema = decoded["schemaVersion"]
    if not isinstance(schema, int) or isinstance(schema, bool) or schema != 1 or getattr(schema, "token", "") != "1":
        raise ReplicationError("unsupportedSchema")
    dataset_id = _uuid(decoded["datasetID"], "datasetID")
    epoch = _positive_unsigned(decoded["epoch"], "epoch")
    endpoint_id = _uuid(decoded["endpointID"], "endpointID")
    server_key_id = decoded["serverKeyID"]
    if not isinstance(server_key_id, str) or not _HASH_RE.fullmatch(server_key_id):
        raise ReplicationError("invalidServerKeyID")
    raw_members = decoded["members"]
    if not isinstance(raw_members, list) or len(raw_members) > 8:
        raise ReplicationError("invalidTrust")
    members: list[TrustedMember] = []
    member_ids: set[str] = set()
    key_ids: set[str] = set()
    for raw in raw_members:
        if not isinstance(raw, dict) or set(raw) != {"memberID", "keyID", "publicKey", "active"}:
            raise ReplicationError("invalidTrust")
        member_id = _uuid(raw["memberID"], "memberID")
        key_id = raw["keyID"]
        if not isinstance(key_id, str) or not _HASH_RE.fullmatch(key_id):
            raise ReplicationError("invalidKeyID")
        public_key = _strict_base64url(raw["publicKey"], "publicKey", exact_bytes=32)
        if hashlib.sha256(public_key).hexdigest() != key_id:
            raise ReplicationError("invalidKeyID")
        if not isinstance(raw["active"], bool) or member_id in member_ids or key_id in key_ids:
            raise ReplicationError("invalidTrust")
        member_ids.add(member_id)
        key_ids.add(key_id)
        members.append(TrustedMember(member_id, key_id, public_key, raw["active"]))
    if endpoint_id in member_ids:
        raise ReplicationError("invalidTrust")
    private_key = Ed25519PrivateKey.from_private_bytes(server_seed)
    try:
        public_key = private_key.public_key().public_bytes_raw()
    except AttributeError:
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

        public_key = private_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    if hashlib.sha256(public_key).hexdigest() != server_key_id:
        raise ReplicationError("invalidServerKeyID")
    return ReplicationTrust(dataset_id, epoch, endpoint_id, server_key_id, server_seed, tuple(members))


def sign_frame_response(request: VerifiedFrame, status: int, body: bytes, trust: ReplicationTrust) -> bytes:
    """Create the exact legacy response frame expected by SyncTransport."""
    if Ed25519PrivateKey is None or not isinstance(body, bytes) or not 100 <= status <= 599:
        raise ReplicationError("invalidResponse")
    if len(body) > MAX_PAYLOAD_BYTES:
        raise ReplicationError("capacity")
    frame: dict[str, object] = {
        "schemaVersion": 1,
        "datasetID": request.dataset_id,
        "epoch": request.epoch,
        "endpointID": trust.endpoint_id,
        "senderID": trust.endpoint_id,
        "keyID": trust.server_key_id,
        "requestID": request.request_id,
        "nonce": _base64url(request.nonce),
        "method": "POST",
        "path": request.path,
        "status": status,
        "body": _base64url(body),
        "bodyHash": hashlib.sha256(body).hexdigest(),
        "signature": "",
    }
    private_key = Ed25519PrivateKey.from_private_bytes(trust.server_private_key)
    frame["signature"] = _base64url(private_key.sign(_frame_signing_bytes(frame)))
    encoded = _canonical_frame_value(frame)
    if len(encoded) > MAX_SIGNED_FRAME_BYTES:
        raise ReplicationError("capacity")
    return encoded


def _require_exact_keys(value: object, keys: set[str], field: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != keys:
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _require_keys(
    value: object,
    required: set[str],
    optional: set[str],
    field: str,
) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    keys = set(value)
    if not required.issubset(keys) or not keys.issubset(required | optional):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _schema_one(value: object) -> None:
    if not isinstance(value, int) or isinstance(value, bool) or value != 1 or getattr(value, "token", "") != "1":
        raise ReplicationError("unsupportedSchema")


def _unsigned_int(value: object, field: str, *, positive: bool = False) -> int:
    if not isinstance(value, str):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    canonical = _positive_unsigned(value, field) if positive else value
    if not positive and (not _UNSIGNED_RE.fullmatch(canonical) or len(canonical) > 20 or int(canonical) > UINT64_MAX):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return int(canonical)


def _verify_detached_record(record: Mapping[str, Any], domain: bytes, public_key: bytes) -> tuple[bytes, bytes]:
    signature = _strict_base64url(record.get("signature"), "signature", exact_bytes=64)
    unsigned = dict(record)
    unsigned.pop("signature", None)
    canonical = _canonical_frame_value(unsigned)
    framed = domain + b"\0" + struct.pack(">I", len(canonical)) + canonical
    if Ed25519PublicKey is None:
        raise ReplicationError("cryptoUnavailable")
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, framed)
    except Exception as exc:
        raise ReplicationError("unauthenticated") from exc
    # The signed wire record is what must be persisted and returned. The
    # unsigned canonical bytes above exist only as the signature preimage.
    return _canonical_frame_value(record), framed


def _parse_frontier(value: object, store_id: str) -> dict[str, int]:
    frontier = _require_exact_keys(value, {"schemaVersion", "positions"}, "frontier")
    _schema_one(frontier["schemaVersion"])
    positions = frontier["positions"]
    if not isinstance(positions, list) or len(positions) > 256:
        raise ReplicationError("capacity")
    result: dict[str, int] = {}
    previous: tuple[str, str] | None = None
    for raw in positions:
        position = _require_exact_keys(raw, {"stream", "through"}, "position")
        stream = _require_exact_keys(position["stream"], {"storeID", "originID"}, "stream")
        position_store = _uuid(stream["storeID"], "storeID")
        origin_id = _uuid(stream["originID"], "originID")
        if position_store != store_id:
            raise ReplicationError("membershipMismatch")
        through = _unsigned_int(position["through"], "through")
        key = (position_store, origin_id)
        if previous is not None and key <= previous:
            raise ReplicationError("invalidFrontier")
        previous = key
        if origin_id in result:
            raise ReplicationError("invalidFrontier")
        result[origin_id] = through
    return result


def parse_exchange_request(
    body: bytes,
    trust: ReplicationTrust,
    *,
    sender_id: str,
) -> tuple[
    str,
    tuple[ExchangeOperationInput, ...],
    tuple[ExchangeAcknowledgementInput, ...],
    dict[str, int],
    dict[str, int] | None,
    int,
]:
    """Strictly decode, validate, and verify a legacy exchange payload."""
    decoded = _strict_json_object(body, MAX_PAYLOAD_BYTES)
    request = _require_keys(
        decoded,
        {"schemaVersion", "storeID", "received", "operations", "acknowledgements", "limit"},
        {"upper"},
        "exchangeRequest",
    )
    _schema_one(request["schemaVersion"])
    store_id = _uuid(request["storeID"], "storeID")
    received = _parse_frontier(request["received"], store_id)
    upper = None if request.get("upper") is None else _parse_frontier(request["upper"], store_id)
    limit_value = request["limit"]
    if not isinstance(limit_value, int) or isinstance(limit_value, bool) or not 1 <= limit_value <= MAX_EXCHANGE_ITEMS:
        raise ReplicationError("invalidLimit")
    raw_operations = request["operations"]
    raw_acknowledgements = request["acknowledgements"]
    if not isinstance(raw_operations, list) or not isinstance(raw_acknowledgements, list):
        raise ReplicationError("invalidExchangeRequest")
    if len(raw_operations) > MAX_EXCHANGE_ITEMS or len(raw_acknowledgements) > MAX_EXCHANGE_ITEMS:
        raise ReplicationError("capacity")
    expected_epoch = _unsigned_int(trust.epoch, "epoch", positive=True)
    members = trust.members_by_id
    operations: list[ExchangeOperationInput] = []
    for raw in raw_operations:
        operation = _require_keys(
            raw,
            {
                "schemaVersion", "datasetID", "epoch", "storeID", "domain", "originID", "keyID",
                "sequence", "mutationID", "entityID", "parents", "kind", "payload", "signature",
            },
            {"baseHash"},
            "operation",
        )
        _schema_one(operation["schemaVersion"])
        if _uuid(operation["datasetID"], "datasetID") != trust.dataset_id:
            raise ReplicationError("datasetMismatch")
        if _unsigned_int(operation["epoch"], "epoch", positive=True) != expected_epoch:
            raise ReplicationError("staleEpoch")
        if _uuid(operation["storeID"], "storeID") != store_id:
            raise ReplicationError("membershipMismatch")
        if not isinstance(operation["domain"], str) or operation["domain"] not in {"calendar", "finance", "fitness", "planning", "tax"}:
            raise ReplicationError("invalidDomain")
        origin_id = _uuid(operation["originID"], "originID")
        if origin_id != sender_id:
            raise ReplicationError("authorizationDenied")
        key_id = operation["keyID"]
        if not isinstance(key_id, str) or not _HASH_RE.fullmatch(key_id):
            raise ReplicationError("invalidKeyID")
        member = members.get(origin_id)
        if member is None or not member.active or member.key_id != key_id:
            raise ReplicationError("authorizationDenied")
        sequence = _unsigned_int(operation["sequence"], "sequence", positive=True)
        mutation_id = _uuid(operation["mutationID"], "mutationID")
        _hash(operation["entityID"], "entityID")
        parents = operation["parents"]
        if not isinstance(parents, list) or len(parents) > 8:
            raise ReplicationError("capacity")
        parsed_parents = [_uuid(parent, "parent") for parent in parents]
        if parsed_parents != sorted(set(parsed_parents)):
            raise ReplicationError("invalidParents")
        base_hash = operation.get("baseHash")
        if base_hash is not None:
            _hash(base_hash, "baseHash")
        payload = _require_keys(
            operation["payload"],
            {"schemaVersion", "hash", "byteCount"},
            {"inline", "blobHash"},
            "payload",
        )
        _schema_one(payload["schemaVersion"])
        payload_hash = payload["hash"]
        _hash(payload_hash, "payloadHash")
        byte_count = payload["byteCount"]
        if not isinstance(byte_count, int) or isinstance(byte_count, bool) or not 0 <= byte_count <= MAX_BLOB_BYTES:
            raise ReplicationError("capacity")
        inline = payload.get("inline")
        blob_hash = payload.get("blobHash")
        if (inline is None) == (blob_hash is None):
            raise ReplicationError("invalidPayload")
        if inline is not None:
            payload_bytes = _strict_base64url(inline, "inline", maximum_bytes=MAX_INLINE_PAYLOAD_BYTES)
            if len(payload_bytes) != byte_count or hashlib.sha256(payload_bytes).hexdigest() != payload_hash:
                raise ReplicationError("bodyHashMismatch")
        else:
            _hash(blob_hash, "blobHash")
            if blob_hash != payload_hash:
                raise ReplicationError("bodyHashMismatch")
        if not isinstance(operation["kind"], str) or operation["kind"] not in {"put", "delete", "resolve", "bootstrap"}:
            raise ReplicationError("invalidKind")
        if operation["kind"] == "delete" and inline != "":
            raise ReplicationError("invalidPayload")
        canonical, signing_bytes = _verify_detached_record(operation, b"LifeOS/operation/v1", member.public_key)
        operations.append(
            ExchangeOperationInput(
                operation_id=mutation_id,
                dataset_id=trust.dataset_id,
                store_id=store_id,
                origin_id=origin_id,
                epoch=expected_epoch,
                sequence=sequence,
                operation_hash=hashlib.sha256(signing_bytes).hexdigest(),
                payload=canonical,
                body_hash=hashlib.sha256(canonical).hexdigest(),
                record=operation,
            )
        )

    acknowledgements: list[ExchangeAcknowledgementInput] = []
    for raw in raw_acknowledgements:
        acknowledgement = _require_exact_keys(
            raw,
            {
                "schemaVersion", "datasetID", "epoch", "storeID", "mutationID", "operationHash",
                "replicaID", "keyID", "level", "resultHash", "signature",
            },
            "acknowledgement",
        )
        _schema_one(acknowledgement["schemaVersion"])
        if _uuid(acknowledgement["datasetID"], "datasetID") != trust.dataset_id:
            raise ReplicationError("datasetMismatch")
        if _unsigned_int(acknowledgement["epoch"], "epoch", positive=True) != expected_epoch:
            raise ReplicationError("staleEpoch")
        if _uuid(acknowledgement["storeID"], "storeID") != store_id:
            raise ReplicationError("membershipMismatch")
        mutation_id = _uuid(acknowledgement["mutationID"], "mutationID")
        operation_hash = acknowledgement["operationHash"]
        _hash(operation_hash, "operationHash")
        replica_id = _uuid(acknowledgement["replicaID"], "replicaID")
        if replica_id != sender_id:
            raise ReplicationError("authorizationDenied")
        key_id = acknowledgement["keyID"]
        if not isinstance(key_id, str) or not _HASH_RE.fullmatch(key_id):
            raise ReplicationError("invalidKeyID")
        member = members.get(replica_id)
        if member is None or not member.active or member.key_id != key_id:
            raise ReplicationError("authorizationDenied")
        if not isinstance(acknowledgement["level"], str) or acknowledgement["level"] not in {"stored", "applied", "retainedConflict"}:
            raise ReplicationError("invalidLevel")
        _hash(acknowledgement["resultHash"], "resultHash")
        canonical, _ = _verify_detached_record(acknowledgement, b"LifeOS/acknowledgement/v1", member.public_key)
        acknowledgements.append(
            ExchangeAcknowledgementInput(
                mutation_id=mutation_id,
                dataset_id=trust.dataset_id,
                store_id=store_id,
                replica_id=replica_id,
                operation_hash=operation_hash,
                payload=canonical,
                body_hash=hashlib.sha256(canonical).hexdigest(),
                record=acknowledgement,
            )
        )
    return store_id, tuple(operations), tuple(acknowledgements), received, upper, int(limit_value)


def _reject_duplicate_json_keys(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise _frame_error("duplicateKey")
        result[key] = value
    return result


class _StrictJSONInt(int):
    def __new__(cls, token: str):
        if len(token) > 20:
            raise _frame_error("invalidFrame")
        instance = int.__new__(cls, int(token))
        instance.token = token
        return instance


def _parse_json_int(token: str) -> _StrictJSONInt:
    return _StrictJSONInt(token)


def verify_signed_frame(
    frame_body: bytes,
    public_key: bytes,
    *,
    expected_dataset_id: str | None = None,
    expected_endpoint_id: str | None = None,
    expected_epoch: str | None = None,
    expected_method: str = "POST",
    expected_path: str | None = None,
    maximum_body_bytes: int = MAX_PAYLOAD_BYTES,
) -> VerifiedFrame:
    """Verify a Swift ``SyncSignedFrame`` without accepting untrusted fields.

    The function performs all structural and hash checks before asking the
    optional Ed25519 implementation to verify the signature. Callers still
    need to authorize the resulting sender against their durable trust state.
    """
    if not isinstance(frame_body, bytes) or len(frame_body) > MAX_SIGNED_FRAME_BYTES:
        raise ReplicationError("capacity")
    if not isinstance(public_key, bytes) or len(public_key) != 32:
        raise ReplicationError("invalidPublicKey")
    if isinstance(maximum_body_bytes, bool) or not isinstance(maximum_body_bytes, int) or not 0 <= maximum_body_bytes <= MAX_PAYLOAD_BYTES:
        raise ReplicationError("invalidBodyLimit")
    try:
        decoded = json.loads(
            frame_body.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_json_keys,
            parse_int=_parse_json_int,
        )
    except (UnicodeDecodeError, json.JSONDecodeError, ReplicationError) as exc:
        if isinstance(exc, ReplicationError):
            raise
        raise _frame_error() from exc
    if not isinstance(decoded, dict):
        raise _frame_error()
    required = {
        "schemaVersion", "datasetID", "epoch", "endpointID", "senderID", "keyID",
        "requestID", "nonce", "method", "path", "status", "body", "bodyHash", "signature",
    }
    if set(decoded) != required:
        raise _frame_error("invalidKeys")
    if (
        not isinstance(decoded["schemaVersion"], int)
        or isinstance(decoded["schemaVersion"], bool)
        or decoded["schemaVersion"] != 1
        or getattr(decoded["schemaVersion"], "token", "") != "1"
        or any(
            not isinstance(decoded[field], str)
            for field in (
                "datasetID", "epoch", "endpointID", "senderID", "keyID", "requestID",
                "nonce", "method", "path", "body", "bodyHash", "signature",
            )
        )
    ):
        raise _frame_error()
    uuid_fields = ("datasetID", "endpointID", "senderID", "requestID")
    for field in uuid_fields:
        value = decoded[field]
        if not _UUID_RE.fullmatch(value) or uuid.UUID(value).urn.split(":")[-1] != value:
            raise _frame_error(f"invalid{field[:1].upper()}{field[1:]}")
    epoch = decoded["epoch"]
    if len(epoch) > 20 or not _UNSIGNED_RE.fullmatch(epoch) or epoch == "0" or int(epoch) > UINT64_MAX:
        raise _frame_error("invalidEpoch")
    key_id = decoded["keyID"]
    if not _HASH_RE.fullmatch(key_id):
        raise _frame_error("invalidKeyID")
    nonce = _strict_base64url(decoded["nonce"], "nonce", exact_bytes=32)
    signature = _strict_base64url(decoded["signature"], "signature", exact_bytes=64)
    method = decoded["method"]
    path = decoded["path"]
    status = decoded["status"]
    if (
        method != expected_method
        or method != "POST"
        or not isinstance(status, int)
        or isinstance(status, bool)
        or status != 0
        or getattr(status, "token", "") != "0"
    ):
        raise _frame_error("invalidFrame")
    if path not in FRAME_PATHS or len(path.encode("utf-8")) > MAX_FRAME_PATH_BYTES:
        raise _frame_error("invalidPath")
    body = _strict_base64url(decoded["body"], "body", maximum_bytes=maximum_body_bytes)
    body_hash = decoded["bodyHash"]
    if not _HASH_RE.fullmatch(body_hash) or hashlib.sha256(body).hexdigest() != body_hash:
        raise ReplicationError("bodyHashMismatch")
    if expected_dataset_id is not None and decoded["datasetID"] != expected_dataset_id:
        raise ReplicationError("datasetMismatch")
    if expected_endpoint_id is not None and decoded["endpointID"] != expected_endpoint_id:
        raise ReplicationError("endpointMismatch")
    if expected_epoch is not None and decoded["epoch"] != expected_epoch:
        raise ReplicationError("staleEpoch")
    if expected_path is not None and path != expected_path:
        raise ReplicationError("routeMismatch")
    if Ed25519PublicKey is None:
        raise ReplicationError("cryptoUnavailable")
    try:
        Ed25519PublicKey.from_public_bytes(public_key).verify(signature, _frame_signing_bytes(decoded))
    except Exception as exc:
        raise ReplicationError("unauthenticated") from exc
    return VerifiedFrame(
        dataset_id=decoded["datasetID"],
        epoch=epoch,
        endpoint_id=decoded["endpointID"],
        sender_id=decoded["senderID"],
        key_id=key_id,
        request_id=decoded["requestID"],
        nonce=nonce,
        method=method,
        path=path,
        status=status,
        body=body,
    )


def _identifier(value: str, field: str) -> str:
    if not isinstance(value, str) or not _IDENTIFIER_RE.fullmatch(value):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _hash(value: str, field: str = "hash") -> str:
    if not isinstance(value, str) or not _HASH_RE.fullmatch(value):
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _nonnegative(value: int, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0 or value > SQLITE_MAX_INTEGER:
        raise ReplicationError(f"invalid{field[:1].upper()}{field[1:]}")
    return value


def _body_hash(body: bytes) -> str:
    return hashlib.sha256(body).hexdigest()


def _json_result(result: ExchangeResult) -> str:
    return json.dumps(
        {
            "receiptID": result.receipt_id,
            "requestID": result.request_id,
            "operationIDs": list(result.operation_ids),
        },
        separators=(",", ":"),
        sort_keys=True,
    )


def _decode_result(value: str) -> ExchangeResult:
    try:
        raw = json.loads(value)
        result = ExchangeResult(
            receipt_id=raw["receiptID"],
            request_id=raw["requestID"],
            operation_ids=tuple(raw["operationIDs"]),
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError) as exc:
        raise ReplicationError("corruptReplayState") from exc
    if not result.receipt_id or result.request_id != raw.get("requestID"):
        raise ReplicationError("corruptReplayState")
    return result


class ReplicationStore:
    """A single-connection SQLite store with serialized writes.

    The connection is protected by an RLock so a caller can safely use the
    same store from bounded request tasks.  All write methods use BEGIN
    IMMEDIATE and commit their request/replay record in the same transaction
    as the effect they describe.
    """

    _SCHEMA_VERSION = 7

    def __init__(self, path: str | Path):
        self.path = str(path)
        self._lock = threading.RLock()
        self._connection = sqlite3.connect(
            self.path,
            isolation_level=None,
            check_same_thread=False,
            timeout=5.0,
        )
        self._connection.execute("PRAGMA foreign_keys = ON")
        self._connection.execute("PRAGMA busy_timeout = 5000")
        if self.path != ":memory:":
            self._connection.execute("PRAGMA journal_mode = WAL")
            self._connection.execute("PRAGMA synchronous = FULL")
        self._migrate()

    def close(self) -> None:
        with self._lock:
            self._connection.close()

    def _migrate(self) -> None:
        with self._lock:
            self._connection.execute("BEGIN IMMEDIATE")
            try:
                version = int(self._connection.execute("PRAGMA user_version").fetchone()[0])
                if version > self._SCHEMA_VERSION:
                    raise ReplicationError("unsupportedSchema")
                schema_statements = (
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_members (
                        member_id TEXT PRIMARY KEY,
                        epoch INTEGER NOT NULL CHECK (epoch >= 0),
                        active INTEGER NOT NULL CHECK (active IN (0, 1)),
                        key_id TEXT,
                        public_key BLOB
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_requests (
                        request_id TEXT PRIMARY KEY,
                        request_fingerprint TEXT NOT NULL,
                        receipt_id TEXT NOT NULL,
                        result_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_operations (
                        row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        operation_id TEXT NOT NULL UNIQUE,
                        dataset_id TEXT NOT NULL,
                        stream_id TEXT NOT NULL,
                        member_id TEXT NOT NULL,
                        epoch INTEGER NOT NULL CHECK (epoch >= 0),
                        sequence INTEGER NOT NULL CHECK (sequence >= 0),
                        request_id TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        body_hash TEXT NOT NULL,
                        operation_hash TEXT,
                        legacy INTEGER NOT NULL DEFAULT 0,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE INDEX IF NOT EXISTS lifeos_replication_operations_page
                        ON lifeos_replication_operations(dataset_id, stream_id, row_id);
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_stream_heads (
                        dataset_id TEXT NOT NULL,
                        stream_id TEXT NOT NULL,
                        member_id TEXT NOT NULL,
                        sequence INTEGER NOT NULL CHECK (sequence >= 0),
                        updated_at INTEGER NOT NULL,
                        PRIMARY KEY(dataset_id, stream_id, member_id)
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_acks (
                        request_id TEXT PRIMARY KEY,
                        receipt_id TEXT NOT NULL,
                        dataset_id TEXT NOT NULL,
                        member_id TEXT NOT NULL,
                        epoch INTEGER NOT NULL CHECK (epoch >= 0),
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_checkpoints (
                        request_id TEXT PRIMARY KEY,
                        dataset_id TEXT NOT NULL,
                        stream_id TEXT NOT NULL,
                        member_id TEXT NOT NULL,
                        epoch INTEGER NOT NULL CHECK (epoch >= 0),
                        head_hash TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_blobs (
                        blob_hash TEXT PRIMARY KEY,
                        total_bytes INTEGER NOT NULL CHECK (total_bytes >= 0),
                        next_offset INTEGER NOT NULL CHECK (next_offset >= 0),
                        last_chunk_offset INTEGER NOT NULL CHECK (last_chunk_offset >= 0),
                        last_chunk_length INTEGER NOT NULL CHECK (last_chunk_length >= 0),
                        last_chunk_hash TEXT NOT NULL,
                        updated_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_observations (
                        dataset_id TEXT NOT NULL,
                        origin_id TEXT NOT NULL,
                        sequence INTEGER NOT NULL CHECK (sequence >= 0),
                        body_hash TEXT NOT NULL,
                        body BLOB NOT NULL,
                        updated_at INTEGER NOT NULL,
                        PRIMARY KEY(dataset_id, origin_id)
                    )
                    """,
                    """
                    CREATE INDEX IF NOT EXISTS lifeos_replication_observation_sequence
                        ON lifeos_replication_observations(dataset_id, origin_id, sequence)
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_challenges (
                        nonce_hash TEXT PRIMARY KEY,
                        session_id TEXT NOT NULL,
                        dataset_id TEXT NOT NULL,
                        sender_id TEXT NOT NULL,
                        expires_at INTEGER NOT NULL,
                        consumed INTEGER NOT NULL CHECK (consumed IN (0, 1)),
                        request_id TEXT,
                        request_fingerprint TEXT,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_exchange_requests (
                        request_id TEXT PRIMARY KEY,
                        request_fingerprint TEXT NOT NULL,
                        response_body BLOB NOT NULL,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_exchange_acks (
                        delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
                        dataset_id TEXT NOT NULL,
                        store_id TEXT NOT NULL,
                        mutation_id TEXT NOT NULL,
                        replica_id TEXT NOT NULL,
                        operation_hash TEXT NOT NULL,
                        body BLOB NOT NULL,
                        body_hash TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_ack_state (
                        dataset_id TEXT NOT NULL,
                        store_id TEXT NOT NULL,
                        mutation_id TEXT NOT NULL,
                        replica_id TEXT NOT NULL,
                        operation_hash TEXT NOT NULL,
                        body BLOB NOT NULL,
                        body_hash TEXT NOT NULL,
                        level TEXT NOT NULL,
                        updated_at INTEGER NOT NULL,
                        PRIMARY KEY(dataset_id, store_id, mutation_id, replica_id)
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_ack_cursors (
                        dataset_id TEXT NOT NULL,
                        store_id TEXT NOT NULL,
                        member_id TEXT NOT NULL,
                        confirmed_through INTEGER NOT NULL CHECK (confirmed_through >= 0),
                        issued_through INTEGER NOT NULL CHECK (issued_through >= 0),
                        updated_at INTEGER NOT NULL,
                        PRIMARY KEY(dataset_id, store_id, member_id)
                    )
                    """,
                    """
                    CREATE TABLE IF NOT EXISTS lifeos_replication_recovery (
                        recovery_id TEXT PRIMARY KEY,
                        reason TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    )
                    """,
                )
                for statement in schema_statements:
                    self._connection.execute(statement)
                blob_columns = {
                    str(row[1])
                    for row in self._connection.execute("PRAGMA table_info(lifeos_replication_blobs)")
                }
                if "last_chunk_offset" not in blob_columns:
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_blobs ADD COLUMN last_chunk_offset INTEGER NOT NULL DEFAULT 0"
                    )
                if "last_chunk_length" not in blob_columns:
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_blobs ADD COLUMN last_chunk_length INTEGER NOT NULL DEFAULT 0"
                    )
                member_columns = {
                    str(row[1])
                    for row in self._connection.execute("PRAGMA table_info(lifeos_replication_members)")
                }
                if "key_id" not in member_columns:
                    self._connection.execute("ALTER TABLE lifeos_replication_members ADD COLUMN key_id TEXT")
                if "public_key" not in member_columns:
                    self._connection.execute("ALTER TABLE lifeos_replication_members ADD COLUMN public_key BLOB")
                operation_columns = {
                    str(row[1])
                    for row in self._connection.execute("PRAGMA table_info(lifeos_replication_operations)")
                }
                if "sequence" not in operation_columns:
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_operations ADD COLUMN sequence INTEGER NOT NULL DEFAULT 0"
                    )
                if "operation_hash" not in operation_columns:
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_operations ADD COLUMN operation_hash TEXT"
                    )
                if "legacy" not in operation_columns:
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_operations ADD COLUMN legacy INTEGER NOT NULL DEFAULT 1"
                    )
                self._connection.execute(
                    """
                    CREATE INDEX IF NOT EXISTS lifeos_replication_operations_stream_sequence
                        ON lifeos_replication_operations(dataset_id, stream_id, legacy, member_id, sequence)
                    """
                )
                challenge_columns = {
                    str(row[1])
                    for row in self._connection.execute("PRAGMA table_info(lifeos_replication_challenges)")
                }
                if "request_fingerprint" not in challenge_columns:
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_challenges ADD COLUMN request_fingerprint TEXT"
                    )
                ack_columns = {
                    str(row[1])
                    for row in self._connection.execute("PRAGMA table_info(lifeos_replication_exchange_acks)")
                }
                if "delivery_id" not in ack_columns:
                    self._connection.execute("ALTER TABLE lifeos_replication_exchange_acks RENAME TO lifeos_replication_exchange_acks_legacy")
                    self._connection.execute(
                        """
                        CREATE TABLE lifeos_replication_exchange_acks (
                            delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
                            dataset_id TEXT NOT NULL,
                            store_id TEXT NOT NULL,
                            mutation_id TEXT NOT NULL,
                            replica_id TEXT NOT NULL,
                            operation_hash TEXT NOT NULL,
                            body BLOB NOT NULL,
                            body_hash TEXT NOT NULL,
                            created_at INTEGER NOT NULL
                        )
                        """
                    )
                    self._connection.execute(
                        """
                        INSERT INTO lifeos_replication_exchange_acks
                        (dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, created_at)
                        SELECT dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, created_at
                        FROM lifeos_replication_exchange_acks_legacy ORDER BY created_at
                        """
                    )
                    self._connection.execute("DROP TABLE lifeos_replication_exchange_acks_legacy")
                ack_indexes = list(self._connection.execute("PRAGMA index_list(lifeos_replication_exchange_acks)"))
                if any(int(row[2]) == 1 for row in ack_indexes):
                    self._connection.execute("ALTER TABLE lifeos_replication_exchange_acks RENAME TO lifeos_replication_exchange_acks_unique")
                    self._connection.execute(
                        """
                        CREATE TABLE lifeos_replication_exchange_acks (
                            delivery_id INTEGER PRIMARY KEY AUTOINCREMENT,
                            dataset_id TEXT NOT NULL,
                            store_id TEXT NOT NULL,
                            mutation_id TEXT NOT NULL,
                            replica_id TEXT NOT NULL,
                            operation_hash TEXT NOT NULL,
                            body BLOB NOT NULL,
                            body_hash TEXT NOT NULL,
                            created_at INTEGER NOT NULL
                        )
                        """
                    )
                    self._connection.execute(
                        """
                        INSERT INTO lifeos_replication_exchange_acks
                        (delivery_id, dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, created_at)
                        SELECT delivery_id, dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, created_at
                        FROM lifeos_replication_exchange_acks_unique ORDER BY delivery_id
                        """
                    )
                    self._connection.execute("DROP TABLE lifeos_replication_exchange_acks_unique")
                cursor_columns = {
                    str(row[1])
                    for row in self._connection.execute("PRAGMA table_info(lifeos_replication_ack_cursors)")
                }
                if "through" in cursor_columns:
                    # The old column recorded an unverified client claim. It
                    # cannot become an issued or confirmed security boundary.
                    # Rebuild the table and deliberately discard those claims;
                    # the next exchange starts a fresh cursor at zero.
                    self._connection.execute(
                        "ALTER TABLE lifeos_replication_ack_cursors RENAME TO lifeos_replication_ack_cursors_legacy"
                    )
                    self._connection.execute(
                        """
                        CREATE TABLE lifeos_replication_ack_cursors (
                            dataset_id TEXT NOT NULL,
                            store_id TEXT NOT NULL,
                            member_id TEXT NOT NULL,
                            confirmed_through INTEGER NOT NULL CHECK (confirmed_through >= 0),
                            issued_through INTEGER NOT NULL CHECK (issued_through >= 0),
                            updated_at INTEGER NOT NULL,
                            PRIMARY KEY(dataset_id, store_id, member_id)
                        )
                        """
                    )
                    self._connection.execute("DROP TABLE lifeos_replication_ack_cursors_legacy")
                    self._connection.execute(
                        "INSERT OR IGNORE INTO lifeos_replication_recovery "
                        "(recovery_id, reason, created_at) VALUES (?, ?, ?)",
                        (
                            "ack_cursor_resync",
                            "Legacy acknowledgement cursors were unverified; client resynchronization is required",
                            int(time.time_ns()),
                        ),
                    )
                else:
                    if "confirmed_through" not in cursor_columns:
                        self._connection.execute(
                            "ALTER TABLE lifeos_replication_ack_cursors ADD COLUMN confirmed_through INTEGER NOT NULL DEFAULT 0"
                        )
                    if "issued_through" not in cursor_columns:
                        self._connection.execute(
                            "ALTER TABLE lifeos_replication_ack_cursors ADD COLUMN issued_through INTEGER NOT NULL DEFAULT 0"
                        )
                state_count = int(
                    self._connection.execute(
                        "SELECT COUNT(*) FROM lifeos_replication_ack_state"
                    ).fetchone()[0]
                )
                if state_count == 0:
                    state_rows = self._connection.execute(
                        "SELECT dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash "
                        "FROM lifeos_replication_exchange_acks ORDER BY delivery_id"
                    ).fetchall()
                    for state_row in state_rows:
                        try:
                            state_record = json.loads(bytes(state_row[5]).decode("utf-8"))
                        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                            raise ReplicationError("corruptStore") from exc
                        level = state_record.get("level") if isinstance(state_record, dict) else None
                        if not isinstance(level, str) or level not in {"stored", "applied", "retainedConflict"}:
                            raise ReplicationError("corruptStore")
                        self._connection.execute(
                            "INSERT INTO lifeos_replication_ack_state "
                            "(dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, level, updated_at) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                            (*state_row, level, int(time.time_ns())),
                        )
                self._connection.execute(
                    """
                    INSERT INTO lifeos_replication_stream_heads
                    (dataset_id, stream_id, member_id, sequence, updated_at)
                    SELECT dataset_id, stream_id, member_id, MAX(sequence), MAX(created_at)
                    FROM lifeos_replication_operations
                    WHERE legacy = 0
                    GROUP BY dataset_id, stream_id, member_id
                    ON CONFLICT(dataset_id, stream_id, member_id) DO UPDATE SET
                        sequence = excluded.sequence,
                        updated_at = excluded.updated_at
                    """
                )
                if version < 2:
                    self._connection.execute(
                        "UPDATE lifeos_replication_blobs SET last_chunk_length = next_offset "
                        "WHERE last_chunk_length = 0 AND next_offset > 0"
                    )
                self._connection.execute(f"PRAGMA user_version = {self._SCHEMA_VERSION}")
                self._connection.execute("COMMIT")
            except BaseException:
                if self._connection.in_transaction:
                    self._connection.execute("ROLLBACK")
                raise

    def _transaction(self):
        class Transaction:
            def __init__(inner, outer: ReplicationStore):
                inner.outer = outer

            def __enter__(inner):
                inner.outer._lock.acquire()
                try:
                    inner.outer._connection.execute("BEGIN IMMEDIATE")
                except BaseException:
                    inner.outer._lock.release()
                    raise
                return inner.outer._connection

            def __exit__(inner, exc_type, exc, tb):
                if exc_type is not None:
                    try:
                        inner.outer._connection.execute("ROLLBACK")
                    finally:
                        inner.outer._lock.release()
                    return False
                try:
                    inner.outer._connection.execute("COMMIT")
                except BaseException:
                    if inner.outer._connection.in_transaction:
                        try:
                            inner.outer._connection.execute("ROLLBACK")
                        except sqlite3.Error:
                            pass
                    raise
                finally:
                    inner.outer._lock.release()
                return False

        return Transaction(self)

    @staticmethod
    def _validate_exchange(request: VerifiedExchange) -> None:
        _identifier(request.request_id, "requestID")
        _identifier(request.dataset_id, "datasetID")
        _identifier(request.stream_id, "streamID")
        _identifier(request.member_id, "memberID")
        _identifier(request.operation_id, "operationID")
        _nonnegative(request.epoch, "epoch")
        if not isinstance(request.payload, bytes) or len(request.payload) > MAX_PAYLOAD_BYTES:
            raise ReplicationError("capacity")
        _hash(request.body_hash, "bodyHash")
        if not secrets.compare_digest(request.body_hash, _body_hash(request.payload)):
            raise ReplicationError("bodyHashMismatch")

    @staticmethod
    def _fingerprint(request: VerifiedExchange) -> str:
        material = "\x1f".join(
            (
                request.dataset_id,
                request.stream_id,
                request.member_id,
                str(request.epoch),
                request.operation_id,
                request.body_hash,
            )
        ).encode("utf-8")
        return hashlib.sha256(material).hexdigest()

    @staticmethod
    def _authorize(connection: sqlite3.Connection, member_id: str, epoch: int) -> None:
        row = connection.execute(
            "SELECT epoch, active FROM lifeos_replication_members WHERE member_id = ?",
            (member_id,),
        ).fetchone()
        if row is None or int(row[1]) != 1:
            raise ReplicationError("authorizationDenied")
        if int(row[0]) != epoch:
            raise ReplicationError("staleEpoch")

    def register_member(
        self,
        member_id: str,
        epoch: int,
        key_id: str | None = None,
        public_key: bytes | None = None,
        active: bool = True,
    ) -> None:
        _identifier(member_id, "memberID")
        _nonnegative(epoch, "epoch")
        if key_id is not None:
            _hash(key_id, "keyID")
        if public_key is not None and (not isinstance(public_key, bytes) or len(public_key) != 32):
            raise ReplicationError("invalidPublicKey")
        if (key_id is None) != (public_key is None):
            raise ReplicationError("invalidMember")
        if public_key is not None and hashlib.sha256(public_key).hexdigest() != key_id:
            raise ReplicationError("invalidKeyID")
        if not isinstance(active, bool):
            raise ReplicationError("invalidMember")
        with self._transaction() as connection:
            connection.execute(
                "INSERT INTO lifeos_replication_members(member_id, epoch, active, key_id, public_key) "
                "VALUES (?, ?, ?, ?, ?) ON CONFLICT(member_id) DO UPDATE SET "
                "epoch=excluded.epoch, active=excluded.active, key_id=excluded.key_id, public_key=excluded.public_key",
                (member_id, epoch, int(active), key_id, public_key),
            )

    def reconcile_members(self, member_ids: set[str]) -> None:
        """Deactivate durable members absent from the signed trust file."""
        if not isinstance(member_ids, set):
            raise ReplicationError("invalidMember")
        for member_id in member_ids:
            _identifier(member_id, "memberID")
        with self._transaction() as connection:
            if not member_ids:
                connection.execute("UPDATE lifeos_replication_members SET active = 0")
                return
            placeholders = ",".join("?" for _ in member_ids)
            connection.execute(
                f"UPDATE lifeos_replication_members SET active = 0 WHERE member_id NOT IN ({placeholders})",
                tuple(member_ids),
            )

    def member_public_key(self, member_id: str, epoch: int, key_id: str) -> bytes:
        _identifier(member_id, "memberID")
        _nonnegative(epoch, "epoch")
        _hash(key_id, "keyID")
        with self._lock:
            row = self._connection.execute(
                "SELECT epoch, active, key_id, public_key FROM lifeos_replication_members WHERE member_id = ?",
                (member_id,),
            ).fetchone()
        if row is None or int(row[1]) != 1 or int(row[0]) != epoch or row[2] != key_id:
            raise ReplicationError("authorizationDenied")
        public_key = row[3]
        if not isinstance(public_key, bytes) or len(public_key) != 32:
            raise ReplicationError("authorizationDenied")
        return public_key

    def has_unmigrated_legacy_operations(self) -> bool:
        with self._lock:
            row = self._connection.execute(
                "SELECT 1 FROM lifeos_replication_operations WHERE legacy = 1 LIMIT 1"
            ).fetchone()
        return row is not None

    def has_recovery_required(self) -> bool:
        with self._lock:
            row = self._connection.execute(
                "SELECT 1 FROM lifeos_replication_recovery LIMIT 1"
            ).fetchone()
        return row is not None

    def revoke_member(self, member_id: str) -> None:
        _identifier(member_id, "memberID")
        with self._transaction() as connection:
            connection.execute(
                "UPDATE lifeos_replication_members SET active = 0 WHERE member_id = ?",
                (member_id,),
            )

    def issue_challenge(self, dataset_id: str, sender_id: str, ttl_seconds: int = 120) -> ChallengeLease:
        _uuid(dataset_id, "datasetID")
        _uuid(sender_id, "senderID")
        if isinstance(ttl_seconds, bool) or not isinstance(ttl_seconds, int) or not 1 <= ttl_seconds <= 120:
            raise ReplicationError("invalidExpiry")
        now = int(time.time())
        expires_at = now + ttl_seconds
        nonce = secrets.token_bytes(32)
        nonce_hash = hashlib.sha256(nonce).hexdigest()
        session_id = str(uuid.uuid4())
        with self._transaction() as connection:
            connection.execute("DELETE FROM lifeos_replication_challenges WHERE expires_at < ?", (now,))
            connection.execute(
                "INSERT INTO lifeos_replication_challenges "
                "(nonce_hash, session_id, dataset_id, sender_id, expires_at, consumed, request_id, created_at) "
                "VALUES (?, ?, ?, ?, ?, 0, NULL, ?)",
                (nonce_hash, session_id, dataset_id, sender_id, expires_at, now),
            )
        return ChallengeLease(session_id, nonce, expires_at)

    def consume_challenge(
        self,
        dataset_id: str,
        sender_id: str,
        nonce: bytes,
        request_id: str,
        request_fingerprint: str,
    ) -> bool:
        _uuid(dataset_id, "datasetID")
        _uuid(sender_id, "senderID")
        _uuid(request_id, "requestID")
        _hash(request_fingerprint, "requestFingerprint")
        if not isinstance(nonce, bytes) or len(nonce) != 32:
            raise ReplicationError("nonceMismatch")
        now = int(time.time())
        nonce_hash = hashlib.sha256(nonce).hexdigest()
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT session_id, dataset_id, sender_id, expires_at, consumed, request_id, request_fingerprint "
                "FROM lifeos_replication_challenges WHERE nonce_hash = ?",
                (nonce_hash,),
            ).fetchone()
            if row is None or row[1] != dataset_id or row[2] != sender_id:
                raise ReplicationError("nonceMismatch")
            if int(row[3]) < now:
                raise ReplicationError("nonceExpired")
            if int(row[4]) == 1:
                if row[5] == request_id and row[6] == request_fingerprint:
                    return True
                raise ReplicationError("replay")
            connection.execute(
                "UPDATE lifeos_replication_challenges SET consumed = 1, request_id = ?, request_fingerprint = ? WHERE nonce_hash = ?",
                (request_id, request_fingerprint, nonce_hash),
            )
            return False

    def append(self, request: VerifiedExchange) -> ExchangeResult:
        self._validate_exchange(request)
        fingerprint = self._fingerprint(request)
        now = time.time_ns()
        with self._transaction() as connection:
            replay = connection.execute(
                "SELECT request_fingerprint, result_json FROM lifeos_replication_requests WHERE request_id = ?",
                (request.request_id,),
            ).fetchone()
            if replay is not None:
                if not secrets.compare_digest(str(replay[0]), fingerprint):
                    raise ReplicationError("idCollision")
                return _decode_result(str(replay[1]))

            self._authorize(connection, request.member_id, request.epoch)
            operation = connection.execute(
                "SELECT request_id FROM lifeos_replication_operations WHERE operation_id = ?",
                (request.operation_id,),
            ).fetchone()
            if operation is not None:
                raise ReplicationError("idCollision")

            receipt_id = secrets.token_hex(16)
            result = ExchangeResult(receipt_id, request.request_id, (request.operation_id,))
            connection.execute(
                "INSERT INTO lifeos_replication_operations "
                "(operation_id, dataset_id, stream_id, member_id, epoch, sequence, request_id, payload, body_hash, operation_hash, legacy, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    request.operation_id,
                    request.dataset_id,
                    request.stream_id,
                    request.member_id,
                    request.epoch,
                    0,
                    request.request_id,
                    request.payload,
                    request.body_hash,
                    None,
                    1,
                    now,
                ),
            )
            connection.execute(
                "INSERT INTO lifeos_replication_requests "
                "(request_id, request_fingerprint, receipt_id, result_json, created_at) VALUES (?, ?, ?, ?, ?)",
                (request.request_id, fingerprint, receipt_id, _json_result(result), now),
            )
            return result

    def exchange(
        self,
        request_id: str,
        request_fingerprint: str,
        dataset_id: str,
        sender_id: str,
        epoch: int,
        store_id: str,
        operations: tuple[ExchangeOperationInput, ...],
        acknowledgements: tuple[ExchangeAcknowledgementInput, ...],
        received: Mapping[str, int],
        upper: Mapping[str, int] | None,
        limit: int,
        ack_cursor_id: str,
    ) -> bytes:
        """Apply one authenticated SyncExchangeRequest atomically.

        Operation and acknowledgement signatures are verified by the gateway
        caller before this method runs. This method owns only durable replay,
        idempotent insertion, frontier projection, and bounded response
        construction under one SQLite writer transaction.
        """
        _uuid(request_id, "requestID")
        _hash(request_fingerprint, "requestFingerprint")
        _uuid(dataset_id, "datasetID")
        _uuid(sender_id, "senderID")
        _nonnegative(epoch, "epoch")
        _uuid(store_id, "storeID")
        _uuid(ack_cursor_id, "ackCursorID")
        if ack_cursor_id == sender_id:
            raise ReplicationError("invalidTrust")
        if len(operations) > MAX_EXCHANGE_ITEMS or len(acknowledgements) > MAX_EXCHANGE_ITEMS:
            raise ReplicationError("capacity")
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_EXCHANGE_ITEMS:
            raise ReplicationError("invalidLimit")
        for origin_id, through in received.items():
            _uuid(origin_id, "originID")
            _nonnegative(through, "through")
        if upper is not None:
            for origin_id, through in upper.items():
                _uuid(origin_id, "originID")
                _nonnegative(through, "through")
        fingerprint = hashlib.sha256(
            "\x1f".join((dataset_id, sender_id, str(epoch), store_id, request_fingerprint)).encode("utf-8")
        ).hexdigest()
        with self._transaction() as connection:
            self._authorize(connection, sender_id, epoch)
            if connection.execute(
                "SELECT 1 FROM lifeos_replication_recovery LIMIT 1"
            ).fetchone() is not None:
                raise ReplicationError("migrationRequired")
            now = time.time_ns()
            connection.execute(
                "DELETE FROM lifeos_replication_exchange_requests WHERE created_at < ?",
                (now - REPLAY_RETENTION_NS,),
            )
            replay = connection.execute(
                "SELECT request_fingerprint, response_body FROM lifeos_replication_exchange_requests "
                "WHERE request_id = ?",
                (request_id,),
            ).fetchone()
            if replay is not None:
                if not secrets.compare_digest(str(replay[0]), fingerprint):
                    raise ReplicationError("idCollision")
                return bytes(replay[1])

            if connection.execute(
                "SELECT 1 FROM lifeos_replication_operations "
                "WHERE dataset_id = ? AND stream_id = ? AND member_id = ? LIMIT 1",
                (dataset_id, store_id, ack_cursor_id),
            ).fetchone() is not None:
                raise ReplicationError("invalidTrust")
            if any(operation.origin_id == ack_cursor_id for operation in operations):
                raise ReplicationError("invalidTrust")

            results: list[dict[str, object]] = []
            for operation in operations:
                if (
                    operation.dataset_id != dataset_id
                    or operation.store_id != store_id
                    or operation.epoch != epoch
                ):
                    raise ReplicationError("membershipMismatch")
                _uuid(operation.operation_id, "operationID")
                _uuid(operation.origin_id, "originID")
                _nonnegative(operation.sequence, "sequence")
                _hash(operation.body_hash, "bodyHash")
                if not isinstance(operation.payload, bytes) or len(operation.payload) > MAX_PAYLOAD_BYTES:
                    raise ReplicationError("capacity")
                existing = connection.execute(
                    "SELECT body_hash, operation_hash, payload FROM lifeos_replication_operations WHERE operation_id = ?",
                    (operation.operation_id,),
                ).fetchone()
                if existing is not None:
                    if (
                        str(existing[0]) != operation.body_hash
                        or (existing[1] is not None and str(existing[1]) != operation.operation_hash)
                        or bytes(existing[2]) != operation.payload
                    ):
                        raise ReplicationError("idCollision")
                    results.append({"mutationID": operation.operation_id, "disposition": "alreadyStored", "error": None})
                    continue
                sequence_row = connection.execute(
                    "SELECT operation_id, body_hash, operation_hash, payload FROM lifeos_replication_operations "
                    "WHERE dataset_id = ? AND stream_id = ? AND member_id = ? AND sequence = ?",
                    (dataset_id, store_id, operation.origin_id, operation.sequence),
                ).fetchone()
                if sequence_row is not None:
                    if (
                        str(sequence_row[0]) != operation.operation_id
                        or str(sequence_row[1]) != operation.body_hash
                        or (sequence_row[2] is not None and str(sequence_row[2]) != operation.operation_hash)
                        or bytes(sequence_row[3]) != operation.payload
                    ):
                        raise ReplicationError("sequenceConflict")
                    results.append({"mutationID": operation.operation_id, "disposition": "alreadyStored", "error": None})
                    continue
                previous_sequence = connection.execute(
                    "SELECT COALESCE(sequence, 0) FROM lifeos_replication_stream_heads "
                    "WHERE dataset_id = ? AND stream_id = ? AND member_id = ?",
                    (dataset_id, store_id, operation.origin_id),
                ).fetchone()
                previous_through = int(previous_sequence[0]) if previous_sequence is not None else 0
                if previous_through + 1 != operation.sequence:
                    raise ReplicationError("sequenceGap")
                connection.execute(
                    "INSERT INTO lifeos_replication_operations "
                    "(operation_id, dataset_id, stream_id, member_id, epoch, sequence, request_id, payload, body_hash, operation_hash, legacy, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        operation.operation_id,
                        dataset_id,
                        store_id,
                        operation.origin_id,
                        epoch,
                        operation.sequence,
                        request_id,
                        operation.payload,
                        operation.body_hash,
                        operation.operation_hash,
                        0,
                        now,
                    ),
                )
                connection.execute(
                    "INSERT INTO lifeos_replication_stream_heads "
                    "(dataset_id, stream_id, member_id, sequence, updated_at) VALUES (?, ?, ?, ?, ?) "
                    "ON CONFLICT(dataset_id, stream_id, member_id) DO UPDATE SET "
                    "sequence = CASE WHEN excluded.sequence > sequence THEN excluded.sequence ELSE sequence END, "
                    "updated_at = excluded.updated_at",
                    (dataset_id, store_id, operation.origin_id, operation.sequence, now),
                )
                results.append({"mutationID": operation.operation_id, "disposition": "stored", "error": None})

            for acknowledgement in acknowledgements:
                if acknowledgement.dataset_id != dataset_id or acknowledgement.store_id != store_id:
                    raise ReplicationError("membershipMismatch")
                if acknowledgement.replica_id == ack_cursor_id:
                    raise ReplicationError("invalidTrust")
                _uuid(acknowledgement.mutation_id, "mutationID")
                _uuid(acknowledgement.replica_id, "replicaID")
                _hash(acknowledgement.operation_hash, "operationHash")
                _hash(acknowledgement.body_hash, "bodyHash")
                operation_row = connection.execute(
                    "SELECT operation_hash FROM lifeos_replication_operations WHERE operation_id = ?",
                    (acknowledgement.mutation_id,),
                ).fetchone()
                if operation_row is None:
                    raise ReplicationError("missingOperation")
                if operation_row[0] is None or str(operation_row[0]) != acknowledgement.operation_hash:
                    raise ReplicationError("hashMismatch")
                existing = connection.execute(
                    "SELECT operation_hash, body_hash, body, level FROM lifeos_replication_ack_state "
                    "WHERE dataset_id = ? AND store_id = ? AND mutation_id = ? AND replica_id = ?",
                    (dataset_id, store_id, acknowledgement.mutation_id, acknowledgement.replica_id),
                ).fetchone()
                if existing is not None:
                    if str(existing[0]) != acknowledgement.operation_hash:
                        raise ReplicationError("idCollision")
                    levels = {"stored": 0, "applied": 1, "retainedConflict": 1}
                    previous_level = str(existing[3])
                    next_level = acknowledgement.record.get("level")
                    if previous_level not in levels:
                        raise ReplicationError("corruptStore")
                    if not isinstance(next_level, str) or next_level not in levels:
                        raise ReplicationError("invalidLevel")
                    if str(existing[1]) == acknowledgement.body_hash and bytes(existing[2]) == acknowledgement.payload:
                        continue
                    if levels[next_level] < levels[previous_level]:
                        continue
                    if levels[next_level] == levels[previous_level]:
                        raise ReplicationError("idCollision")
                    connection.execute(
                        "UPDATE lifeos_replication_ack_state SET body = ?, body_hash = ?, level = ?, updated_at = ? "
                        "WHERE dataset_id = ? AND store_id = ? AND mutation_id = ? AND replica_id = ?",
                        (
                            acknowledgement.payload,
                            acknowledgement.body_hash,
                            next_level,
                            now,
                            dataset_id,
                            store_id,
                            acknowledgement.mutation_id,
                            acknowledgement.replica_id,
                        ),
                    )
                    connection.execute(
                        "INSERT INTO lifeos_replication_exchange_acks "
                        "(dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, created_at) "
                        "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                        (
                            dataset_id,
                            store_id,
                            acknowledgement.mutation_id,
                            acknowledgement.replica_id,
                            acknowledgement.operation_hash,
                            acknowledgement.payload,
                            acknowledgement.body_hash,
                            now,
                        ),
                    )
                    continue
                next_level = acknowledgement.record.get("level")
                if not isinstance(next_level, str) or next_level not in {"stored", "applied", "retainedConflict"}:
                    raise ReplicationError("invalidLevel")
                connection.execute(
                    "INSERT INTO lifeos_replication_ack_state "
                    "(dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, level, updated_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        dataset_id,
                        store_id,
                        acknowledgement.mutation_id,
                        acknowledgement.replica_id,
                        acknowledgement.operation_hash,
                        acknowledgement.payload,
                        acknowledgement.body_hash,
                        next_level,
                        now,
                    ),
                )
                connection.execute(
                    "INSERT INTO lifeos_replication_exchange_acks "
                    "(dataset_id, store_id, mutation_id, replica_id, operation_hash, body, body_hash, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        dataset_id,
                        store_id,
                        acknowledgement.mutation_id,
                        acknowledgement.replica_id,
                        acknowledgement.operation_hash,
                        acknowledgement.payload,
                        acknowledgement.body_hash,
                        now,
                    ),
                )

            incoming_ack_cursor = int(received.get(ack_cursor_id, 0))
            stored_cursor = connection.execute(
                "SELECT confirmed_through, issued_through FROM lifeos_replication_ack_cursors "
                "WHERE dataset_id = ? AND store_id = ? AND member_id = ?",
                (dataset_id, store_id, sender_id),
            ).fetchone()
            stored_confirmed = int(stored_cursor[0]) if stored_cursor is not None else 0
            issued_cursor = int(stored_cursor[1]) if stored_cursor is not None else 0
            if incoming_ack_cursor > issued_cursor:
                raise ReplicationError("invalidFrontier")
            durable_cursor = max(incoming_ack_cursor, stored_confirmed)
            connection.execute(
                "INSERT INTO lifeos_replication_ack_cursors "
                "(dataset_id, store_id, member_id, confirmed_through, issued_through, updated_at) VALUES (?, ?, ?, ?, ?, ?) "
                "ON CONFLICT(dataset_id, store_id, member_id) DO UPDATE SET "
                "confirmed_through = CASE WHEN excluded.confirmed_through > confirmed_through THEN excluded.confirmed_through ELSE confirmed_through END, "
                "issued_through = CASE WHEN excluded.issued_through > issued_through THEN excluded.issued_through ELSE issued_through END, "
                "updated_at = excluded.updated_at",
                (dataset_id, store_id, sender_id, durable_cursor, issued_cursor, now),
            )
            active_member_count = connection.execute(
                "SELECT COUNT(*) FROM lifeos_replication_members WHERE active = 1"
            ).fetchone()
            cursor_member_count = connection.execute(
                "SELECT COUNT(*) FROM lifeos_replication_ack_cursors c "
                "JOIN lifeos_replication_members m ON m.member_id = c.member_id "
                "WHERE c.dataset_id = ? AND c.store_id = ? AND m.active = 1",
                (dataset_id, store_id),
            ).fetchone()
            if int(active_member_count[0]) > 0 and int(cursor_member_count[0]) == int(active_member_count[0]):
                minimum_cursor = connection.execute(
                    "SELECT MIN(c.confirmed_through) FROM lifeos_replication_ack_cursors c "
                    "JOIN lifeos_replication_members m ON m.member_id = c.member_id "
                    "WHERE c.dataset_id = ? AND c.store_id = ? AND m.active = 1",
                    (dataset_id, store_id),
                ).fetchone()
                if minimum_cursor is not None and minimum_cursor[0] is not None:
                    connection.execute(
                        "DELETE FROM lifeos_replication_exchange_acks WHERE delivery_id <= ? "
                        "AND dataset_id = ? AND store_id = ?",
                        (int(minimum_cursor[0]), dataset_id, store_id),
                    )
            retained_ack_count = connection.execute(
                "SELECT COUNT(*) FROM lifeos_replication_exchange_acks WHERE dataset_id = ? AND store_id = ?",
                (dataset_id, store_id),
            ).fetchone()
            if int(retained_ack_count[0]) > MAX_RETAINED_ACKNOWLEDGEMENTS:
                raise ReplicationError("capacity")

            upper_rows = connection.execute(
                "SELECT member_id, sequence FROM lifeos_replication_stream_heads "
                "WHERE dataset_id = ? AND stream_id = ?",
                (dataset_id, store_id),
            ).fetchall()
            snapshot_upper = {str(row[0]): int(row[1]) for row in upper_rows}
            for origin_id, through in received.items():
                if origin_id == ack_cursor_id:
                    continue
                if through > snapshot_upper.get(origin_id, 0):
                    raise ReplicationError("invalidFrontier")
            if upper is not None:
                for origin_id, through in upper.items():
                    if origin_id == ack_cursor_id:
                        continue
                    if through > snapshot_upper.get(origin_id, 0):
                        raise ReplicationError("invalidFrontier")
                    if through < received.get(origin_id, 0):
                        raise ReplicationError("invalidFrontier")
            origin_rows = connection.execute(
                "SELECT member_id FROM lifeos_replication_stream_heads "
                "WHERE dataset_id = ? AND stream_id = ? ORDER BY member_id LIMIT 9",
                (dataset_id, store_id),
            ).fetchall()
            if len(origin_rows) > 8:
                raise ReplicationError("capacity")
            pending_rows: list[tuple[object, ...]] = []
            for origin_row in origin_rows:
                origin_id = str(origin_row[0])
                after = int(received.get(origin_id, 0))
                upper_bound = (
                    int(upper.get(origin_id, 0)) if upper is not None
                    else int(snapshot_upper.get(origin_id, 0))
                )
                if upper_bound <= after:
                    continue
                rows = connection.execute(
                    "SELECT row_id, operation_id, member_id, sequence, payload FROM lifeos_replication_operations "
                    "WHERE dataset_id = ? AND stream_id = ? AND member_id = ? AND legacy = 0 "
                    "AND sequence > ? AND sequence <= ? ORDER BY sequence LIMIT ?",
                    (dataset_id, store_id, origin_id, after, upper_bound, limit + 1),
                ).fetchall()
                pending_rows.extend(rows)

            def decode_operation_row(row: tuple[object, ...]) -> tuple[str, dict[str, object]]:
                try:
                    operation_id = str(row[1])
                    origin_id = str(row[2])
                    sequence = int(row[3])
                    record = json.loads(bytes(row[4]).decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise ReplicationError("corruptStore") from exc
                if (
                    not isinstance(record, dict)
                    or record.get("mutationID") != operation_id
                    or record.get("datasetID") != dataset_id
                    or record.get("storeID") != store_id
                    or record.get("originID") != origin_id
                    or record.get("sequence") != str(sequence)
                ):
                    raise ReplicationError("corruptStore")
                parents = record.get("parents")
                if (
                    not isinstance(parents, list)
                    or len(parents) > 8
                    or any(not isinstance(parent, str) for parent in parents)
                    or parents != sorted(set(parents))
                ):
                    raise ReplicationError("corruptStore")
                return operation_id, record

            pending_rows.sort(key=lambda row: (str(row[2]), int(row[3]), int(row[0])))
            rows_by_operation_id: dict[str, tuple[object, ...]] = {}
            records_by_operation_id: dict[str, dict[str, object]] = {}
            dependency_queue: list[str] = []
            queued_dependencies: set[str] = set()
            for row in pending_rows:
                operation_id, record = decode_operation_row(row)
                if operation_id in rows_by_operation_id:
                    raise ReplicationError("corruptStore")
                rows_by_operation_id[operation_id] = row
                records_by_operation_id[operation_id] = record
                for parent_id in record["parents"]:
                    if parent_id not in rows_by_operation_id and parent_id not in queued_dependencies:
                        dependency_queue.append(parent_id)
                        queued_dependencies.add(parent_id)

            covered_parent_ids: set[str] = set()
            visited_dependencies: set[str] = set()
            dependency_index = 0
            while dependency_index < len(dependency_queue) and len(visited_dependencies) < MAX_DEPENDENCY_ROWS:
                parent_id = dependency_queue[dependency_index]
                dependency_index += 1
                if parent_id in visited_dependencies or parent_id in records_by_operation_id:
                    continue
                visited_dependencies.add(parent_id)
                parent_row = connection.execute(
                    "SELECT row_id, operation_id, member_id, sequence, payload "
                    "FROM lifeos_replication_operations "
                    "WHERE dataset_id = ? AND stream_id = ? AND operation_id = ? AND legacy = 0",
                    (dataset_id, store_id, parent_id),
                ).fetchone()
                if parent_row is None:
                    continue
                parent_origin = str(parent_row[2])
                parent_sequence = int(parent_row[3])
                parent_after = int(received.get(parent_origin, 0))
                parent_upper = (
                    int(upper.get(parent_origin, 0))
                    if upper is not None
                    else int(snapshot_upper.get(parent_origin, 0))
                )
                if parent_sequence <= parent_after:
                    covered_parent_ids.add(parent_id)
                    continue
                if parent_sequence > parent_upper:
                    continue
                operation_id, record = decode_operation_row(parent_row)
                rows_by_operation_id[operation_id] = parent_row
                records_by_operation_id[operation_id] = record
                for dependency_id in record["parents"]:
                    if dependency_id not in rows_by_operation_id and dependency_id not in queued_dependencies:
                        dependency_queue.append(dependency_id)
                        queued_dependencies.add(dependency_id)

            all_rows = sorted(
                rows_by_operation_id.values(),
                key=lambda row: (str(row[2]), int(row[3]), int(row[0])),
            )
            selected_rows: list[tuple[object, ...]] = []
            selected_ids: set[str] = set()
            remaining_ids = set(rows_by_operation_id)
            while len(selected_rows) < limit:
                made_progress = False
                for row in all_rows:
                    operation_id = str(row[1])
                    if operation_id not in remaining_ids:
                        continue
                    record = records_by_operation_id[operation_id]
                    if all(
                        parent in selected_ids or parent in covered_parent_ids
                        for parent in record["parents"]
                    ):
                        selected_rows.append(row)
                        selected_ids.add(operation_id)
                        remaining_ids.remove(operation_id)
                        made_progress = True
                        break
                if not made_progress:
                    break

            candidate_rows = selected_rows
            remaining_rows = [row for row in all_rows if str(row[1]) in remaining_ids]
            candidate_operation_records = [records_by_operation_id[str(row[1])] for row in candidate_rows]
            ack_snapshot_row = connection.execute(
                "SELECT COALESCE(MAX(delivery_id), 0) FROM lifeos_replication_exchange_acks "
                "WHERE dataset_id = ? AND store_id = ?",
                (dataset_id, store_id),
            ).fetchone()
            ack_snapshot_upper = int(ack_snapshot_row[0])
            ack_rows = connection.execute(
                "SELECT delivery_id, body FROM lifeos_replication_exchange_acks "
                "WHERE dataset_id = ? AND store_id = ? AND delivery_id > ? AND delivery_id <= ? "
                "ORDER BY delivery_id LIMIT ?",
                (dataset_id, store_id, durable_cursor, ack_snapshot_upper, MAX_ACKNOWLEDGEMENTS_PER_PAGE + 1),
            ).fetchall()
            ack_more = len(ack_rows) > MAX_ACKNOWLEDGEMENTS_PER_PAGE
            ack_rows = ack_rows[:MAX_ACKNOWLEDGEMENTS_PER_PAGE]
            candidate_ack_records: list[dict[str, object]] = []
            for row in ack_rows:
                try:
                    record = json.loads(bytes(row[1]).decode("utf-8"))
                except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                    raise ReplicationError("corruptStore") from exc
                if not isinstance(record, dict):
                    raise ReplicationError("corruptStore")
                candidate_ack_records.append(record)

            def build_response(operation_count: int, acknowledgement_count: int) -> bytes:
                chosen_rows = candidate_rows[:operation_count]
                selected_sequences: dict[str, set[int]] = {}
                for row in chosen_rows:
                    origin_id = str(row[2])
                    selected_sequences.setdefault(origin_id, set()).add(int(row[3]))
                pending_after_page = candidate_rows[operation_count:] + remaining_rows
                positions_by_origin: dict[str, int] = {}
                all_origins = set(snapshot_upper) | set(received)
                if upper is not None:
                    all_origins |= set(upper)
                for origin_id in all_origins:
                    through = int(received.get(origin_id, 0))
                    selected = selected_sequences.get(origin_id, set())
                    while through < UINT64_MAX and through + 1 in selected:
                        through += 1
                    positions_by_origin[origin_id] = through
                selected_ack_rows = ack_rows[:acknowledgement_count]
                next_ack_cursor = durable_cursor
                if selected_ack_rows:
                    next_ack_cursor = int(selected_ack_rows[-1][0])
                positions_by_origin[ack_cursor_id] = next_ack_cursor
                positions = [
                    {
                        "stream": {"storeID": store_id, "originID": origin_id},
                        "through": str(through),
                    }
                    for origin_id, through in sorted(positions_by_origin.items())
                ]
                response = {
                    "schemaVersion": 1,
                    "storeID": store_id,
                    "results": results,
                    "operations": candidate_operation_records[:operation_count],
                    "acknowledgements": candidate_ack_records[:acknowledgement_count],
                    "upper": {"schemaVersion": 1, "positions": positions},
                    "more": bool(pending_after_page or ack_more or len(ack_rows) > acknowledgement_count),
                }
                return _canonical_frame_value(response)

            operation_count = 0
            for index in range(len(candidate_operation_records)):
                tentative = build_response(index + 1, 0)
                if len(tentative) > MAX_PAYLOAD_BYTES:
                    if index == 0:
                        raise ReplicationError("capacity")
                    break
                operation_count = index + 1
            acknowledgement_count = 0
            for index in range(len(candidate_ack_records)):
                tentative = build_response(operation_count, index + 1)
                if len(tentative) > MAX_PAYLOAD_BYTES:
                    if index == 0 and operation_count == 0:
                        raise ReplicationError("capacity")
                    break
                acknowledgement_count = index + 1
            response_body = build_response(operation_count, acknowledgement_count)
            if len(response_body) > MAX_PAYLOAD_BYTES:
                raise ReplicationError("capacity")
            selected_ack_rows = ack_rows[:acknowledgement_count]
            next_ack_cursor = durable_cursor
            if selected_ack_rows:
                next_ack_cursor = int(selected_ack_rows[-1][0])
            if next_ack_cursor > issued_cursor:
                connection.execute(
                    "UPDATE lifeos_replication_ack_cursors SET issued_through = ?, updated_at = ? "
                    "WHERE dataset_id = ? AND store_id = ? AND member_id = ?",
                    (next_ack_cursor, now, dataset_id, store_id, sender_id),
                )
                issued_cursor = next_ack_cursor
            replay_count, replay_bytes = connection.execute(
                "SELECT COUNT(*), COALESCE(SUM(length(response_body)), 0) "
                "FROM lifeos_replication_exchange_requests"
            ).fetchone()
            if int(replay_count) >= MAX_REPLAY_RECORDS or int(replay_bytes) + len(response_body) > MAX_REPLAY_BYTES:
                raise ReplicationError("capacity")
            connection.execute(
                "INSERT INTO lifeos_replication_exchange_requests "
                "(request_id, request_fingerprint, response_body, created_at) VALUES (?, ?, ?, ?)",
                (request_id, fingerprint, response_body, now),
            )
            return response_body

    def read_page(self, dataset_id: str, stream_id: str, after: int = 0, limit: int = 100) -> OperationPage:
        _identifier(dataset_id, "datasetID")
        _identifier(stream_id, "streamID")
        _nonnegative(after, "after")
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_PAGE_SIZE:
            raise ReplicationError("invalidLimit")
        with self._lock:
            rows = self._connection.execute(
                "SELECT row_id, operation_id, member_id, epoch, request_id, payload, body_hash "
                "FROM lifeos_replication_operations "
                "WHERE dataset_id = ? AND stream_id = ? AND row_id > ? "
                "ORDER BY row_id LIMIT ?",
                (dataset_id, stream_id, after, limit),
            ).fetchall()
        items = tuple(
            OperationRecord(
                operation_id=str(row[1]),
                dataset_id=dataset_id,
                stream_id=stream_id,
                member_id=str(row[2]),
                epoch=int(row[3]),
                request_id=str(row[4]),
                payload=bytes(row[5]),
                body_hash=str(row[6]),
            )
            for row in rows
        )
        return OperationPage(items, int(rows[-1][0]) if rows else after)

    def ack(self, receipt: VerifiedAck) -> None:
        _identifier(receipt.request_id, "requestID")
        _identifier(receipt.receipt_id, "receiptID")
        _identifier(receipt.dataset_id, "datasetID")
        _identifier(receipt.member_id, "memberID")
        _nonnegative(receipt.epoch, "epoch")
        with self._transaction() as connection:
            self._authorize(connection, receipt.member_id, receipt.epoch)
            row = connection.execute(
                "SELECT receipt_id, dataset_id, member_id, epoch FROM lifeos_replication_acks WHERE request_id = ?",
                (receipt.request_id,),
            ).fetchone()
            if row is not None:
                if tuple(row) != (receipt.receipt_id, receipt.dataset_id, receipt.member_id, receipt.epoch):
                    raise ReplicationError("idCollision")
                return
            connection.execute(
                "INSERT INTO lifeos_replication_acks "
                "(request_id, receipt_id, dataset_id, member_id, epoch, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    receipt.request_id,
                    receipt.receipt_id,
                    receipt.dataset_id,
                    receipt.member_id,
                    receipt.epoch,
                    time.time_ns(),
                ),
            )

    def has_ack(self, request_id: str) -> bool:
        _identifier(request_id, "requestID")
        with self._lock:
            return self._connection.execute(
                "SELECT 1 FROM lifeos_replication_acks WHERE request_id = ?", (request_id,)
            ).fetchone() is not None

    def checkpoint(self, request: CheckpointRequest) -> CheckpointReceipt:
        _identifier(request.request_id, "requestID")
        _identifier(request.dataset_id, "datasetID")
        _identifier(request.stream_id, "streamID")
        _identifier(request.member_id, "memberID")
        _hash(request.head_hash, "headHash")
        _nonnegative(request.epoch, "epoch")
        with self._transaction() as connection:
            self._authorize(connection, request.member_id, request.epoch)
            row = connection.execute(
                "SELECT dataset_id, stream_id, member_id, epoch, head_hash "
                "FROM lifeos_replication_checkpoints WHERE request_id = ?",
                (request.request_id,),
            ).fetchone()
            if row is not None:
                expected = (request.dataset_id, request.stream_id, request.member_id, request.epoch, request.head_hash)
                if tuple(row) != expected:
                    raise ReplicationError("idCollision")
                return CheckpointReceipt(request.request_id, *expected[:2], str(row[4]))
            connection.execute(
                "INSERT INTO lifeos_replication_checkpoints "
                "(request_id, dataset_id, stream_id, member_id, epoch, head_hash, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
                (
                    request.request_id,
                    request.dataset_id,
                    request.stream_id,
                    request.member_id,
                    request.epoch,
                    request.head_hash,
                    time.time_ns(),
                ),
            )
            return CheckpointReceipt(request.request_id, request.dataset_id, request.stream_id, request.head_hash)

    def stage_blob(
        self,
        blob_hash: str,
        total_bytes: int,
        offset: int,
        chunk_hash: str,
        chunk_bytes: int | None = None,
    ) -> int:
        _hash(blob_hash, "blobHash")
        _hash(chunk_hash, "chunkHash")
        _nonnegative(total_bytes, "totalBytes")
        _nonnegative(offset, "offset")
        if total_bytes > MAX_BLOB_BYTES or offset > total_bytes:
            raise ReplicationError("capacity")
        if chunk_bytes is None:
            chunk_bytes = total_bytes - offset
        _nonnegative(chunk_bytes, "chunkBytes")
        if chunk_bytes > MAX_BLOB_CHUNK_BYTES or offset + chunk_bytes > total_bytes:
            raise ReplicationError("capacity")
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT total_bytes, next_offset, last_chunk_offset, last_chunk_length, last_chunk_hash "
                "FROM lifeos_replication_blobs WHERE blob_hash = ?",
                (blob_hash,),
            ).fetchone()
            if row is None and offset != 0:
                raise ReplicationError("invalidOffset")
            if row is not None:
                if int(row[0]) != total_bytes:
                    raise ReplicationError("idCollision")
                if offset == int(row[2]):
                    if int(row[3]) == chunk_bytes and str(row[4]) == chunk_hash:
                        return int(row[1])
                    raise ReplicationError("idCollision")
                if offset != int(row[1]):
                    raise ReplicationError("invalidOffset")
            next_offset = offset + chunk_bytes
            connection.execute(
                "INSERT INTO lifeos_replication_blobs "
                "(blob_hash, total_bytes, next_offset, last_chunk_offset, last_chunk_length, last_chunk_hash, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(blob_hash) DO UPDATE SET "
                "next_offset=excluded.next_offset, last_chunk_offset=excluded.last_chunk_offset, "
                "last_chunk_length=excluded.last_chunk_length, last_chunk_hash=excluded.last_chunk_hash, "
                "updated_at=excluded.updated_at",
                (blob_hash, total_bytes, next_offset, offset, chunk_bytes, chunk_hash, time.time_ns()),
            )
            return next_offset

    def put_observation(
        self,
        dataset_id: str,
        origin_id: str,
        sequence: int,
        body_hash: str,
        body: bytes,
    ) -> bool:
        _identifier(dataset_id, "datasetID")
        _identifier(origin_id, "originID")
        _nonnegative(sequence, "sequence")
        _hash(body_hash, "bodyHash")
        if not isinstance(body, bytes) or len(body) > MAX_OBSERVATION_BYTES:
            raise ReplicationError("capacity")
        if not secrets.compare_digest(body_hash, _body_hash(body)):
            raise ReplicationError("bodyHashMismatch")
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT sequence, body_hash, body FROM lifeos_replication_observations WHERE dataset_id = ? AND origin_id = ?",
                (dataset_id, origin_id),
            ).fetchone()
            if row is not None:
                current_sequence = int(row[0])
                if sequence < current_sequence:
                    return False
                if sequence == current_sequence:
                    if str(row[1]) != body_hash or bytes(row[2]) != body:
                        raise ReplicationError("idCollision")
                    return False
            connection.execute(
                "INSERT INTO lifeos_replication_observations(dataset_id, origin_id, sequence, body_hash, body, updated_at) "
                "VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT(dataset_id, origin_id) DO UPDATE SET "
                "sequence=excluded.sequence, body_hash=excluded.body_hash, body=excluded.body, updated_at=excluded.updated_at",
                (dataset_id, origin_id, sequence, body_hash, body, time.time_ns()),
            )
            return True

    def get_observation(self, dataset_id: str, origin_id: str) -> ObservationRecord | None:
        _identifier(dataset_id, "datasetID")
        _identifier(origin_id, "originID")
        with self._lock:
            row = self._connection.execute(
                "SELECT sequence, body_hash, body FROM lifeos_replication_observations WHERE dataset_id = ? AND origin_id = ?",
                (dataset_id, origin_id),
            ).fetchone()
        if row is None:
            return None
        return ObservationRecord(dataset_id, origin_id, int(row[0]), str(row[1]), bytes(row[2]))
