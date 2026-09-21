import XCTest
import CryptoKit
import Foundation
@testable import LifeOSMac

final class DomainSyncTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var firstID: UUID { fixtureUUID("00000000-0000-4000-8000-000000000001") }
    private var secondID: UUID { fixtureUUID("00000000-0000-4000-8000-000000000002") }
    private var seriesID: UUID { fixtureUUID("11111111-1111-4111-8111-111111111111") }
    private var validPNG: Data {
        guard let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=") else {
            XCTFail("invalid PNG test fixture")
            return Data()
        }
        return data
    }

    func testCalendarSeriesRoundTripPreservesFractionalDatesIconAndRecurrence() throws {
        let createdAt = base.addingTimeInterval(0.125)
        let updatedAt = base.addingTimeInterval(0.875)
        let start = base.addingTimeInterval(1.125)
        let end = base.addingTimeInterval(61.875)
        let recurrenceUntil = base.addingTimeInterval(86_400.25)
        let recurrence = try CalendarRecurrenceRule(
            frequency: .weekly,
            interval: 2,
            until: recurrenceUntil
        )
        let item = try CalendarItem(
            id: firstID,
            title: "Deep work",
            icon: "🧭",
            start: start,
            end: end,
            createdAt: createdAt,
            updatedAt: updatedAt,
            timeZoneIdentifier: "Europe/Berlin",
            recurrence: recurrence
        )

        let bytes = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let decoded = try CalendarPayloadCodec.decode(bytes)

        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.tag, "calendarSeries")
        XCTAssertEqual(decoded.seriesID, seriesID.uuidString.lowercased())
        XCTAssertEqual(decoded.items, [item])
        XCTAssertEqual(decoded.items[0].start.timeIntervalSince1970, start.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(decoded.items[0].updatedAt.timeIntervalSince1970, updatedAt.timeIntervalSince1970, accuracy: 0.000_001)
        XCTAssertEqual(decoded.items[0].icon, "🧭")
        XCTAssertEqual(decoded.items[0].recurrence, recurrence)
    }

    func testCalendarSeriesEncodingIsDeterministicRegardlessOfInputOrder() throws {
        let first = try CalendarItem(
            id: firstID,
            title: "First",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let second = try CalendarItem(
            id: secondID,
            title: "Second",
            start: base.addingTimeInterval(120),
            end: base.addingTimeInterval(180),
            createdAt: base,
            updatedAt: base
        )

        let forward = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [first, second])
        let reversed = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [second, first])

        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(try CalendarPayloadCodec.decode(forward).items.map(\.id), [firstID, secondID])
    }

    func testCalendarSeriesRejectsWrongTagVersionAndSeriesID() throws {
        let item = try makeItem(id: firstID)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))

        let wrongTag = replacing(
            validText,
            #""tag":"calendarSeries""#,
            #""tag":"other""#
        )
        let wrongVersion = replacing(
            validText,
            #""schemaVersion":1"#,
            #""schemaVersion":2"#
        )
        let wrongSeriesID = replacing(
            validText,
            seriesID.uuidString.lowercased(),
            "not-a-uuid"
        )

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(wrongTag.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(wrongVersion.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(wrongSeriesID.utf8)))
    }

    func testCalendarSeriesRejectsMissingUnknownAndDuplicateRootKeys() throws {
        let item = try makeItem(id: firstID)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))

        let missingTag = replacing(
            validText,
            #","tag":"calendarSeries""#,
            ""
        )
        let unknownRoot = replacing(
            validText,
            "{",
            #"{"extra":true,"#
        )
        let duplicateRoot = replacing(
            validText,
            #""tag":"calendarSeries""#,
            #""tag":"calendarSeries","tag":"calendarSeries""#
        )

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(missingTag.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(unknownRoot.utf8)))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(duplicateRoot.utf8)))
    }

    func testCalendarSeriesRejectsDuplicateItemIDs() throws {
        let item = try makeItem(id: firstID)
        let itemJSON = try XCTUnwrap(String(data: JSONEncoder.calendar.encode(item), encoding: .utf8))
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let duplicate = replacing(validText, "]", ",\(itemJSON)]")

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(duplicate.utf8)))
    }

    func testCalendarSeriesRejectsTransientOccurrenceIDs() throws {
        let item = try makeItem(id: firstID)
        var transientItem = item
        transientItem.occurrenceSourceID = secondID
        XCTAssertThrowsError(try CalendarPayloadCodec.encode(seriesID: seriesID, items: [transientItem])) { error in
            XCTAssertEqual(error as? CalendarValidationError, .transientOccurrence)
        }

        let itemJSON = try XCTUnwrap(String(data: JSONEncoder.calendar.encode(item), encoding: .utf8))
        let transient = replacing(itemJSON, "{", "{\"occurrenceSourceID\":\"\(secondID.uuidString.lowercased())\",")
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let payload = replacing(validText, itemJSON, transient)

        let canonicalPayload = try SyncWireCodec.canonicalizeJSON(Data(payload.utf8))
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonicalPayload))
    }

    func testCalendarSeriesCanonicalizesDecomposedTitleOnlyAtWireBoundary() throws {
        let decomposedTitle = "Cafe\u{301}"
        let item = try CalendarItem(
            id: firstID,
            title: decomposedTitle,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )

        let payload = try CalendarSeriesPayload(seriesID: seriesID.uuidString.lowercased(), items: [item])
        let publicBytes = try JSONEncoder.calendar.encode(payload)
        let codecBytes = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let decoded = try CalendarPayloadCodec.decode(publicBytes)

        XCTAssertEqual(item.title, decomposedTitle)
        XCTAssertEqual(Array(item.title.utf8), Array(decomposedTitle.utf8))
        XCTAssertEqual(publicBytes, codecBytes)
        XCTAssertEqual(Array(payload.items[0].title.utf8), Array("Café".utf8))
        XCTAssertEqual(decoded.items[0].title, "Café")
        XCTAssertNotEqual(Array(item.title.utf8), Array(decoded.items[0].title.utf8))
    }

    func testCalendarSeriesRejectsNonNFCTitleAtDecodeBoundary() throws {
        let item = try makeItem(id: firstID)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let nonNFCPayload = replacing(validText, "Calendar item", "Cafe\u{301}")

        XCTAssertThrowsError(
            try JSONDecoder.calendar.decode(
                CalendarSeriesPayload.self,
                from: Data(nonNFCPayload.utf8)
            )
        )
    }

    func testCalendarSeriesRejectsUnknownNestedRecurrenceKeys() throws {
        let recurrence = try CalendarRecurrenceRule(frequency: .weekly, interval: 2, until: base.addingTimeInterval(86_400))
        let item = try CalendarItem(
            id: firstID,
            title: "Recurring",
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base,
            recurrence: recurrence
        )
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let mutated = replacing(
            validText,
            #""recurrence":{"#,
            #""recurrence":{"extra":true,"#
        )
        let canonical = try SyncWireCodec.canonicalizeJSON(Data(mutated.utf8))

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonical))
    }

    func testCalendarSeriesRejectsUnknownNestedIconAssetKeys() throws {
        let asset = try CalendarIconAsset(format: .png, bytes: validPNG)
        let item = try CalendarItem(
            id: firstID,
            title: "With icon asset",
            iconAsset: asset,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let mutated = replacing(
            validText,
            #""iconAsset":{"#,
            #""iconAsset":{"extra":true,"#
        )
        let canonical = try SyncWireCodec.canonicalizeJSON(Data(mutated.utf8))

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonical))
    }

    func testCalendarSeriesRejectsMismatchedIconAssetHash() throws {
        let asset = try CalendarIconAsset(format: .png, bytes: validPNG)
        let item = try CalendarItem(
            id: firstID,
            title: "With icon asset",
            iconAsset: asset,
            start: base,
            end: base.addingTimeInterval(60),
            createdAt: base,
            updatedAt: base
        )
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let wrongHash = String(repeating: "0", count: asset.contentHash.count)
        let mutated = replacing(validText, asset.contentHash, wrongHash)
        let canonical = try SyncWireCodec.canonicalizeJSON(Data(mutated.utf8))

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(canonical))
    }

    func testCalendarSeriesRejectsInvalidItem() throws {
        let item = try makeItem(id: firstID)
        let itemJSON = try XCTUnwrap(String(data: JSONEncoder.calendar.encode(item), encoding: .utf8))
        let start = try XCTUnwrap(String(data: try JSONEncoder.calendar.encode(item.start), encoding: .utf8))
        let end = try XCTUnwrap(String(data: try JSONEncoder.calendar.encode(item.end), encoding: .utf8))
        let invalidItem = replacing(itemJSON, end, start)
        let valid = try CalendarPayloadCodec.encode(seriesID: seriesID, items: [item])
        let validText = try XCTUnwrap(String(data: valid, encoding: .utf8))
        let payload = replacing(validText, itemJSON, invalidItem)

        XCTAssertThrowsError(try CalendarPayloadCodec.decode(Data(payload.utf8)))
    }

    func testCalendarSeriesRejectsOversizedPayload() throws {
        let oversized = Data(repeating: 0x20, count: SyncContractConstants.maxInlinePayloadBytes + 1)
        XCTAssertThrowsError(try CalendarPayloadCodec.decode(oversized)) { error in
            XCTAssertEqual(error as? SyncFailure, .capacity)
        }
    }

    func testCalendarStoreMigratesLegacySnapshotAndKeepsWidgetDecodeCompatible() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        try JSONEncoder.calendar.encode(snapshot).write(to: url)

        let store = CalendarStore(url: url)
        let loaded = try await store.loadEnvelope()
        XCTAssertNil(loaded.replication)
        XCTAssertEqual(loaded.seriesMembership.count, 1)
        XCTAssertEqual(loaded.seriesMembership[0].itemID, firstID.uuidString.lowercased())
        XCTAssertEqual(loaded.seriesMembership[0].seriesID, firstID.uuidString.lowercased())

        _ = try await store.save(snapshot)
        let widgetSnapshot = try JSONDecoder.calendar.decode(
            CalendarSnapshot.self,
            from: Data(contentsOf: url)
        )
        XCTAssertEqual(widgetSnapshot, snapshot)
        let persisted = try await store.loadEnvelope()
        XCTAssertNotNil(persisted.seriesMembership.first)
    }

    func testCalendarStorePreservesReplicationOnOrdinarySave() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        let replication = emptyReplication()
        let envelope = try CalendarStoreEnvelope(
            snapshot: snapshot,
            seriesMembership: try links(for: snapshot),
            replication: replication
        )
        let store = CalendarStore(url: url)
        try await store.saveEnvelope(envelope)
        _ = try await store.save(snapshot)
        let reloaded = try await store.loadEnvelope()
        XCTAssertEqual(reloaded.replication, replication)
    }

    func testCalendarSnapshotDecoderAcceptsOneWrapperAndRejectsNestedOrUnknownRoots() throws {
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        let envelope = try CalendarStoreEnvelope(
            snapshot: snapshot,
            seriesMembership: try links(for: snapshot),
            replication: emptyReplication()
        )
        let wrapped = try JSONEncoder.calendar.encode(envelope)
        let decoded = try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: wrapped)
        XCTAssertEqual(decoded, snapshot)

        var wrapperObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: wrapped) as? [String: Any]
        )
        var nestedSnapshot = try XCTUnwrap(wrapperObject["snapshot"] as? [String: Any])
        nestedSnapshot["snapshot"] = nestedSnapshot
        wrapperObject["snapshot"] = nestedSnapshot
        let nested = try JSONSerialization.data(withJSONObject: wrapperObject)
        XCTAssertThrowsError(try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: nested))
        XCTAssertThrowsError(try JSONDecoder.calendar.decode(CalendarStoreEnvelope.self, from: nested))

        var unknownRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: wrapped) as? [String: Any]
        )
        unknownRoot["unexpected"] = true
        let unknown = try JSONSerialization.data(withJSONObject: unknownRoot)
        XCTAssertThrowsError(try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: unknown))

        var rawObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.calendar.encode(snapshot)) as? [String: Any]
        )
        rawObject["unexpected"] = true
        let rawUnknown = try JSONSerialization.data(withJSONObject: rawObject)
        XCTAssertThrowsError(try JSONDecoder.calendar.decode(CalendarSnapshot.self, from: rawUnknown))
    }

    func testCalendarSelfAcknowledgementRetainsOutboxAndRemoteTerminalAckRemovesIt() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )
        let page = try await adapter.pendingPage(after: nil, limit: 128)
        let operation = try XCTUnwrap(page.operations.first)
        let operationHash = try SyncWireCodec.operationHash(for: operation)
        let localDevice = try await identity.identity()
        let selfAcknowledgement = try await identity.signAcknowledgement(SyncAck(
            schemaVersion: 1,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: operation.mutationID,
            operationHash: operationHash,
            replicaID: localDevice.deviceID,
            keyID: localDevice.keyID,
            level: .applied,
            resultHash: operation.payload.hash,
            signature: ""
        ))
        try await adapter.recordAcknowledgement(selfAcknowledgement)
        var envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.outbox.count, 1)

        let remoteKey = Curve25519.Signing.PrivateKey()
        let remoteAcknowledgement = try makeSignedAcknowledgement(
            operation: operation,
            replicaID: remoteOriginID,
            key: remoteKey,
            level: .applied,
            resultHash: operation.payload.hash
        )
        try await adapter.recordAuthenticatedRemoteAcknowledgement(remoteAcknowledgement)
        envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.outbox.count, 0)
        XCTAssertEqual(envelope.replication?.inbox.count, 1)
        XCTAssertTrue(envelope.replication?.receivedAcknowledgements.isEmpty == true)
    }

    func testCalendarRemoteEvidenceKeepsStrongestLevelAndRetiresAtomically() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: remoteStoreID,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )
        let page = try await adapter.pendingPage(after: nil, limit: SyncContractConstants.maxPageOperations)
        let operation = try XCTUnwrap(page.operations.first)
        let remoteKey = Curve25519.Signing.PrivateKey()
        let stored = try makeSignedAcknowledgement(
            operation: operation,
            replicaID: remoteOriginID,
            key: remoteKey,
            level: .stored,
            resultHash: operation.payload.hash
        )
        let applied = try makeSignedAcknowledgement(
            operation: operation,
            replicaID: remoteOriginID,
            key: remoteKey,
            level: .applied,
            resultHash: operation.payload.hash
        )

        try await adapter.recordAuthenticatedRemoteAcknowledgement(stored)
        try await adapter.recordAuthenticatedRemoteAcknowledgement(applied)
        var envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.receivedAcknowledgements, [applied])
        XCTAssertEqual(envelope.replication?.outbox.count, 1)

        try await adapter.recordGatewayAcceptance([operation.mutationID], endpointID: remoteStoreID)
        envelope = try await store.loadEnvelope()
        XCTAssertTrue(envelope.replication?.outbox.isEmpty == true)
        XCTAssertEqual(envelope.replication?.inbox.count, 1)
        XCTAssertTrue(envelope.replication?.receivedAcknowledgements.isEmpty == true)
    }

    func testCalendarCheckpointCompactsCoveredLedgerAcrossRelaunch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot())
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity
        )
        let remoteKey = Curve25519.Signing.PrivateKey()
        var compactedOperation: SyncOperation?
        var removedOperations = 0

        for index in 1...1_025 {
            let item = try makeItem(id: firstID, title: "Stable series")
            let mutationID = String(format: "00000000-0000-4000-8000-%012llx", UInt64(index))
            let operation = try makeSignedOperation(
                seriesID: firstID,
                items: [item],
                datasetID: datasetID,
                storeID: calendarStoreID,
                originID: remoteOriginID,
                sequence: String(index),
                mutationID: mutationID,
                key: remoteKey,
                baseHash: nil,
                kind: .bootstrap
            )
            if index == 1 {
                compactedOperation = operation
            }
            _ = try await adapter.applyRemote(operation)

            if index.isMultiple(of: 64) || index == 1_025 {
                let frontier = SyncFrontier(positions: [
                    SyncPosition(
                        stream: SyncStream(storeID: calendarStoreID, originID: remoteOriginID),
                        through: String(index)
                    )
                ])
                let receipt = try await adapter.checkpoint(frontier)
                removedOperations += receipt.removedOperations
            }
        }

        XCTAssertGreaterThan(removedOperations, 1_000)
        let envelope = try await store.loadEnvelope()
        XCTAssertLessThanOrEqual(envelope.replication?.inbox.count ?? .max, 2)
        XCTAssertLessThanOrEqual(envelope.replication?.receipts.count ?? .max, 2)
        XCTAssertLessThanOrEqual(envelope.replication?.receivedAcknowledgements.count ?? .max, 2)
        XCTAssertEqual(
            envelope.replication?.applied.positions.first?.through,
            "1025"
        )

        let relaunchedStore = CalendarStore(url: url)
        let relaunched = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity
        )
        try await relaunched.recover()
        let beforeReplay = try await relaunchedStore.load()
        let firstOperation = try makeSignedOperation(
            seriesID: firstID,
            items: [try makeItem(id: firstID, title: "Version 1")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "00000000-0000-4000-8000-000000000001",
            key: remoteKey,
            baseHash: nil,
            kind: .bootstrap
        )
        let replay = try await relaunched.applyRemote(firstOperation)
        XCTAssertEqual(replay.disposition, .alreadyApplied)
        let afterReplay = try await relaunchedStore.load()
        XCTAssertEqual(afterReplay, beforeReplay)

        let compacted = try XCTUnwrap(compactedOperation)
        let localDevice = try await identity.identity()
        let delayedLocalAcknowledgement = try await identity.signAcknowledgement(SyncAck(
            schemaVersion: SyncContractConstants.schemaVersion,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: compacted.mutationID,
            operationHash: try SyncWireCodec.operationHash(for: compacted),
            replicaID: localDevice.deviceID,
            keyID: localDevice.keyID,
            level: .applied,
            resultHash: compacted.payload.hash,
            signature: ""
        ))
        let endpoint = makeEngineEndpoint(
            endpointID: remoteStoreID,
            members: [
                SyncMember(
                    deviceID: localDevice.deviceID,
                    keyID: localDevice.keyID,
                    publicKey: localDevice.publicKey,
                    role: .applying,
                    endpoint: nil
                ),
                SyncMember(
                    deviceID: remoteOriginID,
                    keyID: SyncWireCodec.sha256(remoteKey.publicKey.rawRepresentation),
                    publicKey: base64URL(remoteKey.publicKey.rawRepresentation),
                    role: .applying,
                    endpoint: nil
                )
            ]
        )
        let response = SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: calendarStoreID,
            results: [],
            operations: [],
            acknowledgements: [delayedLocalAcknowledgement],
            upper: SyncFrontier(positions: [
                SyncPosition(
                    stream: SyncStream(storeID: calendarStoreID, originID: remoteStoreID),
                    through: "1"
                )
            ]),
            more: false
        )
        let engineAdapter = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: remoteStoreID
        )
        let beforeSnapshot = try await relaunchedStore.load()
        let beforeEnvelope = try await relaunchedStore.loadEnvelope()
        let beforeOutbox = beforeEnvelope.replication?.outbox ?? []
        let transport = AuthenticatedResponseTransport(responses: [response])
        let frontierStore = EngineTestFrontierStore()
        let engine = try SyncEngine(
            adapters: [engineAdapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )

        _ = try await engine.synchronizeOnce(reason: .background)

        let afterEchoSnapshot = try await relaunchedStore.load()
        let afterEchoEnvelope = try await relaunchedStore.loadEnvelope()
        XCTAssertEqual(afterEchoSnapshot, beforeSnapshot)
        XCTAssertEqual(afterEchoEnvelope.replication?.outbox ?? [], beforeOutbox)
        let advancedFrontier = try await frontierStore.loadFrontier()
        XCTAssertEqual(
            advancedFrontier.positions.first(where: { $0.stream.originID == remoteStoreID })?.through,
            "1"
        )
    }

    func testSyncEngineVerifiesSignedRemoteOperationAndTerminalAcknowledgement() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: remoteStoreID,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )
        let localDevice = try await identity.identity()
        let remoteKey = Curve25519.Signing.PrivateKey()
        let endpoint = makeEngineEndpoint(
            endpointID: remoteStoreID,
            members: [
                SyncMember(
                    deviceID: localDevice.deviceID,
                    keyID: localDevice.keyID,
                    publicKey: localDevice.publicKey,
                    role: .applying,
                    endpoint: nil
                ),
                SyncMember(
                    deviceID: remoteOriginID,
                    keyID: SyncWireCodec.sha256(remoteKey.publicKey.rawRepresentation),
                    publicKey: base64URL(remoteKey.publicKey.rawRepresentation),
                    role: .applying,
                    endpoint: nil
                )
            ]
        )
        let localPage = try await adapter.pendingPage(after: nil, limit: SyncContractConstants.maxPageOperations)
        let localOperation = try XCTUnwrap(localPage.operations.first)
        let remoteOperation = try makeSignedOperation(
            seriesID: secondID,
            items: [try makeItem(id: secondID, title: "Remote operation")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "abababab-abab-4aba-8aba-abababababab",
            key: remoteKey,
            baseHash: nil,
            kind: .bootstrap
        )
        let remoteAcknowledgement = try makeSignedAcknowledgement(
            operation: localOperation,
            replicaID: remoteOriginID,
            key: remoteKey,
            level: .applied,
            resultHash: localOperation.payload.hash
        )
        let firstResponse = SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: calendarStoreID,
            results: [SyncOperationResult(mutationID: localOperation.mutationID, disposition: "stored", error: nil)],
            operations: [remoteOperation],
            acknowledgements: [remoteAcknowledgement],
            upper: SyncFrontier(positions: [
                SyncPosition(stream: SyncStream(storeID: calendarStoreID, originID: remoteOriginID), through: "1"),
                SyncPosition(stream: SyncStream(storeID: calendarStoreID, originID: remoteStoreID), through: "1")
            ]),
            more: false
        )
        let secondResponse = makeEngineResponse(
            upper: SyncFrontier(positions: [
                SyncPosition(stream: SyncStream(storeID: calendarStoreID, originID: remoteOriginID), through: "1"),
                SyncPosition(stream: SyncStream(storeID: calendarStoreID, originID: remoteStoreID), through: "2")
            ])
        )
        let transport = AuthenticatedResponseTransport(responses: [firstResponse, secondResponse])
        let frontierStore = EngineTestFrontierStore()
        let firstEngine = try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        _ = try await firstEngine.synchronizeOnce(reason: .background)

        var envelope = try await store.loadEnvelope()
        XCTAssertTrue(envelope.replication?.outbox.isEmpty == true)
        XCTAssertTrue(envelope.replication?.receivedAcknowledgements.isEmpty == true)
        XCTAssertEqual(envelope.replication?.acknowledgements.count, 1)

        let relaunchedStore = CalendarStore(url: url)
        let relaunchedAdapter = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: remoteStoreID,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )
        let secondEngine = try SyncEngine(
            adapters: [relaunchedAdapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        _ = try await secondEngine.synchronizeOnce(reason: .background)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[0].acknowledgements.isEmpty)
        XCTAssertEqual(requests[1].acknowledgements.count, 1)
        XCTAssertEqual(requests[1].acknowledgements[0].replicaID, localOriginID)
        envelope = try await relaunchedStore.loadEnvelope()
        XCTAssertTrue(envelope.replication?.acknowledgements.isEmpty == true)
        XCTAssertTrue(envelope.replication?.receivedAcknowledgements.isEmpty == true)
    }

    func testCalendarUnauthorizedKnownOperationAckIsRejectedByDefault() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let page = try await adapter.pendingPage(after: nil, limit: 128)
        let operation = try XCTUnwrap(page.operations.first)
        let acknowledgement = try makeSignedAcknowledgement(
            operation: operation,
            replicaID: remoteOriginID,
            key: Curve25519.Signing.PrivateKey(),
            level: .applied,
            resultHash: operation.payload.hash
        )

        do {
            try await adapter.recordAcknowledgement(acknowledgement)
            XCTFail("A remote ACK through the default adapter path must be rejected")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .unauthenticated)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.outbox.count, 1)
        XCTAssertEqual(envelope.replication?.inbox.count, 0)
        XCTAssertTrue(envelope.replication?.acknowledgements.isEmpty == true)
        XCTAssertTrue(envelope.replication?.receivedAcknowledgements.isEmpty == true)
    }

    func testSyncEngineDoesNotPersistUnverifiedZeroFrontierOriginsAfterFirstPage() async throws {
        let existingOriginID = remoteOriginID
        let unverifiedOriginA = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        let unverifiedOriginB = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        let initialFrontier = SyncFrontier(positions: [
            SyncPosition(
                stream: SyncStream(storeID: calendarStoreID, originID: existingOriginID),
                through: "3"
            )
        ])
        let response = SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: calendarStoreID,
            results: [],
            operations: [],
            acknowledgements: [],
            upper: SyncFrontier(positions: [
                SyncPosition(
                    stream: SyncStream(storeID: calendarStoreID, originID: existingOriginID),
                    through: "3"
                ),
                SyncPosition(
                    stream: SyncStream(storeID: calendarStoreID, originID: unverifiedOriginA),
                    through: "0"
                ),
                SyncPosition(
                    stream: SyncStream(storeID: calendarStoreID, originID: unverifiedOriginB),
                    through: "0"
                )
            ]),
            more: true
        )
        let adapter = EngineTestAdapter(
            storeID: calendarStoreID,
            page: SyncPage(
                operations: [],
                acknowledgements: [],
                cursor: SyncFrontier(positions: []),
                hasMore: true
            )
        )
        let frontierStore = EngineTestFrontierStore(frontier: initialFrontier)
        let engine = try SyncEngine(
            adapters: [adapter],
            transport: EngineTestTransport(response: response),
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: TestSyncKeychainStore()),
            frontierStore: frontierStore,
            endpoint: makeEngineEndpoint(endpointID: remoteStoreID)
        )

        _ = try await engine.synchronizeOnce(reason: .background)

        let persisted = try await frontierStore.loadFrontier()
        XCTAssertEqual(
            persisted.positions.first(where: { $0.stream.originID == existingOriginID })?.through,
            "3"
        )
        XCTAssertFalse(persisted.positions.contains { position in
            position.stream.originID == unverifiedOriginA || position.stream.originID == unverifiedOriginB
        })
    }

    func testCalendarRemoteAcknowledgementIsEvidenceOnlyAcrossRelaunchAndExchange() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let endpoint = makeEngineEndpoint()
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )

        let initialPage = try await adapter.pendingPage(after: nil, limit: 128)
        let operation = try XCTUnwrap(initialPage.operations.first)
        let remoteAcknowledgement = try makeSignedAcknowledgement(
            operation: operation,
            replicaID: remoteOriginID,
            key: Curve25519.Signing.PrivateKey(),
            level: .stored,
            resultHash: operation.payload.hash
        )
        try await adapter.recordAuthenticatedRemoteAcknowledgement(remoteAcknowledgement)

        var persisted = try await store.loadEnvelope()
        XCTAssertTrue(persisted.replication?.acknowledgements.isEmpty == true)
        XCTAssertEqual(persisted.replication?.receivedAcknowledgements ?? [], [remoteAcknowledgement])

        let relaunchedAdapter = try CalendarSyncAdapter(
            store: CalendarStore(url: url),
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )
        let relaunchedPage = try await relaunchedAdapter.pendingPage(after: nil, limit: 128)
        XCTAssertFalse(relaunchedPage.operations.isEmpty)
        XCTAssertTrue(relaunchedPage.acknowledgements.isEmpty)

        let transport = LocalReplicaOnlyTransport(localReplicaID: localOriginID)
        let frontierStore = EngineTestFrontierStore()
        let firstEngine = try SyncEngine(
            adapters: [relaunchedAdapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        _ = try await firstEngine.synchronizeOnce(reason: .background)

        let firstRequests = await transport.requests()
        XCTAssertEqual(firstRequests.count, 1)
        XCTAssertTrue(firstRequests[0].acknowledgements.isEmpty)

        let localDevice = try await identity.identity()
        let operationHash = try SyncWireCodec.operationHash(for: operation)
        let localAcknowledgement = try await identity.signAcknowledgement(SyncAck(
            schemaVersion: SyncContractConstants.schemaVersion,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: operation.mutationID,
            operationHash: operationHash,
            replicaID: localDevice.deviceID,
            keyID: localDevice.keyID,
            level: .stored,
            resultHash: operation.payload.hash,
            signature: ""
        ))
        try await relaunchedAdapter.recordAcknowledgement(localAcknowledgement)

        let secondAdapter = try CalendarSyncAdapter(
            store: CalendarStore(url: url),
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: [remoteOriginID]
        )
        let secondEngine = try SyncEngine(
            adapters: [secondAdapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        _ = try await secondEngine.synchronizeOnce(reason: .background)

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 2)
        let secondRequest = try XCTUnwrap(requests.dropFirst().first)
        XCTAssertTrue(secondRequest.operations.isEmpty)
        XCTAssertEqual(secondRequest.acknowledgements, [localAcknowledgement])

        persisted = try await store.loadEnvelope()
        XCTAssertTrue(persisted.replication?.acknowledgements.isEmpty == true)
        XCTAssertEqual(persisted.replication?.receivedAcknowledgements ?? [], [remoteAcknowledgement])
    }

    func testCalendarPendingPageReservesAcknowledgementWhileOutboxRemainsPopulated() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: try makeItems(count: 129)))
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity
        )

        let firstGeneration = try await adapter.pendingPage(after: nil, limit: 128)
        let secondGeneration = try await adapter.pendingPage(after: firstGeneration.cursor, limit: 128)
        let operations = firstGeneration.operations + secondGeneration.operations
        XCTAssertEqual(operations.count, 129)

        let localKey = try await identity.loadOrCreateKey()
        for operation in operations {
            let acknowledgement = try makeSignedAcknowledgement(
                operation: operation,
                replicaID: localOriginID,
                key: localKey,
                level: .applied,
                resultHash: operation.payload.hash
            )
            try await adapter.recordAcknowledgement(acknowledgement)
        }

        let firstMixedPage = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(firstMixedPage.operations.count, 127)
        XCTAssertEqual(firstMixedPage.acknowledgements.count, 1)
        XCTAssertTrue(firstMixedPage.hasMore)
        try await adapter.acknowledgePageDelivered(firstMixedPage.acknowledgements)

        let secondMixedPage = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(secondMixedPage.operations.count, 127)
        XCTAssertEqual(secondMixedPage.acknowledgements.count, 1)
        let envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.outbox.count, 129)
    }

    func testCalendarAcknowledgementPaginationSurvivesRelaunch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: try makeItems(count: 130)))
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity
        )

        let firstOperationPage = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(firstOperationPage.operations.count, 128)
        let secondOperationPage = try await adapter.pendingPage(after: firstOperationPage.cursor, limit: 128)
        XCTAssertEqual(secondOperationPage.operations.count, 2)
        let envelope = try await store.loadEnvelope()
        let operations = try XCTUnwrap(envelope.replication?.outbox.sorted {
            (UInt64($0.operation.sequence) ?? 0) < (UInt64($1.operation.sequence) ?? 0)
        })
        XCTAssertEqual(operations.count, 130)

        let localKey = try await identity.loadOrCreateKey()
        for entry in operations {
            let acknowledgement = try makeSignedAcknowledgement(
                operation: entry.operation,
                replicaID: localOriginID,
                key: localKey,
                level: .stored,
                resultHash: entry.operation.payload.hash
            )
            try await adapter.recordAcknowledgement(acknowledgement)
        }

        let operationThrough = try XCTUnwrap(operations.last.flatMap { UInt64($0.operation.sequence) })
        let operationFrontier = SyncFrontier(positions: [
            SyncPosition(
                stream: SyncStream(storeID: calendarStoreID, originID: localOriginID),
                through: String(operationThrough)
            )
        ])
        let firstAckPage = try await adapter.pendingPage(after: operationFrontier, limit: 128)
        XCTAssertEqual(firstAckPage.operations.count, 0)
        XCTAssertEqual(firstAckPage.acknowledgements.count, 128)
        XCTAssertTrue(firstAckPage.hasMore)
        try await adapter.acknowledgePageDelivered(firstAckPage.acknowledgements)

        let relaunchedStore = CalendarStore(url: url)
        let relaunched = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let secondAckPage = try await relaunched.pendingPage(after: operationFrontier, limit: 128)
        XCTAssertEqual(secondAckPage.operations.count, 0)
        XCTAssertEqual(secondAckPage.acknowledgements.count, 2)
        XCTAssertFalse(secondAckPage.hasMore)
        XCTAssertTrue(
            Set(firstAckPage.acknowledgements.map { $0.operationHash })
                .intersection(Set(secondAckPage.acknowledgements.map { $0.operationHash })).isEmpty
        )
        try await relaunched.acknowledgePageDelivered(secondAckPage.acknowledgements)

        let finalStore = CalendarStore(url: url)
        let finalAdapter = try CalendarSyncAdapter(
            store: finalStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let finalPage = try await finalAdapter.pendingPage(after: operationFrontier, limit: 128)
        XCTAssertTrue(finalPage.acknowledgements.isEmpty)
    }

    func testCalendarPendingPageReportsDirtySeriesBeyondGenerationCap() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: try makeItems(count: 130)))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )

        let firstPage = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(firstPage.operations.count, 128)
        XCTAssertTrue(firstPage.hasMore)
        let secondPage = try await adapter.pendingPage(after: firstPage.cursor, limit: 128)
        XCTAssertEqual(secondPage.operations.count, 2)
        XCTAssertFalse(secondPage.hasMore)
    }

    func testCalendarSyncUsesContiguousGatewayPrefixAcrossInterleavedSeries() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        let firstItem = try makeItem(id: firstID, title: "First series")
        _ = try await store.save(CalendarSnapshot(items: [firstItem]))

        let endpoint = makeEngineEndpoint(endpointID: remoteStoreID)
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: [localOriginID]
        )

        // Generate sequence 1 (bootstrap A), then sequence 2 (edit A with
        // sequence 1 as its causal parent), while leaving sequence 1 unstored.
        let firstSeed = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(firstSeed.operations.map(\.sequence), ["1"])
        let updatedFirstItem = try makeItem(id: firstID, title: "Updated first series")
        _ = try await store.save(CalendarSnapshot(items: [updatedFirstItem]))
        let secondSeed = try await adapter.pendingPage(after: firstSeed.cursor, limit: 128)
        XCTAssertTrue(secondSeed.operations.isEmpty)
        XCTAssertTrue(secondSeed.hasMore)

        // Sequence 3 is an independent series, but it must still wait behind
        // blocked sequence 2 because both operations share the local origin.
        let secondItem = try makeItem(id: secondID, title: "Independent second series")
        _ = try await store.save(CalendarSnapshot(items: [updatedFirstItem, secondItem]))
        let deferredSeed = try await adapter.pendingPage(after: secondSeed.cursor, limit: 128)
        XCTAssertTrue(deferredSeed.operations.isEmpty)
        XCTAssertTrue(deferredSeed.hasMore)

        let transport = ContiguousGatewayTransport(endpointID: endpoint.id)
        let frontierStore = EngineTestFrontierStore()
        let engine = try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        let report = try await engine.synchronizeOnce(reason: .manual)
        let requests = await transport.requests()
        let gapFailures = await transport.gapFailures()

        XCTAssertEqual(report.stored, 3)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].operations.map(\.sequence), ["1"])
        XCTAssertEqual(requests[1].operations.map(\.sequence), ["2", "3"])
        XCTAssertEqual(gapFailures, 0)
    }

    func testCalendarPendingOperationIsStableAcrossCallsAndRelaunch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(snapshot)
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity
        )

        let firstPage = try await adapter.pendingPage(after: nil, limit: 128)
        let secondPage = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(firstPage.operations, secondPage.operations)
        let operation = try XCTUnwrap(firstPage.operations.first)
        try SyncWireCodec.validate(operation)
        XCTAssertEqual(operation.storeID, calendarStoreID)
        let payloadBytes = try SyncContractValidation.requireBase64URL(try XCTUnwrap(operation.payload.inline))
        XCTAssertEqual(SyncWireCodec.sha256(payloadBytes), operation.payload.hash)

        let reopened = CalendarStore(url: url)
        let relaunchedIdentity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let relaunched = try CalendarSyncAdapter(
            store: reopened,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: relaunchedIdentity
        )
        let relaunchedPage = try await relaunched.pendingPage(after: nil, limit: 128)
        XCTAssertEqual(relaunchedPage.operations, firstPage.operations)
    }

    func testCalendarAtoBtoAGeneratesTheFinalRevertedOperation() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "A")]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )

        _ = try await adapter.pendingPage(after: nil, limit: 128)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "B")]))
        _ = try await adapter.pendingPage(after: nil, limit: 128)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "A")]))
        _ = try await adapter.pendingPage(after: nil, limit: 128)

        let envelope = try await store.loadEnvelope()
        let outbox = try XCTUnwrap(envelope.replication?.outbox.sorted {
            (UInt64($0.operation.sequence) ?? 0) < (UInt64($1.operation.sequence) ?? 0)
        })
        XCTAssertEqual(outbox.count, 3)
        XCTAssertEqual(outbox.first?.operation.payload.hash, outbox.last?.operation.payload.hash)
        XCTAssertNotEqual(outbox.first?.operation.mutationID, outbox.last?.operation.mutationID)
    }

    func testCalendarKnownConcurrentParentRetainsConflictWithoutChangingSnapshot() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        let original = CalendarSnapshot(items: [try makeItem(id: firstID, title: "Original")])
        _ = try await store.save(original)
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let ancestorPage = try await adapter.pendingPage(after: nil, limit: 128)
        let ancestorOperation = try XCTUnwrap(ancestorPage.operations.first)
        let localBranch = CalendarSnapshot(items: [try makeItem(id: firstID, title: "Local branch")])
        _ = try await store.save(localBranch)
        let localPage = try await adapter.pendingPage(after: ancestorPage.cursor, limit: 128)
        let localOperation = try XCTUnwrap(localPage.operations.first)
        XCTAssertEqual(localOperation.parents, [ancestorOperation.mutationID])
        let remoteOperation = try makeSignedOperation(
            seriesID: firstID,
            items: [try makeItem(id: firstID, title: "Remote branch")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "55555555-5555-4555-8555-555555555555",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: ancestorOperation.payload.hash,
            kind: .put,
            parents: [ancestorOperation.mutationID]
        )

        let before = try await store.load()
        let receipt = try await adapter.applyRemote(remoteOperation)
        XCTAssertEqual(receipt.disposition, .retainedConflict)
        XCTAssertEqual(before, localBranch)
        let after = try await store.load()
        XCTAssertEqual(after, before)
        let envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.conflicts.first?.branches.count, 2)
    }

    func testCalendarRetainedConflictReplayKeepsReceiptAfterAckDeliveryAndRelaunch() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "Original")]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity
        )

        let ancestorPage = try await adapter.pendingPage(after: nil, limit: 128)
        let ancestor = try XCTUnwrap(ancestorPage.operations.first)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "Local branch")]))
        let localPage = try await adapter.pendingPage(after: ancestorPage.cursor, limit: 128)
        let localBranch = try XCTUnwrap(localPage.operations.first)
        let remoteOperation = try makeSignedOperation(
            seriesID: firstID,
            items: [try makeItem(id: firstID, title: "Remote branch")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "77777777-7777-4777-8777-777777777777",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: ancestor.payload.hash,
            kind: .put,
            parents: [ancestor.mutationID]
        )

        let firstReceipt = try await adapter.applyRemote(remoteOperation)
        XCTAssertEqual(firstReceipt.disposition, .retainedConflict)
        XCTAssertEqual(firstReceipt.entityVersion, localBranch.payload.hash)
        let localDevice = try await identity.identity()
        let acknowledgement = try await identity.signAcknowledgement(SyncAck(
            schemaVersion: 1,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: remoteOperation.mutationID,
            operationHash: try SyncWireCodec.operationHash(for: remoteOperation),
            replicaID: localDevice.deviceID,
            keyID: localDevice.keyID,
            level: .retainedConflict,
            resultHash: firstReceipt.entityVersion,
            signature: ""
        ))
        try await adapter.recordAcknowledgement(acknowledgement)
        let ackPage = try await adapter.pendingPage(after: nil, limit: 128)
        XCTAssertTrue(ackPage.acknowledgements.contains(acknowledgement))
        try await adapter.acknowledgePageDelivered(ackPage.acknowledgements)

        let relaunchedStore = CalendarStore(url: url)
        let relaunched = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let replay = try await relaunched.applyRemote(remoteOperation)
        XCTAssertEqual(replay.disposition, .retainedConflict)
        XCTAssertEqual(replay.entityVersion, firstReceipt.entityVersion)
    }

    func testCalendarNewFormatAppliedReplayRemainsAppliedAfterLaterConflict() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let remoteKey = Curve25519.Signing.PrivateKey()
        let appliedOperation = try makeSignedOperation(
            seriesID: seriesID,
            items: [try makeItem(id: secondID, title: "Applied")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "88888888-8888-4888-8888-888888888888",
            key: remoteKey,
            baseHash: nil,
            kind: .bootstrap
        )
        let firstReceipt = try await adapter.applyRemote(appliedOperation)
        XCTAssertEqual(firstReceipt.disposition, .applied)

        let concurrentOperation = try makeSignedOperation(
            seriesID: seriesID,
            items: [try makeItem(id: secondID, title: "Concurrent")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: "ffffffff-ffff-4fff-8fff-ffffffffffff",
            sequence: "1",
            mutationID: "99999999-9999-4999-8999-999999999999",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: appliedOperation.payload.hash,
            kind: .put,
            parents: []
        )
        let conflictReceipt = try await adapter.applyRemote(concurrentOperation)
        XCTAssertEqual(conflictReceipt.disposition, .retainedConflict)
        let conflicted = try await store.loadEnvelope()
        XCTAssertTrue(conflicted.replication?.conflicts.first?.branches.contains(appliedOperation) == true)

        let relaunched = CalendarStore(url: url)
        let relaunchedAdapter = try CalendarSyncAdapter(
            store: relaunched,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let replay = try await relaunchedAdapter.applyRemote(appliedOperation)
        XCTAssertEqual(replay.disposition, .applied)
        XCTAssertEqual(replay.entityVersion, appliedOperation.payload.hash)
    }

    func testCalendarLegacyInboxWithoutEvidenceBecomesAmbiguousAndBlocksReplay() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let operation = try makeSignedOperation(
            seriesID: secondID,
            items: [try makeItem(id: secondID, title: "Legacy inbox")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: nil,
            kind: .bootstrap
        )
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        let envelope = try CalendarStoreEnvelope(
            snapshot: snapshot,
            seriesMembership: try links(for: snapshot),
            replication: makeReplication(inbox: [operation])
        )
        let seedStore = CalendarStore(url: url)
        try await persistLegacyEnvelope(envelope, through: seedStore)

        let relaunchedStore = CalendarStore(url: url)
        let adapter = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: TestSyncKeychainStore())
        )
        try await adapter.recover()

        let migrated = try await relaunchedStore.loadEnvelope()
        let receipt = try XCTUnwrap(migrated.replication?.receipts.first)
        XCTAssertEqual(receipt.disposition, .ambiguous)

        do {
            _ = try await adapter.applyRemote(operation)
            XCTFail("Ambiguous legacy operation must not be replayed")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .receiptMigrationNeedsEvidence)
        } catch {
            XCTFail("Unexpected replay error: \(error)")
        }
    }

    func testCalendarLegacyConflictBranchWithoutEvidenceDoesNotReplayAsApplied() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let operation = try makeSignedOperation(
            seriesID: firstID,
            items: [try makeItem(id: firstID, title: "Legacy conflict")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: nil,
            kind: .bootstrap
        )
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID, title: "Local")])
        let conflict = SyncConflict(
            schemaVersion: SyncContractConstants.schemaVersion,
            conflictID: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            storeID: calendarStoreID,
            entityID: operation.entityID,
            branches: [operation],
            reason: "legacy fixture",
            resolutionID: nil
        )
        let envelope = try CalendarStoreEnvelope(
            snapshot: snapshot,
            seriesMembership: try links(for: snapshot),
            replication: makeReplication(conflicts: [conflict])
        )
        let seedStore = CalendarStore(url: url)
        try await persistLegacyEnvelope(envelope, through: seedStore)

        let relaunchedStore = CalendarStore(url: url)
        let adapter = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: TestSyncKeychainStore())
        )
        try await adapter.recover()

        let migrated = try await relaunchedStore.loadEnvelope()
        let receipt = try XCTUnwrap(migrated.replication?.receipts.first)
        XCTAssertEqual(receipt.disposition, .ambiguous)

        do {
            _ = try await adapter.applyRemote(operation)
            XCTFail("Legacy conflict branch must not be replayed as applied")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .receiptMigrationNeedsEvidence)
        } catch {
            XCTFail("Unexpected replay error: \(error)")
        }
    }

    func testCalendarLegacyLocalAppliedAckMigratesAndReplaysPersistedAppliedDisposition() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let operation = try makeSignedOperation(
            seriesID: secondID,
            items: [try makeItem(id: secondID, title: "Evidence-backed")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: nil,
            kind: .bootstrap
        )
        let device = try await identity.identity()
        let acknowledgement = try await identity.signAcknowledgement(SyncAck(
            schemaVersion: SyncContractConstants.schemaVersion,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: operation.mutationID,
            operationHash: try SyncWireCodec.operationHash(for: operation),
            replicaID: device.deviceID,
            keyID: device.keyID,
            level: .applied,
            resultHash: operation.payload.hash,
            signature: ""
        ))
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        let envelope = try CalendarStoreEnvelope(
            snapshot: snapshot,
            seriesMembership: try links(for: snapshot),
            replication: makeReplication(inbox: [operation], acknowledgements: [acknowledgement])
        )
        let seedStore = CalendarStore(url: url)
        try await persistLegacyEnvelope(envelope, through: seedStore)

        let relaunchedStore = CalendarStore(url: url)
        let adapter = try CalendarSyncAdapter(
            store: relaunchedStore,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        try await adapter.recover()

        let migrated = try await relaunchedStore.loadEnvelope()
        let receipt = try XCTUnwrap(migrated.replication?.receipts.first)
        XCTAssertEqual(receipt.disposition, .applied)
        XCTAssertEqual(receipt.entityVersion, operation.payload.hash)

        let replay = try await adapter.applyRemote(operation)
        XCTAssertEqual(replay.disposition, .applied)
        XCTAssertEqual(replay.entityVersion, operation.payload.hash)
    }

    func testCalendarLocalEditDuringExchangeIsRetainedAsConflict() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "Before")]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let localPage = try await adapter.pendingPage(after: nil, limit: 128)
        let localOperation = try XCTUnwrap(localPage.operations.first)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID, title: "Local edit")]))
        let remoteOperation = try makeSignedOperation(
            seriesID: firstID,
            items: [try makeItem(id: firstID, title: "Remote edit")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "66666666-6666-4666-8666-666666666666",
            key: Curve25519.Signing.PrivateKey(),
            baseHash: localOperation.payload.hash,
            kind: .put,
            parents: [localOperation.mutationID]
        )
        let before = try await store.load()
        let receipt = try await adapter.applyRemote(remoteOperation)
        XCTAssertEqual(receipt.disposition, .retainedConflict)
        let after = try await store.load()
        XCTAssertEqual(after, before)
    }

    func testCalendarRemoteSeriesAppliesPreservesUnrelatedItemsAndReplaysIdempotently() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let unrelated = try makeItem(id: firstID)
        let incoming = try makeItem(id: secondID)
        let snapshot = CalendarSnapshot(items: [unrelated])
        let keychain = TestSyncKeychainStore()
        let localIdentity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(snapshot)
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: localIdentity
        )
        try await adapter.recover()

        let remoteKey = Curve25519.Signing.PrivateKey()
        let remoteOperation = try makeSignedOperation(
            seriesID: seriesID,
            items: [incoming],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "22222222-2222-4222-8222-222222222222",
            key: remoteKey,
            baseHash: nil,
            kind: .bootstrap
        )
        let applied = try await adapter.applyRemote(remoteOperation)
        XCTAssertEqual(applied.disposition, .applied)
        let afterApply = try await store.loadEnvelope()
        XCTAssertEqual(afterApply.snapshot.items.map(\.id), [firstID, secondID])
        XCTAssertEqual(afterApply.replication?.inbox.count, 1)
        XCTAssertEqual(afterApply.replication?.entities.count, 1)

        let reopened = CalendarStore(url: url)
        let relaunched = try CalendarSyncAdapter(
            store: reopened,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let duplicate = try await relaunched.applyRemote(remoteOperation)
        XCTAssertEqual(duplicate.disposition, .applied)
        XCTAssertEqual(duplicate.entityVersion, remoteOperation.payload.hash)
        let reopenedEnvelope = try await reopened.loadEnvelope()
        XCTAssertEqual(reopenedEnvelope.replication?.inbox.count, 1)
    }

    func testCalendarUnknownEntityPutRequiresKnownParent() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let snapshot = CalendarSnapshot(items: [try makeItem(id: firstID)])
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(snapshot)
        let localAdapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        try await localAdapter.recover()
        let remoteKey = Curve25519.Signing.PrivateKey()
        let unknownOperation = try makeSignedOperation(
            seriesID: seriesID,
            items: [try makeItem(id: secondID)],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "33333333-3333-4333-8333-333333333333",
            key: remoteKey,
            baseHash: String(repeating: "0", count: 64),
            kind: .put
        )
        let before = try await store.load()
        do {
            _ = try await localAdapter.applyRemote(unknownOperation)
            XCTFail("An operation without a known entity or local series must be blocked")
        } catch {
            XCTAssertEqual(error as? SyncFailure, .missingParent)
        }
        let after = try await store.load()
        XCTAssertEqual(after, before)
        let envelope = try await store.loadEnvelope()
        XCTAssertEqual(envelope.replication?.conflicts.count, 0)
    }

    func testCalendarRejectsUnknownAckBlobWrongStoreAndDeleteWithoutWriting() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        let pending = try await adapter.pendingPage(after: nil, limit: 1)
        let operation = try XCTUnwrap(pending.operations.first)
        let baseline = try Data(contentsOf: url)
        let signature = base64URL(Data(repeating: 0, count: 64))
        let unknownAck = SyncAck(
            schemaVersion: 1,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: "44444444-4444-4444-8444-444444444444",
            operationHash: String(repeating: "f", count: 64),
            replicaID: remoteOriginID,
            keyID: String(repeating: "a", count: 64),
            level: .stored,
            resultHash: String(repeating: "f", count: 64),
            signature: signature
        )
        await assertAsyncThrows { try await adapter.recordAcknowledgement(unknownAck) }
        XCTAssertEqual(try Data(contentsOf: url), baseline)

        let blobOperation = SyncOperation(
            schemaVersion: operation.schemaVersion,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: operation.storeID,
            domain: operation.domain,
            originID: operation.originID,
            keyID: operation.keyID,
            sequence: operation.sequence,
            mutationID: operation.mutationID,
            entityID: operation.entityID,
            parents: operation.parents,
            baseHash: operation.baseHash,
            kind: operation.kind,
            payload: SyncPayload(schemaVersion: 1, hash: operation.payload.hash, byteCount: operation.payload.byteCount, inline: nil, blobHash: operation.payload.hash),
            signature: operation.signature
        )
        await assertAsyncThrows { try await adapter.applyRemote(blobOperation) }
        XCTAssertEqual(try Data(contentsOf: url), baseline)

        let wrongStoreOperation = SyncOperation(
            schemaVersion: operation.schemaVersion,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: remoteStoreID,
            domain: operation.domain,
            originID: operation.originID,
            keyID: operation.keyID,
            sequence: operation.sequence,
            mutationID: operation.mutationID,
            entityID: operation.entityID,
            parents: operation.parents,
            baseHash: operation.baseHash,
            kind: operation.kind,
            payload: operation.payload,
            signature: operation.signature
        )
        await assertAsyncThrows { try await adapter.applyRemote(wrongStoreOperation) }
        XCTAssertEqual(try Data(contentsOf: url), baseline)

        let empty = Data()
        let deleteOperation = SyncOperation(
            schemaVersion: operation.schemaVersion,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: operation.storeID,
            domain: operation.domain,
            originID: operation.originID,
            keyID: operation.keyID,
            sequence: operation.sequence,
            mutationID: operation.mutationID,
            entityID: operation.entityID,
            parents: operation.parents,
            baseHash: operation.baseHash,
            kind: .delete,
            payload: SyncPayload(schemaVersion: 1, hash: SyncWireCodec.sha256(empty), byteCount: 0, inline: "", blobHash: nil),
            signature: operation.signature
        )
        await assertAsyncThrows { try await adapter.applyRemote(deleteOperation) }
        XCTAssertEqual(try Data(contentsOf: url), baseline)
    }

    func testCalendarRejectsWrongDomainAndBoundedWrapperOrPageInputs() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let keychain = TestSyncKeychainStore()
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        )
        await assertAsyncThrows { try await adapter.pendingPage(after: nil, limit: 0) }
        await assertAsyncThrows { try await adapter.pendingPage(after: nil, limit: SyncContractConstants.maxPageOperations + 1) }

        let page = try await adapter.pendingPage(after: nil, limit: 1)
        let operation = try XCTUnwrap(page.operations.first)
        let wrongDomain = SyncOperation(
            schemaVersion: operation.schemaVersion,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: operation.storeID,
            domain: .finance,
            originID: operation.originID,
            keyID: operation.keyID,
            sequence: operation.sequence,
            mutationID: operation.mutationID,
            entityID: operation.entityID,
            parents: operation.parents,
            baseHash: operation.baseHash,
            kind: operation.kind,
            payload: operation.payload,
            signature: operation.signature
        )
        let baseline = try Data(contentsOf: url)
        await assertAsyncThrows { try await adapter.applyRemote(wrongDomain) }
        XCTAssertEqual(try Data(contentsOf: url), baseline)

        let validEnvelope = try CalendarStoreEnvelope(
            snapshot: CalendarSnapshot(items: [try makeItem(id: firstID)]),
            seriesMembership: [CalendarSeriesLink(itemID: firstID, seriesID: firstID)],
            replication: emptyReplication()
        )
        let encoded = try JSONEncoder.calendar.encode(validEnvelope)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let unknownKey = replacing(encodedText, "{", "{\"extra\":true,")
        try Data(unknownKey.utf8).write(to: url)
        await assertAsyncThrows { _ = try await store.loadEnvelope() }

        let duplicateKey = replacing(encodedText, "\"schemaVersion\":1", "\"schemaVersion\":1,\"schemaVersion\":1")
        try Data(duplicateKey.utf8).write(to: url)
        await assertAsyncThrows { _ = try await store.loadEnvelope() }

        try Data(repeating: 0, count: CalendarStoreEnvelope.maximumEncodedBytes + 1).write(to: url)
        await assertAsyncThrows { _ = try await store.loadEnvelope() }

        let tooManyItems = try (0..<(CalendarSnapshot.maximumItemCount + 1)).map { index in
            try CalendarItem(
                id: UUID(),
                title: "Item \(index)",
                start: base.addingTimeInterval(Double(index) * 120),
                end: base.addingTimeInterval(Double(index) * 120 + 60),
                createdAt: base,
                updatedAt: base
            )
        }
        XCTAssertThrowsError(
            try CalendarStoreEnvelope(
                snapshot: CalendarSnapshot(items: tooManyItems),
                seriesMembership: []
            )
        )
    }

    func testSyncEngineRetiresAcknowledgementsOnlyAfterValidatedFrontierPersistence() async throws {
        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let operation = try makeSignedOperation(
            seriesID: firstID,
            items: [try makeItem(id: firstID)],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: localOriginID,
            sequence: "1",
            mutationID: "12121212-1212-4121-8121-121212121212",
            key: try await identity.loadOrCreateKey(),
            baseHash: nil,
            kind: .bootstrap
        )
        let acknowledgement = makeEngineAcknowledgement()
        let probe = EngineTestProbe()
        let adapter = EngineTestAdapter(
            storeID: calendarStoreID,
            page: SyncPage(
                operations: [operation],
                acknowledgements: [acknowledgement],
                cursor: SyncFrontier(positions: []),
                hasMore: false
            ),
            probe: probe
        )
        let transport = EngineTestTransport(response: makeEngineResponse(results: [
            SyncOperationResult(mutationID: operation.mutationID, disposition: "stored", error: nil)
        ]))
        let frontierStore = EngineTestFrontierStore(probe: probe)
        let engine = try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: makeEngineEndpoint()
        )

        _ = try await engine.synchronizeOnce(reason: .background)

        let pendingAfterSuccess = await adapter.hasPendingAcknowledgements()
        let deliveredAfterSuccess = await adapter.deliveredPageCount()
        let persistedAfterSuccess = await frontierStore.persistedCount()
        let successAckCounts = await transport.acknowledgementCounts()
        let ordering = await probe.events()
        let persistIndex = try XCTUnwrap(ordering.firstIndex(of: "frontier-persist"))
        let gatewayIndex = try XCTUnwrap(ordering.firstIndex(of: "gateway-acceptance"))
        let acknowledgementIndex = try XCTUnwrap(ordering.firstIndex(of: "ack-retirement"))
        XCTAssertFalse(pendingAfterSuccess)
        XCTAssertEqual(deliveredAfterSuccess, 1)
        XCTAssertEqual(persistedAfterSuccess, 1)
        XCTAssertEqual(successAckCounts, [1])
        XCTAssertLessThan(persistIndex, gatewayIndex)
        XCTAssertLessThan(gatewayIndex, acknowledgementIndex)
    }

    func testSyncEngineKeepsAcknowledgementsWhenFrontierPersistenceFails() async throws {
        let acknowledgement = makeEngineAcknowledgement()
        let adapter = EngineTestAdapter(
            storeID: calendarStoreID,
            page: SyncPage(
                operations: [],
                acknowledgements: [acknowledgement],
                cursor: SyncFrontier(positions: []),
                hasMore: false
            )
        )
        let transport = EngineTestTransport(response: makeEngineResponse())
        let frontierStore = EngineTestFrontierStore(failsPersistence: true)
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: TestSyncKeychainStore())
        let engine = try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: makeEngineEndpoint()
        )

        do {
            _ = try await engine.synchronizeOnce(reason: .background)
            XCTFail("A frontier persistence failure must abort the cycle")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .diskFull)
        } catch {
            XCTFail("Unexpected sync error: \(error)")
        }

        let pendingAfterPersistenceFailure = await adapter.hasPendingAcknowledgements()
        let deliveredAfterPersistenceFailure = await adapter.deliveredPageCount()
        XCTAssertTrue(pendingAfterPersistenceFailure)
        XCTAssertEqual(deliveredAfterPersistenceFailure, 0)
    }

    func testSyncEngineKeepsAcknowledgementsWhenResponseFrontierRegresses() async throws {
        let acknowledgement = makeEngineAcknowledgement()
        let adapter = EngineTestAdapter(
            storeID: calendarStoreID,
            page: SyncPage(
                operations: [],
                acknowledgements: [acknowledgement],
                cursor: SyncFrontier(positions: []),
                hasMore: false
            )
        )
        let regressingFrontier = SyncFrontier(positions: [
            SyncPosition(
                stream: SyncStream(storeID: calendarStoreID, originID: remoteOriginID),
                through: "0"
            )
        ])
        let transport = EngineTestTransport(response: makeEngineResponse(upper: regressingFrontier))
        let initialFrontier = EngineTestFrontierStore(frontier: SyncFrontier(positions: [
            SyncPosition(
                stream: SyncStream(storeID: calendarStoreID, originID: remoteOriginID),
                through: "1"
            )
        ]))
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: TestSyncKeychainStore())
        let engine = try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: initialFrontier,
            endpoint: makeEngineEndpoint()
        )

        do {
            _ = try await engine.synchronizeOnce(reason: .background)
            XCTFail("A regressing frontier must abort the cycle")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .invalidInput)
        } catch {
            XCTFail("Unexpected sync error: \(error)")
        }

        let pendingAfterRegression = await adapter.hasPendingAcknowledgements()
        let deliveredAfterRegression = await adapter.deliveredPageCount()
        XCTAssertTrue(pendingAfterRegression)
        XCTAssertEqual(deliveredAfterRegression, 0)
    }

    func testSyncEngineDoesNotStarveAcknowledgementsAcrossBackgroundCycles() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        let initialSnapshot = CalendarSnapshot(items: try makeItems(count: 128))
        _ = try await store.save(initialSnapshot)
        let endpoint = makeEngineEndpoint()
        let seedAdapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: Set([localOriginID, remoteOriginID])
        )
        try await seedAdapter.recover()
        let seedPage = try await seedAdapter.pendingPage(after: nil, limit: SyncContractConstants.maxPageOperations)
        XCTAssertEqual(seedPage.operations.count, 128)
        let parent = try XCTUnwrap(seedPage.operations.first)

        let localKey = try await identity.loadOrCreateKey()
        let queuedAcknowledgement = try makeSignedAcknowledgement(
            operation: parent,
            replicaID: localOriginID,
            key: localKey,
            level: .stored,
            resultHash: parent.payload.hash
        )
        try await store.mutateEnvelope { current in
            guard let existing = current.replication else { throw SyncFailure.corruptStore }
            let replication = SyncAdapterEnvelope(
                schemaVersion: existing.schemaVersion,
                storeID: existing.storeID,
                datasetID: existing.datasetID,
                localOriginID: existing.localOriginID,
                epoch: existing.epoch,
                nextSequence: existing.nextSequence,
                received: existing.received,
                applied: existing.applied,
                outbox: existing.outbox,
                inbox: existing.inbox,
                entities: existing.entities,
                conflicts: existing.conflicts,
                acknowledgements: existing.acknowledgements + [queuedAcknowledgement],
                receivedAcknowledgements: existing.receivedAcknowledgements,
                receipts: existing.receipts,
                receiptLedgerVersion: existing.receiptLedgerVersion
            )
            let updated = try CalendarStoreEnvelope(
                snapshot: current.snapshot,
                seriesMembership: current.seriesMembership,
                replication: replication
            )
            return (updated, ())
        }

        let changedItem = try XCTUnwrap(initialSnapshot.items.first)
        let updatedItem = try CalendarItem(
            id: changedItem.id,
            title: "Updated",
            kind: changedItem.kind,
            icon: changedItem.icon,
            iconAsset: changedItem.iconAsset,
            systemIconName: changedItem.systemIconName,
            status: changedItem.status,
            start: changedItem.start,
            end: changedItem.end,
            createdAt: changedItem.createdAt,
            updatedAt: changedItem.updatedAt.addingTimeInterval(1),
            deletedAt: changedItem.deletedAt,
            timeZoneIdentifier: changedItem.timeZoneIdentifier,
            recurrence: changedItem.recurrence
        )
        let updatedSnapshot = CalendarSnapshot(items: initialSnapshot.items.map { item in
            item.id == changedItem.id ? updatedItem : item
        })
        _ = try await store.save(updatedSnapshot)

        let transport = ScriptedSyncEngineTransport()
        let frontierStore = EngineTestFrontierStore()
        let firstAdapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: Set([localOriginID, remoteOriginID])
        )
        let firstEngine = try SyncEngine(
            adapters: [firstAdapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        _ = try await firstEngine.synchronizeOnce(reason: .background)

        // A fresh adapter and engine model the next process/background cycle;
        // all paging state must come from the durable CalendarStore.
        let secondAdapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: endpoint.id,
            authorizedApplyingReplicaIDs: Set([localOriginID, remoteOriginID])
        )
        let secondEngine = try SyncEngine(
            adapters: [secondAdapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )
        _ = try await secondEngine.synchronizeOnce(reason: .background)

        let requests = await transport.requests()
        let firstRequest = try XCTUnwrap(requests.first)
        let secondRequest = try XCTUnwrap(requests.dropFirst().first)
        let firstMutationIDs = Set(firstRequest.operations.map(\.mutationID))
        let laterChild = try XCTUnwrap(secondRequest.operations.first(where: { $0.parents.contains(parent.mutationID) }))
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(firstRequest.acknowledgements.count, 1)
        XCTAssertEqual(firstRequest.operations.count, 127)
        XCTAssertTrue(firstMutationIDs.contains(parent.mutationID))
        XCTAssertTrue(secondRequest.acknowledgements.isEmpty)
        XCTAssertEqual(secondRequest.operations.map(\.sequence), ["128", "129"])
        XCTAssertEqual(laterChild.parents, [parent.mutationID])
    }

    func testCalendarSyncCompositionRejectsDuplicateRosterMembers() async throws {
        let keychain = TestSyncKeychainStore()
        let member = try await makeCompositionMember(deviceID: localOriginID, keychain: keychain)
        let endpoint = try makeCompositionEndpoint(members: [member, member])

        do {
            _ = try await CalendarSyncComposition.makeEngine(
                endpoint: endpoint,
                store: CalendarStore(url: temporaryURL()),
                calendarStoreID: calendarStoreID,
                localDeviceID: localOriginID,
                keychain: keychain,
                frontierStore: EngineTestFrontierStore()
            )
            XCTFail("Duplicate roster members must be rejected")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .membershipMismatch)
        }
    }

    func testCalendarSyncCompositionRejectsGatewayCursorMemberCollision() async throws {
        let keychain = TestSyncKeychainStore()
        let localMember = try await makeCompositionMember(deviceID: localOriginID, keychain: keychain)
        let remoteMember = try await makeCompositionMember(deviceID: remoteOriginID, keychain: keychain)
        let endpoint = try makeCompositionEndpoint(members: [localMember, remoteMember])

        do {
            _ = try await CalendarSyncComposition.makeEngine(
                endpoint: endpoint,
                store: CalendarStore(url: temporaryURL()),
                calendarStoreID: calendarStoreID,
                localDeviceID: localOriginID,
                keychain: keychain,
                frontierStore: EngineTestFrontierStore()
            )
            XCTFail("The gateway cursor must not collide with a roster member")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .membershipMismatch)
        }
    }

    func testCalendarSyncCompositionRejectsLocalKeyMismatch() async throws {
        let keychain = TestSyncKeychainStore()
        let foreignKey = Curve25519.Signing.PrivateKey()
        let member = SyncMember(
            deviceID: localOriginID,
            keyID: SyncWireCodec.sha256(foreignKey.publicKey.rawRepresentation),
            publicKey: base64URL(foreignKey.publicKey.rawRepresentation),
            role: .applying,
            endpoint: nil
        )
        let endpoint = try makeCompositionEndpoint(members: [member])

        do {
            _ = try await CalendarSyncComposition.makeEngine(
                endpoint: endpoint,
                store: CalendarStore(url: temporaryURL()),
                calendarStoreID: calendarStoreID,
                localDeviceID: localOriginID,
                keychain: keychain,
                frontierStore: EngineTestFrontierStore()
            )
            XCTFail("A roster key that differs from the local identity must be rejected")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .membershipMismatch)
        }
    }

    func testSyncEngineRejectsSignedOperationFromStoringMemberWithoutMutation() async throws {
        let url = temporaryURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let keychain = TestSyncKeychainStore()
        let identity = SyncIdentityStore(deviceID: localOriginID, keychain: keychain)
        let store = CalendarStore(url: url)
        _ = try await store.save(CalendarSnapshot(items: [try makeItem(id: firstID)]))
        let adapter = try CalendarSyncAdapter(
            store: store,
            datasetID: datasetID,
            epoch: "1",
            originID: localOriginID,
            storeID: calendarStoreID,
            identity: identity,
            gatewayCursorID: remoteStoreID,
            authorizedApplyingReplicaIDs: [localOriginID]
        )
        try await adapter.recover()

        let localDevice = try await identity.identity()
        let storingKey = Curve25519.Signing.PrivateKey()
        let storingMember = SyncMember(
            deviceID: remoteOriginID,
            keyID: SyncWireCodec.sha256(storingKey.publicKey.rawRepresentation),
            publicKey: base64URL(storingKey.publicKey.rawRepresentation),
            role: .storing,
            endpoint: nil
        )
        let endpoint = makeEngineEndpoint(
            endpointID: remoteStoreID,
            members: [
                SyncMember(
                    deviceID: localDevice.deviceID,
                    keyID: localDevice.keyID,
                    publicKey: localDevice.publicKey,
                    role: .applying,
                    endpoint: nil
                ),
                storingMember
            ]
        )
        let operation = try makeSignedOperation(
            seriesID: secondID,
            items: [try makeItem(id: secondID, title: "Must be rejected")],
            datasetID: datasetID,
            storeID: calendarStoreID,
            originID: remoteOriginID,
            sequence: "1",
            mutationID: "abababab-abab-4aba-8aba-abababababab",
            key: storingKey,
            baseHash: nil,
            kind: .bootstrap
        )
        XCTAssertNoThrow(try SyncWireCodec.verifyOperation(operation, publicKey: storingKey.publicKey))

        let response = SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: calendarStoreID,
            results: [],
            operations: [operation],
            acknowledgements: [],
            upper: SyncFrontier(positions: [
                SyncPosition(
                    stream: SyncStream(storeID: calendarStoreID, originID: remoteOriginID),
                    through: "1"
                )
            ]),
            more: false
        )
        let transport = EngineTestTransport(response: response)
        let frontierStore = EngineTestFrontierStore()
        _ = try await adapter.pendingPage(after: nil, limit: SyncContractConstants.maxPageOperations)
        let beforeEnvelope = try await store.loadEnvelope()
        let beforeFrontier = try await frontierStore.loadFrontier()
        let engine = try SyncEngine(
            adapters: [adapter],
            transport: transport,
            identity: identity,
            frontierStore: frontierStore,
            endpoint: endpoint
        )

        do {
            _ = try await engine.synchronizeOnce(reason: .background)
            XCTFail("A storing member must not author a calendar mutation")
        } catch let error as SyncFailure {
            XCTAssertEqual(error, .membershipMismatch)
        } catch {
            XCTFail("Unexpected sync error: \(error)")
        }

        let afterEnvelope = try await store.loadEnvelope()
        let afterFrontier = try await frontierStore.loadFrontier()
        XCTAssertEqual(afterEnvelope.snapshot, beforeEnvelope.snapshot)
        XCTAssertEqual(afterEnvelope.seriesMembership, beforeEnvelope.seriesMembership)
        XCTAssertEqual(afterEnvelope.replication, beforeEnvelope.replication)
        XCTAssertEqual(afterFrontier, beforeFrontier)
    }

    private var datasetID: String { "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa" }
    private var calendarStoreID: String { "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb" }
    private var remoteStoreID: String { "cccccccc-cccc-4ccc-8ccc-cccccccccccc" }
    private var localOriginID: String { "dddddddd-dddd-4ddd-8ddd-dddddddddddd" }
    private var remoteOriginID: String { "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee" }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("lifeos-calendar-sync-" + UUID().uuidString, isDirectory: false)
    }

    private func makeEngineEndpoint(
        endpointID: String = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee",
        members: [SyncMember] = []
    ) -> SyncEndpoint {
        let serverKey = Curve25519.Signing.PrivateKey()
        return SyncEndpoint(
            id: endpointID,
            origin: URL(fileURLWithPath: "/lifeos-engine-test"),
            datasetID: datasetID,
            epoch: "1",
            serverKeyID: SyncWireCodec.sha256(serverKey.publicKey.rawRepresentation),
            serverPublicKey: base64URL(serverKey.publicKey.rawRepresentation),
            approvedHost: "lifeos.example.test",
            members: members
        )
    }

    private func makeCompositionEndpoint(members: [SyncMember]) throws -> SyncEndpoint {
        let serverKey = Curve25519.Signing.PrivateKey()
        guard let origin = URL(string: "https://lifeos.example.test") else {
            throw SyncFailure.invalidInput
        }
        return SyncEndpoint(
            id: remoteOriginID,
            origin: origin,
            datasetID: datasetID,
            epoch: "1",
            serverKeyID: SyncWireCodec.sha256(serverKey.publicKey.rawRepresentation),
            serverPublicKey: base64URL(serverKey.publicKey.rawRepresentation),
            approvedHost: "lifeos.example.test",
            members: members
        )
    }

    private func makeCompositionMember(
        deviceID: String,
        keychain: any SyncKeychainStore,
        role: SyncReplicaRole = .applying
    ) async throws -> SyncMember {
        let identity = SyncIdentityStore(deviceID: deviceID, role: role, keychain: keychain)
        let device = try await identity.identity()
        return SyncMember(
            deviceID: device.deviceID,
            keyID: device.keyID,
            publicKey: device.publicKey,
            role: device.role,
            endpoint: nil
        )
    }

    private func makeEngineResponse(
        results: [SyncOperationResult] = [],
        upper: SyncFrontier = SyncFrontier(positions: [])
    ) -> SyncExchangeResponse {
        SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: calendarStoreID,
            results: results,
            operations: [],
            acknowledgements: [],
            upper: upper,
            more: false
        )
    }

    private func makeEngineAcknowledgement() -> SyncAck {
        SyncAck(
            schemaVersion: SyncContractConstants.schemaVersion,
            datasetID: datasetID,
            epoch: "1",
            storeID: calendarStoreID,
            mutationID: "13131313-1313-4131-8131-131313131313",
            operationHash: String(repeating: "a", count: 64),
            replicaID: remoteOriginID,
            keyID: String(repeating: "b", count: 64),
            level: .stored,
            resultHash: String(repeating: "c", count: 64),
            signature: base64URL(Data(repeating: 0, count: 64))
        )
    }

    private func links(for snapshot: CalendarSnapshot) throws -> [CalendarSeriesLink] {
        try snapshot.items.map { item in
            try CalendarSeriesLink(
                itemID: item.id.uuidString.lowercased(),
                seriesID: item.id.uuidString.lowercased()
            )
        }
    }

    private func emptyReplication() -> SyncAdapterEnvelope {
        makeReplication()
    }

    private func makeReplication(
        inbox: [SyncOperation] = [],
        conflicts: [SyncConflict] = [],
        acknowledgements: [SyncAck] = [],
        receivedAcknowledgements: [SyncAck] = [],
        receipts: [SyncOperationReceipt] = [],
        receiptLedgerVersion: Int = 1
    ) -> SyncAdapterEnvelope {
        SyncAdapterEnvelope(
            schemaVersion: 1,
            storeID: calendarStoreID,
            datasetID: datasetID,
            localOriginID: localOriginID,
            epoch: "1",
            nextSequence: "1",
            received: SyncFrontier(positions: []),
            applied: SyncFrontier(positions: []),
            outbox: [],
            inbox: inbox,
            entities: [],
            conflicts: conflicts,
            acknowledgements: acknowledgements,
            receivedAcknowledgements: receivedAcknowledgements,
            receipts: receipts,
            receiptLedgerVersion: receiptLedgerVersion
        )
    }

    private func persistLegacyEnvelope(
        _ envelope: CalendarStoreEnvelope,
        through store: CalendarStore
    ) async throws {
        try await store.saveEnvelope(envelope)
        let persisted = try await store.loadEnvelope()
        var root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder.calendar.encode(persisted)) as? [String: Any]
        )
        var replication = try XCTUnwrap(root["replication"] as? [String: Any])
        replication.removeValue(forKey: "receiptLedgerVersion")
        replication.removeValue(forKey: "receipts")
        replication.removeValue(forKey: "receivedAcknowledgements")
        root["replication"] = replication
        let legacyData = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        try legacyData.write(to: store.url, options: .atomic)
    }

    private func makeSignedOperation(
        seriesID: UUID,
        items: [CalendarItem],
        datasetID: String,
        storeID: String,
        originID: String,
        sequence: String,
        mutationID: String,
        key: Curve25519.Signing.PrivateKey,
        baseHash: String?,
        kind: SyncOperationKind,
        parents: [String] = []
    ) throws -> SyncOperation {
        let payloadBytes = try CalendarPayloadCodec.encode(seriesID: seriesID, items: items)
        let series = seriesID.uuidString.lowercased()
        let unsigned = SyncOperation(
            schemaVersion: 1,
            datasetID: datasetID,
            epoch: "1",
            storeID: storeID,
            domain: .calendar,
            originID: originID,
            keyID: SyncWireCodec.sha256(key.publicKey.rawRepresentation),
            sequence: sequence,
            mutationID: mutationID,
            entityID: SyncWireCodec.sha256(Data("calendar\u{0}\(series)".utf8)),
            parents: parents.sorted(),
            baseHash: baseHash,
            kind: kind,
            payload: SyncPayload(
                schemaVersion: 1,
                hash: SyncWireCodec.sha256(payloadBytes),
                byteCount: payloadBytes.count,
                inline: base64URL(payloadBytes),
                blobHash: nil
            ),
            signature: ""
        )
        return try SyncWireCodec.signOperation(unsigned, using: key)
    }

    private func makeSignedAcknowledgement(
        operation: SyncOperation,
        replicaID: String,
        key: Curve25519.Signing.PrivateKey,
        level: SyncAckLevel,
        resultHash: String
    ) throws -> SyncAck {
        let unsigned = SyncAck(
            schemaVersion: 1,
            datasetID: operation.datasetID,
            epoch: operation.epoch,
            storeID: operation.storeID,
            mutationID: operation.mutationID,
            operationHash: try SyncWireCodec.operationHash(for: operation),
            replicaID: replicaID,
            keyID: SyncWireCodec.sha256(key.publicKey.rawRepresentation),
            level: level,
            resultHash: resultHash,
            signature: ""
        )
        return try SyncWireCodec.signAcknowledgement(unsigned, using: key)
    }

    private func makeItems(count: Int) throws -> [CalendarItem] {
        try (0..<count).map { index in
            let suffix = String(index + 0x100, radix: 16)
            let paddedSuffix = String(repeating: "0", count: max(0, 12 - suffix.count)) + suffix
            let id = try XCTUnwrap(UUID(uuidString: "00000000-0000-4000-8000-\(paddedSuffix)"))
            return try makeItem(id: id, title: "Series \(index)")
        }
    }

    private func makeItem(id: UUID, title: String = "Calendar item") throws -> CalendarItem {
        try CalendarItem(
            id: id,
            title: title,
            start: base.addingTimeInterval(0.25),
            end: base.addingTimeInterval(60.75),
            createdAt: base,
            updatedAt: base
        )
    }

    private func replacing(_ value: String, _ target: String, _ replacement: String) -> String {
        guard let range = value.range(of: target) else {
            XCTFail("test fixture target missing: \(target)")
            return value
        }
        return value.replacingOccurrences(of: target, with: replacement, options: [], range: range)
    }

    private func fixtureUUID(_ value: String) -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            XCTFail("invalid UUID test fixture: \(value)")
            return UUID()
        }
        return uuid
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func assertAsyncThrows(_ operation: @escaping () async throws -> Void) async {
        do {
            try await operation()
            XCTFail("Expected the async operation to throw")
        } catch {
            // Expected rejection.
        }
    }
}

