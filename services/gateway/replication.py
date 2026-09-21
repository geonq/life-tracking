"""Bounded, durable replication primitives used by the LifeOS gateway.

This module deliberately stops at an already-verified boundary.  HTTP framing,
signature verification, and platform key custody belong to the callers.  The
store only accepts typed records whose caller has already authenticated them,
then makes their effects durable and idempotent.
"""

from __future__ import annotations

import hashlib
import json
import re
import secrets
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Final, Iterable


MAX_PAYLOAD_BYTES: Final = 1_048_576
MAX_PAGE_SIZE: Final = 256
MAX_BLOB_BYTES: Final = 33_554_432
MAX_BLOB_CHUNK_BYTES: Final = 262_144
MAX_OBSERVATION_BYTES: Final = 131_072
MAX_IDENTIFIER_BYTES: Final = 256
SQLITE_MAX_INTEGER: Final = 2**63 - 1
_HASH_RE = re.compile(r"^[0-9a-f]{64}$")
_IDENTIFIER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,255}$")


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

    _SCHEMA_VERSION = 2

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
                        active INTEGER NOT NULL CHECK (active IN (0, 1))
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
                        request_id TEXT NOT NULL,
                        payload BLOB NOT NULL,
                        body_hash TEXT NOT NULL,
                        created_at INTEGER NOT NULL
                    )
                    """,
                    """
                    CREATE INDEX IF NOT EXISTS lifeos_replication_operations_page
                        ON lifeos_replication_operations(dataset_id, stream_id, row_id);
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

    def register_member(self, member_id: str, epoch: int) -> None:
        _identifier(member_id, "memberID")
        _nonnegative(epoch, "epoch")
        with self._transaction() as connection:
            connection.execute(
                "INSERT INTO lifeos_replication_members(member_id, epoch, active) VALUES (?, ?, 1) "
                "ON CONFLICT(member_id) DO UPDATE SET epoch=excluded.epoch, active=1",
                (member_id, epoch),
            )

    def revoke_member(self, member_id: str) -> None:
        _identifier(member_id, "memberID")
        with self._transaction() as connection:
            connection.execute(
                "UPDATE lifeos_replication_members SET active = 0 WHERE member_id = ?",
                (member_id,),
            )

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
                "(operation_id, dataset_id, stream_id, member_id, epoch, request_id, payload, body_hash, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    request.operation_id,
                    request.dataset_id,
                    request.stream_id,
                    request.member_id,
                    request.epoch,
                    request.request_id,
                    request.payload,
                    request.body_hash,
                    now,
                ),
            )
            connection.execute(
                "INSERT INTO lifeos_replication_requests "
                "(request_id, request_fingerprint, receipt_id, result_json, created_at) VALUES (?, ?, ?, ?, ?)",
                (request.request_id, fingerprint, receipt_id, _json_result(result), now),
            )
            return result

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
