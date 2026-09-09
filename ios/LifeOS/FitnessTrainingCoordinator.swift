import Combine
import Foundation

/// The source of a template shown by the local training surface.
public enum FitnessTrainingTemplateSource: String, CaseIterable, Equatable, Sendable {
    case starter
    case saved

    public var label: String {
        switch self {
        case .starter: "Starter"
        case .saved: "Saved locally"
        }
    }
}

/// A display-ready template option.  The training snapshot is the immutable
/// payload handed to `FitnessTrainingStore`; `editableTemplate` is present
/// only for templates backed by the existing strength template persistence.
public struct FitnessTrainingTemplateOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let activityKind: TrainingActivityKind
    public let snapshot: TrainingTemplateSnapshot
    public let source: FitnessTrainingTemplateSource
    public let editableTemplate: FitnessStrengthTemplate?

    public init(
        id: String,
        name: String,
        activityKind: TrainingActivityKind,
        snapshot: TrainingTemplateSnapshot,
        source: FitnessTrainingTemplateSource,
        editableTemplate: FitnessStrengthTemplate? = nil
    ) {
        self.id = id
        self.name = name
        self.activityKind = activityKind
        self.snapshot = snapshot
        self.source = source
        self.editableTemplate = editableTemplate
    }

    public var exerciseCount: Int { snapshot.exercises.count }

    public var detail: String {
        let count = exerciseCount == 1 ? "1 exercise" : "\(exerciseCount) exercises"
        return "\(count) · \(source.label)"
    }
}

public enum FitnessTrainingDataQuality: Equatable, Sendable {
    case current
    case stale(detail: String)
    case unavailable(detail: String)

    public var label: String {
        switch self {
        case .current: "Current"
        case .stale: "Stale"
        case .unavailable: "Unavailable"
        }
    }
}

public enum FitnessTrainingNotice: Equatable, Sendable {
    case info(String)
    case error(String)

    public var message: String {
        switch self {
        case .info(let message), .error(let message): message
        }
    }

    public var isError: Bool {
        if case .error = self { return true }
        return false
    }
}

public enum FitnessTrainingLoadState: Equatable, Sendable {
    case idle
    case loading
    case ready
    case saving
    case failed(message: String)
    case recoveryRequired(message: String)
}

/// The UI receives an explicit durable outcome for every session action. A
/// failed store operation must leave the editor open with its draft intact.
public struct FitnessTrainingActionResult: Equatable, Sendable {
    public let didPersist: Bool
    public let message: String?

    public init(didPersist: Bool, message: String? = nil) {
        self.didPersist = didPersist
        self.message = message
    }

    public static func success(message: String? = nil) -> Self {
        Self(didPersist: true, message: message)
    }

    public static func failure(_ message: String) -> Self {
        Self(didPersist: false, message: message)
    }
}

/// The local boundary used by history and statistics caches. The ledger
/// generation covers its durable bytes; integrity and freshness also remain in
/// the token so a retained diagnostic snapshot can never be reused as current
/// data. `calendarDay` invalidates date-sensitive statistics at the product's
/// calendar boundary without comparing every session again.
public struct FitnessTrainingProjectionRevision: Equatable, Sendable {
    public let generation: String?
    public let integrity: TrainingStoreIntegrity
    public let freshness: TrainingStoreFreshness
    public let calendarDay: String

    public init(
        snapshot: TrainingStoreSnapshot,
        now: Date,
        calendar: Calendar = TrainingHistoryProjection.berlinCalendar()
    ) {
        generation = snapshot.generation
        integrity = snapshot.integrity
        freshness = snapshot.freshness
        let components = calendar.dateComponents([.era, .year, .month, .day], from: now)
        calendarDay = [
            components.era ?? 0,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        ].map(String.init).joined(separator: "-")
    }
}

/// Calendar boundaries used by date-sensitive training projections. Berlin is
/// the product calendar, so adding a calendar day (rather than 24 hours) keeps
/// the boundary correct across daylight-saving transitions.
public enum FitnessTrainingCalendarBoundary {
    public static func nextBerlinMidnight(after date: Date) -> Date {
        let calendar = TrainingHistoryProjection.berlinCalendar()
        let startOfDay = calendar.startOfDay(for: date)
        return calendar.date(byAdding: .day, value: 1, to: startOfDay)
            ?? date.addingTimeInterval(24 * 60 * 60)
    }
}

