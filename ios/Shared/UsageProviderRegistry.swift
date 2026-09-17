import Foundation

/// Validation failures at the provider-neutral Usage presentation boundary.
/// The registry is local presentation data; it never contains executable
/// commands, URLs, cookies, or credential material.
public enum UsageRegistryError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier(field: String)
    case invalidText(field: String)
    case invalidBounds(field: String)
    case duplicateIdentifier(kind: String, value: String)
    case invalidReference(kind: String, value: String)
    case invalidValue(field: String)
    case invalidPolicy(provider: String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let field): return "Invalid Usage identifier: \(field)."
        case .invalidText(let field): return "Invalid Usage text: \(field)."
        case .invalidBounds(let field): return "Usage value is outside its bounds: \(field)."
        case .duplicateIdentifier(let kind, let value): return "Duplicate Usage \(kind) identifier: \(value)."
        case .invalidReference(let kind, let value): return "Unknown Usage \(kind) reference: \(value)."
        case .invalidValue(let field): return "Invalid Usage value: \(field)."
        case .invalidPolicy(let provider): return "Usage evidence policy is not approved for \(provider)."
        }
    }
}

private enum UsageRegistryValidation {
    static let maximumIdentifierLength = 64
    static let maximumLabelLength = 80
    static let maximumReasonLength = 64
    static let maximumSourceLength = 128
    static let maximumExplanationLength = 512
    static let maximumConnections = 32
    static let maximumWindows = 512
    static let maximumObservations = 512
    static let maximumEstimates = 512
    static let maximumScopes = 512

    static func identifier(_ value: String, field: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= maximumIdentifierLength,
              value.first?.isASCII == true,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }),
              value.first?.isLetter == true || value.first?.isNumber == true else {
            throw UsageRegistryError.invalidIdentifier(field: field)
        }
        guard !value.contains(where: { $0.isUppercase || $0.isWhitespace || $0.isNewline }) else {
            throw UsageRegistryError.invalidIdentifier(field: field)
        }
        return value
    }

    static func text(_ value: String, field: String, maximum: Int) throws -> String {
        guard !value.isEmpty,
              value.count <= maximum,
              value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.contains(where: { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 || $0 == 0x7f } ?? false) }) else {
            throw UsageRegistryError.invalidText(field: field)
        }
        return value
    }

    static func safeOptionalText(_ value: String?, field: String, maximum: Int) throws -> String? {
        guard let value else { return nil }
        return try text(value, field: field, maximum: maximum)
    }

    static func finite(_ value: Double, field: String) throws -> Double {
        guard value.isFinite else { throw UsageRegistryError.invalidValue(field: field) }
        return value
    }
}

public struct UsageProviderID: Codable, Equatable, Hashable, Comparable, Identifiable, Sendable {
    public let rawValue: String
    public var id: String { rawValue }

