from __future__ import annotations

import json
import plistlib
import re
import sys
from pathlib import Path

try:
    from lane_manifest import LaneManifestError, load_manifest
except ModuleNotFoundError:  # Import works both as a script and as scripts.* in tests.
    from scripts.lane_manifest import LaneManifestError, load_manifest

ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


TARGET_IDENTIFIERS = {
    "LifeOS": "AD5DB9344CDCD6867ABB9D4E",
    "LifeOSWidget": "E58A333F8DF1A794FCC029A3",
    "LifeOSTests": "B6DC0030DCD7D810745068F6",
    "LifeOSUITests": "F416C705B05A08F9488EEA6E",
    "LifeOSMac": "71437E54A44714BC8BB2AFEC",
    "LifeOSMacUITests": "E02714DF1E6E1D2F74181BCC",
    "LifeOSMacSnapshotTests": "2538E14CF3E9C3897F91D13B",
    "LifeOSWidgetSnapshotTests": "744652A86D2BF1DB30BFA2B9",
    "LifeOSMacWidget": "0A09F6FAC73B6A2CCEE0554F",
}


# This is deliberately a minimum, not a promise that the source can never
# gain another test. A decrease is a topology regression; a new test is
# normal product work and should not require changing this validator first.
TEST_TARGETS = {
    "LifeOSTests": ("LifeOSTests", "bundle.unit-test", 386),
    "LifeOSUITests": ("LifeOSUITests", "bundle.ui-testing", 18),
    "LifeOSMacSnapshotTests": ("LifeOSMacSnapshotTests", "bundle.unit-test", 31),
    "LifeOSMacUITests": ("LifeOSMacUITests", "bundle.ui-testing", 6),
    "LifeOSWidgetSnapshotTests": ("LifeOSWidgetSnapshotTests", "bundle.unit-test", 26),
}


# Keep this table next to the validator so the runnable command matrix is
# reviewable even on a host where Xcode cannot be launched. Prerelease is
# intentionally split into two platform-valid schemes; the orchestration
# script invokes them separately so no test action must materialize disjoint
# iOS and macOS products.
LANES = {
    "LifeOSLogic": {
        "plan": "TestPlans/LifeOSLogic.xctestplan",
        "platform": "iOS",
        "destinations": ("platform=iOS Simulator,name=iPhone 17,OS=latest",),
        "test_targets": ("LifeOSTests",),
        "minimum": 386,
        "materialization": "iOS logic XCTest bundle hosted by LifeOS",
        "host": "LifeOS",
    },
    "LifeOSUI": {
        "plan": "TestPlans/LifeOSUI.xctestplan",
        "platform": "iOS",
        "destinations": ("platform=iOS Simulator,name=iPhone 17,OS=latest",),
        "test_targets": ("LifeOSUITests",),
        "minimum": 18,
        "materialization": "iOS UI XCTest bundle hosted by LifeOS",
        "host": "LifeOS",
    },
    "LifeOSMacLogic": {
        "plan": "TestPlans/LifeOSMacLogic.xctestplan",
        "platform": "macOS",
        "destinations": ("platform=macOS",),
        "test_targets": ("LifeOSMacSnapshotTests",),
        "minimum": 31,
        "materialization": "macOS logic/snapshot XCTest bundle hosted by LifeOSMac",
        "host": "LifeOSMac",
    },
    "LifeOSMacUI": {
        "plan": "TestPlans/LifeOSMacUI.xctestplan",
        "platform": "macOS",
        "destinations": ("platform=macOS",),
        "test_targets": ("LifeOSMacUITests",),
        "minimum": 6,
        "materialization": "macOS UI XCTest bundle hosted by LifeOSMac",
        "host": "LifeOSMac",
    },
    "LifeOSWidgets": {
        "plan": "TestPlans/LifeOSWidgets.xctestplan",
        "platform": "macOS",
        "destinations": ("platform=macOS",),
        "test_targets": ("LifeOSWidgetSnapshotTests",),
        "minimum": 26,
        "materialization": "hostless macOS widget snapshot XCTest bundle",
        "host": None,
    },
    "LifeOSPrereleaseIOS": {
        "plan": "TestPlans/LifeOSPrereleaseIOS.xctestplan",
        "platform": "iOS",
        "destinations": ("platform=iOS Simulator,name=iPhone 17,OS=latest",),
        "test_targets": ("LifeOSTests", "LifeOSUITests"),
        "minimum": TEST_TARGETS["LifeOSTests"][2] + TEST_TARGETS["LifeOSUITests"][2],
        "materialization": "Release iOS app + widget prerelease bundles hosted by LifeOS",
        "host": "LifeOS",
    },
    "LifeOSPrereleaseMac": {
        "plan": "TestPlans/LifeOSPrereleaseMac.xctestplan",
        "platform": "macOS",
        "destinations": ("platform=macOS",),
        "test_targets": (
            "LifeOSMacSnapshotTests",
            "LifeOSMacUITests",
            "LifeOSWidgetSnapshotTests",
        ),
        "minimum": (
            TEST_TARGETS["LifeOSMacSnapshotTests"][2]
            + TEST_TARGETS["LifeOSMacUITests"][2]
            + TEST_TARGETS["LifeOSWidgetSnapshotTests"][2]
        ),
        "materialization": "Release macOS app + widget prerelease bundles; widget snapshots remain hostless",
        "host": "LifeOSMac",
    },
}


