#!/usr/bin/env python3
"""Load and validate the single source of truth for native test lanes.

The workflow, local Apple wrapper, and Release prerelease runner all consume
this manifest.  Keeping lane IDs in their small orchestration matrices is
intentional; every executable setting (scheme, plan, configuration, target
scope, timeout, and artifact paths) comes from this file and is cross-checked
by ``validate_native_calendar.py``.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Mapping


ROOT = Path(__file__).resolve().parents[1]
MANIFEST_PATH = ROOT / "scripts/native_lane_manifest.json"
REQUIRED_FIELDS = {
    "kind",
    "scheme",
    "test_plan",
    "platform",
    "configuration",
    "destination",
    "only_testing",
    "minimum_tests",
    "timeout_minutes",
    "result_path",
    "log_path",
    "derived_data_path",
}


class LaneManifestError(ValueError):
    """Raised when the native lane manifest is incomplete or unsafe."""


def _fail(message: str) -> None:
    raise LaneManifestError(message)


def load_manifest(path: Path = MANIFEST_PATH) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        _fail(f"native lane manifest is missing: {path}")
    except json.JSONDecodeError as error:
        _fail(f"native lane manifest is not valid JSON: {error}")
    if not isinstance(payload, dict):
        _fail("native lane manifest root must be an object")
    validate_manifest(payload)
    return payload


def _safe_relative_filename(value: Any, field: str, lane_id: str) -> str:
    if not isinstance(value, str) or not value or Path(value).name != value:
        _fail(f"{lane_id}: {field} must be a non-empty relative filename")
    if value in {".", ".."} or "${" in value or "$({" in value:
        _fail(f"{lane_id}: {field} contains an unresolved path variable")
    return value


def validate_manifest(payload: Mapping[str, Any]) -> None:
    if payload.get("version") != 1:
        _fail("native lane manifest version must be 1")
    job_timeout = payload.get("ci_timeout_minutes")
    if isinstance(job_timeout, bool) or not isinstance(job_timeout, int) or job_timeout <= 0:
        _fail("ci_timeout_minutes must be a positive integer")
    preferred_simulator = payload.get("preferred_ios_simulator")
    if preferred_simulator != "iPhone 17":
        _fail("preferred_ios_simulator must remain iPhone 17")
    lanes = payload.get("lanes")
    if not isinstance(lanes, dict) or not lanes:
        _fail("native lane manifest must contain lanes")
    seen_schemes: set[str] = set()
    seen_plans: set[str] = set()
    for lane_id, lane in lanes.items():
        if not isinstance(lane_id, str) or not isinstance(lane, Mapping):
            _fail("native lane manifest lanes must map string IDs to objects")
        missing = sorted(REQUIRED_FIELDS - set(lane))
        if missing:
            _fail(f"{lane_id}: missing fields {missing}")
        kind = lane["kind"]
        if kind not in {"debug", "prerelease"}:
            _fail(f"{lane_id}: unknown lane kind {kind!r}")
        platform = lane["platform"]
        if platform not in {"ios", "macos"}:
            _fail(f"{lane_id}: unknown platform {platform!r}")
        expected_configuration = "Debug" if kind == "debug" else "Release"
        if lane["configuration"] != expected_configuration:
            _fail(f"{lane_id}: {kind} lanes must use {expected_configuration}")
        scheme = lane["scheme"]
        plan = lane["test_plan"]
        if not isinstance(scheme, str) or not scheme or scheme in seen_schemes:
            _fail(f"{lane_id}: schemes must be unique non-empty strings")
        if not isinstance(plan, str) or not plan or plan in seen_plans:
            _fail(f"{lane_id}: test plans must be unique non-empty strings")
        seen_schemes.add(scheme)
        seen_plans.add(plan)
        if not isinstance(lane["destination"], str) or not lane["destination"]:
            _fail(f"{lane_id}: destination must be a non-empty string")
        if platform == "ios":
            if lane.get("simulator_name") != preferred_simulator:
                _fail(f"{lane_id}: iOS simulator must use the preferred {preferred_simulator}")
            if "platform=iOS Simulator" not in lane["destination"]:
                _fail(f"{lane_id}: iOS destination must be a simulator destination")
        elif "platform=macOS" not in lane["destination"]:
            _fail(f"{lane_id}: macOS destination must target platform=macOS")
        only_testing = lane["only_testing"]
        if (
            not isinstance(only_testing, list)
            or not only_testing
            or any(not isinstance(target, str) or not target for target in only_testing)
        ):
            _fail(f"{lane_id}: only_testing must be a non-empty list of target names")
        for field in ("minimum_tests", "timeout_minutes"):
            value = lane[field]
            if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
                _fail(f"{lane_id}: {field} must be a positive integer")
        if lane["timeout_minutes"] != job_timeout:
            _fail(f"{lane_id}: timeout_minutes must match ci_timeout_minutes")
        for field in ("result_path", "log_path", "derived_data_path"):
            _safe_relative_filename(lane[field], field, lane_id)
        if lane["result_path"] == lane["log_path"]:
            _fail(f"{lane_id}: result_path and log_path must differ")


def lane(lane_id: str, path: Path = MANIFEST_PATH) -> Mapping[str, Any]:
    payload = load_manifest(path)
    try:
        return payload["lanes"][lane_id]
    except KeyError:
        _fail(f"unknown native lane: {lane_id}")


def _field_value(lane_data: Mapping[str, Any], field: str) -> str:
    if field == "only_testing":
        return ",".join(str(value) for value in lane_data[field])
    value = lane_data.get(field)
    if value is None:
        _fail(f"lane field is missing: {field}")
    if isinstance(value, (dict, list)):
        _fail(f"lane field is not scalar: {field}")
    return str(value)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lane", required=True)
    parser.add_argument("--field", help="print one scalar field")
    parser.add_argument("--github-output", type=Path, help="write all shell-safe fields to GITHUB_OUTPUT")
    args = parser.parse_args(argv)
    try:
        lane_data = lane(args.lane)
        if not args.field and not args.github_output:
            parser.error("one of --field or --github-output is required")
        if args.field:
            print(_field_value(lane_data, args.field))
        if args.github_output:
            output_fields = (
                "scheme",
                "test_plan",
                "platform",
                "configuration",
                "destination",
                "simulator_name",
                "only_testing",
                "minimum_tests",
                "timeout_minutes",
                "result_path",
                "log_path",
                "derived_data_path",
            )
            with args.github_output.open("a", encoding="utf-8") as handle:
                for field in output_fields:
                    if field in lane_data:
                        handle.write(f"{field}={_field_value(lane_data, field)}\n")
                handle.write(f"lane_kind={lane_data['kind']}\n")
        return 0
    except LaneManifestError as error:
        print(f"native lane manifest: FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
