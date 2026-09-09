import SwiftUI

/// Ownership contract for the two places Biology can be rendered.
///
/// The Fitness shell owns identity, date selection, and the single page
/// scroll when Biology is one of its sections. A standalone Biology surface
/// owns those controls itself.
struct FitnessBiologyPresentationPolicy: Equatable, Sendable {
    let showsPageHeader: Bool
    let ownsDateSelection: Bool
    let ownsScrollView: Bool
    let parentOwnsSourceNotice: Bool

    init(embeddedInParentScroll: Bool) {
        showsPageHeader = !embeddedInParentScroll
        ownsDateSelection = !embeddedInParentScroll
        ownsScrollView = !embeddedInParentScroll
        parentOwnsSourceNotice = embeddedInParentScroll
    }
}

private struct FitnessBiologyNavigationTitle: ViewModifier {
    let isEmbedded: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEmbedded {
            content
        } else {
            content.navigationTitle("Biology")
        }
    }
}

/// Stable identity for one displayed Biology series. The sample fingerprint
/// is a compact rolling hash rather than a render-time string serialization.
struct FitnessBiologySeriesIdentity: Equatable, Hashable, Sendable {
    let metricID: String
    let rangeID: String
    let endingDay: Date
    let sourceState: String
    let window: String
    let provenance: String
    let sampleCount: Int
    let sampleFingerprint: UInt64
}

/// Chronological Biology samples plus O(1) date lookup and chart bounds.
/// Source adapters provide chronological observations; malformed fixture or
/// adapter order is repaired once at construction, never during scrubbing.
struct FitnessBiologySeriesIndex: Sendable {
    let points: [FitnessBiologySample]
    let revision: FitnessBiologySeriesIdentity
    let minimumValue: Double?
    let maximumValue: Double?
    let firstDate: Date?
    let lastDate: Date?
    private let indexByDate: [Date: Int]

    init(
        points: [FitnessBiologySample],
        identityContext: FitnessBiologySeriesIdentity? = nil
    ) {
        let ordered = Self.chronological(points)
        self.points = ordered

        var indexByDate: [Date: Int] = [:]
        var minimumValue: Double?
        var maximumValue: Double?
        var fingerprint: UInt64 = 14_695_981_039_346_656_037
        for (index, point) in ordered.enumerated() {
            if indexByDate[point.date] == nil {
                indexByDate[point.date] = index
            }
            minimumValue = minimumValue.map { min($0, point.value) } ?? point.value
            maximumValue = maximumValue.map { max($0, point.value) } ?? point.value
            fingerprint ^= point.date.timeIntervalSinceReferenceDate.bitPattern
            fingerprint &*= 1_099_511_628_211
            fingerprint ^= point.value.bitPattern
            fingerprint &*= 1_099_511_628_211
        }
        self.indexByDate = indexByDate
        self.minimumValue = minimumValue
        self.maximumValue = maximumValue
        self.firstDate = ordered.first?.date
        self.lastDate = ordered.last?.date
        self.revision = FitnessBiologySeriesIdentity(
            metricID: identityContext?.metricID ?? "biology",
            rangeID: identityContext?.rangeID ?? "",
            endingDay: identityContext?.endingDay ?? .distantPast,
            sourceState: identityContext?.sourceState ?? "",
            window: identityContext?.window ?? "",
            provenance: identityContext?.provenance ?? "",
            sampleCount: ordered.count,
            sampleFingerprint: fingerprint
        )
    }

    static func make(
        metric: FitnessBiologyMetric,
        range: FitnessBiologyRange,
        endingAt date: Date,
        calendar: Calendar = .current
    ) -> FitnessBiologySeriesIndex {
        let points = metric.displaySamples(for: range, endingAt: date, calendar: calendar)
        let context = FitnessBiologySeriesIdentity(
            metricID: metric.id.rawValue,
            rangeID: range.rawValue,
            endingDay: calendar.startOfDay(for: date),
            sourceState: metric.sourceState.rawValue,
            window: metric.window ?? "",
            provenance: metric.provenance ?? "",
            sampleCount: 0,
            sampleFingerprint: 0
        )
        return FitnessBiologySeriesIndex(points: points, identityContext: context)
    }