private final class TestSyncKeychainStore: SyncKeychainStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]

    func read(service: String, account: String) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return values[service + "\u{0}" + account]
    }

    func write(_ data: Data, service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[service + "\u{0}" + account] = data
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: service + "\u{0}" + account)
    }
}

private actor EngineTestProbe {
    private var recordedEvents: [String] = []

    func record(_ event: String) {
        recordedEvents.append(event)
    }

    func events() -> [String] {
        recordedEvents
    }
}

private actor EngineTestAdapter: SyncDomainAdapter {
    let storeID: String
    let domain: SyncDomain = .calendar
    private var page: SyncPage
    private var deliveredPages = 0
    private let probe: EngineTestProbe?

    init(storeID: String, page: SyncPage, probe: EngineTestProbe? = nil) {
        self.storeID = storeID
        self.page = page
        self.probe = probe
    }

    func recover() async throws {}

    func pendingPage(after: SyncFrontier?, limit: Int) async throws -> SyncPage {
        page
    }

    func applyRemote(_ operation: SyncOperation) async throws -> SyncCommitReceipt {
        throw SyncFailure.invalidInput
    }

    func recordAcknowledgement(_ acknowledgement: SyncAck) async throws {}

    func acknowledgePageDelivered(_ acknowledgements: [SyncAck]) async throws {
        guard !acknowledgements.isEmpty else { return }
        let deliveredKeys = Set(acknowledgements.map(Self.acknowledgementKey))
        let remaining = page.acknowledgements.filter {
            !deliveredKeys.contains(Self.acknowledgementKey($0))
        }
        page = SyncPage(
            operations: page.operations,
            acknowledgements: remaining,
            cursor: page.cursor,
            hasMore: page.hasMore
        )
        deliveredPages += 1
        await probe?.record("ack-retirement")
    }

    func recordGatewayAcceptance(_ mutationIDs: [String], endpointID: String) async throws {
        guard !mutationIDs.isEmpty else { return }
        await probe?.record("gateway-acceptance")
    }

    func checkpoint(_ frontier: SyncFrontier) async throws -> SyncCheckpointReceipt {
        SyncCheckpointReceipt(
            schemaVersion: SyncContractConstants.schemaVersion,
            checkpointHash: String(repeating: "d", count: 64),
            storeID: storeID,
            covered: frontier,
            removedOperations: 0
        )
    }

    func hasPendingAcknowledgements() -> Bool {
        !page.acknowledgements.isEmpty
    }

    func deliveredPageCount() -> Int {
        deliveredPages
    }

    private static func acknowledgementKey(_ value: SyncAck) -> String {
        value.operationHash + "\u{0}" + value.mutationID + "\u{0}" + value.replicaID + "\u{0}" + value.level.rawValue
    }
}

