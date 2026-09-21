# R8 receipt identity and retry contract

Planning-only. Recovery import and data management share one receipt protocol, but retain separate log files and
operation domains. A receipt is an idempotency identity, not a UI timestamp.

## Types and identity

```swift
public enum LifeOSReceiptDomain: String, Codable, Sendable { case recoveryImportV4, dataManagementV4 }
public enum LifeOSReceiptState: String, Codable, Sendable {
 case prepared, mapped, projecting, streaming, interrupted, failed, committed, rejected
}
public enum LifeOSReceiptErrorCode: String, Codable, Sendable {
 case invalidArchive, receiptIdentityConflict, gatewayUnavailable, cancelled, diskFull, corruptTarget
 case verificationFailed, staleTarget, historyPruned, operationReuse
}
public struct LifeOSReceiptTransitionV4: Codable, Equatable, Sendable {
 public let receiptID: UUID; public let operationID: UUID; public let domain: LifeOSReceiptDomain
 public let artifactID: UUID; public let artifactHash: String; public let targetID: String; public let state: LifeOSReceiptState
 public let completedUnits: UInt32; public let currentUnit: UInt32; public let parentReceiptID: UUID?
 public let parentTransitionHash: String; public let attempt: UInt32; public let errorCode: LifeOSReceiptErrorCode?
 public let createdAt: Date; public let updatedAt: Date; public let transitionHash: String
}
public struct LifeOSReceiptAnchorV4: Codable, Equatable, Sendable {
 public let receiptID: UUID; public let operationID: UUID; public let domain: LifeOSReceiptDomain
 public let artifactID: UUID; public let artifactHash: String; public let targetID: String; public let terminalState: LifeOSReceiptState
 public let terminalTransitionHash: String; public let prunedAt: Date
}
public struct RecoveryBundleImportReceiptV4: Codable, Equatable, Sendable {
 public let receiptID: UUID; public let operationID: UUID; public let bundleID: UUID; public let bundleHash: String
 public let targetDeviceID: String; public let targetOriginID: String; public let state: LifeOSReceiptState
 public let completedStores: [SyncStoreKind]; public let nextStoreIndex: UInt16; public let parentReceiptID: UUID?
 public let parentTransitionHash: String; public let transitionHash: String; public let lastErrorCode: LifeOSReceiptErrorCode?
}
public struct LifeOSDataReceiptV4: Codable, Equatable, Sendable {
 public let receiptID: UUID; public let operationID: UUID; public let archiveID: UUID; public let archiveHash: String
 public let targetID: String; public let state: LifeOSReceiptState; public let completedPacks: [LifeOSDataStoreID]
 public let currentFileIndex: UInt32; public let nextPackIndex: UInt16; public let parentReceiptID: UUID?
 public let parentTransitionHash: String; public let transitionHash: String; public let errorCode: LifeOSReceiptErrorCode?
}
public struct LifeOSReceiptLogV4: Codable, Equatable, Sendable {
 public let schemaVersion: Int; public let transitions: [LifeOSReceiptTransitionV4]
 public let anchors: [LifeOSReceiptAnchorV4]; public let logHash: String
}
public enum LifeOSReceiptIdentityV4 {
 public static func makeID(datasetID: String, domain: LifeOSReceiptDomain, operationID: UUID,
   artifactID: UUID, artifactHash: String, targetID: String) -> UUID
}
public actor LifeOSReceiptCoordinator {
 public func append(_ transition: LifeOSReceiptTransitionV4) async throws
 public func resume(receiptID: UUID) async throws -> LifeOSReceiptTransitionV4
 public func prune() async throws
}
```

`LifeOSReceiptIdentityV4.makeID(datasetID,domain,operationID,artifactID,artifactHash,targetID)` calls the R8-03 UUIDv5
primitive with `nameBytes = Frame("LifeOS/receipt-id/v4", P)`, where P is
`len(datasetID)+UTF8(datasetID)+len(domain.rawValue)+UTF8(domain.rawValue)+UInt32BE(16)+operationID.uuidBytes+
UInt32BE(16)+artifactID.uuidBytes+len(artifactHash)+UTF8(artifactHash)+len(targetID)+UTF8(targetID)`.
The same logical retry must reproduce the same ID; a different artifact hash, target ID or operation ID produces a
different ID. `operationID` is allocated once by the owning coordinator and stored before external work.
`parentReceiptID` is the immediate prior attempt only; `parentTransitionHash` is the prior transition's hash or 64
zero hex characters for the first transition. Receipt IDs and operation IDs are distinct fields.

