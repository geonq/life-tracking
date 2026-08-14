import SwiftUI
import Charts

// MARK: - Projection chart (02-charts-rings-widgets.md §2) — 4-series model.
//
// Target (green dashed) / Actual (blue solid, area fill) / Current estimate (orange dashed) /
// Past estimate (grey dotted, only if a prior-estimate series is actually stored — it is not,
// see DemoUsageAnalytics / UsageAnalyticsSnapshot, so this series is omitted rather than
// fabricated).

struct UsageProjectionChart: View {
    let provider: Provider
    let window: UsageWindow?
    let analytics: UsageAnalyticsSnapshot

    @State private var selectedIndex: Int?
    @State private var pinnedRangeStart: Date?
    @State private var zoomFactor: Double = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: Series data

    /// Actual = observed activity points in the selected window. The activity transport is
    /// hourly, so a selected 5-hour window must not quietly plot older observations.
    private var actualPoints: [UsageProjectionPoint] {
        let points = analytics.activity
            .sorted { $0.date < $1.date }
            .filter { point in
                guard let resetAt = window?.resetAt, let durationMinutes = window?.durationMinutes else { return true }
                let start = resetAt.addingTimeInterval(-Double(durationMinutes) * 60)
                return point.date >= start && point.date <= resetAt
            }
        return points.map { UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent) }
    }

    /// Current estimate = the forward projection engine's points, only when the analytics
    /// snapshot declares the same window. A range switch must never reuse another window's
    /// estimate, even if the dates happen to overlap.
    private var estimatePoints: [UsageProjectionPoint] {
        guard let windowID = analytics.windowID, windowID == window?.id else { return [] }
        let lastObservedDate = actualPoints.last?.date ?? .distantPast
        return analytics.projection
            .filter { $0.date > lastObservedDate }
            .filter { point in
                guard let resetAt = window?.resetAt else { return true }
                return point.date <= resetAt
            }
    }

    /// Target = straight-line ideal pace from the first observed point to 100% at reset.
    private var targetPoints: [UsageProjectionPoint] {
        guard let start = actualPoints.first, let resetAt = window?.resetAt, resetAt > start.date else { return [] }
        let totalSeconds = resetAt.timeIntervalSince(start.date)
        guard totalSeconds > 0 else { return [] }
        let steps = 12
        return (0...steps).map { step in
            let fraction = Double(step) / Double(steps)
            let date = start.date.addingTimeInterval(totalSeconds * fraction)
            let value = start.usedPercent + (1 - start.usedPercent) * fraction
            return UsageProjectionPoint(date: date, usedPercent: value)
        }
    }

    /// Past-estimate / account-history series — GAP. `UsageAnalyticsSnapshot` does not persist
    /// a prior estimate snapshot to compare against, so this series is always empty rather than
    /// fabricated. Flagged in 02 §2 / data-gaps list.
    private var historyPoints: [UsageProjectionPoint] { [] }

    private var allSelectablePoints: [UsageSelectionPoint] {
        (actualPoints.map { UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: false) }
            + estimatePoints.map { UsageSelectionPoint(date: $0.date, usedPercent: $0.usedPercent, isProjected: true) }
        )
        .sorted {
            if $0.date == $1.date {
                return !$0.isProjected && $1.isProjected
            }
            return $0.date < $1.date
        }
    }

    private var selectedPoint: UsageSelectionPoint? {
        guard let selectedIndex, allSelectablePoints.indices.contains(selectedIndex) else { return nil }
        return allSelectablePoints[selectedIndex]
    }

    private var chartDomain: ClosedRange<Date> {
        let dates = (targetPoints + historyPoints + estimatePoints + actualPoints).map(\.date)
        guard let earliest = dates.min(), let latest = dates.max(), latest > earliest else {
            let now = Date.now
            return now.addingTimeInterval(-3_600)...now
        }

        let lowerBound = max(pinnedRangeStart ?? earliest, earliest)
        let availableInterval = max(latest.timeIntervalSince(lowerBound), 60)
        let visibleInterval = availableInterval * zoomFactor
        return latest.addingTimeInterval(-visibleInterval)...latest
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            legend

            referenceChart
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let x = value.location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    selectClosest(to: date)
                                }
                            })
                        if let selectedPoint,
                           let x = proxy.position(forX: selectedPoint.date),
                           let y = proxy.position(forY: selectedPoint.usedPercent) {
                            ScrubBubble(x: frame.origin.x + x, y: max(18, frame.origin.y + y - 26)) {
                                Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: 190)
            .task(id: selectionDomainID) {
                // Do not invent a default observation. The hero is sourced from the selected
                // window, while analytics can contain a different observation cadence. A scrub
                // point appears only after the user explicitly chooses one.
                selectedIndex = nil
                pinnedRangeStart = nil
                zoomFactor = 1
            }

            detailRow

            belowChartRows
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) usage remaining chart")
        .accessibilityValue(chartAccessibilitySummary)
    }

    private var selectionDomainID: String {
        let pointIDs = allSelectablePoints.map { "\($0.date.timeIntervalSinceReferenceDate)-\($0.isProjected)" }
        return "\(window?.id ?? "none")|\(pointIDs.joined(separator: ","))"
    }

    private var chartAccessibilitySummary: String {
        guard let latest = actualPoints.last else {
            return "No observed hourly points are available."
        }
        let remaining = Int(((1 - latest.usedPercent) * 100).rounded())
        let timestamp = latest.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
        if let estimate = estimatePoints.last {
            let estimateTimestamp = estimate.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
            return "Latest observed value: \(remaining) percent remaining at \(timestamp). Current estimate reaches \(Int((estimate.usedPercent * 100).rounded())) percent used by \(estimateTimestamp)."
        }
        return "Latest observed value: \(remaining) percent remaining at \(timestamp). No estimate is available for this window."
    }

    private var referenceChart: some View {
        Chart {
                ForEach(actualPoints) { point in
                    AreaMark(x: .value("Time", point.date), y: .value("Actual area", point.usedPercent))
                        .foregroundStyle(actualAreaGradient)
                        .interpolationMethod(.catmullRom)
                    LineMark(
                        x: .value("Time", point.date),
                        y: .value("Actual", point.usedPercent),
                        series: .value("Series", "Actual")
                    )
                    .foregroundStyle(LifeOSTokens.Series.actual)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.catmullRom)
                }

                ForEach(targetPoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Target", point.usedPercent), series: .value("Series", "Target"))
                        .foregroundStyle(LifeOSTokens.Series.target)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [4, 3]))
                        .interpolationMethod(.catmullRom)
                }

                ForEach(historyPoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("History", point.usedPercent), series: .value("Series", "History"))
                        .foregroundStyle(LifeOSTokens.Series.history)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [1, 2]))
                        .interpolationMethod(.catmullRom)
                }

                ForEach(estimatePoints) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Estimate", point.usedPercent), series: .value("Series", "Estimate"))
                        .foregroundStyle(LifeOSTokens.Series.estimate)
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 2]))
                        .interpolationMethod(.catmullRom)
                }

                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.date))
                        .foregroundStyle(Color.primary.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 0.75))
                    PointMark(x: .value("Selected time", selectedPoint.date), y: .value("Selected usage", selectedPoint.usedPercent))
                        .symbolSize(46)
                        .foregroundStyle(LifeOSTokens.surface)
                        .annotation(position: .overlay) {
                            Circle()
                                .fill(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                                .frame(width: 7, height: 7)
                        }
                }
            }
            .chartYScale(domain: 0...1)
            .chartXScale(domain: chartDomain)
            .chartYAxis { yAxisMarks }
            .chartXAxis { xAxisMarks }
            .chartPlotStyle { plot in
                plot.mask(alignment: .leading) {
                    GeometryReader { geometry in
                        Rectangle()
                            .fill(.white)
                            .frame(width: geometry.size.width * chartDrawProgress)
                    }
                }
            }
            .chartDrawOn()
    }

    @Environment(\.lifeOSChartDrawn) private var chartDrawProgress

    private var yAxisMarks: some AxisContent {
        AxisMarks(values: [0, 0.25, 0.5, 0.75, 1]) { value in
            AxisGridLine().foregroundStyle(LifeOSTokens.chartGrid)
            AxisValueLabel {
                if let number = value.as(Double.self) { Text(number, format: .percent.precision(.fractionLength(0))) }
            }
        }
    }

    private var xAxisMarks: some AxisContent {
        let isShortWindow = window?.durationMinutes == UsageRange.fiveHour.durationMinutes
        return AxisMarks(values: .automatic(desiredCount: isShortWindow ? 5 : 7)) { value in
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    if isShortWindow {
                        Text(date, format: .dateTime.hour().minute())
                    } else {
                        Text(date, format: .dateTime.weekday(.abbreviated).day())
                    }
                }
            }
        }
    }

    private var actualAreaGradient: LinearGradient {
        LinearGradient(
            colors: [LifeOSTokens.Series.actual.opacity(0.22), LifeOSTokens.Series.actual.opacity(0)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var legend: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130, maximum: 240), alignment: .leading)],
            alignment: .leading,
            spacing: 8
        ) {
            UsageLegendKey(color: LifeOSTokens.Series.target, label: "Target", dashed: true)
            UsageLegendKey(color: LifeOSTokens.Series.actual, label: "Actual")
            if !estimatePoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.estimate, label: "Current estimate", dashed: true)
            }
            if !historyPoints.isEmpty {
                UsageLegendKey(color: LifeOSTokens.Series.history, label: "Past estimate", dotted: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Scrub detail row + prev/next stepper (02 §2 "Scrub bubble + stepper row")

    private var detailRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if let selectedPoint {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(selectedPoint.isProjected ? "Estimate" : "Actual")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selectedPoint.isProjected ? LifeOSTokens.Series.estimate : LifeOSTokens.Series.actual)
                        Text("\(Int((1 - selectedPoint.usedPercent) * 100))% remaining")
                            .font(.caption.weight(.semibold))
                        Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text("\(provider.displayName) · \(qualityTag)")
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            } else {
                Text("Scrub the chart or use the stepper for exact values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            stepperButtons
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var qualityTag: String {
        switch analytics.provenance.quality {
        case .observed: "Observed"
        case .estimated: "Derived estimate · Low confidence"
        case .demo: "Demo fixtures · not live"
        case .unavailable: "Unavailable"
        }
    }

    private var stepperButtons: some View {
        HStack(spacing: 6) {
            stepButton(icon: .chevronLeft, accessibilityLabel: "Previous usage point") { step(by: -1) }
                .disabled(allSelectablePoints.isEmpty || (selectedIndex ?? 0) <= 0)
            stepButton(icon: .chevronRight, accessibilityLabel: "Next usage point") { step(by: 1) }
                .disabled(allSelectablePoints.isEmpty)
        }
    }

    private func stepButton(icon: LifeOSIconName, accessibilityLabel: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            LifeOSIcon(icon)
                .frame(width: 10, height: 10)
                .frame(width: 26, height: 26)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .accessibilityLabel(accessibilityLabel)
    }

    private func step(by delta: Int) {
        guard !allSelectablePoints.isEmpty else { return }
        let current = selectedIndex ?? (delta > 0 ? -1 : allSelectablePoints.count)
        let next = min(max(current + delta, 0), allSelectablePoints.count - 1)
        if reduceMotion { selectedIndex = next }
        else {
            withAnimation(LifeOSMotion.track) { selectedIndex = next }
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    private func selectClosest(to date: Date) {
        guard !allSelectablePoints.isEmpty else { return }
        let closest = allSelectablePoints.enumerated().min {
            abs($0.element.date.timeIntervalSince(date)) < abs($1.element.date.timeIntervalSince(date))
        }
        if let closest, closest.offset != selectedIndex {
            selectedIndex = closest.offset
            ScrubBubble<EmptyView>.snapHaptic()
        }
    }

    // MARK: Below-chart rows (02 §2)

    private var belowChartRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.3)
            metaRow(
                label: "Set range start",
                value: selectedPoint.map { $0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "Choose a point",
                action: pinRangeStart
            )
            HStack(spacing: 16) {
                iconLabelButton(icon: .zoomIn, label: "Zoom in") { changeZoom(by: 0.6) }
                iconLabelButton(icon: .zoomOut, label: "Zoom out") { changeZoom(by: 1 / 0.6) }
            }
            metaRow(label: "Reset", value: resetText)
            metaRow(label: "Suggested pace", value: "Not enough data")
            metaRow(label: "Runway", value: "Not enough data")
        }
        .padding(.top, 2)
    }

    private var resetText: String {
        guard let resetAt = window?.resetAt else { return "Not available" }
        return resetAt.formatted(.dateTime.month(.abbreviated).day().year().hour().minute())
    }

    @ViewBuilder
    private func metaRow(label: String, value: String, action: (() -> Void)? = nil) -> some View {
        if let action {
            Button(action: action) {
                metaRowContent(label: label, value: value)
            }
            .buttonStyle(.plain)
            .disabled(selectedPoint == nil)
        } else {
            metaRowContent(label: label, value: value)
        }
    }

    private func metaRowContent(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).foregroundStyle(.primary)
        }
        .font(.caption)
    }

    private func iconLabelButton(icon: LifeOSIconName, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                LifeOSIcon(icon).frame(width: 10, height: 10)
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }

    private func pinRangeStart() {
        guard let selectedPoint else { return }
        pinnedRangeStart = selectedPoint.date
        zoomFactor = 1
    }

    private func changeZoom(by multiplier: Double) {
        zoomFactor = min(max(zoomFactor * multiplier, 0.25), 1)
    }
}
