import SwiftUI
import Charts

/// Strength detail for the IMG_0393 contract. It is standalone for snapshot
/// review and is also mounted by the Fitness Activity Strength route.
public struct FitnessStrengthDetailView: View {
    private let snapshot: FitnessStrengthSnapshot
    private let onSourceTap: (() -> Void)?
    @StateObject private var templateStore: FitnessStrengthTemplateStore
    @State private var selectedGroup: FitnessStrengthMuscleGroup = .chest
    @State private var editorPresentation: FitnessStrengthTemplateEditorPresentation?
    @State private var pendingDelete: FitnessStrengthTemplate?
    @State private var notice: String?
    @State private var noticeIsError = false

    public init(
        snapshot: FitnessStrengthSnapshot = .init(),
        templateStore: FitnessStrengthTemplateStore = FitnessStrengthTemplateStore(),
        onSourceTap: (() -> Void)? = nil
    ) {
        self.snapshot = snapshot
        self.onSourceTap = onSourceTap
        _templateStore = StateObject(wrappedValue: templateStore)
    }

    public var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer(topPadding: 24, bottomPadding: 24) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    totalVolumeCard
                    progressCard
                    templatesSection
                if let onSourceTap {
                    StrengthSurfaceCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Source boundary")
                                .font(LifeOSFont.header(14))
                            Text("Values require a named window, provenance, and reviewed workout samples. Missing data remains unavailable; LifeOS does not substitute zero.")
                                .font(LifeOSFont.body(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Review source and permissions", action: onSourceTap)
                                .font(LifeOSFont.inter(11, weight: .semiBold))
                                .buttonStyle(.bordered)
                                .tint(LifeOSTokens.accent)
                        }
                    }
                }
                if let notice {
                        Text(notice)
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(noticeIsError ? LifeOSTokens.warning : LifeOSTokens.success)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isStaticText)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .sheet(item: $editorPresentation) { presentation in
            FitnessStrengthTemplateEditor(template: presentation.template) { template in
                try templateStore.upsert(template)
                noticeIsError = false
                notice = "\(template.name) saved locally. Sync to the Windows server is pending."
                editorPresentation = nil
            }
            #if os(macOS)
            .frame(minWidth: 420, minHeight: 420)
            #endif
        }
        .confirmationDialog(
            "Delete training template?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { template in
            Button("Delete \(template.name)", role: .destructive) {
                delete(template)
            }
            Button("Cancel", role: .cancel) {}
        } message: { template in
            Text("This removes the local template. A completed workout is not deleted.")
        }
        .accessibilityIdentifier("fitness-strength-detail")
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Strength")
                    .font(LifeOSFont.headerLarge(28))
                Text(windowLabel)
                    .font(LifeOSFont.caption(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 12)
            Button {
                editorPresentation = .add
            } label: {
                Label("Add template", systemImage: "plus")
                    .font(LifeOSFont.inter(12, weight: .semiBold))
            }
            .buttonStyle(.borderedProminent)
            .tint(LifeOSTokens.accent)
            .accessibilityHint("Create a local training template")
            #if os(macOS)
            .help("Add training template")
            #endif
        }
    }

    private var totalVolumeCard: some View {
        StrengthSurfaceCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 9) {
                    Image(systemName: "scalemass.fill")
                        .foregroundStyle(LifeOSTokens.accent)
                    Text("Total volume")
                        .font(LifeOSFont.header(17))
                    Spacer()
                    StrengthStateBadge(state: snapshot.totalVolume.state)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 24) {
                        totalVolumeSummary
                            .frame(width: 170, alignment: .leading)
                        adaptiveRadialDiagram
                        selectedGroupDetail
                            .frame(width: 260, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300, maxHeight: 300, alignment: .center)

                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 16) {
                            totalVolumeSummary
                                .frame(maxWidth: .infinity, alignment: .leading)
                            selectedGroupDetail
                                .frame(width: 220, alignment: .leading)
                        }
                        adaptiveRadialDiagram
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var totalVolumeSummary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("All muscle groups")
                .font(LifeOSFont.caption(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            StrengthAggregateValue(state: snapshot.totalVolume.state)
            Text("Logged volume in the selected window")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var adaptiveRadialDiagram: some View {
        ViewThatFits(in: .horizontal) {
            radialDiagram(size: 340)
            radialDiagram(size: 304)
            radialDiagram(size: 272)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func radialDiagram(size: CGFloat) -> some View {
        StrengthRadialDiagram(metrics: snapshot.groups, selectedGroup: $selectedGroup)
            .frame(width: size, height: size)
    }

    private var selectedGroupDetail: some View {
        VStack(alignment: .leading, spacing: 9) {
                        Text("Selected group")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                        Text(selectedMetric.group.title)
                            .font(LifeOSFont.header(20))
                        StrengthMetricValue(metric: selectedMetric)
                        Text("Tap a group to inspect its source-backed volume. Unavailable is not zero.")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = selectedMetric.sourceDetail {
                            Text(detail)
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var windowLabel: String {
        switch snapshot.progress {
        case .observed(_, let window, _), .demo(_, let window, _):
            return window
        case .empty:
            switch snapshot.totalVolume.state {
            case .observed(_, let window, _), .demo(_, let window, _): return window
            case .unavailable, .calibrating: return "Selected source window"
            }
        }
    }

    private var selectedMetric: FitnessStrengthMetric {
        snapshot.metric(for: selectedGroup)
    }

    private var progressCard: some View {
        StrengthSurfaceCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 9) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .foregroundStyle(LifeOSTokens.info)
                    Text("Strength progress")
                        .font(LifeOSFont.header(17))
                    Spacer()
                    if snapshot.progress.isDemo {
                        Text("DEMO · NOT LIVE")
                            .font(LifeOSFont.inter(9, weight: .bold))
                            .foregroundStyle(LifeOSTokens.warning)
                    }
                }
                switch snapshot.progress {
                case .empty(let reason):
                    StrengthEmptyProgress(reason: reason)
                case .observed(let points, let window, let provenance), .demo(let points, let window, let provenance):
                    StrengthProgressChart(points: points)
                        .frame(height: 180)
                    Text("\(window) · \(provenance)")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("fitness-strength-progress-card")
    }

    private var templatesSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline) {
                Text("Training templates")
                    .font(LifeOSFont.header(20))
                Spacer()
                Text("Local first")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            if templateStore.templates.isEmpty {
                StrengthSurfaceCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 23, weight: .medium))
                            .foregroundStyle(LifeOSTokens.accent)
                        Text("No training templates")
                            .font(LifeOSFont.header(17))
                        Text("Create a reusable session with exercises, sets, repetitions, and optional load. LifeOS does not invent a workout when the list is empty.")
                            .font(LifeOSFont.body(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Add first template") { editorPresentation = .add }
                            .buttonStyle(.bordered)
                            .tint(LifeOSTokens.accent)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 12)], spacing: 12) {
                    ForEach(templateStore.templates) { template in
                        FitnessStrengthTemplateCard(
                            template: template,
                            onEdit: { editorPresentation = .edit(template) },
                            onDelete: { pendingDelete = template }
                        )
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-strength-templates")
    }

    private func delete(_ template: FitnessStrengthTemplate) {
        do {
            _ = try templateStore.delete(id: template.id)
            pendingDelete = nil
            noticeIsError = false
            notice = "\(template.name) deleted locally."
        } catch {
            noticeIsError = true
            notice = "Could not delete \(template.name): \(error.localizedDescription)"
            pendingDelete = nil
        }
    }
}

// MARK: - Strength visualization

private struct StrengthRadialDiagram: View {
    let metrics: [FitnessStrengthMetric]
    @Binding var selectedGroup: FitnessStrengthMuscleGroup
    @State private var hoveredGroup: FitnessStrengthMuscleGroup?

    private let displayOrder: [FitnessStrengthMuscleGroup] = [
        .chest, .back, .legs, .shoulders, .core, .arms
    ]

    var body: some View {
        GeometryReader { proxy in
            let center = CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            let diameter = min(proxy.size.width, proxy.size.height)
            let radius = diameter * 0.27
            let labelRadius = diameter * 0.40
            let maximum = displayMetrics.compactMap(\.kilograms).max() ?? 0

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [LifeOSTokens.surface.opacity(0.68), LifeOSTokens.canvas.opacity(0.20)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: diameter * 0.66, height: diameter * 0.66)
                    .position(center)
                    .allowsHitTesting(false)

                ForEach(Array(displayMetrics.enumerated()), id: \.element.id) { index, metric in
                    StrengthRadialSegment(
                        index: index,
                        intensity: intensity(for: metric, maximum: maximum),
                        color: color(for: metric.group),
                        isSelected: metric.group == selectedGroup,
                        isHovered: metric.group == hoveredGroup
                    )
                    .frame(width: radius * 2.0, height: radius * 2.0)
                    .position(center)
                    .allowsHitTesting(false)
                }

                Circle()
                    .fill(LifeOSTokens.surface.opacity(0.92))
                    .frame(width: diameter * 0.20, height: diameter * 0.20)
                    .position(center)
                    .overlay {
                        Image(systemName: "figure.strengthtraining.traditional")
                            .font(.system(size: diameter * 0.075, weight: .medium))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    .allowsHitTesting(false)

                ForEach(displayMetrics) { metric in
                    let angle = labelAngle(for: metric.group)
                    let x = center.x + CGFloat(cos(angle.radians)) * labelRadius
                    let y = center.y + CGFloat(sin(angle.radians)) * labelRadius
                    Button {
                        select(metric.group)
                    } label: {
                        VStack(spacing: 2) {
                            Text(metric.kilograms.map { $0.formatted(.number.precision(.fractionLength(0...1))) + " kg" } ?? "—")
                                .font(LifeOSFont.inter(12, weight: .semiBold))
                                .foregroundStyle(metric.kilograms == nil ? LifeOSTokens.tertiaryText : color(for: metric.group))
                            Text(metric.group.shortTitle)
                                .font(LifeOSFont.inter(11, weight: .medium))
                                .foregroundStyle(metric.group == selectedGroup ? .primary : LifeOSTokens.tertiaryText)
                        }
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(
                            LifeOSTokens.surface.opacity(metric.group == selectedGroup ? 0.82 : 0.60),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .frame(width: 84)
                    .position(x: x, y: y)
                    .opacity(metric.group == hoveredGroup ? 0.72 : 1)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(metric.group.title) strength volume")
                    .accessibilityValue(metric.kilograms.map { "\($0.formatted(.number.precision(.fractionLength(0...1)))) kilograms" } ?? "Unavailable")
                    .accessibilityHint("Select this muscle group")
                    #if os(macOS)
                    .onHover { inside in
                        withAnimation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy) {
                            hoveredGroup = inside ? metric.group : nil
                        }
                    }
                    .help("Inspect \(metric.group.title) volume")
                    #endif
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Strength muscle group volume diagram")
        .accessibilityIdentifier("fitness-strength-radial-diagram")
    }

    private var displayMetrics: [FitnessStrengthMetric] {
        displayOrder.map { group in
            metrics.first(where: { $0.group == group }) ?? .unavailable(group: group)
        }
    }

    private func labelAngle(for group: FitnessStrengthMuscleGroup) -> Angle {
        switch group {
        case .chest: .degrees(-90)
        case .back: .degrees(-30)
        case .legs: .degrees(30)
        case .shoulders: .degrees(90)
        case .core: .degrees(150)
        case .arms: .degrees(210)
        }
    }

    private func select(_ group: FitnessStrengthMuscleGroup) {
        withAnimation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy) {
            selectedGroup = group
        }
    }

    private func intensity(for metric: FitnessStrengthMetric, maximum: Double) -> CGFloat {
        guard let value = metric.kilograms else { return 0.18 }
        guard maximum > 0 else { return 0.30 }
        return CGFloat(0.30 + min(max(value / maximum, 0), 1) * 0.70)
    }

    private func color(for group: FitnessStrengthMuscleGroup) -> Color {
        switch group {
        case .arms: LifeOSTokens.Hue.violet.base
        case .core: LifeOSTokens.Hue.teal.base
        case .chest: LifeOSTokens.Hue.blue.base
        case .back: LifeOSTokens.Hue.green.base
        case .legs: LifeOSTokens.Hue.orange.base
        case .shoulders: LifeOSTokens.Hue.pink.base
        }
    }
}

private struct StrengthRadialSegment: View {
    let index: Int
    let intensity: CGFloat
    let color: Color
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        StrengthSegmentShape(index: index, intensity: intensity)
            .fill(color.opacity(isSelected ? 0.82 : isHovered ? 0.62 : 0.38))
            .overlay {
                StrengthSegmentShape(index: index, intensity: intensity)
                    .stroke(color.opacity(isSelected ? 0.92 : 0.18), lineWidth: isSelected ? 1.5 : 0.8)
            }
            .animation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy, value: isSelected)
    }
}

private struct StrengthSegmentShape: Shape {
    let index: Int
    let intensity: CGFloat

    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let maxRadius = min(rect.width, rect.height) / 2
        let outerRadius = maxRadius * (0.68 + 0.20 * intensity)
        let innerRadius = maxRadius * 0.39
        let gap = 3.2
        let start = Angle.degrees(Double(index) * 60 - 90 + gap)
        let end = Angle.degrees(Double(index + 1) * 60 - 90 - gap)
        var path = Path()
        path.move(to: point(center: center, radius: outerRadius, angle: start))
        path.addArc(center: center, radius: outerRadius, startAngle: start, endAngle: end, clockwise: false)
        path.addLine(to: point(center: center, radius: innerRadius, angle: end))
        path.addArc(center: center, radius: innerRadius, startAngle: end, endAngle: start, clockwise: true)
        path.closeSubpath()
        return path
    }

    private func point(center: CGPoint, radius: CGFloat, angle: Angle) -> CGPoint {
        CGPoint(x: center.x + CGFloat(cos(angle.radians)) * radius, y: center.y + CGFloat(sin(angle.radians)) * radius)
    }
}

private struct StrengthMetricValue: View {
    let metric: FitnessStrengthMetric

    var body: some View {
        switch metric.state {
        case .observed(let kilograms, _, _), .demo(let kilograms, _, _):
            HStack(alignment: .lastTextBaseline, spacing: 5) {
                Text(kilograms.formatted(.number.precision(.fractionLength(0...1))))
                    .font(LifeOSFont.spaceGrotesk(32, weight: .bold))
                Text("kg")
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        case .unavailable(let reason), .calibrating(let reason):
            VStack(alignment: .leading, spacing: 3) {
                Text("—")
                    .font(LifeOSFont.spaceGrotesk(32, weight: .bold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text(reason)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StrengthAggregateValue: View {
    let state: FitnessStrengthMetric.State

    var body: some View {
        switch state {
        case .observed(let kilograms, _, _), .demo(let kilograms, _, _):
            HStack(alignment: .lastTextBaseline, spacing: 4) {
                Text(kilograms.formatted(.number.precision(.fractionLength(0...1))))
                    .font(LifeOSFont.spaceGrotesk(28, weight: .bold))
                    .monospacedDigit()
                Text("kg")
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        case .unavailable, .calibrating:
            Text("—")
                .font(LifeOSFont.spaceGrotesk(28, weight: .bold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }
}

private struct StrengthStateBadge: View {
    let state: FitnessStrengthMetric.State

    var body: some View {
        Text(label)
            .font(LifeOSFont.inter(9, weight: .bold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.13), in: Capsule())
            .accessibilityLabel(label)
    }

    private var label: String {
        switch state {
        case .observed: "OBSERVED"
        case .demo: "DEMO · NOT LIVE"
        case .calibrating: "CALIBRATING"
        case .unavailable: "UNAVAILABLE"
        }
    }

    private var color: Color {
        switch state {
        case .observed: LifeOSTokens.success
        case .demo: LifeOSTokens.warning
        case .calibrating: LifeOSTokens.accent
        case .unavailable: LifeOSTokens.tertiaryText
        }
    }
}

private struct StrengthProgressChart: View {
    let points: [FitnessStrengthProgressPoint]

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("Date", point.date), y: .value("Kilograms", point.kilograms))
                .foregroundStyle(
                    LinearGradient(
                        colors: [LifeOSTokens.info.opacity(0.23), LifeOSTokens.info.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            LineMark(x: .value("Date", point.date), y: .value("Kilograms", point.kilograms))
                .foregroundStyle(LifeOSTokens.info)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            PointMark(x: .value("Date", point.date), y: .value("Kilograms", point.kilograms))
                .foregroundStyle(LifeOSTokens.info)
                .symbolSize(22)
        }
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3, 4]))
                    .foregroundStyle(LifeOSTokens.chartGrid)
                AxisValueLabel()
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .chartXAxis {
            AxisMarks { _ in
                AxisGridLine().foregroundStyle(.clear)
                AxisTick().foregroundStyle(.clear)
            }
        }
        .chartPlotStyle { plot in
            plot.background(LifeOSTokens.canvas.opacity(0.22), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .accessibilityLabel("Strength progress chart")
        .accessibilityValue("\(points.count) source-backed observations")
    }
}

private struct StrengthEmptyProgress: View {
    let reason: String

    var body: some View {
        ZStack {
            VStack(spacing: 19) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 10) {
                        Capsule().fill(Color.primary.opacity(0.055)).frame(width: index == 1 ? 120 : 80, height: 10)
                        Rectangle().fill(Color.primary.opacity(0.045)).frame(height: 2)
                        Circle().fill(Color.primary.opacity(0.09)).frame(width: 10, height: 10)
                    }
                }
            }
            VStack(spacing: 6) {
                Text("No progress data")
                    .font(LifeOSFont.header(17))
                Text(reason)
                    .font(LifeOSFont.body(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No strength progress data")
        .accessibilityValue(reason)
    }
}

// MARK: - Template cards/editor

private struct FitnessStrengthTemplateCard: View {
    let template: FitnessStrengthTemplate
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        StrengthSurfaceCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "figure.strengthtraining.traditional")
                        .foregroundStyle(LifeOSTokens.accent)
                    Text(template.name)
                        .font(LifeOSFont.header(15))
                        .lineLimit(2)
                    Spacer()
                    Menu {
                        Button("Edit", action: onEdit)
                        Button("Delete", role: .destructive, action: onDelete)
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 28, height: 28)
                    }
                    .menuStyle(.borderlessButton)
                    .accessibilityLabel("Actions for \(template.name)")
                }
                if template.exercises.isEmpty {
                    Text("No exercises yet")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    ForEach(template.exercises.prefix(3)) { exercise in
                        HStack(spacing: 7) {
                            Circle().fill(LifeOSTokens.accent.opacity(0.6)).frame(width: 5, height: 5)
                            Text(exercise.name)
                                .font(LifeOSFont.caption(11))
                                .lineLimit(1)
                            Spacer()
                            Text("\(exercise.sets) × \(exercise.repetitions)")
                                .font(LifeOSFont.inter(10, weight: .medium))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    if template.exercises.count > 3 {
                        Text("+\(template.exercises.count - 3) more")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
                Button("Edit template", action: onEdit)
                    .buttonStyle(.bordered)
                    .tint(LifeOSTokens.accent)
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                    .accessibilityHint("Edit exercises, sets, repetitions, and optional load")
            }
        }
        .opacity(hovered ? 0.80 : 1)
        #if os(macOS)
        .onHover { inside in
            withAnimation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy) { hovered = inside }
        }
        #endif
    }
}

private struct FitnessStrengthTemplateEditor: View {
    let template: FitnessStrengthTemplate?
    let onSave: (FitnessStrengthTemplate) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var exercises: [FitnessStrengthDraftExercise]
    @State private var errorMessage: String?

    init(template: FitnessStrengthTemplate?, onSave: @escaping (FitnessStrengthTemplate) throws -> Void) {
        self.template = template
        self.onSave = onSave
        _name = State(initialValue: template?.name ?? "")
        _exercises = State(initialValue: template?.exercises.map(FitnessStrengthDraftExercise.init) ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Template") {
                    TextField("Name", text: $name)
                    #if os(iOS)
                    .textInputAutocapitalization(.words)
                    #endif
                }
                Section {
                    if exercises.isEmpty {
                        Text("Add exercises to make the session reusable. A template may remain empty while you draft it.")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    ForEach($exercises) { $exercise in
                        FitnessStrengthDraftExerciseRow(exercise: $exercise) {
                            exercises.removeAll { $0.id == exercise.id }
                        }
                    }
                    Button {
                        exercises.append(FitnessStrengthDraftExercise())
                    } label: {
                        Label("Add exercise", systemImage: "plus")
                    }
                } header: {
                    Text("Exercises")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(LifeOSTokens.warning)
                            .font(LifeOSFont.caption(11))
                    }
                }
            }
            .navigationTitle(template == nil ? "New template" : "Edit template")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() {
        do {
            let now = Date.now
            let domainExercises = try exercises.map { try $0.makeDomainExercise() }
            let saved = try FitnessStrengthTemplate(
                id: template?.id ?? UUID().uuidString,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                exercises: domainExercises,
                createdAt: template?.createdAt ?? now,
                updatedAt: now
            )
            try onSave(saved)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct FitnessStrengthDraftExercise: Identifiable {
    var id: String = UUID().uuidString
    var name: String = ""
    var muscleGroup: FitnessStrengthMuscleGroup = .chest
    var sets: Int = 3
    var repetitions: Int = 8
    var loadText: String = ""

    init() {}

    init(_ exercise: FitnessStrengthExercise) {
        id = exercise.id
        name = exercise.name
        muscleGroup = exercise.muscleGroup
        sets = exercise.sets
        repetitions = exercise.repetitions
        loadText = exercise.loadKilograms.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? ""
    }

    func makeDomainExercise() throws -> FitnessStrengthExercise {
        let parsedLoad: Double?
        let trimmedLoad = loadText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLoad.isEmpty {
            parsedLoad = nil
        } else {
            let normalized = trimmedLoad.replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized), value.isFinite, value >= 0 else {
                throw FitnessStrengthTemplateValidationError.invalidLoad
            }
            parsedLoad = value
        }
        return try FitnessStrengthExercise(id: id, name: name, muscleGroup: muscleGroup, sets: sets, repetitions: repetitions, loadKilograms: parsedLoad)
    }
}

private struct FitnessStrengthDraftExerciseRow: View {
    @Binding var exercise: FitnessStrengthDraftExercise
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Exercise", text: $exercise.name)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove exercise")
            }
            Picker("Muscle group", selection: $exercise.muscleGroup) {
                ForEach(FitnessStrengthMuscleGroup.allCases) { group in
                    Text(group.title).tag(group)
                }
            }
            HStack {
                Stepper("Sets \(exercise.sets)", value: $exercise.sets, in: 1...100)
                Stepper("Reps \(exercise.repetitions)", value: $exercise.repetitions, in: 1...1_000)
            }
            TextField("Load kg (optional)", text: $exercise.loadText)
                #if os(iOS)
                .keyboardType(.decimalPad)
                #endif
        }
        .padding(.vertical, 4)
    }
}

private enum FitnessStrengthTemplateEditorPresentation: Identifiable {
    case add
    case edit(FitnessStrengthTemplate)

    var id: String {
        switch self {
        case .add: "add"
        case .edit(let template): "edit-\(template.id)"
        }
    }

    var template: FitnessStrengthTemplate? {
        if case .edit(let template) = self { return template }
        return nil
    }
}

private struct StrengthSurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(LifeOSTokens.cardPadding)
            .flatCard()
    }
}
