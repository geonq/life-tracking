import SwiftUI

struct SettingsView: View {
    var body: some View {
        Form {
            Section("Privacy") {
                Label("Native iOS foundation · Demo data only", systemImage: "lock.shield")
                    .accessibilityLabel("Privacy status: native iOS foundation, Demo data only")
                Text("HealthKit, Clipper, Finance, connectors, voice capture, and real data are not implemented.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
    }
}
