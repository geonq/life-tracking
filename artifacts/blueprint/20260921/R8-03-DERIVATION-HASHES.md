# R8 identity and hash derivations

Planning-only. These byte rules are normative for recovery mappings, aliases, deterministic store IDs and receipt IDs.
Every hash field is excluded from the object used to calculate that field; no implementation may hash a structure that
already contains its own hash.

## Canonical bytes

`CanonicalJSON(value)` is the R3-00 subset: UTF-16 lexicographic object keys, no whitespace, canonical JSON escaping,
UTF-8 output, integer-only metadata, no duplicate keys, and an explicitly documented array order. UUIDs are lower-case
RFC-4122 strings in JSON. Dates are UTC ISO-8601 with exactly three fractional digits. Hashes are lower-case hex.
`Frame(domain,C)` is `UTF8(domain) + NUL + UInt32BE(C.count) + C`; the count is the UTF-8 byte count, not characters.
All length-prefixed strings below use `UInt32BE(UTF8(value).count) + UTF8(value)`.

```swift
public struct RecoveryStoreMappingV4: Codable, Equatable, Sendable {
 public let sourceDatasetID: String; public let targetDatasetID: String; public let sourceStoreUUID: UUID
 public let targetStoreUUID: UUID; public let sourceOriginID: String; public let targetOriginID: String
 public let mappingHash: String
}
public enum LifeOSDerivation {
 public static func mappingHash(_ mapping: RecoveryStoreMappingV4) -> String
 public static func aliasHash(_ alias: SyncStoreAliasV4) -> String
 public static func aliasTableHash(_ table: SyncStoreAliasTableV4) -> String
 public static func uuidV5(namespace: UUID, nameBytes: Data) -> UUID
 public static func deterministicStoreUUID(datasetID: String, kind: SyncStoreKind) -> UUID
}
public enum IdentityDerivationError: Error, Sendable {
 case invalidUTF8, invalidLength, nonCanonicalInput, hashMismatch, uuidCollision, duplicateIdentity
 case namespaceMismatch, unsupportedPurpose, mappingDatasetMismatch
}
```

## Mapping and alias preimages

For `mappingHash`, C is canonical JSON of exactly these six keys, with no `mappingHash`, in UTF-16 key order:
`sourceDatasetID`, `sourceOriginID`, `sourceStoreUUID`, `targetDatasetID`, `targetOriginID`, `targetStoreUUID`.
The value is `hex(SHA256(Frame("LifeOS/recovery-mapping/v4", C)))`. Source/target IDs and origins are nonblank and
bounded to 128 UTF-8 bytes; UUIDs are valid; dataset equality is checked by the adapter's target context.

For `aliasHash`, C is canonical JSON of `kind`, `legacyStoreUUID`, `canonicalID` and `aliasVersion`, excluding
`aliasHash`; hash `Frame("LifeOS/store-alias/v4", C)`. For `tableHash`, C is canonical JSON of `schemaVersion`, `tag`,
`datasetID` and sorted `entries`, excluding `tableHash`; hash `Frame("LifeOS/store-alias-table/v4", C)`. A table has
exactly 17 entries. Alias `canonicalID` must equal `kind.rawValue`; `aliasVersion == 4`.

## UUIDv5 and collisions

The fixed namespace is `2f5e2a66-7c44-5d3f-9bb6-243b3b2f4d21` and is called
`LifeOSUUIDNamespace.v4`. `uuidV5` computes SHA-1 over the namespace's 16 network-order bytes followed by
`nameBytes`, sets the version nibble to 5 and RFC-4122 variant bits, and returns the lower-case UUID.
`deterministicStoreUUID` calls it with `nameBytes = Frame("LifeOS/uuid-name/v4", P)`, where P is the concatenation of
length-prefixed `purpose="store"`, `datasetID` and `kind.rawValue`. Receipt identity uses the same primitive with its
own exact name preimage in R8-05; it does not create a second UUID algorithm.

The resolver first checks an existing persisted alias. A newly derived UUID may be installed only when no UUID or kind
collision exists; if the same UUID maps to different dataset/kind/source mapping, it returns `uuidCollision` and writes
nothing. An existing R3 UUID always wins over derivation. A UUIDv5 collision is not resolved by salting or choosing a
second namespace; it is a fatal migration error requiring an owner-signed alias table.

## Verification order and no self-reference

`SyncAliasMigration` validates UTF-8/lengths, canonical JSON, alias hashes, table hash, table signature, then mappings.
`RecoveryBundleCodecV4` validates the mapping hash before target projection. The source operation signature is verified
over its original V1/V2 bytes before any resolved kind is added. `mappingHash`, `aliasHash`, `tableHash`, `chainHash`,
`trustHash` and receipt transition hashes each use their named hash-free preimage and cannot be copied from another
record. `trustHash` is `hex(SHA256(Frame("LifeOS/trust-record/v4", C)))`, where C is the canonical V4 trust record with
`trustHash` omitted. Any duplicate identity, noncanonical spelling, different canonical encoding, hash mismatch or out-of-bound input
returns `IdentityDerivationError` and leaves the containing transaction unchanged.

P01 owns these derivations and publishes test vectors as planning evidence. P03/P04/P06/P13 call `mappingHash` only
through the recovery adapter; P18 calls `LifeOSReceiptIdentityV4.makeID`; no domain store may implement a second hash or UUID algorithm.
