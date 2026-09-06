import Foundation

// MARK: - Durable local storage for tracking preferences, with a save/cancel draft

/// Stable, user-visible failures for the local Finance tracking preferences
/// store. Mirrors `FinanceBudgetStoreError`.
public enum FinanceTrackingPreferencesStoreError: Error, Equatable, Sendable {
    case applicationSupportUnavailable
    case readFailed
    case invalidEnvelope
    case writeFailed
    case invalidAnchorDate
    case invalidCustomDayOfMonth
    case noDraftToCommit
}

extension FinanceTrackingPreferencesStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "Local Finance tracking preferences storage is unavailable."
        case .readFailed:
            return "Local Finance tracking preferences storage could not be read."
        case .invalidEnvelope:
            return "Local Finance tracking preferences storage is invalid and was not loaded."
        case .writeFailed:
            return "Tracking preference changes could not be saved."
        case .invalidAnchorDate:
            return "The tracking cycle anchor date is invalid."
        case .invalidCustomDayOfMonth:
            return "A custom tracking frequency needs a day of month from 1 to 31."
        case .noDraftToCommit:
            return "There is no draft tracking preference to save."
        }
    }

    fileprivate init(_ validationError: FinanceTrackingPreferencesValidationError) {
        switch validationError {
        case .invalidAnchorDate: self = .invalidAnchorDate
        case .invalidCustomDayOfMonth: self = .invalidCustomDayOfMonth
        }
    }
}

/// Versioned on-disk envelope. Both `committed` and `draft` are optional and
/// independent: an absent file, or a file with neither field, decodes to an
/// honest "never configured, no draft in progress" state rather than an
/// error. A present `draft` never overwrites `committed` on load — only
/// `commitDraft()` does that, and only when explicitly called.
public struct FinanceTrackingPreferencesEnvelope: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let committed: FinanceTrackingPreferences?
    public let draft: FinanceTrackingPreferences?

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, committed, draft
    }

    public init(committed: FinanceTrackingPreferences? = nil, draft: FinanceTrackingPreferences? = nil) {
        self.schemaVersion = Self.currentSchemaVersion
        self.committed = committed
        self.draft = draft
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        committed = try container.decodeIfPresent(FinanceTrackingPreferences.self, forKey: .committed)
        draft = try container.decodeIfPresent(FinanceTrackingPreferences.self, forKey: .draft)
    }
}

/// Atomic, Application-Support-backed local storage for the durable
/// income/expense tracking cadence preference, plus a non-destructive draft
/// so a UI can implement explicit save/cancel: `saveDraft` persists an
/// in-progress edit without touching the committed value; `commitDraft`
/// promotes that draft to committed (an explicit "Save"); `discardDraft`
/// clears it without changing what is committed (an explicit "Cancel").
///
/// Structurally mirrors `FinanceBudgetStore`: an in-process transaction lock
/// guards read-modify-write cycles, writes go through a temp file plus
/// `replaceItemAt`/`moveItem`, and iOS writes request
/// `.completeFileProtection`. The URL is injectable only for deterministic
/// tests; the default path has no temporary-directory or home-directory
/// fallback — if Application Support cannot be resolved, initialization
/// fails closed.
public final class FinanceTrackingPreferencesStore: @unchecked Sendable {
    public static let fileName = "finance-tracking-preferences.json"
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
            throw FinanceTrackingPreferencesStoreError.applicationSupportUnavailable
        }
        return support
            .appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent(fileName, isDirectory: false)
    }

    /// The committed preference. `nil` means "never configured" — an
    /// honest empty state, never a fabricated default cadence.
    public func current() throws -> FinanceTrackingPreferences? {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked().committed
    }

    /// The in-progress draft, if any. `nil` means no edit is in progress.
    public func draft() throws -> FinanceTrackingPreferences? {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        return try loadUnlocked().draft
    }

    /// Persists `preferences` as the draft without touching the committed
    /// value. Validates first; an invalid draft is never persisted, so a
    /// subsequent `commitDraft()` can never promote an invalid value.
    public func saveDraft(_ preferences: FinanceTrackingPreferences) throws {
        if let validationError = preferences.validationError {
            throw FinanceTrackingPreferencesStoreError(validationError)
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var envelope = try loadUnlocked()
        envelope = FinanceTrackingPreferencesEnvelope(committed: envelope.committed, draft: preferences)
        try saveUnlocked(envelope)
    }

    /// Promotes the current draft to committed and clears the draft. Throws
    /// `.noDraftToCommit` if there is nothing to save — this is the
    /// explicit "Save" action, and it is a no-op-that-throws rather than a
    /// silent success when there is no pending edit.
    @discardableResult
    public func commitDraft() throws -> FinanceTrackingPreferences {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var envelope = try loadUnlocked()
        guard let draft = envelope.draft else {
            throw FinanceTrackingPreferencesStoreError.noDraftToCommit
        }
        envelope = FinanceTrackingPreferencesEnvelope(committed: draft, draft: nil)
        try saveUnlocked(envelope)
        return draft
    }

    /// Discards the draft, leaving the committed value untouched. This is
    /// the explicit "Cancel" action; safe to call with no draft pending.
    public func discardDraft() throws {
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        var envelope = try loadUnlocked()
        guard envelope.draft != nil else { return }
        envelope = FinanceTrackingPreferencesEnvelope(committed: envelope.committed, draft: nil)
        try saveUnlocked(envelope)
    }

    /// Commits `preferences` directly, bypassing the draft, and clears any
    /// pending draft. For flows with no separate edit step.
    @discardableResult
    public func commit(_ preferences: FinanceTrackingPreferences) throws -> FinanceTrackingPreferences {
        if let validationError = preferences.validationError {
            throw FinanceTrackingPreferencesStoreError(validationError)
        }
        Self.processTransactionLock.lock()
        defer { Self.processTransactionLock.unlock() }
        let envelope = FinanceTrackingPreferencesEnvelope(committed: preferences, draft: nil)
        try saveUnlocked(envelope)
        return preferences
    }

    private func loadUnlocked() throws -> FinanceTrackingPreferencesEnvelope {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return FinanceTrackingPreferencesEnvelope()
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw FinanceTrackingPreferencesStoreError.readFailed
        }
        do {
            let envelope = try JSONDecoder.financeTrackingPreferences.decode(FinanceTrackingPreferencesEnvelope.self, from: data)
            guard envelope.schemaVersion == FinanceTrackingPreferencesEnvelope.currentSchemaVersion else {
                throw FinanceTrackingPreferencesStoreError.invalidEnvelope
            }
            guard envelope.committed?.validationError == nil, envelope.draft?.validationError == nil else {
                throw FinanceTrackingPreferencesStoreError.invalidEnvelope
            }
            return envelope
        } catch {
            throw FinanceTrackingPreferencesStoreError.invalidEnvelope
        }
    }

    private func saveUnlocked(_ envelope: FinanceTrackingPreferencesEnvelope) throws {
        let data: Data
        do {
            data = try JSONEncoder.financeTrackingPreferences.encode(envelope)
        } catch {
            throw FinanceTrackingPreferencesStoreError.invalidEnvelope
        }
        do {
            try atomicReplace(data)
        } catch {
            throw FinanceTrackingPreferencesStoreError.writeFailed
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
    static let financeTrackingPreferences: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

private extension JSONEncoder {
    static let financeTrackingPreferences: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}
