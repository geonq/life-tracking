import SwiftUI

/// Settings is for infrequent setup and trust decisions. Product data views
/// stay focused; connections, credentials status, and device permissions live
/// here instead of becoming extra primary destinations.
struct SettingsView: View {
    private let categories: [SettingsCategory] = [
        .init(id: "providers", title: "AI providers", subtitle: "Codex, Claude, GLM, DeepSeek, Google AI Studio", readiness: .serverGatePending, icon: .assistant),
        .init(id: "finance", title: "Bank connections", subtitle: "Sparkasse, Revolut Personal / Business, Trade Republic, and consent", readiness: .consentRequired, icon: .bankConnections),
        .init(id: "health", title: "Health & devices", subtitle: "Helio → Zepp → Apple Health / HealthKit", readiness: .permissionRequired, icon: .health),
        .init(id: "sync", title: "Sync & storage", subtitle: "Windows authority, server URL, and local data", readiness: .identityPending, icon: .refresh),
        .init(id: "privacy", title: "Privacy & security", subtitle: "Local safeguards, signing, and unresolved server gates", readiness: .localSafeguards, icon: .security)
    ]

    var body: some View {
        ScrollView {
            LifeOSResponsiveContentContainer {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Keep setup out of the daily workflow")
                            .font(LifeOSFont.spaceGrotesk(20, weight: .bold))
                        Text("Connections and security-sensitive configuration are managed here. LifeOS stays honest about what is and is not connected.")
                            .font(LifeOSFont.inter(14))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 390, maximum: 600), spacing: 12)], spacing: 12) {
                        NavigationLink {
                            ProviderConnectionsSettingsView()
                        } label: {
                            SettingsHubCard(category: categories[0])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-providers")

                        NavigationLink {
                            FinanceConnectionsSettingsView()
                        } label: {
                            SettingsHubCard(category: categories[1])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-finance")

                        NavigationLink {
                            HealthDevicesSettingsView()
                        } label: {
                            SettingsHubCard(category: categories[2])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-health")

                        NavigationLink {
                            SyncStorageSettingsView()
                        } label: {
                            SettingsHubCard(category: categories[3])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-sync")

                        NavigationLink {
                            PrivacySecuritySettingsView()
                        } label: {
                            SettingsHubCard(category: categories[4])
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("settings-category-privacy")
                    }

                    Text("Provider keys remain on the Windows Hermes server. This app does not accept or store raw provider secrets.")
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Settings")
        .tint(LifeOSTokens.accent)
        .accessibilityIdentifier("settings-hub")
    }
}

private struct SettingsCategory: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let readiness: SettingsReadiness
    let icon: LifeOSIconName
}

private enum SettingsReadiness: Equatable {
    case serverGatePending
    case consentRequired
    case permissionRequired
    case identityPending
    case localSafeguards

    var title: String {
        switch self {
        case .serverGatePending: "Server gate pending"
        case .consentRequired: "Consent required"
        case .permissionRequired: "Permissions pending"
        case .identityPending: "Identity migration pending"
        case .localSafeguards: "Local safeguards active · server gate pending"
        }
    }

    var color: Color {
        switch self {
        case .localSafeguards, .serverGatePending, .consentRequired, .permissionRequired, .identityPending:
            LifeOSTokens.warning
        }
    }
}

private struct SettingsHubCard: View {
    let category: SettingsCategory
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isFocused: Bool
    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LifeOSTokens.accent.opacity(0.12))
                LifeOSIcon(category.icon)
                    .foregroundStyle(LifeOSTokens.accent)
                    .frame(width: 20, height: 20)
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(category.title)
                    .font(LifeOSFont.inter(14, weight: .semiBold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(category.subtitle)
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Text(category.readiness.title)
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                    .foregroundStyle(category.readiness.color)
                    .multilineTextAlignment(.leading)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            LifeOSIcon(.chevronRight)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 14, height: 14)
                .accessibilityHidden(true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .leading)
        .background(
            LinearGradient(
                colors: [LifeOSTokens.surface, LifeOSTokens.accent.opacity(isHovering || isFocused ? 0.045 : 0.018)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: LifeOSTokens.cardShape
        )
        .overlay(
            LifeOSTokens.cardShape.stroke(
                isHovering || isFocused ? LifeOSTokens.accent.opacity(0.38) : LifeOSTokens.quietBorder,
                lineWidth: isHovering || isFocused ? 1 : 0.75
            )
        )
        .contentShape(LifeOSTokens.cardShape)
        .scaleEffect(!reduceMotion && (isHovering || isFocused) ? 1.008 : 1)
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: isHovering || isFocused)
        .accessibilityValue(Text(category.readiness.title))
        .accessibilityHint(Text("Opens \(category.title) settings"))
#if os(macOS)
        .focusable(true)
        .focused($isFocused)
        .onHover { isHovering = $0 }
        .help("Open \(category.title) settings")
#endif
    }
}

private struct ProviderConnectionsSettingsView: View {
    private let providers = ["Codex", "Claude", "GLM", "DeepSeek", "Google AI Studio"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "AI & provider connections",
                    message: "Usage is read from the Windows Hermes server. This client never accepts, copies, or stores a provider key."
                )

                SettingsSection(title: "Provider status", icon: .assistant) {
                    VStack(spacing: 0) {
                        ForEach(providers, id: \.self) { provider in
                            SettingsStatusRow(
                                title: provider,
                                detail: "No client key entry · Windows source pending",
                                status: "Unavailable",
                                icon: .usage,
                                statusColor: LifeOSTokens.warning
                            )
                            if provider != providers.last {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }

                SettingsSection(title: "Usage boundary", icon: .usage) {
                    SettingsStatusRow(
                        title: "Home → Usage",
                        detail: "The single destination for provider activity and projections",
                        status: "When synced",
                        icon: .overview,
                        statusColor: LifeOSTokens.tertiaryText
                    )
                }

                TruthfulSetupNote(text: "Provider setup is unavailable until the secure Windows server and required security gates pass. There is intentionally no paste, reveal, or copy path for raw keys.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("AI & Providers")
    }
}

private struct FinanceConnectionsSettingsView: View {
    private let connections = ["Sparkasse", "Revolut Personal", "Revolut Business", "Trade Republic"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Bank & finance connections",
                    message: "Connectors are disabled by default. Explicit consent and the reviewed Windows gateway are required before account observations can appear."
                )

                SettingsSection(title: "Connection catalog", icon: .bankConnections) {
                    VStack(spacing: 0) {
                        ForEach(connections, id: \.self) { connection in
                            SettingsStatusRow(
                                title: connection,
                                detail: "Consent + reviewed Windows connector required",
                                status: "Unavailable",
                                icon: .finance,
                                statusColor: LifeOSTokens.warning
                            )
                            if connection != connections.last {
                                Divider().padding(.leading, 38)
                            }
                        }
                    }
                }

                TruthfulSetupNote(text: "Secrets stay on the Windows server; LifeOS does not request, enter, or store bank credentials on this device. No bank transaction data is fabricated while connectors are unavailable.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Bank & Finance")
    }
}

private struct HealthDevicesSettingsView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Health & devices",
                    message: "Health data follows one supported source chain so every metric keeps its device provenance."
                )

                SettingsSection(title: "Supported source chain", icon: .health) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Helio Strap  →  Zepp  →  Apple Health / HealthKit")
                            .font(LifeOSFont.inter(15, weight: .semiBold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Helio Strap is the measuring device. Zepp and HealthKit provide transport and permissions; neither is presented as the sensor.")
                            .font(LifeOSFont.inter(13))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            LifeOSIcon(.warning)
                                .foregroundStyle(LifeOSTokens.warning)
                                .frame(width: 16, height: 16)
                            Text("Not connected")
                                .font(LifeOSFont.inter(13, weight: .semiBold))
                                .foregroundStyle(LifeOSTokens.warning)
                        }
                    }
                }

                SettingsSection(title: "Permission checkpoints", icon: .health) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Helio Strap",
                            detail: "Primary sensor pairing is not available in this build",
                            status: "Unavailable",
                            icon: .health,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Zepp",
                            detail: "Transport/source permission is not available in this build",
                            status: "Unavailable",
                            icon: .refresh,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Apple Health / HealthKit",
                            detail: "Read permissions have not been requested",
                            status: "Permission needed",
                            icon: .health,
                            statusColor: LifeOSTokens.warning
                        )
                    }
                }

                TruthfulSetupNote(text: "Device setup is unavailable until the reviewed source, permission, and security gates pass. Demo fitness values remain explicitly labeled and are not sensor readings.")
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Health & Devices")
    }
}

