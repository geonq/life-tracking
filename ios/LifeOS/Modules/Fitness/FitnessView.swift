import SwiftUI

#if os(iOS)
import UIKit
#endif

// MARK: - Fitness data contracts

/// The Fitness surface deliberately accepts a snapshot instead of reaching into
/// HealthKit from a view. Production callers pass `.unavailable` until the
/// reviewed Helio Strap → Zepp → Apple Health → HealthKit importer is connected.
/// `.demo` is an explicit visual fixture and is never selected implicitly.
public struct FitnessSnapshot {
    public let source: FitnessSourceState
    public let readiness: FitnessMetric
    public let strain: FitnessMetric
    public let sleep: FitnessMetric
    public let stress: FitnessMetric
    public let energyReserve: FitnessMetric
    public let healthMonitor: [FitnessMetric]
    public let bodyMetrics: [FitnessMetric]
    public let workouts: [FitnessWorkout]
    public let journalEntries: [FitnessJournalEntry]
    /// Explicit local journal records used by the functional Journal surface.
    /// Production snapshots leave this empty until a reviewed source supplies
    /// observations; visual fixtures opt in with clearly labelled values.
    public let journalRecords: [FitnessJournalRecord]
    public let nutrition: FitnessNutritionSnapshot
    public let supplements: [FitnessSupplement]
    /// Exact activity/performance boundary for the last-30-days surface.
    /// Production snapshots leave it unavailable until an approved importer
    /// supplies the named window and provenance for each value.
    public let activity: FitnessActivitySnapshot
    /// Source-aware IMG_0393 Strength detail. Production callers leave this
    /// unavailable until a reviewed workout importer supplies its provenance.
    public let strength: FitnessStrengthSnapshot
    /// Source-aware IMG_0394–0395 Biology detail. Production callers leave
    /// this unavailable until HealthKit/Helio samples pass the importer gate;
    /// the visual fixture is opt-in through `FitnessSnapshot.demo` only.
    public let biology: FitnessBiologySnapshot
    /// Source-aware detail contracts for the IMG_0396–0404 drill-downs. They
    /// are independent from the generic Today cards so absent fields cannot be
    /// inferred from a similarly named value.
    public let loadDetail: FitnessLoadDetail
    public let recoveryDetail: FitnessRecoveryDetail
    public let sleepDetail: FitnessSleepDetail
    /// Source-aware Stress detail for Bevel IMG_0405–IMG_0412. It remains
    /// independent from the generic Today stress card so missing subtype,
    /// range, and distribution data cannot be inferred from that card.
    public let stressDetail: FitnessStressSnapshot

    public init(
        source: FitnessSourceState = .unavailable,
        readiness: FitnessMetric = .unavailable("Readiness"),
        strain: FitnessMetric = .unavailable("Strain"),
        sleep: FitnessMetric = .unavailable("Sleep"),
        stress: FitnessMetric = .unavailable("Stress"),
        energyReserve: FitnessMetric = .unavailable("Energy reserve"),
        healthMonitor: [FitnessMetric] = FitnessMetric.defaultHealthMonitor,
        bodyMetrics: [FitnessMetric] = FitnessMetric.defaultBodyMetrics,
        workouts: [FitnessWorkout] = [],
        journalEntries: [FitnessJournalEntry] = [],
        journalRecords: [FitnessJournalRecord] = [],
        nutrition: FitnessNutritionSnapshot = .unavailable,
        supplements: [FitnessSupplement] = [],
        activity: FitnessActivitySnapshot = .unavailable,
        strength: FitnessStrengthSnapshot = .init(),
        biology: FitnessBiologySnapshot = .unavailable,
        loadDetail: FitnessLoadDetail? = nil,
        recoveryDetail: FitnessRecoveryDetail? = nil,
        sleepDetail: FitnessSleepDetail? = nil,
        stressDetail: FitnessStressSnapshot? = nil
    ) {
        self.source = source
        self.readiness = readiness
        self.strain = strain
        self.sleep = sleep
        self.stress = stress
        self.energyReserve = energyReserve
        self.healthMonitor = healthMonitor
        self.bodyMetrics = bodyMetrics
        self.workouts = workouts
        self.journalEntries = journalEntries
        self.journalRecords = journalRecords
        self.nutrition = nutrition
        self.supplements = supplements
        self.activity = activity
        self.strength = strength
        self.biology = biology
        self.loadDetail = loadDetail ?? FitnessLoadDetail()
        self.recoveryDetail = recoveryDetail ?? FitnessRecoveryDetail.from(readiness: readiness, healthMonitor: healthMonitor)
        self.sleepDetail = sleepDetail ?? FitnessSleepDetail.from(sleep: sleep)
        self.stressDetail = stressDetail ?? .unavailable
    }

    public static let unavailable = FitnessSnapshot()

    /// Deterministic, clearly-labelled visual fixtures. This is intentionally
    /// opt-in and is useful for screenshot review before real HealthKit samples
    /// pass the Fitness release gates.
    public static let demo: FitnessSnapshot = {
        let now = Date.now
        let demoEvidence = FitnessSourceEvidence(state: .demo(
            source: "DEMO · NOT LIVE",
            device: "Visual fixture",
            window: "Selected day · explicit 30-day fixture window",
            freshness: "Fixture timestamp"
        ))
        let demoRanges: Set<FitnessTrendRange> = [.seven, .fourteen, .thirty]
        func demoSeries(_ values: [Double]) -> [FitnessTrendRange: [Double]] {
            // Keep fixture history in the metric's actual source unit. The
            // chart normalizes only its drawing geometry; values shown to the
            // user must never leak that internal 0...1 representation.
            let finite = values.filter(\.isFinite)
            guard !finite.isEmpty else { return [:] }
            let span = max((finite.max() ?? 0) - (finite.min() ?? 0), 1)
            let fourteen = finite.enumerated().map { index, value in
                value + Double((index % 3) - 1) * span * 0.08
            }
            let thirty = finite.enumerated().map { index, value in
                value + Double((index % 4) - 2) * span * 0.11
            }
            return [.seven: finite, .fourteen: fourteen, .thirty: thirty]
        }
        let demoDuration = FitnessMetric(
            title: "Training duration",
            value: "57",
            unit: "min",
            detail: "Explicit fixture workout total",
            quality: .demo,
            hue: .orange,
            trend: [0.32, 0.38, 0.34, 0.46, 0.41, 0.55]
        )
        let demoEnergy = FitnessMetric(
            title: "Total energy",
            value: "1,935",
            unit: "kcal",
            detail: "Explicit fixture workout total",
            quality: .demo,
            hue: .orange,
            trend: [0.46, 0.51, 0.43, 0.58, 0.52, 0.67]
        )
        let demoLoadTrendCards = [
            FitnessLoadTrendCard(
                id: .load,
                metric: FitnessMetric(
                    title: "Load",
                    value: "55",
                    unit: "%",
                    detail: "Explicit fixture trend",
                    quality: .demo,
                    hue: .orange,
                    trend: [0.41, 0.44, 0.38, 0.47, 0.43, 0.55]
                ),
                evidence: demoEvidence,
                target: FitnessLoadTargetBand(lower: 20, upper: 40, unit: "%"),
                availableRanges: demoRanges
            ),
            FitnessLoadTrendCard(
                id: .duration,
                metric: demoDuration,
                evidence: demoEvidence,
                availableRanges: demoRanges
            ),
            FitnessLoadTrendCard(
                id: .daytimeHeartRate,
                metric: FitnessMetric(
                    title: "Daytime heart rate",
                    value: "101",
                    unit: "bpm",
                    detail: "Explicit fixture daytime sample",
                    quality: .demo,
                    hue: .pink,
                    trend: [0.47, 0.50, 0.44, 0.53, 0.49, 0.56]
                ),
                evidence: demoEvidence,
                availableRanges: demoRanges
            ),
            FitnessLoadTrendCard(
                id: .totalEnergy,
                metric: demoEnergy,
                evidence: demoEvidence,
                availableRanges: demoRanges
            ),
            FitnessLoadTrendCard(
                id: .steps,
                metric: FitnessMetric(
                    title: "Steps",
                    value: "7,472",
                    unit: "",
                    detail: "Explicit fixture step count",
                    quality: .demo,
                    hue: .teal,
                    trend: [0.48, 0.57, 0.52, 0.64, 0.59, 0.72]
                ),
                evidence: demoEvidence,
                availableRanges: demoRanges
            )
        ]
        // Keep the visual fixture anchored to the selected review night. A
        // wall-clock-relative `Date.now` interval turns into a daytime bar in
        // afternoon snapshots, which is not an honest representation of an
        // overnight sleep observation.
        var sleepCalendar = Calendar(identifier: .gregorian)
        sleepCalendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let sleepEnd = sleepCalendar.date(from: DateComponents(year: 2026, month: 7, day: 27, hour: 6, minute: 46))!
        let previousDayMorning = sleepCalendar.date(byAdding: .day, value: -1, to: sleepEnd)!
        let sleepStart = sleepCalendar.date(bySettingHour: 22, minute: 46, second: 0, of: previousDayMorning)!
        let sleepEvidence = FitnessSleepObservationEvidence(state: .demo(
            source: "DEMO · NOT LIVE",
            device: "Visual fixture",
            provenance: "Explicit sleep timeline fixture",
            freshness: "Fixture timestamp"
        ))
        let sleepBoundary = FitnessSleepDayBoundary(name: "Local sleep day · 18:00 cutoff", timeZone: "Europe/Berlin")
        let sleepStages = [
            FitnessSleepStageSample(stage: .deep, start: sleepStart, end: sleepStart.addingTimeInterval(80 * 60)),
            FitnessSleepStageSample(stage: .core, start: sleepStart.addingTimeInterval(80 * 60), end: sleepStart.addingTimeInterval(200 * 60)),
            FitnessSleepStageSample(stage: .rem, start: sleepStart.addingTimeInterval(200 * 60), end: sleepStart.addingTimeInterval(270 * 60)),
            FitnessSleepStageSample(stage: .awake, start: sleepStart.addingTimeInterval(270 * 60), end: sleepStart.addingTimeInterval(288 * 60)),
            FitnessSleepStageSample(stage: .core, start: sleepStart.addingTimeInterval(288 * 60), end: sleepStart.addingTimeInterval(398 * 60)),
            FitnessSleepStageSample(stage: .rem, start: sleepStart.addingTimeInterval(398 * 60), end: sleepEnd)
        ].compactMap { $0 }
        let sleepNight = FitnessSleepNight(
            id: "demo-sleep-night",
            start: sleepStart,
            end: sleepEnd,
            stageSamples: sleepStages,
            boundary: sleepBoundary,
            evidence: sleepEvidence,
            state: .observed
        )
        func sleepMetric(_ id: FitnessSleepTrendID, _ title: String, _ value: String, _ unit: String, _ hue: LifeOSTokens.Hue, _ trend: [Double]) -> FitnessSleepTrendCard {
            let metric = FitnessMetric(
                id: "demo-sleep-\(id.rawValue)",
                title: title,
                value: value,
                unit: unit,
                detail: "Explicit source fixture value; LifeOS does not reproduce a proprietary score formula.",
                quality: .demo,
                hue: hue,
                trend: trend
            )
            return FitnessSleepTrendCard(
                id: id,
                metric: metric,
                evidence: demoEvidence,
                availableRanges: demoRanges,
                seriesByRange: demoSeries(trend)
            )
        }
        let sleepTrends = [
            sleepMetric(.quality, "Sleep quality", "86", "/100", .violet, [78, 81, 79, 84, 82, 85, 86]),
            sleepMetric(.timeInBed, "Time in bed", "8h 0m", "", .blue, [468, 476, 471, 487, 480, 492, 480]),
            sleepMetric(.duration, "Sleep duration", "7h 42m", "", .violet, [438, 451, 446, 469, 455, 474, 462]),
            sleepMetric(.rem, "REM sleep", "2h 32m", "", .teal, [126, 139, 134, 148, 141, 156, 152]),
            sleepMetric(.deep, "Deep sleep", "1h 20m", "", .blue, [68, 76, 72, 83, 78, 86, 80]),
            sleepMetric(.core, "Core sleep", "3h 50m", "", .green, [218, 224, 226, 235, 229, 238, 230]),
            sleepMetric(.awake, "Awake time", "18", "min", .orange, [28, 24, 29, 21, 25, 20, 18]),
            sleepMetric(.heartRateDrop, "Heart-rate drop", "12", "bpm", .pink, [8, 10, 9, 11, 10, 13, 12]),
            sleepMetric(.sleepBalance, "Sleep balance", "+18", "min", .teal, [-12, -4, 2, 9, 6, 14, 18]),
            sleepMetric(.wakeTime, "Wake time", "07:00", "", .blue, [405, 414, 408, 421, 416, 425, 420]),
            sleepMetric(.sleepOnset, "Sleep onset", "22:46", "", .violet, [1_385, 1_376, 1_381, 1_368, 1_374, 1_362, 1_366])
        ]
        let sleepDetail = FitnessSleepDetail(
            night: sleepNight,
            quality: sleepTrends.first(where: { $0.id == .quality })?.metric ?? .unavailable("Sleep quality"),
            timeInBed: sleepTrends.first(where: { $0.id == .timeInBed })?.metric ?? .unavailable("Time in bed"),
            duration: sleepTrends.first(where: { $0.id == .duration })?.metric ?? .unavailable("Sleep duration"),
            schedule: FitnessSleepSchedule(state: .configured(
                windDownMinutes: 1_336,
                targetBedtimeMinutes: 1_366,
                wakeTargetMinutes: 420,
                sleepNeedMinutes: 493,
                timeZone: "Europe/Berlin",
                window: "Explicit fixture schedule",
                provenance: "DEMO · NOT LIVE",
                freshness: "Fixture timestamp"
            )),
            sleepNeed: FitnessSourceCopy(state: .demo(
                text: "Fixture schedule value only; no sleep-need formula is reproduced.",
                window: "Explicit fixture schedule",
                provenance: "DEMO · NOT LIVE"
            )),
            windDown: FitnessSourceCopy(state: .demo(
                text: "Fixture wind-down target only; no recommendation is inferred.",
                window: "Explicit fixture schedule",
                provenance: "DEMO · NOT LIVE"
            )),
            insights: [FitnessSourceCopy(state: .demo(
                text: "Fixture timeline context only. LifeOS does not turn stages into a proprietary score or coaching conclusion.",
                window: "Selected night · explicit fixture",
                provenance: "DEMO · NOT LIVE"
            ))],
            trends: sleepTrends
        )
        return FitnessSnapshot(
            source: FitnessSourceState(
                status: .demo,
                title: "Demo fixture",
                detail: "DEMO · NOT LIVE HEALTH DATA",
                freshness: "Injected for visual review"
            ),
            readiness: FitnessMetric(
                title: "Readiness",
                value: "78",
                unit: "/100",
                detail: "Observed inputs · demo fixture",
                quality: .demo,
                progress: 0.78,
                hue: .green
            ),
            strain: FitnessMetric(
                title: "Strain / load",
                value: "42",
                unit: "/100",
                detail: "Source coverage is simulated",
                quality: .demo,
                progress: 0.42,
                hue: .blue
            ),
            sleep: FitnessMetric(
                title: "Sleep",
                value: "7h 42m",
                unit: "",
                detail: "Source stages are simulated",
                quality: .demo,
                progress: 0.86,
                hue: .violet
            ),
            stress: FitnessMetric(
                title: "Stress",
                value: "32",
                unit: "/100",
                detail: "Observed trend · demo fixture",
                quality: .demo,
                progress: 0.32,
                hue: .orange,
                trend: [0.32, 0.39, 0.34, 0.50, 0.42, 0.38, 0.32]
            ),
            energyReserve: FitnessMetric(
                title: "Energy reserve",
                value: "70%",
                unit: "",
                detail: "Derived estimate · demo fixture",
                quality: .demo,
                progress: 0.70,
                hue: .teal,
                trend: [0.38, 0.46, 0.42, 0.58, 0.64, 0.68, 0.70]
            ),
            healthMonitor: [
                FitnessMetric(title: "HRV", value: "52", unit: "ms", detail: "Helio → Zepp → HealthKit · demo", quality: .demo, hue: .teal),
                FitnessMetric(title: "Resting heart rate", value: "54", unit: "bpm", detail: "Helio → Zepp → HealthKit · demo", quality: .demo, hue: .pink),
                FitnessMetric(title: "Respiration", value: "14.8", unit: "/min", detail: "HealthKit transport · demo", quality: .demo, hue: .blue),
                FitnessMetric(title: "Blood oxygen", value: "98", unit: "%", detail: "HealthKit transport · demo", quality: .demo, hue: .lime),
                FitnessMetric(title: "Skin temperature", value: "+0.1", unit: "°C", detail: "HealthKit transport · demo", quality: .demo, hue: .orange),
                FitnessMetric(title: "Sleep", value: "7h 42m", unit: "", detail: "HealthKit transport · demo", quality: .demo, hue: .violet)
            ],
            bodyMetrics: [
                FitnessMetric(title: "Weight", value: "—", unit: "kg", detail: "No source observation", quality: .unavailable, hue: .blue),
                FitnessMetric(title: "Body fat", value: "—", unit: "%", detail: "No source observation", quality: .unavailable, hue: .pink),
                FitnessMetric(title: "VO₂ max", value: "—", unit: "ml/kg/min", detail: "No source observation", quality: .unavailable, hue: .green),
                FitnessMetric(title: "HRV baseline", value: "52", unit: "ms", detail: "30-day demo fixture", quality: .demo, hue: .teal)
            ],
            workouts: [
                FitnessWorkout(id: "demo-workout-1", name: "Morning run", kind: "Cardio", time: now.addingTimeInterval(-5_400), duration: "42 min", detail: "6.2 km · source coverage simulated", hue: .blue),
                FitnessWorkout(id: "demo-workout-2", name: "Strength session", kind: "Strength", time: now.addingTimeInterval(-28_800), duration: "38 min", detail: "Manual exercise log · demo fixture", hue: .violet)
            ],
            journalEntries: [
                FitnessJournalEntry(id: "demo-journal-1", title: "Morning sunlight", time: now.addingTimeInterval(-25_200), source: .manual, icon: .sun),
                FitnessJournalEntry(id: "demo-journal-2", title: "Hydration", time: now.addingTimeInterval(-18_000), source: .manual, icon: .water),
                FitnessJournalEntry(id: "demo-journal-3", title: "Magnesium planned", time: now.addingTimeInterval(-3_600), source: .manual, icon: .supplement)
            ],
            journalRecords: FitnessJournalVisualFixtures.records(at: now),
            nutrition: .demo,
            supplements: FitnessSupplement.demo,
            activity: FitnessActivitySnapshot.demo(anchor: now),
            strength: FitnessStrengthSnapshot.demo(anchor: now),
            biology: FitnessBiologySnapshot.demo(anchor: now),
            loadDetail: FitnessLoadDetail(
                gauge: FitnessLoadGauge(state: .demo(
                    current: 55,
                    lowerBound: 20,
                    upperBound: 40,
                    unit: "%",
                    window: "Today · demo fixture",
                    provenance: "DEMO · NOT LIVE"
                )),
                duration: demoDuration,
                energy: demoEnergy,
                coaching: FitnessSourceCopy(state: .demo(
                    text: "Fixture coaching only: the target band is shown for visual review; no live recommendation is made.",
                    window: "Today · demo fixture",
                    provenance: "DEMO · NOT LIVE"
                )),
                heartRateZones: [
                    FitnessHeartRateZone(zone: 0, duration: "00:05:23", range: "0–99 bpm", provenance: "DEMO · NOT LIVE"),
                    FitnessHeartRateZone(zone: 1, duration: "00:36:23", range: "100–119 bpm", provenance: "DEMO · NOT LIVE"),
                    FitnessHeartRateZone(zone: 2, duration: "00:15:46", range: "120–139 bpm", provenance: "DEMO · NOT LIVE"),
                    FitnessHeartRateZone(zone: 3, duration: "00:00:12", range: "140–159 bpm", provenance: "DEMO · NOT LIVE"),
                    FitnessHeartRateZone(zone: 4, duration: "00:00:00", range: "160–179 bpm", provenance: "DEMO · NOT LIVE"),
                    FitnessHeartRateZone(zone: 5, duration: "00:00:00", range: "180–198 bpm", provenance: "DEMO · NOT LIVE")
                ].compactMap { $0 },
                trend: FitnessMetric(title: "Load trend", value: "55", unit: "%", detail: "Explicit fixture trend", quality: .demo, hue: .orange, trend: [0.41, 0.44, 0.38, 0.47, 0.43, 0.55]),
                trendCards: demoLoadTrendCards
            ),
            sleepDetail: sleepDetail,
            stressDetail: .demo
        )
    }()
}

public struct FitnessSourceState {
    public enum Status: Equatable {
        case unavailable, stale, permissionRequired, connected, demo

        var label: String {
            switch self {
            case .unavailable: "Not connected"
            case .stale: "Source stale"
            case .permissionRequired: "Permission needed"
            case .connected: "Connected"
            case .demo: "Demo fixture"
            }
        }

        var color: Color {
            switch self {
            case .connected: LifeOSTokens.success
            case .demo: LifeOSTokens.warning
            case .stale, .permissionRequired: LifeOSTokens.warning
            case .unavailable: LifeOSTokens.tertiaryText
            }
        }

        var needsReview: Bool {
            switch self {
            case .unavailable, .stale, .permissionRequired: true
            case .connected, .demo: false
            }
        }
    }

    public let status: Status
    public let title: String
    public let detail: String
    public let freshness: String

    public init(status: Status, title: String, detail: String, freshness: String) {
        self.status = status
        self.title = title
        self.detail = detail
        self.freshness = freshness
    }

    public static let unavailable = FitnessSourceState(
        status: .unavailable,
        title: "Health data is not connected",
        detail: "Helio Strap → Zepp → Apple Health → HealthKit",
        freshness: "No source observation available"
    )
}

public struct FitnessWorkout: Identifiable {
    public let id: String
    public let name: String
    public let kind: String
    public let time: Date
    public let duration: String
    public let detail: String
    public let hue: LifeOSTokens.Hue

    public init(id: String, name: String, kind: String, time: Date, duration: String, detail: String, hue: LifeOSTokens.Hue = .blue) {
        self.id = id
        self.name = name
        self.kind = kind
        self.time = time
        self.duration = duration
        self.detail = detail
        self.hue = hue
    }
}

public struct FitnessJournalEntry: Identifiable {
    public enum Source: String { case manual = "Manual", healthKit = "HealthKit", derived = "Derived", inferred = "Inferred" }
    public enum Icon { case sun, water, supplement, mood, tag }

    public let id: String
    public let title: String
    public let time: Date
    public let source: Source
    public let icon: Icon

    public init(id: String, title: String, time: Date, source: Source, icon: Icon = .tag) {
        self.id = id
        self.title = title
        self.time = time
        self.source = source
        self.icon = icon
    }
}