/// One published state object gives the views a coherent local snapshot.  The
/// state never contains imported HealthKit/Zepp values; those remain a
/// separate read-only projection owned by the fitness module.
public struct FitnessTrainingState: Equatable, Sendable {
    public var loadState: FitnessTrainingLoadState
    public var templates: [FitnessTrainingTemplateOption]
    public var sessions: [TrainingSession]
    public var history: [TrainingHistoryItem]
    public var activeSession: TrainingSession?
    public var latestCompletedSession: TrainingSession?
    public var dataQuality: FitnessTrainingDataQuality
    public var notice: FitnessTrainingNotice?
    public var templateWarning: String?

    public init(
        loadState: FitnessTrainingLoadState = .idle,
        templates: [FitnessTrainingTemplateOption] = [],
        sessions: [TrainingSession] = [],
        history: [TrainingHistoryItem] = [],
        activeSession: TrainingSession? = nil,
        latestCompletedSession: TrainingSession? = nil,
        dataQuality: FitnessTrainingDataQuality = .current,
        notice: FitnessTrainingNotice? = nil,
        templateWarning: String? = nil
    ) {
        self.loadState = loadState
        self.templates = templates
        self.sessions = sessions
        self.history = history
        self.activeSession = activeSession
        self.latestCompletedSession = latestCompletedSession
        self.dataQuality = dataQuality
        self.notice = notice
        self.templateWarning = templateWarning
    }
}

/// Main-actor coordinator for the local-first workout experience.
///
/// There is one durable `FitnessTrainingStore` actor per coordinator.  User
/// templates continue to use the already shipped `FitnessStrengthTemplateStore`
/// file, so this tranche does not create a second template persistence format.
/// Starter templates are bounded in-memory conveniences and are never silently
/// written to the user's saved-template file.
@MainActor
public final class FitnessTrainingCoordinator: ObservableObject {
    @Published public private(set) var state: FitnessTrainingState
    @Published public private(set) var historyProjectionRevision: FitnessTrainingProjectionRevision

    private let trainingStore: FitnessTrainingStore
    private let templateStore: FitnessStrengthTemplateStore
    private let clock: @Sendable () -> Date
    private var mutationID: UUID?
    private var refreshInFlight = false
    private var localHistorySnapshot: TrainingStoreSnapshot

    public init(
        trainingStore: FitnessTrainingStore? = nil,
        templateStore: FitnessStrengthTemplateStore? = nil,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.clock = clock
        self.trainingStore = trainingStore ?? FitnessTrainingStore(clock: clock)
        self.templateStore = templateStore ?? FitnessStrengthTemplateStore()
        let options = Self.makeTemplateOptions(from: self.templateStore.templates)
        let initialNow = clock()
        self.localHistorySnapshot = TrainingStoreSnapshot(
            sessions: [],
            generation: nil,
            integrity: .verified,
            freshness: .current,
            capturedAt: initialNow
        )
        self.historyProjectionRevision = FitnessTrainingProjectionRevision(
            snapshot: self.localHistorySnapshot,
            now: initialNow
        )
        self.state = FitnessTrainingState(
            templates: options,
            templateWarning: self.templateStore.integrityWarning
        )
    }

    /// Whether a durable mutation or recovery read is currently running.
    public var isBusy: Bool { mutationID != nil || refreshInFlight }

    public func refresh() async {
        guard mutationID == nil, !refreshInFlight else { return }
        refreshInFlight = true
        state.loadState = .loading
        await reloadSnapshot()
        refreshInFlight = false
    }

    public func retry() async {
        await refresh()
    }

