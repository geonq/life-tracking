// Supplement history, inventory, correction, and occurrence-action contracts.
import Foundation

private let supplementHistoryMaxRevision = 9_007_199_254_740_991
private let supplementHistoryMaxInventoryUnits = 1_000_000_000

private func decodeSupplementHistoryTimestamp<Key: CodingKey>(
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>,
    field: String
) throws -> Date {
    let raw = try container.decode(String.self, forKey: key)
    guard raw.utf8.count <= 40 else {
        throw SupplementValidationError.invalidTimestamp(field)
    }

    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let standard = ISO8601DateFormatter()
    standard.formatOptions = [.withInternetDateTime]
    guard let date = fractional.date(from: raw) ?? standard.date(from: raw),
          date.timeIntervalSinceReferenceDate.isFinite else {
        throw SupplementValidationError.invalidTimestamp(field)
    }
    return date
}

private func decodeSupplementHistoryOptionalTimestamp<Key: CodingKey>(
    forKey key: Key,
    from container: KeyedDecodingContainer<Key>,
    field: String
) throws -> Date? {
    guard container.contains(key) else { return nil }
    guard try !container.decodeNil(forKey: key) else {
        throw DecodingError.valueNotFound(
            Date.self,
            .init(codingPath: container.codingPath + [key], debugDescription: "Explicit null is not accepted")
        )
    }
    return try decodeSupplementHistoryTimestamp(forKey: key, from: container, field: field)
}

private func validateSupplementHistoryTimestamp(_ date: Date, field: String) throws {
    guard date.timeIntervalSinceReferenceDate.isFinite else {
        throw SupplementValidationError.invalidTimestamp(field)
    }
}

public enum SupplementOccurrenceState: String, Codable, CaseIterable, Equatable, Sendable {
    case planned
    case taken
    case snoozed
    case skipped
    case missed
}

public struct SupplementOccurrence: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var planID: String
    public var scheduledFor: Date
    public var state: SupplementOccurrenceState
    public var actedAt: Date?
    public var snoozedUntil: Date?
    public var revision: Int
    public var updatedAt: Date

    private enum CodingKeys: String, CodingKey {
        case id, planID, scheduledFor, state, actedAt, snoozedUntil, revision, updatedAt
    }

    public init(
        id: String,
        planID: String,
        scheduledFor: Date,
        state: SupplementOccurrenceState = .planned,
        actedAt: Date? = nil,
        snoozedUntil: Date? = nil,
        revision: Int,
        updatedAt: Date
    ) throws {
        self.id = id
        self.planID = planID
        self.scheduledFor = scheduledFor
        self.state = state
        self.actedAt = actedAt
        self.snoozedUntil = snoozedUntil
        self.revision = revision
        self.updatedAt = updatedAt
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "id", "planID", "scheduledFor", "state", "actedAt", "snoozedUntil", "revision", "updatedAt"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        planID = try container.decode(String.self, forKey: .planID)
        scheduledFor = try decodeSupplementHistoryTimestamp(
            forKey: .scheduledFor, from: container, field: "scheduledFor"
        )
        state = try container.decode(SupplementOccurrenceState.self, forKey: .state)
        actedAt = try decodeSupplementHistoryOptionalTimestamp(
            forKey: .actedAt, from: container, field: "actedAt"
        )
        snoozedUntil = try decodeSupplementHistoryOptionalTimestamp(
            forKey: .snoozedUntil, from: container, field: "snoozedUntil"
        )
        revision = try container.decode(Int.self, forKey: .revision)
        updatedAt = try decodeSupplementHistoryTimestamp(
            forKey: .updatedAt, from: container, field: "updatedAt"
        )
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        try SupplementValidation.validateOpaqueID(id, field: "occurrence.id")
        try SupplementValidation.validateOpaqueID(planID, field: "occurrence.planID")
        guard (0...supplementHistoryMaxRevision).contains(revision) else {
            throw SupplementValidationError.invalidBounds("occurrence.revision")
        }
        try validateSupplementHistoryTimestamp(scheduledFor, field: "scheduledFor")
        if let actedAt {
            try SupplementValidation.validateObserved(actedAt, field: "actedAt", now: now)
        }
        if let snoozedUntil {
            try validateSupplementHistoryTimestamp(snoozedUntil, field: "snoozedUntil")
        }
        try SupplementValidation.validateObserved(updatedAt, field: "updatedAt", now: now)

        switch state {
        case .planned, .missed:
            guard actedAt == nil, snoozedUntil == nil else {
                throw SupplementValidationError.contradictoryState(
                    "\(state.rawValue) occurrence action timestamps"
                )
            }
        case .snoozed:
            guard let actedAt, let snoozedUntil, snoozedUntil > actedAt else {
                throw SupplementValidationError.contradictoryState("snoozed occurrence timestamps")
            }
        case .taken, .skipped:
            guard actedAt != nil, snoozedUntil == nil else {
                throw SupplementValidationError.contradictoryState(
                    "\(state.rawValue) occurrence timestamps"
                )
            }
        }
    }
}

