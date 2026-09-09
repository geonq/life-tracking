import Foundation
import CryptoKit

// MARK: - Bounded local training domain

/// LifeOS is the primary workout tracker: local configured exercises/templates
/// and actual sets, reps, and load are canonical and editable here. Imported
/// wearable records are read-only, source-qualified snapshots; an optional
/// `importedRecordKey` link never lets either side overwrite the other.
/// The bounded ledger deliberately has no HealthKit, network, or provider
/// metadata dependency.
public enum TrainingValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case invalidRevision
    case invalidActivityKind
    case invalidText(field: String)
    case invalidTimeZone
    case invalidDate(field: String)
    case invalidTargetRepetitions
    case invalidActualRepetitions
    case invalidLoad
    case invalidSetState
    case invalidPauseInterval
    case invalidSessionStatus
    case invalidTemplateSnapshot
    case invalidImportedIdentity
    case invalidImportedActivity
    case invalidImportedSource
    case invalidImportedEnergy
    case duplicateIdentifier
    case duplicateTemplateExerciseIdentifier
    case tooManyExercises
    case tooManySets
    case tooManyPauses
    case completedSessionRequiresSet
    case invalidCompletedDuration
    case invalidCoverage

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "The local training identifier is invalid."
        case .invalidRevision: "The training revision is invalid."
        case .invalidActivityKind: "The training activity kind is invalid."
        case .invalidText(let field): "The \(field) must contain bounded, non-control text."
        case .invalidTimeZone: "The captured time zone is not a valid IANA time zone."
        case .invalidDate(let field): "The \(field) is invalid or outside the allowed clock window."
        case .invalidTargetRepetitions: "Target repetitions must be between 1 and 1,000."
        case .invalidActualRepetitions: "Completed repetitions must be between 1 and 1,000."
        case .invalidLoad: "Load must be a finite kilogram value from 0 to 1,000,000."
        case .invalidSetState: "The set completion flag and actual values are inconsistent."
        case .invalidPauseInterval: "Pause intervals must be ordered, bounded, and non-overlapping."
        case .invalidSessionStatus: "The session status and timestamps are inconsistent."
        case .invalidTemplateSnapshot: "The template snapshot is invalid."
        case .invalidImportedIdentity: "The imported workout identity is invalid."
        case .invalidImportedActivity: "The imported workout activity value is invalid."
        case .invalidImportedSource: "The imported workout source qualification is invalid."
        case .invalidImportedEnergy: "The imported workout energy value is invalid."
        case .duplicateIdentifier: "A local training identifier is duplicated."
        case .duplicateTemplateExerciseIdentifier: "A template exercise identifier is duplicated."
        case .tooManyExercises: "A session can contain at most 100 exercises."
        case .tooManySets: "An exercise can contain at most 100 sets."
        case .tooManyPauses: "A session can contain at most 256 pauses."
        case .completedSessionRequiresSet: "A finished session needs at least one completed set."
        case .invalidCompletedDuration: "A completed session must last more than 0 and at most 366 days."
        case .invalidCoverage: "The history coverage interval is invalid."
        }
    }
}

public enum TrainingDomainLimits {
    public static let maximumTitleUTF8Bytes = 400
    public static let maximumExerciseNameUTF8Bytes = 400
    public static let maximumNotesUTF8Bytes = 2_000
    public static let maximumTimeZoneUTF8Bytes = 128
    /// Imported HealthKit stable keys can contain the source identifier or all
    /// 65 UUIDs (the primary UUID plus HealthKit's 64 aliases).  The local
    /// link field uses the same bound so a valid identity is never rejected at
    /// the link boundary.
    public static let maximumImportedKeyUTF8Bytes = 4_096
    public static let maximumTemplateIdentifierUTF8Bytes = 128
    public static let maximumExercisesPerSession = 100
    public static let maximumSetsPerExercise = 100
    public static let maximumPausesPerSession = 256
    public static let maximumRepetitions = 1_000
    public static let maximumLoadKilograms = 1_000_000.0
    public static let maximumImportedSyncIdentifierUTF8Bytes = 512
    public static let maximumImportedAliases = 64
    public static let maximumImportedIdentityUTF8Bytes = 4_096
    public static let maximumImportedHistoryRecords = 50_000
    /// Bounds how many untrusted input rows the projection inspects in one
    /// refresh. This is deliberately independent from the number of accepted
    /// rows so a provider cannot make validation work grow with an unbounded
    /// tail after the accepted-record cap is reached.
    public static let maximumImportedInputInspectionRows = 65_536
    public static let maximumImportedDiagnostics = 256
    public static let maximumImportedConflictEvidence = 256
    public static let maximumConflictFingerprints = 8
    public static let maximumImportedEnergyKilocalories = 1_000_000_000.0
    public static let futureTolerance: TimeInterval = 5 * 60
    public static let maximumCompletedDuration: TimeInterval = 366 * 24 * 60 * 60
    public static let maximumCoverageInterval: TimeInterval = maximumCompletedDuration
}

public enum TrainingStoreIntegrity: String, Codable, Equatable, Sendable {
    case verified
    case unavailable
}

public enum TrainingStoreFreshness: String, Codable, Equatable, Sendable {
    case current
    case stale
}

/// An immutable view of one durable-read transaction.  `generation` is the
/// SHA-256 fingerprint of the exact bytes read from disk.  A stale snapshot is
/// diagnostic data only; callers must not treat it as a current ledger.
public struct TrainingStoreSnapshot: Equatable, Sendable {
    public let sessions: [TrainingSession]
    public let generation: String?
    public let integrity: TrainingStoreIntegrity
    public let freshness: TrainingStoreFreshness
    public let capturedAt: Date

    public init(
        sessions: [TrainingSession],
        generation: String?,
        integrity: TrainingStoreIntegrity,
        freshness: TrainingStoreFreshness,
        capturedAt: Date
    ) {
        self.sessions = sessions
        self.generation = generation
        self.integrity = integrity
        self.freshness = freshness
        self.capturedAt = capturedAt
    }
}

private enum TrainingText {
    static func normalized(_ value: String, field: String, maximumBytes: Int) throws -> String {
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TrainingValidationError.invalidText(field: field)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes else {
            throw TrainingValidationError.invalidText(field: field)
        }
        return trimmed
    }

    static func optional(_ value: String?, field: String, maximumBytes: Int) throws -> String? {
        guard let value else { return nil }
        return try normalized(value, field: field, maximumBytes: maximumBytes)
    }

    static func boundedOpaqueKey(_ value: String?, field: String, maximumBytes: Int) throws -> String? {
        guard let value else { return nil }
        return try normalized(value, field: field, maximumBytes: maximumBytes)
    }
}

private enum TrainingDates {
    static func validate(_ date: Date, field: String, now: Date, futureTolerance: TimeInterval = TrainingDomainLimits.futureTolerance) throws {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              now.timeIntervalSinceReferenceDate.isFinite,
              futureTolerance.isFinite,
              futureTolerance >= 0,
              date.timeIntervalSince(now) <= futureTolerance else {
            throw TrainingValidationError.invalidDate(field: field)
        }
    }

    static func validateOptional(_ date: Date?, field: String, now: Date) throws {
        if let date { try validate(date, field: field, now: now) }
    }
}

private struct TrainingAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownTrainingKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: TrainingAnyCodingKey.self)
    let keys = Set(container.allKeys.map(\.stringValue))
    guard keys.isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(
            codingPath: decoder.codingPath,
            debugDescription: "Unknown training field"
        ))
    }
}

private func decodeBoundedTrainingArray<Element: Decodable, Key: CodingKey>(
    _ type: Element.Type,
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>,
    maximum: Int,
    overflow: TrainingValidationError
) throws -> [Element] {
    var nested = try container.nestedUnkeyedContainer(forKey: key)
    var values: [Element] = []
    if let count = nested.count {
        values.reserveCapacity(min(count, maximum))
    }
    while !nested.isAtEnd {
        guard values.count < maximum else { throw overflow }
        values.append(try nested.decode(Element.self))
    }
    return values
}

private func trainingCorrupted(_ decoder: Decoder, _ message: String) -> DecodingError {
    DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: message))
}

/// Current training persistence and mutation fingerprints use the same
/// lossless numeric representation. JSON numbers round-trip Date precision
/// without ISO-8601's fractional-second truncation.
enum TrainingDateCoding {
    static func encodeDate(_ date: Date, to encoder: Encoder) throws {
        let seconds = date.timeIntervalSinceReferenceDate
        guard seconds.isFinite else {
            throw EncodingError.invalidValue(date, .init(
                codingPath: encoder.codingPath,
                debugDescription: "Training dates must have a finite reference-date interval"
            ))
        }
        var container = encoder.singleValueContainer()
        try container.encode(seconds)
    }

    static func decodeDate(from decoder: Decoder) throws -> Date {
        let container = try decoder.singleValueContainer()
        let seconds = try container.decode(Double.self)
        guard seconds.isFinite else {
            throw trainingCorrupted(decoder, "Training dates must have a finite reference-date interval")
        }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            try Self.encodeDate(date, to: encoder)
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func makeDecoder(now: Date) -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            try Self.decodeDate(from: decoder)
        }
        decoder.userInfo[.trainingValidationNow] = now
        return decoder
    }
}

extension CodingUserInfoKey {
    static let trainingValidationNow: CodingUserInfoKey = {
        guard let key = CodingUserInfoKey(rawValue: "lifeos.training.validationNow") else {
            preconditionFailure("The training validation coding key must be constructible")
        }
        return key
    }()
}

private extension Decoder {
    var trainingValidationNow: Date {
        (userInfo[.trainingValidationNow] as? Date) ?? Date()
    }
}

// MARK: - Identities and source qualification

/// A local identifier is encoded as the canonical lowercase UUID string.
/// Imported provider identities intentionally use the separate opaque string
/// field on a session; they never enter this local UUID namespace.
public struct TrainingRecordID: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let uuid: UUID

    public init() { self.uuid = UUID() }

    public init(uuid: UUID) { self.uuid = uuid }

    public init(rawValue: String) throws {
        guard let uuid = UUID(uuidString: rawValue),
              rawValue == uuid.uuidString.lowercased() else {
            throw TrainingValidationError.invalidIdentifier
        }
        self.uuid = uuid
    }

    public var id: String { rawValue }
    public var rawValue: String { uuid.uuidString.lowercased() }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let identifier = try? TrainingRecordID(rawValue: value) else {
            throw trainingCorrupted(decoder, "Local training IDs must be canonical lowercase UUIDs")
        }
        self = identifier
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TrainingActivityKind: String, Codable, CaseIterable, Hashable, Sendable {
    case strength
    case cardio
    case mobility
    case flexibility
    case sport
    case other
}

