import Foundation

public struct CalendarEventPlacement: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let item: CalendarItem
    public let visibleStart: Date
    public let visibleEnd: Date
    public let column: Int
    public let columnCount: Int
    public let yStart: Double
    public let yEnd: Double

    /// The trailing-aligned layer depth. Depth 0 is the full-width/base event;
    /// greater depths are inset from the leading edge and rendered above it.
    /// `column` remains as a source-compatible alias for older callers.
    public var depth: Int { column }

    public func layerFrame(containerWidth: Double, edgeInset: Double = 0) -> CalendarEventLayerFrame {
        CalendarOverlapLayout.layerFrame(depth: depth, containerWidth: containerWidth, edgeInset: edgeInset)
    }

    /// Corner radii used by the event surface. The outer edge of an overlap
    /// group stays rounded while an edge joined to its neighbor tightens.
    /// Keeping this on the placement makes the visual treatment deterministic
    /// from the layout result, rather than from view iteration order.
    public var cornerRadii: CalendarEventCornerRadii {
        let outer: Double = 7
        let joined: Double = 2
        let isLeadingColumn = column <= 0
        let isTrailingColumn = column >= columnCount - 1
        return CalendarEventCornerRadii(
            topLeading: isLeadingColumn ? outer : joined,
            bottomLeading: isLeadingColumn ? outer : joined,
            bottomTrailing: isTrailingColumn ? outer : joined,
            topTrailing: isTrailingColumn ? outer : joined
        )
    }

    public init(
        item: CalendarItem,
        visibleStart: Date,
        visibleEnd: Date,
        column: Int,
        columnCount: Int,
        interval: DateInterval
    ) {
        self.id = item.id
        self.item = item
        self.visibleStart = visibleStart
        self.visibleEnd = visibleEnd
        self.column = column
        self.columnCount = max(1, columnCount)
        let duration = interval.duration
        if duration > 0 {
            self.yStart = min(1, max(0, visibleStart.timeIntervalSince(interval.start) / duration))
            self.yEnd = min(1, max(0, visibleEnd.timeIntervalSince(interval.start) / duration))
        } else {
            self.yStart = 0
            self.yEnd = 0
        }
    }
}

public struct CalendarEventLayerFrame: Equatable, Sendable {
    public let leading: Double
    public let width: Double
    public let trailing: Double

    public init(leading: Double, width: Double, trailing: Double) {
        self.leading = leading
        self.width = width
        self.trailing = trailing
    }
}

public struct CalendarEventCornerRadii: Equatable, Sendable {
    public let topLeading: Double
    public let bottomLeading: Double
    public let bottomTrailing: Double
    public let topTrailing: Double

    public init(
        topLeading: Double,
        bottomLeading: Double,
        bottomTrailing: Double,
        topTrailing: Double
    ) {
        self.topLeading = topLeading
        self.bottomLeading = bottomLeading
        self.bottomTrailing = bottomTrailing
        self.topTrailing = topTrailing
    }
}

public enum CalendarOverlapLayout {
    /// IMG_0663 uses a proportional first overlap: Clip begins about 37% into
    /// the day column, while each deeper layer adds only a small fixed step.
    /// The clamps keep that visual language usable on narrow iPhone columns and
    /// prevent an enormous inset on wide Mac columns.
    public static let baseLayerInsetFraction: Double = 0.37
    public static let minimumBaseLayerInset: Double = 24
    public static let maximumBaseLayerInset: Double = 180
    public static let additionalLayerInset: Double = 16
    public static let minimumLayerWidth: Double = 44

    private struct VisibleEvent {
        let item: CalendarItem
        let start: Date
        let end: Date
    }

    private struct ColumnEvent {
        let event: VisibleEvent
        let depth: Int
    }

    /// Places events into the smallest available trailing-aligned depth. Events
    /// that only touch at an endpoint do not overlap and may reuse a depth.
    public static func layout(items: [CalendarItem], interval: DateInterval) -> [CalendarEventPlacement] {
        guard interval.duration > 0 else { return [] }

        let visible = items
            .filter { !$0.isDeleted && $0.start < interval.end && $0.end > interval.start }
            .map {
                VisibleEvent(
                    item: $0,
                    start: max($0.start, interval.start),
                    end: min($0.end, interval.end)
                )
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end > $1.end }
                return $0.item.id.uuidString < $1.item.id.uuidString
            }

        var output: [CalendarEventPlacement] = []
        var index = 0
        var previousGroupEnd: Date?

        while index < visible.count {
            var groupEnd = visible[index].end
            var groupEndIndex = index + 1
            while groupEndIndex < visible.count, visible[groupEndIndex].start < groupEnd {
                groupEnd = max(groupEnd, visible[groupEndIndex].end)
                groupEndIndex += 1
            }

            let group = Array(visible[index..<groupEndIndex])
            // Keep the leading track occupied when an overlap starts exactly
            // as the previous full-width event ends. This is the Notion/Figma
            // stack language: Gym remains the base, Clip/Tax enter as trailing
            // layers, and chillen can reclaim the base once that stack ends.
            let startsAtPreviousBoundary = previousGroupEnd == group.first?.start
            let depthOffset = startsAtPreviousBoundary && group.count > 1 ? 1 : 0
            var depthEnds: [Date] = []
            var assigned: [ColumnEvent] = []

            for event in group {
                if let available = depthEnds.firstIndex(where: { $0 <= event.start }) {
                    depthEnds[available] = event.end
                    assigned.append(ColumnEvent(event: event, depth: available + depthOffset))
                } else {
                    let depth = depthEnds.count
                    depthEnds.append(event.end)
                    assigned.append(ColumnEvent(event: event, depth: depth + depthOffset))
                }
            }

            let columnCount = max(1, depthEnds.count + depthOffset)
            output.append(contentsOf: assigned.map {
                CalendarEventPlacement(
                    item: $0.event.item,
                    visibleStart: $0.event.start,
                    visibleEnd: $0.event.end,
                    column: $0.depth,
                    columnCount: columnCount,
                    interval: interval
                )
            })
            previousGroupEnd = groupEnd
            index = groupEndIndex
        }

