from __future__ import annotations

import json
import os
import stat
import tempfile
import unittest
from pathlib import Path

from scripts.clipper import hermes_uploader as uploader


class Response:
    def __init__(self, code: int = 204) -> None:
        self.code = code
        self.closed = False

    def getcode(self) -> int:
        return self.code

    def close(self) -> None:
        self.closed = True


class Opener:
    def __init__(self, response: Response | None = None) -> None:
        self.request = None
        self.timeout = None
        self.response = response or Response()

    def open(self, request, timeout):
        self.request = request
        self.timeout = timeout
        return self.response


class UploaderTests(unittest.TestCase):
    def test_endpoint_is_exact_loopback_route(self) -> None:
        self.assertEqual(uploader.validate_endpoint(uploader.DEFAULT_ENDPOINT), uploader.DEFAULT_ENDPOINT)
        for value in (
            "http://localhost:8787/api/clipper/ingest",
            "http://127.0.0.1:8787/api/clipper/ingest?token=secret",
            "https://127.0.0.1:8787/api/clipper/ingest",
            "http://127.0.0.1:8787/api/other",
        ):
            with self.assertRaises(uploader.ProtocolError):
                uploader.validate_endpoint(value)

    def test_post_is_bounded_private_and_deterministically_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            snapshot = root / "snapshot.json"
            secret = root / "secret"
            snapshot.write_text(json.dumps({"availability": "observed", "generatedAt": "now"}), encoding="utf-8")
            secret.write_text("s" * 32, encoding="ascii")
            os.chmod(snapshot, 0o600)
            os.chmod(secret, 0o600)
            opener = Opener()
            self.assertTrue(uploader.post_snapshot(snapshot, secret, opener=opener))
            self.assertEqual(opener.timeout, 5.0)
            self.assertEqual(opener.request.get_header("Idempotency-key"), "hermes-" + __import__("hashlib").sha256(json.dumps({"availability": "observed", "generatedAt": "now"}, sort_keys=True, separators=(",", ":")).encode()).hexdigest())
            self.assertEqual(stat.S_IMODE(secret.stat().st_mode), 0o600)
            self.assertTrue(opener.response.closed)


if __name__ == "__main__":
    unittest.main()
