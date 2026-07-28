import SwiftUI

struct SettingsView: View {
    private let signing = SigningStatus.current()

    var body: some View {
        Form {
            Section("Privacy") {
                Label("Native iOS + macOS foundation · Demo usage data", systemImage: "lock.shield")
                    .accessibilityLabel("Privacy status: native iOS and macOS foundation, Demo usage data")
                Text("Calendar items are stored locally. HealthKit, Clipper, Finance, connectors, and voice capture are not implemented.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Signing") {
                Label(signingLabel, systemImage: signing.state == .expired ? "exclamationmark.triangle" : "checkmark.shield")
                Text(signing.guidance)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Text("Automatic self-signing is unavailable by Apple platform design.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }

    private var signingLabel: String {
        guard let days = signing.daysRemaining else { return "Signing expiration unavailable" }
        return signing.state == .expired ? "Signing expired" : "Signing: \(days) day\(days == 1 ? "" : "s") remaining"
    }
}
