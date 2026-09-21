import base64
import hashlib
import json
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from pathlib import Path

try:
    from services.gateway.replication import (
        CheckpointRequest,
        ExchangeAcknowledgementInput,
        ExchangeOperationInput,
        MAX_PAYLOAD_BYTES,
        ReplicationTrust,
        ReplicationError,
        ReplicationStore,
        TrustedMember,
        VerifiedAck,
        VerifiedExchange,
        _frame_signing_bytes,
        parse_exchange_request,
        verify_signed_frame,
    )
except ModuleNotFoundError:
    from replication import (
        CheckpointRequest,
        ExchangeAcknowledgementInput,
        ExchangeOperationInput,
        MAX_PAYLOAD_BYTES,
        ReplicationTrust,
        ReplicationError,
        ReplicationStore,
        TrustedMember,
        VerifiedAck,
        VerifiedExchange,
        _frame_signing_bytes,
        parse_exchange_request,
        verify_signed_frame,
    )


FRAME_DATASET = "11111111-1111-4111-8111-111111111111"
FRAME_ENDPOINT = "22222222-2222-4222-8222-222222222222"
FRAME_SENDER = "33333333-3333-4333-8333-333333333333"
FRAME_REQUEST = "44444444-4444-4444-8444-444444444444"


def signed_frame_fixture(payload: bytes = b"{}") -> dict[str, object]:
    encoded = base64.urlsafe_b64encode(payload).rstrip(b"=").decode("ascii")
    return {
        "schemaVersion": 1,
        "datasetID": FRAME_DATASET,
        "epoch": "7",
        "endpointID": FRAME_ENDPOINT,
        "senderID": FRAME_SENDER,
        "keyID": "a" * 64,
        "requestID": FRAME_REQUEST,
        "nonce": base64.urlsafe_b64encode(b"n" * 32).rstrip(b"=").decode("ascii"),
        "method": "POST",
        "path": "/replication/v1/exchange",
        "status": 0,
        "body": encoded,
        "bodyHash": hashlib.sha256(payload).hexdigest(),
        "signature": base64.urlsafe_b64encode(b"s" * 64).rstrip(b"=").decode("ascii"),
    }


def exchange(request_id: str, operation_id: str, payload: bytes = b"payload", epoch: int = 7) -> VerifiedExchange:
    return VerifiedExchange(
        request_id=request_id,
        dataset_id="dataset",
        stream_id="stream",
        member_id="member",
        epoch=epoch,
        operation_id=operation_id,
        payload=payload,
        body_hash=hashlib.sha256(payload).hexdigest(),
    )


class ReplicationStoreTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "replication.sqlite"
        self.store = ReplicationStore(self.path)
        self.store.register_member("member", 7)

    def tearDown(self) -> None:
        self.store.close()
        self.temp.cleanup()

    def test_migration_preserves_existing_table_and_reopen_is_durable(self) -> None:
        self.store.close()
        connection = sqlite3.connect(self.path)
        connection.execute("CREATE TABLE user_owned(value TEXT NOT NULL)")
        connection.execute("INSERT INTO user_owned VALUES ('kept')")
        connection.commit()
        connection.close()

        store = ReplicationStore(self.path)
        store.register_member("member", 7)
        result = store.append(exchange("request-1", "operation-1"))
        store.close()
        reopened = ReplicationStore(self.path)
        page = reopened.read_page("dataset", "stream")
        self.assertEqual(page.items[0].operation_id, "operation-1")
        self.assertEqual(page.items[0].payload, b"payload")
        self.assertEqual(reopened.read_page("dataset", "stream").next_after, 1)
        self.assertTrue(result.receipt_id)
        self.assertEqual(reopened._connection.execute("SELECT value FROM user_owned").fetchone()[0], "kept")
        reopened.close()
        self.store = ReplicationStore(self.path)

    def test_original_operations_schema_migrates_before_sequence_index_creation(self) -> None:
        self.store.close()
        legacy_path = Path(self.temp.name) / "legacy-operations.sqlite"
        connection = sqlite3.connect(legacy_path)
        connection.execute(
            """
            CREATE TABLE lifeos_replication_operations (
                row_id INTEGER PRIMARY KEY AUTOINCREMENT,
                operation_id TEXT NOT NULL UNIQUE,
                dataset_id TEXT NOT NULL,
                stream_id TEXT NOT NULL,
                member_id TEXT NOT NULL,
                epoch INTEGER NOT NULL,
                request_id TEXT NOT NULL,
                payload BLOB NOT NULL,
                body_hash TEXT NOT NULL,
                created_at INTEGER NOT NULL
            )
            """
        )
        connection.commit()
        connection.close()

        migrated = ReplicationStore(legacy_path)
        columns = {
            str(row[1])
            for row in migrated._connection.execute("PRAGMA table_info(lifeos_replication_operations)")
        }
        self.assertTrue({"sequence", "operation_hash", "legacy"}.issubset(columns))
        indexes = {
            str(row[1])
            for row in migrated._connection.execute("PRAGMA index_list(lifeos_replication_operations)")
        }
        self.assertIn("lifeos_replication_operations_stream_sequence", indexes)
        migrated.close()
        self.store = ReplicationStore(self.path)

    def test_legacy_cursor_table_is_rebuilt_and_untrusted_claim_is_reset(self) -> None:
        self.store.close()
        legacy_path = Path(self.temp.name) / "legacy-cursor.sqlite"
        connection = sqlite3.connect(legacy_path)
        connection.execute(
            """
            CREATE TABLE lifeos_replication_ack_cursors (
                dataset_id TEXT NOT NULL,
                store_id TEXT NOT NULL,
                member_id TEXT NOT NULL,
                through INTEGER NOT NULL,
                updated_at INTEGER NOT NULL,
                PRIMARY KEY(dataset_id, store_id, member_id)
            )
            """
        )
        connection.execute(
            "INSERT INTO lifeos_replication_ack_cursors VALUES (?, ?, ?, ?, ?)",
            (FRAME_DATASET, FRAME_ENDPOINT, FRAME_SENDER, 10_000, 1),
        )
        connection.commit()
        connection.close()

        store = ReplicationStore(legacy_path)
        columns = {
            str(row[1])
            for row in store._connection.execute("PRAGMA table_info(lifeos_replication_ack_cursors)")
        }
        self.assertNotIn("through", columns)
        self.assertEqual(
            store._connection.execute("SELECT COUNT(*) FROM lifeos_replication_ack_cursors").fetchone()[0],
            0,
        )
        self.assertTrue(store.has_recovery_required())
        store.register_member(FRAME_SENDER, 7, hashlib.sha256(b"k" * 32).hexdigest(), b"k" * 32)
        with self.assertRaisesRegex(ReplicationError, "migrationRequired"):
            store.exchange(
                "55555555-5555-4555-8555-555555555555", "a" * 64, FRAME_DATASET, FRAME_SENDER, 7,
                FRAME_ENDPOINT, (), (), {}, None, 128, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            )
        with self.assertRaisesRegex(ReplicationError, "migrationRequired"):
            store.exchange(
                "66666666-6666-4666-8666-666666666666", "b" * 64, FRAME_DATASET, FRAME_SENDER, 7,
                FRAME_ENDPOINT, (), (), {"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa": 1}, None, 128,
                "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            )
        store.close()
        self.store = ReplicationStore(self.path)

    def test_append_page_and_exact_replay(self) -> None:
        first = exchange("request-1", "operation-1")
        result = self.store.append(first)
        self.assertEqual(self.store.append(first), result)
        self.store.append(exchange("request-2", "operation-2", b"second"))
        page = self.store.read_page("dataset", "stream", limit=1)
        self.assertEqual([item.operation_id for item in page.items], ["operation-1"])
        page2 = self.store.read_page("dataset", "stream", after=page.next_after)
        self.assertEqual([item.operation_id for item in page2.items], ["operation-2"])

    def test_membership_reconciliation_deactivates_removed_devices(self) -> None:
        self.store.register_member("member-two", 7)
        self.store.reconcile_members({"member"})
        self.assertEqual(
            self.store._connection.execute(
                "SELECT active FROM lifeos_replication_members WHERE member_id = ?",
                ("member-two",),
            ).fetchone()[0],
            0,
        )

    def test_exchange_parser_accepts_swift_omitted_optional_fields(self) -> None:
        key_id = "a" * 64
        trust = ReplicationTrust(
            FRAME_DATASET,
            "7",
            FRAME_ENDPOINT,
            "s" * 64,
            b"s" * 32,
            (TrustedMember(FRAME_SENDER, key_id, b"k" * 32, True),),
        )
        operation = {
            "schemaVersion": 1,
            "datasetID": FRAME_DATASET,
            "epoch": "7",
            "storeID": FRAME_ENDPOINT,
            "domain": "calendar",
            "originID": FRAME_SENDER,
            "keyID": key_id,
            "sequence": "1",
            "mutationID": "55555555-5555-4555-8555-555555555555",
            "entityID": "e" * 64,
            "parents": [],
            "kind": "delete",
            "payload": {
                "schemaVersion": 1,
                "hash": hashlib.sha256(b"").hexdigest(),
                "byteCount": 0,
                "inline": "",
            },
            "signature": "ignored-by-patched-verifier",
        }
        request = {
            "schemaVersion": 1,
            "storeID": FRAME_ENDPOINT,
            "received": {"schemaVersion": 1, "positions": []},
            "operations": [operation],
            "acknowledgements": [],
            "limit": 128,
        }
        body = json.dumps(request, separators=(",", ":"), sort_keys=True).encode("utf-8")
        canonical = json.dumps(operation, separators=(",", ":"), sort_keys=True).encode("utf-8")
        with patch("services.gateway.replication._verify_detached_record", return_value=(canonical, b"signed")):
            parsed = parse_exchange_request(body, trust, sender_id=FRAME_SENDER)
        self.assertEqual(parsed[0], FRAME_ENDPOINT)
        self.assertIsNone(parsed[4])
        self.assertEqual(parsed[1][0].operation_id, operation["mutationID"])

    def test_conflicting_replay_and_stale_authority_are_rejected_without_effect(self) -> None:
        self.store.append(exchange("request-1", "operation-1"))
        conflicting = exchange("request-1", "operation-other", b"different")
        with self.assertRaisesRegex(ReplicationError, "idCollision"):
            self.store.append(conflicting)
        stale = exchange("request-2", "operation-2", epoch=8)
        with self.assertRaisesRegex(ReplicationError, "staleEpoch"):
            self.store.append(stale)
        self.assertEqual(len(self.store.read_page("dataset", "stream").items), 1)

    def test_ack_and_checkpoint_are_durable_and_idempotent(self) -> None:
        result = self.store.append(exchange("request-1", "operation-1"))
        ack = VerifiedAck("ack-1", result.receipt_id, "dataset", "member", 7)
        self.store.ack(ack)
        self.store.ack(ack)
        self.assertTrue(self.store.has_ack("ack-1"))
        checkpoint = CheckpointRequest("checkpoint-1", "dataset", "stream", "member", 7, "a" * 64)
        self.assertEqual(self.store.checkpoint(checkpoint).head_hash, "a" * 64)
        self.assertEqual(self.store.checkpoint(checkpoint).head_hash, "a" * 64)

    def test_caps_and_observation_sequence_idempotency(self) -> None:
        with self.assertRaisesRegex(ReplicationError, "invalidLimit"):
            self.store.read_page("dataset", "stream", limit=257)
        with self.assertRaisesRegex(ReplicationError, "capacity"):
            self.store.stage_blob("b" * 64, 33_554_433, 0, "c" * 64)
        blob_hash = "e" * 64
        chunk_hash = "f" * 64
        self.assertEqual(self.store.stage_blob(blob_hash, 4, 0, chunk_hash, 2), 2)
        self.assertEqual(self.store.stage_blob(blob_hash, 4, 0, chunk_hash, 2), 2)
        self.assertEqual(self.store.stage_blob(blob_hash, 4, 2, chunk_hash, 2), 4)
        with self.assertRaisesRegex(ReplicationError, "invalidOffset"):
            self.store.stage_blob(blob_hash, 4, 1, chunk_hash, 1)
        with self.assertRaisesRegex(ReplicationError, "invalidOffset"):
            self.store.stage_blob("1" * 64, 4, 1, chunk_hash, 1)
        with self.assertRaisesRegex(ReplicationError, "invalidAfter"):
            self.store.read_page("dataset", "stream", after=2**63)
        body = b"observation"
        body_hash = hashlib.sha256(body).hexdigest()
        self.assertTrue(self.store.put_observation("dataset", "origin", 1, body_hash, body))
        self.assertFalse(self.store.put_observation("dataset", "origin", 1, body_hash, body))
        self.assertFalse(self.store.put_observation("dataset", "origin", 0, body_hash, body))
        with self.assertRaisesRegex(ReplicationError, "idCollision"):
            self.store.put_observation("dataset", "origin", 1, hashlib.sha256(b"other").hexdigest(), b"other")
        self.assertEqual(self.store.get_observation("dataset", "origin").sequence, 1)

    def test_challenge_is_durable_single_use_and_request_replay_bound(self) -> None:
        dataset_id = FRAME_DATASET
        sender_id = FRAME_SENDER
        request_id = FRAME_REQUEST
        second_request_id = "55555555-5555-4555-8555-555555555555"
        lease = self.store.issue_challenge(dataset_id, sender_id)
        fingerprint = hashlib.sha256(b"frame").hexdigest()
        self.assertEqual(self.store.consume_challenge(dataset_id, sender_id, lease.nonce, request_id, fingerprint), False)
        self.assertEqual(self.store.consume_challenge(dataset_id, sender_id, lease.nonce, request_id, fingerprint), True)
        with self.assertRaisesRegex(ReplicationError, "replay"):
            self.store.consume_challenge(dataset_id, sender_id, lease.nonce, second_request_id, fingerprint)

    def test_exchange_persists_operations_and_replays_exact_response(self) -> None:
        dataset_id = FRAME_DATASET
        sender_id = FRAME_SENDER
        store_id = FRAME_ENDPOINT
        request_id = FRAME_REQUEST
        operation_id = "55555555-5555-4555-8555-555555555555"
        record = {
            "mutationID": operation_id,
            "datasetID": dataset_id,
            "storeID": store_id,
            "originID": sender_id,
            "epoch": "7",
            "sequence": "1",
            "parents": [],
        }
        payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
        self.store.register_member(sender_id, 7, hashlib.sha256(b"k" * 32).hexdigest(), b"k" * 32)
        operation = ExchangeOperationInput(
            operation_id=operation_id,
            dataset_id=dataset_id,
            store_id=store_id,
            origin_id=sender_id,
            epoch=7,
            sequence=1,
            operation_hash=hashlib.sha256(b"operation-signing-bytes").hexdigest(),
            payload=payload,
            body_hash=hashlib.sha256(payload).hexdigest(),
            record=record,
        )
        response = self.store.exchange(
            request_id,
            hashlib.sha256(b"request").hexdigest(),
            dataset_id,
            sender_id,
            7,
            store_id,
            (operation,),
            (),
            {},
            None,
            128,
            store_id,
        )
        self.assertEqual(json.loads(response)["results"][0]["disposition"], "stored")
        self.assertEqual(self.store.exchange(
            request_id,
            hashlib.sha256(b"request").hexdigest(),
            dataset_id,
            sender_id,
            7,
            store_id,
            (operation,),
            (),
            {},
            None,
            128,
            store_id,
        ), response)

    def test_exchange_rejects_sequence_gaps_and_revoked_replays(self) -> None:
        dataset_id = FRAME_DATASET
        sender_id = FRAME_SENDER
        store_id = FRAME_ENDPOINT
        self.store.register_member(sender_id, 7, hashlib.sha256(b"k" * 32).hexdigest(), b"k" * 32)

        def operation(operation_id: str, sequence: int) -> ExchangeOperationInput:
            record = {
                "mutationID": operation_id,
                "datasetID": dataset_id,
                "storeID": store_id,
                "originID": sender_id,
                "epoch": "7",
                "sequence": str(sequence),
                "parents": [],
            }
            payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
            return ExchangeOperationInput(
                operation_id=operation_id,
                dataset_id=dataset_id,
                store_id=store_id,
                origin_id=sender_id,
                epoch=7,
                sequence=sequence,
                operation_hash=hashlib.sha256(f"operation-{sequence}".encode()).hexdigest(),
                payload=payload,
                body_hash=hashlib.sha256(payload).hexdigest(),
                record=record,
            )

        request_one = "55555555-5555-4555-8555-555555555555"
        request_two = "66666666-6666-4666-8666-666666666666"
        with self.assertRaisesRegex(ReplicationError, "sequenceGap"):
            self.store.exchange(
                request_one, "a" * 64, dataset_id, sender_id, 7, store_id,
                (operation("77777777-7777-4777-8777-777777777777", 2),), (), {}, None, 128, store_id,
            )
        self.store.exchange(
            request_one, "a" * 64, dataset_id, sender_id, 7, store_id,
            (operation("77777777-7777-4777-8777-777777777777", 1),), (), {}, None, 128, store_id,
        )
        self.store.exchange(
            request_two, "b" * 64, dataset_id, sender_id, 7, store_id,
            (operation("88888888-8888-4888-8888-888888888888", 2),), (), {}, None, 128, store_id,
        )
        with self.assertRaisesRegex(ReplicationError, "sequenceConflict"):
            self.store.exchange(
                "99999999-9999-4999-8999-999999999999", "c" * 64, dataset_id, sender_id, 7, store_id,
                (operation("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", 2),), (), {}, None, 128, store_id,
            )
        self.store.revoke_member(sender_id)
        with self.assertRaisesRegex(ReplicationError, "authorizationDenied"):
            self.store.exchange(
                request_two, "b" * 64, dataset_id, sender_id, 7, store_id,
                (operation("88888888-8888-4888-8888-888888888888", 2),), (), {}, None, 128, store_id,
            )

    def test_exchange_allows_acknowledgement_progression_for_known_operation(self) -> None:
        dataset_id = FRAME_DATASET
        sender_id = FRAME_SENDER
        store_id = FRAME_ENDPOINT
        operation_id = "55555555-5555-4555-8555-555555555555"
        self.store.register_member(sender_id, 7, hashlib.sha256(b"k" * 32).hexdigest(), b"k" * 32)
        operation_record = {
            "mutationID": operation_id,
            "datasetID": dataset_id,
            "storeID": store_id,
            "originID": sender_id,
            "epoch": "7",
            "sequence": "1",
            "parents": [],
        }
        operation_payload = json.dumps(operation_record, separators=(",", ":"), sort_keys=True).encode("utf-8")
        operation_hash = "a" * 64
        operation = ExchangeOperationInput(
            operation_id=operation_id, dataset_id=dataset_id, store_id=store_id, origin_id=sender_id,
            epoch=7, sequence=1, operation_hash=operation_hash, payload=operation_payload,
            body_hash=hashlib.sha256(operation_payload).hexdigest(), record=operation_record,
        )
        self.store.exchange(
            "66666666-6666-4666-8666-666666666666", "a" * 64, dataset_id, sender_id, 7, store_id,
            (operation,), (), {}, None, 128, store_id,
        )

        def acknowledgement(level: str, result_hash: str) -> ExchangeAcknowledgementInput:
            record = {"mutationID": operation_id, "level": level, "resultHash": result_hash}
            payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
            return ExchangeAcknowledgementInput(
                mutation_id=operation_id, dataset_id=dataset_id, store_id=store_id, replica_id=sender_id,
                operation_hash=operation_hash, payload=payload, body_hash=hashlib.sha256(payload).hexdigest(),
                record=record,
            )

        stored = acknowledgement("stored", "b" * 64)
        self.store.exchange(
            "77777777-7777-4777-8777-777777777777", "b" * 64, dataset_id, sender_id, 7, store_id,
            (), (stored,), {}, None, 128, store_id,
        )
        stored_response = self.store.exchange(
            "99999999-9999-4999-8999-999999999999", "d" * 64, dataset_id, sender_id, 7, store_id,
            (), (), {}, None, 128, store_id,
        )
        stored_decoded = json.loads(stored_response)
        ack_cursor = next(
            item["through"]
            for item in stored_decoded["upper"]["positions"]
            if item["stream"]["originID"] == store_id
        )
        applied = acknowledgement("applied", "c" * 64)
        response = self.store.exchange(
            "88888888-8888-4888-8888-888888888888", "c" * 64, dataset_id, sender_id, 7, store_id,
            (), (applied,), {store_id: int(ack_cursor)}, None, 128, store_id,
        )
        self.assertEqual(json.loads(response)["acknowledgements"][0]["level"], "applied")

    def test_exchange_keeps_large_pages_bounded_and_preserves_supplied_upper(self) -> None:
        dataset_id = FRAME_DATASET
        sender_id = FRAME_SENDER
        store_id = FRAME_ENDPOINT
        ack_cursor_id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
        self.store.register_member(sender_id, 7, hashlib.sha256(b"k" * 32).hexdigest(), b"k" * 32)

        operations = []
        for sequence in range(1, 14):
            operation_id = f"00000000-0000-4000-8000-{sequence:012d}"
            record = {
                "mutationID": operation_id,
                "datasetID": dataset_id,
                "storeID": store_id,
                "originID": sender_id,
                "epoch": "7",
                "sequence": str(sequence),
                "parents": [],
                "padding": "x" * 87_000,
            }
            payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
            operations.append(ExchangeOperationInput(
                operation_id=operation_id, dataset_id=dataset_id, store_id=store_id, origin_id=sender_id,
                epoch=7, sequence=sequence, operation_hash=hashlib.sha256(f"op-{sequence}".encode()).hexdigest(),
                payload=payload, body_hash=hashlib.sha256(payload).hexdigest(), record=record,
            ))
        response = self.store.exchange(
            "00000000-0000-4000-8000-000000000001", "a" * 64, dataset_id, sender_id, 7, store_id,
            tuple(operations), (), {}, None, 128, ack_cursor_id,
        )
        decoded = json.loads(response)
        self.assertLessEqual(len(response), MAX_PAYLOAD_BYTES)
        self.assertTrue(decoded["more"])
        operation_position = next(
            item for item in decoded["upper"]["positions"]
            if item["stream"]["originID"] == sender_id
        )
        self.assertLess(operation_position["through"], "13")

        with self.assertRaisesRegex(ReplicationError, "invalidFrontier"):
            self.store.exchange(
                "00000000-0000-4000-8000-000000000003", "c" * 64, dataset_id, sender_id, 7, store_id,
                (), (), {ack_cursor_id: 1}, None, 128, ack_cursor_id,
            )

        response_upper = {
            item["stream"]["originID"]: int(item["through"])
            for item in decoded["upper"]["positions"]
        }
        bounded = self.store.exchange(
            "00000000-0000-4000-8000-000000000002", "b" * 64, dataset_id, sender_id, 7, store_id,
            (), (), {sender_id: int(operation_position["through"])}, response_upper, 128, ack_cursor_id,
        )
        self.assertLessEqual(len(bounded), MAX_PAYLOAD_BYTES)

    def test_exchange_delivers_cross_origin_parent_before_large_child_page(self) -> None:
        dataset_id = FRAME_DATASET
        store_id = FRAME_ENDPOINT
        child_origin = "10000000-0000-4000-8000-000000000001"
        parent_origin = "20000000-0000-4000-8000-000000000001"
        ack_cursor_id = "30000000-0000-4000-8000-000000000001"
        parent_id = "40000000-0000-4000-8000-000000000001"
        self.store.register_member(child_origin, 7, hashlib.sha256(b"c" * 32).hexdigest(), b"c" * 32)
        self.store.register_member(parent_origin, 7, hashlib.sha256(b"p" * 32).hexdigest(), b"p" * 32)

        def operation(origin_id: str, operation_id: str, sequence: int, parents: list[str]) -> ExchangeOperationInput:
            record = {
                "mutationID": operation_id,
                "datasetID": dataset_id,
                "storeID": store_id,
                "originID": origin_id,
                "epoch": "7",
                "sequence": str(sequence),
                "parents": parents,
            }
            payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
            return ExchangeOperationInput(
                operation_id=operation_id,
                dataset_id=dataset_id,
                store_id=store_id,
                origin_id=origin_id,
                epoch=7,
                sequence=sequence,
                operation_hash=hashlib.sha256(operation_id.encode()).hexdigest(),
                payload=payload,
                body_hash=hashlib.sha256(payload).hexdigest(),
                record=record,
            )

        parent = operation(parent_origin, parent_id, 1, [])
        self.store.exchange(
            "50000000-0000-4000-8000-000000000001", "a" * 64, dataset_id, parent_origin, 7, store_id,
            (parent,), (), {}, None, 128, ack_cursor_id,
        )
        children = tuple(
            operation(
                child_origin,
                f"60000000-0000-4000-8000-{sequence:012d}",
                sequence,
                [parent_id],
            )
            for sequence in range(1, 129)
        )
        first_response = json.loads(self.store.exchange(
            "50000000-0000-4000-8000-000000000002", "b" * 64, dataset_id, child_origin, 7, store_id,
            children, (), {}, None, 128, ack_cursor_id,
        ))
        first_ids = [record["mutationID"] for record in first_response["operations"]]
        self.assertEqual(first_ids[0], parent_id)
        self.assertIn(parent_id, first_ids)
        self.assertTrue(first_response["more"])

        self.store.close()
        self.store = ReplicationStore(self.path)
        received = {
            item["stream"]["originID"]: int(item["through"])
            for item in first_response["upper"]["positions"]
        }
        second_response = json.loads(self.store.exchange(
            "50000000-0000-4000-8000-000000000003", "c" * 64, dataset_id, child_origin, 7, store_id,
            (), (), received, None, 128, ack_cursor_id,
        ))
        second_ids = [record["mutationID"] for record in second_response["operations"]]
        self.assertEqual(second_ids, [children[-1].operation_id])

    def test_exchange_dependency_budget_preserves_contiguous_child_progress(self) -> None:
        dataset_id = FRAME_DATASET
        store_id = FRAME_ENDPOINT
        child_origin = "11000000-0000-4000-8000-000000000001"
        parent_origin = "20000000-0000-4000-8000-000000000001"
        ack_cursor_id = "99000000-0000-4000-8000-000000000001"
        parent_ids = [f"70000000-0000-4000-8000-{index:012d}" for index in range(1, 9)]
        for origin_id in [child_origin, parent_origin]:
            public_key = origin_id.encode()[:32].ljust(32, b"k")
            self.store.register_member(origin_id, 7, hashlib.sha256(public_key).hexdigest(), public_key)

        def operation(origin_id: str, operation_id: str, sequence: int, parents: list[str]) -> ExchangeOperationInput:
            record = {
                "mutationID": operation_id,
                "datasetID": dataset_id,
                "storeID": store_id,
                "originID": origin_id,
                "epoch": "7",
                "sequence": str(sequence),
                "parents": parents,
            }
            payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
            return ExchangeOperationInput(
                operation_id=operation_id,
                dataset_id=dataset_id,
                store_id=store_id,
                origin_id=origin_id,
                epoch=7,
                sequence=sequence,
                operation_hash=hashlib.sha256(operation_id.encode()).hexdigest(),
                payload=payload,
                body_hash=hashlib.sha256(payload).hexdigest(),
                record=record,
            )

        for index, operation_id in enumerate(parent_ids, start=1):
            self.store.exchange(
                f"80000000-0000-4000-8000-{index:012d}", "a" * 64, dataset_id, parent_origin, 7, store_id,
                (operation(parent_origin, operation_id, index, []),), (), {}, None, 128, ack_cursor_id,
            )
        children = tuple(
            operation(
                child_origin,
                f"60000000-0000-4000-8000-{sequence:012d}",
                sequence,
                sorted(parent_ids),
            )
            for sequence in range(1, 129)
        )
        received = {parent_origin: 8}
        response = json.loads(self.store.exchange(
            "81000000-0000-4000-8000-000000000001", "b" * 64, dataset_id, child_origin, 7, store_id,
            children, (), received, None, 128, ack_cursor_id,
        ))
        self.assertEqual(
            [record["mutationID"] for record in response["operations"]],
            [child.operation_id for child in children],
        )
        self.assertFalse(response["more"])
        self.assertEqual(
            next(item["through"] for item in response["upper"]["positions"] if item["stream"]["originID"] == child_origin),
            "128",
        )

    def test_exchange_frontier_never_skips_blocked_sequence(self) -> None:
        dataset_id = FRAME_DATASET
        store_id = FRAME_ENDPOINT
        sender_id = "12000000-0000-4000-8000-000000000001"
        ack_cursor_id = "99000000-0000-4000-8000-000000000002"
        self.store.register_member(sender_id, 7, hashlib.sha256(b"s" * 32).hexdigest(), b"s" * 32)
        missing_parent = "13000000-0000-4000-8000-000000000001"

        def operation(operation_id: str, sequence: int, parents: list[str]) -> ExchangeOperationInput:
            record = {
                "mutationID": operation_id,
                "datasetID": dataset_id,
                "storeID": store_id,
                "originID": sender_id,
                "epoch": "7",
                "sequence": str(sequence),
                "parents": parents,
            }
            payload = json.dumps(record, separators=(",", ":"), sort_keys=True).encode("utf-8")
            return ExchangeOperationInput(
                operation_id=operation_id,
                dataset_id=dataset_id,
                store_id=store_id,
                origin_id=sender_id,
                epoch=7,
                sequence=sequence,
                operation_hash=hashlib.sha256(operation_id.encode()).hexdigest(),
                payload=payload,
                body_hash=hashlib.sha256(payload).hexdigest(),
                record=record,
            )

        first_id = "14000000-0000-4000-8000-000000000001"
        second_id = "14000000-0000-4000-8000-000000000002"
        first = operation(first_id, 1, [missing_parent])
        second = operation(second_id, 2, [])
        response = json.loads(self.store.exchange(
            "82000000-0000-4000-8000-000000000001", "c" * 64, dataset_id, sender_id, 7, store_id,
            (first, second), (), {}, None, 128, ack_cursor_id,
        ))
        self.assertEqual([record["mutationID"] for record in response["operations"]], [second_id])
        self.assertEqual(
            next(item["through"] for item in response["upper"]["positions"] if item["stream"]["originID"] == sender_id),
            "0",
        )
        self.assertTrue(response["more"])
        replay = json.loads(self.store.exchange(
            "82000000-0000-4000-8000-000000000002", "d" * 64, dataset_id, sender_id, 7, store_id,
            (), (), {sender_id: 0}, None, 128, ack_cursor_id,
        ))
        self.assertEqual([record["mutationID"] for record in replay["operations"]], [second_id])


class SignedFrameTests(unittest.TestCase):
    def encoded(self, frame: dict[str, object]) -> bytes:
        return json.dumps(frame, separators=(",", ":"), sort_keys=True).encode("utf-8")

    def test_frame_signing_bytes_match_foundation_solidus_escaping(self) -> None:
        signing = _frame_signing_bytes(signed_frame_fixture())
        self.assertIn(b'"path":"\\/replication\\/v1\\/exchange"', signing)
        self.assertNotIn(b'"path":"/replication/v1/exchange"', signing)

    def test_frame_rejects_shape_hash_route_and_body_bounds_before_crypto(self) -> None:
        unknown = signed_frame_fixture()
        unknown["extra"] = True
        with self.assertRaisesRegex(ReplicationError, "invalidKeys"):
            verify_signed_frame(self.encoded(unknown), b"k" * 32)

        wrong_hash = signed_frame_fixture()
        wrong_hash["bodyHash"] = "b" * 64
        with self.assertRaisesRegex(ReplicationError, "bodyHashMismatch"):
            verify_signed_frame(self.encoded(wrong_hash), b"k" * 32)

        with self.assertRaisesRegex(ReplicationError, "routeMismatch"):
            verify_signed_frame(
                self.encoded(signed_frame_fixture()),
                b"k" * 32,
                expected_path="/replication/v1/ack",
            )

        invalid_nonce = signed_frame_fixture()
        invalid_nonce["nonce"] = invalid_nonce["nonce"] + "="
        with self.assertRaisesRegex(ReplicationError, "invalidNonce"):
            verify_signed_frame(self.encoded(invalid_nonce), b"k" * 32)

        invalid_epoch = signed_frame_fixture()
        invalid_epoch["epoch"] = "01"
        with self.assertRaisesRegex(ReplicationError, "invalidEpoch"):
            verify_signed_frame(self.encoded(invalid_epoch), b"k" * 32)

        oversized_epoch = signed_frame_fixture()
        oversized_epoch["epoch"] = "9" * 5_000
        with self.assertRaisesRegex(ReplicationError, "invalidEpoch"):
            verify_signed_frame(self.encoded(oversized_epoch), b"k" * 32)

        numeric_schema = signed_frame_fixture()
        numeric_schema["schemaVersion"] = True
        with self.assertRaisesRegex(ReplicationError, "invalidFrame"):
            verify_signed_frame(self.encoded(numeric_schema), b"k" * 32)

        invalid_path = signed_frame_fixture()
        invalid_path["path"] = "/replication/v1/unknown"
        with self.assertRaisesRegex(ReplicationError, "invalidPath"):
            verify_signed_frame(self.encoded(invalid_path), b"k" * 32)

        surrogate_path = signed_frame_fixture()
        surrogate_path["path"] = "\ud800"
        with self.assertRaisesRegex(ReplicationError, "invalidPath"):
            verify_signed_frame(self.encoded(surrogate_path), b"k" * 32)

        negative_zero = self.encoded(signed_frame_fixture()).replace(b'"status":0', b'"status":-0')
        with self.assertRaisesRegex(ReplicationError, "invalidFrame"):
            verify_signed_frame(negative_zero, b"k" * 32)

        oversized = signed_frame_fixture(b"12345")
        with self.assertRaisesRegex(ReplicationError, "capacity"):
            verify_signed_frame(self.encoded(oversized), b"k" * 32, maximum_body_bytes=4)

    def test_valid_frame_requires_crypto_when_runtime_dependency_is_missing(self) -> None:
        frame = signed_frame_fixture()
        try:
            import cryptography  # noqa: F401
        except ImportError:
            with self.assertRaisesRegex(ReplicationError, "cryptoUnavailable"):
                verify_signed_frame(self.encoded(frame), b"k" * 32)

    @unittest.skipUnless(
        __import__("importlib.util").util.find_spec("cryptography") is not None,
        "cryptography is provided by the Windows runtime, not this Mac test environment",
    )
    def test_real_ed25519_frame_vector(self) -> None:
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        private_key = Ed25519PrivateKey.generate()
        frame = signed_frame_fixture(b"hello")
        frame["signature"] = base64.urlsafe_b64encode(
            private_key.sign(_frame_signing_bytes(frame))
        ).rstrip(b"=").decode("ascii")
        verified = verify_signed_frame(
            self.encoded(frame),
            private_key.public_key().public_bytes_raw(),
            expected_dataset_id=FRAME_DATASET,
            expected_endpoint_id=FRAME_ENDPOINT,
            expected_epoch="7",
            expected_path="/replication/v1/exchange",
        )
        self.assertEqual(verified.body, b"hello")


if __name__ == "__main__":
    unittest.main()
