# Finance execution packet

Updated 2026-09-16 Europe/Berlin. This packet records the current gap and the
implementation order for the new finance requirements. It is subordinate to
the main release plan and remains a NO-GO until live-data and runtime evidence
exists.

## Current gap

- `FinanceDomain` has Sparkasse, Revolut, and Trade Republic connectors, but no
  Robinhood source or bank/investment account discriminator.
- `FinanceStatementImporter` treats a broad `Datum` + `Betrag` header match as
  Trade Republic and accepts other valid layouts as generic CSV without an
  explicit mapping step.
- `FinanceImportedTransaction` keeps Trade Republic orders in the imported
  transaction type; there is no separate investment activity/holding ledger.
- `fixedCosts` and merchant categorization are not recurring-payment
  detection. No durable candidate, cadence override, evidence, or Manage
  Payment flow exists.
- Production net worth currently uses observed bank balances only. Imported
  activity must never become a valuation by inference.
- `thenextsemis.vercel.app` remains optional and deferred until the direct path
  is stable.

## Data and provenance

Add `ios/Shared/FinanceImportProvenance.swift` with versioned detection state
(`known`, `unknown`, `ambiguous`, `userMapped`), canonical column mapping,
batch ID, SHA-256, byte count, normalized-header fingerprint, detector/mapping
versions, source row numbers, and import time. Persist provenance metadata;
never persist raw statement text as the mapping record.

Add `ios/Shared/FinanceImportInstitutionRegistry.swift`. Each known institution
fingerprint must combine normalized headers, delimiter, column count/order,
required/forbidden columns, and sample-value validation. A single candidate
must clear a threshold and deterministic margin. Unknown or ambiguous input
blocks confirmation until the user selects a known mapping or defines an
explicit user mapping. A user mapping never claims an institution.

Remove the `Datum` + `Betrag` Trade Republic shortcut from
`ios/Shared/FinanceStatementImporter.swift`. Existing Trade Republic imports
remain visible, but legacy rows are marked heuristic/unattributed during
migration until explicitly confirmed.

Keep row IDs, category overrides, amounts, tombstones, and reimport
deduplication stable. Add batch and source-row provenance without changing the
meaning of existing bank transactions.

## Recurring payments

Add `ios/Shared/FinanceRecurringPayment.swift` and
`ios/Shared/FinanceRecurringPaymentDetector.swift`.

The detector must:

1. Normalize merchant identity with case/diacritic folding, whitespace and
   punctuation normalization, preferring provider merchant identity.
2. Group by source, account, and merchant; exclude income, refunds, typed
   transfers, investment orders, and rows without reliable provenance.
3. Sort each group by local finance date and test weekly (6–8 days), monthly
   (calendar-month match with end-of-month clamping and ±3 days), and yearly
   (calendar-year match with leap-day normalization and ±3 days).
4. Require at least three occurrences. Mark high confidence only with four or
   more consistent occurrences and amount variance within `max(€1, 5%)` of the
   median. Otherwise mark `needsReview`.
5. Resolve by match count, then total date deviation, then fixed cadence order;
   ties remain reviewable. Calculate the next expected date in the persisted
   finance timezone.

The target is `O(n log n)` time and `O(n)` memory per revision, with cached
results keyed by transaction revision. Every candidate has Manage Payment.
The sheet shows evidence transactions, source/batch provenance, confidence,
next expected date, active/paused/ignored state, and a weekly/monthly/yearly
cadence picker. A user override is durable and is never replaced by detection.

## Robinhood and net worth

Add `ios/Shared/FinanceInvestmentDomain.swift`,
`ios/Shared/FinanceRobinhoodImporter.swift`, and
`ios/Shared/FinanceInvestmentActivityStore.swift`.

Keep investment activity separate from `FinanceImportedTransaction`. Model
account snapshots, verified cash, holdings, and activities (buy, sell,
dividend, interest, fee, deposit, withdrawal, transfer, unknown). Preserve
quantity and source amounts exactly. Buy/sell rows and transfers are never
holdings; imported activity alone contributes zero to net worth.

Add a `FinanceNetWorthBreakdown` consumed by `FinanceView` and
`FinanceAnalyticsView`: verified bank cash, verified investment cash, and
verified EUR holding values. Each component carries source, observedAt,
verification state, and exclusion reason. Missing prices, foreign currency,
unknown account identity, and unverified values remain visible as partial or
excluded. Do not double-count an account snapshot and activity cash effects.

Add a separate Robinhood account/activity card; it must never enter bank
transaction categories or bank-account totals. Extend gateway/contracts only
after the local model is stable, using separate sync schemas rather than
overloading `/finance/imported`.

## UI, migrations, and gates

- `ios/LifeOS/Modules/Finance/FinanceImportView.swift`: detection-first
  preview, provenance panel, mapping screen, and a disabled confirmation for
  unknown/ambiguous input.
- Finance detail UI: recurring candidates with Manage Payment, and a separate
  Robinhood investment surface with partial-state copy.
- Bump local/import schemas while preserving IDs, overrides, revisions, and
  tombstones. Keep legacy data visibly legacy until reviewed.
- Add focused tests for institution fingerprints, unknown/ambiguous mapping,
  provenance/reimport, weekly/monthly/yearly recurrence, DST/month-end/leap
  years, cadence overrides, Robinhood activity classification, malformed rows,
  verified/unverified valuation, no double counting, and sync rejection.
- Add gateway/contract tests only when the local schemas are final. Validate
  the real Robinhood export supplied by geonq; do not fabricate fixtures as
  production data.
- Consider `thenextsemis.vercel.app` only as a separate adapter/feature gate
  after direct Robinhood import and verified net-worth paths pass all tests.
- Preserve the product AI boundary: no advisor or generic conversational AI;
  calorie-photo tracking remains the only in-app AI.
