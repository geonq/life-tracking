# R11 compact archive footer and separately authenticated manifest

Planning-only. This sheet supersedes the R10 footer/manifest layout. A footer never embeds 4,096 file records;
it references a separately authenticated, streamed manifest so a full pack remains valid.

## Frame and manifest shapes

The R10 frame bytes and UInt8 values remain: `0x01 archiveHeader`, `0x02 packHeader`, `0x03 fileHeader`,
`0x04 chunk`, `0x05 fileFooter`, `0x06 packFooter`, `0x07 archiveFooter`; every other value is rejected.
Header metadata is <=64 KiB; chunk payload is <=1 MiB; every other frame metadata+payload is <=128 KiB.

```swift
public struct LifeOSArchiveManifestBodyV7: Codable, Sendable {
 public let schemaVersion: Int; public let archiveID: UUID; public let preparedArtifactID: UUID
 public let protection: String; public let representation: String; public let retention: String
 public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
 public let packs: [LifeOSPackManifestV6]
}
public struct LifeOSArchiveFooterReferenceV7: Codable, Sendable {
 public let frameKind: UInt8; public let archiveID: UUID; public let preparedArtifactID: UUID
 public let manifestRelativePath: String; public let manifestHash: String; public let manifestByteCount: UInt64
 public let manifestChunkCount: UInt32; public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64; public let archiveHash: String
}
public struct LifeOSPackFooterReferenceV7: Codable, Sendable {
 public let frameKind: UInt8; public let packID: UUID; public let packIndex: UInt16
 public let manifestRelativePath: String; public let packHash: String; public let declaredFileCount: UInt32
 public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
}
```

The manifest bytes are exactly `CanonicalJSON(LifeOSArchiveManifestBodyV7)` at the fixed relative path
`manifest/archive-manifest.json`; its `manifestHash` is `SHA256(Frame("LifeOS/archive-manifest/v7", bytes))`.
The manifest is streamed to a partial file in <=1 MiB chunks, has `manifestByteCount <=268,435,456` and is
never decoded whole. The archive data remains <=256 MiB; total temporary/final storage is bounded at 512 MiB
(data plus worst-case manifest). The footer reference canonical JSON is <=8 KiB, so 4,096-file packs fit.

`archiveHash` is `SHA256(Frame("LifeOS/archive/v7", CanonicalJSON({schemaVersion:7,archiveID,
preparedArtifactID,manifestHash,declared counts,packRefs:[{packID,packIndex,packHash,counts}]})))`; it excludes
itself. `packHash` remains the R10 preimage over ordered file descriptors and child `fileDigest`s; the pack
footer carries only its compact path/hash/count reference. Footer references bind path, store IDs, protection, representation,
retention, counts and hashes through the separately authenticated manifest, not inference from frame order.

## Write and verification order

The writer emits bounded header/pack/file/chunk/file-footer frames and compact pack-footer references containing
the already-known pack hash. It then streams and fsyncs the manifest partial, atomically renames it, computes
`archiveHash` after `manifestHash` and all pack hashes are fixed, and emits the final archive-footer reference.
A crash before the manifest rename leaves the old manifest; an incomplete partial is unreferenced and retryable.

The verifier checks magic/version/kind/length and numeric kind allowlist, then header identity and bounds; it
streams frames and chunk hashes; checks file/pack order and digests; checks footer references and fixed manifest
path; streams the manifest with the 256 MiB cap and recomputes `manifestHash`; compares every file/store/path/
count/protection/retention descriptor to the frames; recomputes `packHash` and `archiveHash`; only then binds the
R11 V6 receipt. Unknown kinds, duplicate IDs/paths, count mismatch, hash mismatch or manifest overflow fail
closed before projection. P18 owns codec/digest/streaming; P01 owns canonical bytes and numeric values.

## R12 supersession

R12-03/04 are final for the post-pack manifest carrier, fixed pack/index paths, streaming sink/source/verifier,
and the complete cross-language V7 archive-hash object. The R11 materialized archive body and `{...}` digest
placeholder are historical only.