    func index(for date: Date) -> Int? {
        indexByDate[date]
    }

    func point(for date: Date) -> FitnessBiologySample? {
        guard let index = index(for: date), points.indices.contains(index) else { return nil }
        return points[index]
    }

    /// Finds the nearest date in O(log n) because `points` is chronological.
    func nearestIndex(forX x: CGFloat, width: CGFloat, inset: CGFloat = 8) -> Int? {
        guard !points.isEmpty, width > 0,
              let firstDate, let lastDate else { return nil }
        let plotWidth = max(width - inset * 2, 1)
        let clampedX = min(max(x, inset), inset + plotWidth)
        let span = max(lastDate.timeIntervalSince(firstDate), 1)
        let target = firstDate.addingTimeInterval(
            span * Double((clampedX - inset) / plotWidth)
        )
        var lower = 0
        var upper = points.count - 1
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].date < target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        guard lower > 0 else { return 0 }
        let previous = lower - 1
        return abs(points[previous].date.timeIntervalSince(target)) <= abs(points[lower].date.timeIntervalSince(target))
            ? previous
            : lower
    }

    private static func chronological(_ points: [FitnessBiologySample]) -> [FitnessBiologySample] {
        guard points.count > 1 else { return points }
        let alreadyChronological = zip(points, points.dropFirst()).allSatisfy { $0.date <= $1.date }
        return alreadyChronological ? points : points.sorted { $0.date < $1.date }
    }
}

/// Source-backed Biology detail for the six Bevel IMG_0394–0395 metrics.
///
/// This view is intentionally standalone so it can be reviewed before it is
/// wired into the broader Fitness section. The default snapshot is honest and
/// empty; visual fixtures must be passed explicitly by the caller.
public struct FitnessBiologyDetailSurface: View {
    public let snapshot: FitnessBiologySnapshot
    public let usesVisualFixtures: Bool

