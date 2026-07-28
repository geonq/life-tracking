import XCTest
@testable import LifeOS

final class SigningStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testFreeProvisioningWarnsBeforeExpiration() {
        let status = SigningStatus(
            mode: .personalTeam,
            expirationDate: now.addingTimeInterval(2 * 86_400),
            now: now
        )

        XCTAssertEqual(status.state, .expiringSoon)
        XCTAssertEqual(status.daysRemaining, 2)
        XCTAssertFalse(status.canSelfRenew)
        XCTAssertTrue(status.guidance.localizedCaseInsensitiveContains("rebuild"))
    }

    func testExpiredProvisioningNeverClaimsSelfRenewal() {
        let status = SigningStatus(
            mode: .personalTeam,
            expirationDate: now.addingTimeInterval(-1),
            now: now
        )

        XCTAssertEqual(status.state, .expired)
        XCTAssertEqual(status.daysRemaining, 0)
        XCTAssertFalse(status.canSelfRenew)
    }

    func testUnknownExpirationIsExplicitlyUnknown() {
        let status = SigningStatus(mode: .unknown, expirationDate: nil, now: now)

        XCTAssertEqual(status.state, .unknown)
        XCTAssertNil(status.daysRemaining)
        XCTAssertFalse(status.canSelfRenew)
    }
}
