# R16 authority bootstrap and legacy-retirement crash recovery

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R16 is the final rule for an existing authority, pending
legacy-retirement intent and a crash between unlink and commit.

## One bootstrap rule

An existing `Receipts/authority-v9.json` without
`Receipts/authority-mutations-v9.log` is never reconstructed from filenames,
timestamps, directory order or current file hashes. `open()` returns
`authorityMutationLogMissing` and exposes no receipt projection. The only
repair is restoring the complete log from an authenticated backup whose first
record chains to the immutable authority; the restore is an external,
user-gated evidence step. Creating a new log or replacing the owner record is
forbidden. A completely new installation with neither file follows the R15
owner-key/fence-open bootstrap and is a different state.

## Authenticated pending retirement intent

R15 `legacyRetireIntent` is amended to carry this exact payload before any
unlink:

```swift
struct LifeOSLegacyRetireIntentV9: Codable, Sendable {
  let schemaVersion: UInt16; let authorityID: UUID; let migrationEpoch: UInt64
  let intentID: UUID; let sourceID: String; let relativePath: String
  let expectedSourceHash: String; let sourceFingerprintHash: String
  let expectedInventoryHash: String; let createdAt: Int64
  let intentHash: String; let signerKeyID: String; let signature: Data
}
struct LifeOSLegacyRetireProofV9: Codable, Sendable {
  let schemaVersion: UInt16; let authorityID: UUID; let migrationEpoch: UInt64
  let intentID: UUID; let sourceID: String; let relativePath: String
  let expectedSourceHash: String; let postState: LifeOSLegacyPostStateV9
  let parentSyncToken: UUID; let proofHash: String; let signerKeyID: String
  let signature: Data
}
enum LifeOSLegacyPostStateV9: UInt8, Codable, Sendable { case absent = 1 }
```

`intentHash` is `SHA256(Frame("LifeOS/legacy-retire-intent/v9",
CanonicalJSON(all fields except intentHash/signature)))`. The device signature
covers `intentHash`; the owner-authorized device key, epoch, path allowlist,
source fingerprint and current inventory are checked before persistence.
`proofHash` is `SHA256(Frame("LifeOS/legacy-retire-proof/v9",
CanonicalJSON(all proof fields except proofHash/signature)))`; `parentSyncToken`
is a fresh UUID recorded only after `fsync(parentDirectory)` returns success.
The canonical JSON value of `postState` is the numeric enum value `1` for
`absent`; no string spelling is accepted.
The proof is an authenticated application-level proof of the authorized
absence; it is not claimed to identify an external actor after a crash.

## Exact unlink and recovery order

Under the authority lock P18 validates the source bytes against
`expectedSourceHash`, appends and fsyncs the intent, unlinks exactly the named
file, fsyncs its parent, then appends and fsyncs the commit/proof. No other
legacy path is scanned. Recovery executes this table:

|observed after restart|action|
|---|---|
|path exists with expected hash|repeat unlink, parent fsync, create proof, append commit|
|path absent and pending intent matches|create a new proof with a new `parentSyncToken`, append commit; this is the only sink-ahead adoption|
|path exists with another hash|return `legacyExternalModification`; do not delete|
|path absent without matching intent|return `legacyRetirementUnproven`; do not append a commit|
|intent/commit already present|verify hashes and return idempotent no-op|

```swift
func recoverPendingLegacyRetirement(_ intent: LifeOSLegacyRetireIntentV9,
                                     observedPath: URL) throws -> LifeOSLegacyRetireProofV9
func bootstrapExistingAuthority(_ authorityURL: URL, mutationLogURL: URL) throws
  -> LifeOSReceiptAuthorityStateV9
```

The commit record embeds `proofHash`, `expectedSourceHash`, `postState` and
the intent ID. A different proof for the same intent is
`authorityReplayConflict`. The proof is accepted only after the authenticated
intent, source fingerprint, epoch, expected inventory and path all match;
absence alone never authorizes retirement.

## Durable visibility

The sequence is intent fsync → unlink → parent fsync → proof/commit fsync →
retirement-proof fsync. A crash before intent leaves the source visible; after
intent and before unlink recovery follows the first row; after unlink it
follows the second row. `retired` is projected only after all per-source
commits and the aggregate R15 retirement proof verify. No projection may read
legacy files while phase is `retiringLegacy` or `retired`; canonical reads use
the existing V9 envelope and authority lock.

P01 owns canonical bytes, signatures and typed errors. P18 owns the authority
actor, filesystem calls, replay and atomic projection in the existing
`ios/Shared/LifeOSReceiptCoordinator.swift`. No new recovery marker or
database is permitted.
