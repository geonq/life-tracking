"""Focused deterministic tests for the acceptance-registry contract."""

from __future__ import annotations

import copy
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.validate_acceptance_registry import (
    RegistryError,
    load_registry,
    registry_hash,
    score_registry,
    validate_registry,
)


ROOT = Path(__file__).resolve().parents[2]


def leaf(**overrides):
    row = {
        "id": "ZZ-01",
        "aliases": [],
        "workstream": "Test",
        "owner": "test-owner",
        "severity": "P1",
        "source": ["repo://binding/test.md"],
        "acceptance": "The deterministic test behavior passes.",
        "evidence_types": ["unit"],
        "evidence_path": None,
        "evidence_result": None,
        "test_count": None,
        "claim_kind": "interaction",
        "producing_sha": "abc1234",
        "threshold": "all deterministic checks pass",
        "blocker": "acceptance evidence incomplete",
        "status": "foundation",
        "atomic_key": "ZZ-01",
    }
    row.update(overrides)
    return row


def registry(rows=None, **overrides):
    data = {
        "schema_version": 1,
        "state": "UNFROZEN",
        "implementation_baseline_commit": "abc1234",
        "frozen_registry_sha256": None,
        "freeze_manifest": None,
        "aliases": [],
        "rows": rows if rows is not None else [leaf()],
    }
    data.update(overrides)
    return data