        return output
    }

    /// Recomputes the complete overlap geometry for a provisional move. The
    /// source item is removed before the moved copy is inserted so source and
    /// destination columns both resolve their lanes exactly as they will at
    /// commit time.
    public static func layoutWithProvisionalMove(
        items: [CalendarItem],
        movingItemID: UUID,
        provisionalStart: Date,
        provisionalEnd: Date,
        interval: DateInterval
    ) -> [CalendarEventPlacement] {
        guard let moving = items.first(where: { $0.id == movingItemID }),
              let moved = try? moving.updating(
                  start: provisionalStart,
                  end: provisionalEnd,
                  at: moving.updatedAt
              ) else {
            return layout(items: items, interval: interval)
        }
        return layout(items: items.filter { $0.id != movingItemID } + [moved], interval: interval)
    }

    public static func layerFrame(
        depth: Int,
        containerWidth: Double,
        edgeInset: Double = 0
    ) -> CalendarEventLayerFrame {
        let safeContainer = max(0, containerWidth)
        let safeEdge = min(max(0, edgeInset), safeContainer)
        let trailing = safeContainer - safeEdge
        let inset = layerInset(depth: depth, containerWidth: trailing)
        // A very narrow iPhone day column cannot satisfy an absolute minimum
        // and remain inside its container at the same time. Prefer the safe
        // minimum whenever possible, then clamp to the available width so a
        // narrow column never spills into its neighbour.
        let width = min(trailing, max(minimumLayerWidth, trailing - inset))
        return CalendarEventLayerFrame(
            leading: max(0, trailing - width),
            width: width,
            trailing: max(0, trailing)
        )
    }

    public static func layerInset(depth: Int, containerWidth: Double) -> Double {
        guard depth > 0 else { return 0 }
        let width = max(0, containerWidth)
        let proportional = width * baseLayerInsetFraction
        let clampedBase = min(maximumBaseLayerInset, max(minimumBaseLayerInset, proportional))
        // If the column cannot fit the safe minimum, consume only the space
        // that is actually available; layerFrame performs the final width clamp.
        let fittingBase = min(clampedBase, max(0, width - minimumLayerWidth))
        return fittingBase + Double(depth - 1) * additionalLayerInset
    }
}

/// Pure geometry for the sticky all-day lane above the timed grid.
///
/// Row contract (geonq's exact rule): every all-day entry owns exactly one
/// lane cell, and one empty cell always trails below them. Zero entries
/// therefore render exactly ONE empty cell; n entries render n cells plus one
/// empty cell. Overlaps never share a row because sharing would collapse the
/// count. Keeping this separate from SwiftUI makes the lane height and
/// stacking deterministic across iPhone sizes and gives the interaction tests
/// a model contract to exercise without rendering a view.
public enum CalendarAllDayLayout {
    public static let rowHeight: Double = 26
    public static let rowSpacing: Double = 2
    public static let minimumRows = 1

    public struct Placement: Equatable, Identifiable, Sendable {
        public let item: CalendarItem
        public let row: Int
        public let firstDayIndex: Int
        public let dayCount: Int

        public var id: UUID { item.id }

        fileprivate init(item: CalendarItem, row: Int, firstDayIndex: Int, dayCount: Int) {
            self.item = item
            self.row = row
            self.firstDayIndex = firstDayIndex
            self.dayCount = dayCount
        }
    }

    public static func isAllDay(_ item: CalendarItem, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: item.start)
        let end = calendar.startOfDay(for: item.end)
        return item.start == start && item.end == end && end > start
    }

    public static func placements(
        items: [CalendarItem],
        days: [Date],
        calendar: Calendar
    ) -> [Placement] {
        guard !days.isEmpty else { return [] }
        let dayStarts = days.map { calendar.startOfDay(for: $0) }
        let dayEnds = dayStarts.map { calendar.date(byAdding: .day, value: 1, to: $0) ?? $0 }

        let allDayItems = items
            .filter { !$0.isDeleted && isAllDay($0, calendar: calendar) }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.id.uuidString < $1.id.uuidString
            }

        var result: [Placement] = []
        for (row, item) in allDayItems.enumerated() {
            let visibleIndices = days.indices.filter { index in
                item.start < dayEnds[index] && item.end > dayStarts[index]
            }
            guard let first = visibleIndices.first, let last = visibleIndices.last else { continue }
            let endExclusive = last + 1
            result.append(
                Placement(
                    item: item,
                    row: row,
                    firstDayIndex: first,
                    dayCount: endExclusive - first
                )
            )
        }
        return result
    }

    /// Entries + 1: the trailing empty cell is part of the contract even when
    /// the lane is empty (zero entries -> exactly one cell).
    public static func rowCount(
        items: [CalendarItem],
        days: [Date],
        calendar: Calendar
    ) -> Int {
        max(minimumRows, placements(items: items, days: days, calendar: calendar).count + 1)
    }

    public static func height(
        items: [CalendarItem],
        days: [Date],
        calendar: Calendar
    ) -> Double {
        let rows = rowCount(items: items, days: days, calendar: calendar)
        return Double(rows) * rowHeight + Double(max(0, rows - 1)) * rowSpacing
    }
}

public enum CalendarEventResizeEdge: Sendable {
    case start
    case end
}

public enum CalendarProvisionalRenderState: Equatable, Sendable {
    case sourceOnly
    case destinationOnly
}

/// Deterministic gesture arbitration shared by the Mac timeline and the iOS
/// pager. A parent horizontal scroll must yield for the complete event
/// mutation, including the period in which a provisional preview is waiting
/// for local durability.
public enum CalendarGestureArbitration {
    public struct CompletedMutationCleanup: Equatable, Sendable {
        public let eventMoveActive: Bool
        public let hasProvisionalPreview: Bool
        public let settledHeaderDate: Date

        fileprivate init(settledHeaderDate: Date) {
            self.eventMoveActive = false
            self.hasProvisionalPreview = false
            self.settledHeaderDate = settledHeaderDate
        }
    }

