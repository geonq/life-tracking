import Foundation
import XCTest
@testable import LifeOS

final class FitnessCoreDetailDomainTests: XCTestCase {
    func testLoadGaugeRejectsMissingMetadataAndNeverCreatesTarget() {
        let invalid = FitnessLoadGauge(state: .observed(
            current: 55,
            lowerBound: 20,
            upperBound: 40,
            unit: "%",
            window: "",
            provenance: "HealthKit"
        ))
        if case .unavailable(let reason) = invalid.state {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("A target without a named window must remain unavailable")
        }

        XCTAssertNil(FitnessLoadGauge.unavailable.currentProgress)
        XCTAssertTrue(FitnessLoadDetail().heartRateZones.isEmpty)
        XCTAssertNil(FitnessLoadDetail().trend)
    }

    func testObservedLoadGaugePreservesTargetBandAndProgress() {
        let gauge = FitnessLoadGauge(state: .observed(
            current: 55,
            lowerBound: 20,
            upperBound: 80,
            unit: "%",
            window: "Today",
            provenance: "Helio Strap → Zepp → HealthKit"
        ))
        XCTAssertEqual(gauge.targetLabel, "20–80 %")
        XCTAssertEqual(gauge.currentProgress ?? -1, 0.5833333333333334, accuracy: 0.0001)
    }

    func testRecoveryBuildsExactlySixNamedTrendsFromExistingHealthMetrics() {
        let metrics = [
            FitnessMetric(title: "HRV", value: "52", unit: "ms", detail: "Observed", quality: .observed, trend: [0.4, 0.5]),
            FitnessMetric(title: "Resting heart rate", value: "54", unit: "bpm", detail: "Observed", quality: .observed),
            FitnessMetric(title: "Respiration", value: "14.8", unit: "/min", detail: "Observed", quality: .observed),
            FitnessMetric(title: "Blood oxygen", value: "98", unit: "%", detail: "Observed", quality: .observed),
            FitnessMetric(title: "Skin temperature", value: "+0.1", unit: "°C", detail: "Observed", quality: .observed)
        ]
        let readiness = FitnessMetric(title: "Readiness", value: "78", unit: "/100", detail: "Observed", quality: .observed)
        let detail = FitnessRecoveryDetail.from(readiness: readiness, healthMonitor: metrics)

        XCTAssertEqual(detail.trends.map(\.id), FitnessRecoveryTrendID.allCases)
        XCTAssertEqual(detail.hrv.value, "52")
        XCTAssertEqual(detail.restingHeartRate.value, "54")
        XCTAssertEqual(detail.trends.first?.metric.value, "78")
        XCTAssertEqual(detail.trends.last?.metric.value, "+0.1")
    }

    func testRecoveryMissingSignalsStayUnavailableRatherThanZero() {
        let detail = FitnessRecoveryDetail.from(
            readiness: .unavailable("Readiness"),
            healthMonitor: []
        )
        XCTAssertEqual(detail.trends.count, 6)
        XCTAssertTrue(detail.trends.allSatisfy { $0.metric.quality == .unavailable })
        XCTAssertTrue(detail.insights.allSatisfy { $0.isUnavailable })
    }

    func testSleepDefaultsKeepTimeInBedAndAllStagesUnavailable() {
        let detail = FitnessSleepDetail.from(sleep: .unavailable("Sleep"))
        XCTAssertEqual(detail.trends.map(\.id), FitnessSleepTrendID.allCases)
        XCTAssertEqual(detail.timeInBed.quality, .unavailable)
        XCTAssertEqual(detail.duration.quality, .unavailable)
        XCTAssertTrue(detail.trends.filter { [.rem, .deep, .core, .awake].contains($0.id) }.allSatisfy { $0.metric.quality == .unavailable })
        XCTAssertTrue(detail.sleepNeed.isUnavailable)
        XCTAssertTrue(detail.windDown.isUnavailable)
    }