def top_level_section(text: str, name: str) -> str:
    """Return a top-level YAML section without requiring PyYAML."""

    lines = text.splitlines()
    marker = f"{name}:"
    start = next((index for index, line in enumerate(lines) if line == marker), None)
    require(start is not None, f"project.yml missing top-level {name}: section")
    section = []
    for line in lines[start + 1 :]:
        if line and not line.startswith((" ", "\t")):
            break
        section.append(line)
    return "\n".join(section) + "\n"


def named_yaml_block(section: str, name: str, indent: int = 2) -> str:
    """Return one mapping child from a known YAML section."""

    lines = section.splitlines()
    marker = f"{' ' * indent}{name}:"
    start = next((index for index, line in enumerate(lines) if line == marker), None)
    require(start is not None, f"section missing {name}:")
    end = len(lines)
    for index in range(start + 1, len(lines)):
        if lines[index].startswith(" " * indent) and not lines[index].startswith(" " * (indent + 1)):
            end = index
            break
    return "\n".join(lines[start:end]) + "\n"


def yaml_sequence(block: str, field: str, field_indent: int = 4) -> list[str]:
    """Read an inline or indented YAML sequence from a target/scheme block."""

    lines = block.splitlines()
    marker = f"{' ' * field_indent}{field}:"
    start = next((index for index, line in enumerate(lines) if line.startswith(marker)), None)
    require(start is not None, f"block missing {field}:")
    line = lines[start]
    inline = line.split(":", 1)[1].strip()
    if inline:
        require(inline.startswith("[") and inline.endswith("]"), f"{field} must be a YAML sequence")
        return [value.strip().strip("'\"") for value in inline[1:-1].split(",") if value.strip()]

    values: list[str] = []
    for candidate in lines[start + 1 :]:
        if candidate and len(candidate) - len(candidate.lstrip(" ")) <= field_indent:
            break
        stripped = candidate.strip()
        if stripped.startswith("-"):
            values.append(stripped[1:].strip().strip("'\""))
    return values


def target_sources(block: str) -> list[str]:
    return yaml_sequence(block, "sources")