public enum SupplementCorrectionEntityKind: String, Codable, CaseIterable, Equatable, Sendable {
    case plan
    case schedule
    case occurrence
    case inventory
}

/// The only values permitted in a correction's before/after fields.
public enum SupplementScalarValue: Equatable, Sendable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    /// Compatibility spelling for callers that use the JSON type name.
    public static func boolean(_ value: Bool) -> SupplementScalarValue { .bool(value) }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let value = try? container.decode(String.self) {
            guard value.utf16.count <= 1_000 else {
                throw SupplementValidationError.invalidText("scalarValue")
            }
            self = .string(value)
            return
        }
        if let value = try? container.decode(Bool.self) {
            self = .bool(value)
            return
        }
        if let value = try? container.decode(Double.self),
           value.isFinite,
           value >= -Double(supplementHistoryMaxRevision),
           value <= Double(supplementHistoryMaxRevision) {
            self = .number(value)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "Supplement scalar value must be a bounded string, number, boolean, or null"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            guard value.utf16.count <= 1_000 else {
                throw SupplementValidationError.invalidText("scalarValue")
            }
            try container.encode(value)
        case .number(let value):
            guard value.isFinite,
                  value >= -Double(supplementHistoryMaxRevision),
                  value <= Double(supplementHistoryMaxRevision) else {
                throw SupplementValidationError.invalidBounds("scalarValue")
            }
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    fileprivate func isIdentical(to other: SupplementScalarValue) -> Bool {
        switch (self, other) {
        case (.string(let lhs), .string(let rhs)): return lhs == rhs
        case (.bool(let lhs), .bool(let rhs)): return lhs == rhs
        case (.null, .null): return true
        case (.number(let lhs), .number(let rhs)):
            return lhs.bitPattern == rhs.bitPattern
        default:
            return false
        }
    }

    fileprivate func validate() throws {
        switch self {
        case .string(let value):
            guard value.utf16.count <= 1_000 else {
                throw SupplementValidationError.invalidText("scalarValue")
            }
        case .number(let value):
            guard value.isFinite,
                  value >= -Double(supplementHistoryMaxRevision),
                  value <= Double(supplementHistoryMaxRevision) else {
                throw SupplementValidationError.invalidBounds("scalarValue")
            }
        case .bool, .null:
            break
        }
    }
}

public struct SupplementCorrection: Codable, Equatable, Sendable {
    public let id: String
    public let entityKind: SupplementCorrectionEntityKind
    public let entityID: String
    public let field: String
    public let oldValue: SupplementScalarValue
    public let newValue: SupplementScalarValue
    public let actorID: String
    public let correctedAt: Date
    public let reason: String

    private enum CodingKeys: String, CodingKey {
        case id, entityKind, entityID, field, oldValue, newValue, actorID, correctedAt, reason
    }

    public init(
        id: String,
        entityKind: SupplementCorrectionEntityKind,
        entityID: String,
        field: String,
        oldValue: SupplementScalarValue,
        newValue: SupplementScalarValue,
        actorID: String,
        correctedAt: Date,
        reason: String
    ) throws {
        self.id = id
        self.entityKind = entityKind
        self.entityID = entityID
        self.field = field
        self.oldValue = oldValue
        self.newValue = newValue
        self.actorID = actorID
        self.correctedAt = correctedAt
        self.reason = reason
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "id", "entityKind", "entityID", "field", "oldValue", "newValue", "actorID", "correctedAt", "reason"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        entityKind = try container.decode(SupplementCorrectionEntityKind.self, forKey: .entityKind)
        entityID = try container.decode(String.self, forKey: .entityID)
        field = try container.decode(String.self, forKey: .field)
        oldValue = try container.decode(SupplementScalarValue.self, forKey: .oldValue)
        newValue = try container.decode(SupplementScalarValue.self, forKey: .newValue)
        actorID = try container.decode(String.self, forKey: .actorID)
        correctedAt = try decodeSupplementHistoryTimestamp(
            forKey: .correctedAt, from: container, field: "correctedAt"
        )
        reason = try container.decode(String.self, forKey: .reason)
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        try SupplementValidation.validateOpaqueID(id, field: "correction.id")
        try SupplementValidation.validateOpaqueID(entityID, field: "correction.entityID")
        try SupplementValidation.validateOpaqueID(actorID, field: "correction.actorID")
        try SupplementValidation.validateText(field, field: "correction.field", max: 64)
        try SupplementValidation.validateText(reason, field: "correction.reason", max: 500)
        try oldValue.validate()
        try newValue.validate()
        guard !oldValue.isIdentical(to: newValue) else {
            throw SupplementValidationError.contradictoryState(
                "correction oldValue and newValue must differ"
            )
        }
        try SupplementValidation.validateObserved(correctedAt, field: "correctedAt", now: now)
    }
}

