import XCTest
@testable import LifeOS

final class OverviewDomainTests: XCTestCase {
    func testDemoOverviewContainsRequestedCompactCardsWithoutPretendingToBeLive() {
        let overview = DemoDataProvider.overview
        XCTAssertEqual(overview.sections.map(\.kind), [.llm, .clipper, .health, .finance])
        XCTAssertTrue(overview.sections.allSatisfy { $0.provenance.quality == .demo })
        XCTAssertEqual(overview.sections.first { $0.kind == .llm }?.metrics.map(\.label), ["Codex", "Claude", "Banked resets"])
        XCTAssertEqual(overview.sections.first { $0.kind == .clipper }?.metrics.map(\.label), ["Views today", "Subscribers today", "Revenue this month"])
        XCTAssertEqual(overview.sections.first { $0.kind == .clipper }?.metrics.map(\.icon), [.views, .subscribers, .revenue])
        XCTAssertEqual(overview.sections.first { $0.kind == .finance }?.metrics.map(\.icon), [.savings, .budget])
    }

    func testUnavailableValuesStayUnavailableInsteadOfInventingMetrics() {
        let metric = OverviewMetric(label: "Resting heart rate", value: nil, unit: "bpm", icon: .heartRate)
        XCTAssertNil(metric.displayValue)
    }
}