    public static func parentHorizontalScrollEnabled(
        eventMutationActive: Bool,
        hasProvisionalPreview: Bool
    ) -> Bool {
        !eventMutationActive && !hasProvisionalPreview
    }

    /// The pager header returns to the settled page as soon as an event drag
    /// takes ownership; this is intentionally not tied to save completion.
    public static func headerDateAfterEventOwnership(settledPage: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: settledPage)
    }

    public static func cleanupAfterCompletedMutation(settledPage: Date, calendar: Calendar) -> CompletedMutationCleanup {
        CompletedMutationCleanup(settledHeaderDate: headerDateAfterEventOwnership(settledPage: settledPage, calendar: calendar))
    }

    /// Cancellation and validation failure use the same terminal state as a
    /// completed mutation: no event owns the parent scroll and no provisional
    /// preview remains mounted.
    public static func cleanupAfterCancelledMutation(settledPage: Date, calendar: Calendar) -> CompletedMutationCleanup {
        CompletedMutationCleanup(settledHeaderDate: headerDateAfterEventOwnership(settledPage: settledPage, calendar: calendar))
    }
}

/// Small state machine for the iOS 17 pager fallback. Native scroll paging
/// still owns the actual content offset; this state only records whether a
/// horizontal finger drag currently owns the pager's settle gate.
public struct CalendarPagerDragState: Equatable, Sendable {
    public private(set) var isActive: Bool

    public init(isActive: Bool = false) {
        self.isActive = isActive
    }

    @discardableResult
    public mutating func beginHorizontalDrag() -> Bool {
        guard !isActive else { return false }
        isActive = true
        return true
    }

    @discardableResult
    public mutating func end() -> Bool {
        guard isActive else { return false }
        isActive = false
        return true
    }

    @discardableResult
    public mutating func cancel() -> Bool {
        end()
    }
}

/// Render ownership for a month drag. The source owner remains mounted and
/// interactive until the gesture ends; the destination is only a visual ghost
/// and never becomes a second gesture/accessibility surface.
public enum CalendarMonthMoveRenderState: Equatable, Sendable {
    case normal
    case sourceOwner
    case destinationGhost
}

/// Controls which occurrence to use when a wall-clock time is repeated by a
/// fall-back transition. Creation and ordinary reverse mapping use `.first`;
/// existing-event edits can preserve the endpoint's original occurrence.
public enum CalendarTimelineOccurrencePolicy: Sendable {
    case first
    case preserveOriginal(Date)
}

/// The single vertical coordinate system used by a timed day column.
///
/// The vertical coordinate is a 24-hour local wall-clock axis so 09:00 stays
/// aligned across normal and DST columns. A spring-forward day has no valid
/// date in the 02:00–02:59 band; reverse mapping snaps that band forward to
/// the corresponding 03:00–03:59 time. A fall-back day has two dates for the
/// repeated 01:00–01:59 band; both intentionally share one y coordinate (the
/// event overlap lane distinguishes them), while reverse mapping selects the
/// calendar's earlier occurrence deterministically.
public struct CalendarTimelineScale: Equatable, Sendable {
    public let interval: DateInterval
    public let hourHeight: Double

    public init(interval: DateInterval, hourHeight: Double) {
        self.interval = interval
        self.hourHeight = max(0, hourHeight)
    }

    /// Actual elapsed length, useful for persistence/DST assertions. It is
    /// not used as the visual axis length.
    public var elapsedDayMinutes: Int {
        max(0, Int((interval.duration / 60).rounded()))
    }

    public var dayMinutes: Int { 24 * 60 }

    public var totalHeight: Double {
        24 * hourHeight
    }

    /// The timeline is a 24-hour wall-clock axis. Keeping this conversion
    /// explicit prevents a localized 12-hour display string from affecting
    /// placement (13:00 is always row 13, not row 1).
    public static func wallClockMinute(for date: Date, calendar: Calendar) -> Double {
        let components = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return Double(components.hour ?? 0) * 60
            + Double(components.minute ?? 0)
            + Double(components.second ?? 0) / 60
            + Double(components.nanosecond ?? 0) / 60_000_000_000
    }

