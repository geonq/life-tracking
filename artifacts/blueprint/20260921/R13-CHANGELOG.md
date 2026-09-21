# Revision 13 changelog

Planning-only. No Swift/TypeScript/Python source, builds, tests, xcodegen, commits or pushes changed.

R13 closes three independent-review blockers:

- R13-01 defines all six manifest carrier wire payloads, metadata nullability, index locations, length bounds,
  canonical bytes, cross-language codec entry points and closed validation errors.
- R13-02 separates staged manifest files and hash finalization from sink emission, binds every footer to finalized
  refs, defines durable sink calls, exact output order, receipt cursors and crash resume.
- R13-03 makes `Application Support/LifeOS/Receipts` the sole post-migration authority and defines fixed-path
  discovery, V5/V6 validation, prefix/conflict merge, fencing, atomic relocation and resumable recovery.
- R13-04 updates worker ownership without adding a source path; P01 owns codecs, P18 owns production/relocation,
  and P16 waits for their reports.

R12-02, R12-03 and R12-05 now point to R13 as the superseding authority. The R13 ownership audit retains 203 unique
paths and introduces no second receipt, manifest or canonical-byte authority.
