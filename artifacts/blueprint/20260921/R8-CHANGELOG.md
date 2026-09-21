# Revision8 changelog

Planning-only. No Swift/TypeScript/Python source, generated project, build, test, xcodegen, commit or push was touched.

1. Replaced the single R7 epoch field with an owner-authenticated historical chain whose coverage proves every retained
   operation source epoch, including ordering, roots, verification and atomic trust installation.
2. Reconciled R3 UUID store IDs with R7 kind IDs through a signed alias table and versioned resolver that preserves
   legacy signed bytes, stream positions, checkpoint hashes and transport negotiation.
3. Sealed mapping, alias, table, chain and deterministic UUIDv5 preimages, canonical encoding and collision rejection.
4. Replaced interval-only Calendar gestures with complete create/update fields, explicit metadata, resize contexts,
   tombstone derivation and separate local-operation versus replicated-admission call paths.
5. Added unique recovery/data-management receipt identities, exact transition hashes, lineage, crash resume and a
   bounded, content-addressed pruning rule.
6. Replaced whole-pack export interfaces with bounded frame streams, sink ownership, fsync/atomic finalization,
   cancellation, resume and gateway/disk-full behavior without decoding a file into memory.
7. Reconciled all retained P00–P18 manifests with one canonical ownership/dependency table and machine-readable R8
   allowlist metadata; R7-06's conflicting packet table is explicitly historical.

R8 audit result: no new architecture contradiction remains in the seven reviewed areas. External device, service,
signing, visual and security evidence gates remain release work and are listed separately in R8-READINESS.

## Revision9

R9-01…06 close the next independent review: Calendar command plumbing, receipt preparation/finalization and cursors,
typed chunk frames/backpressure, resumable alias migration, detached handshake signing and one canonical allowlist.
