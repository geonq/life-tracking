# Revision5 manifest — independent review closure
Planning-only document set. Every listed file is <=200 lines; R4 remains immutable history except for explicit supersession notes.

|File|Purpose|Lines|
|---|---|---:|
|[R5-READINESS.md](R5-READINESS.md)|Historical verdict, seven sealed contradictions, packet status and external evidence gates|32|
|[R5-CHANGELOG.md](R5-CHANGELOG.md)|Historical independent-review correction record|20|
|[R5-01-LEAF-AUDIT.md](R5-01-LEAF-AUDIT.md)|258-row false-owner audit and corrected ownership rule|54|
|[R5-02-SYNC-ENGINE.md](R5-02-SYNC-ENGINE.md)|Historical durable inbox, ACK enumeration, frontier retrieval/advance and cancellation|67|
|[R5-03-DELETION-CALENDAR.md](R5-03-DELETION-CALENDAR.md)|Historical typed deletion, tombstones, CAS and Calendar context|82|
|[R5-04-ARCHIVE-TRUST.md](R5-04-ARCHIVE-TRUST.md)|Historical recovery receipts, identity mapping, key verification and rotation|68|
|[R5-05-READBACK.md](R5-05-READBACK.md)|Historical throwing bank readback and cancellation/error behavior|50|
|[R5-06-BOUNDS.md](R5-06-BOUNDS.md)|Historical single 10,000-ACK archive/scanner bound|22|

## Affected R4 sheets

|File|R5 correction|
|---|---|
|R4-02-ARCHIVES.md|R5 archive bound and recovery supersession|
|R4-03-CALENDAR.md|Typed deletion and gesture supersession|
|R4-08-CODEC.md|10,000 ACK scanner/archive bound|
|R4-09-KEYS.md; R4-10-TRUST.md|Historical verification and recovery mapping|
|R4-11-FEATURE-ALGORITHMS.md|Corrected feature owner references|
|R4-15-TRANSPORT-COMPOSITION.md; R4-16-OWNERSHIP-INTERFACES.md|Sync call graph and packet ownership|
|R4-RELEASE-INTERFACES.md|Throwing `BankReadbackProvider` contract|
|R4-NO-GUESSING.md|R5 mandatory worker checks|
|R4-LEAVES-01.md; R4-LEAVES-02.md; R4-LEAVES-03.md|Corrected RF/BF/DT/NU/PC/DA/CA/ST bindings|

Line counts above are the checked counts for this revision. The affected R4 files retain their existing historical line counts except where a supersession note was already recorded; the final controller check must recalculate every file before dispatch.

## Revision6
The current correction set is [R6-MANIFEST.md](R6-MANIFEST.md). Its files supersede the affected R5 clauses while
preserving this manifest as history.
