# R18-07 — authoritative closure, precedence and worker dispatch

> R19-07-DISPATCH.md supersedes the six topics under review; use R19 active-schema and capacity rules. This R18 sheet is retained only where expressly compatible.

Read this first, then your packet's ORDERED contractFiles array in14-OWNERSHIP.json.
Replaces R17-08 group-only dispatch, all earlier conflicting dispatch prompts and highest-revision blanket assumptions.
203 existing path entries and packet DAG edges are unchanged; no permission to add files from historical prose.

## Exact authority and retained clauses

|topic / historical conflict|final authority|retained|
|---|---|---|
|R17-01 phase/terminal; R17-02 terminal compaction|R18-01|R17 cursor objects and numeric enums except target/retry changes below|
|R17 UUID targetKeys; R7/R9 deletion sequencing|R18-02|R7 closed26 registry and existing domain owner authority|
|R15 V6 scalar-as-file hash; R17 converter route|R18-03|R11/R12 ORIGINAL historical preimages; R15 V7 finalization/binding fields|
|R17 RecoverySink/write gap; earlier V5–V7 writers|R18-04|R17-03 wire framing/footer bounds; R17-04 recovery decision table|
|R17 unrestricted retries/compaction/pruning/caps|R18-05|R17 aggregate file authorization and phase schemas amended R18-01|
|proposed SignerCLI/PlatformVisualAdapter/ReleaseCapabilities/ApplicationServices files|R18-06|retained symbol behavior at exact relocated allowed paths|
|R17 group-only packet closure and older prompts|R18-07 +14 compiled contractFiles +11|existing203 file assignments/DAG and product requirements|
|R17-05/06/07 authority bootstrap/checkpoint/file inventory|R17 unchanged, with R18 receipt schema/digest inputs|all signatures, crash tables, trust and capacity validation|
|03/04/17/20/27 design/OS27/layout|unchanged|all features, native enhancements/fallbacks, animation algorithms and evidence gates|

Historical READY reports are archival, never acceptance. No worker may union two competing field sets or select a preferred overload.
If R18 does not amend a topic, its highest explicit historical topic authority remains binding, not whatever file happens to sort last.
R6-07 old registry/signature sections overridden by R7 remain historical; its bank bridge/initializers remain CURRENT with R5-05.
R9-02 old receipt lifecycle is historical; its domain projection marker declarations/atomicity are retained and shared by producers/consumer.

## Deterministic dependency closure algorithm

Metadata stores `contractGroups`, `packetContractGroups`, `contractDependencies`, `sharedContractConsumers`, `symbolLocations`.
For each packet: seed existing R17 group union + own R2-Pxx + explicit shared-contract entries + seven R18 sheets.
For each seed, recursively union contractDependencies[filename] until fixed point, with visited set; cycles in DOCUMENT references are harmless.
contractDependencies includes exact named sheet references and unambiguous revision-prefix references such as R5-05, resolved to real filenames.
Exclude administrative readiness/manifest/changelog/index/prompts and other packets' R2 sheets from automatic reference expansion.
Retain all prior packet contracts; no implicit subtraction. Referenced historical clauses still follow the topic supersession table above.
Compile unique list: baseline numeric filenames ascending, then revision number ascending, then filename; current R18 last.
Persist explicit array into each packet; worker reads that array, never performs its own heuristic group selection.
Source dependency DAG is independent: fixed P00..P18 dependencies in14; document-reference cycles do not authorize execution cycles.
Metadata validator checks all referenced files exist, required shared declarations in both producer/consumer arrays, unique paths and DAG cycle freedom.
Complexity O(documents+reference edges) fixed-point traversal per packet; no dependency inferred from filesystem directory globs.

## Shared declarations: mandatory producer and consumer closure

|contract|producers / consumers requiring same declaration|
|---|---|
|R5-05 READBACK +R6-07 NEW-NAME-AUDIT|P09 provider/coordinator, P16 transport/composition, P17 live deployment evidence|
|R9-02 RECEIPT-LIFECYCLE marker clauses|P01 declaration, P03 Calendar/Finance, P04 Fitness/Nutrition, P05/P06 Planning, P13 Tax, P18 verifier, P16 composition|
|R18-01/02/03/05 receipt/deletion schemas|P01 codecs, P02 host adapter, P03/P04/P06/P12/P13/P14 domain owners, P16 composition, P18 implementation|
|R18-04 writer +R17-03/04 frame/recovery|P01 codec/plan types, P18 sink/coordinator, P16 composition|
|R4-09 keys +R18-06 relocation|P01 signer, P02 bridge, P16 targets, P17 deployment|
|R4-12 platform +17/20/27 +R18-06|P07 visual adapter, P08/P09/P10/P12/P14 UI, P16 targets, P18 evidence|
|R4-RELEASE-INTERFACES +R18-06 split|P06 vault, P09 bank/net-worth, P11 health, P14 signing/widget, P16 composition, P17/P18 evidence|

The exact filename arrays and packet IDs above are expanded under sharedContractConsumers in14; prefix abbreviations in table are explanatory.
Domain projection marker stays `LifeOSProjectionMarkerV5` with R9 exact fields; declaration in P01 SyncDomainAdapter.swift ONLY.
P03/P04/P06/P13 persist marker in existing envelope/SQLite transaction with domain mutation; P18 verifies before advancing receipt.
P05 supplies Planning journal transaction; P06 adapter calls it. No marker type copied into a store or rewritten as a V8 receipt.
P01 owns R18 deletion wire/port declarations; domain owners supply implementations. P18 consumes ports without importing concrete UI.
Cross-packet fixes go to file owner. Test cases in these sheets are later implementation acceptance cases, not tests executed by planning.

## Exact dispatch phases

P00 reconciles current code/evidence and8 existing D1 files before any implementation; do not regenerate already accepted code.
P01 implements shared declarations/pure validation and publishes symbol signatures before dependent domains start.
P03/P04/P05/P06/P09/etc implement their existing packet scope plus shared ports explicitly assigned here; no P18 receipt filesystem writes.
P18-I starts after P01/P06/P15 per existing DAG: three owned Shared files implement lifecycle, deletion, migration, sink, retry and authority.
P18-I supplies source diff plus planned proof vectors; its completion is NOT final product evidence or Windows deployment approval.
P16 composes after P18-I and existing deps; membership-only project setup may be coordinated earlier to compile shared targets.
P18-E is separate controller invocation after P16 and available P17: final integrated runtime/visual/security/resource evidence in owned test/script paths.
P18-E does not become a dependency of P18-I; unavailable Windows/physical iPhone remain explicit release gates.
Test ownership: P01 pure vectors in SyncProtocolTests; domain packet tests prove own ports; P18 owns CompletionFlowsTests integration/evidence.
No repeated whole-suite build per edit. Batch meaningful checks after coherent implementations; correctness/security regressions still need evidence.
An actual conflicting source signature requires exact source evidence and targeted amendment; not a new speculative planning revision by default.
All source execution awaits geonq's final go; editor readiness is not independent acceptance or guaranteed faultlessness.
