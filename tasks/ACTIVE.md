# Active LifeOS full-design execution

Status: IN PROGRESS
Updated: 2026-09-14
Mode: prospective implementation of the complete LifeOS design plan; one verified, publishable tranche at a time.

## Authority order
1. Current user instructions and corrections.
2. User-supplied `Instructions.md` and authenticated Figma file `14OEzVG2UEO2J3Dnd717ig` (`MacHomeDesignByMe` and named reference frames).
3. Canonical `Coordination/DECISIONS.md`.
4. `/Users/georgdomke/Arbeit/VS Code/LifeOS Design` documentation.
5. Existing behavior only where higher authority is silent.

## Product boundary
- Native SwiftUI/WidgetKit for iPhone and macOS is the product.
- Windows PC/Tailscale is the private structured-data and document-service boundary.
- Apple Reminders owns actionable task state; Calendar owns time commitments; Obsidian owns durable knowledge/plans; HealthKit transports health samples with Helio Strap/Zepp provenance; the private LifeOS ledger owns financial/tax evidence.
- No production fixture fallback. Missing live values remain unavailable.

## Implemented source and scoped evidence
- Figma-led four-row Overview and Usage detail surfaces.
- Native Calendar week/month/three-day layouts, event editor/status/icons, holidays, and widgets.
- Calendar Tailscale sync/client foundation while preserving peer sync.
- Tax document local feature foundation.
- Provenance-aware read-only Usage ingestion/API/native UI.
- Fail-closed Finance summary and disabled connector contracts.
- Current application source checkpoint: `e07a0a4` (calendar merge hardening
  layered over `e8bbefa`); mainline contains implementation merge `c09c3b7`
  plus subsequent documentation syncs, with
  implementation merge `c09c3b7`. The feature branch push and merge succeeded;
  GitHub CLI reports PR #1 merged into `main`. The
  deployable Windows candidate is the verified `6baa1f3` source checkpoint;
  recovery reached journal unit 31,400 and was stopped before its final stage.
  The marker remains active and `LifeOSAPI` remains stopped before install.
  Backend boundary security is Astra scoped GREEN at `87e7db6`. Calendar
  security and merge hardening is committed at `8942b8e`, with 107/107 focused
  iPhone tests and a passing macOS build. Usage hierarchy is committed at
  `33c74c9`, with 3/3 focused macOS visual tests and seven inspected captures.
  Fitness Recovery hero repair is committed at `03a78a1`, with 1/1 focused
  macOS snapshot and 1/1 iPhone 17 layout policy test passing.
  Finance responsive hierarchy is committed at `fd8ccfb`, with 16/16 scoped
  Mac snapshots, responsive captures at 900/1200/1512/1800, focused iPhone 17
  contracts, and an Astra Medium GREEN review.
  Shared visual foundation is committed at `628d4b3`, with the current
  compact SF Pro/neutral token contract, flat card treatment, a successful
  serialized Mac build, inspected Home/Calendar captures, and an Astra Medium
  GREEN review. This does not certify whole-app visual or device acceptance.
  Shell refinement is committed at `39f2c21`, with an exact serialized Mac
  build, opened Home/Usage/Calendar captures, and an Astra Medium GREEN review.
  iOS simulator/generic lanes are blocked at asset compilation by the missing
  iphonesimulator runtime; collapsed/compact reversal and iPhone tab rendering
  remain runtime checks.
  Usage/Home/Clipper refinement is committed at `e8bbefa`, with compact
  truthful empty states, connector-specific recovery labels, measured chart
  breakpoints, a successful serialized Mac build, and an Astra Medium GREEN
  review. The focused XCTest command compiled but the sandbox blocked its
  `testmanagerd` connection before assertions.
  Two T12 Calendar Luna Max attempts were stopped without a verified build or
  handoff; their incomplete changes were discarded and are not part of the
  current source. The next Calendar dispatch must use a smaller exact scope.
  Bounded recovery diagnostics are committed at `14a3b7f`; strict progress
  validation is committed at `4e14e38`; strict journal observation is committed
  at `9e43dd7`. Bounded phase telemetry is committed at `0a8d5b6`; the current
  historical telemetry coordination receipt is `056c1b4`, not the current
  source checkpoint. Native Windows PowerShell 5.1 static,
  behavior, failure-parity, and legacy Serve suites passed with exit 0 for the
  latest slice, and Astra Medium reviewed all four slices GREEN. The digest
  callers use a mutable holder because named `[ref]` arguments are rebound by
  Windows PowerShell 5.1. The canonical transaction remains untouched. The
  public CalendarStore merge boundary is hardened at `e07a0a4`, with an Astra
  Medium **GREEN** review and a focused iPhone 17 receipt of 96/96 tests with
  0 failures.

## Current dispatch

- The prior Averroes streaming candidate was stopped, quarantined, and discarded
  after it returned no handoff; no recovery source changes are present. Astra
  had already marked the proposal RED for byte binding, untouched-unit semantics,
  strict boundaries, invalidation, and Windows PowerShell 5.1 safety.
- A prior narrow Mac shell candidate was compiled and tested, then rejected by
  Astra Medium for missing actual shell evidence and collapsed-header geometry
  risk; its patch is preserved in `/private/tmp/lifeos-mac-shell-candidate-red.patch`.
  The causal replacement is the reviewed and pushed `39f2c21` shell refinement.
