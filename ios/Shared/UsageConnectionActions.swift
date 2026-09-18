import Foundation

/// Closed destinations for Usage actions. The app can open only one of these
/// reviewed HTTPS destinations; no source payload or user supplied URL is ever
/// passed to the browser.
public enum UsageConnectionDestination: String, CaseIterable, Hashable, Sendable {
    case gemini = "https://gemini.google.com/"
    case geminiHelp = "https://support.google.com/gemini/"
    case aiStudio = "https://aistudio.google.com/"
    case claude = "https://claude.ai/"

    public var url: URL? { URL(string: rawValue) }
}

public enum UsageConnectionActionKind: String, CaseIterable, Hashable, Sendable {
    case addManualReading = "add_manual_reading"
    case openGemini = "open_gemini"
    case openGeminiHelp = "open_gemini_help"
    case openAIStudio = "open_ai_studio"
    case openClaude = "open_claude"
}

public struct UsageConnectionAction: Identifiable, Equatable, Hashable, Sendable {
    public let connectionID: UsageConnectionID
    public let providerID: UsageProviderID
    public let kind: UsageConnectionActionKind
    public let title: String
    public let detail: String
    public let destination: UsageConnectionDestination?

    public var id: String { "\(connectionID.rawValue).\(kind.rawValue)" }
    public var isManualEntry: Bool { kind == .addManualReading }

    init(
        connectionID: UsageConnectionID,
        providerID: UsageProviderID,
        kind: UsageConnectionActionKind,
        title: String,
        detail: String,
        destination: UsageConnectionDestination? = nil
    ) {
        self.connectionID = connectionID
        self.providerID = providerID
        self.kind = kind
        self.title = title
        self.detail = detail
        self.destination = destination
    }
}

/// Resolves actions from the closed reviewed catalog metadata and current
/// connection state. Adapter IDs are policy keys only; they never name
/// executable code or carry a URL.
public enum UsageConnectionActionResolver {
    public static func actions(
        for connection: UsageRegistryConnection,
        descriptor: UsageProviderDescriptor?
    ) -> [UsageConnectionAction] {
        guard connection.enabled,
              let descriptor,
              descriptor.id == connection.providerID,
              UsageProviderCatalog.descriptor(for: descriptor.id) == descriptor else {
            return []
        }

        let capabilities = Set(descriptor.capabilities)
        switch descriptor.adapterID {
        case UsageManualReading.supportedAdapterID:
            guard descriptor.id.rawValue == UsageManualReading.supportedProviderID,
                  capabilities.contains(.manualEntry),
                  connection.authState != .revoked else { return [] }
            return [
                UsageConnectionAction(
                    connectionID: connection.connectionID,
                    providerID: connection.providerID,
                    kind: .addManualReading,
                    title: "Add reading",
                    detail: "Record the 5-hour and weekly values shown by Gemini."
                ),
                UsageConnectionAction(
                    connectionID: connection.connectionID,
                    providerID: connection.providerID,
                    kind: .openGemini,
                    title: "Open Gemini",
                    detail: "Open the official Gemini page.",
                    destination: .gemini
                ),
                UsageConnectionAction(
                    connectionID: connection.connectionID,
                    providerID: connection.providerID,
                    kind: .openGeminiHelp,
                    title: "Open Gemini help",
                    detail: "Open Google's official Gemini help.",
                    destination: .geminiHelp
                )
            ]
        case "gemini_api_meter":
            guard descriptor.id.rawValue == "gemini_api",
                  capabilities.contains(.localMetering) else { return [] }
            return [
                UsageConnectionAction(
                    connectionID: connection.connectionID,
                    providerID: connection.providerID,
                    kind: .openAIStudio,
                    title: "Open AI Studio",
                    detail: "Review Gemini API project usage in the official dashboard.",
                    destination: .aiStudio
                )
            ]
        case "claude_statusline":
            guard descriptor.id.rawValue == "claude",
                  capabilities.contains(.officialQuota) else { return [] }
            return [
                UsageConnectionAction(
                    connectionID: connection.connectionID,
                    providerID: connection.providerID,
                    kind: .openClaude,
                    title: "Open Claude",
                    detail: "Open the official Claude account page.",
                    destination: .claude
                )
            ]
        default:
            return []
        }
    }
}
