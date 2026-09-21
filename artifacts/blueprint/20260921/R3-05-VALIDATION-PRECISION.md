# Wire decoder and admission precision amendments
P01 owns Swift/TS functions; P02 Python equivalent. Supersedes ambiguity in earlier field tables.
No source implemented; CP-W requires independent review/golden vectors, not worker API invention.

## Required decoding/encoding entry points
Swift: enum SyncWireCodec { static func decode<T:Decodable & Sendable>(_ type:T.Type,from:Data,limit:Int) throws -> T;
static func canonicalBytes<T:Encodable & Sendable>(of:T) throws -> Data }.
Python: decode_wire(record_type:type[T], raw:bytes, limit:int)->T;
canonical_bytes(value:WireValue)->bytes. WireValue is the restricted JSON tree below, not arbitrary object reflection.
TypeScript: decodeWire<T>(raw:Uint8Array,validator:(value:unknown)=>T,limit:number):T;
canonicalBytes(value:WireValue):Uint8Array. Validators are compile-time named per sheet; no dynamic import.
Each sheet type implements init(from decoder:Decoder) throws and encode(to encoder:Encoder) throws in Swift.
Check container.allKeys equals exact declared CodingKeys set; tokenizer must already have rejected duplicates.
Nullable decode: contains(key) MUST be true; decodeNil then explicit nil else decode(T.self,forKey:).
Nullable encode: encodeNil(forKey:) when nil, not encodeIfPresent; required arrays encode even empty.
Perform semantic/cross-field validation before constructing value, after bounded lexical decode, before any mutation.
Each proposed type has func validate() throws; error throws SyncError with exact code/no raw message.
SyncError is also Swift Error; no unbounded underlying error description crosses wire/UI/log boundary.
Nested records without schemaVersion inherit the version of their enclosing versioned sheet.
Limits check raw bytes first, depth32, decoded strings <=body cap, per-field smaller bound and array count during parse.
Swift/Python/TS decode integers as exact integers; Python bool explicitly rejected as int; no coercion of string counters.

## Required canonical tokenizer contract — CP-W acceptance target
Tree: null, Bool, integer0...2147483647, valid Unicode String, bounded Array, object with unique ASCII keys.
No numbers with sign/fraction/exponent; Q counters are strings with exact grammar from R3-00.
Object keys emitted sorted ASCII (equivalent UTF16 for these keys); string values retain scalar sequence, no NFC rewrite.
Escape quotation mark/backslash and control chars per RFC8785; emit other Unicode UTF8, no slash escaping.
No whitespace outside strings; byte length prefix UInt32BE. Do not sign the hexadecimal bodyHash instead of framed bytes.
CP-W must document parser functions/scanner states, exact byte escape table and independent cross-language golden vectors
before implementation. These codec names alone do not satisfy that gate; no chosen third-party tokenizer is implied.

## Receipt identity and conflict hashes
operationHash=SHA256(operation signing bytes), never signed-record JSON hash or only payload hash.
conflictID=SHA256(C(sorted operationHash strings)); heads/parents still mutation UUIDs, not hashes.
SyncAck.resultHash: stored=operationHash; applied=entity versionHash at first apply;
retainedConflict=conflictID at first retention. Freeze result in first receipt transaction; replay returns original hash.
Subsequent edits cannot change an existing ACK's resultHash. Immutable receipts indexed by dataset/mutation/replica/level.
SyncCommitReceipt.entityVersion is committed SyncEntityVersion.versionHash, including multihead set on conflict.
A later resolution creates a new mutation/ACK; never rewrite earlier retainedConflict receipt as applied.
SyncOutboxEntry acknowledgements includes origin's own applied receipt after local commit; required replica set from membership.
Outbox ready→awaitingAcks only after authenticated stored ACK; timeout leaves entry retryable with SAME operation.
Attempts increments saturating on admitted send attempt, reset policy never changes immutable operation identity.
No wall-clock expiry deletes pending entries. Receipt/outbox housekeeping writes do not allocate domain sequence.

## Sequence, paging and bounds
Server admission per stream accepts next contiguous sequence only; greater returns missingParent with no stored receipt.
Same previously stored sequence+identical hash returns alreadyStored; different identity returns idCollision.
Sort submitted operations by originID then UInt64 sequence; within batch accepted prefix can advance next sequence.
Incoming causal parent from another stream may await delivery in inbox; server does not interpret entity business logic.
Freeze upper to server contiguous received frontier after submission commit. Reject upper beyond current durable frontier.
Page unique rows received<sequence<=upper ordered originID/sequence, stop before either count or byte cap.
The128-result+128-ACK response may not fit for arbitrary inputs: precompute serialized response size before transaction;
reduce accepted request size by rejecting whole request capacity if mandatory results/ACKs exceed body cap.
Optional download page takes remaining response budget; more=true when below-upper rows remain, even empty download.
A single envelope exceeding allowed byte budget rejects capacity; never silently omit mandatory operation result.
Client persists downloaded inbox before advancing received and requesting next page; no-gap frontier never max(observed).
Local envelopes retain signed operation bytes/receipts referenced by entity heads until a sealed checkpoint substitutes them.
Sequence exhaustion at UInt64.max rejects capacity before allocation; never wrap/reset stream.

## Error and transport envelope exceptions
Success status is200 for every documented endpoint; signed responses require actual HTTP status==frame.status.
Reject unexpected status/path/method/nonce/requestID/endpointID before decoding success body.
Untrusted failures use SyncPublicError (R3-S29); no body message, dataset, stack, trust membership or retry state.
Health uses SyncHealth (R3-S30); no separate runtime/version response. Authenticated errors use complete SyncError fields.
405 wrong method,404 unknown route,413 overflow,415 unsupported MIME,429 admission cap are public errors before trust;
their code is respectively invalidInput,invalidInput,capacity,unsupportedMedia,busy;401 unauthenticated otherwise.
Retry-After may accompany429; public errors cannot alter durable identity/ACK/epoch. Raw proxyHTML never parsed as wire.
No per-device capability means file access: membership controls known store kinds, not arbitrary path/decoder input.

Local commit advances own received/applied contiguous stream along with unsigned outbox; signing bytes already frozen.
Applied receipt material is committed atomically, signed after commit; no receipt may claim a later projection instead.
Unsigned outbox signature-empty exception is confined to local envelope decoding, never generic SyncOperation wire decoder.