public enum TrainingSourceState: String, Codable, CaseIterable, Hashable, Sendable {
    case local
    case imported
    case mixed
    case partial
    case stale
    case conflict
    case unavailable
    case readIndeterminate = "read_indeterminate"
    case error
}

public enum TrainingCoverageKind: String, Codable, CaseIterable, Hashable, Sendable {
    case complete
    case partial
    case unavailable
}

public struct TrainingCoverage: Codable, Equatable, Hashable, Sendable {
    public let kind: TrainingCoverageKind
    public let lowerBound: Date?
    public let upperBound: Date?

    public init(
        kind: TrainingCoverageKind,
        lowerBound: Date? = nil,
        upperBound: Date? = nil,
        now: Date = .now
    ) throws {
        try TrainingDates.validateOptional(lowerBound, field: "coverage lower bound", now: now)
        try TrainingDates.validateOptional(upperBound, field: "coverage upper bound", now: now)
        if let lowerBound, let upperBound {
            guard upperBound >= lowerBound,
                  upperBound.timeIntervalSince(lowerBound) <= TrainingDomainLimits.maximumCoverageInterval else {
                throw TrainingValidationError.invalidCoverage
            }
        }
        if kind == .unavailable {
            guard lowerBound == nil, upperBound == nil else { throw TrainingValidationError.invalidCoverage }
        } else {
            guard lowerBound != nil || upperBound != nil else { throw TrainingValidationError.invalidCoverage }
        }
        if kind == .complete {
            guard lowerBound != nil, upperBound != nil else { throw TrainingValidationError.invalidCoverage }
        }
        self.kind = kind
        self.lowerBound = lowerBound
        self.upperBound = upperBound
    }

    /// Returns whether this record-level coverage actually contains the
    /// complete interval.  A lower-only or upper-only partial window remains
    /// useful evidence without claiming that the surrounding query is
    /// complete.
    public func contains(startedAt: Date, endedAt: Date) -> Bool {
        guard endedAt >= startedAt, kind != .unavailable else { return false }
        if let lowerBound, startedAt < lowerBound { return false }
        if let upperBound, endedAt > upperBound { return false }
        return true
    }

    private enum CodingKeys: String, CodingKey { case kind, lowerBound, upperBound }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["kind", "lowerBound", "upperBound"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingCoverage(
            kind: container.decode(TrainingCoverageKind.self, forKey: .kind),
            lowerBound: container.decodeIfPresent(Date.self, forKey: .lowerBound),
            upperBound: container.decodeIfPresent(Date.self, forKey: .upperBound),
            now: decoder.trainingValidationNow
        )
    }
}

// MARK: - Templates and set semantics

public enum TrainingLoadConvention: String, Codable, CaseIterable, Hashable, Sendable {
    case externalTotal = "external_total"
    case bodyweight
    case assisted
}

public enum TrainingMuscleGroup: String, Codable, CaseIterable, Hashable, Sendable {
    case arms
    case core
    case chest
    case back
    case legs
    case shoulders
    case other
}

public enum TrainingSetKind: String, Codable, CaseIterable, Hashable, Sendable {
    case warmup
    case working
}

public struct TrainingTemplateExerciseSnapshot: Codable, Equatable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let muscleGroup: TrainingMuscleGroup
    public let targetSets: Int
    public let targetRepetitions: Int
    public let targetLoadKilograms: Double?
    public let loadConvention: TrainingLoadConvention

    public init(
        id: String,
        name: String,
        muscleGroup: TrainingMuscleGroup,
        targetSets: Int = 3,
        targetRepetitions: Int = 8,
        targetLoadKilograms: Double? = nil,
        loadConvention: TrainingLoadConvention = .externalTotal
    ) throws {
        self.id = try TrainingText.normalized(id, field: "template exercise identifier", maximumBytes: TrainingDomainLimits.maximumTemplateIdentifierUTF8Bytes)
        guard Self.validLegacyIdentifier(self.id) else { throw TrainingValidationError.invalidTemplateSnapshot }
        self.name = try TrainingText.normalized(name, field: "exercise name", maximumBytes: TrainingDomainLimits.maximumExerciseNameUTF8Bytes)
        guard (1...TrainingDomainLimits.maximumSetsPerExercise).contains(targetSets) else { throw TrainingValidationError.tooManySets }
        guard (1...TrainingDomainLimits.maximumRepetitions).contains(targetRepetitions) else { throw TrainingValidationError.invalidTargetRepetitions }
        if let targetLoadKilograms {
            guard Self.validLoad(targetLoadKilograms) else { throw TrainingValidationError.invalidLoad }
        }
        self.muscleGroup = muscleGroup
        self.targetSets = targetSets
        self.targetRepetitions = targetRepetitions
        self.targetLoadKilograms = targetLoadKilograms
        self.loadConvention = loadConvention
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, muscleGroup, targetSets, targetRepetitions, targetLoadKilograms, loadConvention
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["id", "name", "muscleGroup", "targetSets", "targetRepetitions", "targetLoadKilograms", "loadConvention"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingTemplateExerciseSnapshot(
            id: c.decode(String.self, forKey: .id),
            name: c.decode(String.self, forKey: .name),
            muscleGroup: c.decode(TrainingMuscleGroup.self, forKey: .muscleGroup),
            targetSets: c.decode(Int.self, forKey: .targetSets),
            targetRepetitions: c.decode(Int.self, forKey: .targetRepetitions),
            targetLoadKilograms: c.decodeIfPresent(Double.self, forKey: .targetLoadKilograms),
            loadConvention: c.decode(TrainingLoadConvention.self, forKey: .loadConvention)
        )
    }

    private static func validLegacyIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first, bytes.count <= TrainingDomainLimits.maximumTemplateIdentifierUTF8Bytes else { return false }
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        return alphaNumeric(first) && bytes.dropFirst().allSatisfy { alphaNumeric($0) || $0 == 45 || $0 == 95 }
    }

    private static func validLoad(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= TrainingDomainLimits.maximumLoadKilograms
    }
}

public struct TrainingTemplateSnapshot: Codable, Equatable, Sendable {
    public let templateID: String
    public let name: String
    public let exercises: [TrainingTemplateExerciseSnapshot]

    public init(
        templateID: String,
        name: String,
        exercises: [TrainingTemplateExerciseSnapshot]
    ) throws {
        let normalizedID = try TrainingText.normalized(templateID, field: "template identifier", maximumBytes: TrainingDomainLimits.maximumTemplateIdentifierUTF8Bytes)
        guard Self.validLegacyIdentifier(normalizedID) else { throw TrainingValidationError.invalidTemplateSnapshot }
        self.templateID = normalizedID
        self.name = try TrainingText.normalized(name, field: "template name", maximumBytes: TrainingDomainLimits.maximumTitleUTF8Bytes)
        guard exercises.count <= TrainingDomainLimits.maximumExercisesPerSession else { throw TrainingValidationError.tooManyExercises }
        var identifiers = Set<String>()
        for exercise in exercises {
            guard identifiers.insert(exercise.id).inserted else { throw TrainingValidationError.duplicateTemplateExerciseIdentifier }
        }
        self.exercises = exercises
    }

    /// Bridges the existing legacy template schema without importing that
    /// store's persistence or allowing later template edits to leak in.
    public init(template: FitnessStrengthTemplate) throws {
        let exercises = try template.exercises.map { exercise in
            try TrainingTemplateExerciseSnapshot(
                id: exercise.id,
                name: exercise.name,
                muscleGroup: TrainingMuscleGroup(rawValue: exercise.muscleGroup.rawValue) ?? .other,
                targetSets: exercise.sets,
                targetRepetitions: exercise.repetitions,
                targetLoadKilograms: exercise.loadKilograms,
                loadConvention: .externalTotal
            )
        }
        try self.init(templateID: template.id, name: template.name, exercises: exercises)
    }

    private enum CodingKeys: String, CodingKey { case templateID, name, exercises }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["templateID", "name", "exercises"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingTemplateSnapshot(
            templateID: c.decode(String.self, forKey: .templateID),
            name: c.decode(String.self, forKey: .name),
            exercises: decodeBoundedTrainingArray(
                TrainingTemplateExerciseSnapshot.self,
                forKey: .exercises,
                from: c,
                maximum: TrainingDomainLimits.maximumExercisesPerSession,
                overflow: .tooManyExercises
            )
        )
    }

    private static func validLegacyIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first else { return false }
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        return alphaNumeric(first) && bytes.dropFirst().allSatisfy { alphaNumeric($0) || $0 == 45 || $0 == 95 }
    }
}

public enum TrainingSessionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case paused
    case completed
    case discarded
}

public struct TrainingPauseInterval: Codable, Equatable, Hashable, Sendable {
    public let startedAt: Date
    public let endedAt: Date?

    public init(startedAt: Date, endedAt: Date? = nil, now: Date = .now) throws {
        try TrainingDates.validate(startedAt, field: "pause start", now: now)
        try TrainingDates.validateOptional(endedAt, field: "pause end", now: now)
        if let endedAt {
            guard endedAt > startedAt else { throw TrainingValidationError.invalidPauseInterval }
        }
        self.startedAt = startedAt
        self.endedAt = endedAt
    }

    public func ended(at date: Date, now: Date = .now) throws -> TrainingPauseInterval {
        try TrainingPauseInterval(startedAt: startedAt, endedAt: date, now: now)
    }

    private enum CodingKeys: String, CodingKey { case startedAt, endedAt }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["startedAt", "endedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingPauseInterval(
            startedAt: c.decode(Date.self, forKey: .startedAt),
            endedAt: c.decodeIfPresent(Date.self, forKey: .endedAt),
            now: decoder.trainingValidationNow
        )
    }
}

