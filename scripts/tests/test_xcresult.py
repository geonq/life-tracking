from __future__ import annotations

import unittest

from scripts.validate_xcresult import (
    XCResultInvariantError,
    legacy_summary_from_payload,
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


if __name__ == "__main__":
    unittest.main()