    public init(_ rawValue: String) throws {
        self.rawValue = try UsageRegistryValidation.identifier(rawValue, field: "providerID")
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct UsageConnectionID: Codable, Equatable, Hashable, Comparable, Identifiable, Sendable {
    public let rawValue: String
    public var id: String { rawValue }

    public init(_ rawValue: String) throws {
        self.rawValue = try UsageRegistryValidation.identifier(rawValue, field: "connectionID")
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct UsageWindowID: Codable, Equatable, Hashable, Comparable, Identifiable, Sendable {
    public let rawValue: String
    public var id: String { rawValue }

    public init(_ rawValue: String) throws {
        self.rawValue = try UsageRegistryValidation.identifier(rawValue, field: "windowID")
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct UsageDimensionID: Codable, Equatable, Hashable, Comparable, Identifiable, Sendable {
    public let rawValue: String
    public var id: String { rawValue }

    public init(_ rawValue: String) throws {
        self.rawValue = try UsageRegistryValidation.identifier(rawValue, field: "dimension")
    }

    public init(rawValue: String) throws {
        try self.init(rawValue)
    }

    public init(from decoder: Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

public enum UsageProductKind: String, Codable, CaseIterable, Hashable, Sendable {
    case subscription
    case api
}

public enum UsageAuthKind: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case localCLI
    case collectorSecret
    case apiKey
    case oauthPKCE
}

public enum UsageCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case officialQuota
    case localMetering
    case manualEntry
}

public enum UsageAuthState: String, Codable, CaseIterable, Hashable, Sendable {
    case notRequired
    case disconnected
    case connected
    case reauthRequired
    case revoked
}

public enum UsageAvailability: String, Codable, CaseIterable, Hashable, Sendable {
    case available
    case unavailable
    case unsupported
    case disabled
}

public enum UsageEvidenceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case providerReported
    /// A validated legacy v1 observation whose source is trusted by the
    /// ingestion boundary but does not carry the reviewed official-provider
    /// guarantee used by Codex and Claude.
    case legacyValidated
    case locallyMeasured
    case manual
    case estimated

    public var displayLabel: String {
        switch self {
        case .providerReported: return "Provider reported"
        case .legacyValidated: return "Legacy validated"
        case .locallyMeasured: return "Locally measured"
        case .manual: return "Manual entry"
        case .estimated: return "Estimated"
        }
    }
}

public enum UsageObservationScope: String, Codable, CaseIterable, Hashable, Sendable {
    case account
    case project
    case localClient
}

public enum UsageResetPolicy: String, Codable, CaseIterable, Hashable, Sendable {
    case rolling
    case calendar
    case providerDefined
}

public enum UsageUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case percentage
    case counter
}

public enum UsageIconToken: String, Codable, CaseIterable, Hashable, Sendable {
    case codex
    case claude
    case gemini
    case glm
    case deepseek
    case googleAIStudio = "google_ai_studio"
    case questionmark
}

public enum UsageRegistryFreshness: String, Codable, CaseIterable, Hashable, Sendable {
    case fresh
    case aging
    case stale
    case unavailable
    case unknown

    init(_ freshness: Freshness) {
        switch freshness {
        case .fresh: self = .fresh
        case .aging: self = .aging
        case .stale: self = .stale
        case .unavailable: self = .unavailable
        }
    }
}

/// Presentation failures retain the last validated registry values while
/// making the reason for their stale or unavailable state explicit.
public enum UsageRegistryPresentationFailure: String, Codable, CaseIterable, Hashable, Sendable {
    case none
    case transport
    case invalidPayload
    case cancelled
    case restoredStaleCache
    case registryConversion

    public var label: String {
        switch self {
        case .none: return "Current"
        case .transport: return "Refresh failed"
        case .invalidPayload: return "Invalid source data"
        case .cancelled: return "Refresh cancelled"
        case .restoredStaleCache: return "Restored stale cache"
        case .registryConversion: return "Usage presentation unavailable"
        }
    }
}

public struct UsageProviderDescriptor: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UsageProviderID
    public let displayName: String
    public let productKind: UsageProductKind
    /// A bounded policy identifier only. The registry never executes it.
    public let adapterID: String
    public let authKinds: [UsageAuthKind]
    public let capabilities: [UsageCapability]
    public let iconToken: UsageIconToken

    public init(
        id: UsageProviderID,
        displayName: String,
        productKind: UsageProductKind,
        adapterID: String,
        authKinds: [UsageAuthKind],
        capabilities: [UsageCapability],
        iconToken: UsageIconToken
    ) throws {
        guard !authKinds.isEmpty, Set(authKinds).count == authKinds.count,
              (!authKinds.contains(.none) || authKinds.count == 1) else {
            throw UsageRegistryError.invalidBounds(field: "authKinds")
        }
        guard !capabilities.isEmpty, Set(capabilities).count == capabilities.count else {
            throw UsageRegistryError.invalidBounds(field: "capabilities")
        }
        self.id = id
        self.displayName = try UsageRegistryValidation.text(
            displayName, field: "displayName", maximum: UsageRegistryValidation.maximumLabelLength
        )
        self.productKind = productKind
        self.adapterID = try UsageRegistryValidation.identifier(adapterID, field: "adapterID")
        self.authKinds = authKinds
        self.capabilities = capabilities
        self.iconToken = iconToken
    }

    public var hasOfficialQuota: Bool { capabilities.contains(.officialQuota) }
}

/// The closed, reviewed catalog. New remote IDs cannot turn themselves into
/// executable adapters; adding a provider requires a source review and a new
/// descriptor here.
public enum UsageProviderCatalog {
    private static func make(
        id: String,
        displayName: String,
        productKind: UsageProductKind,
        adapterID: String,
        authKinds: [UsageAuthKind],
        capabilities: [UsageCapability],
        iconToken: UsageIconToken
    ) -> UsageProviderDescriptor {
        do {
            return try UsageProviderDescriptor(
                id: try UsageProviderID(id),
                displayName: displayName,
                productKind: productKind,
                adapterID: adapterID,
                authKinds: authKinds,
                capabilities: capabilities,
                iconToken: iconToken
            )
        } catch {
            preconditionFailure("The reviewed Usage provider catalog is invalid: \(id)")
        }
    }

    public static let reviewed: [UsageProviderDescriptor] = [
        make(
            id: "codex", displayName: "Codex", productKind: .subscription,
            adapterID: "codex_cli", authKinds: [.localCLI], capabilities: [.officialQuota], iconToken: .codex
        ),
        make(
            id: "claude", displayName: "Claude", productKind: .subscription,
            adapterID: "claude_statusline", authKinds: [.collectorSecret], capabilities: [.officialQuota], iconToken: .claude
        ),
        make(
            id: "gemini_subscription", displayName: "Gemini", productKind: .subscription,
            adapterID: "gemini_subscription_manual", authKinds: [.none], capabilities: [.manualEntry], iconToken: .gemini
        ),
        make(
            id: "gemini_api", displayName: "Gemini API", productKind: .api,
            adapterID: "gemini_api_meter", authKinds: [.apiKey], capabilities: [.localMetering, .manualEntry], iconToken: .gemini
        ),
        make(
            id: "glm", displayName: "GLM", productKind: .api,
            adapterID: "glm_manual", authKinds: [.apiKey], capabilities: [.manualEntry], iconToken: .glm
        ),
        make(
            id: "deepseek", displayName: "DeepSeek", productKind: .api,
            adapterID: "deepseek_manual", authKinds: [.apiKey], capabilities: [.manualEntry], iconToken: .deepseek
        ),
        make(
            id: "google_ai_studio", displayName: "Google AI Studio", productKind: .api,
            adapterID: "google_ai_studio_legacy", authKinds: [.apiKey], capabilities: [.manualEntry], iconToken: .googleAIStudio
        )
    ]

    public static let reviewedByID: [UsageProviderID: UsageProviderDescriptor] =
        Dictionary(uniqueKeysWithValues: reviewed.map { ($0.id, $0) })

    public static let reviewedIDs: Set<UsageProviderID> = Set(reviewed.map(\.id))

    public static func descriptor(for id: UsageProviderID) -> UsageProviderDescriptor? {
        reviewedByID[id]
    }
}

public struct UsageRegistryConnection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let connectionID: UsageConnectionID
    public let providerID: UsageProviderID
    public let label: String
    public let planLabel: String?
    public let enabled: Bool
    public let pinned: Bool
    public let sortOrder: Int
    public let authState: UsageAuthState
    public let availability: UsageAvailability
    public let freshness: UsageRegistryFreshness
    public let reasonCode: String?

    public var id: UsageConnectionID { connectionID }

    public init(
        connectionID: UsageConnectionID,
        providerID: UsageProviderID,
        label: String,
        planLabel: String? = nil,
        enabled: Bool = true,
        pinned: Bool = false,
        sortOrder: Int,
        authState: UsageAuthState,
        availability: UsageAvailability,
        freshness: UsageRegistryFreshness = .unknown,
        reasonCode: String? = nil
    ) throws {
        guard (0...999_999).contains(sortOrder) else {
            throw UsageRegistryError.invalidBounds(field: "sortOrder")
        }
        self.connectionID = connectionID
        self.providerID = providerID
        self.label = try UsageRegistryValidation.text(label, field: "connection.label", maximum: UsageRegistryValidation.maximumLabelLength)
        self.planLabel = try UsageRegistryValidation.safeOptionalText(planLabel, field: "connection.planLabel", maximum: UsageRegistryValidation.maximumLabelLength)
        self.enabled = enabled
        self.pinned = pinned
        self.sortOrder = sortOrder
        self.authState = authState
        self.availability = availability
        self.freshness = freshness
        self.reasonCode = try UsageRegistryValidation.safeOptionalText(reasonCode, field: "connection.reasonCode", maximum: UsageRegistryValidation.maximumReasonLength)
    }
}

public struct UsageRegistryWindow: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UsageWindowID
    public let label: String
    public let unit: UsageUnit
    public let durationMinutes: Int?
    public let resetPolicy: UsageResetPolicy
    public let timezone: String?
    public let dimension: UsageDimensionID?

    public init(
        id: UsageWindowID,
        label: String,
        unit: UsageUnit,
        durationMinutes: Int? = nil,
        resetPolicy: UsageResetPolicy,
        timezone: String? = nil,
        dimension: UsageDimensionID? = nil
    ) throws {
        if let durationMinutes, !(1...10_000_000).contains(durationMinutes) {
            throw UsageRegistryError.invalidBounds(field: "window.durationMinutes")
        }
        if let timezone {
            _ = try UsageRegistryValidation.text(timezone, field: "window.timezone", maximum: UsageRegistryValidation.maximumLabelLength)
        }
        self.id = id
        self.label = try UsageRegistryValidation.text(label, field: "window.label", maximum: UsageRegistryValidation.maximumLabelLength)
        self.unit = unit
        self.durationMinutes = durationMinutes
        self.resetPolicy = resetPolicy
        self.timezone = timezone
        self.dimension = dimension
    }
}

public struct UsageRegistrySelection: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let connectionID: UsageConnectionID
    public let windowID: UsageWindowID
    public let dimension: UsageDimensionID?

