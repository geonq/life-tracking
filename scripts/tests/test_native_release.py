from __future__ import annotations

import unittest
from pathlib import Path

from scripts.validate_native_release import (
    InvariantError,
    parse_build_settings,
    validate_release,
    validate_source,
)


ROOT = Path(__file__).resolve().parents[2]
TEST_APPROVED_HOST = "ci-test." + "ts.net"


class NativeReleaseInvariantTests(unittest.TestCase):
    def test_checked_in_source_remains_fail_closed(self) -> None:
        validate_source(ROOT)

    def test_release_accepts_explicit_injected_values(self) -> None:
        validate_release(
            {
                "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                "PROVISIONING_MODE": "development",
                "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "",
                "OTHER_SWIFT_FLAGS": "",
            },
            root=ROOT,
        )

    def test_release_rejects_placeholder_app_group(self) -> None:
        with self.assertRaisesRegex(InvariantError, "placeholder"):
            validate_release(
                {
                    "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID",
                    "PROVISIONING_MODE": "development",
                    "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                },
                root=ROOT,
            )

    def test_release_rejects_unknown_provisioning_mode(self) -> None:
        with self.assertRaisesRegex(InvariantError, "PROVISIONING_MODE"):
            validate_release(
                {
                    "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                    "PROVISIONING_MODE": "unknown",
                    "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                },
                root=ROOT,
            )

    def test_release_rejects_empty_or_non_tailnet_allowlist(self) -> None:
        for allowlist in ("", "example.com", f"{TEST_APPROVED_HOST},{TEST_APPROVED_HOST}"):
            with self.subTest(allowlist=allowlist):
                with self.assertRaises(InvariantError):
                    validate_release(
                        {
                            "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                            "PROVISIONING_MODE": "development",
                            "LIFEOS_SYNC_APPROVED_HOSTS": allowlist,
                        },
                        root=ROOT,
                    )

    def test_release_rejects_fixture_flags_and_unresolved_variables(self) -> None:
        for key, value, expected in (
            ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG LifeOSVisualFixtures", "fixture"),
            ("OTHER_SWIFT_FLAGS", "$(UNRESOLVED)", "unresolved"),
        ):
            with self.subTest(key=key):
                with self.assertRaisesRegex(InvariantError, expected):
                    validate_release(
                        {
                            "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                            "PROVISIONING_MODE": "development",
                            "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                            key: value,
                        },
                        root=ROOT,
                    )

    def test_build_settings_parser_keeps_last_assignment(self) -> None:
        settings = parse_build_settings(
            """
            APP_GROUP_IDENTIFIER = ignored
            APP_GROUP_IDENTIFIER = group.com.hermes.lifeos.ci
            // COMMENT = ignored
            """
        )
        self.assertEqual(settings["APP_GROUP_IDENTIFIER"], "group.com.hermes.lifeos.ci")


if __name__ == "__main__":
    unittest.main()
