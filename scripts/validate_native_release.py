#!/usr/bin/env python3
"""Validate source-safe and release-injected native LifeOS invariants.

The checked-in XcodeGen spec is intentionally a development-safe source of
truth: it has an empty sync allowlist, an unknown provisioning mode, and a
team-owned App Group placeholder.  Those values are useful because a local
unsigned build must fail closed.  A release lane must inject real values from
its signing environment and is rejected if any of those values remain.

This module deliberately uses only the Python standard library so it can run
on a clean GitHub-hosted macOS runner before any project build starts.
"""

from __future__ import annotations

import argparse
import os
import re
import sys
from pathlib import Path
from typing import Iterable, Mapping


ROOT = Path(__file__).resolve().parents[1]
IOS = ROOT / "ios"

EXPECTED_APP_GROUP_SOURCE = "group.com.hermes.lifeos.REPLACE_WITH_TEAM_CONFIGURED_ID"
EXPECTED_PROVISIONING_SOURCE = "unknown"
EXPECTED_SYNC_ALLOWLIST_SOURCE = ""

EXPECTED_IOS_PRIMARY = ("home", "calendar", "finance", "fitness", "more")
EXPECTED_MAC_PRIMARY = ("home", "calendar", "finance", "fitness", "tax", "settings")

RELEASE_ENVIRONMENT_KEYS = {
    "APP_GROUP_IDENTIFIER": "LIFEOS_RELEASE_APP_GROUP_IDENTIFIER",
    "PROVISIONING_MODE": "LIFEOS_RELEASE_PROVISIONING_MODE",
    "LIFEOS_SYNC_APPROVED_HOSTS": "LIFEOS_RELEASE_SYNC_APPROVED_HOSTS",
}

FIXTURE_FLAGS = (
    "-LifeOSVisualFixtures",
    "-LifeOSCalendarIconLibraryFixture",
    "-LifeOSForceDarkMode",
    "-LifeOSForceLightMode",
)
FIXTURE_TOKENS = tuple(flag.lstrip("-") for flag in FIXTURE_FLAGS)

_BUILD_VARIABLE = re.compile(r"\$\([A-Za-z_][A-Za-z0-9_]*\)|\$\{[^}]+\}")
_XCCONFIG_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
_HOST = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*\.ts\.net$")


class InvariantError(ValueError):
    """Raised when a release/source invariant is violated."""


def _fail(message: str) -> None:
    raise InvariantError(message)


def _read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        _fail(f"required native release input is missing: {path}")


def _require_file(path: Path) -> None:
    if not path.is_file():
        _fail(f"required native release input is missing: {path}")


def _single_setting(text: str, key: str) -> str | None:
    """Read the last simple ``KEY = value`` assignment in a text file."""

    value: str | None = None
    for line in text.splitlines():
        match = _XCCONFIG_LINE.match(line)
        if match and match.group(1) == key:
            value = match.group(2).strip().strip('"')
    return value


def parse_build_settings(text: str) -> dict[str, str]:
    """Parse xcodebuild or xcconfig-style assignments without dependencies."""

    settings: dict[str, str] = {}
    for line in text.splitlines():
        match = _XCCONFIG_LINE.match(line)
        if not match or line.lstrip().startswith("//"):
            continue
        settings[match.group(1)] = match.group(2).strip().strip('"')
    return settings


def _array_members(text: str, marker: str) -> tuple[str, ...]:
    match = re.search(re.escape(marker) + r"[^=]*=\s*\[(?P<body>.*?)\]", text, re.DOTALL)
    if not match:
        _fail(f"native primary navigation declaration missing: {marker}")
    return tuple(re.findall(r"\.([A-Za-z][A-Za-z0-9_]*)", match.group("body")))


def _enum_cases(text: str, enum_name: str) -> tuple[str, ...]:
    match = re.search(
        rf"enum\s+{re.escape(enum_name)}\b.*?\{{(?P<body>.*?)\n\}}",
        text,
        re.DOTALL,
    )
    if not match:
        _fail(f"native primary navigation enum missing: {enum_name}")
    values: list[str] = []
    saw_case = False
    for line in match.group("body").splitlines():
        case_match = re.match(r"\s*case\s+([^\n]+)", line)
        if case_match:
            saw_case = True
            declarations = case_match.group(1).split(",")
            for value in declarations:
                name = value.strip().split()[0]
                if re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", name):
                    values.append(name)
            continue
        # LifeOSAppTab declares all primary cases before its properties and
        # switches. Stop there so switch-case labels are not mistaken for
        # additional top-level navigation tabs.
        if saw_case and line.strip() and not line.lstrip().startswith("//"):
            break
    if not values:
        _fail(f"native primary navigation cases missing: {enum_name}")
    return tuple(values)