    public var id: String {
        "\(connectionID.rawValue)|\(windowID.rawValue)|\(dimension?.rawValue ?? "")"
    }

    public init(connectionID: UsageConnectionID, windowID: UsageWindowID, dimension: UsageDimensionID? = nil) {
        self.connectionID = connectionID
        self.windowID = windowID
        self.dimension = dimension
    }
}

public enum UsageRegistryValue: Equatable, Hashable, Sendable {
    case percentage(Double)
    case counter(used: Double, limit: Double?)

    public var unit: UsageUnit {
        switch self {
        case .percentage: return .percentage
        case .counter: return .counter
        }
    }

    public var percentage: Double? {
        guard case .percentage(let value) = self else { return nil }
        return value
    }
}

public struct UsageRegistryObservation: Equatable, Hashable, Sendable {
    public let selection: UsageRegistrySelection
    public let value: UsageRegistryValue
    public let resetAt: Date?
    public let periodStart: Date?
    public let observedAt: Date
    public let receivedAt: Date
    public let source: String
    public let evidenceKind: UsageEvidenceKind
    public let scope: UsageObservationScope
    public let official: Bool
    public let freshness: UsageRegistryFreshness

    public init(
        selection: UsageRegistrySelection,
        value: UsageRegistryValue,
        resetAt: Date? = nil,
        periodStart: Date? = nil,
        observedAt: Date,
        receivedAt: Date,
        source: String,
        evidenceKind: UsageEvidenceKind,
        scope: UsageObservationScope,
        official: Bool,
        freshness: UsageRegistryFreshness
    ) throws {
        guard observedAt.timeIntervalSinceReferenceDate.isFinite,
              receivedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw UsageRegistryError.invalidValue(field: "observation.timestamp")
        }
        switch value {
        case .percentage(let percentage):
            guard percentage.isFinite, (0...100).contains(percentage) else {
                throw UsageRegistryError.invalidBounds(field: "observation.percentage")
            }
        case .counter(let used, let limit):
            guard used.isFinite, used >= 0, limit.map({ $0.isFinite && $0 > 0 && used <= $0 }) ?? true else {
                throw UsageRegistryError.invalidBounds(field: "observation.counter")
            }
        }
        guard !(evidenceKind == .manual || evidenceKind == .legacyValidated || evidenceKind == .estimated) || !official else {
            throw UsageRegistryError.invalidPolicy(provider: selection.connectionID.rawValue)
        }
        self.selection = selection
        self.value = value
        self.resetAt = resetAt
        self.periodStart = periodStart
        self.observedAt = observedAt
        self.receivedAt = receivedAt
        self.source = try UsageRegistryValidation.text(source, field: "observation.source", maximum: UsageRegistryValidation.maximumSourceLength)
        self.evidenceKind = evidenceKind
        self.scope = scope
        self.official = official
        self.freshness = freshness
    }
}