public enum InventoryEventKind: String, Codable, CaseIterable, Equatable, Sendable {
    case takenDecrement = "taken_decrement"
    case manualAdjustment = "manual_adjustment"
    case refill
    case correction
}

public struct SupplementForecastAssumptions: Codable, Equatable, Sendable {
    public let dosesPerScheduledDay: Double
    public let scheduledDaysPerWeek: Int
    public let inventoryUnitsPerDose: Int
    public let asOf: Date

    private enum CodingKeys: String, CodingKey {
        case dosesPerScheduledDay, scheduledDaysPerWeek, inventoryUnitsPerDose, asOf
    }

    public init(
        dosesPerScheduledDay: Double,
        scheduledDaysPerWeek: Int,
        inventoryUnitsPerDose: Int,
        asOf: Date
    ) throws {
        self.dosesPerScheduledDay = dosesPerScheduledDay
        self.scheduledDaysPerWeek = scheduledDaysPerWeek
        self.inventoryUnitsPerDose = inventoryUnitsPerDose
        self.asOf = asOf
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "dosesPerScheduledDay", "scheduledDaysPerWeek", "inventoryUnitsPerDose", "asOf"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        dosesPerScheduledDay = try container.decode(Double.self, forKey: .dosesPerScheduledDay)
        scheduledDaysPerWeek = try container.decode(Int.self, forKey: .scheduledDaysPerWeek)
        inventoryUnitsPerDose = try container.decode(Int.self, forKey: .inventoryUnitsPerDose)
        asOf = try decodeSupplementHistoryTimestamp(forKey: .asOf, from: container, field: "asOf")
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        guard dosesPerScheduledDay.isFinite, dosesPerScheduledDay > 0, dosesPerScheduledDay <= 100,
              (1...7).contains(scheduledDaysPerWeek),
              (1...supplementHistoryMaxInventoryUnits).contains(inventoryUnitsPerDose) else {
            throw SupplementValidationError.invalidBounds("forecastAssumptions")
        }
        try SupplementValidation.validateObserved(asOf, field: "forecastAssumptions.asOf", now: now)
    }
}

