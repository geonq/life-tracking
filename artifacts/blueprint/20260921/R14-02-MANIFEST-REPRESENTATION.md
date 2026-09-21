# Revision 14 canonical manifest representation

Planning-only. R14-02 closes the R13 ambiguity between stored JSON manifests and carrier records. The sole
manifest authority is canonical object bytes in the two existing path families. Carrier frames are a deterministic
transport projection and are never a second stored manifest.

R15-03 is current for canonical ordering, payload limits, deterministic partitioning and empty-array behavior. The
stored-object authority and root preimage remain as defined here.

## One stored representation

```swift
public struct LifeOSPackManifestObjectV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let tag: String; public let packID: UUID
  public let packIndex: UInt16; public let storeID: String; public let declaredFileCount: UInt32
  public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
  public let files: [LifeOSFileManifestV6]
}
public struct LifeOSArchiveIndexObjectV7: Codable, Sendable {
  public let schemaVersion: UInt16; public let tag: String; public let archiveID: UUID
  public let preparedArtifactID: UUID; public let protection: String; public let representation: String
  public let retention: String; public let declaredPackCount: UInt16; public let declaredFileCount: UInt32
  public let declaredChunkCount: UInt32; public let declaredByteCount: UInt64
  public let packs: [LifeOSPackManifestRefV7]
}
```

`manifest/packs/%04d.json` contains exactly one `LifeOSPackManifestObjectV7`; `manifest/archive-index.json`
contains exactly one `LifeOSArchiveIndexObjectV7`. Objects use R13 canonical JSON: recursively UTF-8-key-sorted
keys, NFC strings, no whitespace, exact key sets, decimal-string unsigned integers, and no duplicate keys. The
pack array is ordered by `packIndex`; the index array is ordered by pack index. Object bytes are the UTF-8 bytes
written to disk, after canonical validation and before any carrier framing. A `.partial` path is not an object.

No carrier record is written as a manifest file. During restore, carriers reconstruct these two object byte sets and
atomically replace the same paths; a carrier sequence is invalid if its reconstruction is not byte-for-byte equal
to the canonical object produced from its validated fields.

## Hashes, counts and non-self-referential root

For a pack object, `manifestHash` is
`hex(SHA256(Frame("LifeOS/manifest-pack-object/v7", packObjectBytes)))`. For the index object,
`archiveIndexHash` is `hex(SHA256(Frame("LifeOS/manifest-index-object/v7", indexObjectBytes)))`. `packHash`
continues to mean the R12 hash of that pack's archive data and is not a manifest hash.

The exact root preimage is the canonical JSON object below; its `objects` order is packs `0000` through the last
pack, then the archive index:

```json
{"archiveID":"UUID","objects":[{"byteCount":"N","objectHash":"HEX","relativePath":"manifest/packs/0000.json"},{"byteCount":"N","objectHash":"HEX","relativePath":"manifest/archive-index.json"}],"schemaVersion":7,"totalByteCount":"N","totalChunkCount":"N"}
```

`objectHash` is the corresponding framed object hash, `byteCount` is the exact UTF-8 object byte count,
`totalByteCount` is the sum of all object byte counts, and `totalChunkCount` is the number of derived pack and
archive index chunk payloads. `manifestRootHash` is
`hex(SHA256(Frame("LifeOS/manifest-root/v7", CanonicalJSON(rootPreimage))))`. The preimage contains no
`manifestRootHash`, carrier footer, carrier digest, sink byte, or archive footer field; therefore no self-reference
exists. `manifestByteCount` in a pack footer is that pack object byte count and in the archive footer is
`totalByteCount`. `manifestChunkCount` has the analogous per-pack or total meaning.

## Carrier derivation and reconstruction

P01 derives the R13 six carrier kinds from the object, in this order: pack header, contiguous pack chunks, pack
footer for each pack, then archive header, contiguous archive chunks, archive footer. A pack chunk partitions only
the `files` array into ordered slices of 1...4,096 files; an archive chunk partitions only `packs` into ordered
slices of 1...26 refs. The header repeats the object identity/count fields, each chunk carries its first index and
slice, and the footer carries the object hash, byte count, chunk count, data `packHash` where applicable, and the
root/count fields already defined by R13. `declaredByteCount` and `declaredChunkCount` remain the domain archive
data counts; `manifestByteCount`, `manifestChunkCount` and `totalChunkCount` are the separate canonical-object/
carrier counts defined here. Footer fields prove the reconstructed object; they are excluded from it.

For a pack, reconstruction validates the header, concatenates chunk file arrays, verifies contiguous indexes and
declared counts, creates the exact `LifeOSPackManifestObjectV7`, and compares its bytes and `manifestHash` to the
footer. For the archive index, it performs the same operation over pack refs and compares `archiveIndexHash` and
the root footer. The verifier then recomputes the root preimage from all object bytes and compares
`manifestRootHash`. Missing, duplicate, out-of-order or extra carrier frames fail before projection.

```swift
public actor LifeOSManifestRepresentationV7 {
  public func stagePack(_ object: LifeOSPackManifestObjectV7) async throws -> LifeOSPackManifestRefV7
  public func stageArchiveIndex(_ object: LifeOSArchiveIndexObjectV7) async throws -> LifeOSManifestRootV7
  public func deriveCarriers() async throws -> AsyncThrowingStream<LifeOSManifestCarrierFrameV7, Error>
  public func reconstruct(_ carriers: AsyncThrowingStream<LifeOSManifestCarrierFrameV7, Error>) async throws -> LifeOSManifestRootV7
}
```

`stagePack` and `stageArchiveIndex` canonicalize, hash, fsync and atomically replace only their fixed JSON object
paths. `deriveCarriers` reads those final bytes and never reserializes a competing in-memory manifest. `reconstruct`
writes `.partial` object paths, verifies the complete root, fsyncs, then atomically replaces the fixed paths. P18
owns calls in `LifeOSDataArchiveWriter.swift`; P01 owns canonical JSON, frame and hash functions in
`SyncWireCodec.swift`/`DomainWireValues.swift`.

R13 carrier schemas remain the wire schema; this sheet defines their only authority and corrects any reading that
carrier records, carrier footer hashes or a materialized carrier index are independently persisted manifests.
