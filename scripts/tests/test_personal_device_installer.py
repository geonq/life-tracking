"""Fixture and command-flow tests for the personal iPhone installer."""

from __future__ import annotations

from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "install_personal_device.sh"
sys.path.insert(0, str(ROOT / "scripts"))
import install_personal_device_checks as checks  # noqa: E402


TEAM = "ABCDE12345"
APP_GROUP = "group.com.hermes.lifeos"
APP_BUNDLE = "com.hermes.lifeos.app"
WIDGET_BUNDLE = "com.hermes.lifeos.app.widget"
UDID = "01234567-89AB-CDEF-0123-456789ABCDEF"
OTHER_UDID = "FEDCBA98-7654-3210-FEDC-BA9876543210"


def device_record(
    udid: str = UDID,
    *,
    state: str = "connected",
    tunnel: str = "connected",
    pairing: str = "paired",
    boot: str = "booted",
    transport: str = "wired",
    reality: str = "physical",
    ddi: bool = True,
) -> dict[str, object]:
    return {
        "state": state,
        "hardwareProperties": {
            "udid": udid,
            "platform": "iOS",
            "deviceType": "iPhone",
            "reality": reality,
        },
        "connectionProperties": {
            "transportType": transport,
            "tunnelState": tunnel,
            "pairingState": pairing,
        },
        "deviceProperties": {
            "bootState": boot,
            "ddiServicesAvailable": ddi,
        },
    }


def device_payload(*devices: dict[str, object]) -> dict[str, object]:
    return {"result": {"devices": list(devices)}}


def profile_for(
    bundle_id: str,
    *,
    udid: str = UDID,
    expires: datetime | None = None,
    groups: list[str] | None = None,
    team: str = TEAM,
) -> dict[str, object]:
    groups = groups or [APP_GROUP]
    expires = expires or (datetime.now(timezone.utc) + timedelta(days=2))
    return {
        "TeamIdentifier": [team],
        "ProvisionedDevices": [udid],
        "ExpirationDate": expires,
        "Entitlements": {
            "application-identifier": f"{team}.{bundle_id}",
            "com.apple.developer.team-identifier": team,
            "com.apple.security.application-groups": groups,
        },
    }


def write_plist(path: Path, value: object) -> None:
    with path.open("wb") as handle:
        plistlib.dump(value, handle, fmt=plistlib.FMT_XML)


class PersonalDeviceInstallerTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = SCRIPT.read_text(encoding="utf-8")

    def test_shell_is_strict_noninteractive_and_keeps_project_stable(self) -> None:
        self.assertTrue(SCRIPT.stat().st_mode & stat.S_IXUSR)
        syntax = subprocess.run(["bash", "-n", str(SCRIPT)], capture_output=True, text=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        help_result = subprocess.run([str(SCRIPT), "--help"], capture_output=True, text=True)
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        self.assertIn("DEVELOPMENT_TEAM", help_result.stdout)
        self.assertIn("APP_GROUP_IDENTIFIER", help_result.stdout)
        self.assertIn("does not renew signing itself", help_result.stdout)
        self.assertIn("already be registered", help_result.stdout)
        self.assertNotIn("xcodegen", self.source.casefold())
        self.assertNotIn("CODE_SIGNING_ALLOWED=NO", self.source)
        self.assertNotIn("CODE_SIGNING_REQUIRED=NO", self.source)
        self.assertNotIn("-allowProvisioningUpdates", self.source)
        self.assertNotIn("command -v", self.source)
        self.assertIn("/usr/bin/env -i", self.source)
        self.assertIn('TMPDIR="$work_dir"', self.source)
        self.assertIn('tool_path="/usr/bin/$tool_name"', self.source)
        self.assertIn("-parallel-testing-enabled NO", self.source)
        self.assertIn("-jobs 1", self.source)
        hostile_environment = os.environ.copy()
        hostile_environment["BASH_FUNC_dirname%%"] = "() { /usr/bin/printf '%s\\n' INHERITED_FUNCTION_EXECUTED >&2; }"
        hostile_help = subprocess.run(
            [str(SCRIPT), "--help"],
            env=hostile_environment,
            capture_output=True,
            text=True,
        )
        self.assertEqual(hostile_help.returncode, 0, hostile_help.stderr)
        self.assertNotIn("INHERITED_FUNCTION_EXECUTED", hostile_help.stderr)
        with tempfile.TemporaryDirectory(prefix="lifeos-shell-startup-") as directory:
            startup_file = Path(directory) / "startup.sh"
            startup_file.write_text(
                "/usr/bin/printf '%s\\n' BASH_ENV_EXECUTED >&2\n",
                encoding="utf-8",
            )
            startup_environment = os.environ.copy()
            startup_environment["BASH_ENV"] = str(startup_file)
            startup_help = subprocess.run(
                [str(SCRIPT), "--help"],
                env=startup_environment,
                capture_output=True,
                text=True,
            )
            self.assertEqual(startup_help.returncode, 0, startup_help.stderr)
            self.assertNotIn("BASH_ENV_EXECUTED", startup_help.stderr)

    def test_device_parser_requires_coherent_physical_reachable_evidence(self) -> None:
        valid = device_record()
        self.assertEqual(checks.connected_iphone_udids(device_payload(valid)), (UDID,))
        self.assertEqual(
            checks.connected_iphone_udids(
                device_payload(device_record(state="disconnected", tunnel="disconnected"))
            ),
            (),
        )
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(device_record(reality="simulator"))),
            (),
        )
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(device_record(ddi=False))),
            (),
        )
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, device_record(OTHER_UDID))),
            (UDID, OTHER_UDID),
        )
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, device_record())),
            (),
        )
        self.assertEqual(
            checks.connected_iphone_udids(
                device_payload(valid, device_record(reality="simulator"))
            ),
            (),
        )
        self.assertEqual(
            checks.connected_iphone_udids(
                device_payload(valid, device_record(state="unavailable", tunnel="unavailable"))
            ),
            (),
        )
        incomplete_duplicate = device_record(state="disconnected", tunnel="disconnected")
        incomplete_duplicate.pop("deviceProperties")
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, incomplete_duplicate)),
            (),
        )
        blank_duplicate = device_record()
        blank_duplicate["state"] = ""
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, blank_duplicate)),
            (),
        )
        null_duplicate = device_record()
        null_duplicate["connectionProperties"]["tunnelState"] = None
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, null_duplicate)),
            (),
        )
        top_level_only = device_record()
        top_level_only["udid"] = UDID
        top_level_only["hardwareProperties"]["udid"] = None
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, top_level_only)),
            (),
        )
        incomplete_connection_duplicate = device_record()
        incomplete_connection_duplicate["connectionProperties"] = {}
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, incomplete_connection_duplicate)),
            (),
        )
        contradictory = device_record()
        contradictory["udid"] = OTHER_UDID
        self.assertEqual(
            checks.connected_iphone_udids(device_payload(valid, contradictory)),
            (),
        )
        with self.assertRaises(checks.DeviceListError):
            checks.connected_iphone_udids({"result": {"devices": "bad"}})
        with tempfile.TemporaryDirectory(prefix="lifeos-device-json-fixture-") as directory:
            duplicate_json = Path(directory) / "devices.json"
            duplicate_json.write_text(
                '{"result":{"devices":[],"devices":[]}}',
                encoding="utf-8",
            )
            with self.assertRaises(checks.DeviceListError):
                checks.load_device_json(str(duplicate_json))

    def test_app_group_validator_rejects_empty_segments_and_trailing_punctuation(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-device-group-fixture-") as directory:
            root = Path(directory)
            metadata = root / "codesign.txt"
            entitlements = root / "entitlements.plist"
            profile = root / "profile.plist"
            metadata.write_text(
                f"Identifier={APP_BUNDLE}\nTeamIdentifier={TEAM}\n",
                encoding="utf-8",
            )
            write_plist(profile, profile_for(APP_BUNDLE))
            args = (
                str(metadata), str(entitlements), str(profile), TEAM,
                APP_BUNDLE, UDID, APP_GROUP,
            )
            for invalid_group in ("group.com..hermes", "group.com.hermes.", "group.com.hermes-"):
                with self.subTest(invalid_group=invalid_group):
                    write_plist(entitlements, {
                        "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                        "com.apple.developer.team-identifier": TEAM,
                        "com.apple.security.application-groups": [invalid_group],
                    })
                    self.assertEqual(checks.validate_signed_bundle(*args), "app-group")

    def test_bounded_runner_cleans_descendants_after_exit_timeout_and_signal(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-runner-fixture-") as directory:
            root = Path(directory)
            runner = str(self._write_fixture_checks(root))
            killed = root / "killed"
            child_pid = root / "child.pid"
            timeout_result = subprocess.run(
                [sys.executable, runner, "--run-bounded", "1", "--", sys.executable, "-c", "import time; time.sleep(60)"],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(timeout_result.returncode, 124, timeout_result.stderr)

            noisy_result = subprocess.run(
                [
                    sys.executable, runner, "--run-bounded", "3", "--", sys.executable,
                    "-c", "import sys; sys.stdout.write('x' * 8388608); sys.stderr.write('y' * 8388608)",
                ],
                capture_output=True, text=True, timeout=8,
            )
            self.assertEqual(noisy_result.returncode, 0, noisy_result.stderr[-200:])
            self.assertLessEqual(len(noisy_result.stdout), checks.MAX_COMMAND_OUTPUT_BYTES)
            self.assertLessEqual(len(noisy_result.stderr), checks.MAX_COMMAND_OUTPUT_BYTES)

            if killed.exists():
                killed.unlink()
            ready = root / "ready"
            signal_code = (
                "import signal,sys,time\n"
                "open(sys.argv[1],'w').write(str(__import__('os').getpid()))\n"
                "signal.signal(signal.SIGTERM,lambda *_:(open(sys.argv[2],'w').close(),sys.exit(0)))\n"
                "open(sys.argv[3],'w').close()\n"
                "time.sleep(60)\n"
            )
            signal_runner = subprocess.Popen(
                [sys.executable, runner, "--run-bounded", "30", "--", sys.executable, "-c", signal_code, str(child_pid), str(killed), str(ready)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            )
            for _ in range(40):
                if ready.exists():
                    break
                time.sleep(0.05)
            time.sleep(0.1)
            signal_runner.terminate()
            signal_result = signal_runner.communicate(timeout=8)
            self.assertEqual(signal_runner.returncode, 143, signal_result[1])
            self.assertTrue(killed.exists())

            startup_pid = root / "startup.pid"
            startup_signal_code = (
                "import os,signal,sys,time\n"
                "open(sys.argv[1],'w').write(str(os.getpid()))\n"
                "os.kill(os.getppid(),signal.SIGTERM)\n"
                "time.sleep(60)\n"
            )
            startup_result = subprocess.run(
                [
                    sys.executable, runner, "--run-bounded", "30", "--", sys.executable,
                    "-c", startup_signal_code, str(startup_pid),
                ],
                capture_output=True, text=True, timeout=8,
            )
            self.assertEqual(startup_result.returncode, 143, startup_result.stderr)
            self.assertTrue(startup_pid.exists())
            startup_child_pid = int(startup_pid.read_text(encoding="utf-8"))
            for _ in range(40):
                try:
                    os.kill(startup_child_pid, 0)
                except OSError:
                    break
                time.sleep(0.05)
            else:
                self.fail(f"startup cancellation left child {startup_child_pid}")

            rejected_runner = ROOT / "scripts" / "install_personal_device_checks.py"
            rejected_result = subprocess.run(
                [
                    sys.executable, str(rejected_runner), "--run-bounded", "1", "--",
                    sys.executable, "-c", "import time; time.sleep(60)",
                ],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(rejected_result.returncode, 2)
            self.assertEqual(rejected_result.stdout, "")

            foreign_helper = root / "foreign_install_personal_device_checks.py"
            foreign_helper.write_text(
                "import sys; print('foreign helper executed'); raise SystemExit(0)\n",
                encoding="utf-8",
            )
            foreign_result = subprocess.run(
                [
                    sys.executable, str(rejected_runner), "--run-bounded", "1", "--",
                    "/usr/bin/python3", "-B", str(foreign_helper), "--devices", str(foreign_helper),
                ],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(foreign_result.returncode, 2)
            self.assertNotIn("foreign helper executed", foreign_result.stdout + foreign_result.stderr)

            xcrun_result = subprocess.run(
                [
                    sys.executable, str(rejected_runner), "--run-bounded", "1", "--",
                    "/usr/bin/xcrun", "python3", "-c", "import os; os._exit(0)",
                ],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(xcrun_result.returncode, 2)

            detached_code = (
                "import os,sys,time\n"
                "pid=os.fork()\n"
                "if pid:\n    os._exit(0)\n"
                "os.setsid()\n"
                "os.chdir('/')\n"
                "open(sys.argv[1],'w').write(str(os.getpid()))\n"
                "time.sleep(60)\n"
            )
            detached_pid = root / "detached.pid"
            detached_result = subprocess.run(
                [
                    sys.executable, str(rejected_runner), "--run-bounded", "1", "--",
                    sys.executable, "-c", detached_code, str(detached_pid),
                ],
                capture_output=True, text=True, timeout=5,
            )
            self.assertEqual(detached_result.returncode, 2)
            self.assertFalse(detached_pid.exists())

    def test_signed_bundle_validator_checks_team_profile_device_and_all_groups(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-device-fixture-") as directory:
            root = Path(directory)
            metadata = root / "codesign.txt"
            entitlements = root / "entitlements.plist"
            profile = root / "profile.plist"
            metadata.write_text(
                f"Identifier={APP_BUNDLE}\nTeamIdentifier={TEAM}\n",
                encoding="utf-8",
            )
            write_plist(entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })

            widget_metadata = root / "widget-codesign.txt"
            widget_entitlements = root / "widget-entitlements.plist"
            widget_profile = root / "widget-profile.plist"
            widget_metadata.write_text(
                f"Identifier={WIDGET_BUNDLE}\nTeamIdentifier={TEAM}\n",
                encoding="utf-8",
            )
            write_plist(widget_entitlements, {
                "application-identifier": f"{TEAM}.{WIDGET_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })
            write_plist(widget_profile, profile_for(WIDGET_BUNDLE))
            widget_args = (
                str(widget_metadata), str(widget_entitlements), str(widget_profile), TEAM,
                WIDGET_BUNDLE, UDID, APP_GROUP,
            )
            self.assertIsNone(checks.validate_signed_bundle(*widget_args))
            write_plist(widget_entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })
            self.assertEqual(checks.validate_signed_bundle(*widget_args), "signing")
            write_plist(profile, profile_for(APP_BUNDLE))
            args = (
                str(metadata), str(entitlements), str(profile), TEAM,
                APP_BUNDLE, UDID, APP_GROUP,
            )
            self.assertIsNone(checks.validate_signed_bundle(*args))

            entitlements.write_text(
                """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>WRONG</string>
<key>application-identifier</key><string>ABCDE12345.com.hermes.lifeos.app</string>
<key>com.apple.developer.team-identifier</key><string>ABCDE12345</string>
<key>com.apple.security.application-groups</key><array><string>group.com.hermes.lifeos</string></array>
</dict></plist>""",
                encoding="utf-8",
            )
            self.assertEqual(checks.validate_signed_bundle(*args), "signing")
            write_plist(entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })

            write_plist(entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP, "group.placeholder"],
            })
            self.assertEqual(checks.validate_signed_bundle(*args), "app-group")
            write_plist(entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP, "group.com.hermes.other"],
            })
            self.assertEqual(checks.validate_signed_bundle(*args), "profile")
            write_plist(entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })

            write_plist(entitlements, {"com.apple.security.application-groups": [APP_GROUP]})
            self.assertEqual(checks.validate_signed_bundle(*args), "signing")
            write_plist(entitlements, {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })

            metadata.write_text(
                f"Identifier={APP_BUNDLE}\nTeamIdentifier=WRONGTEAM1\n",
                encoding="utf-8",
            )
            self.assertEqual(checks.validate_signed_bundle(*args), "signing")
            metadata.write_text(
                f"Identifier={APP_BUNDLE}\nTeamIdentifier={TEAM}\n",
                encoding="utf-8",
            )

            write_plist(profile, profile_for(APP_BUNDLE, expires=datetime.now(timezone.utc) - timedelta(seconds=1)))
            self.assertEqual(checks.validate_signed_bundle(*args), "profile")
            write_plist(profile, profile_for(APP_BUNDLE, udid=OTHER_UDID))
            self.assertEqual(checks.validate_signed_bundle(*args), "profile")
            profile.write_text("<not-a-plist", encoding="utf-8")
            self.assertEqual(checks.validate_signed_bundle(*args), "profile")

    def test_command_flow_rejects_ambiguous_or_unreachable_devices_before_build(self) -> None:
        result, markers = self._run_flow([device_record(), device_record(OTHER_UDID)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous-connected-iphone", result.stderr)
        self.assertNotIn("build-called", markers)
        self.assertNotIn("install-called", markers)

        result, markers = self._run_flow(
            [device_record(state="disconnected", tunnel="disconnected")],
            device_udid=UDID,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("device-not-connected", result.stderr)
        self.assertNotIn("build-called", markers)
        self.assertNotIn("install-called", markers)

        result, markers = self._run_flow([device_record()], device_udid=OTHER_UDID)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("device-not-connected", result.stderr)
        self.assertNotIn("install-called", markers)

        result, markers = self._run_flow([device_record()], malformed_devices=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("device-discovery", result.stderr)
        self.assertNotIn("build-called", markers)
        self.assertNotIn("install-called", markers)

    def test_command_flow_never_installs_after_build_sign_or_profile_failure(self) -> None:
        cases = (
            ({"build_fail": "1"}, "build-failure"),
            ({"codesign_fail": "1"}, "signing-failure"),
            ({"expired_profile": "1"}, "profile-failure"),
        )
        for options, expected in cases:
            with self.subTest(expected=expected):
                result, markers = self._run_flow(
                    [device_record()], diagnostic="stub-diagnostic-sentinel", **options,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("stub-diagnostic-sentinel", result.stdout + result.stderr)
                self.assertNotIn("install-called", markers)

    def test_command_flow_validates_app_and_widget_identity_groups_and_profiles(self) -> None:
        cases = (
            ("app-identity", "signing-failure"),
            ("widget-identity", "signing-failure"),
            ("app-group", "app-group-failure"),
            ("widget-group", "app-group-failure"),
            ("app-profile", "profile-failure"),
            ("widget-profile", "profile-failure"),
            ("malformed-app-profile", "profile-failure"),
            ("malformed-widget-profile", "profile-failure"),
            ("security-tool", "profile-failure"),
            ("app-info-duplicate", "app-missing"),
            ("widget-info-duplicate", "signing-failure"),
        )
        for failure, expected in cases:
            with self.subTest(failure=failure):
                result, markers = self._run_flow(
                    [device_record()],
                    bundle_failure=failure,
                    diagnostic="stub-diagnostic-sentinel",
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertNotIn("stub-diagnostic-sentinel", result.stdout + result.stderr)
                self.assertNotIn("install-called", markers)

    def test_installer_cancellation_cleans_discovery_supervisor_and_preserves_status(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-device-cancel-") as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            state_dir = root / "state"
            bin_dir.mkdir()
            state_dir.mkdir()
            discovery_started = state_dir / "discovery-started"
            discovery_terminated = state_dir / "discovery-terminated"
            install_called = state_dir / "install-called"
            xcrun = f'''#!/bin/bash
set -eu
if [[ "${{1:-}}" == "--find" ]]; then
  printf '%s\\n' "$0"
  exit 0
fi
if [[ " $* " == *" list devices "* ]]; then
  touch "{discovery_started}"
  trap 'touch "{discovery_terminated}"; exit 143' TERM INT HUP
  while true; do sleep 1; done
fi
exit 1
'''
            for name in ("xcodebuild", "codesign", "security"):
                path = bin_dir / name
                path.write_text("#!/bin/bash\nexit 0\n", encoding="utf-8")
                path.chmod(0o755)
            xcrun_path = bin_dir / "xcrun"
            xcrun_path.write_text(xcrun, encoding="utf-8")
            xcrun_path.chmod(0o755)
            installer = self._write_fixture_installer(root, bin_dir)
            environment = os.environ.copy()
            environment.update({
                "PATH": f"{bin_dir}:{environment.get('PATH', '')}",
                "TMPDIR": str(root),
                "DEVELOPMENT_TEAM": TEAM,
                "APP_GROUP_IDENTIFIER": APP_GROUP,
            })
            installer = subprocess.Popen(
                [str(installer), "--development-team", TEAM, "--app-group", APP_GROUP],
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
            )
            for _ in range(100):
                if discovery_started.exists():
                    break
                time.sleep(0.05)
            else:
                installer.kill()
                installer.communicate(timeout=5)
                self.fail("installer did not reach discovery")
            installer.terminate()
            stdout, stderr = installer.communicate(timeout=8)
            self.assertEqual(installer.returncode, 143, stdout + stderr)
            self.assertTrue(discovery_terminated.exists())
            self.assertFalse(install_called.exists())

    def test_command_flow_installs_only_after_all_checks_and_reports_install_failure(self) -> None:
        result, markers = self._run_flow([device_record()])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("device-ready", result.stdout)
        self.assertIn("installed", result.stdout)
        self.assertIn("build-called", markers)
        self.assertIn("install-called", markers)

        result, markers = self._run_flow([device_record()], install_fail="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("install-failure", result.stderr)
        self.assertIn("install-called", markers)

    def test_command_flow_ignores_inherited_python_startup_code(self) -> None:
        result, markers = self._run_flow([device_record()], hostile_python_startup=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("python-startup-executed", markers)
        self.assertIn("install-called", markers)

    def test_production_script_ignores_developer_toolchain_redirects(self) -> None:
        if not Path("/usr/bin/xcrun").is_file():
            self.skipTest("macOS xcrun is unavailable")
        with tempfile.TemporaryDirectory(prefix="lifeos-toolchain-redirect-") as directory:
            root = Path(directory)
            malicious_launcher = root / "Developer" / "usr" / "bin" / "xcrun"
            malicious_tool = root / "Developer" / "usr" / "bin" / "devicectl"
            malicious_tool.parent.mkdir(parents=True)
            sentinel = root / "redirect-executed"
            malicious_launcher.write_text(
                "#!/bin/bash\n"
                f"touch {sentinel}\n"
                "if [[ \"${1:-}\" == \"--find\" ]]; then\n"
                f"  printf '%s\\n' {malicious_tool}\n"
                "  exit 0\n"
                "fi\n"
                "exit 1\n",
                encoding="utf-8",
            )
            malicious_launcher.chmod(0o755)
            malicious_tool.write_text(
                "#!/bin/bash\n"
                f"touch {sentinel}\n"
                "exit 0\n",
                encoding="utf-8",
            )
            malicious_tool.chmod(0o755)
            malicious_xcconfig = root / "malicious.xcconfig"
            malicious_xcconfig.write_text(
                "CODE_SIGN_ALLOCATE = /tmp/malicious\n",
                encoding="utf-8",
            )
            environment = os.environ.copy()
            environment.update({
                "DEVELOPER_DIR": str(root / "Developer"),
                "TOOLCHAINS": "malicious-toolchain",
                "SDKROOT": str(root),
                "XCODE_XCCONFIG_FILE": str(malicious_xcconfig),
                "CODESIGN_ALLOCATE": str(malicious_tool),
                "TMPDIR": str(root),
                "DEVELOPMENT_TEAM": TEAM,
                "APP_GROUP_IDENTIFIER": APP_GROUP,
            })
            positive_control = subprocess.run(
                ["/usr/bin/xcrun", "--find", "devicectl"],
                env=environment,
                capture_output=True,
                text=True,
                timeout=10,
            )
            self.assertEqual(positive_control.returncode, 0, positive_control.stderr)
            self.assertTrue(sentinel.exists(), positive_control.stdout + positive_control.stderr)
            sentinel.unlink()
            environment["LIFEOS_DEVICE_UDID"] = "00000000-0000-0000-0000-000000000000"
            result = subprocess.run(
                [str(SCRIPT), "--development-team", TEAM, "--app-group", APP_GROUP],
                env=environment,
                capture_output=True,
                text=True,
                timeout=20,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(sentinel.exists(), result.stdout + result.stderr)

    def test_output_is_sanitized_and_install_is_after_signed_validation(self) -> None:
        self.assertIn("--validate-bundle", self.source)
        self.assertIn("verify_bundle_or_die", self.source)
        self.assertLess(self.source.index("verify_bundle_or_die"), self.source.index("device install app"))
        self.assertNotRegex(
            self.source,
            re.compile(r"-----BEGIN|password|api[_-]?key|private[_-]?key|secret", re.IGNORECASE),
        )
        self.assertIn("printf 'LifeOS device: %s\\n'", self.source)

    def _run_flow(
        self,
        devices: list[dict[str, object]],
        *,
        device_udid: str | None = None,
        build_fail: str = "0",
        codesign_fail: str = "0",
        expired_profile: str = "0",
        install_fail: str = "0",
        malformed_devices: bool = False,
        diagnostic: str = "",
        bundle_failure: str = "",
        hostile_python_startup: bool = False,
    ) -> tuple[subprocess.CompletedProcess[str], set[str]]:
        with tempfile.TemporaryDirectory(prefix="lifeos-device-flow-") as directory:
            root = Path(directory)
            bin_dir = root / "bin"
            state_dir = root / "state"
            bin_dir.mkdir()
            state_dir.mkdir()
            device_fixture: object = {"result": {"devices": "malformed"}} if malformed_devices else device_payload(*devices)
            (root / "devices.json").write_text(json.dumps(device_fixture), encoding="utf-8")
            expires = (
                datetime.now(timezone.utc) - timedelta(days=1)
                if expired_profile == "1" else None
            )
            app_profile = profile_for(APP_BUNDLE, expires=expires)
            widget_profile = profile_for(WIDGET_BUNDLE, expires=expires)
            if bundle_failure == "app-profile":
                app_profile["ProvisionedDevices"] = [OTHER_UDID]
            elif bundle_failure == "widget-profile":
                widget_profile["ProvisionedDevices"] = [OTHER_UDID]
            write_plist(root / "app-profile.plist", app_profile)
            write_plist(root / "widget-profile.plist", widget_profile)
            if bundle_failure == "malformed-app-profile":
                (root / "app-profile.plist").write_text("<not-a-plist", encoding="utf-8")
            elif bundle_failure == "malformed-widget-profile":
                (root / "widget-profile.plist").write_text("<not-a-plist", encoding="utf-8")
            write_plist(root / "app-entitlements.plist", {
                "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })
            write_plist(root / "widget-entitlements.plist", {
                "application-identifier": f"{TEAM}.{WIDGET_BUNDLE}",
                "com.apple.developer.team-identifier": TEAM,
                "com.apple.security.application-groups": [APP_GROUP],
            })
            if bundle_failure == "app-identity":
                write_plist(root / "app-entitlements.plist", {
                    "application-identifier": f"{TEAM}.com.hermes.invalid",
                    "com.apple.developer.team-identifier": TEAM,
                    "com.apple.security.application-groups": [APP_GROUP],
                })
            elif bundle_failure == "widget-identity":
                write_plist(root / "widget-entitlements.plist", {
                    "application-identifier": f"{TEAM}.com.hermes.invalid.widget",
                    "com.apple.developer.team-identifier": TEAM,
                    "com.apple.security.application-groups": [APP_GROUP],
                })
            elif bundle_failure == "app-group":
                write_plist(root / "app-entitlements.plist", {
                    "application-identifier": f"{TEAM}.{APP_BUNDLE}",
                    "com.apple.developer.team-identifier": TEAM,
                    "com.apple.security.application-groups": ["group.com..invalid"],
                })
            elif bundle_failure == "widget-group":
                write_plist(root / "widget-entitlements.plist", {
                    "application-identifier": f"{TEAM}.{WIDGET_BUNDLE}",
                    "com.apple.developer.team-identifier": TEAM,
                    "com.apple.security.application-groups": ["group.com..invalid"],
                })
            self._write_stubs(bin_dir)
            installer = self._write_fixture_installer(root, bin_dir)
            environment = os.environ.copy()
            for key in (
                "DEVELOPMENT_TEAM",
                "LIFEOS_DEVELOPMENT_TEAM",
                "APP_GROUP_IDENTIFIER",
                "LIFEOS_APP_GROUP_IDENTIFIER",
                "LIFEOS_DEVICE_UDID",
            ):
                environment.pop(key, None)
            environment.update({
                "PATH": f"{bin_dir}:{environment.get('PATH', '')}",
                "TMPDIR": str(root),
                "DEVELOPMENT_TEAM": TEAM,
                "APP_GROUP_IDENTIFIER": APP_GROUP,
                "LIFEOS_DEVICE_UDID": device_udid or "",
                "LIFEOS_STUB_DEVICE_JSON": str(root / "devices.json"),
                "LIFEOS_STUB_STATE_DIR": str(state_dir),
                "LIFEOS_STUB_APP_PROFILE": str(root / "app-profile.plist"),
                "LIFEOS_STUB_WIDGET_PROFILE": str(root / "widget-profile.plist"),
                "LIFEOS_STUB_APP_ENTITLEMENTS": str(root / "app-entitlements.plist"),
                "LIFEOS_STUB_WIDGET_ENTITLEMENTS": str(root / "widget-entitlements.plist"),
                "LIFEOS_STUB_BUILD_FAIL": build_fail,
                "LIFEOS_STUB_CODESIGN_FAIL": codesign_fail,
                "LIFEOS_STUB_INSTALL_FAIL": install_fail,
                "LIFEOS_STUB_DIAGNOSTIC": diagnostic,
                "LIFEOS_STUB_SECURITY_FAIL": "1" if bundle_failure == "security-tool" else "0",
                "LIFEOS_STUB_DUPLICATE_INFO": bundle_failure,
            })
            if hostile_python_startup:
                hostile_python_path = root / "hostile-python"
                hostile_python_path.mkdir()
                (hostile_python_path / "sitecustomize.py").write_text(
                    "from pathlib import Path\n"
                    "import os\n"
                    "Path(os.environ['LIFEOS_STUB_STATE_DIR']).joinpath('python-startup-executed').touch()\n",
                    encoding="utf-8",
                )
                (hostile_python_path / "json.py").write_text(
                    "raise RuntimeError('hostile PYTHONPATH import')\n",
                    encoding="utf-8",
                )
                environment["PYTHONPATH"] = str(hostile_python_path)
            arguments = [str(installer), "--development-team", TEAM, "--app-group", APP_GROUP]
            result = subprocess.run(
                arguments, env=environment, capture_output=True, text=True, timeout=20,
            )
            markers = {path.name for path in state_dir.iterdir() if path.is_file()}
            return result, markers

    @staticmethod
    def _write_stubs(bin_dir: Path) -> None:
        xcrun = r'''#!/bin/bash
set -eu
state="${LIFEOS_STUB_STATE_DIR:?}"
if [[ "${1:-}" == "--find" ]]; then
  printf '%s\n' "$0"
  exit 0
fi
if [[ " $* " == *" list devices "* ]]; then
  output=""
  previous=""
  for argument in "$@"; do
    if [[ "$previous" == "--json-output" ]]; then output="$argument"; fi
    previous="$argument"
  done
  cp "${LIFEOS_STUB_DEVICE_JSON:?}" "$output"
  exit 0
fi
if [[ " $* " == *" device install app "* ]]; then
  touch "$state/install-called"
  if [[ "${LIFEOS_STUB_INSTALL_FAIL:-0}" == "1" ]]; then
    printf '%s\n' "${LIFEOS_STUB_DIAGNOSTIC:-}" >&2
    exit 1
  fi
  exit 0
fi
exit 1
'''
        xcodebuild = r'''#!/bin/bash
set -eu
touch "${LIFEOS_STUB_STATE_DIR:?}/build-called"
if [[ "${LIFEOS_STUB_BUILD_FAIL:-0}" == "1" ]]; then
  printf '%s\n' "${LIFEOS_STUB_DIAGNOSTIC:-}" >&2
  exit 65
fi
derived=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-derivedDataPath" ]]; then derived="$argument"; fi
  previous="$argument"
done
app="$derived/Build/Products/Debug-iphoneos/LifeOS.app"
widget="$app/PlugIns/LifeOSWidget.appex"
mkdir -p "$widget"
if [[ "${LIFEOS_STUB_DUPLICATE_INFO:-}" == "app-info-duplicate" ]]; then
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>wrong</string><key>CFBundleIdentifier</key><string>com.hermes.lifeos.app</string></dict></plist>
PLIST
else
cat > "$app/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.hermes.lifeos.app</string></dict></plist>
PLIST
fi
if [[ "${LIFEOS_STUB_DUPLICATE_INFO:-}" == "widget-info-duplicate" ]]; then
cat > "$widget/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>wrong</string><key>CFBundleIdentifier</key><string>com.hermes.lifeos.app.widget</string></dict></plist>
PLIST
else
cat > "$widget/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.hermes.lifeos.app.widget</string></dict></plist>
PLIST
fi
cp "${LIFEOS_STUB_APP_PROFILE:?}" "$app/embedded.mobileprovision"
cp "${LIFEOS_STUB_WIDGET_PROFILE:?}" "$widget/embedded.mobileprovision"
cp "${LIFEOS_STUB_APP_ENTITLEMENTS:?}" "$app/entitlements.plist"
cp "${LIFEOS_STUB_WIDGET_ENTITLEMENTS:?}" "$widget/entitlements.plist"
'''
        codesign = r'''#!/bin/bash
set -eu
bundle="${!#}"
if [[ "${LIFEOS_STUB_CODESIGN_FAIL:-0}" == "1" && "${1:-}" == "--verify" ]]; then
  printf '%s\n' "${LIFEOS_STUB_DIAGNOSTIC:-}" >&2
  exit 1
fi
case "${1:-}" in
  --verify) exit 0 ;;
  --display)
    if [[ "$bundle" == *.appex ]]; then
      printf 'Identifier=com.hermes.lifeos.app.widget\nTeamIdentifier=ABCDE12345\n'
    else
      printf 'Identifier=com.hermes.lifeos.app\nTeamIdentifier=ABCDE12345\n'
    fi
    ;;
  -d) cat "$bundle/entitlements.plist" ;;
  *) exit 1 ;;
esac
'''
        security = r'''#!/bin/bash
set -eu
if [[ "${LIFEOS_STUB_SECURITY_FAIL:-0}" == "1" ]]; then
  printf '%s\n' "${LIFEOS_STUB_DIAGNOSTIC:-}" >&2
  exit 1
fi
input=""
output=""
previous=""
for argument in "$@"; do
  if [[ "$previous" == "-i" ]]; then input="$argument"; fi
  if [[ "$previous" == "-o" ]]; then output="$argument"; fi
  previous="$argument"
done
cp "$input" "$output"
'''
        for name, contents in {
            "xcrun": xcrun,
            "xcodebuild": xcodebuild,
            "codesign": codesign,
            "security": security,
        }.items():
            path = bin_dir / name
            path.write_text(contents, encoding="utf-8")
            path.chmod(0o755)

    @staticmethod
    def _write_fixture_installer(root: Path, bin_dir: Path) -> Path:
        root = root.resolve()
        bin_dir = bin_dir.resolve()
        fixture_repo = root / "repo"
        fixture_scripts = fixture_repo / "scripts"
        fixture_project = fixture_repo / "ios" / "LifeOS.xcodeproj"
        fixture_scripts.mkdir(parents=True)
        fixture_project.mkdir(parents=True)
        helper_source = (ROOT / "scripts" / "install_personal_device_checks.py").read_text(encoding="utf-8")
        for tool_name in ("xcrun", "xcodebuild", "codesign", "security"):
            helper_source = helper_source.replace(
                f'"/usr/bin/{tool_name}"',
                f'"{bin_dir}/{tool_name}"',
            )
        helper_source = helper_source.replace(
            '"/Users/georgdomke/Developer/life-tracking/scripts/install_personal_device_checks.py"',
            f'"{fixture_scripts / "install_personal_device_checks.py"}"',
        )
        (fixture_scripts / "install_personal_device_checks.py").write_text(
            helper_source, encoding="utf-8",
        )
        shutil.copy2(ROOT / "ios" / "LifeOS.xcodeproj" / "project.pbxproj", fixture_project)
        source = SCRIPT.read_text(encoding="utf-8").replace(
            'tool_path="/usr/bin/$tool_name"',
            f'tool_path="{bin_dir}/$tool_name"',
        )
        installer = fixture_scripts / "install_personal_device.sh"
        installer.write_text(source, encoding="utf-8")
        installer.chmod(0o755)
        return installer

    @staticmethod
    def _write_fixture_checks(root: Path) -> Path:
        root = root.resolve()
        source = (ROOT / "scripts" / "install_personal_device_checks.py").read_text(encoding="utf-8")
        source = source.replace(
            '"/Users/georgdomke/Developer/life-tracking/scripts/install_personal_device_checks.py"',
            f'"{root / "install_personal_device_checks_fixture.py"}"',
        )
        source = source.replace(
            "TEST_EXECUTABLES = frozenset()",
            f"TEST_EXECUTABLES = frozenset({{{sys.executable!r}}})",
        )
        runner = root / "install_personal_device_checks_fixture.py"
        runner.write_text(source, encoding="utf-8")
        return runner


if __name__ == "__main__":
    unittest.main()