def validate_primary_navigation(root: Path = ROOT) -> None:
    """Reject accidental unfinished modules in the release-visible IA."""

    module_source = _read(root / "ios/LifeOS/Modules/ModuleNavigation.swift")
    mac_primary = _array_members(module_source, "static let macPrimaryModules")
    if mac_primary != EXPECTED_MAC_PRIMARY:
        _fail(
            "unexpected macOS primary modules: "
            f"expected {EXPECTED_MAC_PRIMARY}, found {mac_primary}"
        )

    ios_source = _read(root / "ios/LifeOS/LifeOSApp.swift")
    ios_primary = _enum_cases(ios_source, "LifeOSAppTab")
    if ios_primary != EXPECTED_IOS_PRIMARY:
        _fail(
            "unexpected iOS primary tabs: "
            f"expected {EXPECTED_IOS_PRIMARY}, found {ios_primary}"
        )


def _project_setting(project: str, key: str) -> str | None:
    # Only inspect the settings block near the global settings declaration. A
    # target-level release override is handled by the release build settings
    # supplied to ``validate_release``.
    match = re.search(rf"^\s+{re.escape(key)}:\s*(.*?)\s*$", project, re.MULTILINE)
    if not match:
        return None
    value = match.group(1).strip()
    if value.startswith("\"\"") and value.endswith("\"\""):
        return value[2:-2]
    if value.startswith('"') and value.endswith('"'):
        return value[1:-1]
    return value


def _reject_signed_source_values(project: str) -> None:
    app_group = _project_setting(project, "APP_GROUP_IDENTIFIER")
    provisioning = _project_setting(project, "PROVISIONING_MODE")
    allowlist = _project_setting(project, "LIFEOS_SYNC_APPROVED_HOSTS")

    if app_group != EXPECTED_APP_GROUP_SOURCE:
        _fail(
            "source App Group must remain the explicit team-owned placeholder; "
            "signed identifiers belong in release CI/local injection"
        )
    if provisioning != EXPECTED_PROVISIONING_SOURCE:
        _fail("source PROVISIONING_MODE must remain unknown/fail-closed")
    if allowlist != EXPECTED_SYNC_ALLOWLIST_SOURCE:
        _fail("source LIFEOS_SYNC_APPROVED_HOSTS must remain empty/fail-closed")


def _reject_source_fixture_build_flags(project: str) -> None:
    # Fixture launch arguments in UI tests are allowed. Build-time fixture
    # flags, however, would make a production target non-production.
    for token in FIXTURE_TOKENS:
        if token in project:
            _fail(f"fixture flag {token!r} must not be a project build setting")


def validate_source(root: Path = ROOT) -> None:
    """Validate the checked-in development-safe source contract."""

    project_path = root / "ios/project.yml"
    _require_file(project_path)
    project = _read(project_path)
    _reject_signed_source_values(project)
    _reject_source_fixture_build_flags(project)
    validate_primary_navigation(root)

    # Source plists/entitlements intentionally contain build variables. Keep
    # their set narrow so a typo cannot silently ship as an unresolved value.
    allowed_variables = {
        "EXECUTABLE_NAME",
        "PRODUCT_BUNDLE_IDENTIFIER",
        "PRODUCT_NAME",
        "MARKETING_VERSION",
        "CURRENT_PROJECT_VERSION",
        "APP_GROUP_IDENTIFIER",
        "PROVISIONING_MODE",
        "LIFEOS_SYNC_APPROVED_HOSTS",
    }
    source_paths = [
        root / "ios/LifeOS/Info.plist",
        root / "ios/LifeOSWidget/Info.plist",
        root / "ios/LifeOSMac/Info.plist",
        root / "ios/LifeOSMacWidget/Info.plist",
        root / "ios/LifeOS/LifeOS.entitlements",
        root / "ios/LifeOSWidget/LifeOSWidget.entitlements",
        root / "ios/LifeOSMac/LifeOSMac.entitlements",
        root / "ios/LifeOSMacWidget/LifeOSMacWidget.entitlements",
    ]
    for path in source_paths:
        _require_file(path)
        for variable in _BUILD_VARIABLE.findall(_read(path)):
            name = variable[2:-1] if variable.startswith("$(") else variable[2:-1]
            if name not in allowed_variables:
                _fail(f"unapproved unresolved build variable {variable} in {path}")


