import XCTest
@testable import LifeOSMac

@available(macOS 14.0, *)
final class UsageConnectionActionsMacTests: XCTestCase {
    private func connection(
        providerID rawProviderID: String,
        connectionID rawConnectionID: String,
        enabled: Bool = true,
        authState: UsageAuthState = .notRequired,
        availability: UsageAvailability = .available
    ) throws -> UsageRegistryConnection {
        try UsageRegistryConnection(
            connectionID: try UsageConnectionID(rawConnectionID),
            providerID: try UsageProviderID(rawProviderID),
            label: rawProviderID,
            enabled: enabled,
            sortOrder: 1,
            authState: authState,
            availability: availability
        )
    }

    private func descriptor(for rawProviderID: String) throws -> UsageProviderDescriptor {
        try XCTUnwrap(
            UsageProviderCatalog.descriptor(for: try UsageProviderID(rawProviderID))
        )
    }

    func testGeminiSubscriptionActionsAreClosedAndHaveUniqueIDs() throws {
        let source = try connection(
            providerID: "gemini_subscription",
            connectionID: "catalog.gemini_subscription"
        )
        let actions = UsageConnectionActionResolver.actions(
            for: source,
            descriptor: try descriptor(for: "gemini_subscription")
        )

        XCTAssertEqual(actions.map(\.kind), [.addManualReading, .openGemini, .openGeminiHelp])
        XCTAssertEqual(Set(actions.map(\.id)).count, actions.count)
        XCTAssertTrue(actions[0].isManualEntry)
        XCTAssertNil(actions[0].destination)
        XCTAssertEqual(actions[1].destination, .gemini)
        XCTAssertEqual(actions[2].destination, .geminiHelp)
    }

    func testGeminiAPIOffersOnlyItsReviewedProjectDestination() throws {
        let source = try connection(
            providerID: "gemini_api",
            connectionID: "catalog.gemini_api",
            authState: .disconnected,
            availability: .unsupported
        )
        let actions = UsageConnectionActionResolver.actions(
            for: source,
            descriptor: try descriptor(for: "gemini_api")
        )

        XCTAssertEqual(actions.map(\.kind), [.openAIStudio])
        XCTAssertEqual(actions.first?.destination, .aiStudio)
        XCTAssertFalse(actions.contains { $0.isManualEntry })
    }

    func testClaudeActionAndStateGatesRemainExplicit() throws {
        let claude = try connection(
            providerID: "claude",
            connectionID: "legacy.claude",
            authState: .connected
        )
        let actions = UsageConnectionActionResolver.actions(
            for: claude,
            descriptor: try descriptor(for: "claude")
        )
        XCTAssertEqual(actions.map(\.kind), [.openClaude])
        XCTAssertEqual(actions.first?.destination, .claude)

        let disabled = try connection(
            providerID: "gemini_subscription",
            connectionID: "catalog.gemini_subscription.disabled",
            enabled: false
        )
        XCTAssertTrue(
            UsageConnectionActionResolver.actions(
                for: disabled,
                descriptor: try descriptor(for: "gemini_subscription")
            ).isEmpty
        )

        let revoked = try connection(
            providerID: "gemini_subscription",
            connectionID: "catalog.gemini_subscription.revoked",
            authState: .revoked
        )
        XCTAssertTrue(
            UsageConnectionActionResolver.actions(
                for: revoked,
                descriptor: try descriptor(for: "gemini_subscription")
            ).isEmpty
        )
    }
}