    func testGenericSleepDurationDoesNotBecomeSleepQualityOrTimeInBed() {
        let sleep = FitnessMetric(
            title: "Sleep",
            value: "7h 42m",
            unit: "",
            detail: "HealthKit transport · demo",
            quality: .demo
        )
        let detail = FitnessSleepDetail.from(sleep: sleep)

        XCTAssertEqual(detail.duration.value, "7h 42m")
        XCTAssertEqual(detail.duration.title, "Sleep duration")
        XCTAssertEqual(detail.duration.quality, .demo)
        XCTAssertEqual(detail.quality.quality, .unavailable)
        XCTAssertEqual(detail.timeInBed.quality, .unavailable)
        XCTAssertEqual(detail.trends.first(where: { $0.id == .duration })?.metric.value, "7h 42m")
        XCTAssertEqual(detail.trends.first(where: { $0.id == .quality })?.metric.quality, .unavailable)
    }

    func testSleepQualityNamedMetricCannotBeReclassifiedAsDuration() {
        let quality = FitnessMetric(
            title: "Sleep quality",
            value: "78",
            unit: "/100",
            detail: "Explicit quality sample",
            quality: .observed
        )
        let detail = FitnessSleepDetail.from(sleep: quality)

        XCTAssertEqual(detail.duration.quality, .unavailable)
        XCTAssertEqual(detail.quality.quality, .unavailable)
        XCTAssertEqual(detail.timeInBed.quality, .unavailable)
    }

    func testSleepScheduleRequiresExplicitTargetsAndKeepsClockLabelsTyped() {
        let unavailable = FitnessSleepSchedule(
            state: .configured(
                windDownMinutes: 1_360,
                targetBedtimeMinutes: 1_366,
                wakeTargetMinutes: 420,
                sleepNeedMinutes: 493,
                timeZone: "Europe/Berlin",
                window: "Configured by user",
                provenance: "Manual schedule",
                freshness: "Updated today"
            )
        )

        XCTAssertFalse(unavailable.isUnavailable)
        XCTAssertEqual(FitnessSleepSchedule.clockLabel(minutes: 1_366), "22:46")
        XCTAssertEqual(FitnessSleepSchedule.clockLabel(minutes: 420), "07:00")
        XCTAssertEqual(FitnessSleepSchedule.durationLabel(minutes: 493), "8h 13m")
        XCTAssertTrue(unavailable.evidenceSummary.contains("Manual schedule"))

        let invalid = FitnessSleepSchedule(state: .configured(
            windDownMinutes: 1_440,
            targetBedtimeMinutes: 1_366,
            wakeTargetMinutes: 420,
            sleepNeedMinutes: 493,
            timeZone: "Europe/Berlin",
            window: "Configured by user",
            provenance: "Manual schedule",
            freshness: "Updated today"
        ))
        XCTAssertTrue(invalid.isUnavailable)
    }

    func testSleepTrendFamiliesKeepStageAndBalanceMetricsIndependent() {
        let detail = FitnessSleepDetail()
        XCTAssertEqual(detail.trends.map(\.id), FitnessSleepTrendID.allCases)
        XCTAssertEqual(detail.trends.count, 11)
        XCTAssertTrue(detail.trends.filter { [.rem, .deep, .core].contains($0.id) }.allSatisfy { $0.metric.quality == .unavailable })
        XCTAssertTrue(detail.trends.filter { [.heartRateDrop, .sleepBalance, .wakeTime, .sleepOnset].contains($0.id) }.allSatisfy { $0.metric.quality == .unavailable })
        XCTAssertTrue(detail.trends.allSatisfy { $0.availableRanges.isEmpty })
    }

