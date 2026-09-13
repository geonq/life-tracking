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

private actor CalendarRemoteScript {
    struct Observation: Sendable {
        let fetchCount: Int
        let pushCount: Int
        let etags: [String]
        let idempotencyKeys: [String]
        let bodies: [Data]
    }

    let initial: CalendarRemoteResource
    let conflict: CalendarRemoteResource
    let success: CalendarRemoteResource
    private var fetchCount = 0
    private var pushCount = 0
    private var etags: [String] = []
    private var idempotencyKeys: [String] = []
    private var bodies: [Data] = []

    init(initial: CalendarRemoteResource, conflict: CalendarRemoteResource, success: CalendarRemoteResource) {
        self.initial = initial
        self.conflict = conflict
        self.success = success
    }

    func fetch() -> CalendarRemoteResource {
        fetchCount += 1
        return initial
    }

    func push(data: Data, etag: String, idempotencyKey: String) throws -> CalendarRemoteResource {
        pushCount += 1
        etags.append(etag)
        idempotencyKeys.append(idempotencyKey)
        bodies.append(data)
        if pushCount == 1 {
            throw CalendarSyncError.calendarConflict(data: conflict.data, etag: conflict.etag)
        }
        return success
    }

    func observation() -> Observation {
        Observation(
            fetchCount: fetchCount,
            pushCount: pushCount,
            etags: etags,
            idempotencyKeys: idempotencyKeys,
            bodies: bodies
        )
    }
}

private final class AppGroupTestFileManager: FileManager {
    let groupURL: URL
    private(set) var appGroupLookupCount = 0

    init(groupURL: URL) {
        self.groupURL = groupURL
        super.init()
    }

    override func containerURL(forSecurityApplicationGroupIdentifier groupIdentifier: String) -> URL? {
        appGroupLookupCount += 1
        return groupURL
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
        XCTAssertThrowsError(try CalendarItem(title: String(repeating: "x", count: CalendarItem.maximumTitleUTF8Bytes + 1), start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)) { error in
            XCTAssertEqual(error as? CalendarValidationError, .titleTooLong)
        }
        let item = try CalendarItem(title: "x", icon: "not-an-emoji", status: .planned, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertNil(item.icon)
        XCTAssertFalse(item.hasIcon)
        XCTAssertNil(try CalendarItem(title: "blank", start: base, end: base.addingTimeInterval(60)).icon)
        XCTAssertEqual(CalendarEmojiValidation.validated("🧑‍💻"), "🧑‍💻")
        XCTAssertNil(CalendarEmojiValidation.validated("😀😀"))
        XCTAssertNil(CalendarEmojiValidation.validated("1"))
        XCTAssertEqual(CalendarEmojiValidation.validated("1️⃣"), "1️⃣")
    }

    func testCalendarItemDecodingRejectsMalformedTitleAndInterval() throws {
        let item = try CalendarItem(
            title: "valid",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let encoded = try encoder.encode(item)
        let original = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970

        var blankTitle = original
        blankTitle["title"] = "   "
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: blankTitle)
        ))

