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
GATEWAY_LOCK = ROOT / "services" / "gateway" / "requirements.lock"
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
        self.assertIn("--wheelhouse", result.stdout + result.stderr)

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
        planned.append("gateway/wheelhouse/ALLOWLIST.sha256")
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

    def test_builder_checks_every_staged_module_before_packaging_without_credentials(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        self.assertIn('env -i NODE_ENV=test "$node_binary"', builder)
        self.assertIn("await import(pathToFileURL(file).href)", builder)
        for root in ("api/dist", "api/node_modules/@iphone-life-os/contracts/dist", "api/node_modules/zod"):
            self.assertIn(repr(root), builder)
        self.assertLess(builder.index("Staged JavaScript import closure failed"), builder.index('archive_tmp='))
        self.assertNotIn("console.error(error)", builder)

    def test_python_dependency_lock_is_validated_and_digest_bound_without_downloads(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        verifier = VERIFIER.read_text(encoding="utf-8")
        lock = GATEWAY_LOCK.read_text(encoding="utf-8")

        self.assertIn('gateway_lock_source="$repo_root/services/gateway/requirements.lock"', builder)
        self.assertIn("--wheelhouse", builder)
        self.assertIn("wheelhouse.contract", builder)
        self.assertIn("ALLOWLIST.sha256", builder)
        self.assertIn("MAX_WHEEL_MEMBERS", builder)
        self.assertIn("reject_path_redirection", builder)
        self.assertIn("gateway dependency lock line", builder)
        self.assertIn("gateway/wheelhouse/", builder)
        self.assertIn("staged gateway dependency lock digest mismatch", builder)
        self.assertNotIn("pip download", builder)
        self.assertNotIn("curl ", builder)
        self.assertLess(
            builder.index('gateway_lock_sha="$(python3'),
            builder.index('archive_tmp='),
            "the lock must be validated before the release archive is created",
        )
        self.assertIn("Read-CandidateGatewayDependencyLock", verifier)
        self.assertIn("manifestHashes['gateway/requirements.lock']", verifier)
        self.assertIn("Candidate manifest does not bind the gateway dependency lock digest", verifier)

        entry_pattern = re.compile(
            r"\A(?P<name>[A-Za-z0-9][A-Za-z0-9._-]{0,127})=="
            r"(?P<version>[A-Za-z0-9][A-Za-z0-9.!+_-]{0,127})\s+"
            r"--hash=sha256:[0-9a-f]{64}"
            r"\s+#\s+[A-Za-z0-9][A-Za-z0-9._+!-]{0,255}\.whl\Z"
        )
        names: list[str] = []
        wheels: list[str] = []
        for line in lock.splitlines():
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            self.assertIsNotNone(entry_pattern.fullmatch(line), line)
            raw_name = line.split("==", 1)[0]
            names.append(re.sub(r"[-_.]+", "-", raw_name).lower())
            wheels.append(line.split("#", 1)[1].strip())
        self.assertEqual(names, sorted(set(names)))
        self.assertGreater(len(names), 0)
        self.assertEqual(len(wheels), len(set(wheels)))
        self.assertTrue(all(wheel.endswith(".whl") for wheel in wheels))

    def test_node_runtime_size_contract_matches_candidate_verifier(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        verifier = VERIFIER.read_text(encoding="utf-8")
        common = COMMON.read_text(encoding="utf-8")

        self.assertIn("candidate_node_max_file_bytes=$((256 * 1024 * 1024))", builder)
        self.assertIn("candidate_service_host_max_file_bytes=$((256 * 1024 * 1024))", builder)
        self.assertIn("(( node_size <= candidate_node_max_file_bytes ))", builder)
        self.assertIn("$script:LifeOSCandidateNodeMaxFileBytes = 256 * 1024 * 1024", common)
        self.assertIn("$script:LifeOSCandidateServiceHostMaxFileBytes = 256 * 1024 * 1024", common)
        self.assertIn(
            "$maxCandidateNodeFileBytes = [long]$script:LifeOSCandidateNodeMaxFileBytes",
            verifier,
        )
        self.assertIn(
            "$maxCandidateServiceHostFileBytes = [long]$script:LifeOSCandidateServiceHostMaxFileBytes",
            verifier,
        )
        self.assertIn(
            "$maxCandidateBytes = [long]($expectedFiles.Count - 2) * $maxCandidateFileBytes + $maxCandidateNodeFileBytes + $maxCandidateServiceHostFileBytes",
            verifier,
        )
        self.assertIn(
            "$itemMaxBytes = if ($relativePath -ceq 'node-runtime/node.exe')",
            verifier,
        )
        self.assertIn("$relativePath -ceq 'service-host/LifeOS.ServiceHost.exe'", verifier)
        self.assertIn("'service-host/LifeOS.ServiceHost.exe' = $maxCandidateServiceHostFileBytes", verifier)

    def test_builder_applies_the_same_narrow_per_file_bounds_before_copy_and_hash(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        self.assertIn("candidate_max_file_bytes=$((64 * 1024 * 1024))", builder)
        self.assertIn("candidate_node_max_file_bytes=$((256 * 1024 * 1024))", builder)
        self.assertIn("candidate_service_host_max_file_bytes=$((256 * 1024 * 1024))", builder)
        self.assertIn("service-host/LifeOS.ServiceHost.exe)", builder)
        self.assertIn("node-runtime/node.exe)", builder)
        self.assertIn("service-host/LifeOS.ServiceHost.exe)", builder)
        self.assertIn("candidate_file_max_bytes", builder)
        self.assertIn('source_size="$(file_size_bytes "$source")"', builder)
        self.assertIn("candidate input exceeds its bounded size", builder)
        self.assertIn("source API package metadata exceeds the candidate file bound", builder)
        self.assertIn("staged API package metadata exceeds the candidate file bound", builder)
        self.assertIn("candidate file exceeds its bounded size: {relative}", builder)
        self.assertIn(
            'elif relative == "service-host/LifeOS.ServiceHost.exe":',
            builder,
        )
        copy_body = builder.split("copy_file() {", 1)[1].split("echo \"Building contracts", 1)[0]
        self.assertLess(copy_body.index('source_size="$(file_size_bytes "$source")"'), copy_body.index('cp -p "$source"'))
        manifest_body = builder.split("python3 - \"$release_tmp\" \"$release_tmp/CANDIDATE-MANIFEST.sha256\" <<'PY'", 1)[1].split("\nPY", 1)[0]
        self.assertLess(manifest_body.index("path.stat().st_size > max_bytes"), manifest_body.index("path.read_bytes()"))

    def test_verifier_rejects_links_unexpected_files_and_unsafe_manifest_paths(self) -> None:
        verifier = VERIFIER.read_text(encoding="utf-8")
        common = COMMON.read_text(encoding="utf-8")
        self.assertIn("Get-LifeOSBoundedTreeItem", verifier)
        self.assertIn("ReparsePoint", common)
        self.assertIn("Candidate file allowlist mismatch", verifier)
        self.assertIn("Candidate manifest paths are not sorted deterministically", verifier)
        self.assertIn("Candidate manifest path is unsafe", verifier)
        self.assertIn("CANDIDATE-MANIFEST.sha256", verifier)
        self.assertIn("[System.StringComparer]::Ordinal", verifier)
        self.assertIn("[A-Za-z0-9@]", verifier)
        self.assertIn("(?:\\.{1,2})", verifier)

    def test_verifier_enforces_exact_api_package_and_dependency_property_sets(self) -> None:
        verifier = VERIFIER.read_text(encoding="utf-8")
        self.assertIn("Assert-ExactJsonPropertySet", verifier)
        self.assertIn("'name', 'version', 'private', 'type', 'dependencies'", verifier)
        self.assertIn("'@iphone-life-os/contracts', 'zod'", verifier)
        self.assertIn("-isnot [bool]", verifier)

    def test_legacy_suite_covers_live_bare_serve_keys_and_stale_exit_code(self) -> None:
        legacy_test = LEGACY_TEST.read_text(encoding="utf-8")
        self.assertIn("geonqserver.tail5f8789.ts.net:8420", legacy_test)
        self.assertIn("absoluteHttpsCompatibility", legacy_test)
        self.assertIn("$LASTEXITCODE = 23", legacy_test)
        self.assertIn("caller LASTEXITCODE is restored", legacy_test)

    def test_packaging_docs_do_not_claim_bit_for_bit_reproducibility(self) -> None:
        builder = BUILDER.read_text(encoding="utf-8")
        readme = (ROOT / "services" / "windows-service-host" / "deploy" / "README.md").read_text(encoding="utf-8")
        self.assertIn("deterministic packaging", builder)
        self.assertIn("Deterministic Windows candidate packaging", readme)
        self.assertNotIn("source bundle is reproducible", readme)

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
        fingerprint_end = common.index("function Test-TailscaleServeExact")
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
