# Revision 17 changelog

> R18 supersedes the seven audit topics listed in R18-07-DISPATCH.md. This sheet is retained only for clauses not replaced there; prior readiness is historical.


Planning-only response to all eight R16 independent audit blockers.

1. Replaced incomplete cursor structs with one exact tagged object, V8 phase/operation table and full validator context.
2. Added complete V8 file/log/snapshot/transition/anchor, authenticated migration rebasing, independent compaction and maximum-work capacity calculation.
3. Corrected outer bounds for BOTH data and manifest inner frames, partition-index limit, boundary vectors and sole footer ownership.
4. Unified recovery API with actual bytes/plan access, fsync-before-adoption, exhaustive errors, current-head CAS and linear scan strategy.
5. Replaced authority flat optionals with discriminated persisted payloads, complete signed retirement proofs and first-bootstrap Keychain seal recovery.
6. Defined signed checkpoint payload/root, bounded aggregate terminal roots, pending-intent recovery and atomic log rotation.
7. Defined exact three-file inventory/root hashes, receipt-to-file operation mapping and replacement/commit crash table.
8. Added per-packet explicit ordered contractFiles arrays and section-level supersession; split P18-I implementation from P18-E final evidence.

Historical R15/R16 sheets now open with supersession notices. Index and ready-to-send prompts point to R17.
14-OWNERSHIP metadata/read maps changed; all203 source-path assignments and packet dependencies remain identical.
No source/test/project/dependency edit, build, test, generation, commit or push performed by this revision.
