# Packet B design — durable publication protocol

Date: 2026-09-19 Europe/Berlin. Base: e29b317.
Status: READY FOR LUNA after Astra Medium source review. This plan is
implementation guidance; it is not an overall release approval.

## Objective

Harden the accepted PlanningMutationJournal before a filesystem publisher is
introduced. Add enforced publication transitions, durable conflict decisions,
queued keepBoth child mutations, progressive bounded recovery, and retention
guards. Keep filesystem access, bookmarks, entitlements, UI, gateway, and
physical-device work in later packets.

## Exact file boundary

Add ios/Planning/PlanningPublicationDomain.swift.
Modify ios/Planning/PlanningMutationJournal.swift.
Modify ios/LifeOSTests/PlanningMutationJournalTests.swift.
Modify ios/LifeOSTests/PlanningStorageDomainTests.swift.
Modify ios/LifeOSMacSnapshotTests/PlanningDurabilityTests.swift.
Add this receipt as artifacts/final/planning-core/packet-b-publication-20260919.md.
Do not modify codecs, PlanningVaultBinding, PlanningStorageDomain,
PlanningConflictResolver, project.yml, entitlements, app entry points, views,
gateway, or transport.

## Current gaps to close

- beginPublication permits multiple attempts and can regress publishing to prepared.
- recordStagedIdentity lacks current-attempt/legal-phase checks.
- recordPublicationOutcome lacks publishing-phase/current-attempt/exact-result checks.
- recordConflict can replace evidence and resolveConflict is not durable/idempotent.
- keepBoth does not create a queued sibling mutation.
- recovery starts at the oldest entries and can starve later work.
- compaction can remove payloads still needed by resolved conflicts.
- persisted attempts/state are not fully validated on reopen.

## Required source design

Add validated Codable publication context, attempt snapshots, recovery cursor/page,
and durable resolution record. Include selection generation, root/observed identity
and version, attempt ordinal, phase, witness, outcome, retry date, legacy flag,
decision fingerprint and optional child mutation. Reject NUL/oversized/nonfinite
or invalid identity/version data; additive unknown fields remain compatible.

Add an atomic schema-v2 migration under the existing writer lock. Preserve v1
fingerprints and evidence. Add publication_details and conflict_resolutions with
foreign keys, unique constraints, bounded JSON, and indexes. Validate v1 fully
before an exclusive transaction; create tables; migrate legacy attempts as
legacy_unverified in deterministic order; validate; set PRAGMA user_version=2;
commit. Any failure rolls back and leaves the original usable. Fresh databases
are v2. Unsupported/malformed schemas remain untouched.

Enforce one active attempt. Keep old signatures for compatibility, but require
validated context for markPublishing. Legal transitions are staged/prepared →
stageReady → publishing → published, with delete-specific prepared → publishing.
Reject stale/competing attempts, illegal calls, contradictory terminal replay,
and retry of publishing without filesystem reconciliation. Create/replace result
must equal proposed bytes version; delete result is absent. Store outcome and
receipt changes transactionally. Witness basename is generated and validated.

Bind conflicts to immutable mutation fields and local bytes. Identical conflict
replay is idempotent; changed reuse and multiple open conflicts fail. Persist a
stable length-prefixed decision fingerprint. Repeated same decisions return the
same child; different decisions fail. applyLocal/applyMerged/keepBoth changes,
reservation, parent and conflict state commit together. keepBoth creates one
queued .create child with a bounded sibling path and original bytes; it is not
reported as published.

Add keyset recovery pages with frozen maximum sequence, at most 32 candidates
and 16 MiB materialized payload per page, running byte budget, monotonic deadline,
cursor progress past blocked entries, no hidden drain loop, bounded retry backoff,
and explicit caps of 64 attempts/mutation and 16,384 retained records. Preserve
ambiguous publishing evidence and never auto-resolve conflicts.

Make compaction retain every payload referenced by retained conflicts, including
resolved ones, and all payloads needed for fingerprint/replay. Delete only truly
unreferenced data in bounded batches. Preserve 64 MiB payload and 256 MiB database
limits; distinguish SQLITE_FULL from SQLITE_IOERR; do not add terminal pruning.
Keep NSLock/process writer lock and never perform external work inside SQLite
transactions. Accepted work survives an eight-day Windows outage.

## Tests and evidence

Retain all 19 existing Mac durability methods. Add 24 new methods: 4 migration,
6 publication, 5 conflict, 4 recovery, and 5 capacity/security. Target 43/43
focused Mac tests. Add 8 portable journal tests and 4 publication-domain tests.
Use tiny bounded fixtures, fake clocks/caps, 33–65 mutations for pagination,
and no personal vault/iCloud/Windows writes. Reopen after durable-boundary
interruption; do not call orderly close a crash test.

Run storage guard; one serial Mac build-for-testing; focused runtime lane;
independent xcresult validation; one generic iOS device SDK build-for-testing;
git diff --check and exact-path audit. Use fresh owned paths, jobs=1, and
parallel-testing-enabled=NO. Record counts, exit codes, paths, storage headroom,
resource limits, and simulator limitation in the receipt.

## Astra acceptance

Reject if scope expands, migration drops/invents evidence, Packet A validation
weakens, an ambiguous publication is retried blindly, a child is duplicated,
compaction breaks reopen, capacity checks follow allocation, a crash appears,
storage guard fails, or tests cannot preserve replay semantics. Acceptance requires
all 43 Mac tests, iOS SDK build, deterministic transitions/resolution replay,
progressive recovery, safe compaction, and explicit deferred filesystem gates.

Deferred: filesystem adapter/bookmarks/entitlements/descriptor containment, real
Mac↔Obsidian writes/crash/symlink tests, terminal archive/reclamation, graph/UI,
gateway/cross-device wiring, simulator and physical iPhone evidence.
