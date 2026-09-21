# Revision 2 — architecture amendment
Status: PLANNING ONLY; no implementation authorization. Date: 2026-09-21.
Parent: blueprint committed at 321a2b5. Documents 01–15 remain historical and unchanged.
Precedence: explicit current user instructions > revision 2 > conflicting revision 1 prose.
Author: current controller, GPT-6; no callable subagent launcher was exposed in this session.
This is NOT an independently completed Astra Medium worker review. Astra sign-off remains CP-A.
No plan guarantees zero defects. Named checkpoints prevent workers guessing unresolved details.

## Corrections
- Separate protocol availability from individual member/platform availability; native Mac is not Catalyst.
- Keep deployment iOS17/macOS14; isolate verified OS26/27 enhancements and gate SDK parsing separately.
- Xcode27 host requirement and Swift6.4 compiler are distinct from deployment and language mode.
- Reject dual DocumentGroup autosave and PlanningVaultStore writers for the same vault.
- Replace global sequence allocation with per-store streams; unrelated stores cannot atomically share a counter.
- Separate durable receipt, applied conflict receipt and rejection; rejection never authorizes compaction.
- Correct cancellation: a durable transaction already committed cannot be uncommitted by Task cancellation.
- Require common-base merge evidence; no worker implements unspecified three-way text/field merging.
- Separate source projection, UI intent, persistence, authentication and composition ownership.
- Expose exact file allowlists per packet and handoff contracts; preserve P05 candidates.
- Delay irreversible migration/real-data cutover until integrity checks at a cohesive wave boundary.
- Fix CSP delivery: frame-ancestors requires an HTTP response header, not an HTML meta element.
- Record API/dependency/function-signature gaps as named pre-code checkpoints, not implicit worker choices.
- Explicit unsupported-feature and real-device gates cannot disappear from completion reports.

## Read order
1. 17-OS27-MATRIX.md and 18-SHARED-CONTRACTS.md.
2. 19-DURABILITY-MIGRATIONS.md and 20-DESIGN-INTERACTIONS.md.
3. 21-QUALITY-REVIEW.md and 22-COVERAGE-DECISIONS.md.
4. Your R2-P00.md … R2-P18.md plus its original packet and exact source file.
5. 23-NO-GUESSING.md; 24-DEPENDENCIES.md; 25-RESEARCH-EVIDENCE.md.
6. 26-SIGNATURE-CHECKPOINTS.md before cross-packet API implementation.

## Dispatch
First P00 remains documentation reconciliation only, after explicit execution go.
Then CP-A seals this amendment and CP-B seals wire/schema/adapter signatures before P01 writes code.
P05 may inspect/repair its existing candidate after go without waiting for relay work.
P07 may implement baseline tokens independently; CP-C must precede OS27-specific source references.
P16 membership-only substep remains separate from final application composition.
No source edit, deletion, build, test, xcodegen, commit, push or deployment is authorized by this amendment.
Only this blueprint directory may change in the current turn.
