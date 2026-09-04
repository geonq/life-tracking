from __future__ import annotations

import unittest

from scripts.validate_xcresult import XCResultInvariantError, validate_summary


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


if __name__ == "__main__":
    unittest.main()
