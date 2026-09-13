import XCTest
@testable import LifeOS

final class ClipperDomainTests: XCTestCase {
    private let referenceNow = ISO8601DateFormatter().date(from: "2026-08-08T12:05:00Z")!

    func testObservedSnapshotDecodesNestedMetricsAndBreakdowns() throws {
        let snapshot = try ClipperSnapshot.decode(Data(observedPayload().utf8), now: referenceNow)

        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.availability, .observed)
        XCTAssertEqual(snapshot.currency, "EUR")
        XCTAssertEqual(snapshot.metrics?.views.value, 42_000)
        XCTAssertEqual(snapshot.metrics?.revenue.amountCents, 84_200)
        XCTAssertEqual(snapshot.accounts?.first?.bots.first?.name, "Daily clips")
        XCTAssertEqual(snapshot.trends?.count, 1)
        XCTAssertEqual(snapshot.breakdowns?.count, 1)
    }

    func testUnavailableSnapshotHasNoMetricOrDetailPayload() throws {
        let expected = ClipperSnapshot.unavailable(at: referenceNow)
        let encoded = try JSONEncoder.lifeOS.encode(expected)
        let decoded = try ClipperSnapshot.decode(encoded, now: referenceNow)

        XCTAssertEqual(decoded, expected)
        XCTAssertEqual(decoded.availability, .unavailable)
        XCTAssertNil(decoded.metrics)
        XCTAssertNil(decoded.accounts)
        XCTAssertEqual(decoded.provenance.quality, .unavailable)
        XCTAssertEqual(decoded.provenance.connectorState, .unavailable)
    }

    func testUnavailableMetricCannotCarryAmountOrHealthyProvenance() throws {
        let payload = observedPayload()
            .replacingOccurrences(of: "\"availability\":\"observed\",\"amountCents\":84200", with: "\"availability\":\"unavailable\",\"amountCents\":0")
            .replacingOccurrences(of: "\"quality\":\"observed\",\"connectorState\":\"healthy\"", with: "\"quality\":\"unavailable\",\"connectorState\":\"unavailable\"")

        XCTAssertThrowsError(try ClipperSnapshot.decode(Data(payload.utf8), now: referenceNow))
    }

    func testDuplicateAccountAndBreakdownIDsAreRejected() throws {
        let payload = observedPayload()
        // Decode a structurally valid payload first, then use JSONSerialization
        // to duplicate the account and top-level breakdown without relying on
        // string formatting.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let accounts = try XCTUnwrap(object["accounts"] as? [[String: Any]])
        object["accounts"] = accounts + accounts
        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let breakdowns = try XCTUnwrap(object["breakdowns"] as? [[String: Any]])
        object["breakdowns"] = breakdowns + breakdowns
        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))

        object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        let trends = try XCTUnwrap(object["trends"] as? [[String: Any]])
        object["trends"] = trends + trends
        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testObservedCountsAreCappedAtTheCrossLanguageSafeIntegerMaximum() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        var metrics = try XCTUnwrap(object["metrics"] as? [String: Any])
        var views = try XCTUnwrap(metrics["views"] as? [String: Any])
        views["value"] = 9_007_199_254_740_992
        metrics["views"] = views
        object["metrics"] = metrics

        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testTopLevelProvenanceMustMatchItsFreshnessAndConnectorState() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        var provenance = try XCTUnwrap(object["provenance"] as? [String: Any])
        provenance["freshness"] = "stale"
        provenance["connectorState"] = "refresh_due"
        object["provenance"] = provenance

        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testFreshProvenanceCannotClaimRefreshDue() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        var provenance = try XCTUnwrap(object["provenance"] as? [String: Any])
        provenance["connectorState"] = "refresh_due"
        object["provenance"] = provenance

        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testStaleProvenanceCannotClaimHealthy() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        var provenance = try XCTUnwrap(object["provenance"] as? [String: Any])
        provenance["observedAt"] = "2026-08-08T11:00:00Z"
        provenance["freshness"] = "stale"
        provenance["connectorState"] = "healthy"
        object["provenance"] = provenance

        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testUnsupportedConnectorStatesAndWhitespaceSourcesAreRejected() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        var provenance = try XCTUnwrap(object["provenance"] as? [String: Any])
        provenance["connectorState"] = "disabled"
        object["provenance"] = provenance
        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))

        provenance["connectorState"] = "healthy"
        provenance["source"] = "   "
        object["provenance"] = provenance
        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testPartialObservedSnapshotStillRequiresAnObservedMetric() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        object["metrics"] = unavailableMetricSet()
        object["accounts"] = []
        var provenance = try XCTUnwrap(object["provenance"] as? [String: Any])
        provenance["quality"] = "partial"
        object["provenance"] = provenance

        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testGeneratedAtMustCoverNestedTrendAndProvenanceTimestamps() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(observedPayload().utf8)) as? [String: Any])
        object["generatedAt"] = "2026-08-08T11:00:00Z"

        XCTAssertThrowsError(try ClipperSnapshot.decode(JSONSerialization.data(withJSONObject: object), now: referenceNow))
    }

    func testClipperBoundaryRejectsOversizedAndDuplicateJSONPayloads() throws {
        XCTAssertThrowsError(
            try ClipperSnapshot.decode(
                Data(repeating: 0x20, count: ClipperPayloadLimits.maximumSnapshotBytes + 1),
                now: referenceNow
            )
        ) { error in
            XCTAssertEqual(error as? ClipperPayloadError, .payloadTooLarge)
        }

        let duplicate = Data(#"{"availability":"unavailable","availability":"unavailable"}"#.utf8)
        XCTAssertThrowsError(try ClipperSnapshot.decode(duplicate, now: referenceNow)) { error in
            XCTAssertEqual(error as? ClipperPayloadError, .duplicateJSONKey)
        }
    }

    func testSecretFilePolicyValidatesShapeAndPermissionsWithoutReturningSecret() {
        XCTAssertEqual(
            ClipperSecretFilePolicy.validate(data: Data(repeating: 0x73, count: 32), permissions: 0o600),
            .valid
        )
        XCTAssertEqual(
            ClipperSecretFilePolicy.validate(data: Data(repeating: 0x73, count: 31), permissions: 0o600),
            .invalidShape
        )
        XCTAssertEqual(
            ClipperSecretFilePolicy.validate(data: Data(repeating: 0x73, count: 32), permissions: 0o644),
            .insecurePermissions
        )
        XCTAssertEqual(
            ClipperSecretFilePolicy.validate(data: Data(repeating: 0x0a, count: 32), permissions: 0o600),
            .invalidShape
        )
    }

    func testCanonicalClipperIdentityAndReplayLedgerAreDeterministic() throws {
        let data = Data(observedPayload().utf8)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data))
        let reordered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let firstKey = try ClipperPayloadIdentity.idempotencyKey(for: data)
        XCTAssertEqual(firstKey, try ClipperPayloadIdentity.idempotencyKey(for: reordered))

        var ledger = ClipperReplayLedger()
        let snapshot = try ClipperSnapshot.decode(data, now: referenceNow)
        XCTAssertEqual(try ledger.accept(snapshot: snapshot, now: referenceNow), .accepted)
        XCTAssertEqual(try ledger.accept(snapshot: snapshot, now: referenceNow), .replay)
        XCTAssertEqual(
            try ledger.accept(snapshot: snapshot, now: referenceNow.addingTimeInterval(16 * 60)),
            .stale
        )
        ledger.revoke()
        XCTAssertEqual(try ledger.accept(snapshot: snapshot, now: referenceNow), .revoked)
    }

    func testClipperSourceApprovalRequiresExactSourceAndFields() throws {
        let snapshot = try ClipperSnapshot.decode(Data(observedPayload().utf8), now: referenceNow)
        let allFields = ClipperSourceApproval(
            source: "reviewed-clipper-connector",
            fields: Set(ClipperApprovedField.allCases)
        )
        XCTAssertTrue(allFields.permits(snapshot))
        XCTAssertFalse(
            ClipperSourceApproval(
                source: "reviewed-clipper-connector",
                fields: [.views]
            ).permits(snapshot)
        )
        XCTAssertFalse(
            ClipperSourceApproval(
                source: "different-source",
                fields: Set(ClipperApprovedField.allCases)
            ).permits(snapshot)
        )
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testDemoStateCannotBypassSourceApprovalForObservedSnapshot() async throws {
        let snapshot = try ClipperSnapshot.decode(Data(observedPayload().utf8), now: referenceNow)
        let coordinator = await MainActor.run {
            ClipperCoordinator(
                fetch: { snapshot },
                initialSnapshot: snapshot,
                initialState: .demo,
                revocationPersistence: InMemoryClipperRevocationPersistence()
            )
        }

        let result = await MainActor.run {
            (coordinator.state, coordinator.failure, coordinator.snapshot.availability)
        }
        XCTAssertEqual(result.0, .unavailable)
        XCTAssertEqual(result.1, .sourceUnavailable)
        XCTAssertEqual(result.2, .unavailable)
    }

    private func observedPayload() -> String {
        """
        {
          "schemaVersion": 1,
          "availability": "observed",
          "generatedAt": "2026-08-08T12:00:00Z",
          "currency": "EUR",
          "metrics": \(metricSetJSON()),
          "accounts": [{
            "id": "account-1", "name": "Primary account",
            "metrics": \(metricSetJSON()),
            "bots": [{"id":"bot-1","name":"Daily clips","metrics":\(metricSetJSON()),"breakdowns":[]}],
            "breakdowns": []
          }],
          "trends": [{"at":"2026-08-08T12:00:00Z","metrics":\(metricSetJSON())}],
          "breakdowns": [{"id":"month-2026-08","label":"August 2026","periodStart":"2026-08-01T00:00:00Z","periodEnd":"2026-09-01T00:00:00Z","metrics":\(metricSetJSON())}],
          "provenance": {"source":"reviewed-clipper-connector","observedAt":"2026-08-08T12:00:00Z","freshness":"fresh","quality":"observed","connectorState":"healthy"}
        }
        """
    }

    private func metricSetJSON() -> String {
        """
        {"views":{"availability":"observed","value":42000,"provenance":\(provenanceJSON())},"subscribers":{"availability":"observed","value":1240,"provenance":\(provenanceJSON())},"revenue":{"availability":"observed","amountCents":84200,"currency":"EUR","provenance":\(provenanceJSON())}}
        """
    }

    private func provenanceJSON() -> String {
        "{\"source\":\"reviewed-clipper-connector\",\"observedAt\":\"2026-08-08T12:00:00Z\",\"freshness\":\"fresh\",\"quality\":\"observed\",\"connectorState\":\"healthy\"}"
    }

    private func unavailableMetricSet() -> [String: Any] {
        let provenance: [String: Any] = [
            "source": "reviewed-clipper-connector",
            "observedAt": "2026-08-08T12:00:00Z",
            "freshness": "unknown",
            "quality": "unavailable",
            "connectorState": "unavailable",
        ]
        return [
            "views": ["availability": "unavailable", "provenance": provenance],
            "subscribers": ["availability": "unavailable", "provenance": provenance],
            "revenue": ["availability": "unavailable", "currency": "EUR", "provenance": provenance],
        ]
    }
}
final class ClipperCoordinatorTests: XCTestCase {
    @available(iOS 17.0, macOS 14.0, *)
    func testSourceUnavailableAndTransportFailureRemainTyped() async {
        let unavailable = await MainActor.run {
            ClipperCoordinator(
                fetch: { ClipperSnapshot.unavailable() },
                revocationPersistence: InMemoryClipperRevocationPersistence()
            )
        }
        await unavailable.refresh()
        let unavailableResult = await MainActor.run {
            (unavailable.state, unavailable.failure, unavailable.snapshot.availability)
        }
        XCTAssertEqual(unavailableResult.0, .unavailable)
        XCTAssertEqual(unavailableResult.1, .sourceUnavailable)
        XCTAssertEqual(unavailableResult.2, .unavailable)

        let failed = await MainActor.run {
            ClipperCoordinator(
                fetch: { throw TailscaleSyncError.gatewayNotConfigured },
                revocationPersistence: InMemoryClipperRevocationPersistence(),
                sourceApproval: ClipperSourceApproval(
                    source: "reviewed-clipper-connector",
                    fields: Set(ClipperApprovedField.allCases)
                )
            )
        }
        await failed.refresh()
        let failedResult = await MainActor.run { (failed.state, failed.failure, failed.errorMessage) }
        XCTAssertEqual(failedResult.0, .unavailable)
        XCTAssertEqual(failedResult.1, .transport)
        XCTAssertEqual(failedResult.2, "Clipper source unavailable; retry the connector")
    }

