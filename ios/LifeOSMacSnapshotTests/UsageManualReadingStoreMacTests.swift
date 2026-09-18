import Foundation
import XCTest
@testable import LifeOSMac

private final class OneShotDataReadbackFailureDefaults: UserDefaults {
    private var shouldFailNextReadback = true

    init(suiteName: String) {
        super.init(suiteName: suiteName)!
    }

    override func data(forKey defaultName: String) -> Data? {
        if shouldFailNextReadback,
           defaultName == UserDefaultsUsageManualReadingStore.key {
            shouldFailNextReadback = false
            return nil
        }
        return super.data(forKey: defaultName)
    }
}

private final class PersistentPostWriteReadbackFailureDefaults: UserDefaults {
    private var shouldFailReadback = false

    init(suiteName: String) {
        super.init(suiteName: suiteName)!
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        if defaultName == UserDefaultsUsageManualReadingStore.key {
            shouldFailReadback = true
        }
    }

    override func object(forKey defaultName: String) -> Any? {
        if shouldFailReadback,
           defaultName == UserDefaultsUsageManualReadingStore.key {
            return nil
        }
        return super.object(forKey: defaultName)
    }

    override func data(forKey defaultName: String) -> Data? {
        if shouldFailReadback,
           defaultName == UserDefaultsUsageManualReadingStore.key {
            return nil
        }
        return super.data(forKey: defaultName)
    }
}

private final class RemoveSuppressedDefaults: UserDefaults {
    init(suiteName: String) {
        super.init(suiteName: suiteName)!
    }

    override func removeObject(forKey defaultName: String) {
        guard defaultName != UserDefaultsUsageManualReadingStore.key else { return }
        super.removeObject(forKey: defaultName)
    }
}