public struct UsageRegistryEstimate: Equatable, Hashable, Sendable {
    public let selection: UsageRegistrySelection
    public let projectedPercentAtReset: Double?
    public let estimatedExhaustionAt: Date?
    public let velocityPercentPerHour: Double?
    public let confidence: String
    public let explanation: String
    public let official: Bool

    public init(
        selection: UsageRegistrySelection,
        projectedPercentAtReset: Double? = nil,
        estimatedExhaustionAt: Date? = nil,
        velocityPercentPerHour: Double? = nil,
        confidence: String,
        explanation: String,
        official: Bool = false
    ) throws {
        if let projectedPercentAtReset {
            guard projectedPercentAtReset.isFinite, (0...100).contains(projectedPercentAtReset) else {
                throw UsageRegistryError.invalidBounds(field: "estimate.projectedPercentAtReset")
            }
        }
        if let velocityPercentPerHour {
            guard velocityPercentPerHour.isFinite, velocityPercentPerHour >= 0 else {
                throw UsageRegistryError.invalidBounds(field: "estimate.velocityPercentPerHour")
            }
        }
        guard !official else { throw UsageRegistryError.invalidPolicy(provider: selection.connectionID.rawValue) }
        self.selection = selection
        self.projectedPercentAtReset = projectedPercentAtReset
        self.estimatedExhaustionAt = estimatedExhaustionAt
        self.velocityPercentPerHour = velocityPercentPerHour
        self.confidence = try UsageRegistryValidation.text(confidence, field: "estimate.confidence", maximum: UsageRegistryValidation.maximumReasonLength)
        self.explanation = try UsageRegistryValidation.text(explanation, field: "estimate.explanation", maximum: UsageRegistryValidation.maximumExplanationLength)
        self.official = false
    }
}

