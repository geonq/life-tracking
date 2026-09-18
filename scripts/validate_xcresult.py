#!/usr/bin/env python3
"""Reject empty, canceled, skipped, or failed XCTest result bundles.

The existence of an ``.xcresult`` directory only proves that xcodebuild wrote
an artifact.  It does not prove that the intended test bundle materialised or
that any tests ran.  This validator consumes Apple's public
``xcresulttool get test-results summary`` JSON and enforces the lane's minimum
expected count before CI can treat the lane as green. When Xcode cannot
materialize that summary, it uses a strict legacy-object fallback that refuses
ambiguous or incomplete action records.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path
from typing import Any, Mapping


class XCResultInvariantError(ValueError):
    """Raised when an XCTest result is not a valid lane pass."""


def _fail(message: str) -> None:
    raise XCResultInvariantError(message)


def _subprocess_error_detail(error: BaseException) -> str:
    output = getattr(error, "stdout", "")
    if isinstance(output, str) and output.strip():
        return output.strip()
    return str(error)


def _integer(payload: Mapping[str, Any], key: str) -> int:
    value = payload.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(f"xcresult summary field {key!r} is not an integer")
    return value


def validate_summary(summary: Mapping[str, Any], minimum_tests: int) -> dict[str, int | str]:
    """Validate a summary object and return the stable fields for reporting."""

    if minimum_tests <= 0:
        _fail("minimum expected test count must be greater than zero")
    result = summary.get("result")
    if result != "Passed":
        _fail(f"xcresult result is {result!r}; only Passed is accepted")

    total = _integer(summary, "totalTestCount")
    passed = _integer(summary, "passedTests")
    failed = _integer(summary, "failedTests")
    skipped = _integer(summary, "skippedTests")
    expected_failures = _integer(summary, "expectedFailures")

    counters = {
        "totalTestCount": total,
        "passedTests": passed,
        "failedTests": failed,
        "skippedTests": skipped,
        "expectedFailures": expected_failures,
    }
    negative = [key for key, value in counters.items() if value < 0]
    if negative:
        _fail(f"xcresult summary contains negative counters: {negative}")
    if total <= 0:
        _fail("xcresult materialized zero tests")
    if total < minimum_tests:
        _fail(f"xcresult ran {total} tests; minimum expected is {minimum_tests}")
    if failed:
        _fail(f"xcresult contains {failed} failed tests")
    if skipped:
        _fail(f"xcresult contains {skipped} skipped tests")
    if expected_failures:
        _fail(f"xcresult contains {expected_failures} expected failures")
    if passed != total:
        _fail(f"xcresult count mismatch: passed={passed}, total={total}")

    return {
        "result": str(result),
        "totalTestCount": total,
        "passedTests": passed,
        "failedTests": failed,
        "skippedTests": skipped,
        "expectedFailures": expected_failures,
    }


def read_summary(summary_file: Path) -> Mapping[str, Any]:
    try:
        payload = json.loads(summary_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _fail(f"xcresult summary file is missing: {summary_file}")
    except json.JSONDecodeError as error:
        _fail(f"xcresult summary is not valid JSON: {error}")
    if not isinstance(payload, Mapping):
        _fail("xcresult summary root must be a JSON object")
    return payload


def _legacy_value(value: Any) -> Any:
    if isinstance(value, Mapping) and "_value" in value:
        return value["_value"]
    return value


def _legacy_values(value: Any) -> list[Any]:
    if isinstance(value, Mapping):
        values = value.get("_values")
        if isinstance(values, list):
            return values
    if isinstance(value, list):
        return value
    return []


_LEGACY_TEST_COMMANDS = {"test", "tests"}
_LEGACY_NON_TEST_COMMANDS = {
    "analyze",
    "archive",
    "build",
    "clean",
    "install",
    "profile",
    "run",
}
_LEGACY_TEST_RESULT_NAMES = {"test", "tests", "testing"}
_LEGACY_NON_TEST_RESULT_NAMES = {
    "analyze",
    "archive",
    "build",
    "clean",
    "install",
    "profile",
    "run",
}


def _legacy_text_field(
    payload: Mapping[str, Any], key: str, *, context: str
) -> str | None:
    if key not in payload:
        return None
    value = _legacy_value(payload[key])
    if not isinstance(value, str):
        if key == "status":
            _fail(
                "xcresult legacy action status must be a string; "
                f"got {type(value).__name__}"
            )
        _fail(
            f"xcresult legacy {context} field {key!r} must be a string; "
            f"got {type(value).__name__}"
        )
    if not value.strip():
        _fail(f"xcresult legacy {context} field {key!r} is empty")
    return value.strip()


def _legacy_action_kind(action: Mapping[str, Any], index: int) -> str:
    """Classify one legacy action without trusting payload presence alone.

    Apple emits ``schemeCommandName=Test`` and ``testPlanName`` on real test
    actions; the action result carries typed ``resultName`` and ``status``.
    Older result roots may omit that metadata, so a valid ``testsRef`` or
    ``metrics.testsCount`` remains sufficient for the single-action path. A
    status by itself is deliberately ambiguous because build actions also
    have statuses. Any other action must be explicitly recognizable as
    non-test or the validator fails closed.
    """

    command = _legacy_text_field(action, "schemeCommandName", context="action")
    title = _legacy_text_field(action, "title", context="action")
    test_plan = _legacy_text_field(action, "testPlanName", context="action")
    action_result = action.get("actionResult")
    if not isinstance(action_result, Mapping):
        command_name = command.casefold() if command else None
        if command_name in _LEGACY_NON_TEST_COMMANDS:
            return "non-test"
        _fail(
            f"xcresult legacy action[{index}] is missing actionResult; "
            "relevance cannot be established"
        )

    # Validate typed status whenever it is present, even when another field
    # later classifies this as a non-test action. Status alone is not a test
    # discriminator, but malformed status data must never be ignored.
    _legacy_text_field(action_result, "status", context="action")
    result_name = _legacy_text_field(action_result, "resultName", context="action result")
    command_name = command.casefold() if command else None
    result_name_normalized = result_name.casefold() if result_name else None

    test_signals: list[str] = []
    non_test_signals: list[str] = []
    if command_name in _LEGACY_TEST_COMMANDS:
        test_signals.append("schemeCommandName")
    elif command_name in _LEGACY_NON_TEST_COMMANDS:
        non_test_signals.append("schemeCommandName")
    if test_plan is not None:
        test_signals.append("testPlanName")
    if title is not None and title.casefold().startswith("testing "):
        test_signals.append("title")
    if result_name_normalized in _LEGACY_TEST_RESULT_NAMES:
        test_signals.append("resultName")
    elif result_name_normalized in _LEGACY_NON_TEST_RESULT_NAMES:
        non_test_signals.append("resultName")

    metrics = action_result.get("metrics")
    has_test_evidence = "testsRef" in action_result or (
        isinstance(metrics, Mapping) and "testsCount" in metrics
    )
    if has_test_evidence:
        test_signals.append("test result payload")

    if test_signals and non_test_signals:
        _fail(
            f"xcresult legacy action[{index}] has conflicting test and non-test metadata"
        )
    if test_signals:
        return "test"
    if non_test_signals:
        return "non-test"
    _fail(
        f"xcresult legacy action[{index}] relevance cannot be established from metadata"
    )


def _legacy_test_action(root: Mapping[str, Any]) -> Mapping[str, Any]:
    if "actions" not in root:
        _fail("xcresult legacy result contains no actions collection")
    actions_value = root["actions"]
    actions = _legacy_values(actions_value)
    if not actions and not (
        isinstance(actions_value, Mapping) and isinstance(actions_value.get("_values"), list)
    ) and not isinstance(actions_value, list):
        _fail("xcresult legacy actions collection is malformed")
    test_actions: list[Mapping[str, Any]] = []
    for index, action in enumerate(actions):
        if not isinstance(action, Mapping):
            _fail(f"xcresult legacy action[{index}] is malformed")
        kind = _legacy_action_kind(action, index)
        if kind == "non-test":
            continue
        action_result = action.get("actionResult")
        if not isinstance(action_result, Mapping):
            _fail(f"xcresult legacy action[{index}] is missing actionResult")
        test_actions.append(action_result)
    if len(test_actions) > 1:
        _fail(
            "xcresult legacy result contains multiple test actions; "
            "refusing to choose one"
        )
    if test_actions:
        return test_actions[0]
    _fail("xcresult legacy result contains no test action")


def _legacy_reference_id(reference: Any) -> str:
    if not isinstance(reference, Mapping):
        _fail("xcresult legacy test action is missing testsRef")
    reference_id = _legacy_value(reference.get("id"))
    if not isinstance(reference_id, str) or not reference_id.strip():
        _fail("xcresult legacy testsRef is missing an id")
    return reference_id


def _legacy_integer(payload: Mapping[str, Any], key: str) -> int:
    value = _legacy_value(payload.get(key))
    if isinstance(value, bool):
        _fail(f"xcresult legacy field {key!r} is not an integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        try:
            return int(value)
        except ValueError:
            pass
    _fail(f"xcresult legacy field {key!r} is not an integer")


def _legacy_test_status_counts(tests_payload: Mapping[str, Any]) -> dict[str, int]:
    counts = {
        "passedTests": 0,
        "failedTests": 0,
        "skippedTests": 0,
        "expectedFailures": 0,
    }
    status_names = {
        "Success": "passedTests",
        "Failure": "failedTests",
        "Skipped": "skippedTests",
        "Expected Failure": "expectedFailures",
        "ExpectedFailure": "expectedFailures",
    }
    found = 0

    def visit(value: Any) -> None:
        nonlocal found
        if isinstance(value, Mapping):
            if "testStatus" in value:
                status = _legacy_value(value["testStatus"])
                if not isinstance(status, str):
                    _fail(
                        "xcresult legacy test status must be a string; "
                        f"got {type(status).__name__}"
                    )
                counter = status_names.get(status)
                if counter is None:
                    _fail(f"xcresult legacy test status {status!r} is unknown")
                counts[counter] += 1
                found += 1
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(tests_payload)
    if found == 0:
        _fail("xcresult legacy tests object contains no testStatus values")
    return counts


def legacy_summary_from_payload(
    root: Mapping[str, Any], tests_payload: Mapping[str, Any]
) -> Mapping[str, Any]:
    """Build a modern-shaped summary from a resolved legacy testsRef object."""

    action_result = _legacy_test_action(root)
    _legacy_reference_id(action_result.get("testsRef"))
    status = _legacy_value(action_result.get("status"))
    if not isinstance(status, str):
        _fail(
            "xcresult legacy action status must be a string; "
            f"got {type(status).__name__}"
        )
    result_by_status = {
        "succeeded": "Passed",
        "failed": "Failed",
        "skipped": "Skipped",
        "canceled": "Canceled",
        "cancelled": "Canceled",
    }
    result = result_by_status.get(status)
    if result is None:
        _fail(f"xcresult legacy action status {status!r} is unknown")

    counts = _legacy_test_status_counts(tests_payload)
    total = sum(counts.values())
    metrics = action_result.get("metrics")
    if not isinstance(metrics, Mapping):
        _fail("xcresult legacy test action is missing metrics.testsCount")
    declared_total = _legacy_integer(metrics, "testsCount")
    if declared_total < 0:
        _fail("xcresult legacy metrics.testsCount is negative")
    if declared_total != total:
        _fail(
            "xcresult legacy test count mismatch: "
            f"metrics.testsCount={declared_total}, testStatus values={total}"
        )

    return {
        "result": result,
        "totalTestCount": total,
        **counts,
    }


def _legacy_object(result_path: Path, object_id: str | None = None) -> Mapping[str, Any]:
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "object",
        "--legacy",
        "--format",
        "json",
        "--path",
        str(result_path),
    ]
    if object_id is not None:
        command.extend(["--id", object_id])
    label = "legacy tests object" if object_id is not None else "legacy root"
    try:
        completed = subprocess.run(
            command,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        _fail(f"xcresulttool {label} failed: {_subprocess_error_detail(error)}")
    try:
        payload = json.loads(completed.stdout)
    except (json.JSONDecodeError, TypeError) as error:
        _fail(f"xcresulttool {label} is not valid JSON: {error}")
    if not isinstance(payload, Mapping):
        _fail(f"xcresulttool {label} root must be a JSON object")
    return payload


def _legacy_xcresult_summary(result_path: Path) -> Mapping[str, Any]:
    root = _legacy_object(result_path)
    action_result = _legacy_test_action(root)
    tests_ref_id = _legacy_reference_id(action_result.get("testsRef"))
    tests_payload = _legacy_object(result_path, tests_ref_id)
    return legacy_summary_from_payload(root, tests_payload)


def xcresult_summary(result_path: Path) -> Mapping[str, Any]:
    if not result_path.is_dir():
        _fail(f"xcresult result bundle is missing: {result_path}")
    command = [
        "xcrun",
        "xcresulttool",
        "get",
        "test-results",
        "summary",
        "--path",
        str(result_path),
        "--compact",
    ]
    try:
        completed = subprocess.run(
            command,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        modern_error = f"xcresulttool summary failed: {_subprocess_error_detail(error)}"
        try:
            return _legacy_xcresult_summary(result_path)
        except XCResultInvariantError as legacy_error:
            _fail(f"{modern_error}; legacy fallback failed: {legacy_error}")
    try:
        payload = json.loads(completed.stdout)
    except (json.JSONDecodeError, TypeError) as error:
        modern_error = f"xcresulttool summary is not valid JSON: {error}"
        try:
            return _legacy_xcresult_summary(result_path)
        except XCResultInvariantError as legacy_error:
            _fail(f"{modern_error}; legacy fallback failed: {legacy_error}")
    if not isinstance(payload, Mapping):
        modern_error = "xcresulttool summary root must be a JSON object"
        try:
            return _legacy_xcresult_summary(result_path)
        except XCResultInvariantError as legacy_error:
            _fail(f"{modern_error}; legacy fallback failed: {legacy_error}")
    return payload


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result", type=Path, required=True, help="path to the .xcresult bundle")
    parser.add_argument("--minimum-tests", type=int, required=True)
    parser.add_argument(
        "--summary-file",
        type=Path,
        help="optional summary JSON (for diagnostics/tests); otherwise invoke xcrun",
    )
    args = parser.parse_args()
    summary = read_summary(args.summary_file) if args.summary_file else xcresult_summary(args.result)
    validated = validate_summary(summary, args.minimum_tests)
    print(
        "xcresult: PASS; "
        f"{validated['passedTests']}/{validated['totalTestCount']} tests passed "
        f"(minimum {args.minimum_tests})"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except XCResultInvariantError as error:
        print(f"xcresult invariants: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
