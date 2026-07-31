import SwiftUI

struct OverviewView: View {
    private let snapshot: OverviewSnapshot
    private let usageSnapshots: [ProviderSnapshot]
    private let usageAnalytics: [UsageAnalyticsSnapshot]
    @Binding private var showingUsage: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        snapshot: OverviewSnapshot = .unavailable(),
        usageSnapshots: [ProviderSnapshot] = [],
        usageAnalytics: [UsageAnalyticsSnapshot] = [],
        showingUsage: Binding<Bool> = .constant(false)
    ) {
        self.snapshot = snapshot
        self.usageSnapshots = usageSnapshots
        self.usageAnalytics = usageAnalytics
        _showingUsage = showingUsage
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, headerBottomSpacing)

                    VStack(spacing: LifeOSTokens.overviewCardGap) {
                        ForEach(Array(snapshot.sections.enumerated()), id: \.element.id) { index, section in
                            sectionRow(section)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                                .animation(
                                    reduceMotion ? nil : LifeOSMotion.spring.delay(Double(index) * 0.055),
                                    value: snapshot.generatedAt
                                )
                        }
                    }
                }
                .frame(maxWidth: 1_198, alignment: .leading)
                .padding(.horizontal, responsiveHorizontalInset)
                .padding(.top, headerTopSpacing)
                .padding(.bottom, contentBottomPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
#if os(iOS)
            .safeAreaPadding(.bottom, 58)
#endif
            .accessibilityIdentifier("overview-screen")
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationDestination(isPresented: $showingUsage) {
                UsageView(
                    snapshots: usageSnapshots,
                    analytics: usageAnalytics
                )
            }
        }
    }

    private var responsiveHorizontalInset: CGFloat {
#if os(macOS)
        LifeOSTokens.overviewContentInset
#else
        18
#endif
    }

    private var headerTopSpacing: CGFloat {
#if os(macOS)
        28
#else
        14
#endif
    }

    private var headerBottomSpacing: CGFloat {
#if os(macOS)
        36
#else
        20
#endif
    }

    private var contentBottomPadding: CGFloat {
#if os(macOS)
        40
#else
        // The floating iOS tab bar overlays scroll content. Keep the final card
        // fully scrollable above it rather than allowing metrics to sit beneath it.
        112
#endif
    }

    private var snapshotStatusLabel: String {
        let qualities = snapshot.sections.map(\.provenance.quality)
        if qualities.allSatisfy({ $0 == .demo }) { return "PREVIEW DATA" }
        if qualities.allSatisfy({ $0 == .unavailable }) { return "DATA UNAVAILABLE" }
        return "CONNECTED DATA"
    }

    private var header: some View {
#if os(macOS)
        VStack(alignment: .leading, spacing: 0) {
            Text("Overview")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.primary)
                .padding(.bottom, 32)

            Text("LifeOS")
                .font(.system(size: 38, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .padding(.bottom, 6)

            HStack(spacing: 10) {
                Text("The absolute all-in-one solution for geong")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color(red: 0x6F/255, green: 0x83/255, blue: 0x9C/255))
                Text(snapshotStatusLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LifeOSTokens.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LifeOSTokens.accent.opacity(0.12), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
#else
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("LifeOS")
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(snapshotStatusLabel)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LifeOSTokens.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LifeOSTokens.accent.opacity(0.12), in: Capsule())
            }
            Text("The absolute all-in-one solution for geong")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color(red: 0x6F/255, green: 0x83/255, blue: 0x9C/255))
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
#endif
    }

    @ViewBuilder
    private func sectionRow(_ section: OverviewSection) -> some View {
        if section.kind == .llm {
            NavigationLink {
                UsageView(
                    snapshots: usageSnapshots,
                    analytics: usageAnalytics
                )
            } label: {
                OverviewMetricCard(section: section)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account-usage-link")
            .accessibilityHint("Opens detailed LLM usage analytics")
        } else {
            OverviewMetricCard(section: section)
        }
    }
}

private struct OverviewMetricCard: View {
    let section: OverviewSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var title: String {
        switch section.kind {
        case .llm: "LLM Stats"
        case .clipper: "Clipper Analytics"
        case .health: "Health"
        case .finance: "Finance"
        }
    }

    private var description: String {
        switch section.kind {
        case .llm: "Every trackable data on all the currently used LLMs."
        case .clipper: "Views, subscribers, money generated and more analytics for all clipper accounts."
        case .health: "Every trackable datapoint surrounding my health."
        case .finance: "Month over month financial tracking to optimize spending and budgeting."
        }
    }

