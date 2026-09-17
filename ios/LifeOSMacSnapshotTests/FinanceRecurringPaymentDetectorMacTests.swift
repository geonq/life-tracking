import XCTest
@testable import LifeOSMac

final class FinanceRecurringPaymentDetectorMacTests: XCTestCase {
    func testIdentityIsDeterministicAndExcludesUnstableTransactionFields() throws {
        let key = try FinanceRecurringPaymentKey(
            sourceNamespace: "genericCSV",
            accountID: FinanceRecurringTestFixtures.accountID,
            currency: "eur",
            normalizedMerchantKey: "streaming provider"
        )
        let sameKey = try FinanceRecurringPaymentKey(
            sourceNamespace: "genericCSV",
            accountID: FinanceRecurringTestFixtures.accountID,
            currency: "EUR",
            normalizedMerchantKey: "streaming provider"
        )
        let otherAccount = try FinanceRecurringPaymentKey(
            sourceNamespace: "genericCSV",
            accountID: UUID(uuidString: "00000000-0000-4000-8000-000000000402")!,
            currency: "EUR",
            normalizedMerchantKey: "streaming provider"
        )

        XCTAssertEqual(key, sameKey)
        XCTAssertEqual(try key.canonicalData(), try sameKey.canonicalData())
        XCTAssertEqual(key.stableID.count, 64)
        XCTAssertNotEqual(key, otherAccount)
        XCTAssertEqual(
            FinanceRecurringPaymentDetector.normalizedMerchantKey("  Streaming—Provider  "),
            "streaming provider"
        )
    }

