import Foundation
import SwiftUI

// MARK: - Chart contract

public enum LifeOSChartLineStyle: String, CaseIterable, Codable, Sendable {
    case solid
    case dashed
    case dotted

    public var dashPattern: [CGFloat] {
        switch self {
        case .solid: []
        case .dashed: [6, 4]
        case .dotted: [1, 4]
        }
    }
}

public struct LifeOSChartSeriesStyle: Equatable, Sendable {
    public let lineStyle: LifeOSChartLineStyle
    public let lineWidth: CGFloat
    public let areaOpacity: Double
    public let dashPattern: [CGFloat]

    public init(
        lineStyle: LifeOSChartLineStyle,
        lineWidth: CGFloat,
        areaOpacity: Double = 0,
        dashPattern: [CGFloat]? = nil
    ) {
        self.lineStyle = lineStyle
        self.lineWidth = lineWidth
        self.areaOpacity = areaOpacity
        self.dashPattern = dashPattern ?? lineStyle.dashPattern
    }
}

public enum LifeOSChartSeriesKind: String, CaseIterable, Codable, Sendable {
    case observed
    case target
    case estimate
    case history

    public var label: String {
        switch self {
        case .observed: "Observed"
        case .target: "Target"
        case .estimate: "Estimate"
        case .history: "History"
        }
    }

    public var style: LifeOSChartSeriesStyle {
        switch self {
        case .observed:
            // §5.4: 2pt solid; flat 0.08 area (call sites drop the fill below 200pt height).
            LifeOSChartSeriesStyle(lineStyle: .solid, lineWidth: 2, areaOpacity: 0.08)
        case .target:
            LifeOSChartSeriesStyle(lineStyle: .dashed, lineWidth: 1.25)
        case .estimate:
            LifeOSChartSeriesStyle(lineStyle: .dashed, lineWidth: 1.5, dashPattern: [3, 3])
        case .history:
            LifeOSChartSeriesStyle(lineStyle: .dotted, lineWidth: 1.25)
        }
    }

    public var color: Color {
        switch self {
        case .observed: LifeOSTokens.Series.observed
        case .target: LifeOSTokens.Series.target
        case .estimate: LifeOSTokens.Series.estimate
        case .history: LifeOSTokens.Series.history
        }
    }
}

public enum LifeOSChartProvenance: String, CaseIterable, Codable, Sendable {
    case observed
    case stale
    case estimated
    case partial
    case demo
    case unavailable

    public var label: String {
        switch self {
        case .observed: "Observed"
        case .stale: "Stale"
        case .estimated: "Estimated"
        case .partial: "Partial"
        case .demo: "DEMO · NOT LIVE"
        case .unavailable: "Unavailable"
        }
    }
}

/// A source point may be missing. Missing and non-finite values are gaps; they
/// are never normalized to zero.
public struct LifeOSChartPoint: Equatable, Identifiable, Sendable {
    public let timestamp: Date
    public let value: Double?

    public init(timestamp: Date, value: Double?) {
        self.timestamp = timestamp
        self.value = value
    }

    public var id: Date { timestamp }
}

public struct LifeOSChartSeries: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let kind: LifeOSChartSeriesKind
    public let points: [LifeOSChartPoint]
    public let source: String
    public let provenance: LifeOSChartProvenance

    public init(
        id: String,
        label: String,
        kind: LifeOSChartSeriesKind,
        points: [LifeOSChartPoint],
        source: String,
        provenance: LifeOSChartProvenance
    ) {
        self.id = id
        self.label = label
        self.kind = kind
        self.points = points
        self.source = source
        self.provenance = provenance
    }

    public var provenanceLabel: String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? provenance.label : "\(provenance.label) · \(source)"
    }
}

/// Shared chart metadata. A chart can be rendered by multiple screen surfaces
/// without losing its unit, timezone, cadence or source contract.
public struct LifeOSChartSpec: Equatable {
    public let unit: String
    public let timeZone: TimeZone
    public let expectedCadence: TimeInterval?
    public let source: String
    public let provenance: LifeOSChartProvenance
    public let series: [LifeOSChartSeries]

