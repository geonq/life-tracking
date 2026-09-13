from __future__ import annotations

import json
import os
import plistlib
import tempfile
import unittest
from pathlib import Path

from scripts.usage import install_claude_forwarder as installer


class ClaudeForwarderInstallerTests(unittest.TestCase):
    def test_plan_uses_exact_gateway_and_preserves_paths(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            plan = installer.build_plan(
                repo_root=Path(__file__).resolve().parents[3],
                home=home,
                state_dir=home / "private-state",
            )
            self.assertEqual(plan["endpoint"], installer.DEFAULT_ENDPOINT)
            self.assertIn("claude_statusline_collector.py", plan["status_command"])
            self.assertIn("--spool", plan["status_command"])
            self.assertEqual(plan["launchd"]["StartInterval"], 60)
            self.assertEqual(plan["launchd"]["ProgramArguments"][-1], str(plan["config"]))

    def test_apply_merges_status_line_and_writes_private_launch_agent(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            claude = home / ".claude"
            claude.mkdir(mode=0o700)
            settings = claude / "settings.json"
            settings.write_text(json.dumps({
                "permissions": {"deny": [".env"]},
                "statusLine": {"type": "command", "padding": False, "command": "old-command"},
            }), encoding="utf-8")
            os.chmod(settings, 0o600)
            plan = installer.build_plan(
                repo_root=Path(__file__).resolve().parents[3],
                home=home,
                state_dir=home / "private-state",
            )

            installer.apply_plan(plan)

            merged = json.loads(settings.read_text(encoding="utf-8"))
            self.assertEqual(merged["permissions"], {"deny": [".env"]})
            self.assertEqual(merged["statusLine"]["type"], "command")
            self.assertFalse(merged["statusLine"]["padding"])
            self.assertNotIn("refreshInterval", merged["statusLine"])
            self.assertEqual(len(list((home / "private-state").glob("settings.json.before-lifeos*"))), 1)
            self.assertTrue((home / "private-state" / "settings.json.before-lifeos").exists())
            self.assertEqual(oct(settings.stat().st_mode & 0o777), "0o600")
            self.assertEqual(oct((home / "private-state" / "endpoint.json").stat().st_mode & 0o777), "0o600")
            with (home / "Library/LaunchAgents" / f"{installer.AGENT_LABEL}.plist").open("rb") as stream:
                plist = plistlib.load(stream)
            self.assertEqual(plist["Label"], installer.AGENT_LABEL)
            self.assertEqual(plist["StartInterval"], 60)

    def test_rerunning_apply_keeps_single_backup_of_original_statusline(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            home = Path(raw)
            claude = home / ".claude"
            claude.mkdir(mode=0o700)
            settings = claude / "settings.json"
            original_status_line = {"type": "command", "padding": False, "command": "original-pre-lifeos-command"}
            settings.write_text(json.dumps({
                "permissions": {"deny": [".env"]},
                "statusLine": original_status_line,
            }), encoding="utf-8")
            os.chmod(settings, 0o600)
            plan = installer.build_plan(
                repo_root=Path(__file__).resolve().parents[3],
                home=home,
                state_dir=home / "private-state",
            )

            installer.apply_plan(plan)
            installer.apply_plan(plan)

            backups = list((home / "private-state").glob("settings.json.before-lifeos*"))
            self.assertEqual(len(backups), 1)
            backup_content = json.loads(backups[0].read_text(encoding="utf-8"))
            self.assertEqual(backup_content["statusLine"], original_status_line)
            self.assertNotIn("claude_statusline_collector.py", backup_content["statusLine"]["command"])
            self.assertEqual(oct(backups[0].stat().st_mode & 0o777), "0o600")

    def test_invalid_endpoint_never_produces_a_plan(self) -> None:
        with tempfile.TemporaryDirectory() as raw:
            with self.assertRaises(Exception):
                installer.build_plan(
                    repo_root=Path(__file__).resolve().parents[3],
                    home=Path(raw),
                    endpoint="https://evil.example/usage/claude-ingest",
                )


if __name__ == "__main__":
    unittest.main()
