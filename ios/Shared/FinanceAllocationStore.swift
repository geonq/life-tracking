import Foundation

// MARK: - Durable local storage for income allocation rules

/// Stable, user-visible failures for the local Finance allocation store.
/// Mirrors `FinanceBudgetStoreError`: no filesystem paths or decoder details
/// leak into the public error surface.
public enum FinanceAllocationStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
    case invalidLabel
    case invalidBucket
    case invalidShare
    case percentageTotalExceeds100
    case duplicateRuleID
    case ruleNotFound
}

extension FinanceAllocationStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local Finance allocation storage is unavailable."
        case .readFailed:
            return "Local Finance allocation storage could not be read."
        case .invalidEnvelope:
            return "Local Finance allocation storage is invalid and was not loaded."
        case .writeFailed:
            return "Allocation rule changes could not be saved."
        case .invalidLabel:
            return "An allocation rule needs a non-empty label."
        case .invalidBucket:
            return "An allocation rule needs a non-empty bucket."
        case .invalidShare:
            return "An allocation share must be a percentage from 1 to 100, or a positive fixed amount."
        case .percentageTotalExceeds100:
            return "Allocation rule percentages cannot add up to more than 100%."
        case .duplicateRuleID:
            return "Allocation rules cannot share an identifier."
        case .ruleNotFound:
            return "That allocation rule no longer exists."
        }
    }

    fileprivate init(_ ruleSetError: FinanceAllocationRuleSetError) {
        switch ruleSetError {
        case .invalidLabel: self = .invalidLabel
        case .invalidBucket: self = .invalidBucket
        case .invalidShare: self = .invalidShare
        case .percentageTotalExceeds100: self = .percentageTotalExceeds100
        case .duplicateRuleID: self = .duplicateRuleID
        }
    }
}

/// Versioned on-disk envelope. An absent file decodes to an honest empty
/// state (no rules), not an error. Mirrors `FinanceBudgetStoreEnvelope`.
public struct FinanceAllocationStoreEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let rules: [FinanceAllocationRule]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, rules
    }

    public init(rules: [FinanceAllocationRule] = []) {
        self.schemaVersion = Self.currentSchemaVersion
        self.rules = rules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        rules = try container.decodeIfPresent([FinanceAllocationRule].self, forKey: .rules) ?? []
    }
}

/// Atomic, Application-Support-backed local storage for user-managed income
/// allocation rules. CRUD over an ordered list: the array order returned by
/// `list()`/`load()` is the "rule order" `FinanceAllocationEngine.preview`
/// uses as its remainder tie-break, so `create` appends and `update` replaces
/// in place — neither operation reorders existing rules.
///
/// Structurally mirrors `FinanceBudgetStore`: an in-process transaction lock
/// guards read-modify-write cycles, writes go through a temp file plus
/// `replaceItemAt`/`moveItem`, and iOS writes request
/// `.completeFileProtection`. The URL is injectable only for deterministic
/// tests; the default path has no temporary-directory or home-directory
/// fallback — if Application Support cannot be resolved, initialization
/// fails closed.
public final class FinanceAllocationStore: @unchecked Sendable {
    public static let fileName = "finance-allocation-rules.json"
    private static let processTransactionLock = NSLock()

    public let fileURL: URL
    private let fileManager: FileManager

    public init(url: URL? = nil, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        if let url {
            self.fileURL = url
        } else {
            self.fileURL = try Self.defaultURL(fileManager: fileManager)
        }
    }

    public static func defaultURL(fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw FinanceAllocationStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The full ordered rule set. Rule order is significant — see the type
    /// header — and is preserved exactly as persisted.
    public func list() throws -> [FinanceAllocationRule] {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked()
    }

    /// Appends a new rule to the end of the ordered set. Throws when the
    /// resulting set — this rule plus every existing one — would be
    /// invalid (empty label/bucket, an out-of-range share, or a percentage
    /// total over 100%); nothing is persisted in that case.
    @discardableResult
    public func create(label: String, bucket: String, share: FinanceAllocationShare) throws -> FinanceAllocationRule {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var rules = try loadUnlocked()
        let newRule = FinanceAllocationRule(label: label, bucket: bucket, share: share)
        rules.append(newRule)
        if let error = FinanceAllocationEngine.validate(rules) {
            throw FinanceAllocationStoreError(error)
        }
        try saveUnlocked(rules)
        return newRule
    }

    /// Replaces the rule with `id` in place — its position in the ordered
    /// list is unchanged — with new label/bucket/share. Throws
    /// `.ruleNotFound` if no rule with that id exists, or the same
    /// validation errors as `create` if the edited set would be invalid.
    @discardableResult
    public func update(id: UUID, label: String, bucket: String, share: FinanceAllocationShare) throws -> FinanceAllocationRule {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var rules = try loadUnlocked()
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw FinanceAllocationStoreError.ruleNotFound
        }
        let updated = FinanceAllocationRule(
            id: id,
            label: label,
            bucket: bucket,
            share: share,
            createdAt: rules[index].createdAt
        )
        rules[index] = updated
        if let error = FinanceAllocationEngine.validate(rules) {
            throw FinanceAllocationStoreError(error)
        }
        try saveUnlocked(rules)
        return updated
    }

    /// Removes the rule with `id`. Throws `.ruleNotFound` if it does not
    /// exist rather than silently no-op'ing.
    public func remove(id: UUID) throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var rules = try loadUnlocked()
        guard let index = rules.firstIndex(where: { $0.id == id }) else {
            throw FinanceAllocationStoreError.ruleNotFound
        }
        rules.remove(at: index)
        try saveUnlocked(rules)
    }

    /// The deterministic per-bucket split of `incomeCents` given the
    /// currently persisted rule set. See `FinanceAllocationEngine.preview`
    /// for the exact remainder rule.
    public func preview(incomeCents: Int) throws -> FinanceAllocationPreviewResult {
        let rules = try list()
        return FinanceAllocationEngine.preview(rules: rules, incomeCents: incomeCents)
    }

    private func loadUnlocked() throws -> [FinanceAllocationRule] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FinanceAllocationStoreError.readFailed
        }
        do {
            let envelope = try JSONDecoder.financeAllocation.decode(FinanceAllocationStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == FinanceAllocationStoreEnvelope.currentSchemaVersion else {
                throw FinanceAllocationStoreError.invalidEnvelope
            }
            guard FinanceAllocationEngine.validate(envelope.rules) == nil else {
                throw FinanceAllocationStoreError.invalidEnvelope
            }
            return envelope.rules
        } catch {
            throw FinanceAllocationStoreError.invalidEnvelope
        }
    }

    private func saveUnlocked(_ rules: [FinanceAllocationRule]) throws {
        let data: Data
        do {
            data = try JSONEncoder.financeAllocation.encode(FinanceAllocationStoreEnvelope(rules: rules))
        } catch {
            throw FinanceAllocationStoreError.invalidEnvelope
        }
        do {
            try atomicReplace(data)
        } catch {
            throw FinanceAllocationStoreError.writeFailed
        }
    }

    private func atomicReplace(_ data: Data) throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let temporary = directory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer {
            if fileManager.fileExists(atPath: temporary.path) {
                try? fileManager.removeItem(at: temporary)
            }
        }

#if os(iOS)
        try data.write(to: temporary, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: temporary, options: [.atomic])
#endif

        if fileManager.fileExists(atPath: fileURL.path) {
            _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
        } else {
            try fileManager.moveItem(at: temporary, to: fileURL)
        }
    }
}

private extension JSONDecoder {
    static let financeAllocation: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let financeAllocation: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
