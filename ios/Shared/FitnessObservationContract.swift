import Foundation

/// The only Fitness data allowed to cross the authenticated Tailscale route.
/// It contains source-backed quantities and bounded workout evidence, never
/// raw HealthKit objects, identifiers, credentials, or proprietary scores.
public enum FitnessObservationContractError: Error, Equatable, Sendable {
    case malformed
    case unsupportedSchema
    case invalidState
    case invalidValue
    case futureTimestamp
    case stale
    case oversized
}

public enum FitnessObservationState: String, Codable, CaseIterable, Equatable, Sendable {
    case observed
    case stale
    case unavailable
    case permissionRequired = "permission_required"
}

public enum FitnessObservationSource: String, Codable, CaseIterable, Equatable, Sendable {
    case healthKit = "healthkit"
}

public enum FitnessObservationProvenance: String, Codable, CaseIterable, Equatable, Sendable {
    case iPhoneHealthKitProjection = "iphone_healthkit_projection"
}

public enum FitnessObservationMetricID: String, Codable, CaseIterable, Hashable, Equatable, Sendable {
    case heartRate = "heart_rate"
    case restingHeartRate = "resting_heart_rate"
    case heartRateVariability = "heart_rate_variability"
    case respiratoryRate = "respiratory_rate"
    case oxygenSaturation = "oxygen_saturation"
    case vo2Max = "vo2_max"
    case bodyMass = "body_mass"
    case bodyFatPercentage = "body_fat_percentage"
    case leanBodyMass = "lean_body_mass"
    case steps
    case activeEnergy = "active_energy"
    case water
    case caffeine
    case sleepDuration = "sleep_duration"

    public var unit: FitnessObservationUnit {
        switch self {
        case .heartRate, .restingHeartRate: .beatsPerMinute
        case .heartRateVariability: .milliseconds
        case .respiratoryRate: .perMinute
        case .oxygenSaturation, .bodyFatPercentage: .percent
        case .vo2Max: .millilitersPerKilogramMinute
        case .bodyMass, .leanBodyMass: .kilograms
        case .steps: .count
        case .activeEnergy: .kilocalories
        case .water: .milliliters
        case .caffeine: .milligrams
        case .sleepDuration: .seconds
        }
    }

    var isDailyMetric: Bool {
        switch self {
        case .steps, .activeEnergy, .water, .caffeine, .sleepDuration: true
        default: false
        }
    }

    var maximumValue: Double {
        switch self {
        case .heartRate, .restingHeartRate, .respiratoryRate: 1_000
        case .heartRateVariability: 10_000
        case .oxygenSaturation, .bodyFatPercentage: 100
        case .vo2Max: 200
        case .bodyMass, .leanBodyMass: 1_000
        case .steps: 1_000_000
        case .activeEnergy: 1_000_000
        case .water: 1_000_000
        case .caffeine: 1_000_000
        case .sleepDuration: 172_800
        }
    }
}

public enum FitnessObservationUnit: String, Codable, CaseIterable, Equatable, Sendable {
    case beatsPerMinute = "bpm"
    case milliseconds = "ms"
    case perMinute = "per_minute"
    case percent
    case millilitersPerKilogramMinute = "ml_per_kg_min"
    case kilograms = "kg"
    case count
    case kilocalories = "kcal"
    case milliliters = "ml"
    case milligrams = "mg"
    case seconds
}

public struct FitnessObservationValue: Codable, Equatable, Sendable {
    public let metric: FitnessObservationMetricID
    public let value: Double
    public let unit: FitnessObservationUnit
    public let observedAt: Date

    public init(
        metric: FitnessObservationMetricID,
        value: Double,
        unit: FitnessObservationUnit,
        observedAt: Date
    ) throws {
        guard value.isFinite, value >= 0, unit == metric.unit,
              observedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw FitnessObservationContractError.invalidValue
        }
        self.metric = metric
        self.value = value
        self.unit = unit
        self.observedAt = observedAt
    }

    private enum CodingKeys: String, CodingKey { case metric, value, unit, observedAt }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["metric", "value", "unit", "observedAt"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try FitnessObservationValue(
            metric: container.decode(FitnessObservationMetricID.self, forKey: .metric),
            value: container.decode(Double.self, forKey: .value),
            unit: container.decode(FitnessObservationUnit.self, forKey: .unit),
            observedAt: container.decode(Date.self, forKey: .observedAt)
        )
    }
}

public struct FitnessObservationDay: Codable, Equatable, Sendable {
    public let date: Date
    public let values: [FitnessObservationValue]

    public init(date: Date, values: [FitnessObservationValue]) {
        self.date = date
        self.values = values
    }

    private enum CodingKeys: String, CodingKey { case date, values }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: ["date", "values"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.date = try container.decode(Date.self, forKey: .date)
        self.values = try container.decode([FitnessObservationValue].self, forKey: .values)
    }
}

public struct FitnessObservationWorkout: Codable, Equatable, Sendable {
    public let activityTypeRawValue: Int
    public let startAt: Date
    public let endAt: Date
    public let durationSeconds: Double
    public let activeEnergyKilocalories: Double?

