# Historical feature leaves — 3/3
Read R3-F00-COVERAGE-RULES.md and named F01…F05 matrix. Source docs/LIFEOS_ACCEPTANCE_REGISTRY.md.
These are the169 original rows expanded through frozen split_groups into258 unique leaves; no parent double-counting.
Status is the historical registry claim, not a fresh source verdict; each binding remains an explicit pre-code review gate.
Current evidence is the named function/family; per-leaf missing behavior is the unproven acceptance delta in column2.
Each CP-L:<ID> must resolve to an exact symbol/action, DTO/error/cancellation contract and capture before Luna dispatch.
Authority/dependencies/offline/privacy/visual requirements inherit the named family matrix; no generic UI guess allowed.
Release requires column6 at accepted SHA; no source-present function alone proves a screenshot feature works.
Coaching/demo/unsupported-source historical wording is superseded by F00; preserve original text as history only.

|Leaf|Exact retained requirement|Historical state|Packet / inherited family|Source seam + pre-code gate|Release evidence|
|---|---|---|---|---|---|
|DT-02B|Writes are crash-safe and atomic across database, index, WAL, and temporary files.|missing|P01/P18 / F03|CP-L:DT-02B|integration|
|DT-02C|Backup exclusion, export, restore, and user deletion propagate across all storage classes.|missing|P01/P18 / F03|CP-L:DT-02C|device + integration|
|DT-03A|Retention enforces at most three images per meal, 90-day originals, 365-day detail, and derivatives no larger than 500 KiB.|foundation|P01/P18 / F03|CP-L:DT-03A|integration + performance|
|DT-03B|The 8 GiB warning, 9 GiB compaction warning, and 10 GiB ingest gate include database, WAL, cache, logs, backups, and temporary files.|foundation|P01/P18 / F03|CP-L:DT-03B|integration + performance|
|DT-03C|Compaction is transactional, proves export and provenance first, and never silently deletes user truth.|foundation|P01/P18 / F03|CP-L:DT-03C|integration + operator|
|SG-01A|Release configuration fails on placeholder App Group or host values.|foundation|P16/P17 / F03|CP-L:SG-01A|source + integration + operator|
|SG-01B|Release configuration fails on unknown provisioning mode or empty release allowlists.|foundation|P16/P17 / F03|CP-L:SG-01B|source + integration + operator|
|SG-01C|Release configuration fails on unresolved build variables or fixture/demo flags.|foundation|P16/P17 / F03|CP-L:SG-01C|source + integration + operator|
|SG-02A|Signed app and extension binaries pass strict signature inspection.|blocked-external|P16/P17 / F03|CP-L:SG-02A|release-signature + device|
|SG-02B|Expanded entitlements and App Group membership match the signed release contract.|blocked-external|P16/P17 / F03|CP-L:SG-02B|release-signature + device|
|QA-01A|The seven isolated schemes/test plans are committed and named: LifeOSLogic, LifeOSUI, LifeOSMacLogic, LifeOSMacUI, LifeOSWidgets, LifeOSPrereleaseIOS, and LifeOSPrereleaseMac.|foundation|P18 / F03|CP-L:QA-01A|source + integration|
|QA-01B|Each lane has a runnable command, exact only-testing scope, minimum nonzero expected count, timeout, and retained result path.|foundation|P18 / F03|CP-L:QA-01B|integration|
|QA-02A|Mac UI runner materialization is isolated with inspected host, loader, and app paths before a smoke test.|foundation|P18 / F03|CP-L:QA-02A|ui-runtime|
|QA-02B|Canceled, materialization-failed, and zero-test runs are retained as failures and never accepted.|foundation|P18 / F03|CP-L:QA-02B|ui-runtime|
|QA-03A|Accessibility audit covers labels, actions, focus order, and contrast on every release area.|missing|P18 / F03|CP-L:QA-03A|device + ui-runtime|
|QA-03B|Dynamic Type and VoiceOver/custom-action alternatives preserve the critical workflows.|missing|P18 / F03|CP-L:QA-03B|device + ui-runtime|
|QA-03C|Reduce Motion removes decorative animation while preserving information and interaction.|missing|P18 / F03|CP-L:QA-03C|device + ui-runtime|
|QA-04A|Launch and first-render latency meet the frozen release threshold.|missing|P18 / F03|CP-L:QA-04A|performance|
|QA-04B|Scroll and interaction latency meet the frozen release threshold at narrow/default/max sizes.|missing|P18 / F03|CP-L:QA-04B|performance|
|QA-04C|Storage accounting, compaction, and restore meet the frozen performance threshold.|missing|P18 / F03|CP-L:QA-04C|performance|
|QA-05|Final iPhone/Mac visual and interaction review accepted by geonq|blocked-external|P18 / F03|CP-L:QA-05|operator + milestone-visual|
|GW-01A|The approved gateway authenticates and bounds every Calendar, Usage, Finance, Clipper, Nutrition, Fitness, and Supplement route.|missing|P02/P17 / F03|CP-L:GW-01A|integration + security-negative|
|GW-01B|Direct listeners, forged headers, and unauthorized route access fail closed.|missing|P02/P17 / F03|CP-L:GW-01B|security-negative + operator|
|GW-01C|Oversized bodies/responses and timeouts are rejected within the frozen limits.|missing|P02/P17 / F03|CP-L:GW-01C|integration + security-negative|
|GW-02A|Provider secrets are encrypted at rest and scoped to the service identity.|missing|P02/P17 / F03|CP-L:GW-02A|security-negative + operator|
|GW-02B|Service-SID ACLs prevent unauthorized read or write of provider secrets.|missing|P02/P17 / F03|CP-L:GW-02B|security-negative + operator|
|GW-02C|Rotation, revocation, and fail-closed startup behavior are tested.|missing|P02/P17 / F03|CP-L:GW-02C|security-negative + operator|
|GW-03A|Codex collector reaches the authenticated gateway and Node route without collecting prompts or file contents.|foundation|P02/P17 / F03|CP-L:GW-03A|integration + security-negative|
|GW-03B|Codex collector retry and restart behavior is idempotent and bounded.|foundation|P02/P17 / F03|CP-L:GW-03B|integration + security-negative|
|GW-04A|Claude collector uses the exact external-to-loopback route and authenticated forwarder.|foundation|P02/P17 / F03|CP-L:GW-04A|integration + security-negative|
|GW-04B|Claude retry and replay handling is idempotent and dual-auth compatible.|foundation|P02/P17 / F03|CP-L:GW-04B|integration + security-negative|
|GW-04C|Unauthorized Claude requests and forged identity are rejected.|foundation|P02/P17 / F03|CP-L:GW-04C|security-negative + operator|
|CL-01|Clipper authoritative source and supported fields are explicitly approved; unsupported values unavailable|blocked-external|P02/P16 / F01|ClipperCoordinator.refresh; CP-L:CL-01|operator + source|
|CL-02A|Clipper ingestion preserves integer EUR cents, typed fields, and source provenance through gateway and client.|missing|P02/P16 / F01|ClipperCoordinator.refresh; CP-L:CL-02A|integration + live-readonly|
|CL-02B|Partial, stale, and unavailable Clipper states remain distinct from zero.|missing|P02/P16 / F01|ClipperCoordinator.refresh; CP-L:CL-02B|integration + live-readonly|
|CL-02C|Clipper-only retry preserves typed error details and cannot duplicate an accepted record.|missing|P02/P16 / F01|ClipperCoordinator.refresh; CP-L:CL-02C|integration|
|CL-03A|Clipper Overview and detail surfaces expose only confirmed or honest unavailable data.|foundation|P02/P16 / F01|ClipperCoordinator.refresh; CP-L:CL-03A|ui-runtime + live-readonly|
|CL-03B|Clipper connection, revoke, and error states provide truthful setup/retry actions.|foundation|P02/P16 / F01|ClipperCoordinator.refresh; CP-L:CL-03B|ui-runtime + live-readonly|
|PR-01A|Fixture and demo routes are unreachable through production app and gateway configuration.|missing|P15 / F05|CP-L:PR-01A|integration + security-negative|
|PR-01B|The production health endpoint cannot be mistaken for live product data.|missing|P15 / F05|CP-L:PR-01B|integration + security-negative|
|WS-01A|Confirmed app state publishes versioned, privacy-filtered, protected per-module widget snapshots atomically.|foundation|P14 / F04|WidgetSnapshotPublisher.publish; CP-L:WS-01A|integration + device|
|WS-01B|Widget timeline reload requests are coalesced and budget-aware.|foundation|P14 / F04|WidgetSnapshotPublisher.publish; CP-L:WS-01B|integration + device|
|WS-02A|Widget providers render fresh, expired, locked, redacted, unavailable, and stale snapshots truthfully after reload.|foundation|P14 / F04|WidgetSnapshotPublisher.publish; CP-L:WS-02A|integration + device|
|WS-02B|A reload request is not treated as an immediate-display guarantee.|foundation|P14 / F04|WidgetSnapshotPublisher.publish; CP-L:WS-02B|integration + device|
|DA-01A|Calendar authority and schema version are explicit at the client/server boundary.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-01A|source + integration|
|DA-01B|Calendar revisions, idempotency, offline queue, tombstones, deletion propagation, and retention have positive and negative integration evidence.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-01B|integration|
|DA-02A|HealthKit/Fitness authority and the device-local or authenticated-upload exception are explicitly recorded.|missing|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-02A|source + device|
|DA-02B|Fitness revisions, idempotency, offline behavior, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.|missing|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-02B|integration + device|
|DA-03A|Confirmed nutrition records are authoritative and draft proposals are excluded from durable totals.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-03A|source + integration|
|DA-03B|Nutrition revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-03B|integration|
|DA-04A|Supplement schedule, occurrence, action, and inventory authority is explicit with a versioned schema.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-04A|source + integration|
|DA-04B|Supplement revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-04B|integration|
|DA-05A|Usage sample, aggregation, and provider authority is explicit with a versioned schema.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-05A|source + integration|
|DA-05B|Usage revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.|foundation|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-05B|integration|
|DA-06A|Finance account, transaction, budget, and holding authority is explicit with reconciliation IDs and a versioned schema.|missing|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-06A|source + integration + live-readonly|
|DA-06B|Finance revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.|missing|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-06B|integration + live-readonly|
|DA-07A|Clipper snapshot authority, schema, and correction/revocation behavior are explicit.|missing|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-07A|source + integration + live-readonly|
|DA-07B|Clipper revisions, idempotency, offline queue, tombstones, deletion, retention, and positive/negative evidence are defined before live enablement.|missing|P01/domain owner / F03|R3-04 adapter methods proposed; CP-L:DA-07B|integration + live-readonly|
|HK-01A|HealthKit capability and iOS-only entitlement are present with no macOS or fixture claim.|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-01A|release-signature + device|
|HK-01B|NSHealthShareUsageDescription and NSHealthUpdateUsageDescription are present and truthful.|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-01B|release-signature + device|
|HK-02A|HealthKit availability is checked with HKHealthStore.isHealthDataAvailable().|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-02A|device + ui-runtime|
|HK-02B|Restricted, unavailable, denied, pending, and revoked health-source states remain distinct.|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-02B|device + ui-runtime|
|HK-03A|Read and write authorization are separate and write status uses authorizationStatus(for:).|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-03A|device + ui-runtime|
|HK-03B|Read denial is treated as indistinguishable from no readable samples and never becomes zero.|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-03B|device + ui-runtime|
|HK-04A|Anchored queries reconcile source/device, units, duplicates, revisions, and deletions.|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-04A|unit + device + integration|
|HK-04B|HealthKit reconciliation preserves partial/stale provenance and never fabricates zero values.|missing|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-04B|unit + device + integration|
|HK-05A|A signed physical-device Helio/Zepp to HealthKit path proves source provenance.|blocked-external|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-05A|device + live-readonly|
|HK-05B|Physical-device evidence covers partial, stale, and conflict states without fixture substitution.|blocked-external|P11 / F02|HealthKitProductionBridge.requestReadAuthorization; CP-L:HK-05B|device + live-readonly|
|PC-01A|Sparkasse/Enable Banking consent and session lifecycle is gateway-owned and read-only.|missing|P09/P12/P17 / F01/F02|CP-L:PC-01A|integration + live-readonly|
|PC-01B|Sparkasse/Enable Banking expiry, revoke, freshness, and retry states are source-labelled.|missing|P09/P12/P17 / F01/F02|CP-L:PC-01B|integration + live-readonly|
|PC-02A|Revolut Personal support or unavailable capability is explicit and consent is gateway-owned.|missing|P09/P12/P17 / F01/F02|CP-L:PC-02A|integration + live-readonly|
|PC-02B|Revolut Personal expiry, revoke, freshness, retry, and no-secret-client behavior are proven.|missing|P09/P12/P17 / F01/F02|CP-L:PC-02B|integration + live-readonly|
|PC-03A|Revolut Business eligibility and consent/token lifecycle are explicit and gateway-owned.|missing|P09/P12/P17 / F01/F02|CP-L:PC-03A|integration + live-readonly|
|PC-03B|Revolut Business expiry, revoke, freshness, retry, and no-secret-client behavior are proven.|missing|P09/P12/P17 / F01/F02|CP-L:PC-03B|integration + live-readonly|
|PC-04A|Trade Republic manual import parses supported records with provenance and duplicate detection.|missing|P09/P12/P17 / F01/F02|CP-L:PC-04A|integration|
|PC-04B|Trade Republic reimport and reconciliation preserve corrections without duplicate balances.|missing|P09/P12/P17 / F01/F02|CP-L:PC-04B|integration|
|PC-05A|Codex capability, wire fields, freshness, and rate-limit semantics are explicit.|foundation|P09/P12/P17 / F01/F02|CP-L:PC-05A|integration + live-readonly|
|PC-05B|Codex history, scheduler, restart, retry, and unavailable behavior are proven.|foundation|P09/P12/P17 / F01/F02|CP-L:PC-05B|integration + live-readonly|
|PC-06A|Claude statusline capability, freshness, history, and forwarder install contract are explicit.|foundation|P09/P12/P17 / F01/F02|CP-L:PC-06A|integration + live-readonly|
|PC-06B|Claude restart, retry, and unavailable behavior are proven without prompt/file-content collection.|foundation|P09/P12/P17 / F01/F02|CP-L:PC-06B|integration + live-readonly|
|PC-07A|GLM credential scope and wire capability are explicit or the provider is visibly unavailable.|missing|P09/P12/P17 / F01/F02|CP-L:PC-07A|integration + live-readonly|
|PC-07B|GLM freshness, retry, rate-limit, history, and restart behavior are proven or unavailable.|missing|P09/P12/P17 / F01/F02|CP-L:PC-07B|integration + live-readonly|
|PC-08A|DeepSeek credential scope and wire capability are explicit or the provider is visibly unavailable.|missing|P09/P12/P17 / F01/F02|CP-L:PC-08A|integration + live-readonly|
|PC-08B|DeepSeek freshness, retry, rate-limit, history, and restart behavior are proven or unavailable.|missing|P09/P12/P17 / F01/F02|CP-L:PC-08B|integration + live-readonly|
|PC-09A|Google AI Studio credential scope and wire capability are explicit or the provider is visibly unavailable.|missing|P09/P12/P17 / F01/F02|CP-L:PC-09A|integration + live-readonly|
|PC-09B|Google AI Studio freshness, retry, rate-limit, history, and restart behavior are proven or unavailable.|missing|P09/P12/P17 / F01/F02|CP-L:PC-09B|integration + live-readonly|
