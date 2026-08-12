import XCTest
@testable import LifeOS

private actor CalendarMutationGate {
    private var entered = 0
    private var entryWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered += 1
        let ready = entryWaiters.partitioned { $0.count <= entered }
        entryWaiters = ready.remainder
        ready.matching.forEach { $0.continuation.resume() }
        await withCheckedContinuation { continuation in
            releaseWaiters.append(continuation)
        }
    }

    func waitForEntries(_ count: Int) async {
        guard entered < count else { return }
        await withCheckedContinuation { continuation in
            entryWaiters.append((count, continuation))
        }
    }

    func releaseOne() {
        guard !releaseWaiters.isEmpty else { return }
        releaseWaiters.removeFirst().resume()
    }
}

private extension Array {
    func partitioned(where belongsInFirst: (Element) -> Bool) -> (matching: [Element], remainder: [Element]) {
        reduce(into: (matching: [], remainder: [])) { result, element in
            if belongsInFirst(element) { result.matching.append(element) }
            else { result.remainder.append(element) }
        }
    }
}

private final class CalendarRevisionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
}

final class CalendarDomainTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private enum CoordinatorTestError: Error {
        case peerUnavailable
    }

    func testValidationAndExplicitNoIconSemantics() throws {
        XCTAssertThrowsError(try CalendarItem(title: "   ", icon: "📅", status: .planned, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base))
        XCTAssertThrowsError(try CalendarItem(title: "x", icon: "📅", status: .planned, start: base, end: base, createdAt: base, updatedAt: base))
        let item = try CalendarItem(title: "x", icon: "not-an-emoji", status: .planned, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertNil(item.icon)
        XCTAssertFalse(item.hasIcon)
        XCTAssertNil(try CalendarItem(title: "blank", start: base, end: base.addingTimeInterval(60)).icon)
        XCTAssertEqual(CalendarEmojiValidation.validated("🧑‍💻"), "🧑‍💻")
        XCTAssertNil(CalendarEmojiValidation.validated("😀😀"))
        XCTAssertNil(CalendarEmojiValidation.validated("1"))
        XCTAssertEqual(CalendarEmojiValidation.validated("1️⃣"), "1️⃣")
    }

    func testOrderingAndDayQueryAndProgressUpdate() throws {
        let later = try CalendarItem(title: "later", start: base.addingTimeInterval(3600), end: base.addingTimeInterval(3660), createdAt: base, updatedAt: base)
        let earlier = try CalendarItem(title: "earlier", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let snapshot = CalendarSnapshot(items: [later, earlier])
        XCTAssertEqual(snapshot.items.map(\.title), ["earlier", "later"])
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        XCTAssertEqual(snapshot.items(on: base, calendar: utcCalendar).count, 2)
        let changed = try earlier.updating(status: .inProgress, at: base.addingTimeInterval(10))
        XCTAssertEqual(changed.status, .inProgress)
    }

    func testEditorDateAdjustmentPreservesDurationAndOvernightDayOffset() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 23, minute: 15)))
        let end = try XCTUnwrap(calendar.date(byAdding: .minute, value: 150, to: start))
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 0, minute: 0)))

        let translated = CalendarEditorDateAdjustment.translatedBounds(
            start: start,
            end: end,
            to: target,
            calendar: calendar
        )

        XCTAssertEqual(translated.end.timeIntervalSince(translated.start), end.timeIntervalSince(start))
        XCTAssertEqual(calendar.component(.hour, from: translated.start), 23)
        XCTAssertEqual(calendar.component(.minute, from: translated.start), 15)
        XCTAssertEqual(calendar.component(.day, from: translated.start), 20)
        XCTAssertEqual(calendar.component(.day, from: translated.end), 21)
        XCTAssertEqual(calendar.component(.hour, from: translated.end), 1)
        XCTAssertEqual(calendar.component(.minute, from: translated.end), 45)
        XCTAssertGreaterThan(translated.end, translated.start)
    }

    func testEditorDateAdjustmentDoesNotReverseMalformedBounds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let translated = CalendarEditorDateAdjustment.translatedBounds(
            start: start,
            end: start.addingTimeInterval(-60),
            to: start,
            calendar: calendar
        )

        XCTAssertGreaterThan(translated.end, translated.start)
    }

    func testEditorMutationResolutionDismissesOnlySuccessfulCompletion() {
        let success = CalendarEditorMutationResolution(result: .success)
        XCTAssertTrue(success.shouldDismiss)
        XCTAssertFalse(success.retryAvailable)
        XCTAssertNil(success.message)

        let failure = CalendarEditorMutationResolution(result: .failure("disk unavailable"))
        XCTAssertFalse(failure.shouldDismiss)
        XCTAssertTrue(failure.retryAvailable)
        XCTAssertEqual(failure.message, "disk unavailable")

        let emptyFailure = CalendarEditorMutationResolution(result: .failure(""))
        XCTAssertFalse(emptyFailure.shouldDismiss)
        XCTAssertTrue(emptyFailure.retryAvailable)
        XCTAssertEqual(emptyFailure.message, "Unable to save the calendar locally. Keep editing and retry.")
    }

    func testProgressUsesRequestedStatusesAndMigratesLegacyBlocked() throws {
        XCTAssertEqual(CalendarProgress.allCases, [.planned, .inProgress, .done, .aborted])
        let legacy = try JSONDecoder().decode(CalendarProgress.self, from: Data(#""blocked""#.utf8))
        XCTAssertEqual(legacy, .aborted)
        let encoded = try JSONEncoder().encode(CalendarProgress.aborted)
        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), #""aborted""#)
    }

    func testUpdatingCanExplicitlyRemoveIconAssetWhileOmissionPreservesIt() throws {
        let asset = try CalendarIconAsset(
            format: .png,
            bytes: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        )
        let item = try CalendarItem(
            title: "Branded",
            iconAsset: asset,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )

        XCTAssertEqual(try item.updating(at: base.addingTimeInterval(1)).iconAsset, asset)
        XCTAssertNil(try item.updating(clearIconAsset: true, at: base.addingTimeInterval(2)).iconAsset)
    }

    func testUpdatingCanExplicitlyRemoveEmojiWhileOmissionPreservesIt() throws {
        let item = try CalendarItem(title: "Emoji", icon: "🎯", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertEqual(try item.updating(at: base.addingTimeInterval(1)).icon, "🎯")
        XCTAssertNil(try item.updating(clearIcon: true, at: base.addingTimeInterval(2)).icon)
        XCTAssertFalse(try item.updating(clearIcon: true, at: base.addingTimeInterval(2)).hasIcon)
    }

    func testMergeUsesLastWriteWinsAndPropagatesTombstone() throws {
        let id = UUID()
        let old = try CalendarItem(id: id, title: "old", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let newer = try old.updating(title: "new", at: base.addingTimeInterval(2))
        let deleted = newer.deleting(at: base.addingTimeInterval(3))
        XCTAssertEqual(CalendarSnapshot(items: [old]).merged(with: CalendarSnapshot(items: [newer])).items.first?.title, "new")
        XCTAssertTrue(CalendarSnapshot(items: [newer]).merged(with: CalendarSnapshot(items: [deleted])).items.first?.isDeleted == true)
    }

    func testSnapshotRoundTrip() throws {
        let item = try CalendarItem(title: "round trip", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let data = try JSONEncoder().encode(CalendarSnapshot(items: [item]))
        XCTAssertEqual(try JSONDecoder().decode(CalendarSnapshot.self, from: data), CalendarSnapshot(items: [item]))
    }

    func testSystemIconCodableAndLegacyPayloadCompatibility() throws {
        let item = try CalendarItem(
            title: "Native symbol",
            icon: "🔹",
            systemIconName: "calendar",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        XCTAssertEqual(item.systemIconName, "calendar")
        let encoded = try JSONEncoder().encode(item)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: encoded), item)

        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "systemIconName")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertNil(try JSONDecoder().decode(CalendarItem.self, from: legacyData).systemIconName)
    }

    func testSystemIconUpdatesAndInvalidNamesFallBackWithoutRasterAssets() throws {
        let item = try CalendarItem(title: "Icon", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let symbol = try item.updating(systemIconName: "calendar", at: base.addingTimeInterval(1))
        XCTAssertEqual(symbol.systemIconName, "calendar")
        XCTAssertNil(symbol.iconAsset)

        let invalid = try item.updating(systemIconName: "definitely.not.a.real.lifeos.symbol", at: base.addingTimeInterval(2))
        XCTAssertNil(invalid.systemIconName)

        let cleared = try symbol.updating(clearSystemIconName: true, at: base.addingTimeInterval(3))
        XCTAssertNil(cleared.systemIconName)
    }

    func testIconCodableMigratesLegacyStringMissingAndNullAndEnforcesSourcePrecedence() throws {
        let emoji = try CalendarItem(title: "Legacy", icon: "🎯", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let encoded = try JSONEncoder().encode(emoji)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: encoded).icon, "🎯")

        var missing = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        missing.removeValue(forKey: "icon")
        let missingData = try JSONSerialization.data(withJSONObject: missing)
        XCTAssertNil(try JSONDecoder().decode(CalendarItem.self, from: missingData).icon)

        var null = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        null["icon"] = NSNull()
        let nullData = try JSONSerialization.data(withJSONObject: null)
        XCTAssertNil(try JSONDecoder().decode(CalendarItem.self, from: nullData).icon)

        let asset = try CalendarIconAsset(
            format: .png,
            bytes: Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        )
        let assetObject = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(asset)) as? [String: Any])
        var mixedAsset = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        mixedAsset["iconAsset"] = assetObject
        let mixedAssetItem = try JSONDecoder().decode(CalendarItem.self, from: JSONSerialization.data(withJSONObject: mixedAsset))
        XCTAssertNil(mixedAssetItem.icon)
        XCTAssertEqual(mixedAssetItem.iconAsset, asset)

        var mixedSystem = mixedAsset
        mixedSystem["systemIconName"] = "calendar"
        let mixedSystemItem = try JSONDecoder().decode(CalendarItem.self, from: JSONSerialization.data(withJSONObject: mixedSystem))
        XCTAssertEqual(mixedSystemItem.systemIconName, "calendar")
        XCTAssertNil(mixedSystemItem.iconAsset)
        XCTAssertNil(mixedSystemItem.icon)
    }

    func testDayQueryExcludesTombstones() throws {
        let live = try CalendarItem(title: "live", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let deleted = live.deleting(at: base.addingTimeInterval(10))
        XCTAssertTrue(CalendarSnapshot(items: [deleted]).items(on: base).isEmpty)
    }

    func testSameTimestampMergeIsDeterministic() throws {
        let id = UUID()
        let left = try CalendarItem(id: id, title: "alpha", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let right = try CalendarItem(id: id, title: "omega", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertEqual(CalendarSnapshot(items: [left]).merged(with: CalendarSnapshot(items: [right])),
                       CalendarSnapshot(items: [right]).merged(with: CalendarSnapshot(items: [left])))
    }

    func testStoreReadsItsISO8601Output() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let store = CalendarStore(url: url)
        let item = try CalendarItem(title: "persisted", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        try await store.save(CalendarSnapshot(items: [item]))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.items, [item])
        try? FileManager.default.removeItem(at: directory)
    }

    func testStoreCommitAcknowledgesOneDurableSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CalendarStore(url: directory.appendingPathComponent("calendar.json"))
        let item = try CalendarItem(title: "acknowledged", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let acknowledged = try await store.save(CalendarSnapshot(items: [item]))
        let loaded = try await store.load()

        XCTAssertEqual(acknowledged.items, [item])
        XCTAssertEqual(loaded, acknowledged)
        XCTAssertEqual(loaded.items.filter { $0.id == item.id }.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testCoordinatorLocalFailureLeavesSnapshotUnchangedAndReturnsFailure() async throws {
        // A regular file in the parent path makes CalendarStore.createDirectory
        // fail deterministically. Using a directory at the JSON path is not a
        // reliable failure target: replaceItem(at:withItemAt:) may replace it
        // with the temporary file on the current simulator.
        let blockingFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: blockingFile.path, contents: Data()))
        let url = blockingFile.appendingPathComponent("calendar.json")
        let original = try CalendarItem(title: "original", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let updated = try original.updating(title: "should fail", at: base.addingTimeInterval(1))
        let coordinator = CalendarCoordinator(initialSnapshot: CalendarSnapshot(items: [original]), storeURL: url)

        let result = await coordinator.save(updated)

        if case .failure = result {} else { XCTFail("A store failure must not acknowledge a local commit") }
        XCTAssertEqual(coordinator.snapshot.items, [original])
        XCTAssertNotNil(coordinator.errorMessage)
        try? FileManager.default.removeItem(at: blockingFile)
    }

    @MainActor
    func testCoordinatorLocalSuccessAcknowledgesExactlyOneCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let original = try CalendarItem(title: "original", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let updated = try original.updating(title: "saved", at: base.addingTimeInterval(1))
        let coordinator = CalendarCoordinator(initialSnapshot: CalendarSnapshot(items: [original]), storeURL: url)

        let result = await coordinator.save(updated)
        XCTAssertEqual(result, .success)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(loaded.items, [updated])
        XCTAssertEqual(loaded.items.filter { $0.id == updated.id }.count, 1)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testFailedSaveRetainsRetryAfterLaterSaveSucceeds() async throws {
        let blockingFile = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: blockingFile.path, contents: Data()))
        let url = blockingFile.appendingPathComponent("calendar.json")
        let failedItem = try CalendarItem(title: "retry me", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let laterItem = try CalendarItem(title: "later", start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base)
        let coordinator = CalendarCoordinator(storeURL: url)

        let failed = await coordinator.save(failedItem)
        try FileManager.default.removeItem(at: blockingFile)
        let later = await coordinator.save(laterItem)

        if case .failure = failed {} else { XCTFail("The blocked first save must fail") }
        XCTAssertEqual(later, .success)
        XCTAssertNotNil(coordinator.errorMessage)

        let retry = await coordinator.retryLastSave()
        XCTAssertEqual(retry, .success)
        XCTAssertNil(coordinator.errorMessage)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(Set(loaded.items.map(\.id)), Set([failedItem.id, laterItem.id]))
        try? FileManager.default.removeItem(at: blockingFile)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    @MainActor
    func testPeerSendFailureStillAcknowledgesLocalCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let item = try CalendarItem(title: "peer warning", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(),
            storeURL: url,
            peerSend: { _, _, _ in throw CoordinatorTestError.peerUnavailable }
        )

        let result = await coordinator.save(item)
        XCTAssertEqual(result, .success)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(loaded.items, [item])
        XCTAssertTrue(coordinator.syncWarning?.contains("saved locally") == true)
        XCTAssertNil(coordinator.errorMessage)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testOverlappingCreatesUseLatestDurableSnapshotAndAdvanceRevisions() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = CalendarMutationGate()
        let revisions = CalendarRevisionRecorder()
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(),
            storeURL: directory.appendingPathComponent("calendar.json"),
            peerSend: { _, _, revision in revisions.append(revision) },
            storeMutationHook: { await gate.pause() }
        )
        let first = try CalendarItem(title: "first", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let second = try CalendarItem(title: "second", start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base)

        let firstSave = Task { await coordinator.save(first) }
        await gate.waitForEntries(1)
        let secondSave = Task { await coordinator.save(second) }
        await gate.releaseOne()
        await gate.waitForEntries(2)
        await gate.releaseOne()

        let firstResult = await firstSave.value
        let secondResult = await secondSave.value
        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(secondResult, .success)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(Set(loaded.items.map(\.id)), Set([first.id, second.id]))
        XCTAssertEqual(loaded.items.count, 2)
        XCTAssertEqual(revisions.values.count, 2)
        XCTAssertTrue(zip(revisions.values, revisions.values.dropFirst()).allSatisfy { $0 < $1 })
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testOverlappingSameIDSavesUseUpdatedAtAsDefinedOrdering() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let gate = CalendarMutationGate()
        let id = UUID()
        let older = try CalendarItem(id: id, title: "older", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base.addingTimeInterval(1))
        let newer = try CalendarItem(id: id, title: "newer", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base.addingTimeInterval(2))
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(),
            storeURL: directory.appendingPathComponent("calendar.json"),
            storeMutationHook: { await gate.pause() }
        )

        let firstSave = Task { await coordinator.save(newer) }
        await gate.waitForEntries(1)
        let secondSave = Task { await coordinator.save(older) }
        await gate.releaseOne()
        await gate.waitForEntries(2)
        await gate.releaseOne()

        let firstResult = await firstSave.value
        let secondResult = await secondSave.value
        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(secondResult, .success)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(loaded.items, [newer])
        try? FileManager.default.removeItem(at: directory)
    }

    func testLocalStoreURLDoesNotRequirePaidAppGroupCapability() {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("LifeOSTest", isDirectory: true)
        XCTAssertEqual(CalendarStoreURL.localURL(baseDirectory: baseURL).path,
                       baseURL.appendingPathComponent("calendar.json").path)
    }
}
