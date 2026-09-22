import CryptoKit
import Foundation
import XCTest

@testable import LifeOSMac

final class SyncProtocolTests: XCTestCase {
    private let datasetID = "11111111-1111-4111-8111-111111111111"
    private let storeID = "22222222-2222-4222-8222-222222222222"
    private let originID = "33333333-3333-4333-8333-333333333333"

    func testSyncStoreKindCasesHaveStableOrderRawValuesAndUniqueness() {
        let expectedCases: [SyncStoreKind] = [
            .calendar,
            .financeImports,
            .financeRecurring,
            .financeInvestments,
            .financeBudgets,
            .financeAllocations,
            .financePreferences,
            .training,
            .trainingTemplates,
            .meals,
            .nutritionGoals,
            .supplements,
            .journal,
            .lifestyle,
            .barcodeRecords,
            .vault,
            .tax
        ]
        let expectedRawValues = [
            "calendar",
            "financeImports",
            "financeRecurring",
            "financeInvestments",
            "financeBudgets",
            "financeAllocations",
            "financePreferences",
            "training",
            "trainingTemplates",
            "meals",
            "nutritionGoals",
            "supplements",
            "journal",
            "lifestyle",
            "barcodeRecords",
            "vault",
            "tax"
        ]

        XCTAssertEqual(SyncStoreKind.allCases, expectedCases)
        let rawValues = SyncStoreKind.allCases.map(\.rawValue)
        XCTAssertEqual(rawValues, expectedRawValues)
        XCTAssertEqual(Set(rawValues).count, rawValues.count)
    }

    func testSyncStoreKindMapsEveryCaseToItsSyncDomain() {
        let expectedMappings: [(SyncStoreKind, SyncDomain)] = [
            (.calendar, .calendar),
            (.financeImports, .finance),
            (.financeRecurring, .finance),
            (.financeInvestments, .finance),
            (.financeBudgets, .finance),
            (.financeAllocations, .finance),
            (.financePreferences, .finance),
            (.training, .fitness),
            (.trainingTemplates, .fitness),
            (.meals, .fitness),
            (.nutritionGoals, .fitness),
            (.supplements, .fitness),
            (.journal, .fitness),
            (.lifestyle, .fitness),
            (.barcodeRecords, .fitness),
            (.vault, .planning),
            (.tax, .tax)
        ]

        XCTAssertEqual(expectedMappings.count, SyncStoreKind.allCases.count)
        for (kind, expectedDomain) in expectedMappings {
            XCTAssertEqual(kind.domain, expectedDomain, "Unexpected domain for \(kind.rawValue)")
        }
    }

    func testSyncStoreKindCodableRoundTripsAndRejectsUnknownRawValues() throws {
        for kind in SyncStoreKind.allCases {
            let encoded = try JSONEncoder().encode(kind)
            XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "\"\(kind.rawValue)\"")
            XCTAssertEqual(try JSONDecoder().decode(SyncStoreKind.self, from: encoded), kind)
        }

