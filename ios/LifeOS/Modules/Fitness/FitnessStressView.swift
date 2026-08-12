import SwiftUI

/// Responsive Stress detail for Bevel IMG_0405–IMG_0412. The surface is fed by
/// `FitnessStressSnapshot`; it never reads generic Fitness values and never
/// derives a missing subtype from the overall series.
public struct FitnessStressDetailView: View {
    public let snapshot: FitnessStressSnapshot
    @Binding public var selectedDate: Date
    public let embeddedInParentScroll: Bool

    @State private var selectedKind: FitnessStressSeriesKind = .overall
    @State private var selectedRange: FitnessTrendRange?
    @State private var selectedSampleIndex = 0

    public init(
        snapshot: FitnessStressSnapshot = .unavailable,
        selectedDate: Binding<Date>,
        embeddedInParentScroll: Bool = false
    ) {
        self.snapshot = snapshot
        self._selectedDate = selectedDate
        self.embeddedInParentScroll = embeddedInParentScroll
        _selectedRange = State(initialValue: snapshot.windows(for: .overall).first?.range)
    }

    private var selectedDay: FitnessStressDay? {
        snapshot.day(for: selectedDate)
    }

    private var selectedSeries: FitnessStressSeries? {
        selectedDay?.series(for: selectedKind)
    }

    private var selectedWindow: FitnessStressTrendWindow? {
        guard let selectedRange else { return nil }
        return snapshot.window(for: selectedKind, range: selectedRange)
    }

    public var body: some View {
        Group {
            if embeddedInParentScroll {
                content
            } else {
                ScrollView {
                    content
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Stress")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .onChange(of: selectedKind) { _, kind in
            selectedRange = snapshot.windows(for: kind).first?.range
            selectedSampleIndex = max(0, (selectedSeries?.samples.count ?? 1) - 1)
        }
        .onChange(of: selectedDate) { _, _ in
            selectedSampleIndex = max(0, (selectedSeries?.samples.count ?? 1) - 1)
        }
        .accessibilityIdentifier("fitness-stress-detail")
    }

    private var content: some View {
        LifeOSResponsiveContentContainer(horizontalPadding: 0, topPadding: 0, bottomPadding: 0) {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let selectedDay {
                    heroAndContext(for: selectedDay)
                    coaching(for: selectedDay)
                    seriesTabs
                    intradaySection(for: selectedDay)
                    distributionSection(for: selectedDay)
                } else {
                    unavailableCard(
                        title: "Stress is unavailable for this date",
                        detail: "No source observation is supplied for \(selectedDate.stressDateLabel). An unavailable day is not zero."
                    )
                    seriesTabs
                    unavailableCard(title: selectedKind.title, detail: "This subtype has no selected-day source samples.")
                }
                coverageSection
                trendSection
                provenanceSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stress")
                    .font(LifeOSFont.headerLarge(28))
                Text(selectedDate.stressDateLabel)
                    .font(LifeOSFont.body(13))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            StressStateBadge(evidence: selectedDay?.evidence ?? .unavailable("No selected-day source observation."))
        }
    }

    private func heroAndContext(for day: FitnessStressDay) -> some View {
        StressSurfaceCard {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 22) {
                    heroContent(for: day)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(LifeOSTokens.quietBorder)
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                    contextPanel(for: day)
                        .frame(minWidth: 300, maxWidth: 360, alignment: .leading)
                }
                .frame(minHeight: 208)
                VStack(alignment: .leading, spacing: 16) {
                    heroContent(for: day)
                    Divider()
                    contextPanel(for: day)
                }
            }
        }
        .accessibilityIdentifier("fitness-stress-hero")
    }

