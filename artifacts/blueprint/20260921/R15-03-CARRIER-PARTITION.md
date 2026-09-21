# Revision 15 deterministic carrier partition

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15-03 supersedes R13's non-empty-only chunk wording and R14's informal carrier partition wording.
Swift, Python and TypeScript must run
this same algorithm over the same canonical object bytes; no implementation may split an item by guessing.

## Ordering, bounds and byte limit

The canonical object is encoded first with R13 canonical JSON: recursive UTF-8 key ordering, NFC strings, no
whitespace, duplicate-key rejection and decimal-string unsigned integers. `LifeOSFileManifestV6` entries are sorted
by NFC UTF-8 `relativePath`, then lowercase UUID `fileID`; equal keys are rejected. Packs are sorted by numeric
`packIndex`; pack refs use the same order. The resulting full object bytes are the bytes hashed by R14-02.

```swift
public enum LifeOSCarrierPartitionV7 {
  public static let maxPayloadBytes = 1_048_576
  public static let maxPackItems = 4_096
  public static let maxArchiveItems = 26
  public static let maxObjectBytes = 268_435_456
  public static func partitionPack(_ items: [LifeOSFileManifestV6], packID: UUID, packIndex: UInt16,
    payloadLimit: UInt32 = maxPayloadBytes) throws -> [LifeOSPackManifestChunkPayloadV7]
  public static func partitionIndex(_ items: [LifeOSPackManifestRefV7], archiveID: UUID,
    payloadLimit: UInt32 = maxPayloadBytes) throws -> [LifeOSArchiveIndexChunkPayloadV7]
}
```

`maxPayloadBytes` is the complete UTF-8 canonical JSON payload length, excluding the outer carrier header/digest.
Production callers must use exactly 1,048,576; the `payloadLimit` parameter exists only for deterministic test
vectors and must be in `1...maxPayloadBytes`.
The R13 outer-frame maximum remains valid with this value. `maxObjectBytes` applies to each stored object. A single
encoded item greater than `maxPayloadBytes` returns `carrierItemTooLarge`; it is never split or base64-wrapped.

## Greedy maximal partition

1. Validate and canonical-encode every item once. For a pack use the ordered `files` array and limit 4,096 items;
   for the archive index use the ordered `packs` array and limit 26 refs.
2. At `chunkIndex=0`, set `firstFileIndex`/`firstPackIndex` to the next source index. Add the longest contiguous
   prefix whose complete candidate payload object, including keys, decimal indexes, brackets, commas and UTF-8 item
   bytes, is <=1,048,576. The candidate is the exact R13 chunk payload with no padding.
3. Emit that slice, increment `chunkIndex`, set the next first index to the prior first index plus slice length,
   and repeat. A pack/index with an empty array emits exactly one payload with `chunkIndex=0`, first index `0` and
   an empty array; its `manifestChunkCount` is 1. Nonempty arrays emit at least one chunk. Chunk indexes are
   contiguous and never depend on dictionary/hash iteration order.
4. The implementation may compute candidate lengths from cached canonical item bytes and fixed prefix/suffix byte
   sums; it must produce the same bytes as encoding the complete candidate object. A binary search over the maximal
   prefix is permitted. `files`/`packs` order, count and first-index fields are validated before hashing.

The pack footer receives the full canonical pack-object byte count/hash and this partition's chunk count. The archive
footer receives the total object byte count/root hash and the sum of all pack/index chunk counts. The root preimage
includes these deterministic counts, while each outer frame digest covers its own metadata and payload bytes.

## Cross-language vector

This is a partition-helper vector over already validated item bytes; the item validator runs before the helper. Use
`maxPayloadBytes=189`, `packID=00000000-0000-0000-0000-000000000000`, `packIndex="0"`, and canonical item bytes
`{"a":"0"}`, `{"a":"1"}`, `{"a":"2"}`. The canonical payload for the first candidate with two items is:

```json
{"chunkIndex":"0","files":[{"a":"0"},{"a":"1"}],"firstFileIndex":"0","packID":"00000000-0000-0000-0000-000000000000","packIndex":"0","schemaVersion":7,"tag":"lifeos.pack-manifest-chunk.v7"}
```

It is 189 UTF-8 bytes and SHA-256
`eab10aac3375e23a3265878eb5d1cc65f8689c9b8d4d36fc0a367ac937af5fdf`. The second payload contains only item 2,
has `chunkIndex="1"`, `firstFileIndex="2"`, is 179 bytes, and hashes to
`9377177763f11148677df5c540eaf01683275071e4aa71503862184b93b732c7`. Empty input produces 170 bytes with
`files:[]`, `chunkIndex="0"`, `firstFileIndex="0"`, and hash
`fc82d8a49d14de661622529755192a6c0f7bc81b4903760434aeb12354d23192`. Swift `Data`, Python `bytes` and
TypeScript `Uint8Array` tests must assert these exact UTF-8 bytes, lengths, boundaries and hashes.

Errors are `nonCanonicalJSON`, `invalidOrder`, `duplicateItem`, `itemTooLarge`, `payloadTooLarge`, `capacity`,
`countMismatch`, `digestMismatch` and `cancelled`. P01 owns the algorithm in
`ios/Sync/SyncWireCodec.swift`/`DomainWireValues.swift` and its cross-language contract; P18 consumes the returned
chunks without re-partitioning.