        for rawValue in [
            "unknown",
            "Calendar",
            "11111111-1111-4111-8111-111111111111"
        ] {
            let encoded = try JSONEncoder().encode(rawValue)
            XCTAssertThrowsError(try JSONDecoder().decode(SyncStoreKind.self, from: encoded), rawValue)
        }
    }

    func testSyncOperationSignedWireEncodingRemainsStable() throws {
        let keyID = String(repeating: "a", count: 64)
        let signature = String(repeating: "A", count: 86)
        let entityID = String(repeating: "b", count: 64)
        let unsigned = try makeOperation(keyID: keyID)
        let fixture = SyncOperation(
            schemaVersion: unsigned.schemaVersion,
            datasetID: unsigned.datasetID,
            epoch: unsigned.epoch,
            storeID: unsigned.storeID,
            domain: unsigned.domain,
            originID: unsigned.originID,
            keyID: unsigned.keyID,
            sequence: unsigned.sequence,
            mutationID: unsigned.mutationID,
            entityID: unsigned.entityID,
            parents: unsigned.parents,
            baseHash: unsigned.baseHash,
            kind: unsigned.kind,
            payload: unsigned.payload,
            signature: signature
        )
        let expectedJSON = #"{"datasetID":"\#(datasetID)","domain":"calendar","entityID":"\#(entityID)","epoch":"1","keyID":"\#(keyID)","kind":"bootstrap","mutationID":"44444444-4444-4444-8444-444444444444","originID":"\#(originID)","parents":[],"payload":{"byteCount":0,"hash":"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855","inline":"","schemaVersion":1},"schemaVersion":1,"sequence":"9007199254740993","signature":"\#(signature)","storeID":"\#(storeID)"}"#

        XCTAssertEqual(try SyncWireCodec.encodeOperation(fixture), Data(expectedJSON.utf8))
    }

    func testOperationCanonicalEncodingPreservesLargeDecimalSequence() throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsigned = try makeOperation(keyID: SyncWireCodec.sha256(key.publicKey.rawRepresentation))
        let signed = try SyncWireCodec.signOperation(unsigned, using: key)
        try SyncWireCodec.verifyOperation(signed, publicKey: key.publicKey)

        let encoded = try SyncWireCodec.encodeOperation(signed)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).hasPrefix("{\"datasetID\""))
        let decoded = try SyncWireCodec.decodeOperation(encoded)
        XCTAssertEqual(decoded.sequence, "9007199254740993")
        XCTAssertEqual(try SyncWireCodec.operationHash(for: signed), try SyncWireCodec.operationHash(for: decoded))
    }

    func testCanonicalJSONAcceptsStrictStringFragments() throws {
        let simple = try SyncWireCodec.canonicalJSON("simple")
        XCTAssertEqual(simple, Data(#""simple""#.utf8))

        let escapedValue = "quote \" and slash \\"
        let escaped = try SyncWireCodec.canonicalJSON(escapedValue)
        XCTAssertEqual(try JSONDecoder().decode(String.self, from: escaped), escapedValue)
        XCTAssertEqual(try SyncWireCodec.canonicalizeJSON(escaped), escaped)

        let nfcValue = "é"
        let nfc = try SyncWireCodec.canonicalJSON(nfcValue)
        XCTAssertEqual(nfc, Data(#""é""#.utf8))
        let escapedNFC = Data([0x22, 0x5C, 0x75, 0x30, 0x30, 0x45, 0x39, 0x22])
        XCTAssertEqual(try SyncWireCodec.canonicalizeJSON(escapedNFC), nfc)
        let decomposed = Data([0x22, 0x65, 0xCC, 0x81, 0x22])
        XCTAssertThrowsError(try SyncWireCodec.canonicalizeJSON(decomposed))
        let escapedDecomposed = Data([0x22, 0x65, 0x5C, 0x75, 0x30, 0x33, 0x30, 0x31, 0x22])
        XCTAssertThrowsError(try SyncWireCodec.canonicalizeJSON(escapedDecomposed))
    }

    func testCanonicalJSONRejectsMalformedAndUnsupportedNumericFragments() throws {
        let malformed: [Data] = [
            Data("\"unterminated".utf8),
            Data("\"bad\\q\"".utf8),
            Data("\"\\u12G4\"".utf8),
            Data("\"\n\"".utf8)
        ]
        for fragment in malformed {
            XCTAssertThrowsError(try SyncWireCodec.canonicalizeJSON(fragment))
        }

        for fragment in ["01", "-1", "1.0", "1e3"] {
            XCTAssertThrowsError(try SyncWireCodec.canonicalizeJSON(Data(fragment.utf8)))
        }
    }

    func testBase64URLValidationDecodesURLSafeAlphabet() throws {
        let bytes = Data([0xfb, 0xff, 0xef])
        let encoded = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")

        XCTAssertEqual(encoded, "-__v")
        XCTAssertEqual(try SyncContractValidation.requireBase64URL(encoded), bytes)
    }

    func testAdministrativeAndObservationCountersUseCanonicalDecimalStrings() throws {
        let scope = AdminScope20(
            namespace: "data.restore.v20",
            datasetID: datasetID,
            operationID: "22222222-2222-4222-8222-222222222222",
            fenceID: "33333333-3333-4333-8333-333333333333",
            targetHostID: "44444444-4444-4444-8444-444444444444",
            storeID: .usageLocal
        )
        let put = AdminBlobPut20(
            schemaVersion: 20,
            scope: scope,
            blobHash: String(repeating: "a", count: 64),
            totalBytes: SyncContractConstants.maxAdministrativeSegmentBytes,
            offset: 0,
            chunkHash: String(repeating: "b", count: 64),
            bytesBase64URL: "",
            isFinal: true
        )

        let putBytes = try JSONEncoder().encode(put)
        let putJSON = String(decoding: putBytes, as: UTF8.self)
        XCTAssertTrue(putJSON.contains("\"totalBytes\":\"33554432\""))
        XCTAssertTrue(putJSON.contains("\"offset\":\"0\""))
        let decodedPut = try JSONDecoder().decode(AdminBlobPut20.self, from: putBytes)
        XCTAssertEqual(decodedPut, put)

        let numericTotal = Data(putJSON.replacingOccurrences(of: "\"totalBytes\":\"33554432\"", with: "\"totalBytes\":33554432").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AdminBlobPut20.self, from: numericTotal))
        let wrongStore = Data(putJSON.replacingOccurrences(of: "\"storeID\":\"usageLocal\"", with: "\"storeID\":\"calendar\"").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AdminBlobPut20.self, from: wrongStore))

        let read = AdminBlobRead20(
            schemaVersion: 20,
            scope: scope,
            blobHash: put.blobHash,
            offset: 0,
            limit: UInt32(SyncContractConstants.maxBlobChunkBytes)
        )
        let readJSON = String(decoding: try JSONEncoder().encode(read), as: UTF8.self)
        XCTAssertTrue(readJSON.contains("\"limit\":\"262144\""))
        let numericLimit = Data(readJSON.replacingOccurrences(of: "\"limit\":\"262144\"", with: "\"limit\":262144").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AdminBlobRead20.self, from: numericLimit))

        let access = ObservationAccess20(
            schemaVersion: 20,
            datasetID: datasetID,
            epoch: 1,
            originID: originID,
            originKeyID: String(repeating: "c", count: 64),
            readerKeyIDs: [],
            ownerKeyID: String(repeating: "d", count: 64),
            signature: String(repeating: "A", count: 86)
        )
        let accessJSON = String(decoding: try JSONEncoder().encode(access), as: UTF8.self)
        XCTAssertTrue(accessJSON.contains("\"epoch\":\"1\""))
        let numericEpoch = Data(accessJSON.replacingOccurrences(of: "\"epoch\":\"1\"", with: "\"epoch\":1").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ObservationAccess20.self, from: numericEpoch))
        let zeroEpoch = Data(accessJSON.replacingOccurrences(of: "\"epoch\":\"1\"", with: "\"epoch\":\"0\"").utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(ObservationAccess20.self, from: zeroEpoch))
    }

    func testAdministrativeNumericCapsAreEnforcedAtEncoding() throws {
        let scope = AdminScope20(
            namespace: "data.restore.v20",
            datasetID: datasetID,
            operationID: "22222222-2222-4222-8222-222222222222",
            fenceID: "33333333-3333-4333-8333-333333333333",
            targetHostID: "44444444-4444-4444-8444-444444444444",
            storeID: .clipperLocal
        )
        let oversizedPut = AdminBlobPut20(
            schemaVersion: 20,
            scope: scope,
            blobHash: String(repeating: "a", count: 64),
            totalBytes: SyncContractConstants.maxAdministrativeSegmentBytes + 1,
            offset: 0,
            chunkHash: String(repeating: "b", count: 64),
            bytesBase64URL: "",
            isFinal: true
        )
        XCTAssertThrowsError(try JSONEncoder().encode(oversizedPut))

        let source = RemotePackSource20(
            schemaVersion: 20,
            namespace: "data.restore.v20",
            datasetID: datasetID,
            operationID: "22222222-2222-4222-8222-222222222222",
            fenceID: "33333333-3333-4333-8333-333333333333",
            targetHostID: "44444444-4444-4444-8444-444444444444",
            storeID: .clipperLocal,
            packHash: String(repeating: "a", count: 64),
            sourceHash: String(repeating: "b", count: 64),
            manifestFormat: "packObjectV7",
            manifestHash: String(repeating: "c", count: 64),
            manifestByteCount: SyncContractConstants.maxAdministrativeManifestBytes,
            bundleHash: String(repeating: "d", count: 64),
            byteCount: SyncContractConstants.maxAdministrativeBundleBytes,
            segments: [AdminBlobRef20(index: 0, blobHash: String(repeating: "e", count: 64), byteCount: SyncContractConstants.maxAdministrativeSegmentBytes)]
        )
        let sourceJSON = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        XCTAssertTrue(sourceJSON.contains("\"manifestByteCount\":\"268435456\""))
        XCTAssertTrue(sourceJSON.contains("\"byteCount\":\"536870929\""))
        XCTAssertTrue(sourceJSON.contains("\"byteCount\":\"33554432\""))
    }

    func testDuplicateKeysAndUnknownRootKeysFailBeforeDecode() throws {
        let duplicate = Data(#"{"schemaVersion":1,"schemaVersion":1}"#.utf8)
        XCTAssertThrowsError(try SyncWireCodec.decodeOperation(duplicate))

        var operation = try makeOperation(keyID: String(repeating: "a", count: 64))
        operation = SyncOperation(
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
            payload: operation.payload,
            signature: operation.signature
        )
        let encoded = try SyncWireCodec.canonicalJSON(operation)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unexpected"] = true
        let altered = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try SyncWireCodec.decodeOperation(altered))
    }

    func testFrameSignatureBindsMethodPathAndBodyHash() throws {
        let key = Curve25519.Signing.PrivateKey()
        let body = Data(#"{"ok":true}"#.utf8)
        let unsigned = SyncSignedFrame(
            schemaVersion: 1,
            datasetID: datasetID,
            epoch: "1",
            endpointID: storeID,
            senderID: originID,
            keyID: SyncWireCodec.sha256(key.publicKey.rawRepresentation),
            requestID: "44444444-4444-4444-8444-444444444444",
            nonce: b64(Data(repeating: 7, count: 32)),
            method: "POST",
            path: "/replication/v1/exchange",
            status: 0,
            body: b64(body),
            bodyHash: SyncWireCodec.sha256(body),
            signature: ""
        )
        let signed = try SyncWireCodec.signFrame(unsigned, using: key)
        try SyncWireCodec.verifyFrame(signed, publicKey: key.publicKey)
        var forged = signed
        forged = SyncSignedFrame(
            schemaVersion: forged.schemaVersion,
            datasetID: forged.datasetID,
            epoch: forged.epoch,
            endpointID: forged.endpointID,
            senderID: forged.senderID,
            keyID: forged.keyID,
            requestID: forged.requestID,
            nonce: forged.nonce,
            method: forged.method,
            path: "/replication/v1/ack",
            status: forged.status,
            body: forged.body,
            bodyHash: forged.bodyHash,
            signature: forged.signature
        )
        XCTAssertThrowsError(try SyncWireCodec.verifyFrame(forged, publicKey: key.publicKey))
    }

    func testPayloadBoundsAndFrontierOrderingAreClosed() throws {
        let payload = SyncPayload(
            hash: String(repeating: "a", count: 64),
            byteCount: 0,
            inline: "",
            blobHash: nil
        )
        XCTAssertThrowsError(try SyncWireCodec.validate(payload))
        XCTAssertThrowsError(try SyncWireCodec.validate(SyncFrontier(
            positions: [
                SyncPosition(stream: SyncStream(storeID: storeID, originID: originID), through: "1"),
                SyncPosition(stream: SyncStream(storeID: storeID, originID: originID), through: "2")
            ]
        )))
    }

    private func makeOperation(keyID: String) throws -> SyncOperation {
        let emptyHash = SyncWireCodec.sha256(Data())
        return SyncOperation(
            datasetID: datasetID,
            epoch: "1",
            storeID: storeID,
            domain: .calendar,
            originID: originID,
            keyID: keyID,
            sequence: "9007199254740993",
            mutationID: "44444444-4444-4444-8444-444444444444",
            entityID: String(repeating: "b", count: 64),
            parents: [],
            baseHash: nil,
            kind: .bootstrap,
            payload: SyncPayload(hash: emptyHash, byteCount: 0, inline: "", blobHash: nil),
            signature: ""
        )
    }

    private func b64(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