public struct TrainingSetLog: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: TrainingRecordID
    public let kind: TrainingSetKind
    public let targetRepetitions: Int?
    public let targetLoadKilograms: Double?
    public let actualRepetitions: Int?
    public let actualLoadKilograms: Double?
    public let isCompleted: Bool
    public let completedAt: Date?

    public init(
        id: TrainingRecordID = TrainingRecordID(),
        kind: TrainingSetKind = .working,
        targetRepetitions: Int? = nil,
        targetLoadKilograms: Double? = nil,
        actualRepetitions: Int? = nil,
        actualLoadKilograms: Double? = nil,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        now: Date = .now
    ) throws {
        guard (id.uuid.uuidString.lowercased() == id.rawValue) else { throw TrainingValidationError.invalidIdentifier }
        if let targetRepetitions, !(1...TrainingDomainLimits.maximumRepetitions).contains(targetRepetitions) {
            throw TrainingValidationError.invalidTargetRepetitions
        }
        if let actualRepetitions, !(1...TrainingDomainLimits.maximumRepetitions).contains(actualRepetitions) {
            throw TrainingValidationError.invalidActualRepetitions
        }
        if let targetLoadKilograms, !Self.validLoad(targetLoadKilograms) { throw TrainingValidationError.invalidLoad }
        if let actualLoadKilograms, !Self.validLoad(actualLoadKilograms) { throw TrainingValidationError.invalidLoad }
        try TrainingDates.validateOptional(completedAt, field: "set completion", now: now)
        if isCompleted {
            guard actualRepetitions != nil, completedAt != nil else { throw TrainingValidationError.invalidSetState }
        } else {
            guard completedAt == nil else { throw TrainingValidationError.invalidSetState }
        }
        self.id = id
        self.kind = kind
        self.targetRepetitions = targetRepetitions
        self.targetLoadKilograms = targetLoadKilograms
        self.actualRepetitions = actualRepetitions
        self.actualLoadKilograms = actualLoadKilograms
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }

    public var countsAsCompletedSet: Bool { isCompleted && actualRepetitions != nil }

    /// A missing actual load stays missing. An explicit zero is retained as a
    /// real zero and is therefore different from an unavailable load.
    public func externalVolumeKilograms(loadConvention: TrainingLoadConvention) -> Double? {
        guard countsAsCompletedSet,
              loadConvention == .externalTotal,
              let actualRepetitions,
              let actualLoadKilograms else { return nil }
        let contribution = Double(actualRepetitions) * actualLoadKilograms
        return contribution.isFinite ? contribution : nil
    }

    private static func validLoad(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= TrainingDomainLimits.maximumLoadKilograms
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, targetRepetitions, targetLoadKilograms, actualRepetitions, actualLoadKilograms, isCompleted, completedAt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["id", "kind", "targetRepetitions", "targetLoadKilograms", "actualRepetitions", "actualLoadKilograms", "isCompleted", "completedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingSetLog(
            id: c.decode(TrainingRecordID.self, forKey: .id),
            kind: c.decode(TrainingSetKind.self, forKey: .kind),
            targetRepetitions: c.decodeIfPresent(Int.self, forKey: .targetRepetitions),
            targetLoadKilograms: c.decodeIfPresent(Double.self, forKey: .targetLoadKilograms),
            actualRepetitions: c.decodeIfPresent(Int.self, forKey: .actualRepetitions),
            actualLoadKilograms: c.decodeIfPresent(Double.self, forKey: .actualLoadKilograms),
            isCompleted: c.decode(Bool.self, forKey: .isCompleted),
            completedAt: c.decodeIfPresent(Date.self, forKey: .completedAt),
            now: decoder.trainingValidationNow
        )
    }
}

public struct TrainingExerciseLog: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: TrainingRecordID
    public let templateExerciseID: String?
    public let name: String
    public let muscleGroup: TrainingMuscleGroup
    public let loadConvention: TrainingLoadConvention
    public let sets: [TrainingSetLog]
    public let notes: String?

    public init(
        id: TrainingRecordID = TrainingRecordID(),
        templateExerciseID: String? = nil,
        name: String,
        muscleGroup: TrainingMuscleGroup = .other,
        loadConvention: TrainingLoadConvention = .externalTotal,
        sets: [TrainingSetLog] = [],
        notes: String? = nil
    ) throws {
        if let templateExerciseID {
            let normalized = try TrainingText.normalized(templateExerciseID, field: "template exercise identifier", maximumBytes: TrainingDomainLimits.maximumTemplateIdentifierUTF8Bytes)
            guard Self.validLegacyIdentifier(normalized) else { throw TrainingValidationError.invalidIdentifier }
            self.templateExerciseID = normalized
        } else {
            self.templateExerciseID = nil
        }
        self.id = id
        self.name = try TrainingText.normalized(name, field: "exercise name", maximumBytes: TrainingDomainLimits.maximumExerciseNameUTF8Bytes)
        guard sets.count <= TrainingDomainLimits.maximumSetsPerExercise else { throw TrainingValidationError.tooManySets }
        self.muscleGroup = muscleGroup
        self.loadConvention = loadConvention
        self.sets = sets
        self.notes = try TrainingText.optional(notes, field: "exercise notes", maximumBytes: TrainingDomainLimits.maximumNotesUTF8Bytes)
        var ids = Set<TrainingRecordID>()
        for set in sets {
            guard ids.insert(set.id).inserted else { throw TrainingValidationError.duplicateIdentifier }
        }
    }

    public var completedSets: [TrainingSetLog] { sets.filter(\.countsAsCompletedSet) }

    public var completedWorkingSets: [TrainingSetLog] {
        completedSets.filter { $0.kind == .working }
    }

    public var recordedExternalVolumeKilograms: Double? {
        let contributions = completedSets.compactMap { $0.externalVolumeKilograms(loadConvention: loadConvention) }
        guard !contributions.isEmpty else { return nil }
        let total = contributions.reduce(0, +)
        return total.isFinite ? total : nil
    }

    public var recordedWorkingVolumeKilograms: Double? {
        let contributions = completedWorkingSets.compactMap { $0.externalVolumeKilograms(loadConvention: loadConvention) }
        guard !contributions.isEmpty else { return nil }
        let total = contributions.reduce(0, +)
        return total.isFinite ? total : nil
    }

    public var bestRecordedExternalWorkingLoadKilograms: Double? {
        completedWorkingSets.compactMap { set in
            guard loadConvention == .externalTotal else { return nil }
            return set.actualLoadKilograms
        }.max()
    }

    private static func validLegacyIdentifier(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard let first = bytes.first else { return false }
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        return alphaNumeric(first) && bytes.dropFirst().allSatisfy { alphaNumeric($0) || $0 == 45 || $0 == 95 }
    }

    private enum CodingKeys: String, CodingKey {
        case id, templateExerciseID, name, muscleGroup, loadConvention, sets, notes
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["id", "templateExerciseID", "name", "muscleGroup", "loadConvention", "sets", "notes"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingExerciseLog(
            id: c.decode(TrainingRecordID.self, forKey: .id),
            templateExerciseID: c.decodeIfPresent(String.self, forKey: .templateExerciseID),
            name: c.decode(String.self, forKey: .name),
            muscleGroup: c.decode(TrainingMuscleGroup.self, forKey: .muscleGroup),
            loadConvention: c.decode(TrainingLoadConvention.self, forKey: .loadConvention),
            sets: decodeBoundedTrainingArray(
                TrainingSetLog.self,
                forKey: .sets,
                from: c,
                maximum: TrainingDomainLimits.maximumSetsPerExercise,
                overflow: .tooManySets
            ),
            notes: c.decodeIfPresent(String.self, forKey: .notes)
        )
    }
}

// MARK: - Session and history records

public struct TrainingSession: Codable, Equatable, Sendable, Identifiable {
    public let id: TrainingRecordID
    public let revision: Int
    public let activityKind: TrainingActivityKind
    public let title: String
    public let createdAt: Date
    public let updatedAt: Date
    public let startedAt: Date
    public let endedAt: Date?
    public let timeZoneIdentifier: String
    public let templateID: String?
    public let templateSnapshot: TrainingTemplateSnapshot?
    public let pauses: [TrainingPauseInterval]
    public let status: TrainingSessionStatus
    public let exercises: [TrainingExerciseLog]
    public let notes: String?
    public let importedRecordKey: String?

    public init(
        id: TrainingRecordID = TrainingRecordID(),
        revision: Int = 0,
        activityKind: TrainingActivityKind = .strength,
        title: String,
        createdAt: Date,
        updatedAt: Date,
        startedAt: Date,
        endedAt: Date? = nil,
        timeZoneIdentifier: String = TimeZone.current.identifier,
        templateID: String? = nil,
        templateSnapshot: TrainingTemplateSnapshot? = nil,
        pauses: [TrainingPauseInterval] = [],
        status: TrainingSessionStatus = .active,
        exercises: [TrainingExerciseLog] = [],
        notes: String? = nil,
        importedRecordKey: String? = nil,
        now: Date = .now
    ) throws {
        self.id = id
        self.revision = revision
        self.activityKind = activityKind
        self.title = try TrainingText.normalized(title, field: "session title", maximumBytes: TrainingDomainLimits.maximumTitleUTF8Bytes)
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.timeZoneIdentifier = try Self.normalizedTimeZone(timeZoneIdentifier)
        self.templateID = try Self.normalizedTemplateID(templateID)
        self.templateSnapshot = templateSnapshot
        self.pauses = pauses
        self.status = status
        self.exercises = exercises
        self.notes = try TrainingText.optional(notes, field: "session notes", maximumBytes: TrainingDomainLimits.maximumNotesUTF8Bytes)
        if let importedRecordKey {
            guard let boundedKey = try TrainingText.boundedOpaqueKey(importedRecordKey, field: "imported record key", maximumBytes: TrainingDomainLimits.maximumImportedKeyUTF8Bytes) else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            self.importedRecordKey = try TrainingImportedWorkoutIdentity.canonicalStableKey(from: [boundedKey])
        } else {
            self.importedRecordKey = nil
        }
        try validate(now: now)
    }

