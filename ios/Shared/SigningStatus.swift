import Foundation

public enum ProvisioningMode: String, Codable, Equatable, Sendable {
    case personalTeam = "personal_team"
    case developerProgram = "developer_program"
    case sideloaded
    case unknown
}

public enum SigningState: String, Codable, Equatable, Sendable {
    case valid
    case expiringSoon = "expiring_soon"
    case expired
    case unknown
}

public struct SigningStatus: Equatable, Sendable {
    public let mode: ProvisioningMode
    public let expirationDate: Date?
    public let now: Date

    public init(mode: ProvisioningMode, expirationDate: Date?, now: Date = .now) {
        self.mode = mode
        self.expirationDate = expirationDate
        self.now = now
    }

    public var state: SigningState {
        guard let expirationDate else { return .unknown }
        guard expirationDate > now else { return .expired }
        return expirationDate.timeIntervalSince(now) <= 3 * 86_400 ? .expiringSoon : .valid
    }

    public var daysRemaining: Int? {
        guard let expirationDate else { return nil }
        return max(0, Int(ceil(expirationDate.timeIntervalSince(now) / 86_400)))
    }

    /// iOS does not allow an installed app to replace its own code signature.
    public var canSelfRenew: Bool { false }

    public var guidance: String {
        switch mode {
        case .personalTeam:
            return "Personal Team installs expire after Apple’s provisioning period. Rebuild and reinstall with Xcode before expiration."
        case .sideloaded:
            return "Refresh through the sideloading service that installed this app before its signing period expires."
        case .developerProgram:
            return "Signing is managed by the selected developer profile; the app cannot renew its own code signature."
        case .unknown:
            return "Signing expiration is unavailable in this build. The app cannot renew its own code signature."
        }
    }

    public static func current(bundle: Bundle = .main, now: Date = .now) -> SigningStatus {
        let mode = (bundle.object(forInfoDictionaryKey: "PROVISIONING_MODE") as? String)
            .flatMap(ProvisioningMode.init(rawValue:)) ?? .unknown

        if let date = bundle.object(forInfoDictionaryKey: "PROVISIONING_EXPIRATION_DATE") as? Date {
            return SigningStatus(mode: mode, expirationDate: date, now: now)
        }
        if let value = bundle.object(forInfoDictionaryKey: "PROVISIONING_EXPIRATION_DATE") as? String {
            let formatter = ISO8601DateFormatter()
            return SigningStatus(mode: mode, expirationDate: formatter.date(from: value), now: now)
        }
        return SigningStatus(mode: mode, expirationDate: nil, now: now)
    }
}
