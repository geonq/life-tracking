# R10 archive manifest identity and digest contract

Planning-only. R10 supersedes archive digest and frame-verification clauses in R9-03 and the archive
identity clauses in R7-05. Every digest covers the manifest identity that selects a file, not only its
bytes.

## Frame kinds and common framing

```swift
public enum LifeOSArchiveFrameKindV6: UInt8, Codable, Sendable {
 case archiveHeader = 0x01, packHeader = 0x02, fileHeader = 0x03
 case chunk = 0x04, fileFooter = 0x05, packFooter = 0x06, archiveFooter = 0x07
}
public struct LifeOSArchiveFrameV6: Sendable {
 public let kind: LifeOSArchiveFrameKindV6; public let metadata: Data; public let payload: Data
}
public enum LifeOSArchiveFrameCodecV6 {
 public static func encode(_ frame: LifeOSArchiveFrameV6) throws -> Data
 public static func decode(_ bytes: Data) throws -> LifeOSArchiveFrameV6
}
public enum LifeOSArchiveIntegrityErrorV6: Error, Sendable {
 case unknownFrameKind(UInt8), badLength, identityMismatch, countMismatch, digestMismatch
 case unsupportedSchema, capacity, diskFull, cancelled
}
```

`0x00` and every value `0x08...0xFF` are `unknownFrameKind` and are rejected before metadata or
payload allocation. A frame is `UTF8("LIFEOSAR") + UInt16BE(6) + kind.rawValue + UInt32BE(metaLen) +
UInt32BE(payloadLen) + metadata + payload + SHA256(Frame("LifeOS/archive-frame/v6", kindByte +
metadata + payload))`. `metaLen <=64 KiB`, `payloadLen <=1 MiB` for a chunk and `<=128 KiB` for
other frames. The decoder checks magic/version/kind/length before base64 or JSON decoding.

## Canonical manifest shapes

```swift
public struct LifeOSFileManifestV6: Codable, Sendable {
 public let fileID: UUID; public let relativePath: String; public let storeID: String
 public let protection: String; public let representation: String; public let retention: String
 public let declaredByteCount: UInt64; public let declaredChunkCount: UInt32
 public let chunkHashes: [String]; public let fileDigest: String
}
public struct LifeOSPackManifestV6: Codable, Sendable {
 public let packID: UUID; public let packIndex: UInt16; public let storeID: String
 public let declaredFileCount: UInt32; public let declaredChunkCount: UInt32
 public let declaredByteCount: UInt64; public let files: [LifeOSFileManifestV6]; public let packHash: String
}
public struct LifeOSArchiveManifestV6: Codable, Sendable {
 public let schemaVersion: Int; public let archiveID: UUID; public let preparedArtifactID: UUID
 public let protection: String; public let representation: String; public let retention: String
 public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
 public let packs: [LifeOSPackManifestV6]; public let archiveHash: String
}
```

`relativePath` is nonempty UTF-8 NFC, slash-separated, no leading slash, no `.`/`..`, NUL or
backslash, and <=512 bytes. `storeID` is the exact `LifeOSDataStoreID.rawValue`, <=64 ASCII;
protection/representation/retention are the closed R7 enum strings. A file has <=4096 chunks, a
pack <=4096 files, an archive exactly <=26 packs, and counts/sums must match all arrays. A domain
envelope is <=32 MiB; an ordinary file is <=4 MiB; each chunk is <=1 MiB. The registry order is
the pack order, and files are ordered by relative-path UTF-8 bytes within a pack.
The Swift `UInt64`/`UInt32` fields use decimal-string JSON adapters in canonical bytes; a JSON number
for a declared count is rejected. UUIDs use lowercase hyphenated text and hashes use lowercase hex.

The archive header metadata carries `archiveID`, `preparedArtifactID`, protection, representation,
retention and all four declared counts plus `frameKind=1`. Pack/file headers carry their IDs, path or
store ID and their declared counts plus `frameKind=2|3`. Chunk metadata carries file ID, chunk index,
declared chunk length and `frameKind=4`; footers carry their corresponding digest and `frameKind=5|6|7`.
No field is inferred from a path or omitted when its value is the default.

## Exact digest preimages

The canonical preimages use decimal strings for UInt64 values and preserve ordered arrays:

