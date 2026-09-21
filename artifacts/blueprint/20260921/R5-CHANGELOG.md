# Revision5 changelog — independent review closure
Planning-only; no source/build/test/commit/push action.

1. Replaced false/incomplete RF, BF and DT owner bindings and audited all 258 leaf rows. Fitness routing,
nutrition, lifestyle, finance travel, storage/retention, settings, nutrition photo, bank and typed-domain rows now
name the command, persistence boundary and acceptance behavior that actually owns them. Generic helpers remain only
for cross-cutting runners/renderers with direct responsibility.
2. Added durable `persistInbox`, ACK enumeration, frontier read/advance and exact result/error semantics to the
sync adapter call graph. Cancellation now has durable-before/after boundaries and replay is idempotent.
3. Replaced empty deletion payloads with `DeleteIntent`/`TombstonePayload`, CAS/base-head validation and typed delete
entry points for Calendar, Finance, Fitness, Planning and Tax. Calendar series deletion is explicit and bounded.
4. Added complete Calendar `BeginContext`, resize-edge and `CommitIntent` contracts with stale-head recheck.
5. Unified archive ACK bounds at 10,000 across Swift/Python/TypeScript and the scanner; no schema-valid undecodable state remains.
6. Added signed recovery archive mapping/import receipts, current-versus-historical epoch verification, rotation/reseed
ordering, replay and crash recovery behavior.
7. Changed bank readback to `async throws`, with a closed cancellation/error taxonomy and exact FinanceCoordinator behavior.

R4 remains preserved as history. R5 documents supersede only the affected clauses and leaf function cells.

R6 is the final contract correction set; read [R6-INDEX](00-INDEX.md) and [R6-READINESS](R6-READINESS.md) before dispatch.