public enum FitnessSection: String, CaseIterable, Identifiable, Sendable {
    case today = "Today"
    case journal = "Journal"
    case fitness = "Fitness"
    case biology = "Biology"
    case nutrition = "Nutrition"
    case supplements = "Supplements"
    case settings = "Settings"

    public var id: String { rawValue }

    var icon: LifeOSIconName {
        switch self {
        case .today: .overview
        case .journal: .more
        case .fitness: .fitness
        case .biology: .health
        case .nutrition: .grocery
        case .supplements: .verified
        case .settings: .settings
        }
    }

    var subtitle: String {
        switch self {
        case .today: "Your day, with evidence"
        case .journal: "Small facts, kept useful"
        case .fitness: "Activity and training detail"
        case .biology: "Source-backed body signals"
        case .nutrition: "Meals, macros, and energy"
        case .supplements: "Your plan, reminders, and stock"
        case .settings: "Permissions, privacy, and units"
        }
    }
}

/// Calendar-day stepping for the Fitness date header. Calendar arithmetic is
/// intentionally used instead of adding 24 hours so a day remains a local
/// calendar day when the selected timezone crosses a DST transition.
enum FitnessDateNavigation {
    static func addingDays(_ days: Int, to date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: days, to: date) ?? date
    }
}

/// The section strip should only move when a route change would otherwise hide
/// the selected section. A normal tap is already visible and must preserve the
/// user's horizontal offset; initial and deep-linked routes may request reveal.
enum FitnessSectionRevealPolicy {
    static func shouldReveal(
        selection: FitnessSection,
        visibleSectionIDs: Set<String>,
        userInitiated: Bool
    ) -> Bool {
        guard !userInitiated else { return false }
        // Initial and deep-linked routes use the same post-layout rule: an
        // already visible section needs no scroll, avoiding a first-layout
        // nudge when the selected tab is already on screen.
        return !visibleSectionIDs.contains(selection.id)
    }
}

struct FitnessSectionRevealRequest: Equatable {
    let section: FitnessSection
    let generation: Int
    let isInitialAppearance: Bool
}

enum FitnessSectionRevealAction: Equatable {
    case waitForLayout
    case clear
    case reveal
}

enum FitnessSectionRevealState {
    static func action(
        for request: FitnessSectionRevealRequest,
        currentSelection: FitnessSection,
        currentGeneration: Int,
        visibleSectionIDs: Set<String>,
        layoutReady: Bool
    ) -> FitnessSectionRevealAction {
        guard request.generation == currentGeneration,
              request.section == currentSelection else {
            return .clear
        }
        guard layoutReady else { return .waitForLayout }
        return FitnessSectionRevealPolicy.shouldReveal(
            selection: request.section,
            visibleSectionIDs: visibleSectionIDs,
            userInitiated: false
        ) ? .reveal : .clear
    }
}

public enum FitnessHealthMetric: String, Hashable, Sendable {
    case respiration
    case heartRate
    case hrv
    case spo2
    case temperature
    case sleepDuration

    public var title: String {
        switch self {
        case .respiration: "Respiration"
        case .heartRate: "Heart rate"
        case .hrv: "HRV"
        case .spo2: "SpO₂"
        case .temperature: "Temperature"
        case .sleepDuration: "Sleep duration"
        }
    }

    /// Source adapters use descriptive names (for example, “Resting heart
    /// rate” and “Blood oxygen”), while widget routes use compact labels. Keep
    /// this mapping explicit so a deep link never lands on a different metric
    /// or invents an unavailable value because display strings differ.
    func matches(metricTitle: String) -> Bool {
        let normalized = metricTitle.lowercased().replacingOccurrences(of: "₂", with: "2")
        switch self {
        case .respiration:
            return normalized.contains("respiration")
        case .heartRate:
            return normalized.contains("heart") && normalized.contains("rate")
        case .hrv:
            return normalized == "hrv" || normalized.contains("heart rate variability")
        case .spo2:
            return normalized.contains("spo2") || normalized.contains("sp02") || normalized.contains("oxygen")
        case .temperature:
            return normalized.contains("temperature")
        case .sleepDuration:
            return normalized == "sleep" || normalized.contains("sleep duration")
        }
    }
}

public enum FitnessWidgetEntryPoint: Hashable, Sendable {
    case dailyOverview
    case strain
    case recovery
    case sleep
    case healthMonitor
    case stress
    case energyReserve
    case healthMetric(FitnessHealthMetric)
}

// MARK: - Fitness root

public struct FitnessView: View {
    private static let contentTopID = "fitness-content-top"
    public let snapshot: FitnessSnapshot
    /// Optional date-aware provider used by production HealthKit wiring. The
    /// static snapshot remains the source-compatible default for fixtures and
    /// macOS callers.
    public let snapshotProvider: ((Date) -> FitnessSnapshot)?
    public let usesVisualFixtures: Bool
    /// The app shell owns the substantive Health permission/settings route.
    /// Fitness only dismisses its source explainer and asks the shell to take
    /// that action; it never constructs another HealthKit client or store.
    private let onSourceReview: (() -> Void)?
    private let initialSection: FitnessSection
    private let initialNutritionEntryPoint: FitnessNutritionEntryPoint?
    private let initialFitnessEntryPoint: FitnessWidgetEntryPoint?
    @State private var selectedSection: FitnessSection
    @State private var selectedDate: Date
    @State private var showingSourceGate = false
    @State private var reviewSourceAfterDismiss = false
    @StateObject private var journalStore: FitnessJournalStore

    @Environment(\.openURL) private var openURL
#if os(macOS)
    @Environment(\.openSettings) private var openSettings
#endif

    private var detailEntryPointUsesParentScroll: Bool {
        initialFitnessEntryPoint?.coreRoute != nil
    }

    private var fitnessContentTopPadding: CGFloat {
        detailEntryPointUsesParentScroll ? 6 : 14
    }

    private var resolvedSnapshot: FitnessSnapshot {
        snapshotProvider?(selectedDate) ?? snapshot
    }

    public init(
        snapshot: FitnessSnapshot = .unavailable,
        snapshotProvider: ((Date) -> FitnessSnapshot)? = nil,
        initialSection: FitnessSection = .today,
        initialNutritionEntryPoint: FitnessNutritionEntryPoint? = nil,
        initialFitnessEntryPoint: FitnessWidgetEntryPoint? = nil,
        selectedDate: Date = .now,
        usesVisualFixtures: Bool = false,
        onSourceReview: (() -> Void)? = nil,
        journalStore: FitnessJournalStore? = nil
    ) {
        let fixtureMode = FitnessJournalFixturePolicy.isFixtureMode(
            usesVisualFixtures: usesVisualFixtures,
            sourceIsDemo: snapshot.source.status == .demo
        )
        self.snapshot = snapshot
        self.snapshotProvider = snapshotProvider
        self.usesVisualFixtures = usesVisualFixtures
        self.onSourceReview = onSourceReview
        self.initialSection = initialSection
        self.initialNutritionEntryPoint = initialNutritionEntryPoint
        self.initialFitnessEntryPoint = initialFitnessEntryPoint
        _selectedSection = State(initialValue: initialSection)
        _selectedDate = State(initialValue: selectedDate)
        let seededRecords = snapshot.journalRecords.map { record in
            var copy = record
            // Visual fixtures are date-scoped to the review date so the same
            // deterministic snapshot remains useful when the date picker is
            // exercised. This path is never used for production observations.
            if fixtureMode { copy.date = selectedDate }
            return copy
        }
        _journalStore = StateObject(wrappedValue: journalStore ?? FitnessJournalStore(
            initialRecords: seededRecords,
            persistenceURL: fixtureMode ? nil : FitnessJournalStore.defaultPersistenceURL,
            fixtureOnly: fixtureMode
        ))
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                FitnessHeader(selectedDate: $selectedDate, source: resolvedSnapshot.source, onSourceTap: { showingSourceGate = true })
                FitnessSectionPicker(selection: $selectedSection)
                if usesVisualFixtures || resolvedSnapshot.source.status == .demo {
                    FitnessFixtureBanner()
                }

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        Color.clear
                            .frame(height: 1)
                            .id(Self.contentTopID)
                        LifeOSResponsiveContentContainer(
                            horizontalPadding: 16,
                            topPadding: fitnessContentTopPadding,
                            bottomPadding: 28
                        ) {
                            FitnessSectionContent(
                                section: selectedSection,
                                snapshot: resolvedSnapshot,
                                selectedDate: $selectedDate,
                                nutritionEntryPoint: initialNutritionEntryPoint,
                                fitnessEntryPoint: initialFitnessEntryPoint,
                                journalStore: journalStore,
                                usesVisualFixtures: usesVisualFixtures,
                                onSourceTap: { showingSourceGate = true }
                            )
                        }
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: selectedSection) { oldSection, newSection in
                        guard oldSection != newSection else { return }
                        if LifeOSMotion.reduceMotion {
                            scrollProxy.scrollTo(Self.contentTopID, anchor: .top)
                        } else {
                            withAnimation(LifeOSMotion.snappy) {
                                scrollProxy.scrollTo(Self.contentTopID, anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
        .tint(LifeOSTokens.accent)
        .onChange(of: initialSection) { _, newSection in
            guard selectedSection != newSection else { return }
            if LifeOSMotion.reduceMotion {
                selectedSection = newSection
            } else {
                withAnimation(LifeOSMotion.snappy) {
                    selectedSection = newSection
                }
            }
        }
        .sheet(isPresented: $showingSourceGate, onDismiss: {
            guard reviewSourceAfterDismiss else { return }
            reviewSourceAfterDismiss = false
            performSourceReview()
        }) {
            FitnessSourceGateSheet(source: resolvedSnapshot.source, onSourceTap: {
                reviewSourceAfterDismiss = true
                showingSourceGate = false
            })
                .presentationDetents([.medium])
        }
        .accessibilityIdentifier("fitness-view")
    }

    /// Keep all Health setup decisions in the app shell. When a standalone
    /// Fitness preview has no shell callback, the source explainer still
    /// dismisses; a production iPhone fallback opens only Apple's public app
    /// settings URL (never a private Health URL scheme).
    private func performSourceReview() {
        if let onSourceReview {
            onSourceReview()
            return
        }
#if os(iOS)
        guard !usesVisualFixtures,
              let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
#elseif os(macOS)
        guard !usesVisualFixtures else { return }
        openSettings()
#endif
    }
}

private struct FitnessHeader: View {
    @Binding var selectedDate: Date
    let source: FitnessSourceState
    let onSourceTap: () -> Void
    @State private var showingDatePicker = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Fitness")
                        .font(LifeOSFont.display(30))
                        .tracking(-0.5)
                    Text(source.status == .demo ? "Visual review" : "Local-first health journal")
                        .font(LifeOSFont.bodyText(14))
                        .foregroundStyle(LifeOSTokens.secondaryText)
                }

                Spacer(minLength: 8)

                Button(action: onSourceTap) {
                    // §4.2: dot + overline, no tinted chip background.
                    HStack(spacing: 6) {
                        Circle().fill(source.status.color).frame(width: 6, height: 6)
                        Text(source.status.label)
                            .font(LifeOSFont.overline())
                            .tracking(0.8)
                            .textCase(.uppercase)
                            .foregroundStyle(source.status.color)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Health source status")
                .accessibilityValue(source.status.label)
            }

            HStack(spacing: 8) {
                LifeOSIcon(.calendar)
                    .foregroundStyle(LifeOSTokens.Module.fitness)
                    .frame(width: 15, height: 15)

                Button {
                    shiftDate(by: -1)
                } label: {
                    LifeOSIcon(.chevronLeft)
                        .frame(width: 16, height: 16)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LifeOSTokens.Module.fitness)
                .accessibilityLabel("Previous day")
                .accessibilityHint("Show the previous calendar day")
                .accessibilityIdentifier("fitness-date-previous-day")

                Button {
                    showingDatePicker = true
                } label: {
                    Text(selectedDate.fitnessHeaderDateLabel)
                        .font(LifeOSFont.control())
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .frame(minHeight: 44, alignment: .leading)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Selected date")
                .accessibilityValue(selectedDate.fitnessHeaderDateLabel)
                .accessibilityIdentifier("fitness-date-picker")

                Button {
                    shiftDate(by: 1)
                } label: {
                    LifeOSIcon(.chevronRight)
                        .frame(width: 16, height: 16)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(LifeOSTokens.accent)
                .accessibilityLabel("Next day")
                .accessibilityHint("Show the next calendar day")
                .accessibilityIdentifier("fitness-date-next-day")

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LifeOSTokens.surface.opacity(0.68), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .sheet(isPresented: $showingDatePicker) {
            NavigationStack {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Choose the day to review")
                        .font(LifeOSFont.header(18))
                    DatePicker("Selected date", selection: $selectedDate, displayedComponents: .date)
                        .labelsHidden()
#if os(iOS)
                        .datePickerStyle(.graphical)
#endif
                        .accessibilityIdentifier("fitness-date-picker-control")
                    Spacer(minLength: 0)
                }
                .padding(20)
                .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showingDatePicker = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func shiftDate(by days: Int) {
        selectedDate = FitnessDateNavigation.addingDays(days, to: selectedDate)
    }
}

private struct FitnessSectionPicker: View {
    @Binding var selection: FitnessSection
    @State private var visibleSectionIDs = Set<String>()
    @State private var pendingUserSelection: FitnessSection?
    @State private var hasRequestedInitialReveal = false
    @State private var revealGeneration = 0
    @State private var pendingReveal: FitnessSectionRevealRequest?
    @State private var scheduledRevealGeneration: Int?
    @State private var sectionLayoutReady = false

    var body: some View {
        GeometryReader { proxy in
#if os(macOS)
            if proxy.size.width >= 900 {
                HStack(spacing: 7) {
                    sectionButtons()
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                compactMenu()
            }
#else
            ScrollViewReader { scrollProxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        sectionButtons()
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 2)
                }
                .coordinateSpace(name: "fitness-section-picker")
                .onPreferenceChange(FitnessSectionFramePreferenceKey.self) { frames in
                    let viewport = CGRect(x: 0, y: 0, width: proxy.size.width, height: 46)
                    let currentVisibleSectionIDs = Set(frames.compactMap { id, frame in
                        frame.intersects(viewport) ? id : nil
                    })
                    visibleSectionIDs = currentVisibleSectionIDs
                    sectionLayoutReady = !frames.isEmpty
                    reconcilePendingReveal(
                        using: scrollProxy,
                        visibleSectionIDs: currentVisibleSectionIDs,
                        layoutReady: !frames.isEmpty
                    )
                }
                .onAppear {
                    guard !hasRequestedInitialReveal else { return }
                    hasRequestedInitialReveal = true
                    queueReveal(for: selection, isInitialAppearance: true)
                    schedulePendingReveal(using: scrollProxy)
                }
                .onChange(of: selection) { oldSection, newSection in
                    guard oldSection != newSection else { return }
                    if pendingUserSelection == newSection {
                        pendingUserSelection = nil
                        invalidatePendingReveal()
                        return
                    }
                    queueReveal(for: newSection, isInitialAppearance: false)
                    schedulePendingReveal(using: scrollProxy)
                }
            }
#endif
        }
        .frame(height: 46)
        .accessibilityElement(children: .contain)
#if os(macOS)
        .accessibilityHint("Choose a Fitness section")
#else
        .accessibilityHint("Swipe left or right to browse Fitness sections")
#endif
    }

#if os(macOS)
    private func compactMenu() -> some View {
        Menu {
            ForEach(FitnessSection.allCases) { section in
                Button {
                    withAnimation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy) {
                        selection = section
                    }
                } label: {
                    Text(section.rawValue)
                }
            }
        } label: {
            HStack(spacing: 8) {
                LifeOSIcon(selection.icon)
                    .frame(width: 15, height: 15)
                Text(selection.rawValue)
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                Spacer(minLength: 0)
                LifeOSIcon(.chevronRight)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 12, height: 12)
                    .rotationEffect(.degrees(90))
            }
                .foregroundStyle(LifeOSTokens.Module.fitness)
            .padding(.horizontal, 11)
            .frame(height: 36, alignment: .leading)
            .background(LifeOSTokens.raised, in: Capsule())
            .padding(.horizontal, 16)
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Fitness section")
        .accessibilityValue(selection.rawValue)
    }
#endif

    @ViewBuilder
    private func sectionButtons() -> some View {
        ForEach(FitnessSection.allCases) { section in
            Button {
                select(section)
            } label: {
                HStack(spacing: 6) {
                    LifeOSIcon(section.icon)
                        .frame(width: 15, height: 15)
                        .foregroundStyle(selection == section ? LifeOSTokens.Module.fitness : LifeOSTokens.secondaryText)
                    Text(section.rawValue)
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .foregroundStyle(selection == section ? LifeOSTokens.primaryText : LifeOSTokens.secondaryText)
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
                .background(selection == section ? LifeOSTokens.Module.fitness.opacity(0.14) : LifeOSTokens.surface.opacity(0.48), in: Capsule())
            }
            .buttonStyle(.plain)
            .background(GeometryReader { geometry in
                Color.clear.preference(
                    key: FitnessSectionFramePreferenceKey.self,
                    value: [section.id: geometry.frame(in: .named("fitness-section-picker"))]
                )
            })
            .id(section.id)
            .accessibilityAddTraits(selection == section ? .isSelected : [])
        }
    }

    private func select(_ section: FitnessSection) {
        guard selection != section else {
            invalidatePendingReveal()
            return
        }
        invalidatePendingReveal()
        pendingUserSelection = section
        withAnimation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.snappy) {
            selection = section
        }
    }

    private func queueReveal(for section: FitnessSection, isInitialAppearance: Bool) {
        revealGeneration += 1
        pendingReveal = FitnessSectionRevealRequest(
            section: section,
            generation: revealGeneration,
            isInitialAppearance: isInitialAppearance
        )
        scheduledRevealGeneration = nil
    }

    private func invalidatePendingReveal() {
        revealGeneration += 1
        pendingReveal = nil
        scheduledRevealGeneration = nil
    }

    /// Reveal only against the latest measured section frames. The next
    /// run-loop callback is bounded to this request generation; if a user tap
    /// or a newer route replaces it, the stale callback becomes a no-op.
    private func schedulePendingReveal(using proxy: ScrollViewProxy) {
        guard let request = pendingReveal,
              scheduledRevealGeneration != request.generation else { return }
        scheduledRevealGeneration = request.generation
        let generation = request.generation
        DispatchQueue.main.async {
            guard pendingReveal?.generation == generation else { return }
            scheduledRevealGeneration = nil
            reconcilePendingReveal(
                using: proxy,
                visibleSectionIDs: visibleSectionIDs,
                layoutReady: sectionLayoutReady
            )
        }
    }

    private func reconcilePendingReveal(
        using proxy: ScrollViewProxy,
        visibleSectionIDs: Set<String>,
        layoutReady: Bool
    ) {
        guard let request = pendingReveal else { return }
        switch FitnessSectionRevealState.action(
            for: request,
            currentSelection: selection,
            currentGeneration: revealGeneration,
            visibleSectionIDs: visibleSectionIDs,
            layoutReady: layoutReady
        ) {
        case .waitForLayout:
            return
        case .clear:
            pendingReveal = nil
            scheduledRevealGeneration = nil
        case .reveal:
            pendingReveal = nil
            scheduledRevealGeneration = nil
            revealSelection(request.section, using: proxy, animated: !request.isInitialAppearance)
        }
    }

    private func revealSelection(_ section: FitnessSection, using proxy: ScrollViewProxy, animated: Bool) {
        let reveal = {
            proxy.scrollTo(section.id, anchor: scrollAnchor(for: section))
        }
        guard animated, !LifeOSMotion.reduceMotion else {
            reveal()
            return
        }
        withAnimation(LifeOSMotion.snappy) {
            reveal()
        }
    }

    private func scrollAnchor(for section: FitnessSection) -> UnitPoint {
        switch section {
        case .today: .leading
        case .settings: .trailing
        default: .center
        }
    }

}

private struct FitnessSectionFramePreferenceKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, next in next })
    }
}

private struct FitnessFixtureBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            LifeOSIcon(.warning).frame(width: 14, height: 14)
            Text("DEMO FIXTURES · NOT LIVE DATA")
                .font(LifeOSFont.inter(10, weight: .bold))
                .tracking(0.45)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(LifeOSTokens.warning)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("fitness-demo-banner")
    }
}

private struct FitnessSectionContent: View {
    let section: FitnessSection
    let snapshot: FitnessSnapshot
    @Binding var selectedDate: Date
    let nutritionEntryPoint: FitnessNutritionEntryPoint?
    let fitnessEntryPoint: FitnessWidgetEntryPoint?
    @ObservedObject var journalStore: FitnessJournalStore
    let usesVisualFixtures: Bool
    let onSourceTap: () -> Void

    var body: some View {
        switch section {
        case .today:
            if let route = fitnessEntryPoint?.coreRoute {
                FitnessCoreDetailView(
                    route: route,
                    snapshot: snapshot,
                    selectedDate: $selectedDate,
                    onSourceTap: onSourceTap,
                    embeddedInParentScroll: true
                )
            } else {
                FitnessTodayView(snapshot: snapshot, selectedDate: $selectedDate, onSourceTap: onSourceTap)
            }
        case .journal:
            FitnessJournalView(snapshot: snapshot, selectedDate: $selectedDate, journalStore: journalStore, onSourceTap: onSourceTap)
        case .fitness:
            FitnessActivityView(
                snapshot: snapshot,
                selectedDate: selectedDate,
                usesVisualFixtures: usesVisualFixtures,
                onSourceTap: onSourceTap
            )
        case .biology:
            VStack(alignment: .leading, spacing: 14) {
                if snapshot.source.status.needsReview {
                    FitnessSourceGateCard(source: snapshot.source, onSourceTap: onSourceTap)
                }
                FitnessBiologyDetailSurface(
                    snapshot: snapshot.biology,
                    selectedDate: $selectedDate,
                    usesVisualFixtures: usesVisualFixtures || snapshot.source.status == .demo
                )
                .id(selectedDate)
            }
        case .nutrition:
            FitnessNutritionView(snapshot: snapshot, selectedDate: selectedDate, initialEntryPoint: nutritionEntryPoint)
        case .supplements:
            FitnessSupplementsView(supplements: snapshot.supplements, selectedDate: selectedDate)
        case .settings:
            FitnessSettingsView(source: snapshot.source, onSourceTap: onSourceTap)
        }
    }
}

// MARK: - Today

private struct FitnessTodayView: View {
    let snapshot: FitnessSnapshot
    @Binding var selectedDate: Date
    let onSourceTap: () -> Void

    var body: some View {
        FitnessCoreTodayComposition(
            snapshot: snapshot,
            selectedDate: $selectedDate,
            onSourceTap: onSourceTap
        )
    }
}

// MARK: - Matrix-driven Today composition

/// The Today surface is deliberately composed in reading order rather than
/// as an equal-weight bento. The order mirrors the functional Bevel frames:
/// readiness first, then the paired load/sleep read, stress/energy context,
/// nutrition, health monitor, and finally the chronological record.
private enum FitnessCoreRoute: Hashable {
    case readiness, load, sleep, stress, energyReserve, healthMonitor
    case healthMetric(FitnessHealthMetric)
    case workout(String)

