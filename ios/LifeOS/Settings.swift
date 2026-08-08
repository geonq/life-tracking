import SwiftUI

struct SettingsView: View {
    private let signing = SigningStatus.current()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(TailscaleSyncClient.serverURLDefaultsKey) private var syncServerURL = ""
    @AppStorage(TailscaleSyncClient.tokenDefaultsKey) private var syncToken = ""
    @AppStorage("LifeOS.Sync.LastSuccess") private var lastSyncTimestamp: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
#if os(macOS)
                Text("Settings")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
#endif

                SettingsSection(title: "Privacy", icon: .security) {
                    HStack(spacing: 8) {
                        LifeOSIcon(.verified).frame(width: 16, height: 16)
                        Text("Native iOS + macOS foundation · Demo usage data")
                    }
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Calendar items are stored locally. HealthKit, Clipper, Finance, connectors, and voice capture are not implemented.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Tailscale Sync", icon: .security) {
                    HStack(spacing: 8) {
                        LifeOSIcon(.security).frame(width: 16, height: 16)
                        Text("Sync calendar and tax documents over your Tailscale network")
                    }
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Server URL (e.g. https://lifeos-server.example.ts.net)", text: $syncServerURL)
                            .textFieldStyle(.roundedBorder)
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
#endif
                            .autocorrectionDisabled()
                        SecureField("Auth token", text: $syncToken)
                            .textFieldStyle(.roundedBorder)
                            .autocorrectionDisabled()
                    }
                    Text(syncStatusLabel)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Signing", icon: signing.state == .expired ? .warning : .verified) {
                    HStack(spacing: 8) {
                        LifeOSIcon(signing.state == .expired ? .warning : .verified).frame(width: 16, height: 16)
                        Text(signingLabel)
                    }
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

    private var syncStatusLabel: String {
        let serverConfigured = !syncServerURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let tokenConfigured = !syncToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard serverConfigured, tokenConfigured else { return "Not configured" }
        guard lastSyncTimestamp > 0 else { return "Configured · not yet synced" }
        let date = Date(timeIntervalSince1970: lastSyncTimestamp)
        return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    }

    private var signingLabel: String {
        guard let days = signing.daysRemaining else { return "Signing expiration unavailable" }
        return signing.state == .expired ? "Signing expired" : "Signing: \(days) day\(days == 1 ? "" : "s") remaining"
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: LifeOSIconName
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: LifeOSTokens.spacing) {
            HStack(spacing: 8) {
                LifeOSIcon(icon).frame(width: 18, height: 18)
                Text(title)
            }
                .font(.headline)
                .foregroundStyle(LifeOSTokens.accent)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lifeOSCard()
        .accessibilityElement(children: .contain)
    }
}
