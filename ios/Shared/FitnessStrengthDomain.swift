import Foundation
import Combine

// MARK: - Strength source contract (Bevel IMG_0393)

/// The six muscle groups shown by the Strength surface.  This is a display
/// taxonomy, not a claim that a provider can infer anatomy from an unlabeled
/// workout.
public enum FitnessStrengthMuscleGroup: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case arms
    case core
    case chest
    case back
    case legs
    case shoulders

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .arms: "Arms"
        case .core: "Core"
        case .chest: "Chest"
        case .back: "Back"
        case .legs: "Legs"
        case .shoulders: "Shoulders"
        }
    }

    public var shortTitle: String {
        switch self {
        case .arms: "Arms"
        case .core: "Core"
        case .chest: "Chest"
        case .back: "Back"
        case .legs: "Legs"
        case .shoulders: "Shoulders"
        }
    }
}

/// A source-backed kilogram value.  Missing data is deliberately not
/// represented by `0`; zero is an observed value only when its source says so.
public struct FitnessStrengthMetric: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        case unavailable(reason: String)
        case calibrating(reason: String)
        case observed(kilograms: Double, window: String, provenance: String)
        case demo(kilograms: Double, window: String, provenance: String)
    }

    public let id: String
    public let group: FitnessStrengthMuscleGroup
    public let state: State
    /// Source availability is independent from the value payload. A stale or
    /// partial kilogram observation may remain visible with an explicit label;
    /// permission, device, read, conflict, and error states remain value-less.
    public let sourceState: FitnessMetric.SourceState

    public init(
        group: FitnessStrengthMuscleGroup,
        state: State,
        sourceState: FitnessMetric.SourceState? = nil
    ) {
        self.id = group.rawValue
        self.group = group
        let validatedState = Self.validated(state)
        self.state = validatedState
        self.sourceState = Self.resolvedSourceState(sourceState, for: validatedState)
    }

    public var kilograms: Double? {
        guard sourceState.canDisplayValue else { return nil }
        switch state {
        case .observed(let kilograms, _, _), .demo(let kilograms, _, _):
            return kilograms
        case .unavailable, .calibrating:
            return nil
        }
    }

    public var isDemo: Bool {
        if case .demo = state { return true }
        return false
    }

    public var sourceDetail: String? {
        switch state {
        case .observed(_, let window, let provenance), .demo(_, let window, let provenance):
            let detail = "\(window) · \(provenance)"
            return sourceState == .observed || sourceState == .demo
                ? detail
                : "\(sourceState.label) · \(detail)"
        case .unavailable, .calibrating:
            return nil
        }
    }

    fileprivate static func validated(_ state: State) -> State {
        switch state {
        case .unavailable(let reason):
            return .unavailable(reason: normalizedReason(reason, fallback: "No source strength observation is available."))
        case .calibrating(let reason):
            return .calibrating(reason: normalizedReason(reason, fallback: "Strength history is still calibrating."))
        case .observed(let kilograms, let window, let provenance):
            guard validValue(kilograms), validText(window), validText(provenance) else {
                return .unavailable(reason: "A source window, provenance, and valid kilogram value are required.")
            }
            return .observed(kilograms: kilograms, window: window.trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance.trimmingCharacters(in: .whitespacesAndNewlines))
        case .demo(let kilograms, let window, let provenance):
            guard validValue(kilograms), validText(window), validText(provenance) else {
                return .unavailable(reason: "The fixture value is invalid or missing its source label.")
            }
            return .demo(kilograms: kilograms, window: window.trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func validValue(_ value: Double) -> Bool {
        value.isFinite && value >= 0 && value <= 1_000_000
    }

    private static func validText(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 240
    }

    private static func normalizedReason(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : String(trimmed.prefix(240))
    }

    public static func unavailable(
        group: FitnessStrengthMuscleGroup,
        reason: String = "No source strength observation is available.",
        sourceState: FitnessMetric.SourceState? = nil
    ) -> FitnessStrengthMetric {
        FitnessStrengthMetric(group: group, state: .unavailable(reason: reason), sourceState: sourceState)
    }

    private static func resolvedSourceState(
        _ requested: FitnessMetric.SourceState?,
        for state: State
    ) -> FitnessMetric.SourceState {
        let fallback: FitnessMetric.SourceState
        switch state {
        case .unavailable: fallback = .unavailable
        case .calibrating: fallback = .calibrating
        case .observed: fallback = .observed
        case .demo: fallback = .demo
        }

        guard let requested else { return fallback }
        switch state {
        case .demo:
            return .demo
        case .observed:
            switch requested {
            case .observed, .partial, .stale:
                return requested
            default:
                return .observed
            }
        case .unavailable, .calibrating:
            switch requested {
            case .permissionRequired, .deviceUnavailable, .readIndeterminate,
                 .partial, .stale, .conflict, .error:
                return requested
            default:
                return fallback
            }
        }
    }
}

/// The aggregate total has its own identity so a total volume observation can
/// never be mistaken for a chest observation merely because both use kg.
public struct FitnessStrengthAggregate: Equatable, Identifiable, Sendable {
    public let id = "total-volume"
    public let title = "Total volume"
    public let state: FitnessStrengthMetric.State
    public let sourceState: FitnessMetric.SourceState

    public init(
        state: FitnessStrengthMetric.State = .unavailable(reason: "No source strength total is available."),
        sourceState: FitnessMetric.SourceState? = nil
    ) {
        // Reuse the metric boundary for finite values and source metadata; the
        // aggregate's identity remains independent of any muscle group.
        self.state = FitnessStrengthMetric.validated(state)
        self.sourceState = Self.resolvedSourceState(sourceState, for: self.state)
    }

    public var kilograms: Double? {
        guard sourceState.canDisplayValue else { return nil }
        switch state {
        case .observed(let kilograms, _, _), .demo(let kilograms, _, _): return kilograms
        case .unavailable, .calibrating: return nil
        }
    }

    public static func unavailable(
        reason: String = "No source strength total is available.",
        sourceState: FitnessMetric.SourceState? = nil
    ) -> FitnessStrengthAggregate {
        FitnessStrengthAggregate(state: .unavailable(reason: reason), sourceState: sourceState)
    }

    private static func resolvedSourceState(
        _ requested: FitnessMetric.SourceState?,
        for state: FitnessStrengthMetric.State
    ) -> FitnessMetric.SourceState {
        let fallback: FitnessMetric.SourceState
        switch state {
        case .unavailable: fallback = .unavailable
        case .calibrating: fallback = .calibrating
        case .observed: fallback = .observed
        case .demo: fallback = .demo
        }

        guard let requested else { return fallback }
        switch state {
        case .demo:
            return .demo
        case .observed:
            switch requested {
            case .observed, .partial, .stale:
                return requested
            default:
                return .observed
            }
        case .unavailable, .calibrating:
            switch requested {
            case .permissionRequired, .deviceUnavailable, .readIndeterminate,
                 .partial, .stale, .conflict, .error:
                return requested
            default:
                return fallback
            }
        }
    }
}

public struct FitnessStrengthProgressPoint: Equatable, Identifiable, Sendable {
    public let date: Date
    public let kilograms: Double

    public var id: Date { date }

    public init?(date: Date, kilograms: Double) {
        guard date.timeIntervalSinceReferenceDate.isFinite,
              kilograms.isFinite, kilograms >= 0, kilograms <= 1_000_000 else { return nil }
        self.date = date
        self.kilograms = kilograms
    }
}

public enum FitnessStrengthProgressState: Equatable, Sendable {
    case empty(reason: String)
    case observed(points: [FitnessStrengthProgressPoint], window: String, provenance: String)
    case demo(points: [FitnessStrengthProgressPoint], window: String, provenance: String)

    public var points: [FitnessStrengthProgressPoint] {
        switch self {
        case .empty: []
        case .observed(let points, _, _), .demo(let points, _, _): points
        }
    }

    public var isDemo: Bool {
        if case .demo = self { return true }
        return false
    }
}

/// A complete source-aware snapshot for the Strength detail.  Adapters should
/// pass all six groups, even when they are unavailable, so the view never
/// turns an omitted sample into a zero.
public struct FitnessStrengthSnapshot: Equatable, Sendable {
    public let totalVolume: FitnessStrengthAggregate
    public let groups: [FitnessStrengthMetric]
    public let progress: FitnessStrengthProgressState

    public init(
        totalVolume: FitnessStrengthAggregate = .unavailable(),
        groups: [FitnessStrengthMetric] = [],
        progress: FitnessStrengthProgressState = .empty(reason: "No strength activity was recorded in the selected window.")
    ) {
        self.totalVolume = totalVolume
        var byGroup = Dictionary(uniqueKeysWithValues: groups.map { ($0.group, $0) })
        self.groups = FitnessStrengthMuscleGroup.allCases.map { group in
            byGroup.removeValue(forKey: group) ?? .unavailable(group: group)
        }
        self.progress = Self.validatedProgress(progress)
    }

    public func metric(for group: FitnessStrengthMuscleGroup) -> FitnessStrengthMetric {
        groups.first(where: { $0.group == group }) ?? .unavailable(group: group)
    }

    private static func validatedProgress(_ state: FitnessStrengthProgressState) -> FitnessStrengthProgressState {
        switch state {
        case .empty(let reason):
            let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            return .empty(reason: trimmed.isEmpty ? "No strength activity was recorded in the selected window." : String(trimmed.prefix(240)))
        case .observed(let points, let window, let provenance):
            guard validProgress(points: points, window: window, provenance: provenance) else {
                return .empty(reason: "Progress needs a valid source window and provenance before it can be shown.")
            }
            return .observed(points: points.sorted { $0.date < $1.date }, window: window.trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance.trimmingCharacters(in: .whitespacesAndNewlines))
        case .demo(let points, let window, let provenance):
            guard validProgress(points: points, window: window, provenance: provenance) else {
                return .empty(reason: "The fixture progress series is invalid or missing its source label.")
            }
            return .demo(points: points.sorted { $0.date < $1.date }, window: window.trimmingCharacters(in: .whitespacesAndNewlines), provenance: provenance.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    private static func validProgress(points: [FitnessStrengthProgressPoint], window: String, provenance: String) -> Bool {
        guard !points.isEmpty,
              points.count <= 366,
              validSourceText(window),
              validSourceText(provenance) else { return false }
        var dates = Set<Date>()
        return points.allSatisfy { dates.insert($0.date).inserted }
    }

    private static func validSourceText(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.utf16.count <= 240
    }

    /// Explicit visual fixture for screenshot work. It is never a default
    /// source and the provenance remains visible to the caller/UI.
    public static func demo(anchor: Date) -> FitnessStrengthSnapshot {
        let calendar = Calendar(identifier: .gregorian)
        let start = calendar.startOfDay(for: anchor)
        let values: [FitnessStrengthMuscleGroup: Double] = [
            .arms: 42, .core: 24, .chest: 56, .back: 64, .legs: 88, .shoulders: 38
        ]
        let window = "Last 30 days · demo fixture"
        let provenance = "DEMO · NOT LIVE · explicit fixture field"
        let metrics = FitnessStrengthMuscleGroup.allCases.map { group in
            FitnessStrengthMetric(group: group, state: .demo(kilograms: values[group] ?? 0, window: window, provenance: provenance))
        }
        let points = (0..<6).compactMap { index -> FitnessStrengthProgressPoint? in
            guard let date = calendar.date(byAdding: .day, value: index * 5 - 25, to: start) else { return nil }
            return FitnessStrengthProgressPoint(date: date, kilograms: Double(120 + index * 18))
        }
        return FitnessStrengthSnapshot(
            totalVolume: FitnessStrengthAggregate(state: .demo(kilograms: 312, window: window, provenance: provenance)),
            groups: metrics,
            progress: .demo(points: points, window: window, provenance: provenance)
        )
    }
}

// MARK: - User-entered training templates

public enum FitnessStrengthTemplateValidationError: Error, Equatable, LocalizedError, Sendable {
    case invalidIdentifier
    case invalidName
    case invalidExerciseName
    case invalidSets
    case invalidRepetitions
    case invalidLoad
    case duplicateExerciseIdentifier(String)
    case tooManyExercises
    case tooManyTemplates
    case invalidDates
    case persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: "This template identifier is invalid."
        case .invalidName: "Give the training template a name."
        case .invalidExerciseName: "Each exercise needs a name."
        case .invalidSets: "Sets must be between 1 and 100."
        case .invalidRepetitions: "Repetitions must be between 1 and 1,000."
        case .invalidLoad: "Load must be a finite kilogram value from 0 to 1,000,000."
        case .duplicateExerciseIdentifier(let id): "Exercise identifier \(id) is duplicated."
        case .tooManyExercises: "A template can contain at most 100 exercises."
        case .tooManyTemplates: "LifeOS can store at most 100 training templates."
        case .invalidDates: "Template dates are invalid."
        case .persistenceFailed: "The training template could not be saved locally."
        }
    }
}

private struct FitnessStrengthAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownStrengthKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: FitnessStrengthAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown strength template field"))
    }
}

private func validStrengthIdentifier(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard (1...128).contains(bytes.count), let first = bytes.first else { return false }
    func alphaNumeric(_ byte: UInt8) -> Bool { (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte) }
    return alphaNumeric(first) && bytes.dropFirst().allSatisfy { alphaNumeric($0) || $0 == 45 || $0 == 95 }
}

private func validStrengthText(_ value: String, maximum: Int) -> Bool {
    !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= maximum
}

public struct FitnessStrengthExercise: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var muscleGroup: FitnessStrengthMuscleGroup
    public var sets: Int
    public var repetitions: Int
    public var loadKilograms: Double?

    private enum CodingKeys: String, CodingKey { case id, name, muscleGroup, sets, repetitions, loadKilograms }

    public init(
        id: String = UUID().uuidString,
        name: String,
        muscleGroup: FitnessStrengthMuscleGroup,
        sets: Int = 3,
        repetitions: Int = 8,
        loadKilograms: Double? = nil
    ) throws {
        self.id = id
        self.name = name
        self.muscleGroup = muscleGroup
        self.sets = sets
        self.repetitions = repetitions
        self.loadKilograms = loadKilograms
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownStrengthKeys(decoder, allowed: ["id", "name", "muscleGroup", "sets", "repetitions", "loadKilograms"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        muscleGroup = try c.decode(FitnessStrengthMuscleGroup.self, forKey: .muscleGroup)
        sets = try c.decode(Int.self, forKey: .sets)
        repetitions = try c.decode(Int.self, forKey: .repetitions)
        loadKilograms = try c.decodeIfPresent(Double.self, forKey: .loadKilograms)
        try validate()
    }

    public func validate() throws {
        guard validStrengthIdentifier(id) else { throw FitnessStrengthTemplateValidationError.invalidIdentifier }
        guard validStrengthText(name, maximum: 100) else { throw FitnessStrengthTemplateValidationError.invalidExerciseName }
        guard (1...100).contains(sets) else { throw FitnessStrengthTemplateValidationError.invalidSets }
        guard (1...1_000).contains(repetitions) else { throw FitnessStrengthTemplateValidationError.invalidRepetitions }
        if let loadKilograms {
            guard loadKilograms.isFinite, loadKilograms >= 0, loadKilograms <= 1_000_000 else {
                throw FitnessStrengthTemplateValidationError.invalidLoad
            }
        }
    }
}

public struct FitnessStrengthTemplate: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var exercises: [FitnessStrengthExercise]
    public let createdAt: Date
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey { case id, name, exercises, createdAt, updatedAt }

    public init(
        id: String = UUID().uuidString,
        name: String,
        exercises: [FitnessStrengthExercise] = [],
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) throws {
        self.id = id
        self.name = name
        self.exercises = exercises
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        try validate()
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownStrengthKeys(decoder, allowed: ["id", "name", "exercises", "createdAt", "updatedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        exercises = try c.decode([FitnessStrengthExercise].self, forKey: .exercises)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        try validate()
    }

    public func validate() throws {
        guard validStrengthIdentifier(id) else { throw FitnessStrengthTemplateValidationError.invalidIdentifier }
        guard validStrengthText(name, maximum: 100) else { throw FitnessStrengthTemplateValidationError.invalidName }
        guard exercises.count <= 100 else { throw FitnessStrengthTemplateValidationError.tooManyExercises }
        var identifiers = Set<String>()
        for exercise in exercises {
            try exercise.validate()
            guard identifiers.insert(exercise.id).inserted else {
                throw FitnessStrengthTemplateValidationError.duplicateExerciseIdentifier(exercise.id)
            }
        }
        guard createdAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt.timeIntervalSinceReferenceDate.isFinite,
              updatedAt >= createdAt else {
            throw FitnessStrengthTemplateValidationError.invalidDates
        }
    }
}

/// Small local-first store for user-entered templates.  The write happens
/// before the published array changes, so a failed disk write cannot leave the
/// view claiming that a template exists when it does not.
public final class FitnessStrengthTemplateStore: ObservableObject {
    @Published public private(set) var templates: [FitnessStrengthTemplate]
    @Published public private(set) var lastSaveError: String?
    @Published public private(set) var integrityWarning: String?

    private let persistenceURL: URL?
    private static let maximumPersistenceBytes = 2 * 1_024 * 1_024

    public init(initialTemplates: [FitnessStrengthTemplate] = [], persistenceURL: URL? = FitnessStrengthTemplateStore.defaultPersistenceURL) {
        self.persistenceURL = persistenceURL
        self.templates = []
        self.lastSaveError = nil
        self.integrityWarning = nil

        var source = initialTemplates
        if let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) {
            let size = (try? FileManager.default.attributesOfItem(atPath: persistenceURL.path)[.size] as? NSNumber)?.intValue ?? 0
            if size > Self.maximumPersistenceBytes {
                self.integrityWarning = "Training templates could not be read; showing valid local templates only."
            } else {
                do {
                    source = try Self.decode(from: Data(contentsOf: persistenceURL))
                } catch {
                    self.integrityWarning = "Training templates could not be read; showing valid local templates only."
                }
            }
        }
        self.templates = Self.validatedTemplates(source)
    }

    public static var defaultPersistenceURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return support.appendingPathComponent("LifeOS", isDirectory: true).appendingPathComponent("fitness-strength-templates.json")
    }

    public func template(id: String) -> FitnessStrengthTemplate? {
        templates.first { $0.id == id }
    }

    public func upsert(_ template: FitnessStrengthTemplate) throws {
        do {
            try template.validate()
            var candidate = templates
            if let index = candidate.firstIndex(where: { $0.id == template.id }) {
                candidate[index] = template
            } else {
                guard candidate.count < 100 else { throw FitnessStrengthTemplateValidationError.tooManyTemplates }
                candidate.append(template)
            }
            try persist(candidate)
            templates = candidate
            lastSaveError = nil
        } catch let error as FitnessStrengthTemplateValidationError {
            lastSaveError = error.localizedDescription
            throw error
        } catch {
            lastSaveError = FitnessStrengthTemplateValidationError.persistenceFailed.localizedDescription
            throw FitnessStrengthTemplateValidationError.persistenceFailed
        }
    }

    @discardableResult
    public func delete(id: String) throws -> Bool {
        guard templates.contains(where: { $0.id == id }) else { return false }
        let candidate = templates.filter { $0.id != id }
        do {
            try persist(candidate)
            templates = candidate
            lastSaveError = nil
            return true
        } catch {
            lastSaveError = FitnessStrengthTemplateValidationError.persistenceFailed.localizedDescription
            throw FitnessStrengthTemplateValidationError.persistenceFailed
        }
    }

    private func persist(_ value: [FitnessStrengthTemplate]) throws {
        guard let persistenceURL else { throw FitnessStrengthTemplateValidationError.persistenceFailed }
        let directory = persistenceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumPersistenceBytes else {
            throw FitnessStrengthTemplateValidationError.persistenceFailed
        }
#if os(iOS)
        try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])
#else
        try data.write(to: persistenceURL, options: [.atomic])
#endif
    }

    private static func decode(from data: Data) throws -> [FitnessStrengthTemplate] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = try decoder.decode([FitnessStrengthTemplate].self, from: data)
        return try validatedTemplatesOrThrow(values)
    }

    private static func validatedTemplates(_ values: [FitnessStrengthTemplate]) -> [FitnessStrengthTemplate] {
        (try? validatedTemplatesOrThrow(values)) ?? []
    }

    private static func validatedTemplatesOrThrow(_ values: [FitnessStrengthTemplate]) throws -> [FitnessStrengthTemplate] {
        guard values.count <= 100 else { throw FitnessStrengthTemplateValidationError.tooManyTemplates }
        var identifiers = Set<String>()
        for value in values {
            try value.validate()
            guard identifiers.insert(value.id).inserted else {
                throw FitnessStrengthTemplateValidationError.duplicateExerciseIdentifier(value.id)
            }
        }
        return values
    }
}
