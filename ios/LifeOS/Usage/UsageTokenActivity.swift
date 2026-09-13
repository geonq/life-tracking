import SwiftUI
import Charts

// MARK: - Token activity bar chart (02-charts-rings-widgets.md §3)

struct UsageTokenActivityView: View {
    let provider: Provider
    let activity: [UsageActivityPoint]

    @State private var selectedID: Date?
    @State private var revealedTokens: [Date: Double] = [:]
    @State private var hasPresentedActivity = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(provider: Provider, activity: [UsageActivityPoint], initialSelectedDate: Date? = nil) {
        self.provider = provider
        self.activity = activity
        _selectedID = State(initialValue: initialSelectedDate)
    }

    private var orderedActivity: [UsageActivityPoint] {
        var latestByDate: [Date: UsageActivityPoint] = [:]
        for point in activity where point.date.timeIntervalSinceReferenceDate.isFinite {
            latestByDate[point.date] = point
        }
        return latestByDate.values.sorted { $0.date < $1.date }
    }

    private var activityRevealID: String {
        orderedActivity
            .map { "\($0.date.timeIntervalSinceReferenceDate):\($0.tokens)" }
            .joined(separator: "|")
    }

    private var totalTokens: Int { orderedActivity.reduce(0) { $0 + $1.tokens } }

    private var dailySummaries: [UsageDailyActivitySummary] {
        UsageActivityAggregation.daily(from: orderedActivity)
    }

    private var completeDays: [UsageDailyActivitySummary] {
        dailySummaries.filter(\.isComplete)
    }

    private var maxTokens: Double {
        Double(max(orderedActivity.map(\.tokens).max() ?? 0, 1))
    }

    private var spansMultipleDays: Bool {
        guard let first = orderedActivity.first?.date, let last = orderedActivity.last?.date else { return false }
        return !Calendar.current.isDate(first, inSameDayAs: last)
    }

    private var xAxisDesiredCount: Int {
        spansMultipleDays ? 4 : 5
    }

    private var chartHeight: CGFloat {
#if os(macOS)
        230
#else
        215
#endif
    }

