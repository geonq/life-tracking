import Foundation
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Durable lifestyle facts

/// The three lifestyle facts that LifeOS is allowed to record in this local
/// ledger.  These are source facts, not health scores and not a replacement
/// for HealthKit observations.
public enum FitnessLifestyleKind: String, Codable, CaseIterable, Hashable, Sendable {
    case hydration
    case caffeine
    case alcohol

    public var displayName: String {
        switch self {
        case .hydration: return "Hydration"
        case .caffeine: return "Caffeine"
        case .alcohol: return "Alcohol"
        }
    }

    public var defaultQuickAmount: (value: Double, unit: FitnessLifestyleUnit)? {
        switch self {
        case .hydration: return (250, .milliliters)
        case .caffeine: return (50, .milligrams)
        case .alcohol: return (1, .standardDrinks)
        }
    }

    public var allowedUnits: Set<FitnessLifestyleUnit> {
        switch self {
        case .hydration: return [.milliliters]
        case .caffeine: return [.milligrams]
        // Alcohol is deliberately never represented in milliliters, BAC, or
        // an ambiguous generic count. An alcoholic-beverage count does not
        // carry standard-drink semantics; an importer must leave that fact
        // unavailable unless the source explicitly supplies standard drinks.
        case .alcohol: return [.standardDrinks]
        }
    }
}

public enum FitnessLifestyleUnit: String, Codable, CaseIterable, Hashable, Sendable {
    case milliliters = "ml"
    case milligrams = "mg"
    case standardDrinks

    public var label: String {
        switch self {
        case .milliliters: return "ml"
        case .milligrams: return "mg"
        case .standardDrinks: return "standard drinks"
        }
    }
}

public enum FitnessLifestyleEventState: String, Codable, CaseIterable, Sendable {
    case quantity
    case explicitNone
    case alcoholFree
}

public enum FitnessLifestyleLocalTimeFoldPolicy: String, Codable, CaseIterable, Sendable {
    case earlierOffset
    case laterOffset
}

public enum FitnessLifestyleJournalLinkage: String, Codable, CaseIterable, Sendable {
    case unavailable
}

/// A bounded note captured with a lifestyle fact. The current architecture
/// does not expose a typed FitnessJournalStore link, so linkage is explicitly
/// unavailable rather than represented by a fake foreign key.
public struct FitnessLifestyleJournalNote: Codable, Equatable, Hashable, Sendable {
    public let text: String
    public let createdAt: Date
    public let linkage: FitnessLifestyleJournalLinkage

    public init(text: String, createdAt: Date = Date(), linkage: FitnessLifestyleJournalLinkage = .unavailable) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.createdAt = createdAt
        self.linkage = linkage
    }

    public var displayLinkage: String { "Journal linkage unavailable" }
}

/// Provenance is intentionally a small closed shape.  Manual entries are the
/// only source used by the current UI.  The HealthKit case exists so a later,
/// reviewed importer can preserve source identity without changing this file's
/// persistence schema or pretending that an importer already exists.
public enum FitnessLifestyleProvenance: String, Codable, CaseIterable, Hashable, Sendable {
    case manual
    case healthKit

    public var label: String {
        switch self {
        case .manual: return "Manual"
        case .healthKit: return "HealthKit"
        }
    }
}

public struct FitnessLifestyleLineage: Codable, Equatable, Hashable, Sendable {
    public let rootEventID: UUID
    public let parentEventID: UUID?
    public let revision: Int

    public init(rootEventID: UUID, parentEventID: UUID? = nil, revision: Int = 1) {
        self.rootEventID = rootEventID
        self.parentEventID = parentEventID
        self.revision = revision
    }
}

/// Source identity retained when an observed HealthKit sample is used as a
/// correlation input. Keeping this separate from the public provenance enum
/// lets a reviewed model trace a value back to the exact source sample and
/// revision without exposing identifiers in ordinary UI copy.
public struct FitnessLifestyleSourceSample: Codable, Equatable, Hashable, Sendable {
    public let eventID: UUID
    public let sampleUUID: UUID
    public let sampleRevision: String
    public let lineageRootEventID: UUID
    public let lineageRevision: Int

    public init(
        eventID: UUID,
        sampleUUID: UUID,
        sampleRevision: String,
        lineageRootEventID: UUID,
        lineageRevision: Int
    ) {
        self.eventID = eventID
        self.sampleUUID = sampleUUID
        self.sampleRevision = sampleRevision
        self.lineageRootEventID = lineageRootEventID
        self.lineageRevision = lineageRevision
    }
}

/// A single timestamped lifestyle fact or explicit "none" marker.
///
/// `localDay` is captured at write time using `timeZoneIdentifier`. It is
/// retained alongside the exact instant so historical records do not depend
/// on the device's current timezone or on a future timezone database change.
public struct FitnessLifestyleEvent: Codable, Equatable, Hashable, Identifiable, Sendable {
    public let id: UUID
    public let kind: FitnessLifestyleKind
    public let state: FitnessLifestyleEventState
    public let value: Double?
    public let unit: FitnessLifestyleUnit?
    public let occurredAt: Date
    public let timeZoneIdentifier: String
    public let localDay: String
    public let localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    public let createdAt: Date
    public var updatedAt: Date
    public let provenance: FitnessLifestyleProvenance
    public let sourceSampleUUID: UUID?
    public let sourceSampleRevision: String?
    public let lineage: FitnessLifestyleLineage
    public let journalNote: FitnessLifestyleJournalNote?
    public var isDeleted: Bool
    public var deletedAt: Date?
    public var supersededAt: Date?
    public var supersededBy: UUID?

    public init(
        id: UUID = UUID(),
        kind: FitnessLifestyleKind,
        state: FitnessLifestyleEventState,
        value: Double? = nil,
        unit: FitnessLifestyleUnit? = nil,
        occurredAt: Date,
        timeZoneIdentifier: String,
        localDay: String? = nil,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        provenance: FitnessLifestyleProvenance = .manual,
        sourceSampleUUID: UUID? = nil,
        sourceSampleRevision: String? = nil,
        lineage: FitnessLifestyleLineage? = nil,
        journalNote: FitnessLifestyleJournalNote? = nil,
        isDeleted: Bool = false,
        deletedAt: Date? = nil,
        supersededAt: Date? = nil,
        supersededBy: UUID? = nil
    ) {
        self.id = id
        self.kind = kind
        self.state = state
        self.value = value
        self.unit = unit
        self.occurredAt = occurredAt
        self.timeZoneIdentifier = timeZoneIdentifier
        self.localDay = localDay ?? FitnessLifestyleTime.localDay(for: occurredAt, timeZoneIdentifier: timeZoneIdentifier)
        self.localTimeFoldPolicy = localTimeFoldPolicy
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.provenance = provenance
        self.sourceSampleUUID = sourceSampleUUID
        self.sourceSampleRevision = sourceSampleRevision
        self.lineage = lineage ?? FitnessLifestyleLineage(rootEventID: id)
        self.journalNote = journalNote
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
        self.supersededAt = supersededAt
        self.supersededBy = supersededBy
    }

    public var isExplicitNone: Bool { state == .explicitNone }
    public var isAlcoholFree: Bool { state == .alcoholFree }
    public var isActive: Bool { !isDeleted && supersededBy == nil }
}

public enum FitnessLifestyleMissingness: String, Codable, Sendable {
    case observed
    case explicitNone
    case alcoholFree
    case missing
}

/// A descriptive, source-aware input for a later reviewed calculation.  This
/// type deliberately carries no causal adjustment, score, readiness, stress,
/// or body-age logic.
public struct FitnessLifestyleCorrelationInput: Codable, Equatable, Sendable {
    public let localDay: String
    public let kind: FitnessLifestyleKind
    public let value: Double?
    public let unit: FitnessLifestyleUnit?
    public let explicitNone: Bool
    public let alcoholFree: Bool
    public let missingness: FitnessLifestyleMissingness
    public let provenance: [FitnessLifestyleProvenance]
    public let sampleCount: Int
    public let sourceSamples: [FitnessLifestyleSourceSample]
    public let interpretation: String

    public init(
        localDay: String,
        kind: FitnessLifestyleKind,
        value: Double?,
        unit: FitnessLifestyleUnit?,
        explicitNone: Bool,
        alcoholFree: Bool = false,
        missingness: FitnessLifestyleMissingness,
        provenance: [FitnessLifestyleProvenance],
        sampleCount: Int,
        sourceSamples: [FitnessLifestyleSourceSample] = [],
        interpretation: String = "Descriptive input only; no causal inference."
    ) {
        self.localDay = localDay
        self.kind = kind
        self.value = value
        self.unit = unit
        self.explicitNone = explicitNone
        self.alcoholFree = alcoholFree
        self.missingness = missingness
        self.provenance = provenance
        self.sampleCount = sampleCount
        self.sourceSamples = sourceSamples
        self.interpretation = interpretation
    }
}

public struct FitnessLifestyleDaySummary: Equatable, Sendable {
    public let localDay: String
    public let kind: FitnessLifestyleKind
    /// `nil` means no observation. An explicit-none day is also `nil`, but is
    /// distinguished by `explicitNone` and `missingness`; it must not be
    /// silently converted into a zero by callers.
    public let total: Double?
    public let unit: FitnessLifestyleUnit?
    public let explicitNone: Bool
    public let alcoholFree: Bool
    public let missingness: FitnessLifestyleMissingness
    public let provenance: [FitnessLifestyleProvenance]
    public let sampleCount: Int
    public let sourceSamples: [FitnessLifestyleSourceSample]

    public init(
        localDay: String,
        kind: FitnessLifestyleKind,
        total: Double?,
        unit: FitnessLifestyleUnit?,
        explicitNone: Bool,
        alcoholFree: Bool = false,
        missingness: FitnessLifestyleMissingness,
        provenance: [FitnessLifestyleProvenance],
        sampleCount: Int,
        sourceSamples: [FitnessLifestyleSourceSample] = []
    ) {
        self.localDay = localDay
        self.kind = kind
        self.total = total
        self.unit = unit
        self.explicitNone = explicitNone
        self.alcoholFree = alcoholFree
        self.missingness = missingness
        self.provenance = provenance
        self.sampleCount = sampleCount
        self.sourceSamples = sourceSamples
    }

    public var correlationInput: FitnessLifestyleCorrelationInput {
        FitnessLifestyleCorrelationInput(
            localDay: localDay,
            kind: kind,
            value: total,
            unit: unit,
            explicitNone: explicitNone,
            alcoholFree: alcoholFree,
            missingness: missingness,
            provenance: provenance,
            sampleCount: sampleCount,
            sourceSamples: sourceSamples
        )
    }
}

/// Provenance-aware daily inputs for downstream descriptive calculations.
/// Consumers receive source/missingness/none/alcohol-free state and must not
/// infer a score or causal adjustment from this snapshot.
public struct FitnessLifestyleDailyInputSnapshot: Equatable, Sendable {
    public let localDay: String
    public let timeZoneIdentifier: String
    public let summaries: [FitnessLifestyleDaySummary]
    public let interpretation: String

    public init(localDay: String, timeZoneIdentifier: String, summaries: [FitnessLifestyleDaySummary], interpretation: String = "Descriptive inputs only; no causal inference.") {
        self.localDay = localDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.summaries = summaries
        self.interpretation = interpretation
    }
}

public struct FitnessLifestyleSettings: Codable, Equatable, Sendable {
    public let kind: FitnessLifestyleKind
    public var goal: Double?
    public var quickAmount: Double?
    public var quickUnit: FitnessLifestyleUnit?
    public var reminderTimeMinutes: Int?
    public var reminderEnabled: Bool
    public var reminderContext: FitnessLifestyleReminderContext
    public var reminderFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    public var updatedAt: Date

    public init(
        kind: FitnessLifestyleKind,
        goal: Double? = nil,
        quickAmount: Double? = nil,
        quickUnit: FitnessLifestyleUnit? = nil,
        reminderTimeMinutes: Int? = nil,
        reminderEnabled: Bool = false,
        reminderContext: FitnessLifestyleReminderContext = .custom,
        reminderFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        updatedAt: Date = Date()
    ) {
        self.kind = kind
        self.goal = goal
        self.quickAmount = quickAmount
        self.quickUnit = quickUnit
        self.reminderTimeMinutes = reminderTimeMinutes
        self.reminderEnabled = reminderEnabled
        self.reminderContext = reminderContext
        self.reminderFoldPolicy = reminderFoldPolicy
        self.updatedAt = updatedAt
    }