def validate_lane_manifest() -> None:
    """Cross-check executable lane settings against the source topology."""

    try:
        manifest = load_manifest()
    except LaneManifestError as error:
        raise AssertionError(str(error)) from error
    manifest_lanes = manifest["lanes"]
    expected_lane_ids = {
        "ios-logic": "LifeOSLogic",
        "ios-ui": "LifeOSUI",
        "mac-logic": "LifeOSMacLogic",
        "mac-ui": "LifeOSMacUI",
        "widgets": "LifeOSWidgets",
        "prerelease-ios": "LifeOSPrereleaseIOS",
        "prerelease-mac": "LifeOSPrereleaseMac",
    }
    require(set(manifest_lanes) == set(expected_lane_ids), "native lane manifest IDs drifted")
    ci_timeout = manifest["ci_timeout_minutes"]
    workflow_path = ROOT / ".github/workflows/native-apple.yml"
    require(workflow_path.is_file(), f"native workflow missing: {lane_path(workflow_path)}")
    workflow = workflow_path.read_text(encoding="utf-8")
    timeout_match = re.search(r"(?m)^\s+timeout-minutes:\s*(\d+)\s*$", workflow)
    require(timeout_match is not None, "native workflow must declare a job timeout")
    require(int(timeout_match.group(1)) == ci_timeout, "workflow timeout drifted from lane manifest")
    require("python3 -B scripts/lane_manifest.py" in workflow, "native workflow must load the lane manifest")
    require("matrix.lane" in workflow, "native workflow must resolve the matrix lane")
    require("--github-output \"$GITHUB_OUTPUT\"" in workflow, "native workflow must expose lane settings")
    require("fetch-depth: 0" in workflow, "native workflow must fetch the expected evidence commit")
    require('if: steps.lane.outputs.platform == \'ios\'' in workflow, "native workflow must gate simulator selection by manifest platform")
    require('"iPhone" in device.get("name", "")' in workflow, "native workflow fallback must remain iPhone-only")
    require(
        "python3 -B scripts/validate_acceptance_registry.py\n" in workflow,
        "native workflow must run normal registry integrity validation without an evidence override",
    )
    require(
        "python3 -B scripts/validate_acceptance_registry.py --score\n" in workflow
        and "inputs.final_acceptance" in workflow,
        "native workflow must expose an explicit manual final-acceptance score gate",
    )
    require(
        "--expected-commit \"$expected_commit\"" not in workflow,
        "native workflow must not pass HEAD/PR SHA as an implicit evidence override",
    )
    for lane_id, scheme in expected_lane_ids.items():
        lane = manifest_lanes[lane_id]
        source_lane = LANES[scheme]
        require(lane["scheme"] == scheme, f"{lane_id} scheme drifted")
        require(lane["test_plan"] == scheme, f"{lane_id} test plan drifted")
        require(lane["platform"] == source_lane["platform"].lower(), f"{lane_id} platform drifted")
        require(lane["destination"] == source_lane["destinations"][0], f"{lane_id} destination drifted")
        require(lane["only_testing"] == list(source_lane["test_targets"]), f"{lane_id} only-testing drifted")
        require(lane["minimum_tests"] == source_lane["minimum"], f"{lane_id} minimum test count drifted")
        expected_configuration = "Debug" if lane["kind"] == "debug" else "Release"
        require(lane["configuration"] == expected_configuration, f"{lane_id} configuration drifted")
        require(lane["timeout_minutes"] == ci_timeout, f"{lane_id} timeout drifted")
        if lane["kind"] == "debug":
            require(lane["result_path"] == f"lifeos-{lane_id}.xcresult", f"{lane_id} result path drifted")
            require(lane["log_path"] == f"lifeos-{lane_id}-xcodebuild.log", f"{lane_id} log path drifted")
            require(lane["derived_data_path"] == f"lifeos-derived-{lane_id}", f"{lane_id} DerivedData path drifted")
            require(f"- lane: {lane_id}" in workflow, f"native workflow is missing {lane_id}")
        else:
            require(lane["result_path"] == f"{scheme}.xcresult", f"{lane_id} result path drifted")
            require(lane["log_path"] == f"{scheme}-xcodebuild.log", f"{lane_id} log path drifted")
            require(lane["derived_data_path"] == scheme, f"{lane_id} DerivedData path drifted")

    prerelease_path = ROOT / "scripts/run_prerelease_lanes.sh"
    require(prerelease_path.is_file(), f"prerelease script missing: {lane_path(prerelease_path)}")
    prerelease = prerelease_path.read_text(encoding="utf-8")
    require("scripts/lane_manifest.py" in prerelease, "prerelease script must consume the lane manifest")
    require('run_lane "prerelease-ios"' in prerelease, "prerelease script is missing the iOS lane")
    require('run_lane "prerelease-mac"' in prerelease, "prerelease script is missing the macOS lane")
    require('"-only-testing:$target"' in prerelease, "prerelease script must enforce only-testing scope")
    require('-configuration "$configuration"' in prerelease, "prerelease script must consume manifest configuration")
    require("validate_xcresult.py" in prerelease, "prerelease script must validate result bundles")

    local_path = ROOT / "scripts/validate_apple_on_mac.sh"
    require(local_path.is_file(), f"local Apple validator missing: {lane_path(local_path)}")
    local = local_path.read_text(encoding="utf-8")
    require("scripts/lane_manifest.py" in local, "local Apple validator must consume the lane manifest")
    require('run_ios_lane "ios-logic"' in local, "local Apple validator is missing iOS logic lane")
    require('run_mac_lane "mac-logic"' in local, "local Apple validator is missing macOS logic lane")
    require("simctl terminate" in local and "simctl shutdown" in local, "local Apple validator must clean up simulator processes")
    require("simctl terminate" in prerelease and "simctl shutdown" in prerelease, "prerelease script must clean up simulator processes")