    var title: String {
        switch self {
        case .readiness: "Recovery"
        case .load: "Load"
        case .sleep: "Sleep"
        case .stress: "Stress"
        case .energyReserve: "Energy Reserve"
        case .healthMonitor: "Health Monitor"
        case .healthMetric(let metric): metric.title
        case .workout: "Workout"
        }
    }

    var accent: LifeOSTokens.Hue {
        switch self {
        case .readiness: .green
        case .load: .blue
        case .sleep: .violet
        case .stress: .orange
        case .energyReserve: .teal
        case .healthMonitor: .pink
        case .healthMetric: .pink
        case .workout: .blue
        }
    }
}

private extension FitnessWidgetEntryPoint {
    var coreRoute: FitnessCoreRoute? {
        switch self {
        case .dailyOverview: nil
        case .strain: .load
        case .recovery: .readiness
        case .sleep: .sleep
        case .healthMonitor: .healthMonitor
        case .stress: .stress
        case .energyReserve: .energyReserve
        case .healthMetric(let metric): .healthMetric(metric)
        }
    }
}

private struct FitnessCoreTodayComposition: View {
    let snapshot: FitnessSnapshot
    @Binding var selectedDate: Date
    let onSourceTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            FitnessSectionHeading(title: "Today", subtitle: selectedDate.fitnessDayLabel)

            if snapshot.source.status.needsReview {
                FitnessSourceGateCard(source: snapshot.source, onSourceTap: onSourceTap)
            }

            FitnessCoreReadinessHero(metric: snapshot.readiness)

            FitnessCoreSectionLabel(title: "Load & sleep", detail: "The two signals that frame today")
            FitnessCoreColumns(minColumnWidth: 300) {
                FitnessCoreMetricCard(route: .load, metric: snapshot.strain, emphasis: true)
                FitnessCoreMetricCard(route: .sleep, metric: snapshot.sleep, emphasis: true)
            }

            FitnessCoreSectionLabel(title: "Daily balance", detail: "Stress and reserve are separate signals")
            FitnessCoreColumns(minColumnWidth: 300) {
                FitnessCoreMetricCard(route: .stress, metric: snapshot.stress)
                FitnessCoreMetricCard(route: .energyReserve, metric: snapshot.energyReserve)
            }

            FitnessCoreSectionLabel(title: "Nutrition", detail: "Food records and energy calculations")
            FitnessNutritionSummaryCard(nutrition: snapshot.nutrition)

            FitnessCoreHealthMonitorCard(metrics: snapshot.healthMonitor)
            FitnessCoreTimelineCard(
                workouts: snapshot.workouts,
                journalEntries: snapshot.journalEntries,
                supplements: snapshot.supplements
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationDestination(for: FitnessCoreRoute.self) { route in
            FitnessCoreDetailView(
                route: route,
                snapshot: snapshot,
                selectedDate: $selectedDate,
                onSourceTap: onSourceTap
            )
        }
        .accessibilityIdentifier("fitness-today-composition")
    }
}

private struct FitnessCoreSectionLabel: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Capsule()
                .fill(LifeOSTokens.Module.fitness)
                .frame(width: 3, height: 16)
                .accessibilityHidden(true)
            Text(title)
                .font(LifeOSFont.cardTitle(15))
            Text(detail)
                .font(LifeOSFont.metadata())
                .foregroundStyle(LifeOSTokens.secondaryText)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A tiny layout primitive that makes the desktop reflow deterministic:
/// one column on a phone, two columns at normal Mac widths, and three columns
/// when the maximised content can actually support them. It intentionally
/// avoids a fixed max-width container or a mechanically adaptive fourth row.
private struct FitnessCoreColumns: Layout {
    let minColumnWidth: CGFloat
    let spacing: CGFloat = 12

    private func columnCount(for width: CGFloat) -> Int {
        if width >= minColumnWidth * 3 + spacing * 2 { return 3 }
        if width >= minColumnWidth * 2 + spacing { return 2 }
        return 1
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let width = proposal.width ?? minColumnWidth
        let count = min(columnCount(for: width), max(subviews.count, 1))
        let columnWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var height: CGFloat = 0
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            rowHeight = max(rowHeight, subviews[index].sizeThatFits(.init(width: columnWidth, height: nil)).height)
            if index % count == count - 1 || index == subviews.count - 1 {
                height += rowHeight
                if index != subviews.count - 1 { height += spacing }
                rowHeight = 0
            }
        }
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let count = min(columnCount(for: bounds.width), max(subviews.count, 1))
        let columnWidth = max(1, (bounds.width - spacing * CGFloat(count - 1)) / CGFloat(count))
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for index in subviews.indices {
            let column = index % count
            let size = subviews[index].sizeThatFits(.init(width: columnWidth, height: nil))
            rowHeight = max(rowHeight, size.height)
            let x = bounds.minX + CGFloat(column) * (columnWidth + spacing)
            subviews[index].place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: .init(width: columnWidth, height: size.height)
            )
            if column == count - 1 || index == subviews.count - 1 {
                y += rowHeight + spacing
                rowHeight = 0
            }
        }
    }
}

private struct FitnessCoreReadinessHero: View {
    let metric: FitnessMetric

    var body: some View {
        FitnessCoreNavigationCard(route: .readiness, accent: .green) {
            HStack(alignment: .center, spacing: 14) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Recovery")
                        .font(LifeOSFont.header(18))
                    Text("Readiness score")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.value ?? "—")
                            .font(LifeOSFont.spaceGrotesk(40, weight: .bold))
                            .monospacedDigit()
                        if metric.value != nil, !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(LifeOSFont.caption(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    FitnessCoreProvenance(metric: metric)
                }
                Spacer(minLength: 8)
                if let progress = metric.progress, metric.isValueAvailable {
                    FitnessRing(progress: progress, hue: metric.hue, size: 78, color: FitnessRingPalette.threshold(progress))
                        .accessibilityHidden(true)
                } else {
                    FitnessCoreUnavailableMark(size: 58)
                }
            }
            Text(readinessContext)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(1)
        }
        .accessibilityIdentifier("fitness-core-recovery-card")
    }

    private var readinessContext: String {
        switch metric.sourceState {
        case .unavailable, .permissionRequired, .deviceUnavailable,
             .readIndeterminate, .calibrating, .conflict, .error:
            "\(metric.sourceState.label) · \(metric.detail)"
        case .demo:
            "Live wake-time timing requires a connected source"
        case .partial, .stale:
            "\(metric.sourceState.label) · Open for source-backed interpretation"
        default:
            "Open for source-backed interpretation"
        }
    }
}

private struct FitnessCoreMetricCard: View {
    let route: FitnessCoreRoute
    let metric: FitnessMetric
    var emphasis = false

    var body: some View {
        FitnessCoreNavigationCard(route: route, accent: route.accent) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(route.title)
                        .font(LifeOSFont.header(emphasis ? 17 : 15))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.value ?? "—")
                            .font(LifeOSFont.spaceGrotesk(emphasis ? 34 : 28, weight: .bold))
                            .monospacedDigit()
                        if metric.value != nil, !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(LifeOSFont.caption(11))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                }
                Spacer(minLength: 4)
                if let progress = metric.progress, metric.isValueAvailable {
                    FitnessRing(progress: progress, hue: metric.hue, size: emphasis ? 58 : 48, color: FitnessRingPalette.color(route: route, progress: progress))
                        .accessibilityHidden(true)
                } else {
                    FitnessCoreUnavailableMark(size: 42)
                }
            }
            if metric.trend.isEmpty {
                FitnessCoreProvenance(metric: metric)
            } else {
                FitnessCoreSparkline(values: metric.trend)
                FitnessCoreProvenance(metric: metric)
            }
        }
        .accessibilityIdentifier("fitness-core-\(route.title.lowercased().replacingOccurrences(of: " ", with: "-"))-card")
    }
}

private struct FitnessCoreNavigationCard<Content: View>: View {
    let route: FitnessCoreRoute
    let accent: LifeOSTokens.Hue
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: route) {
            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatCard()
            .overlay(alignment: .topLeading) {
                Capsule()
                    .fill(accent.base)
                    .frame(width: 3, height: 28)
                    .padding(.top, 14)
                    .accessibilityHidden(true)
            }
            .overlay(
                LifeOSTokens.cardShape.stroke(
                    hovering ? LifeOSTokens.strongBorder : Color.clear,
                    lineWidth: 1
                )
            )
            .contentShape(LifeOSTokens.cardShape)
        }
        .buttonStyle(.plain)
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .animation(reduceMotion ? nil : LifeOSMotion.springSnappy, value: hovering)
        .accessibilityHint("Opens \(route.title) detail")
    }
}

private struct FitnessCoreProvenance: View {
    let metric: FitnessMetric

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(fitnessMetricStateColor(metric.sourceState))
                .frame(width: 6, height: 6)
            Text(metric.sourceState.label)
                .font(LifeOSFont.inter(10, weight: .semiBold))
                .foregroundStyle(fitnessMetricStateColor(metric.sourceState))
            Text("·")
                .foregroundStyle(Color.secondary)
            Text(compactDetail)
                .font(LifeOSFont.caption(11))
                .foregroundStyle(Color.secondary)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private var compactDetail: String {
        metric.provenanceSummary
            .replacingOccurrences(of: " · demo fixture", with: "")
            .replacingOccurrences(of: "demo fixture", with: "fixture")
    }
}

private func fitnessMetricStateColor(_ state: FitnessMetric.SourceState) -> Color {
    switch state {
    case .observed, .derived, .manual:
        LifeOSTokens.success
    case .demo, .partial, .stale, .calibrating, .permissionRequired,
         .deviceUnavailable, .readIndeterminate, .conflict, .error:
        LifeOSTokens.warning
    case .unavailable:
        LifeOSTokens.tertiaryText
    }
}

private struct FitnessCoreUnavailableMark: View {
    let size: CGFloat

    init(size: CGFloat = 54) { self.size = size }

    var body: some View {
        ZStack {
            Circle().stroke(LifeOSTokens.quietBorder, lineWidth: 5)
            Text("—")
                .font(LifeOSFont.spaceGrotesk(size * 0.34, weight: .bold))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct FitnessCoreSparkline: View {
    let values: [Double]
    // §5.5: the trend sparkline is the one chromatic element on neutral
    // metric cards — always accent. The legacy `hue` init arg is dropped.
    var accent: Color = LifeOSTokens.accent

    init(values: [Double]) {
        self.values = values
    }

    var body: some View {
        let normalized = FitnessTrendSeries(values: values)?.normalized ?? []
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(Array(normalized.enumerated()), id: \.offset) { _, value in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(accent.opacity(0.42 + value * 0.42))
                    .frame(maxWidth: .infinity, minHeight: 4, maxHeight: 34)
                    .frame(height: max(4, min(34, CGFloat(value) * 30 + 4)))
            }
        }
        .frame(height: 34, alignment: .bottom)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Trend")
        .accessibilityValue(values.map { $0.formatted(.number.precision(.fractionLength(0...1))) }.joined(separator: ", "))
    }
}

private struct FitnessCoreHealthMonitorCard: View {
    let metrics: [FitnessMetric]

    var body: some View {
        FitnessCoreNavigationCard(route: .healthMonitor, accent: .pink) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Health Monitor")
                        .font(LifeOSFont.header(17))
                    Text("Independent observations; missing fields stay unavailable")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 0)
                LifeOSIcon(.chevronRight)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .frame(width: 14, height: 14)
            }
            FitnessCoreColumns(minColumnWidth: 170) {
                ForEach(metrics) { metric in
                    FitnessCoreMiniMetric(metric: metric)
                }
            }
        }
        .accessibilityIdentifier("fitness-core-health-monitor-card")
    }
}

private struct FitnessCoreMiniMetric: View {
    let metric: FitnessMetric

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(fitnessMetricStateColor(metric.sourceState))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(metric.value ?? "—")
                        .font(LifeOSFont.spaceGrotesk(18, weight: .bold))
                        .monospacedDigit()
                    if !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(LifeOSFont.caption(9))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(LifeOSTokens.screenCanvas.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.hairlineBorder, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.title)
        .accessibilityValue("\(metric.value ?? "Not available") \(metric.unit). \(metric.sourceState.label). \(metric.provenanceSummary)")
    }
}

private struct FitnessCoreTimelineItem: Identifiable {
    let id: String
    let date: Date
    let title: String
    let detail: String
    let trailing: String
    let icon: LifeOSIconName
    let hue: LifeOSTokens.Hue
}

private struct FitnessCoreTimelineCard: View {
    let workouts: [FitnessWorkout]
    let journalEntries: [FitnessJournalEntry]
    let supplements: [FitnessSupplement]

    private var items: [FitnessCoreTimelineItem] {
        let workoutItems = workouts.map {
            FitnessCoreTimelineItem(id: $0.id, date: $0.time, title: $0.name, detail: "\($0.kind) · \($0.duration)", trailing: $0.time.fitnessTimeLabel, icon: .fitness, hue: $0.hue)
        }
        let journalItems = journalEntries.map {
            FitnessCoreTimelineItem(id: $0.id, date: $0.time, title: $0.title, detail: $0.source.rawValue, trailing: $0.time.fitnessTimeLabel, icon: .more, hue: .teal)
        }
        let supplementItems = supplements.map {
            FitnessCoreTimelineItem(id: "supplement-\($0.id)", date: Date.distantPast, title: $0.name, detail: "Planned · \($0.timing)", trailing: "Local", icon: .verified, hue: .violet)
        }
        return (workoutItems + journalItems + supplementItems).sorted { $0.date > $1.date }
    }

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Timeline")
                            .font(LifeOSFont.header(17))
                        Text("Chronological record for the selected day")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 0)
                    Text("Date-scoped")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if items.isEmpty {
                    FitnessEmptyRow(title: "No activity logged", detail: "Meals, hydration, caffeine, alcohol, supplements, workouts, and journal facts appear here when recorded.", icon: .more)
                } else {
                    ForEach(items) { item in
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(LifeOSTokens.raised)
                                .frame(width: 32, height: 32)
                                .overlay(LifeOSIcon(item.icon).foregroundStyle(LifeOSTokens.secondaryText).frame(width: 15, height: 15))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(LifeOSFont.inter(12, weight: .medium))
                                Text(item.detail)
                                    .font(LifeOSFont.caption(10))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                            Spacer(minLength: 8)
                            Text(item.trailing)
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("\(item.title), \(item.detail), \(item.trailing)")
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-core-timeline")
    }
}

private struct FitnessCoreDetailView: View {
    let route: FitnessCoreRoute
    let snapshot: FitnessSnapshot
    @Binding var selectedDate: Date
    let onSourceTap: () -> Void
    let embeddedInParentScroll: Bool

    init(
        route: FitnessCoreRoute,
        snapshot: FitnessSnapshot,
        selectedDate: Binding<Date>,
        onSourceTap: @escaping () -> Void,
        embeddedInParentScroll: Bool = false
    ) {
        self.route = route
        self.snapshot = snapshot
        self._selectedDate = selectedDate
        self.onSourceTap = onSourceTap
        self.embeddedInParentScroll = embeddedInParentScroll
    }

    private var metric: FitnessMetric {
        switch route {
        case .readiness: snapshot.readiness
        case .load: snapshot.strain
        case .sleep: snapshot.sleep
        case .stress: snapshot.stress
        case .energyReserve: snapshot.energyReserve
        case .healthMonitor: snapshot.healthMonitor.first ?? .unavailable("Health Monitor")
        case .healthMetric(let healthMetric):
            snapshot.healthMonitor.first { healthMetric.matches(metricTitle: $0.title) }
                ?? .unavailable(healthMetric.title)
        case .workout:
            .unavailable("Workout detail")
        }
    }

    var body: some View {
        Group {
            if case .stress = route {
                FitnessStressDetailView(
                    snapshot: snapshot.stressDetail,
                    selectedDate: $selectedDate,
                    embeddedInParentScroll: embeddedInParentScroll
                )
            } else if embeddedInParentScroll {
                detailContent
            } else {
                ScrollView {
                    detailContent
                        .padding(.horizontal, 16)
                        .padding(.top, 14)
                        .padding(.bottom, 28)
                }
                .scrollIndicators(.hidden)
            }
        }
        .navigationTitle(route.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
    }

    @ViewBuilder
    private var detailContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            FitnessSectionHeading(title: route.title, subtitle: selectedDate.fitnessDayLabel)
            FitnessCoreDetailHero(metric: metric, route: route)
            FitnessCoreAvailabilityNote(metric: metric, source: snapshot.source, onSourceTap: onSourceTap)

            switch route {
            case .readiness:
                FitnessCoreRecoveryDetail(detail: snapshot.recoveryDetail, selectedDate: selectedDate)
            case .load:
                FitnessCoreLoadDetail(metric: metric, detail: snapshot.loadDetail, workouts: snapshot.workouts, selectedDate: selectedDate)
            case .sleep:
                FitnessCoreSleepDetail(detail: snapshot.sleepDetail, source: snapshot.source, selectedDate: selectedDate)
            case .stress:
                EmptyView()
            case .energyReserve:
                FitnessCoreTrendDetail(metric: metric, title: "Daily energy")
                FitnessCoreDetailRows(title: "Charge context", rows: [
                    ("Last charged", "Unavailable · source event timestamp required"),
                    ("Charged", "Unavailable · no charge events supplied"),
                    ("Discharged", "Unavailable · no expenditure events supplied")
                ])
            case .healthMonitor:
                FitnessCoreHealthDetail(metrics: snapshot.healthMonitor, source: snapshot.source)
            case .healthMetric(_):
                FitnessCoreHealthDetail(metrics: [metric], source: snapshot.source)
            case .workout(let id):
                FitnessCoreWorkoutDetail(
                    workout: snapshot.workouts.first(where: { $0.id == id }),
                    source: snapshot.source
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func healthMetric(named name: String) -> FitnessMetric? {
        snapshot.healthMonitor.first { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    }
}

private struct FitnessCoreLoadDetail: View {
    let metric: FitnessMetric
    let detail: FitnessLoadDetail
    let workouts: [FitnessWorkout]
    let selectedDate: Date
    @State private var selectedRange: FitnessTrendRange = .seven

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
#if os(macOS)
            FitnessCoreColumns(minColumnWidth: 340) {
                FitnessCoreLoadGaugeCard(metric: metric, gauge: detail.gauge, reconciliation: detail.durationReconciliation)
                VStack(alignment: .leading, spacing: 12) {
                    FitnessCoreColumns(minColumnWidth: 150) {
                        FitnessCoreMeasurementCard(title: "Duration", metric: detail.duration)
                        FitnessCoreMeasurementCard(title: "Energy", metric: detail.energy)
                    }
                    FitnessCoreSourceCopyCard(title: "Coaching", copy: detail.coaching)
                }
            }
            FitnessCoreColumns(minColumnWidth: 420) {
                FitnessCoreWorkoutList(workouts: workouts)
                FitnessCoreHeartRateZones(zones: detail.heartRateZones)
            }
#else
            FitnessCoreLoadGaugeCard(metric: metric, gauge: detail.gauge, reconciliation: detail.durationReconciliation)
            FitnessCoreColumns(minColumnWidth: 240) {
                FitnessCoreMeasurementCard(title: "Duration", metric: detail.duration)
                FitnessCoreMeasurementCard(title: "Energy", metric: detail.energy)
            }
            FitnessCoreSourceCopyCard(title: "Coaching", copy: detail.coaching)
            FitnessCoreWorkoutList(workouts: workouts)
            FitnessCoreHeartRateZones(zones: detail.heartRateZones)
#endif
            FitnessCoreLoadTrends(cards: detail.trendCards, selectedDate: selectedDate, selectedRange: $selectedRange)
        }
    }
}

private struct FitnessCoreLoadGaugeCard: View {
    let metric: FitnessMetric
    let gauge: FitnessLoadGauge
    let reconciliation: FitnessZoneDurationReconciliation

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("Gauge and target").font(LifeOSFont.header(14))
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(metric.value ?? "No data")
                        .font(LifeOSFont.spaceGrotesk(27, weight: .bold))
                        .monospacedDigit()
                    if !metric.unit.isEmpty, metric.value != nil {
                        Text(metric.unit)
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    Text(gauge.targetLabel)
                        .font(LifeOSFont.inter(11, weight: .medium))
                        .multilineTextAlignment(.trailing)
                        .foregroundStyle(gauge.currentProgress == nil ? LifeOSTokens.tertiaryText : LifeOSTokens.accent)
                }
                if let progress = gauge.currentProgress {
                    ProgressView(value: progress)
                        .tint(LifeOSTokens.accent)
                    Text("Source target band · no proprietary load formula is reproduced")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    Text(loadGaugeReason)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(reconciliation.label)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(reconciliationLabelColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var loadGaugeReason: String {
        switch gauge.state {
        case .unavailable(let reason): return reason
        case .observed(_, _, _, _, let window, let provenance), .demo(_, _, _, _, let window, let provenance):
            return "\(window) · \(provenance)"
        }
    }

    private var reconciliationLabelColor: Color {
        switch reconciliation {
        case .matched: LifeOSTokens.success
        case .mismatch: LifeOSTokens.warning
        case .unavailable: LifeOSTokens.tertiaryText
        }
    }
}

private struct FitnessCoreMeasurementCard: View {
    let title: String
    let metric: FitnessMetric
    var evidence: FitnessSourceEvidence? = nil

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title)
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(Color.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(metric.value ?? "No data")
                        .font(LifeOSFont.spaceGrotesk(25, weight: .bold))
                        .monospacedDigit()
                    if metric.value != nil, !metric.unit.isEmpty {
                        Text(metric.unit)
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(Color.secondary)
                    }
                }
                Text(evidence?.summary ?? metric.detail)
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct FitnessCoreHeartRateZones: View {
    let zones: [FitnessHeartRateZone]
    @State private var expandedZoneID: Int?

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("Heart-rate zones").font(LifeOSFont.header(14))
                if zones.isEmpty {
                    FitnessEmptyRow(title: "Unavailable", detail: "No typed source zone sample is present. LifeOS does not infer zones from duration or a generic load value.", icon: .health)
                } else {
                    ForEach(zones) { zone in
                        FitnessCoreHeartRateZoneRow(
                            zone: zone,
                            isExpanded: expandedZoneID == zone.id,
                            onToggle: {
                                expandedZoneID = expandedZoneID == zone.id ? nil : zone.id
                            }
                        )
                    }
                }
            }
        }
    }
}

private struct FitnessCoreHeartRateZoneRow: View {
    let zone: FitnessHeartRateZone
    let isExpanded: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Text("Z\(zone.id)")
                        .font(LifeOSFont.inter(11, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.accent)
                        .frame(width: 25, alignment: .leading)
                    Text(zone.duration)
                        .font(LifeOSFont.inter(12, weight: .medium))
                        .monospacedDigit()
                    Spacer(minLength: 6)
                    Text(zone.range)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Image(systemName: isExpanded ? "info.circle.fill" : "info.circle")
                        .font(.caption2)
                        .foregroundStyle(isExpanded || hovering ? LifeOSTokens.accent : LifeOSTokens.tertiaryText)
                }
                if isExpanded {
                    Text(zone.evidence.summary)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LifeOSTokens.screenCanvas.opacity(hovering || isExpanded ? 0.62 : 0.34), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isExpanded || hovering ? LifeOSTokens.accent.opacity(0.42) : LifeOSTokens.hairlineBorder, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
#if os(macOS)
        .onHover { hovering = $0 }
        .help("Show source, device, window, and freshness for heart-rate zone \(zone.id)")
#endif
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Heart-rate zone \(zone.id), \(zone.duration), \(zone.range)")
        .accessibilityValue(isExpanded ? zone.evidence.summary : "Evidence collapsed")
        .accessibilityHint("Shows source evidence")
    }
}

private struct FitnessCoreLoadTrends: View {
    let cards: [FitnessLoadTrendCard]
    let selectedDate: Date
    @Binding var selectedRange: FitnessTrendRange