    public func validate(now: Date = .now) throws {
        guard (0..<Int.max).contains(revision) else { throw TrainingValidationError.invalidRevision }
        try TrainingDates.validate(createdAt, field: "created date", now: now)
        try TrainingDates.validate(updatedAt, field: "updated date", now: now)
        try TrainingDates.validate(startedAt, field: "start date", now: now)
        try TrainingDates.validateOptional(endedAt, field: "end date", now: now)
        if let importedRecordKey {
            _ = try TrainingImportedWorkoutIdentity.validateStableKey(importedRecordKey)
        }
        guard updatedAt >= createdAt, updatedAt >= startedAt, startedAt >= createdAt else {
            throw TrainingValidationError.invalidDate(field: "session ordering")
        }
        if let endedAt {
            guard endedAt >= startedAt else { throw TrainingValidationError.invalidDate(field: "session ordering") }
        }

        if let templateID = templateID {
            guard let templateSnapshot, templateSnapshot.templateID == templateID else {
                throw TrainingValidationError.invalidTemplateSnapshot
            }
        } else if templateSnapshot != nil {
            throw TrainingValidationError.invalidTemplateSnapshot
        }

        guard exercises.count <= TrainingDomainLimits.maximumExercisesPerSession else {
            throw TrainingValidationError.tooManyExercises
        }
        guard pauses.count <= TrainingDomainLimits.maximumPausesPerSession else {
            throw TrainingValidationError.tooManyPauses
        }
        var exerciseIDs = Set<TrainingRecordID>()
        var templateExerciseIDs = Set<String>()
        for exercise in exercises {
            guard exerciseIDs.insert(exercise.id).inserted else { throw TrainingValidationError.duplicateIdentifier }
            if let templateExerciseID = exercise.templateExerciseID {
                guard templateExerciseIDs.insert(templateExerciseID).inserted else {
                    throw TrainingValidationError.duplicateTemplateExerciseIdentifier
                }
            }
            for set in exercise.sets {
                try TrainingDates.validateOptional(set.completedAt, field: "set completion", now: now)
                if let completedAt = set.completedAt {
                    guard completedAt >= startedAt else { throw TrainingValidationError.invalidDate(field: "set completion") }
                    if let endedAt { guard completedAt <= endedAt else { throw TrainingValidationError.invalidDate(field: "set completion") } }
                }
            }
        }

        try validatePauses(now: now)
        switch status {
        case .active:
            guard endedAt == nil, pauses.last?.endedAt != nil || pauses.isEmpty else { throw TrainingValidationError.invalidSessionStatus }
        case .paused:
            guard endedAt == nil,
                  let last = pauses.last,
                  last.endedAt == nil else { throw TrainingValidationError.invalidSessionStatus }
        case .completed:
            guard let endedAt,
                  endedAt > startedAt,
                  endedAt.timeIntervalSince(startedAt) <= TrainingDomainLimits.maximumCompletedDuration,
                  pauses.allSatisfy({ $0.endedAt != nil }),
                  activityKind != .strength || exercises.contains(where: { $0.completedSets.isEmpty == false }) else {
                if let endedAt,
                   endedAt > startedAt,
                   endedAt.timeIntervalSince(startedAt) <= TrainingDomainLimits.maximumCompletedDuration {
                    if activityKind == .strength {
                        throw TrainingValidationError.completedSessionRequiresSet
                    }
                    throw TrainingValidationError.invalidSessionStatus
                }
                throw TrainingValidationError.invalidCompletedDuration
            }
        case .discarded:
            guard pauses.allSatisfy({ $0.endedAt != nil }) else { throw TrainingValidationError.invalidSessionStatus }
        }
    }

    public var completedSets: [TrainingSetLog] {
        exercises.flatMap(\.completedSets)
    }

    public var completedWorkingSets: [TrainingSetLog] {
        exercises.flatMap(\.completedWorkingSets)
    }

    public var recordedExternalVolumeKilograms: Double? {
        let contributions = exercises.compactMap(\.recordedExternalVolumeKilograms)
        guard !contributions.isEmpty else { return nil }
        let total = contributions.reduce(0, +)
        return total.isFinite ? total : nil
    }

    public var recordedWorkingVolumeKilograms: Double? {
        let contributions = exercises.compactMap(\.recordedWorkingVolumeKilograms)
        guard !contributions.isEmpty else { return nil }
        let total = contributions.reduce(0, +)
        return total.isFinite ? total : nil
    }

    public var recordedDuration: TimeInterval? {
        guard let endedAt, endedAt >= startedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }

    /// Creates the next immutable ledger revision while retaining the
    /// template snapshot and session identity. The store uses this to apply
    /// its own durable revision and monotonic clock value.
    public func replacing(
        revision: Int,
        updatedAt: Date,
        status: TrainingSessionStatus? = nil,
        endedAt: Date? = nil,
        pauses: [TrainingPauseInterval]? = nil,
        now: Date = .now
    ) throws -> TrainingSession {
        try TrainingSession(
            id: id,
            revision: revision,
            activityKind: activityKind,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            templateID: templateID,
            templateSnapshot: templateSnapshot,
            pauses: pauses ?? self.pauses,
            status: status ?? self.status,
            exercises: exercises,
            notes: notes,
            importedRecordKey: importedRecordKey,
            now: now
        )
    }

    /// Changes only the source-link field while preserving the local workout
    /// namespace and every editable set. Link and unlink mutations use this
    /// helper with a store-assigned revision.
    public func replacingImportedRecordKey(
        _ importedRecordKey: String?,
        revision: Int,
        updatedAt: Date,
        now: Date = .now
    ) throws -> TrainingSession {
        try TrainingSession(
            id: id,
            revision: revision,
            activityKind: activityKind,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: timeZoneIdentifier,
            templateID: templateID,
            templateSnapshot: templateSnapshot,
            pauses: pauses,
            status: status,
            exercises: exercises,
            notes: notes,
            importedRecordKey: importedRecordKey,
            now: now
        )
    }

    private func validatePauses(now: Date) throws {
        var previousEnd: Date?
        for (index, pause) in pauses.enumerated() {
            try TrainingDates.validate(pause.startedAt, field: "pause start", now: now)
            try TrainingDates.validateOptional(pause.endedAt, field: "pause end", now: now)
            guard pause.startedAt >= startedAt else { throw TrainingValidationError.invalidPauseInterval }
            if let previousEnd { guard pause.startedAt >= previousEnd else { throw TrainingValidationError.invalidPauseInterval } }
            if let pauseEnd = pause.endedAt {
                guard pauseEnd > pause.startedAt else { throw TrainingValidationError.invalidPauseInterval }
                if let sessionEnd = self.endedAt { guard pauseEnd <= sessionEnd else { throw TrainingValidationError.invalidPauseInterval } }
            } else {
                guard index == pauses.count - 1 else { throw TrainingValidationError.invalidPauseInterval }
            }
            previousEnd = pause.endedAt
        }
    }

    private static func normalizedTimeZone(_ value: String) throws -> String {
        let normalized = try TrainingText.normalized(value, field: "time zone", maximumBytes: TrainingDomainLimits.maximumTimeZoneUTF8Bytes)
        guard TimeZone(identifier: normalized) != nil else { throw TrainingValidationError.invalidTimeZone }
        return normalized
    }

