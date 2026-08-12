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
