# Revision6 readiness — final contract closure
Verdict: **READY FOR LUNA — planning contracts sealed.**
This is an implementation-dispatch verdict, not a claim that source is complete, tested, secure, live-connected or
ready for release. The current task edited planning documents only.

|R6 blocker|Exact closure|Authority|
|---|---|---|
|Usage/Clipper absent from closed domain set|Usage local-only; Clipper read-only; leaf owners and no-replication rule|R6-01, R6-07|
|Travel/data-management schemas|Bounded local travel store and closed data registry/receipt protocol|R6-02, R6-07|
|Inbox atomicity|JSON ledger per envelope; Planning schema-v3 existing `journal.sqlite`; no second DB|R6-03|
|Recovery signing/epochs|Dedicated v2 signing bytes, trust epochs, immutable operation-key index, eight-epoch overflow|R6-04|
|Recovery retry|Receipt-first state machine, fixed projection order, crash/idempotency/disk-full rules|R6-05|
|Calendar commit/gestures|Required receipt/generation/intent signature, full context, CAS, separate gesture owners|R6-06|
|R5 name drift/false leaf owners|Signature index and noun/verb audit with Astra checkpoint rule|R6-07|

## Packet readiness
P00–P18 are READY for implementation under the R6 amendments. P01 uses R6-03…05 and R6-07; P03/P08 use R6-06;
P09/P13/P16 use R6-02/R6-07; P10 uses the R6 retention/compaction signatures; P12 keeps Usage local-only;
P02/P17 keep Clipper read-only and use the existing relay/server stores. No worker may add a closed enum case,
parallel store, generic archive, timestamp conflict winner, empty deletion payload or nonthrowing readback.

## Remaining evidence gates
U1 actual non-Uni iCloud/Obsidian vault selection and permission; U2 enrolled device/public-key fingerprints; U3 physical
iPhone HealthKit/Zepp permissions and provenance comparison; U4 Personal Team signing/App Group capability; U5 live bank
consent and actual exports; W Windows service/gateway return, ACL/DPAPI/readback and outage recovery; X installed SDK/device
captures; V final visual/motion review; S batched Astra security review. These are evidence conditions, not unresolved
architecture choices. Until evidence exists, the compile-safe behavior is the named unavailable/offline state.

## Dispatch rule
Before coding, the worker reads R6-01…07, R6-MANIFEST, the owning R4/R5 sheets and the packet allowlist. If an existing
declaration differs, stop at the R6-07 checkpoint with path/declaration/isolation evidence; do not guess or broaden scope.

## Revision7 status

This R6 verdict is historical. R7-READINESS is the current readiness authority and supersedes conflicting R6 archive,
epoch, ledger, Calendar-local-commit and data-management statements.
