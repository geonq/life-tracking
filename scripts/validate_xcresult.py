#!/usr/bin/env python3
"""Reject empty, canceled, skipped, or failed XCTest result bundles.

The existence of an ``.xcresult`` directory only proves that xcodebuild wrote
an artifact.  It does not prove that the intended test bundle materialised or
that any tests ran.  This validator consumes Apple's public
``xcresulttool get test-results summary`` JSON and enforces the lane's minimum
expected count before CI can treat the lane as green.
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
        output = getattr(error, "stdout", "") or ""
        _fail(f"xcresulttool summary failed: {output.strip()}")
    try:
        payload = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        _fail(f"xcresulttool summary is not valid JSON: {error}")
    if not isinstance(payload, Mapping):
        _fail("xcresulttool summary root must be a JSON object")
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
