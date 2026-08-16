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

    private var totalTokens: Int { activity.reduce(0) { $0 + $1.tokens } }

    private var maxTokens: Double {
        Double(max(activity.map(\.tokens).max() ?? 0, 1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Token activity").font(.subheadline.weight(.semibold))
                Text("Hourly token totals from your \(provider.displayName) account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            summaryCard

            Chart(activity) { point in
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
                            Text(date, format: .dateTime.weekday(.abbreviated).hour())
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(LifeOSTokens.chartGrid)
                    AxisValueLabel().foregroundStyle(.secondary)
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
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let x = value.location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) { selectClosest(to: date) }
                            })
                            .onTapGesture { location in
                                let x = location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) { selectClosest(to: date) }
                            }
#elseif os(macOS)
                            .onContinuousHover(coordinateSpace: .local) { phase in
                                switch phase {
                                case .active(let location):
                                    let x = location.x - frame.origin.x
                                    if let date: Date = proxy.value(atX: x) { selectClosest(to: date) }
                                case .ended:
                                    break
                                }
                            }
#endif
                        if let selectedPoint,
                           let x = proxy.position(forX: selectedPoint.date) {
                            let y = proxy.position(forY: Double(selectedPoint.tokens)) ?? frame.origin.y
                            ScrubBubble(x: frame.origin.x + x, y: max(18, frame.origin.y + y - 26)) {
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
            .task(id: activity.map(\.date)) { await revealBars() }

            footer
        }
        .glassCard()
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
                    .foregroundStyle(.secondary)
                Text(totalTokens.formatted(.number.notation(.compactName)))
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(activity.isEmpty ? "No hourly observations" : "\(activity.count) hourly observations")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 6) {
                statLine(label: "Coverage", value: "No daily aggregation")
                statLine(label: "Updated", value: updatedText)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var updatedText: String {
        guard let last = activity.last else { return "Not available" }
        return last.date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func statLine(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption2.weight(.semibold))
        }
    }

    private var footer: some View {
        HStack {
            Text(footerHintText)
                .font(.caption)
                .foregroundStyle(.secondary)
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
        guard let latest = activity.last else { return "No hourly observations are available." }
        let total = totalTokens.formatted(.number.notation(.compactName))
        return "\(activity.count) hourly observations, totaling \(total) tokens. Latest point: \(latest.tokens.formatted(.number.notation(.compactName))) tokens at \(latest.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))."
    }

    private func barColor(for point: UsageActivityPoint) -> Color {
        guard let selectedID else { return LifeOSTokens.Series.actual }
        return point.date == selectedID ? LifeOSTokens.Series.actual : LifeOSTokens.Series.actual.opacity(0.55)
    }

    private var selectedPoint: UsageActivityPoint? {
        guard let selectedID else { return nil }
        return activity.first { $0.date == selectedID }
    }

    private var chartXDomain: ClosedRange<Date> {
        let dates = activity.map(\.date).sorted()
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
        guard !activity.isEmpty else { return }

        if reduceMotion {
            revealedTokens = Dictionary(uniqueKeysWithValues: activity.map { ($0.date, Double($0.tokens)) })
            return
        }

        // Each bar starts at index * 0.015s; its value then grows from the baseline with the
        // shared one-shot chartDraw easing. This is presentation-only state; source tokens stay
        // untouched in UsageActivityPoint.
        var previousStartDelay: UInt64 = 0
        for (index, point) in activity.enumerated() {
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
        guard !activity.isEmpty else { return }
        let closest = activity.min { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) }
        if let closestDate = closest?.date, closestDate != selectedID {
            ScrubBubble<EmptyView>.snapHaptic()
        }
        selectedID = closest?.date
    }
}