    private var xAxisMarks: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: xAxisDesiredCount)) { value in
            AxisValueLabel {
                if let date = value.as(Date.self) {
                    activityTimeAxisLabel(for: date)
                }
            }
        }
    }

    @ViewBuilder
    private func activityTimeAxisLabel(for date: Date) -> some View {
        if spansMultipleDays {
            Text(date, format: .dateTime.month(.abbreviated).day())
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.metadataText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .allowsTightening(true)
                .multilineTextAlignment(.center)
                .frame(minWidth: 42)
        } else {
            Text(date, format: .dateTime.hour().minute())
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.metadataText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var yAxisMarks: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LifeOSTokens.chartGrid)
            AxisValueLabel()
                // AxisValueLabel is AxisMark content, not a View, so use the
                // system-default metadata size at this chart-only boundary.
                .font(.system(size: 13, weight: .regular, design: .default))
                .foregroundStyle(LifeOSTokens.metadataText)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token activity").lifeOSTypography(.cardTitle)
                Text("Hourly token totals from your \(provider.displayName) account.")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }

            if orderedActivity.isEmpty {
                emptyActivityState
            } else {
                summaryCard

                Chart(orderedActivity) { point in
                    BarMark(
                        x: .value("Time", point.date),
                        y: .value("Tokens", revealedTokens[point.date] ?? 0)
                    )
                    .cornerRadius(4)
                    .foregroundStyle(barColor(for: point))
                }
                .chartXAxis { xAxisMarks }
                .chartYAxis { yAxisMarks }
                .chartYScale(domain: 0...maxTokens)
                .chartXScale(domain: chartXDomain)
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        if let plotFrame = proxy.plotFrame {
                            let frame = geometry[plotFrame]

                            Rectangle().fill(.clear).contentShape(Rectangle())
#if os(iOS)
                                .simultaneousGesture(DragGesture(minimumDistance: LifeOSDirectionalClassifier.minimumDistance).onChanged { value in
                                    guard LifeOSDirectionalClassifier.classify(value.translation) == .horizontal,
                                          let date = LifeOSChartKit.timestamp(
                                              forPlotX: value.location.x,
                                              in: frame,
                                              domain: chartXDomain
                                          ) else { return }
                                    selectClosest(to: date)
                                })
                                .onTapGesture { location in
                                    guard let date = LifeOSChartKit.timestamp(
                                        forPlotX: location.x,
                                        in: frame,
                                        domain: chartXDomain
                                    ) else { return }
                                    selectClosest(to: date)
                                }
#elseif os(macOS)
                                .onContinuousHover(coordinateSpace: .local) { phase in
                                    switch phase {
                                    case .active(let location):
                                        guard let date = LifeOSChartKit.timestamp(
                                            forPlotX: location.x,
                                            in: frame,
                                            domain: chartXDomain
                                        ) else { return }
                                        selectClosest(to: date)
                                    case .ended:
                                        break
                                    }
                                }
#endif
                            if let selectedPoint,
                               let x = proxy.position(forX: selectedPoint.date) {
                                let y = proxy.position(forY: Double(selectedPoint.tokens)) ?? frame.origin.y
                                ScrubBubble(
                                    x: frame.origin.x + x,
                                    y: frame.origin.y + y,
                                    bounds: frame
                                ) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(selectedPoint.tokens.formatted(.number.notation(.compactName)) + " tokens")
                                        Text(selectedPoint.date, format: .dateTime.weekday(.abbreviated).hour().minute())
                                            .lifeOSTypography(.metadata)
                                            .foregroundStyle(LifeOSTokens.tertiaryText)
                                    }
                                }
                                .allowsHitTesting(false)
                            }
                        }
                    }
                }
                .frame(height: chartHeight)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(provider.displayName) hourly token activity chart")
                .accessibilityValue(activityAccessibilitySummary)
                .task(id: activityRevealID) {
                    if let selectedID, !orderedActivity.contains(where: { $0.date == selectedID }) {
                        self.selectedID = nil
                    }
                    await revealBars()
                }
                .onChange(of: reduceMotion) { _, _ in
                    LifeOSMotion.withoutAnimation {
                        revealedTokens = revealedValues
                    }
                }

                keyboardStepper
                footer
            }
        }
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) token activity")
    }

    private var emptyActivityState: some View {
        VStack(alignment: .leading, spacing: 8) {
            LifeOSIcon(.usage)
                .frame(width: 20, height: 20)
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text("No token activity")
                .lifeOSTypography(.cardTitle)
            Text("The gateway has not supplied token activity for this account, so no chart range is shown.")
                .lifeOSTypography(.body)
                .foregroundStyle(LifeOSTokens.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private var summaryCard: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top) {
                summaryPrimary
                Spacer(minLength: 12)
                summaryStats
            }
            VStack(alignment: .leading, spacing: 12) {
                summaryPrimary
                Divider().opacity(0.3)
                summaryStats
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var summaryPrimary: some View {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LifeOSIcon(.usage).frame(width: 14, height: 14).foregroundStyle(LifeOSTokens.Series.actual)
                    Text(provider.displayName).lifeOSTypography(.cardTitle)
                }
                Text("Hourly token totals")
                    .lifeOSTypography(.body)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                Text(totalTokens.formatted(.number.notation(.compactName)))
                    .lifeOSTypography(.metric)
                    .tracking(-0.3)
                    .monospacedDigit()
                Text(activity.isEmpty ? "No hourly observations" : "\(activity.count) hourly observations")
                    .lifeOSTypography(.metadata)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
    }

    private var summaryStats: some View {
            VStack(alignment: .trailing, spacing: 6) {
                statLine(label: "Daily coverage", value: dailyCoverageText)
                statLine(label: "Peak complete day", value: peakDayText)
                statLine(label: "Updated", value: updatedText)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var updatedText: String {
        guard let last = orderedActivity.last else { return "Not available" }
        return last.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func statLine(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).lifeOSTypography(.metadata).foregroundStyle(LifeOSTokens.secondaryText)
            Text(value).lifeOSTypography(.button)
        }
    }

    private var dailyCoverageText: String {
        guard !dailySummaries.isEmpty else { return "Not available" }
        return "\(completeDays.count)/\(dailySummaries.count) complete"
    }

    private var peakDayText: String {
        guard let peak = completeDays.max(by: { $0.tokens < $1.tokens }) else { return "Not available" }
        return "\(peak.tokens.formatted(.number.notation(.compactName))) tokens"
    }

    private var keyboardStepper: some View {
        HStack(spacing: 8) {
            Button { stepSelection(by: -1) } label: {
                LifeOSIcon(.chevronLeft).frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
            .disabled(orderedActivity.isEmpty)
#if os(macOS)
            .keyboardShortcut(.leftArrow, modifiers: [])
#endif
            .accessibilityLabel("Previous token activity point")

            Text(selectedPoint.map { $0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) } ?? "Select a point")
                .lifeOSTypography(.button).monospacedDigit()
                .foregroundStyle(LifeOSTokens.secondaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(minWidth: 180)
                .accessibilityLabel(selectedPoint.map {
                    "Selected token activity point \($0.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))"
                } ?? "No token activity point selected")

            Button { stepSelection(by: 1) } label: {
                LifeOSIcon(.chevronRight).frame(width: 11, height: 11)
            }
            .buttonStyle(.plain)
            .disabled(orderedActivity.isEmpty)
#if os(macOS)
            .keyboardShortcut(.rightArrow, modifiers: [])
#endif
            .accessibilityLabel("Next token activity point")
        }
        .foregroundStyle(LifeOSTokens.secondaryText)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Token activity point stepper")
    }

    private var footer: some View {
        HStack {
            Text(footerHintText)
                .lifeOSTypography(.metadata)
                .foregroundStyle(LifeOSTokens.secondaryText)
            Spacer()
        }
    }

    private var footerHintText: String {
#if os(iOS)
        "Drag or tap a bar for exact details."
#else
        "Hover a bar for exact details."
#endif
    }

    private var activityAccessibilitySummary: String {
        guard let latest = orderedActivity.last else { return "No hourly observations are available." }
        let total = totalTokens.formatted(.number.notation(.compactName))
        return "\(orderedActivity.count) hourly observations, totaling \(total) tokens. Latest point: \(latest.tokens.formatted(.number.notation(.compactName))) tokens at \(latest.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))."
    }

    private func barColor(for point: UsageActivityPoint) -> Color {
        guard let selectedID else { return LifeOSTokens.Series.actual }
        return point.date == selectedID ? LifeOSTokens.Series.actual : LifeOSTokens.Series.actual.opacity(0.55)
    }

    private var selectedPoint: UsageActivityPoint? {
        guard let selectedID else { return nil }
        return orderedActivity.first { $0.date == selectedID }
    }

    private var chartXDomain: ClosedRange<Date> {
        let dates = orderedActivity.map(\.date)
        guard let first = dates.first, let last = dates.last else {
            let now = Date()
            return now.addingTimeInterval(-1_800)...now.addingTimeInterval(1_800)
        }

        let smallestPositiveInterval = zip(dates, dates.dropFirst())
            .map { $1.timeIntervalSince($0) }
            .filter { $0 > 0 }
            .min()
        let padding = smallestPositiveInterval.map { $0 / 2 } ?? 1_800
        return first.addingTimeInterval(-padding)...last.addingTimeInterval(padding)
    }

    @MainActor
    private func revealBars() async {
        // One bounded reveal keeps a large activity feed from spawning a
        // per-bar task chain. The source values are assigned in one pass, so
        // the animation can never be mistaken for a changing token total.
        let values = orderedActivity.reduce(into: [Date: Double]()) { result, point in
            result[point.date] = Double(point.tokens)
        }
        guard !Task.isCancelled else { return }
        let shouldAnimate = !hasPresentedActivity && !reduceMotion
        hasPresentedActivity = true
        if shouldAnimate {
            withAnimation(LifeOSMotion.chartDraw) { revealedTokens = values }
        } else {
            LifeOSMotion.withoutAnimation { revealedTokens = values }
        }
    }

    private var revealedValues: [Date: Double] {
        orderedActivity.reduce(into: [Date: Double]()) { result, point in
            result[point.date] = Double(point.tokens)
        }
    }

    private func selectClosest(to date: Date) {
        let points = orderedActivity.map {
            LifeOSChartPoint(timestamp: $0.date, value: Double($0.tokens))
        }
        guard let closest = LifeOSChartKit.nearestPoint(in: points, to: date, expectedCadence: 3_600) else { return }
        if closest.timestamp != selectedID {
            ScrubBubble<EmptyView>.snapHaptic()
        }
        selectedID = closest.timestamp
    }

    private func stepSelection(by offset: Int) {
        guard !orderedActivity.isEmpty else { return }
        let currentIndex = selectedID.flatMap { selected in
            orderedActivity.firstIndex { $0.date == selected }
        } ?? (offset < 0 ? orderedActivity.count : -1)
        let nextIndex = min(max(currentIndex + offset, 0), orderedActivity.count - 1)
        let next = orderedActivity[nextIndex].date
        if next != selectedID { ScrubBubble<EmptyView>.snapHaptic() }
        selectedID = next
    }
}
