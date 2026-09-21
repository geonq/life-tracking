# Revision4 canonical domain value rules
Planning-only. Supersedes CP-S placeholders and contradictory R3 domain-value encoding instructions.
R4-V-* sheets enumerate every field of57 transport structs; R4-ENUMS-* freezes38 raw enum alphabets.
P01 adds ios/Sync/DomainWireValues.swift; P03/P04/P06/P13 implement explicit converters in their adapter files.
These are DTOs, never new domain stores. Existing validated domain values remain application authority.
Every Wire4 field is REQUIRED, nullable fields explicitly null; encoding name equals property; no omitted defaults.
No unknown/duplicate keys accepted in a known version. Root schemaVersion=1; tag fixes one decoder.
All listed DTO fields persist within operation bytes/checkpoint archives; no device secret/bookmark/query anchor may appear.
Python dataclasses/TS interfaces describe the same transport; server need not construct Swift business models.
Swift Codable methods manually enforce contains/null/unknown-key checks via R4-08 bounded scanner.

## Exact scalar conversion functions in DomainWireValues.swift
WireScalar.uuid(_ value:UUID)->String = value.uuidString.lowercased(); uuid(_ text:String)throws->UUID requires canonical roundtrip.
WireScalar.integer(_ value:Int)->String = base10 Int64, no plus/leading zeros/-0; parseInteger(_:)throws->Int exact Int64.
I64 range -9223372036854775808...9223372036854775807; domain validators impose narrower/nonnegative limits.
WireScalar.f64(_ value:Double)throws->String =16 lowercase hex digits of value.bitPattern; reject NaN/infinity.
WireScalar.parseF64(_ text:String)throws->Double parses exactly16hex digits then Double(bitPattern:); reject nonfinite.
Dates use F64(Date.timeIntervalSinceReferenceDate), epoch2001-01-01T00:00:00Z; decode Date(timeIntervalSinceReferenceDate:).
Bit-pattern encoding preserves submillisecond dates/quantities without JS number serialization or rounding migrations.
Do not reinterpret these strings as wall-clock order; causal parents order changes. Legacy dates decode through existing store codec.
Python F64: struct.pack('>d',value).hex(), inverse struct.unpack('>d',bytes.fromhex(text))[0]; reject nonfinite.
TS F64: DataView.setFloat64(0,value,false),8bytes lowercase hex; inverse getFloat64(0,false); validate finite.
UUID/int/F64/String all JSON strings, Bool JSON bool; new root version/count metadata remain JSON integer per R3.
WireScalar.bytes(_ data:Data)->String base64url unpadded; inverse bounded by field before allocation.
String default <=4096UTF8 bytes, no NUL; IDs<=256bytes, timezone<=128 and TimeZone(identifier:) nonnil;
calendar title<=240UTF8, barcode8...14ASCII digits, hashes64lowerhex, URL<=2048 and http/https only.
Preserve source strings without Unicode normalization; strictly valid Unicode, no unpaired surrogate. Newline allowed in notes.
Arrays max10000, nested depth32, total domain payload<=32MiB; smaller domain bounds below prevail.
Ordered arrays preserve order; sets sort explicit ID and reject duplicates. Never sort exercise/set/node display order incidentally.
After conversion call existing validated initializer/validatedForPersistence; failure invalidInput, never silently sanitize wire.
No new all-unknown defaults. Legacy aliases/defaults happen once via old decoder before fromDomain.

## Exact associated-value replacements
Wire4FinanceAllocationShare {tag:String,value:String}: tag percentage or fixedCents; value I64; percentage0...100/fixed>=0.
fromDomain switch .percentage(n)/.fixedCents(n); toDomain inverse, same source validation.
Wire4FinanceTrackingFrequency {tag:String,day:String?}: weekly/biweekly/monthly require null day;
customDayOfMonth requires I64 1...31. No invented schedule default.
Wire4SupplementScalarValue {tag:String,stringValue:String?,numberValue:String?,boolValue:Bool?}:
string/number/bool require exactly matching slot nonnull; null requires all slots null. Number=F64.
Wire4CalendarIconAsset explicit schemaVersion='1',contentHash=SHA256(bytes),format png/jpeg,bytes base64url<=256KiB;
verify digest/magic/size before existing CalendarIconAsset initializer; image<=2048each/4million pixels/single frame.
Wire4CalendarItem excludes occurrenceSourceID; fromDomain requires nil, toDomain leaves nil. No transient recurrence expansion on wire.
Wire4Source.demo forbidden on live replicated journal; automatic observations are derived, never promoted to editable manual facts.
Photo lineage only hashes/IDs/provider metadata; no image bytes, prompt text or credentials in DTO.

## Evolution and backward compatibility
Unknown future root version/tag: retain authenticated operation in inbox as blocked unsupportedSchema, no applied ACK.
Legacy JSON defaults remain old decoder-only; migration validates entire source before publishing new wrapper.
Old local files kept exact hashed backup; no rewriting legacy pending request bytes/revisions or stripping metadata for downgrade.
Older peers cannot accept v1 domain DTO without corresponding membership payloadVersion1; do not fall back to old unsigned sync.
All fieldwise converters are O(fields+bytes); array conversions O(elements), dictionary identity checks expectedO(n).
Converters never access disk/network, actor state or current wall clock. Pass all timestamps from original domain value.