    private var enabledRanges: Set<FitnessTrendRange> {
        cards.reduce(into: Set<FitnessTrendRange>()) { result, card in result.formUnion(card.availableSeriesRanges) }
    }

    private var activeRange: FitnessTrendRange {
        if enabledRanges.contains(selectedRange) { return selectedRange }
        return FitnessTrendRange.allCases.first(where: { enabledRanges.contains($0) }) ?? selectedRange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Load trends").font(LifeOSFont.header(15))
                    Text("\(selectedDate.fitnessDayLabel) · source history only").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer()
                Menu {
                    ForEach(FitnessTrendRange.allCases) { range in
                        Button(range.title) { selectedRange = range }
                            .disabled(!enabledRanges.contains(range))
                    }
                } label: {
                        Label(enabledRanges.isEmpty ? "History unavailable" : activeRange.title, systemImage: "calendar")
                        .font(LifeOSFont.caption(10))
                    }
                .menuStyle(.borderlessButton)
                .disabled(enabledRanges.count <= 1)
                .accessibilityLabel("Trend range")
                .accessibilityValue(enabledRanges.isEmpty ? "History unavailable" : activeRange.title)
            }

#if os(macOS)
            LazyVGrid(columns: [GridItem(.flexible(minimum: 260)), GridItem(.flexible(minimum: 260))], spacing: 10) {
                ForEach(cards) { card in FitnessCoreLoadTrendCard(card: card, selectedRange: activeRange) }
            }
#else
            VStack(spacing: 10) {
                ForEach(cards) { card in FitnessCoreLoadTrendCard(card: card, selectedRange: activeRange) }
            }
#endif
        }
        .padding(13)
        .flatCard()
    }
}

private struct FitnessCoreLoadTrendCard: View {
    let card: FitnessLoadTrendCard
    let selectedRange: FitnessTrendRange
    @State private var hovering = false
    @State private var isExpanded = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(card.id.title).font(LifeOSFont.inter(12, weight: .medium))
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(card.metric.value ?? "No data").font(LifeOSFont.spaceGrotesk(24, weight: .bold)).monospacedDigit()
                    Text(card.metric.unit).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if let selectedSeries, !selectedSeries.isEmpty {
                    FitnessCoreSparkline(values: selectedSeries)
                    Text("\(card.truth.label) · \(selectedRange.title) series")
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(truthColor)
                } else {
                    Text(!card.metric.isValueAvailable
                         ? card.truth.label
                         : "\(card.metric.sourceState.label) · source series unavailable · range not relabelled")
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(truthColor)
                }
                Text(card.evidence.summary)
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .lineLimit(2)
                if isExpanded {
                    FitnessCoreLoadTrendEvidenceDetail(card: card)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LifeOSTokens.screenCanvas.opacity(hovering || isExpanded || isFocused ? 0.72 : 0.38), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(hovering || isExpanded || isFocused ? LifeOSTokens.strongBorder : LifeOSTokens.hairlineBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
#if os(macOS)
        .focusable(true)
        .focused($isFocused)
        .onHover { hovering = $0 }
        .help("Show \(card.id.title) target, ranges, and source evidence")
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.id.title)
        .accessibilityValue("\(card.metric.value ?? "Not available") \(card.metric.unit). \(card.truth.label). \(card.evidence.summary). \(isExpanded ? "Details shown" : "Details hidden")")
        .accessibilityHint("Shows target, range availability, and source evidence")
    }

    private var truthColor: Color {
        switch card.truth {
        case .underTarget, .overTarget: LifeOSTokens.warning
        case .inTarget: LifeOSTokens.success
        case .observed: LifeOSTokens.accent
        case .partial, .stale: LifeOSTokens.warning
        case .demo: LifeOSTokens.warning
        case .unavailable: LifeOSTokens.tertiaryText
        }
    }

    private var selectedSeries: [Double]? { card.series(for: selectedRange) }
}

private struct FitnessCoreLoadTrendEvidenceDetail: View {
    let card: FitnessLoadTrendCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let target = card.target {
                Text("Target band · \(target.lower.formatted(.number.precision(.fractionLength(0...1))))–\(target.upper.formatted(.number.precision(.fractionLength(0...1)))) \(target.unit)")
                    .font(LifeOSFont.inter(10, weight: .semiBold))
            } else {
                Text("Target · not configured for this metric")
                    .font(LifeOSFont.inter(10, weight: .semiBold))
            }
            Text(card.availableSeriesRanges.isEmpty
                 ? "History ranges · insufficient source history"
                 : "History ranges · \(card.availableSeriesRanges.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(card.evidence.summary)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FitnessCoreRecoveryDetail: View {
    let detail: FitnessRecoveryDetail
    let selectedDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FitnessCoreColumns(minColumnWidth: 240) {
                FitnessCoreMeasurementCard(title: "Resting HRV", metric: detail.hrv, evidence: FitnessSourceEvidence.from(metric: detail.hrv))
                FitnessCoreMeasurementCard(title: "Resting heart rate", metric: detail.restingHeartRate, evidence: FitnessSourceEvidence.from(metric: detail.restingHeartRate))
            }
            FitnessCoreSourceCopyCard(title: "Why this recovery state?", copy: detail.explanation)
            FitnessCoreSourceCopyCard(
                title: "Insights",
                copy: detail.insights.first ?? .unavailable("Insights require observed recovery inputs; no conclusion is drawn from missing data.")
            )
            FitnessCoreRecoveryTrends(trends: detail.trends, selectedDate: selectedDate)
        }
    }
}

private struct FitnessCoreRecoveryTrends: View {
    let trends: [FitnessRecoveryTrendCard]
    let selectedDate: Date
    @State private var selectedTrend: FitnessRecoveryTrendID?
    @State private var requestedRange: FitnessTrendRange = .seven

    private var enabledRanges: Set<FitnessTrendRange> {
        trends.reduce(into: Set<FitnessTrendRange>()) { result, card in result.formUnion(card.availableSeriesRanges) }
    }

    private var activeRange: FitnessTrendRange {
        if enabledRanges.contains(requestedRange) { return requestedRange }
        return FitnessTrendRange.allCases.first(where: { enabledRanges.contains($0) }) ?? requestedRange
    }

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Recovery trends").font(LifeOSFont.header(15))
                        Text("\(selectedDate.fitnessDayLabel) · each metric keeps its own source evidence").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer()
                    Menu {
                        ForEach(FitnessTrendRange.allCases) { range in
                            Button(range.title) {
                                requestedRange = range
                            }
                            .disabled(!enabledRanges.contains(range))
                        }
                    } label: {
                        Label(activeRange.title, systemImage: "calendar")
                            .font(LifeOSFont.caption(10))
                    }
                    .disabled(enabledRanges.count <= 1)
                    .accessibilityLabel("Recovery trend range")
                    .accessibilityValue(activeRange.title)
                }
#if os(macOS)
                LazyVGrid(columns: [GridItem(.flexible(minimum: 260)), GridItem(.flexible(minimum: 260))], spacing: 10) {
                    ForEach(trends) { card in
                        FitnessCoreRecoveryTrendButton(
                            card: card,
                            range: activeRange,
                            isSelected: selectedTrend == card.id,
                            onToggle: {
                                selectedTrend = selectedTrend == card.id ? nil : card.id
                            }
                        )
                    }
                }
                if let selectedTrend, let selectedCard = trends.first(where: { $0.id == selectedTrend }) {
                    FitnessCoreRecoveryEvidenceDetail(card: selectedCard, range: activeRange)
                }
#else
                ForEach(trends) { card in
                    VStack(alignment: .leading, spacing: 0) {
                        FitnessCoreRecoveryTrendButton(
                            card: card,
                            range: activeRange,
                            isSelected: selectedTrend == card.id,
                            onToggle: {
                                selectedTrend = selectedTrend == card.id ? nil : card.id
                            }
                        )
                        if selectedTrend == card.id {
                            FitnessCoreRecoveryEvidenceDetail(card: card, range: activeRange)
                                .padding(.horizontal, 9)
                        }
                    }
                }
#endif
            }
        }
    }
}

private struct FitnessCoreRecoveryTrendButton: View {
    let card: FitnessRecoveryTrendCard
    let range: FitnessTrendRange
    let isSelected: Bool
    let onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onToggle) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(card.id.title).font(LifeOSFont.inter(12, weight: .medium))
                    Spacer()
                    Text(card.metric.value ?? "No data").font(LifeOSFont.inter(12, weight: .semiBold))
                    Image(systemName: isSelected ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if let series = card.series(for: range), !series.isEmpty {
                    FitnessCoreSparkline(values: series)
                } else if card.metric.isValueAvailable {
                    Text("Source series unavailable · range not relabelled")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Text(!card.metric.isValueAvailable ? card.metric.detail : "\(card.metric.sourceState.label) · \(card.evidence.summary)")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .multilineTextAlignment(.leading)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(LifeOSTokens.screenCanvas.opacity(hovering || isSelected ? 0.58 : 0.34), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(hovering || isSelected ? LifeOSTokens.accent.opacity(0.42) : LifeOSTokens.hairlineBorder, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
#if os(macOS)
        .onHover { hovering = $0 }
        .help("Show \(card.id.title) source and trend detail")
#endif
        .accessibilityHint("Shows source and trend detail")
    }
}

private struct FitnessCoreRecoveryEvidenceDetail: View {
    let card: FitnessRecoveryTrendCard
    let range: FitnessTrendRange

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Detail · \(range.title)")
                .font(LifeOSFont.inter(10, weight: .semiBold))
            Text(card.evidence.summary)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            if !card.availableSeriesRanges.isEmpty && !card.availableSeriesRanges.contains(range) {
                Text("Insufficient history · \(range.title) is not available for this metric")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else if card.series(for: range)?.isEmpty != false {
                Text("Insufficient history · no source series across this range")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .padding(.top, 3)
    }
}

private struct FitnessCoreSleepDetail: View {
    let detail: FitnessSleepDetail
    let source: FitnessSourceState
    let selectedDate: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
#if os(macOS)
            // The compact two-column form is preferred on a normal Mac
            // window; the custom layout falls back to one column when the
            // detail pane cannot support two readable cards.
            FitnessCoreColumns(minColumnWidth: 330) {
                FitnessCoreMeasurementCard(title: "Sleep duration", metric: detail.duration)
                FitnessCoreMeasurementCard(title: "Sleep quality", metric: detail.quality)
                FitnessCoreMeasurementCard(title: "Time in bed", metric: detail.timeInBed)
            }
#else
            FitnessCoreColumns(minColumnWidth: 240) {
                FitnessCoreMeasurementCard(title: "Sleep duration", metric: detail.duration)
                FitnessCoreMeasurementCard(title: "Sleep quality", metric: detail.quality)
                FitnessCoreMeasurementCard(title: "Time in bed", metric: detail.timeInBed)
            }
#endif
            FitnessSleepTimelineCard(night: detail.night)
            FitnessCoreSourceCopyCard(title: "Why no data?", copy: whyNoData)
            FitnessCoreSourceCopyCard(
                title: "Insights",
                copy: detail.insights.first ?? .unavailable("Insights require an observed sleep interval; no conclusion is drawn from missing data.")
            )
            FitnessCoreSleepScheduleCard(
                schedule: detail.schedule,
                sleepNeed: detail.sleepNeed,
                windDown: detail.windDown,
                source: source
            )
            FitnessCoreSleepTrends(trends: detail.trends, selectedDate: selectedDate, source: source)
        }
    }

    private var whyNoData: FitnessSourceCopy {
        let metrics = [detail.quality, detail.timeInBed, detail.duration]
        if metrics.allSatisfy({ !$0.isValueAvailable }) {
            return .unavailable("Sleep quality, time in bed, and duration require a source sleep interval. Stages and score values are never fabricated from an empty night.")
        }
        let isDemo = source.status == .demo || metrics.contains(where: { $0.sourceState == .demo })
        return FitnessSourceCopy(state: isDemo
            ? .demo(
                text: "Fixture-only sleep values are shown for visual review; no live score or stage result is implied.",
                window: source.freshness,
                provenance: "DEMO · NOT LIVE"
            )
            : .observed(
                text: "Sleep values are shown only for the observations supplied by the connected source.",
                window: source.freshness,
                provenance: source.title
            ))
    }
}

private struct FitnessSleepTimelineCard: View {
    let night: FitnessSleepNight

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Observed night")
                            .font(LifeOSFont.header(14))
                        Text("Timeline only · no proprietary score or formula")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(Color.secondary)
                    }
                    Spacer(minLength: 8)
                    Text(night.state.label)
                        .font(LifeOSFont.inter(9, weight: .semiBold))
                        .foregroundStyle(statusColor)
                }
                switch night.state {
                case .unavailable(let reason):
                    FitnessEmptyRow(title: "Timeline unavailable", detail: reason, icon: .sleep)
                case .partial(let reason):
                    timelineTrack
                    Text("Partial · \(reason)")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                case .conflict(let reason):
                    FitnessEmptyRow(title: "Timeline withheld", detail: reason, icon: .sleep)
                    Text("Conflict · no stage geometry is treated as authoritative")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.warning)
                case .observed:
                    timelineTrack
                    Text("Observed interval and stage samples")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(Color.secondary)
                }
                if let boundary = night.boundary {
                    Text("Sleep-day boundary · \(boundary.summary)")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(Color.secondary)
                }
                Text(night.evidence.summary)
                    .font(LifeOSFont.caption(11))
                    .foregroundStyle(Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-sleep-timeline")
        .accessibilityLabel("Observed sleep timeline")
        .accessibilityValue(night.statusSummary)
    }

    @ViewBuilder
    private var timelineTrack: some View {
        if let start = night.start, let end = night.end, end > start {
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(LifeOSTokens.tertiaryText.opacity(0.16))
                        ForEach(night.stageSamples) { sample in
                            let lower = max(0, min(1, sample.start.timeIntervalSince(start) / end.timeIntervalSince(start)))
                            let upper = max(lower, min(1, sample.end.timeIntervalSince(start) / end.timeIntervalSince(start)))
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(stageColor(sample.stage))
                                .frame(width: max(2, proxy.size.width * CGFloat(upper - lower)))
                                .offset(x: proxy.size.width * CGFloat(lower))
                        }
                    }
                }
                .frame(height: 22)
                HStack {
                    Text(start, style: .time)
                    Spacer()
                    Text(end, style: .time)
                }
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                HStack(spacing: 9) {
                    ForEach(FitnessSleepStageSample.Stage.allCases) { stage in
                        HStack(spacing: 3) {
                            Circle().fill(stageColor(stage)).frame(width: 6, height: 6)
                            Text(stage.title)
                        }
                    }
                }
                .font(LifeOSFont.caption(9))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        } else {
            FitnessEmptyRow(title: "Interval incomplete", detail: "A start and end are required to draw the night timeline.", icon: .sleep)
        }
    }

    private var statusColor: Color {
        switch night.state {
        case .observed:
            return night.evidence.isDemo || night.evidence.isPartial || night.evidence.isStale
                ? LifeOSTokens.warning
                : LifeOSTokens.success
        case .partial, .conflict: return LifeOSTokens.warning
        case .unavailable: return LifeOSTokens.tertiaryText
        }
    }

    private func stageColor(_ stage: FitnessSleepStageSample.Stage) -> Color {
        switch stage {
        case .rem: return .lifeOSViolet500
        case .deep: return LifeOSTokens.accent
        case .core: return .lifeOSTeal500
        case .awake: return LifeOSTokens.warning
        }
    }
}