def test_function_count(target_name: str) -> int:
    directory = IOS / TEST_TARGETS[target_name][0]
    pattern = re.compile(r"^\s*func\s+test[A-Za-z0-9_]*\s*\(")
    return sum(
        1
        for source in directory.glob("*.swift")
        for line in source.read_text(encoding="utf-8").splitlines()
        if pattern.match(line)
    )


def generated_target_identifiers() -> dict[str, str]:
    """Read target UUIDs from an optional generated project for drift checks."""

    pbx_path = IOS / "LifeOS.xcodeproj/project.pbxproj"
    if not pbx_path.is_file():
        return {}
    pbx = pbx_path.read_text(encoding="utf-8")
    return {
        name: identifier
        for identifier, name in re.findall(
            r"(?m)^\s*([0-9A-F]{24}) /\* ([A-Za-z0-9_]+) \*/ = \{\n\s*isa = PBXNativeTarget;",
            pbx,
        )
    }


def validate_xcode_topology(project: str) -> list[str]:
    """Validate source-of-truth lanes before XcodeGen materializes the project."""

    validate_lane_manifest()
    target_section = top_level_section(project, "targets")
    scheme_section = top_level_section(project, "schemes")
    require("  LifeOSPrerelease:" not in scheme_section, "mixed-platform LifeOSPrerelease scheme must be removed")
    require(
        not (IOS / "TestPlans/LifeOSPrerelease.xctestplan").exists(),
        "mixed-platform LifeOSPrerelease test plan must be removed",
    )

    orchestration_path = ROOT / "scripts/run_prerelease_lanes.sh"
    require(orchestration_path.is_file(), f"prerelease orchestration script missing: {lane_path(orchestration_path)}")
    orchestration = orchestration_path.read_text(encoding="utf-8")
    for prerelease_lane in ("prerelease-ios", "prerelease-mac"):
        require(
            f'run_lane "{prerelease_lane}"' in orchestration,
            f"prerelease orchestration does not invoke {prerelease_lane}",
        )
    require("-testPlan \"$test_plan\"" in orchestration, "prerelease orchestration must select each lane's test plan")
    require("-only-testing:$target" in orchestration, "prerelease orchestration must scope each test target")
    require("-configuration \"$configuration\"" in orchestration, "prerelease orchestration must select configuration")
    require(
        'destination="$(manifest_value "$lane_id" destination)"' in orchestration,
        "prerelease orchestration must consume manifest destinations",
    )

    expected_target_membership = {
        "LifeOS": ("LifeOS", "Shared", "Shared/FitnessMetric.swift"),
        "LifeOSWidget": ("LifeOSWidget", "Shared", "Shared/FitnessMetric.swift"),
        "LifeOSMac": ("LifeOSMac", "Shared", "Shared/FitnessMetric.swift"),
        "LifeOSMacWidget": ("LifeOSMacWidget", "Shared", "Shared/FitnessMetric.swift"),
        "LifeOSTests": ("LifeOSTests",),
        "LifeOSUITests": ("LifeOSUITests",),
        "LifeOSMacUITests": ("LifeOSMacUITests",),
        "LifeOSMacSnapshotTests": ("LifeOSMacSnapshotTests",),
        "LifeOSWidgetSnapshotTests": ("LifeOSWidgetSnapshotTests",),
    }
    forbidden_membership = {
        "LifeOS": ("LifeOSMac",),
        "LifeOSWidget": ("LifeOS/LifeOSApp.swift", "LifeOSMac"),
        "LifeOSMac": ("LifeOS/LifeOSApp.swift",),
        "LifeOSMacWidget": ("LifeOS/LifeOSApp.swift", "LifeOSMac/LifeOSMacApp.swift"),
    }

    target_blocks: dict[str, str] = {}
    for target_name, required_paths in expected_target_membership.items():
        block = named_yaml_block(target_section, target_name)
        target_blocks[target_name] = block
        sources = target_sources(block)
        for required_path in required_paths:
            require(required_path in sources, f"{target_name} target membership missing {required_path}")
        for forbidden_path in forbidden_membership.get(target_name, ()):
            require(forbidden_path not in sources, f"{target_name} target membership must exclude {forbidden_path}")

    materialized_ids = generated_target_identifiers()
    if materialized_ids:
        for target_name, expected_identifier in TARGET_IDENTIFIERS.items():
            require(
                materialized_ids.get(target_name) == expected_identifier,
                f"generated target ID drifted for {target_name}; regenerate checked-in test plans",
            )
    plan_identifiers = materialized_ids or TARGET_IDENTIFIERS

    for target_name, (_, product_type, minimum) in TEST_TARGETS.items():
        block = target_blocks[target_name]
        require(f"type: {product_type}" in block, f"{target_name} materialization type changed")
        actual = test_function_count(target_name)
        require(actual > 0, f"{target_name} has zero materialized XCTest methods")
        require(actual >= minimum, f"{target_name} has {actual} tests; minimum is {minimum}")

    for lane_name, lane in LANES.items():
        scheme = named_yaml_block(scheme_section, lane_name)
        require(lane["plan"] in scheme, f"{lane_name} does not reference {lane['plan']}")
        test_block = scheme[scheme.index("    test:") :]
        configured_targets = yaml_sequence(test_block, "targets", field_indent=6)
        require(
            tuple(configured_targets) == lane["test_targets"],
            f"{lane_name} test target membership is {configured_targets}, expected {list(lane['test_targets'])}",
        )
        require("shared: true" in scheme, f"{lane_name} must be a shared scheme")

        plan_path = IOS / lane["plan"]
        require(plan_path.is_file(), f"{lane_name} test plan missing: {lane_path(plan_path)}")
        try:
            plan = json.loads(plan_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            raise AssertionError(f"{lane_name} test plan is invalid JSON: {error}") from error
        require(plan.get("version") == 1, f"{lane_name} test plan version must be 1")
        entries = plan.get("testTargets")
        require(isinstance(entries, list) and entries, f"{lane_name} test plan has no test targets")
        plan_targets = []
        for entry in entries:
            target = entry.get("target", {}) if isinstance(entry, dict) else {}
            target_name = target.get("name")
            plan_targets.append(target_name)
            require(target_name in TEST_TARGETS, f"{lane_name} references unknown test target {target_name}")
            require(target.get("containerPath") == "container:LifeOS.xcodeproj", f"{lane_name} target container changed")
            require(target.get("identifier") == plan_identifiers[target_name], f"{lane_name} target ID changed for {target_name}")
            require(entry.get("parallelizable") is False, f"{lane_name}/{target_name} must be non-parallel for bounded evidence")
        require(tuple(plan_targets) == lane["test_targets"], f"{lane_name} test-plan membership is {plan_targets}")

        variable_target = plan.get("defaultOptions", {}).get("targetForVariableExpansion")
        if lane["host"] is None:
            require(variable_target is None, f"{lane_name} must not materialize an app host")
        else:
            require(variable_target is not None, f"{lane_name} must declare its host materialization")
            require(variable_target.get("name") == lane["host"], f"{lane_name} host is not {lane['host']}")
            require(variable_target.get("identifier") == plan_identifiers[lane["host"]], f"{lane_name} host ID changed")

    widget_block = target_blocks["LifeOSWidgetSnapshotTests"]
    require('TEST_HOST: ""' in widget_block, "widget snapshots must explicitly set an empty TEST_HOST")
    require('BUNDLE_LOADER: ""' in widget_block, "widget snapshots must explicitly set an empty BUNDLE_LOADER")
    require("- target:" not in widget_block, "widget snapshots must not depend on a host target")

    # If a generated project is already present, inspect its materialized
    # shared schemes too. CI invokes this validator before generation, so the
    # source-level checks above remain authoritative there.
    generated_scheme_dir = IOS / "LifeOS.xcodeproj/xcshareddata/xcschemes"
    materialization = "source"
    if generated_scheme_dir.is_dir():
        expected_scheme_names = set(LANES)
        actual_scheme_names = {path.stem for path in generated_scheme_dir.glob("*.xcscheme")}
        missing_generated = sorted(expected_scheme_names - actual_scheme_names)
        if missing_generated:
            # The generated project is ignored and may predate this source
            # change. Do not mistake that stale local artifact for current
            # materialization; validate_generated_project handles regeneration
            # separately and will report the drift explicitly.
            materialization = f"source (ignored generated project stale; missing {missing_generated})"
        else:
            for lane_name, lane in LANES.items():
                scheme_path = generated_scheme_dir / f"{lane_name}.xcscheme"
                scheme_xml = scheme_path.read_text(encoding="utf-8")
                require(f"container:{lane['plan']}" in scheme_xml, f"generated {lane_name} plan reference missing")
                materialized_targets = re.findall(r'BlueprintName = "([^"]+)"', scheme_xml)
                testable_targets = re.findall(r'<TestableReference[\s\S]*?<BuildableReference[\s\S]*?BlueprintName = "([^"]+)"', scheme_xml)
                require(set(lane["test_targets"]).issubset(set(testable_targets)), f"generated {lane_name} testables are incomplete")
                if lane_name == "LifeOSMacUI":
                    require(testable_targets == ["LifeOSMacUITests"], "generated LifeOSMacUI must contain only LifeOSMacUITests")
                if lane_name == "LifeOSWidgets":
                    require("TEST_HOST" not in scheme_xml, "generated LifeOSWidgets must remain hostless")
                require(materialized_targets, f"generated {lane_name} has no buildable targets")
            materialization = "generated + source"

    return [
        f"{name}: platform={lane['platform']}; destinations={list(lane['destinations'])}; "
        f"test-targets={list(lane['test_targets'])}; minimum={lane['minimum']}; "
        f"materialization={lane['materialization']}"
        for name, lane in LANES.items()
    ] + [f"scheme materialization checked: {materialization}"]


def lane_path(path: Path) -> str:
    try:
        return str(path.relative_to(ROOT))
    except ValueError:
        return str(path)


def main() -> int:
    project = (IOS / "project.yml").read_text(encoding="utf-8")
    required_files = [
        "Shared/CalendarDomain.swift",
        "Shared/CalendarIconAsset.swift",
        "Shared/CalendarStore.swift",
        "Shared/CalendarViews.swift",
        "LifeOS/CalendarView.swift",
        "LifeOSWidget/CalendarWidget.swift",
        "LifeOSMac/LifeOSMacApp.swift",
        "LifeOSMac/Info.plist",
        "LifeOSMac/LifeOSMac.entitlements",
        "LifeOSMacWidget/LifeOSMacWidget.swift",
        "LifeOSMacWidget/Info.plist",
        "LifeOSMacWidget/LifeOSMacWidget.entitlements",
        "LifeOSTests/CalendarDomainTests.swift",
        "LifeOSTests/CalendarIconAssetTests.swift",
        "LifeOSMacUITests/LifeOSMacUITests.swift",
        "LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift",
        "Shared/SigningStatus.swift",
        "LifeOSTests/SigningStatusTests.swift",
        "Shared/CalendarPeerSync.swift",
        "LifeOSTests/CalendarPeerSyncTests.swift",
    ]
    missing = [relative for relative in required_files if not (IOS / relative).is_file()]
    require(not missing, f"missing native calendar/macOS files: {missing}")

    for token in ("LifeOSMac:", "LifeOSMacWidget:", 'macOS: "14.0"',
                  "CODE_SIGN_ENTITLEMENTS: LifeOS/LifeOS.entitlements",
                  "CODE_SIGN_ENTITLEMENTS: LifeOSWidget/LifeOSWidget.entitlements",
                  "CODE_SIGN_ENTITLEMENTS: LifeOSMac/LifeOSMac.entitlements",
                  "CODE_SIGN_ENTITLEMENTS: LifeOSMacWidget/LifeOSMacWidget.entitlements"):
        require(token in project, f"project.yml missing {token}")

    # Keep each executable target's entry point isolated and make every
    # acceptance lane explicit before XcodeGen materializes the project.
    lane_matrix = validate_xcode_topology(project)

    design_tokens = (IOS / "Shared/DesignTokens.swift").read_text(encoding="utf-8")
    for token in ("lifeOSDarkCanvas", "lifeOSLightCanvas", "traits.userInterfaceStyle == .dark", ".darkAqua"):
        require(token in design_tokens, f"adaptive light/dark design tokens missing {token}")

    ios_ui_tests = (IOS / "LifeOSUITests/LifeOSUITests.swift").read_text(encoding="utf-8")
    for token in ("testDarkModeScreenshots", '"dark-overview"', '"dark-usage"',
                  '"dark-calendar-three-day"', '"dark-calendar-month"',
                  '"dark-tax-documents"', '"dark-settings"'):
        require(token in ios_ui_tests, f"iOS dark visual coverage missing {token}")

    mac_snapshots = (IOS / "LifeOSMacSnapshotTests/LifeOSMacSnapshotTests.swift").read_text(encoding="utf-8")
    for token in ("testDarkModeSnapshots", "colorScheme: .dark", "LifeOSMacRootView-overview-dark",
                  "CalendarView-dark", "TaxDocumentsView-dark"):
        require(token in mac_snapshots, f"macOS dark snapshot coverage missing {token}")

    usage_widget = (IOS / "LifeOSWidget/UsageWidget.swift").read_text(encoding="utf-8")
    calendar_widget_source = (IOS / "LifeOSWidget/CalendarWidget.swift").read_text(encoding="utf-8")
    require("LifeOSTokens.surface" in usage_widget, "usage widget must use an adaptive branded surface")
    require("LifeOSTokens.surface" in calendar_widget_source, "calendar widget must use an adaptive branded surface")

    ios_widget = (IOS / "LifeOSWidget/LifeOSWidget.swift").read_text(encoding="utf-8")
    require("WidgetBundle" in ios_widget, "iOS widget entry point must bundle usage and calendar widgets")
    require("CalendarWidget()" in ios_widget, "iOS widget bundle must include CalendarWidget")

    mac_widget = (IOS / "LifeOSMacWidget/LifeOSMacWidget.swift").read_text(encoding="utf-8")
    require("WidgetBundle" in mac_widget, "macOS widget extension must define a WidgetBundle")
    require("CalendarWidget()" in mac_widget, "macOS widget bundle must include CalendarWidget")

    app = (IOS / "LifeOS/LifeOSApp.swift").read_text(encoding="utf-8")
    require("Calendar" in app or "RootTabView" in app, "iOS app must expose the calendar")

    parsed_plists = {}
    for relative in ("LifeOS/Info.plist", "LifeOSWidget/Info.plist", "LifeOSMac/Info.plist", "LifeOSMacWidget/Info.plist"):
        with (IOS / relative).open("rb") as handle:
            parsed_plists[relative] = plistlib.load(handle)

    # CalendarPeerSync uses MultipeerConnectivity's service type, while the
    # plist uses Bonjour's corresponding underscored TCP service name.
    peer_sync = (IOS / "Shared/CalendarPeerSync.swift").read_text(encoding="utf-8")
    require('serviceType = "lifeos-calendar"' in peer_sync, "CalendarPeerSync service type changed")
    bonjour_service = "_lifeos-calendar._tcp"
    for relative in ("LifeOS/Info.plist", "LifeOSMac/Info.plist"):
        plist = parsed_plists[relative]
        require(plist.get("NSLocalNetworkUsageDescription"), f"{relative} must explain local peer-sync access")
        require(bonjour_service in plist.get("NSBonjourServices", []), f"{relative} must advertise {bonjour_service}")

    entitlements = {}
    for relative in ("LifeOS/LifeOS.entitlements", "LifeOSWidget/LifeOSWidget.entitlements",
                     "LifeOSMac/LifeOSMac.entitlements", "LifeOSMacWidget/LifeOSMacWidget.entitlements"):
        with (IOS / relative).open("rb") as handle:
            entitlements[relative] = plistlib.load(handle)
        groups = entitlements[relative].get("com.apple.security.application-groups", [])
        require(groups == ["$(APP_GROUP_IDENTIFIER)"], f"{relative} must use the shared App Group build setting")
    mac_entitlements = entitlements["LifeOSMac/LifeOSMac.entitlements"]
    require(mac_entitlements.get("com.apple.security.app-sandbox") is True, "macOS app must enable App Sandbox")
    require(mac_entitlements.get("com.apple.security.network.client") is True, "macOS app needs sandbox outbound-network permission")
    require(mac_entitlements.get("com.apple.security.network.server") is True, "macOS app needs sandbox inbound-network permission")
    require("REPLACE_WITH_TEAM_CONFIGURED_ID" in project, "App Group configuration must remain explicit until team-configured")

    calendar_domain = (IOS / "Shared/CalendarDomain.swift").read_text(encoding="utf-8")
    for token in ("CalendarItem", "CalendarProgress", "CalendarSnapshot", "deletedAt", "deleting(at:", "iconAsset"):
        require(token in calendar_domain, f"calendar domain missing {token}")

    icon_asset = (IOS / "Shared/CalendarIconAsset.swift").read_text(encoding="utf-8")
    for token in ("maxBytes", "init(from decoder:", "deterministicKey"):
        require(token in icon_asset, f"calendar icon validation missing {token}")

    calendar_view = (IOS / "LifeOS/CalendarView.swift").read_text(encoding="utf-8")
    for token in ("fileImporter", ".png", ".jpeg", "startAccessingSecurityScopedResource", "CalendarEmojiCatalog", "CalendarIconPickerTab"):
        require(token in calendar_view, f"calendar editor icon import missing {token}")

    shared_swift = "\n".join(path.read_text(encoding="utf-8") for path in (IOS / "Shared").glob("*.swift"))
    require(shared_swift.count("struct CalendarItem:") == 1, "CalendarItem must have one canonical shared declaration")
    require(shared_swift.count("enum CalendarProgress:") == 1, "CalendarProgress must have one canonical shared declaration")
    require(shared_swift.count("struct CalendarSnapshot:") == 1, "CalendarSnapshot must have one canonical shared declaration")

    calendar_widget = (IOS / "LifeOSWidget/CalendarWidget.swift").read_text(encoding="utf-8")
    require("systemMedium" in calendar_widget, "calendar widget must support the wide 2x4 family")

    print("native calendar/macOS source invariants: PASS")
    print("xcode test topology: PASS")
    for line in lane_matrix:
        print(f"  {line}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"native calendar/macOS source invariants: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