    public init(
        unit: String,
        timeZone: TimeZone = .current,
        expectedCadence: TimeInterval?,
        source: String,
        provenance: LifeOSChartProvenance,
        series: [LifeOSChartSeries]
    ) {
        self.unit = unit
        self.timeZone = timeZone
        self.expectedCadence = expectedCadence.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }
        self.source = source
        self.provenance = provenance
        self.series = series
    }
}

public struct LifeOSChartDomain: Equatable, Sendable {
    public let start: Date?
    public let end: Date?
    public let minimum: Double?
    public let maximum: Double?

    public init(start: Date?, end: Date?, minimum: Double?, maximum: Double?) {
        self.start = start
        self.end = end
        self.minimum = minimum
        self.maximum = maximum
    }

    public static func resolved(from series: [LifeOSChartSeries]) -> LifeOSChartDomain {
        let validPoints = series.flatMap(\.points).filter { point in
            point.timestamp.timeIntervalSinceReferenceDate.isFinite
                && point.value?.isFinite == true
        }

        guard !validPoints.isEmpty else {
            return LifeOSChartDomain(start: nil, end: nil, minimum: nil, maximum: nil)
        }

        let timestamps = validPoints.map(\.timestamp)
        let values = validPoints.compactMap(\.value)
        return LifeOSChartDomain(
            start: timestamps.min(),
            end: timestamps.max(),
            minimum: values.min(),
            maximum: values.max()
        )
    }
}

public struct LifeOSChartNormalizedPoint: Equatable, Identifiable, Sendable {
    public let timestamp: Date
    public let value: Double?
    /// Unit x coordinate in chronological order.
    public let x: Double
    /// Unit y coordinate with zero at the bottom of a plot. Nil means a gap.
    public let y: Double?
    /// True when the source value is missing or non-finite.
    public let isGap: Bool
    /// True when the renderer must break before this valid point because a
    /// missing value or cadence gap separates it from the previous segment.
    public let startsNewSegment: Bool

    public var id: Date { timestamp }

    public var unitPoint: CGPoint? {
        guard let y else { return nil }
        return CGPoint(x: x, y: 1 - y)
    }
}

public struct LifeOSChartSelectedDatum: Equatable, Identifiable, Sendable {
    public let seriesID: String
    public let seriesLabel: String
    public let kind: LifeOSChartSeriesKind
    public let point: LifeOSChartPoint
    public let source: String
    public let provenance: LifeOSChartProvenance

    public var id: String {
        "\(seriesID)·\(point.timestamp.timeIntervalSinceReferenceDate)"
    }

    public var provenanceLabel: String {
        let source = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return source.isEmpty ? provenance.label : "\(provenance.label) · \(source)"
    }
}

public enum LifeOSChartSelectionNoDataReason: String, CaseIterable, Codable, Hashable, Sendable {
    case explicitGap
    case cadenceBreak
    case noValidData
}

public struct LifeOSChartNoDataSelection: Equatable, Sendable {
    public let requestedTimestamp: Date
    public let reason: LifeOSChartSelectionNoDataReason
    /// Nil means the no-data condition applies to the whole selection set.
    public let seriesID: String?

    public init(
        requestedTimestamp: Date,
        reason: LifeOSChartSelectionNoDataReason,
        seriesID: String? = nil
    ) {
        self.requestedTimestamp = requestedTimestamp
        self.reason = reason
        self.seriesID = seriesID
    }
}

public enum LifeOSChartSelectionResult: Equatable, Sendable {
    case selected(LifeOSChartSelectedDatum)
    case noData(LifeOSChartNoDataSelection)

    public var selectedDatum: LifeOSChartSelectedDatum? {
        guard case .selected(let datum) = self else { return nil }
        return datum
    }

    public var noDataSelection: LifeOSChartNoDataSelection? {
        guard case .noData(let selection) = self else { return nil }
        return selection
    }
}

// MARK: - Pure chart operations

public enum LifeOSChartKit {
    private struct SelectionCandidate {
        let datum: LifeOSChartSelectedDatum
        let distance: TimeInterval
        let seriesIndex: Int
    }

