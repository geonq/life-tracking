from __future__ import annotations

import json
import subprocess
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from scripts.validate_xcresult import (
    XCResultInvariantError,
    legacy_summary_from_payload,
    xcresult_summary,
    validate_summary,
)


class XCResultInvariantTests(unittest.TestCase):
    @staticmethod
    def summary(**overrides):
        payload = {
            "result": "Passed",
            "totalTestCount": 386,
            "passedTests": 386,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
        }
        payload.update(overrides)
        return payload

    def test_pass_requires_minimum_and_all_tests_pass(self) -> None:
        validated = validate_summary(self.summary(), 386)
        self.assertEqual(validated["passedTests"], 386)

    def test_below_minimum_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "minimum"):
            validate_summary(self.summary(totalTestCount=12, passedTests=12), 386)

    def test_canceled_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "only Passed"):
            validate_summary(self.summary(result="Skipped"), 386)

    def test_zero_test_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "zero"):
            validate_summary(self.summary(totalTestCount=0, passedTests=0), 386)

    def test_failed_test_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "failed"):
            validate_summary(self.summary(failedTests=1, passedTests=385), 386)

    def test_skipped_test_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "skipped"):
            validate_summary(self.summary(skippedTests=1, passedTests=385), 386)

    def test_expected_failure_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "expected failures"):
            validate_summary(self.summary(expectedFailures=1, passedTests=385), 386)

    def test_negative_counters_are_rejected(self) -> None:
        for field in ("totalTestCount", "passedTests", "failedTests", "skippedTests", "expectedFailures"):
            with self.subTest(field=field):
                with self.assertRaisesRegex(XCResultInvariantError, "negative"):
                    validate_summary(self.summary(**{field: -1}), 386)


class LegacySummaryTests(unittest.TestCase):
    @staticmethod
    def root(*, status="succeeded", tests_count=None, tests_ref=True):
        action_result = {
            "status": status,
            "metrics": {"testsCount": {"_value": str(tests_count)}} if tests_count is not None else {},
        }
        if tests_ref:
            action_result["testsRef"] = {"id": {"_value": "tests-ref"}}
        return {"actions": {"_values": [{"actionResult": action_result}]}}

    @staticmethod
    def make_tests_payload(*statuses):
        return {
            "summaries": {
                "_values": [
                    {
                        "tests": {
                            "_values": [
                                {
                                    "subtests": {
                                        "_values": [
                                            {"testStatus": {"_value": status}} for status in statuses
                                        ]
                                    }
                                }
                            ]
                        }
                    }
                ]
            }
        }

    def summary(self, *statuses):
        return legacy_summary_from_payload(
            self.root(tests_count=len(statuses)),
            self.make_tests_payload(*statuses),
        )

    def test_success_is_the_only_passed_status(self) -> None:
        self.assertEqual(
            self.summary("Success", "Success"),
            {
                "result": "Passed",
                "totalTestCount": 2,
                "passedTests": 2,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
            },
        )

    def test_failure_is_classified(self) -> None:
        summary = self.summary("Success", "Failure")
        self.assertEqual(summary["passedTests"], 1)
        self.assertEqual(summary["failedTests"], 1)

    def test_skipped_is_classified(self) -> None:
        self.assertEqual(self.summary("Skipped")["skippedTests"], 1)

    def test_expected_failure_spellings_are_classified(self) -> None:
        summary = self.summary("Expected Failure", "ExpectedFailure")
        self.assertEqual(summary["expectedFailures"], 2)

    def test_unknown_status_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "unknown"):
            self.summary("Success", "Flaky")

    def test_missing_test_action_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "no test action"):
            legacy_summary_from_payload(
                {"actions": {"_values": []}}, self.make_tests_payload("Success")
            )

    def test_missing_tests_reference_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "missing testsRef"):
            legacy_summary_from_payload(
                self.root(tests_count=1, tests_ref=False),
                self.make_tests_payload("Success"),
            )

    def test_missing_metrics_are_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "testsCount"):
            legacy_summary_from_payload(
                self.root(tests_count=None), self.make_tests_payload("Success")
            )

    def test_empty_result_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "no testStatus"):
            self.summary()

    def test_count_mismatch_is_rejected(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "count mismatch"):
            legacy_summary_from_payload(
                self.root(tests_count=2), self.make_tests_payload("Success")
            )

    def test_non_string_action_status_is_rejected_without_type_error(self) -> None:
        with self.assertRaisesRegex(XCResultInvariantError, "action status must be a string"):
            legacy_summary_from_payload(
                self.root(status={"unexpected": "mapping"}, tests_count=1),
                self.make_tests_payload("Success"),
            )

    def test_non_string_test_status_is_rejected_without_type_error(self) -> None:
        payload = self.make_tests_payload("Success")
        payload["summaries"]["_values"][0]["tests"]["_values"][0]["subtests"]["_values"][0][
            "testStatus"
        ] = {"_value": {"unexpected": "mapping"}}
        with self.assertRaisesRegex(XCResultInvariantError, "test status must be a string"):
            legacy_summary_from_payload(self.root(tests_count=1), payload)

    def test_multiple_test_actions_fail_closed(self) -> None:
        first = self.root(status="succeeded", tests_count=1)["actions"]["_values"][0]
        second = self.root(status="failed", tests_count=1)["actions"]["_values"][0]
        root = {"actions": {"_values": [first, second]}}
        with self.assertRaisesRegex(XCResultInvariantError, "multiple test actions"):
            legacy_summary_from_payload(root, self.make_tests_payload("Success"))

    def test_non_success_action_statuses_are_preserved_for_strict_validation(self) -> None:
        for action_status, expected_result in (
            ("failed", "Failed"),
            ("skipped", "Skipped"),
            ("canceled", "Canceled"),
            ("cancelled", "Canceled"),
        ):
            with self.subTest(action_status=action_status):
                summary = legacy_summary_from_payload(
                    self.root(status=action_status, tests_count=1),
                    self.make_tests_payload("Success"),
                )
                self.assertEqual(summary["result"], expected_result)
                with self.assertRaisesRegex(XCResultInvariantError, "only Passed"):
                    validate_summary(summary, 1)


