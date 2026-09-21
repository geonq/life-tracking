# R11 receipt V6 artifact binding and finalization

Planning-only. This sheet is the final V6 finalize contract; a migrated V5 receipt is converted before opening
the V6 store and is never used as a runtime finalize input.

## Binding values and exact hash

```swift
public struct LifeOSArtifactBindingV6: Codable, Sendable {
 public let schemaVersion: Int; public let receiptID: UUID; public let preparedArtifactID: UUID
 public let artifactKind: String; public let relativePath: String; public let manifestHash: String
 public let archiveHash: String; public let byteCount: UInt64; public let fileCount: UInt32
 public let chunkCount: UInt32; public let representation: String; public let protection: String
 public let retention: String; public let artifactHash: String; public let boundAt: Int64
}
public struct LifeOSFinalizeArtifactInputV6: Sendable {
 public let receiptID: UUID; public let attempt: UInt16; public let preparedArtifactID: UUID
 public let artifactKind: String; public let relativePath: String; public let manifestHash: String; public let archiveHash: String
 public let byteCount: UInt64; public let fileCount: UInt32; public let chunkCount: UInt32
 public let representation: String; public let protection: String; public let retention: String
 public let expectedTransitionHash: String
}
public struct LifeOSFinalizeResultV6: Sendable { public let receipt: LifeOSReceiptV6; public let artifactHash: String }
```

`artifactHash` is `hex(SHA256(Frame("LifeOS/artifact-binding/v6", CanonicalJSON({schemaVersion:6,
receiptID,preparedArtifactID,artifactKind,relativePath,manifestHash,archiveHash,byteCount,fileCount,
chunkCount,representation,protection,retention}))))`. The preimage excludes `artifactHash` and `boundAt`.
`LifeOSReceiptV6` gains optional `binding: LifeOSArtifactBindingV6?`; state `bound|committed` requires it,
and `prepared|streaming|finalizing` must not contain it. The existing `artifactHash` field in the V6 transition
preimage carries this digest, so the transition chain binds the complete artifact identity without a V5 lookup.

## Store/coordinator API and durable order

```swift
public actor LifeOSReceiptStoreV6 {
 public func finalizeArtifact(_ input: LifeOSFinalizeArtifactInputV6) throws -> LifeOSFinalizeResultV6
 public func commitBound(_ receiptID: UUID, expectedArtifactHash: String) throws -> LifeOSReceiptV6
 public func resumeV6(_ receiptID: UUID) throws -> LifeOSReceiptV6
}
public actor LifeOSReceiptCoordinatorV6 {
 public func finalize(_ input: LifeOSFinalizeArtifactInputV6) async throws -> LifeOSFinalizeResultV6
}
```

The coordinator verifies receipt identity/attempt/expected transition, relative path, manifest hash, archive hash,
declared counts and fsynced archive bytes using `LifeOSArchiveIntegrityV6`; it then calls the store. The store
recomputes the binding hash, takes the receipt actor fence, writes a complete temporary V6 log containing `bound`
and the binding, fsyncs, atomically replaces the existing log, fsyncs the directory, and returns. `commitBound`
requires the identical binding hash, writes `committed` in a second atomic replacement, and only then reports
success. No projection, widget snapshot or deletion is marked complete before `committed` is durable.

## Retry, crash and errors

`finalizeArtifact` is idempotent for the same receipt/attempt/prepared ID and all binding fields. A crash before
rename leaves the previous state; after rename `resumeV6` sees `bound` and calls `commitBound`. If the artifact
is present but the binding is absent, resume re-verifies it and appends bound. A different hash, path, count or
prepared ID returns `artifactIdentityConflict` and never replaces the log. A missing/changed manifest is
`sourceChanged`; disk-full is `diskFull`; cancellation before log replacement is `cancelled`, while cancellation
after replacement returns the durable receipt. A corrupt V5/V6 chain is `corruptLog`; the last verified log is
preserved. V5 migration is a separate `migrateV5LogToV6` preflight that must finish before `resumeV6`.

P18 owns the receipt store/coordinator and P18 archive verification; P01 owns canonical framing and error values.
Acceptance evidence must show retry at every boundary (artifact rename, bound log rename, committed log rename)
returns one artifact hash and one receipt ID, with no duplicate projection or deletion.

## R12 supersession

R12-02 is final for the durable location and encoding of `LifeOSArtifactBindingV6`: the complete binding record
is stored in each existing receipt log and is referenced by hash from bound/committed transitions. A digest-only
receipt is invalid.
