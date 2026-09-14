# T0b calendar security reconciliation

Date: 2026-09-14 Europe/Berlin
Base: main 8ab5739
Reviewed source commit: e07a0a4
Worker: Harvey the 4th, gpt-5.6-luna, max reasoning
Execution verdict: source findings returned after interruption; specified worker-side test execution is UNVERIFIED. Parent ran the focused iPhone 17 simulator suite separately: 96 selected tests, 0 failures, including the new public-store regression test.

| Finding | Severity | Verdict | Current evidence |
|---|---|---|---|
| Nearby peer pairing/invitation/authentication | High | PARTIAL | OOB 32-byte pairing, pinned MCPeerID, authenticated AES-GCM handshake, opt-in discovery, and invitation gating at CalendarPeerSync.swift:266-278, 672-685, 774-788, 882-904. MCSession securityIdentity remains nil and invitation context is unused at 672-685 and 904. |
| Remote timestamps/deletions/merge injection | High | PARTIAL | Coordinator sanitizes remote paths at CalendarCoordinator.swift:826-872, 1019-1030, 1075-1084 and CalendarDomain.swift:850-976. Source commit e07a0a4 also sanitizes the public CalendarStore.merge boundary against the durable local snapshot at CalendarStore.swift:84-108. Peer transport identity remains unresolved. |
| Decoded CalendarItem/snapshot invariants | Medium | PARTIAL | Codable validation, title/item limits, and duplicate rejection on decode exist at CalendarDomain.swift:425-524, 702-734, 770-784. CalendarSnapshot(items:) intentionally deduplicates before a boundary validation at 693-750; this is a trusted local-construction compatibility path but deserves an explicit boundary contract. |
| Icon validation before ImageIO / unavailable symbol | Medium | FIXED source-level | Schema/size/hash checks precede ImageIO at CalendarIconAsset.swift:35-59, 66-81; unavailable symbols fall back at CalendarViews.swift:592-610 and CalendarView.swift:2888-2900. |
| Replay and challenge binding | Low | FIXED source-level | AES-GCM challenge binding and increasing session sequences at CalendarPeerSync.swift:358-470. Worker execution of related tests was unverified; parent’s 95-test simulator run passed. |
| Mutation ordering/concurrency | Low | FIXED source-level | FIFO coordinator operations, actor-backed store transactions, and deterministic merge ordering at CalendarCoordinator.swift:302-309, CalendarStore.swift:73-105, CalendarDomain.swift:794-813. |
| Recurrence bounds/overflow | Low | FIXED source-level | Interval/overflow guards, logarithmic window seeking, and 400-occurrence cap at CalendarDomain.swift:104-125, 164-316. |
| DST/move/resize handling | Low | FIXED source-level | Wall-clock DST, skipped/repeated-hour, move, and resize paths at CalendarLayout.swift:905-1008, 1824-2038. |

## Release residuals

- The nil MCSession security identity remains a documented limitation; frame authentication and explicit pairing are still required, but a certificate-backed transport identity is not proven.
- The lower-level store merge now has defense-in-depth sanitization in e07a0a4. Its direct API discards rejection diagnostics, and the broader peer transport identity limitation remains open.
- No finding is promoted to final product acceptance from source review alone.

## Bounded patch result

The exact two-file patch was applied and pushed as e07a0a4. Astra Medium reviewed
the patch as GREEN for this bounded scope. The regression test directly calls
the public store API, proves future remote overwrite/deletion attempts are
preserved locally, and proves a legitimate newer edit still merges. Complexity
remains O(n log n) overall with O(n) additional temporary storage.

Verification: the focused regression test passed 1/1; the selected iPhone 17
simulator suite passed 96/96 with 0 failures using -jobs 1. Simulator
entitlement and proxy-resolution warnings were present but caused no XCTest
failure. This is scoped evidence, not a product-wide security green light.

Commands: xcodebuild -list exit 0; parent focused iPhone simulator commands
exit 0; git diff --check exit 0; git push origin main exit 0.
