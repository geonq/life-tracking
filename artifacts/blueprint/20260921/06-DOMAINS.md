# Domain-specific implementation contracts
## Calendar
Use CalendarCoordinator.save/delete/performPersist and CalendarStore.mutate as entry points.
Preserve existing CalendarItem validation, recurrence, duplicate rejection and remote merge admission.
Add replicated entity version/parents and receipt to durable envelope; legacy JSON migration retains original bytes.
Remote snapshot legacy paths become read-only compatibility after new protocol negotiated.
Never let a stale full snapshot overwrite receipt-backed pending edits.
No auto-pair at launch; MCSession name/order is discovery only. Authenticated operations only enter reducer.
Recurring-series exception and master updates share one logical operation where invariants span both.
Range expansion bounded by visible dates and existing occurrence cap; sorting O(n log n), not falsely O(n).

## Obsidian
Use PlanningVaultAccess.select/restore, PlanningVaultStore.read/stage/publish/publishPendingPage/resolveConflict.
Retain Packet C path/identity/no-follow defenses and journals. Do not bypass with Data.write from a view.
Binding identity is persisted vaultID, selected user scope and generation, not guessed absolute path.
Only create LifeOS/ after user picks vault and confirms folder creation. Existing directory requires marker validation.
No file moves outside LifeOS/. Read-only references outside owned subfolder require explicitly granted vault scope.
Default paths: LifeOS/Projects/<UUID>/index.md and map.canvas, plus notes/<UUID>.md.
Use stable ID in names to survive title changes; frontmatter lifeos_id/version optional namespaced keys.
Preserve unknown YAML/JSON, whitespace/source where untouched; reject unsupported edits rather than rewrite entire note.
Canvas authored arrows are presentation relationships. Derived links come from Markdown; no bidirectional auto-conversion.
Creating semantic link command edits source Markdown through version-checked mutation and previews target.
Reference result enum existing exact/ambiguous/missing/notLoaded/outside is authoritative; never guess basename match.
Shapes outside standard Canvas use optional namespaced extension; stock Obsidian preserves rectangle fallback.
Graph index remains 10k nodes/40k relationships/32MiB source; radix BVH build O(V+E), worst query O(V+E).
Source parsing O(B); derived link output bounded to relationship cap; repeated node instances preserved.
NSFilePresenter coalesces change notices, then re-read coordinated bytes/hash; debounce 250ms, no filesystem polling.
NSFileCoordinator is only local coordination. iCloud concurrent edit still needs base/ours/theirs comparison.
Never treat download-in-progress or missing provider file as deletion.
Three-way merge independent text hunks only; overlapping changes create explicit conflict with both versions.
Binary/unsupported frontmatter conflicts always retain both; no automatic conflict-file deletion.
Relay carries unpublished proposals/content hashes. Each device publishes via Packet C CAS, never raw remote path writes.
A remote mutation already present by content hash is idempotent; divergent file becomes conflict.
Windows receives mirror/proposals only and cannot silently edit canonical iCloud vault.

## Finance
Existing FinanceRecurringPaymentDetector.makeInput/detect explicitly handles imported transactions only.
Add FinanceRecurringObservation normalizer for live and imported inputs; preserve existing evidence references.
Group by source account + normalized counterparty + currency + debit/credit kind.
Normalize bounded Unicode/merchant text once, never merge different account identities by display name.
Sort each group by booked date O(n log n) total; scan candidate weekly/monthly/yearly calendar slots O(n).
Use calendar arithmetic ±3 days; do not approximate monthly as 30 days. Amount variance explicit.
Two samples may suggest weekly/monthly; yearly requires two annual observations and remains low-confidence.
Existing detector thresholds take precedence where stricter; update only with named regression evidence.
Manual confirmed cadence/nonrecurring override keyed to stable group identity survives refresh/import corrections.
Live/import duplicates: provider transaction ID first; otherwise suggest match with evidence, do not auto-delete equal amounts.
Use integer minor units with currency exponent + Decimal for shares/prices/FX; no binary float money aggregation.
CSV bounded parser preserves quoted multiline; exact institution profile or explicit mapping, no forced guess.
Trade Republic manual history and Robinhood activities remain distinct source kinds.
Robinhood holdings snapshot: account, instrument ID, quantity, price, currency, valuationAt, source, coverage.
Activities alone cannot establish complete holdings; missing opening balance remains partial.
Net worth = qualified bank cash + qualified investment equity/cash − liabilities; no transfer double count.
FX needs observed rate+timestamp; incomplete currencies contribute to an explicitly partial total.
NextSemis deferred optional adapter; do not scrape the UI or make it required.