public struct InventoryEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let planID: String
    public let kind: InventoryEventKind
    public let delta: Int
    public let stockAfter: Int
    public let occurredAt: Date
    public let occurrenceID: String?
    public let costCents: Int?
    public let batch: String?
    public let expiry: Date?
    public let source: String?
    public let forecastAssumptions: SupplementForecastAssumptions?

    private enum CodingKeys: String, CodingKey {
        case id, planID, kind, delta, stockAfter, occurredAt, occurrenceID, costCents, batch, expiry, source, forecastAssumptions
    }

    public init(
        id: String,
        planID: String,
        kind: InventoryEventKind,
        delta: Int,
        stockAfter: Int,
        occurredAt: Date,
        occurrenceID: String? = nil,
        costCents: Int? = nil,
        batch: String? = nil,
        expiry: Date? = nil,
        source: String? = nil,
        forecastAssumptions: SupplementForecastAssumptions? = nil,
        now: Date = .now
    ) throws {
        self.id = id
        self.planID = planID
        self.kind = kind
        self.delta = delta
        self.stockAfter = stockAfter
        self.occurredAt = occurredAt
        self.occurrenceID = occurrenceID
        self.costCents = costCents
        self.batch = batch
        self.expiry = expiry
        self.source = source
        self.forecastAssumptions = forecastAssumptions
        try validate(now: now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "id", "planID", "kind", "delta", "stockAfter", "occurredAt", "occurrenceID", "costCents",
            "batch", "expiry", "source", "forecastAssumptions"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        planID = try container.decode(String.self, forKey: .planID)
        kind = try container.decode(InventoryEventKind.self, forKey: .kind)
        delta = try container.decode(Int.self, forKey: .delta)
        stockAfter = try container.decode(Int.self, forKey: .stockAfter)
        occurredAt = try decodeSupplementHistoryTimestamp(forKey: .occurredAt, from: container, field: "occurredAt")
        occurrenceID = try decodeSupplementOptional(String.self, forKey: .occurrenceID, from: container)
        costCents = try decodeSupplementOptional(Int.self, forKey: .costCents, from: container)
        batch = try decodeSupplementOptional(String.self, forKey: .batch, from: container)
        expiry = try decodeSupplementHistoryOptionalTimestamp(forKey: .expiry, from: container, field: "expiry")
        source = try decodeSupplementOptional(String.self, forKey: .source, from: container)
        forecastAssumptions = try decodeSupplementOptional(
            SupplementForecastAssumptions.self, forKey: .forecastAssumptions, from: container
        )
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        try SupplementValidation.validateOpaqueID(id, field: "inventoryEvent.id")
        try SupplementValidation.validateOpaqueID(planID, field: "inventoryEvent.planID")
        if let occurrenceID {
            try SupplementValidation.validateOpaqueID(occurrenceID, field: "inventoryEvent.occurrenceID")
        }
        guard (-supplementHistoryMaxInventoryUnits...supplementHistoryMaxInventoryUnits).contains(delta),
              delta != 0,
              (0...supplementHistoryMaxInventoryUnits).contains(stockAfter),
              (0...supplementHistoryMaxRevision).contains(costCents ?? 0) else {
            throw SupplementValidationError.invalidBounds("inventoryEvent")
        }
        if let costCents {
            guard (0...supplementHistoryMaxRevision).contains(costCents) else {
                throw SupplementValidationError.invalidBounds("inventoryEvent.costCents")
            }
        }
        if let batch { try SupplementValidation.validateText(batch, field: "inventoryEvent.batch", max: 128) }
        if let source { try SupplementValidation.validateText(source, field: "inventoryEvent.source", max: 128) }
        try validateSupplementHistoryTimestamp(occurredAt, field: "occurredAt")
        if let expiry { try validateSupplementHistoryTimestamp(expiry, field: "expiry") }
        try SupplementValidation.validateObserved(occurredAt, field: "occurredAt", now: now)
        try forecastAssumptions?.validate(now: now)

        if kind == .takenDecrement {
            guard occurrenceID != nil, delta < 0 else {
                throw SupplementValidationError.contradictoryState(
                    "Taken decrement requires an occurrenceID and a negative delta"
                )
            }
        } else {
            guard occurrenceID == nil else {
                throw SupplementValidationError.contradictoryState(
                    "only Taken decrement may reference an occurrence"
                )
            }
        }
        if kind == .refill {
            guard delta > 0 else {
                throw SupplementValidationError.contradictoryState("refill must increase inventory")
            }
        }
        if kind != .refill && (costCents != nil || batch != nil || expiry != nil) {
            throw SupplementValidationError.contradictoryState(
                "cost, batch, and expiry are only valid for refills"
            )
        }
    }
}