    public init(
        activityTypeRawValue: Int,
        startAt: Date,
        endAt: Date,
        durationSeconds: Double,
        activeEnergyKilocalories: Double? = nil
    ) {
        self.activityTypeRawValue = activityTypeRawValue
        self.startAt = startAt
        self.endAt = endAt
        self.durationSeconds = durationSeconds
        self.activeEnergyKilocalories = activeEnergyKilocalories
    }

    private enum CodingKeys: String, CodingKey {
        case activityTypeRawValue, startAt, endAt, durationSeconds, activeEnergyKilocalories
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "activityTypeRawValue", "startAt", "endAt", "durationSeconds", "activeEnergyKilocalories"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.activityTypeRawValue = try container.decode(Int.self, forKey: .activityTypeRawValue)
        self.startAt = try container.decode(Date.self, forKey: .startAt)
        self.endAt = try container.decode(Date.self, forKey: .endAt)
        self.durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
        self.activeEnergyKilocalories = try container.decodeIfPresent(Double.self, forKey: .activeEnergyKilocalories)
    }
}

public struct FitnessObservationEnvelope: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let maximumEncodedBytes = 128 * 1024
    public static let maximumMetrics = 32
    public static let maximumDays = 31
    public static let maximumValuesPerDay = 8
    public static let maximumWorkouts = 64
    public static let staleAfter: TimeInterval = 15 * 60
    public static let maximumHistoryAge: TimeInterval = 31 * 24 * 60 * 60
    public static let maximumCurrentMetricAge: TimeInterval = 48 * 60 * 60
    /// HealthKit's workout duration is active duration, so pauses may make it
    /// shorter than the wall-clock interval. The tolerance only covers
    /// fractional-second serialization and date rounding at the boundary.
    public static let workoutDurationRoundingTolerance: TimeInterval = 1

    public let schemaVersion: Int
    public let state: FitnessObservationState
    public let generatedAt: Date
    public let observedAt: Date
    public let source: FitnessObservationSource
    public let provenance: FitnessObservationProvenance
    public let metrics: [FitnessObservationValue]
    public let days: [FitnessObservationDay]
    public let workouts: [FitnessObservationWorkout]

    public init(
        state: FitnessObservationState,
        generatedAt: Date,
        observedAt: Date,
        source: FitnessObservationSource = .healthKit,
        provenance: FitnessObservationProvenance = .iPhoneHealthKitProjection,
        metrics: [FitnessObservationValue] = [],
        days: [FitnessObservationDay] = [],
        workouts: [FitnessObservationWorkout] = []
    ) throws {
        self.schemaVersion = Self.schemaVersion
        self.state = state
        self.generatedAt = generatedAt
        self.observedAt = observedAt
        self.source = source
        self.provenance = provenance
        self.metrics = metrics
        self.days = days
        self.workouts = workouts
        try validate(at: generatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, state, generatedAt, observedAt, source, provenance, metrics, days, workouts
    }

    public init(from decoder: Decoder) throws {
        try rejectUnknownLifeOSKeys(decoder, allowed: [
            "schemaVersion", "state", "generatedAt", "observedAt", "source", "provenance",
            "metrics", "days", "workouts"
        ])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        self.state = try container.decode(FitnessObservationState.self, forKey: .state)
        self.generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        self.observedAt = try container.decode(Date.self, forKey: .observedAt)
        self.source = try container.decode(FitnessObservationSource.self, forKey: .source)
        self.provenance = try container.decode(FitnessObservationProvenance.self, forKey: .provenance)
        self.metrics = try container.decode([FitnessObservationValue].self, forKey: .metrics)
        self.days = try container.decode([FitnessObservationDay].self, forKey: .days)
        self.workouts = try container.decode([FitnessObservationWorkout].self, forKey: .workouts)
    }

    public static func decode(_ data: Data, now: Date = .now) throws -> Self {
        guard data.count <= maximumEncodedBytes else { throw FitnessObservationContractError.oversized }
        do {
            let value = try JSONDecoder.lifeOS.decode(Self.self, from: data)
            try value.validate(at: now)
            return value
        } catch let error as FitnessObservationContractError {
            throw error
        } catch {
            throw FitnessObservationContractError.malformed
        }
    }

    public func encoded(now: Date = .now) throws -> Data {
        try validate(at: now)
        do {
            let data = try JSONEncoder.lifeOS.encode(self)
            guard data.count <= Self.maximumEncodedBytes else {
                throw FitnessObservationContractError.oversized
            }
            return data
        } catch let error as FitnessObservationContractError {
            throw error
        } catch {
            throw FitnessObservationContractError.malformed
        }
    }

    public func validate(at now: Date = .now) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              schemaVersion == Self.schemaVersion else {
            throw schemaVersion == Self.schemaVersion
                ? FitnessObservationContractError.invalidValue
                : FitnessObservationContractError.unsupportedSchema
        }
        guard source == .healthKit, provenance == .iPhoneHealthKitProjection else {
            throw FitnessObservationContractError.invalidValue
        }
        guard validDate(generatedAt), validDate(observedAt) else {
            throw FitnessObservationContractError.invalidValue
        }
        let generatedAge = now.timeIntervalSince(generatedAt)
        guard generatedAge >= -5 else { throw FitnessObservationContractError.futureTimestamp }
        guard generatedAge <= Self.maximumHistoryAge else { throw FitnessObservationContractError.stale }
        guard observedAt <= generatedAt.addingTimeInterval(5), observedAt <= now.addingTimeInterval(5) else {
            throw FitnessObservationContractError.futureTimestamp
        }
        guard metrics.count <= Self.maximumMetrics,
              days.count <= Self.maximumDays,
              workouts.count <= Self.maximumWorkouts else {
            throw FitnessObservationContractError.oversized
        }

        switch state {
        case .observed:
            guard generatedAge <= Self.staleAfter else { throw FitnessObservationContractError.stale }
            guard !metrics.isEmpty || days.contains(where: { !$0.values.isEmpty }) || !workouts.isEmpty else {
                throw FitnessObservationContractError.invalidState
            }
        case .stale, .unavailable, .permissionRequired:
            guard metrics.isEmpty, days.isEmpty, workouts.isEmpty else {
                throw FitnessObservationContractError.invalidState
            }
        }

        var seenMetrics = Set<FitnessObservationMetricID>()
        for metric in metrics {
            guard !metric.metric.isDailyMetric,
                  seenMetrics.insert(metric.metric).inserted,
                  validDate(metric.observedAt),
                  metric.observedAt >= generatedAt.addingTimeInterval(-Self.maximumCurrentMetricAge),
                  metric.observedAt <= generatedAt.addingTimeInterval(5),
                  validValue(metric) else {
                throw FitnessObservationContractError.invalidValue
            }
            try validateObservedTimestamp(metric.observedAt)
        }

        var seenDays = Set<Date>()
        for day in days {
            guard validDate(day.date),
                  seenDays.insert(day.date).inserted,
                  day.date >= generatedAt.addingTimeInterval(-Self.maximumHistoryAge),
                  day.date <= generatedAt.addingTimeInterval(5),
                  day.values.count <= Self.maximumValuesPerDay else {
                throw FitnessObservationContractError.invalidValue
            }
            var seenDayMetrics = Set<FitnessObservationMetricID>()
            for metric in day.values {
                guard metric.metric.isDailyMetric,
                      seenDayMetrics.insert(metric.metric).inserted,
                      validDate(metric.observedAt),
                      metric.observedAt >= generatedAt.addingTimeInterval(-Self.maximumHistoryAge),
                      metric.observedAt <= generatedAt.addingTimeInterval(5),
                      validValue(metric) else {
                    throw FitnessObservationContractError.invalidValue
                }
                try validateObservedTimestamp(metric.observedAt)
            }
        }

        for workout in workouts {
            guard workout.activityTypeRawValue >= 0,
                  workout.activityTypeRawValue <= 1_000_000,
                  validDate(workout.startAt),
                  validDate(workout.endAt),
                  workout.endAt > workout.startAt,
                  workout.startAt >= generatedAt.addingTimeInterval(-Self.maximumHistoryAge),
                  workout.endAt <= generatedAt.addingTimeInterval(5),
                  workout.durationSeconds.isFinite,
                  workout.durationSeconds > 0,
                  workout.durationSeconds <= Self.maximumHistoryAge,
                  workout.durationSeconds <= workout.endAt.timeIntervalSince(workout.startAt)
                    + Self.workoutDurationRoundingTolerance,
                  workout.activeEnergyKilocalories.map({ $0.isFinite && $0 >= 0 && $0 <= 1_000_000 }) ?? true else {
                throw FitnessObservationContractError.invalidValue
            }
            try validateObservedTimestamp(workout.endAt)
        }

        let itemDates = metrics.map(\.observedAt)
            + days.flatMap { $0.values.map(\.observedAt) }
            + workouts.map(\.endAt)
        guard itemDates.allSatisfy({ $0 <= observedAt.addingTimeInterval(1) }) else {
            throw FitnessObservationContractError.invalidValue
        }

        func validateObservedTimestamp(_ date: Date) throws {
            if date > now.addingTimeInterval(5) { throw FitnessObservationContractError.futureTimestamp }
        }
    }

    private func validValue(_ value: FitnessObservationValue) -> Bool {
        value.value.isFinite && value.value >= 0 && value.value <= value.metric.maximumValue
            && value.unit == value.metric.unit
    }

    private func validDate(_ date: Date) -> Bool {
        date.timeIntervalSinceReferenceDate.isFinite
    }
}

/// Keeps visual fixtures completely outside the live observation transport.
/// Both app targets use this single gate, which also makes the invariant
/// directly testable without constructing a network session.
public enum FitnessObservationSyncPolicy {
    public static func allowsNetwork(usesVisualFixtures: Bool) -> Bool {
        !usesVisualFixtures
    }
}
