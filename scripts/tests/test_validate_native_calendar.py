from __future__ import annotations

import unittest
from pathlib import Path

from scripts.validate_native_calendar import named_yaml_block, target_sources, top_level_section


ROOT = Path(__file__).resolve().parents[2]


class NativeCalendarSourceParserTests(unittest.TestCase):
    def test_scalar_source_entries_are_preserved(self) -> None:
        block = """
    sources:
      - LifeOS
      - Shared/FitnessMetric.swift
    resources:
      - path: Shared/Resources/Fonts
        excludes: [ignored]
"""
        self.assertEqual(target_sources(block), ["LifeOS", "Shared/FitnessMetric.swift"])

    def test_path_mapping_keeps_path_and_ignores_excludes_metadata(self) -> None:
        block = """
    sources:
      - LifeOSWidget
      - path: Shared
        excludes: [HealthKit*.swift]
      - Shared/FitnessMetric.swift
    resources:
      - path: Shared/Resources/Fonts
"""
        self.assertEqual(
            target_sources(block),
            ["LifeOSWidget", "Shared", "Shared/FitnessMetric.swift"],
        )

    def test_inline_scalar_sequence_is_normalized(self) -> None:
        block = '    sources: [LifeOS, Shared, "Shared/FitnessMetric.swift"]\n    resources: [Fonts]\n'
        self.assertEqual(target_sources(block), ["LifeOS", "Shared", "Shared/FitnessMetric.swift"])

    def test_malformed_source_entries_fail_closed(self) -> None:
        malformed_blocks = (
            "    sources:\n      - path:\n        excludes: [HealthKit*.swift]\n",
            "    sources:\n      - excludes: [HealthKit*.swift]\n",
            "    sources:\n      - resources: [Fonts]\n",
            "    sources:\n      - path: Shared\n        resources: [Fonts]\n",
            "    sources: {}\n",
        )
        for block in malformed_blocks:
            with self.subTest(block=block):
                with self.assertRaises(AssertionError):
                    target_sources(block)

    def test_checked_in_project_sources_pass_through_normalization(self) -> None:
        project = (ROOT / "ios/project.yml").read_text(encoding="utf-8")
        targets = top_level_section(project, "targets")
        expected = {
            "LifeOS": ["LifeOS", "Shared", "Shared/FitnessMetric.swift"],
            "LifeOSWidget": ["LifeOSWidget", "Shared", "Shared/FitnessMetric.swift"],
            "LifeOSMac": [
                "LifeOSMac",
                "Shared",
                "Shared/FitnessMetric.swift",
                "LifeOS/OverviewView.swift",
                "LifeOS/CodexView.swift",
                "LifeOS/Usage",
                "LifeOS/Settings.swift",
                "LifeOS/CalendarView.swift",
                "LifeOS/Modules",
                "LifeOS/TaxDocumentsView.swift",
                "LifeOS/WidgetSnapshotPublisher.swift",
            ],
            "LifeOSMacWidget": [
                "LifeOSMacWidget",
                "Shared",
                "Shared/FitnessMetric.swift",
                "LifeOSWidget/UsageWidget.swift",
                "LifeOSWidget/CalendarWidget.swift",
                "LifeOSWidget/NextEventWidget.swift",
                "LifeOSWidget/FutureModuleWidgets.swift",
            ],
        }
        for target_name, expected_sources in expected.items():
            with self.subTest(target=target_name):
                self.assertEqual(target_sources(named_yaml_block(targets, target_name)), expected_sources)


if __name__ == "__main__":
    unittest.main()