public struct UsageLegacyDetailReference: Equatable, Hashable, Sendable {
    public let provider: Provider
    public let sourceWindowID: String

    public init(provider: Provider, sourceWindowID: String) {
        self.provider = provider
        self.sourceWindowID = sourceWindowID
    }
}

/// The validated presentation packet for the provider registry. It is built
/// from already validated v1 data in this tranche; it is deliberately not a
/// decoder for the future v2 wire payload.
public struct UsageRegistryPresentation: Equatable, Sendable {
    public let generatedAt: Date?
    public let catalog: [UsageProviderDescriptor]
    public let connections: [UsageRegistryConnection]
    public let windowsByConnection: [UsageConnectionID: [UsageRegistryWindow]]
    public let observations: [UsageRegistryObservation]
    public let estimates: [UsageRegistryEstimate]
    public let completeScopes: Set<UsageRegistrySelection>
    public let legacyDetails: [UsageRegistrySelection: UsageLegacyDetailReference]
    public let preferences: UsageRegistryPreferencesState
    public private(set) var failure: UsageRegistryPresentationFailure

    private let observationLookup: [UsageRegistrySelection: [UsageRegistryObservation]]
    private let estimateLookup: [UsageRegistrySelection: UsageRegistryEstimate]

    public init(
        generatedAt: Date?,
        catalog: [UsageProviderDescriptor] = UsageProviderCatalog.reviewed,
        connections: [UsageRegistryConnection],
        windowsByConnection: [UsageConnectionID: [UsageRegistryWindow]],
        observations: [UsageRegistryObservation] = [],
        estimates: [UsageRegistryEstimate] = [],
        completeScopes: Set<UsageRegistrySelection> = [],
        legacyDetails: [UsageRegistrySelection: UsageLegacyDetailReference] = [:],
        preferences: UsageRegistryPreferencesState = .empty,
        failure: UsageRegistryPresentationFailure = .none
    ) throws {
        guard catalog.count == UsageProviderCatalog.reviewed.count,
              Set(catalog.map(\.id)) == UsageProviderCatalog.reviewedIDs,
              Dictionary(uniqueKeysWithValues: catalog.map { ($0.id, $0) }) == UsageProviderCatalog.reviewedByID else {
            throw UsageRegistryError.invalidPolicy(provider: "catalog")
        }
        guard connections.count <= UsageRegistryValidation.maximumConnections else {
            throw UsageRegistryError.invalidBounds(field: "connections")
        }
        guard Set(connections.map(\.connectionID)).count == connections.count else {
            throw UsageRegistryError.duplicateIdentifier(kind: "connection", value: "duplicate")
        }
        let connectionLookup = Dictionary(uniqueKeysWithValues: connections.map { ($0.connectionID, $0) })
        for connection in connections where UsageProviderCatalog.descriptor(for: connection.providerID) == nil {
            throw UsageRegistryError.invalidReference(kind: "provider", value: connection.providerID.rawValue)
        }

        let allWindows = windowsByConnection.values.flatMap { $0 }
        guard allWindows.count <= UsageRegistryValidation.maximumWindows else {
            throw UsageRegistryError.invalidBounds(field: "windows")
        }
        guard Set(allWindows.map(\.id)).count == allWindows.count else {
            throw UsageRegistryError.duplicateIdentifier(kind: "window", value: "duplicate")
        }
        for (connectionID, windows) in windowsByConnection {
            guard connectionLookup[connectionID] != nil else {
                throw UsageRegistryError.invalidReference(kind: "connection", value: connectionID.rawValue)
            }
            guard Set(windows.map(\.id)).count == windows.count else {
                throw UsageRegistryError.duplicateIdentifier(kind: "window", value: connectionID.rawValue)
            }
        }
        try preferences.validate()
        try Self.validateScopes(
            completeScopes, connections: connectionLookup, windowsByConnection: windowsByConnection,
            field: "completeScopes"
        )
        guard completeScopes.count <= UsageRegistryValidation.maximumScopes else {
            throw UsageRegistryError.invalidBounds(field: "completeScopes")
        }
        guard observations.count <= UsageRegistryValidation.maximumObservations else {
            throw UsageRegistryError.invalidBounds(field: "observations")
        }
        guard estimates.count <= UsageRegistryValidation.maximumEstimates else {
            throw UsageRegistryError.invalidBounds(field: "estimates")
        }

        var observationLookup = [UsageRegistrySelection: [UsageRegistryObservation]]()
        var observationKeys = Set<String>()
        for observation in observations {
            let window = try Self.validateScope(
                observation.selection,
                connections: connectionLookup,
                windowsByConnection: windowsByConnection,
                field: "observation"
            )
            guard observation.value.unit == window.unit else {
                throw UsageRegistryError.invalidValue(field: "observation.unit")
            }
            guard let connection = connectionLookup[observation.selection.connectionID],
                  let descriptor = UsageProviderCatalog.descriptor(for: connection.providerID) else {
                throw UsageRegistryError.invalidReference(kind: "provider", value: observation.selection.connectionID.rawValue)
            }
            guard Self.isEvidenceAllowed(observation, provider: descriptor) else {
                throw UsageRegistryError.invalidPolicy(provider: descriptor.id.rawValue)
            }
            let observationKey = "\(observation.selection.id)|\(observation.observedAt.timeIntervalSinceReferenceDate)"
            guard observationKeys.insert(observationKey).inserted else {
                throw UsageRegistryError.duplicateIdentifier(kind: "observation", value: observation.selection.id)
            }
            observationLookup[observation.selection, default: []].append(observation)
        }

        var estimateLookup = [UsageRegistrySelection: UsageRegistryEstimate]()
        for estimate in estimates {
            let window = try Self.validateScope(
                estimate.selection,
                connections: connectionLookup,
                windowsByConnection: windowsByConnection,
                field: "estimate"
            )
            guard window.unit == .percentage else {
                throw UsageRegistryError.invalidPolicy(provider: "counter-estimate")
            }
            guard estimateLookup.updateValue(estimate, forKey: estimate.selection) == nil else {
                throw UsageRegistryError.duplicateIdentifier(kind: "estimate", value: estimate.selection.id)
            }
        }

        for (selection, reference) in legacyDetails {
            let window = try Self.validateScope(
                selection,
                connections: connectionLookup,
                windowsByConnection: windowsByConnection,
                field: "legacyDetail"
            )
            guard let connection = connectionLookup[selection.connectionID],
                  connection.connectionID.rawValue.hasPrefix("legacy."),
                  connection.providerID.rawValue == reference.provider.rawValue,
                  window.id == selection.windowID else {
                throw UsageRegistryError.invalidReference(kind: "legacyDetail", value: selection.id)
            }
            let expectedWindowID: UsageWindowID
            do {
                expectedWindowID = try UsageRegistryLegacyMapping.windowID(
                    for: reference.provider,
                    sourceWindowID: reference.sourceWindowID
                )
            } catch {
                throw UsageRegistryError.invalidReference(kind: "legacyDetail", value: selection.id)
            }
            guard expectedWindowID == selection.windowID else {
                throw UsageRegistryError.invalidReference(kind: "legacyDetail", value: selection.id)
            }
        }

        self.generatedAt = generatedAt
        self.catalog = catalog.sorted { $0.id < $1.id }
        self.connections = connections.sorted { $0.connectionID < $1.connectionID }
        self.windowsByConnection = windowsByConnection.mapValues { $0.sorted { $0.id < $1.id } }
        self.observations = observations.sorted {
            if $0.selection.id != $1.selection.id { return $0.selection.id < $1.selection.id }
            return $0.observedAt < $1.observedAt
        }
        self.estimates = estimates.sorted { $0.selection.id < $1.selection.id }
        self.completeScopes = completeScopes
        self.legacyDetails = legacyDetails
        self.preferences = preferences
        self.failure = failure
        self.observationLookup = observationLookup
        self.estimateLookup = estimateLookup
    }

