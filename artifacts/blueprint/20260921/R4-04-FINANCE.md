# Finance/wealth canonical variants and reconciliation seal
P03 store integration; P09 presentation. Source-of-truth is existing user ledgers plus read-only provider observations.
FinancePayload is custom Codable/Equatable/Sendable Swift enum, Python frozen tagged dataclass union, TS discriminated union.
Exact JSON for every case: {"schemaVersion":1,"tag":<table>,"value":<exact Wire4 type>}; all3 keys required.
Swift cases use table tag and associated type; Python class Finance<Tag>Payload has schemaVersion:int,tag:Literal[tag],value:type;
TS FinancePayload = union of readonly {schemaVersion:1;tag:literal;value:Wire4Type}. No untyped dictionary value.
|Tag / existing store|Value type / local filename|Entity local identity|
|---|---|---|
|imported / FinanceImportedTransactionStore|Wire4FinanceImportedTransaction / finance-imported-transactions.json|transaction.id|
|recurring / FinanceRecurringPaymentStore|Wire4FinanceRecurringPaymentOverride / finance-recurring-payments.json|override.key.stableID|
|investmentActivity / FinanceInvestmentActivityStore|Wire4FinanceInvestmentActivity / finance-investment-activity.json|activity.id|
|investmentAccount / same|Wire4FinanceInvestmentAccountSnapshot / same|source.stableKey|
|investmentReceipt / same|Wire4FinanceInvestmentImportReceipt / same|receipt.id|
|budget / FinanceBudgetStore|Wire4FinanceCategoryBudget / finance-budgets.json|budget.id|
|allocation / FinanceAllocationStore|Wire4FinanceAllocationRule / finance-allocation-rules.json|rule.id|
|tracking / FinanceTrackingPreferencesStore|Wire4FinanceTrackingPreferences / finance-tracking-preferences.json|literal committed|
Each tag maps enrolled storeKind; investment uses prefix activity:/account:/receipt: before legacy identity to avoid collisions.
Other wire entity IDs SHA256(kind+NUL+local identity). No bank tokens, account login details or original CSV bytes transported.
Descriptions/sourceCategory and account provenance are personal user data allowed only inside enrolled dataset.
All nested values enumerated R4-V/ENUMS; Int cents exact I64 strings, FinanceExactDecimal rawValue retained/validated canonically.
Record limit10000 imports/activities; each other collection<=10000; old stricter limit and32MiB wrapper limit win.

## Exact functions and atomic composition
FinancePayloadCodec.encode(_ payload:FinancePayload)throws->Data; decode(_ bytes:Data,kind:SyncStoreKind)throws->FinancePayload.
FinanceSyncAdapter(kind:SyncStoreKind,store:FinanceReplicationStore) retains one matching existing store reference.
FinanceReplicationStore is internal protocol with commitReplication(_ payload:FinancePayload,operation:SyncOperation?)async throws->SyncCommitReceipt;
all six existing store types conform by adding this method INSIDE their current writer lock, not by a new datastore.
Imported commitPreparedImport→commitTransactions→saveStateUnlocked retains existing import receipts/mappings;
insert replication entities/outbox in same candidate. Incoming imported value updates only matching id via existing validated conversion.
Recurring saveOverride/clearOverride→saveUnlocked remains command API; replicated key match exact stableID; evidenceCache derived only.
Investment merge/upsertAccountSnapshot→saveUnlocked uses separate entity kind; preserve importReceipts and dedup activity IDs.
Budget setBudget/remove, Allocation create/update/remove, Preferences commit/commitDraft all use commitReplication before saveUnlocked.
Remote apply calls commitReplication directly (preserves incoming identity), NOT user command that allocates new ID/revision.
Bulk local import emits immutable per-record ops plus receipt in ONE store save; reserve contiguous sequences before candidate write.
If whole batch cannot fit cap, reject before any store/receipt change. No partial confirmed import UI.

## Migration/pending/server revisions
R3 exact wrapper versions retained. New metadata32MiB ceiling does not enlarge domain data's old8MiB/4MiB limits.
Old remoteRevision/ETag/record revisions/tombstones preserved as legacy receipt authority; NOT converted to timestamp winners.
Migration gives each current record one bootstrap head; origin sequence monotonically allocated in existing sorted local ID order.
Legacy unresolved attemptedRequest freezes original bytes/idempotencyKey: query old receipt before v1 bootstrap of that entity.
New edit of blocked legacy entity stays draft with pendingLegacyReceipt result; independent entities still editable.
After old receipt resolved, reconcile exact returned sourceRevision to local candidate, then bootstrap+edit in one store transaction.
No inferred mapping from revision number to operation hash. Store metadata explicitly retains legacyRevisionByEntity rows
{entityID:String,sourceRevision:String,bootstrapMutationID:String}; all required HASH/I64/UUID, max10000; local-only.
Same posted CSV reimport retains original identities and creates zero changes/ops when content unchanged.
FinanceArchive=R4-02 specialized FinancePayload, one store-kind archive; include original import receipt/provenance metadata
needed for dedup, never original file bytes. Legacy pending entries must be resolved before checkpoint can cover their entity.

## Deterministic functional bindings
FinanceRecurringPaymentDetector.detect/normalizedMerchantKey/nextExpectedDate remain the detector; explicit override outranks detection.
Manage Payment calls saveOverride with cadence weekly/monthly/yearly or clearOverride for suspected; ignored means not recurring.
FinanceStatementImporter existing import entry (R4-FUNCTIONS) classifies content, unknown requires mapping preview before commit.
FinanceRobinhoodImporter.importCSV→FinanceInvestmentActivityStore.merge; account snapshots independently verified, no trades executed.
FinanceCoordinator.refresh/apply reads Enable Banking; offline stale cache+local imports; do not erase existing working consent.
Net worth uses existing FinanceInvestmentDomain net-worth calculation, excludes transfer duplicate/consolidationKey overlap;
no holdings valuation inferred from cash flow or future quote. NextSemis disabled optional adapter per R4-RELEASE-INTERFACES.
WidgetSnapshotPublisher.mapFinance produces accepted summaries after commit; unobserved amounts=null, never0.
Evidence: genuine Sparkasse/Revolut readback, recurring override persistence, Trade Republic reimport, Robinhood cash/holdings separation,
legacy pending/retry/conflict/max-size migration and post-commit widget source. Live credentials are release evidence, not a coding choice.