    public static func defaults(for kind: FitnessLifestyleKind) -> FitnessLifestyleSettings {
        let quick = kind.defaultQuickAmount
        return FitnessLifestyleSettings(
            kind: kind,
            quickAmount: quick?.value,
            quickUnit: quick?.unit
        )
    }

    public var reminderTimeLabel: String? {
        guard let reminderTimeMinutes else { return nil }
        let hour = reminderTimeMinutes / 60
        let minute = reminderTimeMinutes % 60
        return String(format: "%02d:%02d", hour, minute)
    }
}

public enum FitnessLifestyleReminderContext: String, Codable, CaseIterable, Sendable {
    case wake
    case beforeLunch
    case nightly
    case custom

    public var label: String {
        switch self {
        case .wake: return "After waking"
        case .beforeLunch: return "Before lunch"
        case .nightly: return "Nightly"
        case .custom: return "Custom"
        }
    }
}

public enum FitnessLifestyleNotificationAuthorization: Equatable, Sendable {
    case notDetermined
    case denied
    case authorized
    case provisional
    /// App Clips can receive temporary notification authorization. It is a
    /// real, schedulable state, but it must remain visible as temporary rather
    /// than being collapsed into full authorization.
    case ephemeral
    case unknown

    public var canSchedule: Bool {
        switch self {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined, .denied, .unknown: return false
        }
    }
}

public struct FitnessLifestyleReminderRequest: Equatable, Sendable {
    public let identifier: String
    public let kind: FitnessLifestyleKind
    public let context: FitnessLifestyleReminderContext
    public let hour: Int
    public let minute: Int
    public let timeZoneIdentifier: String
    public let foldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    public let title: String
    public let body: String
    public let repeats: Bool
    /// Bounded one-shot requests carry their resolved absolute fire instant.
    /// Repeating calendar triggers cannot represent the repeated-hour DST
    /// fold, so production requests use this field with an absolute trigger.
    public let fireDate: Date?

    public init(
        identifier: String,
        kind: FitnessLifestyleKind,
        context: FitnessLifestyleReminderContext,
        hour: Int,
        minute: Int,
        timeZoneIdentifier: String,
        foldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        title: String,
        body: String,
        repeats: Bool = false,
        fireDate: Date? = nil
    ) {
        self.identifier = identifier
        self.kind = kind
        self.context = context
        self.hour = hour
        self.minute = minute
        self.timeZoneIdentifier = timeZoneIdentifier
        self.foldPolicy = foldPolicy
        self.title = title
        self.body = body
        self.repeats = repeats
        self.fireDate = fireDate
    }
}

/// A pending request as observed at the UserNotifications boundary. A
/// request with `request == nil` is still owned by LifeOS (its identifier has
/// our prefix), but its payload could not be decoded. It is therefore removed
/// and rebuilt rather than treated as equal by identifier alone.
public struct FitnessLifestylePendingReminder: Equatable, Sendable {
    public let identifier: String
    public let request: FitnessLifestyleReminderRequest?

    public init(identifier: String, request: FitnessLifestyleReminderRequest?) {
        self.identifier = identifier
        self.request = request
    }
}

public enum FitnessLifestyleReminderReconciliationError: Error, Equatable, Sendable, LocalizedError {
    case authorizationDenied
    case pendingReadFailed
    case requestFailed(String)
    case invalidSchedule(String)
    case timedOut

    public var errorDescription: String? {
        switch self {
        case .authorizationDenied: return "Notification authorization is not available."
        case .pendingReadFailed: return "Pending notification requests could not be read."
        case .requestFailed(let detail): return "A notification request could not be scheduled: \(detail)"
        case .invalidSchedule(let detail): return "The notification schedule is invalid: \(detail)"
        case .timedOut: return "Notification reconciliation timed out."
        }
    }
}

public protocol FitnessLifestyleNotificationClient: AnyObject {
    func authorizationStatus(completion: @escaping (FitnessLifestyleNotificationAuthorization) -> Void)
    func requestAuthorization(completion: @escaping (Result<Bool, Error>) -> Void)
    func pendingIdentifiers(completion: @escaping (Result<[String], Error>) -> Void)
    func pendingRequests(completion: @escaping (Result<[FitnessLifestylePendingReminder], Error>) -> Void)
    func removePending(identifiers: [String])
    func add(_ request: FitnessLifestyleReminderRequest, completion: @escaping (Error?) -> Void)
}

public extension FitnessLifestyleNotificationClient {
    /// Legacy deterministic clients may not model the system prompt. The
    /// default is a denied/no-op result so tests cannot accidentally claim a
    /// permission grant; production overrides this at the UserNotifications
    /// boundary.
    func requestAuthorization(completion: @escaping (Result<Bool, Error>) -> Void) {
        completion(.success(false))
    }

    /// Compatibility default for deterministic clients that only expose
    /// identifiers. Production uses the full request payload; an unknown
    /// payload is deliberately treated as unequal and reconciled.
    func pendingRequests(completion: @escaping (Result<[FitnessLifestylePendingReminder], Error>) -> Void) {
        pendingIdentifiers { result in
            completion(result.map { identifiers in
                identifiers.map { FitnessLifestylePendingReminder(identifier: $0, request: nil) }
            })
        }
    }
}

/// Reconciles only LifeOS-owned lifestyle reminder identifiers. It is safe to
/// run after relaunch, foregrounding, permission changes, and timezone changes.
/// When authorization is denied, stale LifeOS-owned requests are still removed,
/// but no new requests are added and enabled reminders report the denial.
public final class FitnessLifestyleReminderReconciler {
    public static let identifierPrefix = "lifeos.lifestyle.reminder."
    private let client: FitnessLifestyleNotificationClient
    private let operationQueue = DispatchQueue(label: "lifeos.lifestyle.reminder-reconciliation")
    private let operationQueueKey = DispatchSpecificKey<Void>()
    private let generationLock = NSLock()
    private var generation: UInt64 = 0

    private final class Once {
        private let lock = NSLock()
        private var consumed = false

        func run(_ action: () -> Void) {
            lock.lock()
            guard !consumed else {
                lock.unlock()
                return
            }
            consumed = true
            lock.unlock()
            action()
        }
    }

    public init(client: FitnessLifestyleNotificationClient) {
        self.client = client
        operationQueue.setSpecific(key: operationQueueKey, value: ())
    }

    /// Cancels the currently running reconciliation generation. In-flight
    /// UserNotifications callbacks may still arrive, but their side effects
    /// are ignored before any subsequent removal/addition.
    public func cancel() {
        synchronouslyOnOperationQueue {
            self.generationLock.lock()
            self.generation &+= 1
            self.generationLock.unlock()
        }
    }

    public func reconcile(
        settings: [FitnessLifestyleSettings],
        timeZoneIdentifier: String,
        now: Date = Date(),
        timeout: TimeInterval = 10,
        completion: @escaping (Result<[String], FitnessLifestyleReminderReconciliationError>) -> Void
    ) {
        let token = beginGeneration()
        let completionOnce = Once()
        guard timeout.isFinite, timeout > 0 else {
            completion(.failure(.invalidSchedule("timeout")))
            return
        }

        // The reconciler is often created inline by its caller. Keep it alive
        // through the bounded run even when that caller does not retain the
        // instance; otherwise the queue and its callbacks disappear with the
        // reconciler before the first client response. The client callbacks
        // below remain weak so a client retaining a lost/late callback cannot
        // create a permanent reconciler/queue cycle.
        operationQueue.asyncAfter(deadline: .now() + timeout) { [self] in
            self.finish(
                token: token,
                result: .failure(.timedOut),
                completion: completion,
                once: completionOnce
            )
        }

        operationQueue.async { [self] in
            guard self.isCurrent(token) else { return }
            let authorizationOnce = Once()
            self.client.authorizationStatus { [weak self] status in
                guard let self else { return }
                self.operationQueue.async {
                    authorizationOnce.run {
                        guard self.isCurrent(token) else { return }
                        self.readPending(
                            token: token,
                            authorization: status,
                            settings: settings,
                            timeZoneIdentifier: timeZoneIdentifier,
                            now: now,
                            completion: completion,
                            completionOnce: completionOnce
                        )
                    }
                }
            }
        }
    }

    private func addSequentially(
        _ requests: [FitnessLifestyleReminderRequest],
        index: Int,
        completed: [String],
        token: UInt64,
        completion: @escaping (Result<[String], FitnessLifestyleReminderReconciliationError>) -> Void,
        completionOnce: Once
    ) {
        guard isCurrent(token) else { return }
        guard index < requests.count else {
            finish(token: token, result: .success(completed), completion: completion, once: completionOnce)
            return
        }
        let request = requests[index]
        let callbackOnce = Once()
        client.add(request) { [weak self] error in
            guard let self else { return }
            self.operationQueue.async {
                callbackOnce.run {
                    guard self.isCurrent(token) else { return }
                    if let error {
                        self.finish(
                            token: token,
                            result: .failure(.requestFailed(error.localizedDescription)),
                            completion: completion,
                            once: completionOnce
                        )
                    } else {
                        self.addSequentially(
                            requests,
                            index: index + 1,
                            completed: completed + [request.identifier],
                            token: token,
                            completion: completion,
                            completionOnce: completionOnce
                        )
                    }
                }
            }
        }
    }

    private func readPending(
        token: UInt64,
        authorization: FitnessLifestyleNotificationAuthorization,
        settings: [FitnessLifestyleSettings],
        timeZoneIdentifier: String,
        now: Date,
        completion: @escaping (Result<[String], FitnessLifestyleReminderReconciliationError>) -> Void,
        completionOnce: Once
    ) {
        guard isCurrent(token) else { return }
        let desired: [FitnessLifestyleReminderRequest]
        do {
            desired = try settings.flatMap { setting in
                try Self.requests(
                    for: setting,
                    timeZoneIdentifier: timeZoneIdentifier,
                    now: now,
                    lookAheadDays: Self.defaultLookAheadDays
                )
            }
        } catch let error as FitnessLifestyleReminderReconciliationError {
            finish(token: token, result: .failure(error), completion: completion, once: completionOnce)
            return
        } catch {
            finish(
                token: token,
                result: .failure(.invalidSchedule("unable to create reminder")),
                completion: completion,
                once: completionOnce
            )
            return
        }

        let pendingOnce = Once()
        client.pendingRequests { [weak self] result in
            guard let self else { return }
            self.operationQueue.async {
                pendingOnce.run {
                    guard self.isCurrent(token) else { return }
                    switch result {
                    case .failure:
                        self.finish(
                            token: token,
                            result: .failure(.pendingReadFailed),
                            completion: completion,
                            once: completionOnce
                        )
                    case .success(let pending):
                        self.reconcilePending(
                            token: token,
                            authorization: authorization,
                            desired: desired,
                            pending: pending,
                            completion: completion,
                            completionOnce: completionOnce
                        )
                    }
                }
            }
        }
    }

    private func reconcilePending(
        token: UInt64,
        authorization: FitnessLifestyleNotificationAuthorization,
        desired: [FitnessLifestyleReminderRequest],
        pending: [FitnessLifestylePendingReminder],
        completion: @escaping (Result<[String], FitnessLifestyleReminderReconciliationError>) -> Void,
        completionOnce: Once
    ) {
        guard isCurrent(token) else { return }
        let managed = pending.filter { $0.identifier.hasPrefix(Self.identifierPrefix) }
        // The system caps pending local notification requests at 64. LifeOS
        // owns only its prefixed identifiers, so every other request is
        // reserved capacity and must remain untouched. Normalize duplicate
        // desired IDs first; the sorted choice makes duplicate settings
        // deterministic rather than depending on caller order.
        let uniqueDesired = Self.uniqueDesiredRequests(desired)
        let unmanagedCount = pending.count - managed.count
        let managedBudget = max(0, Self.maximumPendingRequestCount - unmanagedCount)
        let selectedDesired = Self.selectDesiredRequests(uniqueDesired, capacity: managedBudget)
        let desiredByID = Dictionary(uniqueKeysWithValues: selectedDesired.map { ($0.identifier, $0) })
        let matching = managed.filter { pending in
            guard let desired = desiredByID[pending.identifier],
                  let existing = pending.request else { return false }
            return existing == desired
        }
        let matchingIDs = Set(matching.map(\.identifier))
        let stale = Set(managed.map(\.identifier)).subtracting(matchingIDs)
        if !stale.isEmpty, isCurrent(token) {
            client.removePending(identifiers: Array(stale).sorted())
        }

        guard authorization.canSchedule else {
            if uniqueDesired.isEmpty {
                finish(token: token, result: .success([]), completion: completion, once: completionOnce)
            } else {
                finish(
                    token: token,
                    result: .failure(.authorizationDenied),
                    completion: completion,
                    once: completionOnce
                )
            }
            return
        }

        let additions = selectedDesired.filter { !matchingIDs.contains($0.identifier) }
        addSequentially(
            additions,
            index: 0,
            completed: Array(matchingIDs).sorted(),
            token: token,
            completion: completion,
            completionOnce: completionOnce
        )
    }

