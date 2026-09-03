"""Dependency-free checks for the source-bound Windows candidate tooling."""

from __future__ import annotations

import re
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "scripts" / "build_windows_release.sh"
VERIFIER = ROOT / "services" / "windows-service-host" / "deploy" / "verify-candidate.ps1"
COMMON = ROOT / "services" / "windows-service-host" / "deploy" / "Deployment.Common.ps1"
LEGACY_TEST = (
    ROOT
    / "services"
    / "windows-service-host"
    / "deploy"
    / "tests"
    / "Deployment.LegacyServe.Tests.ps1"
)


def _shell_array(source: str, name: str) -> list[str]:
    match = re.search(
        rf"(?ms)^{re.escape(name)}=\((?P<body>.*?)\)", source
    )
    if match is None:
        raise AssertionError(f"missing shell array: {name}")
    return re.findall(r"[A-Za-z0-9._/-]+", match.group("body"))


def _verifier_allowlist(source: str) -> list[str]:
    match = re.search(r"(?ms)^\$expectedFiles = @\(\n(?P<body>.*?)^\)", source)
    if match is None:
        raise AssertionError("missing candidate verifier allowlist")
    return re.findall(r"(?m)^\s+'([^']+)'\s*$", match.group("body"))


class WindowsReleaseBuilderTests(unittest.TestCase):
    def test_help_is_available_without_build_dependencies_or_source_inputs(self) -> None:
        result = subprocess.run(
            ["bash", str(BUILDER), "--help"],
            cwd=ROOT,
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("--node-source", result.stdout + result.stderr)

    def test_planned_copy_destinations_match_verifier_and_are_unique(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        verifier = VERIFIER.read_text(encoding="utf-8")

        api_dist = _shell_array(builder, "api_dist_files")
        contracts_dist = _shell_array(builder, "contract_dist_files")
        zod_root = _shell_array(builder, "zod_root_files")
        zod_files = _shell_array(builder, "zod_files")
        gateway = _shell_array(builder, "gateway_files")
        deploy = _shell_array(builder, "deploy_files")
        deploy_tests = _shell_array(builder, "deploy_test_files")

        for name, values in (
            ("api_dist_files", api_dist),
            ("contract_dist_files", contracts_dist),
            ("zod_root_files", zod_root),
            ("zod_files", zod_files),
            ("gateway_files", gateway),
            ("deploy_files", deploy),
            ("deploy_test_files", deploy_tests),
        ):
            self.assertEqual(len(values), len(set(values)), f"duplicate source in {name}")

        planned: list[str] = ["SOURCE_SHA.txt", "api/package.json"]
        planned.extend(f"api/dist/{name}" for name in api_dist)
        planned.append("api/node_modules/@iphone-life-os/contracts/package.json")
        planned.extend(
            f"api/node_modules/@iphone-life-os/contracts/dist/{name}"
            for name in contracts_dist
        )
        planned.extend(f"api/node_modules/zod/{name}" for name in zod_root)
        planned.extend(f"api/node_modules/zod/{name}" for name in zod_files)
        planned.extend(f"gateway/{name}" for name in gateway)
        planned.append("windows-service-host/deploy/gateway_launcher.py")
        planned.extend(f"deploy/{name}" for name in deploy)
        planned.extend(f"deploy/tests/{name}" for name in deploy_tests)
        planned.extend(
            ["node-runtime/node.exe", "service-host/LifeOS.ServiceHost.exe"]
        )

        allowlist = _verifier_allowlist(verifier)
        self.assertEqual(len(planned), len(set(planned)), "duplicate candidate destination")
        self.assertEqual(len(allowlist), len(set(allowlist)), "duplicate verifier allowlist entry")
        self.assertEqual(set(planned), set(allowlist))

    def test_builder_is_source_bound_and_does_not_copy_runtime_trees(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        self.assertIn("git -C \"$repo_root\" status --porcelain=v1", builder)
        self.assertIn('[[ "$source_sha" == "$origin_sha" ]]', builder)
        self.assertIn("git -C \"$repo_root\" rev-parse HEAD", builder)
        self.assertIn("node-runtime/node.exe", builder)
        self.assertIn("never copies a user Hermes node tree", builder)
        self.assertNotRegex(builder, r"\b(?:cp|rsync)\s+(?:-[A-Za-z]+\s+)*-[rR]\b")
        self.assertNotIn('cp -p "$repo_root/node_modules"', builder)
        self.assertIn("CANDIDATE-MANIFEST.sha256", builder)
        self.assertIn("lifeos-release-$source_sha.zip", builder)

    def test_verifier_rejects_links_unexpected_files_and_unsafe_manifest_paths(self) -> None:
        verifier = VERIFIER.read_text(encoding="utf-8")
        self.assertIn("ReparsePoint", verifier)
        self.assertIn("Candidate file allowlist mismatch", verifier)
        self.assertIn("Candidate manifest paths are not sorted deterministically", verifier)
        self.assertIn("Candidate manifest path is unsafe", verifier)
        self.assertIn("CANDIDATE-MANIFEST.sha256", verifier)
        self.assertIn("[System.StringComparer]::Ordinal", verifier)
        self.assertIn("[A-Za-z0-9@]", verifier)
        self.assertIn("(?:\\.{1,2})", verifier)

    def test_legacy_fake_is_windows_powershell_5_1_compatible(self) -> None:
        legacy_test = LEGACY_TEST.read_text(encoding="utf-8")
        self.assertIn("param()\n$Arguments = @($args)", legacy_test)
        self.assertNotIn("ValueFromRemainingArguments", legacy_test)

    def test_restore_helpers_do_not_emit_raw_serve_json(self) -> None:
        common = COMMON.read_text(encoding="utf-8")
        helper_start = common.index("function Restore-TailscaleServeLegacyMapping")
        snapshot_start = common.index("function Restore-TailscaleServeSnapshot")
        write_start = common.index("function Write-JsonAtomic")
        helper = common[helper_start:snapshot_start]
        snapshot = common[snapshot_start:write_start]
        self.assertNotRegex(helper, r"return\s+\$[A-Za-z_]")
        self.assertNotRegex(snapshot, r"return\s+\$[A-Za-z_]")
        self.assertIn("$null = Restore-TailscaleServeLegacyMapping", snapshot)

        fingerprint_start = common.index("function Get-TailscaleServeFingerprint")
        fingerprint_end = common.index("function Test-TailscaleServeEmpty")
        fingerprint = common[fingerprint_start:fingerprint_end]
        self.assertIn("Remove($mirrorName)", fingerprint)
        self.assertNotIn("Properties.Remove('TCP')", fingerprint)

        behavior = (
            ROOT
            / "services"
            / "windows-service-host"
            / "deploy"
            / "tests"
            / "Deployment.Behavior.Tests.ps1"
        ).read_text(encoding="utf-8")
        self.assertIn("Restore-TailscaleServeSnapshot", behavior)
        self.assertIn("| Out-Null", behavior)
        self.assertIn("$restored = Get-TailscaleStatusJson", behavior)


if __name__ == "__main__":
    unittest.main()