private struct FitnessCoreSleepScheduleCard: View {
    let schedule: FitnessSleepSchedule
    let sleepNeed: FitnessSourceCopy
    let windDown: FitnessSourceCopy
    let source: FitnessSourceState

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sleep schedule")
                        .font(LifeOSFont.header(15))
                    Text("Targets are shown only when explicitly configured or supplied")
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(Color.secondary)
                }
                Spacer(minLength: 8)
                if source.status == .demo {
                    Text("DEMO · NOT LIVE")
                        .font(LifeOSFont.inter(9, weight: .semiBold))
                        .foregroundStyle(LifeOSTokens.warning)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(LifeOSTokens.warning.opacity(0.12), in: Capsule())
                }
            }
            FitnessSleepScheduleRadial(schedule: schedule)
            scheduleDetails
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-sleep-schedule-card")
    }

    @ViewBuilder
    private var scheduleDetails: some View {
        switch schedule.state {
        case .unavailable(let reason):
            FitnessEmptyRow(
                title: "No schedule configured",
                detail: "\(reason) Sleep need and wind-down remain unavailable until a target is supplied.",
                icon: .sleep
            )
            Text("Source status · \(source.title) · \(source.freshness)")
                .font(LifeOSFont.caption(11))
                .foregroundStyle(Color.secondary)
        case .configured(
            let windDownMinutes,
            let targetBedtimeMinutes,
            let wakeTargetMinutes,
            let sleepNeedMinutes,
            _, _, _, _
        ):
            FitnessCoreDetailRows(title: "Configured targets", rows: [
                ("Wind-down", FitnessSleepSchedule.clockLabel(minutes: windDownMinutes)),
                ("Target bedtime", FitnessSleepSchedule.clockLabel(minutes: targetBedtimeMinutes)),
                ("Wake target", FitnessSleepSchedule.clockLabel(minutes: wakeTargetMinutes)),
                ("Sleep need", FitnessSleepSchedule.durationLabel(minutes: sleepNeedMinutes))
            ])
            Text(schedule.evidenceSummary)
                .font(LifeOSFont.caption(11))
                .foregroundStyle(Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FitnessSleepScheduleRadial: View {
    let schedule: FitnessSleepSchedule

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.08), lineWidth: 18)
                Circle()
                    .stroke(Color.primary.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                    .padding(16)

                switch schedule.state {
                case .unavailable:
                    VStack(spacing: 4) {
                        LifeOSIcon(.sleep)
                            .frame(width: 22, height: 22)
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                        Text("Schedule unavailable")
                            .font(LifeOSFont.inter(12, weight: .semiBold))
                        Text("No radial target is inferred")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                case .configured(
                    let windDownMinutes,
                    let targetBedtimeMinutes,
                    let wakeTargetMinutes,
                    let sleepNeedMinutes,
                    _, _, _, _
                ):
                    let duration = sleepWindowFraction(bedtime: targetBedtimeMinutes, wake: wakeTargetMinutes)
                    Circle()
                        .trim(from: 0, to: duration)
                        .stroke(
                            AngularGradient(
                                colors: [LifeOSTokens.accent.opacity(0.58), LifeOSTokens.accent],
                                center: .center
                            ),
                            style: StrokeStyle(lineWidth: 18, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90 + angle(for: targetBedtimeMinutes)))
                    scheduleMarker(minutes: windDownMinutes, radius: min(proxy.size.width, proxy.size.height) * 0.34, color: LifeOSTokens.warning, size: 10, in: proxy.size)
                    scheduleMarker(minutes: targetBedtimeMinutes, radius: min(proxy.size.width, proxy.size.height) * 0.44, color: LifeOSTokens.accent, size: 14, in: proxy.size)
                    scheduleMarker(minutes: wakeTargetMinutes, radius: min(proxy.size.width, proxy.size.height) * 0.44, color: LifeOSTokens.success, size: 14, in: proxy.size)
                    VStack(spacing: 4) {
                        Text("Sleep window")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                        Text("\(FitnessSleepSchedule.clockLabel(minutes: targetBedtimeMinutes)) → \(FitnessSleepSchedule.clockLabel(minutes: wakeTargetMinutes))")
                            .font(LifeOSFont.inter(13, weight: .semiBold))
                            .monospacedDigit()
                        Text(FitnessSleepSchedule.durationLabel(minutes: sleepNeedMinutes) + " need")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(height: 220)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sleep schedule radial")
        .accessibilityValue(accessibilityValue)
    }

    private var accessibilityValue: String {
        switch schedule.state {
        case .unavailable(let reason):
            return "Unavailable. \(reason)"
        case .configured(
            let windDownMinutes,
            let targetBedtimeMinutes,
            let wakeTargetMinutes,
            let sleepNeedMinutes,
            let timeZone,
            _, _, _
        ):
            return "Wind-down \(FitnessSleepSchedule.clockLabel(minutes: windDownMinutes)), bedtime \(FitnessSleepSchedule.clockLabel(minutes: targetBedtimeMinutes)), wake \(FitnessSleepSchedule.clockLabel(minutes: wakeTargetMinutes)), sleep need \(FitnessSleepSchedule.durationLabel(minutes: sleepNeedMinutes)), \(timeZone)"
        }
    }

    private func sleepWindowFraction(bedtime: Int, wake: Int) -> CGFloat {
        let seconds = (wake - bedtime + 1_440) % 1_440
        return CGFloat(seconds == 0 ? 1 : seconds) / 1_440
    }

    private func angle(for minutes: Int) -> Double {
        Double(minutes) / 1_440.0 * 360.0
    }

    private func scheduleMarker(minutes: Int, radius: CGFloat, color: Color, size: CGFloat, in canvas: CGSize) -> some View {
        let radians = (Double(minutes) / 1_440.0 * Double.pi * 2) - Double.pi / 2
        let centerX = canvas.width / 2 + cos(radians) * radius
        let centerY = canvas.height / 2 + sin(radians) * radius
        return Circle()
            .fill(color)
            .frame(width: size, height: size)
            .overlay(Circle().stroke(LifeOSTokens.surface, lineWidth: 2))
            .position(x: centerX, y: centerY)
            .accessibilityHidden(true)
    }
}

private struct FitnessCoreSleepTrends: View {
    let trends: [FitnessSleepTrendCard]
    let selectedDate: Date
    let source: FitnessSourceState
    @State private var selectedRange: FitnessTrendRange = .seven

    private var enabledRanges: Set<FitnessTrendRange> {
        trends.reduce(into: Set<FitnessTrendRange>()) { result, card in
            result.formUnion(card.availableSeriesRanges)
        }
    }

    private var activeRange: FitnessTrendRange {
        if enabledRanges.contains(selectedRange) { return selectedRange }
        return FitnessTrendRange.allCases.first(where: { enabledRanges.contains($0) }) ?? selectedRange
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sleep trends")
                        .font(LifeOSFont.header(15))
                    Text("\(selectedDate.fitnessDayLabel) · source history only")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                Spacer(minLength: 8)
                Menu {
                    ForEach(FitnessTrendRange.allCases) { range in
                        Button(range.title) { selectedRange = range }
                            .disabled(!enabledRanges.contains(range))
                    }
                } label: {
                    Label(enabledRanges.isEmpty ? "History unavailable" : activeRange.title, systemImage: "calendar")
                        .font(LifeOSFont.caption(10))
                }
                .menuStyle(.borderlessButton)
                .disabled(enabledRanges.count <= 1)
                .accessibilityLabel("Sleep trend range")
                .accessibilityValue(enabledRanges.isEmpty ? "History unavailable" : activeRange.title)
            }
            if source.status == .demo {
                Text("DEMO · NOT LIVE · trend values appear only when an explicit fixture card supplies them")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FitnessCoreColumns(minColumnWidth: 260) {
                ForEach(trends) { card in
                    FitnessCoreSleepTrendCard(card: card, selectedRange: activeRange)
                }
            }
        }
        .padding(13)
        .flatCard()
        .accessibilityIdentifier("fitness-sleep-trends")
    }
}

private struct FitnessCoreSleepTrendCard: View {
    let card: FitnessSleepTrendCard
    let selectedRange: FitnessTrendRange
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var hovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : LifeOSMotion.snappy) {
                isExpanded.toggle()
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    LifeOSIcon(card.id.icon)
                        .frame(width: 16, height: 16)
                        .foregroundStyle(card.metric.isValueAvailable ? LifeOSTokens.accent : fitnessMetricStateColor(card.metric.sourceState))
                    Text(card.id.title)
                        .font(LifeOSFont.inter(12, weight: .medium))
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(card.metric.value ?? "No data")
                        .font(LifeOSFont.spaceGrotesk(24, weight: .bold))
                        .monospacedDigit()
                    if card.metric.value != nil, !card.metric.unit.isEmpty {
                        Text(card.metric.unit)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                }
                if let selectedSeries, !selectedSeries.isEmpty {
                    FitnessCoreSparkline(values: selectedSeries)
                    if FitnessTrendSeries(values: selectedSeries) != nil {
                        Text(sourceContext(selectedSeries))
                            .font(LifeOSFont.caption(9))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .monospacedDigit()
                    }
                    Text("\(selectedRange.title) source history")
                        .font(LifeOSFont.inter(10, weight: .medium))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                } else {
                    Text(card.metric.isValueAvailable
                         ? "\(card.metric.sourceState.label) · trend unavailable"
                         : "\(card.metric.sourceState.label) · no trend available")
                        .font(LifeOSFont.inter(10, weight: .semiBold))
                        .foregroundStyle(fitnessMetricStateColor(card.metric.sourceState))
                }
                if isExpanded {
                    FitnessCoreSleepTrendEvidenceDetail(card: card)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LifeOSTokens.screenCanvas.opacity(hovering || isExpanded || isFocused ? 0.72 : 0.38),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(hovering || isExpanded || isFocused ? LifeOSTokens.accent.opacity(0.44) : LifeOSTokens.hairlineBorder, lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
#if os(macOS)
        .focusable(true)
        .focused($isFocused)
        .onHover { hovering = $0 }
        .help("Show \(card.id.title) unit, source, freshness, and available history")
#endif
        .accessibilityElement(children: .contain)
        .accessibilityLabel(card.id.title)
        .accessibilityValue("\(card.metric.value ?? "Not available") \(card.metric.unit). \(card.metric.sourceState.label). \(card.evidence.summary). \(isExpanded ? "Details shown" : "Details hidden")")
        .accessibilityHint("Shows source, freshness, and available history")
    }

    private var selectedSeries: [Double]? { card.series(for: selectedRange) }

    private func sourceContext(_ values: [Double]) -> String {
        guard let series = FitnessTrendSeries(values: values) else { return "Source history unavailable" }
        switch card.id {
        case .timeInBed, .duration, .rem, .deep, .core, .awake, .sleepBalance:
            return "Range \(minutesLabel(series.minimum))–\(minutesLabel(series.maximum)) · Δ \(signedMinutes(series.delta))"
        case .wakeTime, .sleepOnset:
            return "Range \(clockLabel(series.minimum))–\(clockLabel(series.maximum)) · Δ \(signedMinutes(series.delta))"
        default:
            return series.context(unit: card.metric.unit)
        }
    }

    private func minutesLabel(_ value: Double) -> String {
        let total = Int(value.rounded())
        let magnitude = abs(total)
        guard magnitude >= 60 else { return "\(total)m" }
        return "\(total < 0 ? "−" : "")\(magnitude / 60)h \(magnitude % 60)m"
    }

    private func signedMinutes(_ value: Double) -> String {
        let total = Int(value.rounded())
        if total == 0 { return "0m" }
        return "\(total > 0 ? "+" : "−")\(minutesLabel(Double(abs(total))))"
    }

    private func clockLabel(_ value: Double) -> String {
        let total = ((Int(value.rounded()) % 1_440) + 1_440) % 1_440
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

private struct FitnessCoreSleepTrendEvidenceDetail: View {
    let card: FitnessSleepTrendCard

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Trend detail")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(card.metric.isValueAvailable ? "Unit · \(card.metric.unit.isEmpty ? "not specified" : card.metric.unit)" : "\(card.metric.sourceState.label) · \(card.metric.detail)")
                .font(LifeOSFont.caption(10))
                .fixedSize(horizontal: false, vertical: true)
            Text(card.availableSeriesRanges.isEmpty
                 ? "History ranges · insufficient source history"
                 : "History ranges · \(card.availableSeriesRanges.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", "))")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
            Text(card.evidence.summary)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(9)
        .background(LifeOSTokens.surface.opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct FitnessCoreTrendCard: View {
    let title: String
    let metric: FitnessMetric
    let source: FitnessSourceState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(LifeOSFont.inter(12, weight: .medium))
                Spacer(minLength: 8)
                Text(metric.value ?? "No data")
                    .font(LifeOSFont.inter(12, weight: .semiBold))
                        .foregroundStyle(metric.isValueAvailable ? .primary : fitnessMetricStateColor(metric.sourceState))
            }
            if !metric.trend.isEmpty {
                FitnessCoreSparkline(values: metric.trend)
            }
            Text(!metric.isValueAvailable
                 ? metric.detail
                 : metric.trend.isEmpty ? "\(metric.sourceState.label) value · trend unavailable" : "\(metric.sourceState.label) trend · \(source.freshness)")
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(metric.value.map { "\($0) \(metric.unit). \(metric.sourceState.label)" } ?? "No data. \(metric.sourceState.label). \(metric.detail)")
    }
}

private struct FitnessCoreSourceCopyCard: View {
    let title: String
    let copy: FitnessSourceCopy

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(title).font(LifeOSFont.header(14))
                switch copy.state {
                case .unavailable(let reason):
                    Text("No data")
                        .font(LifeOSFont.inter(13, weight: .semiBold))
                    Text(reason)
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                case .observed(let text, let window, let provenance), .demo(let text, let window, let provenance):
                    Text(text)
                        .font(LifeOSFont.body(12))
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(window) · \(provenance)")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
    }
}

private struct FitnessCoreCopyRow: View {
    let title: String
    let copy: FitnessSourceCopy

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text(title)
                .font(LifeOSFont.caption(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Spacer(minLength: 8)
            switch copy.state {
            case .unavailable(let reason):
                Text("Unavailable · \(reason)")
                    .font(LifeOSFont.inter(11, weight: .medium))
                    .multilineTextAlignment(.trailing)
            case .observed(let text, _, _), .demo(let text, _, _):
                Text(text)
                    .font(LifeOSFont.inter(11, weight: .medium))
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}

private struct FitnessCoreDetailHero: View {
    let metric: FitnessMetric
    let route: FitnessCoreRoute

    var body: some View {
        FitnessCard {
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(route.title)
                        .font(LifeOSFont.header(18))
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(metric.value ?? "—")
                            .font(LifeOSFont.spaceGrotesk(43, weight: .bold))
                            .monospacedDigit()
                        if metric.value != nil, !metric.unit.isEmpty {
                            Text(metric.unit)
                                .font(LifeOSFont.caption(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    FitnessCoreProvenance(metric: metric)
                }
                Spacer(minLength: 0)
                if let progress = metric.progress, metric.isValueAvailable {
                    FitnessRing(progress: progress, hue: metric.hue, size: 112, color: FitnessRingPalette.color(route: route, progress: progress))
                        .accessibilityHidden(true)
                } else {
                    FitnessCoreUnavailableMark(size: 66)
                }
            }
        }
    }
}

private struct FitnessCoreAvailabilityNote: View {
    let metric: FitnessMetric
    let source: FitnessSourceState
    let onSourceTap: () -> Void

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(metric.isValueAvailable ? "Source and freshness" : "Why this is unavailable")
                    .font(LifeOSFont.header(14))
                Text(!metric.isValueAvailable
                     ? "LifeOS does not substitute zero or a guessed score. Connect the reviewed sensor chain and grant only the HealthKit categories you want to use."
                     : "\(metric.sourceState.label) · \(source.title) · \(source.freshness)")
                    .font(LifeOSFont.body(12))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Review source and permissions", action: onSourceTap)
                    .font(LifeOSFont.inter(11, weight: .semiBold))
                    .buttonStyle(.bordered)
                    .tint(LifeOSTokens.accent)
            }
        }
    }
}

private struct FitnessCoreDetailRows: View {
    let title: String
    let rows: [(String, String)]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(LifeOSFont.header(14))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(row.0)
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                        Spacer(minLength: 8)
                        Text(row.1)
                            .font(LifeOSFont.inter(11, weight: .medium))
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if row.0 != rows.last?.0 {
                        Divider().opacity(0.55)
                    }
                }
            }
        }
    }
}

private struct FitnessCoreTrendDetail: View {
    let metric: FitnessMetric
    let title: String

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(LifeOSFont.header(14))
                if metric.trend.isEmpty {
                    FitnessEmptyRow(title: "Trend unavailable", detail: "A trend needs source samples across a named window. Missing days are not converted to zero.", icon: .more)
                } else {
                    FitnessCoreSparkline(values: metric.trend)
                    Text("Observed window · source samples are shown as supplied")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
    }
}

/// Maps a horizontal chart location to one aggregate bucket. Keeping this
/// small, deterministic model separate makes the app-only scrub behavior
/// testable without exposing raw source samples to widgets.
struct FitnessStressScrubModel {
    static func index(locationX: CGFloat, width: CGFloat, bucketCount: Int) -> Int {
        guard bucketCount > 1, width > 0 else { return 0 }
        let normalized = min(1, max(0, locationX / width))
        return min(bucketCount - 1, max(0, Int((normalized * CGFloat(bucketCount - 1)).rounded())))
    }
}

private struct FitnessCoreStressScrubDetail: View {
    let metric: FitnessMetric
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedIndex: Int
    @FocusState private var chartIsFocused: Bool

    init(metric: FitnessMetric) {
        self.metric = metric
        _selectedIndex = State(initialValue: max(0, metric.trend.count - 1))
    }

    private var selectedValue: Int {
        guard metric.trend.indices.contains(selectedIndex) else { return 0 }
        return Int((metric.trend[selectedIndex] * 100).rounded())
    }

    private var selectedTime: String {
        guard metric.trend.count > 1 else { return "Selected point" }
        let hour = (12 + Int((Double(selectedIndex) / Double(metric.trend.count - 1) * 18).rounded())) % 24
        return String(format: "%02d:00", hour)
    }

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Daily stress trend").font(LifeOSFont.header(14))
                if metric.trend.isEmpty {
                    FitnessEmptyRow(title: "Trend unavailable", detail: "A trend needs source samples across a named window. Missing days are not converted to zero.", icon: .more)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("\(selectedValue)")
                            .font(LifeOSFont.spaceGrotesk(25, weight: .bold))
                            .monospacedDigit()
                        Text("/100 · \(selectedTime)")
                            .font(LifeOSFont.caption(11))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    FitnessCoreStressScrubChart(
                        values: metric.trend,
                        selectedIndex: $selectedIndex,
                        hue: metric.hue,
                        isFocused: chartIsFocused
                    )
#if os(macOS)
                    Text("Hover or focus the chart; arrow keys move the selected bucket")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
#else
                    Text("Drag to scrub aggregate buckets")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
#endif
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Daily stress trend")
            .accessibilityValue("\(selectedValue) out of 100 at \(selectedTime)")
            .accessibilityAdjustableAction { direction in
                guard !metric.trend.isEmpty else { return }
                switch direction {
                case .increment:
                    selectedIndex = min(metric.trend.count - 1, selectedIndex + 1)
                case .decrement:
                    selectedIndex = max(0, selectedIndex - 1)
                @unknown default:
                    break
                }
            }
#if os(macOS)
            .focused($chartIsFocused)
            .focusable(true)
            .onMoveCommand { direction in
                guard !metric.trend.isEmpty else { return }
                switch direction {
                case .left:
                    selectedIndex = max(0, selectedIndex - 1)
                case .right:
                    selectedIndex = min(metric.trend.count - 1, selectedIndex + 1)
                default:
                    break
                }
            }
#else
            .focused($chartIsFocused)
#endif
            .animation(reduceMotion ? nil : LifeOSMotion.snappy, value: selectedIndex)
        }
        .accessibilityIdentifier("fitness-stress-scrub-detail")
    }
}

private struct FitnessCoreStressScrubChart: View {
    let values: [Double]
    @Binding var selectedIndex: Int
    let hue: LifeOSTokens.Hue
    let isFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                Path { path in
                    guard values.count > 1 else { return }
                    for (index, value) in values.enumerated() {
                        let x = proxy.size.width * CGFloat(index) / CGFloat(values.count - 1)
                        let y = proxy.size.height * CGFloat(1 - min(max(value, 0), 1))
                        if index == 0 { path.move(to: CGPoint(x: x, y: y)) }
                        else { path.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                if values.indices.contains(selectedIndex) {
                    let x = values.count > 1 ? proxy.size.width * CGFloat(selectedIndex) / CGFloat(values.count - 1) : 0
                    let y = proxy.size.height * CGFloat(1 - min(max(values[selectedIndex], 0), 1))
                    Path { path in
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                    }
                    .stroke(LifeOSTokens.tertiaryText.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    Circle()
                        .fill(LifeOSTokens.accent)
                        .frame(width: 10, height: 10)
                        .offset(x: x - 5, y: y - 5)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                selectedIndex = FitnessStressScrubModel.index(
                    locationX: value.location.x,
                    width: proxy.size.width,
                    bucketCount: values.count
                )
            })
#if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                if case .active(let location) = phase {
                    selectedIndex = FitnessStressScrubModel.index(
                        locationX: location.x,
                        width: proxy.size.width,
                        bucketCount: values.count
                    )
                }
            }
#endif
        }
        .frame(height: 88)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(isFocused ? LifeOSTokens.strongBorder : .clear, lineWidth: 1)
        )
        .accessibilityHidden(true)
    }
}

private struct FitnessCoreWorkoutList: View {
    let workouts: [FitnessWorkout]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                Text("Workout timeline").font(LifeOSFont.header(14))
                if workouts.isEmpty {
                    FitnessEmptyRow(title: "No workouts", detail: "No source workout records are available for this date.", icon: .fitness)
                } else {
                    ForEach(workouts) { workout in
                        NavigationLink(value: FitnessCoreRoute.workout(workout.id)) {
                            FitnessWorkoutRow(workout: workout, showsDisclosure: true)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct FitnessCoreWorkoutDetail: View {
    let workout: FitnessWorkout?
    let source: FitnessSourceState

    var body: some View {
        if let workout {
            VStack(alignment: .leading, spacing: 14) {
                FitnessCard {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(LifeOSTokens.raised)
                                .frame(width: 42, height: 42)
                                .overlay(LifeOSIcon(.fitness).foregroundStyle(LifeOSTokens.secondaryText).frame(width: 19, height: 19))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(workout.name).font(LifeOSFont.header(17))
                                Text(workout.kind).font(LifeOSFont.caption(11)).foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                        }
                        FitnessCoreDetailRows(title: "Observed workout", rows: [
                            ("Started", workout.time.fitnessTimeLabel),
                            ("Duration", workout.duration),
                            ("Source detail", workout.detail),
                            ("Source status", "\(source.title) · \(source.freshness)")
                        ])
                    }
                }
                FitnessCoreSourceCopyCard(title: "Workout data boundary", copy: FitnessSourceCopy(state: .observed(
                    text: "Workout rows are source records. Load, energy, zones, and sets are shown only when that record supplies them.",
                    window: source.freshness,
                    provenance: source.title
                )))
            }
        } else {
            FitnessEmptyRow(title: "Workout unavailable", detail: "This workout record is no longer present in the selected snapshot.", icon: .fitness)
        }
    }
}

private struct FitnessCoreHealthDetail: View {
    let metrics: [FitnessMetric]
    let source: FitnessSourceState

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Independent observations").font(LifeOSFont.header(14))
                ForEach(metrics) { metric in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Circle()
                            .fill(fitnessMetricStateColor(metric.sourceState))
                            .frame(width: 7, height: 7)
                        Text(metric.title).font(LifeOSFont.inter(12, weight: .medium))
                        Spacer(minLength: 8)
                        Text(metric.value.map { "\($0) \(metric.unit)" } ?? metric.sourceState.label)
                            .font(LifeOSFont.inter(12, weight: .semiBold))
                            .multilineTextAlignment(.trailing)
                    }
                    Text(!metric.isValueAvailable ? "\(metric.sourceState.label) · \(metric.detail)" : "\(metric.sourceState.label) · \(source.freshness)")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .padding(.leading, 17)
                }
            }
        }
    }
}

struct FitnessSectionHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Capsule()
                .fill(LifeOSTokens.Module.fitness)
                .frame(width: 3, height: 27)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(LifeOSFont.sectionTitle())
                Text(subtitle)
                    .font(LifeOSFont.metadata())
                    .foregroundStyle(LifeOSTokens.secondaryText)
            }
        }
        .padding(.bottom, 2)
    }
}

private struct FitnessSourceGateCard: View {
    let source: FitnessSourceState
    let onSourceTap: () -> Void

    private var title: String {
        switch source.status {
        case .unavailable: "Health source unavailable"
        case .stale: "Health source is stale"
        case .permissionRequired: "Health permissions needed"
        case .connected: "Health source connected"
        case .demo: "Demo health source"
        }
    }