class AcceptanceRegistryTests(unittest.TestCase):
    def test_real_registry_is_valid_and_aliases_do_not_inflate_denominator(self):
        data, report = load_registry()
        self.assertEqual(report.errors, ())
        # T0 intentionally keeps the registry UNFROZEN while rows are added;
        # assert accounting against the loaded materialised data instead of a
        # transient leaf count.
        self.assertEqual(report.leaf_count, len(data["rows"]))
        self.assertEqual(report.alias_count, len(data["aliases"]))
        self.assertGreater(report.leaf_count, 0)
        self.assertEqual(report.accepted_count, 0)
        self.assertEqual(report.state, "UNFROZEN")
        self.assertEqual(report.leaf_count, 258)
        self.assertEqual(report.counts_by_workstream()["Calendar"]["leaves"], 13)
        self.assertEqual(report.counts_by_workstream()["Usage"]["leaves"], 18)
        self.assertEqual(report.counts_by_workstream()["Nutrition"]["leaves"], 8)
        required_ids = {"SY-01", "QA-05", "US-02J", "NU-03"}
        self.assertTrue(required_ids.issubset({row["id"] for row in report.rows}))

    def test_duplicate_leaf_ids_are_rejected(self):
        report = validate_registry(registry(rows=[leaf(), copy.deepcopy(leaf())]))
        self.assertTrue(any("duplicate" in error for error in report.errors))

    def test_duplicate_atomic_keys_are_rejected_even_when_ids_differ(self):
        report = validate_registry(
            registry(
                rows=[
                    leaf(id="ZZ-01", atomic_key="same.behavior"),
                    leaf(id="ZZ-02", atomic_key="same.behavior"),
                ]
            )
        )
        self.assertTrue(any("duplicate atomic/non-overlap key" in error for error in report.errors))

    def test_non_overlap_groups_require_known_unique_members_and_boundary(self):
        report = validate_registry(
            registry(
                non_overlap_groups=[
                    {"id": "bad", "leaves": ["ZZ-01", "ZZ-01"], "boundary": ""},
                    {"id": "bad", "leaves": ["ZZ-01", "ZZ-404"], "boundary": "separate"},
                ]
            )
        )
        self.assertTrue(any("non-overlap group bad" in error for error in report.errors))
        self.assertTrue(any("duplicate or empty non-overlap group ID" in error for error in report.errors))

    def test_absolute_source_paths_are_rejected(self):
        report = validate_registry(registry(rows=[leaf(source=["/Users/geonq/private/reference.png"])]))
        self.assertTrue(any("stable design://" in error for error in report.errors))

    def test_alias_must_target_leaf_and_cannot_be_scored(self):
        data = registry(
            aliases=[
                {"alias": "IMG_0001", "leaf_id": "ZZ-01", "source": "design://binding/image.png"},
                {"alias": "ZZ-ALIAS", "leaf_id": "ZZ-01", "source": "design://binding/second.png"},
            ]
        )
        report = validate_registry(data)
        self.assertEqual(report.errors, ())
        self.assertEqual(report.leaf_count, 1)
        self.assertEqual(report.alias_count, 2)

        counted_alias = registry(
            aliases=[{"alias": "ZZ-01", "leaf_id": "ZZ-01", "source": "design://binding/image.png"}]
        )
        report = validate_registry(counted_alias)
        self.assertTrue(any("also a scored leaf" in error for error in report.errors))

    def test_unknown_status_and_evidence_type_are_rejected(self):
        report = validate_registry(registry(rows=[leaf(status="done", evidence_types=["screenshot"])]))
        self.assertTrue(any("unknown status" in error for error in report.errors))
        self.assertTrue(any("unknown evidence type" in error for error in report.errors))

    def test_unknown_claim_kind_is_rejected(self):
        report = validate_registry(registry(rows=[leaf(claim_kind="provider")] ))
        self.assertTrue(any("unknown claim kind" in error for error in report.errors))

    def test_accepted_requires_current_commit_and_evidence_path(self):
        accepted = leaf(status="accepted", blocker="none")
        report = validate_registry(registry(rows=[accepted]))
        self.assertTrue(any("no evidence path" in error for error in report.errors))

        accepted = leaf(
            status="accepted",
            blocker="none",
            evidence_path="repo://artifacts/zz-01.xcresult",
            producing_sha="old1234",
        )
        report = validate_registry(registry(rows=[accepted]))
        self.assertTrue(any("current producing commit" in error for error in report.errors))

    def test_canceled_zero_test_and_fixture_only_live_claims_never_pass(self):
        canceled = leaf(evidence_result="canceled", evidence_path="repo://artifacts/result.xcresult")
        self.assertTrue(any("canceled/zero-test" in error for error in validate_registry(registry(rows=[canceled])).errors))

        zero_test = leaf(
            status="accepted",
            blocker="none",
            evidence_path="repo://artifacts/result.xcresult",
            test_count=0,
        )
        report = validate_registry(registry(rows=[zero_test]))
        self.assertTrue(any("zero-test" in error for error in report.errors))

        fixture = leaf(
            status="accepted",
            blocker="none",
            evidence_path="repo://fixtures/result.json",
            producing_sha="abc1234",
            evidence_result="passed",
            test_count=1,
            claim_kind="live",
        )
        report = validate_registry(registry(rows=[fixture]))
        self.assertTrue(any("fixture/demo" in error for error in report.errors))

    def test_fixture_evidence_is_reserved_for_layout_only_claims(self):
        layout = leaf(
            evidence_path="repo://fixtures/layout.json",
            evidence_result="Demo fixtures · not live provider data",
            claim_kind="layout-only",
        )
        report = validate_registry(registry(rows=[layout]))
        self.assertFalse(any("fixture/demo" in error for error in report.errors))

        layout_live = copy.deepcopy(layout)
        layout_live["evidence_types"] = ["live-readonly"]
        report = validate_registry(registry(rows=[layout_live]))
        self.assertTrue(any("layout-only claim cannot use live-readonly" in error for error in report.errors))

    def test_expected_commit_overrides_registry_metadata_for_accepted_rows(self):
        accepted = leaf(
            status="accepted",
            blocker="none",
            evidence_path="repo://artifacts/zz-01.xcresult",
            evidence_result="passed",
            test_count=1,
        )
        report = validate_registry(
            registry(rows=[accepted], registry_producing_commit="abc1234"),
            expected_commit="def5678",
        )
        self.assertTrue(any("expected commit" in error for error in report.errors))

    def test_expected_symbolic_commit_and_producing_sha_use_git_when_available(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            (repo_root / ".git").mkdir()
            calls = []

            def fake_git_run(args, **kwargs):
                calls.append(args)
                if "rev-parse" in args:
                    return subprocess.CompletedProcess(args, 0, stdout="abc1234\n", stderr="")
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with patch("scripts.validate_acceptance_registry.subprocess.run", side_effect=fake_git_run):
                report = validate_registry(
                    registry(), repo_root=repo_root, expected_commit="HEAD"
                )
            self.assertEqual(report.errors, ())
            self.assertTrue(any("rev-parse" in call for call in calls))
            self.assertTrue(any("cat-file" in call for call in calls))

    def test_missing_producing_commit_is_rejected_when_git_is_available(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            (repo_root / ".git").mkdir()

            def fake_git_run(args, **kwargs):
                if "cat-file" in args:
                    raise subprocess.CalledProcessError(1, args)
                return subprocess.CompletedProcess(args, 0, stdout="abc1234\n", stderr="")

            with patch("scripts.validate_acceptance_registry.subprocess.run", side_effect=fake_git_run):
                report = validate_registry(registry(), repo_root=repo_root)
            self.assertTrue(any("producing SHA does not resolve" in error for error in report.errors))

    def test_frozen_manifest_rejects_mutable_split_or_merge(self):
        data = registry(
            state="FROZEN",
            registry_producing_commit="abc1234",
            freeze_manifest={
                "leaf_ids": ["ZZ-01"],
                "aliases": {},
                "split_map": {},
                "atomic_keys": {"ZZ-01": "ZZ-01"},
                "non_overlap_groups": [],
                "workstream_leaf_counts": {"Test": 1},
                "workstream_map": {"ZZ-01": "Test"},
            },
        )
        data["frozen_registry_sha256"] = registry_hash(data)
        self.assertEqual(validate_registry(data).errors, ())

        mutated = copy.deepcopy(data)
        mutated["rows"] = [leaf(id="ZZ-02", atomic_key="ZZ-02")]
        report = validate_registry(mutated)
        self.assertTrue(any("mutable split/merge" in error for error in report.errors))

        moved = copy.deepcopy(data)
        moved["rows"] = [leaf(workstream="Other")]
        report = validate_registry(moved)
        self.assertTrue(any("workstream_map" in error for error in report.errors))

    def test_unfrozen_registry_cannot_be_scored(self):
        data = registry()
        report = validate_registry(data)
        with self.assertRaisesRegex(RegistryError, "UNFROZEN.*scoring is prohibited"):
            score_registry(data, report)


if __name__ == "__main__":
    unittest.main()