public struct SupplementSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public var generatedAt: Date
    public var revision: Int
    public var plans: [SupplementPlan]
    public var occurrences: [SupplementOccurrence]
    public var corrections: [SupplementCorrection]
    public var inventoryEvents: [InventoryEvent]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, generatedAt, revision, plans, occurrences, corrections, inventoryEvents
    }

    public init(
        generatedAt: Date,
        revision: Int,
        plans: [SupplementPlan],
        occurrences: [SupplementOccurrence],
        corrections: [SupplementCorrection] = [],
        inventoryEvents: [InventoryEvent] = []
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.generatedAt = generatedAt
        self.revision = revision
        self.plans = plans
        self.occurrences = occurrences
        self.corrections = corrections
        self.inventoryEvents = inventoryEvents
        try validate(now: .now)
    }

    public init(
        schemaVersion: Int,
        generatedAt: Date,
        revision: Int,
        plans: [SupplementPlan],
        occurrences: [SupplementOccurrence],
        corrections: [SupplementCorrection] = [],
        inventoryEvents: [InventoryEvent] = []
    ) throws {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.revision = revision
        self.plans = plans
        self.occurrences = occurrences
        self.corrections = corrections
        self.inventoryEvents = inventoryEvents
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "schemaVersion", "generatedAt", "revision", "plans", "occurrences", "corrections", "inventoryEvents"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        generatedAt = try decodeSupplementHistoryTimestamp(
            forKey: .generatedAt, from: container, field: "generatedAt"
        )
        revision = try container.decode(Int.self, forKey: .revision)
        plans = try container.decode([SupplementPlan].self, forKey: .plans)
        occurrences = try container.decode([SupplementOccurrence].self, forKey: .occurrences)
        corrections = try container.decode([SupplementCorrection].self, forKey: .corrections)
        inventoryEvents = try container.decode([InventoryEvent].self, forKey: .inventoryEvents)
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> SupplementSnapshot {
        let decoder = JSONDecoder.lifeOS
        decoder.userInfo[.lifeOSNow] = now
        return try decoder.decode(Self.self, from: data)
    }

    public func validate(now: Date = .now) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw SupplementValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        try SupplementValidation.validateObserved(generatedAt, field: "generatedAt", now: now)
        guard (0...supplementHistoryMaxRevision).contains(revision),
              plans.count <= 10_000,
              occurrences.count <= 100_000,
              corrections.count <= 100_000,
              inventoryEvents.count <= 100_000 else {
            throw SupplementValidationError.invalidBounds("snapshot")
        }

        var planIDs = Set<String>()
        for plan in plans {
            try plan.validate(now: now)
            guard planIDs.insert(plan.id).inserted else {
                throw SupplementValidationError.duplicateIdentifier(plan.id)
            }
        }

        var occurrenceIDs = Set<String>()
        for occurrence in occurrences {
            try occurrence.validate(now: now)
            guard occurrenceIDs.insert(occurrence.id).inserted else {
                throw SupplementValidationError.duplicateIdentifier(occurrence.id)
            }
            guard planIDs.contains(occurrence.planID) else {
                throw SupplementValidationError.danglingPlanReference(occurrence.planID)
            }
        }

        var correctionIDs = Set<String>()
        for correction in corrections {
            try correction.validate(now: now)
            guard correctionIDs.insert(correction.id).inserted else {
                throw SupplementValidationError.duplicateIdentifier(correction.id)
            }
            switch correction.entityKind {
            case .plan, .schedule:
                guard planIDs.contains(correction.entityID) else {
                    throw SupplementValidationError.danglingPlanReference(correction.entityID)
                }
            case .occurrence:
                guard occurrenceIDs.contains(correction.entityID) else {
                    throw SupplementValidationError.danglingPlanReference(correction.entityID)
                }
            case .inventory:
                break
            }
        }

        var inventoryEventIDs = Set<String>()
        for event in inventoryEvents {
            try event.validate(now: now)
            guard inventoryEventIDs.insert(event.id).inserted else {
                throw SupplementValidationError.duplicateIdentifier(event.id)
            }
            guard planIDs.contains(event.planID) else {
                throw SupplementValidationError.danglingPlanReference(event.planID)
            }
            if event.kind == .takenDecrement, let occurrenceID = event.occurrenceID {
                guard let occurrence = occurrences.first(where: { $0.id == occurrenceID }),
                      occurrence.planID == event.planID,
                      occurrence.state == .taken else {
                    throw SupplementValidationError.contradictoryState(
                        "Taken decrement occurrence link is invalid"
                    )
                }
            }
        }

        for correction in corrections where correction.entityKind == .inventory {
            guard inventoryEventIDs.contains(correction.entityID) else {
                throw SupplementValidationError.danglingPlanReference(correction.entityID)
            }
        }
    }
}

public enum SupplementAction: String, Codable, CaseIterable, Equatable, Sendable {
    case taken
    case snooze
    case skip
}

public struct SupplementOccurrenceActionRequest: Codable, Equatable, Sendable {
    public let actionID: String
    public let occurrenceID: String
    public let planID: String
    public let action: SupplementAction
    public let occurredAt: Date
    public let snoozeUntil: Date?
    public let baseRevision: Int
    public let sourceDeviceID: String

    private enum CodingKeys: String, CodingKey {
        case actionID, occurrenceID, planID, action, occurredAt, snoozeUntil, baseRevision, sourceDeviceID
    }