    private var summary: String {
        switch source.status {
        case .unavailable:
            "No readings are substituted or estimated here."
        case .stale:
            "Existing values remain labelled stale until a newer source observation arrives."
        case .permissionRequired:
            "Grant only the HealthKit categories you want LifeOS to read."
        case .connected:
            "Source metadata is available for the selected snapshot."
        case .demo:
            "Fixture-only values are not live health data."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(LifeOSTokens.accent.opacity(0.13))
                    LifeOSIcon(.health).foregroundStyle(LifeOSTokens.accent).padding(9)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(LifeOSFont.header(15))
                    Text(summary)
                        .font(LifeOSFont.caption(11))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            Text("The sensor authority is the Helio Strap. Zepp and Apple Health transport its samples to HealthKit; HealthKit permission and source metadata are required before LifeOS can show a metric. Current source: \(source.title) · \(source.detail) · \(source.freshness).")
                .font(LifeOSFont.body(13))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Review source and permissions", action: onSourceTap)
                .font(LifeOSFont.inter(12, weight: .semiBold))
                .buttonStyle(.borderedProminent)
                .tint(LifeOSTokens.accent)
                .accessibilityIdentifier("fitness-source-review")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .flatCard()
        .accessibilityElement(children: .contain)
        .accessibilityValue("\(source.status.label). \(summary) \(source.freshness)")
        .accessibilityIdentifier("fitness-health-source-gate")
    }
}

private struct FitnessMetricCard: View {
    let metric: FitnessMetric
    var emphasis = false

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(metric.title)
                            .font(LifeOSFont.metadata())
                            .foregroundStyle(LifeOSTokens.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(metric.value ?? "—")
                                .font(LifeOSFont.spaceGrotesk(emphasis ? 29 : 23, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(metric.isValueAvailable ? metric.hue.base : fitnessMetricStateColor(metric.sourceState))
                                .fixedSize(horizontal: true, vertical: false)
                            if metric.value != nil, !metric.unit.isEmpty {
                                Text(metric.unit)
                                    .font(LifeOSFont.metadata())
                                    .foregroundStyle(LifeOSTokens.secondaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .layoutPriority(1)
                    Spacer(minLength: 0)
                    if let progress = metric.progress, metric.isValueAvailable {
                        FitnessRing(progress: progress, hue: metric.hue, size: emphasis ? 52 : 42)
                    }
                }
                // Demo provenance is already stated once in the source chip
                // and banner. Keep the card focused on the metric itself;
                // unavailable/observed records still explain their status.
                if metric.sourceState != .demo {
                    Text(metric.detail)
                        .font(LifeOSFont.metadata())
                        .foregroundStyle(metric.isValueAvailable ? LifeOSTokens.secondaryText : LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 6) {
                        // §4.2: the quality dot is a neutral marker; only a
                        // demo fixture earns the warning semantic.
                        let dotColor = fitnessMetricStateColor(metric.sourceState)
                        Circle().fill(dotColor).frame(width: 5, height: 5)
                        Text(metric.sourceState.label)
                            .font(LifeOSFont.inter(10, weight: .semiBold))
                            .foregroundStyle(dotColor)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.title)
        .accessibilityValue(metricAccessibilityValue)
    }

    private var metricAccessibilityValue: String {
        let value = metric.value ?? "Not available"
        let unit = metric.unit.isEmpty ? "" : " \(metric.unit)"
        return "\(value)\(unit). \(metric.sourceState.label). \(metric.provenanceSummary)"
    }
}

// MARK: - Journal

/// Explicit, deterministic journal observations for visual review only. The
/// production path has no automatic rows until a connector supplies these
/// fields with provenance; no Bevel threshold or formula is reproduced here.
enum FitnessJournalVisualFixtures {
    static func records(at date: Date) -> [FitnessJournalRecord] {
        let provenance = "DEMO · NOT LIVE · explicit fixture field"
        func record(
            _ id: String,
            _ title: String,
            _ emoji: String,
            _ section: FitnessJournalRecord.Section,
            source: FitnessJournalRecord.Source = .manual,
            state: FitnessJournalRecord.TagState = .unknown,
            quantity: Double? = nil,
            unit: String? = nil,
            observedValue: String? = nil,
            window: String? = nil,
            editable: Bool = true
        ) -> FitnessJournalRecord {
            FitnessJournalRecord(
                id: id,
                title: title,
                emoji: emoji,
                section: section,
                date: date,
                source: source,
                provenance: provenance,
                tagState: state,
                quantity: quantity,
                unit: unit,
                observedValue: observedValue,
                window: window ?? (section == .automatic ? "Selected day" : nil),
                editable: editable
            )
        }

        return [
            record("fixture-mood", "Daily mood", "😊", .pinned),
            record("fixture-alcohol", "Alcohol", "🍷", .day, quantity: 0, unit: "ml"),
            record("fixture-hydration", "Hydration", "💧", .day, quantity: 1_250, unit: "ml"),
            record("fixture-ketogenic", "Ketogenic", "🥑", .day, state: .yes),
            record("fixture-caffeine", "Caffeine", "☕️", .day, quantity: 180, unit: "mg"),
            record("fixture-low-carb", "Low carb", "🥖", .day, state: .unknown),
            record("fixture-sugar", "Added sugar", "🍬", .day, state: .no),
            record("fixture-device", "Device in bed", "📱", .night, state: .no),
            record("fixture-late-meal", "Late meal", "🍽️", .night, state: .unknown),
            record("fixture-steps", "10,000+ steps", "👟", .automatic, source: .derived, state: .yes, observedValue: "10,482 steps", editable: false),
            record("fixture-cardio", "20+ minutes cardio", "🏃", .automatic, source: .derived, state: .no, observedValue: "12 min", editable: false),
            record("fixture-strength", "20+ minutes strength", "🏋️", .automatic, source: .derived, state: .yes, observedValue: "26 min", editable: false),
            record("fixture-daylight", "20+ minutes daylight", "☀️", .automatic, source: .unavailable, state: .unknown, editable: false),
            record("fixture-zone2", "30+ minutes Zone 2", "🟠", .automatic, source: .derived, state: .no, observedValue: "18 min", editable: false),
            record("fixture-noise", "50+ dB sleep noise", "🔊", .automatic, source: .unavailable, state: .unknown, editable: false),
            record("fixture-stress", "50+ stress value", "🔴", .automatic, source: .derived, state: .no, observedValue: "34", editable: false),
            record("fixture-nutrition", "67+ nutrition score", "🍎", .automatic, source: .unavailable, state: .unknown, editable: false),
            record("fixture-mindfulness", "Mindfulness session", "🧘", .automatic, source: .healthKit, state: .no, observedValue: "0 min", editable: false),
            record("fixture-sunrise", "Morning sunlight", "🌞", .automatic, source: .unavailable, state: .unknown, editable: false),
            record("fixture-nap", "Nap", "😴", .automatic, source: .unavailable, state: .unknown, editable: false)
        ]
    }
}

private struct FitnessJournalView: View {
    let snapshot: FitnessSnapshot
    @Binding var selectedDate: Date
    @ObservedObject var journalStore: FitnessJournalStore
    let onSourceTap: () -> Void
    @State private var sheet: FitnessJournalSheet?
    @State private var automaticDetail: FitnessJournalRecord?

    private let quickLogs: [(String, String, String)] = [
        ("Mood", "😊", "Manual context"),
        ("Hydration", "💧", "Quick amount"),
        ("Caffeine", "☕️", "Quick amount"),
        ("Alcohol", "🍷", "User-entered quantity"),
        ("Custom tag", "＋", "Personal context")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FitnessSectionHeading(title: "Journal", subtitle: "Facts and context for \(selectedDate.fitnessDayLabel)")
            FitnessJournalMonthCalendar(selectedDate: $selectedDate, store: journalStore)

            FitnessCard {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Quick log").font(LifeOSFont.header(15))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8)], spacing: 8) {
                        ForEach(quickLogs, id: \.0) { item in
                            Button { sheet = .new(seed: template(for: item.0)) } label: {
                                HStack(spacing: 7) {
                                    Text(item.1).font(.system(size: 18)).frame(width: 20, height: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.0).font(LifeOSFont.inter(12, weight: .semiBold))
                                        Text(item.2).font(LifeOSFont.inter(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .foregroundStyle(.primary)
                                .padding(10)
                                .background(LifeOSTokens.screenCanvas.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("fitness-journal-quick-\(item.0.lowercased().replacingOccurrences(of: " ", with: "-"))")
                        }
                    }
                    Text("Entries stay on this device until you choose a reviewed sync or source flow.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                    if let lastSaveError = journalStore.lastSaveError {
                        Text(lastSaveError)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.danger)
                    }
                    if let integrityWarning = journalStore.integrityWarning {
                        Text(integrityWarning)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.warning)
                    }
                }
            }

            if snapshot.source.status.needsReview {
                FitnessSourceGateCard(source: snapshot.source, onSourceTap: onSourceTap)
            }

            FitnessJournalGroup(title: "Pinned", records: records(in: .pinned), store: journalStore, onEdit: openEditor)
            FitnessJournalGroup(title: "Day", records: records(in: .day), store: journalStore, onEdit: openEditor)
            FitnessJournalGroup(title: "Night", records: records(in: .night), store: journalStore, onEdit: openEditor)
            FitnessJournalAutomaticGroup(records: records(in: .automatic)) { record in
                automaticDetail = record
            }

            FitnessCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Associations, not causation").font(LifeOSFont.header(14))
                    Text("Journal correlations can show dates that co-occur in your selected data. They do not establish that a food, supplement, sleep event, or activity caused a health change.")
                        .font(LifeOSFont.body(12)).foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .sheet(item: $sheet) { item in
            FitnessJournalEditor(seed: item.seed, selectedDate: selectedDate) { record in
                journalStore.upsert(record)
            }
        }
        .sheet(item: $automaticDetail) { record in
            FitnessJournalAutomaticDetail(record: record)
        }
    }

    private func openEditor(_ record: FitnessJournalRecord) {
        guard record.editable else { return }
        sheet = .edit(seed: record)
    }

    private func records(in section: FitnessJournalRecord.Section) -> [FitnessJournalRecord] {
        let saved = journalStore.records(on: selectedDate)
        let templates = templatesForSelectedDate().filter { $0.section == section }
        let resolved = templates.map { template in
            saved.first(where: { $0.id == template.id })
                ?? saved.first(where: { $0.title == template.title && $0.section == template.section })
                ?? template
        }
        let knownTitles = Set(templates.map(\.title))
        let extras = saved.filter { $0.section == section && !knownTitles.contains($0.title) }
        return (resolved + extras).sorted { $0.title < $1.title }
    }

    private func templatesForSelectedDate() -> [FitnessJournalRecord] {
        let key = selectedDate.fitnessJournalDateKey
        func template(_ suffix: String, _ title: String, _ emoji: String, _ section: FitnessJournalRecord.Section, unit: String? = nil) -> FitnessJournalRecord {
            FitnessJournalRecord(id: "template-\(key)-\(suffix)", title: title, emoji: emoji, section: section, date: selectedDate, source: .manual, provenance: "Manual · not recorded", unit: unit)
        }
        return [
            template("mood", "Daily mood", "😊", .pinned),
            template("alcohol", "Alcohol", "🍷", .day, unit: "ml"),
            template("hydration", "Hydration", "💧", .day, unit: "ml"),
            template("ketogenic", "Ketogenic", "🥑", .day),
            template("caffeine", "Caffeine", "☕️", .day, unit: "mg"),
            template("low-carb", "Low carb", "🥖", .day),
            template("added-sugar", "Added sugar", "🍬", .day),
            template("device", "Device in bed", "📱", .night),
            template("late-meal", "Late meal", "🍽️", .night)
        ]
    }

    private func template(for title: String) -> FitnessJournalRecord {
        let section: FitnessJournalRecord.Section = title == "Mood" ? .pinned : .day
        let normalizedTitle = title == "Mood" ? "Daily mood" : title
        if let existing = records(in: section).first(where: { $0.title.caseInsensitiveCompare(normalizedTitle) == .orderedSame }) { return existing }
        let unit: String? = switch title {
        case "Hydration", "Alcohol": "ml"
        case "Caffeine": "mg"
        default: nil
        }
        let emoji = quickLogs.first(where: { $0.0 == title })?.1 ?? "🏷️"
        return FitnessJournalRecord(id: "new-\(UUID().uuidString)", title: normalizedTitle, emoji: emoji, section: section, date: selectedDate, source: .manual, provenance: "Local journal · user entered", unit: unit)
    }
}

private enum FitnessJournalSheet: Identifiable {
    case new(seed: FitnessJournalRecord)
    case edit(seed: FitnessJournalRecord)
    var id: String {
        switch self {
        case .new(let seed): "new-\(seed.id)"
        case .edit(let seed): "edit-\(seed.id)"
        }
    }
    var seed: FitnessJournalRecord {
        switch self {
        case .new(let seed), .edit(let seed): seed
        }
    }
}

private struct FitnessJournalGroup: View {
    let title: String
    let records: [FitnessJournalRecord]
    @ObservedObject var store: FitnessJournalStore
    let onEdit: (FitnessJournalRecord) -> Void
    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(LifeOSFont.header(15)).foregroundStyle(.secondary)
                if records.isEmpty {
                    FitnessEmptyRow(title: "No entries", detail: "A blank day is not the same as zero consumption or zero stress.", icon: .more)
                } else {
                    ForEach(records) { record in
                        FitnessJournalRow(record: record, store: store, onEdit: onEdit, onAutomaticDetail: nil)
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-journal-group-\(title.lowercased())")
    }
}

private struct FitnessJournalAutomaticGroup: View {
    let records: [FitnessJournalRecord]
    let onDetail: (FitnessJournalRecord) -> Void
    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Automatic").font(LifeOSFont.header(15)).foregroundStyle(.secondary)
                    Spacer()
                    Text("Observed / derived only").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if records.isEmpty {
                    FitnessEmptyRow(title: "No automatic observations", detail: "Connect HealthKit or an approved importer. LifeOS does not reproduce thresholds or fill this section with guesses.", icon: .health)
                } else {
                    ForEach(records) { record in
                        FitnessJournalRow(record: record, store: nil, onEdit: nil, onAutomaticDetail: onDetail)
                    }
                }
            }
        }
        .accessibilityIdentifier("fitness-journal-group-automatic")
    }
}

private struct FitnessJournalRow: View {
    let record: FitnessJournalRecord
    let store: FitnessJournalStore?
    let onEdit: ((FitnessJournalRecord) -> Void)?
    let onAutomaticDetail: ((FitnessJournalRecord) -> Void)?
    var body: some View {
        HStack(spacing: 10) {
            Text(record.emoji).font(.system(size: 22)).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title).font(LifeOSFont.inter(13, weight: .medium))
                Text(provenanceLabel).font(LifeOSFont.caption(9)).foregroundStyle(LifeOSTokens.tertiaryText).lineLimit(1)
            }
            Spacer()
            if let quantity = record.quantity, let unit = record.unit {
                Button { onEdit?(record) } label: {
                    Text("\(quantity.formatted(.number.precision(.fractionLength(0...1)))) \(unit)").font(LifeOSFont.inter(12, weight: .semiBold)).foregroundStyle(.primary)
                }.buttonStyle(.plain)
            } else if record.unit != nil {
                Button { onEdit?(record) } label: {
                    Text("— \(record.unit ?? "")").font(LifeOSFont.inter(12, weight: .semiBold)).foregroundStyle(LifeOSTokens.tertiaryText)
                }.buttonStyle(.plain)
            } else if record.isAutomaticObservation {
                if record.source == .unavailable || record.observedValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                    Text("Unavailable").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                } else if let observedValue = record.observedValue {
                    Text(observedValue).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                    FitnessJournalStatusMark(state: record.tagState, automatic: true)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            } else {
                FitnessJournalTriState(record: record, store: store, onEdit: onEdit)
            }
        }
        .padding(.vertical, 9).padding(.horizontal, 10)
        .background(LinearGradient(colors: [LifeOSTokens.screenCanvas.opacity(0.78), LifeOSTokens.surface.opacity(0.58)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .contentShape(Rectangle())
        .onTapGesture {
            if record.isAutomaticObservation {
                onAutomaticDetail?(record)
            } else {
                onEdit?(record)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(record.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(record.isAutomaticObservation ? "Opens read-only observation details" : "Opens manual journal entry")
        .accessibilityAddTraits(record.isAutomaticObservation ? .isButton : [])
        .accessibilityAction {
            if record.isAutomaticObservation {
                onAutomaticDetail?(record)
            } else {
                onEdit?(record)
            }
        }
        .accessibilityIdentifier("fitness-journal-row-\(record.id)")
    }
    private var accessibilityValue: String {
        let window = record.window.map { " \($0)." } ?? ""
        if let quantity = record.quantity, let unit = record.unit { return "\(quantity) \(unit). \(record.source.label).\(window)" }
        if record.isAutomaticObservation { return "\(record.tagState.label). \(record.observedValue ?? "No explicit value"). \(record.source.label).\(window)" }
        return "\(record.tagState.label). \(record.source.label)."
    }

    private var provenanceLabel: String {
        if let window = record.window { return "\(record.source.label) · \(window) · \(record.provenance)" }
        return "\(record.source.label) · \(record.provenance)"
    }
}

private struct FitnessJournalMonthCalendar: View {
    @Binding var selectedDate: Date
    let store: FitnessJournalStore
    @State private var visibleMonth: Date

    private let model = FitnessJournalCalendarModel()

    init(selectedDate: Binding<Date>, store: FitnessJournalStore) {
        _selectedDate = selectedDate
        self.store = store
        _visibleMonth = State(initialValue: FitnessJournalCalendarModel().monthStart(for: selectedDate.wrappedValue))
    }

    private var monthStart: Date { model.monthStart(for: visibleMonth) }
    private var canGoPrevious: Bool { model.canMoveMonth(from: monthStart, by: -1) }
    private var canGoNext: Bool { model.canMoveMonth(from: monthStart, by: 1) }

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text(monthStart.formatted(.dateTime.month(.wide).year()))
                        .font(LifeOSFont.header(16))
                    Spacer(minLength: 0)
                    Button {
                        moveMonth(by: -1)
                    } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoPrevious)
                    .accessibilityLabel("Previous month")
                    .accessibilityIdentifier("fitness-journal-month-previous")
                    Button {
                        moveMonth(by: 1)
                    } label: {
                        Image(systemName: "chevron.right")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canGoNext)
                    .accessibilityLabel("Next month")
                    .accessibilityIdentifier("fitness-journal-month-next")
                }

                HStack(spacing: 0) {
                    ForEach(weekdaySymbols, id: \.self) { symbol in
                        Text(symbol)
                            .font(LifeOSFont.inter(10, weight: .semiBold))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                            .frame(maxWidth: .infinity)
                    }
                }

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                    ForEach(Array(model.cells(in: monthStart).enumerated()), id: \.offset) { _, date in
                        if let date {
                            dayButton(for: date)
                        } else {
                            Color.clear.frame(height: 34)
                                .accessibilityHidden(true)
                        }
                    }
                }
                Text("Green checks mark manual entries only.")
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .onChange(of: selectedDate) { _, newDate in
            let newMonth = model.monthStart(for: newDate)
            if newMonth != monthStart { visibleMonth = newMonth }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fitness-journal-month-calendar")
    }

    private var weekdaySymbols: [String] {
        let symbols = model.calendar.shortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let first = max(0, min(6, model.calendar.firstWeekday - 1))
        return Array(symbols[first...]) + Array(symbols[..<first])
    }

    @ViewBuilder
    private func dayButton(for date: Date) -> some View {
        let selected = model.calendar.isDate(date, inSameDayAs: selectedDate)
        let completed = store.hasEntries(on: date)
        let selectable = model.isSelectable(date)
        Button {
            guard selectable else { return }
            selectedDate = date
        } label: {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.day()))
                    .font(LifeOSFont.inter(12, weight: selected ? .bold : .medium))
                    .foregroundStyle(selectable ? (selected ? LifeOSTokens.accent : Color.primary) : LifeOSTokens.tertiaryText.opacity(0.45))
                Circle()
                    .fill(completed ? LifeOSTokens.success : .clear)
                    .overlay {
                        Circle().stroke(completed ? LifeOSTokens.success : LifeOSTokens.quietBorder, lineWidth: 1.2)
                        if completed {
                            Text("✓").font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 34)
            .background(selected ? LifeOSTokens.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!selectable)
        .accessibilityLabel(date.fitnessJournalAccessibilityDate)
        .accessibilityValue(completed ? "Completed with manual entry" : "No manual entries")
        .accessibilityIdentifier("fitness-journal-day-\(date.fitnessJournalDateKey)")
    }

    private func moveMonth(by value: Int) {
        guard model.canMoveMonth(from: monthStart, by: value) else { return }
        visibleMonth = model.month(byAdding: value, to: monthStart)
    }
}

private struct FitnessJournalAutomaticDetail: View {
    let record: FitnessJournalRecord
    @Environment(\.dismiss) private var dismiss

    private var status: String {
        guard record.source != .unavailable, record.observedValue?.isEmpty == false else { return "Unavailable" }
        return record.tagState.label
    }

    private var observedValue: String {
        record.observedValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? record.observedValue!
            : "No explicit observed value"
    }

    private var unavailableReason: String? {
        guard status == "Unavailable" else { return nil }
        if record.source == .unavailable { return record.provenance }
        return "The source did not provide an explicit sample; no threshold status was inferred."
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        Text(record.emoji).font(.system(size: 28))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(record.title).font(LifeOSFont.header(18))
                            Text("Automatic observation · read-only")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                    FitnessCard {
                        VStack(alignment: .leading, spacing: 10) {
                            FitnessJournalDetailField(title: "Status", value: status)
                            FitnessJournalDetailField(title: "Observed value", value: observedValue)
                            FitnessJournalDetailField(title: "Source", value: record.source.label)
                            FitnessJournalDetailField(title: "Window", value: record.window ?? "No named window")
                            FitnessJournalDetailField(title: "Provenance", value: record.provenance)
                            if let unavailableReason {
                                Divider()
                                FitnessJournalDetailField(title: "Why unavailable", value: unavailableReason)
                            }
                        }
                    }
                    Text("LifeOS displays the importer’s explicit observation and does not infer completion, a threshold, or a zero value from missing samples.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 8)
            }
            .padding(.horizontal, 16)
            .navigationTitle("Observation details")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("fitness-journal-automatic-detail")
    }
}

private struct FitnessJournalDetailField: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(LifeOSFont.caption(9))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(value)
                .font(LifeOSFont.body(13))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct FitnessJournalTriState: View {
    let record: FitnessJournalRecord
    let store: FitnessJournalStore?
    let onEdit: ((FitnessJournalRecord) -> Void)?

    var body: some View {
        HStack(spacing: 2) {
            ForEach(FitnessJournalRecord.TagState.allCases, id: \.self) { state in
                Button {
                    if store?.record(id: record.id) == nil {
                        var seeded = record
                        seeded.tagState = state
                        store?.upsert(seeded)
                    } else {
                        store?.setTagState(state, for: record.id)
                    }
                } label: {
                    Text(symbol(for: state))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(record.tagState == state ? color(for: state) : LifeOSTokens.tertiaryText.opacity(0.62))
                        .frame(width: 28, height: 28)
                        .background(record.tagState == state ? color(for: state).opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(state.label)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .onTapGesture { onEdit?(record) }
    }

    private func symbol(for state: FitnessJournalRecord.TagState) -> String {
        switch state {
        case .yes: "✓"
        case .no: "×"
        case .unknown: "—"
        }
    }

    private func color(for state: FitnessJournalRecord.TagState) -> Color {
        switch state {
        case .yes: LifeOSTokens.success
        case .no: LifeOSTokens.danger
        case .unknown: LifeOSTokens.tertiaryText
        }
    }
}

private struct FitnessJournalStatusMark: View {
    let state: FitnessJournalRecord.TagState
    let automatic: Bool

    var body: some View {
        Text(symbol)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(color)
            .frame(width: 27, height: 27)
            .background(color.opacity(0.12), in: Circle())
            .overlay(Circle().stroke(color.opacity(0.36), lineWidth: 0.75))
            .accessibilityLabel("\(state.label)\(automatic ? ", automatic observation" : "")")
    }

    private var symbol: String {
        switch state {
        case .yes: "✓"
        case .no: "×"
        case .unknown: "—"
        }
    }

    private var color: Color {
        switch state {
        case .yes: LifeOSTokens.success
        case .no: LifeOSTokens.danger
        case .unknown: LifeOSTokens.tertiaryText
        }
    }
}

private struct FitnessJournalEditor: View {
    let seed: FitnessJournalRecord
    let selectedDate: Date
    let onSave: (FitnessJournalRecord) -> Bool
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var quantity: String
    @State private var tagState: FitnessJournalRecord.TagState
    @State private var saveError: String?

    init(seed: FitnessJournalRecord, selectedDate: Date, onSave: @escaping (FitnessJournalRecord) -> Bool) {
        self.seed = seed
        self.selectedDate = selectedDate
        self.onSave = onSave
        _title = State(initialValue: seed.title)
        _quantity = State(initialValue: seed.quantity.map { String($0) } ?? "")
        _tagState = State(initialValue: seed.tagState)
        _saveError = State(initialValue: nil)
    }

    private var isQuantity: Bool { seed.unit != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Entry") {
                    TextField("Name", text: $title)
                    Text("\(seed.emoji) · \(selectedDate.fitnessDayLabel)")
                        .font(LifeOSFont.caption(11)).foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if isQuantity {
                    Section("Amount") {
                        HStack {
                            TextField("Amount", text: $quantity)
#if os(iOS)
                                .keyboardType(.decimalPad)
#endif
                            Text(seed.unit ?? "")
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                } else {
                    Section("State") {
                        Picker("State", selection: $tagState) {
                            ForEach(FitnessJournalRecord.TagState.allCases, id: \.self) { state in
                                Text(state.label).tag(state)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
                if let saveError {
                    Text(saveError)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.danger)
                }
                Section("Source") {
                    Text("Manual · stored locally")
                        .font(LifeOSFont.caption(11)).foregroundStyle(LifeOSTokens.tertiaryText)
                    Text("No health value is inferred from an empty field.")
                        .font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            .navigationTitle(seed.id.hasPrefix("new-") ? "Add journal entry" : "Edit journal entry")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        var record = seed
                        record.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? seed.title : title.trimmingCharacters(in: .whitespacesAndNewlines)
                        record.date = selectedDate
                        record.source = .manual
                        record.provenance = "Local journal · user entered"
                        record.editable = true
                        if let unit = seed.unit {
                            let rawQuantity = quantity.trimmingCharacters(in: .whitespacesAndNewlines)
                            let parsedQuantity = rawQuantity.isEmpty ? nil : FitnessJournalQuantity.parse(rawQuantity)
                            if !rawQuantity.isEmpty && parsedQuantity == nil {
                                saveError = "Enter a number for the amount, or leave it empty."
                                return
                            }
                            record.unit = unit
                            record.quantity = parsedQuantity
                            record.quantityInput = rawQuantity.isEmpty ? nil : rawQuantity
                        } else {
                            record.quantity = nil
                            record.quantityInput = nil
                            record.tagState = tagState
                        }
                        if onSave(record) {
                            dismiss()
                        } else {
                            saveError = "Could not save locally. Check the journal storage and try again."
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Fitness activity

private enum FitnessActivityRoute: Hashable {
    case activitySummary
    case performanceTarget
    case strengthDetail
    case day(Date)
    case metric(String)

    var title: String {
        switch self {
        case .activitySummary: "Activity summary"
        case .performanceTarget: "Performance / load"
        case .strengthDetail: "Strength"
        case .day(let date): date.activityDayLabel
        case .metric(let id):
            switch id {
            case "cardio-load": "Cardio load"
            case "cardio-focus": "Cardio focus"
            case "heart-rate-recovery": "Heart-rate recovery"
            case "strength-volume": "Strength volume"
            default: "Fitness detail"
            }
        }
    }
}

private struct FitnessActivityView: View {
    let snapshot: FitnessSnapshot
    let selectedDate: Date
    let usesVisualFixtures: Bool
    let onSourceTap: () -> Void
    @State private var visibleMonth: Date
    @State private var selectedActivityDay: Date?

    init(snapshot: FitnessSnapshot, selectedDate: Date, usesVisualFixtures: Bool, onSourceTap: @escaping () -> Void) {
        self.snapshot = snapshot
        self.selectedDate = selectedDate
        self.usesVisualFixtures = usesVisualFixtures
        self.onSourceTap = onSourceTap
        _visibleMonth = State(initialValue: selectedDate)
        _selectedActivityDay = State(initialValue: selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FitnessSectionHeading(title: "Fitness", subtitle: "Last 30 days · activity and performance")
            if snapshot.source.status.needsReview {
                FitnessSourceGateCard(source: snapshot.source, onSourceTap: onSourceTap)
            }
#if os(macOS)
            // The Mac detail column can be much wider than the source data.
            // Keep the two primary charts in a deliberate reading grid so a
            // maximised window does not turn each signal into a long, empty
            // line. The iPhone keeps the original single-column reading order.
            FitnessActivityCalendarCard(
                snapshot: snapshot.activity,
                visibleMonth: $visibleMonth,
                selectedDay: $selectedActivityDay
            )
            FitnessCoreColumns(minColumnWidth: 480) {
                FitnessActivitySummaryCard(snapshot: snapshot.activity, selectedDate: selectedDate)
                FitnessPerformanceTargetCard(target: snapshot.activity.performanceTarget)
            }
#else
            FitnessActivityCalendarCard(
                snapshot: snapshot.activity,
                visibleMonth: $visibleMonth,
                selectedDay: $selectedActivityDay
            )
            FitnessActivitySummaryCard(snapshot: snapshot.activity, selectedDate: selectedDate)
            FitnessPerformanceTargetCard(target: snapshot.activity.performanceTarget)
#endif

            FitnessCoreSectionLabel(title: "Cardio", detail: "Source-backed training signals")
            FitnessCoreColumns(minColumnWidth: 210) {
                FitnessActivityMetricCard(route: .metric("cardio-load"), metric: snapshot.activity.cardioLoad)
                FitnessActivityMetricCard(route: .metric("cardio-focus"), metric: snapshot.activity.cardioFocus)
                FitnessActivityMetricCard(route: .metric("heart-rate-recovery"), metric: snapshot.activity.heartRateRecovery)
            }

            FitnessCoreSectionLabel(title: "Strength", detail: "Volume from explicit sets and load")
            FitnessActivityMetricCard(route: .strengthDetail, metric: snapshot.activity.strengthVolume)

            FitnessCard {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Workout records").font(LifeOSFont.header(14))
                    if snapshot.workouts.isEmpty {
                        FitnessEmptyRow(title: "No workouts", detail: "No source workout records are available for this window.", icon: .fitness)
                    } else {
                        ForEach(snapshot.workouts) { workout in
                            FitnessWorkoutRow(workout: workout)
                        }
                    }
                }
            }
            Text("\(selectedDate.fitnessDayLabel) is a context date. Values require a named source window; LifeOS does not reproduce proprietary load formulas.")
                .font(LifeOSFont.caption(11))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .navigationDestination(for: FitnessActivityRoute.self) { route in
            FitnessActivityDetailView(
                route: route,
                snapshot: snapshot.activity,
                strengthSnapshot: strengthSnapshotForDisplay,
                usesVisualFixtures: usesVisualFixtures,
                selectedDate: selectedDate,
                onSourceTap: onSourceTap
            )
        }
        .accessibilityIdentifier("fitness-activity-performance")
    }

    private var strengthSnapshotForDisplay: FitnessStrengthSnapshot {
        // A demo snapshot is safe only behind the explicit visual-fixture
        // launch path. A normal production route remains an honest empty.
        if snapshot.source.status == .demo && !usesVisualFixtures {
            return .init()
        }
        return snapshot.strength
    }
}

private struct FitnessActivityCalendarCard: View {
    let snapshot: FitnessActivitySnapshot
    @Binding var visibleMonth: Date
    @Binding var selectedDay: Date?

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Activity calendar").font(LifeOSFont.header(15))
                        Text("Last 30 days · two-month view")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 4) {
                        Button { moveMonth(by: -1) } label: {
                            LifeOSIcon(.chevronLeft).frame(width: 15, height: 15)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canMoveMonth(by: -1))
                        .accessibilityLabel("Previous activity month")
                        Button { moveMonth(by: 1) } label: {
                            LifeOSIcon(.chevronRight).frame(width: 15, height: 15)
                        }
                        .buttonStyle(.plain)
                        .disabled(!canMoveMonth(by: 1))
                        .accessibilityLabel("Next activity month")
                    }
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 15) {
                        monthGrid(for: previousMonth)
                        monthGrid(for: visibleMonth)
                    }
                    VStack(alignment: .leading, spacing: 14) {
                        monthGrid(for: previousMonth)
                        monthGrid(for: visibleMonth)
                    }
                }

                HStack(spacing: 13) {
                    legendItem(color: LifeOSTokens.success, text: "1")
                    legendItem(color: LifeOSTokens.info, text: "2")
                    legendItem(color: LifeOSTokens.accent, text: "3+")
                    Text("activities")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Activity legend: one, two, or three or more activities")
                Text(sourceCoverageLabel)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if snapshot.activityCalendarDays.isEmpty {
                    Text("Activity history unavailable · no source observations")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
        }
        .accessibilityIdentifier("fitness-activity-calendar")
    }

    private var previousMonth: Date {
        let base = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) ?? visibleMonth
        return calendar.date(byAdding: .month, value: -1, to: base) ?? base
    }

    private var sourceCoverageLabel: String {
        guard let first = snapshot.activityCalendarDays.map(\.date).min(),
              let last = snapshot.activityCalendarDays.map(\.date).max() else {
            return "Source window unavailable · months are not navigable"
        }
        return "Source coverage · \(first.activityDayLabel) – \(last.activityDayLabel)"
    }

    private func canMoveMonth(by value: Int) -> Bool {
        guard !snapshot.activityCalendarDays.isEmpty else { return false }
        let base = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) ?? visibleMonth
        let next = calendar.date(byAdding: .month, value: value, to: base) ?? base
        return snapshot.activityCalendarDays.contains {
            calendar.isDate($0.date, equalTo: next, toGranularity: .month)
        }
    }

    private func moveMonth(by value: Int) {
        guard canMoveMonth(by: value) else { return }
        let base = calendar.date(from: calendar.dateComponents([.year, .month], from: visibleMonth)) ?? visibleMonth
        let next = calendar.date(byAdding: .month, value: value, to: base) ?? base
        if LifeOSMotion.reduceMotion {
            visibleMonth = next
        } else {
            withAnimation(LifeOSMotion.snappy) { visibleMonth = next }
        }
    }

    @ViewBuilder
    private func monthGrid(for month: Date) -> some View {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: month)) ?? month
        let dayCount = calendar.range(of: .day, in: .month, for: monthStart)?.count ?? 30
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        let dates = (1...dayCount).compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: monthStart) }
        let symbols = calendar.shortStandaloneWeekdaySymbols
        let firstWeekdayIndex = max(0, min(symbols.count - 1, calendar.firstWeekday - 1))
        let daySymbols = Array(symbols[firstWeekdayIndex...] + symbols[..<firstWeekdayIndex])
        let leadingStart = daySymbols.count
        let datesStart = leadingStart + leading

        VStack(alignment: .leading, spacing: 7) {
            Text(monthStart.activityMonthLabel).font(LifeOSFont.inter(13, weight: .semiBold))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 5) {
                ForEach(daySymbols.indices, id: \.self) { index in
                    Text(String(daySymbols[index].prefix(1)))
                        .font(LifeOSFont.caption(9))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .frame(maxWidth: .infinity)
                }
                ForEach(leadingStart..<datesStart, id: \.self) { _ in
                    Color.clear.frame(height: 18)
                }
                ForEach(datesStart..<(datesStart + dates.count), id: \.self) { index in
                    activityDayButton(dates[index - datesStart])
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(monthStart.activityMonthLabel)
    }

    private func activityDayButton(_ date: Date) -> some View {
        let day = snapshot.activityCalendarDays.first(where: { calendar.isDate($0.date, inSameDayAs: date) })
        let selected = selectedDay.map { calendar.isDate($0, inSameDayAs: date) } ?? false
        return NavigationLink(value: FitnessActivityRoute.day(date)) {
            ZStack {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(activityColor(for: day))
                if day == nil {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            LifeOSTokens.tertiaryText.opacity(0.55),
                            style: StrokeStyle(lineWidth: 1, dash: [2, 2])
                        )
                }
                if selected {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(LifeOSTokens.accent, lineWidth: 1.5)
                }
            }
                .frame(height: 18)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded { selectedDay = date })
        .accessibilityLabel(activityAccessibilityLabel(for: date, day: day))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func activityColor(for day: FitnessActivityDay?) -> Color {
        guard let day else { return LifeOSTokens.quietBorder.opacity(0.10) }
        guard let count = day.activityCount else { return LifeOSTokens.quietBorder.opacity(0.18) }
        switch min(max(count, 0), 3) {
        case 1: return LifeOSTokens.success.opacity(0.72)
        case 2: return LifeOSTokens.info.opacity(0.78)
        case 3: return LifeOSTokens.accent.opacity(0.84)
        default: return LifeOSTokens.quietBorder.opacity(0.48)
        }
    }

    private func activityAccessibilityLabel(for date: Date, day: FitnessActivityDay?) -> String {
        guard let day else {
            return "\(date.activityDayLabel), activity unavailable · outside the named source window"
        }
        switch day.state {
        case .observed(let count, let window, let provenance):
            return "\(date.activityDayLabel), \(count) activities · observed · \(window) · \(provenance)"
        case .demo(let count, let window, let provenance):
            return "\(date.activityDayLabel), \(count) activities · demo fixture · \(window) · \(provenance)"
        case .unavailable(let reason, let window, let provenance):
            return "\(date.activityDayLabel), activity unavailable · \(reason) · \(window) · \(provenance)"
        }
    }

    private func legendItem(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(LifeOSFont.inter(10, weight: .medium))
        }
        .foregroundStyle(LifeOSTokens.tertiaryText)
    }
}

private struct FitnessActivitySummaryCard: View {
    let snapshot: FitnessActivitySnapshot
    let selectedDate: Date

    var body: some View {
        NavigationLink(value: FitnessActivityRoute.activitySummary) {
            FitnessCard {
                VStack(alignment: .leading, spacing: 11) {
                    FitnessActivityCardHeader(title: "Activity summary", icon: .fitness, accent: .orange)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(FitnessActivityMetricFormatter.value(snapshot.activityTotal))
                            .font(LifeOSFont.spaceGrotesk(31, weight: .bold))
                            .monospacedDigit()
                        Spacer(minLength: 0)
                        Text(selectedDate.activityRangeLabel)
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                    }
                    FitnessActivityLineChart(points: snapshot.activitySeries, accent: snapshot.activityTotal.hue, yAxisLabel: "minutes")
                        .accessibilityIdentifier("fitness-activity-summary-chart")
                    FitnessActivityMetricFooter(metric: snapshot.activityTotal)
                }
            }
            .overlay(
                    LifeOSTokens.cardShape
                    .fill(Color.clear)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fitness-activity-summary-card")
        .accessibilityHint("Opens activity summary detail")
    }
}

private struct FitnessPerformanceTargetCard: View {
    let target: FitnessPerformanceTarget

    var body: some View {
        NavigationLink(value: FitnessActivityRoute.performanceTarget) {
            FitnessCard {
                VStack(alignment: .leading, spacing: 10) {
                    FitnessActivityCardHeader(title: "Performance / load", icon: .budget, accent: .green)
                    HStack(alignment: .bottom, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Source comparison")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Text(FitnessPerformanceTargetFormatter.value(target))
                                .font(LifeOSFont.spaceGrotesk(31, weight: .bold))
                                .monospacedDigit()
                            Text(FitnessPerformanceTargetFormatter.status(target))
                                .font(LifeOSFont.inter(13, weight: .semiBold))
                                .foregroundStyle(FitnessPerformanceTargetFormatter.statusColor(target))
                        }
                        FitnessActivityLineChart(
                            points: target.series,
                            accent: .blue,
                            yAxisLabel: "load",
                            targetBand: FitnessPerformanceTargetFormatter.band(target)
                        )
                        .accessibilityIdentifier("fitness-performance-target-chart")
                        .frame(minWidth: 140, maxWidth: 360)
                    }
                    Text(FitnessPerformanceTargetFormatter.detail(target))
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .overlay(
                LifeOSTokens.cardShape
                    .fill(LinearGradient(
                        colors: [LifeOSTokens.success.opacity(0.055), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("fitness-performance-target-card")
        .accessibilityHint("Opens performance and load detail")
    }
}

private struct FitnessActivityMetricCard: View {
    let route: FitnessActivityRoute
    let metric: FitnessActivityMetric
    @State private var hovering = false

    var body: some View {
        NavigationLink(value: route) {
            FitnessCard {
                VStack(alignment: .leading, spacing: 10) {
                    FitnessActivityCardHeader(title: metric.title, icon: .fitness, accent: metric.hue)
                    Text(FitnessActivityMetricFormatter.value(metric))
                        .font(LifeOSFont.spaceGrotesk(27, weight: .bold))
                        .monospacedDigit()
                    Text(FitnessActivityMetricFormatter.status(metric))
                        .font(LifeOSFont.inter(12, weight: .semiBold))
                        .foregroundStyle(FitnessActivityMetricFormatter.statusColor(metric))
                    FitnessActivityMetricFooter(metric: metric)
                }
            }
            .overlay(
                    LifeOSTokens.cardShape
                    .fill(Color.clear)
                    .allowsHitTesting(false)
            )
        }
        .buttonStyle(.plain)
#if os(macOS)
        .onHover { hovering = $0 }
#endif
        .overlay(
            LifeOSTokens.cardShape.stroke(
                hovering ? LifeOSTokens.strongBorder : .clear,
                lineWidth: 1
            )
        )
        .animation(LifeOSMotion.reduceMotion ? nil : LifeOSMotion.springSnappy, value: hovering)
        .accessibilityIdentifier("fitness-\(metric.id)-card")
        .accessibilityHint("Opens \(metric.title) detail")
    }
}

private struct FitnessActivityCardHeader: View {
    let title: String
    let icon: LifeOSIconName
    let accent: LifeOSTokens.Hue

    var body: some View {
        HStack(spacing: 8) {
            LifeOSIcon(icon)
                .frame(width: 16, height: 16)
                .foregroundStyle(LifeOSTokens.secondaryText)
            Text(title)
                .font(LifeOSFont.header(14))
                .lineLimit(1)
            Spacer(minLength: 0)
            LifeOSIcon(.chevronRight)
                .frame(width: 13, height: 13)
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }
}

private struct FitnessActivityMetricFooter: View {
    let metric: FitnessActivityMetric

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Circle()
                .fill(FitnessActivityMetricFormatter.statusColor(metric))
                .frame(width: 6, height: 6)
            Text(FitnessActivityMetricFormatter.provenance(metric))
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct FitnessActivityLineChart: View {
    let points: [FitnessActivitySeriesPoint]
    let accent: LifeOSTokens.Hue
    let yAxisLabel: String
    var targetBand: (Double, Double)? = nil
    /// Selection is keyed to the source date rather than an array offset.
    /// Refreshes can reorder or replace points; the user's selected day must
    /// not silently jump to a different observation.
    @State private var selectedPointID: Date?

    private var orderedPoints: [FitnessActivitySeriesPoint] {
        points.sorted { $0.date < $1.date }
    }

    private var chartDatasetID: String {
        let values = orderedPoints.map { point in
            let value = point.value.map { String($0) } ?? "gap"
            return "\(point.date.timeIntervalSinceReferenceDate):\(value)"
        }
        let band = targetBand.map { "|band:\($0.0):\($0.1)" } ?? ""
        return values.joined(separator: "|") + band
    }

    private var selectedIndex: Int? {
        guard let selectedPointID else { return nil }
        return orderedPoints.firstIndex { $0.date == selectedPointID }
    }

    var body: some View {
        GeometryReader { proxy in
            let plotPoints = orderedPoints
            let values = plotPoints.map(\.value)
            let observed = values.compactMap { $0 }
            let lower = min(observed.min() ?? 0, targetBand?.0 ?? .greatestFiniteMagnitude)
            let upper = max(observed.max() ?? 1, targetBand?.1 ?? 0)
            let range = max(upper - lower, 1)
            ZStack(alignment: .topLeading) {
                LifeOSChartDrawReveal(content: ZStack(alignment: .topLeading) {
                    if let targetBand {
                        let top = proxy.size.height * CGFloat(1 - (targetBand.1 - lower) / range)
                        let bottom = proxy.size.height * CGFloat(1 - (targetBand.0 - lower) / range)
                        Rectangle()
                            .fill(LifeOSTokens.success.opacity(0.12))
                            .frame(height: max(0, bottom - top))
                            .offset(y: max(0, top))
                    }
                    Path { path in
                        var started = false
                        for (index, value) in values.enumerated() {
                            guard let value, proxy.size.width > 0 else {
                                started = false
                                continue
                            }
                            let x = chartX(for: plotPoints[index].date, width: proxy.size.width)
                            let y = proxy.size.height * CGFloat(1 - (value - lower) / range)
                            if started { path.addLine(to: CGPoint(x: x, y: y)) }
                            else { path.move(to: CGPoint(x: x, y: y)); started = true }
                        }
                    }
                    .stroke(LifeOSTokens.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    if let lastIndex = values.lastIndex(where: { $0 != nil }), let last = values[lastIndex] {
                        let x = chartX(for: plotPoints[lastIndex].date, width: proxy.size.width)
                        let y = proxy.size.height * CGFloat(1 - (last - lower) / range)
                        Circle()
                            .fill(LifeOSTokens.accent)
                            .frame(width: 8, height: 8)
                            .position(x: x, y: y)
                    }
                })
                if let selectedPoint, let selectedIndex {
                    let x = chartX(for: selectedIndex, width: proxy.size.width)
                    let y = chartY(for: selectedPoint.value, lower: lower, range: range, height: proxy.size.height)
                    Rectangle()
                        .fill(LifeOSTokens.accent.opacity(0.22))
                        .frame(width: 1, height: proxy.size.height)
                        .position(x: x, y: proxy.size.height / 2)
                    Circle()
                        .fill(LifeOSTokens.screenCanvas)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(LifeOSTokens.accent, lineWidth: 2))
                        .position(x: x, y: y)
                    chartTooltip(for: selectedPoint, at: CGPoint(x: x, y: y), chartSize: proxy.size)
                }
            }
            .overlay(alignment: .bottomLeading) {
                Text(yAxisLabel)
                    .font(LifeOSFont.caption(9))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                DragGesture(minimumDistance: LifeOSDirectionalClassifier.minimumDistance, coordinateSpace: .local)
                    .onChanged { value in
                        guard LifeOSDirectionalClassifier.classify(value.translation) == .horizontal else { return }
                        if let index = nearestIndex(toX: value.location.x, width: proxy.size.width) {
                            selectedPointID = plotPoints[index].date
                        }
                    }
            )
#if os(macOS)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    if let index = nearestIndex(toX: location.x, width: proxy.size.width) {
                        selectedPointID = plotPoints[index].date
                    }
                case .ended:
                    selectedPointID = nil
                }
            }
#endif
        }
        .frame(minHeight: 82)
        .chartDrawOn(id: chartDatasetID)
        .task(id: chartDatasetID) {
            guard let selectedPointID else { return }
            if !orderedPoints.contains(where: { $0.date == selectedPointID && $0.value != nil }) {
                self.selectedPointID = nil
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(yAxisLabel) trend")
        .accessibilityValue(accessibilityValue)
        .accessibilityHint("Swipe up or down to inspect an exact date and value")
        .accessibilityAdjustableAction { direction in
            let indices = selectableIndices
            guard !indices.isEmpty else { return }
            let current = selectedIndex.flatMap { indices.firstIndex(of: $0) } ?? (direction == .increment ? -1 : indices.count)
            let next: Int
            switch direction {
            case .increment: next = min(indices.count - 1, current + 1)
            case .decrement: next = max(0, current - 1)
            @unknown default: next = current
            }
            selectedPointID = orderedPoints[indices[next]].date
        }
    }

    private var selectableIndices: [Int] {
        orderedPoints.indices.filter { orderedPoints[$0].value != nil }
    }

    private var selectedPoint: FitnessActivitySeriesPoint? {
        guard let selectedPointID else { return nil }
        return orderedPoints.first { $0.date == selectedPointID && $0.value != nil }
    }

    private var accessibilityValue: String {
        guard let selectedPoint else {
            return orderedPoints.compactMap(\.value).isEmpty
                ? "Unavailable"
                : "Observed source points; no point selected"
        }
        return "Selected \(selectedPoint.date.activityDayLabel), \(chartValue(selectedPoint.value))"
    }

    private func nearestIndex(toX x: CGFloat, width: CGFloat) -> Int? {
        guard width > 0, !selectableIndices.isEmpty else { return nil }
        return selectableIndices.min { left, right in
            abs(chartX(for: orderedPoints[left].date, width: width) - x)
                < abs(chartX(for: orderedPoints[right].date, width: width) - x)
        }
    }

    private func chartX(for index: Int, width: CGFloat) -> CGFloat {
        guard orderedPoints.indices.contains(index) else { return width / 2 }
        return chartX(for: orderedPoints[index].date, width: width)
    }

    private func chartX(for date: Date, width: CGFloat) -> CGFloat {
        guard let first = orderedPoints.first?.date, let last = orderedPoints.last?.date else {
            return width / 2
        }
        let span = max(last.timeIntervalSince(first), 1)
        let fraction = min(max(date.timeIntervalSince(first) / span, 0), 1)
        return width * CGFloat(fraction)
    }

    private func chartY(for value: Double?, lower: Double, range: Double, height: CGFloat) -> CGFloat {
        guard let value else { return height }
        return height * CGFloat(1 - (value - lower) / range)
    }

    @ViewBuilder
    private func chartTooltip(for point: FitnessActivitySeriesPoint, at location: CGPoint, chartSize: CGSize) -> some View {
        let tooltipWidth: CGFloat = 154
        VStack(alignment: .leading, spacing: 2) {
            Text(point.date.activityDayLabel)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
            Text(chartValue(point.value))
                .font(LifeOSFont.inter(12, weight: .semiBold))
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: tooltipWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .position(
            x: min(max(location.x, tooltipWidth / 2), max(tooltipWidth / 2, chartSize.width - tooltipWidth / 2)),
            y: max(27, location.y - 30)
        )
        .allowsHitTesting(false)
    }

    private func chartValue(_ value: Double?) -> String {
        guard let value else { return "Unavailable" }
        let formatted = value.formatted(.number.precision(.fractionLength(0...1)))
        return "\(formatted) \(yAxisLabel)"
    }
}

private struct FitnessActivityDetailView: View {
    let route: FitnessActivityRoute
    let snapshot: FitnessActivitySnapshot
    let strengthSnapshot: FitnessStrengthSnapshot
    let usesVisualFixtures: Bool
    let selectedDate: Date
    let onSourceTap: () -> Void
    @StateObject private var strengthTemplateStore: FitnessStrengthTemplateStore

    init(
        route: FitnessActivityRoute,
        snapshot: FitnessActivitySnapshot,
        strengthSnapshot: FitnessStrengthSnapshot,
        usesVisualFixtures: Bool,
        selectedDate: Date,
        onSourceTap: @escaping () -> Void
    ) {
        self.route = route
        self.snapshot = snapshot
        self.strengthSnapshot = strengthSnapshot
        self.usesVisualFixtures = usesVisualFixtures
        self.selectedDate = selectedDate
        self.onSourceTap = onSourceTap
        _strengthTemplateStore = StateObject(wrappedValue: FitnessStrengthTemplateStore(
            persistenceURL: usesVisualFixtures ? nil : FitnessStrengthTemplateStore.defaultPersistenceURL
        ))
    }

    @ViewBuilder
    var body: some View {
        if case .strengthDetail = route {
            FitnessStrengthDetailView(
                snapshot: strengthSnapshot,
                templateStore: strengthTemplateStore,
                onSourceTap: onSourceTap
            )
            .navigationTitle(route.title)
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        } else {
            detailScrollBody
        }
    }

    private var detailScrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                FitnessSectionHeading(title: route.title, subtitle: selectedDate.activityRangeLabel)
                switch route {
                case .activitySummary:
                    FitnessCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text(FitnessActivityMetricFormatter.value(snapshot.activityTotal))
                                .font(LifeOSFont.spaceGrotesk(40, weight: .bold))
                            FitnessActivityLineChart(points: snapshot.activitySeries, accent: snapshot.activityTotal.hue, yAxisLabel: "minutes")
                                .accessibilityIdentifier("fitness-activity-summary-detail-chart")
                            FitnessActivityMetricFooter(metric: snapshot.activityTotal)
                        }
                    }
                case .performanceTarget:
                    FitnessCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Source comparison")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Text(FitnessPerformanceTargetFormatter.value(snapshot.performanceTarget))
                                .font(LifeOSFont.spaceGrotesk(40, weight: .bold))
                            FitnessActivityLineChart(
                                points: snapshot.performanceTarget.series,
                                accent: .blue,
                                yAxisLabel: "load",
                                targetBand: FitnessPerformanceTargetFormatter.band(snapshot.performanceTarget)
                            )
                            .accessibilityIdentifier("fitness-performance-target-detail-chart")
                            Text(FitnessPerformanceTargetFormatter.detail(snapshot.performanceTarget))
                                .font(LifeOSFont.body(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                case .strengthDetail:
                    EmptyView()
                case .day(let date):
                    FitnessCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(date.activityDayLabel)
                                .font(LifeOSFont.header(15))
                            if let day = snapshot.activityCalendarDays.first(where: { Calendar(identifier: .gregorian).isDate($0.date, inSameDayAs: date) }) {
                                switch day.state {
                                case .observed(let count, let window, let provenance), .demo(let count, let window, let provenance):
                                    Text("\(count) activities")
                                        .font(LifeOSFont.spaceGrotesk(32, weight: .bold))
                                        .monospacedDigit()
                                    Text(day.state.isDemo ? "Demo fixture · not live" : "Explicit source count")
                                        .font(LifeOSFont.caption(10))
                                        .foregroundStyle(day.state.isDemo ? LifeOSTokens.warning : LifeOSTokens.tertiaryText)
                                    Text("\(window) · \(provenance)")
                                        .font(LifeOSFont.caption(10))
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                case .unavailable(let reason, let window, let provenance):
                                    Text("Activity unavailable")
                                        .font(LifeOSFont.spaceGrotesk(28, weight: .bold))
                                    Text(reason)
                                        .font(LifeOSFont.body(12))
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                    Text("\(window) · \(provenance)")
                                        .font(LifeOSFont.caption(10))
                                        .foregroundStyle(LifeOSTokens.tertiaryText)
                                }
                            } else {
                                Text("Activity unavailable")
                                    .font(LifeOSFont.spaceGrotesk(28, weight: .bold))
                                Text("No source observation is available for this day; LifeOS does not substitute zero.")
                                    .font(LifeOSFont.body(12))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                            }
                        }
                    }
                case .metric(let id):
                    if let metric = metric(for: id) {
                        FitnessCard {
                            VStack(alignment: .leading, spacing: 9) {
                                Text(FitnessActivityMetricFormatter.value(metric))
                                    .font(LifeOSFont.spaceGrotesk(40, weight: .bold))
                                Text(FitnessActivityMetricFormatter.status(metric))
                                    .font(LifeOSFont.inter(14, weight: .semiBold))
                                    .foregroundStyle(FitnessActivityMetricFormatter.statusColor(metric))
                                Text(FitnessActivityMetricFormatter.detail(metric))
                                    .font(LifeOSFont.body(12))
                                    .foregroundStyle(LifeOSTokens.tertiaryText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                FitnessCard {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Source boundary").font(LifeOSFont.header(14))
                        Text("Values are shown only when the source supplies a named window, provenance, and the required observations. Missing or calibrating data is not converted to zero.")
                            .font(LifeOSFont.body(12))
                            .foregroundStyle(LifeOSTokens.tertiaryText)
                        Button("Review source and permissions", action: onSourceTap)
                            .font(LifeOSFont.inter(11, weight: .semiBold))
                            .buttonStyle(.bordered)
                            .tint(LifeOSTokens.accent)
                    }
                }
            }
            .padding(16)
        }
        .scrollIndicators(.hidden)
        .navigationTitle(route.title)
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
#endif
        .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
    }

    private func metric(for id: String) -> FitnessActivityMetric? {
        switch id {
        case "cardio-load": snapshot.cardioLoad
        case "cardio-focus": snapshot.cardioFocus
        case "heart-rate-recovery": snapshot.heartRateRecovery
        case "strength-volume": snapshot.strengthVolume
        default: nil
        }
    }
}

private enum FitnessActivityMetricFormatter {
    static func value(_ metric: FitnessActivityMetric) -> String {
        switch metric.state {
        case .unavailable: "No data"
        case .permissionRequired, .deviceUnavailable, .readIndeterminate,
             .conflict, .error: "No data"
        case .calibrating: "Calibrating"
        case .partial(let value, let unit, _, _), .stale(let value, let unit, _, _),
             .observed(let value, let unit, _, _), .demo(let value, let unit, _, _):
            format(value: value, unit: unit)
        }
    }

    static func status(_ metric: FitnessActivityMetric) -> String {
        metric.statusLabel
    }

    static func detail(_ metric: FitnessActivityMetric) -> String {
        switch metric.state {
        case .unavailable(let reason), .permissionRequired(let reason),
             .deviceUnavailable(let reason), .readIndeterminate(let reason),
             .calibrating(let reason), .conflict(let reason), .error(let reason):
            reason
        case .partial(_, _, let window, let provenance), .stale(_, _, let window, let provenance),
             .observed(_, _, let window, let provenance), .demo(_, _, let window, let provenance):
            "\(metric.statusLabel) · \(window) · \(provenance)"
        }
    }

    static func provenance(_ metric: FitnessActivityMetric) -> String {
        switch metric.state {
        case .unavailable(let reason), .permissionRequired(let reason),
             .deviceUnavailable(let reason), .readIndeterminate(let reason),
             .calibrating(let reason), .conflict(let reason), .error(let reason): reason
        case .partial(_, _, let window, _), .stale(_, _, let window, _),
             .observed(_, _, let window, _): window
        case .demo: "DEMO · NOT LIVE"
        }
    }

    static func statusColor(_ metric: FitnessActivityMetric) -> Color {
        switch metric.state {
        case .unavailable: LifeOSTokens.tertiaryText
        case .permissionRequired, .deviceUnavailable, .readIndeterminate,
             .calibrating, .partial, .stale, .conflict, .error: LifeOSTokens.warning
        case .observed: LifeOSTokens.success
        case .demo: LifeOSTokens.warning
        }
    }

    private static func format(value: Double, unit: FitnessActivityMetric.Unit) -> String {
        let rounded = Int(value.rounded())
        switch unit {
        case .minutes:
            if rounded >= 60 { return "\(rounded / 60)h \(rounded % 60)min" }
            return "\(rounded) min"
        case .percent: return "\(rounded)%"
        case .sourceDefined: return "\(rounded) · source-defined"
        case .bpm: return "\(rounded) bpm"
        case .kilograms: return "\(rounded) kg"
        case .count: return "\(rounded)"
        }
    }
}

private enum FitnessPerformanceTargetFormatter {
    static func value(_ target: FitnessPerformanceTarget) -> String {
        guard target.sourceState.canDisplayValue else {
            return target.sourceState.label
        }
        switch target.state {
        case .unavailable: return target.sourceState.label
        case .calibrating: return "Calibrating"
        case .observed(_, let deviation, _, _, _, _), .demo(_, let deviation, _, _, _, _):
            return String(format: "%+.0f%%", deviation)
        }
    }

    static func status(_ target: FitnessPerformanceTarget) -> String {
        switch target.sourceState {
        case .permissionRequired, .deviceUnavailable, .readIndeterminate,
             .conflict, .error:
            return target.sourceState.label
        case .partial, .stale:
            guard let status = target.targetStatus else { return target.sourceState.label }
            return "\(target.sourceState.label) · \(statusLabel(status))"
        case .unavailable:
            return "Unavailable"
        case .calibrating:
            return "Calibrating"
        case .derived, .manual:
            return target.sourceState.label
        case .observed, .demo:
            break
        }
        switch target.state {
        case .unavailable: return "Unavailable"
        case .calibrating: return "Calibrating"
        case .observed, .demo:
            switch target.targetStatus {
            case .below: return statusLabel(.below)
            case .within: return statusLabel(.within)
            case .above: return statusLabel(.above)
            case nil: return "Unavailable"
            }
        }
    }

    private static func statusLabel(_ status: FitnessPerformanceTarget.TargetStatus) -> String {
        switch status {
        case .below: return "Below target"
        case .within: return "Within target"
        case .above: return "Above target"
        }
    }

    static func detail(_ target: FitnessPerformanceTarget) -> String {
        switch target.state {
        case .unavailable(let reason), .calibrating(let reason):
            return target.sourceState == .unavailable || target.sourceState == .calibrating
                ? reason
                : "\(target.sourceState.label) · \(reason)"
        case .observed(_, _, let lower, let upper, let window, let provenance), .demo(_, _, let lower, let upper, let window, let provenance):
            let detail = "Target band \(Int(lower.rounded()))–\(Int(upper.rounded())) · \(window) · \(provenance)"
            return target.sourceState == .observed || target.sourceState == .demo
                ? detail
                : "\(target.sourceState.label) · \(detail)"
        }
    }

    static func band(_ target: FitnessPerformanceTarget) -> (Double, Double)? {
        guard target.sourceState.canDisplayValue else { return nil }
        switch target.state {
        case .observed(_, _, let lower, let upper, _, _), .demo(_, _, let lower, let upper, _, _): return (lower, upper)
        case .unavailable, .calibrating: return nil
        }
    }

    static func statusColor(_ target: FitnessPerformanceTarget) -> Color {
        switch target.sourceState {
        case .unavailable: LifeOSTokens.tertiaryText
        case .permissionRequired, .deviceUnavailable, .readIndeterminate,
             .calibrating, .partial, .stale, .conflict, .error:
            LifeOSTokens.warning
        case .derived, .manual: LifeOSTokens.success
        case .observed:
            switch target.targetStatus {
            case .below: LifeOSTokens.accent
            case .within: LifeOSTokens.success
            case .above: LifeOSTokens.warning
            case nil: LifeOSTokens.tertiaryText
            }
        case .demo: LifeOSTokens.warning
        }
    }
}

private extension Date {
    var activityMonthLabel: String {
        formatted(.dateTime.month(.wide).year())
    }

    var activityDayLabel: String {
        formatted(.dateTime.day().month(.abbreviated).year())
    }

    var activityRangeLabel: String {
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -29, to: self) ?? self
        return "\(start.activityDayLabel) – \(activityDayLabel)"
    }
}

private extension FitnessActivityDay.State {
    var isDemo: Bool {
        if case .demo = self { return true }
        return false
    }
}

private struct FitnessWorkoutRow: View {
    let workout: FitnessWorkout
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LifeOSTokens.raised)
                .frame(width: 35, height: 35)
                .overlay(LifeOSIcon(.fitness).foregroundStyle(LifeOSTokens.secondaryText).frame(width: 17, height: 17))
            VStack(alignment: .leading, spacing: 2) {
                Text(workout.name).font(LifeOSFont.inter(13, weight: .semiBold))
                Text("\(workout.kind) · \(workout.duration)").font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer()
            Text(workout.time.fitnessTimeLabel).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityHint(showsDisclosure ? "Opens workout detail" : "Workout record")
    }
}

private struct FitnessCompactMetric: View {
    let metric: FitnessMetric

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(fitnessMetricStateColor(metric.sourceState)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(metric.title).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(metric.value ?? "—").font(LifeOSFont.spaceGrotesk(18, weight: .bold)).monospacedDigit()
                    if !metric.unit.isEmpty { Text(metric.unit).font(LifeOSFont.caption(9)).foregroundStyle(LifeOSTokens.tertiaryText) }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(LifeOSTokens.screenCanvas.opacity(0.7), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(LifeOSTokens.quietBorder, lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metric.title)
        .accessibilityValue("\(metric.value ?? "Not available") \(metric.unit). \(metric.sourceState.label). \(metric.provenanceSummary)")
    }
}

// MARK: - Health monitor and timeline cards

private struct FitnessHealthMonitorCard: View {
    let metrics: [FitnessMetric]
    let onSourceTap: () -> Void

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Text("Health Monitor")
                        .font(LifeOSFont.header(15))
                    Spacer()
                    Button("Why no data?", action: onSourceTap)
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.accent)
                        .buttonStyle(.plain)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], spacing: 8) {
                    ForEach(metrics) { metric in
                        FitnessCompactMetric(metric: metric)
                    }
                }
            }
        }
    }
}

private struct FitnessTimelineCard: View {
    let workouts: [FitnessWorkout]
    let journalEntries: [FitnessJournalEntry]
    let supplements: [FitnessSupplement]

    var body: some View {
        FitnessCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Timeline")
                        .font(LifeOSFont.header(15))
                    Spacer()
                    Text("Date-scoped")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
                if workouts.isEmpty && journalEntries.isEmpty && supplements.isEmpty {
                    FitnessEmptyRow(title: "No activity logged", detail: "Meals, hydration, caffeine, alcohol, supplements, workouts, and journal facts appear here when recorded.", icon: .more)
                } else {
                    ForEach(workouts) { workout in
                        FitnessWorkoutRow(workout: workout)
                    }
                    ForEach(journalEntries) { entry in
                        FitnessTimelineEntryRow(entry: entry)
                    }
                    ForEach(supplements.prefix(2)) { supplement in
                        HStack(spacing: 10) {
                            LifeOSIcon(.verified).foregroundStyle(LifeOSTokens.accent).frame(width: 18, height: 18)
                            Text("\(supplement.name) · planned \(supplement.timing)")
                                .font(LifeOSFont.inter(12, weight: .medium))
                            Spacer()
                            Text("Local")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                        }
                    }
                }
            }
        }
    }
}

private struct FitnessTimelineEntryRow: View {
    let entry: FitnessJournalEntry

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(LifeOSTokens.info.opacity(0.14))
                .frame(width: 32, height: 32)
                .overlay(LifeOSIcon(.more).foregroundStyle(LifeOSTokens.info).frame(width: 15, height: 15))
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(LifeOSFont.inter(12, weight: .medium))
                Text(entry.source.rawValue)
                    .font(LifeOSFont.caption(10))
                    .foregroundStyle(LifeOSTokens.tertiaryText)
            }
            Spacer(minLength: 8)
            Text(entry.time.fitnessTimeLabel)
                .font(LifeOSFont.caption(10))
                .foregroundStyle(LifeOSTokens.tertiaryText)
        }
    }
}

// MARK: - Settings and reusable primitives

private struct FitnessSettingsView: View {
    let source: FitnessSourceState
    let onSourceTap: () -> Void
    @State private var photoInference = false
    @State private var lockScreenPrivacy = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            FitnessSectionHeading(title: "Settings", subtitle: "Keep source, privacy, and retention explicit")
            FitnessSourceGateCard(source: source, onSourceTap: onSourceTap)
            FitnessCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Health source")
                        .font(LifeOSFont.header(15))
                    Text("Helio Strap is the sensor authority. Apple Health and HealthKit are transport and permission layers, not a substitute sensor.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                    Label("Read-only HealthKit access", systemImage: "lock.shield")
                        .font(LifeOSFont.body(12))
                    Text("This build never writes meals, nutrition, scores, or device settings to HealthKit.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            FitnessCard {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Privacy")
                        .font(LifeOSFont.header(15))
                    Toggle("Allow opt-in photo assistance", isOn: $photoInference)
                    Text(photoInference ? "Each opted-in photo leaves this PC and is sent to Google for inference. Estimates stay proposals until you edit and confirm them." : "Local/manual only · no photo leaves this PC")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Redact detail on lock screen", isOn: $lockScreenPrivacy)
                    Text("Lock-screen surfaces omit supplement names/doses, meal photos, detailed body values, and journal text by default.")
                        .font(LifeOSFont.caption(10))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                }
            }
            FitnessCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Retention budget")
                            .font(LifeOSFont.header(15))
                        Spacer()
                        Text("≤ 10 GB / rolling 12 months")
                            .font(LifeOSFont.caption(10))
                            .foregroundStyle(LifeOSTokens.success)
                    }
                    Text("Warnings at 8 GB, structured-only/transient-photo mode at 9 GB, and no silent deletion at the hard cap. Originals default to 90 days; structured records remain independent.")
                        .font(LifeOSFont.body(12))
                        .foregroundStyle(LifeOSTokens.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct FitnessSourceGateSheet: View {
    let source: FitnessSourceState
    let onSourceTap: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    FitnessSourceGateCard(source: source, onSourceTap: onSourceTap)
                        .padding(.top, 8)
                    FitnessCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("What this gate means")
                                .font(LifeOSFont.header(15))
                            Text("LifeOS will ask for HealthKit categories one at a time with plain-language reasons. Denying one category leaves unrelated manual logs available and does not create a replacement value.")
                                .font(LifeOSFont.body(12))
                                .foregroundStyle(LifeOSTokens.tertiaryText)
                            Text("No private Zepp protocol or invented Bevel-compatible score is used.")
                                .font(LifeOSFont.caption(10))
                                .foregroundStyle(LifeOSTokens.warning)
                        }
                    }
                    Button("Close") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(LifeOSTokens.accent)
                }
                .padding(16)
            }
            .background(LifeOSTokens.screenCanvas.ignoresSafeArea())
            .navigationTitle("Health source")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
    }
}

struct FitnessCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        // Keep the card itself a single layout item. Without this wrapper a
        // multi-child builder (such as a metric's value row + provenance row)
        // can be flattened by LazyVGrid into the exact empty companion cards
        // that this surface must avoid.
        VStack(alignment: .leading, spacing: 0) {
            content
        }
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .flatCard()
    }
}

