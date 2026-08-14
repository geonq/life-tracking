import XCTest
@testable import LifeOS

final class CalendarLayoutTests: XCTestCase {
    func testMobilePagerProjectionIsThresholdedDirectionalAndBounded() {
        XCTAssertEqual(
            CalendarInteractionLayout.pagerPageDelta(
                translation: -40,
                predictedTranslation: -55,
                pageWidth: 390,
                maximumPages: 2
            ),
            0
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerPageDelta(
                translation: -110,
                predictedTranslation: -430,
                pageWidth: 390,
                maximumPages: 2
            ),
            1
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerPageDelta(
                translation: 110,
                predictedTranslation: 920,
                pageWidth: 390,
                maximumPages: 2
            ),
            -2
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerPageDelta(
                translation: -110,
                predictedTranslation: -1_900,
                pageWidth: 390,
                maximumPages: 2
            ),
            2
        )
    }

    func testPagerFallbackDragStateBeginsOnceAndCleansUpOnEndOrCancel() {
        var state = CalendarPagerDragState()
        XCTAssertFalse(state.end())
        XCTAssertTrue(state.beginHorizontalDrag())
        XCTAssertFalse(state.beginHorizontalDrag())
        XCTAssertTrue(state.end())
        XCTAssertFalse(state.end())
        XCTAssertTrue(state.beginHorizontalDrag())
        XCTAssertTrue(state.cancel())
        XCTAssertFalse(state.isActive)
    }

