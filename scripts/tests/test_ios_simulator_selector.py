from __future__ import annotations

import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

from scripts.ios_simulator_selector import _generic_fallback_name, _valid_device_name, main, select_simulator


UDID_A = "A0000000-0000-4000-8000-000000000001"
UDID_B = "A0000000-0000-4000-8000-000000000002"
UDID_C = "A0000000-0000-4000-8000-000000000003"


def runtime(version: str, *, identifier: str | None = None, name: str | None = None,
            available: object = True) -> dict[str, object]:
    major_minor = version.replace(".", "-")
    return {
        "identifier": identifier or f"com.apple.CoreSimulator.SimRuntime.iOS-{major_minor}",
        "name": name or f"iOS {version}",
        "version": version,
        "isAvailable": available,
    }


def device(name: str, udid: object = UDID_A, *, state: object = "Shutdown",
           available: object = True) -> dict[str, object]:
    return {"name": name, "udid": udid, "state": state, "isAvailable": available}


def payload(*runtime_records: dict[str, object],
            devices: dict[str, list[dict[str, object]]] | None = None) -> dict[str, object]:
    return {"runtimes": list(runtime_records), "devices": devices or {}}


def runtime_id(record: dict[str, object]) -> str:
    return str(record["identifier"])


class IOSSimulatorSelectorTests(unittest.TestCase):
    def test_exact_iphone_17_has_priority_over_newer_generic_model(self) -> None:
        older = runtime("26.5")
        newer = runtime("27.0")
        data = payload(
            older,
            newer,
            devices={
                runtime_id(older): [device("iPhone 17", UDID_A, state="Booted")],
                runtime_id(newer): [device("iPhone 16", UDID_B)],
            },
        )
        self.assertEqual(select_simulator(data), (UDID_A, "Booted"))

    def test_exact_model_chooses_highest_numeric_runtime(self) -> None:
        older = runtime("26.10")
        newer = runtime("26.9")
        data = payload(
            older,
            newer,
            devices={
                runtime_id(older): [device("iPhone 17", UDID_A)],
                runtime_id(newer): [device("iPhone 17", UDID_B)],
            },
        )
        self.assertEqual(select_simulator(data), (UDID_A, "Shutdown"))

    def test_patch_runtime_version_orders_after_same_major_minor(self) -> None:
        base = runtime("27.0", identifier="com.apple.CoreSimulator.SimRuntime.iOS-27-0", name="iOS 27.0")
        patch = runtime(
            "27.0.1",
            identifier="com.apple.CoreSimulator.SimRuntime.iOS-27-0-1",
            name="iOS 27.0",
        )
        data = payload(
            base,
            patch,
            devices={
                runtime_id(base): [device("iPhone 17", UDID_A)],
                runtime_id(patch): [device("iPhone 17", UDID_B)],
            },
        )
        self.assertEqual(select_simulator(data), (UDID_B, "Shutdown"))

    def test_equal_runtime_tie_uses_casefolded_udid_order(self) -> None:
        record = runtime("27.0")
        data = payload(
            record,
            devices={runtime_id(record): [
                device("iPhone 17", UDID_B),
                device("iPhone 17", UDID_A, state="Booted"),
            ]},
        )
        self.assertEqual(select_simulator(data), (UDID_A, "Booted"))

    def test_fallback_uses_newest_generic_and_excludes_pro_and_se(self) -> None:
        self.assertFalse(_generic_fallback_name("iPhone 17 Pro"))
        self.assertTrue(_valid_device_name("iPhone SE (3rd generation)"))
        self.assertFalse(_generic_fallback_name("iPhone SE (3rd generation)"))
        older = runtime("26.5")
        newer = runtime("27.0")
        data = payload(
            older,
            newer,
            devices={
                runtime_id(older): [device("iPhone 16", UDID_A)],
                runtime_id(newer): [
                    device("iPhone 17 Pro", UDID_B),
                    device("iPhone SE (3rd generation)", UDID_C),
                ],
            },
        )
        self.assertEqual(select_simulator(data), (UDID_A, "Shutdown"))

    def test_pro_and_se_only_do_not_produce_generic_fallback(self) -> None:
        record = runtime("27.0")
        data = payload(
            record,
            devices={runtime_id(record): [
                device("iPhone 17 Pro", UDID_A),
                device("iPhone SE (3rd generation)", UDID_B),
            ]},
        )
        self.assertIsNone(select_simulator(data))

    def test_fallback_tie_is_deterministic(self) -> None:
        record = runtime("27.0")
        data = payload(
            record,
            devices={runtime_id(record): [
                device("iPhone 16", UDID_C),
                device("iPhone 15", UDID_A),
            ]},
        )
        self.assertEqual(select_simulator(data), (UDID_A, "Shutdown"))

    def test_only_booted_and_shutdown_states_are_emitted(self) -> None:
        record = runtime("27.0")
        for invalid_state in (None, [], {}, "", "  ", "Creating", "garbage", "Booted|other", "Booted\n"):
            with self.subTest(state=invalid_state):
                data = payload(
                    record,
                    devices={runtime_id(record): [
                        device("iPhone 17", UDID_A, state=invalid_state),
                        device("iPhone 17", UDID_B, state="Shutdown"),
                    ]},
                )
                self.assertEqual(select_simulator(data), (UDID_B, "Shutdown"))

    def test_empty_and_whitespace_udids_are_rejected(self) -> None:
        record = runtime("27.0")
        data = payload(
            record,
            devices={runtime_id(record): [
                device("iPhone 17", ""),
                device("iPhone 17", "   "),
                device("iPhone 17", UDID_A),
            ]},
        )
        self.assertEqual(select_simulator(data), (UDID_A, "Shutdown"))

    def test_malformed_uuid_is_rejected(self) -> None:
        record = runtime("27.0")
        data = payload(record, devices={runtime_id(record): [device("iPhone 17", "not-a-uuid")]})
        self.assertIsNone(select_simulator(data))

    def test_string_false_availability_is_not_truthy(self) -> None:
        record = runtime("27.0")
        data = payload(
            record,
            devices={runtime_id(record): [
                device("iPhone 17", UDID_A, available="false"),
                device("iPhone 17", UDID_B),
            ]},
        )
        self.assertEqual(select_simulator(data), (UDID_B, "Shutdown"))

    def test_runtime_availability_must_be_boolean_true(self) -> None:
        record = runtime("27.0", available="true")
        data = payload(record, devices={runtime_id(record): [device("iPhone 17")]})
        self.assertIsNone(select_simulator(data))

    def test_partial_runtime_identifier_does_not_match(self) -> None:
        malformed = runtime("99.0", identifier="com.apple.CoreSimulator.SimRuntime.iOS-99-garbage")
        valid = runtime("27.0")
        data = payload(
            malformed,
            valid,
            devices={
                runtime_id(malformed): [device("iPhone 17", UDID_A)],
                runtime_id(valid): [device("iPhone 17", UDID_B)],
            },
        )
        self.assertEqual(select_simulator(data), (UDID_B, "Shutdown"))

    def test_runtime_name_and_version_are_fully_anchored_and_consistent(self) -> None:
        malformed_name = runtime("99.0", name="iOS 99.0 Beta")
        malformed_version = runtime("99.0", name="iOS 99.0", identifier="com.apple.CoreSimulator.SimRuntime.iOS-99-0-extra")
        valid = runtime("27.0")
        data = payload(
            malformed_name,
            malformed_version,
            valid,
            devices={
                runtime_id(malformed_name): [device("iPhone 17", UDID_A)],
                runtime_id(malformed_version): [device("iPhone 17", UDID_C)],
                runtime_id(valid): [device("iPhone 17", UDID_B)],
            },
        )
        self.assertEqual(select_simulator(data), (UDID_B, "Shutdown"))

    def test_invalid_device_availability_and_blank_state_are_rejected(self) -> None:
        record = runtime("27.0")
        data = payload(
            record,
            devices={runtime_id(record): [
                device("iPhone 17", UDID_A, available=1),
                device("iPhone 17", UDID_B, state="  "),
            ]},
        )
        self.assertIsNone(select_simulator(data))

    def test_no_candidate_returns_empty_selection(self) -> None:
        self.assertIsNone(select_simulator(payload(runtime("27.0"))))

    def test_cli_preserves_udid_pipe_state_and_empty_output(self) -> None:
        record = runtime("27.0")
        data = payload(record, devices={runtime_id(record): [device("iPhone 17", UDID_A, state="Booted")]})
        with patch("sys.stdin", io.StringIO(json.dumps(data))), patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(main(), 0)
        self.assertEqual(output.getvalue(), f"{UDID_A}|Booted\n")

        with patch("sys.stdin", io.StringIO(json.dumps(payload(runtime("27.0"))))), patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(main(), 0)
        self.assertEqual(output.getvalue(), "")

    def test_full_simctl_inventory_shape_works_with_wrapper_command(self) -> None:
        record = runtime("27.0.1", identifier="com.apple.CoreSimulator.SimRuntime.iOS-27-0-1")
        data = payload(record, devices={runtime_id(record): [device("iPhone 17", UDID_A)]})
        data["devicetypes"] = [{"name": "iPhone 17"}]
        data["pairs"] = []
        with patch("sys.stdin", io.StringIO(json.dumps(data))), patch("sys.stdout", new_callable=io.StringIO) as output:
            self.assertEqual(main(), 0)
        self.assertEqual(output.getvalue(), f"{UDID_A}|Shutdown\n")

        wrapper = Path(__file__).parents[1].joinpath("validate_apple_on_mac.sh").read_text()
        self.assertIn("xcrun simctl list -j | python3 -B", wrapper)
        self.assertNotIn("simctl list devices available -j", wrapper)

    def test_malformed_json_cli_returns_error_without_output(self) -> None:
        with (
            patch("sys.stdin", io.StringIO("{malformed")),
            patch("sys.stdout", new_callable=io.StringIO) as output,
            patch("sys.stderr", new_callable=io.StringIO) as error,
        ):
            self.assertEqual(main(), 2)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("Invalid simctl JSON:", error.getvalue())

    def test_malformed_records_do_not_raise(self) -> None:
        record = runtime("27.0")
        data = payload(record, devices={runtime_id(record): [None, "device", {}]})
        self.assertIsNone(select_simulator(data))


if __name__ == "__main__":
    unittest.main()