    /// Locale-correct metadata/accessibility text. This is presentation-only;
    /// placement must use `wallClockMinute` above.
    public static func localizedTimeLabel(
        for date: Date,
        calendar: Calendar,
        locale: Locale = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    public func y(for date: Date, calendar: Calendar = .current) -> Double {
        guard interval.duration > 0, date.timeIntervalSinceReferenceDate.isFinite else { return 0 }
        guard date >= interval.start else { return 0 }
        guard date < interval.end else { return totalHeight }
        let wallMinutes = Self.wallClockMinute(for: date, calendar: calendar)
        return min(totalHeight, max(0, wallMinutes / 60 * hourHeight))
    }

    public func date(
        for y: Double,
        calendar: Calendar,
        snappingTo minutes: Int? = nil,
        occurrence: CalendarTimelineOccurrencePolicy = .first
    ) -> Date? {
        guard interval.duration > 0, y.isFinite else { return nil }
        let clampedY = min(totalHeight, max(0, y))
        let rawMinutes = clampedY / max(hourHeight, 0.0001) * 60
        let step = max(1, minutes ?? 1)
        let snapped = min(dayMinutes, max(0, Int((rawMinutes / Double(step)).rounded()) * step))
        guard snapped < dayMinutes else { return interval.end }
        let base = calendar.dateComponents([.year, .month, .day], from: interval.start)
        var components = DateComponents()
        components.year = base.year
        components.month = base.month
        components.day = base.day
        components.hour = snapped / 60
        components.minute = snapped % 60
        components.second = 0
        guard let candidate = calendar.date(from: components) else { return nil }
        let wallKey = { (date: Date) in
            let value = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            return (value.year, value.month, value.day, value.hour, value.minute)
        }
        let requestedKey = (components.year, components.month, components.day, components.hour, components.minute)
        let normalizedCandidate: Date
        if wallKey(candidate) == requestedKey {
            normalizedCandidate = candidate
        } else {
            // Foundation's next-time policy can resolve every wall time in a
            // skipped hour to the transition boundary (02:30 -> 03:00).
            // Resolve the first valid instant for the requested hour, then
            // restore the requested minute within that hour (02:30 -> 03:30).
            var hourComponents = components
            hourComponents.minute = 0
            let hourKey = (hourComponents.year, hourComponents.month, hourComponents.day, hourComponents.hour, hourComponents.minute)
            let hourCandidate = calendar.date(from: hourComponents)
            let gapStart = if let hourCandidate, wallKey(hourCandidate) == hourKey {
                hourCandidate
            } else {
                calendar.nextDate(
                    after: interval.start.addingTimeInterval(-1),
                    matching: hourComponents,
                    matchingPolicy: .nextTime,
                    repeatedTimePolicy: .first,
                    direction: .forward
                ) ?? candidate
            }
            normalizedCandidate = calendar.date(
                byAdding: .minute,
                value: components.minute ?? 0,
                to: gapStart
            ) ?? gapStart
        }
        // Foundation normally resolves an ambiguous fall-back wall time to
        // the first occurrence. If a platform policy returns the later one,
        // explicitly walk back one elapsed hour when it has the same wall
        // components so reverse mapping remains deterministic.
        let canonical: Date
        if let earlier = calendar.date(byAdding: .hour, value: -1, to: normalizedCandidate),
           earlier >= interval.start,
           wallKey(earlier) == wallKey(normalizedCandidate) {
            canonical = earlier
        } else {
            canonical = normalizedCandidate
        }

        let resolved: Date
        if case let .preserveOriginal(original) = occurrence,
           let earlier = calendar.date(byAdding: .hour, value: -1, to: original),
           wallKey(earlier) == wallKey(original),
           let later = calendar.date(byAdding: .hour, value: 1, to: canonical),
           wallKey(later) == wallKey(canonical) {
            resolved = later
        } else {
            resolved = canonical
        }
        return min(max(resolved, interval.start), interval.end)
    }

    /// Returns a visual span that preserves the wall-clock axis while still
    /// giving a fall-back event crossing the repeated hour its elapsed fold.
    /// Spring-forward gaps remain a single wall-clock gap, so a 01:30–03:30
    /// event occupies the visible two-hour span even though only 60 elapsed
    /// minutes passed.
    public func height(from start: Date, to end: Date, calendar: Calendar) -> Double {
        guard end > start else { return 0 }
        let wallDelta = max(0, y(for: end, calendar: calendar) - y(for: start, calendar: calendar))
        let elapsed = max(0, end.timeIntervalSince(start))
        let wallMinutes = max(0, wallDelta / max(hourHeight, 0.0001) * 60)
        let foldMinutes = max(0, elapsed / 60 - wallMinutes)
        return min(totalHeight - y(for: start, calendar: calendar), wallDelta + foldMinutes / 60 * hourHeight)
    }
}

/// Pure calendar math used by the timeline's press/drag interactions. Keeping
/// this separate from SwiftUI makes snap thresholds, DST behavior, and edge
/// clamping deterministic in unit tests and keeps the gesture code small.
public enum CalendarInteractionLayout {
    public static let snapIntervalMinutes = 15
    public static let minimumDurationMinutes = 15
    public static let creationDurationMinutes = 60
    /// Space after the final 24:00 mark so the endpoint remains visible when
    /// the finite timed viewport is scrolled all the way to the bottom. This
    /// is display-only; creation and event math continue to use `timelineHeight`.
    ///
    /// The buffer must exceed every floating layer that covers the timeline's
    /// trailing edge on iPhone: the home-indicator safe area, the compact tab
    /// bar, and the calendar's own quick-action pill/FAB overlay. A buffer
    /// budgeted only for the first two clamps maximum scroll with 21:00+
    /// hidden behind the floating chrome and the last reachable hour stuck
    /// around 13:00 at the top of the viewport — the reported
    /// "vertical scroll stops around 13:00" regression.
    public static let homeIndicatorSafeAreaHeight: Double = 34
    public static let compactTabBarHeight: Double = 50
    public static let quickActionsOverlayHeight: Double = 58
    public static let endpointLabelClearance: Double = 14
    public static let endpointScrollMargin: Double = 8
    public static let timelineBottomInset: Double =
        homeIndicatorSafeAreaHeight
            + compactTabBarHeight
            + quickActionsOverlayHeight
            + endpointLabelClearance
            + endpointScrollMargin
    /// The short range shown while a mobile time selection is being held.
    /// The editor receives the actual dragged interval; this is only the
    /// initial ghost before the finger expresses a longer/shorter range.
    public static let mobileSelectionDurationMinutes = 30

    /// The reduced-motion month transition still communicates the panel
    /// change, but does so with a short opacity cross-fade rather than the
    /// matched-geometry height morph used by the full-motion path.
    public enum MonthExpansionMotionPolicy: Equatable, Sendable {
        case opacityCrossfade(duration: Double)
        case matchedGeometryMorph
    }

    public static let reducedMotionMonthCrossfadeDuration: Double = 0.16

    public static func monthExpansionMotionPolicy(
        reduceMotion: Bool
    ) -> MonthExpansionMotionPolicy {
        reduceMotion
            ? .opacityCrossfade(duration: reducedMotionMonthCrossfadeDuration)
            : .matchedGeometryMorph
    }

    /// The result of projecting a pager release. `normalizedVelocity` uses
    /// the pager's offset coordinate: negative means the finger released
    /// toward later dates (left), positive means earlier dates (right).
    /// Keeping the value bounded avoids an unusually large predicted
    /// translation producing an unstable spring.
    public struct PagerSettleProjection: Equatable, Sendable {
        public let pageDelta: Int
        public let normalizedVelocity: Double

        public init(pageDelta: Int, normalizedVelocity: Double) {
            self.pageDelta = pageDelta
            self.normalizedVelocity = normalizedVelocity
        }
    }

