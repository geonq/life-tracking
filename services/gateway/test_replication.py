import base64
import hashlib
import json
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
        _frame_signing_bytes,
        verify_signed_frame,
    )
except ModuleNotFoundError:
    from replication import (
        CheckpointRequest,
        ReplicationError,
        ReplicationStore,
        VerifiedAck,
        VerifiedExchange,
        _frame_signing_bytes,
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


class SignedFrameTests(unittest.TestCase):
    def encoded(self, frame: dict[str, object]) -> bytes:
        return json.dumps(frame, separators=(",", ":"), sort_keys=True).encode("utf-8")

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
