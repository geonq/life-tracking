import XCTest
@testable import LifeOS

final class CalendarDomainTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testValidationAndEmojiFallback() throws {
        XCTAssertThrowsError(try CalendarItem(title: "   ", icon: "📅", status: .planned, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base))
        XCTAssertThrowsError(try CalendarItem(title: "x", icon: "📅", status: .planned, start: base, end: base, createdAt: base, updatedAt: base))
        let item = try CalendarItem(title: "x", icon: "not-an-emoji", status: .planned, start: base, end: base.addingTimeInterval(60), createdAt: base, updatedAt: base)
        XCTAssertEqual(item.icon, "📅")
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

    func testLocalStoreURLDoesNotRequirePaidAppGroupCapability() {
        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("LifeOSTest", isDirectory: true)
        XCTAssertEqual(CalendarStoreURL.localURL(baseDirectory: baseURL).path,
                       baseURL.appendingPathComponent("calendar.json").path)
    }
}