    private static func normalizedTemplateID(_ value: String?) throws -> String? {
        guard let value else { return nil }
        let normalized = try TrainingText.normalized(value, field: "template identifier", maximumBytes: TrainingDomainLimits.maximumTemplateIdentifierUTF8Bytes)
        let bytes = Array(normalized.utf8)
        guard let first = bytes.first else { throw TrainingValidationError.invalidIdentifier }
        func alphaNumeric(_ byte: UInt8) -> Bool {
            (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
        }
        guard alphaNumeric(first), bytes.dropFirst().allSatisfy({ alphaNumeric($0) || $0 == 45 || $0 == 95 }) else {
            throw TrainingValidationError.invalidIdentifier
        }
        return normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, activityKind, title, createdAt, updatedAt, startedAt, endedAt, timeZoneIdentifier, templateID, templateSnapshot, pauses, status, exercises, notes, importedRecordKey
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["id", "revision", "activityKind", "title", "createdAt", "updatedAt", "startedAt", "endedAt", "timeZoneIdentifier", "templateID", "templateSnapshot", "pauses", "status", "exercises", "notes", "importedRecordKey"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingSession(
            id: c.decode(TrainingRecordID.self, forKey: .id),
            revision: c.decode(Int.self, forKey: .revision),
            activityKind: c.decode(TrainingActivityKind.self, forKey: .activityKind),
            title: c.decode(String.self, forKey: .title),
            createdAt: c.decode(Date.self, forKey: .createdAt),
            updatedAt: c.decode(Date.self, forKey: .updatedAt),
            startedAt: c.decode(Date.self, forKey: .startedAt),
            endedAt: c.decodeIfPresent(Date.self, forKey: .endedAt),
            timeZoneIdentifier: c.decode(String.self, forKey: .timeZoneIdentifier),
            templateID: c.decodeIfPresent(String.self, forKey: .templateID),
            templateSnapshot: c.decodeIfPresent(TrainingTemplateSnapshot.self, forKey: .templateSnapshot),
            pauses: decodeBoundedTrainingArray(
                TrainingPauseInterval.self,
                forKey: .pauses,
                from: c,
                maximum: TrainingDomainLimits.maximumPausesPerSession,
                overflow: .tooManyPauses
            ),
            status: c.decode(TrainingSessionStatus.self, forKey: .status),
            exercises: decodeBoundedTrainingArray(
                TrainingExerciseLog.self,
                forKey: .exercises,
                from: c,
                maximum: TrainingDomainLimits.maximumExercisesPerSession,
                overflow: .tooManyExercises
            ),
            notes: c.decodeIfPresent(String.self, forKey: .notes),
            importedRecordKey: c.decodeIfPresent(String.self, forKey: .importedRecordKey),
            now: decoder.trainingValidationNow
        )
    }
}

public struct TrainingHistoryItem: Codable, Equatable, Identifiable, Sendable {
    public let id: TrainingRecordID
    public let revision: Int
    public let activityKind: TrainingActivityKind
    public let title: String
    public let startedAt: Date
    public let endedAt: Date?
    public let duration: TimeInterval?
    public let status: TrainingSessionStatus
    public let sourceState: TrainingSourceState
    public let coverage: TrainingCoverage
    public let timeZoneIdentifier: String
    public let importedRecordKey: String?

    public init(session: TrainingSession, now: Date = .now) throws {
        try session.validate(now: now)
        self.id = session.id
        self.revision = session.revision
        self.activityKind = session.activityKind
        self.title = session.title
        self.startedAt = session.startedAt
        self.endedAt = session.endedAt
        self.duration = session.recordedDuration
        self.status = session.status
        self.sourceState = .local
        self.coverage = try TrainingCoverage(
            kind: session.status == .completed ? .complete : .partial,
            lowerBound: session.startedAt,
            upperBound: session.endedAt,
            now: now
        )
        self.timeZoneIdentifier = session.timeZoneIdentifier
        self.importedRecordKey = session.importedRecordKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, revision, activityKind, title, startedAt, endedAt, duration, status, sourceState, coverage, timeZoneIdentifier, importedRecordKey
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["id", "revision", "activityKind", "title", "startedAt", "endedAt", "duration", "status", "sourceState", "coverage", "timeZoneIdentifier", "importedRecordKey"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TrainingRecordID.self, forKey: .id)
        revision = try c.decode(Int.self, forKey: .revision)
        activityKind = try c.decode(TrainingActivityKind.self, forKey: .activityKind)
        title = try TrainingText.normalized(c.decode(String.self, forKey: .title), field: "history title", maximumBytes: TrainingDomainLimits.maximumTitleUTF8Bytes)
        startedAt = try c.decode(Date.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Date.self, forKey: .endedAt)
        duration = try c.decodeIfPresent(TimeInterval.self, forKey: .duration)
        status = try c.decode(TrainingSessionStatus.self, forKey: .status)
        sourceState = try c.decode(TrainingSourceState.self, forKey: .sourceState)
        coverage = try c.decode(TrainingCoverage.self, forKey: .coverage)
        timeZoneIdentifier = try TrainingSession.normalizedTimeZoneForHistory(c.decode(String.self, forKey: .timeZoneIdentifier))
        importedRecordKey = try TrainingText.boundedOpaqueKey(c.decodeIfPresent(String.self, forKey: .importedRecordKey), field: "imported record key", maximumBytes: TrainingDomainLimits.maximumImportedKeyUTF8Bytes)
        if let importedRecordKey {
            _ = try TrainingImportedWorkoutIdentity.validateStableKey(importedRecordKey)
        }
        try TrainingDates.validate(startedAt, field: "history start", now: decoder.trainingValidationNow)
        try TrainingDates.validateOptional(endedAt, field: "history end", now: decoder.trainingValidationNow)
        guard revision >= 0, revision < Int.max, sourceState == .local else {
            throw trainingCorrupted(decoder, "Invalid local training history item")
        }
        if let duration {
            guard duration.isFinite, duration > 0, duration <= TrainingDomainLimits.maximumCompletedDuration else {
                throw trainingCorrupted(decoder, "Invalid local training history item")
            }
        }
        if let endedAt {
            guard endedAt >= startedAt else {
                throw trainingCorrupted(decoder, "Invalid local training history item")
            }
        }
    }
}

/// The HealthKit revision is kept in the shared target without importing
/// HealthKit itself, so macOS and widgets can preserve it losslessly.
public enum TrainingImportedSampleRevision: Codable, Equatable, Hashable, Sendable {
    case syncVersion(Int64)
    case uuidFallback

    public init(syncVersion: Int64?) throws {
        guard let syncVersion else {
            self = .uuidFallback
            return
        }
        guard syncVersion >= 0 else { throw TrainingValidationError.invalidImportedIdentity }
        self = .syncVersion(syncVersion)
    }

    /// Enum cases remain source-compatible with existing HealthKit mapping
    /// code, but every imported identity and Codable boundary calls this
    /// validator before allowing the value into the durable training domain.
    public var isValid: Bool {
        numericValue.map { $0 >= 0 } ?? true
    }

    public func validate() throws {
        guard isValid else { throw TrainingValidationError.invalidImportedIdentity }
    }

    public var rawValue: String {
        switch self {
        case .syncVersion(let value): "sync:\(value)"
        case .uuidFallback: "uuid-fallback"
        }
    }

    public var numericValue: Int64? {
        switch self {
        case .syncVersion(let value): value
        case .uuidFallback: nil
        }
    }

    public func isNewer(than other: Self) -> Bool {
        switch (numericValue, other.numericValue) {
        case let (.some(lhs), .some(rhs)): return lhs > rhs
        case (.some, .none): return true
        default: return false
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["kind", "value"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "sync_version": self = try Self(syncVersion: c.decode(Int64.self, forKey: .value))
        case "uuid_fallback":
            guard !c.contains(.value) else { throw trainingCorrupted(decoder, "UUID fallback cannot carry a version value") }
            self = .uuidFallback
        default: throw trainingCorrupted(decoder, "Unknown imported workout revision")
        }
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .syncVersion(let value):
            try c.encode("sync_version", forKey: .kind)
            try c.encode(value, forKey: .value)
        case .uuidFallback:
            try c.encode("uuid_fallback", forKey: .kind)
        }
    }
}

/// This mirrors `HealthKitSourceMatch`.  The reviewed result is persisted
/// separately from availability, so an error or an unavailable refresh cannot
/// erase a prior Helio qualification.
public enum TrainingSourceQualification: String, Codable, CaseIterable, Hashable, Sendable {
    case confirmed
    case candidate
    case unattributed
    case other
    case conflict
}

/// The HealthKit identity fields needed by the training boundary. Keeping this
/// value type in the shared target means widgets and macOS can decode imported
/// records without importing the iOS-only HealthKit framework.
public struct TrainingImportedWorkoutIdentity: Codable, Equatable, Hashable, Sendable {
    public let uuid: UUID
    public let syncIdentifier: String?
    public let aliases: [UUID]
    public let revision: TrainingImportedSampleRevision

    public init(
        uuid: UUID,
        syncIdentifier: String? = nil,
        aliases: [UUID] = [],
        revision: TrainingImportedSampleRevision = .uuidFallback
    ) throws {
        let normalizedSyncIdentifier = try TrainingText.optional(
            syncIdentifier,
            field: "imported sync identifier",
            maximumBytes: TrainingDomainLimits.maximumImportedSyncIdentifierUTF8Bytes
        )
        let normalizedAliases = Array(Set(aliases).subtracting([uuid])).sorted { $0.uuidString < $1.uuidString }
        guard normalizedAliases.count <= TrainingDomainLimits.maximumImportedAliases else {
            throw TrainingValidationError.invalidImportedIdentity
        }
        try revision.validate()
        guard normalizedSyncIdentifier != nil
            ? revision.numericValue != nil
            : revision == .uuidFallback else {
            throw TrainingValidationError.invalidImportedIdentity
        }
        self.uuid = uuid
        self.syncIdentifier = normalizedSyncIdentifier
        self.aliases = normalizedAliases
        self.revision = revision
        guard isWithinSafetyBounds else { throw TrainingValidationError.invalidImportedIdentity }
    }

    public var stableKey: String {
        let uuidTokens = ([uuid] + aliases).map { "uuid:\($0.uuidString.lowercased())" }
        return (try? Self.canonicalStableKey(from: uuidTokens + (syncIdentifier.map { ["sync_identifier:\($0)"] } ?? [])))
            ?? "uuid:\(uuid.uuidString.lowercased())"
    }

    public var aliasKeys: Set<String> {
        var result = Set(([uuid] + aliases).map { "uuid:\($0.uuidString.lowercased())" })
        if let syncIdentifier { result.insert("sync_identifier:\(syncIdentifier)") }
        result.insert(stableKey)
        return result
    }

    public var isWithinSafetyBounds: Bool {
        let syncIdentifierIsBounded = syncIdentifier.map {
            $0.utf8.count <= TrainingDomainLimits.maximumImportedSyncIdentifierUTF8Bytes
        } ?? true
        return aliases.count <= TrainingDomainLimits.maximumImportedAliases &&
        syncIdentifierIsBounded &&
        revision.isValid &&
        (syncIdentifier != nil ? revision.numericValue != nil : revision == .uuidFallback) &&
        stableKey.utf8.count <= TrainingDomainLimits.maximumImportedIdentityUTF8Bytes &&
        Self.isValidStableKey(stableKey)
    }

    /// Returns canonical ownership tokens for a persisted source key. UUID
    /// aliases intentionally produce one token per UUID so `uuid:A` and
    /// `uuid:A,B` collide when they describe the same HealthKit evidence.
    /// Sync identifiers remain a single opaque token; their contents are
    /// never split, which keeps commas and other printable provider bytes
    /// unambiguous.
    static func stableKeyTokens(_ value: String) throws -> [String] {
        guard value.utf8.count <= TrainingDomainLimits.maximumImportedIdentityUTF8Bytes,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value == value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw TrainingValidationError.invalidImportedIdentity
        }

        if value.hasPrefix("sync_identifier:") {
            let identifier = String(value.dropFirst("sync_identifier:".count))
            guard !identifier.isEmpty,
                  identifier == identifier.trimmingCharacters(in: .whitespacesAndNewlines),
                  identifier.utf8.count <= TrainingDomainLimits.maximumImportedSyncIdentifierUTF8Bytes else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            return [value]
        }

        if value.hasPrefix("identity:") {
            let payload = String(value.dropFirst("identity:".count))
            let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  parts[0].hasPrefix("u:"),
                  parts[1].hasPrefix("s:") else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            let uuidComponents = String(parts[0].dropFirst(2)).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard (1...(TrainingDomainLimits.maximumImportedAliases + 1)).contains(uuidComponents.count),
                  uuidComponents == uuidComponents.sorted(),
                  Set(uuidComponents).count == uuidComponents.count,
                  uuidComponents.allSatisfy({ component in
                      guard let uuid = UUID(uuidString: component) else { return false }
                      return uuid.uuidString.lowercased() == component
                  }) else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            let encodedSyncIdentifier = String(parts[1].dropFirst(2))
            guard let syncData = Self.decodeBase64URL(encodedSyncIdentifier),
                  let syncIdentifier = String(data: syncData, encoding: .utf8),
                  let normalizedSyncIdentifier = try? TrainingText.normalized(
                      syncIdentifier,
                      field: "imported sync identifier",
                      maximumBytes: TrainingDomainLimits.maximumImportedSyncIdentifierUTF8Bytes
                  ),
                  !normalizedSyncIdentifier.isEmpty else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            return uuidComponents.map { "uuid:\($0)" } + ["sync_identifier:\(normalizedSyncIdentifier)"]
        }

        guard value.hasPrefix("uuid:") else { throw TrainingValidationError.invalidImportedIdentity }
        let components = String(value.dropFirst("uuid:".count))
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
        guard (1...(TrainingDomainLimits.maximumImportedAliases + 1)).contains(components.count),
              components == components.sorted(),
              Set(components).count == components.count,
              components.allSatisfy({ component in
                  guard let uuid = UUID(uuidString: component) else { return false }
                  return uuid.uuidString.lowercased() == component
              }) else {
            throw TrainingValidationError.invalidImportedIdentity
        }
        return components.map { "uuid:\($0)" }
    }

    /// Returns one deterministic link key for a set of known aliases. UUID and
    /// sync-ID tokens are kept together in the `identity:` form so an old link
    /// represented by one alias can be reconciled when HealthKit later exposes
    /// the other alias. Legacy UUID-only and sync-only forms remain readable.
    static func canonicalStableKey(from values: [String]) throws -> String {
        let tokens = Set(try values.flatMap { try stableKeyTokens($0) })
        let uuidTokens = tokens.filter { $0.hasPrefix("uuid:") }.sorted()
        let syncTokens = tokens.filter { $0.hasPrefix("sync_identifier:") }.sorted()
        guard !uuidTokens.isEmpty || !syncTokens.isEmpty,
              syncTokens.count <= 1 else {
            throw TrainingValidationError.invalidImportedIdentity
        }
        if let syncToken = syncTokens.first {
            if uuidTokens.isEmpty { return syncToken }
            guard uuidTokens.count <= TrainingDomainLimits.maximumImportedAliases + 1 else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            let syncIdentifier = String(syncToken.dropFirst("sync_identifier:".count))
            let uuidPayload = uuidTokens.map { String($0.dropFirst("uuid:".count)) }.joined(separator: ",")
            let syncPayload = Self.encodeBase64URL(Data(syncIdentifier.utf8))
            let key = "identity:u:\(uuidPayload);s:\(syncPayload)"
            guard key.utf8.count <= TrainingDomainLimits.maximumImportedIdentityUTF8Bytes,
                  Self.isValidStableKeyWithoutRecursion(key) else {
                throw TrainingValidationError.invalidImportedIdentity
            }
            return key
        }
        return "uuid:" + uuidTokens.map { String($0.dropFirst("uuid:".count)) }.joined(separator: ",")
    }

    private static func isValidStableKeyWithoutRecursion(_ value: String) -> Bool {
        guard value.hasPrefix("identity:") else { return false }
        let payload = String(value.dropFirst("identity:".count))
        let parts = payload.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, parts[0].hasPrefix("u:"), parts[1].hasPrefix("s:") else { return false }
        let uuids = String(parts[0].dropFirst(2)).split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard !uuids.isEmpty, uuids == uuids.sorted(), Set(uuids).count == uuids.count else { return false }
        guard uuids.allSatisfy({ component in
            guard let uuid = UUID(uuidString: component) else { return false }
            return uuid.uuidString.lowercased() == component
        }) else { return false }
        guard let data = decodeBase64URL(String(parts[1].dropFirst(2))),
              let syncIdentifier = String(data: data, encoding: .utf8),
              (try? TrainingText.normalized(syncIdentifier, field: "imported sync identifier", maximumBytes: TrainingDomainLimits.maximumImportedSyncIdentifierUTF8Bytes)) != nil else {
            return false
        }
        return true
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard value.utf8.count <= TrainingDomainLimits.maximumImportedSyncIdentifierUTF8Bytes * 2 else { return nil }
        var encoded = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        return Data(base64Encoded: encoded)
    }

    /// Compares persisted source keys by evidence identity rather than by
    /// their current serialization. Invalid keys never compare as equal.
    public static func stableKeysRepresentSameIdentity(_ lhs: String, _ rhs: String) -> Bool {
        guard let lhsTokens = try? stableKeyTokens(lhs),
              let rhsTokens = try? stableKeyTokens(rhs) else { return false }
        return !Set(lhsTokens).isDisjoint(with: rhsTokens)
    }

    /// Validates the canonical identity string used by link mutations. This
    /// keeps an arbitrary user string from becoming a durable source link.
    public static func isValidStableKey(_ value: String) -> Bool {
        (try? stableKeyTokens(value)) != nil
    }

    public static func validateStableKey(_ value: String) throws -> String {
        guard isValidStableKey(value) else { throw TrainingValidationError.invalidImportedIdentity }
        return value
    }

    private enum CodingKeys: String, CodingKey { case uuid, syncIdentifier, aliases, revision }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["uuid", "syncIdentifier", "aliases", "revision"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let aliases: [UUID]
        if !c.contains(.aliases) {
            aliases = []
        } else if try c.decodeNil(forKey: .aliases) {
            aliases = []
        } else {
            aliases = try decodeBoundedTrainingArray(
                UUID.self,
                forKey: .aliases,
                from: c,
                maximum: TrainingDomainLimits.maximumImportedAliases,
                overflow: .invalidImportedIdentity
            )
        }
        self = try TrainingImportedWorkoutIdentity(
            uuid: c.decode(UUID.self, forKey: .uuid),
            syncIdentifier: c.decodeIfPresent(String.self, forKey: .syncIdentifier),
            aliases: aliases,
            revision: c.decodeIfPresent(TrainingImportedSampleRevision.self, forKey: .revision) ?? .uuidFallback
        )
    }
}

/// Bounded provenance copied from a HealthKit observation. It retains every
/// source/device field needed by the reviewed Helio registry. Availability is
/// held by `sourceState`; this object is intentionally preserved on retained
/// records even when a later query is unavailable or errors.
public struct TrainingImportedWorkoutProvenance: Codable, Equatable, Hashable, Sendable {
    public let sourceBundleIdentifier: String?
    public let sourceName: String?
    public let sourceVersion: String?
    public let sourceProductType: String?
    public let sourceOperatingSystemVersion: String?
    public let deviceName: String?
    public let deviceManufacturer: String?
    public let deviceModel: String?
    public let deviceHardwareVersion: String?
    public let deviceFirmwareVersion: String?
    public let deviceSoftwareVersion: String?
    public let deviceLocalIdentifier: String?
    public let helioMatch: TrainingSourceQualification