class XCResultSummaryCommandTests(unittest.TestCase):
    @staticmethod
    def modern_summary() -> str:
        return json.dumps(
            {
                "result": "Passed",
                "totalTestCount": 1,
                "passedTests": 1,
                "failedTests": 0,
                "skippedTests": 0,
                "expectedFailures": 0,
            }
        )

    @staticmethod
    def legacy_root(
        *, status="succeeded", tests_count=1, extra_action=None, extra_raw_actions=()
    ) -> str:
        action_result = {
            "status": status,
            "metrics": {"testsCount": {"_value": str(tests_count)}}
            if tests_count is not None
            else {},
            "testsRef": {"id": {"_value": "tests-ref"}},
        }
        actions = [{"actionResult": action_result}]
        if extra_action is not None:
            actions.append({"actionResult": extra_action})
        actions.extend(extra_raw_actions)
        return json.dumps({"actions": {"_values": actions}})

    @staticmethod
    def typed_text(value: str) -> dict[str, object]:
        return {"_type": {"_name": "String"}, "_value": value}

    @classmethod
    def explicit_test_action_without_payload(cls, status: str) -> dict[str, object]:
        return {
            "schemeCommandName": cls.typed_text("Test"),
            "actionResult": {
                "resultName": cls.typed_text("action"),
                "status": cls.typed_text(status),
            },
        }

    @staticmethod
    def legacy_tests() -> str:
        return json.dumps(
            {
                "summaries": {
                    "_values": [
                        {
                            "tests": {
                                "_values": [
                                    {
                                        "subtests": {
                                            "_values": [
                                                {"testStatus": {"_value": "Success"}}
                                            ]
                                        }
                                    }
                                ]
                            }
                        }
                    ]
                }
            }
        )

    def setUp(self) -> None:
        self.tempdir = tempfile.TemporaryDirectory()
        self.result_path = Path(self.tempdir.name) / "result.xcresult"
        self.result_path.mkdir()

    def tearDown(self) -> None:
        self.tempdir.cleanup()

    def test_modern_success_does_not_invoke_fallback(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout=self.modern_summary())
        with patch("scripts.validate_xcresult.subprocess.run", return_value=completed) as run:
            self.assertEqual(xcresult_summary(self.result_path)["result"], "Passed")
        run.assert_called_once()
        self.assertNotIn("--legacy", run.call_args.args[0])

    def test_modern_failure_invokes_legacy_root_then_tests_reference(self) -> None:
        failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        root = subprocess.CompletedProcess([], 0, stdout=self.legacy_root())
        tests = subprocess.CompletedProcess([], 0, stdout=self.legacy_tests())
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[failure, root, tests],
        ) as run:
            self.assertEqual(xcresult_summary(self.result_path)["result"], "Passed")
        self.assertEqual(run.call_count, 3)
        modern_command = run.call_args_list[0].args[0]
        root_command = run.call_args_list[1].args[0]
        tests_command = run.call_args_list[2].args[0]
        self.assertNotIn("--legacy", modern_command)
        self.assertIn("--legacy", root_command)
        self.assertNotIn("--id", root_command)
        self.assertEqual(tests_command[-2:], ["--id", "tests-ref"])

    def test_later_failed_action_is_rejected_by_legacy_fallback(self) -> None:
        failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        later_failed_action = {
            "status": "failed",
            "metrics": {"testsCount": {"_value": "1"}},
            "testsRef": {"id": {"_value": "later-tests-ref"}},
        }
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_action=later_failed_action)
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[failure, root],
        ) as run:
            with self.assertRaisesRegex(XCResultInvariantError, "multiple test actions"):
                xcresult_summary(self.result_path)
        self.assertEqual(run.call_count, 2)

    def test_incomplete_later_test_actions_are_rejected_by_metadata(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        for status in ("failed", "canceled", "skipped"):
            with self.subTest(status=status):
                root = subprocess.CompletedProcess(
                    [],
                    0,
                    stdout=self.legacy_root(
                        extra_raw_actions=(
                            self.explicit_test_action_without_payload(status),
                        )
                    ),
                )
                with patch(
                    "scripts.validate_xcresult.subprocess.run",
                    side_effect=[modern_failure, root],
                ) as run:
                    with self.assertRaisesRegex(
                        XCResultInvariantError, "multiple test actions"
                    ):
                        xcresult_summary(self.result_path)
                self.assertEqual(run.call_count, 2)

    def test_unidentified_later_action_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        unidentified_action = {
            "actionResult": {
                "resultName": self.typed_text("action"),
                "status": self.typed_text("succeeded"),
            }
        }
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_raw_actions=(unidentified_action,))
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root],
        ):
            with self.assertRaisesRegex(
                XCResultInvariantError, "relevance cannot be established"
            ):
                xcresult_summary(self.result_path)

    def test_missing_later_action_result_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_raw_actions=({},))
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root],
        ):
            with self.assertRaisesRegex(
                XCResultInvariantError, "relevance cannot be established"
            ):
                xcresult_summary(self.result_path)

    def test_missing_action_result_with_conflicting_metadata_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        ambiguous_action = {
            "schemeCommandName": self.typed_text("Build"),
            "testPlanName": self.typed_text("Tests"),
            "title": self.typed_text("Testing LifeOS"),
        }
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_raw_actions=(ambiguous_action,))
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root],
        ):
            with self.assertRaisesRegex(XCResultInvariantError, "missing actionResult"):
                xcresult_summary(self.result_path)

    def test_malformed_action_result_on_build_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        for malformed_result in (None, [], "not-an-object"):
            with self.subTest(malformed_result=malformed_result):
                malformed_action = {
                    "schemeCommandName": self.typed_text("Build"),
                    "actionResult": malformed_result,
                }
                root = subprocess.CompletedProcess(
                    [], 0, stdout=self.legacy_root(extra_raw_actions=(malformed_action,))
                )
                with patch(
                    "scripts.validate_xcresult.subprocess.run",
                    side_effect=[modern_failure, root],
                ):
                    with self.assertRaisesRegex(XCResultInvariantError, "missing actionResult"):
                        xcresult_summary(self.result_path)

    def test_valid_action_result_with_conflicting_metadata_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        conflicting_action = {
            "schemeCommandName": self.typed_text("Build"),
            "testPlanName": self.typed_text("Tests"),
            "title": self.typed_text("Testing LifeOS"),
            "actionResult": {
                "resultName": self.typed_text("action"),
                "status": self.typed_text("succeeded"),
            },
        }
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_raw_actions=(conflicting_action,))
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root],
        ):
            with self.assertRaisesRegex(
                XCResultInvariantError, "conflicting test and non-test metadata"
            ):
                xcresult_summary(self.result_path)

    def test_action_without_status_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        malformed_action = {
            "schemeCommandName": self.typed_text("Build"),
            "actionResult": {"resultName": self.typed_text("action")},
        }
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_raw_actions=(malformed_action,))
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root],
        ):
            with self.assertRaisesRegex(XCResultInvariantError, "missing action status"):
                xcresult_summary(self.result_path)

    def test_empty_action_metadata_fails_closed(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        empty_metadata_action = {
            "schemeCommandName": self.typed_text(""),
            "actionResult": {
                "resultName": self.typed_text("action"),
                "status": self.typed_text("succeeded"),
            },
        }
        root = subprocess.CompletedProcess(
            [], 0, stdout=self.legacy_root(extra_raw_actions=(empty_metadata_action,))
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root],
        ):
            with self.assertRaisesRegex(XCResultInvariantError, "schemeCommandName.*empty"):
                xcresult_summary(self.result_path)

    def test_modern_failure_summary_is_rejected_without_fallback(self) -> None:
        failed_summary = self.modern_summary().replace('"Passed"', '"Failed"')
        completed = subprocess.CompletedProcess([], 0, stdout=failed_summary)
        with patch("scripts.validate_xcresult.subprocess.run", return_value=completed) as run:
            summary = xcresult_summary(self.result_path)
            with self.assertRaisesRegex(XCResultInvariantError, "only Passed"):
                validate_summary(summary, 1)
        run.assert_called_once()
        self.assertNotIn("--legacy", run.call_args.args[0])

    def test_referenced_tests_object_subprocess_failure_is_structured(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        root = subprocess.CompletedProcess([], 0, stdout=self.legacy_root())
        tests_failure = subprocess.CalledProcessError(
            1, ["xcrun", "tests"], output="tests unavailable"
        )
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root, tests_failure],
        ):
            with self.assertRaisesRegex(
                XCResultInvariantError, "legacy tests object failed: tests unavailable"
            ):
                xcresult_summary(self.result_path)

    def test_referenced_tests_object_json_failure_is_structured(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun"], output="unsupported")
        root = subprocess.CompletedProcess([], 0, stdout=self.legacy_root())
        tests = subprocess.CompletedProcess([], 0, stdout="not-json")
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, root, tests],
        ):
            with self.assertRaisesRegex(
                XCResultInvariantError, "legacy tests object is not valid JSON"
            ):
                xcresult_summary(self.result_path)

    def test_subprocess_failure_with_empty_stdout_remains_structured(self) -> None:
        modern_failure = subprocess.CalledProcessError(1, ["xcrun", "summary"])
        legacy_failure = subprocess.CalledProcessError(1, ["xcrun", "root"])
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, legacy_failure],
        ):
            with self.assertRaisesRegex(XCResultInvariantError, "returned non-zero exit status"):
                xcresult_summary(self.result_path)

    def test_json_failure_remains_structured(self) -> None:
        modern_failure = subprocess.CompletedProcess([], 0, stdout="not-json")
        legacy_failure = subprocess.CompletedProcess([], 0, stdout="also-not-json")
        with patch(
            "scripts.validate_xcresult.subprocess.run",
            side_effect=[modern_failure, legacy_failure],
        ):
            with self.assertRaisesRegex(XCResultInvariantError, "not valid JSON"):
                xcresult_summary(self.result_path)


if __name__ == "__main__":
    unittest.main()