## Fitness/HealthKit/Zepp
FitnessTrainingStore already has begin/update/finish/delete/link/unlink and durable receipt behavior.
Use those APIs; add transport wrapper to receipts, not a duplicate training ledger.
LifeOS owns sets/reps/load/templates/rest/history; HealthKit owns sampled physiological records.
HKWorkoutBuilder exports completed workout after explicit permission; one external ID per LifeOS session.
Retry queries prior UUID/sync identifier before save; crash-after-save must not duplicate export.
Manual duration/type only when supplied; never synthesize heart rate/calories from reps.
Reconciliation candidates: same supported activity and start within 5min, overlapping duration >=80%.
Auto-link only a single candidate with source metadata and no existing competing link; otherwise user chooses.
Import changes/deletions by anchor, dedup UUID+source; save data and new anchor atomically or replay safely.
Do not feed LifeOS-exported workouts back as new Zepp observations.
Field provenance stays per value; app-entered sets never replaced by partial HealthKit summary.
No proprietary Zepp score/PAI/training-effect recreation with guessed formulas.
Nutrition proposal remains draft; confirmed meal durable once; photo strips EXIF, bounded decode, no silent upload offline.
During Windows outage use manual nutrition; selected photo may be retained locally only with explicit pending state.

## Usage and Clipper
Extend existing UsageCapability/AuthKind/RegistryAdapter, not a dynamic executable plugin loader.
Each reviewed adapter declares product, dimensions, windows, authKind, collector location, freshness, refresh support.
Codex local quota, Claude collector, Gemini subscription manual and Gemini API metering remain distinct.
Provider may be added as manual metadata; automatic code adapters require reviewed allowlist.
No scraping browser cookies, undocumented subscription endpoints, or inferred remaining quota from token usage.
Auth secrets stay collector host Keychain/protected storage; OAuth only when officially available.
Manual readings include enteredAt/reset/window; a stale manual value never silently becomes live.
Clipper retains bounded real collector contract and unavailable state; no unrelated AI feature.

## Tax, privacy and retention
TaxDocumentStore uses atomic protected local storage; retain extraction provenance, never export pages via replication.
Raw original PDF retained locally until user deletes; encrypted device/OS storage plus file protection.
OCR page text moves to local-only protected cache, purged 30 days after accepted extraction or earlier explicit delete.
Pending review/conflict keeps necessary text until resolved; disk pressure prompts removal, never silently discards user original.
Sanitized extracted fields may sync; identifiers masked consistently, raw identifiers excluded from logs/widgets/notifications.
Migration separates raw pages from publication DTO and validates round trip before dropping legacy copy.
CSV fields neutralize formula prefixes; bounded parser avoids catastrophic regex fallback.
Privacy deletion creates tombstone; retain minimal ID/version/hash to prevent resurrection, no raw content.

## Additional local stores and notifications
P04 must enumerate existing lifestyle/journal/supplement mutation entry points and wrap each atomic envelope,
not just the main workout flow; no user-authored record silently omitted from sync.
Device-local appearance, HealthKit grants/anchors, Keychain secrets and notification permission never replicate.
Notification schedules derive from merged local records and current timezone; stable occurrence IDs prevent duplicate reminders.
User-authored usage readings/settings may stay local by device in v1; label device scope in Usage settings.
Clipper/provider observations may replicate read-only with source timestamp, never as editable revenue.
