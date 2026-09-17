import Foundation
import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
final class FinanceRobinhoodInvestmentMacTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01 UTC

    func testObservedRobinhoodSchemaPreservesExactValuesAndKeepsNetWorthGated() throws {
        let result = try importFixture()
        XCTAssertEqual(result.activities.count, 6)
        XCTAssertEqual(result.coverage, .activitiesOnly)
        XCTAssertEqual(
            result.productionGate,
            .blockedMissingAccountSnapshotAndValuationEvidence
        )
        XCTAssertEqual(
            result.evidence.headerFingerprint,
            FinanceInvestmentContract.robinhoodActivityHeaderFingerprint
        )
        XCTAssertEqual(result.evidence.dataRowCount, 6)

        let purchase = try XCTUnwrap(result.activities.first { $0.kind == .buy })
        XCTAssertEqual(purchase.quantity?.rawValue, "0.12345678901234567890")
        XCTAssertEqual(purchase.instrumentPrice?.amount.rawValue, "1000.0000000000")
        XCTAssertEqual(purchase.instrumentPrice?.currency, "EUR")
        XCTAssertEqual(purchase.fees?.amount.rawValue, "1.23")
    }

    func testObservedActivityTypesAreClassifiedWithoutGuessingRewards() throws {
        let result = try importFixture()
        let kinds = Dictionary(uniqueKeysWithValues: result.activities.map { ($0.rawTransactionType, $0.kind) })

        XCTAssertEqual(kinds["SEPA Deposit"], .deposit)
        XCTAssertEqual(kinds["Crypto Deposit"], .deposit)
        XCTAssertEqual(kinds["Crypto Purchase"], .buy)
        XCTAssertEqual(kinds["Crypto Sale"], .sell)
        XCTAssertEqual(kinds["Staking Earnings"], .interest)
        XCTAssertEqual(kinds["Crypto Reward"], .unknown)
    }

    func testUnsupportedSchemaUnknownTypeAndMalformedCSVFailClosed() throws {
        let unknownHeader = fixture.replacingOccurrences(of: "Activity Date,", with: "Unknown Date,", options: [], range: fixture.startIndex..<fixture.endIndex)
        XCTAssertThrowsError(try FinanceRobinhoodImporter.importCSV(
            Data(unknownHeader.utf8), accountID: "robinhood-primary", observedAt: observedAt
        )) { error in
            XCTAssertEqual(error as? FinanceRobinhoodImportError, .unsupportedSchema)
        }

        let unknownType = fixture.replacingOccurrences(of: "Crypto Sale", with: "Mystery Action")
        XCTAssertThrowsError(try FinanceRobinhoodImporter.importCSV(
            Data(unknownType.utf8), accountID: "robinhood-primary", observedAt: observedAt
        )) { error in
            guard case .unsupportedActivityType = error as? FinanceRobinhoodImportError else {
                return XCTFail("Expected an unsupported activity type")
            }
        }

        let malformed = "Activity Date,Transaction Type,Instrument,Instrument Quantity,Instrument Price,Fees,Debit,Credit,\n2026-01-01,Crypto Purchase,\"BTC,0.1,€100.00,€1.00,€11.00,-,\n"
        XCTAssertThrowsError(try FinanceRobinhoodImporter.importCSV(
            Data(malformed.utf8), accountID: "robinhood-primary", observedAt: observedAt
        )) { error in
            XCTAssertEqual(error as? FinanceRobinhoodImportError, .malformedCSV)
        }
    }

    func testVerifiedFooterAndSeparatorAreIgnoredWithoutPersistingFooterText() throws {
        let result = try FinanceRobinhoodImporter.importCSV(
            Data(footerFixture.utf8),
            accountID: "robinhood-primary",
            observedAt: observedAt
        )
        XCTAssertEqual(result.activities.count, 39)
        XCTAssertEqual(result.evidence.dataRowCount, 39)
        XCTAssertEqual(result.evidence.blankRowsSkipped, 1)
        XCTAssertFalse(result.evidence.fileSHA256.contains("personal"))

        let lines = footerFixture.split(whereSeparator: \.isNewline).map(String.init)
        let nonTerminalFooter = ([lines[0], lines[lines.count - 1]] + lines.dropFirst().dropLast()).joined(separator: "\n")
        XCTAssertThrowsError(try FinanceRobinhoodImporter.importCSV(
            Data(nonTerminalFooter.utf8), accountID: "robinhood-primary", observedAt: observedAt
        )) { error in
            guard case .invalidRow = error as? FinanceRobinhoodImportError else {
                return XCTFail("Expected a nonterminal footer to be rejected")
            }
        }
    }

    func testActivityIdentityIsStableAcrossReorderingAndDuplicatesFailClosed() throws {
        let lines = fixture.split(whereSeparator: \.isNewline).map(String.init)
        let reordered = ([lines[0]] + lines.dropFirst().reversed()).joined(separator: "\n") + "\n"
        let original = try importFixture()
        let reorderedResult = try FinanceRobinhoodImporter.importCSV(
            Data(reordered.utf8), accountID: "robinhood-primary", observedAt: observedAt
        )
        XCTAssertEqual(Set(original.activities.map(\.id)), Set(reorderedResult.activities.map(\.id)))

        let duplicate = (lines + [lines[1]]).joined(separator: "\n") + "\n"
        XCTAssertThrowsError(try FinanceRobinhoodImporter.importCSV(
            Data(duplicate.utf8), accountID: "robinhood-primary", observedAt: observedAt
        )) { error in
            XCTAssertEqual(error as? FinanceRobinhoodImportError, .duplicateActivityIdentity)
        }
    }

    func testRequiredActivityValuesAndFXConversionsFailClosed() throws {
        let missingQuantity = fixture.replacingOccurrences(
            of: "0.12345678901234567890", with: "-"
        )
        XCTAssertThrowsError(try FinanceRobinhoodImporter.importCSV(
            Data(missingQuantity.utf8), accountID: "robinhood-primary", observedAt: observedAt
        ))

        let mismatchedEUR = try FinanceInvestmentValuationEvidence(
            priceSource: "snapshot", priceObservedAt: observedAt
        )
        XCTAssertThrowsError(try FinanceInvestmentHoldingValuation(
            nativeValue: try FinanceInvestmentMoney(amount: "1.00", currency: "EUR"),
            eurValue: try FinanceInvestmentMoney(amount: "2.00", currency: "EUR"),
            evidence: mismatchedEUR
        ))

        let mismatchedFX = try FinanceInvestmentValuationEvidence(
            priceSource: "snapshot",
            priceObservedAt: observedAt,
            fxSource: "fx",
            fxObservedAt: observedAt,
            fxRate: try FinanceExactDecimal("0.30")
        )
        XCTAssertThrowsError(try FinanceInvestmentHoldingValuation(
            nativeValue: try FinanceInvestmentMoney(amount: "100.00", currency: "USD"),
            eurValue: try FinanceInvestmentMoney(amount: "25.00", currency: "EUR"),
            evidence: mismatchedFX
        ))
    }

    func testFreshPriceWithStaleFXBlocksHoldingValuation() throws {
        let staleFXDate = observedAt.addingTimeInterval(-91 * 24 * 60 * 60)
        let holding = try FinanceInvestmentHoldingObservation(
            id: "btc-stale-fx",
            assetIdentifier: "BTC",
            quantity: try FinanceExactDecimal("1"),
            assetCurrency: "USD",
            valuation: try FinanceInvestmentHoldingValuation(
                nativeValue: try FinanceInvestmentMoney(amount: "100.00", currency: "USD"),
                eurValue: try FinanceInvestmentMoney(amount: "25.00", currency: "EUR"),
                evidence: try FinanceInvestmentValuationEvidence(
                    priceSource: "fresh-price",
                    priceObservedAt: observedAt,
                    fxSource: "stale-fx",
                    fxObservedAt: staleFXDate,
                    fxRate: try FinanceExactDecimal("0.25")
                )
            )
        )
        let snapshot = try FinanceInvestmentAccountSnapshot(
            source: try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary"),
            observedAt: observedAt,
            holdings: [holding],
            cashCoverage: .complete,
            holdingsCoverage: .complete
        )
        let breakdown = try FinanceNetWorthBreakdown(
            bankCash: [],
            investmentSnapshots: [snapshot],
            asOf: observedAt
        )

        XCTAssertNotEqual(breakdown.availability, .complete)
        XCTAssertTrue(breakdown.components.contains {
            $0.kind == .investmentHoldings && $0.exclusionReason == .staleObservation
        })
    }

    func testAccountCoverageDistinguishesUnknownFromVerifiedEmpty() throws {
        let source = try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary")
        let cash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-snapshot",
            verificationID: "cash-only"
        )
        let cashOnly = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            verifiedCash: cash,
            cashCoverage: .complete,
            holdingsCoverage: .unknown
        )
        let cashOnlyBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [], investmentSnapshots: [cashOnly], asOf: observedAt
        )
        XCTAssertEqual(cashOnlyBreakdown.availability, .partial)
        XCTAssertTrue(cashOnlyBreakdown.components.contains {
            $0.exclusionReason == .incompleteAccountCoverage
        })

        let holding = try FinanceInvestmentHoldingObservation(
            id: "eth-only",
            assetIdentifier: "ETH",
            quantity: try FinanceExactDecimal("1"),
            assetCurrency: "EUR",
            valuation: try FinanceInvestmentHoldingValuation(
                nativeValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                eurValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                evidence: try FinanceInvestmentValuationEvidence(
                    priceSource: "snapshot",
                    priceObservedAt: observedAt
                )
            )
        )
        let holdingsOnly = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            holdings: [holding],
            cashCoverage: .unknown,
            holdingsCoverage: .complete
        )
        let holdingsOnlyBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [], investmentSnapshots: [holdingsOnly], asOf: observedAt
        )
        XCTAssertEqual(holdingsOnlyBreakdown.availability, .partial)
        XCTAssertTrue(holdingsOnlyBreakdown.components.contains {
            $0.exclusionReason == .incompleteAccountCoverage
        })

        let verifiedEmpty = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            cashCoverage: .complete,
            holdingsCoverage: .complete
        )
        let verifiedEmptyBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [], investmentSnapshots: [verifiedEmpty], asOf: observedAt
        )
        XCTAssertEqual(verifiedEmptyBreakdown.availability, .complete)
        XCTAssertEqual(verifiedEmptyBreakdown.includedTotalEUR?.canonicalValue, "0")
    }

    func testLocalStoreReimportIsIdempotent() throws {
        let result = try importFixture()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-robinhood-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(FinanceInvestmentActivityStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FinanceInvestmentActivityStore(url: url)
        let first = try store.merge(result)
        let second = try store.merge(result)

        XCTAssertEqual(first.revision, 1)
        XCTAssertEqual(second.revision, first.revision)
        XCTAssertEqual(second.ledger.activities.count, result.activities.count)
        XCTAssertEqual(second.ledger.importReceipts.count, 1)
        XCTAssertEqual(try store.load(), second)
    }

    func testHoldingsOnlySnapshotRoundTripsThroughLedgerStore() throws {
        let source = try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary")
        let holding = try FinanceInvestmentHoldingObservation(
            id: "btc-round-trip",
            assetIdentifier: "BTC",
            quantity: try FinanceExactDecimal("1"),
            assetCurrency: "EUR",
            valuation: try FinanceInvestmentHoldingValuation(
                nativeValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                eurValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                evidence: try FinanceInvestmentValuationEvidence(
                    priceSource: "snapshot",
                    priceObservedAt: observedAt
                )
            )
        )
        let snapshot = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            holdings: [holding],
            cashCoverage: .unknown,
            holdingsCoverage: .complete
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-robinhood-holdings-round-trip-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(FinanceInvestmentActivityStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FinanceInvestmentActivityStore(url: url)
        let saved = try store.upsertAccountSnapshot(snapshot)
        XCTAssertEqual(saved.ledger.accountSnapshots, [snapshot])
        XCTAssertEqual(try store.load(), saved)
    }

    func testVerifiedEmptySnapshotRoundTripsThroughLedgerStore() throws {
        let snapshot = try FinanceInvestmentAccountSnapshot(
            source: try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary"),
            observedAt: observedAt,
            cashCoverage: .complete,
            holdingsCoverage: .complete
        )
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-robinhood-empty-round-trip-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(FinanceInvestmentActivityStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FinanceInvestmentActivityStore(url: url)
        let saved = try store.upsertAccountSnapshot(snapshot)
        XCTAssertEqual(saved.ledger.accountSnapshots, [snapshot])
        XCTAssertEqual(try store.load(), saved)
    }

    func testFormattingEquivalentReimportUsesSemanticActivityEquality() throws {
        let original = try importFixture()
        let formattingVariant = fixture
            .replacingOccurrences(of: "BTC", with: "btc")
            .replacingOccurrences(of: "€100.00", with: "€100.0")
        let variant = try FinanceRobinhoodImporter.importCSV(
            Data(formattingVariant.utf8),
            accountID: "robinhood-primary",
            observedAt: observedAt
        )
        XCTAssertEqual(Set(original.activities.map(\.id)), Set(variant.activities.map(\.id)))

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-robinhood-formatting-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent(FinanceInvestmentActivityStore.fileName)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FinanceInvestmentActivityStore(url: url)
        let first = try store.merge(original)
        let second = try store.merge(variant)
        XCTAssertEqual(second.ledger.activities, first.ledger.activities)
        XCTAssertEqual(second.ledger.activities.count, original.activities.count)
        XCTAssertEqual(second.ledger.importReceipts.count, 2)
    }

    func testPartialValuationIncludesOnlyVerifiedEUREvidence() throws {
        let source = try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary")
        let cash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-snapshot",
            verificationID: "cash-1"
        )
        let valuedHolding = try FinanceInvestmentHoldingObservation(
            id: "btc-holding",
            assetIdentifier: "BTC",
            quantity: try FinanceExactDecimal("0.1"),
            assetCurrency: "USD",
            valuation: try FinanceInvestmentHoldingValuation(
                nativeValue: try FinanceInvestmentMoney(amount: "100.00", currency: "USD"),
                eurValue: try FinanceInvestmentMoney(amount: "25.00", currency: "EUR"),
                evidence: try FinanceInvestmentValuationEvidence(
                    priceSource: "robinhood-snapshot",
                    priceObservedAt: observedAt,
                    fxSource: "verified-fx",
                    fxObservedAt: observedAt,
                    fxRate: try FinanceExactDecimal("0.25")
                )
            )
        )
        let unvaluedHolding = try FinanceInvestmentHoldingObservation(
            id: "eth-holding",
            assetIdentifier: "ETH",
            quantity: try FinanceExactDecimal("2.000000000000000000"),
            assetCurrency: "EUR"
        )
        let snapshot = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            verifiedCash: cash,
            holdings: [valuedHolding, unvaluedHolding],
            cashCoverage: .complete,
            holdingsCoverage: .complete
        )
        let activity = try XCTUnwrap(try importFixture().activities.first)

        let breakdown = try FinanceNetWorthBreakdown(
            bankCash: [],
            investmentSnapshots: [snapshot],
            activities: [activity],
            asOf: observedAt
        )

        XCTAssertEqual(breakdown.includedTotalEUR?.decimalValue, Decimal(125))
        XCTAssertEqual(breakdown.availability, .partial)
        XCTAssertEqual(breakdown.activityCount, 1)
        XCTAssertFalse(breakdown.components.contains {
            $0.kind == .investmentActivity && $0.status == .included
        })
        XCTAssertTrue(breakdown.components.contains {
            $0.exclusionReason == .missingHoldingValuation
        })
    }

    func testAccountTotalAndLinkedCashCannotBeCountedTwice() throws {
        let source = try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary")
        let cash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "60.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-snapshot",
            verificationID: "cash-1",
            consolidationKey: "linked-cash"
        )
        let holding = try FinanceInvestmentHoldingObservation(
            id: "btc-holding",
            assetIdentifier: "BTC",
            quantity: try FinanceExactDecimal("1.0"),
            assetCurrency: "EUR",
            valuation: try FinanceInvestmentHoldingValuation(
                nativeValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                eurValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                evidence: try FinanceInvestmentValuationEvidence(
                    priceSource: "robinhood-snapshot",
                    priceObservedAt: observedAt
                )
            )
        )
        let total = try FinanceInvestmentAccountValuation(
            eurValue: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-snapshot",
            verificationID: "total-1"
        )
        let totalSnapshot = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            verifiedCash: cash,
            holdings: [holding],
            cashCoverage: .complete,
            holdingsCoverage: .complete,
            totalValuation: total
        )
        let coveredBankCash = try FinanceVerifiedBankCashObservation(
            accountID: "bank-linked",
            amount: try FinanceInvestmentMoney(amount: "60.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "bank-covered-1",
            consolidationKey: "linked-cash"
        )
        let totalBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [coveredBankCash],
            investmentSnapshots: [totalSnapshot],
            asOf: observedAt
        )
        XCTAssertEqual(totalBreakdown.includedTotalEUR?.decimalValue, Decimal(100))
        XCTAssertEqual(
            totalBreakdown.components.filter { $0.status == .included }.map(\.kind),
            [.investmentAccountTotal]
        )

        var decodedOverlapPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(totalBreakdown)) as? [String: Any]
        )
        var decodedOverlapComponents = try XCTUnwrap(
            decodedOverlapPayload["components"] as? [[String: Any]]
        )
        let decodedBankIndex = try XCTUnwrap(decodedOverlapComponents.firstIndex {
            ($0["kind"] as? String) == FinanceNetWorthComponentKind.bankCash.rawValue
        })
        decodedOverlapComponents[decodedBankIndex]["status"] = FinanceNetWorthComponentStatus.included.rawValue
        decodedOverlapComponents[decodedBankIndex]["exclusionReason"] = NSNull()
        decodedOverlapComponents[decodedBankIndex]["amountEUR"] = ["rawValue": "60.00"]
        decodedOverlapComponents[decodedBankIndex]["identityKey"] = "cash|linked|linked-cash"
        try recomputeNetWorthComponentID(&decodedOverlapComponents[decodedBankIndex])
        let decodedCrossSourceCash = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthComponent.self,
            from: JSONSerialization.data(withJSONObject: decodedOverlapComponents[decodedBankIndex])
        )
        XCTAssertEqual(decodedCrossSourceCash.kind, .bankCash)
        XCTAssertEqual(decodedCrossSourceCash.identityKey, "cash|linked|linked-cash")
        decodedOverlapPayload["components"] = decodedOverlapComponents
        decodedOverlapPayload["includedTotalEUR"] = ["rawValue": "160.00"]
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceNetWorthBreakdown.self,
            from: JSONSerialization.data(withJSONObject: decodedOverlapPayload)
        ))

        let bankCash = try FinanceVerifiedBankCashObservation(
            accountID: "bank-linked",
            amount: try FinanceInvestmentMoney(amount: "50.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "bank-1",
            consolidationKey: "linked-cash"
        )
        let investmentCash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "50.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-snapshot",
            verificationID: "investment-1",
            consolidationKey: "linked-cash"
        )
        let linkedSnapshot = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            verifiedCash: investmentCash,
            cashCoverage: .complete,
            holdingsCoverage: .unknown
        )
        let linkedBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [bankCash],
            investmentSnapshots: [linkedSnapshot],
            asOf: observedAt
        )
        XCTAssertEqual(linkedBreakdown.includedTotalEUR?.decimalValue, Decimal(50))
        XCTAssertEqual(
            linkedBreakdown.components.filter { $0.status == .included }.count,
            1
        )
        XCTAssertTrue(linkedBreakdown.components.contains {
            $0.exclusionReason == .duplicateCashIdentity
        })
    }

    func testOverlappingAccountTotalsCannotProduceCompleteNetWorth() throws {
        let firstSource = try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary")
        let secondSource = try FinanceInvestmentSourceIdentity(accountID: "robinhood-secondary")
        let firstCash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "60.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-primary",
            verificationID: "cash-primary",
            consolidationKey: "shared-cash"
        )
        let secondCash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "60.00", currency: "EUR"),
            observedAt: observedAt,
            source: "robinhood-secondary",
            verificationID: "cash-secondary",
            consolidationKey: "shared-cash"
        )
        let firstSnapshot = try FinanceInvestmentAccountSnapshot(
            source: firstSource,
            observedAt: observedAt,
            verifiedCash: firstCash,
            cashCoverage: .complete,
            holdingsCoverage: .complete,
            totalValuation: try FinanceInvestmentAccountValuation(
                eurValue: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
                observedAt: observedAt,
                source: "robinhood-primary",
                verificationID: "total-primary"
            )
        )
        let secondSnapshot = try FinanceInvestmentAccountSnapshot(
            source: secondSource,
            observedAt: observedAt,
            verifiedCash: secondCash,
            cashCoverage: .complete,
            holdingsCoverage: .complete,
            totalValuation: try FinanceInvestmentAccountValuation(
                eurValue: try FinanceInvestmentMoney(amount: "200.00", currency: "EUR"),
                observedAt: observedAt,
                source: "robinhood-secondary",
                verificationID: "total-secondary"
            )
        )

        let breakdown = try FinanceNetWorthBreakdown(
            bankCash: [],
            investmentSnapshots: [firstSnapshot, secondSnapshot],
            asOf: observedAt
        )

        XCTAssertEqual(breakdown.includedTotalEUR?.decimalValue, Decimal(60))
        XCTAssertEqual(breakdown.availability, .partial)
        XCTAssertEqual(
            breakdown.components.filter { $0.status == .included }.map(\.kind),
            [.investmentCash]
        )
        XCTAssertEqual(
            breakdown.components.filter { $0.exclusionReason == .ambiguousLinkedCash }.count,
            2
        )

        let roundTripped = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthBreakdown.self,
            from: JSONEncoder.lifeOS.encode(breakdown)
        )
        XCTAssertEqual(roundTripped, breakdown)
    }

    func testExactDecimalRejectsInvalidAndUnrepresentableValues() throws {
        XCTAssertNoThrow(try FinanceExactDecimal("0.12345678901234567890"))
        XCTAssertThrowsError(try FinanceExactDecimal("123456789012345678901234567890"))
        XCTAssertThrowsError(try FinanceExactDecimal("0.12345678901234567890123456789"))
        XCTAssertThrowsError(try FinanceExactDecimal("1e3"))
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceExactDecimal.self,
            from: Data(#"{"rawValue":"not-a-decimal"}"#.utf8)
        ))
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceExactDecimal.self,
            from: Data(#"{"rawValue":"1.0","unexpected":true}"#.utf8)
        ))
    }

    func testExactDecimalAdditionReportsFoundationPrecisionLoss() throws {
        let large = try FinanceExactDecimal("9999999999999999999999999999")
        let one = try FinanceExactDecimal("1")
        XCTAssertThrowsError(try FinanceExactDecimal.adding([large, one]))
    }

    func testNetWorthFreshnessConflictsLiabilitiesAndMissingSnapshotsAreExplicit() throws {
        let stale = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "stale-1"
        )
        let staleBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [stale], investmentSnapshots: [], asOf: observedAt.addingTimeInterval(91 * 24 * 60 * 60)
        )
        XCTAssertEqual(staleBreakdown.availability, .unavailable)
        XCTAssertTrue(staleBreakdown.components.contains { $0.exclusionReason == .staleObservation })

        let future = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt.addingTimeInterval(24 * 60 * 60),
            source: "enable-banking",
            verificationID: "future-1"
        )
        let futureBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [future], investmentSnapshots: [], asOf: observedAt
        )
        XCTAssertTrue(futureBreakdown.components.contains { $0.exclusionReason == .futureObservation })

        let conflictA = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "conflict-a"
        )
        let conflictB = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "200.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "conflict-b"
        )
        let conflictBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [conflictA, conflictB], investmentSnapshots: [], asOf: observedAt
        )
        XCTAssertEqual(conflictBreakdown.availability, .unavailable)
        XCTAssertTrue(conflictBreakdown.components.contains { $0.exclusionReason == .ambiguousSnapshot })

        let liability = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "-25.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "liability-1"
        )
        let liabilityBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [liability], investmentSnapshots: [], asOf: observedAt
        )
        XCTAssertEqual(liabilityBreakdown.includedTotalEUR?.canonicalValue, "-25")

        let activity = try XCTUnwrap(try importFixture().activities.first)
        let coveredCash = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "covered-1"
        )
        let missingSnapshotBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [coveredCash], investmentSnapshots: [], activities: [activity], asOf: observedAt
        )
        XCTAssertEqual(missingSnapshotBreakdown.availability, .partial)
        XCTAssertTrue(missingSnapshotBreakdown.components.contains { $0.exclusionReason == .missingAccountSnapshot })
    }

    func testImportAndReceiptDecodingRejectTamperedDuplicates() throws {
        let result = try importFixture()
        let encodedResult = try JSONEncoder.lifeOS.encode(result)
        var resultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedResult) as? [String: Any]
        )
        var resultActivities = try XCTUnwrap(resultObject["activities"] as? [[String: Any]])
        resultActivities.append(try XCTUnwrap(resultActivities.first))
        resultObject["activities"] = resultActivities
        let duplicateResult = try JSONSerialization.data(withJSONObject: resultObject)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceRobinhoodImportResult.self,
            from: duplicateResult
        ))

        resultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encodedResult) as? [String: Any]
        )
        resultObject["unexpected"] = true
        let unknownResultField = try JSONSerialization.data(withJSONObject: resultObject)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceRobinhoodImportResult.self,
            from: unknownResultField
        ))

        let receipt = try FinanceInvestmentImportReceipt(
            evidence: result.evidence,
            activities: result.activities
        )
        let ledger = try FinanceInvestmentLedger(
            activities: result.activities,
            importReceipts: [receipt]
        )
        var ledgerObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(ledger)) as? [String: Any]
        )
        var receipts = try XCTUnwrap(ledgerObject["importReceipts"] as? [[String: Any]])
        var receiptObject = try XCTUnwrap(receipts.first)
        var invalidRowCountReceipt = receiptObject
        invalidRowCountReceipt["dataRowCount"] = result.activities.count + 1
        var invalidRowCountLedger = ledgerObject
        invalidRowCountLedger["importReceipts"] = [invalidRowCountReceipt]
        let invalidRowCount = try JSONSerialization.data(withJSONObject: invalidRowCountLedger)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceInvestmentLedger.self,
            from: invalidRowCount
        ))

        var receiptActivityIDs = try XCTUnwrap(receiptObject["activityIDs"] as? [String])
        receiptActivityIDs.append(try XCTUnwrap(receiptActivityIDs.first))
        receiptObject["activityIDs"] = receiptActivityIDs
        receipts[0] = receiptObject
        ledgerObject["importReceipts"] = receipts
        let duplicateReceiptReference = try JSONSerialization.data(withJSONObject: ledgerObject)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceInvestmentLedger.self,
            from: duplicateReceiptReference
        ))
    }

    func testDecodedImportRevalidatesRobinhoodSemanticsAndIDs() throws {
        let result = try importFixture()
        let tamperedCases: [(String, (inout [String: Any]) throws -> Void)] = [
            ("missing quantity", { activity in
                activity["quantity"] = NSNull()
            }),
            ("missing price", { activity in
                activity["instrumentPrice"] = NSNull()
            }),
            ("wrong currency", { activity in
                var price = try XCTUnwrap(activity["instrumentPrice"] as? [String: Any])
                price["currency"] = "USD"
                activity["instrumentPrice"] = price
            }),
            ("wrong debit direction", { activity in
                let debit = activity["debit"] ?? NSNull()
                activity["debit"] = NSNull()
                activity["credit"] = debit
            }),
            ("invalid transaction mapping", { activity in
                activity["kind"] = FinanceInvestmentActivityKind.sell.rawValue
            }),
            ("substituted semantic ID", { activity in
                activity["id"] = String(repeating: "0", count: 64)
            })
        ]

        for (label, mutate) in tamperedCases {
            let data = try tamperedResultData(result, mutate: mutate)
            XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
                FinanceRobinhoodImportResult.self,
                from: data
            ), "Expected decoded import to reject \(label)")
        }
    }

    func testBreakdownDecodingRejectsImpossibleDerivedStates() throws {
        let source = try FinanceInvestmentSourceIdentity(accountID: "robinhood-primary")
        let holding = try FinanceInvestmentHoldingObservation(
            id: "btc-valued",
            assetIdentifier: "BTC",
            quantity: try FinanceExactDecimal("1"),
            assetCurrency: "EUR",
            valuation: try FinanceInvestmentHoldingValuation(
                nativeValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                eurValue: try FinanceInvestmentMoney(amount: "40.00", currency: "EUR"),
                evidence: try FinanceInvestmentValuationEvidence(
                    priceSource: "snapshot",
                    priceObservedAt: observedAt
                )
            )
        )
        let snapshot = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            holdings: [holding],
            cashCoverage: .complete,
            holdingsCoverage: .complete
        )
        let breakdown = try FinanceNetWorthBreakdown(
            bankCash: [], investmentSnapshots: [snapshot], asOf: observedAt
        )
        let encoded = try JSONEncoder.lifeOS.encode(breakdown)

        var activityPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var activityComponents = try XCTUnwrap(activityPayload["components"] as? [[String: Any]])
        let holdingIndex = try XCTUnwrap(activityComponents.firstIndex {
            ($0["kind"] as? String) == FinanceNetWorthComponentKind.investmentHoldings.rawValue
        })
        activityComponents[holdingIndex]["kind"] = FinanceNetWorthComponentKind.investmentActivity.rawValue
        try recomputeNetWorthComponentID(&activityComponents[holdingIndex])
        let decodedIncludedActivity = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthComponent.self,
            from: JSONSerialization.data(withJSONObject: activityComponents[holdingIndex])
        )
        XCTAssertEqual(decodedIncludedActivity.kind, .investmentActivity)
        activityPayload["components"] = activityComponents
        let includedActivity = try JSONSerialization.data(withJSONObject: activityPayload)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceNetWorthBreakdown.self,
            from: includedActivity
        ))

        var stalePayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        var staleComponents = try XCTUnwrap(stalePayload["components"] as? [[String: Any]])
        staleComponents[holdingIndex]["observedAt"] = "2025-01-01T00:00:00Z"
        try recomputeNetWorthComponentID(&staleComponents[holdingIndex])
        let decodedStaleHolding = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthComponent.self,
            from: JSONSerialization.data(withJSONObject: staleComponents[holdingIndex])
        )
        XCTAssertEqual(decodedStaleHolding.kind, .investmentHoldings)
        XCTAssertEqual(decodedStaleHolding.observedAt, try JSONDecoder.lifeOS.decode(
            Date.self,
            from: Data("\"2025-01-01T00:00:00Z\"".utf8)
        ))
        stalePayload["components"] = staleComponents
        let staleIncluded = try JSONSerialization.data(withJSONObject: stalePayload)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceNetWorthBreakdown.self,
            from: staleIncluded
        ))

        let cash = try FinanceInvestmentCashObservation(
            amount: try FinanceInvestmentMoney(amount: "60.00", currency: "EUR"),
            observedAt: observedAt,
            source: "snapshot",
            verificationID: "cash"
        )
        let totalSnapshot = try FinanceInvestmentAccountSnapshot(
            source: source,
            observedAt: observedAt,
            verifiedCash: cash,
            holdings: [holding],
            cashCoverage: .complete,
            holdingsCoverage: .complete,
            totalValuation: try FinanceInvestmentAccountValuation(
                eurValue: try FinanceInvestmentMoney(amount: "100.00", currency: "EUR"),
                observedAt: observedAt,
                source: "snapshot",
                verificationID: "total"
            )
        )
        let totalBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [], investmentSnapshots: [totalSnapshot], asOf: observedAt
        )
        var overlapPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(totalBreakdown)) as? [String: Any]
        )
        var overlapComponents = try XCTUnwrap(overlapPayload["components"] as? [[String: Any]])
        let cashIndex = try XCTUnwrap(overlapComponents.firstIndex {
            ($0["kind"] as? String) == FinanceNetWorthComponentKind.investmentCash.rawValue
        })
        overlapComponents[cashIndex]["status"] = FinanceNetWorthComponentStatus.included.rawValue
        overlapComponents[cashIndex]["exclusionReason"] = NSNull()
        overlapComponents[cashIndex]["amountEUR"] = ["rawValue": "60.00"]
        overlapComponents[cashIndex]["identityKey"] = "cash|unlinked|investmentCash|robinhood-primary|robinhood"
        try recomputeNetWorthComponentID(&overlapComponents[cashIndex])
        let decodedOverlappingCash = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthComponent.self,
            from: JSONSerialization.data(withJSONObject: overlapComponents[cashIndex])
        )
        XCTAssertEqual(decodedOverlappingCash.kind, .investmentCash)
        XCTAssertEqual(decodedOverlappingCash.amountEUR?.canonicalValue, "60")
        overlapPayload["components"] = overlapComponents
        overlapPayload["includedTotalEUR"] = ["rawValue": "160.00"]
        let overlappingTotal = try JSONSerialization.data(withJSONObject: overlapPayload)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceNetWorthBreakdown.self,
            from: overlappingTotal
        ))

        let bankCash = try FinanceVerifiedBankCashObservation(
            accountID: "checking",
            amount: try FinanceInvestmentMoney(amount: "50.00", currency: "EUR"),
            observedAt: observedAt,
            source: "enable-banking",
            verificationID: "bank-cash"
        )
        let bankBreakdown = try FinanceNetWorthBreakdown(
            bankCash: [bankCash], investmentSnapshots: [], asOf: observedAt
        )
        var duplicateBankPayload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(bankBreakdown)) as? [String: Any]
        )
        var bankComponents = try XCTUnwrap(duplicateBankPayload["components"] as? [[String: Any]])
        let bankIndex = try XCTUnwrap(bankComponents.firstIndex {
            ($0["status"] as? String) == FinanceNetWorthComponentStatus.included.rawValue
        })
        var duplicateBank = bankComponents[bankIndex]
        let duplicateObservedAt = observedAt.addingTimeInterval(-60)
        duplicateBank["observedAt"] = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: JSONEncoder.lifeOS.encode(duplicateObservedAt),
                options: [.fragmentsAllowed]
            ) as? String
        )
        duplicateBank["amountEUR"] = ["rawValue": "51.00"]
        let duplicateBankIdentity = try XCTUnwrap(duplicateBank["identityKey"] as? String)
        let originalComponentData = try JSONSerialization.data(withJSONObject: bankComponents[bankIndex])
        let originalComponent = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthComponent.self,
            from: originalComponentData
        )
        duplicateBank["id"] = FinanceInvestmentHash.sha256(
            "\(originalComponent.kind.rawValue)|\(originalComponent.accountID)|\(originalComponent.source)|\(duplicateObservedAt.timeIntervalSinceReferenceDate)|included|included|51|\(duplicateBankIdentity)"
        )
        let duplicateComponentData = try JSONSerialization.data(withJSONObject: duplicateBank)
        let decodedDuplicate = try JSONDecoder.lifeOS.decode(
            FinanceNetWorthComponent.self,
            from: duplicateComponentData
        )
        XCTAssertEqual(decodedDuplicate.identityKey, duplicateBankIdentity)
        XCTAssertEqual(decodedDuplicate.observedAt, duplicateObservedAt)
        XCTAssertEqual(decodedDuplicate.amountEUR?.canonicalValue, "51")
        bankComponents.append(duplicateBank)
        duplicateBankPayload["components"] = bankComponents
        duplicateBankPayload["includedTotalEUR"] = ["rawValue": "101.00"]
        let duplicateBankData = try JSONSerialization.data(withJSONObject: duplicateBankPayload)
        XCTAssertThrowsError(try JSONDecoder.lifeOS.decode(
            FinanceNetWorthBreakdown.self,
            from: duplicateBankData
        )) { error in
            XCTAssertEqual(error as? FinanceInvestmentValidationError, .duplicateIdentity)
        }
    }

    private func recomputeNetWorthComponentID(_ component: inout [String: Any]) throws {
        let kind = try XCTUnwrap(
            (component["kind"] as? String).flatMap(FinanceNetWorthComponentKind.init(rawValue:))
        )
        let accountID = try XCTUnwrap(component["accountID"] as? String)
        let source = try XCTUnwrap(component["source"] as? String)
        let observedAtObject = try XCTUnwrap(component["observedAt"])
        let observedAt = try JSONDecoder.lifeOS.decode(
            Date.self,
            from: JSONSerialization.data(withJSONObject: observedAtObject, options: [.fragmentsAllowed])
        )
        let amountEUR: FinanceExactDecimal?
        if let amountObject = component["amountEUR"] as? [String: Any] {
            amountEUR = try JSONDecoder.lifeOS.decode(
                FinanceExactDecimal.self,
                from: JSONSerialization.data(withJSONObject: amountObject)
            )
        } else {
            amountEUR = nil
        }
        let status = try XCTUnwrap(
            (component["status"] as? String).flatMap(FinanceNetWorthComponentStatus.init(rawValue:))
        )
        let exclusionReason = (component["exclusionReason"] as? String)
            .flatMap(FinanceNetWorthExclusionReason.init(rawValue:))
        let identityKey = try XCTUnwrap(component["identityKey"] as? String)
        let coveredCashIdentityKeys = try XCTUnwrap(
            component["coveredCashIdentityKeys"] as? [String]
        )
        component["id"] = FinanceInvestmentHash.sha256(
            FinanceNetWorthComponent.canonicalID(
                kind: kind,
                accountID: accountID,
                source: source,
                observedAt: observedAt,
                amountEUR: amountEUR,
                status: status,
                exclusionReason: exclusionReason,
                identityKey: identityKey,
                coveredCashIdentityKeys: coveredCashIdentityKeys
            )
        )
    }

    private func tamperedResultData(
        _ result: FinanceRobinhoodImportResult,
        mutate: (inout [String: Any]) throws -> Void
    ) throws -> Data {
        var resultObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.lifeOS.encode(result)) as? [String: Any]
        )
        var activities = try XCTUnwrap(resultObject["activities"] as? [[String: Any]])
        let index = try XCTUnwrap(activities.firstIndex {
            ($0["rawTransactionType"] as? String) == "Crypto Purchase"
        })
        var activity = activities[index]
        try mutate(&activity)
        activities[index] = activity
        resultObject["activities"] = activities
        return try JSONSerialization.data(withJSONObject: resultObject)
    }

    private func importFixture() throws -> FinanceRobinhoodImportResult {
        try FinanceRobinhoodImporter.importCSV(
            Data(fixture.utf8),
            accountID: "robinhood-primary",
            observedAt: observedAt
        )
    }

    private var fixture: String {
        """
        Activity Date,Transaction Type,Instrument,Instrument Quantity,Instrument Price,Fees,Debit,Credit,
        2026-01-01,SEPA Deposit,EUR,-,-,-,-,€100.00,
        2026-01-02,Crypto Purchase,BTC,0.12345678901234567890,€1000.0000000000,€1.23,€124.45,-,
        2026-01-03,Crypto Sale,BTC,0.10000000000000000000,€1100.0000000000,€1.10,-,€108.90,
        2026-01-04,Crypto Deposit,ETH,1.500000000000000000,€2000.0000000000,-,-,€3000.00,
        2026-01-05,Crypto Reward,ETH,0.010000000000000000,€2100.0000000000,-,-,€21.00,
        2026-01-06,Staking Earnings,ETH,0.020000000000000000,€2200.0000000000,-,-,€44.00,
        """
    }

    private var footerFixture: String {
        var lines = [FinanceInvestmentContract.robinhoodActivityCSVHeader.joined(separator: ",")]
        for index in 0..<39 {
            let month = index < 28 ? 1 : 2
            let day = index < 28 ? index + 1 : index - 27
            let date = String(format: "2026-%02d-%02d", month, day)
            lines.append("\(date),Crypto Purchase,BTC,1.0000000000,€1.00,-,€1.00,-,")
        }
        lines.append("")
        lines.append(",,,,,,,,\"Personal disclaimer footer\"")
        return lines.joined(separator: "\n") + "\n"
    }
}