    /// Returns the latest immutable local read transaction for composition with
    /// a separate, read-only imported source. The coordinator remains the sole
    /// owner of the local ledger; callers cannot mutate or replace this value.
    public func historyProjection(
        importedSnapshot: TrainingImportedHistorySnapshot? = nil,
        now: Date? = nil
    ) -> TrainingHistoryProjection {
        TrainingHistoryProjection(
            localSnapshot: localHistorySnapshot,
            importedSnapshot: importedSnapshot,
            now: now ?? clock()
        )
    }

    /// Returns the same immutable ledger boundary with a current calendar
    /// token. This lets a long-lived view invalidate date-sensitive work at
    /// midnight even when the ledger bytes did not change.
    public func currentHistoryProjectionRevision(now: Date? = nil) -> FitnessTrainingProjectionRevision {
        FitnessTrainingProjectionRevision(
            snapshot: localHistorySnapshot,
            now: now ?? clock()
        )
    }

    /// Returns the next Berlin midnight using the injected clock by default.
    /// Passing the last boundary advances by a calendar day even when a test
    /// clock or a suspended process has not moved forward yet.
    public func nextHistoryProjectionBoundary(after date: Date? = nil) -> Date {
        FitnessTrainingCalendarBoundary.nextBerlinMidnight(after: date ?? clock())
    }

    /// Publishes a date boundary without rereading the ledger. The view uses
    /// this after the one scheduled midnight wake so history and statistics
    /// invalidate even when the durable bytes are unchanged.
    public func refreshHistoryProjectionBoundary(now: Date? = nil) {
        let revision = currentHistoryProjectionRevision(now: now)
        if revision != historyProjectionRevision {
            historyProjectionRevision = revision
        }
    }

    @discardableResult
    public func start(
        template: FitnessTrainingTemplateOption,
        title: String? = nil
    ) async -> TrainingCommitReceipt? {
        guard state.activeSession == nil else {
            state.notice = .error("Finish or discard the current session before starting another.")
            return nil
        }

        return await executeMutation { mutationID in
            try await self.trainingStore.begin(
                template: template.snapshot,
                title: title?.trimmedOrNil,
                activityKind: template.activityKind,
                mutationID: mutationID
            )
        }
    }

    /// Saves an edited active or paused draft.  The store's revision check is
    /// the final authority, so a stale UI draft becomes an honest conflict.
    @discardableResult
    public func save(draft: TrainingSession) async -> TrainingCommitReceipt? {
        guard draft.status == .active || draft.status == .paused else {
            state.notice = .error("Only an active or paused session can be edited.")
            return nil
        }

        return await executeMutation { mutationID in
            try await self.trainingStore.update(
                draft,
                expectedRevision: draft.revision,
                mutationID: mutationID
            )
        }
    }

    /// Saves the current edits and opens a rest interval in one revision.
    @discardableResult
    public func pause(draft: TrainingSession) async -> TrainingCommitReceipt? {
        guard draft.status == .active else {
            state.notice = .error("This session is already paused or finished.")
            return nil
        }
        do {
            let now = try eventDate(atLeast: draft.startedAt)
            let pause = try TrainingPauseInterval(startedAt: now, now: now)
            let paused = try makeSession(
                from: draft,
                status: .paused,
                endedAt: nil,
                pauses: draft.pauses + [pause],
                updatedAt: now,
                now: now
            )
            return await save(draft: paused)
        } catch {
            record(error: error)
            return nil
        }
    }

    /// Closes the open rest interval in one revision.  No duration is
    /// inferred when the injected clock has not advanced.
    @discardableResult
    public func resume(draft: TrainingSession) async -> TrainingCommitReceipt? {
        guard draft.status == .paused,
              let openPause = draft.pauses.last,
              openPause.endedAt == nil else {
            state.notice = .error("This session is not paused.")
            return nil
        }
        do {
            let now = try eventDate(after: openPause.startedAt)
            let closedPause = try openPause.ended(at: now, now: now)
            var pauses = draft.pauses
            pauses[pauses.count - 1] = closedPause
            let resumed = try makeSession(
                from: draft,
                status: .active,
                endedAt: nil,
                pauses: pauses,
                updatedAt: now,
                now: now
            )
            return await save(draft: resumed)
        } catch {
            record(error: error)
            return nil
        }
    }

