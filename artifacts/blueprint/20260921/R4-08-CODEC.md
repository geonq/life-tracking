# Canonical codec implementation contract — CP-W sealed
P01 ios/Sync/SyncWireCodec.swift, packages/contracts/src/replication.ts; P02 services/gateway/replication.py.
No JSON.parse/JSONDecoder first-pass on untrusted bytes: duplicate names must be caught before dictionary construction.
No new codec dependency; bounded LifeOS restricted-JSON scanner, not a general ECMAScript-number implementation.

## Exact types and parser functions
Swift indirect enum WireJSON:Equatable,Sendable { case null,bool(Bool),integer(UInt32),string(String),array([WireJSON]),object([WireMember]) }.
WireMember:Equatable,Sendable {let key:String;let value:WireJSON}; object order retained until canonicalization; duplicate rejected.
WireDecodeError:Error,Sendable {case invalidUTF8,unexpectedToken,duplicateKey,unknownKey,missingKey,invalidNumber,
invalidUnicode,depthLimit,byteLimit,countLimit,trailingBytes,invalidBase64,invalidSignature,invalidHash,unsupportedVersion}.
Map invalidSignature→unauthenticated,invalidHash→hashMismatch,limits→capacity,unsupportedVersion→unsupportedSchema,others→invalidInput.
Swift struct WireScanner { var offset:Int; let bytes:[UInt8]; let byteLimit:Int;
mutating func value(depth:Int)throws->WireJSON; mutating func object(depth:Int)throws->[WireMember];
mutating func array(depth:Int)throws->[WireJSON]; mutating func string()throws->String;
mutating func integer()throws->UInt32; mutating func skipWhitespace(); mutating func literal(_ expected:[UInt8])throws }.
Python class WireScanner methods value/object/array/string/integer/skip_whitespace/literal with same integer byte offset;
TS class WireScanner same camelCase methods, Uint8Array input; neither uses generic JSON parser to detect duplicate keys.
WireScanner.parse(_ bytes:Data,limit:Int)throws->WireJSON validates cap,UTF8; value(depth:0); skips final whitespace; requires EOF.
Whitespace is only0x20/0x09/0x0a/0x0d. Empty input/invalid UTF8/BOM reject. Depth>32 rejects before nested allocation.
value dispatch byte { [ " t f n 0...9; anything else rejects. Keywords exactly true/false/null with delimiter after.
integer consumes0 alone or1...9 followed by digits, checked multiply/add<=2147483647; next byte must delimiter;
reject -,+,fraction,e/E,leading0,NaN,Infinity; all larger/signed/domain numbers are R4-01 strings.
array: consume[, allow immediate], else value/comma loop; reject trailing comma; max10000 and type-specific lower count on decode.
object: consume{; key must string and ASCII, decoded-key Set insertion must be new; colon then value; comma loop;
max128 members; reject trailing comma. Enforce field exact-key set in typed decoder, not scanner schema inference.
string: consume quote; scan UTF8 runs; escape states accept ",backslash,slash,b,f,n,r,t,u+4hex only;
u high-surrogate requires immediately escaped low-surrogate; combine scalar; lone high/low surrogate rejects.
Unescaped controls<0x20 reject; append decoded scalar UTF8 with byte cap BEFORE append; no normalization of text.

## Canonical writer
WireCanonical.encode(_ value:WireJSON,limit:Int)throws->Data;
appendValue(_:to:),appendString(_:to:),appendInteger(_:to:) checked-output cursor in preallocated bounded buffer.
Object keys sorted ASCII lexicographic (our keys ASCII, equal to RFC8785 UTF16 order); preserve array order.
Strings escape quote/backslash, use short b/t/n/f/r for8/9/10/12/13; other0...31 lowerhex4digit u escape;
all remaining Unicode scalar UTF8 unchanged, including slash and U+2028/U+2029. Never escape all nonASCII.
Boolean/null literal; integer base10 no padding; no whitespace. Domain F64/I64 values remain quoted strings.
Require decoded typed DTO's exact keys and semantic validation; reserialize to canonical bytes for signing, preserve nested signatures.
No dependence on locale/Foundation date encoding/JS floating point. Output size cap checked during emission.
Complexity parseO(bytes), storageO(bytes); sortO(sum objectKeys log keys), count<=128/object. No per-frame use.

## Signature/hash functions
SyncWireCodec.signingBytes(kind:SyncSignedKind,value:WireJSON)throws->Data:
remove exactly TOP-LEVEL signature property, require it in original signed DTO; don't remove nested signatures.
Let C=canonical bytes; output UTF8('LifeOS/'+kind.rawValue+'/v1')+single0byte+UInt32BE(C.count)+C.
Kinds operation,acknowledgement,membership,frame,checkpoint,observation only (R4-15 addition); signature Ed25519 (not prehash variant).
Signature=CryptoKit Curve25519.Signing.PrivateKey.signature(for:bytes); verify publicKey.isValidSignature(_:for:).
Python Ed25519PrivateKey.sign(bytes)/Ed25519PublicKey.verify(signature,bytes); TS verification Node crypto.verify(null,bytes,key,sig).
TS raw32byte Ed25519 key imported with fixed SPKI prefix hex302a300506032b6570032100; no caller-controlled algorithm.
operationHash=SHA256(signingBytes); payloadHash=SHA256(exact raw payload); keyID=SHA256(raw public key32bytes).
decodeSignedFrame(_ bytes:Data,expected:FrameExpectation,trust:SyncTrustRecord)throws->SyncSignedFrame validates
status/method/path/requestID/nonce/endpoint/epoch/keyID/bodyHash before decoding body into exact route type.
Comparison of secret digests uses library timing-safe API, never a hand-rolled byte loop; public IDs use ordinary equality.
Canonical signing always validates sorted parents/unique IDs; reordered invalid parent arrays reject instead of silently sorting on receive.

## Fixed byte fixtures (documentation, not an executed test)
Input {"z":null,"n":"9007199254740993","a":"é"} canonical UTF8 {"a":"é","n":"9007199254740993","z":null}.
Empty-object canonical bytes7b7d; operation-domain signing bytes are hex
4c6966654f532f6f7065726174696f6e2f763100000000027b7d.
This is a codec byte fixture, not a valid operation. Empty array5b5d; true74727565; quoted newline225c6e22.
Reject duplicate decoded keys {"a":1,"\u0061":2}, sequence metadata number9007199254740993, invalid surrogate,
unknown root version, altered nested payload hash, wrong epoch, and trailing bytes. Every failure before state mutation.
Execution validation compares independent Swift/TS/Python bytes and RFC8032 section7.1 Ed25519 vectors;
no cryptographic test executed or sign-off claimed in this planning phase. Fixed API+bytes are not deferred design decisions.
References: [JCS](https://www.rfc-editor.org/rfc/rfc8785), [Ed25519](https://www.rfc-editor.org/rfc/rfc8032),
[Apple key](https://developer.apple.com/documentation/cryptokit/curve25519/signing/privatekey),
[Python Ed25519](https://cryptography.io/en/latest/hazmat/primitives/asymmetric/ed25519/).

## Revision5 bounds
R5-06 fixes the archive acknowledgement limit at 10,000 in Swift, Python and TypeScript. The scanner's 10,000 array
limit and every archive/recovery decoder use that same constant; a 10,001-element ACK array is rejected before allocation.

## Revision6 supersession
Recovery archive signatures use the separate `LifeOS/recovery-archive/v2` domain in R6-04; SyncWireCodec operation/frame
domains remain R4 v1. R6-03 applies the same scanner bound to JSON ledgers and Planning envelope reconstruction.
