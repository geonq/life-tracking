# Revision3 schema authority
Planning-only, supersedes contradictory16–26 protocol prose; all declarations are proposed source additions.
No new runtime evidence or independent Astra worker acceptance is claimed.
P01 owns Swift/TS wire contracts, P02 Python equivalents; store owners own domain integration.
Read R3-S01…S30 field tables plus R3-01-HTTP.md and R3-02-TRANSACTIONS.md together.

## Field grammar used in every schema sheet
Swift struct declarations conform Codable, Equatable, Sendable. All properties immutable let.
Python @dataclass(frozen=True) and TS readonly interfaces describe decoded values, not runtime validation by themselves.
String = Swift String / Python str / TS string. Int = Swift Int / Python int / TS number; booleans are NOT integers.
Arrays = [T]/tuple[T,...]/ReadonlyArray<T>; Bool = Bool/bool/boolean.
Nullable T? = T? / T|None / T|null. Key remains REQUIRED with JSON null; no omitted defaults on wire.
Every field uses exactly the shown camelCase encoding name; no aliases, implicit date/data encoder or synthesized enum envelope.
All wire fields required; no runtime default; unknown fields, duplicate keys, invalid UTF8/surrogates reject.
All arrays required even empty; count checked during bounded decode, not after unlimited materialization.
Version1 only; future versions unsupportedSchema; never silently downgrade/reinterpret.
Every field is persisted with its containing persisted record; transient records are explicitly marked on their sheet.
Every field is owned by the sheet's named packet; members nested from other sheets retain definition ownership.
Local migration defaults are ONLY R3-03; wire defaults never populate malformed network records.

## Primitive validators
V: Int exactly1. U: lower-case canonical UUID string36; reject noncanonical case/whitespace.
Q: canonical unsigned64 decimal string0...18446744073709551615, no leading zero except0.
POSQ: Q>=1. HASH: lowercase64 hex SHA256; never bare display revision/date.
B64: RFC4648 base64url unpadded canonical; decode/reencode equality; size checked before allocation.
KEY: B64 decoded32bytes (Ed25519); SIG: B64 decoded64bytes; NONCE: B64 decoded32 random bytes.
ID: ASCII [a-z0-9._:-]{1,160}, no paths/slashes/control; stable hash of legacy UTF8 identity when not fitting.
MSEC: Q Unix milliseconds diagnostic only; never conflict order.
Domain values: calendar, finance, fitness, planning, tax. Read-only usage/HealthKit/Clipper not editable replication domains.
StoreKind is closed enum in R3-04; no device-supplied executable/decoder selector.
Enums encode raw case string; explicit custom Codable validates all values and bounds.
Decoders must reject duplicate keys BEFORE JSONDecoder/JSON.parse/dict loses them; bounded tokenizer, depth<=32.
CP-W tokenizer implementation/API and hostile vectors requires Astra approval before P01 source dispatch.
Reject floats/exponents/negative numeric wire metadata; integer numbers <=2147483647; larger counters are Q strings.

## Canonical bytes C(x)
UTF8 RFC8785 JSON subset: lexicographic UTF16 key order, no whitespace, canonical JSON string escaping,
no floats anywhere in wire metadata; UTF8 payload content is opaque base64 bytes, not recursively canonicalized.
All keys are ASCII; strings reject unpaired surrogates. Null/booleans retain JSON tokens.
Arrays preserve specified order; set arrays sorted lexicographically on documented key, duplicates reject.
Do not use JSONEncoder.sortedKeys as proof of RFC8785 equivalence; CP-W seals exact encoder vectors.
Signature sign(T,x) = Ed25519 over UTF8("LifeOS/"+T+"/v1\0") || UInt32BE(len(C(x))) || C(x).
x omits signature ONLY; nested signatures remain. Length is UTF8 bytes, not character count.
T exactly operation, acknowledgement, membership, frame, checkpoint for respective records.
Hash of record = SHA256(signing bytes before signing); verify signature separately. Payload hash hashes raw decoded bytes.
Types/SIG examples are canonical STRUCTURAL examples; zero signatures/keys are not cryptographic golden vectors.
CP-W must replace sample signatures with independently verified vectors before execution; no example is an enrollment credential.
Invalid example on each sheet violates schema/semantics; verifier additionally rejects forged signatures.

## Identity corrections
storeID is shared LOGICAL identity for one store kind/scope across devices, allocated in owner-signed membership.
Do not randomly create distinct Mac/iPhone storeIDs for corresponding stores. Local instance identity is not wire storeID.
Sequence stream=(datasetID,storeID,originID). Domain from membership must match operation domain.
One logical store has one local durable envelope per device; store transaction owns its origin sequence.
Legacy entity identity stays unchanged locally; entityID wire is sha256 of UTF8(kind+"\0"+legacyID),64hex.
No Windows provider secret, HealthKit anchor, vault bookmark or signing key is payload content.
