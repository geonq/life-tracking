# Revision 15 readiness

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only. R15 changes blueprint documents only. No source, build, test, generated project, commit or push was
changed.

## Verdict

**READY FOR LUNA — all six R15 independent-review blockers are sealed.**

|blocker|sealed contract|owner|
|---|---|---|
|Receipt transitions/binding|Complete V7 transition, binding, anchor, finalization hashes, calls and V6 migration|P18/P01; R15-01|
|Hash split|Raw archive `artifactFileHash`, semantic `artifactIdentityHash`, binding hash and typed expected carrier|P01/P18; R15-01|
|Unified cursor|One global next-frame ordinal across data prefix, carriers and data suffix with closed nullability|P18; R15-02|
|Carrier partition|Canonical ordering, 1 MiB payload limit, maximal deterministic slices, empty chunks and vector|P01; R15-03|
|Authority authentication|Immutable owner record, device-authenticated append-only mutation chain and fence policy|P01/P18; R15-04|
|Relocation recovery|Per-file fingerprints, intent/commit cursor, crash branches and permanent retirement proof|P18; R15-05|

## No-guessing audit

The only terminal archive path is `sinkFinalized→bound→committed`; deletion uses the same typed operation kind with
null file/semantic hashes and a logical deletion finalization. The only physical-byte equality check is
`artifactFileHash`; identity and binding equality are checked independently. The cursor's global `frameOrdinal`
cannot reset, and pack zero is used only for pack-specific frames when a pack exists.

Canonical JSON object bytes remain the sole manifest authority. Partition output is greedy-maximal under 1,048,576
payload bytes and includes one empty chunk for an empty array. Authority state is reconstructed by replaying the
owner-signed record and authenticated mutation log; no mutable signed marker or recovery sidecar is allowed.

## External evidence gates

Cross-language vector execution, archive crash injection, real filesystem interruption/retirement, Windows/Tailscale
outage behavior, physical devices, signing/App Groups, visual/motion acceptance, storage telemetry and final
security review remain release evidence. They do not reopen a sealed planning contract or authorize a bug-free claim.

This R15 verdict is historical. R16-READINESS.md is the current readiness
authority for cursor, sink-ahead and post-retirement recovery contracts.
