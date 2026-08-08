import SwiftUI
import Charts

struct CodexView: View {
    let snapshot: ProviderSnapshot
    let analytics: [UsageAnalyticsSnapshot]

    init(snapshot: ProviderSnapshot, analytics: [UsageAnalyticsSnapshot] = []) {
        self.snapshot = snapshot
        self.analytics = analytics
    }

    var body: some View {
        UsageView(snapshots: [snapshot], analytics: analytics)
    }
}

struct UsageView: View {
    let snapshots: [ProviderSnapshot]
    private let analytics: [UsageAnalyticsSnapshot]
    @State private var selectedProviders: Set<Provider>
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    init(snapshots: [ProviderSnapshot], analytics: [UsageAnalyticsSnapshot]) {
        self.snapshots = snapshots
        self.analytics = analytics
        _selectedProviders = State(initialValue: Set(snapshots.map(\.provider)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
#if os(iOS)
                Button { dismiss() } label: {
                    LifeOSIcon(.chevronLeft)
                        .frame(width: 15, height: 15)
                        .frame(width: 34, height: 34)
                        .background(Color.primary.opacity(0.055), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Back")
                .accessibilityIdentifier("usage-back")
#endif
                header
                providerSelector

                ForEach(snapshots.filter { selectedProviders.contains($0.provider) }, id: \.provider) { snapshot in
                    ProviderAnalyticsSection(
                        snapshot: snapshot,
                        analytics: UsageAnalyticsResolver.matching(
                            snapshot: snapshot,
                            candidates: analytics
                        )
                    )
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .frame(maxWidth: 1_180, alignment: .leading)
#if os(iOS)
            .padding(.horizontal, 18)
            .padding(.top, 10)
            .padding(.bottom, 24)
#else
            .padding(LifeOSTokens.pagePadding)
#endif
        }
        .accessibilityIdentifier("usage-screen")
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
#if os(iOS)
        .toolbar(.hidden, for: .navigationBar)
#endif
        .tint(LifeOSTokens.accent)
        .animation(reduceMotion ? nil : LifeOSMotion.spring, value: selectedProviders)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("LLM usage")
                .font(LifeOSFont.headerLarge(25))
            Text("Limits, activity and model mix by provider")
                .font(LifeOSFont.body(15))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(LifeOSTokens.warning)
                    .frame(width: 5, height: 5)
                Text("Preview data · connect sources for live updates")
                    .lineLimit(1)
            }
                .font(.caption)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    private var providerSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(snapshots, id: \.provider) { snapshot in
                    let selected = selectedProviders.contains(snapshot.provider)
                    Button {
                        if selected && selectedProviders.count > 1 {
                            selectedProviders.remove(snapshot.provider)
                        } else {
                            selectedProviders.insert(snapshot.provider)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(providerColor(snapshot.provider))
                                .frame(width: 7, height: 7)
                            Text(snapshot.provider.displayName)
                                .font(.caption.weight(.semibold))
                            if selected {
                                LifeOSIcon(.done).frame(width: 11, height: 11)
                            }
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selected ? Color.primary.opacity(0.07) : LifeOSTokens.surface, in: Capsule())
                        .overlay(Capsule().stroke(selected ? Color.primary.opacity(0.13) : LifeOSTokens.quietBorder, lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(snapshot.provider.displayName), \(selected ? "shown" : "hidden")")
                }
            }
        }
        .accessibilityLabel("Visible providers")
    }
}

private struct ProviderAnalyticsSection: View {
    let snapshot: ProviderSnapshot
    let analytics: UsageAnalyticsSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
            HStack(spacing: 10) {
                Circle().fill(providerColor(snapshot.provider)).frame(width: 9, height: 9)
                Text(snapshot.provider.displayName)
                    .font(.title3.weight(.bold))
                Text(snapshot.accountLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                provenanceBadge
            }

            if let analytics {
                ViewThatFits(in: .horizontal) {
                    wideBento(analytics)
                        .frame(minWidth: 900)
                    compactStack(analytics)
                }
            } else {
                VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
                    ProviderLimitsCard(snapshot: snapshot)
                    unavailableAnalytics
                }
            }
        }
        .padding(.top, 8)
        .accessibilityElement(children: .contain)
    }

    private func wideBento(_ analytics: UsageAnalyticsSnapshot) -> some View {
        VStack(spacing: LifeOSTokens.spacing) {
            HStack(alignment: .top, spacing: LifeOSTokens.spacing) {
                ProjectionChartCard(provider: snapshot.provider, analytics: analytics)
                    .frame(maxWidth: .infinity)
                ProviderLimitsCard(snapshot: snapshot)
                    .frame(width: 320)
            }
            HStack(alignment: .top, spacing: LifeOSTokens.spacing) {
                TokenActivityCard(provider: snapshot.provider, activity: analytics.activity)
                    .frame(maxWidth: .infinity)
                ModelBreakdownCard(provider: snapshot.provider, models: analytics.modelBreakdowns)
                    .frame(width: 400)
            }
            UsageHeatmapCard(provider: snapshot.provider, cells: analytics.heatmap)
        }
    }

    private func compactStack(_ analytics: UsageAnalyticsSnapshot) -> some View {
        VStack(spacing: LifeOSTokens.spacing) {
            ProjectionChartCard(provider: snapshot.provider, analytics: analytics)
            ProviderLimitsCard(snapshot: snapshot)
            TokenActivityCard(provider: snapshot.provider, activity: analytics.activity)
            ModelBreakdownCard(provider: snapshot.provider, models: analytics.modelBreakdowns)
            UsageHeatmapCard(provider: snapshot.provider, cells: analytics.heatmap)
        }
    }

    private var provenanceBadge: some View {
        Text(snapshot.provenance.quality.rawValue.uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(snapshot.provenance.quality == .observed ? LifeOSTokens.success : LifeOSTokens.warning)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((snapshot.provenance.quality == .observed ? LifeOSTokens.success : LifeOSTokens.warning).opacity(0.12), in: Capsule())
    }

    private var unavailableAnalytics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Analytics unavailable").font(.headline)
            Text("No activity or model breakdown was supplied; LifeOS will not invent one.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .lifeOSCard()
    }
}

private struct ProviderLimitsCard: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Limits", subtitle: "Shortest active window first", icon: .usage)
            ForEach(snapshot.windows.sorted(by: windowSort)) { window in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(window.label).font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(window.usedPercent?.formatted(.percent.precision(.fractionLength(0))) ?? "Unavailable")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .foregroundStyle(window.usedPercent == nil ? Color.secondary : providerColor(snapshot.provider))
                    }
                    if let percent = window.usedPercent {
                        LimitTrack(value: percent, color: providerColor(snapshot.provider))
                            .accessibilityValue(percent.formatted(.percent))
                    } else {
                        Text("Official window not supplied")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    if let reset = window.resetAt {
                        Text("Resets \(reset, style: .relative)")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
            }
            Text("Source: \(snapshot.provenance.source) · \(snapshot.provenance.freshness().rawValue)")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .lifeOSCard()
    }

    private func windowSort(_ lhs: UsageWindow, _ rhs: UsageWindow) -> Bool {
        (lhs.durationMinutes ?? .max) < (rhs.durationMinutes ?? .max)
    }
}

private struct LimitTrack: View {
    let value: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.07))
                Capsule()
                    .fill(color.opacity(0.88))
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
        }
        .frame(height: 3)
    }
}