    public init(
        actionID: String,
        occurrenceID: String,
        planID: String,
        action: SupplementAction,
        occurredAt: Date,
        snoozeUntil: Date? = nil,
        baseRevision: Int,
        sourceDeviceID: String
    ) throws {
        self.actionID = actionID
        self.occurrenceID = occurrenceID
        self.planID = planID
        self.action = action
        self.occurredAt = occurredAt
        self.snoozeUntil = snoozeUntil
        self.baseRevision = baseRevision
        self.sourceDeviceID = sourceDeviceID
        try validate(now: .now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "actionID", "occurrenceID", "planID", "action", "occurredAt", "snoozeUntil", "baseRevision", "sourceDeviceID"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        actionID = try container.decode(String.self, forKey: .actionID)
        occurrenceID = try container.decode(String.self, forKey: .occurrenceID)
        planID = try container.decode(String.self, forKey: .planID)
        action = try container.decode(SupplementAction.self, forKey: .action)
        occurredAt = try decodeSupplementHistoryTimestamp(forKey: .occurredAt, from: container, field: "occurredAt")
        snoozeUntil = try decodeSupplementHistoryOptionalTimestamp(
            forKey: .snoozeUntil, from: container, field: "snoozeUntil"
        )
        baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        sourceDeviceID = try container.decode(String.self, forKey: .sourceDeviceID)
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    public func validate(now: Date = .now) throws {
        try SupplementValidation.validateOpaqueID(actionID, field: "actionID")
        try SupplementValidation.validateOpaqueID(occurrenceID, field: "occurrenceID")
        try SupplementValidation.validateOpaqueID(planID, field: "planID")
        try SupplementValidation.validateOpaqueID(sourceDeviceID, field: "sourceDeviceID")
        guard (0...supplementHistoryMaxRevision).contains(baseRevision) else {
            throw SupplementValidationError.invalidBounds("baseRevision")
        }
        try validateSupplementHistoryTimestamp(occurredAt, field: "occurredAt")
        try SupplementValidation.validateObserved(occurredAt, field: "occurredAt", now: now)
        if let snoozeUntil {
            try validateSupplementHistoryTimestamp(snoozeUntil, field: "snoozeUntil")
        }

        if action == .snooze {
            guard let snoozeUntil, snoozeUntil > occurredAt else {
                throw SupplementValidationError.invalidAction("snooze action requires a later snoozeUntil")
            }
        } else if snoozeUntil != nil {
            throw SupplementValidationError.invalidAction(
                "only snooze actions may set snoozeUntil"
            )
        }
    }
}

public struct SupplementOccurrenceActionResponse: Codable, Equatable, Sendable {
    public let occurrence: SupplementOccurrence
    public let inventoryDelta: Int
    public let idempotent: Bool
    public let serverRevision: Int

    private enum CodingKeys: String, CodingKey {
        case occurrence, inventoryDelta, idempotent, serverRevision
    }

    public init(
        occurrence: SupplementOccurrence,
        inventoryDelta: Int,
        idempotent: Bool,
        serverRevision: Int,
        now: Date = .now
    ) throws {
        self.occurrence = occurrence
        self.inventoryDelta = inventoryDelta
        self.idempotent = idempotent
        self.serverRevision = serverRevision
        try validate(now: now)
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownSupplementKeys(decoder, allowed: [
            "occurrence", "inventoryDelta", "idempotent", "serverRevision"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        occurrence = try container.decode(SupplementOccurrence.self, forKey: .occurrence)
        inventoryDelta = try container.decode(Int.self, forKey: .inventoryDelta)
        idempotent = try container.decode(Bool.self, forKey: .idempotent)
        serverRevision = try container.decode(Int.self, forKey: .serverRevision)
        try validate(now: decoder.userInfo[.lifeOSNow] as? Date ?? .now)
    }

    private func validate(now: Date = .now) throws {
        try occurrence.validate(now: now)
        guard (-supplementHistoryMaxInventoryUnits...0).contains(inventoryDelta),
              (0...supplementHistoryMaxRevision).contains(serverRevision) else {
            throw SupplementValidationError.invalidBounds("actionResponse")
        }
        if idempotent, inventoryDelta != 0 {
            throw SupplementValidationError.contradictoryState(
                "idempotent replay cannot change inventory"
            )
        }
        if !idempotent, occurrence.state != .taken, inventoryDelta != 0 {
            throw SupplementValidationError.contradictoryState(
                "Snooze and Skip cannot change inventory"
            )
        }
    }
}
