import CryptoKit
import Foundation
import XCTest

@testable import LifeOSMac

final class SyncProtocolTests: XCTestCase {
    private let datasetID = "11111111-1111-4111-8111-111111111111"
    private let storeID = "22222222-2222-4222-8222-222222222222"
    private let originID = "33333333-3333-4333-8333-333333333333"

    func testOperationCanonicalEncodingPreservesLargeDecimalSequence() throws {
        let key = Curve25519.Signing.PrivateKey()
        let unsigned = try makeOperation(keyID: SyncWireCodec.sha256(key.publicKey.rawRepresentation))
        let signed = try SyncWireCodec.signOperation(unsigned, using: key)
        try SyncWireCodec.verifyOperation(signed, publicKey: key.publicKey)

        let encoded = try SyncWireCodec.encodeOperation(signed)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).hasPrefix("{\"baseHash\""))
        let decoded = try SyncWireCodec.decodeOperation(encoded)
        XCTAssertEqual(decoded.sequence, "9007199254740993")
        XCTAssertEqual(try SyncWireCodec.operationHash(for: signed), try SyncWireCodec.operationHash(for: decoded))
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
