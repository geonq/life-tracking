import SwiftUI

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
    @State private var showAllMetrics = false
    @State private var selectedMetric: FitnessBiologyMetricID?
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    public init(
        snapshot: FitnessBiologySnapshot = .unavailable,
        selectedDate: Binding<Date>,
        usesVisualFixtures: Bool = false
    ) {
        self.snapshot = snapshot
        self.usesVisualFixtures = usesVisualFixtures
        _selectedDate = selectedDate
    }

    public var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(horizontalPadding: 16, topPadding: 18, bottomPadding: 32) {
                VStack(alignment: .leading, spacing: 18) {
                    biologyHeader
                    FitnessBiologicalAgeCard(age: snapshot.biologicalAge, isFixture: usesVisualFixtures)
                    metricSection
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .tint(LifeOSTokens.accent)
        .navigationTitle("Biology")
        .sheet(item: $selectedMetric) { id in
            if let metric = snapshot.metrics.first(where: { $0.id == id }) {
                FitnessBiologyMetricDetailView(metric: metric, selectedDate: selectedDate, initialRange: selectedRange)
            }
        }
        .accessibilityIdentifier("fitness-biology")
    }

    private var biologyHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Biology")
                        .font(LifeOSFont.headerLarge(28))
                    Text("Source-backed body signals")
                        .font(LifeOSFont.body(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                if usesVisualFixtures {
                    Text("DEMO · NOT LIVE")
                        .font(LifeOSFont.caption(9).weight(.semibold))
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
                        .frame(width: 30, height: 30)
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
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(BiologyQuietIconButtonStyle())
                .accessibilityLabel("Next biology date")

                Spacer(minLength: 4)

                Picker("Range", selection: $selectedRange) {
                    ForEach(FitnessBiologyRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.menu)
                .font(LifeOSFont.caption(11).weight(.semibold))
                .accessibilityIdentifier("fitness-biology-range")
            }
        }
    }

    private var metricSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Body metrics")
                        .font(LifeOSFont.header(17))
                    Text("Each value keeps its source, window, and freshness")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                if snapshot.metrics.count > 3 && !showsAllMetricsByDefault {
                    Button(showAllMetrics ? "Show less" : "Show all") {
                        withAnimation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy) {
                            showAllMetrics.toggle()
                        }
                    }
                    .font(LifeOSFont.caption(11).weight(.semibold))
                    .buttonStyle(.plain)
                    .foregroundStyle(LifeOSTokens.accent)
                    .accessibilityIdentifier("fitness-biology-show-all")
                }
            }

            LazyVGrid(columns: metricGridColumns, spacing: 12) {
                ForEach(visibleMetrics) { metric in
                    FitnessBiologyMetricCard(
                        metric: metric,
                        date: selectedDate,
                        range: selectedRange,
                        isFixture: usesVisualFixtures,
                        onTap: { selectedMetric = metric.id }
                    )
                }
            }
            .animation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.primary, value: showAllMetrics)
        }
    }

    private var visibleMetrics: [FitnessBiologyMetric] {
        showAllMetrics || showsAllMetricsByDefault ? snapshot.metrics : Array(snapshot.metrics.prefix(3))
    }

    private var showsAllMetricsByDefault: Bool {
#if os(macOS)
        true
#else
        horizontalSizeClass == .regular
#endif
    }

    private var metricGridColumns: [GridItem] {
#if os(macOS)
        Array(repeating: GridItem(.flexible(minimum: 0), spacing: 12), count: 3)
#else
        [GridItem(.adaptive(minimum: 286), spacing: 12)]
#endif
    }

    private func shiftDate(by days: Int) {
        let calendar = Calendar(identifier: .gregorian)
        selectedDate = calendar.date(byAdding: .day, value: days, to: selectedDate) ?? selectedDate
    }
}

private struct FitnessBiologicalAgeCard: View {
    let age: FitnessBiologicalAge
    let isFixture: Bool
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Biological age")
                        .font(LifeOSFont.header(17))
                    Text("Experimental · not a clinical result")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                Image(systemName: age.isReviewedAndDisplayable ? "checkmark.seal" : "info.circle")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(age.isReviewedAndDisplayable ? LifeOSTokens.success : LifeOSTokens.tertiaryText)
            }

            switch age.state {
            case .observed(let value, _, let model, let reviewedAt, let window, let provenance):
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(value, format: .number.precision(.fractionLength(1)))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text("years")
                        .font(LifeOSFont.body(14))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Reviewed model · \(model)")
                    Text("Reviewed \(reviewedAt, format: .dateTime.year().month().day()) · \(window)")
                    Text(provenance)
                }
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            case .unavailable(let reason), .calibrating(let reason), .gated(let reason):
                Text(reason)
                    .font(LifeOSFont.body(13))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Only a reviewed model with explicit source metadata can show a value.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }

            if isFixture {
                Text("DEMO · NOT LIVE HEALTH DATA")
                    .font(LifeOSFont.caption(9).weight(.semibold))
                    .foregroundStyle(LifeOSTokens.warning)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .overlay(LifeOSTokens.cardShape.stroke(hovering ? LifeOSTokens.accent.opacity(0.30) : Color.clear, lineWidth: hovering ? 1 : 0.75))
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : LifeOSMotion.snappy, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-biology-age")
    }
}