struct FitnessEmptyRow: View {
    let title: String
    let detail: String
    let icon: LifeOSIconName

    var body: some View {
        HStack(spacing: 10) {
            LifeOSIcon(icon).foregroundStyle(LifeOSTokens.tertiaryText).frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(LifeOSFont.inter(13, weight: .semiBold))
                Text(detail).font(LifeOSFont.caption(10)).foregroundStyle(LifeOSTokens.tertiaryText).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 3)
    }
}

/// Ring color policy (Quiet Machine §5.5): progress rings read accent; status
/// rings (strain/load, recovery/readiness, sleep score) read success/warning/
/// danger by threshold band. Stress is NOT a status per spec — it reads accent.
private enum FitnessRingPalette {
    static func color(route: FitnessCoreRoute, progress: Double) -> Color {
        switch route {
        case .load, .readiness, .sleep:
            return threshold(progress)
        case .stress, .energyReserve, .healthMonitor, .healthMetric, .workout:
            return LifeOSTokens.Ring.progressArc
        }
    }

    static func threshold(_ progress: Double) -> Color {
        if progress >= 0.67 { return LifeOSTokens.success }
        if progress >= 0.34 { return LifeOSTokens.warning }
        return LifeOSTokens.danger
    }
}

private struct FitnessRing: View {
    let progress: Double
    let hue: LifeOSTokens.Hue
    let size: CGFloat
    /// Resolved arc color; defaults to the sanctioned accent.
    var color: Color = LifeOSTokens.Ring.progressArc
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayedProgress = 0.0