private struct SyncStorageSettingsView: View {
    private let syncClient = TailscaleSyncClient()
    @AppStorage(TailscaleSyncClient.serverURLDefaultsKey) private var syncServerURL = ""
    @AppStorage("LifeOS.Sync.LastSuccess") private var lastSyncTimestamp: Double = 0
    @State private var syncIsConfigured = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Sync & storage",
                    message: "Keep the existing Tailscale server configuration reachable while making its trust boundary clear."
                )

                SettingsSection(title: "Tailscale sync", icon: .security) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Server URL (e.g. https://lifeos-server.example.ts.net)", text: $syncServerURL)
                            .textFieldStyle(.roundedBorder)
#if os(iOS)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
#endif
                            .autocorrectionDisabled()
                        Text("Transitional bearer is read-only from Keychain; identity migration is pending. LifeOS exposes no token editor.")
                            .font(LifeOSFont.inter(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(syncStatusLabel)
                            .font(LifeOSFont.inter(12, weight: .semiBold))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }

                SettingsSection(title: "Trust state", icon: .refresh) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Windows server",
                            detail: "Authoritative store; secure deployment gate is still pending",
                            status: "Pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Device identity",
                            detail: "Transitional read-only bearer remains in Keychain",
                            status: "Migration pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Local records",
                            detail: "Remain local until an authenticated sync path succeeds",
                            status: "Local first",
                            icon: .documents,
                            statusColor: LifeOSTokens.success
                        )
                    }
                }

                SettingsSection(title: "Local storage", icon: .documents) {
                    Text("Calendar, tax documents, and app preferences remain on this device unless an explicitly configured, authenticated sync path is available.")
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Sync & Storage")
        .task(id: syncServerURL) {
            syncIsConfigured = await syncClient.isConfigured
        }
    }

    private var syncStatusLabel: String {
        guard syncIsConfigured else { return "Not configured" }
        guard lastSyncTimestamp > 0 else { return "Configured · not yet synced" }
        let date = Date(timeIntervalSince1970: lastSyncTimestamp)
        return "Last synced \(date.formatted(date: .abbreviated, time: .shortened))"
    }
}