    @Binding private var selectedDate: Date
    @State private var selectedRange: FitnessBiologyRange = .thirtyDays
    @State private var selectedMetric: FitnessBiologyMetricID?
    private let embeddedInParentScroll: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        snapshot: FitnessBiologySnapshot = .unavailable,
        selectedDate: Binding<Date>,
        usesVisualFixtures: Bool = false,
        embeddedInParentScroll: Bool = false
    ) {
        self.snapshot = snapshot
        self.usesVisualFixtures = usesVisualFixtures
        self.embeddedInParentScroll = embeddedInParentScroll
        _selectedDate = selectedDate
    }

    public var body: some View {
        Group {
            if embeddedInParentScroll {
                biologyContent
            } else {
                ScrollView {
                    biologyContent
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .tint(LifeOSTokens.accent)
        .modifier(FitnessBiologyNavigationTitle(isEmbedded: embeddedInParentScroll))
        .sheet(item: $selectedMetric) { id in
            if let metric = snapshot.metrics.first(where: { $0.id == id }) {
                FitnessBiologyMetricDetailView(metric: metric, selectedDate: selectedDate, initialRange: selectedRange)
            }
        }
        .accessibilityIdentifier("fitness-biology")
    }

    private var biologyContent: some View {
        LifeOSResponsiveContentContainer(
            horizontalPadding: embeddedInParentScroll ? 0 : 16,
            topPadding: embeddedInParentScroll ? 0 : 18,
            bottomPadding: embeddedInParentScroll ? 0 : 32
        ) {
            VStack(alignment: .leading, spacing: 18) {
                if presentationPolicy.showsPageHeader {
                    biologyHeader
                } else {
                    biologyRangeControl
                }
                FitnessBiologicalAgeCard(age: snapshot.biologicalAge, isFixture: usesVisualFixtures)
                metricSection
            }
        }
    }

    private var presentationPolicy: FitnessBiologyPresentationPolicy {
        FitnessBiologyPresentationPolicy(embeddedInParentScroll: embeddedInParentScroll)
    }

    private var biologyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Biology")
                        .lifeOSTypography(.pageTitle)
                    Text("Source-backed body signals")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                if usesVisualFixtures {
                    Text("DEMO · NOT LIVE")
                        .lifeOSTypography(.metadata, weight: .semibold)
                        .foregroundStyle(LifeOSTokens.warning)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(LifeOSTokens.warning.opacity(0.12), in: Capsule())
                }
            }

            HStack(spacing: 8) {
                Button {
                    shiftDate(by: -1)
                } label: {
                    LifeOSIcon(.chevronLeft)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(BiologyQuietIconButtonStyle())
                .accessibilityLabel("Previous biology date")

                DatePicker("Date", selection: $selectedDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("fitness-biology-date")

                Button {
                    shiftDate(by: 1)
                } label: {
                    LifeOSIcon(.chevronRight)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(BiologyQuietIconButtonStyle())
                .accessibilityLabel("Next biology date")
                Spacer(minLength: 0)
            }

            biologyRangeControl
        }
    }

    private var biologyRangeControl: some View {
        HStack(alignment: .center, spacing: 10) {
            Text("Trend range")
                .lifeOSTypography(.metadata, weight: .semibold)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Picker("Range", selection: $selectedRange) {
                ForEach(FitnessBiologyRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.menu)
            .lifeOSTypography(.metadata, weight: .semibold)
            .accessibilityIdentifier("fitness-biology-range")
            Spacer(minLength: 0)
        }
    }

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Body metrics")
                    .lifeOSTypography(.sectionTitle)
                Text("Each value keeps its source, window, and freshness")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }

            if let sharedUnavailableReason {
                FitnessBiologyAvailabilityNotice(reason: sharedUnavailableReason)
            }

            FitnessBiologyMetricColumns(
                spacing: 12,
                forceSingleColumn: dynamicTypeSize.isAccessibilitySize
            ) {
                ForEach(visibleMetrics) { metric in
                    FitnessBiologyMetricCard(
                        metric: metric,
                        date: selectedDate,
                        range: selectedRange,
                        isFixture: usesVisualFixtures,
                        sharedUnavailableReason: sharedUnavailableReason
                    ) {
                        selectedMetric = metric.id
                    }
                }
            }
        }
    }

    private var visibleMetrics: [FitnessBiologyMetric] {
        Array(snapshot.metrics.prefix(6))
    }

    private var sharedUnavailableReason: String? {
        let unavailableMetrics = visibleMetrics.filter { $0.currentValue == nil }
        guard !unavailableMetrics.isEmpty,
              unavailableMetrics.count == visibleMetrics.count else { return nil }
        let reasons = Set(unavailableMetrics.map(\.stateDetail))
        guard reasons.count == 1 else { return nil }
        return reasons.first
    }

    private func shiftDate(by days: Int) {
        let calendar = Calendar(identifier: .gregorian)
        selectedDate = calendar.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }
}

private struct FitnessBiologyMetricColumns: Layout {
    let spacing: CGFloat
    let forceSingleColumn: Bool

    init(spacing: CGFloat, forceSingleColumn: Bool = false) {
        self.spacing = spacing
        self.forceSingleColumn = forceSingleColumn
    }