private actor EngineTestTransport: SyncEngineTransport {
    private let response: SyncExchangeResponse
    private var requests: [SyncExchangeRequest] = []

    init(response: SyncExchangeResponse) {
        self.response = response
    }

    func exchange(request: SyncExchangeRequest, endpoint: SyncEndpoint) async throws -> SyncExchangeResponse {
        requests.append(request)
        return response
    }

    func acknowledgementCounts() -> [Int] {
        requests.map { $0.acknowledgements.count }
    }
}

private actor AuthenticatedResponseTransport: SyncEngineTransport {
    private let responses: [SyncExchangeResponse]
    private var recordedRequests: [SyncExchangeRequest] = []

    init(responses: [SyncExchangeResponse]) {
        self.responses = responses
    }

    func exchange(request: SyncExchangeRequest, endpoint: SyncEndpoint) async throws -> SyncExchangeResponse {
        recordedRequests.append(request)
        let index = min(recordedRequests.count - 1, responses.count - 1)
        guard index >= 0 else { throw SyncFailure.invalidInput }
        return responses[index]
    }

    func requests() -> [SyncExchangeRequest] {
        recordedRequests
    }
}

private actor EngineTestFrontierStore: SyncFrontierStore {
    private var frontier: SyncFrontier
    private let failsPersistence: Bool
    private let probe: EngineTestProbe?
    private var persistenceCount = 0

    init(
        frontier: SyncFrontier = SyncFrontier(positions: []),
        failsPersistence: Bool = false,
        probe: EngineTestProbe? = nil
    ) {
        self.frontier = frontier
        self.failsPersistence = failsPersistence
        self.probe = probe
    }

    func loadFrontier() async throws -> SyncFrontier {
        frontier
    }

    func persist(_ frontier: SyncFrontier) async throws {
        guard !failsPersistence else { throw SyncFailure.diskFull }
        self.frontier = frontier
        persistenceCount += 1
        await probe?.record("frontier-persist")
    }

    func persistedCount() -> Int {
        persistenceCount
    }
}

