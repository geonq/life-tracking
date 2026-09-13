"""Focused deterministic tests for the acceptance-registry contract."""

from __future__ import annotations

import copy
import hashlib
import subprocess
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest.mock import patch

from scripts.validate_acceptance_registry import (
    RegistryError,
    ValidationReport,
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
        "source": ["design://binding/test.md"],
        "acceptance": "The deterministic test behavior passes.",
        "evidence_types": ["unit"],
        "evidence_path": None,
        "evidence_sha256": None,
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
        "unresolved_scope_decisions": [],
        "aliases": [],
        "rows": rows if rows is not None else [leaf()],
    }
    data.update(overrides)
    return data


def frozen_registry(rows, *, registry_producing_commit="abc1234"):
    data = registry(
        rows=rows,
        state="FROZEN",
        registry_producing_commit=registry_producing_commit,
        freeze_manifest={
            "leaf_ids": [row["id"] for row in rows],
            "aliases": {},
            "split_map": {},
            "atomic_keys": {row["id"]: row["atomic_key"] for row in rows},
            "non_overlap_groups": [],
            "workstream_leaf_counts": {"Test": len(rows)},
            "workstream_map": {row["id"]: "Test" for row in rows},
        },
    )
    data["frozen_registry_sha256"] = registry_hash(data)
    return data