    /// The platform's pending-request limit is global to the app, not scoped
    /// to LifeOS. Keep this explicit so every notification producer can see
    /// the contract and tests can assert the final bound without duplicating
    /// the platform constant.
    public static let maximumPendingRequestCount = 64

    private static func uniqueDesiredRequests(_ requests: [FitnessLifestyleReminderRequest]) -> [FitnessLifestyleReminderRequest] {
        var seen = Set<String>()
        return requests
            .sorted(by: requestOrder)
            .filter { seen.insert($0.identifier).inserted }
    }

    /// Selects a deterministic, bounded horizon. Requests are considered in
    /// local-day order so near-term reminders are always preferred. When the
    /// final day does not fit, its enabled kinds are selected in a rotating
    /// round-robin order derived from that actual calendar day. This keeps the
    /// remainder fair across a rolling 30-day horizon without giving water,
    /// caffeine, or alcohol an implicit priority.
    private static func selectDesiredRequests(
        _ requests: [FitnessLifestyleReminderRequest],
        capacity: Int
    ) -> [FitnessLifestyleReminderRequest] {
        guard capacity > 0, !requests.isEmpty else { return [] }

        let requestsByDay = Dictionary(grouping: requests, by: localDay)
        let days = requestsByDay.keys.sorted()
        var selected: [FitnessLifestyleReminderRequest] = []
        var remaining = capacity

        for day in days {
            guard remaining > 0, let dayRequests = requestsByDay[day] else { break }
            let chronological = dayRequests.sorted(by: requestOrder)
            guard chronological.count > remaining else {
                selected.append(contentsOf: chronological)
                remaining -= chronological.count
                continue
            }

            // The current day is the only partial bucket. Rotate the starting
            // kind by the stable day ordinal; a repeated reconciliation is
            // therefore deterministic, while a rolling horizon does not let
            // one kind permanently receive the remainder slot.
            let byKind = Dictionary(grouping: chronological, by: \.kind)
            let kinds = FitnessLifestyleKind.allCases.filter { byKind[$0] != nil }
            guard !kinds.isEmpty else { break }
            let offset = stableDayOrdinal(day).map { ordinal in
                let remainder = ordinal % kinds.count
                return remainder >= 0 ? remainder : remainder + kinds.count
            } ?? 0
            let rotatingKinds = Array(kinds[offset...]) + Array(kinds[..<offset])
            var cursors = Dictionary(uniqueKeysWithValues: kinds.map { ($0, 0) })

            while remaining > 0 {
                var selectedInRound = false
                for kind in rotatingKinds {
                    guard remaining > 0,
                          let kindRequests = byKind[kind],
                          let cursor = cursors[kind],
                          cursor < kindRequests.count else { continue }
                    selected.append(kindRequests[cursor])
                    cursors[kind] = cursor + 1
                    remaining -= 1
                    selectedInRound = true
                }
                guard selectedInRound else { break }
            }
            break
        }

        // Keep the add sequence chronologically ordered even though the
        // partial bucket was selected by rotating kind for fairness.
        return selected.sorted(by: requestOrder)
    }

    private static func localDay(of request: FitnessLifestyleReminderRequest) -> String {
        let components = request.identifier.split(separator: ".")
        guard let day = components.last, day.count == 10 else {
            return request.fireDate.map { String(format: "%020.6f", $0.timeIntervalSinceReferenceDate) } ?? request.identifier
        }
        return String(day)
    }

    private static func requestOrder(_ lhs: FitnessLifestyleReminderRequest, _ rhs: FitnessLifestyleReminderRequest) -> Bool {
        switch (lhs.fireDate, rhs.fireDate) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none): return true
        case (.none, .some): return false
        default: break
        }
        if lhs.identifier != rhs.identifier { return lhs.identifier < rhs.identifier }
        if lhs.kind != rhs.kind { return kindRank(lhs.kind) < kindRank(rhs.kind) }
        if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
        if lhs.minute != rhs.minute { return lhs.minute < rhs.minute }
        if lhs.context != rhs.context { return lhs.context.rawValue < rhs.context.rawValue }
        return lhs.foldPolicy.rawValue < rhs.foldPolicy.rawValue
    }

    private static func kindRank(_ kind: FitnessLifestyleKind) -> Int {
        FitnessLifestyleKind.allCases.firstIndex(of: kind) ?? Int.max
    }

    private static func stableDayOrdinal(_ day: String) -> Int? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else {
            return nil
        }
        return Int(floor(date.timeIntervalSince1970 / 86_400))
    }

    private func beginGeneration() -> UInt64 {
        var token: UInt64 = 0
        synchronouslyOnOperationQueue {
            self.generationLock.lock()
            self.generation &+= 1
            token = self.generation
            self.generationLock.unlock()
        }
        return token
    }

    private func synchronouslyOnOperationQueue(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: operationQueueKey) != nil {
            action()
        } else {
            operationQueue.sync(execute: action)
        }
    }

    private func isCurrent(_ token: UInt64) -> Bool {
        generationLock.lock()
        let current = generation == token
        generationLock.unlock()
        return current
    }

    private func finish(
        token: UInt64,
        result: Result<[String], FitnessLifestyleReminderReconciliationError>,
        completion: @escaping (Result<[String], FitnessLifestyleReminderReconciliationError>) -> Void,
        once: Once
    ) {
        guard isCurrent(token) else { return }
        once.run {
            completion(result)
            self.generationLock.lock()
            if self.generation == token { self.generation &+= 1 }
            self.generationLock.unlock()
        }
    }

    public static let defaultLookAheadDays = 30

    public static func request(for settings: FitnessLifestyleSettings, timeZoneIdentifier: String) throws -> FitnessLifestyleReminderRequest? {
        try requests(
            for: settings,
            timeZoneIdentifier: timeZoneIdentifier,
            now: Date(),
            lookAheadDays: defaultLookAheadDays
        ).first
    }

    /// Produces a bounded set of absolute one-shot requests. This is the
    /// only production schedule path: a repeating UNCalendarNotificationTrigger
    /// cannot encode whether an ambiguous wall clock belongs to the earlier or
    /// later DST occurrence.
    public static func requests(
        for settings: FitnessLifestyleSettings,
        timeZoneIdentifier: String,
        now: Date,
        lookAheadDays: Int = defaultLookAheadDays
    ) throws -> [FitnessLifestyleReminderRequest] {
        guard settings.reminderEnabled else { return [] }
        guard FitnessLifestyleTime.isValidTimeZoneIdentifier(timeZoneIdentifier) else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("timezone")
        }
        guard let minutes = settings.reminderTimeMinutes, (0..<24 * 60).contains(minutes) else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("time")
        }
        guard now.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("now")
        }
        guard (1...90).contains(lookAheadDays) else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("look-ahead")
        }
        let context = settings.reminderContext
        let kindName = settings.kind.displayName.lowercased()
        let title = "\(settings.kind.displayName) reminder"
        let body: String
        switch context {
        case .wake: body = "Descriptive \(kindName) reminder · configured after waking."
        case .beforeLunch: body = "Descriptive \(kindName) reminder · configured before lunch."
        case .nightly: body = "Descriptive \(kindName) reminder · configured nightly."
        case .custom: body = "Descriptive \(kindName) reminder · your configured time."
        }
        let currentDay = FitnessLifestyleTime.localDay(for: now, timeZoneIdentifier: timeZoneIdentifier)
        guard !currentDay.isEmpty else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("current local day")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        guard let firstDay = FitnessLifestyleTime.date(fromLocalDay: currentDay, timeZoneIdentifier: timeZoneIdentifier) else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("current local day")
        }

        var result: [FitnessLifestyleReminderRequest] = []
        for dayOffset in 0..<lookAheadDays {
            guard let dayDate = calendar.date(byAdding: .day, value: dayOffset, to: firstDay) else { continue }
            let localDay = FitnessLifestyleTime.localDay(for: dayDate, timeZoneIdentifier: timeZoneIdentifier)
            guard let fireDate = try? FitnessLifestyleTime.date(
                forLocalDay: localDay,
                timeMinutes: minutes,
                timeZoneIdentifier: timeZoneIdentifier,
                foldPolicy: settings.reminderFoldPolicy
            ) else {
                // A spring-forward gap has no valid local occurrence. Skip
                // only that day and keep the bounded schedule honest.
                continue
            }
            guard fireDate > now else { continue }
            let identifier = "\(Self.identifierPrefix)\(settings.kind.rawValue).\(localDay)"
            result.append(FitnessLifestyleReminderRequest(
                identifier: identifier,
                kind: settings.kind,
                context: context,
                hour: minutes / 60,
                minute: minutes % 60,
                timeZoneIdentifier: timeZoneIdentifier,
                foldPolicy: settings.reminderFoldPolicy,
                title: title,
                body: body,
                repeats: false,
                fireDate: fireDate
            ))
        }
        guard !result.isEmpty else {
            throw FitnessLifestyleReminderReconciliationError.invalidSchedule("no future occurrence in horizon")
        }
        return result
    }
}

#if canImport(UserNotifications)
public final class SystemFitnessLifestyleNotificationClient: FitnessLifestyleNotificationClient {
    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) { self.center = center }

    public func authorizationStatus(completion: @escaping (FitnessLifestyleNotificationAuthorization) -> Void) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined: completion(.notDetermined)
            case .denied: completion(.denied)
            case .authorized: completion(.authorized)
            case .provisional: completion(.provisional)
#if os(iOS)
            case .ephemeral: completion(.ephemeral)
#endif
            @unknown default: completion(.unknown)
            }
        }
    }

    public func requestAuthorization(completion: @escaping (Result<Bool, Error>) -> Void) {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(granted))
            }
        }
    }

    public func pendingIdentifiers(completion: @escaping (Result<[String], Error>) -> Void) {
        pendingRequests { result in completion(result.map { $0.map(\.identifier) }) }
    }

    public func pendingRequests(completion: @escaping (Result<[FitnessLifestylePendingReminder], Error>) -> Void) {
        center.getPendingNotificationRequests { requests in
            completion(.success(requests.map(Self.pendingReminder)))
        }
    }

    public func removePending(identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    public func add(_ request: FitnessLifestyleReminderRequest, completion: @escaping (Error?) -> Void) {
        let trigger: UNNotificationTrigger
        if let fireDate = request.fireDate, !request.repeats {
            let seconds = fireDate.timeIntervalSinceNow
            guard seconds >= 1 else {
                completion(FitnessLifestyleReminderReconciliationError.invalidSchedule("fire date is not in the future"))
                return
            }
            // An absolute interval trigger preserves the resolved earlier or
            // later DST occurrence. Calendar triggers only preserve the wall
            // clock and cannot encode the fold.
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        } else {
            var components = DateComponents()
            components.hour = request.hour
            components.minute = request.minute
            components.timeZone = TimeZone(identifier: request.timeZoneIdentifier)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: request.repeats)
        }
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        content.userInfo = Self.userInfo(for: request)
        center.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger), withCompletionHandler: completion)
    }

    private static func userInfo(for request: FitnessLifestyleReminderRequest) -> [AnyHashable: Any] {
        var info: [AnyHashable: Any] = [
            "kind": request.kind.rawValue,
            "context": request.context.rawValue,
            "hour": request.hour,
            "minute": request.minute,
            "timeZoneIdentifier": request.timeZoneIdentifier,
            "foldPolicy": request.foldPolicy.rawValue,
            "title": request.title,
            "body": request.body,
            "repeats": request.repeats
        ]
        if let fireDate = request.fireDate {
            info["fireDate"] = fireDate.timeIntervalSinceReferenceDate
        }
        return info
    }

    private static func pendingReminder(_ request: UNNotificationRequest) -> FitnessLifestylePendingReminder {
        let identifier = request.identifier
        guard let kindRaw = request.content.userInfo["kind"] as? String,
              let kind = FitnessLifestyleKind(rawValue: kindRaw),
              let contextRaw = request.content.userInfo["context"] as? String,
              let context = FitnessLifestyleReminderContext(rawValue: contextRaw),
              let hour = request.content.userInfo["hour"] as? Int,
              let minute = request.content.userInfo["minute"] as? Int,
              let timeZoneIdentifier = request.content.userInfo["timeZoneIdentifier"] as? String,
              let foldRaw = request.content.userInfo["foldPolicy"] as? String,
              let foldPolicy = FitnessLifestyleLocalTimeFoldPolicy(rawValue: foldRaw),
              let title = request.content.userInfo["title"] as? String,
              let body = request.content.userInfo["body"] as? String,
              let repeats = request.content.userInfo["repeats"] as? Bool else {
            return FitnessLifestylePendingReminder(identifier: identifier, request: nil)
        }
        let fireDate: Date?
        if let interval = request.content.userInfo["fireDate"] as? TimeInterval {
            fireDate = Date(timeIntervalSinceReferenceDate: interval)
        } else if repeats {
            fireDate = nil
        } else {
            fireDate = (request.trigger as? UNCalendarNotificationTrigger)?.nextTriggerDate()
        }
        return FitnessLifestylePendingReminder(
            identifier: identifier,
            request: FitnessLifestyleReminderRequest(
                identifier: identifier,
                kind: kind,
                context: context,
                hour: hour,
                minute: minute,
                timeZoneIdentifier: timeZoneIdentifier,
                foldPolicy: foldPolicy,
                title: title,
                body: body,
                repeats: repeats,
                fireDate: fireDate
            )
        )
    }
}
#endif

