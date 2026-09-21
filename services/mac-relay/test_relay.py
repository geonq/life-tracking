import os
import subprocess
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from main import RelayApplication, RelayConfig, RelayResponse, create_server  # noqa: E402


class RelayTests(unittest.TestCase):
    def test_default_is_loopback_and_health_is_unsigned(self) -> None:
        response = RelayApplication().dispatch("GET", "/replication/v1/health", [], b"")
        self.assertEqual(response.status, 200)
        self.assertIn(b'"status":"relay"', response.body)
        with self.assertRaises(ValueError):
            create_server(RelayConfig(host="0.0.0.0"))

    def test_admin_and_unknown_routes_are_denied(self) -> None:
        app = RelayApplication()
        admin = app.dispatch("POST", "/replication/v1/data/manage", [("content-type", "application/json")], b"{}")
        self.assertEqual(admin.status, 403)
        blob = b'{"tag":"admin.blob.put"}'
        self.assertEqual(
            app.dispatch("POST", "/replication/v1/blob", [("content-type", "application/json")], blob).status,
            403,
        )
        self.assertEqual(app.dispatch("GET", "/replication/v1/unknown", [], b"").status, 404)

    def test_body_cap_and_missing_handler_fail_closed(self) -> None:
        app = RelayApplication(RelayConfig(max_request_bytes=4))
        self.assertEqual(
            app.dispatch("POST", "/replication/v1/exchange", [("content-type", "application/json")], b"12345").status,
            413,
        )
        self.assertEqual(
            RelayApplication().dispatch("POST", "/replication/v1/exchange", [("content-type", "application/json")], b"{}").status,
            503,
        )

    def test_injected_handler_receives_only_validated_route(self) -> None:
        seen: list[tuple[str, str, bytes]] = []

        def handler(method, path, headers, body):
            seen.append((method, path, body))
            return RelayResponse(200, b'{"ok":true}')

        response = RelayApplication(handler=handler).dispatch(
            "POST",
            "/replication/v1/exchange",
            [("content-type", "application/json")],
            b"{}",
        )
        self.assertEqual(response.status, 200)
        self.assertEqual(seen, [("POST", "/replication/v1/exchange", b"{}")])
        self.assertEqual(
            RelayApplication(handler=handler).dispatch(
                "POST",
                "/replication/v1/exchange",
                [("content-type", "application/json"), ("Content-Type", "application/json")],
                b"{}",
            ).status,
            400,
        )

    def test_install_script_only_renders_template(self) -> None:
        script = Path(__file__).with_name("install.sh")
        environment = os.environ.copy()
        environment["LIFEOS_RELAY_PYTHON"] = "python3"
        result = subprocess.run(
            [str(script), "--print-template"],
            check=True,
            capture_output=True,
            text=True,
            env=environment,
        )
        self.assertIn("com.geonq.lifeos.relay", result.stdout)
        self.assertIn("python", result.stdout.casefold())
        self.assertNotIn("launchctl", result.stdout)
        self.assertNotIn("launchctl", script.read_text())


if __name__ == "__main__":
    unittest.main()