    func testSleepNightFullObservationKeepsIntervalStagesEvidenceAndBoundaryTyped() {
        let start = Date(timeIntervalSinceReferenceDate: 10_000)
        let end = start.addingTimeInterval(8 * 3_600)
        let stages = [
            FitnessSleepStageSample(stage: .deep, start: start, end: start.addingTimeInterval(3_600)),
            FitnessSleepStageSample(stage: .core, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(6 * 3_600)),
            FitnessSleepStageSample(stage: .rem, start: start.addingTimeInterval(6 * 3_600), end: end)
        ].compactMap { $0 }
        let night = FitnessSleepNight(
            start: start,
            end: end,
            stageSamples: stages,
            boundary: FitnessSleepDayBoundary(name: "Local sleep day", timeZone: "Europe/Berlin"),
            evidence: FitnessSleepObservationEvidence(state: .observed(
                source: "HealthKit",
                device: "Helio Strap",
                provenance: "Helio → Zepp → HealthKit",
                freshness: "2 h ago"
            )),
            state: .observed
        )

        XCTAssertEqual(night.state, .observed)
        XCTAssertEqual(night.durationSeconds, 8 * 3_600)
        XCTAssertEqual(night.stageSamples.map(\.stage), [.deep, .core, .rem])
        XCTAssertEqual(night.boundary?.summary, "Local sleep day · Europe/Berlin")
        XCTAssertTrue(night.statusSummary.contains("HealthKit"))
    }

    func testSleepNightPartialObservationIsExplicitWhenStagesAreMissing() {
        let start = Date(timeIntervalSinceReferenceDate: 20_000)
        let night = FitnessSleepNight(
            start: start,
            end: start.addingTimeInterval(7 * 3_600),
            boundary: FitnessSleepDayBoundary(name: "Source sleep day", timeZone: "UTC"),
            evidence: FitnessSleepObservationEvidence(state: .observed(
                source: "HealthKit", device: "Helio Strap", provenance: "Imported interval", freshness: "Today"
            )),
            state: .observed
        )

        if case .partial(let reason) = night.state {
            XCTAssertTrue(reason.contains("stage"))
        } else {
            XCTFail("An interval without stages must remain explicitly partial")
        }
    }

    func testSleepNightUnavailableAndConflictStatesNeverBecomeAHealthyTimeline() {
        XCTAssertTrue(FitnessSleepNight.unavailable.isUnavailable)

        let start = Date(timeIntervalSinceReferenceDate: 30_000)
        let first = FitnessSleepStageSample(stage: .deep, start: start, end: start.addingTimeInterval(2 * 3_600))!
        let overlapping = FitnessSleepStageSample(stage: .rem, start: start.addingTimeInterval(3_600), end: start.addingTimeInterval(3 * 3_600))!
        let conflict = FitnessSleepNight(
            start: start,
            end: start.addingTimeInterval(6 * 3_600),
            stageSamples: [first, overlapping],
            boundary: FitnessSleepDayBoundary(name: "Local sleep day", timeZone: "UTC"),
            evidence: FitnessSleepObservationEvidence(state: .observed(
                source: "HealthKit", device: "Helio Strap", provenance: "Two source samples", freshness: "Now"
            )),
            state: .observed
        )

        if case .conflict(let reason) = conflict.state {
            XCTAssertTrue(reason.contains("overlap"))
        } else {
            XCTFail("Overlapping stage samples must remain an explicit conflict")
        }

        let outside = FitnessSleepNight(
            start: start,
            end: start.addingTimeInterval(6 * 3_600),
            stageSamples: [FitnessSleepStageSample(stage: .rem, start: start.addingTimeInterval(5 * 3_600), end: start.addingTimeInterval(7 * 3_600))!],
            boundary: FitnessSleepDayBoundary(name: "Local sleep day", timeZone: "UTC"),
            evidence: FitnessSleepObservationEvidence(state: .observed(
                source: "HealthKit", device: "Helio Strap", provenance: "Out-of-bounds sample", freshness: "Now"
            )),
            state: .observed
        )
        if case .conflict(let reason) = outside.state {
            XCTAssertTrue(reason.contains("outside"))
        } else {
            XCTFail("Stage samples outside the interval must remain an explicit conflict")
        }
    }

