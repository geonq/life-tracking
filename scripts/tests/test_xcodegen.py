from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from scripts.validate_xcodegen import (
    XcodeGenInvariantError,
    _canonical_files,
    _normalise_pbxproj_paths,
    native_target_identifiers,
    native_target_names,
    normalize_version,
    validate_test_plan_bindings,
    validate_version,
)


class XcodeGenInvariantTests(unittest.TestCase):
    def test_version_is_exactly_pinned(self) -> None:
        self.assertEqual(normalize_version("Version: 2.46.0"), "2.46.0")
        validate_version("Version: 2.46.0", "2.46.0")
        with self.assertRaisesRegex(XcodeGenInvariantError, "version drift"):
            validate_version("Version: 2.45.4", "2.46.0")

    def test_native_target_parser_only_returns_native_targets(self) -> None:
        pbxproj = """
        /* Begin PBXNativeTarget section */
                AAAAAAAAAAAAAAAAAAAAAAAA /* LifeOS */ = {
                        isa = PBXNativeTarget;
                };
                BBBBBBBBBBBBBBBBBBBBBBBB /* LifeOSTests */ = {
                        isa = PBXNativeTarget;
                };
        /* End PBXNativeTarget section */
        """
        self.assertEqual(native_target_names(pbxproj), ("LifeOS", "LifeOSTests"))
        self.assertEqual(
            native_target_identifiers(pbxproj),
            {
                "LifeOS": "AAAAAAAAAAAAAAAAAAAAAAAA",
                "LifeOSTests": "BBBBBBBBBBBBBBBBBBBBBBBB",
            },
        )

    def test_test_plan_bindings_match_generated_target_ids_and_host(self) -> None:
        targets = {
            "LifeOS": "AAAAAAAAAAAAAAAAAAAAAAAA",
            "LifeOSTests": "BBBBBBBBBBBBBBBBBBBBBBBB",
        }
        plan = {
            "defaultOptions": {
                "targetForVariableExpansion": {
                    "containerPath": "container:LifeOS.xcodeproj",
                    "identifier": targets["LifeOS"],
                    "name": "LifeOS",
                }
            },
            "testTargets": [
                {
                    "target": {
                        "containerPath": "container:LifeOS.xcodeproj",
                        "identifier": targets["LifeOSTests"],
                        "name": "LifeOSTests",
                    }
                }
            ],
        }
        validate_test_plan_bindings(
            plan,
            plan_path=Path("LifeOSLogic.xctestplan"),
            target_identifiers=targets,
        )
        plan["defaultOptions"]["targetForVariableExpansion"]["identifier"] = "CCCCCCCCCCCCCCCCCCCCCCCC"
        with self.assertRaisesRegex(XcodeGenInvariantError, "UUID/name drift"):
            validate_test_plan_bindings(
                plan,
                plan_path=Path("LifeOSLogic.xctestplan"),
                target_identifiers=targets,
            )

    def test_canonical_files_ignores_machine_local_products(self) -> None:
        with tempfile.TemporaryDirectory(prefix="lifeos-xcodegen-test-") as directory:
            project = Path(directory)
            (project / "project.pbxproj").write_text("pbx", encoding="utf-8")
            (project / "xcuserdata/user.xcuserdatad").mkdir(parents=True)
            (project / "xcuserdata/user.xcuserdatad/settings").write_text("local", encoding="utf-8")
            (project / "project.xcworkspace/xcuserdata/user.xcuserdatad").mkdir(parents=True)
            (project / "project.xcworkspace/xcuserdata/user.xcuserdatad/state").write_text("local", encoding="utf-8")
            package = project / "project.xcworkspace/xcshareddata/swiftpm"
            package.mkdir(parents=True)
            (package / "Package.resolved").write_text("local", encoding="utf-8")
            files = _canonical_files(project)
            self.assertEqual(set(files), {"project.pbxproj"})

    def test_normalise_pbxproj_paths_handles_temp_output_quotes(self) -> None:
        temporary = b"""
\t\tname = LifeOS;
\t\tpath = \"/tmp/generated/ios/LifeOS\";
"""
        self.assertEqual(
            _normalise_pbxproj_paths(temporary),
            b"\t\tpath = LifeOS;\n",
        )

if __name__ == "__main__":
    unittest.main()