    public static var empty: UsageRegistryPresentation {
        do {
            return try UsageRegistryPresentation(
                generatedAt: nil,
                connections: [],
                windowsByConnection: [:]
            )
        } catch {
            preconditionFailure("The empty Usage registry must be valid")
        }
    }

    public func withFailure(_ failure: UsageRegistryPresentationFailure) -> UsageRegistryPresentation {
        var copy = self
        copy.failure = failure
        return copy
    }

    public func connection(id: UsageConnectionID?) -> UsageRegistryConnection? {
        guard let id else { return nil }
        return connections.first { $0.connectionID == id }
    }

    public func descriptor(for connection: UsageRegistryConnection) -> UsageProviderDescriptor? {
        UsageProviderCatalog.descriptor(for: connection.providerID)
    }

    public func windows(for connectionID: UsageConnectionID?) -> [UsageRegistryWindow] {
        guard let connectionID else { return [] }
        return windowsByConnection[connectionID] ?? []
    }

    public func observation(for selection: UsageRegistrySelection?) -> UsageRegistryObservation? {
        guard let selection else { return nil }
        return observationLookup[selection]?.max(by: { $0.observedAt < $1.observedAt })
    }

    public func estimate(for selection: UsageRegistrySelection?) -> UsageRegistryEstimate? {
        guard let selection else { return nil }
        return estimateLookup[selection]
    }