@available(macOS 14.0, *)
final class UsageManualReadingStoreMacTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func reading(
        window: UsageManualReadingWindow = .fiveHour,
        value: Double = 42,
        valueKind: UsageManualReadingValueKind = .used,
        observedAt: Date? = nil,
        resetAt: Date? = nil,
        now: Date? = nil
    ) throws -> UsageManualReading {
        try UsageManualReading(
            providerID: try UsageProviderID(UsageManualReading.supportedProviderID),
            adapterID: UsageManualReading.supportedAdapterID,
            window: window,
            value: value,
            valueKind: valueKind,
            observedAt: observedAt ?? self.now.addingTimeInterval(-60),
            resetAt: resetAt,
            now: now ?? self.now
        )
    }

    func testUsedAndRemainingInputsAreStoredAsCanonicalUsedPercent() throws {
        XCTAssertEqual(
            try UsageManualReading.canonicalUsedPercent(42, kind: .used),
            42
        )
        XCTAssertEqual(
            try UsageManualReading.canonicalUsedPercent(42, kind: .remaining),
            58
        )

        let remaining = try reading(value: 42, valueKind: .remaining)
        XCTAssertEqual(remaining.usedPercent, 58)
    }

    func testValidationRejectsOutOfRangeFutureAndBackwardsResetValues() throws {
        XCTAssertThrowsError(try reading(value: 100.01)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .invalidValue)
        }
        XCTAssertThrowsError(try reading(observedAt: now.addingTimeInterval(6), now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .futureObservedAt)
        }
        XCTAssertThrowsError(try reading(resetAt: now.addingTimeInterval(-61))) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .resetBeforeObserved)
        }
    }

    func testManualReadingSetKeepsLatestObservationPerWindowAndBoundsTheSet() throws {
        let store = InMemoryUsageManualReadingStore()
        let newer = try reading(value: 30, observedAt: now.addingTimeInterval(-60))
        let older = try reading(value: 90, observedAt: now.addingTimeInterval(-120))
        let weekly = try reading(
            window: .weekly,
            value: 12,
            observedAt: now.addingTimeInterval(-30)
        )

        XCTAssertEqual(try store.save(newer, now: now), [newer])
        XCTAssertEqual(try store.save(older, now: now), [newer])
        XCTAssertEqual(try store.save(weekly, now: now), [newer, weekly])
        XCTAssertEqual(try store.load(now: now), [newer, weekly])

        XCTAssertThrowsError(try UsageManualReadingSet.validated([newer, newer], now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .duplicateWindow)
        }
    }

    func testStalenessUsesAgeAndProviderResetBoundary() throws {
        let aged = try reading(
            observedAt: now.addingTimeInterval(-UsageManualReading.staleAfter),
            now: now
        )
        XCTAssertEqual(aged.status(at: now), .needsUpdating)
        XCTAssertEqual(aged.freshness(at: now), .stale)

        let reset = try reading(
            observedAt: now.addingTimeInterval(-60),
            resetAt: now,
            now: now
        )
        XCTAssertEqual(reset.status(at: now), .needsUpdating)
    }

    func testCodableRejectsUnknownKeysAndInvalidDecodedValues() throws {
        let source = try reading()
        let providerID = try UsageProviderID(UsageManualReading.supportedProviderID)
        let envelope = try UsageManualReadingEnvelope(
            providerID: providerID,
            adapterID: UsageManualReading.supportedAdapterID,
            readings: [source]
        )
        let encoded = try JSONEncoder.lifeOS.encode(envelope)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var readings = try XCTUnwrap(object["readings"] as? [[String: Any]])

        readings[0]["unexpected"] = true
        object["readings"] = readings
        let unknownKeyData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder.lifeOS.decode(UsageManualReadingEnvelope.self, from: unknownKeyData)
        )

        readings[0].removeValue(forKey: "unexpected")
        readings[0]["usedPercent"] = 101
        object["readings"] = readings
        let invalidValueData = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(
            try JSONDecoder.lifeOS.decode(UsageManualReadingEnvelope.self, from: invalidValueData)
        ) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .invalidValue)
        }
    }

    func testUserDefaultsStoreRejectsOversizedPayloadAndRoundTripsBoundedData() throws {
        let suiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsUsageManualReadingStore(defaults: defaults)
        let source = try reading()

        XCTAssertEqual(try store.save(source, now: now), [source])
        XCTAssertEqual(try store.load(now: now), [source])

        defaults.set(
            Data(repeating: 0x78, count: UsageManualReadingEnvelope.maximumEncodedBytes + 1),
            forKey: UserDefaultsUsageManualReadingStore.key
        )
        XCTAssertThrowsError(try store.load(now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .payloadTooLarge)
        }
    }

    func testUserDefaultsStoreRejectsExistingWrongTypeButKeepsMissingKeyEmpty() throws {
        let suiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsUsageManualReadingStore(defaults: defaults)

        XCTAssertEqual(try store.load(now: now), [])
        defaults.set("not-data", forKey: UserDefaultsUsageManualReadingStore.key)

        XCTAssertThrowsError(try store.load(now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .invalidEnvelope)
        }
    }

    func testUserDefaultsStoreRollsBackPostWriteFailureAndPreservesPriorOrAbsentPayload() throws {
        let suiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try reading(value: 24)
        let store = UserDefaultsUsageManualReadingStore(defaults: defaults)
        XCTAssertEqual(try store.save(source, now: now), [source])
        let previousData = try XCTUnwrap(defaults.data(forKey: UserDefaultsUsageManualReadingStore.key))

        let failingDefaults = OneShotDataReadbackFailureDefaults(suiteName: suiteName)
        let failingStore = UserDefaultsUsageManualReadingStore(defaults: failingDefaults)
        let replacement = try reading(value: 76)

        XCTAssertThrowsError(try failingStore.replace([replacement], now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .saveFailed)
        }
        XCTAssertEqual(failingDefaults.data(forKey: UserDefaultsUsageManualReadingStore.key), previousData)
        XCTAssertEqual(try failingStore.load(now: now), [source])

        let emptySuiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let emptyDefaults = OneShotDataReadbackFailureDefaults(suiteName: emptySuiteName)
        defer { emptyDefaults.removePersistentDomain(forName: emptySuiteName) }
        let emptyStore = UserDefaultsUsageManualReadingStore(defaults: emptyDefaults)

        XCTAssertThrowsError(try emptyStore.replace([source], now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .saveFailed)
        }
        XCTAssertNil(emptyDefaults.object(forKey: UserDefaultsUsageManualReadingStore.key))
        XCTAssertEqual(try emptyStore.load(now: now), [])
    }

    func testPersistentReadbackFailureRestoresPriorRawPayload() throws {
        let suiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let source = try reading(value: 24)
        let store = UserDefaultsUsageManualReadingStore(defaults: defaults)
        XCTAssertEqual(try store.save(source, now: now), [source])
        let previousData = try XCTUnwrap(defaults.data(forKey: UserDefaultsUsageManualReadingStore.key))

        let failingDefaults = PersistentPostWriteReadbackFailureDefaults(suiteName: suiteName)
        let failingStore = UserDefaultsUsageManualReadingStore(defaults: failingDefaults)
        XCTAssertThrowsError(try failingStore.replace([try reading(value: 76)], now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .saveFailed)
        }

        let observer = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertEqual(observer.object(forKey: UserDefaultsUsageManualReadingStore.key) as? Data, previousData)
        XCTAssertEqual(try UserDefaultsUsageManualReadingStore(defaults: observer).load(now: now), [source])
    }

    func testPersistentReadbackFailureWithAbsentKeyDoesNotLeaveCandidate() throws {
        let suiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let failingDefaults = PersistentPostWriteReadbackFailureDefaults(suiteName: suiteName)
        defer { failingDefaults.removePersistentDomain(forName: suiteName) }
        let store = UserDefaultsUsageManualReadingStore(defaults: failingDefaults)

        XCTAssertThrowsError(try store.replace([try reading(value: 76)], now: now)) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .saveFailed)
        }

        let observer = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        XCTAssertNil(observer.object(forKey: UserDefaultsUsageManualReadingStore.key))
        XCTAssertEqual(try UserDefaultsUsageManualReadingStore(defaults: observer).load(now: now), [])
    }

    func testDeleteThrowsWhenWrongTypeObjectCannotBeRemoved() throws {
        let suiteName = "LifeOS.UsageManualReadingStoreMacTests.\(UUID().uuidString)"
        let defaults = RemoveSuppressedDefaults(suiteName: suiteName)
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        defaults.set("corrupt", forKey: UserDefaultsUsageManualReadingStore.key)

        XCTAssertThrowsError(try UserDefaultsUsageManualReadingStore(defaults: defaults).delete()) { error in
            XCTAssertEqual(error as? UsageManualReadingStoreError, .deleteFailed)
        }
        XCTAssertEqual(defaults.object(forKey: UserDefaultsUsageManualReadingStore.key) as? String, "corrupt")
    }

    func testStoreFailureLeavesPreviouslyCommittedReadingsVisible() throws {
        let source = try reading()
        let store = InMemoryUsageManualReadingStore(readings: [source])
        store.saveError = .saveFailed

        XCTAssertThrowsError(try store.save(try reading(value: 70), now: now))
        XCTAssertEqual(store.readings, [source])

        store.saveError = nil
        store.deleteError = .deleteFailed
        XCTAssertThrowsError(try store.delete())
        XCTAssertEqual(store.readings, [source])
    }
}