    public var qualification: TrainingSourceQualification { helioMatch }

    public var hasEvidence: Bool {
        sourceBundleIdentifier != nil || sourceName != nil || sourceVersion != nil ||
        sourceProductType != nil || sourceOperatingSystemVersion != nil || deviceName != nil ||
        deviceManufacturer != nil || deviceModel != nil || deviceHardwareVersion != nil ||
        deviceFirmwareVersion != nil || deviceSoftwareVersion != nil || deviceLocalIdentifier != nil ||
        helioMatch != .unattributed
    }

    public init(
        sourceBundleIdentifier: String? = nil,
        sourceName: String? = nil,
        sourceVersion: String? = nil,
        sourceProductType: String? = nil,
        sourceOperatingSystemVersion: String? = nil,
        deviceName: String? = nil,
        deviceManufacturer: String? = nil,
        deviceModel: String? = nil,
        deviceHardwareVersion: String? = nil,
        deviceFirmwareVersion: String? = nil,
        deviceSoftwareVersion: String? = nil,
        deviceLocalIdentifier: String? = nil,
        helioMatch: TrainingSourceQualification = .unattributed
    ) throws {
        self.sourceBundleIdentifier = try TrainingText.optional(sourceBundleIdentifier, field: "source bundle identifier", maximumBytes: 512)
        self.sourceName = try TrainingText.optional(sourceName, field: "source name", maximumBytes: 512)
        self.sourceVersion = try TrainingText.optional(sourceVersion, field: "source version", maximumBytes: 512)
        self.sourceProductType = try TrainingText.optional(sourceProductType, field: "source product type", maximumBytes: 512)
        self.sourceOperatingSystemVersion = try TrainingText.optional(sourceOperatingSystemVersion, field: "source operating system version", maximumBytes: 512)
        self.deviceName = try TrainingText.optional(deviceName, field: "device name", maximumBytes: 512)
        self.deviceManufacturer = try TrainingText.optional(deviceManufacturer, field: "device manufacturer", maximumBytes: 512)
        self.deviceModel = try TrainingText.optional(deviceModel, field: "device model", maximumBytes: 512)
        self.deviceHardwareVersion = try TrainingText.optional(deviceHardwareVersion, field: "device hardware version", maximumBytes: 512)
        self.deviceFirmwareVersion = try TrainingText.optional(deviceFirmwareVersion, field: "device firmware version", maximumBytes: 512)
        self.deviceSoftwareVersion = try TrainingText.optional(deviceSoftwareVersion, field: "device software version", maximumBytes: 512)
        self.deviceLocalIdentifier = try TrainingText.optional(deviceLocalIdentifier, field: "device local identifier", maximumBytes: 512)
        guard helioMatch == .unattributed || self.sourceBundleIdentifier != nil else {
            throw TrainingValidationError.invalidImportedSource
        }
        self.helioMatch = helioMatch
    }

    private enum CodingKeys: String, CodingKey {
        case sourceBundleIdentifier, sourceName, sourceVersion, sourceProductType, sourceOperatingSystemVersion
        case deviceName, deviceManufacturer, deviceModel, deviceHardwareVersion, deviceFirmwareVersion
        case deviceSoftwareVersion, deviceLocalIdentifier, helioMatch
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: [
            "sourceBundleIdentifier", "sourceName", "sourceVersion", "sourceProductType",
            "sourceOperatingSystemVersion", "deviceName", "deviceManufacturer", "deviceModel",
            "deviceHardwareVersion", "deviceFirmwareVersion", "deviceSoftwareVersion",
            "deviceLocalIdentifier", "helioMatch"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingImportedWorkoutProvenance(
            sourceBundleIdentifier: c.decodeIfPresent(String.self, forKey: .sourceBundleIdentifier),
            sourceName: c.decodeIfPresent(String.self, forKey: .sourceName),
            sourceVersion: c.decodeIfPresent(String.self, forKey: .sourceVersion),
            sourceProductType: c.decodeIfPresent(String.self, forKey: .sourceProductType),
            sourceOperatingSystemVersion: c.decodeIfPresent(String.self, forKey: .sourceOperatingSystemVersion),
            deviceName: c.decodeIfPresent(String.self, forKey: .deviceName),
            deviceManufacturer: c.decodeIfPresent(String.self, forKey: .deviceManufacturer),
            deviceModel: c.decodeIfPresent(String.self, forKey: .deviceModel),
            deviceHardwareVersion: c.decodeIfPresent(String.self, forKey: .deviceHardwareVersion),
            deviceFirmwareVersion: c.decodeIfPresent(String.self, forKey: .deviceFirmwareVersion),
            deviceSoftwareVersion: c.decodeIfPresent(String.self, forKey: .deviceSoftwareVersion),
            deviceLocalIdentifier: c.decodeIfPresent(String.self, forKey: .deviceLocalIdentifier),
            helioMatch: c.decodeIfPresent(TrainingSourceQualification.self, forKey: .helioMatch) ?? .unattributed
        )
    }
}

/// A source-qualified workout imported from HealthKit. The record deliberately
/// keeps the raw activity value and stable identity; mapping either to a
/// display label belongs to the projection/UI layer. Local set logs never
/// enter this type, so imported workouts cannot overwrite user-entered data.
public struct TrainingImportedHistoryRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let identity: TrainingImportedWorkoutIdentity
    public let activityTypeRawValue: Int
    public let startedAt: Date
    public let endedAt: Date
    public let durationSeconds: TimeInterval
    public let activeEnergyKilocalories: Double?
    public let sourceState: TrainingSourceState
    public let coverage: TrainingCoverage
    public let provenance: TrainingImportedWorkoutProvenance?

    public var id: String { identity.stableKey }

    public init(
        identity: TrainingImportedWorkoutIdentity,
        activityTypeRawValue: Int,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        activeEnergyKilocalories: Double? = nil,
        sourceState: TrainingSourceState = .imported,
        coverage: TrainingCoverage? = nil,
        provenance: TrainingImportedWorkoutProvenance? = nil,
        now: Date = .now
    ) throws {
        guard identity.isWithinSafetyBounds,
              !identity.stableKey.isEmpty,
              identity.stableKey.utf8.count <= TrainingDomainLimits.maximumImportedIdentityUTF8Bytes,
              !identity.stableKey.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw TrainingValidationError.invalidImportedIdentity
        }
        guard activityTypeRawValue >= 0 else { throw TrainingValidationError.invalidImportedActivity }
        try TrainingDates.validate(startedAt, field: "imported workout start", now: now)
        try TrainingDates.validate(endedAt, field: "imported workout end", now: now)
        guard endedAt > startedAt,
              endedAt.timeIntervalSince(startedAt) <= TrainingDomainLimits.maximumCompletedDuration,
              durationSeconds.isFinite,
              durationSeconds > 0,
              durationSeconds <= TrainingDomainLimits.maximumCompletedDuration else {
            throw TrainingValidationError.invalidDate(field: "imported workout interval")
        }
        if let activeEnergyKilocalories {
            guard activeEnergyKilocalories.isFinite,
                  activeEnergyKilocalories >= 0,
                  activeEnergyKilocalories <= TrainingDomainLimits.maximumImportedEnergyKilocalories else {
                throw TrainingValidationError.invalidImportedEnergy
            }
        }
        guard sourceState != .local, sourceState != .mixed else {
            throw TrainingValidationError.invalidImportedSource
        }