    func testSleepTrendRangeUsesOnlySuppliedSeriesAndDoesNotRelabelOneSeries() {
        let metric = FitnessMetric(title: "Sleep duration", value: "7h 42m", unit: "", detail: "Fixture", quality: .demo, trend: [0.2, 0.3])
        let card = FitnessSleepTrendCard(
            id: .duration,
            metric: metric,
            availableRanges: [.seven, .thirty],
            seriesByRange: [.seven: [0.2, 0.3], .thirty: [0.7, 0.8]]
        )
        XCTAssertEqual(card.availableSeriesRanges, [.seven, .thirty])
        XCTAssertNotEqual(card.series(for: .seven), card.series(for: .thirty))

        let oneSeries = FitnessSleepTrendCard(
            id: .duration,
            metric: metric,
            availableRanges: [.seven, .thirty],
            seriesByRange: [.seven: [0.2, 0.3]]
        )
        XCTAssertEqual(oneSeries.availableSeriesRanges, [.seven])
        XCTAssertNil(oneSeries.series(for: .thirty))
    }

    func testDemoSleepDetailSuppliesTimelineScheduleAndAllReferenceTrendFamilies() {
        let detail = FitnessSnapshot.demo.sleepDetail
        XCTAssertEqual(detail.night.state, .observed)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let startComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: detail.night.start!)
        let endComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: detail.night.end!)
        XCTAssertEqual(startComponents.hour, 22)
        XCTAssertEqual(startComponents.minute, 46)
        XCTAssertEqual(endComponents.hour, 6)
        XCTAssertEqual(endComponents.minute, 46)
        XCTAssertEqual(startComponents.day, 26)
        XCTAssertEqual(endComponents.day, 27)
        XCTAssertEqual(detail.night.durationSeconds, 8 * 3_600)
        XCTAssertEqual(detail.night.stageSamples.first?.start, detail.night.start)
        XCTAssertEqual(detail.night.stageSamples.last?.end, detail.night.end)
        XCTAssertEqual(detail.night.stageSamples.reduce(0) { $0 + $1.durationSeconds }, 8 * 3_600)
        XCTAssertEqual(detail.trends.map(\.id), FitnessSleepTrendID.allCases)
        XCTAssertTrue(detail.trends.allSatisfy { $0.metric.quality == .demo })
        XCTAssertTrue(detail.trends.allSatisfy { $0.availableSeriesRanges == [.seven, .fourteen, .thirty] })
        XCTAssertTrue(detail.trends.allSatisfy { $0.evidence.summary.contains("DEMO · NOT LIVE") })
        XCTAssertFalse(detail.schedule.isUnavailable)
        XCTAssertFalse(detail.sleepNeed.isUnavailable)
        XCTAssertFalse(detail.windDown.isUnavailable)
        guard let insight = detail.insights.first else {
            return XCTFail("Demo sleep detail must include an explicit insight state")
        }
        if case .demo(let text, _, let provenance) = insight.state {
            XCTAssertTrue(text.localizedCaseInsensitiveContains("proprietary"))
            XCTAssertTrue(provenance.contains("DEMO"))
        } else {
            XCTFail("Demo sleep insight must remain explicitly demo and honest about proprietary scoring")
        }
        let duration = detail.trends.first(where: { $0.id == .duration })!
        XCTAssertNotEqual(duration.series(for: .seven), duration.series(for: .fourteen))
        XCTAssertNotEqual(duration.series(for: .fourteen), duration.series(for: .thirty))
    }

    func testSourceCopyWithMissingObservedProvenanceBecomesUnavailable() {
        let copy = FitnessSourceCopy(state: .observed(text: "A claim", window: "Today", provenance: " "))
        XCTAssertTrue(copy.isUnavailable)
        XCTAssertNil(copy.text)
    }

    func testHeartRateZoneDurationsParseAndReconcileToWorkoutDuration() {
        let zones = [
            FitnessHeartRateZone(zone: 0, duration: "00:05:23", range: "0–99 bpm", provenance: "HealthKit"),
            FitnessHeartRateZone(zone: 1, duration: "00:36:23", range: "100–119 bpm", provenance: "HealthKit"),
            FitnessHeartRateZone(zone: 2, duration: "00:15:46", range: "120–139 bpm", provenance: "HealthKit")
        ].compactMap { $0 }
        let detail = FitnessLoadDetail(
            duration: FitnessMetric(title: "Training duration", value: "57", unit: "min", detail: "Observed workout duration", quality: .observed),
            heartRateZones: zones
        )

        XCTAssertEqual(zones.map(\.durationSeconds), [323, 2183, 946])
        XCTAssertEqual(detail.zoneDurationSeconds, 3452)
        if case .matched(let zoneSeconds, let workoutSeconds) = detail.durationReconciliation {
            XCTAssertEqual(zoneSeconds, 3452)
            XCTAssertEqual(workoutSeconds, 3420)
        } else {
            XCTFail("Expected a one-minute display-rounding delta to reconcile")
        }

        let mismatch = FitnessLoadDetail(
            duration: FitnessMetric(title: "Training duration", value: "56", unit: "min", detail: "Observed workout duration", quality: .observed),
            heartRateZones: zones
        )
        if case .mismatch(let zoneSeconds, let workoutSeconds) = mismatch.durationReconciliation {
            XCTAssertEqual(zoneSeconds, 3452)
            XCTAssertEqual(workoutSeconds, 3360)
        } else {
            XCTFail("Expected a larger disagreement to remain visible")
        }
    }

    func testDurationParserSupportsClockAndExplicitUnits() {
        XCTAssertEqual(FitnessDurationParser.seconds(value: "01:02:03"), 3723)
        XCTAssertEqual(FitnessDurationParser.seconds(value: "12:30"), 750)
        XCTAssertEqual(FitnessDurationParser.seconds(value: "1.5", unit: "h"), 5400)
        XCTAssertNil(FitnessDurationParser.seconds(value: "01:72"))
    }

    func testLoadTrendCardsExposeObservedUnavailableAndTargetTruth() {
        let target = FitnessLoadTargetBand(lower: 20, upper: 40, unit: "%")
        let observed = FitnessLoadTrendCard(
            id: .load,
            metric: FitnessMetric(title: "Load", value: "55", unit: "%", detail: "Observed", quality: .observed),
            evidence: FitnessSourceEvidence(state: .observed(source: "HealthKit", device: "Helio", window: "Today", freshness: "4 min ago")),
            target: target,
            availableRanges: [.seven, .fourteen]
        )
        let missing = FitnessLoadTrendCard(id: .steps, metric: .unavailable("Steps"))
        XCTAssertEqual(observed.truth, .overTarget)
        XCTAssertEqual(observed.evidence.summary, "HealthKit · Helio · Today · 4 min ago")
        XCTAssertEqual(missing.truth, .unavailable(reason: "Connect a reviewed source to see this metric."))
        XCTAssertEqual(observed.availableRanges, [.seven, .fourteen])

        let energy = FitnessLoadTrendCard(
            id: .totalEnergy,
            metric: FitnessMetric(title: "Total energy", value: "1.935", unit: "kcal", detail: "Observed", quality: .observed),
            target: FitnessLoadTargetBand(lower: 1_000, upper: 1_500, unit: "kcal")
        )
        XCTAssertEqual(energy.truth, .unavailable(reason: "Observed"))
    }

    func testRecoveryTrendEvidenceDoesNotBorrowSnapshotFreshness() {
        let metric = FitnessMetric(title: "HRV", value: "52", unit: "ms", detail: "Observed", quality: .observed)
        let evidence = FitnessSourceEvidence(state: .observed(source: "Helio Strap", device: "Helio", window: "Overnight", freshness: "2 h ago"))
        let card = FitnessRecoveryTrendCard(id: .restingHRV, metric: metric, evidence: evidence, availableRanges: [.three])
        let detail = FitnessRecoveryDetail(trends: [card])

        XCTAssertEqual(detail.trends.first?.evidence.summary, "Helio Strap · Helio · Overnight · 2 h ago")
        XCTAssertEqual(detail.trends.first?.availableRanges, [.three])
    }

    func testDemoLoadDetailSuppliesAllFiveTypedTrendCardsWithFixtureTruth() {
        let cards = FitnessSnapshot.demo.loadDetail.trendCards

        XCTAssertEqual(cards.map(\.id), FitnessLoadTrendID.allCases)
        XCTAssertTrue(cards.allSatisfy { $0.metric.quality == .demo })
        XCTAssertTrue(cards.allSatisfy { $0.evidence.summary.contains("DEMO · NOT LIVE") })
        XCTAssertTrue(cards.allSatisfy { $0.availableRanges == [.seven, .fourteen, .thirty] })
        XCTAssertNotNil(cards.first(where: { $0.id == .load })?.target)
        XCTAssertTrue(cards.filter { $0.id != .load }.allSatisfy { $0.target == nil })
        XCTAssertTrue(cards.allSatisfy { $0.truth == .demo })
    }

    func testDemoRecoveryTrendsExposeOnlyExplicitFixtureRanges() {
        let detail = FitnessRecoveryDetail.from(
            readiness: FitnessMetric(title: "Readiness", value: "78", unit: "/100", detail: "Fixture", quality: .demo),
            healthMonitor: [
                FitnessMetric(title: "HRV", value: "52", unit: "ms", detail: "Fixture", quality: .demo)
            ]
        )

        let demoTrends = detail.trends.filter { $0.metric.quality == .demo }
        let unavailableTrends = detail.trends.filter { $0.metric.quality == .unavailable }
        XCTAssertEqual(demoTrends.map(\.id), [.recovery, .restingHRV])
        XCTAssertTrue(demoTrends.allSatisfy { $0.availableRanges == [.seven, .fourteen, .thirty] })
        XCTAssertTrue(demoTrends.allSatisfy { $0.evidence.summary.contains("DEMO · NOT LIVE") })
        XCTAssertTrue(unavailableTrends.allSatisfy { $0.availableRanges.isEmpty })
        XCTAssertTrue(unavailableTrends.allSatisfy {
            if case .unavailable = $0.evidence.state { return true }
            return false
        })
    }

    func testTrendSeriesPreservesRealMinutesAndBPMAndNormalizesOnlyForRendering() {
        let evidence = FitnessSourceEvidence(state: .observed(
            source: "HealthKit",
            device: "Helio Strap",
            window: "Seven nights",
            freshness: "2 h ago"
        ))
        let duration = FitnessSleepTrendCard(
            id: .duration,
            metric: FitnessMetric(title: "Sleep duration", value: "8h 0m", unit: "min", detail: "Observed", quality: .observed),
            evidence: evidence,
            availableRanges: [.seven],
            seriesByRange: [.seven: [420, 480, 540]]
        )
        let durationSeries = FitnessTrendSeries(values: duration.series(for: .seven)!)!
        XCTAssertEqual(duration.series(for: .seven), [420, 480, 540])
        XCTAssertEqual(durationSeries.normalized, [0, 0.5, 1])
        XCTAssertEqual(durationSeries.context(unit: "min"), "Range 420–540 min · Δ +120 min")

        let heartRate = FitnessRecoveryTrendCard(
            id: .restingHeartRate,
            metric: FitnessMetric(title: "Resting heart rate", value: "52", unit: "bpm", detail: "Observed", quality: .observed),
            evidence: evidence,
            availableRanges: [.seven],
            seriesByRange: [.seven: [54, 58, 52]]
        )
        XCTAssertEqual(heartRate.series(for: .seven), [54, 58, 52])
        XCTAssertEqual(FitnessTrendSeries(values: heartRate.series(for: .seven)!)!.context(unit: "bpm"), "Range 52–58 bpm · Δ −2 bpm")
    }

    func testUnavailableOrUnprovenancedMetricsRejectTrendSeriesAndRanges() {
        let stale = FitnessSleepTrendCard(
            id: .duration,
            metric: .unavailable("Sleep duration"),
            evidence: FitnessSourceEvidence(state: .observed(source: "HealthKit", device: "Helio", window: "Tonight", freshness: "Now")),
            availableRanges: [.seven],
            seriesByRange: [.seven: [420, 480]]
        )
        XCTAssertTrue(stale.availableRanges.isEmpty)
        XCTAssertTrue(stale.availableSeriesRanges.isEmpty)
        XCTAssertNil(stale.series(for: .seven))

        for quality in [FitnessMetric.Quality.observed, .derived, .manual] {
            let metric = FitnessMetric(title: "Sleep duration", value: "480", unit: "min", detail: "Value without provenance", quality: quality)
            let evidence = FitnessSourceEvidence.from(metric: metric)
            if case .unavailable = evidence.state {
                // Expected: a value without source/device/window/freshness is not usable evidence.
            } else {
                XCTFail("\(quality.label) metric without provenance must be unavailable")
            }
            let card = FitnessSleepTrendCard(id: .duration, metric: metric, availableRanges: [.seven], seriesByRange: [.seven: [420, 480]])
            XCTAssertTrue(card.availableRanges.isEmpty)
            XCTAssertNil(card.series(for: .seven))
        }
    }

    func testMetricStatePreservesPartialStaleAndPermissionSemantics() throws {
        let provenance = try XCTUnwrap(FitnessMetric.Provenance(
            source: "HealthKit",
            device: "Helio Strap",
            window: "Rolling 7 days",
            freshness: "2 hours ago",
            observationID: "hrv-1",
            revision: "sync:12"
        ))
        let partial = FitnessMetric(
            title: "HRV",
            value: "52",
            unit: "ms",
            detail: "Some source pages are still pending",
            quality: .observed,
            sourceState: .partial,
            provenance: provenance
        )
        XCTAssertTrue(partial.isValueAvailable)
        XCTAssertEqual(FitnessSourceEvidence.from(metric: partial).statusLabel, "Partial")
        XCTAssertTrue(FitnessSourceEvidence.from(metric: partial).isPartial)

        let denied = FitnessMetric.unavailable(
            "Respiration",
            reason: "HealthKit read permission is required.",
            sourceState: .permissionRequired
        )
        XCTAssertFalse(denied.isValueAvailable)
        XCTAssertEqual(FitnessSourceEvidence.from(metric: denied).statusLabel, "Permission required")
        XCTAssertTrue(FitnessSourceEvidence.from(metric: denied).isUnavailable)

        let trend = FitnessLoadTrendCard(id: .load, metric: partial, availableRanges: [.seven])
        XCTAssertEqual(trend.truth, .partial)
        XCTAssertEqual(trend.availableRanges, [.seven])
    }

    func testSleepEvidencePreservesPermissionStaleAndConflictStates() {
        let permission = FitnessSleepObservationEvidence(state: .permissionRequired(
            reason: "HealthKit sleep read permission is required."
        ))
        XCTAssertTrue(permission.isUnavailable)
        XCTAssertEqual(permission.statusLabel, "Permission required")
        XCTAssertTrue(permission.summary.contains("HealthKit sleep read permission"))

        let stale = FitnessSleepObservationEvidence(state: .stale(
            reason: "The retained sleep interval is outside its freshness window."
        ))
        XCTAssertFalse(stale.isUnavailable)
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.statusLabel, "Stale")

        let conflict = FitnessSleepObservationEvidence(state: .conflict(
            reason: "Two source sleep revisions overlap."
        ))
        XCTAssertTrue(conflict.isUnavailable)
        XCTAssertEqual(conflict.statusLabel, "Conflict")
        XCTAssertTrue(conflict.summary.contains("overlap"))
    }
}
