import SwiftUI

struct OverviewView: View {
    private let snapshot: OverviewSnapshot
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(snapshot: OverviewSnapshot = DemoDataProvider.overview) {
        self.snapshot = snapshot
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 280, maximum: 520), spacing: LifeOSTokens.spacing)],
                        alignment: .leading,
                        spacing: LifeOSTokens.spacing
                    ) {
                        ForEach(Array(snapshot.sections.enumerated()), id: \.element.id) { index, section in
                            sectionView(section)
                                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                                .animation(
                                    reduceMotion ? nil : LifeOSMotion.spring.delay(Double(index) * 0.045),
                                    value: snapshot.generatedAt
                                )
                        }
                    }
                }
                .frame(maxWidth: 1_160, alignment: .leading)
                .padding(LifeOSTokens.pagePadding)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("Life OS")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Everything important, at a glance")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle().fill(LifeOSTokens.warning).frame(width: 6, height: 6)
                Text("Preview data · connect sources when ready")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sectionView(_ section: OverviewSection) -> some View {
        if section.kind == .llm {
            NavigationLink {
                UsageView(snapshots: DemoDataProvider.providers)
            } label: {
                OverviewCategoryCard(section: section)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("account-usage-link")
        } else {
            OverviewCategoryCard(section: section)
        }
    }
}

private struct OverviewCategoryCard: View {
    let section: OverviewSection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    private var icon: LifeOSIconName {
        switch section.kind {
        case .llm: .usage
        case .clipper: .clipper
        case .health: .health
        case .finance: .finance
        }
    }

    private func icon(for metric: OverviewMetric) -> LifeOSIconName {
        switch metric.icon {
        case .usage: .usage
        case .views: .views
        case .subscribers: .subscribers
        case .revenue: .revenue
        case .heartRate: .heartRate
        case .sleep: .sleep
        case .health: .health
        case .savings: .savings
        case .budget: .budget
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                LifeOSIcon(icon)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 19, height: 19)
                    .frame(width: LifeOSTokens.iconFrame, height: LifeOSTokens.iconFrame)
                    .background(LifeOSTokens.accent.opacity(0.11), in: LifeOSTokens.smallCardShape)
                Text(section.title)
                    .font(.headline.weight(.semibold))
                Spacer(minLength: 8)
                Text(section.provenance.quality.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(LifeOSTokens.warning)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(LifeOSTokens.warning.opacity(0.10), in: Capsule())
                if section.kind == .llm {
                    LifeOSIcon(.chevronRight)
                        .foregroundStyle(.secondary)
                        .frame(width: 15, height: 15)
                }
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), alignment: .leading)], alignment: .leading, spacing: 14) {
                ForEach(section.metrics) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        LifeOSIcon(icon(for: metric))
                            .foregroundStyle(LifeOSTokens.accent)
                            .frame(width: 14, height: 14)
                        Text(metric.displayValue ?? "Not connected")
                            .font(.system(.title3, design: .rounded, weight: .semibold))
                            .foregroundStyle(metric.displayValue == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Text(metric.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(metric.label): \(metric.displayValue ?? "not connected")")
                }
            }
        }
        .lifeOSCard()
        .scaleEffect(hovering && !reduceMotion ? 1.008 : 1)
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: hovering)
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(section.title), preview data")
    }
}