- Claude's supplied security findings are reconciled in
  `artifacts/final/T0/security-findings.md`. The parent-led matrix records
  source-fixed, partial, open, and unverified states; it does not authorize
  canonical Windows mutation or claim a final penetration test. Do not start
  another broad audit; source fixes must use a completed, bounded owner packet.
- T0 requirements mapping is generated from the validated frozen registry.
  T10a capability preflight completed as **SOURCE GAP** and is retained at
  `artifacts/final/T0/t10a-capability-preflight.md`; three T1a recovery review
  attempts produced no usable report and made no mutation. The next dispatch is
  the bounded T1 owner repair for the A1 RED findings after the pushed
  CalendarStore fix. A1.4 truthfulness is pushed at `9539841`; A1.1–A1.3
  still block recovery. The calendar reconciliation receipt is at
  `artifacts/final/T0/calendar-security-reconciliation.md`.

## Execution phases

### Phase 1 — Finance native surface and truthful connection readiness [IN PROGRESS]
- [ ] RED/GREEN tests for unavailable/observed presentation, connector policy labels, and fixture isolation.
- [ ] Native Finance Overview using the six existing independent metrics.
- [ ] Accounts/Connections readiness for Enable Banking/Sparkasse and the
  Trade Republic import path; PayPal is removed from the active product scope.
  No fake balances or fake connection health.
- [ ] iPhone navigation and macOS desktop-first sidebar integration.
- [ ] Deterministic, globally labeled visual fixtures for light/dark QA only.
- [ ] Fresh iPhone/macOS build, tests, screenshots, visual critique, independent review, scoped commit/push, remote parity.

### Phase 2 — Finance ledger core
- [ ] Shared Account, Transaction, Category, Rule, ImportBatch, and SyncHistory models with provenance and audit links.
- [ ] Manual Cash/Custom balance adjustments as auditable transactions.
- [ ] Unified transaction review/search/filter/inspector UI.
- [ ] CSV/PDF import adapters only after representative user-source samples are available; preserve originals and reject ambiguous duplicates.
- [ ] Budgets, cash flow, income/expenses, recurring/subscriptions/bills/goals.
- [ ] Net worth/reports only from verified source records.

### Phase 3 — Tax and Documents completion
- [ ] Shared document metadata/merge strategy including `updatedAt` and conflict semantics.
- [ ] Windows-hosted encrypted archive path over Tailscale; checksum and transfer receipt.
- [ ] OCR extraction with editable fields and original-file retention.
- [ ] Transaction matching and Missing Documents.
- [ ] iPhone hold-to-confirm staging deletion only after verified archive receipt; never imply deletion of Files/iCloud originals.
- [ ] Refined macOS Tax three-pane UI grounded in researched tax-app references.

### Phase 4 — Business
- [ ] Shared business ledger over Finance transactions; Revolut Business readiness without duplicating records.
- [ ] Revenue/expenses/profit, customers/suppliers, invoices, VAT, uploads,
  reports, and deterministic insights. Calorie-photo estimation is the only
  permitted in-app AI flow.
- [ ] No Clipper workflow duplication; Clipper remains an external read-only source.

### Phase 5 — Investments
- [ ] Trade Republic import-only path unless an official/regulated connector becomes available.
- [ ] Holdings, lots, dividends, interest, performance, allocation, capital gains, reports.
- [ ] Original document provenance and safe tax linkage.

### Phase 6 — Tasks, Grocery, Shopping
- [ ] Tasks are an Apple Reminders-backed lens, not a competing mutable task store.
- [ ] Grocery/Shopping retain their distinct lightweight interaction models, ownership and clearing semantics.
- [ ] Calendar overlays derive from authoritative sources without duplicating mutable records.

### Phase 7 — Home, navigation, reports, settings, and cross-module polish
- [ ] Full desktop three-pane shell, contextual inspector, breadcrumbs, command palette, keyboard paths.
- [ ] Only functional modules appear as active destinations; unavailable integrations are honest and non-interactive where appropriate.
- [ ] Home widgets/deep links, notifications, quick actions, cross-module report output.
- [ ] Settings for approved integrations, storage, backup, security, import/export, appearance and widgets.
- [ ] Product-wide typography/token/accessibility/Reduce Motion sweep and fresh visual comparison to Figma.

### Phase 8 — Fitness [EXTERNAL SAMPLE BOUNDARY]
- [ ] Complete all BF/HK/NU/SU/retention and native workout contracts; real source-dependent fields require physical provenance, and unavailable data does not reduce functional scope.
- [ ] Preserve HealthKit source/device metadata; Helio Strap is sensor authority.
- [ ] Zepp-only metrics remain unavailable without an authorized official interface.

### Phase 9 — Real connector activation and hardware acceptance [OPERATOR/AUTHORIZATION BOUNDARY]
- [ ] Sparkasse regulated Open Banking provider/coverage/consent.
- [ ] Trade Republic remains import-only unless official access exists; no production `pytr`.
- [ ] Physical-device signing/provisioning, actual account data, folder conventions,
  and hardware-specific visual acceptance. Source-present signing and Shortcut
  intents, executed Shortcut behavior, and signed-device renewal are separate
  evidence states. The personal installer source is now present and
  Astra scoped GREEN with 13/13 tests; physical signing/provisioning/install
  evidence is still required.

## Tranche completion witness
A tranche is complete only when exact current source has passing focused/full tests, fresh iPhone and macOS screenshots are inspected, production paths fail closed, an independent review is reconciled, approved files are committed/pushed, the working branch matches its remote and its PR head, and canonical status is clean. Whole-product completion additionally requires every requested phase, including external/device evidence, and the user's final visual/product review.