        let defaultCoverage: TrainingCoverage
        switch sourceState {
        case .imported:
            defaultCoverage = try TrainingCoverage(kind: .complete, lowerBound: startedAt, upperBound: endedAt, now: now)
        default:
            defaultCoverage = try TrainingCoverage(kind: .partial, lowerBound: startedAt, upperBound: endedAt, now: now)
        }

        let resolvedCoverage = coverage ?? defaultCoverage
        switch sourceState {
        case .imported:
            guard resolvedCoverage.kind == .complete,
                  resolvedCoverage.contains(startedAt: startedAt, endedAt: endedAt) else {
                throw TrainingValidationError.invalidCoverage
            }
        case .partial, .stale, .conflict:
            guard resolvedCoverage.kind == .partial,
                  resolvedCoverage.contains(startedAt: startedAt, endedAt: endedAt) else {
                throw TrainingValidationError.invalidCoverage
            }
        case .unavailable, .readIndeterminate, .error:
            // These states describe the current query, not the retained
            // record. A retained record may carry a partial record window or
            // an unavailable query window; either way its source evidence and
            // provenance remain intact for later reconciliation.
            guard resolvedCoverage.kind == .partial || resolvedCoverage.kind == .unavailable else {
                throw TrainingValidationError.invalidCoverage
            }
            if resolvedCoverage.kind == .partial {
                guard resolvedCoverage.contains(startedAt: startedAt, endedAt: endedAt) else {
                    throw TrainingValidationError.invalidCoverage
                }
            }
        case .local, .mixed:
            throw TrainingValidationError.invalidImportedSource
        }

        self.identity = identity
        self.activityTypeRawValue = activityTypeRawValue
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSeconds = durationSeconds
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.sourceState = sourceState
        self.coverage = resolvedCoverage
        self.provenance = provenance
    }

    /// Converts one untrusted HealthKit observation into an explicit result.
    /// A malformed row can be reported and skipped by a projection without
    /// turning the entire refresh into an empty or failed history.
    public static func ingest(
        identity: TrainingImportedWorkoutIdentity,
        activityTypeRawValue: Int,
        startedAt: Date,
        endedAt: Date,
        durationSeconds: TimeInterval,
        activeEnergyKilocalories: Double? = nil,
        sourceState: TrainingSourceState = .imported,
        coverage: TrainingCoverage? = nil,
        provenance: TrainingImportedWorkoutProvenance? = nil,
        now: Date = .now
    ) -> TrainingImportedRecordResult {
        do {
            return .accepted(try Self(
                identity: identity,
                activityTypeRawValue: activityTypeRawValue,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: durationSeconds,
                activeEnergyKilocalories: activeEnergyKilocalories,
                sourceState: sourceState,
                coverage: coverage,
                provenance: provenance,
                now: now
            ))
        } catch let error as TrainingValidationError {
            return .skipped(TrainingImportedRecordRejection(reason: error, stableKey: identity.stableKey))
        } catch {
            return .skipped(TrainingImportedRecordRejection(reason: .invalidImportedSource, stableKey: identity.stableKey))
        }
    }

    private enum CodingKeys: String, CodingKey {
        case identity, activityTypeRawValue, startedAt, endedAt, durationSeconds
        case activeEnergyKilocalories, sourceState, coverage, provenance
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: [
            "identity", "activityTypeRawValue", "startedAt", "endedAt", "durationSeconds",
            "activeEnergyKilocalories", "sourceState", "coverage", "provenance"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingImportedHistoryRecord(
            identity: c.decode(TrainingImportedWorkoutIdentity.self, forKey: .identity),
            activityTypeRawValue: c.decode(Int.self, forKey: .activityTypeRawValue),
            startedAt: c.decode(Date.self, forKey: .startedAt),
            endedAt: c.decode(Date.self, forKey: .endedAt),
            durationSeconds: c.decode(Double.self, forKey: .durationSeconds),
            activeEnergyKilocalories: c.decodeIfPresent(Double.self, forKey: .activeEnergyKilocalories),
            sourceState: c.decode(TrainingSourceState.self, forKey: .sourceState),
            coverage: c.decodeIfPresent(TrainingCoverage.self, forKey: .coverage),
            provenance: c.decodeIfPresent(TrainingImportedWorkoutProvenance.self, forKey: .provenance),
            now: decoder.trainingValidationNow
        )
    }
}

public struct TrainingImportedRecordRejection: Equatable, Sendable {
    public let reason: TrainingValidationError
    public let stableKey: String?

    public init(reason: TrainingValidationError, stableKey: String?) {
        self.reason = reason
        self.stableKey = stableKey
    }
}

/// Bounded evidence for imported rows that share an identity and revision but
/// disagree on payload. The projection keeps one deterministic conflict row
/// while retaining these fingerprints so the disagreement cannot be mistaken
/// for a clean observation.
public struct TrainingImportedConflictEvidence: Equatable, Hashable, Sendable {
    public let stableKey: String
    public let payloadFingerprints: [String]
    public let conflictingRecordCount: Int

    public init(stableKey: String, payloadFingerprints: [String], conflictingRecordCount: Int) {
        self.stableKey = stableKey
        self.payloadFingerprints = Array(payloadFingerprints.prefix(TrainingDomainLimits.maximumConflictFingerprints))
        self.conflictingRecordCount = max(0, conflictingRecordCount)
    }
}

public enum TrainingImportedRecordResult: Equatable, Sendable {
    case accepted(TrainingImportedHistoryRecord)
    case skipped(TrainingImportedRecordRejection)
}

/// Query/window availability is deliberately separate from each retained
/// record's `coverage`. On an unavailable or errored refresh, previously
/// retained records can remain in this snapshot with their provenance intact.
public struct TrainingImportedHistorySnapshot: Equatable, Sendable {
    public let records: [TrainingImportedHistoryRecord]
    public let queryState: TrainingSourceState
    public let queryCoverage: TrainingCoverage
    public let rejectedRowCount: Int
    public let truncatedRowCount: Int
    public let rejectedRows: [TrainingImportedRecordRejection]
    public let conflictEvidence: [TrainingImportedConflictEvidence]

    public init(
        records: [TrainingImportedHistoryRecord],
        queryState: TrainingSourceState,
        queryCoverage: TrainingCoverage,
        rejectedRowCount: Int = 0,
        truncatedRowCount: Int = 0,
        rejectedRows: [TrainingImportedRecordRejection] = [],
        conflictEvidence: [TrainingImportedConflictEvidence] = [],
        now: Date = .now
    ) throws {
        guard records.count <= TrainingDomainLimits.maximumImportedHistoryRecords else {
            throw TrainingValidationError.invalidImportedSource
        }
        guard rejectedRowCount >= 0,
              truncatedRowCount >= 0,
              truncatedRowCount <= rejectedRowCount,
              rejectedRows.count <= TrainingDomainLimits.maximumImportedDiagnostics,
              rejectedRows.count <= rejectedRowCount,
              rejectedRows.allSatisfy({
                  guard let stableKey = $0.stableKey else { return true }
                  return TrainingImportedWorkoutIdentity.isValidStableKey(stableKey)
              }),
              conflictEvidence.count <= TrainingDomainLimits.maximumImportedConflictEvidence,
              conflictEvidence.allSatisfy({
                  $0.conflictingRecordCount >= 2 &&
                  $0.payloadFingerprints.count <= TrainingDomainLimits.maximumConflictFingerprints &&
                  TrainingImportedWorkoutIdentity.isValidStableKey($0.stableKey)
              }) else {
            throw TrainingValidationError.invalidImportedSource
        }
        guard queryState != .local, queryState != .mixed else {
            throw TrainingValidationError.invalidImportedSource
        }
        switch queryState {
        case .imported:
            guard queryCoverage.kind == .complete,
                  rejectedRowCount == 0,
                  truncatedRowCount == 0,
                  conflictEvidence.isEmpty else { throw TrainingValidationError.invalidCoverage }
        case .partial, .stale, .conflict:
            guard queryCoverage.kind == .partial else { throw TrainingValidationError.invalidCoverage }
        case .unavailable, .readIndeterminate, .error:
            guard queryCoverage.kind == .unavailable || queryCoverage.kind == .partial else {
                throw TrainingValidationError.invalidCoverage
            }
        case .local, .mixed:
            throw TrainingValidationError.invalidImportedSource
        }
        // The record interval is evidence about that record only. When the
        // query window has bounds, every returned record must fit them; an
        // unavailable window intentionally imposes no bounds on retained data.
        if queryCoverage.kind != .unavailable {
            for record in records {
                guard queryCoverage.contains(startedAt: record.startedAt, endedAt: record.endedAt) else {
                    throw TrainingValidationError.invalidCoverage
                }
            }
        }
        self.records = records
        self.queryState = queryState
        self.queryCoverage = queryCoverage
        self.rejectedRowCount = rejectedRowCount
        self.truncatedRowCount = truncatedRowCount
        self.rejectedRows = rejectedRows
        self.conflictEvidence = conflictEvidence
        _ = now // Keep the initializer's validation call site explicit for API symmetry.
    }
}

/// A stable union for the next projection phase. The local item remains the
/// editable workout truth, while imported wearable source truth has its own
/// read-only typed payload and can be linked without flattening, overwriting,
/// or inventing sets, load, Training Effect, or recovery metrics.
public enum TrainingHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    case local(TrainingHistoryItem)
    case imported(TrainingImportedHistoryRecord)

    public var id: String {
        switch self {
        case .local(let item): "local:\(item.id.rawValue)"
        case .imported(let record): "imported:\(record.id)"
        }
    }

    public var startedAt: Date {
        switch self {
        case .local(let item): item.startedAt
        case .imported(let record): record.startedAt
        }
    }

    public var sourceState: TrainingSourceState {
        switch self {
        case .local(let item): item.sourceState
        case .imported(let record): record.sourceState
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, local, imported }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .local(let item):
            try c.encode("local", forKey: .kind)
            try c.encode(item, forKey: .local)
        case .imported(let record):
            try c.encode("imported", forKey: .kind)
            try c.encode(record, forKey: .imported)
        }
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["kind", "local", "imported"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "local": self = .local(try c.decode(TrainingHistoryItem.self, forKey: .local))
        case "imported": self = .imported(try c.decode(TrainingImportedHistoryRecord.self, forKey: .imported))
        default: throw trainingCorrupted(decoder, "Unknown training history entry kind")
        }
    }
}