@contextmanager
def git_fixture():
    """Create two real commits: evidence E followed by registry commit R."""

    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        subprocess.run(["git", "init", "-q", str(root)], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.email", "tests@example.test"], check=True)
        subprocess.run(["git", "-C", str(root), "config", "user.name", "Acceptance Tests"], check=True)
        artifact = root / "artifacts" / "result.xcresult"
        artifact.parent.mkdir()
        artifact.write_bytes(b"immutable evidence")
        (root / "source.txt").write_text("tracked source\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "artifacts/result.xcresult", "source.txt"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "evidence"], check=True)
        evidence_commit = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
        ).stdout.strip()
        (root / "registry-marker.txt").write_text("registry\n", encoding="utf-8")
        subprocess.run(["git", "-C", str(root), "add", "registry-marker.txt"], check=True)
        subprocess.run(["git", "-C", str(root), "commit", "-qm", "registry"], check=True)
        registry_commit = subprocess.run(
            ["git", "-C", str(root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
        ).stdout.strip()
        digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
        yield root, evidence_commit, registry_commit, digest


class AcceptanceRegistryTests(unittest.TestCase):
    def test_real_registry_is_valid_and_aliases_do_not_inflate_denominator(self):
        data, report = load_registry()
        self.assertEqual(report.errors, ())
        # T0 froze this denominator at a clean tracked HEAD. Future progress may
        # change statuses/evidence, but never the leaf or alias accounting.
        self.assertEqual(report.leaf_count, len(data["rows"]))
        self.assertEqual(report.alias_count, len(data["aliases"]))
        self.assertGreater(report.leaf_count, 0)
        self.assertEqual(report.accepted_count, 0)
        self.assertEqual(report.state, "FROZEN")
        self.assertTrue(report.registry_blob_verified)
        self.assertEqual(report.leaf_count, 258)
        self.assertEqual(report.counts_by_workstream()["Calendar"]["leaves"], 13)
        self.assertEqual(report.counts_by_workstream()["Usage"]["leaves"], 18)
        self.assertEqual(report.counts_by_workstream()["Nutrition"]["leaves"], 8)
        required_ids = {"SY-01", "QA-05", "US-02J", "NU-03"}
        self.assertTrue(required_ids.issubset({row["id"] for row in report.rows}))

    def test_every_local_repo_source_is_existing_and_tracked(self):
        data, report = load_registry()
        self.assertEqual(report.errors, ())
        locators = {
            locator
            for row in report.rows
            for locator in row.get("source", [])
            if isinstance(locator, str) and locator.startswith("repo://")
        }
        locators.update(
            alias["source"]
            for alias in report.aliases
            if isinstance(alias.get("source"), str) and alias["source"].startswith("repo://")
        )
        self.assertGreater(len(locators), 0)
        for locator in locators:
            relative = locator.removeprefix("repo://")
            path = ROOT / relative
            self.assertTrue(path.exists(), locator)
            tracked = subprocess.run(
                ["git", "-C", str(ROOT), "ls-files", "--error-unmatch", "--", relative],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(tracked.returncode, 0, locator)
            self.assertIn(relative, tracked.stdout.splitlines(), locator)

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

    @staticmethod
    def accepted_claim(
        claim_kind,
        evidence_types,
        *,
        producing_sha,
        digest,
        source=("repo://source.txt",),
        evidence_profile=None,
    ):
        return leaf(
            status="accepted",
            blocker="none",
            claim_kind=claim_kind,
            source=list(source),
            evidence_types=evidence_types,
            evidence_path="repo://artifacts/result.xcresult",
            evidence_sha256=digest,
            evidence_result="passed",
            test_count=1,
            producing_sha=producing_sha,
            evidence_profile=evidence_profile,
        )

    def test_claim_kind_matrix_accepts_one_compatible_type(self):
        cases = (
            ("live", ["integration"]),
            ("interaction", ["ui-runtime"]),
            ("operator", ["operator"]),
            ("layout-only", ["milestone-visual"]),
        )
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            for claim_kind, evidence_types in cases:
                with self.subTest(claim_kind=claim_kind):
                    row = self.accepted_claim(
                        claim_kind,
                        evidence_types,
                        producing_sha=evidence_commit,
                        digest=digest,
                    )
                    report = validate_registry(
                        frozen_registry([row], registry_producing_commit=registry_commit),
                        repo_root=repo_root,
                    )
                    self.assertEqual(report.errors, (), report.errors)

    def test_claim_kind_matrix_rejects_source_or_visual_only_acceptance(self):
        cases = (
            ("live", ["source", "unit", "ui-runtime", "milestone-visual"]),
            ("interaction", ["source", "unit", "milestone-visual"]),
            ("operator", ["source", "integration"]),
            ("layout-only", ["source", "unit"]),
        )
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            for claim_kind, evidence_types in cases:
                with self.subTest(claim_kind=claim_kind):
                    row = self.accepted_claim(
                        claim_kind,
                        evidence_types,
                        producing_sha=evidence_commit,
                        digest=digest,
                    )
                    report = validate_registry(
                        frozen_registry([row], registry_producing_commit=registry_commit),
                        repo_root=repo_root,
                    )
                    self.assertTrue(
                        any(f"{claim_kind} claim requires one compatible" in error for error in report.errors),
                        report.errors,
                    )

    def test_layout_only_cannot_accept_live_readonly(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            row = self.accepted_claim(
                "layout-only",
                ["milestone-visual", "live-readonly"],
                producing_sha=evidence_commit,
                digest=digest,
            )
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("cannot use evidence type(s): live-readonly" in error for error in report.errors))

    def test_interaction_profiles_allow_performance_and_layout_evidence(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            for profile, evidence_types in (
                ("interaction-performance", ["performance"]),
                ("interaction-layout", ["milestone-visual"]),
            ):
                with self.subTest(profile=profile):
                    row = self.accepted_claim(
                        "interaction",
                        evidence_types,
                        producing_sha=evidence_commit,
                        digest=digest,
                        evidence_profile=profile,
                    )
                    report = validate_registry(
                        frozen_registry([row], registry_producing_commit=registry_commit),
                        repo_root=repo_root,
                    )
                    self.assertEqual(report.errors, (), report.errors)

    def test_accepted_requires_current_commit_and_evidence_path(self):
        accepted = leaf(status="accepted", blocker="none")
        report = validate_registry(registry(rows=[accepted]))
        self.assertTrue(any("no evidence path" in error for error in report.errors))
        self.assertTrue(any("explicit passed/verified" in error for error in report.errors))
        self.assertTrue(any("positive integer test_count" in error for error in report.errors))
        self.assertTrue(any("FROZEN" in error for error in report.errors))

    def test_accepted_rejects_missing_or_ambiguous_result_and_count(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            row = self.accepted_claim(
                "interaction", ["integration"], producing_sha=evidence_commit, digest=digest
            )
            row["evidence_result"] = None
            row["test_count"] = None
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("explicit passed/verified" in error for error in report.errors))
            self.assertTrue(any("positive integer test_count" in error for error in report.errors))

            row["evidence_result"] = "looks good"
            row["test_count"] = 1.5
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("explicit passed/verified" in error for error in report.errors))
            self.assertTrue(any("positive integer test_count" in error for error in report.errors))

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

    def test_accepted_artifact_is_immutable_and_path_check_has_no_opt_out(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            (repo_root / ".git").mkdir()
            artifact = repo_root / "artifacts" / "result.xcresult"
            artifact.parent.mkdir()
            artifact.write_bytes(b"immutable evidence")
            digest = hashlib.sha256(artifact.read_bytes()).hexdigest()
            accepted = leaf(
                status="accepted",
                blocker="none",
                claim_kind="interaction",
                evidence_types=["integration"],
                evidence_path="repo://artifacts/result.xcresult",
                evidence_sha256=digest,
                evidence_result="passed",
                test_count=1,
            )

            def fake_git_run(args, **kwargs):
                if "rev-parse" in args:
                    return subprocess.CompletedProcess(args, 0, stdout="abc1234\n", stderr="")
                if "ls-tree" in args:
                    return subprocess.CompletedProcess(
                        args,
                        0,
                        stdout="100644 blob deadbeef\tartifacts/result.xcresult\n",
                        stderr="",
                    )
                if "ls-files" in args:
                    return subprocess.CompletedProcess(
                        args, 0, stdout="artifacts/result.xcresult\n", stderr=""
                    )
                if "show" in args:
                    return subprocess.CompletedProcess(
                        args, 0, stdout=b"immutable evidence", stderr=b""
                    )
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with patch("scripts.validate_acceptance_registry.subprocess.run", side_effect=fake_git_run):
                report = validate_registry(
                    frozen_registry([accepted]),
                    repo_root=repo_root,
                    check_evidence_paths=False,
                    expected_commit="HEAD",
                )
            self.assertEqual(report.errors, ())

            artifact.write_bytes(b"tampered evidence")
            with patch("scripts.validate_acceptance_registry.subprocess.run", side_effect=fake_git_run):
                report = validate_registry(
                    frozen_registry([accepted]),
                    repo_root=repo_root,
                    check_evidence_paths=False,
                    expected_commit="HEAD",
                )
            self.assertTrue(any("does not match artifact" in error for error in report.errors))

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
            rows=[leaf(evidence_types=["integration"])],
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
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            (repo_root / ".git").mkdir()

            def fake_git_run(args, **kwargs):
                if "rev-parse" in args:
                    return subprocess.CompletedProcess(args, 0, stdout="abc1234\n", stderr="")
                return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

            with patch("scripts.validate_acceptance_registry.subprocess.run", side_effect=fake_git_run):
                self.assertEqual(validate_registry(data, repo_root=repo_root, expected_commit="HEAD").errors, ())

                mutated = copy.deepcopy(data)
                mutated["rows"] = [leaf(id="ZZ-02", atomic_key="ZZ-02")]
                report = validate_registry(mutated, repo_root=repo_root, expected_commit="HEAD")
                self.assertTrue(any("mutable split/merge" in error for error in report.errors))

                moved = copy.deepcopy(data)
                moved["rows"] = [leaf(workstream="Other")]
                report = validate_registry(moved, repo_root=repo_root, expected_commit="HEAD")
                self.assertTrue(any("workstream_map" in error for error in report.errors))

    def test_frozen_definition_hash_excludes_progress_evidence(self):
        row = leaf(evidence_types=["integration"])
        data = frozen_registry([row], registry_producing_commit=None)
        before = registry_hash(data)
        changed = copy.deepcopy(data)
        changed["rows"][0].update(
            status="accepted",
            blocker="none",
            evidence_path="repo://artifacts/result.xcresult",
            evidence_sha256="a" * 64,
            evidence_result="passed",
            test_count=1,
            producing_sha="f" * 40,
        )
        self.assertEqual(registry_hash(changed), before)
        changed["rows"][0]["acceptance"] = "A different requirement."
        self.assertNotEqual(registry_hash(changed), before)
        platform_changed = copy.deepcopy(data)
        platform_changed["rows"][0]["platform"] = "macOS"
        self.assertNotEqual(registry_hash(platform_changed), before)

    def test_frozen_validation_and_scoring_fail_without_real_git(self):
        data = frozen_registry([leaf(evidence_types=["integration"])], registry_producing_commit=None)
        report = validate_registry(data)
        self.assertTrue(any("real Git repository" in error for error in report.errors))
        with self.assertRaisesRegex(RegistryError, "Git repository"):
            score_registry(data, report)

    def test_frozen_registry_rejects_unresolved_scope_decisions(self):
        data = frozen_registry([leaf(evidence_types=["integration"])], registry_producing_commit=None)
        data["unresolved_scope_decisions"] = ["performance threshold is still TBD"]
        data["frozen_registry_sha256"] = registry_hash(data)
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo_root)], check=True)
            report = validate_registry(data, repo_root=repo_root)
        self.assertTrue(any("empty unresolved_scope_decisions" in error for error in report.errors))

    def test_frozen_registry_requires_explicit_unresolved_scope_decisions(self):
        data = frozen_registry([leaf(evidence_types=["integration"])], registry_producing_commit=None)
        del data["unresolved_scope_decisions"]
        data["frozen_registry_sha256"] = registry_hash(data)
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo_root)], check=True)
            report = validate_registry(data, repo_root=repo_root)
        self.assertTrue(any("explicit empty unresolved_scope_decisions" in error for error in report.errors))

    def test_remote_evidence_and_directory_bundle_are_rejected(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            row = self.accepted_claim(
                "live", ["integration"], producing_sha=evidence_commit, digest=digest
            )
            row["evidence_path"] = "https://evidence.example.test/result?sha256=" + digest
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("tracked repo:// artifact" in error for error in report.errors))

            row["evidence_path"] = "repo://artifacts"
            row["evidence_sha256"] = digest
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("one tracked regular file" in error for error in report.errors))

    def test_source_and_evidence_must_exist_at_evidence_commit(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            late_source = repo_root / "late-source.txt"
            late_source.write_text("late\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo_root), "add", "late-source.txt"], check=True)
            subprocess.run(["git", "-C", str(repo_root), "commit", "-qm", "late source"], check=True)
            row = self.accepted_claim(
                "live",
                ["integration"],
                producing_sha=evidence_commit,
                digest=digest,
                source=("repo://late-source.txt",),
            )
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("source does not exist" in error for error in report.errors))

    def test_symlink_evidence_locator_cannot_alias_a_tracked_artifact(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            (repo_root / "artifact-alias").symlink_to(repo_root / "artifacts" / "result.xcresult")
            row = self.accepted_claim(
                "live", ["integration"], producing_sha=evidence_commit, digest=digest
            )
            row["evidence_path"] = "repo://artifact-alias"
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("unsafe" in error for error in report.errors), report.errors)

    def test_repo_source_and_evidence_must_be_blobs_at_producing_commit(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo_root)], check=True)
            subprocess.run(["git", "-C", str(repo_root), "config", "user.email", "tests@example.test"], check=True)
            subprocess.run(["git", "-C", str(repo_root), "config", "user.name", "Acceptance Tests"], check=True)
            (repo_root / "source-transition").mkdir()
            (repo_root / "source-transition" / "child.txt").write_text("source tree\n", encoding="utf-8")
            (repo_root / "evidence-transition").mkdir()
            (repo_root / "evidence-transition" / "child.txt").write_text("evidence tree\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo_root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo_root), "commit", "-qm", "tree evidence"], check=True)
            evidence_commit = subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()
            tree_listing = subprocess.run(
                ["git", "-C", str(repo_root), "show", f"{evidence_commit}:evidence-transition"],
                check=True,
                capture_output=True,
            ).stdout
            (repo_root / "source-transition" / "child.txt").unlink()
            (repo_root / "source-transition").rmdir()
            (repo_root / "source-transition").write_text("now a file\n", encoding="utf-8")
            (repo_root / "evidence-transition" / "child.txt").unlink()
            (repo_root / "evidence-transition").rmdir()
            (repo_root / "evidence-transition").write_bytes(tree_listing)
            subprocess.run(["git", "-C", str(repo_root), "add", "-A"], check=True)
            subprocess.run(["git", "-C", str(repo_root), "commit", "-qm", "files now"], check=True)
            registry_commit = subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()
            row = self.accepted_claim(
                "live",
                ["integration"],
                producing_sha=evidence_commit,
                digest=hashlib.sha256(tree_listing).hexdigest(),
                source=("repo://source-transition",),
            )
            row["evidence_path"] = "repo://evidence-transition"
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("evidence does not exist" in error for error in report.errors), report.errors)
            self.assertTrue(any("source does not exist" in error for error in report.errors), report.errors)

    def test_symlink_at_producing_commit_cannot_become_regular_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            repo_root = Path(temporary)
            subprocess.run(["git", "init", "-q", str(repo_root)], check=True)
            subprocess.run(["git", "-C", str(repo_root), "config", "user.email", "tests@example.test"], check=True)
            subprocess.run(["git", "-C", str(repo_root), "config", "user.name", "Acceptance Tests"], check=True)
            (repo_root / "source.txt").write_text("source\n", encoding="utf-8")
            (repo_root / "evidence-link").symlink_to("target.txt")
            subprocess.run(["git", "-C", str(repo_root), "add", "."], check=True)
            subprocess.run(["git", "-C", str(repo_root), "commit", "-qm", "symlink evidence"], check=True)
            evidence_commit = subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()
            (repo_root / "evidence-link").unlink()
            (repo_root / "evidence-link").write_text("target.txt", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo_root), "add", "evidence-link"], check=True)
            subprocess.run(["git", "-C", str(repo_root), "commit", "-qm", "regular now"], check=True)
            registry_commit = subprocess.run(
                ["git", "-C", str(repo_root), "rev-parse", "HEAD"], check=True, capture_output=True, text=True
            ).stdout.strip()
            digest = hashlib.sha256(b"target.txt").hexdigest()
            row = self.accepted_claim(
                "live", ["integration"], producing_sha=evidence_commit, digest=digest
            )
            row["evidence_path"] = "repo://evidence-link"
            report = validate_registry(
                frozen_registry([row], registry_producing_commit=registry_commit),
                repo_root=repo_root,
            )
            self.assertTrue(any("evidence does not exist" in error for error in report.errors), report.errors)

    def test_frozen_registry_path_must_match_tracked_head_blob(self):
        with git_fixture() as (repo_root, evidence_commit, registry_commit, digest):
            registry_path = repo_root / "registry.md"
            registry_path.write_text("frozen registry\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo_root), "add", "registry.md"], check=True)
            subprocess.run(["git", "-C", str(repo_root), "commit", "-qm", "tracked registry"], check=True)
            data = frozen_registry([leaf(evidence_types=["integration"], producing_sha=evidence_commit)])
            report = validate_registry(data, repo_root=repo_root, registry_path=registry_path)
            self.assertEqual(report.errors, (), report.errors)
            self.assertTrue(report.registry_blob_verified)
            registry_path.write_text("dirty registry\n", encoding="utf-8")
            report = validate_registry(data, repo_root=repo_root, registry_path=registry_path)
            self.assertFalse(report.registry_blob_verified)
            self.assertTrue(any("tracked HEAD blob" in error for error in report.errors), report.errors)

    def test_unfrozen_registry_cannot_be_scored(self):
        data = registry()
        report = validate_registry(data)
        with self.assertRaisesRegex(RegistryError, "UNFROZEN.*scoring is prohibited"):
            score_registry(data, report)

    def test_score_rejects_report_from_different_registry_data(self):
        data = frozen_registry([leaf(evidence_types=["integration"])], registry_producing_commit=None)
        report = ValidationReport(
            rows=(leaf(status="accepted", severity="P0"),),
            aliases=(),
            errors=(),
            warnings=(),
            state="FROZEN",
            registry_hash=registry_hash(data),
            validated_payload_sha256="0" * 64,
            git_verified=True,
            registry_blob_verified=True,
        )
        changed = copy.deepcopy(data)
        changed["rows"][0]["acceptance"] = "Changed frozen requirement"
        with self.assertRaisesRegex(RegistryError, "does not belong"):
            score_registry(changed, report)


if __name__ == "__main__":
    unittest.main()
