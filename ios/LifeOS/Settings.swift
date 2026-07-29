import SwiftUI

struct SettingsView: View {
    private let signing = SigningStatus.current()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
#if os(macOS)
                Text("Settings")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
#endif

                SettingsSection(title: "Privacy", systemImage: "lock.shield") {
                    Label("Native iOS + macOS foundation · Demo usage data", systemImage: "checkmark.seal")
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Calendar items are stored locally. HealthKit, Clipper, Finance, connectors, and voice capture are not implemented.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Signing", systemImage: signing.state == .expired ? "exclamationmark.triangle" : "checkmark.shield") {
                    Label(signingLabel, systemImage: signing.state == .expired ? "exclamationmark.triangle.fill" : "checkmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(signing.state == .expired ? LifeOSTokens.danger : LifeOSTokens.success)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(signing.guidance)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Automatic self-signing is unavailable by Apple platform design.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .tint(LifeOSTokens.accent)
        .animation(reduceMotion ? nil : LifeOSMotion.ease, value: signing.state)
    }

    private var signingLabel: String {
        guard let days = signing.daysRemaining else { return "Signing expiration unavailable" }
        return signing.state == .expired ? "Signing expired" : "Signing: \(days) day\(days == 1 ? "" : "s") remaining"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(LifeOSTokens.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lifeOSCard()
        .accessibilityElement(children: .contain)
    }
}