```text
file = {schemaVersion:6,frameKind:5,fileHeaderFrameKind:3,chunkFrameKind:4,fileID,relativePath,storeID,protection,representation,
        retention,declaredByteCount,declaredChunkCount,chunkHashes}
pack = {schemaVersion:6,frameKind:6,packHeaderFrameKind:2,fileHeaderFrameKind:3,fileFooterFrameKind:5,
        packID,packIndex,storeID,declaredFileCount,
        declaredChunkCount,declaredByteCount,files:[{fileID,relativePath,storeID,protection,representation,retention,fileDigest}]}
archive = {schemaVersion:6,frameKind:7,archiveHeaderFrameKind:1,packHeaderFrameKind:2,packFooterFrameKind:6,
           archiveFooterFrameKind:7,archiveID,preparedArtifactID,protection,representation,
           retention,declaredPackCount,declaredFileCount,declaredChunkCount,declaredByteCount,
           packs:[{packID,packIndex,storeID,declaredFileCount,declaredChunkCount,declaredByteCount,packHash}]}
```

Each of the three preimages also has the final field
`frameKinds:{archiveHeader:1,packHeader:2,fileHeader:3,chunk:4,fileFooter:5,packFooter:6,archiveFooter:7}`;
this is numeric and ordered exactly as shown. The displayed `frameKind` fields identify the digest's
footer; the complete `frameKinds` field binds every frame kind to the digest version.

`fileDigest=hex(SHA256(Frame("LifeOS/archive-file/v6",CanonicalJSON(file))))`; the `file` preimage
excludes the output `fileDigest`. `packHash` and `archiveHash` use the analogous domain strings
`LifeOS/archive-pack/v6` and `LifeOS/archive/v6`; the pack preimage includes child `fileDigest`
values but excludes `packHash`, and the archive preimage includes child `packHash` values but excludes
`archiveHash`. `chunkHashes[i]` is SHA-256 of the exact chunk bytes. The same canonical object
is used for footer metadata and manifest verification; numeric frame kind is never represented by a
string in these preimages.

```swift
public enum LifeOSArchiveIntegrityV6 {
 public static func fileDigest(_ file: LifeOSFileManifestV6) throws -> String
 public static func packHash(_ pack: LifeOSPackManifestV6) throws -> String
 public static func archiveHash(_ archive: LifeOSArchiveManifestV6) throws -> String
 public static func verifyManifest(_ manifest: LifeOSArchiveManifestV6,
   frames: AsyncStream<LifeOSArchiveFrameV6>) async throws -> LifeOSArchiveManifestV6
}
public enum LifeOSArchiveMigratorV6 {
 public static func migrateV5Archive(at source: URL, to destination: URL) throws -> LifeOSArchiveManifestV6
}
```

P18 owns `LifeOSArchiveIntegrityV6.fileDigest(_:)`, `packHash(_:)`, `archiveHash(_:)` and
`verifyManifest(_:,frames:)`. Verification order is: frame
kind/version/length; header identity/protection; path and store-ID allowlist; declared counts and
limits; chunk bytes/hash/index; file digest; pack digest/order; archive digest and receipt binding.
Duplicate IDs, duplicate paths, count mismatch, unknown enum strings, unknown frame kinds or hash
mismatch return typed `archiveIntegrity` before store projection.

## Migration and failure behavior

R9 manifests with schema 5 are accepted only through `LifeOSArchiveMigratorV6`, which assigns the
fixed v6 frame kinds, copies all existing identity fields, rejects a missing path/store/protection/
representation/retention, recomputes every digest and writes a new partial manifest. The v5 artifact
remains untouched until v6 verification and atomic rename succeed. A v6 decoder never falls back to
v5 after seeing version 6. Unknown fields are rejected; known omitted v5 fields are migratable only
when the closed default is explicitly recorded in the v6 manifest.

`LifeOSArchiveIntegrityV6` never decodes a whole archive into memory. It streams frames through the
R9 bounded sink, records only bounded manifests/chunk hashes, and returns `diskFull`, `capacity`,
`cancelled` or `archiveIntegrity` without deleting the last verified artifact. Receipt binding occurs
only after `archiveHash` and every manifest identity field have been fsynced.

## R11 supersession

R10-05 remains the frame codec and V6 digest history. R11-07 is final for the compact pack/archive footers and
the separately authenticated streamed manifest: a footer carries a bounded reference, not a 4,096-file array;
manifest and archive hashes are verified before receipt binding.

R12-03/04 supersede the materialized V7 body and incomplete archive preimage with streamed carrier frames,
pack/index paths and the exact Swift/Python/TypeScript canonical hash object.