    private func columnCount(for width: CGFloat) -> Int {
        forceSingleColumn ? 1 : (width >= 720 ? 2 : 1)
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let count = min(columnCount(for: width), max(subviews.count, 1))
        let columnWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            rowHeight = max(rowHeight, subviews[index].sizeThatFits(.init(width: columnWidth, height: nil)).height)
            if index % count == count - 1 || index == subviews.count - 1 {
                height += rowHeight
                if index < subviews.count - 1 { height += spacing }
                rowHeight = 0
            }
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = min(columnCount(for: bounds.width), max(subviews.count, 1))
        let columnWidth = max(1, (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let column = index % count
            let size = subviews[index].sizeThatFits(.init(width: columnWidth, height: nil))
            rowHeight = max(rowHeight, size.height)
            subviews[index].place(
                at: CGPoint(x: bounds.minX + CGFloat(column) * (columnWidth + spacing), y: y),
                anchor: .topLeading,
                proposal: .init(width: columnWidth, height: size.height)
            )
            if column == count - 1 || index == subviews.count - 1 {
                y += rowHeight + spacing
                rowHeight = 0
            }
        }
    }
}

private struct FitnessBiologicalAgeCard: View {
    let age: FitnessBiologicalAge
    let isFixture: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion

    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Biological age")
                        .lifeOSTypography(.sectionTitle)
                    Text("Experimental · not a clinical result")
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: age.isReviewedAndDisplayable ? "checkmark.seal" : "info.circle")
                    .lifeOSTypography(.button)
                    .foregroundStyle(age.isReviewedAndDisplayable ? LifeOSTokens.success : LifeOSTokens.tertiaryText)
            }

            switch age.state {
            case .observed(let value, _, let model, let reviewedAt, let window, let provenance):
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(value, format: .number.precision(.fractionLength(1)))
                        .lifeOSTypography(.metricCompact)
                        .monospacedDigit()
                    Text("years")
                        .lifeOSTypography(.body)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reviewed model · \(model)")
                    Text("Reviewed \(reviewedAt, format: .dateTime.year().month().day()) · \(window)")
                    Text(provenance)
                }
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            case .unavailable(let reason), .calibrating(let reason), .gated(let reason):
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("—")
                        .lifeOSTypography(.metricCompact)
                        .monospacedDigit()
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Text(reason)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if isFixture {
                Text("DEMO · NOT LIVE HEALTH DATA")
                    .lifeOSTypography(.metadata, weight: .semibold)
                    .foregroundStyle(LifeOSTokens.warning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .overlay(LifeOSTokens.cardShape.stroke(hovering ? LifeOSTokens.accent.opacity(0.30) : Color.clear, lineWidth: hovering ? 1 : 0.75))
        .onHover { hovering = $0 }
        .animation(LifeOSMotion.curve(for: .hover, reduceMotion: reduceMotion)?.animation, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-biology-age")
    }
}

private struct FitnessBiologyMetricCard: View {
    let metric: FitnessBiologyMetric
    let date: Date
    let range: FitnessBiologyRange
    let isFixture: Bool
    let sharedUnavailableReason: String?
    let onTap: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.lifeOSReduceMotion) private var requestedReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var reduceMotion: Bool { systemReduceMotion || requestedReduceMotion }

    private var visiblePoints: [FitnessBiologySample] {
        metric.displaySamples(for: range, endingAt: date)
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(metric.title)
                        .lifeOSTypography(.cardTitle)
                        .foregroundStyle(Color.primary)
                    if metric.isDemo || isFixture {
                        Text("DEMO")
                            .lifeOSTypography(.metadata, weight: .bold)
                            .foregroundStyle(LifeOSTokens.warning)
                    }
                    Spacer(minLength: 0)
                }
                metricValue
                if let metadataLine {
                    Text(metadataLine)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                if visiblePoints.count > 1 {
                    FitnessBiologyMiniChart(points: visiblePoints, hue: metric.id.hue)
                        .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36)
                }
            }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatCard()
            .overlay(LifeOSTokens.cardShape.stroke(hovering ? LifeOSTokens.strongBorder : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(LifeOSMotion.curve(for: .hover, reduceMotion: reduceMotion)?.animation, value: hovering)
        .accessibilityLabel("\(metric.title), \(metric.accessibilityValue)")
        .accessibilityHint("Opens the \(metric.title) trend detail")
        .accessibilityIdentifier("fitness-biology-metric-\(metric.id.rawValue)")
    }

    @ViewBuilder private var metricValue: some View {
        if metric.currentValue != nil {
            let sampleCount = metric.sampleCount ?? 0
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    metricValueContent(sampleCount: sampleCount)
                }
            } else {
                HStack(alignment: .lastTextBaseline, spacing: 4) {
                    metricValueContent(sampleCount: sampleCount)
                }
            }
        } else {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 3) {
                    Text("—")
                        .lifeOSTypography(.sectionTitle, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Text(metric.unit.label)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("—")
                        .lifeOSTypography(.sectionTitle, weight: .semibold)
                        .monospacedDigit()
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Text(metric.unit.label)
                        .lifeOSTypography(.metadata)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
    }

    @ViewBuilder
    private func metricValueContent(sampleCount: Int) -> some View {
        Text(metric.displayValue)
            .lifeOSTypography(.metric)
            .monospacedDigit()
            .foregroundStyle(Color.primary)
        Text(metric.unit.label)
            .lifeOSTypography(.metadata, weight: .semibold)
            .foregroundStyle(LifeOSTokens.tertiaryText)
        Text("· \(sampleCount) samples")
            .lifeOSTypography(.metadata)
            .foregroundStyle(LifeOSTokens.tertiaryText)
    }

    private var metadataLine: String? {
        guard metric.currentValue != nil else {
            return metric.stateDetail == sharedUnavailableReason ? nil : metric.stateDetail
        }
        switch metric.state {
        case .observed(_, _, let device, _, let freshness, let window, _, _), .demo(_, _, let device, _, let freshness, let window, _, _):
            return "\(metric.sourceState.label) · \(device) · \(freshness) · \(window)"
        case .unavailable, .calibrating:
            return metric.stateDetail
        }
    }
}

