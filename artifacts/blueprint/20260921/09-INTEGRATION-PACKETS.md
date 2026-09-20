# Integration, security and operations
Exact allowed source/doc paths are in 14-OWNERSHIP.json. Cross-owner fixes return to the owning packet.

## P14 — widgets, App Intents and installer
WidgetSnapshotPublisher.publish consumes accepted domain revisions; skip unchanged digest.
Version/freshness/privacy projection never calls provider/HealthKit from extension.
Wire current widget catalog, next-event accessoryRectangular and Mac equivalents to qualified producers.
Render compact dark/tinted/default variants; container-relative corners; privacySensitive content.
LifeOSAppIntents: MorningStatus performs available refresh and reports actual freshness;
workout completion intent delegates to store; entity IDs resolved before mutation.
Zepp action opens official supported action if discovered and verified; otherwise explicit manual sync step.
No fabricated Zepp URL scheme or assertion that opening it completed sync.
USB Refresh Mac Shortcut calls install_personal_device.sh through Run Shell Script with fixed quoted path.
Installer validates connected UDID, existing bundle ID/team, build/profile expiry, then installs in place.
Never uninstall to renew. Preserve data; require backup/export before bundle/team migration.
Document Shortcut steps in docs/personal-shortcuts.md, including Xcode/USB trust/Developer Mode prerequisites.
Profile/capabilities unavailable: code stays buildable; widget/HealthKit gates remain blocked, no silent alternative container.
Acceptance: snapshot revision/digest, intent idempotency, stale/locked deep link;
installer checks failure paths; physical profile renewal remains distinct proof.

## P15 — cleanup and security
Produce dead-code-manifest.md: symbol, references, target membership, replacement, migration need, removal owner.
Only delete proven unused code after reference scan including string routes, fixtures, intents and Xcode targets.
DemoFixtures stays behind explicit development launch flags; remove no referenced preview fixture blindly.
P10 removes coaching UI; P08 renames chat icon copy; P16 removes forbidden navigation/production fixture selection.
Do not delete unrelated unconnected modules as “cleanup”; inventory carries their unresolved required behavior.
Node API existing Host/size/constant-time/history protections retained; audit malicious local requests.
Fix proven remaining Node issues in owned files; no speculative whole-file rewrite.
Pin CI actions to reviewed commit SHAs; pin generator/dependencies; lockfile change scoped and reviewed.
Dashboard CSP baseline default-src self, object-src none, base-uri none, frame-ancestors none;
enumerate actual build asset/network needs before relaxing; no blanket unsafe-eval.
Audit dependency advisories after lock update; run relevant service suite once.
Security finding schema: severity, SHA, entrypoint, payload, expected/observed, owner, fix and evidence.
Astra checks transport admission/replay, path traversal/reparse, raw tax leakage, CSV/regex bounds,
clock skew/duplicate IDs, shell resolution, secrets in logs, crash/disk-full/recovery, supply chain.
Use owned disposable endpoints/data; do not penetration-test bank/Apple/Google/Zepp infrastructure.
All exploitable high/critical and data-loss findings block release; documented residual risks require explicit acceptance.

## P16 — composition and exclusive shared integration
Own project.yml, application roots, OverviewView, Settings, ModuleNavigation, existing TailscaleSyncClient.
Register ios/Sync in LifeOS/LifeOSMac only; no transport tasks in WidgetKit.
One application composition root creates domain stores, sync adapters, engine, snapshot publisher.
No per-view singleton duplication; lifecycle stop cancels tasks and subscriptions idempotently.
LifeOSApp/LifeOSMacApp route through existing native NavigationStack authority.
OverviewView adopts Home layout; match card IDs only where source exists in same host.
Settings exposes actual relay/server/vault/queue/pairing/conflicts, manual refresh and revoke.
TailscaleSyncClient existing provider paths remain exact Windows host; new transport uses enrolled registry.
Do not broaden approved hosts to *.ts.net or switch bank fetch to Mac blindly.
Legacy calendar/import write paths disabled only after pending receipts and v1 negotiated endpoint are safe.
Wire production launch to live sources; fixture flags debug-only and visibly marked.
Register permitted background task identifiers and handlers; expiration cancels operation without losing outbox.
New App Group capability only when profile supports; never fake container availability.
Home→Usage/Clipper/Finance navigation reversible without flash; preserve route scroll and focus.
Acceptance: integrated Mac launch without fixture args; open every route; real local saves/relaunch;
Mac relay round trip in disposable data; no leaked process or duplicated refresh task.
This packet is the sole XcodeGen owner during execution. Generate once after all files are registered.
Generated project changes may be recorded only if repository normally tracks them; no hand editing.

## P17 — canonical Windows deployment (requires Windows online)
Read exact existing deployment marker/journal/candidate hashes and stopped service state afresh.
Build reviewed candidate using pinned source; never clear marker to bypass recovery.
Preserve existing service config/provider secrets; protected ACL and reparse checks before reads/writes.
verify-candidate → disposable install/failure/rollback proof → Astra cutover review → authorized canonical install.
Verify actual service identity, automatic startup/restart, only loopback :8421,
Tailscale Serve exact host/port, no Funnel, trusted-edge OS-owner checks, /health and /ready.
Add replication DB directory to protected config; existing bank secrets remain Windows-only.
Replay Apple outage operations before compacting anything; incoming snapshots do not erase local edits.
Rollback restores binaries/config compatible with old store or stops safely with journal preserved;
never roll data back behind acknowledged mutations.
Record source SHA, service version, configuration hashes excluding secrets, restart/reboot and rollback evidence.
Mac/static validation cannot substitute Windows ACL/service proof. No network attempts while host unavailable.

## P18 — final release and storage discipline
run_prerelease_lanes orchestrates one Apple lane at a time with existing result validator.
Reuse a stable owned DerivedData per configuration for incremental builds; unique bounded result bundles.
Full clean only for changed toolchain/config or evidenced cache fault, not every packet.
Storage guard before lanes; 15 GiB hard floor, aim >=20 GiB; stop generating artifacts below floor.
Keep last successful and active result bundle plus compact receipts; remove only enumerated completed temp paths.
No automatic deletion of app containers, vaults, user exports, source, booted simulators or active evidence.
Track bytes written by build lane if available; storage used is not SSD lifetime wear.
One manual app for testing; close only owned process identified by executable/PID after captures.
Quiet compile allowed; stop only documented timeout/resource fault/cancellation, record as unverified.
Final UI/security corrections go back to owner, then rerun impacted acceptance cases.
Acceptance: release matrix, crash-free Mac session, no idle build/simulator, artifacts bounded, commit/push parity.
Controller publishes accepted code and context gradually after final go; planning phase makes no commits.

## Dependency handoffs
P02 owns main.py for both original routes and new route registration; P13 supplies sanitized tax contract to P02.
P09 supplies Finance DTO/adapter changes to P02 for gateway route composition; do not let P09 edit main.py.
P15 can identify any vulnerability, but fixes in Swift/privacy/deployment go back to P03/P13/P17.
P16 passes completed HealthKit hooks to P10/P14 through injection; no direct edit outside owner scope.
P17 deployment is deferred while Windows unavailable; P18 may finish Mac/simulator evidence meanwhile with W gates open.