    /// Detail rings ≥90pt stroke 8; mid cards 6; minis 3. Solid, no gradient.
    private var stroke: CGFloat {
        size >= 90 ? 8 : (size >= 48 ? 6 : 3)
    }

    var body: some View {
        ZStack {
            Circle().stroke(LifeOSTokens.Ring.track, lineWidth: stroke)
            Circle()
                .trim(from: 0, to: displayedProgress)
                .stroke(color, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .task {
            displayedProgress = reduceMotion ? progress : 0
            guard !reduceMotion else { return }
            withAnimation(LifeOSMotion.ringReveal) { displayedProgress = progress }
        }
        .onChange(of: progress) { _, newValue in
            if reduceMotion { displayedProgress = newValue }
            else { withAnimation(LifeOSMotion.ringReveal) { displayedProgress = newValue } }
        }
        .accessibilityHidden(true)
    }
}

extension Date {
    var fitnessHeaderDateLabel: String {
        formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year())
    }

    var fitnessDayLabel: String {
        formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var fitnessTimeLabel: String {
        formatted(.dateTime.hour().minute())
    }

    var fitnessJournalDateKey: String {
        formatted(.dateTime.year().month(.twoDigits).day(.twoDigits))
    }

    var fitnessJournalMonthLabel: String {
        formatted(.dateTime.month(.abbreviated).year())
    }

    var fitnessJournalAccessibilityDate: String {
        formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    }
}
