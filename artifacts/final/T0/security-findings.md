# Claude security findings reconciliation

Updated: 2026-09-14 Europe/Berlin

Scope: the twelve High/Medium findings and the Low findings supplied by
geonq. This is a source and targeted-test reconciliation. It is not a
deployed Windows, physical-device, or network penetration certificate.

Status meanings: FIXED-SOURCE means the current checked-in boundary and
focused tests address the finding. PARTIAL means one or more trust or
deployment conditions remain. OPEN means a source or test change is still
needed. UNVERIFIED means the source may be improved but the required
runtime/deployed evidence is missing.

## Finding matrix

| ID | Status | Current evidence | Remaining gate |
| --- | --- | --- | --- |
| H1 peer admission | PARTIAL | Pairing secret, pinned peer/sender, explicit discovery setting, authenticated envelope, and invitation gate exist. | MCSession still uses no certificate-backed security identity; physical/network proof is open. |
| H2 remote timestamps | FIXED-SOURCE | Remote merge applies five-minute skew, causal clocks, deterministic ties, creation identity, and deletion checks before store merge. | Fresh deployed/server reconciliation receipt remains open. |
| H3 decoded CalendarItem | FIXED-SOURCE | CalendarItem decoding routes through validation; title, interval, timestamp, icon, item-count, and duplicate-ID bounds are enforced. | Current source build is covered; physical/runtime proof remains open. |
| H4 sync token storage | FIXED-SOURCE | The client stores no sync bearer; it stores only approved server configuration and opaque consent handoff values. | Deployed gateway secret ACL and rotation evidence remain open. |
| M5 response size/type | FIXED-SOURCE | Calendar, documents, usage, nutrition, finance, and Clipper reads use bounded collection and JSON content-type checks. | Deployed host evidence remains open. |
| M6 tax privacy | PARTIAL | Tax identifiers and evidence are redacted; pages are excluded from TaxDocument encoding; iOS writes request complete file protection. | macOS at-rest policy, legacy migration, and deployed sync exclusion need proof. |
| M7 CSV formula injection | FIXED-SOURCE | Export prefixes formula-leading and control-leading values before CSV quoting; focused tests cover it. | No remaining source action identified. |
| M8 tax atomic save | FIXED-SOURCE | Same-directory temporary writes use atomic replace/move and cleanup on failure. | Power-loss durability is not physically certified. |
| M9 usage temp symlink | FIXED-SOURCE | Atomic writer uses O_EXCL/O_NOFOLLOW, a 0700 parent policy, descriptor/path identity checks, flush, and rename. | Deployed ACL/reparse evidence remains open. |
| M10 localhost Host | FIXED-SOURCE | API requires loopback transport plus an exact loopback Host and bound port; JSON responses set nosniff. | Served deployment and browser/runtime evidence remain open. |
| M11 Windows Codex path | FIXED-SOURCE | Launch uses an absolute regular-file allowlist, fixed System32 cmd path for .cmd, no shell mode, and safe working directory. | Windows deployment/ACL proof remains open. |
| M12 secret comparison | FIXED-SOURCE | SHA-256 digests feed timingSafeEqual and startup validation enforces bounded minimum secret length. | Deployed configuration rotation evidence remains open. |
| L1 tax regex ReDoS | OPEN | Input is bounded, but the money regex still has nested repetition and has no adversarial fuzz receipt. | Replace or fuzz the pattern and record time/RSS bounds. |
| L2 corrupt history line | FIXED-SOURCE | JSONL decoding filters damaged records individually while retaining valid neighbours and fails closed for unusable state. | Multi-process file behavior remains unverified. |
| L3 history race | PARTIAL | A per-path in-process mutation queue serializes API writers. | Cross-process locking is not implemented or proven. |
| L4 duplicate calendar IDs | FIXED-SOURCE | Snapshot decoding rejects duplicates; merge uses explicit uniquing logic and no fatal unique-key initializer. | No remaining source action identified. |
| L5 icon decode order | FIXED-SOURCE | Version, byte-size, hash, and format checks precede ImageIO decoding. | No remaining source action identified. |
| L6 dependency audit | UNVERIFIED | CI pins checkout and XcodeGen artifact/version/digest; current dependency advisories still need a fresh audit receipt. | Run the dependency audit and update only if it identifies a real fix. |
| L7 CI supply chain | FIXED-SOURCE | Workflow permissions are read-only; actions and XcodeGen are pinned and the XcodeGen archive digest is checked. | Hosted workflow execution remains a release gate. |
| L8 dashboard CSP | FIXED-SOURCE | Dashboard index and Vite served headers define a restrictive CSP; no unsafe HTML sink was found. | Served production header proof remains open. |

## Current security conclusion

The checked-in source is materially hardened, but the security gate is not
green. H1, M6, L1, L3, L6, and every deployed/Windows/physical proof item
remain open or partial. No canonical Windows recovery or installation was
performed during this reconciliation.