private struct ProjectionChartCard: View {
    let provider: Provider
    let analytics: UsageAnalyticsSnapshot
    @State private var plotted = false
    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectedPoint: UsageSelectionPoint? {
        guard let selectedDate else { return nil }
        return UsageSelection.closestPoint(
            to: selectedDate,
            observed: analytics.activity.map { UsageProjectionPoint(date: $0.date, usedPercent: $0.usedPercent) },
            projected: analytics.projection
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Projected limit", subtitle: "Activity-weighted until natural reset", icon: .usage)
            Chart {
                ForEach(analytics.activity) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Used", plotted ? point.usedPercent : 0))
                        .foregroundStyle(providerColor(provider))
                        .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                }
                ForEach(analytics.projection) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Projection", plotted ? point.usedPercent : 0))
                        .foregroundStyle(providerColor(provider).opacity(0.62))
                        .lineStyle(StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: [6, 4]))
                }
                RuleMark(y: .value("Limit", 1))
                    .foregroundStyle(Color.secondary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 0.75, dash: [2, 3]))
                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.date))
                        .foregroundStyle(Color.primary.opacity(0.22))
                        .lineStyle(StrokeStyle(lineWidth: 0.75))
                    PointMark(
                        x: .value("Selected time", selectedPoint.date),
                        y: .value("Selected usage", selectedPoint.usedPercent)
                    )
                    .symbolSize(34)
                    .foregroundStyle(LifeOSTokens.surface)
                    .annotation(position: .overlay) {
                        Circle()
                            .fill(providerColor(provider))
                            .frame(width: 6, height: 6)
                    }
                }
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { value in
                    AxisGridLine().foregroundStyle(LifeOSTokens.chartGrid)
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(number, format: .percent.precision(.fractionLength(0))) }
                    }
                }
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
            .chartPlotStyle { plotArea in
                plotArea.background(DotGridBackground())
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let x = value.location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) { selectedDate = date }
                            })
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let selectedPoint {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedPoint.isProjected ? "Projected" : "Observed").font(.caption.weight(.semibold))
                        Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text(selectedPoint.usedPercent, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption2.monospacedDigit())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .background(LifeOSTokens.surface.opacity(0.96), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(selectedPoint.isProjected ? "Projected" : "Observed") usage \(selectedPoint.usedPercent.formatted(.percent))")
                }
            }
            .frame(height: 190)
            .task {
                if reduceMotion { plotted = true }
                else { withAnimation(LifeOSMotion.chartReveal) { plotted = true } }
            }
            HStack(spacing: 14) {
                LegendKey(color: providerColor(provider), label: "Observed")
                LegendKey(color: providerColor(provider).opacity(0.62), label: "Projected")
                LegendKey(color: Color.secondary.opacity(0.35), label: "Limit")
            }
        }
        .lifeOSCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) activity weighted usage projection")
    }
}

