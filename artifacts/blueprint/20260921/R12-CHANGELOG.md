# Revision 12 changelog

Planning-only. No Swift/TypeScript/Python source, builds, tests, xcodegen, commits or pushes changed.

R12 closes five independent-review blockers:

- R12-01 makes P01 the sole `SyncTrustStore.swift` owner, gives P05 a P01-owned SQL port, and defines
  deterministic interrupted alias rollback/roll-forward with a whole-dataset reader fence.
- R12-02 stores the complete artifact binding in the existing receipt log and binds it from every terminal
  transition; a digest-only receipt can no longer reopen as valid.
- R12-03 defines bounded post-pack manifest carrier frames, fixed pack/index paths, streaming sink/source APIs,
  resumable chunks and an incremental verifier.
- R12-04 replaces the archive-hash placeholder with exact Swift/Python/TypeScript shapes, canonical JSON rules,
  framing bytes and a cross-language digest vector.
- R12-05 updates the current worker dispatch contract so no packet can duplicate trust, receipt, manifest or hash
  authority.
- The final audit binds every R12 symbol to an existing allowlisted path, fixes the JSON/Planning/trust recovery
  order, makes `boundAt` retry-stable, exposes the bounded manifest sink/source, and closes Python/TypeScript frame
  kind shapes so independent codecs cannot accept a loose or partial archive object.
- The ownership graph is acyclic: P18 now depends on P01/P06/P15, and P16 composition waits for P18; the old
  P16↔P18 dependency is removed.

R11-01, R11-04, R11-07, R10-04 and R10-05 now point to the R12 superseding clauses. The machine allowlist is
revision 12 with 203 unique paths and no new source path.
