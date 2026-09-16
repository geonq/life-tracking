"""Safety contracts for the manual macOS build-storage maintenance command."""

from __future__ import annotations

import os
import stat
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "maintain_macos_storage.sh"


class MacOSStorageMaintenanceTests(unittest.TestCase):
    def test_script_is_executable_and_shell_valid(self) -> None:
        self.assertTrue(SCRIPT.stat().st_mode & stat.S_IXUSR)
        result = subprocess.run(
            ["/bin/bash", "-n", str(SCRIPT)],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_help_is_available_without_touching_storage(self) -> None:
        result = subprocess.run(
            [str(SCRIPT), "--help"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--apply", result.stdout)
        self.assertIn("--prune-simulators", result.stdout)

    def test_cleanup_selection_is_dry_run_by_default(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-storage-test-") as temporary:
            temporary_root = Path(temporary)
            derived = temporary_root / "DerivedData"
            support = temporary_root / "DeviceSupport"
            candidate = derived / "LifeOS-test"
            candidate.mkdir(parents=True)
            (candidate / "sentinel").write_text("keep until apply", encoding="utf-8")
            support.mkdir()
            (support / "old-support").mkdir()
            result = subprocess.run(
                [
                    str(SCRIPT),
                    "--clear-derived-data",
                    "--prune-device-support",
                ],
                cwd=ROOT,
                env={
                    **os.environ,
                    "LIFEOS_DEVELOPER_ROOT": str(temporary_root),
                    "LIFEOS_DERIVED_DATA_ROOT": str(derived),
                    "LIFEOS_DEVICE_SUPPORT_ROOT": str(support),
                    "LIFEOS_MIN_FREE_GIB": "0",
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue((candidate / "sentinel").exists())
            self.assertIn("Dry run only", result.stdout)

    def test_apply_removes_only_selected_generated_directories(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-storage-apply-") as temporary:
            temporary_root = Path(temporary)
            derived = temporary_root / "DerivedData"
            support = temporary_root / "DeviceSupport"
            candidate = derived / "LifeOS-old"
            kept_support = support / "iPhone18,3-26.6"
            old_support = support / "iPhone14,5-17.0"
            candidate.mkdir(parents=True)
            support.mkdir()
            kept_support.mkdir()
            old_support.mkdir()
            (candidate / "sentinel").write_text("remove", encoding="utf-8")
            (kept_support / "sentinel").write_text("keep", encoding="utf-8")
            (old_support / "sentinel").write_text("remove", encoding="utf-8")
            result = subprocess.run(
                [
                    str(SCRIPT),
                    "--apply",
                    "--clear-derived-data",
                    "--prune-device-support",
                ],
                cwd=ROOT,
                env={
                    **os.environ,
                    "LIFEOS_DEVELOPER_ROOT": str(temporary_root),
                    "LIFEOS_DERIVED_DATA_ROOT": str(derived),
                    "LIFEOS_DEVICE_SUPPORT_ROOT": str(support),
                    "LIFEOS_MIN_FREE_GIB": "0",
                },
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(candidate.exists())
            self.assertFalse(old_support.exists())
            self.assertTrue((kept_support / "sentinel").exists())
            self.assertIn("REMOVED:", result.stdout)

    def test_check_fails_closed_when_the_configured_floor_is_unreachable(self) -> None:
        result = subprocess.run(
            [str(SCRIPT), "--check"],
            cwd=ROOT,
            env={**os.environ, "LIFEOS_MIN_FREE_GIB": "999999"},
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("minimum is 999999 GiB", result.stderr)

    def test_apply_refuses_active_build_and_probe_errors(self) -> None:
        for probe_status, expected in ((0, "xcodebuild is active"), (2, "process probe exited with status 2")):
            with self.subTest(probe_status=probe_status), tempfile.TemporaryDirectory(prefix="lifeos-storage-probe-") as temporary:
                temporary_root = Path(temporary)
                derived = temporary_root / "DerivedData"
                candidate = derived / "LifeOS-test"
                candidate.mkdir(parents=True)
                (candidate / "sentinel").write_text("preserve", encoding="utf-8")
                probe = temporary_root / "pgrep"
                probe.write_text(f"#!/bin/sh\nexit {probe_status}\n", encoding="utf-8")
                probe.chmod(0o700)
                result = subprocess.run(
                    [str(SCRIPT), "--apply", "--clear-derived-data"],
                    cwd=ROOT,
                    env={
                        **os.environ,
                        "LIFEOS_DEVELOPER_ROOT": str(temporary_root),
                        "LIFEOS_DERIVED_DATA_ROOT": str(derived),
                        "LIFEOS_PGREP_PATH": str(probe),
                        "LIFEOS_MIN_FREE_GIB": "0",
                    },
                    text=True,
                    capture_output=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertTrue((candidate / "sentinel").exists())

    def test_source_keeps_deletion_paths_scoped_and_skips_booted_simulators(self) -> None:
        source = SCRIPT.read_text(encoding="utf-8")
        self.assertIn('safe_remove_directory "$path"', source)
        self.assertIn('[[ "$state" == "Booted" ]]', source)
        self.assertIn('"$DERIVED_DATA_ROOT"/*', source)
        self.assertIn('"$DEVICE_SUPPORT_ROOT"/*', source)
        self.assertIn('if [[ "$apply_changes" -eq 1 ]]', source)
        self.assertIn('probe_status', source)
        self.assertIn('probe exited with status', source)


if __name__ == "__main__":
    unittest.main()
