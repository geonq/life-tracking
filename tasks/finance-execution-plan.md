# Finance execution packet

Updated 2026-09-17 Europe/Berlin. Source checkpoint: `453d304` on
`main` / `origin/main`. Subordinate to the main release plan; release remains
**NO-GO** until deployment, live-data, and runtime gates have evidence.
Execute stages 1–5 in order; stage 5 defines evidence required at every gate.

## Shipped baseline — preserve, do not rebuild

- `ios/Shared/FinanceInstitutionDetector.swift` contains the versioned,
  deterministic registry: enabled Trade Republic English 23-column comma and
  German legacy/security semicolon profiles; disabled Robinhood, Sparkasse,
  and Revolut markers; near-match/duplicate/unknown fail-closed states; and
  content-free, versioned detection provenance. Do not add a parallel registry.
- `ios/Shared/FinanceStatementImporter.swift` separates institution metadata
  from `FinanceImportSource`. Historical UUID/hash inputs and legacy column
  precedence, including `Datum` + `Betrag` identity behavior, are preserved.
  Do not remove that compatibility path or interpret it as institution proof.
- BOM, CR/CRLF, UTF-16, bounded delimiter probing, cached linear quote
  boundaries, malformed-row recovery into later unquoted/quoted rows and EOF
  replay, and exact currency behavior are shipped. Preserve these guarantees.
- Focused detector/importer tests and historical UUID goldens shipped;
  Astra Medium review: **MERGE**. Mac logic: **55/55 passed**; generic iOS
  test build succeeded. Simulator service/runtime was unavailable, so this
  is not simulator execution evidence. Required storage guard passes.
- `ios/Shared/FinanceImportedTransaction.swift` and
  `ios/Shared/FinanceImportedTransactionStore.swift` remain the cash/investment-
  order import model and sync store. `ios/Shared/FinanceDomain.swift` has
  observed accounts/wealth; recurring metadata is local-only and does not prove
  live bank support.
- Enable Banking historical proof exists; deployed/native live readback is
  a separate gate. Trade Republic remains manual import. PayPal is out of scope.

## Current gap and worker contract

Explicit user mapping, detection-first UI, content-free provenance, account and
configuration identity, cross-device relabeling, legacy attempted-request
compatibility, gateway validation, and local recurring metadata are shipped at
`453d304`. Live recurring reconciliation, a separate investment ledger,
verified net-worth composition, and provider readback remain open. `fixedCosts`
and merchant categorization are not recurring detection; activity is not a
valuation.

Dispatch one bounded Luna packet at a time with the stage's exact files and
acceptance tests; Astra Medium reviews each slice before the next dependency
opens. Workers report changed files, evidence, and blockers; they do not commit
or push. Keep scope local through stage 3; do not expand gateway schemas early.
Use truthful observed data, explicit unavailable/partial states, and no fixtures
in production. No generic in-app AI/advisor; calorie-photo AI is the only AI flow.

## 1. Completed packet — mapping, preview, provenance, and identity

Completed scope: `ios/Shared/FinanceStatementImporter.swift`,
`ios/Shared/FinanceInstitutionDetector.swift`,
`ios/Shared/FinanceImportedTransactionStore.swift`, and
`ios/LifeOS/Modules/Finance/FinanceImportView.swift` (including its
`FinanceImportViewModel`). The packet extended the existing
detection/provenance types and added
`ios/Shared/FinanceImportMapping.swift` for the mapping value/persistence
contract.

- Preview must use `FinanceImportResult.institutionDetection`, never infer an
  institution from `detectedSource`. Show state, profile/version when verified,
  delimiter, content-free reason/evidence codes, valid/skipped counts and rows.
- Unknown/ambiguous input cannot confirm until the user explicitly maps columns
  by index, date format, amount/sign convention, currency and account identity.
  Validate required fields, duplicate column choices and row values; reparse
  through the bounded parser. Duplicate headers require index disambiguation.
- A valid mapping becomes `userMapped` with no claimed institution. Disabled
  profiles and near matches cannot become known via mapping; unsupported
  investment exports stay blocked from bank import. Never enable markers here.
- Enforce the gate in the view model/save path as well as the button. Changing
  file or mapping invalidates the preview; cancellation/stale confirmation
  writes nothing. No automatic acceptance of a saved mapping on a new layout.
- Persist versioned mapping and batch-to-row provenance locally: mapping and
  detector versions, content-free detection metadata, batch ID, file SHA-256,
  byte count, header fingerprint, source row numbers and import time. Do not
  store raw CSV, raw headers or account values in diagnostic provenance/logs.
- Keep metadata separate from identity/sync payloads. Preserve old UUID/hash
  inputs, legacy precedence, categories, overrides, amounts, revisions,
  tombstones and reimport deduplication. Missing historical provenance stays
  unavailable; do not relabel or re-ID stored legacy rows. Version local
  persistence only where needed, with backward-compatible decoding.

Gate passed at `5fe26a4`: mapping, preview cancellation/staleness,
provenance round-trip, mapped-v3 account/configuration identity, synced-only
account relabeling, duplicate/reimport fences, and legacy attempted-request
recovery are covered by the 17/17 Mac finance suite. Mac build-for-testing,
contracts (199/199), contract typecheck, Swift parse, gateway AST, and diff
checks pass; the final Astra Medium review returned **MERGE**. Existing
detector profiles remain unchanged.

## 2. Completed packet — local recurring candidates and Manage Payment

