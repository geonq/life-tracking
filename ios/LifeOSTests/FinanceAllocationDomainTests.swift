import Foundation
import XCTest
@testable import LifeOS

final class FinanceAllocationDomainTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_449_600)

    private func rule(
        id: UUID = UUID(),
        label: String = "Rent",
        bucket: String = "Rent",
        share: FinanceAllocationShare
    ) -> FinanceAllocationRule {
        FinanceAllocationRule(id: id, label: label, bucket: bucket, share: share, createdAt: now)
    }

    // MARK: 1. Empty rule set is honest "no allocation configured", never a zero split

    func testEmptyRuleSetIsNoAllocationConfigured() {
        let result = FinanceAllocationEngine.preview(rules: [], incomeCents: 100_000)
        XCTAssertEqual(result, .noAllocationConfigured)
    }

    // MARK: 2. Percentage-only split sums exactly to income, no lost/invented cents

    func testPercentageOnlySplitSumsExactlyToIncomeWithNoRemainder() {
        let rules = [
            rule(label: "Rent", bucket: "Rent", share: .percentage(40)),
            rule(label: "Savings", bucket: "Savings", share: .percentage(20)),
            rule(label: "Free", bucket: "Free", share: .percentage(40))
        ]
        guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: 100_007) else {
            return XCTFail("expected an allocated preview")
        }
        XCTAssertEqual(preview.incomeCents, 100_007)
        let total = preview.lineItems.reduce(0) { $0 + $1.amountCents } + preview.unallocatedCents
        XCTAssertEqual(total, 100_007)
        // 40% of 100_007 = 40002.8, 20% = 20001.4, 40% = 40002.8 -> whole-cent
        // shares must sum to floor(100_007) = 100_007 exactly since percentages total 100%.
        XCTAssertEqual(preview.unallocatedCents, 0)
    }

    // MARK: 3. Determinism: identical input always produces identical output

    func testAllocationPreviewIsDeterministicAcrossRepeatedCalls() {
        let ruleA = rule(label: "Rent", bucket: "Rent", share: .percentage(33))
        let ruleB = rule(label: "Savings", bucket: "Savings", share: .percentage(33))
        let ruleC = rule(label: "Free", bucket: "Free", share: .percentage(34))
        let rules = [ruleA, ruleB, ruleC]

        let first = FinanceAllocationEngine.preview(rules: rules, incomeCents: 10_000)
        for _ in 0..<25 {
            XCTAssertEqual(FinanceAllocationEngine.preview(rules: rules, incomeCents: 10_000), first)
        }
    }

    // MARK: 4. Largest-remainder tie-break: earlier rule order wins equal remainders

    func testLargestRemainderTieBreaksByRuleOrderThenID() {
        // 10_000 cents split 3 ways at 33%/33%/34%: each gets 3300/3300/3400
        // baseline with 0 remainder cents left over -- use an income/percent
        // combination that forces equal remainders needing a tie-break.
        // 100 cents at 1/1/1% (sum 3%): each ideal = 100*1/100 = 1.00 exactly,
        // so pick values that produce a genuine tie in the fractional remainder.
        let ruleA = rule(label: "A", bucket: "A", share: .percentage(1))
        let ruleB = rule(label: "B", bucket: "B", share: .percentage(1))
        let ruleC = rule(label: "C", bucket: "C", share: .percentage(1))
        let rules = [ruleA, ruleB, ruleC]
        // income=10 cents, percent=1 each: product = 10*1 = 10, baseline = 0,
        // remainder = 10 for all three (tied). target = floor(10*3/100) = 0.
        // No leftover to distribute in this case, so construct a case with
        // leftover > 0 instead.
        let incomeForcingLeftover = 34 // percent sum 3, remaining=34
        // product per rule = 34*1 = 34 -> baseline 0, remainder 34 (tied for all three)
        // target = floor(34*3/100) = floor(1.02) = 1 -> 1 leftover cent to distribute
        guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: incomeForcingLeftover) else {
            return XCTFail("expected an allocated preview")
        }
        // Rule A (earliest order) must win the single leftover cent since all
        // remainders are tied.
        XCTAssertEqual(preview.lineItems.first { $0.label == "A" }?.amountCents, 1)
        XCTAssertEqual(preview.lineItems.first { $0.label == "B" }?.amountCents, 0)
        XCTAssertEqual(preview.lineItems.first { $0.label == "C" }?.amountCents, 0)
        let total = preview.lineItems.reduce(0) { $0 + $1.amountCents } + preview.unallocatedCents
        XCTAssertEqual(total, incomeForcingLeftover)
    }

    // MARK: 5. Fixed-share rules claim exactly their configured cents

    func testFixedShareRuleClaimsExactCentsAndPercentageSplitsTheRemainder() {
        let rules = [
            rule(label: "Rent", bucket: "Rent", share: .fixedCents(50_000)),
            rule(label: "Savings", bucket: "Savings", share: .percentage(100))
        ]
        guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: 120_000) else {
            return XCTFail("expected an allocated preview")
        }
        XCTAssertEqual(preview.lineItems.first { $0.label == "Rent" }?.amountCents, 50_000)
        XCTAssertEqual(preview.lineItems.first { $0.label == "Savings" }?.amountCents, 70_000)
        XCTAssertEqual(preview.unallocatedCents, 0)
    }

    // MARK: 6. Fixed amounts exceeding income are refused, not truncated

    func testFixedAmountsExceedingIncomeAreRefused() {
        let rules = [rule(label: "Rent", bucket: "Rent", share: .fixedCents(200_000))]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: 100_000)
        XCTAssertEqual(result, .fixedAmountsExceedIncome)
    }

    // MARK: 7. Percentages under-totaling 100% leave an honest unallocated remainder

    func testUnderTotaledPercentagesLeaveExplicitUnallocatedRemainder() {
        let rules = [rule(label: "Rent", bucket: "Rent", share: .percentage(50))]
        guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: 10_000) else {
            return XCTFail("expected an allocated preview")
        }
        XCTAssertEqual(preview.lineItems.first?.amountCents, 5_000)
        XCTAssertEqual(preview.unallocatedCents, 5_000)
    }

    // MARK: 8. Non-positive income is refused

    func testNonPositiveIncomeIsInvalid() {
        let rules = [rule(share: .percentage(50))]
        XCTAssertEqual(FinanceAllocationEngine.preview(rules: rules, incomeCents: 0), .invalidIncome)
        XCTAssertEqual(FinanceAllocationEngine.preview(rules: rules, incomeCents: -1), .invalidIncome)
    }

    // MARK: 9. Rule-set validation: percentage total over 100% is rejected

    func testValidateRejectsPercentageTotalOver100() {
        let rules = [
            rule(share: .percentage(60)),
            rule(share: .percentage(50))
        ]
        XCTAssertEqual(FinanceAllocationEngine.validate(rules), .percentageTotalExceeds100)
    }

    func testValidateAcceptsPercentageTotalOfExactly100() {
        let rules = [
            rule(share: .percentage(60)),
            rule(share: .percentage(40))
        ]
        XCTAssertNil(FinanceAllocationEngine.validate(rules))
    }

    // MARK: 10. Rule-set validation: individual share bounds

    func testValidateRejectsOutOfRangeShares() {
        XCTAssertEqual(FinanceAllocationEngine.validate([rule(share: .percentage(0))]), .invalidShare)
        XCTAssertEqual(FinanceAllocationEngine.validate([rule(share: .percentage(101))]), .invalidShare)
        XCTAssertEqual(FinanceAllocationEngine.validate([rule(share: .fixedCents(0))]), .invalidShare)
        XCTAssertEqual(FinanceAllocationEngine.validate([rule(share: .fixedCents(-1))]), .invalidShare)
    }

    func testValidateRejectsEmptyLabelOrBucket() {
        XCTAssertEqual(FinanceAllocationEngine.validate([rule(label: "  ", share: .percentage(10))]), .invalidLabel)
        XCTAssertEqual(FinanceAllocationEngine.validate([rule(bucket: "  ", share: .percentage(10))]), .invalidBucket)
    }

    // MARK: 11. Codable round-trip preserves both share kinds

    func testShareCodableRoundTripPreservesBothKinds() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let percentage = FinanceAllocationShare.percentage(40)
        let percentageData = try encoder.encode(percentage)
        XCTAssertEqual(try decoder.decode(FinanceAllocationShare.self, from: percentageData), percentage)

        let fixed = FinanceAllocationShare.fixedCents(5_000)
        let fixedData = try encoder.encode(fixed)
        XCTAssertEqual(try decoder.decode(FinanceAllocationShare.self, from: fixedData), fixed)
    }

    // MARK: 12. Regression -- F1: preview must call its own validator and fail closed

    func testPreviewRejectsPercentagesOverTotalingInsteadOfFailingOpen() {
        let rules = [
            rule(label: "A", bucket: "A", share: .percentage(60)),
            rule(label: "B", bucket: "B", share: .percentage(60))
        ]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: 10_000)
        XCTAssertEqual(result, .invalidRuleSet(.percentageTotalExceeds100))
        // Specifically must NOT be the previously-observed failure mode: an
        // `.allocated` result with 6000+6000 = 12000 allocated against a
        // 10000 income and unallocatedCents == -2000.
        if case .allocated = result {
            XCTFail("preview must refuse an invalid rule set, never allocate against it")
        }
    }

    func testPreviewRejectsAPercentageOver100InsteadOfOverAllocating() {
        let rules = [rule(share: .percentage(500))]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: 10_000)
        XCTAssertEqual(result, .invalidRuleSet(.invalidShare))
    }

    func testPreviewRejectsANegativeFixedAmountInsteadOfProducingANegativeLineItem() {
        let rules = [
            rule(label: "Negative", bucket: "Negative", share: .fixedCents(-1_000)),
            rule(label: "Rest", bucket: "Rest", share: .percentage(100))
        ]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: 10_000)
        XCTAssertEqual(result, .invalidRuleSet(.invalidShare))
    }

    // MARK: 13. Regression -- F3: incomeCents is bounded like every other Finance entry point

    func testPreviewRejectsIncomeAboveTheSharedMaximumCentsCeiling() {
        let rules = [rule(share: .percentage(50))]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: FinanceBudgetAmountParser.maximumCents + 1)
        XCTAssertEqual(result, .invalidIncome)
    }

    func testPreviewAtIntMaxIncomeDoesNotTrap() {
        // The reviewer's confirmed repro: this used to trap the process.
        let rules = [rule(share: .percentage(50))]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: Int.max)
        XCTAssertEqual(result, .invalidIncome)
    }

    func testPreviewWithFixedTotalsThatWouldOverflowRefusesRatherThanTraps() {
        let rules = [
            rule(label: "A", bucket: "A", share: .fixedCents(FinanceBudgetAmountParser.maximumCents)),
            rule(label: "B", bucket: "B", share: .fixedCents(FinanceBudgetAmountParser.maximumCents))
        ]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: FinanceBudgetAmountParser.maximumCents)
        XCTAssertEqual(result, .fixedAmountsExceedIncome)
    }

    // MARK: 14. Regression -- F4: duplicate rule ids must not collapse into one amount

    func testValidateRejectsDuplicateRuleIDs() {
        let sharedID = UUID()
        let rules = [
            rule(id: sharedID, label: "Fixed", bucket: "Fixed", share: .fixedCents(500)),
            rule(id: sharedID, label: "Percent", bucket: "Percent", share: .percentage(50))
        ]
        XCTAssertEqual(FinanceAllocationEngine.validate(rules), .duplicateRuleID)
    }

    func testPreviewRefusesDuplicateRuleIDsInsteadOfCollapsingTheirAmounts() {
        let sharedID = UUID()
        let rules = [
            rule(id: sharedID, label: "Fixed", bucket: "Fixed", share: .fixedCents(500)),
            rule(id: sharedID, label: "Percent", bucket: "Percent", share: .percentage(50))
        ]
        let result = FinanceAllocationEngine.preview(rules: rules, incomeCents: 2_500)
        XCTAssertEqual(result, .invalidRuleSet(.duplicateRuleID))
        // Specifically must NOT be the previously-observed failure mode: both
        // line items reporting 1_000 because a dictionary keyed by `id`
        // collapsed the two rules into one entry.
        if case .allocated(let preview) = result {
            XCTFail("must refuse duplicate ids, not allocate with collapsed amounts \(preview.lineItems)")
        }
    }

    // MARK: 15. Regression -- F5 test gap: fixed total exactly equal to income

    func testFixedTotalExactlyEqualsIncomeLeavesNoRemainder() {
        let rules = [rule(label: "Rent", bucket: "Rent", share: .fixedCents(120_000))]
        guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: 120_000) else {
            return XCTFail("expected an allocated preview")
        }
        XCTAssertEqual(preview.lineItems.first?.amountCents, 120_000)
        XCTAssertEqual(preview.unallocatedCents, 0)
    }

    // MARK: 16. Regression -- F5 test gap: fixed + multiple percentages with a real remainder

    func testMixedFixedAndMultiplePercentagesWithARealRemainder() {
        // Remaining after the fixed rule is 10_007, split 40/20/40 across
        // three percentage rules -- this does not divide evenly, so it
        // exercises the largest-remainder distribution the algorithm exists
        // for (the only prior fixed+percentage test landed on a clean,
        // zero-remainder 70_000).
        let rules = [
            rule(label: "Rent", bucket: "Rent", share: .fixedCents(50_000)),
            rule(label: "Savings", bucket: "Savings", share: .percentage(40)),
            rule(label: "Free", bucket: "Free", share: .percentage(20)),
            rule(label: "Fun", bucket: "Fun", share: .percentage(40))
        ]
        guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: 60_007) else {
            return XCTFail("expected an allocated preview")
        }
        XCTAssertEqual(preview.lineItems.first { $0.label == "Rent" }?.amountCents, 50_000)
        let total = preview.lineItems.reduce(0) { $0 + $1.amountCents } + preview.unallocatedCents
        XCTAssertEqual(total, 60_007)
        // Percentages total exactly 100%, so every one of the remaining
        // 10_007 cents must land on a percentage rule -- none unallocated.
        XCTAssertEqual(preview.unallocatedCents, 0)
        let percentageTotal = preview.lineItems
            .filter { $0.label != "Rent" }
            .reduce(0) { $0 + $1.amountCents }
        XCTAssertEqual(percentageTotal, 10_007)
    }

    // MARK: 17. Regression -- F5 test gap: property-style cent-conservation sweep

    func testCentConservationHoldsAcrossASweepOfIncomesAndPercentageSplits() {
        let splits: [[Int]] = [
            [100],
            [50, 50],
            [33, 33, 34],
            [40, 20, 40],
            [1, 1, 1],
            [10, 20, 30, 40],
            [25, 25, 25, 25],
            [7, 13, 17, 63]
        ]
        for split in splits {
            let rules = split.enumerated().map { index, percent in
                rule(label: "Rule\(index)", bucket: "Bucket\(index)", share: .percentage(percent))
            }
            for incomeCents in stride(from: 1, through: 4_000, by: 37) {
                guard case .allocated(let preview) = FinanceAllocationEngine.preview(rules: rules, incomeCents: incomeCents) else {
                    return XCTFail("expected an allocated preview for split \(split) at income \(incomeCents)")
                }
                let total = preview.lineItems.reduce(0) { $0 + $1.amountCents } + preview.unallocatedCents
                XCTAssertEqual(total, incomeCents, "cent conservation failed for split \(split) at income \(incomeCents)")

                // No rule may drift more than 1 cent from its ideal
                // (fractional) share of the income.
                for (percent, item) in zip(split, preview.lineItems) {
                    let idealShare = Double(incomeCents) * Double(percent) / 100.0
                    let drift = abs(Double(item.amountCents) - idealShare)
                    XCTAssertLessThanOrEqual(
                        drift, 1.0,
                        "rule at \(percent)% drifted \(drift) cents from its ideal share at income \(incomeCents)"
                    )
                }
            }
        }
    }
}
