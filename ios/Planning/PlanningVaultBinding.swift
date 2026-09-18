import Foundation

public enum PlanningSymlinkPolicy: String, Codable, Equatable, Sendable {
    case rejectUnknown
}

public struct PlanningVaultBinding: Codable, Equatable, Sendable {
    public let vaultRelativePath: PlanningRelativePath
    public let lifeOSSubfolder: PlanningRelativePath
    public let symlinkPolicy: PlanningSymlinkPolicy

    public init(
        vaultRelativePath: String,
        lifeOSSubfolder: String = "LifeOS",
        symlinkPolicy: PlanningSymlinkPolicy = .rejectUnknown
    ) throws {
        guard symlinkPolicy == .rejectUnknown else {
            throw PlanningValidationError.unsupportedSymlinkPolicy
        }
        let vaultPath = try PlanningRelativePath(vaultRelativePath)
        guard !vaultPath.segments.contains(where: { $0.caseInsensitiveCompare("uni") == .orderedSame }) else {
            throw PlanningValidationError.invalidBinding
        }
        let folderPath = try PlanningRelativePath(lifeOSSubfolder)
        let combined = vaultPath.value + "/" + folderPath.value
        _ = try PlanningRelativePath(combined)
        self.vaultRelativePath = vaultPath
        self.lifeOSSubfolder = folderPath
        self.symlinkPolicy = symlinkPolicy
    }

    public var canonicalLifeOSRelativePath: String {
        vaultRelativePath.value + "/" + lifeOSSubfolder.value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: PlanningAnyCodingKey.self)
        let vault = try container.decode(String.self, forKey: planningCodingKey("vaultRelativePath"))
        let subfolder = try container.decode(String.self, forKey: planningCodingKey("lifeOSSubfolder"))
        let policy = try container.decode(PlanningSymlinkPolicy.self, forKey: planningCodingKey("symlinkPolicy"))
        try self.init(vaultRelativePath: vault, lifeOSSubfolder: subfolder, symlinkPolicy: policy)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: PlanningAnyCodingKey.self)
        try container.encode(vaultRelativePath.value, forKey: planningCodingKey("vaultRelativePath"))
        try container.encode(lifeOSSubfolder.value, forKey: planningCodingKey("lifeOSSubfolder"))
        try container.encode(symlinkPolicy, forKey: planningCodingKey("symlinkPolicy"))
    }
}
