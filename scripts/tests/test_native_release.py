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
TEST_EXPIRATION = "2099-01-02T03:04:05Z"


class NativeReleaseInvariantTests(unittest.TestCase):
    def test_checked_in_source_uses_exact_approved_sync_host(self) -> None:
        validate_source(ROOT)

    def test_release_accepts_explicit_injected_values(self) -> None:
        validate_release(
            {
                "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                "PROVISIONING_MODE": "developer_program",
                "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
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
                    "PROVISIONING_MODE": "developer_program",
                    "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
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
                    "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
                    "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                },
                root=ROOT,
            )

    def test_release_rejects_arbitrary_provisioning_mode(self) -> None:
        with self.assertRaisesRegex(InvariantError, "PROVISIONING_MODE"):
            validate_release(
                {
                    "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                    "PROVISIONING_MODE": "development",
                    "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
                    "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                },
                root=ROOT,
            )

    def test_release_accepts_only_the_app_vocabulary(self) -> None:
        for mode in ("personal_team", "developer_program", "sideloaded"):
            with self.subTest(mode=mode):
                validate_release(
                    {
                        "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                        "PROVISIONING_MODE": mode,
                        "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
                        "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                    },
                    root=ROOT,
                )

    def test_release_requires_timezone_qualified_expiration(self) -> None:
        for expiration in ("", "2030-01-02", "not-a-date"):
            with self.subTest(expiration=expiration):
                with self.assertRaisesRegex(InvariantError, "PROVISIONING_EXPIRATION_DATE"):
                    validate_release(
                        {
                            "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                            "PROVISIONING_MODE": "developer_program",
                            "PROVISIONING_EXPIRATION_DATE": expiration,
                            "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                        },
                        root=ROOT,
                    )

    def test_release_matches_swift_iso8601_expiration_forms(self) -> None:
        for expiration in (
            "2099-01-02T03:04:05Z",
            "2099-01-02T03:04:05+00:00",
            "2099-01-02T03:04:05-05:30",
            "2099-01-02T03:04:05+0000",
        ):
            with self.subTest(expiration=expiration):
                validate_release(
                    {
                        "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                        "PROVISIONING_MODE": "developer_program",
                        "PROVISIONING_EXPIRATION_DATE": expiration,
                        "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                    },
                    root=ROOT,
                )

    def test_release_rejects_space_separated_expiration(self) -> None:
        with self.assertRaisesRegex(InvariantError, "T separator"):
            validate_release(
                {
                    "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                    "PROVISIONING_MODE": "developer_program",
                    "PROVISIONING_EXPIRATION_DATE": "2099-01-02 03:04:05+00:00",
                    "LIFEOS_SYNC_APPROVED_HOSTS": TEST_APPROVED_HOST,
                },
                root=ROOT,
            )

    def test_release_rejects_expired_expiration(self) -> None:
        with self.assertRaisesRegex(InvariantError, "must be in the future"):
            validate_release(
                {
                    "APP_GROUP_IDENTIFIER": "group.com.hermes.lifeos.ci",
                    "PROVISIONING_MODE": "developer_program",
                    "PROVISIONING_EXPIRATION_DATE": "2000-01-02T03:04:05Z",
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
                            "PROVISIONING_MODE": "developer_program",
                            "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
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
                            "PROVISIONING_MODE": "developer_program",
                            "PROVISIONING_EXPIRATION_DATE": TEST_EXPIRATION,
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

    def test_selected_tab_text_uses_a_text_safe_neutral_role(self) -> None:
        source = (ROOT / "ios/LifeOS/LifeOSApp.swift").read_text(encoding="utf-8")
        self.assertIn(
            ".foregroundStyle(isSelected ? tab.accent : LifeOSTokens.tertiaryText)",
            source,
        )
        self.assertIn(
            ".foregroundStyle(isSelected ? LifeOSTokens.primaryText : LifeOSTokens.tertiaryText)",
            source,
        )

    def test_health_prompts_are_settings_only_and_write_is_explicit(self) -> None:
        source = (ROOT / "ios/LifeOS/LifeOSApp.swift").read_text(encoding="utf-8")
        self.assertNotIn("autoRequestHealthReadAccessIfNeeded", source)
        self.assertNotIn("requestWriteAuthorization()", source)
        self.assertIn("requestWriteAuthorization(userInitiated: true)", source)


if __name__ == "__main__":
    unittest.main()
