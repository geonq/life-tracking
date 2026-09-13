"""Static, dependency-free tests for Native Apple workflow gating."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github" / "workflows" / "native-apple.yml"

NATIVE_EXACT_PATHS = {
    "scripts/lane_manifest.py",
    "scripts/native_lane_manifest.json",
    "scripts/validate_apple_on_mac.sh",
    "scripts/run_prerelease_lanes.sh",
}
def native_matrix_required(paths: list[str]) -> bool:
    """Mirror the workflow's bounded native-path case statement."""

    return any(
        path.startswith("ios/")
        or path in NATIVE_EXACT_PATHS
        for path in paths
    )


class NativeWorkflowGatingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = WORKFLOW.read_text(encoding="utf-8")

    def test_native_validation_is_manual_only(self) -> None:
        self.assertNotRegex(self.source, r"(?ms)^  push:\n")
        self.assertNotIn("pull_request:", self.source)
        self.assertIn("  workflow_dispatch:", self.source)
        self.assertNotIn("dorny/paths-filter", self.source)

    def test_manual_runs_have_a_non_xcode_contract_job(self) -> None:
        self.assertIn("  contract-check:\n", self.source)
        self.assertIn("name: Registry and source contracts", self.source)
        self.assertIn("scripts/validate_acceptance_registry.py", self.source)
        self.assertIn("python3 -B -m unittest discover -s scripts/tests -p 'test_*.py' -v", self.source)
        self.assertNotIn("xcodebuild", self.source.split("  contract-check:", 1)[1].split("  apple-lanes:", 1)[0])

    def test_native_job_is_output_gated_and_manual_dispatch_bypasses_classification(self) -> None:
        self.assertIn("outputs:\n      native: ${{ steps.changes.outputs.native }}", self.source)
        self.assertIn("lanes: ${{ steps.changes.outputs.lanes }}", self.source)
        self.assertIn(
            "if: needs.classify.outputs.native == 'true' || github.event_name == 'workflow_dispatch'",
            self.source,
        )
        self.assertIn('if [[ "$EVENT_NAME" == "workflow_dispatch" ]]; then', self.source)
        self.assertIn("${{ fromJSON(needs.classify.outputs.lanes) }}", self.source)

    def test_pr_synchronize_uses_incremental_head_diff(self) -> None:
        self.assertIn('ACTION: ${{ github.event.action }}', self.source)
        self.assertIn('AFTER_SHA: ${{ github.event.after }}', self.source)
        self.assertIn('HEAD_SHA: ${{ github.event.pull_request.head.sha }}', self.source)
        self.assertIn('"$ACTION" == "synchronize"', self.source)
        self.assertIn('git cat-file -e "${BEFORE_SHA}^{commit}"', self.source)
        self.assertIn('git diff --name-only "$BEFORE_SHA" "$AFTER_SHA"', self.source)
        self.assertIn('git diff --name-only "$BASE_SHA" "$HEAD_SHA"', self.source)

    def test_path_policy_keeps_docs_registry_and_workflow_changes_cheap(self) -> None:
        self.assertNotIn("ios/*|.github/workflows/native-apple.yml", self.source)
        classifier = self.source.split("          while IFS= read -r path; do", 1)[1].split("          done <", 1)[0]
        self.assertNotIn("scripts/tests/*", classifier)
        self.assertNotIn("scripts/validate_native_release.py", classifier)
        self.assertIn("scripts/native_lane_manifest.json", classifier)
        self.assertIn('lanes={"include":[{"lane":"ios-logic"}', self.source)

    def test_path_behavior_matrix_is_deterministic(self) -> None:
        cases = {
            ("docs/LIFEOS_ACCEPTANCE_REGISTRY.md",): False,
            ("scripts/validate_acceptance_registry.py",): False,
            ("scripts/tests/test_validate_acceptance_registry.py",): False,
            (".github/workflows/native-apple.yml",): False,
            ("ios/project.yml",): True,
            ("scripts/validate_native_release.py",): False,
            ("scripts/tests/test_native_release.py",): False,
            ("docs/LIFEOS_ACCEPTANCE_REGISTRY.md", "ios/project.yml"): True,
        }
        for paths, expected in cases.items():
            with self.subTest(paths=paths):
                self.assertEqual(native_matrix_required(list(paths)), expected)

    def test_source_only_tests_do_not_force_native_matrix(self) -> None:
        classifier = self.source.split("          while IFS= read -r path; do", 1)[1].split("          done <", 1)[0]
        self.assertNotIn("scripts/tests/*", classifier)
        self.assertIn("scripts/native_lane_manifest.json", classifier)


if __name__ == "__main__":
    unittest.main()
