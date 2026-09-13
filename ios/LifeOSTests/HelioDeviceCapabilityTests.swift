import XCTest
@testable import LifeOS

final class HelioDeviceCapabilityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testInventoryHasExactReviewedCapabilityClassification() {
        let inventory = HelioDeviceCapability.inventory
        XCTAssertEqual(inventory.count, 23)

        XCTAssertEqual(
            Set(inventory.filter { $0.sourcePath == .appleHealthExportCandidate }.map(\.id)),
            Set([
                .heartRate, .restingHeartRate, .heartRateVariability, .bloodOxygen,
                .sleep, .sleepStages, .naps, .vo2Max, .workouts, .activeEnergy
            ])
        )
        XCTAssertEqual(
            Set(inventory.filter { $0.sourcePath == .publicBluetoothHeartRateBroadcast }.map(\.id)),
            Set([.heartRateBroadcast])
        )
        XCTAssertEqual(
            Set(inventory.filter { $0.sourcePath == .zeppDerivedNoPublicIOSInterface }.map(\.id)),
            Set([.stress, .bioCharge, .trainingLoad, .trainingEffect, .recovery, .pai, .sleepScore])
        )
        XCTAssertEqual(
            Set(inventory.filter { $0.sourcePath == .zeppOnlyExternalControls }.map(\.id)),
            Set([.pairing, .firmware, .reboot, .configuration])
        )
        XCTAssertEqual(
            Set(inventory.filter { $0.sourcePath == .officialBatteryInterfacePending }.map(\.id)),
            Set([.battery])
        )
    }

    func testInventoryStatusesMatchTheOfficialSourceBoundary() throws {
        let inventory = HelioDeviceCapability.inventory

        XCTAssertTrue(inventory.filter { $0.sourcePath == .appleHealthExportCandidate || $0.sourcePath == .publicBluetoothHeartRateBroadcast }
            .allSatisfy { $0.status == .unverified })
        XCTAssertTrue(inventory.filter { $0.sourcePath == .zeppDerivedNoPublicIOSInterface }
            .allSatisfy { $0.status == .unavailable })
        XCTAssertTrue(inventory.filter { $0.sourcePath == .zeppOnlyExternalControls }
            .allSatisfy { $0.status == .externalZepp })

        let battery = try XCTUnwrap(inventory.first { $0.id == .battery })
        XCTAssertEqual(battery.status, .unavailable)
        XCTAssertFalse(battery.canCarryObservedValue)
        XCTAssertTrue(battery.detail.localizedCaseInsensitiveContains("official"))
        XCTAssertTrue(battery.detail.localizedCaseInsensitiveContains("probe"))
    }

    func testCurrentInventoryCannotCarryMetricValues() {
        XCTAssertTrue(HelioDeviceCapability.inventory.allSatisfy { !$0.canCarryObservedValue })
        XCTAssertTrue(HelioDeviceCapability.inventory(in: .appleHealthExport).allSatisfy { $0.status == .unverified })
        XCTAssertTrue(HelioDeviceCapability.inventory(in: .bluetooth).allSatisfy { $0.status == .unverified })
    }

    func testZeppDerivedAndManagementPathsNeverClaimAReceiverOrLifeOSControl() {
        let derived = HelioDeviceCapability.inventory(in: .zeppDerived)
        XCTAssertTrue(derived.allSatisfy { !$0.sourcePath.supportsObservedMetric && $0.status == .unavailable })

        let controls = HelioDeviceCapability.inventory(in: .externalManagement)
        XCTAssertTrue(controls.allSatisfy { !$0.sourcePath.supportsObservedMetric && $0.status == .externalZepp })
    }

    func testCapabilityRoundTripUsesTheCanonicalRegistry() throws {
        let original = try XCTUnwrap(HelioDeviceCapability.inventory.first { $0.id == .heartRate })
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HelioDeviceCapability.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertFalse(decoded.canCarryObservedValue)
    }

    func testCapabilityDecoderRejectsUnknownFieldsAndForgedObservedBattery() throws {
        let canonical = try XCTUnwrap(HelioDeviceCapability.inventory.first { $0.id == .battery })
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(canonical)) as? [String: Any]
        )
        object["unexpected"] = true
        let unknownField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(HelioDeviceCapability.self, from: unknownField))

        object = [
            "id": "battery",
            "group": "device_status",
            "title": "Battery",
            "sourcePath": "official_battery_interface_pending",
            "status": "observed",
            "detail": "Observed from an unreviewed payload"
        ]
        let forgedStatus = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(HelioDeviceCapability.self, from: forgedStatus))
    }

    func testInternalForgedObservedCapabilityCannotCreateMetricObservation() throws {
        let forged = HelioDeviceCapability(
            id: .heartRate,
            group: .appleHealthExport,
            title: "Heart rate",
            sourcePath: .appleHealthExportCandidate,
            status: .observed,
            detail: "Forged observed row"
        )
        let provenance = try XCTUnwrap(
            HelioDeviceObservationProvenance(
                origin: .appleHealthExport,
                sourcePath: .appleHealthExportCandidate,
                source: "Apple Health / HealthKit",
                device: "Helio Strap",
                observedAt: now.addingTimeInterval(-60),
                freshness: .fresh,
                now: now
            )
        )

        XCTAssertFalse(forged.canCarryObservedValue)
        XCTAssertNil(
            HelioDeviceMetricObservation(
                capability: forged,
                value: 60,
                unit: "bpm",
                provenance: provenance
            )
        )
    }
}