private struct PrivacySecuritySettingsView: View {
    private let signing = SigningStatus.current()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SettingsIntro(
                    title: "Privacy, security & signing",
                    message: "These controls explain where data lives and whether this build can be trusted."
                )

                SettingsSection(title: "Privacy & security", icon: .security) {
                    VStack(spacing: 0) {
                        SettingsStatusRow(
                            title: "Local safeguards",
                            detail: "Protected local storage is used where the feature supports it",
                            status: "Active",
                            icon: .verified,
                            statusColor: LifeOSTokens.success
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Windows server gate",
                            detail: "BitLocker and identity migration are not yet verified",
                            status: "Pending",
                            icon: .security,
                            statusColor: LifeOSTokens.warning
                        )
                        Divider().padding(.leading, 38)
                        SettingsStatusRow(
                            title: "Raw secrets",
                            detail: "No provider or bank key entry, reveal, or copy path in this client",
                            status: "Blocked",
                            icon: .verified,
                            statusColor: LifeOSTokens.success
                        )
                    }
                }

                TruthfulSetupNote(text: "Local safeguards do not certify the remote server. Do not connect provider or bank accounts until the Windows deployment, disk-encryption, and device-identity gates have been reviewed.")

                SettingsSection(title: "Data boundary", icon: .documents) {
                    Text("Calendar items and local-first nutrition records stay on this device until an explicitly configured, authenticated sync path succeeds. Finance, Fitness, and Usage remain unavailable when their reviewed sources are not connected.")
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsSection(title: "Signing", icon: signingIcon) {
                    HStack(spacing: 8) {
                        LifeOSIcon(signingIcon).frame(width: 16, height: 16)
                        Text(signingLabel)
                    }
                    .font(LifeOSFont.inter(13, weight: .semiBold))
                    .foregroundStyle(signingColor)
                    .fixedSize(horizontal: false, vertical: true)
                    Text(signing.guidance)
                        .font(LifeOSFont.inter(13))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Automatic self-signing is unavailable by Apple platform design.")
                        .font(LifeOSFont.inter(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(LifeOSTokens.pagePadding)
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .navigationTitle("Privacy & Security")
    }

    private var signingLabel: String {
        guard let days = signing.daysRemaining else { return "Signing expiration unavailable" }
        switch signing.state {
        case .expired:
            return "Signing expired"
        case .expiringSoon:
            return "Signing expiring: \(days) day\(days == 1 ? "" : "s") remaining"
        case .valid:
            return "Signing: \(days) day\(days == 1 ? "" : "s") remaining"
        case .unknown:
            return "Signing expiration unavailable"
        }
    }

    private var signingIcon: LifeOSIconName {
        if signing.state == .expired { return .warning }
        if signing.state == .valid { return .verified }
        return .security
    }

    private var signingColor: Color {
        switch signing.state {
        case .expired: LifeOSTokens.danger
        case .expiringSoon, .unknown: LifeOSTokens.warning
        case .valid: LifeOSTokens.success
        }
    }
}

private struct SettingsIntro: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LifeOSFont.spaceGrotesk(22, weight: .bold))
            Text(message)
                .font(LifeOSFont.inter(14))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsStatusRow: View {
    let title: String
    let detail: String
    let status: String
    let icon: LifeOSIconName
    let statusColor: Color

    var body: some View {
        HStack(spacing: 10) {
            LifeOSIcon(icon)
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(LifeOSFont.inter(14, weight: .semiBold))
                Text(detail)
                    .font(LifeOSFont.inter(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(status)
                .font(LifeOSFont.inter(11, weight: .semiBold))
                .foregroundStyle(statusColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings-status-\(accessibilityID)")
        .accessibilityValue(Text("\(status). \(detail)"))
    }

    private var accessibilityID: String {
        title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "→", with: "-")
    }
}

private struct TruthfulSetupNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            LifeOSIcon(.warning)
                .foregroundStyle(LifeOSTokens.warning)
                .frame(width: 16, height: 16)
            Text(text)
                .font(LifeOSFont.inter(12))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.warning.opacity(0.07), in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.warning.opacity(0.24), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    let icon: LifeOSIconName
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                LifeOSIcon(icon).frame(width: 18, height: 18)
                Text(title)
            }
            .font(LifeOSFont.inter(15, weight: .semiBold))
            .foregroundStyle(LifeOSTokens.accent)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LifeOSTokens.surface, in: LifeOSTokens.cardShape)
        .overlay(LifeOSTokens.cardShape.stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .contain)
    }
}
