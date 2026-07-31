import SwiftUI

struct CodexView: View {
    let snapshot: ProviderSnapshot

    var body: some View {
        UsageView(snapshots: [snapshot])
    }
}

struct UsageView: View {
    let snapshots: [ProviderSnapshot]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Account usage")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Separate provider observations · no combined total")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: LifeOSTokens.spacing)], spacing: LifeOSTokens.spacing) {
                    ForEach(snapshots, id: \.provider) { snapshot in
                        ProviderCard(snapshot: snapshot)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Usage")
        .tint(LifeOSTokens.accent)
    }
}

private struct ProviderCard: View {
    let snapshot: ProviderSnapshot

    private var qualityColor: Color {
        switch snapshot.provenance.quality {
        case .observed: return LifeOSTokens.success
        case .estimated, .demo: return LifeOSTokens.warning
        case .unavailable: return LifeOSTokens.danger
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
            HStack(spacing: 10) {
                LifeOSIcon(snapshot.provider == .codex ? .usage : .assistant)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 19, height: 19)
                    .frame(width: LifeOSTokens.iconFrame, height: LifeOSTokens.iconFrame)
                    .background(LifeOSTokens.accentLight, in: LifeOSTokens.smallCardShape)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(snapshot.provider.rawValue.capitalized)
                        .font(.headline)
                    Text(snapshot.accountLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(snapshot.provenance.quality == .observed ? "OFFICIAL" : snapshot.provenance.quality.rawValue.uppercased())
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(qualityColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(qualityColor.opacity(0.12), in: Capsule())
                    .accessibilityLabel("Data quality: \(snapshot.provenance.quality.rawValue)")
            }

            ForEach(snapshot.windows) { window in
                WindowRow(window: window)
            }

            Text("Source: \(snapshot.provenance.source) · \(snapshot.provenance.freshness().rawValue)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Source \(snapshot.provenance.source), freshness \(snapshot.provenance.freshness().rawValue)")
        }
        .lifeOSCard()
        .accessibilityElement(children: .contain)
    }
}

private struct WindowRow: View {
    let window: UsageWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(window.label).font(.subheadline.weight(.semibold))
                Spacer()
                if let percent = window.usedPercent {
                    Text(percent, format: .percent)
                        .font(.subheadline.monospacedDigit().weight(.bold))
                        .foregroundStyle(LifeOSTokens.accent)
                } else {
                    Text("Unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let percent = window.usedPercent {
                ProgressView(value: percent)
                    .tint(LifeOSTokens.accent)
                    .accessibilityLabel("\(window.label) usage")
                    .accessibilityValue(percent.formatted(.percent))
            } else {
                Text("Official window not supplied; no value invented")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let reset = window.resetAt {
                Text("Resets \(reset, style: .relative)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let projection = window.projection {
                Text(projectionLabel(projection))
                    .font(.caption2)
                    .foregroundStyle(LifeOSTokens.warning)
            }
        }
    }

    private func projectionLabel(_ projection: Projection) -> String {
        if let percent = projection.percentAtReset {
            return "Estimate at reset: \(percent.formatted(.percent))"
        }
        if let percent = projection.percentAtExhaustion {
            return "Estimate at exhaustion: \(percent.formatted(.percent))"
        }
        return "Estimate · insufficient signal"
    }
}
