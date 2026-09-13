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
                translation: -180,
                predictedTranslation: -650,
                pageWidth: 390,
                maximumPages: 2
            ),
            1,
            "A standard one-page swipe must not skip to a second window"
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

    func testPagerSettleProjectionCarriesBoundedReleaseVelocityWithoutSkippingNormalSwipe() {
        let leftSwipe = CalendarInteractionLayout.pagerSettleProjection(
            translation: -180,
            predictedTranslation: -650,
            pageWidth: 390,
            maximumPages: 2
        )
        XCTAssertEqual(leftSwipe.pageDelta, 1)
        XCTAssertEqual(leftSwipe.normalizedVelocity, (-650.0 + 180.0) / 390.0, accuracy: 0.0001)

        let rightSwipe = CalendarInteractionLayout.pagerSettleProjection(
            translation: 180,
            predictedTranslation: 920,
            pageWidth: 390,
            maximumPages: 2
        )
        XCTAssertEqual(rightSwipe.pageDelta, -2)
        XCTAssertEqual(rightSwipe.normalizedVelocity, (920.0 - 180.0) / 390.0, accuracy: 0.0001)

        let highVelocity = CalendarInteractionLayout.pagerSettleProjection(
            translation: -110,
            predictedTranslation: -1_900,
            pageWidth: 390,
            maximumPages: 2
        )
        XCTAssertEqual(highVelocity.pageDelta, 2)
        XCTAssertEqual(abs(highVelocity.normalizedVelocity), 3, accuracy: 0.0001)

        let shortDrag = CalendarInteractionLayout.pagerSettleProjection(
            translation: -40,
            predictedTranslation: -55,
            pageWidth: 390,
            maximumPages: 2
        )
        XCTAssertEqual(shortDrag, .init(pageDelta: 0, normalizedVelocity: 0))
    }

    func testDayStripSettleNeverAdvancesMoreThanOneDay() {
        // geonq spec: a swipe slides by exactly one day; even a violent flick
        // with a huge predicted translation may reach only the adjacent day.
        let gentleSwipe = CalendarInteractionLayout.pagerSettleProjection(
            translation: -80,
            predictedTranslation: -120,
            pageWidth: 113,
            maximumPages: 1
        )
        XCTAssertEqual(gentleSwipe.pageDelta, 1)

        let hardFlick = CalendarInteractionLayout.pagerSettleProjection(
            translation: -110,
            predictedTranslation: -1_900,
            pageWidth: 113,
            maximumPages: 1
        )
        XCTAssertEqual(hardFlick.pageDelta, 1, "A one-day strip must clamp even extreme flicks to the adjacent day")
        XCTAssertLessThanOrEqual(abs(hardFlick.normalizedVelocity), 3)

        let backwardFlick = CalendarInteractionLayout.pagerSettleProjection(
            translation: 200,
            predictedTranslation: 900,
            pageWidth: 113,
            maximumPages: 1
        )
        XCTAssertEqual(backwardFlick.pageDelta, -1)

        let cancelledShortDrag = CalendarInteractionLayout.pagerSettleProjection(
            translation: -20,
            predictedTranslation: -30,
            pageWidth: 113,
            maximumPages: 1
        )
        XCTAssertEqual(cancelledShortDrag, .init(pageDelta: 0, normalizedVelocity: 0))
    }

    func testPagerInterruptRebasesOffsetIntoTheIncomingPageCoordinateSpace() {
        XCTAssertEqual(
            CalendarInteractionLayout.pagerRebasedOffsetAfterInterrupt(
                currentOffset: -84,
                interruptedTargetOffset: -113
            ),
            29,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerRebasedOffsetAfterInterrupt(
                currentOffset: 84,
                interruptedTargetOffset: 113
            ),
            -29,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerRebasedOffsetAfterInterrupt(
                currentOffset: -113,
                interruptedTargetOffset: -113
            ),
            0,
            accuracy: 0.0001,
            "A grab at the end of the spring must already be at the incoming page's rest position"
        )
    }

    func testReducedMotionMonthExpansionUsesShortOpacityCrossfade() {
        switch CalendarInteractionLayout.monthExpansionMotionPolicy(reduceMotion: true) {
        case .opacityCrossfade(let duration):
            XCTAssertEqual(duration, CalendarInteractionLayout.reducedMotionMonthCrossfadeDuration)
            XCTAssertLessThan(duration, 0.25)
        case .matchedGeometryMorph:
            XCTFail("Reduced motion must not use matched geometry")
        }

        switch CalendarInteractionLayout.monthExpansionMotionPolicy(reduceMotion: false) {
        case .opacityCrossfade:
            XCTFail("Full motion should retain the matched geometry morph")
        case .matchedGeometryMorph:
            break
        }
    }

    func testPagerPreviewDateTracksFractionalDayAcrossVisibleWindow() throws {
        let anchor = DateComponents(calendar: calendar, year: 2026, month: 7, day: 31).date!
        let halfPage = CalendarInteractionLayout.pagerPreviewDate(
            pageAnchor: anchor,
            horizontalOffset: -195,
            pageWidth: 390,
            dayCount: 3,
            calendar: calendar
        )
        let halfComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: halfPage)
        XCTAssertEqual(halfComponents.year, 2026)
        XCTAssertEqual(halfComponents.month, 8)
        XCTAssertEqual(halfComponents.day, 1)
        XCTAssertEqual(halfComponents.hour, 12)
        XCTAssertEqual(halfComponents.minute, 0)

        let nextPage = CalendarInteractionLayout.pagerPreviewDate(
            pageAnchor: anchor,
            horizontalOffset: -390,
            pageWidth: 390,
            dayCount: 3,
            calendar: calendar
        )
        XCTAssertEqual(calendar.startOfDay(for: nextPage), calendar.date(byAdding: .day, value: 3, to: anchor))
    }

    func testPagerPreviewHeaderCallbacksAreBoundaryBounded() throws {
        let anchor = DateComponents(calendar: calendar, year: 2026, month: 7, day: 31).date!
        let midday = calendar.date(byAdding: .hour, value: 12, to: anchor)!
        let nextDay = calendar.date(byAdding: .day, value: 1, to: anchor)!
        let sequence = [anchor, midday, anchor.addingTimeInterval(23 * 60 * 60), nextDay]

        let callbackDates = sequence.dropFirst().filter { candidate in
            CalendarInteractionLayout.pagerPreviewBoundaryChanged(
                from: anchor,
                to: candidate,
                calendar: calendar
            )
        }
        XCTAssertEqual(callbackDates.count, 1, "Fractional same-day pager frames must not rebuild the parent header")
        XCTAssertEqual(
            CalendarInteractionLayout.pagerPreviewBoundary(for: anchor, calendar: calendar),
            CalendarInteractionLayout.pagerPreviewBoundary(for: midday, calendar: calendar)
        )
        XCTAssertNotEqual(
            CalendarInteractionLayout.pagerPreviewBoundary(for: anchor, calendar: calendar),
            CalendarInteractionLayout.pagerPreviewBoundary(for: nextDay, calendar: calendar)
        )
    }

    func testPagerEndDuringSettlePreservesSettleUnlessEventOwnsGesture() {
        XCTAssertEqual(
            CalendarInteractionLayout.pagerEndDisposition(
                hasPendingSettle: true,
                eventMutationActive: false,
                hasProvisionalEventPreview: false,
                horizontalDragActive: false
            ),
            .preservePendingSettle
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerEndDisposition(
                hasPendingSettle: true,
                eventMutationActive: true,
                hasProvisionalEventPreview: false,
                horizontalDragActive: false
            ),
            .resetForEventOwnership
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerEndDisposition(
                hasPendingSettle: false,
                eventMutationActive: false,
                hasProvisionalEventPreview: false,
                horizontalDragActive: true
            ),
            .settleHorizontalPage
        )
    }

    func testTimelineContentHasReachable24HourEndpointWithoutChangingCreationAxis() throws {
        let day = dayStart
        let axisHeight = CalendarInteractionLayout.timelineHeight(
            days: [day],
            hourHeight: 54,
            calendar: calendar
        )
        XCTAssertEqual(axisHeight, 24 * 54)
        // The phone's finite viewport gets the larger of the measured viewport
        // and the bottom chrome budget, so the 24:00 endpoint can travel into
        // view instead of being stranded behind the tab bar.
        let deviceContainerHeight = 731.0
        let dayHeaderHeight = 58.0
        let allDayHeight = CalendarAllDayLayout.rowHeight
        let viewport = CalendarInteractionLayout.timedViewportHeight(
            containerHeight: deviceContainerHeight,
            dayHeaderHeight: dayHeaderHeight,
            allDayHeight: allDayHeight
        )
        let contentHeight = CalendarInteractionLayout.timelineContentHeight(
            days: [day],
            hourHeight: 54,
            calendar: calendar,
            viewportHeight: viewport
        )
        XCTAssertEqual(
            contentHeight,
            axisHeight + max(CalendarInteractionLayout.timelineBottomInset, viewport),
            accuracy: 0.0001
        )
        let maxOffset = CalendarInteractionLayout.timelineMaximumScrollOffset(
            contentHeight: contentHeight,
            viewportHeight: viewport
        )
        XCTAssertGreaterThan(maxOffset, 0, "The full-day content must be scrollable inside the finite viewport")
        XCTAssertGreaterThanOrEqual(
            maxOffset,
            axisHeight - viewport,
            "A 23:45 event must be reachable at the bottom of the timeline"
        )
        XCTAssertEqual(
            CalendarInteractionLayout.timelineHourLabel(
                minute: 1_440,
                dayMinutes: 1_440,
                date: nil,
                calendar: calendar
            ),
            "24:00"
        )
        let twentyThree = calendar.date(byAdding: .hour, value: 23, to: day)
        XCTAssertEqual(
            CalendarInteractionLayout.timelineHourLabel(
                minute: 1_380,
                dayMinutes: 1_440,
                date: twentyThree,
                calendar: calendar
            ),
            "23:00"
        )
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let normalizedSpringGap = berlin.date(
            from: DateComponents(year: 2026, month: 3, day: 29, hour: 3, minute: 0)
        )
        XCTAssertEqual(
            CalendarInteractionLayout.timelineHourLabel(
                minute: 120,
                dayMinutes: 1_440,
                date: normalizedSpringGap,
                calendar: berlin
            ),
            "02:00",
            "Labels follow the wall-clock row even when Foundation normalizes a DST gap"
        )
        // The trailing buffer is display-only: the creation axis stays 24h.
        let created = try XCTUnwrap(CalendarInteractionLayout.creationDate(
            day: day,
            verticalOffset: axisHeight,
            hourHeight: 54,
            calendar: calendar
        ))
        XCTAssertLessThan(created, calendar.date(byAdding: .day, value: 1, to: day)!)
    }

    func testMacTimelineGutterProtectsSingleLineClockLabelsWithoutChangingIPhoneGeometry() {
        XCTAssertEqual(CalendarInteractionLayout.timelineTimeGutter, 44)
        XCTAssertEqual(CalendarInteractionLayout.macTimelineTimeGutter, 52)
        XCTAssertEqual(CalendarInteractionLayout.timelineTimeLabelTrailingInset, 8)
        XCTAssertGreaterThanOrEqual(
            CalendarInteractionLayout.macTimelineTimeGutter - CalendarInteractionLayout.timelineTimeLabelTrailingInset,
            44,
            "The Mac label content area must remain wide enough for the SF Pro HH:MM clock label."
        )
    }

    func testNowIndicatorSelectsAtMostOneVisibleTodayColumn() throws {
        let todayStart = calendar.startOfDay(for: .now)
        let tomorrowStart = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: todayStart))
        let window = [todayStart, tomorrowStart]
        let today = CalendarInteractionLayout.nowIndicatorColumnIndex(
            days: window,
            calendar: calendar
        )
        XCTAssertEqual(today, 0)

        let dayAfterTomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: tomorrowStart))
        XCTAssertNil(
            CalendarInteractionLayout.nowIndicatorColumnIndex(
                days: [tomorrowStart, dayAfterTomorrow],
                calendar: calendar
            )
        )
        XCTAssertEqual(
            window.filter {
                calendar.isDate($0, inSameDayAs: .now)
            }.count,
            1,
            "A three-day window contains at most one today column"
        )
    }

    func testTimelineContentHeightKeepsLateDayContentReachableAtEveryDensity() {
        let day = dayStart
        // A mobile timeline reserves enough trailing space for the actual
        // finite viewport and the known bottom occlusion budget.
        for hourHeight in [
            CalendarInteractionLayout.minimumHourHeight,
            CalendarInteractionLayout.defaultHourHeight,
            CalendarInteractionLayout.maximumHourHeight
        ] {
            for viewport in [597.0, 679.0, 731.0] {
                let axis = CalendarInteractionLayout.timelineHeight(
                    days: [day], hourHeight: hourHeight, calendar: calendar
                )
                let content = CalendarInteractionLayout.timelineContentHeight(
                    days: [day],
                    hourHeight: hourHeight,
                    calendar: calendar,
                    viewportHeight: viewport
                )
                XCTAssertEqual(
                    content,
                    axis + max(CalendarInteractionLayout.timelineBottomInset, viewport),
                    accuracy: 0.0001
                )
                let maxOffset = CalendarInteractionLayout.timelineMaximumScrollOffset(
                    contentHeight: content,
                    viewportHeight: viewport
                )
                XCTAssertGreaterThanOrEqual(
                    maxOffset,
                    axis - viewport,
                    "A 23:45 event must be reachable at hourHeight \(hourHeight)"
                )
                XCTAssertGreaterThanOrEqual(
                    maxOffset + viewport,
                    23 * hourHeight,
                    "23:00 must be reachable at hourHeight \(hourHeight)"
                )
                XCTAssertEqual(
                    maxOffset + viewport - axis,
                    max(CalendarInteractionLayout.timelineBottomInset, viewport),
                    accuracy: 0.0001,
                    "The endpoint tail must cover the viewport or bottom chrome at hourHeight \(hourHeight)"
                )
            }
        }
        // Degenerate inputs stay finite and non-negative.
        XCTAssertEqual(
            CalendarInteractionLayout.timelineMaximumScrollOffset(contentHeight: 100, viewportHeight: 400),
            0
        )
        XCTAssertEqual(
            CalendarInteractionLayout.timelineMaximumScrollOffset(contentHeight: .nan, viewportHeight: 400),
            0
        )
    }

    func testCalendarDensityContractUsesRequestedBoundsAndDefault() {
        XCTAssertEqual(CalendarInteractionLayout.minimumHourHeight, 40)
        XCTAssertEqual(CalendarInteractionLayout.defaultHourHeight, 64)
        XCTAssertEqual(CalendarInteractionLayout.maximumHourHeight, 120)
        XCTAssertLessThan(CalendarInteractionLayout.minimumHourHeight, CalendarInteractionLayout.defaultHourHeight)
        XCTAssertLessThan(CalendarInteractionLayout.defaultHourHeight, CalendarInteractionLayout.maximumHourHeight)
    }

    func testTimelineZoomKeepsThePinchFocalMinuteStationary() {
        let result = CalendarInteractionLayout.zoomedTimeline(
            hourHeight: 54,
            scrollOffset: 4 * 54,
            focalViewportOffset: 200,
            magnification: 1.5,
            viewportHeight: 500
        )

        XCTAssertEqual(result.hourHeight, 81, accuracy: 0.0001)
        XCTAssertEqual(result.focalMinute, 60.0 * (4.0 * 54 + 200) / 54, accuracy: 0.0001)
        XCTAssertEqual(
            60 * (result.scrollOffset + 200) / result.hourHeight,
            result.focalMinute,
            accuracy: 0.0001,
            "The wall-clock minute under the pinch must stay under the same viewport point"
        )
    }

    func testTimelineZoomClampsDensityAndScrollToFiniteContentBounds() {
        let result = CalendarInteractionLayout.zoomedTimeline(
            hourHeight: CalendarInteractionLayout.defaultHourHeight,
            scrollOffset: .infinity,
            focalViewportOffset: .infinity,
            magnification: .infinity,
            viewportHeight: 600
        )

        XCTAssertEqual(result.hourHeight, CalendarInteractionLayout.maximumHourHeight)
        XCTAssertTrue(result.hourHeight.isFinite)
        XCTAssertEqual(
            result.scrollOffset,
            CalendarInteractionLayout.timelineMaximumScrollOffset(
                contentHeight: 24 * CalendarInteractionLayout.maximumHourHeight
                    + CalendarInteractionLayout.timelineEndpointClearance,
                viewportHeight: 600
            ),
            accuracy: 0.0001
        )
        XCTAssertTrue(result.scrollOffset.isFinite)
        XCTAssertGreaterThanOrEqual(result.scrollOffset, 0)

        let minimum = CalendarInteractionLayout.zoomedTimeline(
            hourHeight: CalendarInteractionLayout.defaultHourHeight,
            scrollOffset: 0,
            focalViewportOffset: 0,
            magnification: 0.25,
            viewportHeight: 600
        )
        XCTAssertEqual(minimum.hourHeight, CalendarInteractionLayout.minimumHourHeight)
        XCTAssertTrue(minimum.hourHeight.isFinite)
        XCTAssertTrue(minimum.scrollOffset.isFinite)
        XCTAssertGreaterThanOrEqual(minimum.scrollOffset, 0)
    }

    func testTimelineZoomSessionRestoresInterruptedPinchAndCommitsOnlyOnEnd() {
        var interrupted = CalendarTimelineZoomSession(
            hourHeight: 54,
            scrollOffset: 7 * 54,
            focalViewportOffset: 180
        )
        let initial = interrupted.latest
        let updated = interrupted.update(
            magnification: 1.6,
            viewportHeight: 520
        )
        XCTAssertNotNil(updated)
        XCTAssertTrue(interrupted.isActive)
        XCTAssertNotEqual(interrupted.latest.hourHeight, initial.hourHeight)

        let restored = interrupted.cancel()
        XCTAssertEqual(restored?.hourHeight, interrupted.startingHourHeight)
        XCTAssertEqual(restored?.scrollOffset, interrupted.startingScrollOffset)
        XCTAssertFalse(interrupted.isActive)
        XCTAssertNil(interrupted.update(magnification: 0.8, viewportHeight: 520))

        var completed = CalendarTimelineZoomSession(
            hourHeight: 54,
            scrollOffset: 7 * 54,
            focalViewportOffset: 180
        )
        let committed = completed.update(magnification: 0.8, viewportHeight: 520)
        XCTAssertEqual(completed.complete(), committed)
        XCTAssertFalse(completed.isActive)
        XCTAssertNil(completed.complete(), "A completed pinch must not persist a second terminal sample")
    }

    func testTimelineEditAndZoomOwnershipCannotOverlapInEitherDirection() {
        XCTAssertTrue(CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: false,
            hasProvisionalPreview: false
        ))
        XCTAssertFalse(CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: true,
            hasProvisionalPreview: false
        ), "An active event move or resize owns the timeline before zoom begins")
        XCTAssertFalse(CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: false,
            hasProvisionalPreview: true
        ), "A provisional edit remains the owner until local durability completes")

        var zoom = CalendarTimelineZoomSession(
            hourHeight: 54,
            scrollOffset: 200,
            focalViewportOffset: 160
        )
        XCTAssertNotNil(zoom.update(magnification: 1.3, viewportHeight: 500))
        XCTAssertTrue(zoom.isActive)
        XCTAssertFalse(
            CalendarGestureArbitration.nativeVerticalTimelineScrollEnabled(
                eventMutationActive: false,
                hasProvisionalPreview: true
            ),
            "An edit preview must take the native scroll axis back from zoom")
        let restored = zoom.cancel()
        XCTAssertEqual(restored?.hourHeight ?? -1, 54, accuracy: 0.0001)
        XCTAssertEqual(restored?.scrollOffset ?? -1, 200, accuracy: 0.0001)

        for surface in ["empty grid", "event body", "resize handle"] {
            XCTAssertTrue(
                CalendarGestureArbitration.nativeVerticalTimelineScrollEnabled(
                    eventMutationActive: false,
                    hasProvisionalPreview: false
                ),
                "Native scrolling owns the \(surface) while idle"
            )
            XCTAssertFalse(
                CalendarGestureArbitration.nativeVerticalTimelineScrollEnabled(
                    eventMutationActive: true,
                    hasProvisionalPreview: false
                ),
                "The editing gesture owns the \(surface) after acquisition"
            )
        }
    }

    func testIPhoneTimelineZoomIsAcceptedOnlyWhenIdle() {
        XCTAssertTrue(CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: false,
            hasProvisionalPreview: false
        ))

        var session = CalendarTimelineZoomSession(
            hourHeight: 54,
            scrollOffset: 240,
            focalViewportOffset: 220
        )
        let updated = session.update(magnification: 1.25, viewportHeight: 520)
        XCTAssertNotNil(updated)
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.startingHourHeight, 54, accuracy: 0.0001)
    }

    func testIPhoneTimelineZoomIsRejectedDuringEditOrProvisionalPreview() {
        for state in [
            (eventMoveActive: true, hasProvisionalPreview: false),
            (eventMoveActive: false, hasProvisionalPreview: true),
            (eventMoveActive: true, hasProvisionalPreview: true)
        ] {
            XCTAssertFalse(CalendarGestureArbitration.timelineZoomEnabled(
                eventMutationActive: state.eventMoveActive,
                hasProvisionalPreview: state.hasProvisionalPreview
            ))
        }

        var session = CalendarTimelineZoomSession(
            hourHeight: 54,
            scrollOffset: 240,
            focalViewportOffset: 220
        )
        let initial = session.latest
        for state in [
            (eventMoveActive: true, hasProvisionalPreview: false),
            (eventMoveActive: false, hasProvisionalPreview: true)
        ] where !CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: state.eventMoveActive,
            hasProvisionalPreview: state.hasProvisionalPreview
        ) {
            // The iPhone handler returns before it creates/updates a zoom
            // session when either edit owner is present.
            XCTAssertEqual(session.latest, initial)
            XCTAssertTrue(session.isActive)
        }
        _ = session.cancel()
    }

    func testIPhoneTimelineZoomCancellationRestoresExactScaleWithoutCommit() {
        var session = CalendarTimelineZoomSession(
            hourHeight: 73.25,
            scrollOffset: 417.5,
            focalViewportOffset: 180
        )
        XCTAssertNotNil(session.update(magnification: 1.42, viewportHeight: 610))

        let restored = session.cancel()
        XCTAssertEqual(restored?.hourHeight ?? -1, 73.25, accuracy: 0.0001)
        XCTAssertEqual(restored?.scrollOffset ?? -1, 417.5, accuracy: 0.0001)
        XCTAssertFalse(session.isActive)
        XCTAssertNil(session.complete(), "A cancelled pinch cannot commit a calendar mutation")
    }

    func testIPhoneZoomStartsOnFirstGestureAfterAnIdleEditRelease() throws {
        var transaction = CalendarTimelineZoomTransaction()

        XCTAssertFalse(CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: true,
            hasProvisionalPreview: false
        ))
        // Releasing the edit has no active zoom to reject. The next gesture
        // must be able to acquire the transaction immediately.
        XCTAssertNil(transaction.cancel())
        XCTAssertTrue(CalendarGestureArbitration.timelineZoomEnabled(
            eventMutationActive: false,
            hasProvisionalPreview: false
        ))

        let token = try XCTUnwrap(transaction.begin(
            hourHeight: 54,
            scrollOffset: 12 * 54,
            focalViewportOffset: 220
        ))
        XCTAssertNotNil(transaction.update(
            token: token,
            magnification: 1.18,
            viewportHeight: 520
        ))
        XCTAssertTrue(transaction.isActive)
    }

    func testIPhoneZoomInterruptionAllowsNextPinchAndIgnoresOldCompletion() throws {
        var transaction = CalendarTimelineZoomTransaction()
        let first = try XCTUnwrap(transaction.begin(
            hourHeight: 54,
            scrollOffset: 12 * 54,
            focalViewportOffset: 220
        ))
        XCTAssertNotNil(transaction.update(
            token: first,
            magnification: 1.35,
            viewportHeight: 520
        ))
        XCTAssertNotNil(transaction.cancel(token: first))
        XCTAssertFalse(transaction.isActive)

        let second = try XCTUnwrap(transaction.begin(
            hourHeight: 54,
            scrollOffset: 12 * 54,
            focalViewportOffset: 220
        ))
        XCTAssertNotEqual(first, second)
        XCTAssertNotNil(transaction.update(
            token: second,
            magnification: 0.86,
            viewportHeight: 520
        ))
        XCTAssertNil(transaction.finish(token: first), "A stale ended callback cannot finish the newer pinch")
        XCTAssertTrue(transaction.isActive)
        XCTAssertNotNil(transaction.finish(token: second))
    }

    func testEditingDuringIPhoneZoomCancelsOnlyCurrentSessionAndCannotCommitStaleState() throws {
        var transaction = CalendarTimelineZoomTransaction()
        let first = try XCTUnwrap(transaction.begin(
            hourHeight: 73.25,
            scrollOffset: 16 * 73.25,
            focalViewportOffset: 180
        ))
        XCTAssertNotNil(transaction.update(
            token: first,
            magnification: 1.42,
            viewportHeight: 610
        ))

        let restored = try XCTUnwrap(transaction.cancel(token: first))
        XCTAssertEqual(restored.hourHeight, 73.25, accuracy: 0.0001)
        XCTAssertEqual(restored.scrollOffset, 16 * 73.25, accuracy: 0.0001)
        XCTAssertNil(transaction.finish(token: first))
        XCTAssertNil(transaction.update(
            token: first,
            magnification: 0.8,
            viewportHeight: 610
        ))
        XCTAssertFalse(transaction.isActive)
    }

    func testIPhoneZoomPreservesFocalTimeBelowMidnightDuringPreviewAndCommit() throws {
        var transaction = CalendarTimelineZoomTransaction()
        let baselineHourHeight = 54.0
        let baselineOffset = 14 * baselineHourHeight
        let focalViewportOffset = 236.0
        let token = try XCTUnwrap(transaction.begin(
            hourHeight: baselineHourHeight,
            scrollOffset: baselineOffset,
            focalViewportOffset: focalViewportOffset
        ))

        let preview = try XCTUnwrap(transaction.update(
            token: token,
            magnification: 1.4,
            viewportHeight: 520
        ))
        XCTAssertGreaterThan(preview.focalMinute, 16 * 60, "The fixture must exercise a position well below midnight")
        XCTAssertEqual(
            60 * (preview.scrollOffset + focalViewportOffset) / preview.hourHeight,
            preview.focalMinute,
            accuracy: 0.0001
        )

        let committed = try XCTUnwrap(transaction.finish(token: token))
        XCTAssertEqual(committed, preview, "Commit must settle the same offset used by the live preview")
    }

    func testIPhoneZoomCancelRestoresBaselineHourHeightAndContentOffsetExactly() throws {
        var transaction = CalendarTimelineZoomTransaction()
        let baselineHourHeight = 73.25
        let baselineOffset = 17.125 * baselineHourHeight
        let token = try XCTUnwrap(transaction.begin(
            hourHeight: baselineHourHeight,
            scrollOffset: baselineOffset,
            focalViewportOffset: 180
        ))
        XCTAssertNotNil(transaction.update(
            token: token,
            magnification: 1.42,
            viewportHeight: 610
        ))

        let restored = try XCTUnwrap(transaction.cancel(token: token))
        XCTAssertEqual(restored.hourHeight, baselineHourHeight, accuracy: 0.0001)
        XCTAssertEqual(restored.scrollOffset, baselineOffset, accuracy: 0.0001)
        XCTAssertNil(transaction.cancel(token: token), "Repeated cancellation must be idempotent")
    }

    func testIPhoneZoomLifecycleCancellationClearsStateForEditViewAndScene() throws {
        for interruption in ["edit acquisition", "view disappearance", "scene interruption"] {
            var transaction = CalendarTimelineZoomTransaction()
            let token = try XCTUnwrap(transaction.begin(
                hourHeight: 54,
                scrollOffset: 13 * 54,
                focalViewportOffset: 200
            ))
            XCTAssertNotNil(transaction.update(
                token: token,
                magnification: 1.25,
                viewportHeight: 520
            ))
            XCTAssertNotNil(transaction.cancel(token: token), "(interruption) must return the captured baseline")
            XCTAssertFalse(transaction.isActive, "(interruption) must clear ownership")
            XCTAssertNil(transaction.finish(token: token), "(interruption) must invalidate stale completion")
            XCTAssertNil(transaction.cancel(token: token), "(interruption) cancellation must run only once")
        }
    }

    func testTimelineScrollAnchorRetainsWallTimeAndInitializesTwoHoursBeforeNow() throws {
        let now = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 12,
            hour: 15,
            minute: 42
        )))
        let initial = CalendarTimelineScrollAnchor.todayMinusTwoHours(now: now, calendar: calendar)
        XCTAssertEqual(initial.wallMinute, 13 * 60 + 42)
        XCTAssertEqual(initial.hour, 13)

        let retained = CalendarTimelineScrollAnchor.from(scrollOffset: 8.5 * 54, hourHeight: 54)
        XCTAssertEqual(retained.wallMinute, 8 * 60 + 30)
        XCTAssertEqual(retained.offset(hourHeight: 54), 8.5 * 54, accuracy: 0.0001)
        XCTAssertEqual(CalendarTimelineScrollAnchor.id(for: retained.hour), "calendar-timeline-hour-8")
    }

    @MainActor
    func testCalendarPresentationStateRetainsTimelineAnchorAcrossRemount() {
        let anchor = CalendarTimelineScrollAnchor(wallMinute: 22 * 60 + 45)
        let state = CalendarPresentationState(
            selectedDate: Date(timeIntervalSinceReferenceDate: 800_000_000),
            timelineScrollAnchor: anchor
        )

        XCTAssertEqual(state.timelineScrollAnchor, anchor)
        XCTAssertTrue(state.didRestoreTimelinePosition)
    }

    @MainActor
    func testCalendarPresentationStateDefaultsToCalendarDensity() {
        let state = CalendarPresentationState()

        XCTAssertEqual(
            state.hourHeight,
            CGFloat(CalendarInteractionLayout.defaultHourHeight),
            accuracy: 0.0001
        )
    }

    func testCalendarTimelineRestorationPolicyUsesRequestThenSceneAnchorThenDefault() {
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let retained = CalendarTimelineScrollAnchor(wallMinute: 22 * 60 + 45)
        let requestAnchor = CalendarTimelineScrollAnchor(wallMinute: 7 * 60 + 15)
        let request = CalendarTimelineScrollRequest(id: 4, anchor: requestAnchor)

        XCTAssertEqual(
            CalendarTimelineRestorationPolicy.anchor(
                request: request,
                retained: retained,
                didRestore: true,
                now: now,
                calendar: berlin
            ),
            requestAnchor
        )
        XCTAssertEqual(
            CalendarTimelineRestorationPolicy.anchor(
                request: nil,
                retained: retained,
                didRestore: true,
                now: now,
                calendar: berlin
            ),
            retained
        )
        XCTAssertEqual(
            CalendarTimelineRestorationPolicy.anchor(
                request: nil,
                retained: nil,
                didRestore: false,
                now: now,
                calendar: berlin
            ),
            CalendarTimelineScrollAnchor.todayMinusTwoHours(now: now, calendar: berlin)
        )
    }

    func testCalendarTimelineRestorationUsesMinutePreciseNativeOffsetAfterHourFallback() {
        let anchor = CalendarTimelineScrollAnchor(wallMinute: 14 * 60 + 45)
        let hourHeight = 54.0
        let exactOffset = CalendarTimelineRestorationPolicy.nativeOffset(
            for: anchor,
            hourHeight: hourHeight
        )

        XCTAssertEqual(exactOffset ?? -1, 14.75 * hourHeight, accuracy: 0.0001)
        XCTAssertFalse(
            CalendarTimelineRestorationPolicy.isNativeOffsetSettled(
                observedOffset: 14 * hourHeight,
                targetOffset: exactOffset ?? 0
            ),
            "The coarse hour target must remain pending until the retained minute is reapplied"
        )
        XCTAssertTrue(
            CalendarTimelineRestorationPolicy.isNativeOffsetSettled(
                observedOffset: exactOffset ?? 0,
                targetOffset: exactOffset ?? 0
            )
        )
        XCTAssertNil(
            CalendarTimelineRestorationPolicy.nativeOffset(for: anchor, hourHeight: 0),
            "An invalid layout scale must not create a native restoration target"
        )
    }

    func testCalendarTimelineRestorationClampsLateDayRequestToAttainableBottomEdge() {
        let requestedOffset = 23.75 * 54.0
        let adjustment = 18.0
        let minimumNativeOffset = -24.0
        let maximumNativeOffset = 1_000.0

        let attainable = CalendarTimelineRestorationPolicy.attainableSemanticOffset(
            requestedOffset: requestedOffset,
            nativeOffsetAdjustment: adjustment,
            minimumNativeOffset: minimumNativeOffset,
            maximumNativeOffset: maximumNativeOffset
        )

        XCTAssertEqual(
            attainable ?? -1,
            maximumNativeOffset - adjustment,
            accuracy: 0.0001,
            "A requested late-day offset must settle at UIKit's attainable bottom edge"
        )
        XCTAssertGreaterThan(
            requestedOffset + adjustment,
            maximumNativeOffset,
            "The fixture must exercise the native content-size clamp"
        )
    }

    func testCalendarTimelineRestorationSettlesAgainstClampedTargetAndResumesTracking() {
        let retained = CalendarTimelineScrollAnchor(wallMinute: 23 * 60 + 45)
        let hourHeight = 54.0
        let requestedOffset = retained.offset(hourHeight: hourHeight)
        let adjustment = 18.0
        let attainable = CalendarTimelineRestorationPolicy.attainableSemanticOffset(
            requestedOffset: requestedOffset,
            nativeOffsetAdjustment: adjustment,
            minimumNativeOffset: -24.0,
            maximumNativeOffset: 1_000.0
        )!

        XCTAssertFalse(
            CalendarTimelineRestorationPolicy.isNativeOffsetSettled(
                observedOffset: attainable,
                targetOffset: requestedOffset
            ),
            "The original late-day request must not be treated as attainable"
        )
        XCTAssertTrue(
            CalendarTimelineRestorationPolicy.isNativeOffsetSettled(
                observedOffset: attainable,
                targetOffset: attainable
            ),
            "The pending restoration must clear once the clamped native position is observed"
        )
        XCTAssertTrue(
            CalendarTimelineRestorationPolicy.shouldRecordObservedOffset(
                observedOffset: attainable,
                retainedAnchor: retained,
                hourHeight: hourHeight,
                isRestoring: false,
                isZooming: false
            ),
            "After the clamped target settles, a subsequent native observation can resume anchor tracking"
        )
    }

    func testCalendarTimelineRestorationSuppressesTransientAndZoomOffsetsButKeepsUserTracking() {
        let anchor = CalendarTimelineScrollAnchor(wallMinute: 14 * 60 + 45)
        let hourHeight = 54.0
        let exactOffset = anchor.offset(hourHeight: hourHeight)

        XCTAssertFalse(
            CalendarTimelineRestorationPolicy.shouldRecordObservedOffset(
                observedOffset: 14 * hourHeight,
                retainedAnchor: anchor,
                hourHeight: hourHeight,
                isRestoring: true,
                isZooming: false
            ),
            "The initial 14:00 ScrollViewReader result must not overwrite 14:45"
        )
        XCTAssertFalse(
            CalendarTimelineRestorationPolicy.shouldRecordObservedOffset(
                observedOffset: exactOffset,
                retainedAnchor: anchor,
                hourHeight: hourHeight,
                isRestoring: false,
                isZooming: false
            )
        )
        XCTAssertFalse(
            CalendarTimelineRestorationPolicy.shouldRecordObservedOffset(
                observedOffset: exactOffset + hourHeight,
                retainedAnchor: anchor,
                hourHeight: hourHeight,
                isRestoring: false,
                isZooming: true
            ),
            "Zoom owns the offset until its transaction settles"
        )
        XCTAssertTrue(
            CalendarTimelineRestorationPolicy.shouldRecordObservedOffset(
                observedOffset: exactOffset + hourHeight,
                retainedAnchor: anchor,
                hourHeight: hourHeight,
                isRestoring: false,
                isZooming: false
            ),
            "A later native user scroll must continue updating the scene-owned anchor"
        )
    }

    func testTodayVisibilityUsesTheSameDaySurfaceWindowAsHourSuppression() {
        let common = (
            dayCount: 7,
            columnWidth: 100.0,
            columnOriginX: 40.0,
            timeGutter: 40.0,
            contentWidth: 740.0,
            viewportWidth: 300.0
        )
        XCTAssertTrue(CalendarInteractionLayout.isTimelineDayColumnVisible(
            dayIndex: 0,
            dayCount: common.dayCount,
            columnWidth: common.columnWidth,
            columnOriginX: common.columnOriginX,
            timeGutter: common.timeGutter,
            contentWidth: common.contentWidth,
            viewportWidth: common.viewportWidth,
            horizontalContentOffset: 0
        ))
        XCTAssertTrue(CalendarInteractionLayout.isTimelineDayColumnVisible(
            dayIndex: 2,
            dayCount: common.dayCount,
            columnWidth: common.columnWidth,
            columnOriginX: common.columnOriginX,
            timeGutter: common.timeGutter,
            contentWidth: common.contentWidth,
            viewportWidth: common.viewportWidth,
            horizontalContentOffset: 0
        ), "A partially visible today column still owns the marker")
        XCTAssertFalse(CalendarInteractionLayout.isTimelineDayColumnVisible(
            dayIndex: 3,
            dayCount: common.dayCount,
            columnWidth: common.columnWidth,
            columnOriginX: common.columnOriginX,
            timeGutter: common.timeGutter,
            contentWidth: common.contentWidth,
            viewportWidth: common.viewportWidth,
            horizontalContentOffset: 0
        ))
        XCTAssertTrue(CalendarInteractionLayout.isTimelineDayColumnVisible(
            dayIndex: 2,
            dayCount: common.dayCount,
            columnWidth: common.columnWidth,
            columnOriginX: common.columnOriginX,
            timeGutter: common.timeGutter,
            contentWidth: common.contentWidth,
            viewportWidth: common.viewportWidth,
            horizontalContentOffset: 300
        ))
        XCTAssertFalse(CalendarInteractionLayout.isTimelineDayColumnVisible(
            dayIndex: 1,
            dayCount: common.dayCount,
            columnWidth: common.columnWidth,
            columnOriginX: common.columnOriginX,
            timeGutter: common.timeGutter,
            contentWidth: common.contentWidth,
            viewportWidth: common.viewportWidth,
            horizontalContentOffset: 300
        ))
    }

    func testPagerSettleDurationIsBoundedSpeedScaledAndBounceFree() {
        // Idle releases take the full damped travel; hard flicks settle fast.
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: 0),
            CalendarInteractionLayout.pagerIdleSettleDuration
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: 3),
            CalendarInteractionLayout.pagerFlickSettleDuration
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: -3),
            CalendarInteractionLayout.pagerFlickSettleDuration,
            "Direction must not change the settle duration"
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: .nan),
            CalendarInteractionLayout.pagerIdleSettleDuration
        )
        XCTAssertLessThan(
            CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: 1.5),
            CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: 0.5),
            "Faster releases must settle no slower than slow ones"
        )
        XCTAssertTrue(
            (CalendarInteractionLayout.pagerFlickSettleDuration...CalendarInteractionLayout.pagerIdleSettleDuration)
                .contains(CalendarInteractionLayout.pagerSettleDuration(normalizedVelocity: 900))
        )
    }

    func testPagerSettleVelocityPrefersTrackerMomentumAndFallsBackToProjection() {
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleVelocity(
                normalizedTrackerVelocity: -2.4,
                hasTrackerMomentum: true,
                projectionVelocity: 0
            ),
            -2.4
        )
        // A tracker without a real estimate must not mask the projection.
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleVelocity(
                normalizedTrackerVelocity: -2.4,
                hasTrackerMomentum: false,
                projectionVelocity: -1.1
            ),
            -1.1
        )
        // Sub-threshold tracker motion defers to the projection.
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleVelocity(
                normalizedTrackerVelocity: 0.1,
                hasTrackerMomentum: true,
                projectionVelocity: -0.9
            ),
            -0.9
        )
        // Both inputs are clamped to the bounded spring range.
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleVelocity(
                normalizedTrackerVelocity: 42,
                hasTrackerMomentum: true,
                projectionVelocity: 0
            ),
            3
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerSettleVelocity(
                normalizedTrackerVelocity: .nan,
                hasTrackerMomentum: true,
                projectionVelocity: -5
            ),
            -3
        )
    }

    func testPagerFingerVelocityTrackerEstimatesSignedPointsPerSecond() {
        var tracker = CalendarPagerFingerVelocity()
        XCTAssertFalse(tracker.hasEstimate)
        // First sample only establishes the reference point.
        tracker.sample(x: 0, timeSeconds: 100)
        XCTAssertEqual(tracker.pixelsPerSecond, 0)
        XCTAssertFalse(tracker.hasEstimate)

        // -60pt over 0.1s -> -600pt/s (finger moving toward later dates).
        tracker.sample(x: -60, timeSeconds: 100.1)
        XCTAssertEqual(tracker.pixelsPerSecond, -600, accuracy: 0.0001)
        XCTAssertTrue(tracker.hasEstimate)

        // EMA smooths the next estimate instead of jumping.
        tracker.sample(x: -120, timeSeconds: 100.25)
        XCTAssertEqual(tracker.pixelsPerSecond, 0.55 * (-400) + 0.45 * (-600), accuracy: 0.0001)

        // Sub-millisecond samples cannot divide by a near-zero interval.
        let frozen = tracker.pixelsPerSecond
        tracker.sample(x: -1_000, timeSeconds: 100.2501)
        XCTAssertEqual(tracker.pixelsPerSecond, frozen)

        // Non-finite input is ignored and reset clears everything.
        tracker.sample(x: .nan, timeSeconds: 101)
        XCTAssertEqual(tracker.pixelsPerSecond, frozen)
        tracker.reset()
        XCTAssertFalse(tracker.hasEstimate)
        XCTAssertEqual(tracker.pixelsPerSecond, 0)
    }

    func testAllDayLaneFollowsEntriesPlusOneCellRule() throws {
        let anchor = DateComponents(calendar: calendar, year: 2026, month: 7, day: 31).date!
        let day1 = calendar.date(byAdding: .day, value: 1, to: anchor)!
        let day2 = calendar.date(byAdding: .day, value: 2, to: anchor)!
        let day3 = calendar.date(byAdding: .day, value: 3, to: anchor)!
        let days = [anchor, day1, day2]

        // Zero entries -> exactly ONE empty cell.
        XCTAssertEqual(
            CalendarAllDayLayout.rowCount(items: [], days: days, calendar: calendar),
            1
        )
        XCTAssertEqual(
            CalendarAllDayLayout.height(items: [], days: days, calendar: calendar),
            CalendarAllDayLayout.rowHeight
        )

        // One entry -> its own cell plus exactly one empty cell below it.
        let lone = try CalendarItem(title: "Lone", start: anchor, end: day1)
        XCTAssertEqual(
            CalendarAllDayLayout.rowCount(items: [lone], days: days, calendar: calendar),
            2
        )
        XCTAssertEqual(
            CalendarAllDayLayout.height(items: [lone], days: days, calendar: calendar),
            CalendarAllDayLayout.rowHeight * 2 + CalendarAllDayLayout.rowSpacing
        )

        let first = try CalendarItem(title: "First", start: anchor, end: day1)
        let adjacent = try CalendarItem(title: "Adjacent", start: day1, end: day2)
        let overlapping = try CalendarItem(title: "Overlapping", start: anchor, end: day3)
        let timedStart = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: anchor)!
        let timedEnd = calendar.date(byAdding: .hour, value: 1, to: timedStart)!
        let timed = try CalendarItem(title: "Timed", start: timedStart, end: timedEnd)
        let deleted = try CalendarItem(title: "Deleted", start: anchor, end: day1).deleting(at: anchor.addingTimeInterval(1))

        // Every all-day entry keeps deterministic placement data and its own
        // row. The trailing row remains the creation surface.
        let placements = CalendarAllDayLayout.placements(
            items: [first, adjacent, overlapping, timed, deleted],
            days: days,
            calendar: calendar
        )
        let byTitle = Dictionary(uniqueKeysWithValues: placements.map { ($0.item.title, $0) })
        XCTAssertEqual(placements.count, 3, "Timed and deleted items must never enter the lane")
        // Deterministic lane order: start ascending, then end ascending.
        XCTAssertEqual(byTitle["First"]?.row, 0)
        XCTAssertEqual(byTitle["Overlapping"]?.row, 1)
        XCTAssertEqual(byTitle["Adjacent"]?.row, 2, "Every entry owns its own cell")
        XCTAssertEqual(byTitle["First"]?.firstDayIndex, 0)
        XCTAssertEqual(byTitle["Adjacent"]?.firstDayIndex, 1)
        XCTAssertEqual(byTitle["Overlapping"]?.firstDayIndex, 0)
        XCTAssertEqual(byTitle["First"]?.dayCount, 1)
        XCTAssertEqual(byTitle["Adjacent"]?.dayCount, 1)
        XCTAssertEqual(byTitle["Overlapping"]?.dayCount, 3)

        let entries = [first, adjacent, overlapping]
        XCTAssertEqual(
            CalendarAllDayLayout.rowCount(items: entries, days: days, calendar: calendar),
            4,
            "three entry rows + one trailing empty cell"
        )
        XCTAssertEqual(
            CalendarAllDayLayout.height(items: entries, days: days, calendar: calendar),
            CalendarAllDayLayout.rowHeight * 4 + CalendarAllDayLayout.rowSpacing * 3
        )

        let trailingRow = CalendarAllDayLayout.trailingEmptyRowIndex(
            items: entries,
            days: days,
            calendar: calendar
        )
        XCTAssertEqual(trailingRow, 3)
        let trailingCell = try XCTUnwrap(CalendarAllDayLayout.trailingEmptyCellFrame(
            dayIndex: 1,
            dayWidth: 120,
            items: entries,
            days: days,
            calendar: calendar
        ))
        XCTAssertEqual(trailingCell, CGRect(x: 120, y: 84, width: 120, height: 26))
        XCTAssertEqual(
            CalendarAllDayLayout.trailingEmptyCellDay(
                at: CGPoint(x: 180, y: 97),
                dayWidth: 120,
                items: entries,
                days: days,
                calendar: calendar
            ),
            calendar.startOfDay(for: day1)
        )
        XCTAssertNil(
            CalendarAllDayLayout.trailingEmptyCellDay(
                at: CGPoint(x: 180, y: 80),
                dayWidth: 120,
                items: entries,
                days: days,
                calendar: calendar
            ),
            "The inter-row spacing must not be a creation hit target"
        )
        XCTAssertEqual(
            CalendarAllDayLayout.trailingEmptyCellAccessibilityIdentifier(
                for: day1,
                calendar: calendar
            ),
            "calendar-empty-all-day-2026-08-01"
        )
    }

    func testAllDayLaneKeepsEveryEntryAndTrailingCell() throws {
        let anchor = try XCTUnwrap(DateComponents(
            calendar: calendar,
            year: 2026,
            month: 7,
            day: 31
        ).date)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: anchor))
        let days = [anchor]
        let entries = try (0..<40).map { index in
            try CalendarItem(
                title: "All-day \(index)",
                start: anchor,
                end: nextDay,
                createdAt: anchor,
                updatedAt: anchor
            )
        }

        let placements = CalendarAllDayLayout.placements(items: entries, days: days, calendar: calendar)
        XCTAssertEqual(placements.count, entries.count)
        XCTAssertEqual(
            CalendarAllDayLayout.rowCount(items: entries, days: days, calendar: calendar),
            entries.count + 1,
            "Every all-day entry owns one row plus one trailing empty cell"
        )
        XCTAssertEqual(
            CalendarAllDayLayout.trailingEmptyRowIndex(items: entries, days: days, calendar: calendar),
            entries.count
        )

        let allDayHeight = CalendarAllDayLayout.height(items: entries, days: days, calendar: calendar)
        XCTAssertEqual(
            allDayHeight,
            Double(entries.count + 1) * CalendarAllDayLayout.rowHeight
                + Double(entries.count) * CalendarAllDayLayout.rowSpacing
        )

        let smallestTimedViewport = CalendarInteractionLayout.timedViewportHeight(
            containerHeight: 58 + allDayHeight + 1,
            dayHeaderHeight: 58,
            allDayHeight: allDayHeight
        )
        XCTAssertEqual(smallestTimedViewport, 1)
        let axisHeight = CalendarInteractionLayout.timelineHeight(
            days: days,
            hourHeight: CalendarInteractionLayout.minimumHourHeight,
            calendar: calendar
        )
        let contentHeight = CalendarInteractionLayout.timelineContentHeight(
            days: days,
            hourHeight: CalendarInteractionLayout.minimumHourHeight,
            calendar: calendar
        )
        let maximumOffset = CalendarInteractionLayout.timelineMaximumScrollOffset(
            contentHeight: contentHeight,
            viewportHeight: smallestTimedViewport
        )
        XCTAssertGreaterThan(maximumOffset, 0)
        XCTAssertGreaterThanOrEqual(maximumOffset + smallestTimedViewport, axisHeight)
        XCTAssertGreaterThanOrEqual(maximumOffset + smallestTimedViewport, 23 * CalendarInteractionLayout.minimumHourHeight)
    }

    func testAllDayRowsIgnoreOffWindowItemsAndRecurringRenderIDsStayUnique() throws {
        let anchor = try XCTUnwrap(DateComponents(
            calendar: calendar,
            year: 2026,
            month: 7,
            day: 31
        ).date)
        let day1 = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: anchor))
        let day2 = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: anchor))
        let before = try XCTUnwrap(calendar.date(byAdding: .day, value: -2, to: anchor))
        let after = try XCTUnwrap(calendar.date(byAdding: .day, value: 3, to: anchor))
        let days = [anchor, day1, day2]

        let visibleFirst = try CalendarItem(title: "Visible first", start: anchor, end: day1)
        let visibleSecond = try CalendarItem(title: "Visible second", start: day1, end: day2)
        let offWindowBefore = try CalendarItem(title: "Off-window before", start: before, end: anchor)
        let afterEnd = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: after))
        let offWindowAfter = try CalendarItem(title: "Off-window after", start: after, end: afterEnd)

        let placements = CalendarAllDayLayout.placements(
            items: [offWindowBefore, visibleFirst, offWindowAfter, visibleSecond],
            days: days,
            calendar: calendar
        )
        XCTAssertEqual(placements.map(\.item.title), ["Visible first", "Visible second"])
        XCTAssertEqual(placements.map(\.row), [0, 1], "Visible rows must be contiguous after filtering the window")
        XCTAssertEqual(
            CalendarAllDayLayout.rowCount(items: [offWindowBefore, visibleFirst, offWindowAfter, visibleSecond], days: days, calendar: calendar),
            placements.count + 1,
            "The trailing creation row follows visible events only"
        )

        let recurrence = try CalendarRecurrenceRule(frequency: .daily, until: day1)
        let recurring = try CalendarItem(title: "Recurring all-day", start: anchor, end: day1, recurrence: recurrence)
        let occurrences = CalendarRecurrence.occurrences(
            of: recurring,
            overlapping: DateInterval(start: anchor, end: day2),
            calendar: calendar
        )
        let occurrencePlacements = CalendarAllDayLayout.placements(
            items: occurrences,
            days: days,
            calendar: calendar
        )
        XCTAssertEqual(occurrencePlacements.count, 2)
        XCTAssertEqual(Set(occurrencePlacements.map(\.renderID)).count, occurrencePlacements.count)
        XCTAssertTrue(occurrencePlacements.dropFirst().allSatisfy {
            $0.renderID.hasPrefix(recurring.id.uuidString + "-")
        })
        XCTAssertEqual(
            occurrencePlacements.map(\.renderID),
            occurrences.map(CalendarAllDayLayout.renderIdentity(for:))
        )
    }

    func testTimedRecurringPlacementsExposeStableUniqueRenderIDs() throws {
        let anchor = try XCTUnwrap(DateComponents(
            calendar: calendar,
            year: 2026,
            month: 7,
            day: 31,
            hour: 9
        ).date)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: anchor))
        let until = try XCTUnwrap(calendar.date(byAdding: .day, value: 2, to: anchor))
        let rule = try CalendarRecurrenceRule(frequency: .daily, until: until)
        let recurring = try CalendarItem(
            title: "Recurring timed",
            start: anchor,
            end: nextDay,
            recurrence: rule
        )
        let occurrences = CalendarRecurrence.occurrences(
            of: recurring,
            overlapping: DateInterval(start: anchor, end: until),
            calendar: calendar
        )
        let placements = CalendarOverlapLayout.layout(
            items: occurrences,
            interval: DateInterval(start: anchor, end: until),
        )

        XCTAssertEqual(placements.count, occurrences.count)
        XCTAssertEqual(Set(placements.map(\.renderID)).count, placements.count)
        XCTAssertTrue(placements.dropFirst().allSatisfy { $0.renderID.hasPrefix(recurring.id.uuidString + "-") })
        XCTAssertEqual(placements.first?.renderID, recurring.id.uuidString)
    }

    func testPagerDaySurfaceStartsAtThe40PointGutterBoundary() {
        XCTAssertFalse(CalendarInteractionLayout.isPagerStartInDaySurface(startX: 39.99, timeGutter: 40))
        XCTAssertTrue(CalendarInteractionLayout.isPagerStartInDaySurface(startX: 40, timeGutter: 40))
        XCTAssertTrue(CalendarInteractionLayout.isPagerStartInDaySurface(startX: 40.01, timeGutter: 40))
        XCTAssertFalse(CalendarInteractionLayout.isPagerStartInDaySurface(startX: .nan, timeGutter: 40))
    }

    func testCalendarEditorDoesNotInferTimedMidnightEndingEventAsAllDay() throws {
        let day = try XCTUnwrap(DateComponents(calendar: calendar, year: 2026, month: 7, day: 31).date)
        let nextDay = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: day))
        let timedStart = try XCTUnwrap(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: day))
        let timed = try CalendarItem(title: "Late event", start: timedStart, end: nextDay)
        let allDay = try CalendarItem(title: "All day", start: day, end: nextDay)

        XCTAssertFalse(CalendarEditor.inferredAllDay(item: timed, start: timed.start, endDate: nil, calendar: calendar))
        XCTAssertTrue(CalendarEditor.inferredAllDay(item: allDay, start: allDay.start, endDate: nil, calendar: calendar))
        XCTAssertFalse(CalendarEditor.inferredAllDay(item: nil, start: timedStart, endDate: nextDay, calendar: calendar))
        XCTAssertTrue(CalendarEditor.inferredAllDay(item: nil, start: day, endDate: nextDay, calendar: calendar))
    }

    func testTimedViewportLeavesFullDayContentScrollableInsideFinitePage() {
        XCTAssertEqual(
            CalendarInteractionLayout.timedViewportHeight(
                containerHeight: 800,
                dayHeaderHeight: 58,
                allDayHeight: 26
            ),
            716
        )
        XCTAssertEqual(
            CalendarInteractionLayout.timedViewportHeight(
                containerHeight: 60,
                dayHeaderHeight: 58,
                allDayHeight: 54
            ),
            1
        )
        XCTAssertEqual(
            CalendarInteractionLayout.timedViewportHeight(
                containerHeight: .infinity,
                dayHeaderHeight: 58,
                allDayHeight: 26
            ),
            1
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
            horizontalTranslation: 12,
            verticalTranslation: 1
        ))
        XCTAssertFalse(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 10,
            verticalTranslation: 9
        ))
        XCTAssertFalse(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 1,
            verticalTranslation: 12
        ))
        XCTAssertFalse(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 12,
            verticalTranslation: 10
        ))
        XCTAssertTrue(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 13,
            verticalTranslation: 10
        ))
        XCTAssertFalse(CalendarInteractionLayout.isHorizontalPagerDrag(
            horizontalTranslation: 10,
            verticalTranslation: 12
        ))
        XCTAssertEqual(
            CalendarInteractionLayout.pagerDragAxis(horizontalTranslation: 10, verticalTranslation: 9),
            .undecided
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerDragAxis(horizontalTranslation: 12, verticalTranslation: 10),
            .undecided
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerDragAxis(horizontalTranslation: 13, verticalTranslation: 10),
            .horizontal
        )
        XCTAssertEqual(
            CalendarInteractionLayout.pagerDragAxis(horizontalTranslation: 10, verticalTranslation: 12),
            .undecided
        )
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

    /// Notion parity contract: the empty-grid press claims creation after
    /// ~0.3 s. The gesture view references this constant, so pinning it here
    /// prevents a silent regression to the slower 0.45 s hold.
    func testPressCreationHoldThresholdIsNotionFast() {
        XCTAssertEqual(CalendarInteractionLayout.creationPressHoldSeconds, 0.3, accuracy: 0.0001)
    }

    /// A simple tap (no drag) maps the tapped wall-clock position to a snapped
    /// 30-minute default block anchored at that time. A 23:50 tap must keep
    /// its anchor and cross midnight rather than being pulled back into the day.
    func testSingleTapMapsToThirtyMinuteDefaultBlockAtTappedTime() throws {
        let interval = try XCTUnwrap(
            CalendarInteractionLayout.creationInterval(
                day: dayStart,
                verticalStart: 23 * 60 + 47,
                verticalEnd: 23 * 60 + 47,
                hourHeight: 60,
                calendar: calendar,
                defaultDurationMinutes: CalendarInteractionLayout.mobileSelectionDurationMinutes
            )
        )

        XCTAssertEqual(calendar.component(.hour, from: interval.start), 23)
        XCTAssertEqual(calendar.component(.minute, from: interval.start), 45)
        XCTAssertEqual(
            CalendarInteractionLayout.calendarMinutes(from: interval.start, to: interval.end, calendar: calendar),
            30
        )
    }

    func testPressDragCreationDraftsSnappedRangeFromDownwardMovement() throws {        let sample = try XCTUnwrap(CalendarInteractionLayout.creationPressDragSample(
            day: dayStart,
            anchorY: 9 * 60,
            currentY: 10 * 60,
            hourHeight: 60,
            calendar: calendar
        ))
        XCTAssertEqual(sample, .drafted(DateInterval(
            start: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart)!,
            end: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dayStart)!
        )))
    }

    func testPressDragCreationPullsStartEarlierOnUpwardMovement() throws {
        let sample = try XCTUnwrap(CalendarInteractionLayout.creationPressDragSample(
            day: dayStart,
            anchorY: 10 * 60,
            currentY: 9 * 60 + 15,
            hourHeight: 60,
            calendar: calendar
        ))
        XCTAssertEqual(sample, .drafted(DateInterval(
            start: calendar.date(bySettingHour: 9, minute: 15, second: 0, of: dayStart)!,
            end: calendar.date(bySettingHour: 10, minute: 0, second: 0, of: dayStart)!
        )))
    }

    func testPressDragCreationKeepsDefaultBlockUntilMovementIsIntentional() throws {
        let sample = try XCTUnwrap(CalendarInteractionLayout.creationPressDragSample(
            day: dayStart,
            anchorY: 9 * 60,
            currentY: 9 * 60 + 5,
            hourHeight: 60,
            calendar: calendar
        ))
        XCTAssertEqual(sample, .pending(DateInterval(
            start: calendar.date(bySettingHour: 9, minute: 0, second: 0, of: dayStart)!,
            end: calendar.date(bySettingHour: 9, minute: 30, second: 0, of: dayStart)!
        )))
    }

    func testPressDragCreationClampsPastTheDayBoundary() throws {
        let sample = try XCTUnwrap(CalendarInteractionLayout.creationPressDragSample(
            day: dayStart,
            anchorY: 23 * 60,
            currentY: 40 * 60,
            hourHeight: 60,
            calendar: calendar
        ))
        let interval = try XCTUnwrap(
            CalendarInteractionLayout.dayInterval(containing: dayStart, calendar: calendar)
        )
        XCTAssertEqual(sample, .drafted(DateInterval(
            start: calendar.date(bySettingHour: 23, minute: 0, second: 0, of: dayStart)!,
            end: interval.end
        )))
    }

    func testPressDragCreationRejectsNonFiniteSamples() {
        XCTAssertNil(CalendarInteractionLayout.creationPressDragSample(
            day: dayStart,
            anchorY: 9 * 60,
            currentY: .infinity,
            hourHeight: 60,
            calendar: calendar
        ))
        XCTAssertNil(CalendarInteractionLayout.creationPressDragSample(
            day: dayStart,
            anchorY: .nan,
            currentY: 9 * 60,
            hourHeight: 60,
            calendar: calendar
        ))
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

    func testAllDayCreationUsesLocalMidnightBoundsAcrossDST() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let springDay = try XCTUnwrap(DateComponents(
            calendar: newYork,
            timeZone: newYork.timeZone,
            year: 2026,
            month: 3,
            day: 8
        ).date)
        let fallDay = try XCTUnwrap(DateComponents(
            calendar: newYork,
            timeZone: newYork.timeZone,
            year: 2026,
            month: 11,
            day: 1
        ).date)

        let spring = try XCTUnwrap(CalendarAllDayLayout.creationInterval(for: springDay, calendar: newYork))
        let fall = try XCTUnwrap(CalendarAllDayLayout.creationInterval(for: fallDay, calendar: newYork))

        XCTAssertEqual(newYork.component(.hour, from: spring.start), 0)
        XCTAssertEqual(newYork.component(.minute, from: spring.start), 0)
        XCTAssertEqual(newYork.component(.hour, from: spring.end), 0)
        XCTAssertEqual(newYork.component(.minute, from: spring.end), 0)
        XCTAssertEqual(spring.duration, 23 * 3_600, accuracy: 0.001)
        XCTAssertEqual(fall.duration, 25 * 3_600, accuracy: 0.001)
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

    func testDisplayCalendarDrivesSidebarTimelineAndOverlapForBerlinVsUTCFixture() throws {
        var displayCalendar = Calendar(identifier: .gregorian)
        let locale = Locale(identifier: "en_US_POSIX")
        displayCalendar.locale = locale
        displayCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let start = try XCTUnwrap(DateComponents(
            calendar: sourceCalendar,
            timeZone: sourceCalendar.timeZone,
            year: 2026,
            month: 8,
            day: 12,
            hour: 9,
            minute: 0
        ).date)
        let end = try XCTUnwrap(sourceCalendar.date(byAdding: .hour, value: 1, to: start))
        let item = try CalendarItem(
            title: "UTC meeting",
            start: start,
            end: end,
            createdAt: start,
            updatedAt: start,
            timeZoneIdentifier: "UTC"
        )
        let displayDay = displayCalendar.startOfDay(for: start)
        let displayInterval = try XCTUnwrap(displayCalendar.dateInterval(of: .day, for: displayDay))
        let scale = CalendarTimelineScale(interval: displayInterval, hourHeight: 60)

        var sidebarStyle = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        sidebarStyle.timeZone = displayCalendar.timeZone
        let sidebarTime = item.start.formatted(sidebarStyle)
        let timelineTime = CalendarTimelineScale.localizedTimeLabel(
            for: item.start,
            calendar: displayCalendar,
            locale: locale
        )
        XCTAssertEqual(sidebarTime, timelineTime)
        XCTAssertEqual(sidebarTime.replacingOccurrences(of: "\u{202F}", with: " "), "11:00 AM")
        XCTAssertEqual(sourceCalendar.component(.hour, from: item.start), 9)
        XCTAssertEqual(displayCalendar.component(.hour, from: item.start), 11)
        XCTAssertEqual(CalendarTimelineScale.wallClockMinute(for: item.start, calendar: displayCalendar), 11 * 60, accuracy: 0.001)
        XCTAssertEqual(scale.y(for: item.start, calendar: displayCalendar), 11 * 60, accuracy: 0.001)

        let placements = CalendarOverlapLayout.layout(items: [item], interval: displayInterval)
        let placement = try XCTUnwrap(placements.first)
        XCTAssertEqual(placement.visibleStart, item.start)
        XCTAssertEqual(placement.visibleEnd, item.end)
        XCTAssertEqual(placement.yStart, 11.0 / 24.0, accuracy: 0.0001)
        XCTAssertEqual(placement.yEnd, 12.0 / 24.0, accuracy: 0.0001)
    }

    func testDisplayCalendarOwnsCrossZoneDateBoundaryForTimelineAndAllDayClassification() throws {
        var displayCalendar = Calendar(identifier: .gregorian)
        displayCalendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        var sourceCalendar = Calendar(identifier: .gregorian)
        sourceCalendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))

        let start = try XCTUnwrap(DateComponents(
            calendar: sourceCalendar,
            timeZone: sourceCalendar.timeZone,
            year: 2026,
            month: 8,
            day: 12,
            hour: 22,
            minute: 30
        ).date)
        let end = try XCTUnwrap(sourceCalendar.date(byAdding: .hour, value: 1, to: start))
        let item = try CalendarItem(
            title: "Boundary event",
            start: start,
            end: end,
            createdAt: start,
            updatedAt: start,
            timeZoneIdentifier: "UTC"
        )
        let displayDay = try XCTUnwrap(DateComponents(
            calendar: displayCalendar,
            timeZone: displayCalendar.timeZone,
            year: 2026,
            month: 8,
            day: 13
        ).date)
        let displayInterval = try XCTUnwrap(displayCalendar.dateInterval(of: .day, for: displayDay))
        let previousDay = try XCTUnwrap(displayCalendar.date(byAdding: .day, value: -1, to: displayDay))
        let previousInterval = try XCTUnwrap(displayCalendar.dateInterval(of: .day, for: previousDay))

        XCTAssertEqual(displayCalendar.component(.day, from: start), 13)
        XCTAssertEqual(CalendarTimelineScale.wallClockMinute(for: start, calendar: displayCalendar), 30, accuracy: 0.001)
        XCTAssertFalse(CalendarAllDayLayout.isAllDay(item, calendar: displayCalendar))
        XCTAssertEqual(CalendarOverlapLayout.layout(items: [item], interval: displayInterval).count, 1)
        XCTAssertTrue(CalendarOverlapLayout.layout(items: [item], interval: previousInterval).isEmpty)
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