    func testDetectsHighConfidenceMonthlyMonthEndPatternAndPredictsNextDate() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 28)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 30))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 5, 1)
        )
        let candidate = try XCTUnwrap(assessment.candidates.first)

        XCTAssertEqual(assessment.candidates.count, 1)
        XCTAssertEqual(candidate.detectedCadence, .monthly)
        XCTAssertEqual(candidate.confidence, .high)
        XCTAssertTrue(candidate.reasonCodes.isEmpty)
        XCTAssertEqual(candidate.supportingEvidence.count, 4)

        let predicted = try XCTUnwrap(candidate.predictedDate)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(calendar.component(.month, from: predicted), 5)
        XCTAssertEqual(calendar.component(.day, from: predicted), 31)
    }

    func testEarlyMonthlyPaymentsPredictTheFollowingConsumedPeriod() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 27)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 29))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2026, 5, 1)
            ).candidates.first
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        XCTAssertEqual(candidate.detectedCadence, .monthly)
        XCTAssertEqual(candidate.lastConsumedPeriodIndex, 3)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(candidate.predictedDate)), 5)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.predictedDate)), 31)
    }

    func testEarlyYearlyPaymentsPredictTheFollowingConsumedYear() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2024, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2025, 1, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 29)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2027, 1, 28))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2027, 2, 1)
            ).candidates.first
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        XCTAssertEqual(candidate.detectedCadence, .yearly)
        XCTAssertEqual(candidate.lastConsumedPeriodIndex, 3)
        XCTAssertEqual(calendar.component(.year, from: try XCTUnwrap(candidate.predictedDate)), 2028)
        XCTAssertEqual(calendar.component(.month, from: try XCTUnwrap(candidate.predictedDate)), 1)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.predictedDate)), 31)
    }

    func testRepeatedSixDayPaymentsDoNotBecomeAHighConfidenceWeeklyPrediction() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 7)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 19))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2026, 1, 20)
            ).candidates.first
        )

        XCTAssertEqual(candidate.detectedCadence, .weekly)
        XCTAssertEqual(candidate.confidence, .needsReview)
        XCTAssertTrue(candidate.reasonCodes.contains(.scheduleDrift))
        XCTAssertNil(candidate.predictedDate)
    }

    func testRepeatedEightDayPaymentsDoNotBecomeAHighConfidenceWeeklyPrediction() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 9)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 17)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 25))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2026, 1, 26)
            ).candidates.first
        )

        XCTAssertEqual(candidate.detectedCadence, .weekly)
        XCTAssertEqual(candidate.confidence, .needsReview)
        XCTAssertTrue(candidate.reasonCodes.contains(.scheduleDrift))
        XCTAssertNil(candidate.predictedDate)
    }

    func testWeeklyScanResetsAnchorAfterGapAndPredictsFromLaterRun() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 3)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 10)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 17)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 24))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2026, 3, 1)
            ).candidates.first
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        XCTAssertEqual(candidate.detectedCadence, .weekly)
        XCTAssertEqual(candidate.confidence, .high)
        XCTAssertEqual(candidate.supportingEvidence.count, 4)
        XCTAssertEqual(candidate.anchor.date, transactions[1].bookedAt)
        XCTAssertEqual(candidate.lastConsumedPeriodIndex, 3)
        let predicted = try XCTUnwrap(candidate.predictedDate)
        XCTAssertEqual(calendar.component(.month, from: predicted), 3)
        XCTAssertEqual(calendar.component(.day, from: predicted), 3)
        XCTAssertGreaterThan(predicted, transactions.last!.bookedAt)
    }

    func testLaterEligiblePaymentSuppressesPredictionOutsideWinningRun() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 8)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 15)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 22)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 10))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2026, 3, 11)
            ).candidates.first
        )

        XCTAssertEqual(candidate.detectedCadence, .weekly)
        XCTAssertEqual(candidate.supportingEvidence.count, 4)
        XCTAssertEqual(candidate.latestEligiblePaymentDate, transactions.last?.bookedAt)
        XCTAssertTrue(candidate.reasonCodes.contains(.scheduleDrift))
        XCTAssertEqual(candidate.confidence, .needsReview)
        XCTAssertNil(candidate.predictedDate)
    }

    func testOnlyMappedNegativeCashRowsWithEvidenceCanBecomeCandidates() throws {
        let valid = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let legacy = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 6),
            identityScheme: .legacyV2,
            hasMappedIdentity: false
        )
        let income = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 7),
            amountCents: 10_000,
            category: FinanceTransactionCategory.income.rawValue
        )
        let missingEvidence = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 14)
        )
        let transactions = valid + [legacy, income, missingEvidence]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: valid + [legacy, income])]
        )
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 2, 1)
        )

        XCTAssertEqual(assessment.candidates.count, 1)
        XCTAssertEqual(assessment.exclusions.first(where: { $0.reason == .unsupportedLegacyIdentity })?.count, 1)
        XCTAssertEqual(assessment.exclusions.first(where: { $0.reason == .income })?.count, 1)
        XCTAssertNil(assessment.exclusions.first(where: { $0.reason == .missingProvenance }))
    }

    func testNegativeCashClassificationsAndKeywordsAreRejectedBeforeGrouping() throws {
        let valid = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let income = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 2),
            description: "Salary reversal",
            category: FinanceTransactionCategory.income.rawValue
        )
        let refund = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 3),
            description: "Refund from merchant"
        )
        let transfer = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 4),
            description: "Account movement",
            category: FinanceTransactionCategory.transfers.rawValue
        )
        let transferKeyword = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 5),
            description: "SEPA transfer to savings"
        )
        let investment = try FinanceRecurringTestFixtures.transaction(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 7),
            description: "Broker order",
            category: FinanceTransactionCategory.investments.rawValue,
            kind: .investmentOrder,
            investment: FinanceImportedInvestmentDetails(symbol: "VWCE", tradeType: "buy")
        )
        let excluded = [income, refund, transfer, transferKeyword, investment]
        let all = valid + excluded
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: all,
            batches: [FinanceRecurringTestFixtures.batch(for: all)]
        )
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 2, 1)
        )

        XCTAssertEqual(assessment.candidates.count, 1)
        XCTAssertEqual(assessment.exclusions.first(where: { $0.reason == .income })?.count, 1)
        XCTAssertEqual(assessment.exclusions.first(where: { $0.reason == .refund })?.count, 1)
        XCTAssertEqual(assessment.exclusions.first(where: { $0.reason == .transfer })?.count, 2)
        XCTAssertEqual(assessment.exclusions.first(where: { $0.reason == .investmentOrder })?.count, 1)
    }

    func testMappedV3RowsWithoutBatchProvenanceRemainEligibleWithUnavailableMetadata() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(transactions: transactions, batches: [])
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 2, 1)
        )
        let candidate = try XCTUnwrap(assessment.candidates.first)

        XCTAssertEqual(candidate.supportingEvidence.count, 4)
        XCTAssertTrue(candidate.supportingEvidence.allSatisfy { $0.batchID == nil && $0.sourceRowNumber == nil })
    }

    func testMultiplePaymentsInOneCalendarPeriodRemainNeedsReview() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 2)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 2)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 2))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 4, 1)
        )
        let candidate = try XCTUnwrap(assessment.candidates.first)

        XCTAssertEqual(candidate.detectedCadence, .monthly)
        XCTAssertEqual(candidate.confidence, .needsReview)
        XCTAssertTrue(candidate.reasonCodes.contains(.multiplePaymentsInPeriod))
    }

    func testConflictingDuplicateTransactionIDFailsClosed() throws {
        let id = UUID()
        let first = try FinanceRecurringTestFixtures.transaction(
            id: id,
            date: try FinanceRecurringTestFixtures.date(2026, 1, 1)
        )
        let conflicting = try FinanceRecurringTestFixtures.transaction(
            id: id,
            date: try FinanceRecurringTestFixtures.date(2026, 1, 1),
            amountCents: -1_300
        )

        XCTAssertThrowsError(
            try FinanceRecurringPaymentDetector.makeInput(
                transactions: [first, conflicting],
                batches: []
            )
        ) { error in
            XCTAssertEqual(error as? FinanceRecurringPaymentDetectorError, .conflictingTransactionID)
        }
    }

    func testCalendarPredictionDoesNotDriftAfterFebruaryClamp() throws {
        let anchor = try FinanceRecurringAnchor(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 31),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let afterFebruary = try FinanceRecurringTestFixtures.date(2026, 2, 28, hour: 10)
        let next = try FinanceRecurringPaymentDetector.nextExpectedDate(
            cadence: .monthly,
            anchor: anchor,
            after: afterFebruary
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        XCTAssertEqual(calendar.component(.month, from: next), 3)
        XCTAssertEqual(calendar.component(.day, from: next), 31)
    }

    func testWinningCadenceCarriesTheWinningRunAnchor() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 28)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 30)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 5, 31))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 6, 1)
        )
        let candidate = try XCTUnwrap(assessment.candidates.first)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        XCTAssertEqual(candidate.confidence, .high)
        XCTAssertEqual(calendar.component(.day, from: candidate.anchor.date), 28)
        XCTAssertEqual(calendar.component(.day, from: try XCTUnwrap(candidate.predictedDate)), 28)
    }

    func testAdjacentMonthBoundaryIsToleratedWithoutLosingMonthlyCadence() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 31)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 2, 28)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 3, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 4, 1)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 5, 1))
        ]
        let input = try FinanceRecurringPaymentDetector.makeInput(
            transactions: transactions,
            batches: [FinanceRecurringTestFixtures.batch(for: transactions)]
        )
        let candidate = try XCTUnwrap(
            try FinanceRecurringPaymentDetector.detect(
                input: input,
                now: try FinanceRecurringTestFixtures.date(2026, 6, 1)
            ).candidates.first
        )

        XCTAssertEqual(candidate.detectedCadence, .monthly)
        XCTAssertTrue(candidate.reasonCodes.contains(.multiplePaymentsInPeriod))
    }

    func testLeapYearAndDSTPredictionsStayInCalendarSpace() throws {
        let leapAnchor = try FinanceRecurringAnchor(
            date: try FinanceRecurringTestFixtures.date(2024, 2, 29),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let afterLeap = try FinanceRecurringTestFixtures.date(2025, 2, 28, hour: 10)
        let nextLeap = try FinanceRecurringPaymentDetector.nextExpectedDate(
            cadence: .yearly,
            anchor: leapAnchor,
            after: afterLeap
        )
        let weeklyAnchor = try FinanceRecurringAnchor(
            date: try FinanceRecurringTestFixtures.date(2026, 3, 22, hour: 9),
            timeZoneIdentifier: "Europe/Berlin"
        )
        let nextDST = try FinanceRecurringPaymentDetector.nextExpectedDate(
            cadence: .weekly,
            anchor: weeklyAnchor,
            after: try FinanceRecurringTestFixtures.date(2026, 3, 22, hour: 10)
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))

        XCTAssertEqual(calendar.component(.year, from: nextLeap), 2026)
        XCTAssertEqual(calendar.component(.day, from: nextLeap), 28)
        XCTAssertEqual(calendar.component(.day, from: nextDST), 29)
        XCTAssertEqual(calendar.component(.hour, from: nextDST), 9)
    }

    func testUnsupportedVersionsAndNestedAuthorityAreRejected() throws {
        XCTAssertThrowsError(
            try FinanceRecurringPaymentKey(
                sourceNamespace: "genericCSV",
                accountID: FinanceRecurringTestFixtures.accountID,
                currency: "EUR",
                normalizedMerchantKey: "streaming provider",
                normalizationVersion: "merchant-v2"
            )
        )

        let transactionID = UUID()
        let key = try FinanceRecurringPaymentKey(
            sourceNamespace: "genericCSV",
            accountID: FinanceRecurringTestFixtures.accountID,
            currency: "EUR",
            normalizedMerchantKey: "streaming provider"
        )
        let evidence = try FinanceRecurringEvidenceReference(
            sourceNamespace: key.sourceNamespace,
            transactionID: transactionID
        )
        let nonBerlinAnchor = try FinanceRecurringAnchor(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 1),
            timeZoneIdentifier: "UTC"
        )
        XCTAssertThrowsError(
            try FinanceRecurringPaymentCandidate(
                key: key,
                supportingEvidence: [evidence],
                detectedCadence: .monthly,
                confidence: .needsReview,
                reasonCodes: [.minimumHistoryOnly],
                anchor: nonBerlinAnchor,
                predictedDate: nil,
                detectorVersion: "recurring-v2"
            )
        )

        let candidate = try FinanceRecurringPaymentCandidate(
            key: key,
            supportingEvidence: [evidence],
            detectedCadence: .monthly,
            confidence: .needsReview,
            reasonCodes: [.minimumHistoryOnly],
            anchor: nonBerlinAnchor,
            predictedDate: nil
        )
        XCTAssertThrowsError(
            try FinanceRecurringPaymentAssessment(
                candidates: [candidate],
                exclusions: [],
                coverage: .mappedImportsOnly,
                timeZoneIdentifier: "Europe/Berlin"
            )
        )
    }

    func testLatestEligiblePaymentDateRoundTripsAndLegacyCandidateDecodes() throws {
        let key = try FinanceRecurringPaymentKey(
            sourceNamespace: "genericCSV",
            accountID: FinanceRecurringTestFixtures.accountID,
            currency: "EUR",
            normalizedMerchantKey: "streaming provider"
        )
        let evidence = try FinanceRecurringEvidenceReference(
            sourceNamespace: key.sourceNamespace,
            transactionID: UUID()
        )
        let anchor = try FinanceRecurringAnchor(
            date: try FinanceRecurringTestFixtures.date(2026, 1, 1),
            timeZoneIdentifier: FinanceRecurringPaymentContract.defaultTimeZoneIdentifier
        )
        let latest = try FinanceRecurringTestFixtures.date(2026, 3, 10)
        let candidate = try FinanceRecurringPaymentCandidate(
            key: key,
            supportingEvidence: [evidence],
            detectedCadence: .weekly,
            confidence: .needsReview,
            reasonCodes: [.scheduleDrift],
            anchor: anchor,
            predictedDate: nil,
            latestEligiblePaymentDate: latest
        )
        let encoder = JSONEncoder.lifeOS
        let decoder = JSONDecoder.lifeOS
        let encoded = try encoder.encode(candidate)
        let decoded = try decoder.decode(FinanceRecurringPaymentCandidate.self, from: encoded)
        XCTAssertEqual(decoded.latestEligiblePaymentDate, latest)

        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacyObject.removeValue(forKey: "latestEligiblePaymentDate")
        let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
        let legacyCandidate = try decoder.decode(FinanceRecurringPaymentCandidate.self, from: legacyData)
        XCTAssertNil(legacyCandidate.latestEligiblePaymentDate)
    }

    func testCachedAssessmentRejectsAnInputWhoseEligibilityChanged() throws {
        let transactions = try [
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 6)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 13)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 20)),
            FinanceRecurringTestFixtures.transaction(date: try FinanceRecurringTestFixtures.date(2026, 1, 27))
        ]
        let batch = try FinanceRecurringTestFixtures.batch(for: transactions)
        let input = try FinanceRecurringPaymentDetector.makeInput(transactions: transactions, batches: [batch])
        let assessment = try FinanceRecurringPaymentDetector.detect(
            input: input,
            now: try FinanceRecurringTestFixtures.date(2026, 2, 1)
        )
        let changed = try FinanceRecurringTestFixtures.transaction(
            id: transactions[0].id,
            date: transactions[0].bookedAt,
            category: FinanceTransactionCategory.income.rawValue
        )
        let changedInput = try FinanceRecurringPaymentDetector.makeInput(
            transactions: [changed] + Array(transactions.dropFirst()),
            batches: [try FinanceRecurringTestFixtures.batch(for: [changed] + Array(transactions.dropFirst()))]
        )

        XCTAssertFalse(FinanceRecurringPaymentDetector.validateCachedAssessment(assessment, for: changedInput))
    }
}