public enum FitnessLifestyleStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidEvent(String)
    case invalidSettings(String)
    case conflictWithExplicitNone(FitnessLifestyleKind, String)
    case conflictWithQuantity(FitnessLifestyleKind, String)
    case conflictWithAlcoholFree(FitnessLifestyleKind, String)
    case conflictWithMixedProvenance(FitnessLifestyleKind, String)
    case eventNotFound(UUID)
    case eventNotEditable(UUID)
    case invalidDay(String)
    case unsupportedSchemaVersion(Int)
    case corruptStorage(String)
    case persistenceFailed(String)
    case persistenceUnavailable

    public var errorDescription: String? {
        switch self {
        case .invalidEvent(let detail): return "Lifestyle entry is invalid: \(detail)"
        case .invalidSettings(let detail): return "Lifestyle settings are invalid: \(detail)"
        case .conflictWithExplicitNone(let kind, _): return "An explicit none marker already exists for \(kind.displayName.lowercased()) on this day."
        case .conflictWithQuantity(let kind, _): return "A quantity entry already exists for \(kind.displayName.lowercased()) on this day."
        case .conflictWithAlcoholFree(let kind, _): return "An alcohol-free marker already exists for \(kind.displayName.lowercased()) on this day."
        case .conflictWithMixedProvenance(let kind, _): return "Manual and imported facts conflict for \(kind.displayName.lowercased()) on this day; the ledger must be repaired before combining them."
        case .eventNotFound: return "Lifestyle entry was not found."
        case .eventNotEditable: return "This lifestyle entry is no longer the active revision."
        case .invalidDay(let detail): return "Lifestyle day is invalid: \(detail)"
        case .unsupportedSchemaVersion(let version): return "Unsupported lifestyle storage version \(version)."
        case .corruptStorage(let detail): return "Lifestyle storage could not be read: \(detail)"
        case .persistenceFailed(let detail): return "Lifestyle changes could not be saved: \(detail)"
        case .persistenceUnavailable: return "Lifestyle storage is unavailable; no values were saved."
        }
    }
}

public enum FitnessLifestyleLoadStatus: Equatable, Sendable {
    case empty
    case loaded(eventCount: Int, settingsCount: Int)
    case filteredInvalidRecords(count: Int)
    case failed(String)
}

// MARK: - Time and validation

public enum FitnessLifestyleTime {
    public static let dayPattern = try! NSRegularExpression(pattern: "^\\d{4}-\\d{2}-\\d{2}$")

    public static func isValidTimeZoneIdentifier(_ identifier: String) -> Bool {
        // Foundation accepts the canonical UTC aliases but does not include
        // all of them in `knownTimeZoneIdentifiers` (notably "UTC" and, on
        // some SDKs, "Etc/UTC"). They are fixed-offset IANA identifiers and
        // are safe for local-day and DST resolution.
        identifier == "UTC" || identifier == "Etc/UTC" || TimeZone.knownTimeZoneIdentifiers.contains(identifier)
    }

    public static func localDay(for date: Date, timeZoneIdentifier: String) -> String {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return "" }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = components.year, let month = components.month, let day = components.day else { return "" }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    public static func localDay(for date: Date, timeZone: TimeZone) -> String {
        localDay(for: date, timeZoneIdentifier: timeZone.identifier)
    }

    public static func date(fromLocalDay value: String, timeZoneIdentifier: String) -> Date? {
        guard isValidDay(value), let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        guard let date, localDay(for: date, timeZoneIdentifier: timeZoneIdentifier) == value else { return nil }
        return date
    }

    /// Materializes a selected stored local day using the current local clock
    /// fields. The round-trip check rejects DST-nonexistent times instead of
    /// silently moving an historical quick-add to another wall-clock time or
    /// another day.
    public static func datePreservingLocalDay(
        _ selectedDate: Date,
        now: Date,
        timeZoneIdentifier: String,
        foldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset
    ) throws -> Date {
        guard isValidTimeZoneIdentifier(timeZoneIdentifier) else {
            throw FitnessLifestyleStoreError.invalidDay("invalid IANA timezone")
        }
        let timeZone = TimeZone(identifier: timeZoneIdentifier)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let selected = calendar.dateComponents([.year, .month, .day], from: selectedDate)
        let clock = calendar.dateComponents([.hour, .minute, .second], from: now)
        guard let year = selected.year, let month = selected.month, let day = selected.day,
              let hour = clock.hour, let minute = clock.minute, let second = clock.second else {
            throw FitnessLifestyleStoreError.invalidDay("selected day or local clock is unavailable")
        }
        let localDay = String(format: "%04d-%02d-%02d", year, month, day)
        guard isValidDay(localDay) else { throw FitnessLifestyleStoreError.invalidDay(localDay) }
        let components = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        return try resolveLocalComponents(components, timeZoneIdentifier: timeZoneIdentifier, foldPolicy: foldPolicy)
    }

    /// Resolves the wall-clock components represented by an absolute date.
    /// This preserves an existing absolute timestamp when its stored fold
    /// policy matches, while allowing an editor to intentionally select the
    /// other occurrence of an ambiguous repeated hour.
    public static func date(
        preservingLocalClockOf date: Date,
        timeZoneIdentifier: String,
        foldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    ) throws -> Date {
        guard isValidTimeZoneIdentifier(timeZoneIdentifier), date.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessLifestyleStoreError.invalidDay("invalid local clock")
        }
        let timeZone = TimeZone(identifier: timeZoneIdentifier)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return try resolveLocalComponents(components, timeZoneIdentifier: timeZoneIdentifier, foldPolicy: foldPolicy)
    }

    /// Resolves a local day and clock into an absolute instant. A nonexistent
    /// spring-forward time throws; an ambiguous fall-back time chooses the
    /// explicitly requested occurrence.
    public static func date(
        forLocalDay localDay: String,
        timeMinutes: Int,
        timeZoneIdentifier: String,
        foldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    ) throws -> Date {
        guard isValidDay(localDay), (0..<24 * 60).contains(timeMinutes),
              isValidTimeZoneIdentifier(timeZoneIdentifier) else {
            throw FitnessLifestyleStoreError.invalidDay("invalid local clock")
        }
        let parts = localDay.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw FitnessLifestyleStoreError.invalidDay("invalid local day") }
        let components = DateComponents(
            year: parts[0], month: parts[1], day: parts[2],
            hour: timeMinutes / 60, minute: timeMinutes % 60, second: 0
        )
        return try resolveLocalComponents(components, timeZoneIdentifier: timeZoneIdentifier, foldPolicy: foldPolicy)
    }

    private static func resolveLocalComponents(
        _ components: DateComponents,
        timeZoneIdentifier: String,
        foldPolicy: FitnessLifestyleLocalTimeFoldPolicy
    ) throws -> Date {
        guard isValidTimeZoneIdentifier(timeZoneIdentifier),
              let year = components.year, let month = components.month, let day = components.day,
              let hour = components.hour, let minute = components.minute, let second = components.second,
              let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw FitnessLifestyleStoreError.invalidDay("invalid local clock")
        }
        var nominalUTC = Calendar(identifier: .gregorian)
        nominalUTC.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let nominal = nominalUTC.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)) else {
            throw FitnessLifestyleStoreError.invalidDay("selected day cannot represent the current local clock")
        }
        var candidates: [Date] = []
        for offset in stride(from: -24 * 60 * 60, through: 24 * 60 * 60, by: 15 * 60) {
            let candidate = nominal.addingTimeInterval(TimeInterval(-offset))
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            guard calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: candidate) ==
                    DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second) else { continue }
            candidates.append(candidate)
        }
        let unique = Array(Set(candidates)).sorted()
        guard let result = foldPolicy == .earlierOffset ? unique.first : unique.last else {
            throw FitnessLifestyleStoreError.invalidDay("selected day cannot represent the current local clock")
        }
        return result
    }

    public static func timeString(for date: Date, timeZoneIdentifier: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    public static func isValidDay(_ value: String) -> Bool {
        guard value.utf8.count == 10 else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard dayPattern.firstMatch(in: value, range: range) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...9999).contains(parts[0]), (1...12).contains(parts[1]) else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) != nil
    }
}

private enum FitnessLifestyleValidation {
    static let schemaVersion = 1
    static let maximumSourceRevisionLength = 128
    static let maximumTextLength = 128

    static func validate(_ event: FitnessLifestyleEvent) throws {
        guard event.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000") else {
            throw FitnessLifestyleStoreError.invalidEvent("id")
        }
        guard FitnessLifestyleTime.isValidTimeZoneIdentifier(event.timeZoneIdentifier) else {
            throw FitnessLifestyleStoreError.invalidEvent("timeZoneIdentifier must be an IANA timezone")
        }
        guard FitnessLifestyleTime.isValidDay(event.localDay),
              FitnessLifestyleTime.localDay(for: event.occurredAt, timeZoneIdentifier: event.timeZoneIdentifier) == event.localDay else {
            throw FitnessLifestyleStoreError.invalidEvent("localDay does not match timestamp and timezone")
        }
        for (date, label) in [(event.occurredAt, "occurredAt"), (event.createdAt, "createdAt"), (event.updatedAt, "updatedAt")] {
            guard date.timeIntervalSinceReferenceDate.isFinite else {
                throw FitnessLifestyleStoreError.invalidEvent(label)
            }
        }
        if let deletedAt = event.deletedAt {
            guard deletedAt.timeIntervalSinceReferenceDate.isFinite, event.isDeleted else {
                throw FitnessLifestyleStoreError.invalidEvent("deletedAt requires a tombstone")
            }
        }
        if event.isDeleted && event.deletedAt == nil {
            throw FitnessLifestyleStoreError.invalidEvent("deleted tombstone requires deletedAt")
        }
        if (event.supersededBy == nil) != (event.supersededAt == nil) {
            throw FitnessLifestyleStoreError.invalidEvent("supersededAt and supersededBy must be paired")
        }
        if let supersededAt = event.supersededAt,
           !supersededAt.timeIntervalSinceReferenceDate.isFinite {
            throw FitnessLifestyleStoreError.invalidEvent("supersededAt")
        }
        guard event.lineage.rootEventID != UUID(uuidString: "00000000-0000-0000-0000-000000000000"),
              event.lineage.revision >= 1 else {
            throw FitnessLifestyleStoreError.invalidEvent("lineage")
        }
        guard event.journalNote == nil || event.provenance == .manual else {
            throw FitnessLifestyleStoreError.invalidEvent("imported entries cannot carry journal notes")
        }
        if let note = event.journalNote {
            guard !note.text.isEmpty, note.text.utf8.count <= 240,
                  note.createdAt.timeIntervalSinceReferenceDate.isFinite else {
                throw FitnessLifestyleStoreError.invalidEvent("journal note")
            }
        }

