from __future__ import annotations

import io
import json
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path
from unittest import mock
from urllib.error import HTTPError

from scripts.usage import claude_statusline_collector as collector
from scripts.usage import claude_usage_uploader as uploader
from scripts.usage.protocol import MAX_INPUT_BYTES, MAX_SPOOL_BYTES, ProtocolError


def _write(path: Path, value: str, mode: int = 0o600) -> None:
    path.write_text(value, encoding="utf-8")
    os.chmod(path, mode)


def _canonical_file(path: Path) -> bytes:
    return json.dumps(
        json.loads(path.read_bytes()),
        allow_nan=False,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")


class _Response:
    def __init__(self, code: int = 204) -> None:
        self.code = code
        self.closed = False

    def getcode(self) -> int:
        return self.code

    def close(self) -> None:
        self.closed = True


class _CaptureOpener:
    def __init__(self, response: _Response | None = None, error: Exception | None = None) -> None:
        self.request = None
        self.timeout = None
        self.response = response or _Response()
        self.error = error

    def open(self, request, timeout):
        self.request = request
        self.timeout = timeout
        if self.error is not None:
            raise self.error
        return self.response


class CollectorTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.spool = Path(self.tempdir.name) / "nested" / "spool.json"

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def run_collector(self, raw: bytes) -> str:
        output = io.StringIO()
        with mock.patch.object(collector.sys, "stdin", io.BytesIO(raw)), redirect_stdout(output):
            self.assertEqual(collector.main(["--spool", str(self.spool)]), 0)
        return output.getvalue().strip()

    def test_allowlist_and_private_atomic_spool(self) -> None:
        status = self.run_collector(
            b'{"session_id":"do-not-store","transcript_path":"/private/secret",'
            b'"workspace":{"current_dir":"/private/work"},"rate_limits":'
            b'{"five_hour":{"used_percentage":12.5,"resets_at":1700000000,'
            b'"token":"drop-me"},"seven_day":{"used_percentage":80,'
            b'"resets_at":1700000100,"nested":{"secret":true}},"secret":"drop"},'
            b'"top_secret":"drop"}',
        )
        self.assertEqual(status, "CLAUDE USAGE 5h 12.5% · 7d 80%")
        self.assertEqual(
            self.spool.read_bytes(),
            b'{"rate_limits":{"five_hour":{"resets_at":1700000000,"used_percentage":12.5},'
            b'"seven_day":{"resets_at":1700000100,"used_percentage":80}}}',
        )
        self.assertEqual(stat.S_IMODE(self.spool.stat().st_mode), 0o600)
        stored = self.spool.read_text(encoding="utf-8")
        for secret in ("do-not-store", "transcript_path", "current_dir", "drop-me", "top_secret"):
            self.assertNotIn(secret, stored)

    def test_missing_quota_is_empty_and_never_fabricated(self) -> None:
        self.assertEqual(self.run_collector(b'{"model":"claude","rate_limits":{}}'), "CLAUDE USAGE unavailable")
        self.assertEqual(self.spool.read_bytes(), b'{"rate_limits":{}}')
        self.assertEqual(self.run_collector(b'{"rate_limits":{"five_hour":{"resets_at":1700000000}}}'), "CLAUDE USAGE unavailable")
        self.assertEqual(self.spool.read_bytes(), b'{"rate_limits":{"five_hour":{"resets_at":1700000000}}}')

    def test_valid_field_survives_invalid_sibling_without_type_coercion(self) -> None:
        status = self.run_collector(
            b'{"rate_limits":{"five_hour":{"used_percentage":"42",'
            b'"resets_at":1700000000},"seven_day":{"used_percentage":42,'
            b'"resets_at":true}}}',
        )
        self.assertEqual(status, "CLAUDE USAGE 7d 42%")
        self.assertEqual(
            self.spool.read_bytes(),
            b'{"rate_limits":{"five_hour":{"resets_at":1700000000},"seven_day":{"used_percentage":42}}}',
        )

    def test_nan_infinity_and_duplicate_keys_fail_without_overwriting_last_good(self) -> None:
        good = b'{"rate_limits":{"five_hour":{"used_percentage":10,"resets_at":1700000000}}}'
        self.run_collector(good)
        original = self.spool.read_bytes()
        for bad in (
            b'{"rate_limits":{"five_hour":{"used_percentage":NaN}}}',
            b'{"rate_limits":{"five_hour":{"resets_at":Infinity}}}',
            b'{"rate_limits":{"five_hour":{"used_percentage":1,"used_percentage":2}}}',
            b'{"rate_limits":{"five_hour":{"resets_at":1700000000,"resets_at":1700000001}}}',
        ):
            self.assertEqual(self.run_collector(bad), "CLAUDE USAGE unavailable")
            self.assertEqual(self.spool.read_bytes(), original)

    def test_malformed_and_oversize_fail_without_overwriting_last_good(self) -> None:
        self.run_collector(b'{"rate_limits":{"five_hour":{"used_percentage":10}}}')
        original = self.spool.read_bytes()
        self.assertEqual(self.run_collector(b'{"rate_limits":'), "CLAUDE USAGE unavailable")
        self.assertEqual(self.spool.read_bytes(), original)
        self.assertEqual(self.run_collector(b"{" + b" " * MAX_INPUT_BYTES), "CLAUDE USAGE unavailable")
        self.assertEqual(self.spool.read_bytes(), original)

    def test_atomic_replace_leaves_no_temporary_file(self) -> None:
        self.run_collector(b'{"rate_limits":{"five_hour":{"used_percentage":1}}}')
        self.assertEqual(list(self.spool.parent.glob(f".{self.spool.name}.*")), [])


class EndpointTests(unittest.TestCase):
    def test_exact_tailnet_https_contract(self) -> None:
        for endpoint in (
            "https://host.tailnet.ts.net:8420/usage/claude-ingest",
            "https://host.tailnet.ts.net:443/usage/claude-ingest",
            "https://host.tailnet.ts.net/usage/claude-ingest",
            "HTTPS://HOST.TAILNET.TS.NET:443/usage/claude-ingest",
        ):
            self.assertEqual(uploader.validate_endpoint(endpoint), endpoint)

        for endpoint in (
            "http://host.tailnet.ts.net:8420/usage/claude-ingest",
            "https://host.example:8420/usage/claude-ingest",
            "https://host.tailnet.ts.net.evil.example:8420/usage/claude-ingest",
            "https://ts.net:8420/usage/claude-ingest",
            "https://host.tailnet.ts.net:80/usage/claude-ingest",
            "https://host.tailnet.ts.net:1234/usage/claude-ingest",
            "https://host.tailnet.ts.net:8420/wrong",
            "https://host.tailnet.ts.net:8420/usage/claude-ingest/",
            "https://host.tailnet.ts.net:8420/usage/claude-ingest?secret=1",
            "https://host.tailnet.ts.net:8420/usage/claude-ingest?",
            "https://host.tailnet.ts.net:8420/usage/claude-ingest#fragment",
            "https://host.tailnet.ts.net:8420/usage/claude-ingest#",
            "https://user:password@host.tailnet.ts.net:8420/usage/claude-ingest",
            "https://host.tailnet.ts.net:8420@127.0.0.1/usage/claude-ingest",
            "https://.ts.net:8420/usage/claude-ingest",
            "https://host..tailnet.ts.net:8420/usage/claude-ingest",
            "https://host%2eattacker.ts.net:8420/usage/claude-ingest",
            "https://[::1]:8420/usage/claude-ingest",
            "https://host.tailnet.ts.net:8420/usage/claude-ingest\r\nX-Leak: 1",
        ):
            with self.subTest(endpoint=endpoint), self.assertRaises(ProtocolError):
                uploader.validate_endpoint(endpoint)


class UploaderTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name)
        self.spool = self.root / "spool.json"
        self.config = self.root / "config.json"
        _write(self.spool, '{"rate_limits":{"five_hour":{"used_percentage":12.5,"resets_at":1700000000}}}')
        _write(self.config, '{"endpoint":"https://device.tailnet.ts.net:8420/usage/claude-ingest"}', 0o600)

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def write_new_sample(self, raw: bytes) -> None:
        output = io.StringIO()
        with mock.patch.object(collector.sys, "stdin", io.BytesIO(raw)), redirect_stdout(output):
            self.assertEqual(collector.main(["--spool", str(self.spool)]), 0)

    def test_success_consumes_claim_and_does_not_post_again_without_new_spool(self) -> None:
        opener = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, opener), uploader.SENT)
        claim = uploader.claim_path(self.spool)
        self.assertFalse(self.spool.exists())
        self.assertFalse(claim.exists())
        self.assertTrue(uploader._claim_lock_path(self.spool).exists())

        second_opener = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, second_opener), uploader.UNAVAILABLE)
        self.assertIsNone(second_opener.request)

    def test_network_failure_retains_claim_for_retry(self) -> None:
        opener = _CaptureOpener(error=TimeoutError("private test failure"))
        self.assertEqual(uploader.process_once(self.spool, self.config, opener), uploader.UNAVAILABLE)
        claim = uploader.claim_path(self.spool)
        self.assertTrue(claim.exists())
        self.assertFalse(self.spool.exists())
        self.assertEqual(stat.S_IMODE(claim.stat().st_mode), 0o600)
        self.assertEqual(uploader.load_spool(claim)["rate_limits"]["five_hour"]["used_percentage"], 12.5)

    def test_server_and_config_failures_retain_valid_claim(self) -> None:
        server_failure = _CaptureOpener(response=_Response(503))
        self.assertEqual(uploader.process_once(self.spool, self.config, server_failure), uploader.UNAVAILABLE)
        claim = uploader.claim_path(self.spool)
        self.assertTrue(claim.exists())

        _write(self.config, '{"endpoint":"https://evil.example/usage/claude-ingest"}', 0o600)
        config_failure = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, config_failure), uploader.UNAVAILABLE)
        self.assertTrue(claim.exists())
        self.assertIsNone(config_failure.request)

    def test_existing_claim_wins_and_newer_collector_slot_survives(self) -> None:
        failed = _CaptureOpener(error=TimeoutError("retry later"))
        self.assertEqual(uploader.process_once(self.spool, self.config, failed), uploader.UNAVAILABLE)
        old_body = _canonical_file(uploader.claim_path(self.spool))

        self.write_new_sample(b'{"rate_limits":{"seven_day":{"used_percentage":80,"resets_at":1700000100}}}')
        new_body = self.spool.read_bytes()
        self.assertNotEqual(old_body, new_body)

        retry = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, retry), uploader.SENT)
        self.assertEqual(retry.request.data, old_body)
        self.assertFalse(uploader.claim_path(self.spool).exists())
        self.assertEqual(self.spool.read_bytes(), new_body)

        next_send = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, next_send), uploader.SENT)
        self.assertEqual(next_send.request.data, new_body)
        self.assertFalse(self.spool.exists())

    def test_corrupt_claim_is_discarded_without_blocking_new_spool(self) -> None:
        claim = uploader.claim_path(self.spool)
        _write(claim, '{"session_id":"never-post"}', 0o600)
        fresh_body = _canonical_file(self.spool)
        opener = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, opener), uploader.SENT)
        self.assertEqual(opener.request.data, fresh_body)
        self.assertFalse(claim.exists())
        self.assertFalse(self.spool.exists())

    def test_invalid_claim_permissions_are_discarded_only(self) -> None:
        claim = uploader.claim_path(self.spool)
        _write(claim, '{"rate_limits":{}}', 0o644)
        fresh_body = _canonical_file(self.spool)
        opener = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, opener), uploader.SENT)
        self.assertEqual(opener.request.data, fresh_body)
        self.assertFalse(claim.exists())

    def test_oversize_claim_is_discarded_only(self) -> None:
        claim = uploader.claim_path(self.spool)
        _write(claim, "{" + " " * MAX_SPOOL_BYTES, 0o600)
        fresh_body = _canonical_file(self.spool)
        opener = _CaptureOpener()
        self.assertEqual(uploader.process_once(self.spool, self.config, opener), uploader.SENT)
        self.assertEqual(opener.request.data, fresh_body)
        self.assertFalse(claim.exists())

    def test_exact_post_body_headers_timeout_and_no_credentials(self) -> None:
        opener = _CaptureOpener()
        payload = uploader.load_spool(self.spool)
        endpoint = uploader.load_endpoint(self.config)
        self.assertTrue(uploader.post_payload(payload, endpoint, opener))
        request = opener.request
        self.assertEqual(request.get_method(), "POST")
        self.assertEqual(request.full_url, endpoint)
        self.assertEqual(request.data, b'{"rate_limits":{"five_hour":{"resets_at":1700000000,"used_percentage":12.5}}}')
        self.assertEqual(request.get_header("Content-type"), "application/json")
        self.assertIsNone(request.get_header("Authorization"))
        self.assertIsNone(request.get_header("Cookie"))
        self.assertEqual(opener.timeout, uploader.REQUEST_TIMEOUT_SECONDS)
        self.assertTrue(opener.response.closed)

    def test_spool_allowlist_rejects_secrets_and_nonfinite_or_duplicate_json(self) -> None:
        bad_values = (
            '{"rate_limits":{"five_hour":{"used_percentage":NaN}}}',
            '{"rate_limits":{"five_hour":{"resets_at":Infinity}}}',
            '{"rate_limits":{"five_hour":{"used_percentage":1,"used_percentage":2}}}',
            '{"rate_limits":{"five_hour":{"used_percentage":"12"}}}',
            '{"rate_limits":{"five_hour":{"used_percentage":true}}}',
            '{"rate_limits":{"five_hour":{"used_percentage":10,"secret":"token"}}}',
            '{"rate_limits":{"five_hour":{"used_percentage":10}},"session_id":"secret"}',
        )
        for bad in bad_values:
            with self.subTest(bad=bad):
                _write(self.spool, bad)
                with self.assertRaises(ProtocolError):
                    uploader.load_spool(self.spool)

    def test_oversize_spool_and_nonprivate_spool_are_rejected(self) -> None:
        _write(self.spool, "{" + " " * MAX_SPOOL_BYTES)
        with self.assertRaises(ProtocolError):
            uploader.load_spool(self.spool)
        _write(self.spool, '{"rate_limits":{}}', 0o644)
        with self.assertRaises(ProtocolError):
            uploader.load_spool(self.spool)

    def test_redirect_is_hard_failure_and_never_followed(self) -> None:
        handler = uploader.RejectRedirectHandler()
        request = mock.Mock(full_url="https://device.tailnet.ts.net:8420/usage/claude-ingest")
        self.assertIsNone(handler.redirect_request(request, {}, 302, "Found", {}))
        with self.assertRaises(HTTPError) as raised:
            handler.http_error_302(request, io.BytesIO(), 302, "Found", {})
        raised.exception.close()

    def test_network_failure_is_nonfatal_and_non_sensitive(self) -> None:
        opener = _CaptureOpener(error=TimeoutError("do not print this"))
        payload = uploader.load_spool(self.spool)
        endpoint = uploader.load_endpoint(self.config)
        self.assertFalse(uploader.post_payload(payload, endpoint, opener))
        output = io.StringIO()
        with mock.patch.object(uploader, "post_payload", return_value=False), redirect_stdout(output):
            self.assertEqual(uploader.main(["--spool", str(self.spool), "--config", str(self.config)]), 0)
        self.assertEqual(output.getvalue().strip(), "CLAUDE USAGE unavailable")
        self.assertNotIn("do not print this", output.getvalue())

    def test_post_revalidates_endpoint_before_opening(self) -> None:
        opener = _CaptureOpener()
        payload = uploader.load_spool(self.spool)
        self.assertFalse(uploader.post_payload(payload, "https://evil.example/usage/claude-ingest", opener))
        self.assertIsNone(opener.request)

    def test_malformed_config_does_not_open_network(self) -> None:
        _write(self.config, '{"endpoint":"https://evil.example/usage/claude-ingest","token":"secret"}', 0o600)
        with self.assertRaises(ProtocolError):
            uploader.load_endpoint(self.config)

    def test_endpoint_config_requires_private_permissions(self) -> None:
        _write(self.config, '{"endpoint":"https://device.tailnet.ts.net:8420/usage/claude-ingest"}', 0o644)
        with self.assertRaises(ProtocolError):
            uploader.load_endpoint(self.config)
        os.chmod(self.config, 0o600)
        self.assertEqual(
            uploader.load_endpoint(self.config),
            "https://device.tailnet.ts.net:8420/usage/claude-ingest",
        )


if __name__ == "__main__":
    unittest.main()
