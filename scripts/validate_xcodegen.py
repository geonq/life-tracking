#!/usr/bin/env python3
"""Check that XcodeGen output is fresh, deterministic, and spec-authoritative.

LifeOS intentionally does not commit ``ios/LifeOS.xcodeproj``.  CI therefore
removes any stale generated project, generates from ``ios/project.yml``, and
uses this script to verify the generated target/scheme surface plus a second
fresh generation.  Comparing those two outputs catches drift without adding a
machine-local Xcode project to the public source tree.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Iterable


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_XCODEGEN_VERSION = "2.46.0"
DEFAULT_SCHEMES = (
    "LifeOSLogic",
    "LifeOSUI",
    "LifeOSMacLogic",
    "LifeOSMacUI",
    "LifeOSWidgets",
    "LifeOSPrereleaseIOS",
    "LifeOSPrereleaseMac",
)


class XcodeGenInvariantError(ValueError):
    """Raised when XcodeGen or its generated project violates the contract."""


def _fail(message: str) -> None:
    raise XcodeGenInvariantError(message)


def _run(command: list[str], *, cwd: Path = ROOT) -> str:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        output = getattr(error, "stdout", "") or ""
        _fail(f"command failed ({' '.join(command)}): {output.strip()}")
    return completed.stdout


def normalize_version(output: str) -> str:
    match = re.search(r"(?:Version:\s*)?(\d+\.\d+\.\d+)", output)
    if not match:
        _fail(f"could not parse XcodeGen version from: {output.strip()!r}")
    return match.group(1)


def validate_version(actual_output: str, expected: str = DEFAULT_XCODEGEN_VERSION) -> None:
    actual = normalize_version(actual_output)
    if actual != expected:
        _fail(f"XcodeGen version drift: expected {expected}, found {actual}")


def resolved_spec_targets(spec: Path, *, xcodegen: str = "xcodegen", root: Path = ROOT) -> tuple[str, ...]:
    output = _run([xcodegen, "dump", "--spec", str(spec), "--type", "json"], cwd=root)
    try:
        resolved = json.loads(output)
    except json.JSONDecodeError as error:
        _fail(f"XcodeGen dump was not JSON: {error}")
    targets = resolved.get("targets")
    if not isinstance(targets, dict) or not targets:
        _fail("XcodeGen resolved spec has no targets")
    return tuple(targets)


def native_target_identifiers(project_pbxproj: str) -> dict[str, str]:
    """Extract PBXNativeTarget name/UUID bindings without xcodeproj tooling."""

    identifiers: dict[str, str] = {}
    in_section = False
    pending: tuple[str, str] | None = None
    for line in project_pbxproj.splitlines():
        if "/* Begin PBXNativeTarget section */" in line:
            in_section = True
            continue
        if "/* End PBXNativeTarget section */" in line:
            break
        if not in_section:
            continue
        match = re.match(r"\s*([A-Fa-f0-9]{24}) /\* ([^*]+) \*/ = \{", line)
        if match:
            pending = (match.group(1), match.group(2).strip())
            continue
        if pending and re.match(r"\s*isa = PBXNativeTarget;", line):
            identifier, name = pending
            identifiers[name] = identifier
            pending = None
    return identifiers


def native_target_names(project_pbxproj: str) -> tuple[str, ...]:
    """Extract PBXNativeTarget names without depending on xcodeproj tooling."""

    return tuple(native_target_identifiers(project_pbxproj))


def _validate_test_plan_binding(
    binding: object,
    *,
    plan_path: Path,
    target_identifiers: dict[str, str],
    context: str,
) -> None:
    if not isinstance(binding, dict):
        _fail(f"{plan_path}: {context} must be an object")
    name = binding.get("name")
    identifier = binding.get("identifier")
    container = binding.get("containerPath")
    if not isinstance(name, str) or name not in target_identifiers:
        _fail(f"{plan_path}: {context} references unknown generated target {name!r}")
    if identifier != target_identifiers[name]:
        _fail(
            f"{plan_path}: {context} UUID/name drift for {name}: "
            f"plan={identifier!r}, project={target_identifiers[name]!r}"
        )
    if container != "container:LifeOS.xcodeproj":
        _fail(f"{plan_path}: {context} container must be container:LifeOS.xcodeproj")


def validate_test_plan_bindings(
    payload: object,
    *,
    plan_path: Path,
    target_identifiers: dict[str, str],
) -> None:
    """Verify every test target and variable-expansion host against PBX IDs."""

    if not isinstance(payload, dict):
        _fail(f"{plan_path}: test plan root must be an object")
    entries = payload.get("testTargets")
    if not isinstance(entries, list) or not entries:
        _fail(f"{plan_path}: test plan has no testTargets")
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            _fail(f"{plan_path}: testTargets[{index}] must be an object")
        _validate_test_plan_binding(
            entry.get("target"),
            plan_path=plan_path,
            target_identifiers=target_identifiers,
            context=f"testTargets[{index}]",
        )

    default_options = payload.get("defaultOptions")
    if default_options is None:
        return
    if not isinstance(default_options, dict):
        _fail(f"{plan_path}: defaultOptions must be an object")
    variable_target = default_options.get("targetForVariableExpansion")
    if variable_target is not None:
        _validate_test_plan_binding(
            variable_target,
            plan_path=plan_path,
            target_identifiers=target_identifiers,
            context="defaultOptions.targetForVariableExpansion",
        )


def _canonical_files(project: Path) -> dict[str, bytes]:
    if not project.is_dir():
        _fail(f"generated Xcode project is missing: {project}")
    files: dict[str, bytes] = {}
    for path in sorted(project.rglob("*")):
        if not path.is_file():
            continue
        relative = path.relative_to(project).as_posix()
        # These are machine-local or package-resolution products. They are
        # intentionally ignored and are not part of generated-project drift.
        if relative.startswith("xcuserdata/"):
            continue
        if relative == "project.xcworkspace/xcshareddata/swiftpm/Package.resolved":
            continue
        data = path.read_bytes()
        if relative == "project.pbxproj":
            data = _normalise_pbxproj_paths(data)
        files[relative] = data
    return files


def _normalise_pbxproj_paths(data: bytes) -> bytes:
    """Remove only output-directory noise from PBX source-group paths.

    A project generated beside ``ios/project.yml`` uses paths such as
    ``path = LifeOS;``.  A validation generation in a temporary directory uses
    an equivalent ``name = LifeOS; path = ../../.../ios/LifeOS;`` pair.  The
    source-group basename is the meaningful value; normalising that pair lets
    CI compare the generated project to a clean regeneration without masking
    target/build-setting drift.
    """

    text = data.decode("utf-8")
    text = re.sub(
        r"(?m)^(\s*)path = [^;\n]*/ios/([^/;\"\n]+)\"?;$",
        r"\1path = \2;",
        text,
    )
    text = re.sub(
        r"(?m)^\s*name = ([^;\n]+);\n(?=\s*path = \1;$)",
        "",
        text,
    )
    return text.encode("utf-8")


def _project_name(spec: Path) -> str:
    # The generated directory name is declared by the top-level `name:` key.
    for line in spec.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^name:\s*([^#\s]+)", line)
        if match:
            return match.group(1).strip('"\'')
    _fail(f"XcodeGen spec has no top-level name: {spec}")


def _fresh_generation(
    spec: Path,
    *,
    xcodegen: str,
    root: Path,
    project_name: str,
) -> tuple[dict[str, bytes], dict[str, bytes]]:
    temporary = Path(tempfile.mkdtemp(prefix="lifeos-xcodegen-"))
    # Keep both generations in the same directory: XcodeGen encodes relative
    # source-group paths based on the output directory, so comparing against a
    # project generated at ios/ would report harmless path-layout differences.
    _run(
        [
            xcodegen,
            "generate",
            "--spec",
            str(spec),
            "--project",
            str(temporary),
            "--project-root",
            str(spec.parent),
            "--quiet",
        ],
        cwd=root,
    )
    generated = temporary / f"{project_name}.xcodeproj"
    if not generated.is_dir():
        _fail(f"XcodeGen did not create expected project: {generated}")
    first = _canonical_files(generated)
    _run(
        [
            xcodegen,
            "generate",
            "--spec",
            str(spec),
            "--project",
            str(temporary),
            "--project-root",
            str(spec.parent),
            "--quiet",
        ],
        cwd=root,
    )
    second = _canonical_files(generated)
    return first, second


def validate_generated_project(
    project: Path,
    spec: Path,
    *,
    xcodegen: str = "xcodegen",
    expected_version: str = DEFAULT_XCODEGEN_VERSION,
    required_schemes: Iterable[str] = DEFAULT_SCHEMES,
    root: Path = ROOT,
) -> None:
    """Validate the generated project and compare it with a clean regeneration."""

    if not spec.is_file():
        _fail(f"XcodeGen spec is missing: {spec}")
    _require_project_not_tracked(project, root)

    validate_version(_run([xcodegen, "version"], cwd=root), expected_version)
    target_names = resolved_spec_targets(spec, xcodegen=xcodegen, root=root)
    current_files = _canonical_files(project)
    pbxproj = project / "project.pbxproj"
    if "project.pbxproj" not in current_files:
        _fail(f"generated project has no project.pbxproj: {pbxproj}")
    target_identifiers = native_target_identifiers(current_files["project.pbxproj"].decode("utf-8"))
    generated_targets = tuple(target_identifiers)
    if set(generated_targets) != set(target_names):
        _fail(
            "generated target drift: "
            f"spec={sorted(target_names)}, project={sorted(generated_targets)}"
        )

    schemes_dir = project / "xcshareddata/xcschemes"
    actual_schemes = {path.stem for path in schemes_dir.glob("*.xcscheme")}
    missing_schemes = sorted(set(required_schemes) - actual_schemes)
    if missing_schemes:
        _fail(f"generated project is missing required schemes: {missing_schemes}")

    for scheme in required_schemes:
        plan = root / "ios/TestPlans" / f"{scheme}.xctestplan"
        if not plan.is_file():
            _fail(f"required test plan is missing for {scheme}: {plan}")
        try:
            payload = json.loads(plan.read_text(encoding="utf-8"))
        except json.JSONDecodeError as error:
            _fail(f"test plan is not valid JSON ({plan}): {error}")
        validate_test_plan_bindings(
            payload,
            plan_path=plan,
            target_identifiers=target_identifiers,
        )

    first, second = _fresh_generation(
        spec,
        xcodegen=xcodegen,
        root=root,
        project_name=_project_name(spec),
    )
    if first != second:
        current_only = sorted(set(first) - set(second))
        fresh_only = sorted(set(second) - set(first))
        changed = sorted(
            path for path in set(first).intersection(second) if first[path] != second[path]
        )
        _fail(
            "XcodeGen generated-project output is not deterministic: "
            f"current-only={current_only}, fresh-only={fresh_only}, changed={changed}"
        )
    if current_files != first:
        current_only = sorted(set(current_files) - set(first))
        fresh_only = sorted(set(first) - set(current_files))
        changed = sorted(path for path in set(current_files).intersection(first) if current_files[path] != first[path])
        _fail(
            "generated project drift from a clean XcodeGen regeneration: "
            f"current-only={current_only}, fresh-only={fresh_only}, changed={changed}"
        )


def _require_project_not_tracked(project: Path, root: Path) -> None:
    try:
        relative = project.resolve().relative_to(root.resolve()).as_posix()
    except ValueError:
        # A temporary output directory is the preferred local way to inspect
        # generation without touching the ignored ios/LifeOS.xcodeproj.
        return
    result = subprocess.run(
        ["git", "ls-files", "--error-unmatch", relative],
        cwd=root,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode == 0:
        _fail(f"generated Xcode project is tracked; ios/project.yml must remain authoritative: {relative}")


def _arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, default=ROOT / "ios/LifeOS.xcodeproj")
    parser.add_argument("--spec", type=Path, default=ROOT / "ios/project.yml")
    parser.add_argument("--xcodegen", default="xcodegen")
    parser.add_argument("--expected-version", default=DEFAULT_XCODEGEN_VERSION)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument(
        "--required-scheme",
        action="append",
        dest="required_schemes",
        default=list(DEFAULT_SCHEMES),
        help="repeatable; defaults to all seven T0 lanes",
    )
    return parser.parse_args()


def main() -> int:
    args = _arguments()
    root = args.root.resolve()
    project = args.project if args.project.is_absolute() else root / args.project
    spec = args.spec if args.spec.is_absolute() else root / args.spec
    validate_generated_project(
        project,
        spec,
        xcodegen=args.xcodegen,
        expected_version=args.expected_version,
        required_schemes=args.required_schemes,
        root=root,
    )
    print("XcodeGen version, target surface, schemes, and deterministic generation: PASS")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except XcodeGenInvariantError as error:
        print(f"XcodeGen/generated-project invariants: FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