    /// Sorts timestamps and keeps the last source occurrence for a duplicate
    /// timestamp. The input series is never mutated.
    public static func normalizedPoints(
        for series: LifeOSChartSeries,
        domain: LifeOSChartDomain? = nil,
        expectedCadence: TimeInterval? = nil
    ) -> [LifeOSChartNormalizedPoint] {
        var lastPointByTimestamp: [Date: LifeOSChartPoint] = [:]
        for point in series.points where point.timestamp.timeIntervalSinceReferenceDate.isFinite {
            lastPointByTimestamp[point.timestamp] = point
        }

        let ordered = lastPointByTimestamp.values.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return [] }

        let resolvedDomain = domain ?? LifeOSChartDomain.resolved(from: [series])
        let xSpan = resolvedDomain.start.flatMap { start in
            resolvedDomain.end.map { $0.timeIntervalSince(start) }
        } ?? 0
        let ySpan: Double = if let minimum = resolvedDomain.minimum, let maximum = resolvedDomain.maximum {
            maximum - minimum
        } else {
            0
        }
        let cadence = expectedCadence.flatMap { $0 > 0 && $0.isFinite ? $0 : nil }

        var previousTimestamp: Date?
        var previousPointWasValid = false
        var emittedValidPoint = false

        return ordered.map { point in
            let validValue = point.value.flatMap { $0.isFinite ? $0 : nil }
            let isValid = validValue != nil
            let cadenceGap = isValid && previousPointWasValid && cadence.map {
                point.timestamp.timeIntervalSince(previousTimestamp ?? point.timestamp) > $0 * 1.5
            } == true
            let startsNewSegment = isValid && emittedValidPoint && (!previousPointWasValid || cadenceGap)

            let x: Double
            if let start = resolvedDomain.start, xSpan > 0 {
                x = min(max(point.timestamp.timeIntervalSince(start) / xSpan, 0), 1)
            } else {
                x = 0.5
            }

            let y: Double?
            if let validValue, let minimum = resolvedDomain.minimum, ySpan > 0 {
                y = min(max((validValue - minimum) / ySpan, 0), 1)
            } else if validValue != nil, resolvedDomain.minimum != nil {
                y = 0.5
            } else {
                y = nil
            }

            previousTimestamp = point.timestamp
            previousPointWasValid = isValid
            if isValid { emittedValidPoint = true }

            return LifeOSChartNormalizedPoint(
                timestamp: point.timestamp,
                value: validValue,
                x: x,
                y: y,
                isGap: !isValid,
                startsNewSegment: startsNewSegment
            )
        }
    }

    /// Splits normalized values into renderable segments. Missing values and
    /// cadence gaps never become connected lines.
    public static func segments(
        from normalizedPoints: [LifeOSChartNormalizedPoint]
    ) -> [[LifeOSChartNormalizedPoint]] {
        var result: [[LifeOSChartNormalizedPoint]] = []
        var current: [LifeOSChartNormalizedPoint] = []

        for point in normalizedPoints {
            guard !point.isGap, point.y != nil else {
                if !current.isEmpty { result.append(current) }
                current.removeAll(keepingCapacity: true)
                continue
            }

            if point.startsNewSegment, !current.isEmpty {
                result.append(current)
                current.removeAll(keepingCapacity: true)
            }
            current.append(point)
        }

        if !current.isEmpty { result.append(current) }
        return result
    }

    public static func nearestDatum(
        in series: LifeOSChartSeries,
        to timestamp: Date,
        expectedCadence: TimeInterval? = nil
    ) -> LifeOSChartPoint? {
        selectionResult(in: [series], to: timestamp, expectedCadence: expectedCadence).selectedDatum?.point
    }

    /// Selects the nearest datum across series, explicitly preserving no-data
    /// gaps as a result instead of crossing them to a distant point.
    public static func selectionResult(
        in series: [LifeOSChartSeries],
        to timestamp: Date,
        expectedCadence: TimeInterval? = nil
    ) -> LifeOSChartSelectionResult {
        var candidates: [SelectionCandidate] = []
        var blockedSeries: [(id: String, reason: LifeOSChartSelectionNoDataReason)] = []

        for (seriesIndex, series) in series.enumerated() {
            let normalized = normalizedPoints(for: series, expectedCadence: expectedCadence)
            if let reason = selectionNoDataReason(
                in: normalized,
                at: timestamp,
                expectedCadence: expectedCadence
            ) {
                blockedSeries.append((series.id, reason))
                continue
            }

            candidates.append(contentsOf: normalized.filter { !$0.isGap }.compactMap { point in
                guard let value = point.value else { return nil }
                return SelectionCandidate(
                    datum: LifeOSChartSelectedDatum(
                        seriesID: series.id,
                        seriesLabel: series.label,
                        kind: series.kind,
                        point: LifeOSChartPoint(timestamp: point.timestamp, value: value),
                        source: series.source,
                        provenance: series.provenance
                    ),
                    distance: abs(point.timestamp.timeIntervalSince(timestamp)),
                    seriesIndex: seriesIndex
                )
            })
        }

        if let blocked = blockedSeries.first(where: { reason in
            reason.reason == .explicitGap || reason.reason == .cadenceBreak
        }) {
            let gapReasons = blockedSeries.filter { reason in
                reason.reason == .explicitGap || reason.reason == .cadenceBreak
            }
            let reason = gapReasons.contains { $0.reason == .explicitGap } ?
                LifeOSChartSelectionNoDataReason.explicitGap : .cadenceBreak
            return .noData(
                LifeOSChartNoDataSelection(
                    requestedTimestamp: timestamp,
                    reason: reason,
                    seriesID: gapReasons.count == 1 ? blocked.id : nil
                )
            )
        }

        if let candidate = candidates.min(by: isEarlierCandidate) {
            return .selected(candidate.datum)
        }

        let reason = blockedSeries.map(\.reason).contains(.explicitGap)
            ? LifeOSChartSelectionNoDataReason.explicitGap
            : blockedSeries.map(\.reason).contains(.cadenceBreak)
                ? .cadenceBreak
                : .noValidData
        let seriesID = blockedSeries.count == 1 ? blockedSeries[0].id : nil
        return .noData(
            LifeOSChartNoDataSelection(
                requestedTimestamp: timestamp,
                reason: reason,
                seriesID: seriesID
            )
        )
    }

    /// Source-compatible optional wrapper around `selectionResult`. A gap or
    /// cadence break now returns nil rather than a distant nearest datum.
    public static func nearestSelection(
        in series: [LifeOSChartSeries],
        to timestamp: Date,
        expectedCadence: TimeInterval? = nil
    ) -> LifeOSChartSelectedDatum? {
        selectionResult(in: series, to: timestamp, expectedCadence: expectedCadence).selectedDatum
    }

    private static func isEarlierCandidate(
        _ lhs: SelectionCandidate,
        _ rhs: SelectionCandidate
    ) -> Bool {
        if lhs.distance != rhs.distance { return lhs.distance < rhs.distance }

        let leftObserved = lhs.datum.kind == .observed
        let rightObserved = rhs.datum.kind == .observed
        if leftObserved != rightObserved { return leftObserved }

        if lhs.datum.point.timestamp != rhs.datum.point.timestamp {
            return lhs.datum.point.timestamp < rhs.datum.point.timestamp
        }
        return lhs.seriesIndex < rhs.seriesIndex
    }

    private static func selectionNoDataReason(
        in normalized: [LifeOSChartNormalizedPoint],
        at timestamp: Date,
        expectedCadence: TimeInterval?
    ) -> LifeOSChartSelectionNoDataReason? {
        guard !normalized.isEmpty else { return .noValidData }

        // An explicit nil/non-finite point defines a no-data interval when it
        // is bounded by valid points. Exact selection of an explicit gap is
        // also unavailable, including at a series edge.
        var index = 0
        while index < normalized.count {
            guard normalized[index].isGap else {
                index += 1
                continue
            }

            let gapStart = index
            while index < normalized.count, normalized[index].isGap {
                if normalized[index].timestamp == timestamp { return .explicitGap }
                index += 1
            }
            let gapEnd = index

            if gapStart > 0, gapEnd < normalized.count,
               !normalized[gapStart - 1].isGap, !normalized[gapEnd].isGap,
               timestamp > normalized[gapStart - 1].timestamp,
               timestamp < normalized[gapEnd].timestamp {
                return .explicitGap
            }
        }

        guard let cadence = expectedCadence.flatMap({ $0 > 0 && $0.isFinite ? $0 : nil }) else {
            return nil
        }

        let validPoints = normalized.filter { !$0.isGap }
        for pair in zip(validPoints, validPoints.dropFirst()) {
            let interval = pair.1.timestamp.timeIntervalSince(pair.0.timestamp)
            if interval > cadence * 1.5,
               timestamp > pair.0.timestamp,
               timestamp < pair.1.timestamp {
                return .cadenceBreak
            }
        }

        return nil
    }

    /// A bounded tooltip frame. If the requested tooltip is larger than the
    /// plot, the returned frame is reduced to the available inset area.
    public static func boundedTooltipFrame(
        anchor: CGPoint,
        size: CGSize,
        in bounds: CGRect,
        inset: CGFloat = 8
    ) -> CGRect {
        let safeInset = max(0, inset)
        let availableWidth = max(0, bounds.width - safeInset * 2)
        let availableHeight = max(0, bounds.height - safeInset * 2)
        let width = min(max(0, size.width), availableWidth)
        let height = min(max(0, size.height), availableHeight)
        let minimumX = bounds.minX + safeInset
        let minimumY = bounds.minY + safeInset
        let maximumX = max(minimumX, bounds.maxX - safeInset - width)
        let maximumY = max(minimumY, bounds.maxY - safeInset - height)
        let proposedX = anchor.x - width / 2
        let proposedY = anchor.y - height - safeInset

        return CGRect(
            x: min(max(proposedX, minimumX), maximumX),
            y: min(max(proposedY, minimumY), maximumY),
            width: width,
            height: height
        )
    }
}