    func testPagerFallbackOnlyClaimsClearlyHorizontalMovement() {
        XCTAssertTrue(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 5,
            verticalTranslation: 1
        ))
        XCTAssertFalse(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 5,
            verticalTranslation: 5
        ))
        XCTAssertFalse(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 1,
            verticalTranslation: 12
        ))
    }

    func testMobileDefaultSelectionCreatesExactThirtyMinuteInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        let interval = try XCTUnwrap(
            CalendarInteractionLayout.creationInterval(
                day: day,
                verticalStart: 9.5 * 60,
                verticalEnd: 9.5 * 60,
                hourHeight: 60,
                calendar: calendar,
                defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
            )
        )

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 9)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 30)
        XCTAssertEqual(
            CalendarInteractionLayout.calendarMinutes(from: interval.start, to: interval.end, calendar: calendar),
            30
        )
    }

    func testPointerDefaultSelectionCreatesExactThirtyMinuteInterval() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        let interval = try XCTUnwrap(
            CalendarInteractionLayout.creationInterval(
                day: day,
                verticalStart: 12 * 60,
                verticalEnd: 12 * 60,
                hourHeight: 60,
                calendar: calendar,
                defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
            )
        )

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 12)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 0)
        XCTAssertEqual(
            CalendarInteractionLayout.calendarMinutes(from: interval.start, to: interval.end, calendar: calendar),
            30
        )
    }

    func testMobileSelectionVerticalAdjustmentStaysOnQuarterHourGrid() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12)))
        let interval = try XCTUnwrap(
            CalendarInteractionLayout.creationInterval(
                day: day,
                verticalStart: 9 * 60 + 7,
                verticalEnd: 10 * 60 + 22,
                hourHeight: 60,
                calendar: calendar,
                defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
            )
        )

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 9)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 10)
        XCTAssertEqual(calendar.component(.minute, from: interval.end), 15)
        XCTAssertEqual(
            CalendarInteractionLayout.calendarMinutes(from: interval.start, to: interval.end, calendar: calendar),
            75
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    private var dayStart: Date {
        DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 7, day: 31).date!
    }

    private func item(
        _ id: UUID = UUID(),
        title: String,
        start: TimeInterval,
        end: TimeInterval
    ) throws -> CalendarItem {
        try CalendarItem(
            id: id,
            title: title,
            start: dayStart.addingTimeInterval(start),
            end: dayStart.addingTimeInterval(end),
            createdAt: dayStart,
            updatedAt: dayStart
        )
    }

    func testOnlyOverlappingEventsShareAnOverlapGroup() throws {
        let a = try item(title: "A", start: 0, end: 60)
        let b = try item(title: "B", start: 30, end: 90)
        let c = try item(title: "C", start: 90, end: 120)

        let result = CalendarOverlapLayout.layout(
            items: [a, b, c],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.item.title), ["A", "B", "C"])
        XCTAssertEqual(result.map(\.column), [0, 1, 0])
        XCTAssertEqual(result.map(\.columnCount), [2, 2, 1])
    }

    func testTouchingIntervalsDoNotOverlap() throws {
        let a = try item(title: "A", start: 0, end: 60)
        let b = try item(title: "B", start: 60, end: 120)

        let result = CalendarOverlapLayout.layout(
            items: [a, b],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.column), [0, 0])
        XCTAssertEqual(result.map(\.columnCount), [1, 1])
    }

    func testEventsAreClippedToVisibleInterval() throws {
        let event = try item(title: "Spanning", start: -3600, end: 3600)
        let visible = DateInterval(start: dayStart, duration: 1800)

        let placement = try XCTUnwrap(CalendarOverlapLayout.layout(items: [event], interval: visible).first)

        XCTAssertEqual(placement.visibleStart, dayStart)
        XCTAssertEqual(placement.visibleEnd, dayStart.addingTimeInterval(1800))
        XCTAssertEqual(placement.yStart, 0, accuracy: 0.0001)
        XCTAssertEqual(placement.yEnd, 1, accuracy: 0.0001)
    }

    func testDeletedItemsAndItemsOutsideIntervalAreExcluded() throws {
        let live = try item(title: "Live", start: 0, end: 60)
        let deleted = live.deleting(at: dayStart.addingTimeInterval(1))
        let later = try item(title: "Later", start: 121, end: 180)

        let result = CalendarOverlapLayout.layout(
            items: [deleted, later],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertTrue(result.isEmpty)
    }

    func testSameStartOrderingIsDeterministic() throws {
        let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let first = try item(firstID, title: "First", start: 0, end: 60)
        let second = try item(secondID, title: "Second", start: 0, end: 60)

        let result = CalendarOverlapLayout.layout(
            items: [second, first],
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.item.title), ["First", "Second"])
        XCTAssertEqual(result.map(\.column), [0, 1])
    }

    func testThreeSimultaneousEventsUseThreeColumns() throws {
        let events = try [
            item(title: "A", start: 0, end: 120),
            item(title: "B", start: 10, end: 100),
            item(title: "C", start: 20, end: 80)
        ]

        let result = CalendarOverlapLayout.layout(
            items: events,
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result.map(\.column), [0, 1, 2])
        XCTAssertEqual(result.map(\.columnCount), [3, 3, 3])
    }

    func testNotionTrailingLayersReuseBaseDepthAfterBaseEnds() throws {
        let gym = try item(title: "Gym", start: 0, end: 240)
        let clip = try item(title: "Clip per", start: 60, end: 360)
        let tax = try item(title: "Tax", start: 120, end: 300)
        // Gym ends while Clip and Tax continue. The new event can reuse the
        // full-width base layer instead of creating a fourth side-by-side lane.
        let chillen = try item(title: "chillen fr", start: 240, end: 540)

        let result = CalendarOverlapLayout.layout(
            items: [gym, clip, tax, chillen],
            interval: DateInterval(start: dayStart, duration: 900)
        )

        XCTAssertEqual(result.map(\.item.title), ["Gym", "Clip per", "Tax", "chillen fr"])
        XCTAssertEqual(result.map(\.depth), [0, 1, 2, 0])

        let frames = result.map { $0.layerFrame(containerWidth: 120) }
        XCTAssertEqual(frames[0].width, frames[3].width, accuracy: 0.0001)
        XCTAssertEqual(frames[0].leading, frames[3].leading, accuracy: 0.0001)
        XCTAssertEqual(frames.map(\.trailing), [120, 120, 120, 120])
        XCTAssertLessThan(frames[0].leading, frames[1].leading)
        XCTAssertLessThan(frames[1].leading, frames[2].leading)
        XCTAssertTrue(frames.allSatisfy { $0.width >= CalendarOverlapLayout.minimumLayerWidth })

        let wideFrames = result.map { $0.layerFrame(containerWidth: 308) }
        let expectedFirstInset = 308 * CalendarOverlapLayout.baseLayerInsetFraction
        XCTAssertEqual(wideFrames[1].leading, expectedFirstInset, accuracy: 0.0001)
        XCTAssertEqual(wideFrames[2].leading, expectedFirstInset + CalendarOverlapLayout.additionalLayerInset, accuracy: 0.0001)
        XCTAssertEqual(wideFrames[1].trailing, wideFrames[2].trailing, accuracy: 0.0001)

        // The absolute minimum is impossible in an exceptionally narrow
        // column; clamping is still required to keep the event inside it.
        let narrowFrames = result.map { $0.layerFrame(containerWidth: 38) }
        XCTAssertTrue(narrowFrames.allSatisfy { $0.width <= 38 && $0.trailing == 38 })
    }

    func testIMG0663FixtureKeepsLaterOverlapTrailingAndNextEventFullWidth() throws {
        let gym = try item(
            UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            title: "Gym",
            start: 4 * 3_600,
            end: 5 * 3_600
        )
        let clip = try item(
            UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            title: "Clip video",
            start: 5 * 3_600,
            end: 6 * 3_600
        )
        let tax = try item(
            UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
            title: "Tax",
            start: 5 * 3_600,
            end: 6 * 3_600
        )
        let chillen = try item(
            UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
            title: "chillen",
            start: 6 * 3_600,
            end: 7 * 3_600 + 1_800
        )

        let result = CalendarOverlapLayout.layout(
            items: [gym, clip, tax, chillen],
            interval: DateInterval(start: dayStart, duration: 8 * 3_600)
        )

        XCTAssertEqual(result.map(\.item.title), ["Gym", "Clip video", "Tax", "chillen"])
        XCTAssertEqual(result.map(\.depth), [0, 1, 2, 0])
        XCTAssertEqual(result.map(\.columnCount), [1, 3, 3, 1])

        let frames = result.map { $0.layerFrame(containerWidth: 120) }
        XCTAssertEqual(frames[0].leading, 0, accuracy: 0.0001)
        XCTAssertEqual(frames[0].width, 120, accuracy: 0.0001)
        XCTAssertGreaterThan(frames[1].leading, frames[0].leading)
        XCTAssertGreaterThan(frames[2].leading, frames[1].leading)
        XCTAssertEqual(frames[3].leading, 0, accuracy: 0.0001)
        XCTAssertEqual(frames[3].width, 120, accuracy: 0.0001)
    }

    func testOverlapCornerRadiiKeepOuterEdgesRoundedAndInternalEdgesTight() throws {
        let events = try [
            item(title: "A", start: 0, end: 120),
            item(title: "B", start: 10, end: 100),
            item(title: "C", start: 20, end: 80)
        ]

        let result = CalendarOverlapLayout.layout(
            items: events,
            interval: DateInterval(start: dayStart, duration: 120)
        )

        XCTAssertEqual(result[0].cornerRadii, CalendarEventCornerRadii(
            topLeading: 7, bottomLeading: 7, bottomTrailing: 2, topTrailing: 2
        ))
        XCTAssertEqual(result[1].cornerRadii, CalendarEventCornerRadii(
            topLeading: 2, bottomLeading: 2, bottomTrailing: 2, topTrailing: 2
        ))
        XCTAssertEqual(result[2].cornerRadii, CalendarEventCornerRadii(
            topLeading: 2, bottomLeading: 2, bottomTrailing: 7, topTrailing: 7
        ))
    }

    func testSingleEventKeepsAllCornersRounded() throws {
        let event = try item(title: "Single", start: 0, end: 60)
        let placement = try XCTUnwrap(CalendarOverlapLayout.layout(
            items: [event],
            interval: DateInterval(start: dayStart, duration: 120)
        ).first)

        XCTAssertEqual(placement.cornerRadii, CalendarEventCornerRadii(
            topLeading: 7, bottomLeading: 7, bottomTrailing: 7, topTrailing: 7
        ))
    }

    func testDayQueryIncludesOvernightEventOnBothDays() throws {
        let event = try item(title: "Overnight", start: -1800, end: 1800)
        let snapshot = CalendarSnapshot(items: [event])

        XCTAssertEqual(snapshot.items(on: dayStart.addingTimeInterval(-1), calendar: calendar).map(\.title), ["Overnight"])
        XCTAssertEqual(snapshot.items(on: dayStart, calendar: calendar).map(\.title), ["Overnight"])
    }

    func testVisibleDaysHaveExactRequestedCount() {
        XCTAssertEqual(CalendarDateRange.days(containing: dayStart, count: 3, calendar: calendar).count, 3)
        XCTAssertEqual(CalendarDateRange.days(containing: dayStart, count: 7, calendar: calendar).count, 7)
    }

    func testMonthGridAlwaysUsesSixWeeks() {
        let february = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 2, day: 12).date!
        let july = DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: 2026, month: 7, day: 12).date!

        XCTAssertEqual(CalendarDateRange.monthGrid(containing: february, calendar: calendar).count, 42)
        XCTAssertEqual(CalendarDateRange.monthGrid(containing: july, calendar: calendar).count, 42)
    }

    func testMonthCellPresentationLimitsEventsForCompactColumns() {
        XCTAssertEqual(CalendarMonthCellPresentation.visibleEventLimit(isCompact: true), 3)
        XCTAssertEqual(CalendarMonthCellPresentation.visibleEventLimit(isCompact: false), 3)
        XCTAssertEqual(CalendarMonthCellPresentation.overflowCount(total: 4, visible: 3), 1)
        XCTAssertEqual(CalendarMonthCellPresentation.overflowCount(total: 2, visible: 3), 0)
    }

    func testMonthMovePreservesLocalStartAndExactOvernightDuration() throws {
        let source = try CalendarItem(
            title: "Overnight month move",
            start: DateComponents(calendar: calendar, year: 2026, month: 7, day: 31, hour: 23, minute: 30).date!,
            end: DateComponents(calendar: calendar, year: 2026, month: 8, day: 1, hour: 1, minute: 15).date!
        )
        let targetDay = DateComponents(calendar: calendar, year: 2026, month: 8, day: 20).date!

        let moved = try XCTUnwrap(CalendarInteractionLayout.monthMovedInterval(
            item: source,
            targetDay: targetDay,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moved.start),
                       DateComponents(year: 2026, month: 8, day: 20, hour: 23, minute: 30))
        XCTAssertEqual(calendar.dateComponents([.year, .month, .day, .hour, .minute], from: moved.end),
                       DateComponents(year: 2026, month: 8, day: 21, hour: 1, minute: 15))
        XCTAssertEqual(moved.duration, source.end.timeIntervalSince(source.start), accuracy: 0.000_001)
    }

    func testMonthMovePreservesFractionalDurationAcrossCalendarDay() throws {
        let start = DateComponents(calendar: calendar, year: 2026, month: 7, day: 31, hour: 9, minute: 15).date!
        let source = try CalendarItem(
            title: "Precise duration",
            start: start,
            end: start.addingTimeInterval(3_600.25)
        )
        let targetDay = DateComponents(calendar: calendar, year: 2026, month: 8, day: 3).date!

        let moved = try XCTUnwrap(CalendarInteractionLayout.monthMovedInterval(
            item: source,
            targetDay: targetDay,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.hour, from: moved.start), 9)
        XCTAssertEqual(calendar.component(.minute, from: moved.start), 15)
        XCTAssertEqual(moved.duration, 3_600.25, accuracy: 0.000_001)
    }

    func testMonthMoveKeepsSourceOwnerAndDestinationGhostSeparate() throws {
        let source = try CalendarItem(
            title: "Render ownership",
            start: DateComponents(calendar: calendar, year: 2026, month: 7, day: 31, hour: 9).date!,
            end: DateComponents(calendar: calendar, year: 2026, month: 7, day: 31, hour: 10).date!
        )
        let targetDay = DateComponents(calendar: calendar, year: 2026, month: 8, day: 3).date!
        let moved = try XCTUnwrap(CalendarInteractionLayout.monthMovedInterval(item: source, targetDay: targetDay, calendar: calendar))

        XCTAssertEqual(
            CalendarInteractionLayout.monthMoveRenderState(
                item: source, previewStart: moved.start, previewEnd: moved.end,
                day: source.start, calendar: calendar
            ),
            .sourceOwner
        )
        XCTAssertEqual(
            CalendarInteractionLayout.monthMoveRenderState(
                item: source, previewStart: moved.start, previewEnd: moved.end,
                day: targetDay, calendar: calendar
            ),
            .destinationGhost
        )
        let unrelated = calendar.date(byAdding: .day, value: 1, to: targetDay)!
        XCTAssertEqual(
            CalendarInteractionLayout.monthMoveRenderState(
                item: source, previewStart: moved.start, previewEnd: moved.end,
                day: unrelated, calendar: calendar
            ),
            .normal
        )
    }

    func testMonthMoveRejectsNonexistentSpringForwardLocalStart() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let sourceStart = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 7, hour: 2, minute: 30).date!
        let source = try CalendarItem(title: "Spring gap", start: sourceStart, end: sourceStart.addingTimeInterval(1_800))
        let springTarget = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8).date!

        XCTAssertNil(CalendarInteractionLayout.monthMovedInterval(item: source, targetDay: springTarget, calendar: newYork))
    }

    func testMonthMovePreservesLaterFallBackOccurrenceWhenTargetRepeatsWallTime() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let fallDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1).date!
        let first = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1, hour: 1, minute: 30).date!
        let later = try XCTUnwrap(newYork.date(byAdding: .hour, value: 1, to: first))
        XCTAssertEqual(newYork.component(.hour, from: later), 1)
        XCTAssertEqual(newYork.component(.minute, from: later), 30)
        let source = try CalendarItem(title: "Fall fold", start: later, end: later.addingTimeInterval(1_800))

        let moved = try XCTUnwrap(CalendarInteractionLayout.monthMovedInterval(item: source, targetDay: fallDay, calendar: newYork))
        XCTAssertEqual(moved.start, later)
        XCTAssertEqual(moved.duration, 1_800, accuracy: 0.000_001)
    }

    func testInteractionSnapThresholdsAreSymmetricAroundZero() {
        XCTAssertEqual(
            CalendarInteractionLayout.snappedMinuteDelta(translation: 7.4, hourHeight: 60),
            0
        )
        XCTAssertEqual(
            CalendarInteractionLayout.snappedMinuteDelta(translation: 7.5, hourHeight: 60),
            15
        )
        XCTAssertEqual(
            CalendarInteractionLayout.snappedMinuteDelta(translation: -7.5, hourHeight: 60),
            -15
        )
        XCTAssertEqual(
            CalendarInteractionLayout.snappedMinuteDelta(translation: -7.4, hourHeight: 60),
            0
        )
    }

    func testHorizontalDaySnapThresholdsAreSymmetricAroundZero() {
        XCTAssertEqual(CalendarInteractionLayout.snappedDayDelta(translation: 49, dayWidth: 100), 0)
        XCTAssertEqual(CalendarInteractionLayout.snappedDayDelta(translation: 50, dayWidth: 100), 1)
        XCTAssertEqual(CalendarInteractionLayout.snappedDayDelta(translation: -50, dayWidth: 100), -1)
        XCTAssertEqual(CalendarInteractionLayout.snappedDayDelta(translation: -49, dayWidth: 100), 0)
    }

    func testCrossDayMoveSnapsBothAxesAndPreservesLocalDuration() throws {
        let event = try item(title: "Cross day", start: 9 * 3_600, end: 11 * 3_600)
        let moved = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            verticalTranslation: 7.5,
            horizontalTranslation: 100,
            dayWidth: 100,
            hourHeight: 60,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.day, .hour, .minute], from: moved.start),
                       calendar.dateComponents([.day, .hour, .minute], from: dayStart.addingTimeInterval(24 * 3_600 + 9 * 3_600 + 15 * 60)))
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: moved.start, to: moved.end, calendar: calendar), 120)
    }

    func testCrossDayMoveUsesLocalClockAcrossDST() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let beforeDST = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 7, hour: 9).date!
        let event = try CalendarItem(
            title: "DST move",
            start: beforeDST,
            end: newYork.date(byAdding: .hour, value: 2, to: beforeDST)!,
            createdAt: beforeDST,
            updatedAt: beforeDST
        )

        let moved = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            verticalTranslation: 0,
            horizontalTranslation: 120,
            dayWidth: 120,
            hourHeight: 60,
            calendar: newYork
        ))

        XCTAssertEqual(newYork.component(.day, from: moved.start), 8)
        XCTAssertEqual(newYork.component(.hour, from: moved.start), 9)
        XCTAssertEqual(newYork.component(.minute, from: moved.start), 0)
        XCTAssertEqual(newYork.component(.hour, from: moved.end), 11)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: moved.start, to: moved.end, calendar: newYork), 120)
    }

    func testCrossDayMoveRecomputesOverlapOnTargetDay() throws {
        let event = try item(title: "Moved", start: 9 * 3_600, end: 11 * 3_600)
        let sourceNeighbor = try CalendarItem(
            title: "Source neighbor",
            start: dayStart.addingTimeInterval(9 * 3_600 + 30 * 60),
            end: dayStart.addingTimeInterval(10 * 3_600 + 30 * 60),
            createdAt: dayStart,
            updatedAt: dayStart
        )
        let targetDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let neighbor = try CalendarItem(
            title: "Neighbor",
            start: targetDay.addingTimeInterval(9 * 3_600),
            end: targetDay.addingTimeInterval(10 * 3_600),
            createdAt: targetDay,
            updatedAt: targetDay
        )
        let movedInterval = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            verticalTranslation: 0,
            horizontalTranslation: 100,
            dayWidth: 100,
            hourHeight: 60,
            calendar: calendar
        ))
        let targetInterval = try XCTUnwrap(CalendarInteractionLayout.dayInterval(containing: targetDay, calendar: calendar))
        let sourcePlacements = CalendarOverlapLayout.layoutWithProvisionalMove(
            items: [event, sourceNeighbor],
            movingItemID: event.id,
            provisionalStart: movedInterval.start,
            provisionalEnd: movedInterval.end,
            interval: try XCTUnwrap(CalendarInteractionLayout.dayInterval(containing: dayStart, calendar: calendar))
        )
        let placements = CalendarOverlapLayout.layoutWithProvisionalMove(
            items: [event, neighbor],
            movingItemID: event.id,
            provisionalStart: movedInterval.start,
            provisionalEnd: movedInterval.end,
            interval: targetInterval
        )

        XCTAssertEqual(sourcePlacements.map(\.item.title), ["Source neighbor"])
        XCTAssertEqual(sourcePlacements.map(\.column), [0])
        XCTAssertEqual(placements.map(\.item.title), ["Moved", "Neighbor"])
        XCTAssertEqual(Set(placements.map(\.column)), [0, 1])
    }

    func testProvisionalMoveHasOneVisibleRepresentationPerAxis() {
        let sameDay = CalendarInteractionLayout.provisionalRenderState(
            sourceDate: dayStart.addingTimeInterval(9 * 3_600),
            destinationDate: dayStart.addingTimeInterval(10 * 3_600),
            calendar: calendar
        )
        XCTAssertEqual(sameDay, .sourceOnly)

        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart)!
        let crossDay = CalendarInteractionLayout.provisionalRenderState(
            sourceDate: dayStart.addingTimeInterval(9 * 3_600),
            destinationDate: nextDay.addingTimeInterval(9 * 3_600),
            calendar: calendar
        )
        XCTAssertEqual(crossDay, .destinationOnly)
    }

    func testEventMutationArbitrationYieldsParentScrollAndRestoresSettledHeader() {
        XCTAssertTrue(CalendarGestureArbitration.parentHorizontalScrollEnabled(
            eventMutationActive: false,
            hasProvisionalPreview: false
        ))
        XCTAssertFalse(CalendarGestureArbitration.parentHorizontalScrollEnabled(
            eventMutationActive: true,
            hasProvisionalPreview: false
        ))
        XCTAssertFalse(CalendarGestureArbitration.parentHorizontalScrollEnabled(
            eventMutationActive: false,
            hasProvisionalPreview: true
        ))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let settled = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 15, minute: 42))!
        XCTAssertEqual(
            CalendarGestureArbitration.headerDateAfterEventOwnership(settledPage: settled, calendar: calendar),
            calendar.startOfDay(for: settled)
        )
        let cleanup = CalendarGestureArbitration.cleanupAfterCompletedMutation(settledPage: settled, calendar: calendar)
        XCTAssertFalse(cleanup.eventMoveActive)
        XCTAssertFalse(cleanup.hasProvisionalPreview)
        XCTAssertEqual(cleanup.settledHeaderDate, calendar.startOfDay(for: settled))

        let cancelled = CalendarGestureArbitration.cleanupAfterCancelledMutation(settledPage: settled, calendar: calendar)
        XCTAssertFalse(cancelled.eventMoveActive)
        XCTAssertFalse(cancelled.hasProvisionalPreview)
        XCTAssertEqual(cancelled.settledHeaderDate, calendar.startOfDay(for: settled))
    }

    func testResizeClampsToMinimumFifteenMinutes() throws {
        let event = try item(title: "Shorten", start: 9 * 3_600, end: 10 * 3_600)
        let interval = try XCTUnwrap(CalendarInteractionLayout.resizedInterval(
            item: event,
            edge: .end,
            translation: -120,
            hourHeight: 60,
            day: dayStart,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.dateComponents([.hour, .minute], from: interval.start).hour, 9)
        XCTAssertEqual(
            CalendarInteractionLayout.calendarMinutes(from: interval.start, to: interval.end, calendar: calendar),
            15
        )
    }

    func testMoveClampsSameDayEventsToCalendarDayBounds() throws {
        let event = try item(title: "Bounds", start: 9 * 3_600, end: 10 * 3_600)
        let earliest = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            translation: -12 * 60,
            hourHeight: 60,
            day: dayStart,
            calendar: calendar
        ))
        let latest = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            translation: 24 * 60,
            hourHeight: 60,
            day: dayStart,
            calendar: calendar
        ))

        XCTAssertEqual(earliest.start, dayStart)
        XCTAssertEqual(calendar.component(.hour, from: latest.start), 23)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: latest.start, to: latest.end, calendar: calendar), 60)
    }

    func testOvernightMovePreservesDurationAndCrossesMidnight() throws {
        let event = try item(title: "Overnight", start: -30 * 60, end: 90 * 60)
        let moved = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            translation: -15,
            hourHeight: 60,
            day: dayStart,
            calendar: calendar
        ))

        XCTAssertLessThan(moved.start, dayStart)
        XCTAssertGreaterThan(moved.end, dayStart)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: moved.start, to: moved.end, calendar: calendar), 120)
    }

    func testDSTDayArithmeticUsesCalendarDayLengthAndLocalMinutes() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = DateComponents(
            calendar: newYork,
            timeZone: newYork.timeZone,
            year: 2026,
            month: 3,
            day: 8
        ).date!
        let day = try XCTUnwrap(CalendarInteractionLayout.dayInterval(containing: springDay, calendar: newYork))
        XCTAssertEqual(day.duration, 23 * 3_600, accuracy: 0.001)

        let creation = try XCTUnwrap(CalendarInteractionLayout.creationDate(
            day: springDay,
            verticalOffset: 2 * 60,
            hourHeight: 60,
            calendar: newYork
        ))
        XCTAssertEqual(newYork.component(.hour, from: creation), 3)
    }

    func testTimedCreationSnapsDoubleClickToQuarterHourAndDefaultDuration() throws {
        let interval = try XCTUnwrap(CalendarInteractionLayout.creationInterval(
            day: dayStart,
            verticalStart: 10 * 60 + 7,
            verticalEnd: 10 * 60 + 7,
            hourHeight: 60,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 10)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 0)
        XCTAssertEqual(interval.duration, 60 * 60, accuracy: 0.001)
    }

    func testMacPointerCreationFixtureSnapsNoonToThirtyMinutes() throws {
        let interval = try XCTUnwrap(CalendarInteractionLayout.creationInterval(
            day: dayStart,
            verticalStart: 12 * 60,
            verticalEnd: 12 * 60,
            hourHeight: 60,
            calendar: calendar,
            defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
        ))

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 12)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 12)
        XCTAssertEqual(calendar.component(.minute, from: interval.end), 30)
        XCTAssertEqual(interval.duration, 30 * 60, accuracy: 0.001)
    }

    func testEditorAnchorFrameUsesOneNamedSpaceWithoutHostingFallback() throws {
        let dayColumnFrame = CGRect(x: 148.5, y: 236.25, width: 180, height: 1_296)
        let source = try XCTUnwrap(CalendarEditorAnchorGeometry.sourceFrame(
            forLocalPoint: CGPoint(x: 90, y: 648),
            inNamedSpace: dayColumnFrame
        ))

        XCTAssertEqual(source.origin, CGPoint(x: 238.5, y: 884.25))
        XCTAssertEqual(source.size, CalendarEditorAnchorGeometry.sourceSize)
        XCTAssertNil(CalendarEditorAnchorGeometry.sourceFrame(
            forLocalPoint: CGPoint(x: CGFloat.infinity, y: 0),
            inNamedSpace: dayColumnFrame
        ))
    }

    func testEventEditorAnchorPreservesRenderedCardRectInNamedSpace() throws {
        let dayColumnFrame = CGRect(x: 148.5, y: 236.25, width: 180, height: 1_296)
        let eventRect = CGRect(x: 2, y: 486, width: 86, height: 106)
        let source = try XCTUnwrap(CalendarEditorAnchorGeometry.frame(
            forLocalRect: eventRect,
            inNamedSpace: dayColumnFrame
        ))

        XCTAssertEqual(source, CGRect(x: 150.5, y: 722.25, width: 86, height: 106))
        XCTAssertEqual(source.size, eventRect.size)
        XCTAssertNil(CalendarEditorAnchorGeometry.frame(
            forLocalRect: CGRect(x: 2, y: 486, width: 0, height: 106),
            inNamedSpace: dayColumnFrame
        ))
    }

    func testMacTimedCreationDragUses15MinuteSnappedDurationWithoutStealingSingleClick() throws {
        // This pure predicate remains coverage for the macOS range gesture;
        // iOS deliberately has no empty-grid drag creation path.
        XCTAssertFalse(CalendarInteractionLayout.isIntentionalCreationDrag(
            verticalTranslation: 0,
            horizontalTranslation: 0
        ))
        XCTAssertTrue(CalendarInteractionLayout.isIntentionalCreationDrag(
            verticalTranslation: 30,
            horizontalTranslation: 4
        ))
        XCTAssertFalse(CalendarInteractionLayout.isIntentionalCreationDrag(
            verticalTranslation: 120,
            horizontalTranslation: 80
        ))

        let interval = try XCTUnwrap(CalendarInteractionLayout.creationInterval(
            day: dayStart,
            verticalStart: 10 * 60 + 7,
            verticalEnd: 10 * 60 + 34,
            hourHeight: 60,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.minute, from: interval.start), 0)
        XCTAssertEqual(calendar.component(.hour, from: interval.end), 10)
        XCTAssertEqual(calendar.component(.minute, from: interval.end), 30)
        XCTAssertEqual(interval.duration, 30 * 60, accuracy: 0.001)
    }

    func testTimedCreationNearDayEndKeepsExactWallClockStartAndMayCrossMidnight() throws {
        let interval = try XCTUnwrap(CalendarInteractionLayout.creationInterval(
            day: dayStart,
            verticalStart: 23 * 60 + 49,
            verticalEnd: 23 * 60 + 49,
            hourHeight: 60,
            calendar: calendar
        ))

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 23)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 45)
        XCTAssertEqual(calendar.component(.day, from: interval.end), 1)
        XCTAssertEqual(interval.duration, 60 * 60, accuracy: 0.001)
    }

    func testTimelineScaleKeepsWallClockAlignedAcrossDSTColumns() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let normalDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 7).date!
        let springDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8).date!
        let fallDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1).date!
        let normal = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: normalDay, hourHeight: 60, calendar: newYork))
        let spring = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: springDay, hourHeight: 60, calendar: newYork))
        let fall = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: fallDay, hourHeight: 60, calendar: newYork))

        XCTAssertEqual(normal.totalHeight, 24 * 60, accuracy: 0.001)
        XCTAssertEqual(spring.totalHeight, normal.totalHeight, accuracy: 0.001)
        XCTAssertEqual(fall.totalHeight, normal.totalHeight, accuracy: 0.001)
        XCTAssertEqual(spring.elapsedDayMinutes, 23 * 60)
        XCTAssertEqual(fall.elapsedDayMinutes, 25 * 60)

        let nineNormal = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 7, hour: 9).date!
        let nineSpring = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 9).date!
        let nineFall = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1, hour: 9).date!
        XCTAssertEqual(normal.y(for: nineNormal, calendar: newYork), 9 * 60, accuracy: 0.001)
        XCTAssertEqual(spring.y(for: nineSpring, calendar: newYork), 9 * 60, accuracy: 0.001)
        XCTAssertEqual(fall.y(for: nineFall, calendar: newYork), 9 * 60, accuracy: 0.001)
    }

    func testTimelineScaleDefinesSkippedAndRepeatedDSTHours() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8).date!
        let spring = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: springDay, hourHeight: 60, calendar: newYork))
        let oneThirty = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 1, minute: 30).date!
        let threeThirty = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 3, minute: 30).date!
        XCTAssertEqual(spring.date(for: spring.y(for: oneThirty, calendar: newYork), calendar: newYork, snappingTo: 1), oneThirty)
        XCTAssertEqual(spring.date(for: spring.y(for: threeThirty, calendar: newYork), calendar: newYork, snappingTo: 1), threeThirty)
        let skipped = try XCTUnwrap(spring.date(for: 2.5 * 60, calendar: newYork, snappingTo: 1))
        XCTAssertEqual(newYork.component(.hour, from: skipped), 3)
        XCTAssertEqual(newYork.component(.minute, from: skipped), 30)

        let fallDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1).date!
        let fall = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: fallDay, hourHeight: 60, calendar: newYork))
        let firstOneThirty = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1, hour: 1, minute: 30).date!
        let secondOneThirty = firstOneThirty.addingTimeInterval(60 * 60)
        XCTAssertEqual(newYork.component(.hour, from: secondOneThirty), 1)
        XCTAssertEqual(newYork.component(.minute, from: secondOneThirty), 30)
        XCTAssertEqual(fall.y(for: firstOneThirty, calendar: newYork), fall.y(for: secondOneThirty, calendar: newYork), accuracy: 0.001)
        XCTAssertEqual(fall.height(from: firstOneThirty, to: secondOneThirty, calendar: newYork), 60, accuracy: 0.001)
        let canonical = try XCTUnwrap(fall.date(for: fall.y(for: secondOneThirty, calendar: newYork), calendar: newYork, snappingTo: 1))
        XCTAssertEqual(newYork.component(.hour, from: canonical), 1)
        XCTAssertEqual(newYork.component(.minute, from: canonical), 30)
    }

    func testFallBackSecondOccurrenceMovePreservesFoldForZeroAndSmallEdit() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let fallDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1).date!
        let firstOneThirty = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1, hour: 1, minute: 30).date!
        let secondOneThirty = firstOneThirty.addingTimeInterval(60 * 60)
        let eventEnd = try XCTUnwrap(newYork.date(byAdding: .minute, value: 60, to: secondOneThirty))
        let event = try CalendarItem(title: "Second fold move", start: secondOneThirty, end: eventEnd, createdAt: secondOneThirty, updatedAt: secondOneThirty)

        func assertWall(_ date: Date, hour: Int, minute: Int, elapsedFromFirst: TimeInterval) {
            XCTAssertEqual(newYork.component(.day, from: date), 1)
            XCTAssertEqual(newYork.component(.hour, from: date), hour)
            XCTAssertEqual(newYork.component(.minute, from: date), minute)
            XCTAssertEqual(date.timeIntervalSince(firstOneThirty), elapsedFromFirst, accuracy: 0.001)
        }

        let zero = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            translation: 0,
            hourHeight: 60,
            day: fallDay,
            calendar: newYork
        ))
        assertWall(zero.start, hour: 1, minute: 30, elapsedFromFirst: 60 * 60)
        XCTAssertEqual(zero.start, secondOneThirty)
        XCTAssertEqual(zero.end, eventEnd)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: zero.start, to: zero.end, calendar: newYork), 60)

        let small = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            translation: 15,
            hourHeight: 60,
            day: fallDay,
            calendar: newYork
        ))
        assertWall(small.start, hour: 1, minute: 45, elapsedFromFirst: 75 * 60)
        XCTAssertEqual(small.start, secondOneThirty.addingTimeInterval(15 * 60))
        assertWall(small.end, hour: 2, minute: 45, elapsedFromFirst: 135 * 60)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: small.start, to: small.end, calendar: newYork), 60)
    }

    func testFallBackSecondOccurrenceResizePreservesEndpointFoldForBothEdges() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let fallDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1).date!
        let firstOneThirty = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 11, day: 1, hour: 1, minute: 30).date!
        let secondOneThirty = firstOneThirty.addingTimeInterval(60 * 60)
        let secondTwoThirty = try XCTUnwrap(newYork.date(byAdding: .minute, value: 60, to: secondOneThirty))

        func assertWall(_ date: Date, hour: Int, minute: Int, elapsedFromFirst: TimeInterval) {
            XCTAssertEqual(newYork.component(.day, from: date), 1)
            XCTAssertEqual(newYork.component(.hour, from: date), hour)
            XCTAssertEqual(newYork.component(.minute, from: date), minute)
            XCTAssertEqual(date.timeIntervalSince(firstOneThirty), elapsedFromFirst, accuracy: 0.001)
        }

        let startEvent = try CalendarItem(title: "Second fold start", start: secondOneThirty, end: secondTwoThirty, createdAt: secondOneThirty, updatedAt: secondOneThirty)
        let zeroStart = try XCTUnwrap(CalendarInteractionLayout.resizedInterval(
            item: startEvent,
            edge: .start,
            translation: 0,
            hourHeight: 60,
            day: fallDay,
            calendar: newYork
        ))
        assertWall(zeroStart.start, hour: 1, minute: 30, elapsedFromFirst: 60 * 60)
        XCTAssertEqual(zeroStart.start, secondOneThirty)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: zeroStart.start, to: zeroStart.end, calendar: newYork), 60)

        let smallStart = try XCTUnwrap(CalendarInteractionLayout.resizedInterval(
            item: startEvent,
            edge: .start,
            translation: 15,
            hourHeight: 60,
            day: fallDay,
            calendar: newYork
        ))
        assertWall(smallStart.start, hour: 1, minute: 45, elapsedFromFirst: 75 * 60)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: smallStart.start, to: smallStart.end, calendar: newYork), 45)

        let endEventStart = firstOneThirty.addingTimeInterval(-30 * 60)
        let endEvent = try CalendarItem(title: "Second fold end", start: endEventStart, end: secondOneThirty, createdAt: endEventStart, updatedAt: endEventStart)
        let zeroEnd = try XCTUnwrap(CalendarInteractionLayout.resizedInterval(
            item: endEvent,
            edge: .end,
            translation: 0,
            hourHeight: 60,
            day: fallDay,
            calendar: newYork
        ))
        assertWall(zeroEnd.end, hour: 1, minute: 30, elapsedFromFirst: 60 * 60)
        XCTAssertEqual(zeroEnd.end, secondOneThirty)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: zeroEnd.start, to: zeroEnd.end, calendar: newYork), 90)

        let smallEnd = try XCTUnwrap(CalendarInteractionLayout.resizedInterval(
            item: endEvent,
            edge: .end,
            translation: 15,
            hourHeight: 60,
            day: fallDay,
            calendar: newYork
        ))
        assertWall(smallEnd.end, hour: 1, minute: 45, elapsedFromFirst: 75 * 60)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: smallEnd.start, to: smallEnd.end, calendar: newYork), 105)
    }

    func testTimelineScaleMapsEventAcrossSpringTransition() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8).date!
        let scale = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: springDay, hourHeight: 60, calendar: newYork))
        let start = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 1, minute: 30).date!
        let end = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 3, minute: 30).date!

        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: start, to: end, calendar: newYork), 60)
        XCTAssertEqual(scale.y(for: start, calendar: newYork), 1.5 * 60, accuracy: 0.001)
        XCTAssertEqual(scale.y(for: end, calendar: newYork), 3.5 * 60, accuracy: 0.001)
        XCTAssertGreaterThan(scale.y(for: end, calendar: newYork), scale.y(for: start, calendar: newYork))
    }

    func testTimelineScalePlacesThirteenHundredOnWallClockRowThirteen() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let day = DateComponents(
            calendar: newYork,
            timeZone: newYork.timeZone,
            year: 2026,
            month: 8,
            day: 12
        ).date!
        let scale = try XCTUnwrap(CalendarInteractionLayout.timelineScale(day: day, hourHeight: 60, calendar: newYork))
        let thirteen = DateComponents(
            calendar: newYork,
            timeZone: newYork.timeZone,
            year: 2026,
            month: 8,
            day: 12,
            hour: 13,
            minute: 0
        ).date!

        XCTAssertEqual(CalendarTimelineScale.wallClockMinute(for: thirteen, calendar: newYork), 13 * 60, accuracy: 0.001)
        XCTAssertEqual(scale.y(for: thirteen, calendar: newYork), 13 * 60, accuracy: 0.001)
    }

    func testLocalizedCalendarTimeLabelStaysPresentationOnlyAndLocaleCorrect() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let thirteen = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 13, minute: 0)))

        let localized = CalendarTimelineScale.localizedTimeLabel(
            for: thirteen,
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertEqual(
            localized.replacingOccurrences(of: "\u{202F}", with: " "),
            "1:00 PM"
        )
        XCTAssertEqual(CalendarTimelineScale.wallClockMinute(for: thirteen, calendar: calendar), 13 * 60, accuracy: 0.001)
    }

    func testDSTMoveAndResizeUseTheSameWallClockCoordinate() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        let springDay = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8).date!
        let start = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 1, minute: 30).date!
        let end = DateComponents(calendar: newYork, timeZone: newYork.timeZone, year: 2026, month: 3, day: 8, hour: 3, minute: 30).date!
        let event = try CalendarItem(title: "DST interaction", start: start, end: end, createdAt: start, updatedAt: start)

        let moved = try XCTUnwrap(CalendarInteractionLayout.movedInterval(
            item: event,
            translation: 60,
            hourHeight: 60,
            day: springDay,
            calendar: newYork
        ))
        XCTAssertEqual(newYork.component(.hour, from: moved.start), 3)
        XCTAssertEqual(newYork.component(.minute, from: moved.start), 30)
        XCTAssertEqual(CalendarInteractionLayout.calendarMinutes(from: moved.start, to: moved.end, calendar: newYork), 60)

        let resized = try XCTUnwrap(CalendarInteractionLayout.resizedInterval(
            item: event,
            edge: .end,
            translation: 60,
            hourHeight: 60,
            day: springDay,
            calendar: newYork
        ))
        XCTAssertEqual(newYork.component(.hour, from: resized.end), 4)
        XCTAssertEqual(newYork.component(.minute, from: resized.end), 30)
    }
}
