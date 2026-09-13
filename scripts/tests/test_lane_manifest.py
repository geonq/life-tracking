from __future__ import annotations

import copy
import unittest

from scripts.lane_manifest import LaneManifestError, load_manifest, validate_manifest


class LaneManifestTests(unittest.TestCase):
    def test_real_manifest_has_seven_consistent_lanes(self) -> None:
        payload = load_manifest()
        self.assertEqual(set(payload["lanes"]), {
            "ios-logic",
            "ios-ui",
            "mac-logic",
            "mac-ui",
            "widgets",
            "prerelease-ios",
            "prerelease-mac",
        })
        self.assertEqual(payload["preferred_ios_simulator"], "iPhone 17")

    def test_timeout_and_configuration_are_not_lane_local_drift(self) -> None:
        payload = copy.deepcopy(load_manifest())
        payload["lanes"]["ios-logic"]["timeout_minutes"] = 34
        with self.assertRaisesRegex(LaneManifestError, "timeout_minutes"):
            validate_manifest(payload)

        payload = copy.deepcopy(load_manifest())
        payload["lanes"]["prerelease-ios"]["configuration"] = "Debug"
        with self.assertRaisesRegex(LaneManifestError, "Release"):
            validate_manifest(payload)

    def test_ios_destination_and_artifacts_are_bounded(self) -> None:
        payload = copy.deepcopy(load_manifest())
        payload["lanes"]["ios-ui"]["destination"] = "platform=macOS"
        with self.assertRaisesRegex(LaneManifestError, "iOS destination"):
            validate_manifest(payload)

        payload = copy.deepcopy(load_manifest())
        payload["lanes"]["mac-ui"]["result_path"] = "../outside.xcresult"
        with self.assertRaisesRegex(LaneManifestError, "relative filename"):
            validate_manifest(payload)


if __name__ == "__main__":
    unittest.main()