private struct TokenActivityCard: View {
    let provider: Provider
    let activity: [UsageActivityPoint]
    @State private var plotted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Token activity", subtitle: "Observed volume by hour", icon: .assistant)
            Chart(activity) { point in
                BarMark(x: .value("Time", point.date), y: .value("Tokens", plotted ? point.tokens : 0))
                    .foregroundStyle(providerColor(provider).opacity(0.82))
                    .cornerRadius(2)
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
            .chartPlotStyle { plotArea in
                plotArea.background(DotGridBackground())
            }
            .frame(height: 180)
            .task {
                if reduceMotion { plotted = true }
                else { withAnimation(LifeOSMotion.chartReveal) { plotted = true } }
            }
        }
        .lifeOSCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(provider.displayName) token activity")
    }
}

private struct ModelBreakdownCard: View {
    let provider: Provider
    let models: [UsageModelBreakdown]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Model mix", subtitle: "Token composition by model", icon: .assistant)
            ModelCompositionChart(models: models, color: providerColor(provider))
        }
        .lifeOSCard()
        .accessibilityElement(children: .contain)
    }
}

private struct ModelCompositionChart: View {
    let models: [UsageModelBreakdown]
    let color: Color
    @State private var revealed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let categoryOpacity = [1.0, 0.78, 0.58, 0.40, 0.24]

