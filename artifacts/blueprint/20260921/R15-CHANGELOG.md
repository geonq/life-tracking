# Revision 15 changelog

Planning-only. No Swift/TypeScript/Python source, build, test, xcodegen, commit or push changed.

R15 closes six independent-review blockers:

- R15-01 defines the complete V7 transition, binding, compaction-anchor and finalization records, exact hash
  preimages, sinkFinalized→bound→committed calls, typed expected hashes and recovery/deletion/terminal migration.
- R15-02 unifies data-pack, carrier and final archive-footer emission under one global monotonic cursor and plan hash.
- R15-03 fixes canonical ordering, 1 MiB payload partitioning, maximal slices, empty-array chunks and a
  cross-language vector.
- R15-04 replaces the mutable V8 marker with an immutable owner-signed authority record and device-authenticated
  append-only mutation chain.
- R15-05 persists every legacy fingerprint, canonical replacement intent/commit and retirement proof with exact crash
  recovery and repeated-open behavior.
- R15-06 updates packet ownership and prohibits the superseded scalar hash, cursor and mutable marker decisions.

R12-02/03 and R14-01…04 now point to R15 as the current authority for their affected clauses. Ownership remains 203
unique paths with no second receipt, manifest or canonical-byte authority.

R16 is the current follow-up correction authority for cursor variants, sink
crash recovery, authority bootstrap and post-retirement mutation handling.