        var oversizedTitle = original
        oversizedTitle["title"] = String(repeating: "x", count: CalendarItem.maximumTitleUTF8Bytes + 1)
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: oversizedTitle)
        ))

        var reversedInterval = original
        reversedInterval["end"] = base.timeIntervalSince1970
        reversedInterval["start"] = base.addingTimeInterval(60).timeIntervalSince1970
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: reversedInterval)
        ))

        var invalidIcon = original
        invalidIcon["icon"] = "not-an-emoji"
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: invalidIcon)
        ))

        var invalidSystemIcon = original
        invalidSystemIcon["systemIconName"] = "definitely/not-a-real-symbol"
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: invalidSystemIcon)
        ))

        var invalidIconAsset = original
        invalidIconAsset["iconAsset"] = ["format": "png", "bytes": "aW52YWxpZA=="]
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: invalidIconAsset)
        ))

        var invalidTimeZone = original
        invalidTimeZone["timeZoneIdentifier"] = "Not/AZone"
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: invalidTimeZone)
        ))

        var reversedMutationTimestamp = original
        reversedMutationTimestamp["createdAt"] = base.addingTimeInterval(60).timeIntervalSince1970
        reversedMutationTimestamp["updatedAt"] = base.timeIntervalSince1970
        XCTAssertThrowsError(try decoder.decode(
            CalendarItem.self,
            from: JSONSerialization.data(withJSONObject: reversedMutationTimestamp)
        ))
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

    func testSearchRanksUpcomingAscendingThenPastDescendingAndIgnoresCaseDiacriticsAndTombstones() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12)))

        let pastOld = try CalendarItem(title: "Café review", start: now.addingTimeInterval(-93_600), end: now.addingTimeInterval(-90_000))
        let pastRecent = try CalendarItem(title: "cafe planning", start: now.addingTimeInterval(-90_000), end: now.addingTimeInterval(-86_400))
        let upcomingFar = try CalendarItem(title: "CAFE sync", start: now.addingTimeInterval(7_200), end: now.addingTimeInterval(10_800))
        let upcomingSoon = try CalendarItem(title: "Team cafe", start: now.addingTimeInterval(1_800), end: now.addingTimeInterval(3_600))
        let tombstone = try CalendarItem(title: "cafe ghost", start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_200)).deleting(at: now)
        let unrelated = try CalendarItem(title: "Gym", start: now.addingTimeInterval(900), end: now.addingTimeInterval(1_800))

        let results = CalendarSearch.results(
            matching: "  CAFe ",
            in: [upcomingFar, pastOld, tombstone, unrelated, pastRecent, upcomingSoon],
            calendar: calendar,
            now: now
        )

        XCTAssertEqual(results.map(\.title), ["Team cafe", "CAFE sync", "cafe planning", "Café review"])
    }

    func testSearchReturnsNothingForBlankQuery() throws {
        let item = try CalendarItem(title: "Standup", start: base, end: base.addingTimeInterval(600))
        XCTAssertTrue(CalendarSearch.results(matching: "", in: [item]).isEmpty)
        XCTAssertTrue(CalendarSearch.results(matching: "   ", in: [item]).isEmpty)
        XCTAssertTrue(CalendarSearch.results(matching: "nonexistent", in: [item]).isEmpty)
    }

    func testRecentItemsRankByLatestActivityAndCapAtFive() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 20, hour: 9)))
        func dated(_ title: String, created: TimeInterval, updated: TimeInterval, startOffset: TimeInterval = 0) throws -> CalendarItem {
            try CalendarItem(
                title: title,
                start: day.addingTimeInterval(startOffset),
                end: day.addingTimeInterval(startOffset + 600),
                createdAt: day.addingTimeInterval(created),
                updatedAt: day.addingTimeInterval(updated)
            )
        }

        // Activity is the later of created/updated: an old item edited
        // yesterday outranks a new item never touched since creation.
        let editedOld = try dated("edited old", created: -10_000, updated: -3_600)
        let freshUntouched = try dated("fresh untouched", created: -7_200, updated: -7_200)
        let justCreated = try dated("just created", created: -60, updated: -60)
        let tombstoned = try dated("tombstoned", created: -30, updated: -30).deleting(at: day)
        // Ties break deterministically by ascending id.
        let tieA = try CalendarItem(
            id: UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!,
            title: "tie a",
            start: day,
            end: day.addingTimeInterval(600),
            createdAt: day.addingTimeInterval(-5_000),
            updatedAt: day.addingTimeInterval(-5_000)
        )
        let tieB = try CalendarItem(
            id: UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!,
            title: "tie b",
            start: day.addingTimeInterval(700),
            end: day.addingTimeInterval(1_300),
            createdAt: day.addingTimeInterval(-5_000),
            updatedAt: day.addingTimeInterval(-5_000)
        )

        let recents = CalendarSearch.recentItems(
            in: [freshUntouched, tombstoned, editedOld, justCreated, tieB, tieA],
            limit: 5,
            now: day
        )

        XCTAssertEqual(recents.map(\.title), ["just created", "edited old", "tie a", "tie b", "fresh untouched"])
        XCTAssertEqual(recents.count, 5)
    }

    func testRecentItemsFallBackToNextUpcomingWithoutUsableTimestamps() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 12)))
        let distantPast = Date.distantPast
        func stampless(_ title: String, start: Date) throws -> CalendarItem {
            // createdAt == updatedAt == .distantPast models an import whose
            // activity timestamps are unavailable.
            try CalendarItem(id: UUID(), title: title, start: start, end: start.addingTimeInterval(600), createdAt: distantPast, updatedAt: distantPast)
        }
        let laterToday = try stampless("later today", start: now.addingTimeInterval(3_600))
        let sooner = try stampless("sooner", start: now.addingTimeInterval(600))
        let alreadyPast = try stampless("already past", start: now.addingTimeInterval(-600))

        let recents = CalendarSearch.recentItems(
            in: [laterToday, alreadyPast, sooner],
            limit: 5,
            now: now
        )

        XCTAssertEqual(recents.map(\.title), ["sooner", "later today"])
    }

    func testSearchNavigationDayMapsResultToPagerDayStart() throws {
        let calendar = berlinCalendar()
        let lateEvening = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 31, hour: 23, minute: 45)))
        let item = try CalendarItem(title: "Silvester", start: lateEvening, end: lateEvening.addingTimeInterval(900))

        let navigationDay = CalendarSearch.navigationDay(for: item, calendar: calendar)

        XCTAssertEqual(calendar.startOfDay(for: navigationDay), navigationDay)
        XCTAssertEqual(calendar.component(.year, from: navigationDay), 2026)
        XCTAssertEqual(calendar.component(.month, from: navigationDay), 12)
        XCTAssertEqual(calendar.component(.day, from: navigationDay), 31)
    }

    private func berlinCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        return calendar
    }

    func testRecurrenceExpansionPreservesWallClockAcrossDSTSpringForward() throws {
        let calendar = berlinCalendar()
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 28, hour: 9)))
        let rule = try CalendarRecurrenceRule(frequency: .daily)
        let item = try CalendarItem(title: "Morning sync", start: anchor, end: anchor.addingTimeInterval(1_800), recurrence: rule)
        let windowStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 27)))
        let windowEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 4, day: 1, hour: 12)))

        let occurrences = CalendarRecurrence.occurrences(
            of: item,
            overlapping: DateInterval(start: windowStart, end: windowEnd),
            calendar: calendar
        )

        // Anchor plus Mar 29-31 and Apr 1: five daily instances, each at
        // 09:00 wall-clock even though Mar 29 only has 23 hours.
        XCTAssertEqual(occurrences.count, 5)
        XCTAssertEqual(occurrences.first, item)
        for occurrence in occurrences.dropFirst() {
            XCTAssertEqual(calendar.component(.hour, from: occurrence.start), 9)
            XCTAssertEqual(calendar.component(.minute, from: occurrence.start), 0)
            XCTAssertEqual(occurrence.occurrenceSourceID, item.id)
            XCTAssertNil(try XCTUnwrap(occurrences.last).recurrence?.until)
        }
    }

    func testMonthlyRecurrenceClampsToLastValidDayWithoutCompoundingDrift() throws {
        let calendar = berlinCalendar()
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 10)))
        let rule = try CalendarRecurrenceRule(frequency: .monthly)
        let item = try CalendarItem(title: "Month-end review", start: anchor, end: anchor.addingTimeInterval(3_600), recurrence: rule)
        let windowStart = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1)))
        let windowEnd = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 5, day: 1)))

        let occurrences = CalendarRecurrence.occurrences(
            of: item,
            overlapping: DateInterval(start: windowStart, end: windowEnd),
            calendar: calendar
        )

        // Jan 31, Feb 28 (clamped), Mar 31, Apr 30 — always recomputed from
        // the anchor, so the clamped February step cannot shift March.
        XCTAssertEqual(occurrences.map { calendar.component(.day, from: $0.start) }, [31, 28, 31, 30])
    }

    func testBiweeklyRecurrenceHonorsInclusiveUntilBoundaryAndWindowClip() throws {
        let calendar = berlinCalendar()
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 5, hour: 18)))
        let until = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 2, hour: 18)))
        let rule = try CalendarRecurrenceRule(frequency: .weekly, interval: 2, until: until)
        let item = try CalendarItem(title: "Fortnightly", start: anchor, end: anchor.addingTimeInterval(3_600), recurrence: rule)

        let all = CalendarRecurrence.occurrences(of: item, overlapping: nil, calendar: calendar)
        // Sep 2 18:00 equals `until` exactly; the boundary is inclusive.
        XCTAssertEqual(all.map { calendar.component(.day, from: $0.start) }, [5, 19, 2])

        let lateWindow = DateInterval(
            start: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15))),
            end: try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 20)))
        )
        let clipped = CalendarRecurrence.occurrences(of: item, overlapping: lateWindow, calendar: calendar)
        XCTAssertEqual(clipped.map { calendar.component(.day, from: $0.start) }, [19, 2])

        let exclusiveUntil = try CalendarRecurrenceRule(frequency: .weekly, interval: 2, until: until.addingTimeInterval(-1))
        let strictItem = try CalendarItem(title: "Fortnightly strict", start: anchor, end: anchor.addingTimeInterval(3_600), recurrence: exclusiveUntil)
        let strict = CalendarRecurrence.occurrences(of: strictItem, overlapping: nil, calendar: calendar)
        XCTAssertEqual(strict.map { calendar.component(.day, from: $0.start) }, [5, 19])
    }

    func testOpenEndedDailyRecurrenceStopsAtEngineCapAndNonRecurringExpandsToSelf() throws {
        let calendar = berlinCalendar()
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2020, month: 1, day: 1, hour: 7)))
        let repeating = try CalendarItem(
            title: "Every day forever",
            start: anchor,
            end: anchor.addingTimeInterval(600),
            recurrence: CalendarRecurrenceRule(frequency: .daily)
        )
        let plain = try CalendarItem(title: "One off", start: anchor, end: anchor.addingTimeInterval(600))

        XCTAssertEqual(CalendarRecurrence.occurrences(of: repeating, overlapping: nil, calendar: calendar).count,
                       CalendarRecurrence.maximumOccurrencesPerItem)
        XCTAssertEqual(CalendarRecurrence.occurrences(of: plain, overlapping: nil, calendar: calendar), [plain])
        XCTAssertTrue(CalendarRecurrence.occurrences(
            of: plain.deleting(at: anchor),
            overlapping: nil,
            calendar: calendar
        ).isEmpty)
    }

    func testDistantHistoricalAnchorsFindOnlyInWindowOccurrencesForEveryFrequency() throws {
        let calendar = berlinCalendar()
        let cases: [(frequency: CalendarRecurrenceFrequency, anchor: Date, expected: Date)] = [
            (
                .daily,
                try XCTUnwrap(calendar.date(from: DateComponents(year: 1, month: 1, day: 1, hour: 9))),
                try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 23, hour: 9)))
            ),
            (
                .weekly,
                try XCTUnwrap(calendar.date(from: DateComponents(year: 1900, month: 1, day: 1, hour: 9))),
                try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 24, hour: 9)))
            ),
            (
                .monthly,
                try XCTUnwrap(calendar.date(from: DateComponents(year: 1900, month: 1, day: 1, hour: 9))),
                try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 9)))
            ),
            (
                .yearly,
                try XCTUnwrap(calendar.date(from: DateComponents(year: 1900, month: 1, day: 1, hour: 9))),
                try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 9)))
            )
        ]

        for (frequency, anchor, expected) in cases {
            let item = try CalendarItem(
                title: "Historical \(frequency.rawValue)",
                start: anchor,
                end: anchor.addingTimeInterval(1_800),
                recurrence: CalendarRecurrenceRule(frequency: frequency)
            )
            let day = calendar.startOfDay(for: expected)
            let windowEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
            let occurrences = CalendarRecurrence.occurrences(
                of: item,
                overlapping: DateInterval(start: day, end: windowEnd),
                calendar: calendar
            )

            XCTAssertEqual(occurrences.count, 1, "Unexpected \(frequency.rawValue) occurrence count")
            XCTAssertEqual(occurrences.first?.start, expected, "Unexpected \(frequency.rawValue) occurrence start")
            XCTAssertEqual(occurrences.first?.occurrenceSourceID, item.id)
        }
    }

    func testRecurrenceCodableRoundTripLegacyPayloadAndTransientOccurrenceIdentity() throws {
        let calendar = berlinCalendar()
        let anchor = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 1, hour: 8)))
        let until = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 12, day: 24)))
        let rule = try CalendarRecurrenceRule(frequency: .weekly, interval: 3, until: until)
        let item = try CalendarItem(title: "Retro", start: anchor, end: anchor.addingTimeInterval(3_600), recurrence: rule)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let data = try encoder.encode(item)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object["recurrence"])
        XCTAssertNil(object["occurrenceSourceID"], "Derived-instance identity is transient and must never persist")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let decoded = try decoder.decode(CalendarItem.self, from: data)
        XCTAssertEqual(decoded.recurrence, rule)
        XCTAssertEqual(decoded.occurrenceSourceID, nil)

        // A legacy payload written before the field existed still decodes.
        var legacy = object
        legacy.removeValue(forKey: "recurrence")
        let legacyData = try JSONSerialization.data(withJSONObject: legacy)
        let legacyItem = try decoder.decode(CalendarItem.self, from: legacyData)
        XCTAssertNil(legacyItem.recurrence)

        // Derived copies keep the anchor id family but flag their source.
        let occurrences = CalendarRecurrence.occurrences(of: item, overlapping: nil, calendar: calendar)
        let derived = occurrences.dropFirst().first
        XCTAssertEqual(derived?.occurrenceSourceID, item.id)
        XCTAssertNotEqual(derived?.start, item.start)
    }

    func testUpdatingReplacesAndClearsRecurrenceExplicitly() throws {
        let start = base
        let original = try CalendarItem(
            title: "Series",
            start: start,
            end: start.addingTimeInterval(600),
            createdAt: start,
            updatedAt: start,
            recurrence: CalendarRecurrenceRule(frequency: .daily)
        )
        let replaced = try original.updating(
            at: start,
            recurrence: CalendarRecurrenceRule(frequency: .weekly, interval: 2)
        )
        XCTAssertEqual(replaced.recurrence?.frequency, .weekly)
        XCTAssertEqual(replaced.recurrence?.interval, 2)

        let cleared = try replaced.updating(at: start, clearRecurrence: true)
        XCTAssertNil(cleared.recurrence)

        let invalid = try? CalendarRecurrenceRule(frequency: .daily, interval: 0)
        XCTAssertNil(invalid)
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

    func testRemoteMergeRejectsFutureUpdatedAndDeletedAtValues() throws {
        let now = base.addingTimeInterval(1_000)
        let future = now.addingTimeInterval(CalendarRemoteMergePolicy.maximumClockSkew + 1)
        let futureUpdate = try CalendarItem(
            title: "future update",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: future
        )
        let futureDeletion = try CalendarItem(
            title: "future deletion",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: future,
            deletedAt: future
        )

        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [futureUpdate, futureDeletion]),
            against: CalendarSnapshot(),
            now: now
        )

        XCTAssertTrue(report.snapshot.items.isEmpty)
        XCTAssertEqual(report.rejectedItemCount, 2)
        XCTAssertEqual(report.rejectedDeletionCount, 1)
    }

    func testRemoteMergeQuarantinesStaleMutationForExistingIdentity() throws {
        let id = UUID()
        let current = try CalendarItem(
            id: id,
            title: "local",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(20)
        )
        let stale = try CalendarItem(
            id: id,
            title: "stale remote",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(19)
        )

        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [stale]),
            against: CalendarSnapshot(items: [current]),
            now: base.addingTimeInterval(30)
        )

        XCTAssertTrue(report.snapshot.items.isEmpty)
        XCTAssertEqual(report.rejectedItemCount, 1)
        XCTAssertEqual(report.rejectedDeletionCount, 0)
    }

    func testRemoteMergeRejectsStaleEnvelopeTimestamp() throws {
        let remote = try CalendarItem(
            title: "remote",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [remote]),
            against: CalendarSnapshot(),
            now: base.addingTimeInterval(CalendarRemoteMergePolicy.maximumClockSkew + 1),
            sentAt: base
        )

        XCTAssertTrue(report.snapshot.items.isEmpty)
        XCTAssertTrue(report.rejectedEnvelope)
        XCTAssertEqual(report.rejectedItemCount, 1)
    }

    @MainActor
    func testFutureRemoteMutationsAreQuarantinedBeforeLocalEditPersists() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let now = base.addingTimeInterval(100)
        let future = now.addingTimeInterval(240)
        let localUpdateID = UUID()
        let localDeleteID = UUID()
        let localUpdate = try CalendarItem(
            id: localUpdateID,
            title: "local update",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let localDelete = try CalendarItem(
            id: localDeleteID,
            title: "local delete",
            start: base.addingTimeInterval(120),
            end: base.addingTimeInterval(180),
            createdAt: base,
            updatedAt: base
        )
        let futureUpdate = try CalendarItem(
            id: localUpdateID,
            title: "future overwrite",
            start: localUpdate.start,
            end: localUpdate.end,
            createdAt: localUpdate.createdAt,
            updatedAt: future
        )
        let futureDeletion = localDelete.deleting(at: future)
        let coordinator = CalendarCoordinator(storeURL: directory.appendingPathComponent("calendar.json"))

        let updateSave = await coordinator.save(localUpdate)
        let deleteSave = await coordinator.save(localDelete)
        XCTAssertEqual(updateSave, .success)
        XCTAssertEqual(deleteSave, .success)
        let mergeResult = await coordinator.merge(
            CalendarSnapshot(items: [futureUpdate, futureDeletion]),
            now: now
        )
        XCTAssertEqual(mergeResult, .success)

        let editedUpdate = try localUpdate.updating(title: "local edit wins", at: now.addingTimeInterval(1))
        let editedDelete = try localDelete.updating(title: "local delete edit wins", at: now.addingTimeInterval(1))
        let editedUpdateSave = await coordinator.save(editedUpdate)
        let editedDeleteSave = await coordinator.save(editedDelete)
        XCTAssertEqual(editedUpdateSave, .success)
        XCTAssertEqual(editedDeleteSave, .success)

        let persisted = try await coordinator.store.load()
        XCTAssertEqual(persisted.items.first(where: { $0.id == localUpdateID })?.title, "local edit wins")
        XCTAssertEqual(persisted.items.first(where: { $0.id == localDeleteID })?.title, "local delete edit wins")
        XCTAssertFalse(persisted.items.contains { $0.isDeleted })
    }

    func testRemoteMergeAcceptsValidMatchingTombstone() throws {
        let current = try CalendarItem(
            title: "meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(10)
        )
        let tombstone = current.deleting(at: base.addingTimeInterval(20))

        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [tombstone]),
            against: CalendarSnapshot(items: [current]),
            now: base.addingTimeInterval(30)
        )

        XCTAssertEqual(report.snapshot.items, [tombstone])
        XCTAssertEqual(report.acceptedDeletionCount, 1)
        XCTAssertEqual(report.rejectedDeletionCount, 0)
    }

    func testRemoteMergeUsesTransportPrecisionForIdentityAfterRoundTrip() throws {
        let id = UUID()
        let createdAt = base.addingTimeInterval(0.75)
        let local = try CalendarItem(
            id: id,
            title: "local title",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: createdAt,
            updatedAt: base.addingTimeInterval(1.75)
        )
        let remote = try CalendarItem(
            id: id,
            title: "remote edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: createdAt,
            updatedAt: base.addingTimeInterval(3.75)
        )

        let wireData = try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote]))
        let received = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: wireData)
        let receivedItem = try XCTUnwrap(received.items.first)

        XCTAssertEqual(
            receivedItem.createdAt.timeIntervalSince1970,
            local.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertEqual(receivedItem.createdAt.timeIntervalSince1970, local.createdAt.timeIntervalSince1970, accuracy: 0.000_001)

        let report = CalendarRemoteMergePolicy.sanitize(
            received,
            against: CalendarSnapshot(items: [local]),
            now: base.addingTimeInterval(30)
        )

        XCTAssertEqual(report.snapshot.items.first?.title, "remote edit")
        XCTAssertEqual(report.rejectedItemCount, 0)
    }

    func testRemoteMergeAcceptsLegacyWholeSecondCreationIdentityForEditAndDeletion() throws {
        let id = UUID()
        let local = try CalendarItem(
            id: id,
            title: "local",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base.addingTimeInterval(0.375),
            updatedAt: base.addingTimeInterval(1.375)
        )
        let legacyEdit = try CalendarItem(
            id: id,
            title: "legacy edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(2.375)
        )
        let editReport = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [legacyEdit]),
            against: CalendarSnapshot(items: [local]),
            now: base.addingTimeInterval(10)
        )
        XCTAssertEqual(editReport.snapshot.items, [legacyEdit])
        XCTAssertEqual(editReport.rejectedItemCount, 0)

        let legacyDeletion = try CalendarItem(
            id: id,
            title: "legacy edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(3.375),
            deletedAt: base.addingTimeInterval(3.375)
        )
        let deletionReport = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [legacyDeletion]),
            against: CalendarSnapshot(items: [local]),
            now: base.addingTimeInterval(10)
        )
        XCTAssertEqual(deletionReport.snapshot.items, [legacyDeletion])
        XCTAssertEqual(deletionReport.acceptedDeletionCount, 1)
        XCTAssertEqual(deletionReport.rejectedDeletionCount, 0)
    }

    func testRemoteMergeAcceptsFractionalCreationRoundTripAndRejectsUnrelatedSameSecondIdentity() throws {
        let id = UUID()
        let createdAt = base.addingTimeInterval(0.1234567)
        let local = try CalendarItem(
            id: id,
            title: "local",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: createdAt,
            updatedAt: base.addingTimeInterval(1)
        )
        let remote = try CalendarItem(
            id: id,
            title: "round trip edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: createdAt,
            updatedAt: base.addingTimeInterval(2)
        )
        let wire = try JSONEncoder.calendar.encode(CalendarSnapshot(items: [remote]))
        let received = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: wire)
        let roundTripReport = CalendarRemoteMergePolicy.sanitize(
            received,
            against: CalendarSnapshot(items: [local]),
            now: base.addingTimeInterval(10)
        )
        XCTAssertEqual(roundTripReport.snapshot.items.count, 1)
        XCTAssertEqual(roundTripReport.snapshot.items.first?.title, "round trip edit")

        let unrelated = try CalendarItem(
            id: id,
            title: "unrelated",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base.addingTimeInterval(0.75),
            updatedAt: base.addingTimeInterval(3)
        )
        let unrelatedReport = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [unrelated]),
            against: CalendarSnapshot(items: [local]),
            now: base.addingTimeInterval(10)
        )
        XCTAssertTrue(unrelatedReport.snapshot.items.isEmpty)
        XCTAssertEqual(unrelatedReport.rejectedItemCount, 1)
    }

    func testRemoteMergeConvergesEqualClockNonDeletionConflicts() throws {
        let id = UUID()
        let left = try CalendarItem(
            id: id,
            title: "left",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(5)
        )
        let right = try CalendarItem(
            id: id,
            title: "right",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(5)
        )
        let winner = try XCTUnwrap(CalendarSnapshot(items: [left, right]).items.first)
        let loser = winner == left ? right : left

        let winnerReport = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [winner]),
            against: CalendarSnapshot(items: [loser]),
            now: base.addingTimeInterval(10)
        )
        XCTAssertEqual(winnerReport.snapshot.items, [winner])
        XCTAssertEqual(winnerReport.rejectedItemCount, 0)

        let loserReport = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [loser]),
            against: CalendarSnapshot(items: [winner]),
            now: base.addingTimeInterval(10)
        )
        XCTAssertTrue(loserReport.snapshot.items.isEmpty)
        XCTAssertEqual(loserReport.rejectedItemCount, 1)
    }

    func testRemoteMergeConvergesEqualClockEditAndDeletionInBothDirections() throws {
        let id = UUID()
        let clock = base.addingTimeInterval(5)
        let edit = try CalendarItem(
            id: id,
            title: "edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: clock
        )
        let deletion = try CalendarItem(
            id: id,
            title: "edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: clock,
            deletedAt: clock
        )
        let left = CalendarSnapshot(items: [edit])
        let right = CalendarSnapshot(items: [deletion])

        let leftReport = CalendarRemoteMergePolicy.sanitize(right, against: left, now: base.addingTimeInterval(10))
        let rightReport = CalendarRemoteMergePolicy.sanitize(left, against: right, now: base.addingTimeInterval(10))
        let leftConverged = left.merged(with: leftReport.snapshot)
        let rightConverged = right.merged(with: rightReport.snapshot)

        XCTAssertEqual(leftConverged, rightConverged)
        XCTAssertEqual(leftConverged, CalendarSnapshot(items: [edit, deletion]))
        XCTAssertEqual(leftReport.rejectedItemCount + rightReport.rejectedItemCount, 1)
        XCTAssertEqual(
            leftReport.acceptedDeletionCount + rightReport.acceptedDeletionCount,
            leftConverged.items.first?.isDeleted == true ? 1 : 0
        )

        let reloadedLeft = try JSONDecoder.calendar.decode(
            CalendarSnapshot.self,
            from: JSONEncoder.calendar.encode(leftConverged)
        )
        let reloadedRight = try JSONDecoder.calendar.decode(
            CalendarSnapshot.self,
            from: JSONEncoder.calendar.encode(rightConverged)
        )
        XCTAssertEqual(reloadedLeft, reloadedRight)
    }

    func testRemoteMergeConvergesEqualClockWithSubsequentlyUpdatedTombstone() throws {
        let id = UUID()
        let clock = base.addingTimeInterval(5)
        let edit = try CalendarItem(
            id: id,
            title: "edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: clock
        )
        let original = try CalendarItem(
            id: id,
            title: "edit",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let tombstone = try original
            .deleting(at: clock.addingTimeInterval(-1))
            .updating(at: clock.addingTimeInterval(1))
        var left = CalendarSnapshot(items: [edit])
        var right = CalendarSnapshot(items: [tombstone])

        for _ in 0..<3 {
            let leftIncoming = CalendarRemoteMergePolicy.sanitize(right, against: left, now: base.addingTimeInterval(10))
            let rightIncoming = CalendarRemoteMergePolicy.sanitize(left, against: right, now: base.addingTimeInterval(10))
            left = left.merged(with: leftIncoming.snapshot)
            right = right.merged(with: rightIncoming.snapshot)
        }

        XCTAssertEqual(left, right)
        XCTAssertEqual(left, CalendarSnapshot(items: [edit]))
        let reloaded = try JSONDecoder.calendar.decode(
            CalendarSnapshot.self,
            from: JSONEncoder.calendar.encode(left)
        )
        XCTAssertEqual(reloaded, right)
    }

    func testRemoteMergeConvergesEqualClockDeletionConflictsInBothDirections() throws {
        let id = UUID()
        let clock = base.addingTimeInterval(5)
        let first = try CalendarItem(
            id: id,
            title: "first deletion",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: clock,
            deletedAt: clock
        )
        let second = try CalendarItem(
            id: id,
            title: "second deletion",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: clock,
            deletedAt: clock
        )
        let left = CalendarSnapshot(items: [first])
        let right = CalendarSnapshot(items: [second])
        let leftReport = CalendarRemoteMergePolicy.sanitize(right, against: left, now: base.addingTimeInterval(10))
        let rightReport = CalendarRemoteMergePolicy.sanitize(left, against: right, now: base.addingTimeInterval(10))

        XCTAssertEqual(left.merged(with: leftReport.snapshot), right.merged(with: rightReport.snapshot))
        XCTAssertEqual(left.merged(with: leftReport.snapshot), CalendarSnapshot(items: [first, second]))
        XCTAssertEqual(leftReport.acceptedDeletionCount + rightReport.acceptedDeletionCount, 1)
        XCTAssertEqual(leftReport.rejectedDeletionCount + rightReport.rejectedDeletionCount, 1)
    }

    func testEqualDeletionClockUsesAllPersistedFieldsAsFinalTieBreak() throws {
        let id = UUID()
        let deletionClock = base.addingTimeInterval(5)
        let first = try CalendarItem(
            id: id,
            title: "first tombstone",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: deletionClock,
            deletedAt: deletionClock
        )
        let second = try CalendarItem(
            id: id,
            title: "first tombstone",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: deletionClock.addingTimeInterval(1),
            deletedAt: deletionClock
        )

        let left = CalendarSnapshot(items: [first])
        let right = CalendarSnapshot(items: [second])
        let leftMerged = left.merged(with: right)
        let rightMerged = right.merged(with: left)

        XCTAssertEqual(leftMerged, rightMerged)
        XCTAssertEqual(leftMerged.items.count, 1)
        XCTAssertEqual(leftMerged.items.first?.updatedAt, deletionClock.addingTimeInterval(1))

        let reloaded = try JSONDecoder.calendar.decode(
            CalendarSnapshot.self,
            from: JSONEncoder.calendar.encode(leftMerged)
        )
        XCTAssertEqual(reloaded, rightMerged)

        let noDeadline = try CalendarItem(
            id: id,
            title: "same tombstone",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: deletionClock,
            deletedAt: deletionClock,
            recurrence: try CalendarRecurrenceRule(frequency: .daily)
        )
        let epochDeadline = try CalendarItem(
            id: id,
            title: "same tombstone",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: deletionClock,
            deletedAt: deletionClock,
            recurrence: try CalendarRecurrenceRule(
                frequency: .daily,
                until: Date(timeIntervalSince1970: 0)
            )
        )
        let noDeadlineSnapshot = CalendarSnapshot(items: [noDeadline])
        let epochDeadlineSnapshot = CalendarSnapshot(items: [epochDeadline])
        XCTAssertEqual(
            noDeadlineSnapshot.merged(with: epochDeadlineSnapshot),
            epochDeadlineSnapshot.merged(with: noDeadlineSnapshot)
        )
        let recurrenceMerged = noDeadlineSnapshot.merged(with: epochDeadlineSnapshot)
        let recurrenceReloaded = try JSONDecoder.calendar.decode(
            CalendarSnapshot.self,
            from: JSONEncoder.calendar.encode(recurrenceMerged)
        )
        XCTAssertEqual(recurrenceReloaded, recurrenceMerged)
    }

    func testRetiredPeerMutationTokenCannotPersistAtStoreCommitBoundary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CalendarStore(url: directory.appendingPathComponent("calendar.json"))
        let local = try CalendarItem(
            title: "local",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let remote = try local.updating(title: "remote", at: base.addingTimeInterval(1))
        _ = try await store.save(CalendarSnapshot(items: [local]))

        let fence = CalendarPeerMutationFence()
        fence.activate()
        let token = try XCTUnwrap(fence.capture())
        fence.invalidate()

        do {
            _ = try await store.merge(
                CalendarSnapshot(items: [remote]),
                authorizedBy: fence,
                token: token
            )
            XCTFail("A retired peer token must not reach the durable write")
        } catch {
            XCTAssertEqual(error as? CalendarPeerMutationFenceError, .revoked)
        }
        let persisted = try await store.load()
        XCTAssertEqual(persisted, CalendarSnapshot(items: [local]))
    }

    func testRemoteDeletionKeepsSubsecondMutationOrderingAfterRoundTrip() throws {
        let id = UUID()
        let original = try CalendarItem(
            id: id,
            title: "meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let edited = try original.updating(title: "edited", at: base.addingTimeInterval(0.25))
        let deleted = edited.deleting(at: base.addingTimeInterval(0.75))
        let wireData = try JSONEncoder.calendar.encode(CalendarSnapshot(items: [deleted]))
        let received = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: wireData)
        let receivedDeletion = try XCTUnwrap(received.items.first)
        let receivedDeletedAt = try XCTUnwrap(receivedDeletion.deletedAt)
        let deletedAt = try XCTUnwrap(deleted.deletedAt)

        XCTAssertEqual(receivedDeletion.updatedAt.timeIntervalSince1970, deleted.updatedAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(receivedDeletedAt.timeIntervalSince1970, deletedAt.timeIntervalSince1970, accuracy: 0.000_001)
        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [receivedDeletion]),
            against: CalendarSnapshot(items: [edited]),
            now: base.addingTimeInterval(2)
        )

        XCTAssertEqual(report.snapshot.items, [receivedDeletion])
        XCTAssertEqual(report.acceptedDeletionCount, 1)
        XCTAssertEqual(report.rejectedDeletionCount, 0)
    }

    func testRemoteMergeRejectsMismatchedIdentityAndInvalidDeletionCausalityButRetainsUnseenTombstone() throws {
        let id = UUID()
        let current = try CalendarItem(
            id: id,
            title: "meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(10)
        )
        let causalID = UUID()
        let causalCurrent = try CalendarItem(
            id: causalID,
            title: "causal meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(10)
        )
        let mismatchedIdentity = try CalendarItem(
            id: id,
            title: "meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base.addingTimeInterval(1),
            updatedAt: base.addingTimeInterval(20),
            deletedAt: base.addingTimeInterval(20)
        )
        let causallyInvalid = try CalendarItem(
            id: causalID,
            title: "another meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(20),
            deletedAt: base.addingTimeInterval(5)
        )
        let unseenTombstone = try CalendarItem(
            id: UUID(),
            title: "unseen meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(20),
            deletedAt: base.addingTimeInterval(20)
        )

        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [mismatchedIdentity, causallyInvalid, unseenTombstone]),
            against: CalendarSnapshot(items: [current, causalCurrent]),
            now: base.addingTimeInterval(30)
        )

        XCTAssertEqual(report.snapshot.items, [unseenTombstone])
        XCTAssertEqual(report.rejectedItemCount, 2)
        XCTAssertEqual(report.rejectedDeletionCount, 2)
        XCTAssertEqual(report.acceptedDeletionCount, 1)
        XCTAssertEqual(
            report.warning,
            "Calendar sync rejected 2 remote deletion(s) and preserved local records; accepted 1 remote deletion(s)."
        )
    }

    func testRemoteMergeWarningReportsActualAcceptedAndRejectedCounts() throws {
        let current = try CalendarItem(
            title: "meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(10)
        )
        let acceptedTombstone = current.deleting(at: base.addingTimeInterval(20))
        let acceptedUnseenTombstone = try CalendarItem(
            id: UUID(),
            title: "unseen meeting",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(30),
            deletedAt: base.addingTimeInterval(30)
        )
        let future = base.addingTimeInterval(1_000)
        let rejectedUpdate = try CalendarItem(
            title: "future update",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: future
        )
        let rejectedDeletion = try CalendarItem(
            title: "future deletion",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: future,
            deletedAt: future
        )
        let report = CalendarRemoteMergePolicy.sanitize(
            CalendarSnapshot(items: [acceptedTombstone, acceptedUnseenTombstone, rejectedUpdate, rejectedDeletion]),
            against: CalendarSnapshot(items: [current]),
            now: base.addingTimeInterval(100)
        )

        XCTAssertEqual(report.rejectedItemCount, 2)
        XCTAssertEqual(report.rejectedDeletionCount, 1)
        XCTAssertEqual(report.acceptedDeletionCount, 2)
        XCTAssertEqual(
            report.warning,
            "Calendar sync rejected 1 remote deletion(s) and preserved local records; ignored 1 remote change(s) with invalid timestamps or identity; accepted 2 remote deletion(s)."
        )
    }

    func testNearbyDiscoveryPolicyDefaultsToOffAndFixturesAlwaysDenyIt() {
        let suiteName = "LifeOS.CalendarDomainTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertFalse(CalendarNearbyDiscoveryPolicy.isEnabled(in: defaults))
        XCTAssertFalse(CalendarNearbyDiscoveryPolicy.allowsDiscovery(
            usesVisualFixtures: false,
            settingEnabled: CalendarNearbyDiscoveryPolicy.isEnabled(in: defaults)
        ))

        defaults.set(true, forKey: CalendarNearbyDiscoveryPolicy.defaultsKey)
        XCTAssertTrue(CalendarNearbyDiscoveryPolicy.isEnabled(in: defaults))
        XCTAssertTrue(CalendarNearbyDiscoveryPolicy.allowsDiscovery(
            usesVisualFixtures: false,
            settingEnabled: CalendarNearbyDiscoveryPolicy.isEnabled(in: defaults)
        ))
        XCTAssertFalse(CalendarNearbyDiscoveryPolicy.allowsDiscovery(usesVisualFixtures: true, settingEnabled: true))
    }

    func testSnapshotRoundTrip() throws {
        let item = try CalendarItem(title: "round trip", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let data = try JSONEncoder().encode(CalendarSnapshot(items: [item]))
        XCTAssertEqual(try JSONDecoder().decode(CalendarSnapshot.self, from: data), CalendarSnapshot(items: [item]))
    }

    func testSnapshotRejectsUnsupportedVersionsAndUnboundedItemLists() throws {
        var unsupported = CalendarSnapshot()
        unsupported.schemaVersion = CalendarSnapshot.currentSchemaVersion + 1
        XCTAssertThrowsError(try unsupported.validatedForPersistence()) { error in
            XCTAssertEqual(error as? CalendarSnapshotError, .unsupportedSchemaVersion(2))
        }

        let items = try (0..<CalendarSnapshot.maximumItemCount + 1).map { index in
            try CalendarItem(
                title: "item \(index)",
                start: base.addingTimeInterval(Double(index) * 60),
                end: base.addingTimeInterval(Double(index) * 60 + 30),
                createdAt: base,
                updatedAt: base
            )
        }
        XCTAssertThrowsError(try JSONDecoder().decode(
            CalendarSnapshot.self,
            from: JSONEncoder().encode(CalendarSnapshot(items: items))
        )) { error in
            XCTAssertEqual(error as? CalendarSnapshotError, .tooManyItems)
        }
    }

    func testSnapshotDeduplicatesInMemoryButRejectsRepeatedIDsOnDecode() throws {
        let id = UUID()
        let older = try CalendarItem(
            id: id,
            title: "older",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let newer = try CalendarItem(
            id: id,
            title: "newer",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base.addingTimeInterval(1)
        )

        let normalized = CalendarSnapshot(items: [older, newer])
        XCTAssertEqual(normalized.items.count, 1)
        XCTAssertEqual(normalized.items.first?.title, "newer")

        var malformed = CalendarSnapshot()
        malformed.items = [newer, older]
        let merged = malformed.merged(with: CalendarSnapshot())
        XCTAssertEqual(merged.items.count, 1)
        XCTAssertEqual(merged.items.first?.title, "newer")

        var invalid = CalendarSnapshot()
        invalid.items = [older, newer]
        XCTAssertThrowsError(try invalid.validatedForPersistence()) { error in
            XCTAssertEqual(error as? CalendarSnapshotError, .duplicateItemID)
        }

        let duplicateItems = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode([older, newer])
        )
        let duplicatePayload: [String: Any] = [
            "schemaVersion": CalendarSnapshot.currentSchemaVersion,
            "items": duplicateItems
        ]
        XCTAssertThrowsError(try JSONDecoder().decode(
            CalendarSnapshot.self,
            from: JSONSerialization.data(withJSONObject: duplicatePayload)
        )) { error in
            XCTAssertEqual(error as? CalendarSnapshotError, .duplicateItemID)
        }
    }

    func testRecurrenceUsesStoredTimeZoneForWallClockExpansion() throws {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = DateComponents(
            calendar: berlin,
            timeZone: berlin.timeZone,
            year: 2026,
            month: 3,
            day: 22,
            hour: 9,
            minute: 0
        ).date!
        let rule = try CalendarRecurrenceRule(frequency: .daily)
        let item = try CalendarItem(
            title: "Berlin routine",
            start: start,
            end: start.addingTimeInterval(45 * 60),
            createdAt: start,
            updatedAt: start,
            timeZoneIdentifier: "Europe/Berlin",
            recurrence: rule
        )

        let occurrences = CalendarRecurrence.occurrences(
            of: item,
            overlapping: DateInterval(start: start, duration: 8 * 24 * 60 * 60),
            calendar: utc
        )
        XCTAssertGreaterThanOrEqual(occurrences.count, 8)
        XCTAssertTrue(occurrences.allSatisfy { berlin.component(.hour, from: $0.start) == 9 })
    }

    func testOriginalTimeZoneIsRetainedForExplicitEventDetailDisclosure() throws {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let item = try CalendarItem(
            title: "Travel event",
            start: start,
            end: start.addingTimeInterval(3_600),
            createdAt: start,
            updatedAt: start,
            timeZoneIdentifier: "America/New_York"
        )

        XCTAssertEqual(item.timeZoneIdentifier, "America/New_York")
        let updated = try item.updating(title: "Travel event · edited", at: start.addingTimeInterval(1))
        XCTAssertEqual(updated.timeZoneIdentifier, "America/New_York")
        let decoded = try JSONDecoder().decode(CalendarItem.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(decoded.timeZoneIdentifier, "America/New_York")
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

        let invalid = try item.updating(systemIconName: "definitely/not-a-real-symbol", at: base.addingTimeInterval(2))
        XCTAssertNil(invalid.systemIconName)

        // A newer OS may know a symbol that this receiver cannot render. Its
        // bounded name remains durable so the snapshot survives transport;
        // CalendarIconView supplies the local rendering fallback.
        let futureSymbolName = "calendar.badge.future-lifeos"
        let futureSymbol = try item.updating(systemIconName: futureSymbolName, at: base.addingTimeInterval(2))
        XCTAssertEqual(futureSymbol.systemIconName, futureSymbolName)
        XCTAssertFalse(CalendarSystemIconSupport.isAvailable(futureSymbolName))
        let snapshot = CalendarSnapshot(items: [futureSymbol])
        let decodedSnapshot = try JSONDecoder().decode(CalendarSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decodedSnapshot, snapshot)

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
        var reloads: [[String]] = []
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(items: [original]), storeURL: url,
            widgetTimelineReload: { reloads.append($0) }
        )

        let result = await coordinator.save(updated)

        if case .failure = result {} else { XCTFail("A store failure must not acknowledge a local commit") }
        XCTAssertEqual(coordinator.snapshot.items, [original])
        XCTAssertTrue(reloads.isEmpty, "A failed durable write must not reload widgets")
        XCTAssertFalse(coordinator.canUndo, "A failed local persistence must not create an undo token")
        XCTAssertNotNil(coordinator.errorMessage)
        try? FileManager.default.removeItem(at: blockingFile)
    }

    @MainActor
    func testCoordinatorTaskCompletionAndDeletionReloadAllCalendarProjectionsOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var reloads: [[String]] = []
        let coordinator = CalendarCoordinator(
            usesVisualFixtures: true,
            storeURL: directory.appendingPathComponent("calendar.json"),
            widgetTimelineReload: { reloads.append($0) }
        )
        let task = try CalendarItem(title: "Task", kind: .todo, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let saved = await coordinator.save(task)
        XCTAssertEqual(saved, .success)
        reloads.removeAll()

        let completed = try task.updatingProgress(.done, at: base.addingTimeInterval(1))
        let completion = await coordinator.save(completed)
        XCTAssertEqual(completion, .success)
        let durableCompleted = try await coordinator.store.load()
        XCTAssertEqual(durableCompleted.items, [completed])
        XCTAssertEqual(coordinator.snapshot, durableCompleted)
        let kinds = ["LifeOSCalendarWidget", "LifeOSNextEventWidget", "TasksWidget"]
        XCTAssertEqual(reloads, [kinds])

        // Re-observing or saving the same durable snapshot must not duplicate
        // the batch already requested by the successful completion.
        await coordinator.load()
        let unchanged = await coordinator.save(completed)
        XCTAssertEqual(unchanged, .success)
        let merged = await coordinator.merge(durableCompleted)
        XCTAssertEqual(merged, .success)
        XCTAssertEqual(reloads, [kinds])

        let deletion = await coordinator.delete(completed)
        XCTAssertEqual(deletion, .success)
        let durableDeleted = try await coordinator.store.load()
        XCTAssertTrue(try XCTUnwrap(durableDeleted.items.first).isDeleted)
        XCTAssertEqual(try JSONEncoder.calendar.encode(coordinator.snapshot),
                       try JSONEncoder.calendar.encode(durableDeleted))
        await coordinator.load()
        XCTAssertEqual(reloads, [kinds, kinds])

        let undo = await coordinator.undo()
        XCTAssertEqual(undo, .success)
        XCTAssertEqual(coordinator.snapshot, durableCompleted)
        XCTAssertEqual(reloads, [kinds, kinds, kinds])
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
    func testFixtureCoordinatorWithoutInjectedStoreUsesNoAppGroupAndPersistsOnlyInIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let groupURL = directory.appendingPathComponent("personal-app-group", isDirectory: true)
        try FileManager.default.createDirectory(at: groupURL, withIntermediateDirectories: true)
        let fileManager = AppGroupTestFileManager(groupURL: groupURL)
        let identifier = "group.com.hermes.lifeos.test"
        let bundleURL = directory.appendingPathComponent("FixtureHost.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let info = [
            "CFBundleIdentifier": "com.hermes.lifeos.fixture-host",
            "CFBundlePackageType": "BNDL",
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            AppGroupConfiguration.infoPlistKey: identifier
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: bundleURL.appendingPathComponent("Info.plist"))
        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        let fixture = try CalendarItem(title: "Fixture event", start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let inserted = try CalendarItem(title: "Fixture mutation", start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base.addingTimeInterval(1))
        let coordinator = CalendarCoordinator(
            bundle: bundle,
            fileManager: fileManager,
            initialSnapshot: CalendarSnapshot(items: [fixture]),
            usesVisualFixtures: true
        )

        XCTAssertEqual(fileManager.appGroupLookupCount, 0, "fixture construction must not resolve the personal App Group")
        XCTAssertFalse(coordinator.sharedStorageAvailable)
        XCTAssertEqual(coordinator.storageDescription, "Isolated fixture store")

        let saveResult = await coordinator.save(inserted)
        XCTAssertEqual(saveResult, .success)
        XCTAssertEqual(fileManager.appGroupLookupCount, 0, "fixture mutation must not look up the personal App Group")
        XCTAssertFalse(FileManager.default.fileExists(atPath: groupURL.appendingPathComponent("calendar.json").path))
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(loaded.items, [fixture, inserted])
        let storeURL = await coordinator.store.url
        XCTAssertFalse(storeURL.path.hasPrefix(groupURL.path))
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    @MainActor
    func testFixtureCalendarDefaultsStayOutOfStandardRevisionKeysAcrossSaveAndUndo() async throws {
        let standard = UserDefaults.standard
        let senderKey = "LifeOS.Calendar.senderID"
        let revisionKey = "LifeOS.Calendar.revision"
        let previousSender = standard.object(forKey: senderKey)
        let previousRevision = standard.object(forKey: revisionKey)
        let personalSender = "personal-calendar-sentinel"
        let personalRevision = 71_003
        standard.set(personalSender, forKey: senderKey)
        standard.set(personalRevision, forKey: revisionKey)
        defer {
            if let previousSender { standard.set(previousSender, forKey: senderKey) }
            else { standard.removeObject(forKey: senderKey) }
            if let previousRevision { standard.set(previousRevision, forKey: revisionKey) }
            else { standard.removeObject(forKey: revisionKey) }
        }

        let original = try CalendarItem(
            title: "Fixture original",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let inserted = try original.updating(title: "Fixture saved", at: base.addingTimeInterval(1))
        let coordinator = CalendarCoordinator(
            initialSnapshot: CalendarSnapshot(items: [original]),
            usesVisualFixtures: true
        )
        let storeURL = await coordinator.store.url
        defer { try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent()) }

        XCTAssertNotEqual(coordinator.senderID, personalSender)
        XCTAssertEqual(standard.integer(forKey: revisionKey), personalRevision)

        let saveResult = await coordinator.save(inserted)
        XCTAssertEqual(saveResult, .success)
        XCTAssertEqual(standard.integer(forKey: revisionKey), personalRevision)

        let undoResult = await coordinator.undoLastMutation()
        XCTAssertEqual(undoResult, .success)
        XCTAssertEqual(standard.integer(forKey: revisionKey), personalRevision)
        XCTAssertEqual(standard.string(forKey: senderKey), personalSender)
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
    func testExplicitSyncFetchesMergesAndRetriesConditionalMutationWithOneKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("calendar.json")
        let remote = try CalendarItem(
            title: "remote",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let remoteChange = try CalendarItem(
            title: "remote change",
            start: base.addingTimeInterval(120),
            end: base.addingTimeInterval(180),
            createdAt: base,
            updatedAt: base.addingTimeInterval(1)
        )
        let local = try CalendarItem(
            title: "local",
            start: base.addingTimeInterval(240),
            end: base.addingTimeInterval(300),
            createdAt: base,
            updatedAt: base.addingTimeInterval(2)
        )
        let initial = CalendarSnapshot(items: [remote])
        let conflict = CalendarSnapshot(items: [remote, remoteChange])
        let success = CalendarSnapshot(items: [remote, remoteChange, local])
        let initialResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(initial),
            etag: #""calendar-v1-r1-initial"#
        )
        let conflictResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(conflict),
            etag: #""calendar-v1-r2-conflict"#
        )
        let successResource = CalendarRemoteResource(
            data: try JSONEncoder.calendar.encode(success),
            etag: #""calendar-v1-r3-success"#
        )
        let script = CalendarRemoteScript(initial: initialResource, conflict: conflictResource, success: successResource)
        let coordinator = CalendarCoordinator(
            storeURL: url,
            calendarRemoteFetch: { await script.fetch() },
            calendarRemotePush: { data, etag, key in try await script.push(data: data, etag: etag, idempotencyKey: key) }
        )

        let localSaveResult = await coordinator.save(local)
        XCTAssertEqual(localSaveResult, .success)
        let beforeSync = await script.observation()
        XCTAssertEqual(beforeSync.pushCount, 0, "Local durability must not implicitly upload calendar contents")
        XCTAssertTrue(coordinator.canUndo, "An explicit remote sync should not be needed for local durability")
        let syncResult = await coordinator.syncNow()
        XCTAssertEqual(syncResult, .success)

        let observation = await script.observation()
        XCTAssertEqual(observation.fetchCount, 1)
        XCTAssertEqual(observation.pushCount, 2)
        XCTAssertEqual(observation.etags, [initialResource.etag, conflictResource.etag])
        XCTAssertEqual(Set(observation.idempotencyKeys).count, 1, "Conflict retries must replay one mutation key")
        XCTAssertEqual(observation.bodies.count, 2)
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(Set(loaded.items.map(\.id)), Set([remote.id, remoteChange.id, local.id]))
        XCTAssertNil(coordinator.syncWarning)
        XCTAssertFalse(coordinator.canUndo, "Adopting a changed authoritative resource invalidates a stale undo")
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testReplayedRemoteMergeDoesNotConsumeLocalUndo() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = CalendarCoordinator(storeURL: directory.appendingPathComponent("calendar.json"))
        let item = try CalendarItem(
            title: "local",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )

        let saveResult = await coordinator.save(item)
        XCTAssertEqual(saveResult, .success)
        XCTAssertTrue(coordinator.canUndo)
        let mergeResult = await coordinator.merge(CalendarSnapshot(items: [item]))
        XCTAssertEqual(mergeResult, .success)
        XCTAssertTrue(coordinator.canUndo, "An idempotent peer replay must not invalidate the local undo token")
        let loaded = try await coordinator.store.load()
        XCTAssertEqual(loaded, CalendarSnapshot(items: [item]))
        try? FileManager.default.removeItem(at: directory)
    }

    @MainActor
    func testEventTodoAndDailyScheduleMutationsPersistAndDeleteAsUndoableTombstone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let coordinator = CalendarCoordinator(storeURL: directory.appendingPathComponent("calendar.json"))
        let event = try CalendarItem(title: "Event", kind: .event, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        let todo = try CalendarItem(title: "To-do", kind: .todo, status: .done, start: base.addingTimeInterval(120), end: base.addingTimeInterval(180), createdAt: base, updatedAt: base.addingTimeInterval(1))
        let schedule = try CalendarItem(title: "Daily plan", kind: .dailySchedule, status: .inProgress, start: base.addingTimeInterval(240), end: base.addingTimeInterval(300), createdAt: base, updatedAt: base.addingTimeInterval(2))

        let eventSaveResult = await coordinator.save(event)
        let todoSaveResult = await coordinator.save(todo)
        let scheduleSaveResult = await coordinator.save(schedule)
        let deleteResult = await coordinator.delete(todo)
        XCTAssertEqual(eventSaveResult, .success)
        XCTAssertEqual(todoSaveResult, .success)
        XCTAssertEqual(scheduleSaveResult, .success)
        XCTAssertEqual(deleteResult, .success)

        let persisted = try await coordinator.store.load()
        XCTAssertEqual(persisted.items.count, 3)
        XCTAssertEqual(persisted.items.first(where: { $0.id == event.id })?.kind, .event)
        XCTAssertEqual(persisted.items.first(where: { $0.id == todo.id })?.kind, .todo)
        XCTAssertTrue(persisted.items.first(where: { $0.id == todo.id })?.isDeleted == true)
        XCTAssertEqual(persisted.items.first(where: { $0.id == schedule.id })?.kind, .dailySchedule)

        let undoResult = await coordinator.undo()
        XCTAssertEqual(undoResult, .success)
        let restored = try await coordinator.store.load()
        XCTAssertEqual(Set(restored.items.map(\.id)), Set([event.id, todo.id, schedule.id]))
        XCTAssertFalse(restored.items.contains(where: { $0.isDeleted }))
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

final class CalendarEditorStringLocalizationTests: XCTestCase {
    func testGermanLocaleResolvesEveryEditorSheetString() {
        XCTAssertEqual(CalendarEditorStrings.allDay(localeIdentifier: "de_DE"), "Ganztägig")
        XCTAssertEqual(CalendarEditorStrings.timezone(localeIdentifier: "de_DE"), "Zeitzone")
        XCTAssertEqual(CalendarEditorStrings.titlePlaceholder(localeIdentifier: "de_DE"), "Titel")
        XCTAssertEqual(CalendarEditorStrings.repeatLabel(localeIdentifier: "de_DE"), "Wiederholen")
        XCTAssertEqual(CalendarEditorStrings.recurrenceNone(localeIdentifier: "de_DE"), "Nie")
        XCTAssertEqual(CalendarEditorStrings.untilLabel(localeIdentifier: "de_DE"), "Bis")
        XCTAssertEqual(CalendarEditorStrings.markDone(localeIdentifier: "de_DE"), "Als erledigt markieren")
        XCTAssertEqual(CalendarEditorStrings.deleteEvent(localeIdentifier: "de_DE"), "Ereignis löschen")
        XCTAssertEqual(CalendarEditorStrings.cancel(localeIdentifier: "de_DE"), "Abbrechen")
        XCTAssertEqual(CalendarEditorStrings.save(localeIdentifier: "de_DE"), "Sichern")
    }

    func testEnglishLocalePreservesExistingEditorSheetCopy() {
        XCTAssertEqual(CalendarEditorStrings.allDay(localeIdentifier: "en_US"), "All day")
        XCTAssertEqual(CalendarEditorStrings.timezone(localeIdentifier: "en_US"), "Timezone")
        XCTAssertEqual(CalendarEditorStrings.titlePlaceholder(localeIdentifier: "en_US"), "Event title")
        XCTAssertEqual(CalendarEditorStrings.repeatLabel(localeIdentifier: "en_US"), "Repeat")
        XCTAssertEqual(CalendarEditorStrings.recurrenceNone(localeIdentifier: "en_US"), "None")
        XCTAssertEqual(CalendarEditorStrings.untilLabel(localeIdentifier: "en_US"), "Until")
        XCTAssertEqual(CalendarEditorStrings.markDone(localeIdentifier: "en_US"), "Mark done")
        XCTAssertEqual(CalendarEditorStrings.deleteEvent(localeIdentifier: "en_US"), "Delete event")
        XCTAssertEqual(CalendarEditorStrings.cancel(localeIdentifier: "en_US"), "Cancel")
        XCTAssertEqual(CalendarEditorStrings.save(localeIdentifier: "en_US"), "Save")
    }

    func testRecurrenceFrequencyLabelsAreLocalized() {
        let german = [
            CalendarRecurrenceFrequency.daily: "Täglich",
            .weekly: "Wöchentlich",
            .monthly: "Monatlich",
            .yearly: "Jährlich"
        ]
        for (frequency, expected) in german {
            XCTAssertEqual(CalendarEditorStrings.recurrence(frequency, localeIdentifier: "de_DE"), expected)
            XCTAssertEqual(CalendarEditorStrings.recurrence(frequency, localeIdentifier: "en_US"), frequency.label)
        }
    }

    func testItemKindLabelsAreLocalized() {
        let german = [
            CalendarItemKind.event: "Ereignis",
            .todo: "Aufgabe",
            .dailySchedule: "Tagesplan"
        ]
        for (kind, expected) in german {
            XCTAssertEqual(CalendarEditorStrings.kindLabel(kind, localeIdentifier: "de_DE"), expected)
            XCTAssertEqual(CalendarEditorStrings.kindLabel(kind, localeIdentifier: "en_US"), kind.label)
        }
    }

    func testProgressStatusLabelsAreLocalized() {
        let german = [
            CalendarProgress.planned: "Geplant",
            .inProgress: "In Arbeit",
            .done: "Erledigt",
            .aborted: "Abgebrochen"
        ]
        for (progress, expected) in german {
            XCTAssertEqual(CalendarEditorStrings.status(progress, localeIdentifier: "de_DE"), expected)
            XCTAssertEqual(CalendarEditorStrings.status(progress, localeIdentifier: "en_US"), progress.label)
        }
    }

    func testAnyGermanRegionPrefixResolvesGermanWhileOthersFallBackToEnglish() {
        for identifier in ["de", "de_AT", "de_CH"] {
            XCTAssertEqual(CalendarEditorStrings.allDay(localeIdentifier: identifier), "Ganztägig")
        }
        for identifier in ["en", "en_GB", "fr_FR", "es_ES", "ja_JP"] {
            XCTAssertEqual(CalendarEditorStrings.allDay(localeIdentifier: identifier), "All day")
        }
    }

    func testDurationUnitsUseGermanAbbreviations() {
        XCTAssertTrue(CalendarLayoutDurationProbe.hourUnit(localeIdentifier: "de_DE").hasPrefix("Std"))
        XCTAssertTrue(CalendarLayoutDurationProbe.minuteUnit(localeIdentifier: "de_DE").hasPrefix("Min"))
        XCTAssertEqual(CalendarLayoutDurationProbe.hourUnit(localeIdentifier: "en_US"), "hr")
        XCTAssertEqual(CalendarLayoutDurationProbe.minuteUnit(localeIdentifier: "en_US"), "min")
    }
}

enum CalendarLayoutDurationProbe {
    static func hourUnit(localeIdentifier: String) -> String {
        CalendarEditorStrings.de("Std.", "hr", localeIdentifier: localeIdentifier)
    }

    static func minuteUnit(localeIdentifier: String) -> String {
        CalendarEditorStrings.de("Min", "min", localeIdentifier: localeIdentifier)
    }
}

final class CalendarTestPeerTransport: CalendarPeerTransport {
    private var statusHandler: ((CalendarPeerConnectionStatus) -> Void)?
    private var snapshotHandler: ((CalendarPeerSyncEnvelope, String) -> Void)?
    private var pairingHandler: ((CalendarPairingState) -> Void)?

    func setStatusHandler(_ handler: @escaping (CalendarPeerConnectionStatus) -> Void) {
        statusHandler = handler
    }

    func setSnapshotHandler(_ handler: @escaping (CalendarPeerSyncEnvelope, String) -> Void) {
        snapshotHandler = handler
    }

    func setPairingHandler(_ handler: @escaping (CalendarPairingState) -> Void) {
        pairingHandler = handler
    }

    func createPairing() throws {}
    func importPairing(_ token: String) throws {}
    func confirmPairing() throws {}
    func cancelPairing() {}
    func retryPairingConnection() {}
    func start() {}
    func stop() {}
    func send(snapshot: CalendarSnapshot, senderID: String, revision: Int) throws {}

    func emitStatus(_ status: CalendarPeerConnectionStatus) {
        statusHandler?(status)
    }

    func emitSnapshot(_ envelope: CalendarPeerSyncEnvelope, authenticatedSenderID: String) {
        snapshotHandler?(envelope, authenticatedSenderID)
    }

    func emitPairing(_ state: CalendarPairingState) {
        pairingHandler?(state)
    }
}

@MainActor
final class CalendarPairingFixtureTests: XCTestCase {
    func testFixtureAndInjectedStoreRejectPairingWithoutDiscovery() async {
        for fixture in [true, false] {
            let coordinator = CalendarCoordinator(usesVisualFixtures: fixture,
                storeURL: URL(fileURLWithPath: "/tmp/lifeos-pairing-fixture/calendar.json"))
            // Transport publication is marshalled onto the main actor.
            for _ in 0..<10 { await Task.yield() }
            XCTAssertFalse(coordinator.pairingState.available)
            coordinator.startSync()
            coordinator.createPairing()
            coordinator.importPairing("not-a-token")
            coordinator.confirmPairing()
            XCTAssertNotNil(coordinator.pairingError)
            XCTAssertNil(coordinator.pairingState.outgoing)
            XCTAssertEqual(coordinator.syncStatus, .stopped)
            coordinator.cancelPairing()
            coordinator.retryPairingConnection()
            coordinator.stopSync()
            XCTAssertNil(coordinator.pairingError)
        }
    }

    func testRetiredPeerSnapshotCannotPublishWarningAfterTransportReplacement() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let coordinator = CalendarCoordinator(storeURL: directory.appendingPathComponent("calendar.json"))
        let retired = CalendarTestPeerTransport()
        let current = CalendarTestPeerTransport()
        let envelope = try CalendarPeerSyncEnvelope(
            snapshot: CalendarSnapshot(),
            senderID: "remote",
            revision: 1,
            sentAt: .now
        )

        coordinator.installPeerTransportForTesting(retired)
        coordinator.installPeerTransportForTesting(current)
        let retiredWarning = expectation(description: "retired transport warning")
        retiredWarning.isInverted = true
        coordinator.setPeerWarningObserverForTesting {
            retiredWarning.fulfill()
        }
        retired.emitSnapshot(envelope, authenticatedSenderID: "attacker")
        await fulfillment(of: [retiredWarning], timeout: 0.25)
        XCTAssertNil(coordinator.syncWarning)

        let currentWarning = expectation(description: "current transport warning")
        coordinator.setPeerWarningObserverForTesting {
            currentWarning.fulfill()
        }
        current.emitSnapshot(envelope, authenticatedSenderID: "attacker")
        await fulfillment(of: [currentWarning], timeout: 1)
        XCTAssertNotNil(coordinator.syncWarning)
    }
}