        switch event.state {
        case .explicitNone:
            guard event.provenance == .manual, event.value == nil, event.unit == nil else {
                throw FitnessLifestyleStoreError.invalidEvent("explicit none cannot carry a quantity")
            }
        case .alcoholFree:
            guard event.provenance == .manual, event.kind == .alcohol, event.value == nil, event.unit == nil else {
                throw FitnessLifestyleStoreError.invalidEvent("alcohol-free state is only valid for alcohol")
            }
        case .quantity:
            guard let value = event.value, value.isFinite, value > 0,
                  let unit = event.unit, event.kind.allowedUnits.contains(unit) else {
                throw FitnessLifestyleStoreError.invalidEvent("quantity or canonical unit")
            }
            let maximum: Double = event.kind == .alcohol ? 100 : 100_000
            guard value <= maximum else { throw FitnessLifestyleStoreError.invalidEvent("quantity bounds") }
        }

        switch event.provenance {
        case .manual:
            guard event.sourceSampleUUID == nil, event.sourceSampleRevision == nil else {
                throw FitnessLifestyleStoreError.invalidEvent("manual entries cannot carry source sample identity")
            }
        case .healthKit:
            guard event.state != .explicitNone,
                  let sourceSampleUUID = event.sourceSampleUUID,
                  !isZeroUUID(sourceSampleUUID),
                  let revision = event.sourceSampleRevision,
                  isValidSourceRevision(revision) else {
                throw FitnessLifestyleStoreError.invalidEvent("HealthKit quantity entries require a validated sample UUID and revision")
            }
        }
    }

    static func validate(_ settings: FitnessLifestyleSettings) throws {
        for (value, label) in [(settings.goal, "goal"), (settings.quickAmount, "quickAmount")] {
            if let value {
                guard value.isFinite, value > 0, value <= (settings.kind == .alcohol ? 100 : 100_000) else {
                    throw FitnessLifestyleStoreError.invalidSettings(label)
                }
            }
        }
        if let goal = settings.goal, let quickUnit = settings.quickUnit {
            guard settings.kind.allowedUnits.contains(quickUnit), goal > 0 else {
                throw FitnessLifestyleStoreError.invalidSettings("unit")
            }
        }
        if settings.quickAmount != nil {
            guard let unit = settings.quickUnit, settings.kind.allowedUnits.contains(unit) else {
                throw FitnessLifestyleStoreError.invalidSettings("quickUnit")
            }
        } else if settings.quickUnit != nil {
            throw FitnessLifestyleStoreError.invalidSettings("quick amount/unit pairing")
        }
        if let reminderTimeMinutes = settings.reminderTimeMinutes {
            guard (0..<24 * 60).contains(reminderTimeMinutes) else {
                throw FitnessLifestyleStoreError.invalidSettings("reminder time")
            }
        }
        guard !settings.reminderEnabled || settings.reminderTimeMinutes != nil else {
            throw FitnessLifestyleStoreError.invalidSettings("enabled reminder requires a time")
        }
        guard settings.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessLifestyleStoreError.invalidSettings("updatedAt")
        }
    }

    private static func isValidSourceRevision(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumSourceRevisionLength else { return false }
        return trimmed.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90) ||
            (byte >= 97 && byte <= 122) || byte == 45 || byte == 46 || byte == 95
        }
    }

    private static func isZeroUUID(_ value: UUID) -> Bool {
        value == UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    }
}

// MARK: - Persistence

private struct FitnessLifestyleAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil

    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

private func rejectUnknownFitnessLifestyleKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: FitnessLifestyleAnyCodingKey.self)
    guard Set(container.allKeys.map(\.stringValue)).isSubset(of: allowed) else {
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Unknown lifestyle storage field"))
    }
}

private struct FitnessLifestyleLineageEnvelope: Codable {
    let rootEventID: UUID
    let parentEventID: UUID?
    let revision: Int

    init(_ value: FitnessLifestyleLineage) {
        rootEventID = value.rootEventID
        parentEventID = value.parentEventID
        revision = value.revision
    }

