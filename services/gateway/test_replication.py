import hashlib
import sqlite3
import tempfile
import unittest
from pathlib import Path

try:
    from services.gateway.replication import (
        CheckpointRequest,
        ReplicationError,
        ReplicationStore,
        VerifiedAck,
        VerifiedExchange,
    )
except ModuleNotFoundError:
    from replication import CheckpointRequest, ReplicationError, ReplicationStore, VerifiedAck, VerifiedExchange


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

    def test_append_page_and_exact_replay(self) -> None:
        first = exchange("request-1", "operation-1")
        result = self.store.append(first)
        self.assertEqual(self.store.append(first), result)
        self.store.append(exchange("request-2", "operation-2", b"second"))
        page = self.store.read_page("dataset", "stream", limit=1)
        self.assertEqual([item.operation_id for item in page.items], ["operation-1"])
        page2 = self.store.read_page("dataset", "stream", after=page.next_after)
        self.assertEqual([item.operation_id for item in page2.items], ["operation-2"])

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
        body = b"observation"
        body_hash = hashlib.sha256(body).hexdigest()
        self.assertTrue(self.store.put_observation("dataset", "origin", 1, body_hash, body))
        self.assertFalse(self.store.put_observation("dataset", "origin", 1, body_hash, body))
        self.assertFalse(self.store.put_observation("dataset", "origin", 0, body_hash, body))
        with self.assertRaisesRegex(ReplicationError, "idCollision"):
            self.store.put_observation("dataset", "origin", 1, hashlib.sha256(b"other").hexdigest(), b"other")
        self.assertEqual(self.store.get_observation("dataset", "origin").sequence, 1)


if __name__ == "__main__":
    unittest.main()
