# Revision 16 changelog

> HISTORICAL: R17-08 section-level authority supersedes conflicting clauses and readiness claims. Read R17-MANIFEST before dispatch.

Planning-only correction set; no source or repository history changed.

- R16-01 replaces the single R15 emission-only cursor field with one tagged V8
  receipt cursor, separate validator paths, legal phase edges and a persisted
  pre-emission record containing `manifestRootHash`.
- R16-02 defines the durable archive-frame envelope, tail scanner, receipt
  `durableFrameHash`, sink-ahead adoption, safe truncation and idempotent retry.
- R16-03 chooses strict missing-mutation-log blocking and defines the signed
  pending legacy-retirement intent, post-unlink proof and restart table.
- R16-04 defines legal post-retirement canonical updates, immutable historical
  proof/current-inventory coexistence, epoch/fence replay and bounded signed
  checkpoint rotation.
- R16-05 assigns the work without adding paths or allowing implementation
  workers to invent stores, sidecars, cursors or authority behavior.

R15-01/02/04/05 and R15-06 now point to these sheets as the current authority.