    public func legacyDetail(for selection: UsageRegistrySelection?) -> UsageLegacyDetailReference? {
        guard let selection else { return nil }
        return legacyDetails[selection]
    }

    /// The single pinning authority used by both Usage ordering and the
    /// management sheet. Connection metadata supplies reviewed first-run
    /// defaults until the user has explicitly saved a pinning choice.
    public var effectivePinnedConnectionIDs: Set<UsageConnectionID> {
        let defaults = Set(connections.filter(\.pinned).map(\.connectionID))
        let requested = preferences.pinningConfigured ? preferences.pinnedConnectionIDs : defaults
        let knownIDs = Set(connections.map(\.connectionID))
        return requested.intersection(knownIDs)
    }

    public func orderedConnections(includeHidden: Bool = false) -> [UsageRegistryConnection] {
        let hidden = preferences.hiddenConnectionIDs
        let order = Dictionary(uniqueKeysWithValues: preferences.orderedConnectionIDs.enumerated().map { ($1, $0) })
        let pinned = effectivePinnedConnectionIDs
        return connections
            .filter { includeHidden || !hidden.contains($0.connectionID) }
            .filter(\.enabled)
            .sorted {
                let lhsPinned = pinned.contains($0.connectionID)
                let rhsPinned = pinned.contains($1.connectionID)
                if lhsPinned != rhsPinned { return lhsPinned && !rhsPinned }
                let lhsOrder = order[$0.connectionID] ?? Int.max
                let rhsOrder = order[$1.connectionID] ?? Int.max
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                if $0.sortOrder != $1.sortOrder { return $0.sortOrder < $1.sortOrder }
                return $0.connectionID < $1.connectionID
            }
    }