    /// Finishes a draft after closing a possible rest interval. Strength needs
    /// a completed local set; timed non-strength activity can finish without
    /// fabricated repetitions or load. Imported workouts never satisfy either
    /// local requirement.
    @discardableResult
    public func finish(draft: TrainingSession) async -> TrainingCommitReceipt? {
        guard draft.status == .active || draft.status == .paused else {
            state.notice = .error("This session cannot be finished in its current state.")
            return nil
        }
        do {
            let now = try eventDate(after: draft.startedAt)
            let closedPauses = try draft.pauses.map { pause in
                guard pause.endedAt == nil else { return pause }
                return try pause.ended(at: now, now: now)
            }
            let completed = try makeSession(
                from: draft,
                status: .completed,
                endedAt: now,
                pauses: closedPauses,
                updatedAt: now,
                now: now
            )
            return await executeMutation { mutationID in
                try await self.trainingStore.finish(
                    completed,
                    expectedRevision: completed.revision,
                    mutationID: mutationID
                )
            }
        } catch {
            record(error: error)
            return nil
        }
    }

    @discardableResult
    public func discard(sessionID: TrainingRecordID) async -> TrainingCommitReceipt? {
        guard let current = state.sessions.first(where: { $0.id == sessionID }) else {
            state.notice = .error("The local session is no longer available.")
            return nil
        }
        return await executeMutation { mutationID in
            try await self.trainingStore.discard(
                id: current.id,
                expectedRevision: current.revision,
                mutationID: mutationID
            )
        }
    }

    @discardableResult
    public func delete(sessionID: TrainingRecordID) async -> TrainingCommitReceipt? {
        guard let current = state.sessions.first(where: { $0.id == sessionID }) else {
            state.notice = .error("The local session is no longer available.")
            return nil
        }
        return await executeMutation { mutationID in
            try await self.trainingStore.delete(
                id: current.id,
                expectedRevision: current.revision,
                mutationID: mutationID
            )
        }
    }

    @discardableResult
    public func saveTemplate(_ template: FitnessStrengthTemplate) -> Bool {
        do {
            try templateStore.upsert(template)
            state.templates = Self.makeTemplateOptions(from: templateStore.templates)
            state.templateWarning = templateStore.integrityWarning
            state.notice = .info("\(template.name) is saved locally.")
            return true
        } catch {
            state.notice = .error(error.localizedDescription)
            return false
        }
    }

    public func deleteTemplate(id: String) {
        do {
            guard try templateStore.delete(id: id) else { return }
            state.templates = Self.makeTemplateOptions(from: templateStore.templates)
            state.templateWarning = templateStore.integrityWarning
            state.notice = .info("Template removed from this device.")
        } catch {
            state.notice = .error(error.localizedDescription)
        }
    }

    /// Recovery remains explicit and bounded by the actor's store. Callers
    /// that already have a destination URL can use the streaming overload;
    /// the SwiftUI surface uses `recoveryExportData()` for the in-memory
    /// `FileDocument` path without silently replacing a damaged ledger.
    public func exportRecovery(to destinationURL: URL) async -> Bool {
        do {
            try await trainingStore.export(to: destinationURL)
            state.notice = .info("The preserved training ledger was exported.")
            return true
        } catch {
            record(error: error)
            return false
        }
    }

    /// Prepares the bounded in-memory recovery document used by the SwiftUI
    /// file exporter. Oversized quarantined ledgers intentionally remain on the
    /// store's destination-based streaming path so this method never allocates
    /// an unbounded buffer in the app process.
    public func recoveryExportData() async -> Data? {
        do {
            let data = try await trainingStore.export()
            state.notice = .info("The preserved training ledger is ready to export.")
            return data
        } catch {
            record(error: error)
            return nil
        }
    }

    // MARK: - Serialized store work

