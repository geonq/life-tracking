# DECISIONS — life-tracking (LifeOS native app)

Superseded dated decisions are archived at
[`archive/DECISIONS-2026-08-28-part-01.md`](archive/DECISIONS-2026-08-28-part-01.md).

## Current continuation — 2026-09-07 Europe/Berlin

- The active source checkpoint is local commit `65b2140` on
  `lifeos-foundation-checkpoint-20260812`. The local origin tracking ref is
  `f600a44`; the external push was blocked by automatic approval review, so
  remote parity is unclaimed.
- Three Astra Medium read-only audits completed: security/migration,
  cross-device automation/persistence, and UI/widgets. They found P1 release
  blockers and missing automation/widget behavior. Their findings are the
  current plan; no worker changed source or machine state.
- Windows candidate verification and read-only preflight passed. An authorized
  installer retry is still running; cutover is not accepted until post-install
  readback and rollback evidence exist.

## Security and deployment

- The Windows gateway must not call `tailscale.exe` at startup. It runs as
  `NT SERVICE\LifeOSGateway`; Tailscale LocalAPI is Administrators-only.
- A SYSTEM task publishes a bounded, non-secret Tailscale snapshot; the gateway
  reads it under strict schema and freshness checks. The user authorized this
  persistent privileged component. Windows accepts the task XML only when the
  SYSTEM SID is paired with `RunLevel`; an explicit `LogonType` element is
  rejected on this host, while `Get-ScheduledTask` reports `ServiceAccount`.
- The snapshot directory is readable by the gateway but not writable by it;
  the writer script is hash-verified. Service identities, ACL rights, task
  action, Serve state, and runtime freshness still require live evidence.
- The Astra security audit is authoritative for the next work order: nearby
  Calendar transport needs explicit pairing; local API routes need scoped
  caller authentication; Uvicorn must preserve socket identity; snapshot
  freshness must be enforced while the gateway is running; ACL verification
  must check rights, not only identity; Calendar input validation must be
  complete.

## Data and sync

- Python owns the production Calendar authority with conditional revisions,
  ETags, idempotency, and projection repair. The Node Calendar store is a test
  fixture; it is not a second production authority.
- Local edits must gain a durable outbox operation and precise server receipt
  before sync is called automatic. A timeout retries the exact body and key;
  a newer local edit remains pending; WebSocket events are invalidation hints.
- Domain ownership is explicit: Calendar/manual records may be authored on
  Mac/iPhone; bank observations are server-derived; Trade Republic imports are
  confirmed user facts; HealthKit anchors stay on iPhone; widgets are
  privacy-filtered projections.
- Deletions retain tombstones until active replicas acknowledge them. A server
  restore creates a new epoch. Missing records never imply deletion.
- Legacy migration must quiesce writers, export authoritative envelopes and
  revocation/replay state, classify fresh/legacy/upgrade/repair installs, and
  refuse rollback that would discard acknowledged new writes.

## Provider and truth boundaries

- Enable Banking is the live bank path for the linked Sparkasse Leipzig and
  Revolut accounts. Store opaque connection/session IDs and provenance, never
  bank credentials. Coalesce refreshes, preserve successful partial results,
  and persist typed freshness/failure state.
- Trade Republic remains a manual CSV preview/import path. Keep import batches,
  account identity, corrections, and holdings separate from live balances.
- HealthKit is iPhone-owned. Mac/Windows may display a versioned replica with
  source/device/time provenance, never claim to write HealthKit, and never turn
  an empty or denied read into zero. Zepp actions are used only if a supported
  action exists; otherwise a visible manual-sync step is truthful.
- Missing, stale, partial, conflict, unsupported, and error states remain
  distinct. No provider value is invented.

## UI and release scope

- Preserve all current module and widget kinds; PayPal is removed. Usage stays
  Home-owned and Finance analytics stays within Finance.
- Main brand blue is `#0253C4` from the exact ramp in `colors.md`; do not reuse
  same-saturation blues for unrelated semantics. Estimates/projections remain
  green, with visible observed/projected distinctions.
- Tasks widgets need real Calendar-backed data, Finance widgets need bounded
  history/budget inputs, and Fitness widgets need truthful capability states.
  Transparent inner panels and metadata must be verified over the user's grey
  wallpaper in dark/clear modes.
- Personal Team signing and USB refresh are external gates. Preserve the app
  identity and data, inspect actual profile expiry, and do not claim a seven-day
  refresh is automatic until a signed device proves it.

## Acceptance discipline

Source tests, a build, `/health`, or a successful Shortcut notification do not
prove completion. Release evidence must show local durable commit → server
receipt → second-device durable adoption → widget projection, plus security,
migration, provider, signed-device, visual, and rollback evidence.
