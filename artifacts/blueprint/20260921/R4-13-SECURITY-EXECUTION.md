# Security function decisions and wave review (supersedes CP-SEC design gates)
P15 reviewer evaluates actual diffs/negative evidence; this document is not a completed penetration test.
Existing correct control retained; proposed function names below own specific behavior, not blank security tasks.
|Finding|Exact implementation function/owner|Binding behavior and evidence|
|---|---|---|
|peer invitation|CalendarPeerSync invitation delegate / P03|Default reject; discovery opt-in only after pairing; SyncTrustStore.authorize before data exchange; unknown identity negative|
|timestamp overwrite|CalendarSyncAdapter.applyPayload / P03|R4 causal heads; legacy timestamp merge excluded from v1; future timestamp cannot win|
|decode/duplicate|CalendarItem.init(from:),validatedForPersistence; CalendarSnapshot.init(from:) / P03|Existing validation retained; Wire4 conversion revalidates; duplicate ID no fatalError|
|token plist|SyncIdentityStore.initialize/sign / P01|R4-09 Keychain, no seed export; existing bearer migrated only after successful Keychain readback|
|unbounded response|SyncTransport.exchange / P01|URLSessionDataDelegate increments received count before append, cap2MiB, reject nonJSON/redirect/timeout; zero overflow publication|
|tax identifiers|TaxPublicationCodec.fromDocument/decode / P13|Closed R4-07 fields; raw-cache excluded; hostile identifiers never in archive|
|CSV formula|TaxCSVExporter.escape / P13|Neutralize first significant =+-@ or leading tab/CR/LF with apostrophe before CSV quote escaping; exact string retained for display|
|tax atomicity|TaxDocumentStore.persist / P13|Private same-volume temp→protect→flush→replace; previous bytes intact on failure|
|temp symlink/history|UsageHistory.persist/readBoundedFile / P15|Exclusive no-follow temp in0700dir, validate owner/type, no predictable shared temp fallback|
|Host rebinding|server.ts NEW isAllowedHost(host:string|undefined):boolean / P15|Allow exact localhost/127.0.0.1+configured port only; raw duplicateHost rejected before parser collapse; no arbitrary reflected host|
|executable search|codexSpawnSpec/codexWorkingDirectory/spawnCodex / P15|Retain absolute path validation/current working-dir fence; forbid CWD/ComSpec-controlled executable resolution|
|secret compare|constantTimeEqual/isValidClaudeSecret / P15|Existing SHA256+timingSafeEqual and min32secret; fail startup weak secret|
|regex/history corruption|TaxDocumentParser parsing helpers; UsageHistory.readState / P13/P15|Existing text bounds, per-line retain good records, report corrupt count; no whole-history[] fallback|
|write races|UsageHistory.addMany/persist / P15|One serialized transaction queue; persisted idempotency receipt; concurrent ingests not lost|
|icon decode|CalendarIconAsset.init(from:) / P03|Existing size/hash/magic before ImageIO, then pixel/single-image cap; malicious bytes rejected|
|deps/CI|R4-12 fixed pins / P15|Current lock/pins retained; any advisory fix minimal reviewed patch+lock, no automated blanket update|
|CSP|server.ts NEW dashboardSecurityHeaders():Record<string,string> / P15|default-src self; script-src self; style-src self; img-src self data:; connect-src self; object-src none; base-uri none; frame-ancestors none|
|deep link|LifeOSDeepLink.init(url:) / P16|Exact registered app scheme/route; stable ID validation, rejected external scheme no action|
|replication|WireScanner.parse/SyncTrustStore.authorize/ReplicationStore.append / P01/P02|Sig/key/epoch/nonce/gap/hash/blob bounds/DB fencing negatives required before release|
No dynamic eval/shell/provider command strings. Signature authenticates known person/device, not infallible input: validators still mandatory.
Final security review targets owned local app/gateway/relay and disposable stores; never destructive production-data payloads.
Astra Medium review W1 codec/storage; W2 UI/feature diff; W3 integrated adversarial cases; W4 physical/live release evidence.
If Astra callable worker unavailable, record review pending and retain release NO-GO; Luna implementation still follows sealed contracts.
No report that existing high/critical issue fixed until actual current code and negative evidence inspected; no percentage scores.