For recovery, `targetID` is the validated `targetDeviceID`. For export, it is
`hex(SHA256(Frame("LifeOS/data-target/v4", UTF8(destinationSandboxRelativePath))))`; the raw destination path is
never stored in a receipt. `targetID` is <=128 UTF-8 bytes and artifact hashes are 64 lower-case hex characters.

## Transition bytes and schemas

For a transition, C is canonical JSON of exactly these keys, excluding `transitionHash`, sorted by R3-00 rules:
`receiptID`, `operationID`, `domain`, `artifactID`, `artifactHash`, `targetID`, `state`, `completedUnits`, `currentUnit`,
`parentReceiptID`, `parentTransitionHash`, `attempt`, `errorCode`, `createdAt`, `updatedAt`. The hash is
`hex(SHA256(Frame("LifeOS/receipt-transition/v4", C)))`. `logHash` is
`hex(SHA256(Frame("LifeOS/receipt-log/v4", C)))`, where C is canonical JSON of `transitions` and `anchors` with
`logHash` omitted and sorted by `(operationID,attempt,transitionHash)`.
Counters are monotone and <=26 packs/1024 files/1,048,576 chunks; `attempt <=64`; errors are closed taxonomy values.

`RecoveryBundleImportReceiptV4` stores `receiptID,operationID,bundleID,bundleHash,targetDeviceID,targetOriginID,state,
completedStores,nextStoreIndex,parentReceiptID,parentTransitionHash,transitionHash,lastErrorCode`.
`LifeOSDataReceiptV4` stores `receiptID,operationID,archiveID,archiveHash,targetID,state,completedPacks,currentFileIndex,
nextPackIndex,parentReceiptID,parentTransitionHash,transitionHash,errorCode`. Both use the exact transition preimage above; the fields are a materialized
cursor, never an independent authority.
For recovery, `artifactID=bundleID`, `artifactHash=bundleHash`, `completedUnits=completedStores.count` and
`currentUnit=nextStoreIndex`; for data management, `artifactID=archiveID`, `artifactHash=archiveHash`,
`completedUnits=completedPacks.count` and `currentUnit=nextPackIndex`. A receipt transition is therefore reconstructible
from either concrete receipt without an unrecorded field.

## Durable order and crash resume

`ReceiptLogStore.append` writes a temp file with exclusive/no-follow opens, fsyncs bytes, atomically replaces the log and
fsyncs its directory before returning. The caller writes `prepared` before projection/export. A domain transaction writes
its envelope/data file and a durable `(operationID,artifactHash,cursor)` marker; the log transition is appended only after
that transaction or a streaming sink fsync completes. Recovery compares the marker/file hash and appends a missing log
transition, so no cross-file transaction is assumed. A crash at operation ID allocation, prepared transition, partial
projection, finalized file, cursor advance or committed transition is repaired by durable hashes; no step returns
`committed` early.

`LifeOSReceiptCoordinator.resume(receiptID)` requires identical archive/operation hashes. It replays only incomplete
units; an already durable matching hash is a no-op, a different hash is `receiptIdentityConflict`, and a missing temp
file is recreated from its source. Cancellation returns `interrupted` after the current atomic unit; disk full returns
`diskFull` after preserving the last committed cursor. Recovery transitions are
`prepared→mapped→projecting→committed`; data export adds `streaming`; failure/interrupted can resume, rejected is final.

## Bounded pruning

Each `recovery-imports.json` and `data-management-receipts.json` has at most 256 combined transitions plus anchors.
Active receipts and the newest terminal transition for each active operation are never pruned. A terminal transition may
be compacted to one anchor only after its target hash is durable; anchors are sorted and the oldest are pruned only after
the target's content-addressed preflight can prove an identical retry is harmless. A retry whose old anchor was pruned
rechecks target hashes and resumes idempotently; a different target hash is rejected before mutation. Pruning itself is
atomic and crash-safe. P18 owns `LifeOSReceiptCoordinator`/logs in its three allowlisted files; P01 implements
`LifeOSReceiptIdentityV4` and hash bytes in its SyncContract/SyncWireCodec allowlist. P03/P04/P06/P13 must expose durable
target hashes to the coordinator.

## Revision9 supersession

R9-02 is authoritative. A prepared receipt no longer requires a final artifact hash; V5 receipts carry the complete
attempt/timestamp/pack-file-chunk cursor and transition inputs, including typed deletion artifacts and binding states.