private struct FitnessBiologyMetricCard: View {
    let metric: FitnessBiologyMetric
    let date: Date
    let range: FitnessBiologyRange
    let isFixture: Bool
    let onTap: () -> Void
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visiblePoints: [FitnessBiologySample] { metric.samples(for: range, endingAt: date) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 7) {
                        Text(metric.title)
                            .font(LifeOSFont.header(15))
                            .foregroundStyle(Color.primary)
                        if metric.isDemo || isFixture {
                            Text("DEMO")
                                .font(LifeOSFont.caption(8).weight(.bold))
                                .foregroundStyle(LifeOSTokens.warning)
                        }
                    }
                    metricValue
                    Text(metadataLine)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                FitnessBiologyMiniChart(points: visiblePoints, hue: metric.id.hue, isEmpty: metric.currentValue == nil)
                    .frame(width: 94, height: 52)
            }
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 118, alignment: .leading)
            .flatCard()
            .overlay(LifeOSTokens.cardShape.stroke(hovering ? LifeOSTokens.strongBorder : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : LifeOSMotion.snappy, value: hovering)
        .accessibilityLabel("\(metric.title), \(metric.accessibilityValue)")
        .accessibilityHint("Opens the \(metric.title) trend detail")
        .accessibilityIdentifier("fitness-biology-metric-\(metric.id.rawValue)")
    }

    @ViewBuilder private var metricValue: some View {
        switch metric.state {
        case .observed(let value, let unit, _, let sampleCount, _, _, _, _), .demo(let value, let unit, _, let sampleCount, _, _, _, _):
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(value, format: .number.precision(.fractionLength(metric.id == .hrvBaseline || metric.id == .rhrBaseline ? 0 : 1)))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                Text(unit.label)
                    .font(LifeOSFont.caption(11).weight(.semibold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text("· \(sampleCount) samples")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        case .unavailable, .calibrating:
            Text("— \(metric.unit.label)")
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }

    private var metadataLine: String {
        switch metric.state {
        case .observed(_, _, let device, _, let freshness, let window, _, _), .demo(_, _, let device, _, let freshness, let window, _, _):
            return "\(device) · \(freshness) · \(window)"
        case .unavailable(let reason), .calibrating(let reason):
            return reason
        }
    }
}

private extension FitnessBiologyMetric {
    var accessibilityValue: String {
        switch state {
        case .observed(let value, let unit, _, let count, let freshness, let window, _, _), .demo(let value, let unit, _, let count, let freshness, let window, _, _):
            return "\(value) \(unit.label), \(count) samples, \(freshness), \(window)"
        case .unavailable(let reason), .calibrating(let reason):
            return reason
        }
    }
}

private struct FitnessBiologyMiniChart: View {
    let points: [FitnessBiologySample]
    let hue: LifeOSTokens.Hue
    let isEmpty: Bool

    var body: some View {
        GeometryReader { geometry in
            if points.count > 1 {
                let path = FitnessBiologyChartGeometry.path(for: points, in: geometry.size)
                ZStack {
                    path
                        .stroke(LifeOSTokens.accent.opacity(0.22), style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
                    path
                        .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            } else {
                HStack(spacing: 4) {
                    Circle().fill(isEmpty ? LifeOSTokens.tertiaryText.opacity(0.45) : LifeOSTokens.accent).frame(width: 5, height: 5)
                    Rectangle().fill(LifeOSTokens.quietBorder).frame(height: 1)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
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
    @State private var selectedIndex: Int?

    public init(metric: FitnessBiologyMetric, selectedDate: Date, initialRange: FitnessBiologyRange = .thirtyDays) {
        self.metric = metric
        self.selectedDate = selectedDate
        self.initialRange = initialRange
        _range = State(initialValue: initialRange)
    }

    private var points: [FitnessBiologySample] { metric.samples(for: range, endingAt: selectedDate) }

    public var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(horizontalPadding: 16, topPadding: 18, bottomPadding: 28) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(metric.title)
                                .font(LifeOSFont.headerLarge(26))
                            Text("Source-backed trend detail")
                                .font(LifeOSFont.body(13))
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

                    if points.count > 1 {
                        FitnessBiologyTrendCard(metric: metric, points: points, selectedIndex: $selectedIndex)
                    } else {
                        FitnessBiologyEmptyTrendCard(metric: metric, pointCount: points.count)
                    }

                    FitnessBiologyProvenanceCard(metric: metric)
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle(metric.title)
        .onChange(of: range) { _, _ in selectedIndex = nil }
        .accessibilityIdentifier("fitness-biology-detail-\(metric.id.rawValue)")
    }
}

private struct FitnessBiologyDetailHero: View {
    let metric: FitnessBiologyMetric

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 8) {
            if let value = metric.currentValue {
                Text(value, format: .number.precision(.fractionLength(metric.id == .hrvBaseline || metric.id == .rhrBaseline ? 0 : 1)))
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(metric.unit.label)
                    .font(LifeOSFont.body(15).weight(.semibold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                Text("—")
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text(metric.stateDetail)
                    .font(LifeOSFont.body(13))
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
    let points: [FitnessBiologySample]
    @Binding var selectedIndex: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trend")
                    .font(LifeOSFont.header(15))
                Spacer()
                Text("Drag to inspect")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            FitnessBiologyTrendChart(points: points, hue: metric.id.hue, selectedIndex: $selectedIndex)
                .frame(height: 190)
            if let selectedIndex, points.indices.contains(selectedIndex) {
                let point = points[selectedIndex]
                HStack(alignment: .firstTextBaseline) {
                    Text(point.date, format: .dateTime.month(.abbreviated).day())
                    Spacer()
                    Text(point.value, format: .number.precision(.fractionLength(metric.id == .hrvBaseline || metric.id == .rhrBaseline ? 0 : 1)))
                        .font(.system(.body, design: .rounded).weight(.semibold))
                    Text(metric.unit.label)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .font(LifeOSFont.caption(11))
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
    let points: [FitnessBiologySample]
    let hue: LifeOSTokens.Hue
    @Binding var selectedIndex: Int?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                FitnessBiologyChartGeometry.path(for: points, in: geometry.size)
                    .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if let selectedIndex, points.indices.contains(selectedIndex) {
                    let point = points[selectedIndex]
                    let location = FitnessBiologyChartGeometry.location(for: point, points: points, in: geometry.size)
                    Rectangle()
                        .fill(LifeOSTokens.tertiaryText.opacity(0.28))
                        .frame(width: 1, height: geometry.size.height)
                        .offset(x: location.x)
                    Circle()
                        .fill(LifeOSTokens.surface)
                        .overlay(Circle().stroke(LifeOSTokens.accent, lineWidth: 2))
                        .frame(width: 12, height: 12)
                        .position(location)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                let x = min(max(gesture.location.x, 0), geometry.size.width)
                selectedIndex = FitnessBiologyChartGeometry.closestIndex(forX: x, points: points, in: geometry.size)
            })
        }
        .animation(reduceMotion ? nil : LifeOSMotion.track, value: selectedIndex)
        .accessibilityLabel("\(points.count)-point trend chart")
    }
}

private struct FitnessBiologyEmptyTrendCard: View {
    let metric: FitnessBiologyMetric
    let pointCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(pointCount == 1 ? "Insufficient history" : "No trend available")
                .font(LifeOSFont.header(15))
            Text(pointCount == 1 ? "One source sample is available; a trend needs more observations." : metric.stateDetail)
                .font(LifeOSFont.body(13))
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
                .font(LifeOSFont.header(15))
            switch metric.state {
            case .observed(_, _, let device, let count, let freshness, let window, let provenance, _), .demo(_, _, let device, let count, let freshness, let window, let provenance, _):
                sourceRow("Device", device)
                sourceRow("Samples", "\(count)")
                sourceRow("Freshness", freshness)
                sourceRow("Window", window)
                sourceRow("Provenance", provenance)
            case .unavailable(let reason), .calibrating(let reason):
                Text(reason)
                    .font(LifeOSFont.body(13))
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
        .font(LifeOSFont.caption(11))
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
        for (index, point) in points.enumerated() {
            let x = inset + width * CGFloat(index) / CGFloat(max(points.count - 1, 1))
            let normalized = (point.value - minValue) / spread
            let y = inset + height * CGFloat(1 - normalized)
            if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    static func location(for point: FitnessBiologySample, points: [FitnessBiologySample], in size: CGSize) -> CGPoint {
        guard let index = points.firstIndex(of: point), points.count > 1 else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        let values = points.map(\.value)
        let minValue = values.min() ?? 0
        let maxValue = values.max() ?? 1
        let spread = max(maxValue - minValue, 0.000_001)
        let inset: CGFloat = 8
        let width = max(size.width - inset * 2, 1)
        let height = max(size.height - inset * 2, 1)
        let x = inset + width * CGFloat(index) / CGFloat(points.count - 1)
        let y = inset + height * CGFloat(1 - (point.value - minValue) / spread)
        return CGPoint(x: x, y: y)
    }

    static func closestIndex(forX x: CGFloat, points: [FitnessBiologySample], in size: CGSize) -> Int? {
        guard !points.isEmpty else { return nil }
        let inset: CGFloat = 8
        let width = max(size.width - inset * 2, 1)
        let normalized = min(max((x - inset) / width, 0), 1)
        return min(max(Int((normalized * CGFloat(points.count - 1)).rounded()), 0), points.count - 1)
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