    private func executeMutation(
        _ operation: @escaping (UUID) async throws -> TrainingCommitReceipt
    ) async -> TrainingCommitReceipt? {
        guard mutationID == nil, !Task.isCancelled else { return nil }
        let id = UUID()
        mutationID = id
        state.loadState = .saving

        do {
            let receipt = try await operation(id)
            // A cancelled caller may have cancelled the UI task, but the
            // actor can already have durably committed the mutation. Always
            // reread once so the published state cannot lie about that write.
            await reloadSnapshot()
            record(receipt: receipt)
            mutationID = nil
            return receipt
        } catch {
            record(error: error)
            mutationID = nil
            return nil
        }
    }

    private func reloadSnapshot() async {
        let options = Self.makeTemplateOptions(from: templateStore.templates)
        do {
            let snapshot = try await trainingStore.snapshot()
            let snapshotNow = clock()
            localHistorySnapshot = snapshot
            historyProjectionRevision = FitnessTrainingProjectionRevision(snapshot: snapshot, now: snapshotNow)
            var history: [TrainingHistoryItem] = []
            history.reserveCapacity(snapshot.sessions.count)
            var invalidHistoryCount = 0
            for session in snapshot.sessions where session.status != .discarded {
                do {
                    history.append(try TrainingHistoryItem(session: session, now: snapshotNow))
                } catch {
                    invalidHistoryCount += 1
                }
            }
            history.sort(by: TrainingHistorySort.newestFirst)

            let sessions = snapshot.sessions.sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt > rhs.startedAt }
                return lhs.id.rawValue < rhs.id.rawValue
            }
            let active = sessions.first { $0.status == .active || $0.status == .paused }
            let latestCompleted = sessions.first { $0.status == .completed }
            let quality: FitnessTrainingDataQuality
            if invalidHistoryCount > 0 {
                quality = .unavailable(detail: "Some local history records failed validation and remain hidden.")
            } else {
                switch (snapshot.integrity, snapshot.freshness) {
                case (.verified, .current): quality = .current
                case (_, .stale): quality = .stale(detail: "The last verified local ledger is retained for recovery.")
                default: quality = .unavailable(detail: "The local ledger needs recovery before it can be treated as current.")
                }
            }

