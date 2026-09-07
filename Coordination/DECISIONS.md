# DECISIONS — life-tracking (LifeOS native app)

Superseded dated decisions are archived at [`archive/DECISIONS-2026-08-28-part-01.md`](archive/DECISIONS-2026-08-28-part-01.md).

## Continuation state — 2026-09-04 Europe/Berlin

## Continuation correction — 2026-09-07 Europe/Berlin

- Codex continuation is manual after the Claude handoff. The previous worker
  dispatch could not run Astra after the Codex weekly limit was reached; no
  Astra-authored plan or review is claimed. No watcher or overnight scheduler
  is active.
- The current source checkpoint is `c75c1cb`; the iOS logic suite now covers
  1,245 passing tests after the finance percentage and lifestyle determinism
  fixes. Coordination state must describe current evidence rather than the
  earlier pre-cutover snapshot.
- The current product scope removes PayPal from the active app/API catalog;
  historical eligibility notes do not create a live PayPal surface.
- The current visual decision makes `Series.estimate` vivid green. The older
  orange `#EF8600` mapping is superseded; warning remains a state semantic.
- The 2026-09-07 Luna audit reached the source/evidence boundary and recorded
  the live Windows host as legacy `LifeOSSyncServer` only. The account limit
  interrupted the final report write; the reconstruction and detailed plan are
  in `tasks/luna-audit.md` and `tasks/final-plan.md`.
- The Windows service-SID verifier must translate virtual-account ACL entries
  before comparing them to `S-1-5-80-*`; deployment remains closed until that
  assertion is tested on Windows.

## Existing decisions (unchanged)

- The Windows gateway must NOT call `tailscale.exe` at startup: it runs as the
  virtual service account `NT SERVICE\LifeOSGateway` and Tailscale's LocalAPI is
  the Administrators-only `ProtectedPrefix\Administrators\Tailscale` pipe, so the
  call always fails and rolls the install back.
- Ruled out: pinning the verified login/DNS into the service config at install.
  It drops the per-start re-check that Serve has not been reconfigured (Funnel
  enabled), the control that keeps health/finance data off the public internet.
- Chosen: a SYSTEM scheduled task publishes a bounded, non-secret, ACL-protected
  Tailscale snapshot; the gateway reads it under strict schema and <=90s
  freshness checks. Trust set is unchanged (operator/SYSTEM/Administrators), so
  it is not a privilege downgrade. Needs geonq's approval as a persistent
  privileged component; written and reviewed, NOT deployed.
- The snapshot lives where the gateway can read but not write, and the staged
  writer is hash-verified: SYSTEM runs it with `-ExecutionPolicy Bypass` every
  60s, making it the highest-value persistence target on that box.
- Undecided finding: `Assert-ServiceSidNotAllowed` compares
  `IdentityReference.Value` to an `S-1-5-80-...` SID while Get-Acl renders
  virtual service accounts as `NT SERVICE\<name>`, so its five verify.ps1 call
  sites have most likely never asserted anything. Left untouched deliberately.

## Data and sync

- Calendar local mutation is serialized durable read/modify/write; generation gates publication, and the client rereads before best-effort Tailscale PUT.
- The server is a dumb JSON blob store; merge remains in Swift. No remote atomicity claim exists without a conditional revision API.
- Windows is authoritative for live gateway execution. BitLocker C/D is ON; the exact private `.ts.net` host enters only through signed release paths and the source allowlist fails closed.

## Truth and provider boundaries

- Contracts are provider-neutral and source-aware: never invent live values,
  infer health conclusions, or replace missing samples with zero. Unavailable,
  stale, partial, conflict, and error states stay distinct.
- Enable Banking replaces GoCardless for the personal Finance path. The first
  live targets are the user's linked Sparkasse Leipzig and Revolut Personal
  accounts in the Enable Banking Production app.
- Active setup and acceptance documentation must use Enable Banking
  connection/session terminology; GoCardless/requisition wording is retained
  only in historical handoff entries when needed for audit history.
- The Finance migration is allowed to proceed secret-free: provider adapter,
  callback/session lifecycle, typed mapping, and mocked contract tests may be
  implemented before any credential transfer. The private key and public
  certificate stay on the Mac and never enter Git, the iOS client, chat, logs,
  or an agent prompt.
- Windows remains authoritative for live gateway execution. The BitLocker and
  recovery-key gate has been satisfied; the Enable Banking key/certificate now
  exist only in the protected Windows secret directory. Use task-scoped secret
  configuration only; never bake credentials into source or deployment
  artifacts.
- Enable Banking's intended lifecycle is ASPSP discovery/selection → HTTPS authorization callback with state/code validation → provider session → account balances and transactions. Persist opaque connection/session IDs and source provenance, not bank credentials; no payment initiation is in scope.
- Native finance display and widgets may derive net worth only from observed
  account balances and cash flow only from observed transactions. Missing
  observations stay unavailable; stale provenance stays visibly stale. The
  local strict contract/hardening checkpoints are distinct from any live
  Enable Banking deployment; live data still requires user consent and
  operator evidence.
- Source acceptance, Windows deployment, user consent, and physical-device
  evidence remain separate release gates.
- Health/lifestyle/sensor semantics (Sleep/Stress, hydration, HealthKit import,
  Helio authority, retained observations) are archived in
  [`archive/DECISIONS-archive-2026-09.md`](archive/DECISIONS-archive-2026-09.md)
  and remain live decisions.

## UI and release scope

- Release-visible macOS destinations are Home, Calendar, Finance, Fitness, Tax,
  Settings; iOS is Home, Calendar, Finance, Fitness, More. Usage is Home-owned;
  setup belongs in substantive Settings.
- iPhone Calendar uses native finger-tracked horizontal paging with live header
  projection. Empty timed space opens creation on double tap, not long hold.
  Durable item kinds are Event, Todo, and Daily Schedule: Todo exposes a direct
  persisted completion control; Daily Schedule uses planned/in-progress/done/
  aborted progress. Uploaded icons remain reusable in the same picker flow.
- WidgetKit calendar storage requires one real provisioned App Group shared by
  app and extension. A Personal Team placeholder is a build-capability gate,
  not a disconnected calendar, and Tailscale is not a substitute.
- The macOS Calendar pointer-runtime lane remains incomplete/unaccepted.
- No raw provider/bank secrets enter the client. Windows deployment is allowed
  only through a reviewed, hash-verified staging promotion with a rollback
  backup; bank consent and physical-device actions remain user-controlled.
- `services/windows-service-host/deploy` is reviewed, reproducible, and
  trackable; runtime staging, backups, machine state, and secrets stay excluded.
- Personal Team refresh remains external fixed-Mac USB tooling. Settings
  preflight proves configuration/reachability only, never provider consent.

## Acceptance discipline

- Evidence is partial-tranche; do not call product, provider, visual, sync, or security acceptance complete, or report a score before the 95% gates and geonq’s final review. Root owns Git; bounded workers never commit or force-push.
