# Active LifeOS full-design execution

Status: IN PROGRESS
Updated: 2026-09-13
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

## Completed and published
- Figma-led four-row Overview and Usage detail surfaces.
- Native Calendar week/month/three-day layouts, event editor/status/icons, holidays, and widgets.
- Calendar Tailscale sync/client foundation while preserving peer sync.
- Tax document local feature foundation.
- Provenance-aware read-only Usage ingestion/API/native UI.
- Fail-closed Finance summary and disabled connector contracts.
- Current working checkpoint: `6f421f8` on `lifeos-foundation-checkpoint-20260812`.
  The branch push succeeded; PR #1 is the matching open draft checkpoint.
  Backend boundary security is Astra scoped GREEN at `87e7db6`. Calendar
  security and merge hardening is committed at `8942b8e`, with 107/107 focused
  iPhone tests and a passing macOS build. Usage hierarchy is committed at
  `6f421f8`, with 3/3 focused macOS visual tests and seven inspected captures.

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
- [ ] Minimal honest module until real Helio Strap → Zepp → Apple Health samples can be inspected.
- [ ] Preserve HealthKit source/device metadata; Helio Strap is sensor authority.
- [ ] Zepp-only metrics remain unavailable without an authorized official interface.

### Phase 9 — Real connector activation and hardware acceptance [OPERATOR/AUTHORIZATION BOUNDARY]
- [ ] Sparkasse regulated Open Banking provider/coverage/consent.
- [ ] Trade Republic remains import-only unless official access exists; no production `pytr`.
- [ ] Physical-device signing/provisioning, actual account data, folder conventions,
  and hardware-specific visual acceptance. Current USB/reauthentication intents
  remain manual/unavailable. The personal installer source is now present and
  Astra scoped GREEN with 13/13 tests; physical signing/provisioning/install
  evidence is still required.

## Tranche completion witness
A tranche is complete only when exact current source has passing focused/full tests, fresh iPhone and macOS screenshots are inspected, production paths fail closed, an independent review is reconciled, approved files are committed/pushed, the working branch matches its remote and its PR head, and canonical status is clean. Whole-product completion additionally requires all non-external phases above and the user's final visual/product review.