    private var sectionIcon: LifeOSIconName {
        switch section.kind {
        case .llm: .usage
        case .clipper: .clipper
        case .health: .health
        case .finance: .finance
        }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            desktopRow
                .frame(minWidth: 760)
            compactRow
        }
        .padding(.horizontal, 20)
#if os(macOS)
        .frame(height: LifeOSTokens.overviewCardHeight)
#else
        .frame(minHeight: 142)
        .padding(.vertical, 16)
#endif
        .background(LifeOSTokens.surface, in: cardShape)
        .overlay(cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .contentShape(cardShape)
        .scaleEffect(hovering && !reduceMotion ? 1.004 : 1)
        .overlay {
            if hovering {
                cardShape.stroke(LifeOSTokens.accent.opacity(0.62), lineWidth: 1)
            }
        }
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: hovering)
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(section.provenance.quality.rawValue) data")
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: LifeOSTokens.overviewCardCorner, style: .continuous)
    }

    private var desktopRow: some View {
        HStack(spacing: 15) {
            iconTile
            titleBlock
            Spacer(minLength: 28)
            metricContent
                .frame(width: 430, alignment: .trailing)
            if section.kind == .llm {
                LifeOSIcon(.chevronRight)
                    .foregroundStyle(LifeOSTokens.accent.opacity(0.8))
                    .frame(width: 14, height: 14)
            }
        }
    }

    private var compactRow: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                iconTile
                titleBlock
                Spacer(minLength: 8)
                if section.kind == .llm {
                    LifeOSIcon(.chevronRight)
                        .foregroundStyle(LifeOSTokens.accent.opacity(0.8))
                        .frame(width: 14, height: 14)
                }
            }
            metricContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var iconTile: some View {
        LifeOSIcon(sectionIcon)
            .foregroundStyle(LifeOSTokens.accent)
            .frame(width: 18, height: 18)
            .frame(width: LifeOSTokens.overviewIconTile, height: LifeOSTokens.overviewIconTile)
            .background(Color(red: 0x00/255, green: 0x2A/255, blue: 0x59/255), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(description)
                .font(.system(size: 12.5, weight: .regular))
                .foregroundStyle(Color(red: 0x6F/255, green: 0x83/255, blue: 0x9C/255))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 390, alignment: .leading)
    }

    @ViewBuilder
    private var metricContent: some View {
        switch section.kind {
        case .llm:
            HStack(spacing: 20) {
                RingMetric(value: percentValue(for: "Codex"), label: "Codex")
                RingMetric(value: percentValue(for: "Claude"), label: "Claude")
                RingMetric(value: percentValue(for: "GLM"), label: "GLM")
                VStack(spacing: 3) {
                    HStack(spacing: 4) {
                        LifeOSIcon(.usage).frame(width: 17, height: 17)
                        Text(metricValue(containing: "Banked") ?? "—")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(LifeOSTokens.accent)
                    Text("Codex").font(.system(size: 12, weight: .semibold))
                }
                .frame(minWidth: 55)
            }
        case .clipper:
            HStack(spacing: 36) {
                IconValueMetric(icon: .views, value: metricValue(containing: "Views"))
                IconValueMetric(icon: .subscribers, value: metricValue(containing: "Subscribers"))
                IconValueMetric(icon: .revenue, value: metricValue(containing: "Revenue"))
            }
        case .health:
            HStack(spacing: 52) {
                VStack(spacing: 4) {
                    HStack(spacing: 7) {
                        LifeOSIcon(.heartRate).frame(width: 24, height: 24)
                        Text(metricValue(containing: "heart") ?? "—")
                            .font(.system(size: 14, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(LifeOSTokens.accent)
                    Text("Resting Heart Rate").font(.system(size: 11.5, weight: .semibold))
                }
                ProgressMetric(value: percentValue(containing: "Sleep"), label: "Sleep Quality")
            }
        case .finance:
            HStack(spacing: 56) {
                ProgressMetric(value: percentValue(containing: "Savings"), label: "Savings Goal")
                RingMetric(value: percentValue(containing: "budget"), label: "Budget", centerText: budgetDisplay)
            }
        }
    }

    private var budgetDisplay: String? {
        metricValue(containing: "budget")
    }

    private func metricValue(containing needle: String) -> String? {
        section.metrics.first { $0.label.localizedCaseInsensitiveContains(needle) }?.displayValue
    }

    private func percentValue(for label: String) -> Double? {
        guard let raw = section.metrics.first(where: { $0.label.localizedCaseInsensitiveContains(label) })?.value,
              let number = Double(raw.replacingOccurrences(of: "%", with: "")) else { return nil }
        return min(max(number / 100, 0), 1)
    }

    private func percentValue(containing label: String) -> Double? {
        percentValue(for: label)
    }
}

private struct RingMetric: View {
    let value: Double?
    let label: String
    var centerText: String? = nil

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(LifeOSTokens.accent.opacity(0.16), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: value ?? 0)
                    .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text(centerText ?? value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .minimumScaleFactor(0.7)
            }
            .frame(width: 48, height: 48)
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IconValueMetric: View {
    let icon: LifeOSIconName
    let value: String?

    var body: some View {
        VStack(spacing: 5) {
            LifeOSIcon(icon)
                .foregroundStyle(LifeOSTokens.accent)
                .frame(width: 20, height: 20)
            Text(value ?? "—")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minWidth: 76)
        .accessibilityElement(children: .combine)
    }
}

private struct ProgressMetric: View {
    let value: Double?
    let label: String

    var body: some View {
        VStack(spacing: 5) {
            Text(value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            GeometryReader { proxy in
                Capsule()
                    .fill(LifeOSTokens.accent.opacity(0.16))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LifeOSTokens.accent)
                            .frame(width: proxy.size.width * (value ?? 0))
                    }
            }
            .frame(width: 110, height: 5)
            Text(label)
                .font(.system(size: 11.5, weight: .semibold))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}