private actor ScriptedSyncEngineTransport: SyncEngineTransport {
    private var recordedRequests: [SyncExchangeRequest] = []

    func exchange(request: SyncExchangeRequest, endpoint: SyncEndpoint) async throws -> SyncExchangeResponse {
        recordedRequests.append(request)
        let gatewayThrough = String(recordedRequests.count)
        return SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: request.storeID,
            results: request.operations.map {
                SyncOperationResult(mutationID: $0.mutationID, disposition: "stored", error: nil)
            },
            operations: [],
            acknowledgements: [],
            upper: SyncFrontier(positions: [
                SyncPosition(
                    stream: SyncStream(storeID: request.storeID, originID: endpoint.id),
                    through: gatewayThrough
                )
            ]),
            more: false
        )
    }

    func requests() -> [SyncExchangeRequest] {
        recordedRequests
    }
}

private actor LocalReplicaOnlyTransport: SyncEngineTransport {
    private let localReplicaID: String
    private var recordedRequests: [SyncExchangeRequest] = []

    init(localReplicaID: String) {
        self.localReplicaID = localReplicaID
    }

    func exchange(request: SyncExchangeRequest, endpoint: SyncEndpoint) async throws -> SyncExchangeResponse {
        guard request.acknowledgements.allSatisfy({ $0.replicaID == localReplicaID }) else {
            throw SyncFailure.unauthenticated
        }
        recordedRequests.append(request)
        let gatewayThrough = String(recordedRequests.count)
        return SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: request.storeID,
            results: request.operations.map {
                SyncOperationResult(mutationID: $0.mutationID, disposition: "stored", error: nil)
            },
            operations: [],
            acknowledgements: [],
            upper: SyncFrontier(positions: [
                SyncPosition(
                    stream: SyncStream(storeID: request.storeID, originID: endpoint.id),
                    through: gatewayThrough
                )
            ]),
            more: false
        )
    }

    func requests() -> [SyncExchangeRequest] {
        recordedRequests
    }
}