private struct FitnessBiologyAvailabilityNotice: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LifeOSIcon(.warning)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 16, height: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text("Body metrics unavailable")
                    .lifeOSTypography(.metadata, weight: .semibold)
                Text(reason)
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface.opacity(0.58), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-biology-unavailable-notice")
    }
}

private extension FitnessBiologyMetric {
    /// Builds the display window once for the caller. The domain's public
    /// `samples` accessor remains the source truth, while this view path avoids
    /// sorting the same source array again for every card render.
    func displaySamples(
        for range: FitnessBiologyRange,
        endingAt date: Date,
        calendar: Calendar = .current
    ) -> [FitnessBiologySample] {
        guard sourceState.canDisplayValue,
              date.timeIntervalSinceReferenceDate.isFinite else { return [] }
        let endDay = calendar.startOfDay(for: date)
        guard let start = calendar.date(byAdding: .day, value: -(range.days - 1), to: endDay),
              let end = calendar.date(byAdding: .day, value: 1, to: endDay) else {
            return []
        }

        let sourceSamples: [FitnessBiologySample]
        switch state {
        case .observed(_, _, _, _, _, _, _, let samples), .demo(_, _, _, _, _, _, _, let samples):
            sourceSamples = samples
        case .unavailable, .calibrating:
            return []
        }

        let scoped = sourceSamples.filter { $0.date >= start && $0.date < end }
        guard scoped.count > 1 else { return scoped }
        let alreadyChronological = zip(scoped, scoped.dropFirst()).allSatisfy { $0.date <= $1.date }
        return alreadyChronological ? scoped : scoped.sorted { $0.date < $1.date }
    }

    var accessibilityValue: String {
        guard currentValue != nil else { return "\(sourceState.label) · value unavailable" }
        switch state {
        case .observed(let value, let unit, _, let count, let freshness, let window, _, _), .demo(let value, let unit, _, let count, let freshness, let window, _, _):
            return "\(value) \(unit.label), \(count) samples, \(sourceState.label), \(freshness), \(window)"
        case .unavailable(let reason), .calibrating(let reason):
            return "\(sourceState.label): \(reason)"
        }
    }
}

