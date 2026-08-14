import XCTest
@testable import LifeOS

#if os(iOS) && canImport(HealthKit)
import HealthKit
#endif

final class HealthKitDomainTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func provenance(
        bundle: String = "com.example.health",
        manufacturer: String? = nil,
        model: String? = nil,
        registry: HealthKitHelioEvidenceRegistry = .init(rules: [])
    ) throws -> HealthKitProvenance {
        let source = try HealthKitSourceMetadata(bundleIdentifier: bundle, name: "Health source", version: "4")
        let device = try HealthKitDeviceMetadata(manufacturer: manufacturer, model: model)
        return try HealthKitProvenance.from(source: source, device: device, registry: registry)
    }

    private func quantityObservation(
        metric: HealthKitMetricID = .water,
        value: Double = 250,
        identity: HealthKitSampleIdentity = .init(uuid: UUID()),
        at: Date? = nil,
        provenance: HealthKitProvenance? = nil
    ) throws -> HealthKitObservation {
        let date = at ?? now.addingTimeInterval(-60)
        let quantity = try HealthKitQuantityValue(metric: metric, value: value, unit: try XCTUnwrap(metric.canonicalUnit))
        return try HealthKitObservation(
            metric: metric,
            identity: identity,
            value: .quantity(quantity),
            startDate: date,
            endDate: date,
            provenance: try provenance ?? self.provenance(),
            now: now
        )
    }

    func testAuthorizationReportPreservesReadAmbiguity() {
        let report = HealthKitAuthorizationReport(state: .readIndeterminate, promptCompleted: true)
        XCTAssertEqual(report.state, .readIndeterminate)
        XCTAssertEqual(report.promptCompleted, true)
        XCTAssertNotEqual(report.state, .writeAuthorized)
        XCTAssertNotEqual(report.state, .writeDenied)
    }

    func testHealthKitErrorMappingPreservesUnavailableRestrictedAndReadAmbiguity() {
#if os(iOS) && canImport(HealthKit)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorHealthDataUnavailable.rawValue, description: "unavailable"), .unavailable)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorHealthDataRestricted.rawValue, description: "restricted"), .restricted)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationDenied.rawValue, description: "denied"), .readAccessIndeterminate)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorAuthorizationNotDetermined.rawValue, description: "not determined"), .readAccessIndeterminate)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorRequiredAuthorizationDenied.rawValue, description: "required denial"), .readAccessIndeterminate)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorNoData.rawValue, description: "no data"), .readAccessIndeterminate)
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: HKErrorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue, description: "locked"), .protectedDataUnavailable)
#else
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: "HKErrorDomain", code: Int.max, description: "unavailable"), .queryFailed("unavailable"))
#endif
        XCTAssertEqual(HealthKitAdapterError.mappedHealthKitError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EACCES.rawValue), description: "permission denied"), .protectedDataUnavailable)
    }

    func testCanonicalUnitsRejectWrongUnitNonFiniteAndNegativeValues() throws {
        XCTAssertNoThrow(try HealthKitQuantityValue(metric: .water, value: 500, unit: .milliliters))
        XCTAssertThrowsError(try HealthKitQuantityValue(metric: .water, value: 500, unit: .milligrams))
        XCTAssertThrowsError(try HealthKitQuantityValue(metric: .caffeine, value: -0.1, unit: .milligrams))
        XCTAssertThrowsError(try HealthKitQuantityValue(metric: .caffeine, value: .infinity, unit: .milligrams))
        XCTAssertThrowsError(try HealthKitQuantityValue(metric: .caffeine, value: .nan, unit: .milligrams))
    }

    func testAlcoholIsStandardDrinksAndDoesNotExposeBloodAlcoholContent() {
        XCTAssertEqual(HealthKitMetricID.alcoholicBeverages.canonicalUnit, .standardDrinks)
        XCTAssertFalse(LifeOSHealthKitAdapter.isSupportedMetric(.alcoholicBeverages), "HealthKit beverage counts must not be relabeled as standard drinks")
        XCTAssertFalse(HealthKitMetricID.allCases.contains { $0.rawValue.localizedCaseInsensitiveContains("blood") })
        XCTAssertFalse(HealthKitMetricID.allCases.contains { $0.rawValue.localizedCaseInsensitiveContains("bac") })
    }

    func testBackgroundDeliveryCadenceIsBoundedAndExcludesUnsupportedAlcohol() {
        XCTAssertNil(LifeOSHealthKitAdapter.backgroundDeliveryCadence(for: .alcoholicBeverages))
        XCTAssertEqual(LifeOSHealthKitAdapter.backgroundDeliveryCadence(for: .steps), .hourly)
        XCTAssertEqual(LifeOSHealthKitAdapter.backgroundDeliveryCadence(for: .heartRate), .hourly)
        XCTAssertEqual(LifeOSHealthKitAdapter.backgroundDeliveryCadence(for: .sleep), .immediate)
        XCTAssertEqual(LifeOSHealthKitAdapter.backgroundDeliveryCadence(for: .workout), .immediate)
        let supported = HealthKitMetricID.allCases.filter { $0 != .alcoholicBeverages }
        XCTAssertTrue(
            supported.allSatisfy {
                LifeOSHealthKitAdapter.backgroundDeliveryCadence(for: $0) != nil
            }
        )
    }

    func testSyncVersionIsUsedAndUUIDFallbackIsStable() throws {
        let sync = try HealthKitSampleRevision(syncVersion: 7)
        XCTAssertEqual(sync, .syncVersion(7))
        XCTAssertTrue(try HealthKitSampleRevision(syncVersion: 8).isNewer(than: sync))
        let absentSyncVersion: Int64? = nil
        XCTAssertEqual(try HealthKitSampleRevision(syncVersion: absentSyncVersion), .uuidFallback)
        let uuid = UUID()
        let first = HealthKitSampleIdentity(uuid: uuid, revision: .uuidFallback)
        let second = HealthKitSampleIdentity(uuid: uuid, revision: .uuidFallback)
        XCTAssertEqual(first, second)
        let malformedText = Data(#"{"kind":"sync_version","value":"07"}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(HealthKitSampleRevision.self, from: malformedText))
        XCTAssertThrowsError(try HealthKitSampleRevision(syncVersion: -1))
    }

    func testSyncIdentifierIsStableAcrossNewUUIDAndCarriesAliases() throws {
        let oldUUID = UUID()
        let newUUID = UUID()
        let old = HealthKitSampleIdentity(uuid: oldUUID, syncIdentifier: "stable", revision: try .init(syncVersion: 1))
        let newer = HealthKitSampleIdentity(uuid: newUUID, syncIdentifier: "stable", revision: try .init(syncVersion: 2))
        XCTAssertTrue(old.matchesStableIdentity(newer))
        let merged = newer.withMergedAliases(from: old)
        XCTAssertTrue(merged.aliasUUIDs.contains(oldUUID))
        XCTAssertTrue(merged.aliasUUIDs.contains(newUUID))
        XCTAssertTrue(merged.revision.isNewer(than: old.revision))
    }

    func testUUIDAliasStillMatchesWhenSyncIdentifiersDiffer() {
        let uuid = UUID()
        let first = HealthKitSampleIdentity(uuid: uuid, syncIdentifier: "provider-a", revision: .syncVersion(1))
        let revisedMetadata = HealthKitSampleIdentity(uuid: uuid, syncIdentifier: "provider-b", revision: .syncVersion(1))
        XCTAssertTrue(first.matchesStableIdentity(revisedMetadata))
    }

#if os(iOS) && canImport(HealthKit)
    func testDeletedMetadataRetainsStableIdentityAndNumericRevision() throws {
        let uuid = UUID()
        let adapter = LifeOSHealthKitAdapter()
        let identity = try adapter.sampleIdentity(
            uuid: uuid,
            metadata: [
                HKMetadataKeySyncIdentifier: "stable-deletion",
                HKMetadataKeySyncVersion: NSNumber(value: 12)
            ]
        )
        XCTAssertEqual(identity.uuid, uuid)
        XCTAssertEqual(identity.syncIdentifier, "stable-deletion")
        XCTAssertEqual(identity.revision, .syncVersion(12))
        XCTAssertThrowsError(try adapter.sampleIdentity(uuid: uuid, metadata: [HKMetadataKeySyncIdentifier: "missing-version"]))
    }
#endif

    func testSourceMetadataRetainsSafeDeviceFieldsAndNeverPersistsUDI() throws {
        let source = try HealthKitSourceMetadata(
            bundleIdentifier: "com.zepp.health",
            name: "Zepp",
            version: "9.1.2",
            productType: "iPhone17,1",
            operatingSystemVersion: "26.5.0"
        )
        let device = try HealthKitDeviceMetadata(
            name: "Helio",
            manufacturer: "Amazfit",
            model: "Amazfit Helio Strap",
            hardwareVersion: "1",
            firmwareVersion: "2",
            softwareVersion: "3",
            localIdentifier: "local-id"
        )
        XCTAssertEqual(source.productType, "iPhone17,1")
        XCTAssertEqual(source.operatingSystemVersion, "26.5.0")
        XCTAssertEqual(device.model, "Amazfit Helio Strap")
        XCTAssertEqual(device.firmwareVersion, "2")
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any]
        XCTAssertNil(encoded?["udiDeviceIdentifier"])

        // Legacy files may contain the old field, but migration must drop it
        // and never reproduce it on the next durable write.
        var legacy = try XCTUnwrap(encoded)
        legacy["udiDeviceIdentifier"] = "sensitive-udi"
        let migrated = try JSONDecoder().decode(
            HealthKitDeviceMetadata.self,
            from: JSONSerialization.data(withJSONObject: legacy)
        )
        let reencoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(migrated)) as? [String: Any]
        XCTAssertNil(reencoded?["udiDeviceIdentifier"])
    }

    func testHelioMatchingUsesExactReviewedEvidenceAndNeverSubstring() throws {
        let registry = HealthKitHelioEvidenceRegistry(rules: [
            try HealthKitHelioEvidenceRule(bundleIdentifier: "com.zepp.health", manufacturer: "Amazfit", model: "Helio Strap")
        ])
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.zepp.health", name: "Zepp")
        XCTAssertEqual(registry.match(source: source, device: nil), .candidate)
        XCTAssertEqual(registry.match(source: source, device: try HealthKitDeviceMetadata(manufacturer: "Amazfit", model: "Helio Strap")), .confirmed)
        XCTAssertEqual(registry.match(source: source, device: try HealthKitDeviceMetadata(manufacturer: "Amazfit", model: "Helio Strap Pro")), .other)
        XCTAssertEqual(registry.match(source: try HealthKitSourceMetadata(bundleIdentifier: "com.zepp.health.extra", name: "Zepp"), device: nil), .other)
        XCTAssertEqual(registry.match(source: nil, device: nil), .unattributed)
    }

    func testPersistedHelioMatchMustMatchCanonicalRegistry() throws {
        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.zepp.health", name: "Zepp")
        let device = try HealthKitDeviceMetadata(manufacturer: "Amazfit", model: "Helio Strap")
        let provenance = try HealthKitProvenance.from(source: source, device: device, registry: .canonical)
        let data = try JSONEncoder().encode(provenance)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["helioMatch"] = "other"
        XCTAssertThrowsError(try JSONDecoder().decode(HealthKitProvenance.self, from: JSONSerialization.data(withJSONObject: object)))
        XCTAssertNoThrow(try JSONDecoder().decode(HealthKitProvenance.self, from: data))
    }

    func testSleepAndWorkoutValidationRemainSeparate() throws {
        let sleep = try HealthKitSleepValue(stage: .awake)
        let workout = try HealthKitWorkoutValue(activityTypeRawValue: 1, durationSeconds: 30)
        let provenance = try provenance()
        XCTAssertNoThrow(try HealthKitObservation(metric: .sleep, identity: .init(uuid: UUID()), value: .sleep(sleep), startDate: now, endDate: now, provenance: provenance, now: now))
        let workoutEnd = now.addingTimeInterval(30)
        XCTAssertNoThrow(try HealthKitObservation(metric: .workout, identity: .init(uuid: UUID()), value: .workout(workout), startDate: now, endDate: workoutEnd, provenance: provenance, now: workoutEnd))
        XCTAssertThrowsError(try HealthKitObservation(metric: .sleep, identity: .init(uuid: UUID()), value: .workout(workout), startDate: now, endDate: now, provenance: provenance, now: now))
        XCTAssertThrowsError(try HealthKitWorkoutValue(activityTypeRawValue: 1, durationSeconds: 0))
    }

    func testEnergyOverlapUsesActiveEnergyAsTheOnlyAuthority() throws {
        let provenance = try provenance()
        let active = try HealthKitObservation(
            metric: .activeEnergy,
            identity: .init(uuid: UUID()),
            value: .quantity(try HealthKitQuantityValue(metric: .activeEnergy, value: 100, unit: .kilocalories)),
            startDate: now,
            endDate: now.addingTimeInterval(60),
            provenance: provenance,
            now: now.addingTimeInterval(60)
        )
        let workout = try HealthKitObservation(
            metric: .workout,
            identity: .init(uuid: UUID()),
            value: .workout(try HealthKitWorkoutValue(activityTypeRawValue: 1, durationSeconds: 60, activeEnergyKilocalories: 200)),
            startDate: now.addingTimeInterval(30),
            endDate: now.addingTimeInterval(90),
            provenance: provenance,
            now: now.addingTimeInterval(90)
        )
        let aggregate = try HealthKitEnergyAggregate.from(observations: [active, workout])
        XCTAssertEqual(aggregate.kilocalories, 100)
        XCTAssertEqual(aggregate.policy, .activeEnergyAuthoritative)
    }

    func testSleepPreservesUnknownStageAndOvernightDSTInterval() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 1, minute: 30)))
        let end = start.addingTimeInterval(3 * 60 * 60)
        let value = try HealthKitSleepValue(stage: .unknown(rawValue: 99), timeZoneIdentifier: "Europe/Berlin")
        let observation = try HealthKitObservation(
            metric: .sleep,
            identity: .init(uuid: UUID()),
            value: .sleep(value),
            startDate: start,
            endDate: end,
            provenance: try provenance(),
            now: end
        )
        XCTAssertEqual(observation.endDate.timeIntervalSince(observation.startDate), 3 * 60 * 60)
        XCTAssertEqual(value.stage, .unknown(rawValue: 99))
        XCTAssertEqual(value.timeZoneIdentifier, "Europe/Berlin")
    }

    func testFutureAndNonFiniteObservationDatesAreRejected() throws {
        let future = now.addingTimeInterval(60)
        XCTAssertThrowsError(try quantityObservation(at: future))
        XCTAssertThrowsError(try HealthKitQuantityValue(metric: .water, value: .nan, unit: .milliliters))
        XCTAssertThrowsError(try HealthKitWorkoutValue(activityTypeRawValue: 1, durationSeconds: .infinity))
    }

    func testStrictDecodingRejectsUnknownKeysAndExplicitNullOptionals() throws {
        let observation = try quantityObservation()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(observation)) as? [String: Any])
        object["unexpected"] = true
        let unknown = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(HealthKitObservation.self, from: unknown))

        let source = try HealthKitSourceMetadata(bundleIdentifier: "com.example.health", name: "Health")
        var sourceObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(source)) as? [String: Any])
        sourceObject["version"] = NSNull()
        XCTAssertThrowsError(try JSONDecoder().decode(HealthKitSourceMetadata.self, from: JSONSerialization.data(withJSONObject: sourceObject)))
    }

    func testObservationValueUnionRejectsSiblingPayloads() throws {
        let quantity = try HealthKitQuantityValue(metric: .water, value: 1, unit: .milliliters)
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(HealthKitObservationValue.quantity(quantity))) as? [String: Any])
        object["sleep"] = ["stage": ["kind": "awake"]]
        XCTAssertThrowsError(try JSONDecoder().decode(HealthKitObservationValue.self, from: JSONSerialization.data(withJSONObject: object)))
    }
}