    /// Resolves a horizontal pager release into a bounded number of virtual
    /// pages and a normalized release velocity for a spring settle. The
    /// predicted translation carries the native fling projection while the
    /// committed translation remains the fallback for a slow drag.
    public static func pagerSettleProjection(
        translation: Double,
        predictedTranslation: Double,
        pageWidth: Double,
        maximumPages: Int = 2
    ) -> PagerSettleProjection {
        guard translation.isFinite,
              predictedTranslation.isFinite,
              pageWidth.isFinite,
              pageWidth > 0,
              maximumPages > 0 else {
            return PagerSettleProjection(pageDelta: 0, normalizedVelocity: 0)
        }

        let threshold = max(70, pageWidth * 0.20)
        guard abs(translation) >= threshold || abs(predictedTranslation) >= threshold else {
            return PagerSettleProjection(pageDelta: 0, normalizedVelocity: 0)
        }

        let projected = abs(predictedTranslation) >= threshold ? predictedTranslation : translation
        var pages = Int((-projected / pageWidth).rounded())
        if pages == 0 {
            pages = translation < 0 ? 1 : -1
        }
        // A normal UIKit/XCTest swipe often predicts between 1.5 and 1.7
        // widths even though the user's intent is one page. Reserve the
        // two-page settle for a clearly longer/high-velocity projection.
        if abs(pages) > 1, abs(projected) / pageWidth < 1.75 {
            pages = pages < 0 ? -1 : 1
        }
        let boundedPages = max(-maximumPages, min(maximumPages, pages))
        // DragGesture exposes the release's projected endpoint rather than a
        // velocity scalar. The extension beyond the committed translation is
        // the deterministic velocity proxy; slow drags fall back to their
        // committed displacement.
        let releaseDisplacement = abs(predictedTranslation) >= threshold
            ? predictedTranslation - translation
            : translation
        let velocity = boundedPages == 0
            ? 0
            : max(-3, min(3, releaseDisplacement / pageWidth))
        return PagerSettleProjection(
            pageDelta: boundedPages,
            normalizedVelocity: velocity
        )
    }

    /// Resolves a horizontal pager release into a bounded number of virtual
    /// pages. `predictedTranslation` carries the native fling velocity, while
    /// the committed translation remains the fallback for a slow drag. The
    /// result is positive when the user swiped left (toward later dates).
    /// Keeping this pure makes the settle threshold and momentum behavior
    /// deterministic without coupling it to SwiftUI gesture state.
    public static func pagerPageDelta(
        translation: Double,
        predictedTranslation: Double,
        pageWidth: Double,
        maximumPages: Int = 2
    ) -> Int {
        pagerSettleProjection(
            translation: translation,
            predictedTranslation: predictedTranslation,
            pageWidth: pageWidth,
            maximumPages: maximumPages
        ).pageDelta
    }

    /// Projects the date under a native-width pager while the page is still
    /// moving. A horizontal offset of `-pageWidth` means that the next page is
    /// centred, so the header advances by the complete visible day window.
    /// The result deliberately keeps its fractional time component: callers
    /// can update month/week labels at the exact boundary instead of waiting
    /// for a settled page or quantising the preview to midnight.
    public static func pagerPreviewDate(
        pageAnchor: Date,
        horizontalOffset: Double,
        pageWidth: Double,
        dayCount: Int,
        calendar: Calendar
    ) -> Date {
        guard horizontalOffset.isFinite,
              pageWidth.isFinite,
              pageWidth > 0,
              dayCount > 0 else { return pageAnchor }

        let projectedDays = -horizontalOffset / pageWidth * Double(dayCount)
        guard projectedDays.isFinite else { return pageAnchor }

        let wholeDays = Int(projectedDays.rounded(.towardZero))
        let wholeDayAnchor = calendar.date(byAdding: .day, value: wholeDays, to: pageAnchor) ?? pageAnchor
        let fractionalDay = projectedDays - Double(wholeDays)
        guard abs(fractionalDay) > 0.0001,
              let interval = dayInterval(containing: wholeDayAnchor, calendar: calendar) else {
            return wholeDayAnchor
        }
        let minutes = calendarMinutes(from: interval.start, to: interval.end, calendar: calendar)
        return calendar.date(
            byAdding: .minute,
            value: Int((fractionalDay * Double(minutes)).rounded()),
            to: wholeDayAnchor
        ) ?? wholeDayAnchor
    }

    /// The calendar components that affect the parent header while the page
    /// strip is moving. The strip may still project a fractional Date every
    /// frame, but the parent only needs to rebuild when one of these semantic
    /// boundaries changes.
    public struct PagerPreviewBoundary: Equatable, Sendable {
        public let year: Int
        public let month: Int
        public let day: Int
        public let weekOfYear: Int
        public let weekYear: Int

        fileprivate init(calendar: Calendar, date: Date) {
            year = calendar.component(.year, from: date)
            month = calendar.component(.month, from: date)
            day = calendar.component(.day, from: date)
            weekOfYear = calendar.component(.weekOfYear, from: date)
            weekYear = calendar.component(.yearForWeekOfYear, from: date)
        }
    }

    public static func pagerPreviewBoundary(
        for date: Date,
        calendar: Calendar
    ) -> PagerPreviewBoundary {
        PagerPreviewBoundary(calendar: calendar, date: date)
    }

    public static func pagerPreviewBoundaryChanged(
        from previous: Date?,
        to candidate: Date,
        calendar: Calendar
    ) -> Bool {
        guard let previous else { return true }
        return pagerPreviewBoundary(for: previous, calendar: calendar) !=
            pagerPreviewBoundary(for: candidate, calendar: calendar)
    }

    /// Decides what an ended drag is allowed to do. A vertical/non-owned
    /// gesture arriving while a pager settle is pending must leave that settle
    /// intact; only event ownership is allowed to cancel it.
    public enum PagerEndDisposition: Equatable, Sendable {
        case preservePendingSettle
        case resetForEventOwnership
        case settleHorizontalPage
        case cancelNonOwnedDrag
    }