    @available(iOS 17.0, macOS 14.0, *)
    func testLocalRevokeClearsSnapshotAndBlocksRefreshUntilExplicitClear() async {
        let persistence = InMemoryClipperRevocationPersistence()
        let fetchProbe = ClipperFetchProbe()
        let coordinator = await MainActor.run {
            ClipperCoordinator(
                fetch: {
                    fetchProbe.increment()
                    return ClipperSnapshot.unavailable()
                },
                revocationPersistence: persistence
            )
        }

        await MainActor.run { coordinator.revokeLocally() }
        await coordinator.refresh()
        let revoked = await MainActor.run {
            (coordinator.isLocallyRevoked, coordinator.state, coordinator.failure, coordinator.snapshot.availability)
        }
        XCTAssertTrue(revoked.0)
        XCTAssertEqual(revoked.1, .unavailable)
        XCTAssertEqual(revoked.2, .revoked)
        XCTAssertEqual(revoked.3, .unavailable)
        XCTAssertTrue(persistence.revoked)
        XCTAssertEqual(fetchProbe.value, 0)

        await MainActor.run { coordinator.clearLocalRevocation() }
        let cleared = await MainActor.run {
            (coordinator.isLocallyRevoked, coordinator.state, coordinator.failure, coordinator.snapshot.availability)
        }
        XCTAssertFalse(cleared.0)
        XCTAssertEqual(cleared.1, .unavailable)
        XCTAssertEqual(cleared.2, .sourceUnavailable)
        XCTAssertEqual(cleared.3, .unavailable)
    }
}

private final class InMemoryClipperRevocationPersistence: ClipperRevocationPersistence {
    var revoked = false

    func isRevoked() -> Bool { revoked }
    func setRevoked(_ revoked: Bool) throws { self.revoked = revoked }
}

private final class ClipperFetchProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
