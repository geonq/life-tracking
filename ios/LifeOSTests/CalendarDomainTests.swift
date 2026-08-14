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

private final class AppGroupTestFileManager: FileManager {
    let groupURL: URL

    init(groupURL: URL) {
        self.groupURL = groupURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        groupURL
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

        let translated = try CalendarEditorDateAdjustment.translatedBounds(
            start: start,
            end: end,
            to: target,
            calendar: calendar
        ).get()

        XCTAssertEqual(translated.end.timeIntervalSince(translated.start), end.timeIntervalSince(start))
        XCTAssertEqual(calendar.component(.hour, from: translated.start), 23)
        XCTAssertEqual(calendar.component(.minute, from: translated.start), 15)
        XCTAssertEqual(calendar.component(.day, from: translated.start), 20)
        XCTAssertEqual(calendar.component(.day, from: translated.end), 21)
        XCTAssertEqual(calendar.component(.hour, from: translated.end), 1)
        XCTAssertEqual(calendar.component(.minute, from: translated.end), 45)
        XCTAssertGreaterThan(translated.end, translated.start)
    }

    func testEditorDateAdjustmentRejectsMalformedBounds() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let result = CalendarEditorDateAdjustment.translatedBounds(
            start: start,
            end: start.addingTimeInterval(-60),
            to: start,
            calendar: calendar
        )