    public static func pagerEndDisposition(
        hasPendingSettle: Bool,
        eventMutationActive: Bool,
        hasProvisionalEventPreview: Bool,
        horizontalDragActive: Bool
    ) -> PagerEndDisposition {
        if eventMutationActive || hasProvisionalEventPreview {
            return .resetForEventOwnership
        }
        if hasPendingSettle {
            return .preservePendingSettle
        }
        if horizontalDragActive {
            return .settleHorizontalPage
        }
        return .cancelNonOwnedDrag
    }

    /// Resolves the direction of the iOS 17 fallback drag without claiming
    /// vertical timeline scrolling or event move/resize gestures.
    public static func isHorizontalPagerDrag(
        horizontalTranslation: Double,
        verticalTranslation: Double,
        minimumDistance: Double = 4
    ) -> Bool {
        guard horizontalTranslation.isFinite,
              verticalTranslation.isFinite,
              minimumDistance.isFinite,
              minimumDistance >= 0 else { return false }
        return abs(horizontalTranslation) >= minimumDistance &&
            abs(horizontalTranslation) > abs(verticalTranslation)
    }

    /// The Mac empty-grid drag must be visibly intentional. A click or a
    /// nearly horizontal scroll gesture is never a create command.
    public static func isIntentionalCreationDrag(
        verticalTranslation: Double,
        horizontalTranslation: Double,
        minimumDistance: Double = 12,
        horizontalLimit: Double = 28
    ) -> Bool {
        guard verticalTranslation.isFinite, horizontalTranslation.isFinite,
              minimumDistance.isFinite, horizontalLimit.isFinite,
              minimumDistance >= 0, horizontalLimit >= 0 else { return false }
        return abs(verticalTranslation) >= minimumDistance &&
            abs(horizontalTranslation) <= horizontalLimit
    }

    /// The horizontal equivalent of the quarter-hour vertical snap. A day
    /// column is the unit of movement, so a half-column crossing commits to
    /// the adjacent local calendar day.
    public static func snappedDayDelta(translation: Double, dayWidth: Double) -> Int {
        guard translation.isFinite, dayWidth.isFinite, dayWidth > 0 else { return 0 }
        return Int((translation / dayWidth).rounded())
    }

    public static func snappedMinuteDelta(translation: Double, hourHeight: Double) -> Int {
        guard translation.isFinite, hourHeight.isFinite, hourHeight > 0 else { return 0 }
        let rawMinutes = translation / hourHeight * 60
        return Int((rawMinutes / Double(snapIntervalMinutes)).rounded()) * snapIntervalMinutes
    }

    public static func snappedMinutes(verticalOffset: Double, hourHeight: Double) -> Int {
        max(0, snappedMinuteDelta(translation: verticalOffset, hourHeight: hourHeight))
    }

    public static func dayInterval(containing date: Date, calendar: Calendar) -> DateInterval? {
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start), end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func timelineScale(day: Date, hourHeight: Double, calendar: Calendar) -> CalendarTimelineScale? {
        guard let interval = dayInterval(containing: day, calendar: calendar), interval.duration > 0 else { return nil }
        return CalendarTimelineScale(interval: interval, hourHeight: hourHeight)
    }

    public static func timelineHeight(days: [Date], hourHeight: Double, calendar: Calendar) -> Double {
        // All columns intentionally use the same wall-clock height; a DST
        // transition changes valid instants, not the shared 00:00–24:00 axis.
        _ = days
        _ = calendar
        return hourHeight * 24
    }

    /// Scroll content height for the timed grid. The axis itself still ends
    /// at exactly 24 hours; the extra inset is only a reachable visual buffer
    /// for the final label/boundary.
    public static func timelineContentHeight(days: [Date], hourHeight: Double, calendar: Calendar) -> Double {
        timelineHeight(days: days, hourHeight: hourHeight, calendar: calendar) + timelineBottomInset
    }

    public static func timelineHourLabel(
        minute: Int,
        dayMinutes: Int,
        date: Date?,
        calendar: Calendar
    ) -> String {
        guard minute >= dayMinutes else {
            guard let date else { return "" }
            return String(format: "%02d:00", calendar.component(.hour, from: date))
        }
        return "24:00"
    }

    /// Returns the finite viewport reserved for the timed ScrollView. The
    /// full 00:00–24:00 content is intentionally larger than this value and
    /// must be scrolled inside it rather than expanding the page off-screen.
    public static func timedViewportHeight(
        containerHeight: Double,
        dayHeaderHeight: Double,
        allDayHeight: Double
    ) -> Double {
        guard containerHeight.isFinite,
              dayHeaderHeight.isFinite,
              allDayHeight.isFinite else { return 1 }
        return max(1, containerHeight - max(0, dayHeaderHeight) - max(0, allDayHeight))
    }

    public static func provisionalRenderState(
        sourceDate: Date,
        destinationDate: Date,
        calendar: Calendar
    ) -> CalendarProvisionalRenderState {
        calendar.isDate(sourceDate, inSameDayAs: destinationDate) ? .sourceOnly : .destinationOnly
    }

    public static func calendarMinutes(from start: Date, to end: Date, calendar: Calendar) -> Int {
        guard end >= start else { return 0 }
        if let value = calendar.dateComponents([.minute], from: start, to: end).minute {
            return max(0, value)
        }
        return max(0, Int((end.timeIntervalSince(start) / 60).rounded()))
    }

    /// Returns the first minute of a proposed 60-minute creation block. The
    /// result is snapped to a quarter-hour and kept wholly inside the local
    /// calendar day, including 23/25-hour DST days.
    public static func creationDate(
        day: Date,
        verticalOffset: Double,
        hourHeight: Double,
        calendar: Calendar,
        durationMinutes: Int = creationDurationMinutes
    ) -> Date? {
        guard let scale = timelineScale(day: day, hourHeight: hourHeight, calendar: calendar),
              let proposed = scale.date(for: verticalOffset, calendar: calendar, snappingTo: snapIntervalMinutes),
              let interval = dayInterval(containing: day, calendar: calendar),
              let latest = calendar.date(byAdding: .minute, value: -max(snapIntervalMinutes, durationMinutes), to: interval.end),
              let clampedLatest = max(interval.start, latest) as Date?,
              let clamped = calendar.date(byAdding: .minute, value: 0, to: min(max(proposed, interval.start), clampedLatest))
        else { return nil }
        return clamped
    }

