import Foundation
import XCTest
@testable import LifeOSMac

final class FitnessSyncTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func replacing(_ value: String, _ target: String, with replacement: String) -> String {
        value.replacingOccurrences(of: target, with: replacement)
    }

    private func containsBytes(_ needle: [UInt8], in haystack: Data) -> Bool {
        let bytes = Array(haystack)
        guard !needle.isEmpty, needle.count <= bytes.count else { return false }
        return (0...(bytes.count - needle.count)).contains { offset in
            Array(bytes[offset..<(offset + needle.count)]) == needle
        }
    }

    private func session() throws -> TrainingSession {
        let startedAt = now.addingTimeInterval(-3_600)
        let endedAt = now.addingTimeInterval(-60)
        let set = try TrainingSetLog(
            id: TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!),
            kind: .working,
            targetRepetitions: 8,
            targetLoadKilograms: 20,
            actualRepetitions: 8,
            actualLoadKilograms: 20,
            isCompleted: true,
            completedAt: endedAt,
            now: now
        )
        let exercise = try TrainingExerciseLog(
            id: TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000002")!),
            name: "Bench press",
            muscleGroup: .chest,
            sets: [set],
            notes: "Controlled tempo"
        )
        return try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000003")!),
            revision: 2,
            activityKind: .strength,
            title: "Push day",
            createdAt: startedAt,
            updatedAt: endedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: "Europe/Berlin",
            status: .completed,
            exercises: [exercise],
            notes: "Evening session",
            importedRecordKey: nil,
            now: now
        )
    }

    func testTrainingPayloadRoundTripIsDeterministic() throws {
        let original = try session()
        let first = try FitnessPayloadCodec.encode(original, now: now)
        let second = try FitnessPayloadCodec.encode(original, now: now)

        XCTAssertEqual(first, second)
        XCTAssertEqual(SyncWireCodec.sha256(first), SyncWireCodec.sha256(second))
        guard case .training(let decoded) = try FitnessPayloadCodec.decode(first, now: now) else {
            return XCTFail("expected training payload")
        }
        XCTAssertEqual(decoded.session, original)
    }

    func testTrainingPayloadPreservesFractionalValuesAndNormalizesWireText() throws {
        let startedAt = now.addingTimeInterval(-3_600.25)
        let endedAt = now.addingTimeInterval(-60.125)
        let pause = try TrainingPauseInterval(
            startedAt: now.addingTimeInterval(-2_400.75),
            endedAt: now.addingTimeInterval(-2_300.5),
            now: now
        )
        let templateExercise = try TrainingTemplateExerciseSnapshot(
            id: "bench",
            name: "Cafe\u{301} press",
            muscleGroup: .chest,
            targetSets: 1,
            targetRepetitions: 8,
            targetLoadKilograms: 20.5
        )
        let template = try TrainingTemplateSnapshot(
            templateID: "push-day",
            name: "Cafe\u{301} day",
            exercises: [templateExercise]
        )
        let set = try TrainingSetLog(
            id: TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000011")!),
            kind: .working,
            targetRepetitions: 8,
            targetLoadKilograms: 20.5,
            actualRepetitions: 8,
            actualLoadKilograms: 20.5,
            isCompleted: true,
            completedAt: endedAt,
            now: now
        )
        let exercise = try TrainingExerciseLog(
            id: TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000012")!),
            name: "Cafe\u{301} press",
            muscleGroup: .chest,
            sets: [set],
            notes: "Cafe\u{301} note"
        )
        let original = try TrainingSession(
            id: TrainingRecordID(uuid: UUID(uuidString: "00000000-0000-4000-8000-000000000013")!),
            revision: 3,
            activityKind: .strength,
            title: "Cafe\u{301} session",
            createdAt: startedAt,
            updatedAt: endedAt,
            startedAt: startedAt,
            endedAt: endedAt,
            timeZoneIdentifier: "Europe/Berlin",
            templateID: "push-day",
            templateSnapshot: template,
            pauses: [pause],
            status: .completed,
            exercises: [exercise],
            notes: "Cafe\u{301} notes",
            importedRecordKey: "sync_identifier:zepp-canonical-201",
            now: now
        )

        let encoded = try FitnessPayloadCodec.encode(original, now: now)
        XCTAssertTrue(containsBytes(Array("Café".utf8), in: encoded))
        XCTAssertFalse(containsBytes(Array("Cafe\u{301}".utf8), in: encoded))

        let decoded = try XCTUnwrap(FitnessPayloadCodec.decode(
            encoded,
            now: now
        ).trainingSession)
        XCTAssertEqual(decoded.title, "Café session")
        XCTAssertEqual(decoded.createdAt, startedAt)
        XCTAssertEqual(decoded.updatedAt, endedAt)
        XCTAssertEqual(decoded.startedAt, startedAt)
        XCTAssertEqual(decoded.endedAt, endedAt)
        XCTAssertEqual(decoded.templateSnapshot, original.templateSnapshot)
        XCTAssertEqual(decoded.exercises[0].sets[0].targetLoadKilograms, 20.5)
        XCTAssertEqual(decoded.exercises[0].sets[0].actualLoadKilograms, 20.5)
        XCTAssertEqual(decoded.pauses, original.pauses)
        XCTAssertEqual(decoded.templateID, original.templateID)
        XCTAssertEqual(decoded.importedRecordKey, original.importedRecordKey)
    }

    func testTrainingPayloadRejectsEquivalentAlternateNumericRepresentation() throws {
        let encoded = try FitnessPayloadCodec.encode(try session(), now: now)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let alternate = replacing(text, #""actualLoadKilograms":20,"#, with: #""actualLoadKilograms":20.0,"#)

        XCTAssertNotEqual(Data(alternate.utf8), encoded)
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(Data(alternate.utf8), now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
    }

    func testTrainingPayloadRejectsUnknownRootKeyAndTag() throws {
        let encoded = try FitnessPayloadCodec.encode(try session(), now: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object["unexpected"] = true
        let unknownKey = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(unknownKey, now: now))

        var wrongTag = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        wrongTag["tag"] = "meal"
        let wrongTagData = try JSONSerialization.data(withJSONObject: wrongTag, options: [.sortedKeys])
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(wrongTagData, now: now))

        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        let wrongVersion = replacing(
            encodedText,
            #""schemaVersion":1"#,
            with: #""schemaVersion":2"#
        )
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(Data(wrongVersion.utf8), now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .unsupportedSchema)
        }
    }

    func testTrainingPayloadRejectsNonCanonicalJSON() throws {
        let encoded = try FitnessPayloadCodec.encode(try session(), now: now)
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(encoded + Data([0x20]), now: now))
    }

    func testTrainingPayloadRejectsMalformedNestedValueAndOversizedBytes() throws {
        let encoded = try FitnessPayloadCodec.encode(try session(), now: now)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var value = try XCTUnwrap(object["value"] as? [String: Any])
        value["id"] = "not-a-uuid"
        object["value"] = value
        let malformed = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(malformed, now: now))

        let oversized = Data(repeating: 0x20, count: SyncContractConstants.maxInlinePayloadBytes + 1)
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(oversized, now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .capacity)
        }
    }

    func testTrainingPayloadRejectsBoundedParserAbuse() throws {
        let encoded = try FitnessPayloadCodec.encode(try session(), now: now)
        let encodedText = try XCTUnwrap(String(data: encoded, encoding: .utf8))

        let duplicateKey = replacing(
            encodedText,
            #""tag":"training""#,
            with: #""tag":"training","tag":"training""#
        )
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            Data(duplicateKey.utf8),
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(Data(duplicateKey.utf8), now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let normalizedDuplicate = Data(
            #"{"schemaVersion":1,"tag":"training","value":{},"Cafe\u0301":1,"Café":2}"#.utf8
        )
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            normalizedDuplicate,
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(normalizedDuplicate, now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let depthOverflow = Data(
            (String(repeating: "[", count: 33) + "0" + String(repeating: "]", count: 33)).utf8
        )
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            depthOverflow,
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(depthOverflow, now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let invalidNumberGrammar = Data(
            #"{"schemaVersion":1,"tag":"training","value":{"bad":01}}"#.utf8
        )
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            invalidNumberGrammar,
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(invalidNumberGrammar, now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let nonfiniteNumber = replacing(
            encodedText,
            #""actualLoadKilograms":20,"#,
            with: #""actualLoadKilograms":1e309,"#
        )
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            Data(nonfiniteNumber.utf8),
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(Data(nonfiniteNumber.utf8), now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let negativeLoad = replacing(
            encodedText,
            #""actualLoadKilograms":20,"#,
            with: #""actualLoadKilograms":-1,"#
        )
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(Data(negativeLoad.utf8), now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let malformedEscape = Data(
            #"{"schemaVersion":1,"tag":"training","value":{"bad":"\q"}}"#.utf8
        )
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            malformedEscape,
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(malformedEscape, now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }

        let invalidUTF8 = Data(#"{"schemaVersion":1,"tag":"training","value":{"bad":""# .utf8)
            + Data([0xC3, 0x28])
            + Data(#""}}"# .utf8)
        XCTAssertThrowsError(try FitnessJSONCanonicalizer.canonicalize(
            invalidUTF8,
            maximumBytes: SyncContractConstants.maxInlinePayloadBytes
        )) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
        XCTAssertThrowsError(try FitnessPayloadCodec.decode(invalidUTF8, now: now)) { error in
            XCTAssertEqual(error as? SyncFailure, .invalidInput)
        }
    }
}
