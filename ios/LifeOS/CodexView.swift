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

    init(snapshots: [ProviderSnapshot], analytics: [UsageAnalyticsSnapshot]) {
        self.snapshots = snapshots
        self.analytics = analytics
        _selectedProviders = State(initialValue: Set(snapshots.map(\.provider)))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
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
            .padding(LifeOSTokens.pagePadding)
        }
        .accessibilityIdentifier("usage-screen")
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Usage")
#if os(iOS)
        .toolbar(.hidden, for: .tabBar)
#endif
        .tint(LifeOSTokens.accent)
        .animation(reduceMotion ? nil : LifeOSMotion.spring, value: selectedProviders)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LLM usage")
                .font(.title2.weight(.bold))
            Text("Limits, activity, projections and model mix — always separated by provider")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 6) {
                LifeOSIcon(.warning).frame(width: 13, height: 13)
                Text("Preview analytics · connect official sources for live data")
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
                .font(.caption.weight(.medium))
                .foregroundStyle(LifeOSTokens.warning)
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
                        HStack(spacing: 7) {
                            Circle()
                                .fill(providerColor(snapshot.provider))
                                .frame(width: 7, height: 7)
                            Text(snapshot.provider.displayName)
                                .font(.subheadline.weight(.semibold))
                            if selected {
                                LifeOSIcon(.done).frame(width: 13, height: 13)
                            }
                        }
                        .foregroundStyle(selected ? Color.white : Color.primary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(selected ? providerColor(snapshot.provider) : LifeOSTokens.surface, in: Capsule())
                        .overlay(Capsule().stroke(providerColor(snapshot.provider).opacity(selected ? 0 : 0.25)))
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
            ProviderLimitsCard(snapshot: snapshot)
            ProjectionChartCard(provider: snapshot.provider, analytics: analytics)
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
                        ProgressView(value: percent)
                            .tint(providerColor(snapshot.provider))
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
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    AreaMark(x: .value("Time", point.date), y: .value("Used", plotted ? point.usedPercent : 0))
                        .foregroundStyle(LinearGradient(colors: [providerColor(provider).opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
                }
                ForEach(analytics.projection) { point in
                    LineMark(x: .value("Time", point.date), y: .value("Projection", plotted ? point.usedPercent : 0))
                        .foregroundStyle(providerColor(provider).opacity(0.72))
                        .lineStyle(StrokeStyle(lineWidth: 2.5, dash: [6, 4]))
                }
                RuleMark(y: .value("Limit", 1))
                    .foregroundStyle(providerColor(provider).opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(values: [0, 0.5, 1]) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let number = value.as(Double.self) { Text(number, format: .percent.precision(.fractionLength(0))) }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine().foregroundStyle(Color.secondary.opacity(0.12))
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.weekday(.abbreviated).hour())
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let plotFrame = proxy.plotFrame {
                        let frame = geometry[plotFrame]
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .overlay {
                                if let selectedPoint, let x = proxy.position(forX: selectedPoint.date) {
                                    Rectangle().fill(providerColor(provider).opacity(0.7)).frame(width: 1)
                                        .position(x: x + frame.minX, y: frame.midY)
                                }
                            }
                            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                                let x = value.location.x - frame.origin.x
                                if let date: Date = proxy.value(atX: x) { selectedDate = date }
                            })
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let selectedPoint {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selectedPoint.isProjected ? "Projected" : "Observed").font(.caption.weight(.semibold))
                        Text(selectedPoint.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                        Text(selectedPoint.usedPercent, format: .percent.precision(.fractionLength(0)))
                    }
                    .font(.caption2.monospacedDigit()).padding(8)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(selectedPoint.isProjected ? "Projected" : "Observed") usage \(selectedPoint.usedPercent.formatted(.percent))")
                }
            }
            .frame(height: 190)
            .task {
                if reduceMotion { plotted = true }
                else { withAnimation(.easeOut(duration: 0.85)) { plotted = true } }
            }
            HStack(spacing: 14) {
                LegendKey(color: providerColor(provider), label: "Observed")
                LegendKey(color: providerColor(provider).opacity(0.72), label: "Projected")
                LegendKey(color: providerColor(provider).opacity(0.35), label: "Limit")
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
                    .foregroundStyle(providerColor(provider).gradient)
                    .cornerRadius(3)
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
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 180)
            .task {
                if reduceMotion { plotted = true }
                else { withAnimation(.easeOut(duration: 0.7)) { plotted = true } }
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
            CardHeader(title: "Model breakdown", subtitle: "Input, output, reasoning, tools and images", icon: .assistant)
            RadarUsageChart(models: models, color: providerColor(provider))
                .frame(height: 210)
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                    HStack {
                        Circle().fill(providerColor(provider).opacity(1 - Double(index) * 0.28)).frame(width: 7, height: 7)
                        Text(model.model).font(.caption.weight(.medium))
                        Spacer()
                        Text(model.totalTokens.formatted(.number.notation(.compactName)))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .lifeOSCard()
        .accessibilityElement(children: .contain)
    }
}

private struct RadarUsageChart: View {
    let models: [UsageModelBreakdown]
    let color: Color
    @State private var selectedCategory: Int?
    private let labels = ["Input", "Output", "Reasoning", "Tools", "Images"]

    var body: some View {
        GeometryReader { geometry in
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            ZStack(alignment: .topTrailing) {
                Canvas { context, size in
                    let radius = min(size.width, size.height) * 0.36
                    let maxima = labels.indices.map { category in
                        max(models.map { categoryValue(in: $0, at: category) }.max() ?? 1, 1)
                    }

                    for ring in 1...4 {
                        let points = labels.indices.map { point(center: center, radius: radius * Double(ring) / 4, index: $0, count: labels.count) }
                        context.stroke(polygon(points), with: .color(Color.secondary.opacity(0.12)), lineWidth: 1)
                    }
                    for index in labels.indices {
                        let end = point(center: center, radius: radius, index: index, count: labels.count)
                        var spoke = Path(); spoke.move(to: center); spoke.addLine(to: end)
                        context.stroke(spoke, with: .color(Color.secondary.opacity(selectedCategory == nil || selectedCategory == index ? 0.16 : 0.05)), lineWidth: 1)
                        let labelPoint = point(center: center, radius: radius + 20, index: index, count: labels.count)
                        context.draw(
                            Text(labels[index]).font(.caption2).foregroundStyle(selectedCategory == nil || selectedCategory == index ? Color.secondary : Color.secondary.opacity(0.35)),
                            at: labelPoint
                        )
                    }
                    for (modelIndex, model) in models.enumerated() {
                        let points = labels.indices.map { category in
                            point(center: center,
                                  radius: radius * categoryValue(in: model, at: category) / maxima[category],
                                  index: category, count: labels.count)
                        }
                        let path = polygon(points)
                        let shade = color.opacity(max(0.35, 0.72 - Double(modelIndex) * 0.22))
                        context.fill(path, with: .color(shade.opacity(selectedCategory == nil ? 0.18 : 0.10)))
                        context.stroke(path, with: .color(shade), lineWidth: selectedCategory == nil ? 2 : 2.5)
                    }
                }

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .gesture(SpatialTapGesture().onEnded { value in
                        selectedCategory = UsageSelection.radarCategoryIndex(
                            at: value.location,
                            center: center,
                            count: labels.count
                        )
                    })
                    .accessibilityLabel("Model usage radar. Tap a category for exact values.")

                if let selectedCategory {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(labels[selectedCategory]).font(.caption.weight(.semibold))
                            Spacer(minLength: 8)
                            Button {
                                self.selectedCategory = nil
                            } label: {
                                Text("Done").font(.caption2)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(models) { model in
                            HStack(spacing: 8) {
                                Text(model.model).lineLimit(1)
                                Spacer(minLength: 6)
                                Text(Int(categoryValue(in: model, at: selectedCategory)).formatted(.number.notation(.compactName)))
                                    .monospacedDigit()
                            }
                        }
                    }
                    .font(.caption2)
                    .padding(8)
                    .frame(maxWidth: 180)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func categoryValue(in model: UsageModelBreakdown, at index: Int) -> Double {
        guard model.categories.indices.contains(index) else { return 0 }
        return Double(model.categories[index].value)
    }

    private func point(center: CGPoint, radius: Double, index: Int, count: Int) -> CGPoint {
        let angle = -Double.pi / 2 + 2 * Double.pi * Double(index) / Double(count)
        return CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func polygon(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        points.dropFirst().forEach { path.addLine(to: $0) }
        path.closeSubpath()
        return path
    }
}

private struct UsageHeatmapCard: View {
    let provider: Provider
    let cells: [UsageHeatmapCell]
    @State private var selectedCell: UsageHeatmapCell?
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 8)

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
                    RoundedRectangle(cornerRadius: 2)
                        .fill(providerColor(provider).opacity(0.08 + Double(step) * 0.205))
                        .frame(width: 18, height: 7)
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
        let tile = RoundedRectangle(cornerRadius: 3)
            .fill(providerColor(provider).opacity(0.08 + cell.intensity * 0.82))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.8), lineWidth: 1)
                }
            }
            .opacity(isDimmed ? 0.28 : 1)
            .frame(height: 16)
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
        HStack(alignment: .top, spacing: 10) {
            LifeOSIcon(icon)
                .foregroundStyle(LifeOSTokens.accent)
                .frame(width: 17, height: 17)
                .frame(width: 30, height: 30)
                .background(LifeOSTokens.accent.opacity(0.10), in: LifeOSTokens.smallCardShape)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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