`453d304` adds `FinanceRecurringPayment.swift`,
`FinanceRecurringPaymentDetector.swift`, `FinanceRecurringPaymentStore.swift`,
Finance import integration, and focused Mac tests. It is intentionally local and
mapped-v3 only; it does not claim live-provider support or sync recurring
overrides.

- Stable source/account/currency/merchant identity, bounded mapped-row input,
  evidence references, exclusions, deterministic grouping, and `O(n log n)`
  scans cover weekly/monthly/yearly cadence and finance-timezone boundaries.
- Weekly anchors reset after gaps; month-end/leap-day clamping does not drift;
  repeated 6/8-day drift becomes review-only; later eligible evidence cannot be
  predicted away. Automatic, pause, ignore, and explicit cadence/anchor
  overrides remain distinct and durable across reimport/restart.
- Manage Payment exposes evidence, confidence, next date, state, and override;
  owner-scoped sheet bindings prevent duplicate presenters. Stale/error state,
  cancellation generations, post-import refresh, missing evidence, and corrupt
  store reads remain visible instead of fabricating current data.
- Serial macOS build-for-testing passed; detector, store, view-model, and
  import regression suites passed 56/56. Final Astra Medium review: **MERGE**.

Remaining gate: reconcile this local model with real bank observations and
provider account identity before presenting live recurring payments.

## 3. Robinhood ledger and verified net worth; then optional NextSemis

Add `ios/Shared/FinanceInvestmentDomain.swift`,
`ios/Shared/FinanceRobinhoodImporter.swift`, and
`ios/Shared/FinanceInvestmentActivityStore.swift`. Put `FinanceNetWorthBreakdown`
in the investment domain; integrate observed accounts via
`ios/Shared/FinanceDomain.swift` / `ios/Shared/FinanceCoordinator.swift` and render
in `ios/LifeOS/Modules/Finance/FinanceView.swift` and `FinanceAnalyticsView.swift`.

- Separate account snapshots, holdings, verified cash and activities: buy,
  sell, dividend, interest, fee, deposit, withdrawal, transfer, unknown.
  Preserve exact quantities, amounts, currencies and source identity; validate
  schema/version and idempotent import. Unknown/malformed records fail closed.
- Validate against geonq's real Robinhood export when available. Until then,
  label schema support unverified and keep production enablement gated; unit
  fixtures are test-only. Do not invent supported columns or verified balances.
- Robinhood activity/holdings/cash never enter `FinanceImportedTransaction`,
  bank categories, recurring candidates or bank-account totals. Do not migrate
  existing Trade Republic order IDs as a side effect of this separate ledger.
- Net-worth breakdown: verified bank cash, investment cash and EUR holding
  values, each with account/source, observedAt, verification/exclusion reason.
  Require observed valuation or verified price/FX evidence; absent prices, FX,
  account identity or verification stays partial/excluded, never a fake zero.
- Activity alone contributes zero to net worth. Do not count snapshot cash
  plus activity cash effects, cash twice across linked accounts, or both total
  account valuation and its holdings/cash components. Reconcile identity first.
- Show a separate Robinhood account/activity surface and partial-state copy.
  Only after direct import and verified net-worth tests pass may a separately
  gated NextSemis adapter be considered; it is not a dependency or proof source.

Gate: local ledger/model tests pass; real-export schema and valuation evidence
are separately required for a verified Robinhood claim.

## 4. Stable local models → sync contracts and live reconciliation

Only after stages 1–3 local models pass review, scope changes to
`packages/contracts/src/sync.ts`, `packages/contracts/src/sync.test.ts`,
`services/api/src/` and `services/gateway/` using the actual route owners found
there. Name exact handler/test files in that later packet before editing.

- Define versioned recurring-override and investment sync schemas separately;
  do not overload `/finance/imported` or break its historical identities.
  Specify validation, revision/conflict policy, retries/idempotence, tombstones,
  backward compatibility and reconciliation of source/account identities.
- Prove local → gateway → fresh local readback, duplicate/retry behavior,
  overrides across devices, rejection of invalid payloads and no double count.
- Reconcile actual Enable Banking account/transaction observations and freshness
  with native display. Historical proof does not satisfy current deployment,
  provider consent/health or native live readback; record those gates separately.

## 5. Tests, evidence and dependency gates

- Extend existing `ios/LifeOSTests/FinanceInstitutionDetectorTests.swift`,
  `FinanceStatementImporterTests.swift`, `FinanceImportedTransactionStoreTests.swift`,
  `FinanceImportViewModelSyncTests.swift` and
  `FinanceTradeRepublicImportIntegrationTests.swift` for stage 1 and regressions.
  Keep UUID goldens, currency, encoding, malformed-row/EOF and scan-bound coverage.
- Add focused recurring detector/store tests for exclusions, grouping, ties,
  weekly/monthly/yearly cadence, DST/month-end/leap years, scale and durable
  overrides after restart/reimport/deletion. Test Manage Payment interactions.
- Add investment importer/store/breakdown tests for schema rejection, exact
  values, activity classification, reimport, partial valuation and double count;
  extend `ios/LifeOSTests/FinanceDomainTests.swift` for observed integration.
- Stage 4 adds contract/API/gateway validation and real reconciliation evidence.
  For each packet report commands, counts, review verdict and explicit skips;
  earlier 55/55/build evidence is baseline, not proof for new code.
- Future Apple lanes require `scripts/maintain_macos_storage.sh` preflight and
  serialized `xcodebuild -jobs 1` via existing validation lanes. Simulator
  runtime, physical iPhone, signing and live-provider checks remain separate
  until observed. This documentation-only update runs no native builds.