private struct FitnessBiologyMiniChart: View {
    let points: [FitnessBiologySample]
    let hue: LifeOSTokens.Hue

    var body: some View {
        Group {
            if points.count > 1 {
                GeometryReader { geometry in
                    let path = FitnessBiologyChartGeometry.path(for: points, in: geometry.size)
                    ZStack {
                        path
                            .stroke(hue.base.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                        path
                            .stroke(hue.base, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                }
            } else {
                EmptyView()
            }
        }
        .accessibilityHidden(true)
    }
}

public struct FitnessBiologyMetricDetailView: View {
    public let metric: FitnessBiologyMetric
    public let selectedDate: Date
    public let initialRange: FitnessBiologyRange

    @State private var range: FitnessBiologyRange
    @State private var selectedPointDate: Date?
    @State private var series: FitnessBiologySeriesIndex

    public init(metric: FitnessBiologyMetric, selectedDate: Date, initialRange: FitnessBiologyRange = .thirtyDays) {
        self.metric = metric
        self.selectedDate = selectedDate
        self.initialRange = initialRange
        _range = State(initialValue: initialRange)
        _series = State(initialValue: FitnessBiologySeriesIndex.make(
            metric: metric,
            range: initialRange,
            endingAt: selectedDate
        ))
    }

    public var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(horizontalPadding: 16, topPadding: 18, bottomPadding: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title)
                                .lifeOSTypography(.pageTitle)
                            Text("Source-backed trend detail")
                                .lifeOSTypography(.body)
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        Spacer(minLength: 8)
                        Picker("Range", selection: $range) {
                            ForEach(FitnessBiologyRange.allCases) { range in
                                Text(range.rawValue).tag(range)
                            }
                        }
                        .pickerStyle(.menu)
                    }

                    FitnessBiologyDetailHero(metric: metric)

                    if series.points.count > 1 {
                        FitnessBiologyTrendCard(metric: metric, series: series, selectedDate: $selectedPointDate)
                    } else {
                        FitnessBiologyEmptyTrendCard(metric: metric, pointCount: series.points.count)
                    }

                    FitnessBiologyProvenanceCard(metric: metric)
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle(metric.title)
        .onChange(of: range) { _, _ in rebuildSeries() }
        .onChange(of: metric) { _, newMetric in rebuildSeries(for: newMetric) }
        .accessibilityIdentifier("fitness-biology-detail-\(metric.id.rawValue)")
    }

    private func rebuildSeries(for updatedMetric: FitnessBiologyMetric? = nil) {
        let next = FitnessBiologySeriesIndex.make(
            metric: updatedMetric ?? metric,
            range: range,
            endingAt: selectedDate
        )
        series = next
        if let selectedPointDate, next.index(for: selectedPointDate) == nil {
            self.selectedPointDate = nil
        }
    }
}

private struct FitnessBiologyDetailHero: View {
    let metric: FitnessBiologyMetric

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            if let value = metric.currentValue {
                Text(value, format: .number.precision(.fractionLength(metric.id == .hrvBaseline || metric.id == .rhrBaseline ? 0 : 1)))
                    .lifeOSTypography(.metric)
                    .monospacedDigit()
                Text(metric.unit.label)
                    .lifeOSTypography(.body, weight: .semibold)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                Text("—")
                    .lifeOSTypography(.metric)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text(metric.stateDetail)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
        }
        .padding(16)
        .flatCard()
    }
}

