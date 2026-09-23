import Foundation
import XCTest
@testable import LifeOS

final class FitnessTrainingStoreTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 3_000_000)

    func testTrainingEntityIDMatchesVersionedLiteralFixture() throws {
        let recordID = TrainingRecordID(uuid: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!)
        XCTAssertEqual(
            try TrainingReplicationState.entityID(for: recordID),
            "9c8fa24e4494a1786348611a67b09bbfb47f3acd72fa699b92fe31f165ae5f30"
        )
    }

    func testReplicationMapsRejectWellFormedButNoncanonicalEntityHashes() throws {
        let sessionID = TrainingRecordID(uuid: UUID(uuidString: "80500000-0000-0000-0000-000000000001")!)
        let mutationID = TrainingRecordID(uuid: UUID(uuidString: "80500000-0000-0000-0000-000000000002")!)
        let binding = makeReplicationBinding()
        let session = try TrainingSession(
            id: sessionID,
            title: "Canonical entity hash fixture",
            createdAt: base,
            updatedAt: base,
            startedAt: base,
            now: base
        )
        let payload = TrainingReplicationState.inlinePayload(
            try FitnessPayloadCodec.encode(session, now: base)
        )
        let canonical = try TrainingReplicationState.entityID(for: sessionID)
        let entry = TrainingBootstrapEntry(
            recordID: sessionID,
            mutationID: mutationID,
            entityID: canonical,
            payloadHash: payload.hash
        )
        let intent = TrainingSyncIntent(
            mutationID: mutationID,
            recordID: sessionID,
            kind: .bootstrap,
            payload: payload
        )
        let valid = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [entry],
            pendingIntents: [intent],
            entityKeys: [TrainingEntityKey(recordID: sessionID, entityID: canonical)],
            ledger: TrainingReplicationState.emptyLedger(for: binding)
        )
        XCTAssertNoThrow(try valid.validate(
            retainedSessionIDs: [sessionID],
            receiptMutationIDs: [],
            retiredMutationIDs: []
        ))

        let forged = String(repeating: canonical.first == "0" ? "1" : "0", count: 64)
        XCTAssertNotEqual(forged, canonical)
        XCTAssertEqual(forged.count, 64)
        let tampered = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [TrainingBootstrapEntry(
                recordID: entry.recordID,
                mutationID: entry.mutationID,
                entityID: forged,
                payloadHash: entry.payloadHash
            )],
            pendingIntents: [intent],
            entityKeys: [TrainingEntityKey(recordID: sessionID, entityID: forged)],
            ledger: valid.ledger
        )
        assertReplicationInvalid(tampered, retainedSessionIDs: [sessionID])
    }

    func testEveryBootstrapEntryRequiresOneMatchingPendingBootstrapIntent() throws {
        let binding = makeReplicationBinding()
        let recordID = TrainingRecordID(uuid: UUID(uuidString: "80600000-0000-0000-0000-000000000001")!)
        let mutationID = TrainingRecordID(uuid: UUID(uuidString: "80600000-0000-0000-0000-000000000002")!)
        let session = try TrainingSession(
            id: recordID,
            title: "Bootstrap evidence",
            createdAt: base,
            updatedAt: base,
            startedAt: base,
            now: base
        )
        let payload = TrainingReplicationState.inlinePayload(try FitnessPayloadCodec.encode(session, now: base))
        let entityID = try TrainingReplicationState.entityID(for: recordID)
        let entry = TrainingBootstrapEntry(
            recordID: recordID,
            mutationID: mutationID,
            entityID: entityID,
            payloadHash: payload.hash
        )
        let intent = TrainingSyncIntent(
            mutationID: mutationID,
            recordID: recordID,
            kind: .bootstrap,
            payload: payload
        )
        let valid = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [entry],
            pendingIntents: [intent],
            entityKeys: [TrainingEntityKey(recordID: recordID, entityID: entityID)],
            ledger: TrainingReplicationState.emptyLedger(for: binding)
        )
        try valid.validate(retainedSessionIDs: [recordID], receiptMutationIDs: [], retiredMutationIDs: [])

        let missingAllEvidence = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: [],
            ledger: valid.ledger
        )
        assertReplicationInvalid(missingAllEvidence, retainedSessionIDs: [recordID])

        let missing = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [entry],
            pendingIntents: [],
            entityKeys: valid.entityKeys,
            ledger: valid.ledger
        )
        assertReplicationInvalid(missing, retainedSessionIDs: [recordID])

        let duplicate = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [entry],
            pendingIntents: [intent, intent],
            entityKeys: valid.entityKeys,
            ledger: valid.ledger
        )
        assertReplicationInvalid(duplicate, retainedSessionIDs: [recordID])

        let wrongRecord = TrainingSyncIntent(
            mutationID: mutationID,
            recordID: TrainingRecordID(uuid: UUID(uuidString: "80600000-0000-0000-0000-000000000003")!),
            kind: .bootstrap,
            payload: payload
        )
        let mismatched = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [entry],
            pendingIntents: [wrongRecord],
            entityKeys: valid.entityKeys,
            ledger: valid.ledger
        )
        assertReplicationInvalid(mismatched, retainedSessionIDs: [recordID])
    }

    func testBatchARejectsAdvancedSequenceAndNonemptyAdapterLedger() throws {
        let binding = makeReplicationBinding()
        let empty = TrainingReplicationState.emptyLedger(for: binding)
        let state = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: [],
            ledger: empty
        )
        assertReplicationInvalid(TrainingReplicationState(
            binding: binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: [],
            ledger: replacingLedger(empty, nextSequence: "99")
        ))

        let placeholder = SyncOperation(
            datasetID: binding.datasetID,
            epoch: binding.epoch,
            storeID: binding.storeID,
            domain: .fitness,
            originID: binding.localOriginID,
            keyID: binding.keyID,
            sequence: "1",
            mutationID: "80600000-0000-0000-0000-000000000004",
            entityID: String(repeating: "a", count: 64),
            parents: [],
            baseHash: nil,
            kind: .put,
            payload: SyncPayload(hash: SyncWireCodec.sha256(Data()), byteCount: 0, inline: "", blobHash: nil),
            signature: ""
        )
        let withInbox = replacingLedger(empty, inbox: [placeholder])
        assertReplicationInvalid(TrainingReplicationState(
            binding: binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: [],
            ledger: withInbox
        ))
        XCTAssertNotEqual(state.ledger, withInbox)
    }

    func testEmbeddedAdapterDecoderRejectsNonemptyArraysBeforeElementDecoding() throws {
        let binding = makeReplicationBinding()
        let state = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: [],
            ledger: TrainingReplicationState.emptyLedger(for: binding)
        )
        let encoded = try TrainingDateCoding.makeEncoder().encode(TrainingLedgerEnvelope(replication: state))

        var inboxObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var inboxReplication = try XCTUnwrap(inboxObject["replication"] as? [String: Any])
        var inboxLedger = try XCTUnwrap(inboxReplication["ledger"] as? [String: Any])
        inboxLedger["inbox"] = [["malformed": "must not decode as SyncOperation"]]
        inboxReplication["ledger"] = inboxLedger
        inboxObject["replication"] = inboxReplication
        let nonemptyInbox = try JSONSerialization.data(withJSONObject: inboxObject, options: [.sortedKeys])
        XCTAssertThrowsError(try decodeEnvelope(nonemptyInbox))

        var frontierObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var frontierReplication = try XCTUnwrap(frontierObject["replication"] as? [String: Any])
        var frontierLedger = try XCTUnwrap(frontierReplication["ledger"] as? [String: Any])
        var received = try XCTUnwrap(frontierLedger["received"] as? [String: Any])
        received["positions"] = [["malformed": "must not decode as SyncPosition"]]
        frontierLedger["received"] = received
        frontierReplication["ledger"] = frontierLedger
        frontierObject["replication"] = frontierReplication
        let nonemptyFrontier = try JSONSerialization.data(withJSONObject: frontierObject, options: [.sortedKeys])
        XCTAssertThrowsError(try decodeEnvelope(nonemptyFrontier))
    }

    func testEmbeddedAdapterDecoderRejectsUnknownLedgerKeys() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyReplicationEnvelopeData()) as? [String: Any])
        var replication = try XCTUnwrap(object["replication"] as? [String: Any])
        var ledger = try XCTUnwrap(replication["ledger"] as? [String: Any])
        ledger["unexpectedLedgerField"] = "tampered"
        replication["ledger"] = ledger
        object["replication"] = replication

        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try decodeEnvelope(tampered))
    }

    func testEmbeddedFrontierDecoderRejectsUnknownKeys() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyReplicationEnvelopeData()) as? [String: Any])
        var replication = try XCTUnwrap(object["replication"] as? [String: Any])
        var ledger = try XCTUnwrap(replication["ledger"] as? [String: Any])
        var received = try XCTUnwrap(ledger["received"] as? [String: Any])
        received["unexpectedFrontierField"] = "tampered"
        ledger["received"] = received
        replication["ledger"] = ledger
        object["replication"] = replication

        let tampered = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try decodeEnvelope(tampered))
    }

    func testPersistedV3RejectsMissingBootstrapEvidenceForRetainedDiscardedSession() async throws {
        let fixture = try makeFixture(name: "training-v3-missing-bootstrap-evidence")
        defer { fixture.cleanup() }
        let store = makeStore(fixture, clock: TestClock(base))
        let begun = try await store.begin(
            title: "Discarded but retained",
            mutationID: UUID(uuidString: "80700000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(begun.recordID)
        let optionalSession = try await store.session(id: recordID)
        let session = try XCTUnwrap(optionalSession)
        _ = try await store.discard(
            id: recordID,
            expectedRevision: session.revision,
            mutationID: UUID(uuidString: "80700000-0000-0000-0000-000000000002")!
        )
        let committed = try await store.bindReplication(makeReplicationBinding())
        let validEnvelope = try decodeEnvelope(Data(contentsOf: fixture.url))
        XCTAssertEqual(validEnvelope.sessions.map(\.id), [recordID])
        XCTAssertEqual(validEnvelope.sessions.first?.status, .discarded)

        // Preserve the entity key but remove all bootstrap and pending-intent
        // evidence for this retained session.
        let tamperedReplication = TrainingReplicationState(
            binding: committed.binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: committed.entityKeys,
            ledger: committed.ledger
        )
        let tamperedEnvelope = TrainingLedgerEnvelope(
            sessions: validEnvelope.sessions,
            receipts: validEnvelope.receipts,
            retiredMutationIDs: validEnvelope.retiredMutationIDs,
            replication: tamperedReplication
        )
        let tamperedBytes = try TrainingDateCoding.makeEncoder().encode(tamperedEnvelope)
        try tamperedBytes.write(to: fixture.url)

        let reopened = makeStore(fixture, clock: TestClock(base))
        do {
            _ = try await reopened.load()
            XCTFail("A retained session without bootstrap evidence must fail closed")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .corruptLedger)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), tamperedBytes)
    }

    func testSchemaTwoMigrationPreservesReceiptAndRetiredReplayBarriers() async throws {
        let fixture = try makeFixture(name: "schema-two-migration")
        defer { fixture.cleanup() }
        let recordID = TrainingRecordID(uuid: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!)
        let session = try TrainingSession(
            id: recordID,
            title: "Schema two",
            createdAt: base.addingTimeInterval(0.123456789),
            updatedAt: base.addingTimeInterval(0.123456789),
            startedAt: base.addingTimeInterval(0.123456789),
            now: base.addingTimeInterval(10)
        )
        let receiptUUID = UUID(uuidString: "81000000-0000-0000-0000-000000000002")!
        let receiptID = TrainingRecordID(uuid: receiptUUID)
        let mutation = TrainingMutation(
            mutationID: receiptID,
            operation: .update,
            recordID: recordID,
            expectedRevision: session.revision,
            session: session
        )
        let receipt = try TrainingCommitReceipt(
            mutationID: receiptID,
            outcome: .saved,
            recordID: recordID,
            revision: session.revision
        )
        let entry = try TrainingReceiptJournalEntry(
            mutationID: receiptID,
            payloadFingerprint: TrainingFingerprint.hex(for: mutation, version: .losslessNumericV2),
            payloadFingerprintVersion: .losslessNumericV2,
            receipt: receipt
        )
        let retiredID = TrainingRecordID(uuid: UUID(uuidString: "81000000-0000-0000-0000-000000000003")!)
        let schemaTwo = TrainingLedgerEnvelope(
            schemaVersion: 2,
            sessions: [session],
            receipts: [entry],
            retiredMutationIDs: [retiredID]
        )
        try TrainingDateCoding.makeEncoder().encode(schemaTwo).write(to: fixture.url)

        let store = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        let loaded = try await store.load()
        XCTAssertEqual(loaded, [session])
        let migrated = try decodeEnvelope(try await store.export())
        XCTAssertEqual(migrated.schemaVersion, 3)
        XCTAssertEqual(migrated.sessions, [session])
        XCTAssertEqual(migrated.receipts, [entry])
        XCTAssertEqual(migrated.retiredMutationIDs, [retiredID])
        XCTAssertNil(migrated.replication)
        let retry = try await store.update(session, expectedRevision: session.revision, mutationID: receiptUUID)
        XCTAssertEqual(retry, receipt)

        let restarted = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        _ = try await restarted.load()
        do {
            _ = try await restarted.begin(title: "Retired replay", mutationID: retiredID.uuid)
            XCTFail("Schema-two retired IDs must remain protected after migration")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .mutationIDRetired)
        }
    }

    func testBindingRoundTripsAndReusesBootstrapIDsForAllRetainedSessions() async throws {
        let fixture = try makeFixture(name: "training-bind-round-trip")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let discarded = try await store.begin(
            title: "Retained discarded workout",
            mutationID: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
        )
        let discardedID = try XCTUnwrap(discarded.recordID)
        let optionalDiscardedSession = try await store.session(id: discardedID)
        let discardedSession = try XCTUnwrap(optionalDiscardedSession)
        _ = try await store.discard(
            id: discardedID,
            expectedRevision: discardedSession.revision,
            mutationID: UUID(uuidString: "82000000-0000-0000-0000-000000000002")!
        )
        let active = try await store.begin(
            title: "Active workout",
            mutationID: UUID(uuidString: "82000000-0000-0000-0000-000000000003")!
        )
        let activeID = try XCTUnwrap(active.recordID)
        let binding = makeReplicationBinding()

        let committed = try await store.bindReplication(binding)
        XCTAssertEqual(committed.bootstrapMap.count, 2)
        XCTAssertEqual(committed.pendingIntents.count, 2)
        XCTAssertEqual(Set(committed.bootstrapMap.map(\.recordID)), [discardedID, activeID])
        XCTAssertTrue(committed.pendingIntents.allSatisfy { $0.kind == .bootstrap })
        let bytesAfterBind = try Data(contentsOf: fixture.url)
        let persisted = try decodeEnvelope(bytesAfterBind)
        XCTAssertEqual(persisted.schemaVersion, 3)
        XCTAssertEqual(persisted.replication, committed)
        XCTAssertEqual(
            Set(persisted.sessions.filter { $0.status == .discarded }.map(\.id)),
            [discardedID]
        )

        let repeated = try await store.bindReplication(binding)
        XCTAssertEqual(repeated, committed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytesAfterBind)
        let changedBindings = [
            TrainingSyncBinding(
                datasetID: "90000000-0000-0000-0000-000000000004",
                epoch: binding.epoch,
                storeID: binding.storeID,
                localOriginID: binding.localOriginID,
                keyID: binding.keyID
            ),
            TrainingSyncBinding(
                datasetID: binding.datasetID,
                epoch: "2",
                storeID: binding.storeID,
                localOriginID: binding.localOriginID,
                keyID: binding.keyID
            ),
            TrainingSyncBinding(
                datasetID: binding.datasetID,
                epoch: binding.epoch,
                storeID: "90000000-0000-0000-0000-000000000004",
                localOriginID: binding.localOriginID,
                keyID: binding.keyID
            ),
            TrainingSyncBinding(
                datasetID: binding.datasetID,
                epoch: binding.epoch,
                storeID: binding.storeID,
                localOriginID: "90000000-0000-0000-0000-000000000004",
                keyID: binding.keyID
            ),
            TrainingSyncBinding(
                datasetID: binding.datasetID,
                epoch: binding.epoch,
                storeID: binding.storeID,
                localOriginID: binding.localOriginID,
                keyID: String(repeating: "b", count: 64)
            )
        ]
        for changedBinding in changedBindings {
            do {
                _ = try await store.bindReplication(changedBinding)
                XCTFail("Changing any persisted binding field requires explicit migration")
            } catch {
                XCTAssertEqual(error as? TrainingStoreError, .replicationBindingMismatch)
            }
            XCTAssertEqual(try Data(contentsOf: fixture.url), bytesAfterBind)
        }
        let restarted = makeStore(fixture, clock: clock)
        _ = try await restarted.load()
        let reopened = try await restarted.bindReplication(binding)
        XCTAssertEqual(reopened, committed)
        XCTAssertEqual(try Data(contentsOf: fixture.url), bytesAfterBind)
    }

    func testBindingRejectsBootstrapMutationCollisionWithoutChangingBytes() async throws {
        let fixture = try makeFixture(name: "training-bind-collision")
        defer { fixture.cleanup() }
        let collisionID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
        let store = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { self.base },
            makeBootstrapMutationID: { collisionID }
        )
        _ = try await store.begin(title: "Collision source", mutationID: collisionID)
        let before = try Data(contentsOf: fixture.url)

        do {
            _ = try await store.bindReplication(makeReplicationBinding())
            XCTFail("A bootstrap ID must not reuse a live command receipt ID")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .replicationCollision)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertNil(try decodeEnvelope(before).replication)
    }

    func testBindingRejectsRetiredGeneratedMutationIDCollision() async throws {
        let fixture = try makeFixture(name: "training-bind-retired-collision")
        defer { fixture.cleanup() }
        let originalStore = makeStore(fixture, clock: TestClock(base))
        _ = try await originalStore.begin(
            title: "Retired collision source",
            mutationID: UUID(uuidString: "83100000-0000-0000-0000-000000000001")!
        )
        let original = try decodeEnvelope(Data(contentsOf: fixture.url))
        let retiredID = TrainingRecordID(uuid: UUID(uuidString: "83100000-0000-0000-0000-000000000002")!)
        let withRetiredID = TrainingLedgerEnvelope(
            sessions: original.sessions,
            receipts: original.receipts,
            retiredMutationIDs: [retiredID]
        )
        try TrainingDateCoding.makeEncoder().encode(withRetiredID).write(to: fixture.url)
        let before = try Data(contentsOf: fixture.url)
        let collisionStore = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { self.base },
            makeBootstrapMutationID: { retiredID.uuid }
        )

        do {
            _ = try await collisionStore.bindReplication(makeReplicationBinding())
            XCTFail("A generated bootstrap ID must not reuse a retired command ID")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .replicationCollision)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertNil(try decodeEnvelope(before).replication)
    }

    func testBindingRejectsDeterministicGeneratedMutationIDCollision() async throws {
        let fixture = try makeFixture(name: "training-bind-generated-collision")
        defer { fixture.cleanup() }
        let setupStore = makeStore(fixture, clock: TestClock(base))
        let first = try await setupStore.begin(
            title: "First retained session",
            mutationID: UUID(uuidString: "83200000-0000-0000-0000-000000000001")!
        )
        let firstID = try XCTUnwrap(first.recordID)
        let optionalSession = try await setupStore.session(id: firstID)
        let firstSession = try XCTUnwrap(optionalSession)
        _ = try await setupStore.discard(
            id: firstID,
            expectedRevision: firstSession.revision,
            mutationID: UUID(uuidString: "83200000-0000-0000-0000-000000000002")!
        )
        _ = try await setupStore.begin(
            title: "Second retained session",
            mutationID: UUID(uuidString: "83200000-0000-0000-0000-000000000003")!
        )
        let before = try Data(contentsOf: fixture.url)
        let repeatedID = UUID(uuidString: "83200000-0000-0000-0000-000000000004")!
        let generator = DeterministicBootstrapIDs([repeatedID, repeatedID])
        let collisionStore = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { self.base },
            makeBootstrapMutationID: { generator.next() }
        )

        do {
            _ = try await collisionStore.bindReplication(makeReplicationBinding())
            XCTFail("Two retained sessions must not receive the same generated mutation ID")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .replicationCollision)
        }
        XCTAssertEqual(generator.generatedCount, 2)
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        XCTAssertNil(try decodeEnvelope(before).replication)
    }

    func testCorruptReplicationEntityCollisionIsRejectedWithoutRewritingLedger() async throws {
        let fixture = try makeFixture(name: "training-bind-corrupt-entity")
        defer { fixture.cleanup() }
        let store = makeStore(fixture, clock: TestClock(base))
        _ = try await store.begin(
            title: "Entity collision source",
            mutationID: UUID(uuidString: "83500000-0000-0000-0000-000000000001")!
        )
        let committed = try await store.bindReplication(makeReplicationBinding())
        let validEnvelope = try decodeEnvelope(Data(contentsOf: fixture.url))
        let entityKey = try XCTUnwrap(committed.entityKeys.first)
        let duplicateEntityKey = TrainingEntityKey(
            recordID: entityKey.recordID,
            entityID: entityKey.entityID
        )
        let corruptState = TrainingReplicationState(
            binding: committed.binding,
            bootstrapMap: committed.bootstrapMap,
            pendingIntents: committed.pendingIntents,
            entityKeys: committed.entityKeys + [duplicateEntityKey],
            ledger: committed.ledger
        )
        let corruptEnvelope = TrainingLedgerEnvelope(
            sessions: validEnvelope.sessions,
            receipts: validEnvelope.receipts,
            retiredMutationIDs: validEnvelope.retiredMutationIDs,
            replication: corruptState
        )
        let corruptBytes = try TrainingDateCoding.makeEncoder().encode(corruptEnvelope)
        try corruptBytes.write(to: fixture.url)

        let reopened = makeStore(fixture, clock: TestClock(base))
        do {
            _ = try await reopened.load()
            XCTFail("Duplicate entity ownership must make the ledger corrupt")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .corruptLedger)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), corruptBytes)
        let preserved = try await reopened.export()
        XCTAssertEqual(preserved, corruptBytes)
    }

    func testFailedBindingWritePreservesSameStoreMemoryAndAllowsRetry() async throws {
        let fixture = try makeFixture(name: "training-bind-write-failure")
        defer { fixture.cleanup() }
        let faults = PersistenceFaults()
        let store = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { self.base },
            beforeReplace: {
                if faults.failBeforeReplace { throw TrainingStoreError.persistenceFailed }
            }
        )
        let begin = try await store.begin(
            title: "Existing local state",
            mutationID: UUID(uuidString: "84000000-0000-0000-0000-000000000001")!
        )
        let sessionID = try XCTUnwrap(begin.recordID)
        let sessionsBefore = try await store.allSessions()
        let before = try Data(contentsOf: fixture.url)
        faults.failBeforeReplace = true

        do {
            _ = try await store.bindReplication(makeReplicationBinding())
            XCTFail("An injected write failure must abort binding")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .persistenceFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        let sessionsAfterFailure = try await store.allSessions()
        XCTAssertEqual(sessionsAfterFailure, sessionsBefore)
        let exportAfterFailure = try await store.export()
        XCTAssertNil(try decodeEnvelope(exportAfterFailure).replication)

        faults.failBeforeReplace = false
        let retried = try await store.bindReplication(makeReplicationBinding())
        XCTAssertEqual(retried.bootstrapMap.map(\.recordID), [sessionID])
        let sessionsAfterRetry = try await store.allSessions()
        XCTAssertEqual(sessionsAfterRetry, sessionsBefore)
        XCTAssertEqual(try decodeEnvelope(Data(contentsOf: fixture.url)).replication, retried)
    }

    func testBeginFromTemplatePersistsAnImmutableDraftSnapshot() async throws {
        let fixture = try makeFixture(name: "template-start")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { clock.now }
        )
        let templateExercise = try TrainingTemplateExerciseSnapshot(
            id: "squat",
            name: "Back squat",
            muscleGroup: .legs,
            targetSets: 4,
            targetRepetitions: 6,
            targetLoadKilograms: 100
        )
        let template = try TrainingTemplateSnapshot(
            templateID: "legs-day",
            name: "Legs day",
            exercises: [templateExercise]
        )

        let receipt = try await store.begin(
            template: template,
            mutationID: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(receipt.recordID)
        let optionalSession = try await store.session(id: recordID)
        let session = try XCTUnwrap(optionalSession)

        XCTAssertEqual(session.status, .active)
        XCTAssertEqual(session.templateID, "legs-day")
        XCTAssertEqual(session.templateSnapshot, template)
        XCTAssertEqual(session.title, "Legs day")
        XCTAssertEqual(session.exercises.first?.name, "Back squat")
        XCTAssertEqual(session.exercises.first?.sets.count, 4)
        XCTAssertEqual(session.exercises.first?.sets.first?.targetRepetitions, 6)
        XCTAssertEqual(session.exercises.first?.sets.first?.targetLoadKilograms, 100)
        XCTAssertNil(session.exercises.first?.sets.first?.actualRepetitions)
        XCTAssertEqual(receipt.outcome, .saved)

        let changedTemplate = try TrainingTemplateSnapshot(
            templateID: "legs-day",
            name: "Renamed later",
            exercises: [try TrainingTemplateExerciseSnapshot(
                id: "squat",
                name: "Front squat",
                muscleGroup: .legs,
                targetSets: 2,
                targetRepetitions: 10
            )]
        )
        XCTAssertNotEqual(changedTemplate, session.templateSnapshot)
        XCTAssertEqual(session.exercises.first?.name, "Back squat")
    }

    func testFinishRequiresActualCompletedSetAndExactRetryReturnsOriginalReceipt() async throws {
        let fixture = try makeFixture(name: "finish")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let beginReceipt = try await store.begin(
            title: "Push day",
            mutationID: UUID(uuidString: "20000000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(beginReceipt.recordID)
        let optionalActive = try await store.session(id: recordID)
        let active = try XCTUnwrap(optionalActive)

        clock.now = base.addingTimeInterval(60)
        let workingSet = try TrainingSetLog(
            kind: .working,
            targetRepetitions: 8,
            targetLoadKilograms: 80,
            actualRepetitions: 7,
            actualLoadKilograms: 82.5,
            isCompleted: true,
            completedAt: base.addingTimeInterval(45),
            now: clock.now
        )
        let exercise = try TrainingExerciseLog(
            name: "Bench press",
            muscleGroup: .chest,
            sets: [workingSet]
        )
        let completed = try TrainingSession(
            id: active.id,
            revision: active.revision,
            activityKind: active.activityKind,
            title: active.title,
            createdAt: active.createdAt,
            updatedAt: clock.now,
            startedAt: active.startedAt,
            endedAt: clock.now,
            timeZoneIdentifier: active.timeZoneIdentifier,
            pauses: active.pauses,
            status: .completed,
            exercises: [exercise],
            notes: active.notes,
            importedRecordKey: active.importedRecordKey,
            now: clock.now
        )
        let finishID = UUID(uuidString: "20000000-0000-0000-0000-000000000002")!
        let receipt = try await store.finish(completed, expectedRevision: active.revision, mutationID: finishID)
        XCTAssertEqual(receipt.outcome, .saved)
        XCTAssertEqual(receipt.revision, 1)

        let retry = try await store.finish(completed, expectedRevision: active.revision, mutationID: finishID)
        XCTAssertEqual(retry, receipt)

        let optionalSaved = try await store.session(id: active.id)
        let saved = try XCTUnwrap(optionalSaved)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertEqual(saved.revision, 1)
        XCTAssertEqual(saved.recordedWorkingVolumeKilograms, 577.5)

        let history = try await store.allHistory()
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.duration, 60)
    }

    func testTimedNonStrengthFinishPersistsWithoutSyntheticSetMetrics() async throws {
        let fixture = try makeFixture(name: "timed-finish")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let begin = try await store.begin(
            title: "Timed cardio",
            activityKind: .cardio,
            mutationID: UUID(uuidString: "20500000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(begin.recordID)
        let optionalActive = try await store.session(id: recordID)
        let active = try XCTUnwrap(optionalActive)

        clock.now = base.addingTimeInterval(90)
        let completed = try TrainingSession(
            id: active.id,
            revision: active.revision,
            activityKind: active.activityKind,
            title: active.title,
            createdAt: active.createdAt,
            updatedAt: clock.now,
            startedAt: active.startedAt,
            endedAt: clock.now,
            timeZoneIdentifier: active.timeZoneIdentifier,
            templateID: active.templateID,
            templateSnapshot: active.templateSnapshot,
            pauses: active.pauses,
            status: .completed,
            exercises: [],
            notes: active.notes,
            importedRecordKey: active.importedRecordKey,
            now: clock.now
        )
        let receipt = try await store.finish(
            completed,
            expectedRevision: active.revision,
            mutationID: UUID(uuidString: "20500000-0000-0000-0000-000000000002")!
        )

        XCTAssertEqual(receipt.outcome, .saved)
        let optionalSaved = try await store.session(id: recordID)
        let saved = try XCTUnwrap(optionalSaved)
        XCTAssertEqual(saved.status, .completed)
        XCTAssertTrue(saved.completedSets.isEmpty)
        XCTAssertNil(saved.recordedExternalVolumeKilograms)
        XCTAssertEqual(saved.recordedDuration, 90)
    }

    func testOrdinaryUpdateCannotReopenCompletedOrDiscardedCurrentRevision() async throws {
        let fixture = try makeFixture(name: "terminal-update")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)

        let begin = try await store.begin(
            title: "Completed session",
            mutationID: UUID(uuidString: "21000000-0000-0000-0000-000000000001")!
        )
        let completedID = try XCTUnwrap(begin.recordID)
        let optionalActive = try await store.session(id: completedID)
        let active = try XCTUnwrap(optionalActive)
        clock.now = base.addingTimeInterval(60)
        let completedDraft = try completedDraft(from: active, now: clock.now, title: active.title, sequence: 0)
        _ = try await store.finish(
            completedDraft,
            expectedRevision: active.revision,
            mutationID: UUID(uuidString: "21000000-0000-0000-0000-000000000002")!
        )
        let optionalCompleted = try await store.session(id: completedID)
        let completed = try XCTUnwrap(optionalCompleted)
        let reopenedCompleted = try activeDraft(from: completed, now: clock.now)

        do {
            _ = try await store.update(
                reopenedCompleted,
                expectedRevision: completed.revision,
                mutationID: UUID(uuidString: "21000000-0000-0000-0000-000000000003")!
            )
            XCTFail("An ordinary update must not reopen a completed session")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .invalidMutation)
        }
        let completedAfterUpdate = try await store.session(id: completedID)
        XCTAssertEqual(completedAfterUpdate?.status, .completed)
        XCTAssertEqual(completedAfterUpdate?.revision, completed.revision)

        let discardedBegin = try await store.begin(
            title: "Discarded session",
            mutationID: UUID(uuidString: "21000000-0000-0000-0000-000000000004")!
        )
        let discardedID = try XCTUnwrap(discardedBegin.recordID)
        let optionalDiscarded = try await store.session(id: discardedID)
        let discarded = try XCTUnwrap(optionalDiscarded)
        let discardReceipt = try await store.discard(
            id: discarded.id,
            expectedRevision: discarded.revision,
            mutationID: UUID(uuidString: "21000000-0000-0000-0000-000000000005")!
        )
        XCTAssertEqual(discardReceipt.outcome, .saved)
        let optionalSavedDiscarded = try await store.session(id: discardedID)
        let savedDiscarded = try XCTUnwrap(optionalSavedDiscarded)
        let reopenedDiscarded = try activeDraft(from: savedDiscarded, now: clock.now)

        do {
            _ = try await store.update(
                reopenedDiscarded,
                expectedRevision: savedDiscarded.revision,
                mutationID: UUID(uuidString: "21000000-0000-0000-0000-000000000006")!
            )
            XCTFail("An ordinary update must not reopen a discarded session")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .invalidMutation)
        }
        let discardedAfterUpdate = try await store.session(id: discardedID)
        XCTAssertEqual(discardedAfterUpdate?.status, .discarded)
        XCTAssertEqual(discardedAfterUpdate?.revision, savedDiscarded.revision)
    }

    func testRevisionConflictKeepsCurrentRecordAndDraftAndMutationReuseIsRejected() async throws {
        let fixture = try makeFixture(name: "conflict")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let begin = try await store.begin(
            title: "Original",
            mutationID: UUID(uuidString: "30000000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(begin.recordID)
        let optionalActive = try await store.session(id: recordID)
        let active = try XCTUnwrap(optionalActive)

        let firstDraft = try replacingTitle(active, title: "Current edit", now: clock.now)
        let updateID = UUID(uuidString: "30000000-0000-0000-0000-000000000002")!
        let savedReceipt = try await store.update(firstDraft, expectedRevision: active.revision, mutationID: updateID)
        XCTAssertEqual(savedReceipt.outcome, .saved)

        let exactRetry = try await store.update(firstDraft, expectedRevision: active.revision, mutationID: updateID)
        XCTAssertEqual(exactRetry, savedReceipt)

        let misuse = try replacingTitle(active, title: "Different payload", now: clock.now)
        do {
            _ = try await store.update(misuse, expectedRevision: active.revision, mutationID: updateID)
            XCTFail("A reused mutation ID must reject a different payload")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .mutationIDReuse)
        }

        let staleDraft = try replacingTitle(active, title: "Stale draft", now: clock.now)
        let conflict = try await store.update(
            staleDraft,
            expectedRevision: active.revision,
            mutationID: UUID(uuidString: "30000000-0000-0000-0000-000000000003")!
        )
        XCTAssertEqual(conflict.outcome, .conflict)
        XCTAssertEqual(conflict.currentSession?.title, "Current edit")
        XCTAssertEqual(conflict.revision, 1)

        let optionalCurrent = try await store.session(id: active.id)
        let current = try XCTUnwrap(optionalCurrent)
        XCTAssertEqual(current.title, "Current edit")
        XCTAssertEqual(current.revision, 1)
    }

    func testOnlyOneActiveOrPausedSessionExistsAndDiscardUnblocksBegin() async throws {
        let fixture = try makeFixture(name: "single-active")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let first = try await store.begin(
            title: "First",
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000001")!
        )
        let firstRecordID = try XCTUnwrap(first.recordID)
        let optionalFirstSession = try await store.session(id: firstRecordID)
        let firstSession = try XCTUnwrap(optionalFirstSession)

        let blocked = try await store.begin(
            title: "Second",
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000002")!
        )
        XCTAssertEqual(blocked.outcome, .blocked)
        XCTAssertEqual(blocked.blockReason, .activeSession)

        let discard = try await store.discard(
            id: firstSession.id,
            expectedRevision: firstSession.revision,
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000003")!
        )
        XCTAssertEqual(discard.outcome, .saved)
        let activeAfterDiscard = try await store.activeSession()
        XCTAssertNil(activeAfterDiscard)

        let second = try await store.begin(
            title: "Second",
            mutationID: UUID(uuidString: "40000000-0000-0000-0000-000000000004")!
        )
        XCTAssertEqual(second.outcome, .saved)
        let history = try await store.allHistory()
        XCTAssertEqual(history.count, 1, "Discarded drafts are retained for explicit record accounting but omitted from history")
        XCTAssertEqual(history.first?.title, "Second")
    }

    func testRestartPersistenceExportAndPaginationAreDeterministic() async throws {
        let fixture = try makeFixture(name: "restart")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)

        for index in 0..<3 {
            clock.now = base.addingTimeInterval(TimeInterval(index * 120))
            let begin = try await store.begin(
                title: "Session \(index)",
                mutationID: UUID(uuidString: String(format: "50000000-0000-0000-0000-%012x", index * 2 + 1))!
            )
            let recordID = try XCTUnwrap(begin.recordID)
            let optionalActive = try await store.session(id: recordID)
            let active = try XCTUnwrap(optionalActive)
            clock.now = active.startedAt.addingTimeInterval(60)
            let completed = try completedDraft(from: active, now: clock.now, title: active.title, sequence: index)
            _ = try await store.finish(
                completed,
                expectedRevision: active.revision,
                mutationID: UUID(uuidString: String(format: "50000000-0000-0000-0000-%012x", index * 2 + 2))!
            )
        }

        let exported = try await store.export()
        let envelope = try decodeEnvelope(exported)
        XCTAssertEqual(envelope.schemaVersion, TrainingLedgerEnvelope.currentSchemaVersion)
        XCTAssertEqual(envelope.sessions.count, 3)
        XCTAssertEqual(envelope.receipts.count, 6)

        let restarted = makeStore(fixture, clock: clock)
        let loaded = try await restarted.load()
        XCTAssertEqual(loaded.count, 3)
        let restartedSessions = try await restarted.allSessions()
        XCTAssertEqual(restartedSessions, loaded)
        let restartedHistory = try await restarted.allHistory()
        XCTAssertEqual(restartedHistory.map(\.title), ["Session 2", "Session 1", "Session 0"])

        let firstPage = try await restarted.historyPage(offset: 0, limit: 2)
        XCTAssertEqual(firstPage.items.map(\.title), ["Session 2", "Session 1"])
        XCTAssertTrue(firstPage.hasMore)
        let secondPage = try await restarted.pagedHistory(page: 1, pageSize: 2)
        XCTAssertEqual(secondPage.items.map(\.title), ["Session 0"])
        XCTAssertFalse(secondPage.hasMore)
        do {
            _ = try await restarted.historyPage(offset: 0, limit: 101)
            XCTFail("A page larger than the limit must be rejected")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .invalidHistoryPage)
        }
        do {
            _ = try await restarted.historyPage(offset: 4, limit: 1)
            XCTFail("An offset past the end must be rejected")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .invalidHistoryPage)
        }
    }

    func testSchemaOneISO8601LedgerMigratesWithoutLosingFractionalDates() async throws {
        let fixture = try makeFixture(name: "schema-one-migration")
        defer { fixture.cleanup() }
        let started = base.addingTimeInterval(0.123456789)
        let session = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "80000000-0000-0000-0000-000000000001")!),
            title: "Legacy precision",
            createdAt: started,
            updatedAt: started.addingTimeInterval(0.5),
            startedAt: started,
            now: base.addingTimeInterval(10)
        )
        let legacy = LegacyEnvelopeFixture(sessions: [session])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            let wholeSeconds = seconds.rounded(.towardZero)
            let fractionalDigits = String(format: "%.9f", seconds - wholeSeconds).dropFirst(2)
            let wholeDate = Date(timeIntervalSinceReferenceDate: wholeSeconds)
            let baseString = Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(wholeDate)
            var container = encoder.singleValueContainer()
            try container.encode(baseString.replacingOccurrences(of: "Z", with: ".\(fractionalDigits)Z"))
        }
        try encoder.encode(legacy).write(to: fixture.url)

        let store = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        let loaded = try await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].createdAt.timeIntervalSinceReferenceDate, session.createdAt.timeIntervalSinceReferenceDate, accuracy: 0.000000001)
        XCTAssertEqual(loaded[0].updatedAt.timeIntervalSinceReferenceDate, session.updatedAt.timeIntervalSinceReferenceDate, accuracy: 0.000000001)

        let migrated = try await store.export()
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: migrated) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, TrainingLedgerEnvelope.currentSchemaVersion)
        XCTAssertFalse(String(decoding: migrated, as: UTF8.self).contains("T"), "Current dates use numeric lossless storage")
        let decoded = try decodeEnvelope(migrated)
        let migratedSession = try XCTUnwrap(decoded.sessions.first)
        XCTAssertEqual(migratedSession.createdAt.timeIntervalSinceReferenceDate, session.createdAt.timeIntervalSinceReferenceDate, accuracy: 0.000000001)
        XCTAssertEqual(migratedSession.updatedAt.timeIntervalSinceReferenceDate, session.updatedAt.timeIntervalSinceReferenceDate, accuracy: 0.000000001)
    }

    func testFirstHistoryReadMigratesSchemaOneUnderTheDurableReadLock() async throws {
        let fixture = try makeFixture(name: "schema-one-first-read")
        defer { fixture.cleanup() }
        let session = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "80000000-0000-0000-0000-000000000011")!),
            title: "First read migration",
            createdAt: base.addingTimeInterval(0.125),
            updatedAt: base.addingTimeInterval(0.25),
            startedAt: base.addingTimeInterval(0.125),
            now: base.addingTimeInterval(10)
        )
        let legacy = LegacyEnvelopeFixture(sessions: [session])
        try makeLegacyEncoder().encode(legacy).write(to: fixture.url)

        let store = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        let firstRead = try await store.allSessions()
        XCTAssertEqual(firstRead, [session])
        let migrated = try decodeEnvelope(try Data(contentsOf: fixture.url))
        XCTAssertEqual(migrated.schemaVersion, TrainingLedgerEnvelope.currentSchemaVersion)
    }

    func testSchemaOneReceiptKeepsLegacyFingerprintRetryAndRejectsAlteredPayload() async throws {
        let fixture = try makeFixture(name: "schema-one-receipt")
        defer { fixture.cleanup() }
        let started = base.addingTimeInterval(0.123456789)
        let session = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "80000000-0000-0000-0000-000000000012")!),
            title: "Legacy receipt",
            createdAt: started,
            updatedAt: started.addingTimeInterval(0.5),
            startedAt: started,
            now: base.addingTimeInterval(10)
        )
        let mutationID = UUID(uuidString: "87000000-0000-0000-0000-000000000001")!
        let mutation = TrainingMutation(
            mutationID: TrainingRecordID(uuid: mutationID),
            operation: .update,
            recordID: session.id,
            expectedRevision: session.revision,
            session: session
        )
        let legacyReceipt = try TrainingCommitReceipt(
            mutationID: TrainingRecordID(uuid: mutationID),
            outcome: .saved,
            recordID: session.id,
            revision: session.revision
        )
        let legacyEntry = LegacyReceiptEntryFixture(
            mutationID: TrainingRecordID(uuid: mutationID),
            payloadFingerprint: try TrainingFingerprint.hex(for: mutation, version: .legacyISO8601V1),
            receipt: legacyReceipt
        )
        let legacy = LegacyReceiptEnvelopeFixture(sessions: [session], receipts: [legacyEntry])
        try makeLegacyEncoder().encode(legacy).write(to: fixture.url)

        let store = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        _ = try await store.load()
        let migratedEnvelope = try decodeEnvelope(try await store.export())
        XCTAssertEqual(migratedEnvelope.receipts.first?.payloadFingerprintVersion, .legacyISO8601V1)

        let exactRetry = try await store.update(session, expectedRevision: session.revision, mutationID: mutationID)
        XCTAssertEqual(exactRetry, legacyReceipt)

        let altered = try replacingTitle(session, title: "Altered payload", now: base.addingTimeInterval(1))
        do {
            _ = try await store.update(altered, expectedRevision: session.revision, mutationID: mutationID)
            XCTFail("A reused legacy mutation ID with another payload must be rejected")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .mutationIDReuse)
        }
    }

    func testSchemaOneNonemptyQueueIsRejectedWithoutRewrite() async throws {
        let fixture = try makeFixture(name: "schema-one-queue")
        defer { fixture.cleanup() }
        let legacy = Data("{\"schemaVersion\":1,\"sessions\":[],\"receipts\":[],\"queuedMutations\":[null]}".utf8)
        try legacy.write(to: fixture.url)
        let store = makeStore(fixture, clock: TestClock(base))

        do {
            _ = try await store.load()
            XCTFail("A legacy queue must not be silently discarded")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .legacyQueueDataPresent)
        }
        let exportedLegacy = try await store.export()
        XCTAssertEqual(exportedLegacy, legacy)
    }

    func testReceiptCountAndEncodedByteExhaustionFailClosed() throws {
        let entries = try (0...TrainingStoreLimits.maximumReceipts).map { index in
            let suffix = String(format: "%012x", index + 1)
            let mutationID = TrainingRecordID(uuid: UUID(uuidString: "85000000-0000-0000-0000-\(suffix)")!)
            let receipt = try TrainingCommitReceipt(mutationID: mutationID, outcome: .saved)
            return try TrainingReceiptJournalEntry(
                mutationID: mutationID,
                payloadFingerprint: String(repeating: "a", count: 64),
                receipt: receipt
            )
        }
        let envelope = TrainingLedgerEnvelope(receipts: entries)
        XCTAssertThrowsError(try envelope.validate(now: base)) { error in
            XCTAssertEqual(error as? TrainingStoreError, .receiptJournalFull)
        }

        let oversized = Data(repeating: 0, count: TrainingStoreLimits.maximumLedgerBytes + 1)
        XCTAssertThrowsError(try TrainingStoreLimits.validateEncodedLedgerBytes(oversized)) { error in
            XCTAssertEqual(error as? TrainingStoreError, .ledgerTooLarge)
        }
    }

    func testFractionalPauseDatesSurviveCurrentPersistenceAndRestart() async throws {
        let fixture = try makeFixture(name: "fractional-restart")
        defer { fixture.cleanup() }
        let started = base.addingTimeInterval(0.123456789)
        let pause = try TrainingPauseInterval(
            startedAt: started.addingTimeInterval(1.000123),
            endedAt: started.addingTimeInterval(1.000579),
            now: base.addingTimeInterval(10)
        )
        let session = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "80000000-0000-0000-0000-000000000002")!),
            title: "Fractional restart",
            createdAt: started,
            updatedAt: started.addingTimeInterval(2.000001),
            startedAt: started,
            pauses: [pause],
            now: base.addingTimeInterval(10)
        )
        let envelope = TrainingLedgerEnvelope(sessions: [session])
        try TrainingDateCoding.makeEncoder().encode(envelope).write(to: fixture.url)

        let first = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        let firstLoaded = try await first.load()
        XCTAssertEqual(firstLoaded, [session])
        let restarted = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        let restartedLoaded = try await restarted.load()
        XCTAssertEqual(restartedLoaded, [session])
        let restoredSession = try await restarted.session(id: session.id)
        let restoredPause = try XCTUnwrap(restoredSession?.pauses.first)
        XCTAssertEqual(restoredPause.startedAt, pause.startedAt)
        XCTAssertEqual(restoredPause.endedAt, pause.endedAt)
    }

    func testRevisionIncrementRejectsOverflowBeforePublishing() async throws {
        let fixture = try makeFixture(name: "revision-overflow")
        defer { fixture.cleanup() }
        let session = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "80000000-0000-0000-0000-000000000003")!),
            revision: Int.max - 1,
            title: "Revision boundary",
            createdAt: base,
            updatedAt: base,
            startedAt: base,
            now: base.addingTimeInterval(10)
        )
        try TrainingDateCoding.makeEncoder()
            .encode(TrainingLedgerEnvelope(sessions: [session]))
            .write(to: fixture.url)
        let store = makeStore(fixture, clock: TestClock(base.addingTimeInterval(10)))
        let before = try Data(contentsOf: fixture.url)

        do {
            _ = try await store.update(
                session,
                expectedRevision: session.revision,
                mutationID: UUID(uuidString: "86000000-0000-0000-0000-000000000001")!
            )
            XCTFail("Revision increment must fail before Int.max is published")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .revisionExhausted)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
    }

    func testIndependentStoreInstancesRereadDurableStateBeforeMutation() async throws {
        let fixture = try makeFixture(name: "independent-stores")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let firstStore = makeStore(fixture, clock: clock)
        let secondStore = makeStore(fixture, clock: clock)
        let initialSecondStoreSessions = try await secondStore.load()
        XCTAssertEqual(initialSecondStoreSessions, [])

        let first = try await firstStore.begin(
            title: "First durable session",
            mutationID: UUID(uuidString: "81000000-0000-0000-0000-000000000001")!
        )
        let firstRecordID = try XCTUnwrap(first.recordID)
        let firstOptionalSession = try await firstStore.session(id: firstRecordID)
        let firstSession = try XCTUnwrap(firstOptionalSession)
        _ = try await firstStore.discard(
            id: firstSession.id,
            expectedRevision: firstSession.revision,
            mutationID: UUID(uuidString: "81000000-0000-0000-0000-000000000002")!
        )

        let second = try await secondStore.begin(
            title: "Second durable session",
            mutationID: UUID(uuidString: "81000000-0000-0000-0000-000000000003")!
        )
        XCTAssertEqual(second.outcome, .saved)
        let refreshed = try await firstStore.load()
        XCTAssertEqual(Set(refreshed.map(\.title)), Set(["First durable session", "Second durable session"]))
    }

    func testReceiptLookupRereadsAStaleStoreInstance() async throws {
        let fixture = try makeFixture(name: "stale-receipt-read")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let writer = makeStore(fixture, clock: clock)
        let reader = makeStore(fixture, clock: clock)
        _ = try await reader.load()
        let mutationID = UUID(uuidString: "88000000-0000-0000-0000-000000000001")!
        let receipt = try await writer.begin(title: "Durable receipt", mutationID: mutationID)
        let rereadReceipt = try await reader.receipt(for: mutationID)
        XCTAssertEqual(rereadReceipt, receipt)
    }

    func testEmptyLedgerCanBeReadRepeatedlyAndFailedFirstWriteCanBeRetried() async throws {
        let fixture = try makeFixture(name: "empty-first-use")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)

        let firstRead = try await store.load()
        let secondRead = try await store.allSessions()
        let thirdRead = try await store.allSessions()
        XCTAssertTrue(firstRead.isEmpty)
        XCTAssertTrue(secondRead.isEmpty)
        XCTAssertTrue(thirdRead.isEmpty)

        let faults = PersistenceFaults()
        faults.failBeforeReplace = true
        let retryFixture = try makeFixture(name: "first-write-retry")
        defer { retryFixture.cleanup() }
        let retryStore = FitnessTrainingStore(
            persistenceURL: retryFixture.url,
            fileManager: retryFixture.fileManager,
            clock: { clock.now },
            beforeReplace: {
                if faults.failBeforeReplace {
                    faults.failBeforeReplace = false
                    throw TrainingStoreError.persistenceFailed
                }
            }
        )
        do {
            _ = try await retryStore.begin(
                title: "First attempt",
                mutationID: UUID(uuidString: "8b000000-0000-0000-0000-000000000001")!
            )
            XCTFail("The injected first write must fail")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .persistenceFailed)
        }
        let failureState = await retryStore.loadFailureState()
        XCTAssertNil(failureState)
        let retry = try await retryStore.begin(
            title: "Retry",
            mutationID: UUID(uuidString: "8b000000-0000-0000-0000-000000000002")!
        )
        XCTAssertEqual(retry.outcome, .saved)
    }

    func testOrdinaryReadsFailClosedAfterVerifiedGenerationIsReplacedWithCorruptBytes() async throws {
        let fixture = try makeFixture(name: "ordinary-read-integrity")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let mutationID = UUID(uuidString: "8c000000-0000-0000-0000-000000000001")!
        let receipt = try await store.begin(title: "Retained", mutationID: mutationID)
        let sessionID = try XCTUnwrap(receipt.recordID)
        _ = try await store.allSessions()
        let currentSnapshot = try await store.snapshot()
        XCTAssertEqual(currentSnapshot.integrity, .verified)

        try Data("{\"schemaVersion\":2,\"sessions\":".utf8).write(to: fixture.url)

        do {
            _ = try await store.allSessions()
            XCTFail("allSessions must not expose retained cached data as current")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable) }
        do {
            _ = try await store.session(id: sessionID)
            XCTFail("session must not expose retained cached data as current")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable) }
        do {
            _ = try await store.activeSession()
            XCTFail("activeSession must not expose retained cached data as current")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable) }
        do {
            _ = try await store.allHistory()
            XCTFail("history must not expose retained cached data as current")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable) }
        do {
            _ = try await store.receipt(for: mutationID)
            XCTFail("receipt lookup must not expose retained cached data as current")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable) }

        let diagnostic = try await store.snapshot()
        XCTAssertEqual(diagnostic.integrity, .unavailable)
        XCTAssertEqual(diagnostic.freshness, .stale)
    }

    func testSnapshotReportsGenerationAndStaleIntegrityAfterExternalReadFailure() async throws {
        let fixture = try makeFixture(name: "snapshot-integrity")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        _ = try await store.begin(title: "Snapshot", mutationID: UUID(uuidString: "89000000-0000-0000-0000-000000000001")!)
        let current = try await store.snapshot()
        XCTAssertEqual(current.integrity, .verified)
        XCTAssertEqual(current.freshness, .current)
        XCTAssertEqual(current.sessions.count, 1)
        XCTAssertEqual(current.generation?.count, 64)

        let durable = try Data(contentsOf: fixture.url)
        try Data("{\"schemaVersion\":1".utf8).write(to: fixture.url)
        let stale = try await store.snapshot()
        XCTAssertEqual(stale.sessions, current.sessions)
        XCTAssertEqual(stale.generation, current.generation)
        XCTAssertEqual(stale.integrity, .unavailable)
        XCTAssertEqual(stale.freshness, .stale)

        try durable.write(to: fixture.url)
        _ = try await store.load()
        let recovered = try await store.snapshot()
        XCTAssertEqual(recovered.integrity, .verified)
        XCTAssertEqual(recovered.freshness, .current)
        XCTAssertEqual(recovered.generation, current.generation)
    }

    func testUncertainWriteBlocksUntilExplicitReloadAndRecovery() async throws {
        let fixture = try makeFixture(name: "uncertain-write")
        defer { fixture.cleanup() }
        let faults = PersistenceFaults()
        let store = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { self.base },
            afterReplace: {
                if faults.failAfterReplace {
                    faults.failAfterReplace = false
                    throw TrainingStoreError.readbackValidationFailed
                }
            },
            beforeRestore: {
                if faults.failRestore { throw TrainingStoreError.persistenceFailed }
            }
        )

        do {
            _ = try await store.begin(
                title: "Uncertain",
                mutationID: UUID(uuidString: "82000000-0000-0000-0000-000000000001")!
            )
            XCTFail("An unverifiable rollback must fail closed")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable)
        }
        let failureState = await store.loadFailureState()
        XCTAssertEqual(failureState, .integrityUnavailable)
        do {
            _ = try await store.begin(
                title: "Blocked until reload",
                mutationID: UUID(uuidString: "82000000-0000-0000-0000-000000000002")!
            )
            XCTFail("Writes remain blocked while integrity is unresolved")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable)
        }
        do {
            try await store.clearReceiptJournalAfterExport()
            XCTFail("Receipt compaction must require explicit recovery after an uncertain write")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable)
        }

        faults.failRestore = false
        _ = try await store.load()
        let recoveredFailureState = await store.loadFailureState()
        XCTAssertNil(recoveredFailureState)
        let recovered = try await store.allSessions()
        XCTAssertEqual(recovered.map(\.title), ["Uncertain"])
    }

    func testLinkAndUnlinkAreRevisionedIdempotentAndOneToOne() async throws {
        let fixture = try makeFixture(name: "links")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let firstBegin = try await store.begin(
            title: "First local session",
            mutationID: UUID(uuidString: "8a000000-0000-0000-0000-000000000001")!
        )
        let firstID = try XCTUnwrap(firstBegin.recordID)
        let firstOptional = try await store.session(id: firstID)
        let first = try XCTUnwrap(firstOptional)
        let importedKey = "sync_identifier:zepp-workout-1"
        let linkID = UUID(uuidString: "8a000000-0000-0000-0000-000000000002")!
        let linked = try await store.link(
            sessionID: first.id,
            importedRecordKey: importedKey,
            expectedRevision: first.revision,
            mutationID: linkID
        )
        XCTAssertEqual(linked.outcome, .saved)
        XCTAssertEqual(linked.revision, 1)
        let linkRetry = try await store.link(
            sessionID: first.id,
            importedRecordKey: importedKey,
            expectedRevision: first.revision,
            mutationID: linkID
        )
        XCTAssertEqual(linkRetry, linked)
        do {
            _ = try await store.link(
                sessionID: first.id,
                importedRecordKey: "sync_identifier:another",
                expectedRevision: first.revision,
                mutationID: linkID
            )
            XCTFail("A reused link mutation ID must reject an altered key")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .mutationIDReuse)
        }

        let discarded = try await store.discard(
            id: first.id,
            expectedRevision: 1,
            mutationID: UUID(uuidString: "8a000000-0000-0000-0000-000000000003")!
        )
        XCTAssertEqual(discarded.revision, 2)
        let secondBegin = try await store.begin(
            title: "Second local session",
            mutationID: UUID(uuidString: "8a000000-0000-0000-0000-000000000004")!
        )
        let secondID = try XCTUnwrap(secondBegin.recordID)
        let secondOptional = try await store.session(id: secondID)
        let second = try XCTUnwrap(secondOptional)
        let collision = try await store.link(
            sessionID: second.id,
            importedRecordKey: importedKey,
            expectedRevision: second.revision,
            mutationID: UUID(uuidString: "8a000000-0000-0000-0000-000000000005")!
        )
        XCTAssertEqual(collision.outcome, .conflict)
        XCTAssertEqual(collision.currentSession?.id, first.id)

        let unlinkID = UUID(uuidString: "8a000000-0000-0000-0000-000000000006")!
        let unlinked = try await store.unlink(
            sessionID: first.id,
            importedRecordKey: importedKey,
            expectedRevision: 2,
            mutationID: unlinkID
        )
        XCTAssertEqual(unlinked.outcome, .saved)
        XCTAssertEqual(unlinked.revision, 3)
        let unlinkRetry = try await store.unlink(
            sessionID: first.id,
            importedRecordKey: importedKey,
            expectedRevision: 2,
            mutationID: unlinkID
        )
        XCTAssertEqual(unlinkRetry, unlinked)

        let linkedSecond = try await store.link(
            sessionID: second.id,
            importedRecordKey: importedKey,
            expectedRevision: second.revision,
            mutationID: UUID(uuidString: "8a000000-0000-0000-0000-000000000007")!
        )
        XCTAssertEqual(linkedSecond.outcome, .saved)
        let firstAfter = try await store.session(id: first.id)
        let secondAfter = try await store.session(id: second.id)
        XCTAssertNil(firstAfter?.importedRecordKey)
        XCTAssertEqual(secondAfter?.importedRecordKey, importedKey)
    }

    func testClearReceiptJournalRetiresMutationIDsAcrossRestart() async throws {
        let fixture = try makeFixture(name: "retired-receipts")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let mutationID = UUID(uuidString: "83000000-0000-0000-0000-000000000001")!
        _ = try await store.begin(title: "Retired", mutationID: mutationID)
        try await store.clearReceiptJournalAfterExport()

        let envelope = try decodeEnvelope(try await store.export())
        XCTAssertTrue(envelope.receipts.isEmpty)
        XCTAssertEqual(envelope.retiredMutationIDs, [TrainingRecordID(uuid: mutationID)])

        let restarted = makeStore(fixture, clock: clock)
        _ = try await restarted.load()
        do {
            _ = try await restarted.begin(title: "Replay", mutationID: mutationID)
            XCTFail("Retired mutation IDs must remain rejected after restart")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .mutationIDRetired)
        }
    }

    func testFailedPrePublishWritePreservesExistingBytes() async throws {
        let fixture = try makeFixture(name: "prepublish-failure")
        defer { fixture.cleanup() }
        let faults = PersistenceFaults()
        let store = FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { self.base },
            beforeReplace: {
                if faults.failBeforeReplace { throw TrainingStoreError.persistenceFailed }
            }
        )
        _ = try await store.begin(
            title: "Durable",
            mutationID: UUID(uuidString: "84000000-0000-0000-0000-000000000001")!
        )
        let before = try Data(contentsOf: fixture.url)
        let optionalActive = try await store.activeSession()
        let active = try XCTUnwrap(optionalActive)
        faults.failBeforeReplace = true
        do {
            _ = try await store.discard(
                id: active.id,
                expectedRevision: active.revision,
                mutationID: UUID(uuidString: "84000000-0000-0000-0000-000000000002")!
            )
            XCTFail("Injected pre-publish failure must surface")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .persistenceFailed)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.url), before)
        let remainingSessionCount = try await store.allSessions().count
        XCTAssertEqual(remainingSessionCount, 1)
    }

    func testCorruptUnsupportedAndOversizedFilesArePreservedWithoutEmptyFallback() async throws {
        let fileManager = FileManager.default
        let corruptFixture = try makeFixture(name: "corrupt")
        defer { corruptFixture.cleanup() }
        let corrupt = Data("{\"schemaVersion\":1,\"sessions\":".utf8)
        try corrupt.write(to: corruptFixture.url)
        let corruptStore = FitnessTrainingStore(
            persistenceURL: corruptFixture.url,
            fileManager: fileManager,
            clock: { self.base }
        )
        do {
            _ = try await corruptStore.load()
            XCTFail("Corrupt data must be surfaced")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .corruptLedger)
        }
        let corruptExport = try await corruptStore.export()
        XCTAssertEqual(corruptExport, corrupt)
        do {
            _ = try await corruptStore.allSessions()
            XCTFail("A quarantined ledger must not become an empty success")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable)
        }

        let unsupportedFixture = try makeFixture(name: "unsupported")
        defer { unsupportedFixture.cleanup() }
        let unsupported = Data("{\"schemaVersion\":99,\"sessions\":[],\"receipts\":[],\"queuedMutations\":[]}".utf8)
        try unsupported.write(to: unsupportedFixture.url)
        let unsupportedStore = FitnessTrainingStore(
            persistenceURL: unsupportedFixture.url,
            fileManager: fileManager,
            clock: { self.base }
        )
        do {
            _ = try await unsupportedStore.load()
            XCTFail("Unsupported schema must be surfaced")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .unsupportedSchema(99))
        }
        let unsupportedExport = try await unsupportedStore.export()
        XCTAssertEqual(unsupportedExport, unsupported)

        let oversizedFixture = try makeFixture(name: "oversized")
        defer { oversizedFixture.cleanup() }
        let oversized = Data(repeating: 0x7B, count: TrainingStoreLimits.maximumLedgerBytes + 1)
        try oversized.write(to: oversizedFixture.url)
        let oversizedStore = FitnessTrainingStore(
            persistenceURL: oversizedFixture.url,
            fileManager: fileManager,
            clock: { self.base }
        )
        do {
            _ = try await oversizedStore.load()
            XCTFail("Oversized data must be surfaced")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .ledgerTooLarge)
        }
        do {
            _ = try await oversizedStore.export()
            XCTFail("Data export must refuse an oversized ledger")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .ledgerTooLarge) }
    }

    func testOversizedRecoveryExportStreamsSparseFileAndRejectsSymlinkSource() async throws {
        let fixture = try makeFixture(name: "oversized-stream")
        defer { fixture.cleanup() }
        try Data().write(to: fixture.url)
        let writer = try FileHandle(forWritingTo: fixture.url)
        try writer.seek(toOffset: UInt64(TrainingStoreLimits.maximumLedgerBytes))
        try writer.write(contentsOf: Data([0x7B]))
        try writer.close()

        let store = makeStore(fixture, clock: TestClock(base))
        do {
            _ = try await store.load()
            XCTFail("Oversized data must be surfaced")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .ledgerTooLarge) }
        do {
            _ = try await store.export()
            XCTFail("Data export must refuse an oversized sparse ledger")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .ledgerTooLarge) }

        let destination = fixture.directory.appendingPathComponent("recovery.json")
        try await store.export(to: destination)
        let attributes = try fixture.fileManager.attributesOfItem(atPath: destination.path)
        XCTAssertEqual((attributes[.size] as? NSNumber)?.intValue, TrainingStoreLimits.maximumLedgerBytes + 1)

        let symlinkTarget = fixture.directory.appendingPathComponent("symlink-target.json")
        try Data("{}".utf8).write(to: symlinkTarget)
        let symlink = fixture.directory.appendingPathComponent("symlink-ledger.json")
        try fixture.fileManager.createSymbolicLink(at: symlink, withDestinationURL: symlinkTarget)
        let symlinkStore = FitnessTrainingStore(
            persistenceURL: symlink,
            fileManager: fixture.fileManager,
            clock: { self.base }
        )
        do {
            _ = try await symlinkStore.load()
            XCTFail("A symlink ledger must be rejected")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .unreadableLedger) }
        do {
            try await symlinkStore.export(to: fixture.directory.appendingPathComponent("symlink-recovery.json"))
            XCTFail("Recovery must refuse a symlink source")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .unreadableLedger) }
    }

    func testUUIDAliasExpansionCannotBeLinkedToTwoLocalSessionsOrAcceptedFromDuplicateLedger() async throws {
        let fixture = try makeFixture(name: "alias-links")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let uuidA = "00000000-0000-0000-0000-000000000101"
        let uuidB = "00000000-0000-0000-0000-000000000102"
        let key = "uuid:\(uuidA)"
        let expandedKey = "uuid:\(uuidA),\(uuidB)"
        let firstBegin = try await store.begin(
            title: "First",
            mutationID: UUID(uuidString: "8d000000-0000-0000-0000-000000000001")!
        )
        let firstID = try XCTUnwrap(firstBegin.recordID)
        let firstOptional = try await store.session(id: firstID)
        let first = try XCTUnwrap(firstOptional)
        _ = try await store.link(
            sessionID: first.id,
            importedRecordKey: key,
            expectedRevision: first.revision,
            mutationID: UUID(uuidString: "8d000000-0000-0000-0000-000000000002")!
        )
        let linkedOptional = try await store.session(id: first.id)
        let linked = try XCTUnwrap(linkedOptional)
        let duplicate = try await store.link(
            sessionID: linked.id,
            importedRecordKey: expandedKey,
            expectedRevision: linked.revision,
            mutationID: UUID(uuidString: "8d000000-0000-0000-0000-000000000003")!
        )
        XCTAssertEqual(duplicate.outcome, .saved)
        XCTAssertEqual(duplicate.revision, 2)
        let afterDuplicateOptional = try await store.session(id: first.id)
        let afterDuplicate = try XCTUnwrap(afterDuplicateOptional)
        XCTAssertEqual(afterDuplicate.importedRecordKey, expandedKey)
        XCTAssertEqual(duplicate.revision, afterDuplicate.revision)

        let restarted = makeStore(fixture, clock: clock)
        _ = try await restarted.load()
        let restartedLinkedOptional = try await restarted.session(id: first.id)
        let restartedLinked = try XCTUnwrap(restartedLinkedOptional)
        XCTAssertEqual(restartedLinked.importedRecordKey, expandedKey)

        _ = try await store.discard(
            id: first.id,
            expectedRevision: afterDuplicate.revision,
            mutationID: UUID(uuidString: "8d000000-0000-0000-0000-000000000004")!
        )
        let secondBegin = try await store.begin(
            title: "Second",
            mutationID: UUID(uuidString: "8d000000-0000-0000-0000-000000000005")!
        )
        let secondID = try XCTUnwrap(secondBegin.recordID)
        let secondOptional = try await store.session(id: secondID)
        let second = try XCTUnwrap(secondOptional)
        let collision = try await store.link(
            sessionID: second.id,
            importedRecordKey: expandedKey,
            expectedRevision: second.revision,
            mutationID: UUID(uuidString: "8d000000-0000-0000-0000-000000000006")!
        )
        XCTAssertEqual(collision.outcome, .conflict)

        let duplicateOne = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "8d000000-0000-0000-0000-000000000101")!),
            title: "Duplicate one",
            createdAt: base,
            updatedAt: base,
            startedAt: base,
            status: .discarded,
            importedRecordKey: key,
            now: base
        )
        let duplicateTwo = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "8d000000-0000-0000-0000-000000000102")!),
            title: "Duplicate two",
            createdAt: base,
            updatedAt: base,
            startedAt: base,
            status: .discarded,
            importedRecordKey: expandedKey,
            now: base
        )
        let envelope = TrainingLedgerEnvelope(sessions: [duplicateOne, duplicateTwo])
        try TrainingDateCoding.makeEncoder().encode(envelope).write(to: fixture.url)
        do {
            _ = try await makeStore(fixture, clock: clock).load()
            XCTFail("A persisted alias collision must be rejected")
        } catch { XCTAssertEqual(error as? TrainingStoreError, .corruptLedger) }
    }

    func testCanonicalUUIDAndSyncAliasesRemainOneOwnerAcrossRestart() async throws {
        let fixture = try makeFixture(name: "canonical-alias-links")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let uuidA = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
        let uuidB = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
        let identity = try TrainingImportedWorkoutIdentity(
            uuid: uuidA,
            syncIdentifier: "zepp-canonical-201",
            aliases: [uuidB],
            revision: .syncVersion(3)
        )
        let firstBegin = try await store.begin(
            title: "Canonical first",
            mutationID: UUID(uuidString: "8e000000-0000-0000-0000-000000000001")!
        )
        let firstID = try XCTUnwrap(firstBegin.recordID)
        let firstOptional = try await store.session(id: firstID)
        let first = try XCTUnwrap(firstOptional)
        let firstLink = try await store.link(
            sessionID: first.id,
            importedRecordKey: "uuid:\(uuidA.uuidString.lowercased())",
            expectedRevision: first.revision,
            mutationID: UUID(uuidString: "8e000000-0000-0000-0000-000000000002")!
        )
        XCTAssertEqual(firstLink.outcome, .saved)

        let linkedOptional = try await store.session(id: first.id)
        let linked = try XCTUnwrap(linkedOptional)
        let expanded = try await store.link(
            sessionID: linked.id,
            importedRecordKey: identity.stableKey,
            expectedRevision: linked.revision,
            mutationID: UUID(uuidString: "8e000000-0000-0000-0000-000000000003")!
        )
        XCTAssertEqual(expanded.outcome, .saved)
        XCTAssertEqual(expanded.revision, 2)
        let expandedSessionOptional = try await store.session(id: first.id)
        let expandedSession = try XCTUnwrap(expandedSessionOptional)
        XCTAssertEqual(expandedSession.importedRecordKey, identity.stableKey)
        XCTAssertEqual(expanded.revision, expandedSession.revision)

        let restarted = makeStore(fixture, clock: clock)
        _ = try await restarted.load()
        let restartedSession = try await restarted.session(id: first.id)
        XCTAssertEqual(restartedSession?.importedRecordKey, identity.stableKey)

        _ = try await store.discard(
            id: first.id,
            expectedRevision: expandedSession.revision,
            mutationID: UUID(uuidString: "8e000000-0000-0000-0000-000000000004")!
        )
        let secondBegin = try await store.begin(
            title: "Canonical second",
            mutationID: UUID(uuidString: "8e000000-0000-0000-0000-000000000005")!
        )
        let secondID = try XCTUnwrap(secondBegin.recordID)
        let secondOptional = try await store.session(id: secondID)
        let second = try XCTUnwrap(secondOptional)
        let collision = try await store.link(
            sessionID: second.id,
            importedRecordKey: "sync_identifier:zepp-canonical-201",
            expectedRevision: second.revision,
            mutationID: UUID(uuidString: "8e000000-0000-0000-0000-000000000006")!
        )
        XCTAssertEqual(collision.outcome, .conflict)
    }

    func testConflictingSyncAliasesProduceAConflictWithoutDroppingTheExistingLink() async throws {
        let fixture = try makeFixture(name: "conflicting-sync-aliases")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000301")!
        let firstIdentity = try TrainingImportedWorkoutIdentity(
            uuid: uuid,
            syncIdentifier: "provider-revision-a",
            revision: .syncVersion(1)
        )
        let conflictingIdentity = try TrainingImportedWorkoutIdentity(
            uuid: uuid,
            syncIdentifier: "provider-revision-b",
            revision: .syncVersion(2)
        )
        let begin = try await store.begin(
            title: "Conflict target",
            mutationID: UUID(uuidString: "8f000000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(begin.recordID)
        let optionalActive = try await store.session(id: recordID)
        let active = try XCTUnwrap(optionalActive)
        let firstLink = try await store.link(
            sessionID: active.id,
            importedRecordKey: firstIdentity.stableKey,
            expectedRevision: active.revision,
            mutationID: UUID(uuidString: "8f000000-0000-0000-0000-000000000002")!
        )
        XCTAssertEqual(firstLink.outcome, .saved)

        let optionalLinked = try await store.session(id: recordID)
        let linked = try XCTUnwrap(optionalLinked)
        let conflict = try await store.link(
            sessionID: linked.id,
            importedRecordKey: conflictingIdentity.stableKey,
            expectedRevision: linked.revision,
            mutationID: UUID(uuidString: "8f000000-0000-0000-0000-000000000003")!
        )

        XCTAssertEqual(conflict.outcome, .conflict)
        let optionalPreserved = try await store.session(id: recordID)
        let preserved = try XCTUnwrap(optionalPreserved)
        XCTAssertEqual(preserved.importedRecordKey, firstIdentity.stableKey)
        XCTAssertEqual(preserved.revision, linked.revision)
    }

    func testFailedAtomicWriteDoesNotPublishNewSession() async throws {
        let fixture = try makeFixture(name: "write-failure")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        _ = try await store.begin(
            title: "Durable",
            mutationID: UUID(uuidString: "60000000-0000-0000-0000-000000000001")!
        )
        let before = try await store.allSessions()

        try fixture.fileManager.removeItem(at: fixture.url)
        try fixture.fileManager.createDirectory(at: fixture.url, withIntermediateDirectories: false)
        do {
            _ = try await store.begin(
                title: "Should not publish",
                mutationID: UUID(uuidString: "60000000-0000-0000-0000-000000000002")!
            )
            XCTFail("Writing to a directory should fail")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .unreadableLedger)
        }
        do {
            _ = try await store.allSessions()
            XCTFail("Ordinary reads must fail closed after the durable path becomes unreadable")
        } catch {
            XCTAssertEqual(error as? TrainingStoreError, .integrityUnavailable)
        }
        let diagnostic = try await store.snapshot()
        XCTAssertEqual(diagnostic.sessions, before)
        XCTAssertEqual(diagnostic.integrity, .unavailable)
        XCTAssertEqual(diagnostic.freshness, .stale)
    }

    func testDeleteIsExplicitAndReceiptRetryDoesNotResurrectRecord() async throws {
        let fixture = try makeFixture(name: "delete")
        defer { fixture.cleanup() }
        let clock = TestClock(base)
        let store = makeStore(fixture, clock: clock)
        let begin = try await store.begin(
            title: "Delete me",
            mutationID: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
        )
        let recordID = try XCTUnwrap(begin.recordID)
        let optionalSession = try await store.session(id: recordID)
        let session = try XCTUnwrap(optionalSession)
        let deleteID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
        let receipt = try await store.delete(
            id: session.id,
            expectedRevision: session.revision,
            mutationID: deleteID
        )
        XCTAssertEqual(receipt.outcome, .saved)
        let afterDelete = try await store.session(id: session.id)
        XCTAssertNil(afterDelete)

        let retry = try await store.delete(
            id: session.id,
            expectedRevision: session.revision,
            mutationID: deleteID
        )
        XCTAssertEqual(retry, receipt)
        let afterRetry = try await store.session(id: session.id)
        XCTAssertNil(afterRetry)
    }

    private func makeStore(_ fixture: Fixture, clock: TestClock) -> FitnessTrainingStore {
        FitnessTrainingStore(
            persistenceURL: fixture.url,
            fileManager: fixture.fileManager,
            clock: { clock.now }
        )
    }

    private func emptyReplicationEnvelopeData() throws -> Data {
        let binding = makeReplicationBinding()
        let state = TrainingReplicationState(
            binding: binding,
            bootstrapMap: [],
            pendingIntents: [],
            entityKeys: [],
            ledger: TrainingReplicationState.emptyLedger(for: binding)
        )
        return try TrainingDateCoding.makeEncoder().encode(TrainingLedgerEnvelope(replication: state))
    }

    private func assertReplicationInvalid(
        _ state: TrainingReplicationState,
        retainedSessionIDs: Set<TrainingRecordID> = Set(),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try state.validate(
                retainedSessionIDs: retainedSessionIDs,
                receiptMutationIDs: [],
                retiredMutationIDs: []
            ),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? TrainingStoreError, .corruptLedger, file: file, line: line)
        }
    }

    private func replacingLedger(
        _ ledger: SyncAdapterEnvelope,
        nextSequence: String? = nil,
        inbox: [SyncOperation]? = nil,
        received: SyncFrontier? = nil
    ) -> SyncAdapterEnvelope {
        SyncAdapterEnvelope(
            schemaVersion: ledger.schemaVersion,
            storeID: ledger.storeID,
            datasetID: ledger.datasetID,
            localOriginID: ledger.localOriginID,
            epoch: ledger.epoch,
            nextSequence: nextSequence ?? ledger.nextSequence,
            received: received ?? ledger.received,
            applied: ledger.applied,
            outbox: ledger.outbox,
            inbox: inbox ?? ledger.inbox,
            entities: ledger.entities,
            conflicts: ledger.conflicts,
            acknowledgements: ledger.acknowledgements,
            receivedAcknowledgements: ledger.receivedAcknowledgements,
            receipts: ledger.receipts,
            receiptLedgerVersion: ledger.receiptLedgerVersion
        )
    }

    private func makeReplicationBinding(epoch: String = "1") -> TrainingSyncBinding {
        TrainingSyncBinding(
            datasetID: "90000000-0000-0000-0000-000000000001",
            epoch: epoch,
            storeID: "90000000-0000-0000-0000-000000000002",
            localOriginID: "90000000-0000-0000-0000-000000000003",
            keyID: String(repeating: "a", count: 64)
        )
    }

    private func replacingTitle(_ session: TrainingSession, title: String, now: Date) throws -> TrainingSession {
        try TrainingSession(
            id: session.id,
            revision: session.revision,
            activityKind: session.activityKind,
            title: title,
            createdAt: session.createdAt,
            updatedAt: now,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            timeZoneIdentifier: session.timeZoneIdentifier,
            templateID: session.templateID,
            templateSnapshot: session.templateSnapshot,
            pauses: session.pauses,
            status: session.status,
            exercises: session.exercises,
            notes: session.notes,
            importedRecordKey: session.importedRecordKey,
            now: now
        )
    }

    private func activeDraft(from session: TrainingSession, now: Date) throws -> TrainingSession {
        try TrainingSession(
            id: session.id,
            revision: session.revision,
            activityKind: session.activityKind,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: now,
            startedAt: session.startedAt,
            endedAt: nil,
            timeZoneIdentifier: session.timeZoneIdentifier,
            templateID: session.templateID,
            templateSnapshot: session.templateSnapshot,
            pauses: session.pauses,
            status: .active,
            exercises: session.exercises,
            notes: session.notes,
            importedRecordKey: session.importedRecordKey,
            now: now
        )
    }

    private func completedDraft(
        from active: TrainingSession,
        now: Date,
        title: String,
        sequence: Int
    ) throws -> TrainingSession {
        let set = try TrainingSetLog(
            actualRepetitions: 5 + sequence,
            actualLoadKilograms: 20 + Double(sequence),
            isCompleted: true,
            completedAt: now.addingTimeInterval(-30),
            now: now
        )
        let exercise = try TrainingExerciseLog(
            name: "Row \(sequence)",
            muscleGroup: .back,
            sets: [set]
        )
        return try TrainingSession(
            id: active.id,
            revision: active.revision,
            activityKind: active.activityKind,
            title: title,
            createdAt: active.createdAt,
            updatedAt: now,
            startedAt: active.startedAt,
            endedAt: now,
            timeZoneIdentifier: active.timeZoneIdentifier,
            templateID: active.templateID,
            templateSnapshot: active.templateSnapshot,
            pauses: active.pauses,
            status: .completed,
            exercises: [exercise],
            notes: active.notes,
            importedRecordKey: active.importedRecordKey,
            now: now
        )
    }

    private func decodeEnvelope(_ data: Data) throws -> TrainingLedgerEnvelope {
        try TrainingDateCoding.makeDecoder(now: base.addingTimeInterval(10_000))
            .decode(TrainingLedgerEnvelope.self, from: data)
    }

    private struct LegacyEnvelopeFixture: Encodable {
        let schemaVersion = 1
        let sessions: [TrainingSession]
        let receipts: [TrainingReceiptJournalEntry] = []
        let queuedMutations: [TrainingMutation] = []
    }

    private struct LegacyReceiptEntryFixture: Encodable {
        let mutationID: TrainingRecordID
        let payloadFingerprint: String
        let receipt: TrainingCommitReceipt
    }

    private struct LegacyReceiptEnvelopeFixture: Encodable {
        let schemaVersion = 1
        let sessions: [TrainingSession]
        let receipts: [LegacyReceiptEntryFixture]
        let queuedMutations: [TrainingMutation] = []
    }

    private func makeLegacyEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            let seconds = date.timeIntervalSinceReferenceDate
            let wholeSeconds = seconds.rounded(.towardZero)
            let fractionalDigits = String(format: "%.9f", seconds - wholeSeconds).dropFirst(2)
            let wholeDate = Date(timeIntervalSinceReferenceDate: wholeSeconds)
            let baseString = Date.ISO8601FormatStyle(includingFractionalSeconds: false).format(wholeDate)
            var container = encoder.singleValueContainer()
            try container.encode(baseString.replacingOccurrences(of: "Z", with: ".\(fractionalDigits)Z"))
        }
        return encoder
    }

    private final class PersistenceFaults: @unchecked Sendable {
        var failBeforeReplace = false
        var failAfterReplace = true
        var failRestore = true
    }

    private final class DeterministicBootstrapIDs {
        private let values: [UUID]
        private(set) var generatedCount = 0

        init(_ values: [UUID]) {
            self.values = values
        }

        func next() -> UUID {
            precondition(generatedCount < values.count, "Unexpected bootstrap ID request")
            defer { generatedCount += 1 }
            return values[generatedCount]
        }
    }

    private func makeFixture(name: String) throws -> Fixture {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("lifeos-training-\(name)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return Fixture(
            url: directory.appendingPathComponent("fitness-training-ledger.json"),
            fileManager: fileManager,
            directory: directory
        )
    }

    private final class TestClock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    private struct Fixture {
        let url: URL
        let fileManager: FileManager
        let directory: URL

        func cleanup() {
            try? fileManager.removeItem(at: directory)
        }
    }
}