    private var legendCategories: [(label: String, value: Int)] {
        models.first?.categories ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ForEach(Array(legendCategories.enumerated()), id: \.offset) { index, category in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color.opacity(categoryOpacity[index]))
                            .frame(width: 5, height: 5)
                        Text(category.label)
                            .font(.caption2)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
            .lineLimit(1)

            ForEach(models) { model in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.model)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(model.totalTokens.formatted(.number.notation(.compactName)))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    GeometryReader { geometry in
                        let categories = model.categories
                        let gap: CGFloat = 2
                        let available = max(0, geometry.size.width - gap * CGFloat(max(categories.count - 1, 0)))
                        HStack(spacing: gap) {
                            ForEach(Array(categories.enumerated()), id: \.offset) { index, category in
                                let share = model.totalTokens == 0 ? 0 : Double(category.value) / Double(model.totalTokens)
                                Capsule()
                                    .fill(color.opacity(categoryOpacity[index]))
                                    .frame(width: revealed ? available * share : 0)
                                    .accessibilityLabel("\(category.label), \(category.value.formatted(.number.notation(.compactName)))")
                            }
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 0) {
                        ForEach(model.categories, id: \.label) { category in
                            Text(category.value.formatted(.number.notation(.compactName)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
        .task {
            if reduceMotion { revealed = true }
            else { withAnimation(LifeOSMotion.chartReveal) { revealed = true } }
        }
    }
}

private struct UsageHeatmapCard: View {
    let provider: Provider
    let cells: [UsageHeatmapCell]
    @State private var selectedCell: UsageHeatmapCell?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 9)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            CardHeader(title: "Usage rhythm", subtitle: "When activity typically happens", icon: .usage)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(UsageHeatmapGrid.items(cells: cells)) { item in
                    switch item.kind {
                    case .corner:
                        Text("").frame(height: 12)
                    case .hourHeader(let hour):
                        Text("\(hour)").font(.system(size: 8)).foregroundStyle(.secondary)
                    case .dayHeader(let weekday):
                        Text(shortDay(weekday)).font(.system(size: 8)).foregroundStyle(.secondary)
                    case .cell(let cell):
                        heatmapCell(cell)
                    }
                }
            }
            HStack(spacing: 6) {
                Text("Less")
                ForEach(0..<5, id: \.self) { step in
                    Circle()
                        .fill(providerColor(provider).opacity(0.08 + Double(step) * 0.205))
                        .frame(width: 7, height: 7)
                }
                Text("More")
                Spacer()
                if let selectedCell {
                    Text("\(shortDay(selectedCell.weekday)) \(selectedCell.hour):00 · \(selectedCell.intensity.formatted(.percent.precision(.fractionLength(0))))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .transition(.opacity)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .lifeOSCard()
        .animation(.easeOut(duration: 0.16), value: selectedCell?.id)
    }

    @ViewBuilder
    private func heatmapCell(_ cell: UsageHeatmapCell) -> some View {
        let isSelected = selectedCell?.id == cell.id
        let isDimmed = selectedCell != nil && !isSelected
        let tile = Circle()
            .fill(providerColor(provider).opacity(0.08 + cell.intensity * 0.82))
            .overlay {
                if isSelected {
                    Circle().stroke(Color.primary.opacity(0.8), lineWidth: 1)
                }
            }
            .opacity(isDimmed ? 0.28 : 1)
            .frame(width: 11, height: 11)
            .frame(maxWidth: .infinity, minHeight: 16)
            .contentShape(Rectangle())
            .onTapGesture { selectedCell = isSelected ? nil : cell }
            .accessibilityLabel("\(shortDay(cell.weekday)) \(cell.hour):00, \(cell.intensity.formatted(.percent)) activity")

        #if os(macOS)
        tile.onHover { hovering in
            if hovering { selectedCell = cell }
            else if selectedCell?.id == cell.id { selectedCell = nil }
        }
        #else
        tile
        #endif
    }

    private func shortDay(_ weekday: Int) -> String {
        Calendar.current.shortWeekdaySymbols[max(0, min(weekday - 1, 6))]
    }
}

private struct CardHeader: View {
    let title: String
    let subtitle: String
    let icon: LifeOSIconName

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            LifeOSIcon(icon)
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

private struct DotGridBackground: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 12
            let radius: CGFloat = 0.65
            var x: CGFloat = 0
            while x <= size.width {
                var y: CGFloat = 0
                while y <= size.height {
                    let edgeDistance = min(min(x, size.width - x), min(y, size.height - y))
                    let edgeOpacity = min(max(edgeDistance / 28, 0.18), 1)
                    let dot = CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)
                    context.fill(Path(ellipseIn: dot), with: .color(Color.primary.opacity(0.08 * Double(edgeOpacity))))
                    y += spacing
                }
                x += spacing
            }
        }
        .allowsHitTesting(false)
    }
}

private struct LegendKey: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Capsule().fill(color).frame(width: 14, height: 3)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

private func providerColor(_ provider: Provider) -> Color {
    switch provider {
    case .codex: Color(red: 0.55, green: 0.32, blue: 0.96)
    case .claude: Color(red: 0.94, green: 0.43, blue: 0.18)
    }
}

private extension Provider {
    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        }
    }
}
