import XCTest
@testable import LifeOS

final class HelioDeviceDomainTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func provenance(
        origin: HelioDeviceObservationOrigin = .appleHealthExport,
        age: TimeInterval = 60,
        freshness: HelioDeviceFreshness = .fresh
    ) throws -> HelioDeviceObservationProvenance {
        let timestamp = now.addingTimeInterval(-age)
        return try XCTUnwrap(
            HelioDeviceObservationProvenance(
                origin: origin,
                sourcePath: origin.sourcePath,
                source: origin == .appleHealthExport ? "Apple Health / HealthKit" : "Bluetooth HR broadcast",
                device: "Helio Strap",
                observedAt: timestamp,
                freshness: freshness,
                now: now
            )
        )
    }

    private func decoder(now: Date) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.userInfo[.lifeOSNow] = now
        return decoder
    }

    func testObservedRequiresSourceDeviceTimestampAndFreshness() throws {
        let observedEvidence = try provenance()
        let observed = HelioDeviceConnection.observed(observedEvidence)

        XCTAssertEqual(observed.state, .observed)
        XCTAssertEqual(observed.provenance?.source, "Apple Health / HealthKit")
        XCTAssertEqual(observed.provenance?.device, "Helio Strap")
        XCTAssertEqual(observed.provenance?.observedAt, now.addingTimeInterval(-60))
        XCTAssertEqual(observed.provenance?.freshness, .fresh)

        let missingEvidence = HelioDeviceConnection(state: .observed)
        XCTAssertEqual(missingEvidence.state, .unavailable)
        XCTAssertTrue(missingEvidence.detail.localizedCaseInsensitiveContains("provenance"))

        let staleEvidence = try provenance(age: 3_600, freshness: .stale)
        let mismatched = HelioDeviceConnection(state: .observed, provenance: staleEvidence)
        XCTAssertEqual(mismatched.state, .unavailable)
    }

    func testStaleRequiresStaleProvenanceAndPreservesItsEvidence() throws {
        let staleEvidence = try provenance(age: 3_600, freshness: .stale)
        let stale = HelioDeviceConnection.stale(staleEvidence)

        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.provenance?.freshness, .stale)
        XCTAssertTrue(stale.detail.localizedCaseInsensitiveContains("stale"))

        let freshAsStale = HelioDeviceConnection(state: .stale, provenance: try provenance())
        XCTAssertEqual(freshAsStale.state, .unavailable)
    }

    func testPartialAndConflictRemainDistinctAndNeverCarryAValue() {
        let partial = HelioDeviceConnection.partial("Sleep interval arrived without stages.")
        let conflict = HelioDeviceConnection.conflict("Apple Health and Bluetooth samples disagree.")

        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.reason, "Sleep interval arrived without stages.")
        XCTAssertNil(partial.provenance)
        XCTAssertEqual(conflict.state, .conflict)
        XCTAssertEqual(conflict.reason, "Apple Health and Bluetooth samples disagree.")
        XCTAssertNil(conflict.provenance)
    }

    func testConnectionStateMatrixHasNoConnectedOrFakeValueState() {
        XCTAssertEqual(
            Set(HelioDeviceConnectionState.allCases),
            Set([
                .notConfigured, .permissionRequired, .availableUnverified,
                .observed, .partial, .stale, .conflict, .unavailable, .externalZepp
            ])
        )
        XCTAssertNotEqual(HelioDeviceConnection.notConfigured.state, .observed)
        XCTAssertNotEqual(HelioDeviceConnection.availableUnverified.state, .observed)
    }

    func testUnverifiedCapabilityCannotBecomeMetricObservation() throws {
        let capability = try XCTUnwrap(HelioDeviceCapability.inventory.first { $0.id == .heartRate })
        let evidence = try provenance()

        XCTAssertNil(
            HelioDeviceMetricObservation(
                capability: capability,
                value: 60,
                unit: "bpm",
                provenance: evidence
            )
        )
    }

    func testFixtureHasNoLiveObservationOriginAndCannotBecomeObserved() {
        let fixture = HelioDeviceFixtureObservation(label: "DEMO · NOT LIVE", observedAt: now)
        XCTAssertEqual(fixture.label, "DEMO · NOT LIVE")

        // The live provenance initializer accepts only the two typed live
        // origins; there is deliberately no fixture origin to pass here.
        XCTAssertEqual(HelioDeviceObservationOrigin.allCases.count, 2)
        XCTAssertFalse(HelioDeviceObservationOrigin.allCases.contains { $0.rawValue.localizedCaseInsensitiveContains("fixture") })
    }

    func testBatteryCannotBeObservedFromStaticProductSpecification() {
        let staticSpec = HelioDeviceBatteryReading(
            levelPercent: 82,
            evidenceSource: .staticProductSpecification,
            source: "Amazfit product page",
            device: "Helio Strap",
            observedAt: now.addingTimeInterval(-60),
            freshness: .fresh,
            now: now
        )
        XCTAssertNil(staticSpec)

        if case .unavailable(let reason) = HelioDeviceBatteryStatus.current {
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("official"))
            XCTAssertTrue(reason.localizedCaseInsensitiveContains("probe"))
        } else {
            XCTFail("Static current battery state must remain unavailable")
        }
    }

    func testBatteryObservedFutureAdapterStillRequiresEvidenceAndFreshness() {
        let reading = HelioDeviceBatteryReading(
            levelPercent: 82,
            evidenceSource: .reviewedPhysicalProbe,
            source: "Reviewed physical BLE probe",
            device: "Helio Strap",
            observedAt: now.addingTimeInterval(-60),
            freshness: .fresh,
            now: now
        )
        XCTAssertNotNil(reading)

        let invalidLevel = HelioDeviceBatteryReading(
            levelPercent: 101,
            evidenceSource: .reviewedPhysicalProbe,
            source: "Reviewed physical BLE probe",
            device: "Helio Strap",
            observedAt: now.addingTimeInterval(-60),
            freshness: .fresh,
            now: now
        )
        XCTAssertNil(invalidLevel)
    }

    func testDefaultSettingsSnapshotDoesNotExposeSyncTimestampFirmwareOrBatteryValue() {
        let snapshot = HelioDeviceSettingsSnapshot.current
        XCTAssertEqual(snapshot.connection.state, .notConfigured)
        XCTAssertEqual(snapshot.permission, .permissionRequired)
        XCTAssertNil(snapshot.lastSuccessfulSync)
        XCTAssertEqual(snapshot.battery.title, "Unavailable")
        XCTAssertEqual(snapshot.firmware.title, "Unavailable")
        XCTAssertEqual(snapshot.management.title, "External Zepp")
        XCTAssertTrue(snapshot.capabilities.contains { $0.id == .battery && $0.status == .unavailable })
    }

    func testProvenanceRoundTripIsStrictAndRejectsUnknownFields() throws {
        let original = try provenance()
        let data = try JSONEncoder().encode(original)
        let decoded = try decoder(now: now).decode(HelioDeviceObservationProvenance.self, from: data)
        XCTAssertEqual(decoded, original)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["unexpected"] = "not part of the source contract"
        let hostile = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try decoder(now: now).decode(HelioDeviceObservationProvenance.self, from: hostile)
        )
    }

    func testConnectionDecoderRejectsInvalidObservedStateInsteadOfNormalizingIt() throws {
        let invalidObserved = Data(#"{"state":"observed"}"#.utf8)
        XCTAssertThrowsError(
            try decoder(now: now).decode(HelioDeviceConnection.self, from: invalidObserved)
        )

        let evidence = try provenance()
        let original = HelioDeviceConnection.observed(evidence)
        let data = try JSONEncoder().encode(original)
        let decoded = try decoder(now: now).decode(HelioDeviceConnection.self, from: data)
        XCTAssertEqual(decoded, original)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["unexpected"] = true
        let hostile = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try decoder(now: now).decode(HelioDeviceConnection.self, from: hostile)
        )
    }

    func testStaleBatteryIsExplicitAboutSourceDeviceTimestampAndFreshness() throws {
        let reading = try XCTUnwrap(
            HelioDeviceBatteryReading(
                levelPercent: 82,
                evidenceSource: .reviewedPhysicalProbe,
                source: "Reviewed physical BLE probe",
                device: "Helio Strap",
                observedAt: now.addingTimeInterval(-3_600),
                freshness: .stale,
                now: now
            )
        )
        let status = HelioDeviceBatteryStatus.observed(reading)

        XCTAssertEqual(status.title, "Stale")
        XCTAssertTrue(status.detail.localizedCaseInsensitiveContains("Reviewed physical BLE probe"))
        XCTAssertTrue(status.detail.localizedCaseInsensitiveContains("Helio Strap"))
        XCTAssertTrue(status.detail.localizedCaseInsensitiveContains("Observed:"))
        XCTAssertTrue(status.detail.localizedCaseInsensitiveContains("Freshness: Stale"))
    }

    func testBatteryDecoderRejectsUnknownFieldsAndStaticSpecificationEvidence() throws {
        let reading = try XCTUnwrap(
            HelioDeviceBatteryReading(
                levelPercent: 82,
                evidenceSource: .reviewedPhysicalProbe,
                source: "Reviewed physical BLE probe",
                device: "Helio Strap",
                observedAt: now.addingTimeInterval(-60),
                freshness: .fresh,
                now: now
            )
        )
        let data = try JSONEncoder().encode(reading)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        object["unexpected"] = true
        let unknownField = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try decoder(now: now).decode(HelioDeviceBatteryReading.self, from: unknownField)
        )

        object = [
            "levelPercent": 82,
            "evidenceSource": "static_product_specification",
            "source": "Amazfit product page",
            "device": "Helio Strap",
            "observedAt": now.timeIntervalSinceReferenceDate,
            "freshness": "fresh"
        ]
        let staticSpecification = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try decoder(now: now).decode(HelioDeviceBatteryReading.self, from: staticSpecification)
        )
    }
}
