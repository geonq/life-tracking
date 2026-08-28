import SwiftUI
import Charts

// MARK: - Token activity bar chart (02-charts-rings-widgets.md §3)

struct UsageTokenActivityView: View {
    let provider: Provider
    let activity: [UsageActivityPoint]

    @State private var selectedID: Date?
    @State private var revealedTokens: [Date: Double] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(provider: Provider, activity: [UsageActivityPoint], initialSelectedDate: Date? = nil) {
        self.provider = provider
        self.activity = activity
        _selectedID = State(initialValue: initialSelectedDate)
    }

    private var orderedActivity: [UsageActivityPoint] {
        activity.sorted { $0.date < $1.date }
    }

    private var activityRevealID: String {
        orderedActivity
            .map { "\($0.date.timeIntervalSinceReferenceDate):\($0.tokens)" }
            .joined(separator: "|")
    }

    private var totalTokens: Int { orderedActivity.reduce(0) { $0 + $1.tokens } }

    private var maxTokens: Double {
        Double(max(orderedActivity.map(\.tokens).max() ?? 0, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token activity").font(.subheadline.weight(.semibold))
                Text("Hourly token totals from your \(provider.displayName) account.")
                    .font(.caption)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }

            summaryCard

            Chart(orderedActivity) { point in
                BarMark(
                    x: .value("Time", point.date),
                    y: .value("Tokens", revealedTokens[point.date] ?? 0)
                )
                .cornerRadius(4)
                .foregroundStyle(barColor(for: point))
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            let label = Text(date, format: .dateTime.weekday(.abbreviated).hour())
                            label
                                .font(LifeOSFont.axis())
                                .foregroundStyle(LifeOSTokens.metadataText)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(LifeOSTokens.chartGrid)
                    AxisValueLabel()
                        .font(LifeOSFont.axis())
                        .foregroundStyle(LifeOSTokens.metadataText)
                }
            }
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
                                        .font(.caption2)
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                }
                            }
                            .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: 170)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(provider.displayName) hourly token activity chart")
            .accessibilityValue(activityAccessibilitySummary)
            .task(id: activityRevealID) { await revealBars() }

            footer
        }
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) token activity")
    }

    private var summaryCard: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    LifeOSIcon(.assistant).frame(width: 12, height: 12).foregroundStyle(LifeOSTokens.Series.actual)
                    Text(provider.displayName).font(.caption.weight(.semibold))
                }
                Text("Hourly token totals")
                    .font(.caption2)
                    .foregroundStyle(LifeOSTokens.secondaryText)
                Text(totalTokens.formatted(.number.notation(.compactName)))
                    .font(LifeOSFont.kpi(30))
                    .tracking(-0.3)
                    .monospacedDigit()
                Text(activity.isEmpty ? "No hourly observations" : "\(activity.count) hourly observations")
                    .font(.caption2)
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                statLine(label: "Coverage", value: "No daily aggregation")
                statLine(label: "Updated", value: updatedText)
            }
        }
        .padding(14)
        .background(LifeOSTokens.primaryText.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var updatedText: String {
        guard let last = orderedActivity.last else { return "Not available" }
        return last.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func statLine(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(LifeOSTokens.secondaryText)
            Text(value).font(.caption2.weight(.semibold))
        }
    }

    private var footer: some View {
        HStack {
            Text(footerHintText)
                .font(.caption)
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
        return "\(activity.count) hourly observations, totaling \(total) tokens. Latest point: \(latest.tokens.formatted(.number.notation(.compactName))) tokens at \(latest.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))."
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
        revealedTokens = [:]
        guard !orderedActivity.isEmpty else { return }

        if reduceMotion {
            // Assignment is intentional: malformed/merged feeds with duplicate hour keys must
            // remain renderable instead of trapping in Dictionary(uniqueKeysWithValues:).
            revealedTokens = orderedActivity.reduce(into: [:]) { result, point in
                result[point.date] = Double(point.tokens)
            }
            return
        }

        // Each bar starts at index * 0.015s; its value then grows from the baseline with the
        // shared one-shot chartDraw easing. This is presentation-only state; source tokens stay
        // untouched in UsageActivityPoint.
        var previousStartDelay: UInt64 = 0
        for (index, point) in orderedActivity.enumerated() {
            let startDelay = UInt64(Double(index) * 0.015 * 1_000_000_000)
            if startDelay > previousStartDelay {
                try? await Task.sleep(nanoseconds: startDelay - previousStartDelay)
            }
            previousStartDelay = startDelay
            guard !Task.isCancelled else { return }
            withAnimation(LifeOSMotion.chartDraw) {
                revealedTokens[point.date] = Double(point.tokens)
            }
        }
    }

    private func selectClosest(to date: Date) {
        let points = orderedActivity.map {
            LifeOSChartPoint(timestamp: $0.date, value: Double($0.tokens))
        }
        guard let closest = LifeOSChartKit.nearestPoint(in: points, to: date) else { return }
        if closest.timestamp != selectedID {
            ScrubBubble<EmptyView>.snapHaptic()
        }
        selectedID = closest.timestamp
    }
}
