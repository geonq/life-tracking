import XCTest
@testable import LifeOS

final class SigningStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_783_000_000)

    func testProvisioningModeUsesTheClosedReleaseVocabulary() {
        XCTAssertEqual(
            ProvisioningMode.releaseModes,
            [.personalTeam, .developerProgram, .sideloaded]
        )
        XCTAssertTrue(ProvisioningMode.releaseModes.allSatisfy(\.isReleaseMode))
        XCTAssertFalse(ProvisioningMode.unknown.isReleaseMode)
        XCTAssertNil(ProvisioningMode(rawValue: "development"))
    }

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

    func testUnknownProvisioningModeCannotBorrowAValidExpirationDate() {
        let status = SigningStatus(
            mode: .unknown,
            expirationDate: now.addingTimeInterval(30 * 86_400),
            now: now
        )

        XCTAssertEqual(status.state, .unknown)
        XCTAssertNil(status.daysRemaining)
        XCTAssertFalse(status.metadataIsComplete)
        XCTAssertEqual(status.stateTitle, "Signing expiration unavailable")
    }

    func testSigningPresentationNamesItsEvidenceBoundary() {
        let status = SigningStatus(
            mode: .developerProgram,
            expirationDate: now.addingTimeInterval(10 * 86_400),
            now: now
        )

        XCTAssertEqual(status.modeTitle, "Apple Developer Program")
        XCTAssertEqual(status.stateTitle, "Signing: 10 days remaining")
        XCTAssertTrue(status.metadataIsComplete)
        XCTAssertTrue(status.evidenceBoundary.contains("entitlements"))
        XCTAssertTrue(status.evidenceBoundary.contains("physical device"))
        XCTAssertFalse(status.evidenceBoundary.contains("token"))
    }
}