private actor ContiguousGatewayTransport: SyncEngineTransport {
    private let endpointID: String
    private var nextSequenceByOrigin: [String: UInt64] = [:]
    private var recordedRequests: [SyncExchangeRequest] = []
    private var sequenceGapFailures = 0

    init(endpointID: String) {
        self.endpointID = endpointID
    }

    func exchange(request: SyncExchangeRequest, endpoint: SyncEndpoint) async throws -> SyncExchangeResponse {
        recordedRequests.append(request)
        guard endpoint.id == endpointID else { throw SyncFailure.invalidInput }
        var results: [SyncOperationResult] = []
        var highestAcceptedSequence: UInt64 = 0
        for operation in request.operations {
            let sequence = try SyncContractValidation.requireUnsigned(operation.sequence, positive: true)
            let expected = nextSequenceByOrigin[operation.originID] ?? 1
            guard sequence == expected else {
                sequenceGapFailures += 1
                throw SyncFailure.invalidInput
            }
            nextSequenceByOrigin[operation.originID] = sequence + 1
            highestAcceptedSequence = max(highestAcceptedSequence, sequence)
            results.append(SyncOperationResult(
                mutationID: operation.mutationID,
                disposition: "stored",
                error: nil
            ))
        }

        return SyncExchangeResponse(
            schemaVersion: SyncContractConstants.schemaVersion,
            storeID: request.storeID,
            results: results,
            operations: [],
            acknowledgements: [],
            upper: SyncFrontier(positions: [
                SyncPosition(
                    stream: SyncStream(storeID: request.storeID, originID: endpointID),
                    through: String(highestAcceptedSequence)
                )
            ]),
            more: false
        )
    }

    func requests() -> [SyncExchangeRequest] {
        recordedRequests
    }

    func gapFailures() -> Int {
        sequenceGapFailures
    }
}