private struct FitnessBiologyTrendCard: View {
    let metric: FitnessBiologyMetric
    let series: FitnessBiologySeriesIndex
    @Binding var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trend")
                    .lifeOSTypography(.sectionTitle)
                Spacer()
                Text("Drag to inspect")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            FitnessBiologyTrendChart(series: series, hue: metric.id.hue, metricTitle: metric.title, metricUnit: metric.unit.label, selectedDate: $selectedDate)
                .frame(height: 190)
            if let selectedDate, let point = series.point(for: selectedDate) {
                HStack(alignment: .firstTextBaseline) {
                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                    Spacer()
                    Text(point.value, format: .number.precision(.fractionLength(metric.id == .hrvBaseline || metric.id == .rhrBaseline ? 0 : 1)))
                        .lifeOSTypography(.body, weight: .semibold)
                    Text(metric.unit.label)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .lifeOSTypography(.metadata)
                .padding(.top, 2)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Selected \(metric.title) value")
            }
        }
        .padding(16)
        .flatCard()
    }
}

private struct FitnessBiologyTrendChart: View {
    let series: FitnessBiologySeriesIndex
    let hue: LifeOSTokens.Hue
    let metricTitle: String
    let metricUnit: String
    @Binding var selectedDate: Date?

    private var selectedIndex: Int? {
        guard let selectedDate else { return nil }
        return series.index(for: selectedDate)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LifeOSChartDrawReveal(content: ZStack(alignment: .topLeading) {
                    FitnessBiologyChartGeometry.path(for: series, in: geometry.size)
                        .stroke(hue.base, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                })
                if let selectedIndex, series.points.indices.contains(selectedIndex) {
                    let point = series.points[selectedIndex]
                    let location = FitnessBiologyChartGeometry.location(
                        for: point,
                        index: selectedIndex,
                        series: series,
                        in: geometry.size
                    )
                    Rectangle()
                        .fill(LifeOSTokens.tertiaryText.opacity(0.28))
                        .frame(width: 1, height: geometry.size.height)
                        .offset(x: location.x)
                    Circle()
                        .fill(LifeOSTokens.surface)
                        .overlay(Circle().stroke(hue.base, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(location)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(DragGesture(minimumDistance: LifeOSDirectionalClassifier.minimumDistance).onChanged { gesture in
                guard LifeOSDirectionalClassifier.classify(gesture.translation) == .horizontal else { return }
                let x = min(max(gesture.location.x, 0), geometry.size.width)
                if let index = series.nearestIndex(forX: x, width: geometry.size.width),
                   series.points.indices.contains(index) {
                    selectedDate = series.points[index].date
                } else {
                    selectedDate = nil
                }
            })
        }
        .chartDrawOn(id: series.revision)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metricTitle) trend chart")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Swipe up or down to inspect adjacent samples.")
        .accessibilityAdjustableAction { direction in
            guard !series.points.isEmpty else { return }
            let current = selectedIndex ?? (direction == .increment ? -1 : series.points.count)
            let next: Int
            switch direction {
            case .increment: next = min(series.points.count - 1, current + 1)
            case .decrement: next = max(0, current - 1)
            @unknown default: return
            }
            selectedDate = series.points[next].date
        }
    }

    private var accessibilityValue: String {
        guard let index = selectedIndex, series.points.indices.contains(index) else {
            return series.points.isEmpty ? "Unavailable" : "Observed samples; no sample selected"
        }
        let point = series.points[index]
        return "Selected \(point.date.formatted(date: .abbreviated, time: .omitted)), \(point.value.formatted(.number.precision(.fractionLength(0...2)))) \(metricUnit)"
    }
}

private struct FitnessBiologyEmptyTrendCard: View {
    let metric: FitnessBiologyMetric
    let pointCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pointCount == 1 ? "Insufficient history" : "No trend available")
                .lifeOSTypography(.sectionTitle)
            Text(pointCount == 1 ? "One source sample is available; a trend needs more observations." : metric.stateDetail)
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
    }
}