            state = FitnessTrainingState(
                loadState: .ready,
                templates: options,
                sessions: sessions,
                history: history,
                activeSession: active,
                latestCompletedSession: latestCompleted,
                dataQuality: quality,
                notice: state.notice,
                templateWarning: templateStore.integrityWarning
            )
        } catch {
            let preservedSessions = state.sessions
            let preservedHistory = state.history
            let retainedNow = clock()
            let boundaryNow = retainedNow.timeIntervalSinceReferenceDate.isFinite ? retainedNow : Date()
            let unavailableSnapshot = TrainingStoreSnapshot(
                sessions: localHistorySnapshot.sessions,
                generation: localHistorySnapshot.generation,
                integrity: .unavailable,
                freshness: .stale,
                capturedAt: boundaryNow
            )
            localHistorySnapshot = unavailableSnapshot
            historyProjectionRevision = FitnessTrainingProjectionRevision(
                snapshot: unavailableSnapshot,
                now: boundaryNow
            )
            state.loadState = storeFailureState(for: error)
            state.templates = options
            state.sessions = preservedSessions
            state.history = preservedHistory
            state.activeSession = preservedSessions.first { $0.status == .active || $0.status == .paused }
            state.latestCompletedSession = preservedSessions.first { $0.status == .completed }
            state.dataQuality = .unavailable(detail: "The local ledger could not be read as current data.")
            state.templateWarning = templateStore.integrityWarning
            state.notice = .error(error.localizedDescription)
        }
    }

    private func record(receipt: TrainingCommitReceipt) {
        switch receipt.outcome {
        case .saved: state.notice = .info("Saved locally.")
        case .duplicate: state.notice = .info(receipt.message ?? "That action was already saved.")
        case .conflict: state.notice = .error(receipt.message ?? "The local session changed. Review it before retrying.")
        case .blocked: state.notice = .error(receipt.message ?? "The local training change was blocked.")
        }
    }

    private func record(error: Error) {
        state.loadState = storeFailureState(for: error)
        state.notice = .error(error.localizedDescription)
    }

    private func storeFailureState(for error: Error) -> FitnessTrainingLoadState {
        guard let error = error as? TrainingStoreError else { return .failed(message: error.localizedDescription) }
        switch error {
        case .corruptLedger, .ledgerTooLarge, .unreadableLedger, .protectedDataUnavailable,
             .integrityUnavailable, .readbackValidationFailed, .unsupportedSchema,
             .legacyQueueDataPresent:
            return .recoveryRequired(message: error.localizedDescription)
        default:
            return .failed(message: error.localizedDescription)
        }
    }

    private func eventDate(atLeast reference: Date) throws -> Date {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, now >= reference else {
            throw TrainingStoreError.invalidClock
        }
        return now
    }

    private func eventDate(after reference: Date) throws -> Date {
        let now = clock()
        guard now.timeIntervalSinceReferenceDate.isFinite, now > reference else {
            throw TrainingStoreError.invalidClock
        }
        return now
    }

    private func makeSession(
        from draft: TrainingSession,
        status: TrainingSessionStatus,
        endedAt: Date?,
        pauses: [TrainingPauseInterval],
        updatedAt: Date,
        now: Date
    ) throws -> TrainingSession {
        try TrainingSession(
            id: draft.id,
            revision: draft.revision,
            activityKind: draft.activityKind,
            title: draft.title,
            createdAt: draft.createdAt,
            updatedAt: updatedAt,
            startedAt: draft.startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: draft.timeZoneIdentifier,
            templateID: draft.templateID,
            templateSnapshot: draft.templateSnapshot,
            pauses: pauses,
            status: status,
            exercises: draft.exercises,
            notes: draft.notes,
            importedRecordKey: draft.importedRecordKey,
            now: now
        )
    }

    // MARK: - Template catalog

    private static func makeTemplateOptions(from savedTemplates: [FitnessStrengthTemplate]) -> [FitnessTrainingTemplateOption] {
        var options = starterTemplateOptions()
        var indexByID = Dictionary(uniqueKeysWithValues: options.enumerated().map { ($0.element.id, $0.offset) })

        for template in savedTemplates.sorted(by: { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.id < rhs.id
        }) {
            guard let snapshot = try? TrainingTemplateSnapshot(template: template) else { continue }
            let option = FitnessTrainingTemplateOption(
                id: snapshot.templateID,
                name: snapshot.name,
                activityKind: .strength,
                snapshot: snapshot,
                source: .saved,
                editableTemplate: template
            )
            if let index = indexByID[option.id] {
                options[index] = option
            } else {
                indexByID[option.id] = options.count
                options.append(option)
            }
        }
        return options
    }

    private static func starterTemplateOptions() -> [FitnessTrainingTemplateOption] {
        let definitions: [(id: String, name: String, activityKind: TrainingActivityKind, exerciseID: String, exerciseName: String, muscleGroup: TrainingMuscleGroup, sets: Int, repetitions: Int)] = [
            ("starter-curls", "Curls", .strength, "biceps-curls", "Biceps curls", .arms, 3, 10),
            ("starter-bench-press", "Bench press", .strength, "bench-press", "Bench press", .chest, 4, 8),
            // The current shared domain has no cardio-duration field. This
            // starter therefore records interval count only and never labels
            // it as a guessed duration or wearable metric.
            ("starter-cardio", "Cardio intervals", .cardio, "cardio-intervals", "Cardio intervals", .other, 4, 1)
        ]

        return definitions.compactMap { definition in
            guard let exercise = try? TrainingTemplateExerciseSnapshot(
                id: definition.exerciseID,
                name: definition.exerciseName,
                muscleGroup: definition.muscleGroup,
                targetSets: definition.sets,
                targetRepetitions: definition.repetitions
            ) else {
                return nil
            }
            let exercises = [exercise]
            let id = definition.id
            let name = definition.name
            let activityKind = definition.activityKind
            guard let snapshot = try? TrainingTemplateSnapshot(templateID: id, name: name, exercises: exercises) else {
                return nil
            }
            return FitnessTrainingTemplateOption(
                id: id,
                name: name,
                activityKind: activityKind,
                snapshot: snapshot,
                source: .starter
            )
        }
    }
}

private extension String {
    var trimmedOrNil: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
