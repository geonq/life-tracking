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
}