private struct FitnessBiologyProvenanceCard: View {
    let metric: FitnessBiologyMetric

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Source details")
                .lifeOSTypography(.sectionTitle)
            sourceRow("State", metric.sourceState.label)
            switch metric.state {
            case .observed(_, _, let device, let count, let freshness, let window, let provenance, _), .demo(_, _, let device, let count, let freshness, let window, let provenance, _):
                sourceRow("Device", device)
                sourceRow("Samples", "\(count)")
                sourceRow("Freshness", freshness)
                sourceRow("Window", window)
                sourceRow("Provenance", provenance)
            case .unavailable(let reason), .calibrating(let reason):
                Text(reason)
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
    }

    private func sourceRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Spacer(minLength: 8)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .lifeOSTypography(.metadata)
    }
}

private enum FitnessBiologyChartGeometry {
    static func path(for points: [FitnessBiologySample], in size: CGSize) -> Path {
        guard points.count > 1 else { return Path() }
        let values = points.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let spread = max(maxValue - minValue, 0.000_001)
        let inset: CGFloat = 8
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        var path = Path()
        var previousDate: Date?
        for (index, point) in points.enumerated() {
            let x = x(
                for: point.date,
                firstDate: points[0].date,
                lastDate: points[points.count - 1].date,
                width: width,
                inset: inset
            )
            let normalized = (point.value - minValue) / spread
            let y = inset + height * CGFloat(1 - normalized)
            let location = CGPoint(x: x, y: y)
            let hasGap = previousDate.map { abs(point.date.timeIntervalSince($0)) > 36 * 60 * 60 } ?? false
            if index == 0 || hasGap {
                path.move(to: location)
            } else {
                path.addLine(to: location)
            }
            previousDate = point.date
        }
        return path
    }

    static func path(for series: FitnessBiologySeriesIndex, in size: CGSize) -> Path {
        guard series.points.count > 1,
              let minValue = series.minimumValue,
              let maxValue = series.maximumValue,
              let firstDate = series.firstDate,
              let lastDate = series.lastDate else { return Path() }
        let spread = max(maxValue - minValue, 0.000_001)
        let inset: CGFloat = 8
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        var path = Path()
        var previousDate: Date?
        for (index, point) in series.points.enumerated() {
            let x = x(for: point.date, firstDate: firstDate, lastDate: lastDate, width: width, inset: inset)
            let normalized = (point.value - minValue) / spread
            let y = inset + height * CGFloat(1 - normalized)
            let location = CGPoint(x: x, y: y)
            let hasGap = previousDate.map { abs(point.date.timeIntervalSince($0)) > 36 * 60 * 60 } ?? false
            if index == 0 || hasGap {
                path.move(to: location)
            } else {
                path.addLine(to: location)
            }
            previousDate = point.date
        }
        return path
    }

    static func location(
        for point: FitnessBiologySample,
        index: Int,
        series: FitnessBiologySeriesIndex,
        in size: CGSize
    ) -> CGPoint {
        guard series.points.indices.contains(index), series.points.count > 1,
              let minValue = series.minimumValue,
              let maxValue = series.maximumValue,
              let firstDate = series.firstDate,
              let lastDate = series.lastDate else {
            return CGPoint(x: size.width / 2, y: size.height / 2)
        }
        let spread = max(maxValue - minValue, 0.000_001)
        let inset: CGFloat = 8
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let x = x(for: point.date, firstDate: firstDate, lastDate: lastDate, width: width, inset: inset)
        let y = inset + height * CGFloat(1 - (point.value - minValue) / spread)
        return CGPoint(x: x, y: y)
    }

    private static func x(
        for date: Date,
        firstDate: Date,
        lastDate: Date,
        width: CGFloat,
        inset: CGFloat
    ) -> CGFloat {
        let span = max(lastDate.timeIntervalSince(firstDate), 1)
        let fraction = min(max(date.timeIntervalSince(firstDate) / span, 0), 1)
        return inset + width * CGFloat(fraction)
    }
}

private struct BiologyQuietIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? LifeOSTokens.accent : LifeOSTokens.tertiaryText)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
    }
}