    func lineageValue() -> FitnessLifestyleLineage {
        FitnessLifestyleLineage(rootEventID: rootEventID, parentEventID: parentEventID, revision: revision)
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFitnessLifestyleKeys(decoder, allowed: ["rootEventID", "parentEventID", "revision"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rootEventID = try c.decode(UUID.self, forKey: .rootEventID)
        parentEventID = try c.decodeIfPresent(UUID.self, forKey: .parentEventID)
        revision = try c.decode(Int.self, forKey: .revision)
    }

    private enum CodingKeys: String, CodingKey { case rootEventID, parentEventID, revision }
}

private struct FitnessLifestyleStorageEvent: Codable {
    let id: UUID
    let kind: FitnessLifestyleKind
    let state: FitnessLifestyleEventState
    let value: Double?
    let unit: FitnessLifestyleUnit?
    let occurredAt: Date
    let timeZoneIdentifier: String
    let localDay: String
    let localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy?
    let createdAt: Date
    let updatedAt: Date
    let provenance: FitnessLifestyleProvenance
    let sourceSampleUUID: UUID?
    let sourceSampleRevision: String?
    let lineage: FitnessLifestyleLineageEnvelope
    let journalNote: FitnessLifestyleJournalNote?
    let isDeleted: Bool
    let deletedAt: Date?
    let supersededAt: Date?
    let supersededBy: UUID?

    init(_ value: FitnessLifestyleEvent) {
        id = value.id
        kind = value.kind
        state = value.state
        self.value = value.value
        unit = value.unit
        occurredAt = value.occurredAt
        timeZoneIdentifier = value.timeZoneIdentifier
        localDay = value.localDay
        localTimeFoldPolicy = value.localTimeFoldPolicy
        createdAt = value.createdAt
        updatedAt = value.updatedAt
        provenance = value.provenance
        sourceSampleUUID = value.sourceSampleUUID
        sourceSampleRevision = value.sourceSampleRevision
        lineage = FitnessLifestyleLineageEnvelope(value.lineage)
        journalNote = value.journalNote
        isDeleted = value.isDeleted
        deletedAt = value.deletedAt
        supersededAt = value.supersededAt
        supersededBy = value.supersededBy
    }

    func eventValue() -> FitnessLifestyleEvent {
        FitnessLifestyleEvent(
            id: id, kind: kind, state: state, value: value, unit: unit,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
            localDay: localDay, localTimeFoldPolicy: localTimeFoldPolicy ?? .earlierOffset,
            createdAt: createdAt, updatedAt: updatedAt,
            provenance: provenance, sourceSampleUUID: sourceSampleUUID,
            sourceSampleRevision: sourceSampleRevision, lineage: lineage.lineageValue(),
            journalNote: journalNote,
            isDeleted: isDeleted, deletedAt: deletedAt,
            supersededAt: supersededAt, supersededBy: supersededBy
        )
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFitnessLifestyleKeys(decoder, allowed: [
            "id", "kind", "state", "value", "unit", "occurredAt", "timeZoneIdentifier", "localDay", "localTimeFoldPolicy",
            "createdAt", "updatedAt", "provenance", "sourceSampleUUID", "sourceSampleRevision", "lineage",
            "journalNote", "isDeleted", "deletedAt", "supersededAt", "supersededBy"
        ])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(FitnessLifestyleKind.self, forKey: .kind)
        state = try c.decode(FitnessLifestyleEventState.self, forKey: .state)
        value = try c.decodeIfPresent(Double.self, forKey: .value)
        unit = try c.decodeIfPresent(FitnessLifestyleUnit.self, forKey: .unit)
        occurredAt = try c.decode(Date.self, forKey: .occurredAt)
        timeZoneIdentifier = try c.decode(String.self, forKey: .timeZoneIdentifier)
        localDay = try c.decode(String.self, forKey: .localDay)
        localTimeFoldPolicy = try c.decodeIfPresent(FitnessLifestyleLocalTimeFoldPolicy.self, forKey: .localTimeFoldPolicy)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        provenance = try c.decode(FitnessLifestyleProvenance.self, forKey: .provenance)
        sourceSampleUUID = try c.decodeIfPresent(UUID.self, forKey: .sourceSampleUUID)
        sourceSampleRevision = try c.decodeIfPresent(String.self, forKey: .sourceSampleRevision)
        lineage = try c.decode(FitnessLifestyleLineageEnvelope.self, forKey: .lineage)
        journalNote = try c.decodeIfPresent(FitnessLifestyleJournalNote.self, forKey: .journalNote)
        isDeleted = try c.decode(Bool.self, forKey: .isDeleted)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        supersededAt = try c.decodeIfPresent(Date.self, forKey: .supersededAt)
        supersededBy = try c.decodeIfPresent(UUID.self, forKey: .supersededBy)
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, state, value, unit, occurredAt, timeZoneIdentifier, localDay, localTimeFoldPolicy, createdAt, updatedAt
        case provenance, sourceSampleUUID, sourceSampleRevision, lineage, journalNote, isDeleted, deletedAt, supersededAt, supersededBy
    }
}

private struct FitnessLifestyleStorageSettings: Codable {
    let kind: FitnessLifestyleKind
    let goal: Double?
    let quickAmount: Double?
    let quickUnit: FitnessLifestyleUnit?
    let reminderTimeMinutes: Int?
    let reminderEnabled: Bool
    let reminderContext: FitnessLifestyleReminderContext?
    let reminderFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy?
    let updatedAt: Date

    init(_ value: FitnessLifestyleSettings) {
        kind = value.kind
        goal = value.goal
        quickAmount = value.quickAmount
        quickUnit = value.quickUnit
        reminderTimeMinutes = value.reminderTimeMinutes
        reminderEnabled = value.reminderEnabled
        reminderContext = value.reminderContext
        reminderFoldPolicy = value.reminderFoldPolicy
        updatedAt = value.updatedAt
    }

    func settingsValue() -> FitnessLifestyleSettings {
        FitnessLifestyleSettings(kind: kind, goal: goal, quickAmount: quickAmount, quickUnit: quickUnit,
                                 reminderTimeMinutes: reminderTimeMinutes, reminderEnabled: reminderEnabled,
                                 reminderContext: reminderContext ?? .custom,
                                 reminderFoldPolicy: reminderFoldPolicy ?? .earlierOffset,
                                 updatedAt: updatedAt)
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFitnessLifestyleKeys(decoder, allowed: ["kind", "goal", "quickAmount", "quickUnit", "reminderTimeMinutes", "reminderEnabled", "reminderContext", "reminderFoldPolicy", "updatedAt"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(FitnessLifestyleKind.self, forKey: .kind)
        goal = try c.decodeIfPresent(Double.self, forKey: .goal)
        quickAmount = try c.decodeIfPresent(Double.self, forKey: .quickAmount)
        quickUnit = try c.decodeIfPresent(FitnessLifestyleUnit.self, forKey: .quickUnit)
        reminderTimeMinutes = try c.decodeIfPresent(Int.self, forKey: .reminderTimeMinutes)
        reminderEnabled = try c.decode(Bool.self, forKey: .reminderEnabled)
        reminderContext = try c.decodeIfPresent(FitnessLifestyleReminderContext.self, forKey: .reminderContext)
        reminderFoldPolicy = try c.decodeIfPresent(FitnessLifestyleLocalTimeFoldPolicy.self, forKey: .reminderFoldPolicy)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    private enum CodingKeys: String, CodingKey { case kind, goal, quickAmount, quickUnit, reminderTimeMinutes, reminderEnabled, reminderContext, reminderFoldPolicy, updatedAt }
}

private struct FitnessLifestyleStorageEnvelope: Codable {
    let schemaVersion: Int
    let events: [FitnessLifestyleStorageEvent]
    let settings: [FitnessLifestyleStorageSettings]

    init(events: [FitnessLifestyleEvent], settings: [FitnessLifestyleSettings]) {
        schemaVersion = 1
        self.events = events.map(FitnessLifestyleStorageEvent.init)
        self.settings = settings.map(FitnessLifestyleStorageSettings.init)
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownFitnessLifestyleKeys(decoder, allowed: ["schemaVersion", "events", "settings"])
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        events = try c.decode([FitnessLifestyleStorageEvent].self, forKey: .events)
        settings = try c.decode([FitnessLifestyleStorageSettings].self, forKey: .settings)
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, events, settings }
}

private final class FitnessLifestyleFileLockRegistry {
    static let shared = FitnessLifestyleFileLockRegistry()
    private let registryLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func lock(for url: URL) -> NSRecursiveLock {
        registryLock.lock()
        defer { registryLock.unlock() }
        let key = url.standardizedFileURL.path
        if let existing = locks[key] { return existing }
        let created = NSRecursiveLock()
        locks[key] = created
        return created
    }
}

private struct FitnessLifestyleStoreState {
    var events: [FitnessLifestyleEvent]
    var settings: [FitnessLifestyleSettings]
}

public extension Notification.Name {
    /// Posted after an atomic ledger write. Views use this as a stable
    /// invalidation signal and then reload a fresh snapshot; they never share
    /// mutable arrays across independent store instances.
    static let fitnessLifestyleLedgerDidChange = Notification.Name("LifeOS.FitnessLifestyleLedgerDidChange")
}

/// A local-first durable ledger. Every mutation is a locked read-modify-write
/// against the latest file snapshot, encoded and atomically replaced before the
/// in-memory state is published. Failed writes therefore leave both snapshots
/// unchanged.
public final class FitnessLifestyleLedgerStore {
    public static var defaultPersistenceURL: URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return support.appendingPathComponent("LifeOS", isDirectory: true)
            .appendingPathComponent("fitness-lifestyle-ledger.json")
    }

    public private(set) var events: [FitnessLifestyleEvent] = []
    public private(set) var loadStatus: FitnessLifestyleLoadStatus = .empty
    public private(set) var lastLoadError: FitnessLifestyleStoreError?
    public private(set) var integrityWarning: String?
    public private(set) var revision: UInt64 = 0

    private let persistenceURL: URL?
    private let lock: NSRecursiveLock
    private let fixtureOnly: Bool

    public init(
        persistenceURL: URL? = FitnessLifestyleLedgerStore.defaultPersistenceURL,
        fixtureOnly: Bool = false,
        loadImmediately: Bool = true,
        requirePersistence: Bool = false
    ) {
        self.persistenceURL = persistenceURL
        self.fixtureOnly = fixtureOnly && persistenceURL == nil
        if let persistenceURL {
            lock = FitnessLifestyleFileLockRegistry.shared.lock(for: persistenceURL)
            if loadImmediately { loadInitialState() }
        } else {
            lock = NSRecursiveLock()
            if requirePersistence && !self.fixtureOnly {
                let error = FitnessLifestyleStoreError.persistenceUnavailable
                lastLoadError = error
                loadStatus = .failed(error.localizedDescription)
                integrityWarning = "Local lifestyle storage is unavailable; no values were treated as observations."
            } else {
                loadStatus = .empty
            }
        }
    }

    public var hasLoadFailure: Bool { lastLoadError != nil }

    /// A stable identity for notification filtering. `nil` means an explicit
    /// in-memory fixture store, which never reads or writes production data.
    public var persistenceKey: String? { persistenceURL?.standardizedFileURL.path }

    public func settings(for kind: FitnessLifestyleKind) -> FitnessLifestyleSettings {
        withReadLock { currentSettings(for: kind, in: $0.settings) }
    }

    public func savedSettings(for kind: FitnessLifestyleKind) -> FitnessLifestyleSettings? {
        withReadLock { $0.settings.first(where: { $0.kind == kind }) }
    }

    @discardableResult
    public func saveSettings(_ settings: FitnessLifestyleSettings) throws -> FitnessLifestyleSettings {
        try mutate { state in
            try FitnessLifestyleValidation.validate(settings)
            if let index = state.settings.firstIndex(where: { $0.kind == settings.kind }) {
                state.settings[index] = settings
            } else {
                state.settings.append(settings)
            }
            return settings
        }
    }

    @discardableResult
    public func addQuantity(
        kind: FitnessLifestyleKind,
        amount: Double,
        unit: FitnessLifestyleUnit,
        occurredAt: Date,
        timeZoneIdentifier: String,
        journalNote: FitnessLifestyleJournalNote? = nil,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        let event = FitnessLifestyleEvent(
            kind: kind, state: .quantity, value: amount, unit: unit,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
            localTimeFoldPolicy: localTimeFoldPolicy, createdAt: now,
            provenance: .manual, journalNote: journalNote
        )
        return try insertRoot(event)
    }

    @discardableResult
    public func addAlcoholFree(
        occurredAt: Date,
        timeZoneIdentifier: String,
        journalNote: FitnessLifestyleJournalNote? = nil,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        let event = FitnessLifestyleEvent(
            kind: .alcohol, state: .alcoholFree, occurredAt: occurredAt,
            timeZoneIdentifier: timeZoneIdentifier,
            localTimeFoldPolicy: localTimeFoldPolicy, createdAt: now,
            provenance: .manual, journalNote: journalNote
        )
        return try insertRoot(event)
    }

    @discardableResult
    public func addNone(
        kind: FitnessLifestyleKind,
        occurredAt: Date,
        timeZoneIdentifier: String,
        journalNote: FitnessLifestyleJournalNote? = nil,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        let event = FitnessLifestyleEvent(
            kind: kind, state: .explicitNone, occurredAt: occurredAt,
            timeZoneIdentifier: timeZoneIdentifier,
            localTimeFoldPolicy: localTimeFoldPolicy, createdAt: now,
            provenance: .manual, journalNote: journalNote
        )
        return try insertRoot(event)
    }

    @discardableResult
    private func insert(_ event: FitnessLifestyleEvent) throws -> FitnessLifestyleEvent {
        try mutate { state in
            try FitnessLifestyleValidation.validate(event)
            guard !state.events.contains(where: { $0.id == event.id }) else {
                throw FitnessLifestyleStoreError.invalidEvent("duplicate id")
            }
            if let sourceSampleUUID = event.sourceSampleUUID,
               state.events.contains(where: { $0.sourceSampleUUID == sourceSampleUUID }) {
                throw FitnessLifestyleStoreError.invalidEvent("duplicate source sample identity")
            }
            try validateConflict(for: event, in: state.events)
            state.events.append(event)
            return event
        }
    }

    /// The only public-facing insertion boundary creates a root manual fact.
    /// Existing lineage, imported provenance, and source identity cannot be
    /// smuggled through a generic insertion API.
    @discardableResult
    internal func insertRoot(_ event: FitnessLifestyleEvent) throws -> FitnessLifestyleEvent {
        guard event.provenance == .manual,
              event.lineage.parentEventID == nil,
              event.lineage.rootEventID == event.id,
              event.lineage.revision == 1,
              event.sourceSampleUUID == nil,
              event.sourceSampleRevision == nil,
              !event.isDeleted,
              event.deletedAt == nil,
              event.supersededAt == nil,
              event.supersededBy == nil else {
            throw FitnessLifestyleStoreError.invalidEvent("only a manual root may be inserted")
        }
        return try insert(event)
    }

    /// Future reviewed source adapters use this internal boundary. HealthKit
    /// is intentionally not implemented here; callers must provide the
    /// already-validated source UUID and revision.
    @discardableResult
    internal func insertObservedQuantity(
        kind: FitnessLifestyleKind,
        amount: Double,
        unit: FitnessLifestyleUnit,
        occurredAt: Date,
        timeZoneIdentifier: String,
        sourceSampleUUID: UUID,
        sourceSampleRevision: String,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy = .earlierOffset,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        let event = FitnessLifestyleEvent(
            kind: kind, state: .quantity, value: amount, unit: unit,
            occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
            localTimeFoldPolicy: localTimeFoldPolicy, createdAt: now,
            provenance: .healthKit, sourceSampleUUID: sourceSampleUUID,
            sourceSampleRevision: sourceSampleRevision
        )
        return try insertRootObserved(event)
    }

    private func insertRootObserved(_ event: FitnessLifestyleEvent) throws -> FitnessLifestyleEvent {
        guard event.provenance == .healthKit,
              event.state == .quantity,
              event.lineage.parentEventID == nil,
              event.lineage.rootEventID == event.id,
              event.lineage.revision == 1,
              event.sourceSampleUUID != nil,
              event.sourceSampleRevision != nil else {
            throw FitnessLifestyleStoreError.invalidEvent("observed source root is incomplete")
        }
        return try insert(event)
    }

    /// Correct an active revision by appending a new revision and retaining a
    /// superseded parent.  The event ID changes; the lineage root remains
    /// stable, so sync/history can follow the correction chain unambiguously.
    @discardableResult
    public func correct(
        eventID: UUID,
        state newState: FitnessLifestyleEventState,
        amount: Double? = nil,
        unit: FitnessLifestyleUnit? = nil,
        occurredAt: Date? = nil,
        timeZoneIdentifier: String? = nil,
        journalNote: FitnessLifestyleJournalNote? = nil,
        clearJournalNote: Bool = false,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy? = nil,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        try mutate { state in
            guard let index = state.events.firstIndex(where: { $0.id == eventID }) else {
                throw FitnessLifestyleStoreError.eventNotFound(eventID)
            }
            let previous = state.events[index]
            guard previous.isActive, previous.provenance == .manual else {
                throw FitnessLifestyleStoreError.eventNotEditable(eventID)
            }
            let timestamp = occurredAt ?? previous.occurredAt
            let timezone = timeZoneIdentifier ?? previous.timeZoneIdentifier
            let note = clearJournalNote ? nil : journalNote ?? previous.journalNote
            let candidate = FitnessLifestyleEvent(
                id: UUID(), kind: previous.kind, state: newState,
                value: newState == .quantity ? amount : nil,
                unit: newState == .quantity ? unit : nil,
                occurredAt: timestamp, timeZoneIdentifier: timezone,
                localTimeFoldPolicy: localTimeFoldPolicy ?? previous.localTimeFoldPolicy,
                createdAt: now, provenance: previous.provenance,
                sourceSampleUUID: previous.sourceSampleUUID,
                sourceSampleRevision: previous.sourceSampleRevision,
                lineage: FitnessLifestyleLineage(
                    rootEventID: previous.lineage.rootEventID,
                    parentEventID: previous.id,
                    revision: previous.lineage.revision + 1
                ),
                journalNote: note
            )
            guard candidate.kind == previous.kind,
                  candidate.provenance == previous.provenance,
                  candidate.sourceSampleUUID == previous.sourceSampleUUID,
                  candidate.sourceSampleRevision == previous.sourceSampleRevision else {
                throw FitnessLifestyleStoreError.invalidEvent("revision identity cannot change")
            }
            try FitnessLifestyleValidation.validate(candidate)
            try validateConflict(for: candidate, in: state.events, excluding: [previous.id])
            state.events[index].supersededAt = now
            state.events[index].supersededBy = candidate.id
            state.events[index].updatedAt = now
            state.events.append(candidate)
            return candidate
        }
    }

    @discardableResult
    public func editQuantity(
        eventID: UUID,
        amount: Double,
        unit: FitnessLifestyleUnit,
        occurredAt: Date? = nil,
        timeZoneIdentifier: String? = nil,
        journalNote: FitnessLifestyleJournalNote? = nil,
        clearJournalNote: Bool = false,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy? = nil,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        try correct(eventID: eventID, state: .quantity, amount: amount, unit: unit,
                    occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
                    journalNote: journalNote, clearJournalNote: clearJournalNote,
                    localTimeFoldPolicy: localTimeFoldPolicy, now: now)
    }

    @discardableResult
    public func editToNone(
        eventID: UUID,
        occurredAt: Date? = nil,
        timeZoneIdentifier: String? = nil,
        journalNote: FitnessLifestyleJournalNote? = nil,
        clearJournalNote: Bool = false,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy? = nil,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        try correct(eventID: eventID, state: .explicitNone,
                    occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
                    journalNote: journalNote, clearJournalNote: clearJournalNote,
                    localTimeFoldPolicy: localTimeFoldPolicy, now: now)
    }

    @discardableResult
    public func editToAlcoholFree(
        eventID: UUID,
        occurredAt: Date? = nil,
        timeZoneIdentifier: String? = nil,
        journalNote: FitnessLifestyleJournalNote? = nil,
        clearJournalNote: Bool = false,
        localTimeFoldPolicy: FitnessLifestyleLocalTimeFoldPolicy? = nil,
        now: Date = Date()
    ) throws -> FitnessLifestyleEvent {
        try correct(eventID: eventID, state: .alcoholFree,
                    occurredAt: occurredAt, timeZoneIdentifier: timeZoneIdentifier,
                    journalNote: journalNote, clearJournalNote: clearJournalNote,
                    localTimeFoldPolicy: localTimeFoldPolicy, now: now)
    }

    @discardableResult
    public func delete(eventID: UUID, now: Date = Date()) throws -> FitnessLifestyleEvent {
        try mutate { state in
            guard let index = state.events.firstIndex(where: { $0.id == eventID }) else {
                throw FitnessLifestyleStoreError.eventNotFound(eventID)
            }
            guard state.events[index].isActive, state.events[index].provenance == .manual else {
                throw FitnessLifestyleStoreError.eventNotEditable(eventID)
            }
            let previous = state.events[index]
            let tombstone = FitnessLifestyleEvent(
                id: UUID(), kind: previous.kind, state: previous.state,
                value: previous.value, unit: previous.unit,
                occurredAt: previous.occurredAt,
                timeZoneIdentifier: previous.timeZoneIdentifier,
                localDay: previous.localDay,
                localTimeFoldPolicy: previous.localTimeFoldPolicy,
                createdAt: now,
                provenance: previous.provenance,
                sourceSampleUUID: previous.sourceSampleUUID,
                sourceSampleRevision: previous.sourceSampleRevision,
                lineage: FitnessLifestyleLineage(
                    rootEventID: previous.lineage.rootEventID,
                    parentEventID: previous.id,
                    revision: previous.lineage.revision + 1
                ),
                journalNote: previous.journalNote,
                isDeleted: true,
                deletedAt: now
            )
            state.events[index].supersededAt = now
            state.events[index].supersededBy = tombstone.id
            state.events[index].updatedAt = now
            state.events.append(tombstone)
            return tombstone
        }
    }

    public func activeEvents(kind: FitnessLifestyleKind? = nil) -> [FitnessLifestyleEvent] {
        withReadLock { state in
            guard lastLoadError == nil else { return [] }
            return state.events.filter { $0.isActive && (kind == nil || $0.kind == kind) }.sorted(by: Self.sortEvents)
        }
    }

    public func history(kind: FitnessLifestyleKind? = nil) -> [FitnessLifestyleEvent] {
        withReadLock { state in
            guard lastLoadError == nil else { return [] }
            return state.events.filter { kind == nil || $0.kind == kind }.sorted(by: Self.sortHistory)
        }
    }

    public func history(
        on localDay: String,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> [FitnessLifestyleEvent] {
        try requireReadable()
        try validateDay(localDay, timeZoneIdentifier: timeZoneIdentifier)
        return withReadLock { state in
            state.events.filter { event in
                event.kind == kind && matches(event, localDay: localDay, timeZoneIdentifier: timeZoneIdentifier)
            }.sorted(by: Self.sortHistory)
        }
    }

    public func history(
        for date: Date,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> [FitnessLifestyleEvent] {
        let day = FitnessLifestyleTime.localDay(for: date, timeZoneIdentifier: timeZoneIdentifier)
        return try history(on: day, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
    }

    public func events(
        on localDay: String,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> [FitnessLifestyleEvent] {
        try history(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier).filter(\.isActive)
    }

    public func daySummary(
        on localDay: String,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> FitnessLifestyleDaySummary {
        try requireReadable()
        try validateDay(localDay, timeZoneIdentifier: timeZoneIdentifier)
        let active = try events(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
        let quantities = active.filter { $0.state == .quantity }
        let none = active.contains { $0.state == .explicitNone }
        let alcoholFree = active.contains { $0.state == .alcoholFree }
        if !quantities.isEmpty {
            let units = Set(quantities.compactMap(\.unit))
            guard units.count == 1, let unit = units.first else {
                throw FitnessLifestyleStoreError.corruptStorage("mixed canonical units for \(kind.rawValue) on \(localDay)")
            }
            let total = quantities.reduce(0) { $0 + ($1.value ?? 0) }
            let provenance = Self.uniqueProvenance(quantities.map(\.provenance))
            let sourceSamples = Self.sourceSamples(for: quantities)
            return FitnessLifestyleDaySummary(localDay: localDay, kind: kind, total: total, unit: unit,
                                              explicitNone: false, missingness: .observed,
                                              provenance: provenance, sampleCount: quantities.count,
                                              sourceSamples: sourceSamples)
        }
        if none {
            let noneEvents = active.filter { $0.state == .explicitNone }
            return FitnessLifestyleDaySummary(localDay: localDay, kind: kind, total: nil, unit: nil,
                                              explicitNone: true, missingness: .explicitNone,
                                              provenance: Self.uniqueProvenance(noneEvents.map(\.provenance)), sampleCount: 0)
        }
        if alcoholFree {
            let freeEvents = active.filter { $0.state == .alcoholFree }
            return FitnessLifestyleDaySummary(localDay: localDay, kind: kind, total: nil, unit: nil,
                                              explicitNone: false, alcoholFree: true,
                                              missingness: .alcoholFree,
                                              provenance: Self.uniqueProvenance(freeEvents.map(\.provenance)), sampleCount: 0)
        }
        return FitnessLifestyleDaySummary(localDay: localDay, kind: kind, total: nil, unit: nil,
                                          explicitNone: false, missingness: .missing,
                                          provenance: [], sampleCount: 0)
    }

    public func daySummary(
        for date: Date,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> FitnessLifestyleDaySummary {
        let day = FitnessLifestyleTime.localDay(for: date, timeZoneIdentifier: timeZoneIdentifier)
        return try daySummary(on: day, kind: kind, timeZoneIdentifier: timeZoneIdentifier)
    }

    public func dailyTotal(
        on localDay: String,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> Double? {
        try daySummary(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier).total
    }

    public func correlationInput(
        on localDay: String,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> FitnessLifestyleCorrelationInput {
        try daySummary(on: localDay, kind: kind, timeZoneIdentifier: timeZoneIdentifier).correlationInput
    }

    public func correlationInput(
        for date: Date,
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> FitnessLifestyleCorrelationInput {
        try daySummary(for: date, kind: kind, timeZoneIdentifier: timeZoneIdentifier).correlationInput
    }

    /// Returns a summary for every supplied local day, including missing days.
    /// This prevents a downstream reviewed model from confusing an omitted day
    /// with an observed zero.
    public func dailySummaries(
        for localDays: [String],
        kind: FitnessLifestyleKind,
        timeZoneIdentifier: String
    ) throws -> [FitnessLifestyleDaySummary] {
        try localDays.map { try daySummary(on: $0, kind: kind, timeZoneIdentifier: timeZoneIdentifier) }
    }

    public func dailyInputSnapshot(on localDay: String, timeZoneIdentifier: String) throws -> FitnessLifestyleDailyInputSnapshot {
        let summaries = try FitnessLifestyleKind.allCases.map {
            try daySummary(on: localDay, kind: $0, timeZoneIdentifier: timeZoneIdentifier)
        }
        return FitnessLifestyleDailyInputSnapshot(localDay: localDay, timeZoneIdentifier: timeZoneIdentifier, summaries: summaries)
    }

    public func reload() throws {
        if let lastLoadError { throw lastLoadError }
        guard persistenceURL != nil else { return }
        lock.lock()
        defer { lock.unlock() }
        do {
            let loaded = try readStateFromDisk()
            events = loaded.readOnlyError == nil ? loaded.events : []
            storedSettings = loaded.readOnlyError == nil ? loaded.settings : []
            loadStatus = loaded.status
            integrityWarning = loaded.warning
            lastLoadError = loaded.readOnlyError
            revision &+= 1
            if let readOnlyError = loaded.readOnlyError { throw readOnlyError }
        } catch let error as FitnessLifestyleStoreError {
            events = []
            storedSettings = []
            lastLoadError = error
            loadStatus = .failed(error.localizedDescription)
            integrityWarning = "Lifestyle storage was not replaced; no values were treated as observations."
            throw error
        } catch {
            let wrapped = FitnessLifestyleStoreError.corruptStorage(error.localizedDescription)
            events = []
            storedSettings = []
            lastLoadError = wrapped
            loadStatus = .failed(wrapped.localizedDescription)
            integrityWarning = "Lifestyle storage was not replaced; no values were treated as observations."
            throw wrapped
        }
    }

    // MARK: Locked mutation/read helpers

    private func mutate<T>(_ body: (inout FitnessLifestyleStoreState) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        guard lastLoadError == nil else { throw lastLoadError! }
        var state: FitnessLifestyleStoreState
        if persistenceURL != nil {
            let loaded = try readStateFromDisk()
            if let readOnlyError = loaded.readOnlyError {
                throw readOnlyError
            }
            state = FitnessLifestyleStoreState(events: loaded.events, settings: loaded.settings)
        } else {
            state = FitnessLifestyleStoreState(events: events, settings: currentSettingsArray())
        }
        let result = try body(&state)
        try validateState(state)
        try writeState(state)
        events = state.events.sorted(by: Self.sortHistory)
        loadStatus = .loaded(eventCount: events.count, settingsCount: state.settings.count)
        integrityWarning = nil
        lastLoadError = nil
        revision &+= 1
        NotificationCenter.default.post(
            name: .fitnessLifestyleLedgerDidChange,
            object: persistenceURL?.standardizedFileURL.path,
            userInfo: ["revision": revision]
        )
        return result
    }

    private func withReadLock<T>(_ body: (FitnessLifestyleStoreState) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(FitnessLifestyleStoreState(events: events, settings: currentSettingsArray()))
    }

    private var storedSettings: [FitnessLifestyleSettings] = []

    private func currentSettingsArray() -> [FitnessLifestyleSettings] { storedSettings }

    private func currentSettings(for kind: FitnessLifestyleKind, in settings: [FitnessLifestyleSettings]) -> FitnessLifestyleSettings {
        settings.first(where: { $0.kind == kind }) ?? FitnessLifestyleSettings.defaults(for: kind)
    }

    private func insertStoredSettings(_ settings: [FitnessLifestyleSettings]) {
        storedSettings = settings
    }

    private func validateConflict(
        for event: FitnessLifestyleEvent,
        in events: [FitnessLifestyleEvent],
        excluding excluded: Set<UUID> = []
    ) throws {
        let activeSameDay = events.filter { existing in
            existing.isActive && !excluded.contains(existing.id) && existing.kind == event.kind &&
            existing.localDay == event.localDay && existing.timeZoneIdentifier == event.timeZoneIdentifier
        }
        if event.state == .explicitNone {
            if activeSameDay.contains(where: { $0.state == .quantity }) {
                throw FitnessLifestyleStoreError.conflictWithQuantity(event.kind, event.localDay)
            }
            if activeSameDay.contains(where: { $0.state == .explicitNone }) {
                throw FitnessLifestyleStoreError.conflictWithExplicitNone(event.kind, event.localDay)
            }
            if activeSameDay.contains(where: { $0.state == .alcoholFree }) {
                throw FitnessLifestyleStoreError.conflictWithAlcoholFree(event.kind, event.localDay)
            }
        } else if event.state == .alcoholFree {
            if event.kind != .alcohol { throw FitnessLifestyleStoreError.invalidEvent("alcohol-free kind") }
            if activeSameDay.contains(where: { $0.state == .quantity }) {
                throw FitnessLifestyleStoreError.conflictWithQuantity(event.kind, event.localDay)
            }
            if activeSameDay.contains(where: { $0.state == .alcoholFree }) {
                throw FitnessLifestyleStoreError.conflictWithAlcoholFree(event.kind, event.localDay)
            }
            if activeSameDay.contains(where: { $0.state == .explicitNone }) {
                throw FitnessLifestyleStoreError.conflictWithExplicitNone(event.kind, event.localDay)
            }
        } else if activeSameDay.contains(where: { $0.state == .explicitNone }) {
            throw FitnessLifestyleStoreError.conflictWithExplicitNone(event.kind, event.localDay)
        } else if activeSameDay.contains(where: { $0.state == .alcoholFree }) {
            throw FitnessLifestyleStoreError.conflictWithAlcoholFree(event.kind, event.localDay)
        } else if event.state == .quantity,
                  activeSameDay.contains(where: { $0.state == .quantity && $0.provenance != event.provenance }) {
            throw FitnessLifestyleStoreError.conflictWithMixedProvenance(event.kind, event.localDay)
        }
    }

    private func validateState(_ state: FitnessLifestyleStoreState) throws {
        var ids = Set<UUID>()
        for event in state.events {
            try FitnessLifestyleValidation.validate(event)
            guard ids.insert(event.id).inserted else { throw FitnessLifestyleStoreError.invalidEvent("duplicate id") }
        }
        var settingsKinds = Set<FitnessLifestyleKind>()
        for settings in state.settings {
            try FitnessLifestyleValidation.validate(settings)
            guard settingsKinds.insert(settings.kind).inserted else { throw FitnessLifestyleStoreError.invalidSettings("duplicate kind") }
        }
        try validateLineageGraph(state.events)
        // Validate active conflicts as a final invariant, including a state
        // loaded from disk rather than only newly inserted events.
        for event in state.events where event.isActive {
            try validateConflict(for: event, in: state.events, excluding: [event.id])
        }
    }

    /// Validates the complete revision graph rather than only the new node.
    /// A file with a missing parent, asymmetric supersession, a self-link, or
    /// a broken root/revision chain is quarantined instead of being repaired by
    /// guessing which record is newer.
    private func validateLineageGraph(_ events: [FitnessLifestyleEvent]) throws {
        let byID = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })
        var sourceKeys = Set<String>()
        for event in events {
            guard event.lineage.rootEventID != UUID(uuidString: "00000000-0000-0000-0000-000000000000")! else {
                throw FitnessLifestyleStoreError.invalidEvent("zero lineage root")
            }
            if let sourceUUID = event.sourceSampleUUID {
                let key = sourceUUID.uuidString.lowercased()
                guard sourceKeys.insert(key).inserted else {
                    throw FitnessLifestyleStoreError.invalidEvent("duplicate source sample identity")
                }
            }

            if let parentID = event.lineage.parentEventID {
                guard parentID != event.id, let parent = byID[parentID] else {
                    throw FitnessLifestyleStoreError.invalidEvent("missing or self-referencing lineage parent")
                }
                guard parent.lineage.rootEventID == event.lineage.rootEventID,
                      parent.lineage.revision + 1 == event.lineage.revision,
                      parent.kind == event.kind,
                      parent.provenance == event.provenance,
                      parent.sourceSampleUUID == event.sourceSampleUUID,
                      parent.sourceSampleRevision == event.sourceSampleRevision,
                      parent.supersededBy == event.id,
                      parent.supersededAt != nil else {
                    throw FitnessLifestyleStoreError.invalidEvent("lineage parent link is not symmetric")
                }
            } else {
                guard event.lineage.rootEventID == event.id, event.lineage.revision == 1 else {
                    throw FitnessLifestyleStoreError.invalidEvent("root revision must start at one")
                }
            }

            if let supersededBy = event.supersededBy {
                guard !event.isDeleted, supersededBy != event.id,
                      let child = byID[supersededBy],
                      child.lineage.parentEventID == event.id,
                      child.lineage.rootEventID == event.lineage.rootEventID,
                      child.lineage.revision == event.lineage.revision + 1,
                      event.supersededAt != nil else {
                    throw FitnessLifestyleStoreError.invalidEvent("supersession link is not symmetric")
                }
            } else {
                guard event.supersededAt == nil else {
                    throw FitnessLifestyleStoreError.invalidEvent("supersededAt without supersededBy")
                }
            }

            var cursor = event
            var visited = Set<UUID>()
            while let parentID = cursor.lineage.parentEventID {
                guard visited.insert(cursor.id).inserted, let parent = byID[parentID] else {
                    throw FitnessLifestyleStoreError.invalidEvent("cyclic or missing lineage chain")
                }
                cursor = parent
            }
            guard cursor.id == event.lineage.rootEventID else {
                throw FitnessLifestyleStoreError.invalidEvent("lineage root does not terminate at the declared root")
            }
        }
    }

    private func validateDay(_ localDay: String, timeZoneIdentifier: String) throws {
        guard FitnessLifestyleTime.isValidDay(localDay) else { throw FitnessLifestyleStoreError.invalidDay(localDay) }
        guard FitnessLifestyleTime.isValidTimeZoneIdentifier(timeZoneIdentifier) else {
            throw FitnessLifestyleStoreError.invalidDay("invalid IANA timezone")
        }
    }

    /// A quarantined file is not an empty ledger. Throwing from the
    /// day-scoped APIs prevents callers from rendering a fabricated
    /// `.missing` summary after an integrity failure. Non-throwing collection
    /// accessors above return an empty collection as an unavailable result.
    private func requireReadable() throws {
        lock.lock()
        defer { lock.unlock() }
        if let lastLoadError { throw lastLoadError }
    }

    /// Queries are intentionally bucketed by the timezone captured with the
    /// source event. Re-bucketing an instant into the viewer's timezone would
    /// silently merge contradictory historical days when a user travels.
    private func matches(_ event: FitnessLifestyleEvent, localDay: String, timeZoneIdentifier: String) -> Bool {
        event.timeZoneIdentifier == timeZoneIdentifier && event.localDay == localDay
    }

    private static func sortEvents(_ lhs: FitnessLifestyleEvent, _ rhs: FitnessLifestyleEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func sortHistory(_ lhs: FitnessLifestyleEvent, _ rhs: FitnessLifestyleEvent) -> Bool {
        if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
        if lhs.lineage.revision != rhs.lineage.revision { return lhs.lineage.revision < rhs.lineage.revision }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private static func uniqueProvenance(_ values: [FitnessLifestyleProvenance]) -> [FitnessLifestyleProvenance] {
        var result: [FitnessLifestyleProvenance] = []
        for value in values where !result.contains(value) { result.append(value) }
        return result
    }

    private static func sourceSamples(for events: [FitnessLifestyleEvent]) -> [FitnessLifestyleSourceSample] {
        events.compactMap { event in
            guard event.provenance == .healthKit,
                  let sampleUUID = event.sourceSampleUUID,
                  let sampleRevision = event.sourceSampleRevision else { return nil }
            return FitnessLifestyleSourceSample(
                eventID: event.id,
                sampleUUID: sampleUUID,
                sampleRevision: sampleRevision,
                lineageRootEventID: event.lineage.rootEventID,
                lineageRevision: event.lineage.revision
            )
        }
    }

    // MARK: File operations

    private func loadInitialState() {
        lock.lock()
        defer { lock.unlock() }
        guard let persistenceURL, FileManager.default.fileExists(atPath: persistenceURL.path) else {
            loadStatus = .empty
            return
        }
        do {
            let loaded = try readStateFromDisk()
            events = loaded.readOnlyError == nil ? loaded.events : []
            storedSettings = loaded.readOnlyError == nil ? loaded.settings : []
            loadStatus = loaded.status
            integrityWarning = loaded.warning
            lastLoadError = loaded.readOnlyError
        } catch let error as FitnessLifestyleStoreError {
            lastLoadError = error
            loadStatus = .failed(error.localizedDescription)
            integrityWarning = "Lifestyle storage was not replaced; no values were treated as observations."
            events = []
            storedSettings = []
        } catch {
            let wrapped = FitnessLifestyleStoreError.corruptStorage(error.localizedDescription)
            lastLoadError = wrapped
            loadStatus = .failed(wrapped.localizedDescription)
            integrityWarning = "Lifestyle storage was not replaced; no values were treated as observations."
            events = []
            storedSettings = []
        }
    }

    private struct LoadedState {
        let events: [FitnessLifestyleEvent]
        let settings: [FitnessLifestyleSettings]
        let status: FitnessLifestyleLoadStatus
        let warning: String?
        let readOnlyError: FitnessLifestyleStoreError?
    }

    private func readStateFromDisk() throws -> LoadedState {
        guard let persistenceURL else {
            return LoadedState(events: events, settings: storedSettings, status: .empty, warning: nil, readOnlyError: nil)
        }
        guard FileManager.default.fileExists(atPath: persistenceURL.path) else {
            return LoadedState(events: [], settings: [], status: .empty, warning: nil, readOnlyError: nil)
        }
        do {
            let data = try Data(contentsOf: persistenceURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let envelope = try decoder.decode(FitnessLifestyleStorageEnvelope.self, from: data)
            guard envelope.schemaVersion == FitnessLifestyleValidation.schemaVersion else {
                throw FitnessLifestyleStoreError.unsupportedSchemaVersion(envelope.schemaVersion)
            }
            var filtered = 0
            var validEvents: [FitnessLifestyleEvent] = []
            var seenIDs = Set<UUID>()
            for stored in envelope.events {
                let event = stored.eventValue()
                do {
                    try FitnessLifestyleValidation.validate(event)
                    guard seenIDs.insert(event.id).inserted else { throw FitnessLifestyleStoreError.invalidEvent("duplicate id") }
                    validEvents.append(event)
                } catch {
                    filtered += 1
                }
            }
            var validSettings: [FitnessLifestyleSettings] = []
            var seenKinds = Set<FitnessLifestyleKind>()
            for stored in envelope.settings {
                let settings = stored.settingsValue()
                do {
                    try FitnessLifestyleValidation.validate(settings)
                    guard seenKinds.insert(settings.kind).inserted else { throw FitnessLifestyleStoreError.invalidSettings("duplicate kind") }
                    validSettings.append(settings)
                } catch {
                    filtered += 1
                }
            }
            let sortedEvents = validEvents.sorted(by: Self.sortHistory)
            if filtered > 0 {
                let warning = "\(filtered) lifestyle record\(filtered == 1 ? "" : "s") failed integrity validation. The file is read-only until it is repaired; no values are treated as observations."
                let error = FitnessLifestyleStoreError.corruptStorage("filtered invalid lifestyle records")
                return LoadedState(
                    events: sortedEvents,
                    settings: validSettings,
                    status: .filteredInvalidRecords(count: filtered),
                    warning: warning,
                    readOnlyError: error
                )
            }

            do {
                try validateLineageGraph(sortedEvents)
                if let conflict = activeConflictDescription(sortedEvents) {
                    throw FitnessLifestyleStoreError.corruptStorage(conflict)
                }
            } catch let error as FitnessLifestyleStoreError {
                return LoadedState(
                    events: sortedEvents,
                    settings: validSettings,
                    status: .failed(error.localizedDescription),
                    warning: "Lifestyle history failed an integrity check and is read-only; no values are treated as observations.",
                    readOnlyError: error
                )
            }

            return LoadedState(
                events: sortedEvents,
                settings: validSettings,
                status: .loaded(eventCount: sortedEvents.count, settingsCount: validSettings.count),
                warning: nil,
                readOnlyError: nil
            )
        } catch let error as FitnessLifestyleStoreError {
            throw error
        } catch {
            throw FitnessLifestyleStoreError.corruptStorage(error.localizedDescription)
        }
    }

    private func activeConflictDescription(_ events: [FitnessLifestyleEvent]) -> String? {
        let groups = Dictionary(grouping: events.filter(\.isActive), by: {
            "\($0.kind.rawValue)|\($0.timeZoneIdentifier)|\($0.localDay)"
        })
        for (key, group) in groups {
            let noneCount = group.filter { $0.state == .explicitNone }.count
            let quantityCount = group.filter { $0.state == .quantity }.count
            let alcoholFreeCount = group.filter { $0.state == .alcoholFree }.count
            if (noneCount > 0 && (quantityCount > 0 || alcoholFreeCount > 0)) ||
                (quantityCount > 0 && alcoholFreeCount > 0) {
                return "conflicting lifestyle states in \(key)"
            }
            if noneCount > 1 {
                return "duplicate explicit-none records in \(key)"
            }
            if alcoholFreeCount > 1 {
                return "duplicate alcohol-free records in \(key)"
            }
            if quantityCount > 0 && Set(group.filter { $0.state == .quantity }.map(\.provenance)).count > 1 {
                return "mixed provenance quantities in \(key)"
            }
            let units = Set(group.compactMap(\.unit))
            if units.count > 1 {
                return "mixed canonical units in \(key)"
            }
        }
        return nil
    }

    private func writeState(_ state: FitnessLifestyleStoreState) throws {
        guard let persistenceURL else {
            storedSettings = state.settings
            return
        }
        do {
            try FileManager.default.createDirectory(at: persistenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(FitnessLifestyleStorageEnvelope(events: state.events, settings: state.settings))
#if os(iOS)
            try data.write(to: persistenceURL, options: [.atomic, .completeFileProtection])
#else
            try data.write(to: persistenceURL, options: [.atomic])
#endif
            storedSettings = state.settings
        } catch {
            throw FitnessLifestyleStoreError.persistenceFailed(error.localizedDescription)
        }
    }
}