    /// Maps an intentional empty-grid gesture to a quarter-hour interval.
    /// Unlike the legacy long-press helper above, this preserves a late-day
    /// start and lets the default block cross midnight. That is important for
    /// a double-click at (for example) 23:45: the click's wall-clock position
    /// must not be silently moved to 23:00 just to fit a one-hour block.
    public static func creationInterval(
        day: Date,
        verticalStart: Double,
        verticalEnd: Double,
        hourHeight: Double,
        calendar: Calendar,
        defaultDurationMinutes: Int = creationDurationMinutes
    ) -> DateInterval? {
        guard let scale = timelineScale(day: day, hourHeight: hourHeight, calendar: calendar),
              verticalStart.isFinite,
              verticalEnd.isFinite else { return nil }

        let lower = min(verticalStart, verticalEnd)
        let upper = max(verticalStart, verticalEnd)
        guard let start = scale.date(
            for: lower,
            calendar: calendar,
            snappingTo: snapIntervalMinutes
        ) else { return nil }

        let candidateEnd = scale.date(
            for: upper,
            calendar: calendar,
            snappingTo: snapIntervalMinutes
        )
        let minimum = max(minimumDurationMinutes, snapIntervalMinutes)
        let end: Date
        if lower == upper || candidateEnd == nil || candidateEnd! <= start {
            end = calendar.date(byAdding: .minute, value: max(minimum, defaultDurationMinutes), to: start) ?? start
        } else {
            end = candidateEnd!
        }
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }

    public static func movedInterval(
        item: CalendarItem,
        translation: Double,
        hourHeight: Double,
        day: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let duration = max(minimumDurationMinutes, calendarMinutes(from: item.start, to: item.end, calendar: calendar))

        // The visible day scale intentionally clamps dates outside its 00:00
        // ... 24:00 axis. An overnight event starts outside that axis, so use
        // the snapped local-minute delta directly instead of turning a small
        // upward move into a midnight clamp.
        if !calendar.isDate(item.start, inSameDayAs: item.end),
           let proposedStart = calendar.date(
               byAdding: .minute,
               value: snappedMinuteDelta(translation: translation, hourHeight: hourHeight),
               to: item.start
           ),
           let proposedEnd = calendar.date(byAdding: .minute, value: duration, to: proposedStart) {
            return DateInterval(start: proposedStart, end: proposedEnd)
        }

        let proposedStart: Date
        if let scale = timelineScale(day: day, hourHeight: hourHeight, calendar: calendar),
           let mapped = scale.date(
               for: scale.y(for: item.start, calendar: calendar) + translation,
               calendar: calendar,
               snappingTo: snapIntervalMinutes,
               occurrence: .preserveOriginal(item.start)
           ) {
            proposedStart = mapped
        } else if let fallback = calendar.date(
            byAdding: .minute,
            value: snappedMinuteDelta(translation: translation, hourHeight: hourHeight),
            to: item.start
        ) {
            proposedStart = fallback
        } else {
            return nil
        }
        guard let proposedEnd = calendar.date(byAdding: .minute, value: duration, to: proposedStart) else { return nil }

        // A cross-midnight item is allowed to remain cross-midnight. Clamping
        // it to the visible day would silently destroy the overnight interval.
        guard calendar.isDate(item.start, inSameDayAs: item.end),
              let bounds = dayInterval(containing: day, calendar: calendar),
              let latestStart = calendar.date(byAdding: .minute, value: -duration, to: bounds.end),
              let end = calendar.date(byAdding: .minute, value: duration, to: min(max(proposedStart, bounds.start), latestStart))
        else {
            guard let end = calendar.date(byAdding: .minute, value: duration, to: proposedStart) else { return nil }
            return DateInterval(start: proposedStart, end: max(end, proposedEnd))
        }
        // `end` above is calendar-derived; return the matching clamped start
        // and end without using a fixed 24-hour day.
        return DateInterval(start: min(max(proposedStart, bounds.start), latestStart), end: end)
    }

    /// Moves an event in both axes. Horizontal motion is quantized to visible
    /// day columns while vertical motion remains on the 15-minute grid. The
    /// target start keeps its local wall-clock position when crossing a DST
    /// boundary, and the event duration is rebuilt with calendar minute
    /// arithmetic rather than a fixed 24-hour interval.
    public static func movedInterval(
        item: CalendarItem,
        verticalTranslation: Double,
        horizontalTranslation: Double,
        dayWidth: Double,
        hourHeight: Double,
        calendar: Calendar
    ) -> DateInterval? {
        let dayDelta = snappedDayDelta(translation: horizontalTranslation, dayWidth: dayWidth)
        let duration = max(minimumDurationMinutes, calendarMinutes(from: item.start, to: item.end, calendar: calendar))
        guard let dayShiftedStart = calendar.date(byAdding: .day, value: dayDelta, to: item.start),
              let targetScale = timelineScale(day: dayShiftedStart, hourHeight: hourHeight, calendar: calendar),
              let proposedStart = targetScale.date(
                  for: targetScale.y(for: dayShiftedStart, calendar: calendar) + verticalTranslation,
                  calendar: calendar,
                  snappingTo: snapIntervalMinutes,
                  occurrence: .preserveOriginal(item.start)
              ),
              let proposedEnd = calendar.date(byAdding: .minute, value: duration, to: proposedStart) else {
            return nil
        }

        return DateInterval(start: proposedStart, end: max(proposedEnd, proposedStart.addingTimeInterval(60)))
    }