private extension TrainingSession {
    static func normalizedTimeZoneForHistory(_ value: String) throws -> String {
        let normalized = try TrainingText.normalized(value, field: "time zone", maximumBytes: TrainingDomainLimits.maximumTimeZoneUTF8Bytes)
        guard TimeZone(identifier: normalized) != nil else { throw TrainingValidationError.invalidTimeZone }
        return normalized
    }
}

// MARK: - Mutation and receipt payloads

public struct TrainingMutation: Codable, Equatable, Sendable {
    public enum Operation: String, Codable, CaseIterable, Sendable {
        case begin
        case update
        case finish
        case discard
        case delete
        case link
        case unlink
    }

    public let mutationID: TrainingRecordID
    public let operation: Operation
    public let recordID: TrainingRecordID?
    public let expectedRevision: Int?
    public let session: TrainingSession?
    public let template: TrainingTemplateSnapshot?
    public let title: String?
    public let activityKind: TrainingActivityKind?
    public let notes: String?
    public let importedRecordKey: String?

    public init(
        mutationID: TrainingRecordID,
        operation: Operation,
        recordID: TrainingRecordID? = nil,
        expectedRevision: Int? = nil,
        session: TrainingSession? = nil,
        template: TrainingTemplateSnapshot? = nil,
        title: String? = nil,
        activityKind: TrainingActivityKind? = nil,
        notes: String? = nil,
        importedRecordKey: String? = nil
    ) {
        self.mutationID = mutationID
        self.operation = operation
        self.recordID = recordID
        self.expectedRevision = expectedRevision
        self.session = session
        self.template = template
        self.title = title
        self.activityKind = activityKind
        self.notes = notes
        self.importedRecordKey = importedRecordKey
    }

    private enum CodingKeys: String, CodingKey {
        case mutationID, operation, recordID, expectedRevision, session, template, title, activityKind, notes, importedRecordKey
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["mutationID", "operation", "recordID", "expectedRevision", "session", "template", "title", "activityKind", "notes", "importedRecordKey"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mutationID = try c.decode(TrainingRecordID.self, forKey: .mutationID)
        operation = try c.decode(Operation.self, forKey: .operation)
        recordID = try c.decodeIfPresent(TrainingRecordID.self, forKey: .recordID)
        expectedRevision = try c.decodeIfPresent(Int.self, forKey: .expectedRevision)
        session = try c.decodeIfPresent(TrainingSession.self, forKey: .session)
        template = try c.decodeIfPresent(TrainingTemplateSnapshot.self, forKey: .template)
        title = try TrainingText.optional(c.decodeIfPresent(String.self, forKey: .title), field: "mutation title", maximumBytes: TrainingDomainLimits.maximumTitleUTF8Bytes)
        activityKind = try c.decodeIfPresent(TrainingActivityKind.self, forKey: .activityKind)
        notes = try TrainingText.optional(c.decodeIfPresent(String.self, forKey: .notes), field: "mutation notes", maximumBytes: TrainingDomainLimits.maximumNotesUTF8Bytes)
        importedRecordKey = try TrainingText.boundedOpaqueKey(
            c.decodeIfPresent(String.self, forKey: .importedRecordKey),
            field: "imported record key",
            maximumBytes: TrainingDomainLimits.maximumImportedKeyUTF8Bytes
        )
        if let expectedRevision {
            guard expectedRevision >= 0, expectedRevision < Int.max else {
                throw TrainingValidationError.invalidRevision
            }
        }
    }
}

public struct TrainingCommitReceipt: Codable, Equatable, Sendable {
    public enum Outcome: String, Codable, CaseIterable, Sendable {
        case saved
        case duplicate
        case conflict
        case blocked
    }

    public enum BlockReason: String, Codable, CaseIterable, Sendable {
        case activeSession = "active_session"
        case sessionLimit = "session_limit"
        case ledgerSize = "ledger_size"
        case receiptJournal = "receipt_journal"
        case integrityUnavailable = "integrity_unavailable"
    }

    public let mutationID: TrainingRecordID
    public let outcome: Outcome
    public let recordID: TrainingRecordID?
    public let revision: Int?
    public let currentSession: TrainingSession?
    public let blockReason: BlockReason?
    public let message: String?

    public init(
        mutationID: TrainingRecordID,
        outcome: Outcome,
        recordID: TrainingRecordID? = nil,
        revision: Int? = nil,
        currentSession: TrainingSession? = nil,
        blockReason: BlockReason? = nil,
        message: String? = nil
    ) throws {
        guard outcome == .blocked ? blockReason != nil : blockReason == nil else {
            throw TrainingValidationError.invalidSetState
        }
        if let revision {
            guard revision >= 0, revision < Int.max else {
                throw TrainingValidationError.invalidRevision
            }
        }
        self.mutationID = mutationID
        self.outcome = outcome
        self.recordID = recordID
        self.revision = revision
        self.currentSession = currentSession
        self.blockReason = blockReason
        self.message = try TrainingText.optional(message, field: "receipt message", maximumBytes: 400)
    }

    private enum CodingKeys: String, CodingKey {
        case mutationID, outcome, recordID, revision, currentSession, blockReason, message
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["mutationID", "outcome", "recordID", "revision", "currentSession", "blockReason", "message"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingCommitReceipt(
            mutationID: c.decode(TrainingRecordID.self, forKey: .mutationID),
            outcome: c.decode(Outcome.self, forKey: .outcome),
            recordID: c.decodeIfPresent(TrainingRecordID.self, forKey: .recordID),
            revision: c.decodeIfPresent(Int.self, forKey: .revision),
            currentSession: c.decodeIfPresent(TrainingSession.self, forKey: .currentSession),
            blockReason: c.decodeIfPresent(BlockReason.self, forKey: .blockReason),
            message: c.decodeIfPresent(String.self, forKey: .message)
        )
    }
}

/// Receipt fingerprints are versioned because schema 1 encoded dates as
/// ISO-8601 strings while schema 2 uses lossless numeric reference-date
/// seconds. The version travels with a migrated receipt; the original
/// mutation payload is never reconstructed from the current session.
public enum TrainingFingerprintVersion: String, Codable, CaseIterable, Sendable {
    case legacyISO8601V1 = "iso8601_v1"
    case losslessNumericV2 = "numeric_v2"
}

public struct TrainingReceiptJournalEntry: Codable, Equatable, Sendable {
    public let mutationID: TrainingRecordID
    public let payloadFingerprint: String
    public let payloadFingerprintVersion: TrainingFingerprintVersion
    public let receipt: TrainingCommitReceipt

    public init(
        mutationID: TrainingRecordID,
        payloadFingerprint: String,
        payloadFingerprintVersion: TrainingFingerprintVersion = .losslessNumericV2,
        receipt: TrainingCommitReceipt
    ) throws {
        guard mutationID == receipt.mutationID,
              payloadFingerprint.utf8.count == 64,
              payloadFingerprint.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw TrainingValidationError.invalidIdentifier
        }
        self.mutationID = mutationID
        self.payloadFingerprint = payloadFingerprint
        self.payloadFingerprintVersion = payloadFingerprintVersion
        self.receipt = receipt
    }

    private enum CodingKeys: String, CodingKey {
        case mutationID, payloadFingerprint, payloadFingerprintVersion, receipt
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownTrainingKeys(decoder, allowed: ["mutationID", "payloadFingerprint", "payloadFingerprintVersion", "receipt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self = try TrainingReceiptJournalEntry(
            mutationID: c.decode(TrainingRecordID.self, forKey: .mutationID),
            payloadFingerprint: c.decode(String.self, forKey: .payloadFingerprint),
            payloadFingerprintVersion: c.decodeIfPresent(TrainingFingerprintVersion.self, forKey: .payloadFingerprintVersion) ?? .losslessNumericV2,
            receipt: c.decode(TrainingCommitReceipt.self, forKey: .receipt)
        )
    }
}

public enum TrainingHistorySort {
    public static func newestFirst(_ lhs: TrainingHistoryItem, _ rhs: TrainingHistoryItem) -> Bool {
        if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
        return lhs.id.rawValue < rhs.id.rawValue
    }
}

public struct TrainingHistoryPage: Equatable, Sendable {
    public let items: [TrainingHistoryItem]
    public let offset: Int
    public let limit: Int
    public let totalCount: Int
    public let hasMore: Bool

    public init(items: [TrainingHistoryItem], offset: Int, limit: Int, totalCount: Int) {
        self.items = items
        self.offset = offset
        self.limit = limit
        self.totalCount = totalCount
        self.hasMore = offset + items.count < totalCount
    }
}

public enum TrainingFingerprint {
    public static func hex(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func hex(
        for mutation: TrainingMutation,
        version: TrainingFingerprintVersion = .losslessNumericV2
    ) throws -> String {
        let data: Data
        switch version {
        case .losslessNumericV2:
            data = try TrainingDateCoding.makeEncoder().encode(mutation)
        case .legacyISO8601V1:
            data = try legacyISO8601Data(for: mutation, includingFractionalSeconds: true)
        }
        return hex(data: data)
    }

    /// Schema 1 deployments existed with both Foundation's `.iso8601`
    /// formatter and the fractional ISO formatter used by the migration
    /// fixture. Accept both representations for the explicitly legacy
    /// version; this is a fingerprint comparison only and never recreates a
    /// missing mutation payload.
    public static func legacyCandidates(for mutation: TrainingMutation) throws -> Set<String> {
        let fractional = try hex(for: mutation, version: .legacyISO8601V1)
        let plainData = try legacyISO8601Data(for: mutation, includingFractionalSeconds: false)
        let plain = hex(data: plainData)
        return [fractional, plain]
    }

    private static func legacyISO8601Data(
        for mutation: TrainingMutation,
        includingFractionalSeconds: Bool
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if includingFractionalSeconds {
            encoder.dateEncodingStrategy = .custom { date, encoder in
                let seconds = date.timeIntervalSinceReferenceDate
                guard seconds.isFinite else {
                    throw EncodingError.invalidValue(date, .init(
                        codingPath: encoder.codingPath,
                        debugDescription: "Training dates must be finite"
                    ))
                }
                let wholeSeconds = seconds.rounded(.towardZero)
                let fractionalDigits = String(format: "%.9f", seconds - wholeSeconds).dropFirst(2)
                let wholeDate = Date(timeIntervalSinceReferenceDate: wholeSeconds)
                let base = Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(wholeDate)
                var container = encoder.singleValueContainer()
                try container.encode(base.replacingOccurrences(of: "Z", with: ".\(fractionalDigits)Z"))
            }
        } else {
            encoder.dateEncodingStrategy = .iso8601
        }
        return try encoder.encode(mutation)
    }
}