// MARK: - Accessibility

public struct LifeOSChartAccessibilitySummary: Equatable, Sendable {
    public let title: String
    public let unit: String
    public let source: String
    public let provenance: LifeOSChartProvenance
    public let value: String?
    public let timestamp: Date?

    public init(
        title: String,
        unit: String,
        source: String,
        provenance: LifeOSChartProvenance,
        value: String? = nil,
        timestamp: Date? = nil
    ) {
        self.title = title
        self.unit = unit
        self.source = source
        self.provenance = provenance
        self.value = value
        self.timestamp = timestamp
    }

    public var spokenSummary: String {
        var parts = [provenance.label]
        if let value, !value.isEmpty { parts.append("\(value) \(unit)".trimmingCharacters(in: .whitespaces)) }
        if let timestamp { parts.append(timestamp.formatted(date: .abbreviated, time: .shortened)) }
        if !source.isEmpty { parts.append("Source \(source)") }
        return parts.joined(separator: ", ")
    }
}

private struct LifeOSChartAccessibilityModifier: ViewModifier {
    let summary: LifeOSChartAccessibilitySummary
    let onPrevious: () -> Void
    let onNext: () -> Void

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(summary.title))
            .accessibilityValue(Text(summary.spokenSummary))
            .accessibilityHint(Text("Swipe up or down to inspect adjacent data points."))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: onNext()
                case .decrement: onPrevious()
                @unknown default: break
                }
            }
    }
}

public extension View {
    /// Adds a VoiceOver summary and adjustable previous/next actions. The
    /// closures should update presentation selection only, never chart source.
    func lifeOSChartAccessibility(
        summary: LifeOSChartAccessibilitySummary,
        onPrevious: @escaping () -> Void = {},
        onNext: @escaping () -> Void = {}
    ) -> some View {
        modifier(
            LifeOSChartAccessibilityModifier(
                summary: summary,
                onPrevious: onPrevious,
                onNext: onNext
            )
        )
    }
}