    private func heroContent(for day: FitnessStressDay) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 22) {
                stressRing(metric: day.stress)
                    .frame(width: 184, height: 184)
                heroCopy(for: day)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 16) {
                stressRing(metric: day.stress)
                    .frame(maxWidth: .infinity, minHeight: 168, maxHeight: 168)
                heroCopy(for: day)
            }
        }
    }

    private func heroCopy(for day: FitnessStressDay) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Selected-day observation")
                .font(LifeOSFont.caption(11).weight(.semibold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            if let value = day.stress.value {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Text(value, format: .number.precision(.fractionLength(0...1)))
                        .font(LifeOSFont.spaceGrotesk(42, weight: .bold))
                        .monospacedDigit()
                    Text(day.stress.unit)
                        .font(LifeOSFont.body(15))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Text(day.stress.scale.map { "Source scale · \(formatNumber($0.minimum))–\(formatNumber($0.maximum))" } ?? "Source scale not supplied")
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                Text("—")
                    .font(LifeOSFont.spaceGrotesk(42, weight: .bold))
                Text("No source value")
                    .font(LifeOSFont.body(14))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Text(day.stress.evidence.summary)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stressRing(metric: FitnessStressMetric) -> some View {
        ZStack {
            Circle()
                .stroke(LifeOSTokens.quietBorder.opacity(0.65), lineWidth: 14)
            if let progress = metric.progress {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        LinearGradient(
                            colors: [LifeOSTokens.accent, LifeOSTokens.success],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        style: StrokeStyle(lineWidth: 14, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 2) {
                if let value = metric.value {
                    Text(value, format: .number.precision(.fractionLength(0...1)))
                        .font(LifeOSFont.spaceGrotesk(31, weight: .bold))
                        .monospacedDigit()
                    Text("observed")
                        .font(LifeOSFont.caption(10).weight(.semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    Text("—")
                        .font(LifeOSFont.spaceGrotesk(31, weight: .bold))
                    Text("unavailable")
                        .font(LifeOSFont.caption(10).weight(.semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Selected-day stress")
        .accessibilityValue(metric.value.map { "\(formatNumber($0)) \(metric.unit)" } ?? "Unavailable")
    }

    private func contextPanel(for day: FitnessStressDay) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Context supplied")
                .font(LifeOSFont.header(16))
            if day.averageHRV.isUnavailable && day.averageHeartRate.isUnavailable {
                Text("Average HRV and average heart rate were not supplied by the Stress source.")
                    .font(LifeOSFont.body(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    if !day.averageHRV.isUnavailable { contextMetric(day.averageHRV) }
                    if !day.averageHeartRate.isUnavailable { contextMetric(day.averageHeartRate) }
                }
            }
        }
    }

    private func contextMetric(_ metric: FitnessStressMetric) -> some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 6) {
                Text(metric.title)
                    .font(LifeOSFont.caption(11).weight(.semibold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                HStack(alignment: .lastTextBaseline, spacing: 5) {
                    Text(metric.value ?? 0, format: .number.precision(.fractionLength(0...1)))
                        .font(LifeOSFont.spaceGrotesk(25, weight: .bold))
                        .monospacedDigit()
                    Text(metric.unit)
                        .font(LifeOSFont.caption(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Text(metric.evidence.source ?? "Source unavailable")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func coaching(for day: FitnessStressDay) -> some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Coaching")
                    .font(LifeOSFont.header(16))
                if let text = day.coaching.text {
                    Text(text)
                        .font(LifeOSFont.body(13))
                        .fixedSize(horizontal: false, vertical: true)
                    if let provenance = day.coaching.provenanceSummary {
                        Text(provenance)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                } else {
                    Text("Source-authored coaching is unavailable for this observation.")
                        .font(LifeOSFont.body(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
    }

    private var seriesTabs: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Stress series")
                .font(LifeOSFont.header(16))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FitnessStressSeriesKind.allCases) { kind in
                        StressSeriesTabButton(kind: kind, isSelected: selectedKind == kind) {
                            selectedKind = kind
                        }
                    }
                }
            }
        }
    }

    private func intradaySection(for day: FitnessStressDay) -> some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Intraday \(selectedKind.title)")
                            .font(LifeOSFont.header(16))
                        Text("Source samples · scrub to inspect the selected point")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    if let series = selectedSeries, !series.samples.isEmpty,
                       series.samples.indices.contains(selectedSampleIndex) {
                        let sample = series.samples[selectedSampleIndex]
                        Text(sample.value, format: .number.precision(.fractionLength(0...1)))
                            .font(LifeOSFont.spaceGrotesk(23, weight: .bold))
                            .monospacedDigit()
                    }
                }
                if let series = selectedSeries, !series.isUnavailable {
                    FitnessStressSeriesChart(
                        samples: series.samples,
                        scale: series.scale,
                        selectedIndex: $selectedSampleIndex
                    )
                    if series.samples.indices.contains(selectedSampleIndex) {
                        let sample = series.samples[selectedSampleIndex]
                        Text("Selected \(sample.timestamp, format: .dateTime.hour().minute()) · \(formatNumber(sample.value)) \(series.scale?.unit ?? "source units")")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                } else {
                    Text("No \(selectedKind.title.lowercased()) source samples are supplied for this date. LifeOS does not substitute the overall series.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("fitness-stress-intraday")
    }

    private func distributionSection(for day: FitnessStressDay) -> some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Observed duration")
                        .font(LifeOSFont.header(16))
                    Spacer(minLength: 8)
                    if let total = day.distribution.totalObservedSeconds {
                        Text(formatDuration(total))
                            .font(LifeOSFont.spaceGrotesk(21, weight: .bold))
                            .monospacedDigit()
                    }
                }
                if day.distribution.isUnavailable {
                    Text("Low, medium, and high buckets are unavailable because the source did not supply a reconciled duration.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    ForEach(FitnessStressBand.allCases, id: \.self) { band in
                        StressDistributionRow(band: band, distribution: day.distribution)
                    }
                    if let labels = day.distribution.labels {
                        let lowLabel = labels[.low] ?? "—"
                        let mediumLabel = labels[.medium] ?? "—"
                        let highLabel = labels[.high] ?? "—"
                        Text("Source threshold labels · \(lowLabel) · \(mediumLabel) · \(highLabel)")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    if let provenance = day.distribution.provenance {
                        Text(provenance)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-stress-distribution")
    }

    private var coverageSection: some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Day coverage")
                        .font(LifeOSFont.header(16))
                    Spacer(minLength: 8)
                    Text(selectedDate, format: .dateTime.month(.wide).year())
                        .font(LifeOSFont.caption(11).weight(.semibold))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 8) {
                    ForEach(monthDates, id: \.self) { date in
                        StressCoverageCell(date: date, coverage: snapshot.coverage(for: date))
                    }
                }
                HStack(spacing: 12) {
                    StressCoverageLegend(color: LifeOSTokens.accent, title: "Observed")
                    StressCoverageLegend(color: LifeOSTokens.tertiaryText.opacity(0.45), title: "Unavailable")
                    StressCoverageLegend(color: LifeOSTokens.tertiaryText, title: "Explicit zero")
                }
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .accessibilityIdentifier("fitness-stress-coverage")
    }

    private var monthDates: [Date] {
        let calendar = Calendar.current
        guard let interval = calendar.dateInterval(of: .month, for: selectedDate),
              let dayRange = calendar.range(of: .day, in: .month, for: selectedDate) else { return [] }
        return dayRange.compactMap { day in
            calendar.date(byAdding: .day, value: day - 1, to: interval.start)
        }
    }

    private var trendSection: some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Trend analysis")
                    .font(LifeOSFont.header(16))
                let windows = snapshot.windows(for: selectedKind)
                if windows.isEmpty {
                    Text("No named source windows are supplied for \(selectedKind.title). Range controls stay unavailable until that source history exists.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(windows) { window in
                                StressRangeButton(window: window, isSelected: selectedRange == window.range) {
                                    selectedRange = window.range
                                }
                            }
                        }
                    }
                    if let window = selectedWindow {
                        FitnessStressTrendChart(points: window.points)
                            .frame(height: 112)
                        HStack(alignment: .firstTextBaseline) {
                            Text(window.average.map(formatNumber) ?? "—")
                                .font(LifeOSFont.spaceGrotesk(22, weight: .bold))
                                .monospacedDigit()
                            Text("average · \(window.trendLabel ?? "Insufficient history")")
                                .font(LifeOSFont.caption(11))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Spacer(minLength: 8)
                            Text(window.sourceWindow)
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-stress-trends")
    }

    private var provenanceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Source and state")
                .font(LifeOSFont.header(15))
            Text((selectedDay?.evidence ?? .unavailable("No selected-day source observation.")).summary)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text("Stress is an observed trend in this view, not a mental-health or medical claim.")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .padding(.horizontal, 2)
    }

    private func unavailableCard(title: String, detail: String) -> some View {
        StressSurfaceCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(LifeOSFont.header(16))
                Text(detail)
                    .font(LifeOSFont.body(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct StressSurfaceCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                LinearGradient(
                    colors: [LifeOSTokens.surface, LifeOSTokens.surface.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 18, style: .continuous)
            )
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
    }
}

private struct StressSeriesTabButton: View {
    let kind: FitnessStressSeriesKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let foreground: Color = isSelected ? .white : .primary
        let background: Color = isSelected ? LifeOSTokens.accent : LifeOSTokens.surface
        Button(action: action) {
            Text(kind.title)
                .font(LifeOSFont.caption(11).weight(.semibold))
                .foregroundStyle(foreground)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(background, in: Capsule())
                .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StressRangeButton: View {
    let window: FitnessStressTrendWindow
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        let title = "\(window.range.rawValue)d"
        let foreground: Color = isSelected ? .white : .primary
        let background: Color = isSelected ? LifeOSTokens.accent : LifeOSTokens.surface
        return Button(title, action: action)
            .font(LifeOSFont.caption(11).weight(.semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(background, in: Capsule())
            .overlay(Capsule().stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct StressStateBadge: View {
    let evidence: FitnessStressEvidence

    private var title: String {
        switch evidence.state {
        case .unavailable: return "Unavailable"
        case .observed: return "Observed"
        case .stale: return "Stale"
        case .demo: return "Demo · not live"
        }
    }

    private var color: Color {
        switch evidence.state {
        case .unavailable: return LifeOSTokens.tertiaryText
        case .observed: return LifeOSTokens.success
        case .stale: return LifeOSTokens.warning
        case .demo: return LifeOSTokens.accent
        }
    }

    var body: some View {
        Text(title)
            .font(LifeOSFont.caption(10).weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(color.opacity(0.12), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.28), lineWidth: 0.75))
    }
}

private struct FitnessStressSeriesChart: View {
    let samples: [FitnessStressSample]
    let scale: FitnessStressScale?
    @Binding var selectedIndex: Int

    private let plotHeight: CGFloat = 132
    private let yAxisWidth: CGFloat = 42

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(Array(axisValues.enumerated()), id: \.offset) { index, value in
                        Text(formatNumber(value))
                            .font(LifeOSFont.caption(9))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        if index < axisValues.count - 1 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: yAxisWidth, height: plotHeight)

                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        stressGrid
                        Path { path in
                            guard samples.count > 1 else { return }
                            for (index, sample) in samples.enumerated() {
                                let point = CGPoint(x: x(for: index, width: proxy.size.width), y: y(for: sample.value, height: proxy.size.height))
                                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                        }
                        .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        if samples.indices.contains(selectedIndex) {
                            let sample = samples[selectedIndex]
                            let x = x(for: selectedIndex, width: proxy.size.width)
                            let y = y(for: sample.value, height: proxy.size.height)
                            Path { path in
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                            }
                            .stroke(LifeOSTokens.tertiaryText.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            Circle()
                                .fill(LifeOSTokens.accent)
                                .frame(width: 10, height: 10)
                                .offset(x: x - 5, y: y - 5)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { gesture in
                        selectedIndex = stressScrubIndex(locationX: gesture.location.x, width: proxy.size.width, count: samples.count)
                    })
                }
                .frame(height: plotHeight)
            }

            HStack(spacing: 0) {
                Color.clear.frame(width: yAxisWidth + 8)
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(xTickIndices.enumerated()), id: \.offset) { tickIndex, sampleIndex in
                            let alignment: Alignment = tickIndex == 0 ? .leading : (tickIndex == xTickIndices.count - 1 ? .trailing : .center)
                            Text(samples[sampleIndex].timestamp, format: .dateTime.hour().minute())
                                .font(LifeOSFont.caption(9))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                                .frame(width: 48, alignment: alignment)
                                .position(x: clampedLabelX(for: sampleIndex, width: proxy.size.width), y: 7)
                        }
                    }
                }
            }
            .frame(height: 14)
        }
        .frame(height: plotHeight + 19)
        .accessibilityHidden(true)
    }

    private var axisValues: [Double] {
        let values = samples.map(\.value)
        guard !values.isEmpty else { return [] }
        let minimum = scale?.minimum ?? values.min() ?? 0
        let maximum = scale?.maximum ?? values.max() ?? minimum
        guard maximum > minimum else { return [maximum] }
        return [maximum, minimum + (maximum - minimum) / 2, minimum]
    }

    private var xTickIndices: [Int] {
        guard !samples.isEmpty else { return [] }
        let count = min(4, samples.count)
        guard count > 1 else { return [0] }
        return (0..<count).map { index in
            Int((Double(index) * Double(samples.count - 1) / Double(count - 1)).rounded())
        }
    }

    private var observedRange: (minimum: Double, maximum: Double) {
        let values = samples.map(\.value)
        return (values.min() ?? 0, values.max() ?? 1)
    }

    private var stressGrid: some View {
        VStack(spacing: 0) {
            ForEach(Array(axisValues.enumerated()), id: \.offset) { index, _ in
                Rectangle()
                    .fill(LifeOSTokens.quietBorder.opacity(index == axisValues.count - 1 ? 0.55 : 0.25))
                    .frame(height: 1)
                if index < axisValues.count - 1 { Spacer() }
            }
        }
    }

    private func x(for index: Int, width: CGFloat) -> CGFloat {
        guard samples.count > 1 else { return width / 2 }
        return width * CGFloat(index) / CGFloat(samples.count - 1)
    }

    private func clampedLabelX(for index: Int, width: CGFloat) -> CGFloat {
        min(max(24, x(for: index, width: width)), max(24, width - 24))
    }

    private func y(for value: Double, height: CGFloat) -> CGFloat {
        let normalized: Double
        if let scale {
            normalized = scale.normalized(value)
        } else {
            let range = observedRange
            normalized = range.maximum > range.minimum ? (value - range.minimum) / (range.maximum - range.minimum) : 0.5
        }
        return height * CGFloat(1 - min(1, max(0, normalized)))
    }
}

private struct FitnessStressTrendChart: View {
    let points: [FitnessStressDailyPoint]

    var body: some View {
        GeometryReader { proxy in
            Path { path in
                var previous: CGPoint?
                let values = points.compactMap(\.value)
                let minimum = values.min() ?? 0
                let maximum = values.max() ?? 1
                for (index, point) in points.enumerated() {
                    guard let value = point.value else {
                        previous = nil
                        continue
                    }
                    let normalized = maximum > minimum ? (value - minimum) / (maximum - minimum) : 0.5
                    let location = CGPoint(
                        x: points.count > 1 ? proxy.size.width * CGFloat(index) / CGFloat(points.count - 1) : proxy.size.width / 2,
                        y: proxy.size.height * CGFloat(1 - min(1, max(0, normalized)))
                    )
                    if let previous { path.move(to: previous); path.addLine(to: location) } else { path.move(to: location) }
                    previous = location
                }
            }
            .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(LifeOSTokens.quietBorder.opacity(0.5)).frame(height: 1)
        }
        .accessibilityHidden(true)
    }
}

private struct StressDistributionRow: View {
    let band: FitnessStressBand
    let distribution: FitnessStressDistribution

    private var color: Color {
        switch band {
        case .low: return LifeOSTokens.success
        case .medium: return LifeOSTokens.warning
        case .high: return LifeOSTokens.danger
        }
    }

    var body: some View {
        HStack(spacing: 9) {
            Text(band.title)
                .font(LifeOSFont.body(12).weight(.semibold))
                .frame(width: 58, alignment: .leading)
            GeometryReader { proxy in
                Capsule()
                    .fill(color.opacity(0.14))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(color)
                            .frame(width: proxy.size.width * CGFloat(distribution.percentage(for: band) ?? 0))
                    }
            }
            .frame(height: 8)
            Text(percentageLabel)
                .font(LifeOSFont.caption(11).weight(.semibold))
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
            Text(distribution.duration(for: band).map(formatDuration) ?? "—")
                .font(LifeOSFont.caption(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .monospacedDigit()
                .frame(width: 54, alignment: .trailing)
        }
        .frame(height: 24)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(band.title) \(percentageLabel), \(distribution.duration(for: band).map(formatDuration) ?? "Unavailable")")
    }

    private var percentageLabel: String {
        guard let percentage = distribution.percentage(for: band) else { return "—" }
        return "\(Int((percentage * 100).rounded()))%"
    }
}

private struct StressCoverageCell: View {
    let date: Date
    let coverage: FitnessStressCoverageDay?

    private var fill: Color {
        guard let coverage else { return LifeOSTokens.tertiaryText.opacity(0.12) }
        switch coverage.state {
        case .observed: return LifeOSTokens.accent.opacity(0.88)
        case .zeroObserved: return LifeOSTokens.tertiaryText.opacity(0.38)
        case .unavailable: return LifeOSTokens.tertiaryText.opacity(0.12)
        }
    }

    private var label: String {
        guard let coverage else { return "Unavailable" }
        switch coverage.state {
        case .observed: return "Observed"
        case .zeroObserved: return "Explicit zero"
        case .unavailable: return "Unavailable"
        }
    }

    var body: some View {
        VStack(spacing: 3) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(fill)
                .frame(height: 28)
                .overlay(Text(date, format: .dateTime.day()).font(LifeOSFont.caption(10).weight(.semibold)).foregroundStyle(textColor))
            Text(label)
                .font(.system(size: 7, weight: .medium))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(date, format: .dateTime.day().month()) \(label)")
    }

    private var textColor: Color {
        switch coverage?.state {
        case .observed: return .white
        case .zeroObserved, .unavailable, .none: return .primary
        }
    }
}

private struct StressCoverageLegend: View {
    let color: Color
    let title: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
    }
}

private func stressScrubIndex(locationX: CGFloat, width: CGFloat, count: Int) -> Int {
    guard count > 1, width > 0 else { return 0 }
    let normalized = min(1, max(0, locationX / width))
    return min(count - 1, max(0, Int((normalized * CGFloat(count - 1)).rounded())))
}

private func formatNumber(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(0...1)))
}

private func formatDuration(_ seconds: Int) -> String {
    guard seconds >= 0 else { return "—" }
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
    return "\(minutes)m"
}

private extension Date {
    var stressDateLabel: String {
        formatted(.dateTime.day().month(.wide).year())
    }
}
