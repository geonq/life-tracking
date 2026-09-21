# R11 HTTP blob and route size bounds

Planning-only. This sheet amends R10-02 so a full 262,144-byte blob chunk is valid after base64url and JSON
overhead, while every route remains bounded before allocation.

## Final route caps

`rawRequestCap/rawResponseCap` are HTTP body bytes, including JSON syntax and base64; the decoder rejects a
larger `Content-Length` and a streaming counter rejects a larger chunked body. `decodedPayloadCap` applies after
envelope decoding.

|route|request cap|response cap|decoded payload cap|
|---|---:|---:|---:|
|`POST /challenge`|1,024|1,024|512|
|`POST /hello`|32,768|32,768|16,384|
|`POST /exchange`|2,097,152|2,097,152|1,048,576|
|`POST /ack`|262,144|262,144|131,072|
|`POST /blob`|524,288|65,536|262,144|
|`POST /blob/read`|32,768|524,288|262,144|
|`GET /health`|0|256|256|

Every authenticated response also carries the R11 nonce/signature headers; their worst-case JSON/header
overhead is included in the table. JSON is UTF-8 `application/json`, `Content-Length` is mandatory, and
transfer-encoding is rejected. Raw HTTP caps are enforced before base64 or JSON allocation.

## Blob limits and exact overhead proof

`SyncBlobChunkV6.maxDecodedBytes = 262_144`; a nonfinal chunk is exactly 262,144 bytes and the final chunk
is 1...262,144 bytes. Its base64url field is unpadded and is at most 349,528 bytes (the padded upper bound is
used for validation). The complete `/blob/read` envelope, including nonce fields, headers represented in JSON,
and error slack, is capped at 524,288 bytes; the specified worst case is 349,528 + 8,192 = 357,720 bytes.
The server rejects a client `limit` outside 1...262,144 or a nonfinal offset that is not a multiple of
262,144. A blob is at most 32 MiB and its declared chunk count is `ceil(byteCount/262144)`; zero-byte blobs
have zero chunks.

```swift
public enum SyncBlobLimitsV6 {
 public static let chunkBytes: UInt32 = 262_144; public static let blobBytes: UInt64 = 33_554_432
 public static let readRawResponseBytes: UInt32 = 524_288
 public static func validateRead(limit: UInt32, offset: UInt64, total: UInt64) throws
}
```

`POST /blob` accepts one chunk plus metadata and stores it only after hash/index/offset validation. `/blob/read`
returns one chunk, its raw byte count and hash; it never streams multiple chunks. A missing blob is 404, an
offset past the declared length is 416, a hash mismatch is 422, and a cap violation is 413. All ordinary files
remain <=4 MiB, domain envelopes <=32 MiB, and these HTTP bounds do not enlarge either store. P01 owns constants
and bounded decoding; P02 owns preflight counters and route mapping. A route is not ready if its code path can
decode the body before checking the corresponding cap.
