# Revision6 manifest — final correction set
Planning-only. Every R6 document is <=200 lines. R4/R5 remain history except for explicit supersession pointers.

|File|Purpose|Lines after final check|
|---|---|---:|
|[R6-READINESS.md](R6-READINESS.md)|Final verdict, blocker closure, packet readiness and external evidence|36|
|[R6-CHANGELOG.md](R6-CHANGELOG.md)|Concise correction record|22|
|[R6-01-DOMAIN-CLOSURE.md](R6-01-DOMAIN-CLOSURE.md)|Usage/Clipper boundary and closed enum decision|53|
|[R6-02-TRAVEL-DATA-MANAGEMENT.md](R6-02-TRAVEL-DATA-MANAGEMENT.md)|Travel, data export/restore/delete, registry and receipts|133|
|[R6-03-INBOX-PERSISTENCE.md](R6-03-INBOX-PERSISTENCE.md)|Per-domain JSON ledger and existing Planning SQLite transaction|90|
|[R6-04-RECOVERY-KEYS.md](R6-04-RECOVERY-KEYS.md)|Recovery signature domain, custody, epochs and rotation|102|
|[R6-05-RECOVERY-IMPORT.md](R6-05-RECOVERY-IMPORT.md)|Receipt-first import state machine and retries|70|
|[R6-06-CALENDAR-GESTURES.md](R6-06-CALENDAR-GESTURES.md)|Canonical Calendar commit and gesture ownership|85|
|[R6-07-NAME-AUDIT.md](R6-07-NAME-AUDIT.md)|R5 name signatures and full leaf noun/verb audit|85|

## Superseded or amended references

|Historical file|R6 amendment|
|---|---|
|R5-01-LEAF-AUDIT.md|R6-01, R6-02, R6-06 and R6-07 own the final cells and name audit|
|R5-02-SYNC-ENGINE.md|R6-03 fixes Planning storage and transaction ownership|
|R5-03-DELETION-CALENDAR.md|R6-06 supplies the canonical commit signature and complete gesture values|
|R5-04-ARCHIVE-TRUST.md|R6-04 and R6-05 supply signature, epoch and retry details|
|R5-05-READBACK.md|R6-07 supplies concrete client/disabled-provider signatures|
|R5-06-BOUNDS.md|R6-03 confirms the shared 10,000 ledger bounds|
|R4-06-PLANNING.md|R6-03 supersedes only the inbox/ACK/frontier ownership paragraph; its v3 table names remain authoritative|
|R4-03-CALENDAR.md; R4-15; R4-16|R6-01/R6-03/R6-06 supersede the affected owner and call-graph lines|
|R4-LEAVES-01…03.md|R6-07 records the final false-owner corrections and checkpoint rule|

No source file, source deletion, build, test, xcodegen, commit or push is part of R6.

## Revision7 supersession

Read [R7-MANIFEST](R7-MANIFEST.md) and [R7-READINESS](R7-READINESS.md) first. R7-01…06 are the current contract set;
this manifest remains only the R6 historical file/line inventory.