        guard case .failure(let error) = result else {
            return XCTFail("Malformed bounds must be rejected")
        }
        XCTAssertEqual(error, .invalidInterval)
    }

    func testEditorDateAdjustmentRejectsSpringForwardGapWithoutNormalizing() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 2, minute: 30)))
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))

        let result = CalendarEditorDateAdjustment.translatedBounds(
            start: start,
            end: start.addingTimeInterval(3_600),
            to: target,
            calendar: calendar
        )

        guard case .failure(let error) = result else {
            return XCTFail("A nonexistent local time must not be normalized")
        }
        XCTAssertEqual(error, .unavailableLocalTime)
    }

    func testEditorDateAdjustmentPreservesLaterFallBackOccurrenceAndDuration() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let sourceFirst = try XCTUnwrap(calendar.date(from: DateComponents(year: 2025, month: 11, day: 2, hour: 1, minute: 30)))
        let sourceLater = sourceFirst.addingTimeInterval(3_600)
        XCTAssertEqual(calendar.component(.hour, from: sourceLater), 1)
        let target = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
        let duration: TimeInterval = 5_400

        let translated = try CalendarEditorDateAdjustment.translatedBounds(
            start: sourceLater,
            end: sourceLater.addingTimeInterval(duration),
            to: target,
            calendar: calendar
        ).get()

        XCTAssertEqual(calendar.component(.hour, from: translated.start), 1)
        XCTAssertEqual(calendar.component(.minute, from: translated.start), 30)
        let prior = try XCTUnwrap(calendar.date(byAdding: .hour, value: -1, to: translated.start))
        XCTAssertEqual(calendar.component(.hour, from: prior), 1)
        XCTAssertEqual(translated.end.timeIntervalSince(translated.start), duration)
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

    func testCalendarItemKindRoundTripsAndLegacyPayloadDefaultsToEvent() throws {
        let todo = try CalendarItem(
            title: "Inbox",
            kind: .todo,
            status: .done,
            start: base,
            end: base.addingTimeInterval(900),
            createdAt: base,
            updatedAt: base
        )
        let encoded = try JSONEncoder().encode(todo)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: encoded).kind, .todo)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "kind")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: legacyData).kind, .event)

        let daily = try CalendarItem(
            title: "Morning plan",
            kind: .dailySchedule,
            status: .inProgress,
            start: base,
            end: base.addingTimeInterval(1_800),
            createdAt: base,
            updatedAt: base
        )
        let dailyData = try JSONEncoder().encode(daily)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: dailyData).kind, .dailySchedule)
        let dailyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: dailyData) as? [String: Any])
        XCTAssertEqual(dailyObject["kind"] as? String, "dailySchedule")

        var snakeCasePeerObject = dailyObject
        snakeCasePeerObject["kind"] = "daily_schedule"
        let snakeCasePeerData = try JSONSerialization.data(withJSONObject: snakeCasePeerObject)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: snakeCasePeerData).kind, .dailySchedule)
    }

    func testTodoDoneToggleIsDurableAndLeavesKindAndIntervalUntouched() throws {
        let todo = try CalendarItem(
            title: "Ship",
            kind: .todo,
            start: base,
            end: base.addingTimeInterval(1_200),
            createdAt: base,
            updatedAt: base
        )
        let completed = try todo.togglingDone(at: base.addingTimeInterval(1))
        XCTAssertEqual(completed.status, .done)
        XCTAssertEqual(completed.kind, .todo)
        XCTAssertEqual(completed.start, todo.start)
        XCTAssertEqual(completed.end, todo.end)
        XCTAssertEqual(try completed.togglingDone(at: base.addingTimeInterval(2)).status, .planned)
        let event = try CalendarItem(title: "Meeting", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertEqual(try event.togglingDone(at: base.addingTimeInterval(1)), event)
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

    func testTimeZoneIdentifierDefaultsToFloatingAndRoundTripsExplicitValue() throws {
        let floating = try CalendarItem(title: "floating", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertNil(floating.timeZoneIdentifier)
        let floatingEncoded = try JSONEncoder().encode(floating)
        var floatingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: floatingEncoded) as? [String: Any])
        // A floating event must not write the key at all, so its blob stays
        // identical to a pre-timezone-field snapshot.
        XCTAssertNil(floatingObject["timeZoneIdentifier"])

        let zoned = try CalendarItem(
            title: "zoned",
            start: base,
            end: base.addingTimeInterval(60),
            timeZoneIdentifier: "America/New_York",
            createdAt: base,
            updatedAt: base
        )
        XCTAssertEqual(zoned.timeZoneIdentifier, "America/New_York")
        let zonedEncoded = try JSONEncoder().encode(zoned)
        XCTAssertEqual(try JSONDecoder().decode(CalendarItem.self, from: zonedEncoded), zoned)

        // A legacy payload predating this field must still decode to floating.
        floatingObject.removeValue(forKey: "timeZoneIdentifier")
        let legacyData = try JSONSerialization.data(withJSONObject: floatingObject)
        XCTAssertNil(try JSONDecoder().decode(CalendarItem.self, from: legacyData).timeZoneIdentifier)

        let updated = try floating.updating(timeZoneIdentifier: "Europe/Berlin", at: base.addingTimeInterval(1))
        XCTAssertEqual(updated.timeZoneIdentifier, "Europe/Berlin")
        let clearedAgain = try updated.updating(clearTimeZoneIdentifier: true, at: base.addingTimeInterval(2))
        XCTAssertNil(clearedAgain.timeZoneIdentifier)
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
        XCTAssertFalse(coordinator.canUndo, "A failed local persistence must not create an undo token")
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
    func testCoordinatorFixtureMutationIgnoresPreexistingDurableState() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let stale = try CalendarItem(title: "stale persisted event", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let fixture = try CalendarItem(title: "fixture event", start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base)
        let inserted = try CalendarItem(title: "fixture mutation", start: base.addingTimeInterval(240), end: base.addingTimeInterval(300), createdAt: base, updatedAt: base)

        let existingStore = CalendarStore(url: url)
        try await existingStore.save(CalendarSnapshot(items: [stale]))
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(items: [fixture]),
            usesVisualFixtures: true,
            storeURL: url
        )

        let result = await coordinator.save(inserted)

        XCTAssertEqual(result, .success)
        let expected = CalendarSnapshot(items: [fixture, inserted])
        XCTAssertEqual(coordinator.snapshot, expected)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(loaded, expected)
        XCTAssertFalse(coordinator.snapshot.items.contains { $0.id == stale.id })
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testCoordinatorUndoRestoresExactPreMutationSnapshotOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let original = try CalendarItem(
            title: "before",
            icon: "📅",
            status: .inProgress,
            start: base,
            end: base.addingTimeInterval(90),
            createdAt: base,
            updatedAt: base.addingTimeInterval(10)
        )
        let sentRevisions = CalendarRevisionRecorder()
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(items: [original]),
            storeURL: url,
            peerSend: { _, _, revision in sentRevisions.append(revision) }
        )
        let updated = try original.updating(
            title: "after",
            clearIcon: true,
            status: .done,
            start: base.addingTimeInterval(300),
            end: base.addingTimeInterval(600),
            at: base.addingTimeInterval(20)
        )

        let saveResult = await coordinator.save(updated)
        XCTAssertEqual(saveResult, .success)
        XCTAssertTrue(coordinator.canUndo)
        XCTAssertEqual(sentRevisions.values.count, 1)
        XCTAssertEqual(coordinator.snapshot, CalendarSnapshot(items: [updated]))

        let undoResult = await coordinator.undoLastMutation()
        XCTAssertEqual(undoResult, .success)
        XCTAssertFalse(coordinator.canUndo, "A successful undo must consume the one-shot token")
        XCTAssertEqual(coordinator.snapshot, CalendarSnapshot(items: [original]))
        XCTAssertEqual(sentRevisions.values.count, 1, "Exact local undo must not propagate an older LWW snapshot to peers")
        let restored = try await coordinator.store.load()
        XCTAssertEqual(restored, CalendarSnapshot(items: [original]))

        if case .success = await coordinator.undoLastMutation() {
            XCTFail("Undo must not be reusable")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testCoordinatorSuccessfulMutationReplacesPreviousUndoToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let first = try CalendarItem(title: "first", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let second = try CalendarItem(title: "second", start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base.addingTimeInterval(1))
        let coordinator = CalendarCoordinator(storeURL: url)

        let firstResult = await coordinator.save(first)
        let secondResult = await coordinator.save(second)
        XCTAssertEqual(firstResult, .success)
        XCTAssertEqual(secondResult, .success)
        XCTAssertTrue(coordinator.canUndo)

        // The latest token restores the snapshot immediately before `second`,
        // leaving the first successful mutation intact.
        let undoResult = await coordinator.undoLastMutation()
        XCTAssertEqual(undoResult, .success)
        XCTAssertFalse(coordinator.canUndo)
        XCTAssertEqual(coordinator.snapshot, CalendarSnapshot(items: [first]))
        let restored = try await coordinator.store.load()
        XCTAssertEqual(restored, CalendarSnapshot(items: [first]))
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testCoordinatorRemoteMergeInvalidatesUndoToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let local = try CalendarItem(title: "local", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let remote = try CalendarItem(title: "remote", start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base)
        let coordinator = CalendarCoordinator(storeURL: url)

        let saveResult = await coordinator.save(local)
        XCTAssertEqual(saveResult, .success)
        XCTAssertTrue(coordinator.canUndo)
        let mergeResult = await coordinator.merge(CalendarSnapshot(items: [remote]))
        XCTAssertEqual(mergeResult, .success)
        XCTAssertFalse(coordinator.canUndo, "A successful remote merge must invalidate local undo")
        XCTAssertEqual(Set(coordinator.snapshot.items.map(\.id)), Set([local.id, remote.id]))
        if case .success = await coordinator.undoLastMutation() {
            XCTFail("A remote merge must make the previous local undo unavailable")
        }
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testCoordinatorFailedMutationPreservesPriorUndoToken() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let first = try CalendarItem(title: "first", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let failed = try first.updating(title: "failed", at: base.addingTimeInterval(1))
        let coordinator = CalendarCoordinator(storeURL: url)

        let firstResult = await coordinator.save(first)
        XCTAssertEqual(firstResult, .success)
        XCTAssertTrue(coordinator.canUndo)
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))

        if case .success = await coordinator.save(failed) {
            XCTFail("The regular-file parent must reject the second local save")
        }
        XCTAssertTrue(coordinator.canUndo, "A failed mutation must not replace a prior valid undo token")
        XCTAssertEqual(coordinator.snapshot, CalendarSnapshot(items: [first]))

        try? FileManager.default.removeItem(at: directory)
        let undoResult = await coordinator.undoLastMutation()
        XCTAssertEqual(undoResult, .success)
        XCTAssertFalse(coordinator.canUndo)
        XCTAssertTrue(coordinator.snapshot.items.isEmpty)
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testCoordinatorFailedUndoPreservesTokenAndPublishedSnapshot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let item = try CalendarItem(title: "undo me", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let coordinator = CalendarCoordinator(storeURL: url)

        let saveResult = await coordinator.save(item)
        XCTAssertEqual(saveResult, .success)
        XCTAssertTrue(coordinator.canUndo)
        try FileManager.default.removeItem(at: directory)
        XCTAssertTrue(FileManager.default.createFile(atPath: directory.path, contents: Data()))

        if case .success = await coordinator.undoLastMutation() {
            XCTFail("Undo must report a failed local persistence")
        }
        XCTAssertTrue(coordinator.canUndo, "A failed undo must remain retryable")
        XCTAssertEqual(coordinator.snapshot, CalendarSnapshot(items: [item]))

        try? FileManager.default.removeItem(at: directory)
        let retryResult = await coordinator.retryLastSave()
        XCTAssertEqual(retryResult, .success, "The existing persistence Retry action must retry a failed Undo")
        XCTAssertFalse(coordinator.canUndo)
        XCTAssertTrue(coordinator.snapshot.items.isEmpty)
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

    @MainActor
    func testDevelopmentAppGroupPublishesAndReadsTheSameCalendarStorePath() async throws {
#if DEBUG
        let groupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: groupURL) }

        let identifier = "group.com.hermes.lifeos.\(AppGroupConfiguration.releasePlaceholder)"
        let fileManager = AppGroupTestFileManager(groupURL: groupURL)
        let appURL = try CalendarStoreURL.appGroupURL(identifier: identifier, fileManager: fileManager)
        let widgetURL = try CalendarStoreURL.appGroupURL(identifier: identifier, fileManager: fileManager)
        XCTAssertEqual(appURL, widgetURL)

        let item = try CalendarItem(
            title: "Shared",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        try await CalendarStore(url: appURL, fileManager: fileManager).save(CalendarSnapshot(items: [item]))
        let widgetSnapshot = try await CalendarStore(url: widgetURL, fileManager: fileManager).load()
        XCTAssertEqual(widgetSnapshot.items, [item])
#else
        let identifier = "group.com.hermes.lifeos.\(AppGroupConfiguration.releasePlaceholder)"
        XCTAssertNil(AppGroupConfiguration.validatedIdentifier(identifier))
#endif
    }
}
