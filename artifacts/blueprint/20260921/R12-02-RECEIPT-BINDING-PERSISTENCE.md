# R12 durable receipt artifact binding

Planning-only. This sheet supersedes the binding persistence clauses in R11-04 and the receipt-log persistence
clauses in R10-04. A digest is an identifier; the complete binding record is durable and reconstructible.

R15-01 is now final for the active V7 transition, binding, compaction, finalization-hash and V6 migration record.
R15-04/05 are final for authority fencing and receipt-file replacement. The older binding fields below are
historical where they use the single `artifactHash` name.

## One file authority and exact records

There is no binding sidecar. The exact selector is
`public func logURL(_ domain: LifeOSReceiptDomainV6) -> URL`; it selects exactly one existing file:
`Application Support/LifeOS/Receipts/recovery-imports.json`, `data-management-receipts.json`, or
`data-management-deletions.json`. Each file is a canonical JSON object:

```swift
public enum LifeOSReceiptDomainV6: String, Codable, Sendable {
 case recoveryImport = "recovery-imports.json"; case dataManagement = "data-management-receipts.json"
 case dataDeletion = "data-management-deletions.json"
}
public struct LifeOSReceiptFileV6: Codable, Sendable {
 public let schemaVersion: Int; public let logs: [LifeOSReceiptLogV6]
}
public struct LifeOSReceiptBindingRecordV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let attempt: UInt16
 public let firstBoundSequence: UInt32; public let binding: LifeOSArtifactBindingV6
 public let bindingRecordHash: String
}
public struct LifeOSReceiptLogV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let anchor: LifeOSReceiptCheckpointV6?
 public let bindingRecord: LifeOSReceiptBindingRecordV6?; public let transitions: [LifeOSReceiptTransitionV6]
}
```

`LifeOSReceiptTransitionV6` gains `bindingRecordHash: String?`. It is null before `bound` and required and
equal to `bindingRecord.bindingRecordHash` for `bound|committed`; the complete binding record stays in the log
even after compaction. `LifeOSReceiptCheckpointV6` retains the same binding record when its anchor covers a
bound/committed state. The exact R10 field amendments are `LifeOSReceiptTransitionV6.bindingRecordHash: String?`
and `LifeOSReceiptCheckpointV6.bindingRecord: LifeOSReceiptBindingRecordV6?`; both are encoded with those names.
JSON keys are canonical, unknown keys are rejected, and `logs` is sorted by receipt UUID.

## Hashes, atomic write and reopen

`bindingRecordHash` is
`hex(SHA256(Frame("LifeOS/receipt-binding-record/v6", CanonicalJSON({schemaVersion:6,receiptID,attempt,
firstBoundSequence,binding:{schemaVersion,receiptID,preparedArtifactID,artifactKind,relativePath,manifestHash,
archiveHash,byteCount,fileCount,chunkCount,representation,protection,retention,artifactHash,boundAt}}))))`.
The existing artifact-binding hash remains the exact R11 preimage. The V6 transition preimage is amended by one
field: `bindingRecordHash` appears beside `artifactHash`; the state/hash chain therefore binds both the digest and
the full-record identity. Every unsigned integer uses the existing decimal-string adapter.

`boundAt` is deterministic: on the first finalize attempt the actor copies the current durable head's
`updatedAt` after checking `LifeOSFinalizeArtifactInputV6.expectedTransitionHash`; it never samples a new wall
clock value during retry. A head changed before the atomic replacement returns `receiptIdentityConflict`. Thus a
crash with the old `finalizing` log reconstructs identical binding bytes, while a reopened `bound` log uses its
stored record unchanged.

The existing store surface is exact: `LifeOSReceiptStoreV6.finalizeArtifact(_:)` writes the binding, `commitBound
(_:expectedArtifactHash:)` writes the terminal transition, `resumeV6(_:)` reopens the selected domain log, and
`logURL(_:)` is the only domain-to-file selector. P18 places these symbols in the existing
`ios/Shared/LifeOSReceiptCoordinator.swift`; no receipt file or binding sidecar may be added.

`prepare`, `advance`, `finalizeArtifact` and `commitBound` take the actor fence, decode the complete file, validate
the chain and binding, write a complete `.tmp` file, fsync it, atomically replace the selected receipt file, fsync
its directory, and only then return. A crash selects the old or new complete file by its file hash. The binding
record and the transition that first references it are written in the same replacement; there is no durable state
where `bound` exists with only an artifact digest.

On reopen, `LifeOSReceiptStoreV6` recomputes `artifactHash` from all binding fields, recomputes
`bindingRecordHash`, verifies receipt/attempt/prepared IDs, validates every transition reference and reconstructs
`LifeOSReceiptV6.binding` from `bindingRecord`. Missing binding, a digest-only record, a mismatched record hash or
a bound transition with null `bindingRecordHash` returns `bindingMissing|corruptLog` and never projects data.

## Retry, compaction and crash resume

An identical `(receiptID,attempt,bindingRecordHash)` retry returns the stored result. Because `boundAt` comes from
the durable head, retry before replacement produces the same hash; retry after replacement reads the complete
record. A different field set is
`artifactIdentityConflict`. After a crash before replacement, retry recomputes and writes the same record; after a
bound replacement it appends committed using the same record; after committed it returns the stored result. The
binding record is copied into every compaction anchor that covers it and remains in the top-level log until the
receipt is pruned. Pruning is allowed only for terminal receipts after the configured retention period; it removes
the complete terminal log and never leaves a digest-only record. Active or retryable receipts are never pruned;
there is no reopenable receipt state after an intentional terminal-retention prune.

P18 owns this file schema, store and reopen logic; P01 owns canonical bytes. R11-04's `LifeOSReceiptStoreV6`
API remains the call surface, amended by this record/hash contract. Acceptance must delete the temporary file at
each crash point and prove that reopen reconstructs the exact artifact path, hashes, counts and protection policy.

R13-03 is final for receipt path discovery and relocation. The three `LifeOS/Receipts` files remain the canonical
post-migration destinations, while Replication/DataManagement files are fixed legacy inputs handled only by the P18
relocator before `logURL` is exposed. R14-03 supersedes the V7 relocation journal retention and defines the
permanent V8 authority marker and authorized mutation protocol.
