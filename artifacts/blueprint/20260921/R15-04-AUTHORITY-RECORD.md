# Revision 15 immutable receipt authority

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15-04 replaces R14's mutable, repeatedly signed `relocation-v8.json`. The authority record is
immutable and owner-signed once; all later authorization is an append-only authenticated mutation chain.

## Immutable owner record

```swift
public struct LifeOSReceiptAuthorityRecordV9: Codable, Sendable {
  public let schemaVersion: UInt16; public let authorityID: UUID; public let migrationEpoch: UInt64
  public let ownerKeyID: String; public let ownerPublicKey: Data; public let deviceKeyID: String
  public let devicePublicKey: Data; public let canonicalPaths: [String]; public let legacyPaths: [String]
  public let sourceInventoryHash: String; public let initialCanonicalInventoryHash: String
  public let createdAt: Int64; public let signature: Data
}
public enum LifeOSAuthorityMutationKindV9: UInt8, Codable, Sendable {
  case fenceOpen = 1, canonicalReplaceIntent = 2, canonicalReplaceCommit = 3
  case canonicalVerified = 4, legacyRetireIntent = 5, legacyRetireCommit = 6, retirementProof = 7
}
public enum LifeOSAuthorityRecoveryPhaseV9: UInt8, Codable, Sendable {
  case bootstrap = 1, fenced = 2, copying = 3, verifying = 4
  case committed = 5, retiringLegacy = 6, retired = 7, blocked = 8
}
public enum LifeOSReplacementStateV9: UInt8, Codable, Sendable {
  case intentDurable = 1, fileReplaced = 2, commitDurable = 3, blocked = 4
}
public enum LifeOSLegacyRetirementStateV9: UInt8, Codable, Sendable {
  case missing = 1, intentDurable = 2, deleted = 3, blocked = 4
}
public struct LifeOSAuthorityMutationV9: Codable, Sendable {
  public let schemaVersion: UInt16; public let authorityID: UUID; public let sequence: UInt64
  public let mutationID: UUID; public let intentID: UUID; public let kind: LifeOSAuthorityMutationKindV9
  public let domain: LifeOSReceiptDomainV6?; public let relativePath: String?
  public let migrationEpoch: UInt64; public let expectedInventoryHash: String
  public let oldFileHash: String?; public let newFileHash: String?; public let sourceFingerprintHash: String?
  public let sourceInventory: [LifeOSLegacySourceFingerprintV9]?; public let retirementDispositions: [LifeOSLegacyRetirementDispositionV9]?
  public let resultInventoryHash: String?; public let retirementProofHash: String?; public let previousRecordHash: String?
  public let recordHash: String; public let signerKeyID: String; public let signature: Data
}
```

`authority-v9.json` is written once at the fixed `Application Support/LifeOS/Receipts` location, mode 0600,
fsynced and never replaced. Its owner signature is over
`Frame("LifeOS/receipt-authority-owner/v9", CanonicalJSON(record without signature))`; P01 verifies the pinned owner
key and that `canonicalPaths` is exactly the three V7 receipt paths and `legacyPaths` is exactly the three fixed
legacy inputs. The owner record authorizes one `deviceKeyID`; no bearer secret or mutable marker authorizes writes.
`Data` key/signature fields use base64url without padding in JSON and are decoded before signature verification.

`authority-mutations-v9.log` is append-only, mode 0600. Each record is framed as `UInt32BE(length) + canonical
JSON(record) + SHA256(canonical JSON bytes)`, with length <=65,536; the frame and parent directory are fsynced before
the next operation. `recordHash` is
`SHA256(Frame("LifeOS/receipt-authority-mutation-hash/v9", CanonicalJSON(record without recordHash or signature)))`.
`signature` is the device-key signature over
`Frame("LifeOS/receipt-authority-mutation/v9", CanonicalJSON(record with recordHash and without signature))`.
P01 accepts it only when `authorityID`, `migrationEpoch`, signer key, sequence and `previousRecordHash` chain to the
immutable owner record. A truncated final frame is discarded only when its length/digest proves it was never
complete; a complete invalid frame blocks recovery.

## Fence and authorization policy

`fenceOpen` authenticates the complete per-file source inventory and initial canonical inventory. A canonical
replacement requires an intent/commit pair with the same `intentID`: the intent's expected inventory and old hash
must equal the replayed state; its new hash, domain, path, sequence and migration epoch are fixed before any replace.
The commit is accepted only after the observed file hash and result inventory match the intent. Legacy retirement uses
the same pair and additionally requires the source fingerprint hash. `retirementProof` is the only record that closes
the epoch; it includes every source path/fingerprint disposition and the final canonical inventory.

`sourceInventory` is required with exactly three entries on `fenceOpen` and null for other kinds. It is the complete
`R15-05` fingerprint array. `retirementDispositions` is required with exactly three entries on `retirementProof`
and null otherwise; each entry names the source ID, recorded fingerprint hash and `missing|retired` disposition.
`retirementProofHash` is required only on `retirementProof`. All nullable fields are encoded as JSON `null`, never
omitted, so the mutation hash and signature cover the same bytes in every language.

The coordinator replays the immutable owner record and mutation log under one lock. It derives current phase, cursors,
file hashes and `legacyRetired` from records; it never edits a prior record or stores a second mutable state file.
Owner signature failure, unknown device key, sequence gap, bad previous hash, path outside the owner allowlist,
epoch mismatch, old/new hash mismatch or an unauthorized deletion returns `authorityInvalid` or
`externalModification` and exposes no receipt log.

```swift
public actor LifeOSReceiptAuthorityV9 {
  public func open() throws -> LifeOSReceiptAuthorityStateV9
  public func appendIntent(_ record: LifeOSAuthorityMutationV9) throws
  public func appendCommit(_ record: LifeOSAuthorityMutationV9) throws
  public func verifyRetirementProof() throws -> LifeOSReceiptAuthorityStateV9
}
```

P01 owns owner/device signature verification and framed bytes. P18 owns the actor and append/replay calls in the
existing `ios/Shared/LifeOSReceiptCoordinator.swift`. R14's `relocation-v8.json` is a legacy migration input only;
workers must not mutate or recreate it as an active authority. Upgrade reads it once after validating its R14
signature/transition hash, creates the immutable V9 record and `fenceOpen`, and leaves the V8 file untouched until
the R15 retirement proof makes it permanently ignored.

## R16 current authority

R16-03 is current for an existing authority with a missing mutation log,
authenticated pending legacy-retirement intent and post-unlink crash proof.
R16-04 is current for the immutable historical proof/current inventory model,
legal post-retirement mutations and bounded checkpoint rotation. R15 types remain
the baseline until the R16 extensions are applied.