def _contains_placeholder(value: str) -> bool:
    lowered = value.lower()
    return any(token in lowered for token in ("replace_with", "placeholder", "changeme", "change_me"))


def _hosts(value: str) -> tuple[str, ...]:
    entries = tuple(part.strip().lower() for part in value.split(",") if part.strip())
    if not entries:
        _fail("release LIFEOS_SYNC_APPROVED_HOSTS must not be empty")
    invalid = [host for host in entries if not _HOST.fullmatch(host)]
    if invalid:
        _fail(f"release sync allowlist contains invalid/non-private hosts: {invalid}")
    if len(entries) != len(set(entries)):
        _fail("release sync allowlist contains duplicate hosts")
    return entries


def validate_release(
    settings: Mapping[str, str],
    *,
    root: Path = ROOT,
) -> None:
    """Validate release values after CI/local signing injection."""

    validate_source(root)

    required = ("APP_GROUP_IDENTIFIER", "PROVISIONING_MODE", "LIFEOS_SYNC_APPROVED_HOSTS")
    missing = [key for key in required if not settings.get(key, "").strip()]
    if missing:
        _fail(f"release settings missing required values: {', '.join(missing)}")

    unresolved: list[str] = []
    for key, value in settings.items():
        if _BUILD_VARIABLE.search(value):
            unresolved.append(f"{key}={value}")
    if unresolved:
        _fail(f"release settings contain unresolved build variables: {unresolved}")

    app_group = settings["APP_GROUP_IDENTIFIER"].strip()
    if not app_group.startswith("group.") or len(app_group) <= len("group."):
        _fail("release APP_GROUP_IDENTIFIER must be a non-empty group.* identifier")
    if _contains_placeholder(app_group):
        _fail("release APP_GROUP_IDENTIFIER still contains a placeholder")

    provisioning = settings["PROVISIONING_MODE"].strip().lower()
    if provisioning in {"", "unknown", "debug", "development-placeholder"}:
        _fail("release PROVISIONING_MODE must be an explicit non-unknown mode")
    if _contains_placeholder(provisioning):
        _fail("release PROVISIONING_MODE still contains a placeholder")

    allowlist = settings["LIFEOS_SYNC_APPROVED_HOSTS"].strip()
    if _contains_placeholder(allowlist):
        _fail("release sync allowlist still contains a placeholder")
    _hosts(allowlist)

    for key in ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "OTHER_SWIFT_FLAGS"):
        value = settings.get(key, "")
        for token in FIXTURE_TOKENS:
            if token in value:
                _fail(f"release build setting {key} contains fixture flag {token!r}")


def settings_from_environment() -> dict[str, str]:
    """Return release settings without printing any injected values."""

    return {
        key: os.environ.get(environment_key, "")
        for key, environment_key in RELEASE_ENVIRONMENT_KEYS.items()
    }


def _merge_settings(settings_file: Path | None) -> dict[str, str]:
    settings = parse_build_settings(_read(settings_file)) if settings_file else {}
    # CI values intentionally win over generated/showBuildSettings output,
    # because target-level development defaults are allowed to be placeholders.
    for key, value in settings_from_environment().items():
        if value:
            settings[key] = value
    return settings


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=("development", "release"),
        default="development",
        help="check the source fail-closed contract or injected release values",
    )
    parser.add_argument(
        "--settings-file",
        type=Path,
        help="optional xcodebuild -showBuildSettings/xcconfig output for release mode",
    )
    parser.add_argument("--root", type=Path, default=ROOT)
    return parser.parse_args()


def main(argv: Iterable[str] | None = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    # Keep a small wrapper so tests can call ``main`` without mutating global
    # process arguments while the normal CLI remains self-documenting.
    del parser
    args = _arguments() if argv is None else _arguments_from(argv)
    root = args.root.resolve()
    if args.mode == "development":
        validate_source(root)
        print("native development release/source invariants: PASS")
        return 0

    validate_release(_merge_settings(args.settings_file), root=root)
    print("native release/source invariants: PASS")
    return 0


def _arguments_from(argv: Iterable[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("development", "release"), default="development")
    parser.add_argument("--settings-file", type=Path)
    parser.add_argument("--root", type=Path, default=ROOT)
    return parser.parse_args(list(argv))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except InvariantError as error:
        print(f"native release/source invariants: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
