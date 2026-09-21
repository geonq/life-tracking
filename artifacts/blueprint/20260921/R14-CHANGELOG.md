# Revision 14 changelog

Planning-only. No Swift/TypeScript/Python source, build, test, xcodegen, commit or push changed.

R14 closes three independent-review blockers:

- R14-01 replaces the mixed R13 receipt states with a monotonic V7 phase/cursor machine, durable manifest and sink
  finalization records, explicit artifact/archive hashes, pack-zero emission and cursor-based recovery.
- R14-02 chooses canonical JSON object bytes as the only stored manifest representation. It fixes object hashes,
  byte/count semantics, the non-self-referential root preimage, carrier derivation and reconstruction.
- R14-03 replaces temporary relocation completion with a permanently retained V8 authority marker. It defines
  authorized receipt mutations, external-modification detection, no-journal bootstrap, repeated-open behavior,
  ordered legacy deletion and protection against rediscovering pruned receipts.
- R14-04 updates Luna dispatch and makes P01/P18/P16 boundaries explicit without adding source paths.

R12-02, R12-03, R13-02, R13-03 and R13-04 now point to R14 as the current authority for their affected clauses.
The ownership audit remains 203 unique paths with no new receipt, manifest or canonical-byte authority.
