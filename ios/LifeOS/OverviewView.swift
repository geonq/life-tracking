import SwiftUI

struct OverviewView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
                    Text("Life OS").font(.largeTitle.bold())
                    Text("Compact overview · provider-neutral usage")
                        .foregroundStyle(.secondary)
                    NavigationLink {
                        UsageView(snapshots: DemoDataProvider.providers)
                    } label: {
                        CategoryCard(title: "Account usage",
                                     detail: "Codex and Claude · separate windows",
                                     icon: "gauge.with.dots.needle.67percent")
                    }
                    BlockedCategoryCard(title: "Clipper", reason: "Blocked: no authorized data connector", icon: "chart.line.uptrend.xyaxis")
                    BlockedCategoryCard(title: "Health", reason: "Blocked: HealthKit permission and device sync required", icon: "heart.fill")
                    BlockedCategoryCard(title: "Finance", reason: "Blocked: authorized import required", icon: "banknote.fill")
                }
                .padding()
            }
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
                .foregroundStyle(LifeOSTokens.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
        }
        .padding()
        .background(LifeOSTokens.surface, in: RoundedRectangle(cornerRadius: LifeOSTokens.corner))
        .overlay(RoundedRectangle(cornerRadius: LifeOSTokens.corner).stroke(LifeOSTokens.quietBorder))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

struct BlockedCategoryCard: View {
    let title: String
    let reason: String
    let icon: String

    var body: some View {
        CategoryCard(title: title, detail: reason, icon: icon)
            .overlay(alignment: .topTrailing) {
                Text("BLOCKED").font(.caption2.bold()).foregroundStyle(.secondary).padding(8)
            }
            .accessibilityHint("No metrics are shown until an authorized source is available")
    }
}