    private static func validateScopes(
        _ scopes: Set<UsageRegistrySelection>,
        connections: [UsageConnectionID: UsageRegistryConnection],
        windowsByConnection: [UsageConnectionID: [UsageRegistryWindow]],
        field: String
    ) throws {
        for scope in scopes {
            _ = try validateScope(
                scope,
                connections: connections,
                windowsByConnection: windowsByConnection,
                field: field
            )
        }
    }

    private static func validateScope(
        _ scope: UsageRegistrySelection,
        connections: [UsageConnectionID: UsageRegistryConnection],
        windowsByConnection: [UsageConnectionID: [UsageRegistryWindow]],
        field: String
    ) throws -> UsageRegistryWindow {
        guard connections[scope.connectionID] != nil else {
            throw UsageRegistryError.invalidReference(kind: "connection", value: "\(field):\(scope.connectionID.rawValue)")
        }
        guard let window = windowsByConnection[scope.connectionID]?.first(where: { $0.id == scope.windowID }) else {
            throw UsageRegistryError.invalidReference(kind: "window", value: "\(field):\(scope.windowID.rawValue)")
        }
        guard scope.dimension == window.dimension else {
            throw UsageRegistryError.invalidValue(field: "\(field).dimension")
        }
        return window
    }

    private static func isEvidenceAllowed(
        _ observation: UsageRegistryObservation,
        provider: UsageProviderDescriptor
    ) -> Bool {
        switch provider.id.rawValue {
        case "codex", "claude":
            return observation.evidenceKind == .providerReported && observation.official
        case "gemini_subscription":
            return observation.evidenceKind == .manual && !observation.official
        case "gemini_api":
            return [.locallyMeasured, .manual].contains(observation.evidenceKind) && !observation.official
        case "glm", "deepseek", "google_ai_studio":
            return observation.evidenceKind == .legacyValidated && !observation.official
        default:
            return false
        }
    }
}

public extension UsageRegistryPresentation {
    var visibleConnections: [UsageRegistryConnection] { orderedConnections() }
}

public enum UsageRegistryLegacyMapping {
    public static func providerID(for provider: Provider) throws -> UsageProviderID {
        try UsageProviderID(provider.rawValue)
    }

    public static func connectionID(for provider: Provider) throws -> UsageConnectionID {
        try UsageConnectionID("legacy.\(provider.rawValue)")
    }

    public static func windowID(for provider: Provider, sourceWindowID: String) throws -> UsageWindowID {
        try UsageWindowID("legacy.\(provider.rawValue).\(sourceWindowID)")
    }
}
