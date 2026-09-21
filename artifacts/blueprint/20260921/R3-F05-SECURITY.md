# Security report coverage and release proof
P15 owns final review; row owner fixes only its packet files. Existing report is not a current vulnerability verdict.
All rows: no new pentest/build/test run in planning. Status=PENDING fresh proof at accepted implementation SHA.
CP-SEC:<ID> resolves by inspecting exact current function, recording control/data flow and selecting a bounded
negative case against owned localhost/Tailscale infrastructure. No third-party scanning or destructive live payloads.
Every row requires source evidence plus focused runtime negative evidence before a security green light.
|Report item|Existing entry point / source evidence or explicit function gate|Owner / binding acceptance behavior|
|---|---|---|
|01 unauthenticated nearby sync|CalendarPeerSync.swift invitation delegate; CP-SEC:01 exact current delegate signature/start call|P03/P16; no auto-accept/advertise at launch; signed membership explicit pairing before any data|
|02 future timestamps/deletion takeover|CalendarDomain.swift merge; CalendarCoordinator.synchronizeRemoteSnapshot; CP-SEC:02 current merge overload|P03/P01; R3 causal parents/retained conflicts, no remote time winner; forged/future/deletion cannot silently replace|
|03 decode validation/duplicate IDs|CalendarItem.init(from:), CalendarSnapshot; CP-SEC:03 locate exact current validators|P03; decode validates title/dates/counts/IDs, no Dictionary unique-key trap; invalid input leaves store intact|
|04 plaintext bearer|Settings.swift settings field; TailscaleSyncClient auth; CP-SEC:04 current credential accessor|P01/P15; device-only Keychain, migrate only after verified write, never log secrets; sign transport frames|
|05 oversized responses/content type|TailscaleSyncClient.fetchCalendar/pushCalendar/fetchDocuments; CP-SEC:05 bounded common reader|P01/P03/P13; stream cap before full allocation, exact JSON MIME, timeout/cancel, no redirect|
|06 tax identifier/raw leak|TaxDocuments.swift TaxDocumentStore.load/save/delete; candidate extraction CP-S05|P13; explicit sanitized wire whitelist, protected local raw cache; unmasked reference/page text cannot sync|
|07 CSV formula injection|TaxCSVExporter.escape|P13; spreadsheet-dangerous prefixes including whitespace/control neutralized before quote escaping|
|08 atomic tax write|TaxDocumentStore.persist|P13; same-volume exclusive temp/atomic replace, recovery preserves last valid; never remove then move|
|09 predictable temp/symlink|services/api/src/history.ts UsageHistory.persist/readBoundedFile|P02/P15; exclusive no-follow private temp + restrictive parent; preplanted symlink cannot redirect writes|
|10 localhost Host rebinding|services/api/src/server.ts request handler; CP-SEC:10 locate actual Host allowlist|P02/P15; exact Host/port and origin policy, nosniff, reject hostile Host even loopback; dev proxy no production bypass|
|11 CWD/ComSpec spawn|codex-adapter.ts codexSpawnSpec/codexWorkingDirectory/spawnCodex|P15; approved absolute executable/system shell, no untrusted CWD/PATH/ComSpec; retain current equivalent controls|
|12 weak compare/secret|claude-ingest.ts constantTimeEqual/isValidClaudeSecret (digest helper observed)|P15; fixed-length SHA256 timingSafeEqual, startup minimum secret; no hand-rolled replacement|
|13 regex ReDoS|TaxDocuments.swift moneyPattern consumer; CP-SEC:13 exact parser method|P13; bounded text/input iteration, pathological digit/space runtime evidence; no unrestricted regex alternative|
|14 corrupt history line drops all|UsageHistory.readState|P15; per-record corruption policy retains valid bounded entries, exposes diagnostic not silent whole empty|
|15 concurrent usage writes|UsageHistory.add/addMany/persist|P02/P15; serialized read-modify-commit and idempotency receipt, concurrent ingests retained|
|16 duplicate calendar trap|CalendarDomain.swift; CP-SEC:03 shared validator|P03; duplicate local file enters recoverable error, no fatalError/crash or silent winning overwrite|
|17 icon decode before checks|CalendarIconAsset.init(from:) validator|P03/P15; cheap version/hash/length before ImageIO, bounded pixel decoding, no malformed asset crash|
|18 dependency advisories|package-lock.json; CP-E actual pinned versions/locks|P15; resolve relevant advisories with exact lock review; old count not current audit proof|
|19 CI supply chain|.github/workflows/native-apple.yml; CP-E action/tool pins|P15; reviewed immutable pins, no fork secrets, scoped permissions; do not add credentials for CI build|
|20 dashboard CSP|apps/dashboard/index.html + actual server handler CP-SEC:20|P15/P02; CSP at HTTP layer, frame-ancestors not meta; permit only required origins, no arbitrary inline execution|
|21 deep links/icon redirect controls retain|Domain.swift URL route; CalendarIconAsset; sync URLSession redirect delegate CP-SEC:21|P15; preserve current positive controls, verify hostile schemes/paths/cross-origin redirects rejected|
|22 new replication attack surface|R3-01 handlers/R3-02 store/signature verification proposed|P01/P02/P17; replay/signature/membership/epoch/hash/sequence/frontier/disk-full/ACK negative cases|

BitLocker/ACL/Tailscale identity are necessary host controls, not proof that application auth or data sync is safe.
Read-only source inspection can acknowledge an existing fix but cannot mark its final release proof PASS.
No dead-code deletion in this phase; later P15 manifest must include dynamic URL/intent/target references.
