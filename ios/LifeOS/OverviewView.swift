import SwiftUI

struct OverviewView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
                    Text("Life OS")
                        .font(.largeTitle.bold())
                        .foregroundStyle(.primary)
                    Text("Compact overview · provider-neutral usage")
                        .font(.subheadline)
                        .foregroundStyle(LifeOSTokens.accent.opacity(0.7))
                    NavigationLink {
                        UsageView(snapshots: DemoDataProvider.providers)
                    } label: {
                        CategoryCard(title: "Account usage",
                                     detail: "Codex and Claude · separate windows",
                                     icon: "gauge.with.dots.needle.67percent")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("account-usage-link")
                    BlockedCategoryCard(title: "Clipper", reason: "Blocked: no authorized data connector", icon: "chart.line.uptrend.xyaxis")
                    BlockedCategoryCard(title: "Health", reason: "Blocked: HealthKit permission and device sync required", icon: "heart.fill")
                    BlockedCategoryCard(title: "Finance", reason: "Blocked: authorized import required", icon: "banknote.fill")
                }
                .padding()
            }
            .background(LifeOSTokens.screenCanvas)
            .navigationTitle("Overview")
        }
    }
}

struct CategoryCard: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(LifeOSTokens.accent)
                .frame(width: LifeOSTokens.iconFrame, height: LifeOSTokens.iconFrame)
                .background(LifeOSTokens.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .lifeOSCard()
        .contentShape(RoundedRectangle(cornerRadius: LifeOSTokens.corner))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
        .accessibilityAddTraits(.isButton)
    }
}

struct BlockedCategoryCard: View {
    let title: String
    let reason: String
    let icon: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: LifeOSTokens.iconFrame, height: LifeOSTokens.iconFrame)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(reason).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Text("BLOCKED")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.secondary.opacity(0.10), in: Capsule())
        }
        .lifeOSCard()
        .overlay(alignment: .topTrailing) {
            // Preserve original overlay-free look; badge is inline in HStack
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(reason)")
        .accessibilityHint("No metrics are shown until an authorized source is available")
    }
}
