import XCTest
@testable import LifeOSMac

final class DomainSyncTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let firstID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    private let seriesID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let validPNG = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    func testCalendarSeriesRoundTripPreservesFractionalDatesIconAndRecurrence() throws {
        let createdAt = base.addingTimeInterval(0.125)
        let updatedAt = base.addingTimeInterval(0.875)
        let start = base.addingTimeInterval(1.125)
        let end = base.addingTimeInterval(61.875)
        let recurrenceUntil = base.addingTimeInterval(86_400.25)
        let recurrence = try CalendarRecurrenceRule(
            frequency: .weekly,
            interval: 2,
            until: recurrenceUntil
        )
        let item = try CalendarItem(
            id: firstID,
            title: "Deep work",
            icon: "🧭",
            start: start,
            end: end,
            createdAt: createdAt,
            updatedAt: updatedAt,
            timeZoneIdentifier: "Europe/Berlin",
            recurrence: recurrence
        )

        let bytes = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let decoded = try CalendarPayloadCodec.decode(bytes)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.tag, "calendarSeries")
        XCTAssertEqual(decoded.seriesID, seriesID.uuidString.lowercased())
        XCTAssertEqual(decoded.items, [item])
        XCTAssertEqual(decoded.items[0].start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(decoded.items[0].updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(decoded.items[0].icon, "🧭")
        XCTAssertEqual(decoded.items[0].recurrence, recurrence)
    }

    func testCalendarSeriesEncodingIsDeterministicRegardlessOfInputOrder() throws {
        let first = try CalendarItem(
            id: firstID,
            title: "First",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let second = try CalendarItem(
            id: secondID,
            title: "Second",
            start: base.addingTimeInterval(120),
            end: base.addingTimeInterval(180),
            createdAt: base,
            updatedAt: base
        )

        let forward = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [first, second])
        let reversed = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [second, first])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(try CalendarPayloadCodec.decode(forward).items.map(\.id), [firstID, secondID])
    }

    func testCalendarSeriesRejectsWrongTagVersionAndSeriesID() throws {
        let item = try makeItem(id: firstID)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))

        let wrongTag = replacing(
            validText,
            #""tag":"calendarSeries""#,
            #""tag":"other""#
        )
        let wrongVersion = replacing(
            validText,
            #""schemaVersion":1"#,
            #""schemaVersion":2"#
        )
        let wrongSeriesID = replacing(
            validText,
            seriesID.uuidString.lowercased(),
            "not-a-uuid"
        )

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(wrongTag.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(wrongVersion.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(wrongSeriesID.utf8)))
    }

    func testCalendarSeriesRejectsMissingUnknownAndDuplicateRootKeys() throws {
        let item = try makeItem(id: firstID)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))

        let missingTag = replacing(
            validText,
            #","tag":"calendarSeries""#,
            ""
        )
        let unknownRoot = replacing(
            validText,
            "{",
            #"{"extra":true,"#
        )
        let duplicateRoot = replacing(
            validText,
            #""tag":"calendarSeries""#,
            #""tag":"calendarSeries","tag":"calendarSeries""#
        )

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(missingTag.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(unknownRoot.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(duplicateRoot.utf8)))
    }

    func testCalendarSeriesRejectsDuplicateItemIDs() throws {
        let item = try makeItem(id: firstID)
        let itemJSON = try XCTUnwrap(String(data: JSONEncoder.calendar.encode(item), encoding: .utf8))
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let duplicate = replacing(validText, "]", ",\(itemJSON)]")

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(duplicate.utf8)))
    }

    func testCalendarSeriesRejectsTransientOccurrenceIDs() throws {
        let item = try makeItem(id: firstID)
        var transientItem = item
        transientItem.occurrenceSourceID = secondID
        XCTAssertThrowsError(try CalendarPayloadCodec.encode(seriesID: seriesID, items: [transientItem])) { error in
            XCTAssertEqual(error as? CalendarValidationError, .transientOccurrence)
        }

        let itemJSON = try XCTUnwrap(String(data: JSONEncoder.calendar.encode(item), encoding: .utf8))
        let transient = replacing(itemJSON, "{", "{\"occurrenceSourceID\":\"\(secondID.uuidString.lowercased())\",")
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let payload = replacing(validText, itemJSON, transient)

        let canonicalPayload = try SyncWireCodec.canonicalizeJSON(Data(payload.utf8))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonicalPayload))
    }

    func testCalendarSeriesCanonicalizesDecomposedTitleOnlyAtWireBoundary() throws {
        let decomposedTitle = "Cafe\u{301}"
        let item = try CalendarItem(
            id: firstID,
            title: decomposedTitle,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )

        let payload = try CalendarSeriesPayload(seriesID: seriesID.uuidString.lowercased(), items: [item])
        let publicBytes = try JSONEncoder.calendar.encode(payload)
        let codecBytes = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let decoded = try CalendarPayloadCodec.decode(publicBytes)

        XCTAssertEqual(item.title, decomposedTitle)
        XCTAssertEqual(Array(item.title.utf8), Array(decomposedTitle.utf8))
        XCTAssertEqual(publicBytes, codecBytes)
        XCTAssertEqual(Array(payload.items[0].title.utf8), Array("Café".utf8))
        XCTAssertEqual(decoded.items[0].title, "Café")
        XCTAssertNotEqual(Array(item.title.utf8), Array(decoded.items[0].title.utf8))
    }

    func testCalendarSeriesRejectsNonNFCTitleAtDecodeBoundary() throws {
        let item = try makeItem(id: firstID)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let nonNFCPayload = replacing(validText, "Calendar item", "Cafe\u{301}")

        XCTAssertThrowsError(
            try JSONDecoder.calendar.decode(
                CalendarSeriesPayload.self,
                from: Data(nonNFCPayload.utf8)
            )
        )
    }

    func testCalendarSeriesRejectsUnknownNestedRecurrenceKeys() throws {
        let recurrence = try CalendarRecurrenceRule(frequency: .weekly, interval: 2, until: base.addingTimeInterval(86_400))
        let item = try CalendarItem(
            id: firstID,
            title: "Recurring",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base,
            recurrence: recurrence
        )
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let mutated = replacing(
            validText,
            #""recurrence":{"#,
            #""recurrence":{"extra":true,"#
        )
        let canonical = try SyncWireCodec.canonicalizeJSON(Data(mutated.utf8))

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonical))
    }

    func testCalendarSeriesRejectsUnknownNestedIconAssetKeys() throws {
        let asset = try CalendarIconAsset(format: .png, bytes: validPNG)
        let item = try CalendarItem(
            id: firstID,
            title: "With icon asset",
            iconAsset: asset,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let mutated = replacing(
            validText,
            #""iconAsset":{"#,
            #""iconAsset":{"extra":true,"#
        )
        let canonical = try SyncWireCodec.canonicalizeJSON(Data(mutated.utf8))

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonical))
    }

    func testCalendarSeriesRejectsMismatchedIconAssetHash() throws {
        let asset = try CalendarIconAsset(format: .png, bytes: validPNG)
        let item = try CalendarItem(
            id: firstID,
            title: "With icon asset",
            iconAsset: asset,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let wrongHash = String(repeating: "0", count: asset.contentHash.count)
        let mutated = replacing(validText, asset.contentHash, wrongHash)
        let canonical = try SyncWireCodec.canonicalizeJSON(Data(mutated.utf8))

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonical))
    }

    func testCalendarSeriesRejectsInvalidItem() throws {
        let item = try makeItem(id: firstID)
        let itemJSON = try XCTUnwrap(String(data: JSONEncoder.calendar.encode(item), encoding: .utf8))
        let start = try XCTUnwrap(String(data: try JSONEncoder.calendar.encode(item.start), encoding: .utf8))
        let end = try XCTUnwrap(String(data: try JSONEncoder.calendar.encode(item.end), encoding: .utf8))
        let invalidItem = replacing(itemJSON, end, start)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let payload = replacing(validText, itemJSON, invalidItem)

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(payload.utf8)))
    }

    func testCalendarSeriesRejectsOversizedPayload() throws {
        let oversized = Data(repeating: 0x20, count: SyncContractConstants.maxInlinePayloadBytes + 1)
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(oversized)) { error in
            XCTAssertEqual(error as? SyncFailure, .capacity)
        }
    }

    private func makeItem(id: UUID) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            title: "Calendar item",
            start: base.addingTimeInterval(0.25),
            end: base.addingTimeInterval(60.75),
            createdAt: base,
            updatedAt: base
        )
    }

    private func replacing(_ value: String, _ target: String, _ replacement: String) -> String {
        precondition(value.contains(target), "test fixture target missing: \(target)")
        return value.replacingOccurrences(of: target, with: replacement, options: [], range: value.range(of: target))
    }
}