    /// Moves a month-view event to a calendar day while keeping the event's
    /// local wall-clock start and its exact elapsed duration.  Month cells do
    /// not expose a time axis, so vertical motion is intentionally absent;
    /// the original hour/minute/second/nanosecond are copied into the target
    /// day and the end is rebuilt from the original `TimeInterval` rather
    /// than from calendar-day arithmetic.  That keeps overnight and DST
    /// intervals intact, including fractional-second durations.
    public static func monthMovedInterval(
        item: CalendarItem,
        targetDay: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let duration = item.end.timeIntervalSince(item.start)
        guard duration.isFinite, duration > 0 else { return nil }

        let day = calendar.startOfDay(for: targetDay)
        let dayComponents = calendar.dateComponents([.year, .month, .day], from: day)
        let timeComponents = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: item.start)
        var target = DateComponents()
        target.calendar = calendar
        target.timeZone = calendar.timeZone
        target.year = dayComponents.year
        target.month = dayComponents.month
        target.day = dayComponents.day
        target.hour = timeComponents.hour
        target.minute = timeComponents.minute
        target.second = timeComponents.second
        target.nanosecond = timeComponents.nanosecond
        guard let start = calendar.date(from: target) else { return nil }
        func wallComponents(_ date: Date) -> [Int] {
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
            return [parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0,
                    parts.minute ?? 0, parts.second ?? 0, parts.nanosecond ?? 0]
        }
        let requestedWall = [dayComponents.year ?? 0, dayComponents.month ?? 0, dayComponents.day ?? 0,
                             timeComponents.hour ?? 0, timeComponents.minute ?? 0,
                             timeComponents.second ?? 0, timeComponents.nanosecond ?? 0]
        // A spring-forward target such as 02:30 does not exist. Do not
        // silently normalize it to 03:30 and claim the local time survived.
        guard wallComponents(start) == requestedWall else { return nil }

        // Foundation resolves a repeated fall-back wall time deterministically
        // to one occurrence. If the source was the later occurrence, preserve
        // that choice when the target day has the same repeated wall time.
        var resolvedStart = start
        if let sourceEarlier = calendar.date(byAdding: .hour, value: -1, to: item.start),
           wallComponents(sourceEarlier) == wallComponents(item.start),
           let targetLater = calendar.date(byAdding: .hour, value: 1, to: start),
           wallComponents(targetLater) == wallComponents(start) {
            resolvedStart = targetLater
        }
        let end = resolvedStart.addingTimeInterval(duration)
        guard end > resolvedStart, end.timeIntervalSince(resolvedStart) == duration else { return nil }
        return DateInterval(start: resolvedStart, end: end)
    }

    public static func monthMoveRenderState(
        item: CalendarItem,
        previewStart: Date,
        previewEnd: Date,
        day: Date,
        calendar: Calendar
    ) -> CalendarMonthMoveRenderState {
        guard previewStart != item.start || previewEnd != item.end,
              let dayInterval = dayInterval(containing: day, calendar: calendar) else { return .normal }
        if calendar.isDate(day, inSameDayAs: item.start) { return .sourceOwner }
        guard previewStart < dayInterval.end, previewEnd > dayInterval.start else { return .normal }
        return .destinationGhost
    }

    public static func resizedInterval(
        item: CalendarItem,
        edge: CalendarEventResizeEdge,
        translation: Double,
        hourHeight: Double,
        day: Date,
        calendar: Calendar
    ) -> DateInterval? {
        let minimum = max(1, minimumDurationMinutes)
        let overnight = !calendar.isDate(item.start, inSameDayAs: item.end)
        let bounds = dayInterval(containing: day, calendar: calendar)

        switch edge {
        case .end:
            let proposed: Date?
            if let scale = timelineScale(day: day, hourHeight: hourHeight, calendar: calendar) {
                proposed = scale.date(
                    for: scale.y(for: item.end, calendar: calendar) + translation,
                    calendar: calendar,
                    snappingTo: snapIntervalMinutes,
                    occurrence: .preserveOriginal(item.end)
                )
            } else {
                proposed = calendar.date(
                    byAdding: .minute,
                    value: snappedMinuteDelta(translation: translation, hourHeight: hourHeight),
                    to: item.end
                )
            }
            guard let proposed,
                  let minimumEnd = calendar.date(byAdding: .minute, value: minimum, to: item.start) else { return nil }
            var end = max(proposed, minimumEnd)
            if !overnight, let dayEnd = bounds?.end { end = min(end, dayEnd) }
            return DateInterval(start: item.start, end: max(end, minimumEnd))
        case .start:
            let proposed: Date?
            if let scale = timelineScale(day: day, hourHeight: hourHeight, calendar: calendar) {
                proposed = scale.date(
                    for: scale.y(for: item.start, calendar: calendar) + translation,
                    calendar: calendar,
                    snappingTo: snapIntervalMinutes,
                    occurrence: .preserveOriginal(item.start)
                )
            } else {
                proposed = calendar.date(
                    byAdding: .minute,
                    value: snappedMinuteDelta(translation: translation, hourHeight: hourHeight),
                    to: item.start
                )
            }
            guard let proposed,
                  let latestStart = calendar.date(byAdding: .minute, value: -minimum, to: item.end) else { return nil }
            var start = min(proposed, latestStart)
            if !overnight, let dayStart = bounds?.start { start = max(start, dayStart) }
            return DateInterval(start: min(start, latestStart), end: item.end)
        }
    }
}

public enum CalendarDateRange {
    public static func days(containing anchor: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        guard count > 0 else { return [] }
        let start = calendar.startOfDay(for: anchor)
        return (0..<count).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public static func week(containing anchor: Date, calendar: Calendar = .current) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    public static func monthGrid(containing anchor: Date, calendar: Calendar = .current) -> [Date] {
        guard let month = calendar.dateInterval(of: .month, for: anchor),
              let weekStart = calendar.dateInterval(of: .weekOfYear, for: month.start)?.start,
              let gridEnd = calendar.date(byAdding: .day, value: 42, to: weekStart)
        else { return [] }

        var days: [Date] = []
        var day = weekStart
        while day < gridEnd {
            days.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return days
    }
}

public enum CalendarMonthCellPresentation {
    public static func visibleEventLimit(isCompact: Bool) -> Int {
        // Compact cells use icon-only chips and have room for the same
        // three-row stack. Showing only one made a successfully moved event
        // disappear immediately behind “more” on busy days.
        3
    }

    public static func overflowCount(total: Int, visible: Int) -> Int {
        max(0, total - max(0, visible))
    }
}
