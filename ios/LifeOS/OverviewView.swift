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
                        ForEach(snapshot.sections) { section in
                            sectionRow(section)
                                .transition(reduceMotion ? .identity : .opacity)
                        }
                    }
                }
                .frame(maxWidth: 1_040, alignment: .leading)
                .padding(.horizontal, responsiveHorizontalInset)
                .padding(.top, headerTopSpacing)
                .padding(.bottom, contentBottomPadding)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
#if os(iOS)
            .accessibilityIdentifier("overview-screen")
#endif
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
        24
#else
        16
#endif
    }

    private var contentBottomPadding: CGFloat {
#if os(macOS)
        40
#else
        24
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
        VStack(alignment: .leading, spacing: 5) {
            Text("Life OS")
                .font(LifeOSFont.manrope(32, weight: .extraBold))
                .foregroundStyle(.primary)

            HStack(spacing: 8) {
                Text("A quiet view of what matters now")
                    .font(LifeOSFont.inter(13, weight: .regular))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Text(snapshotStatusLabel)
                    .font(LifeOSFont.inter(9, weight: .semiBold))
                    .tracking(0.45)
                    .foregroundStyle(LifeOSTokens.accent)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(LifeOSTokens.accent.opacity(0.12), in: Capsule())
            }
        }
        .accessibilityElement(children: .combine)
#else
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Life OS")
                    .font(LifeOSFont.manrope(28, weight: .extraBold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 8)
            }
            Text("A quiet view of what matters now")
                .font(LifeOSFont.inter(13, weight: .regular))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
#endif
    }

    @ViewBuilder
    private func sectionRow(_ section: OverviewSection) -> some View {
        if section.kind == .llm {
            Button {
                showingUsage = true
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
        case .llm: "Limits and activity across connected models"
        case .clipper: "Reach, audience and revenue across accounts"
        case .health: "Recovery, sleep and daily signals"
        case .finance: "Cash flow, spending and savings"
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
        .frame(minHeight: 92)
        .padding(.vertical, 8)
#endif
        .background(LifeOSTokens.surface, in: cardShape)
        .overlay(cardShape.stroke(hovering ? Color.primary.opacity(0.18) : LifeOSTokens.quietBorder, lineWidth: 0.75))
        .contentShape(cardShape)
        .offset(y: hovering && !reduceMotion ? -1 : 0)
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
        VStack(alignment: .leading, spacing: 14) {
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
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .frame(width: LifeOSTokens.overviewIconTile, height: LifeOSTokens.overviewIconTile)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(LifeOSFont.spaceGrotesk(16, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(description)
                .font(LifeOSFont.inter(12.5, weight: .regular))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 390, alignment: .leading)
    }

    @ViewBuilder
    private var metricContent: some View {
        switch section.kind {
        case .llm:
            HStack(spacing: 12) {
                GaugeMetric(value: percentValue(for: "Codex"), label: "Codex")
                GaugeMetric(value: percentValue(for: "Claude"), label: "Claude")
                GaugeMetric(value: percentValue(for: "GLM"), label: "GLM")
                ValueMetric(value: metricValue(containing: "Banked"), label: "Banked")
            }
        case .clipper:
            HStack(spacing: 12) {
                ValueMetric(value: metricValue(containing: "Views"), label: "Views")
                ValueMetric(value: metricValue(containing: "Subscribers"), label: "Subscribers")
                ValueMetric(value: metricValue(containing: "Revenue"), label: "Revenue")
            }
        case .health:
            HStack(spacing: 12) {
                ValueMetric(value: metricValue(containing: "heart"), label: "Resting HR")
                GaugeMetric(value: percentValue(containing: "Sleep"), label: "Sleep")
            }
        case .finance:
            HStack(spacing: 12) {
                GaugeMetric(value: percentValue(containing: "Savings"), label: "Savings")
                GaugeMetric(value: percentValue(containing: "budget"), label: "Budget", displayValue: budgetDisplay)
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

private struct GaugeMetric: View {
    let value: Double?
    let label: String
    var displayValue: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                Spacer(minLength: 4)
                Text(displayValue ?? value.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.primary.opacity(0.08))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(LifeOSTokens.accent)
                            .frame(width: proxy.size.width * (value ?? 0))
                    }
            }
            .frame(height: 2)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ValueMetric: View {
    let value: String?
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value ?? "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
