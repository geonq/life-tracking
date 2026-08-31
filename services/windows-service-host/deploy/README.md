# LifeOS Windows deployment toolkit

This directory contains a Windows-only, administrator-run deployment flow for
two independent SCM services. It does not SSH to a machine or mutate a remote
host. The service host binary is the self-contained `win-x64`
`LifeOS.ServiceHost.exe`; only the generated service-host JSON and SCM
identity differ between services.

The defaults preserve the existing source locations:

- API source: `D:\Hermes\lifeos-api`
- Gateway source: `D:\Hermes\lifeos-server`
- legacy gateway/data source: `D:\Hermes\lifeos-server` (override with
  `-LegacyGatewaySource` when deploying from a staged gateway tree)
- machine-owned runtime: `D:\Hermes\lifeos-runtime`
- machine-owned service/code, data, logs, secrets, and backups under
  `D:\Hermes\lifeos-*`

The installer copies a minimal API release (`dist`, package manifest, the real
contracts package, and production `zod`) plus Python gateway code and a reviewed
`gateway_launcher.py` into those machine-owned locations; when present it also
stages the reviewed supplement schema/seed and initializes the gateway-owned
SQLite catalog transactionally. The gateway bundle fails closed if any of
those reviewed files is missing. It never grants a
service access to the source checkout, venv, or node workspace. Original source,
venv, and legacy data remain untouched. Every copy is hash-verified. Existing
destinations are moved into an ACL-locked install backup before replacement.
`usage-history.jsonl` is copied atomically from the legacy gateway `data`
directory into the API-owned data directory. `calendar.json`,
`enablebanking-connections.json` (bounded to 256 KiB),
`finance-summary.json` (bounded to 1 MiB), and `documents` are copied into the
Gateway-owned data directory. The two Finance files are hash-verified,
journaled, and backed up for rollback. The legacy
`claude-ingest.secret` is copied to the separate secret directory; it is never
placed under a service-writable data directory. A distinct Codex secret is
generated from the OS CSPRNG when absent. Secret contents never appear in
generated JSON, manifests, output, or SCM arguments.

The service ACL boundary is deliberately narrow. Both virtual service
accounts have read/execute access to staged code/runtime and the shared
configuration directory. `LifeOSAPI` alone can modify API data/logs; it can
read the Codex secret. `LifeOSGateway` can read API data and can modify only its
calendar/documents/log directories. Both services can read the Claude secret.
The current interactive operator is resolved to a SID at install time. No
profile, `Users`, `Everyone`, or shared-service account grant is created.

The v17 source bundle is reproducible and intentionally includes every
trackable deployment file: `Deployment.Common.ps1`, `README.md`,
`gateway_launcher.py`, `install.ps1`, `preflight.ps1`, `rollback.ps1`,
`verify.ps1`, `tests/Deployment.Behavior.Tests.ps1`, and
`tests/Deployment.Static.Tests.ps1`. The staged gateway release carries
`bundleVersion: v17` plus a SHA-256/length record for every staged file.
Runtime data and secret contents remain ignored; the bundle contains only the
reviewed source and path references.

## Optional live-provider inputs

The default install keeps optional providers disabled. Passing a protected file
path opts the provider in and copies the file into the machine-owned secret
directory; raw API keys or private key contents are not accepted as parameters.

```powershell
& "$deploy\install.ps1" `
  -ServiceHostBinarySource 'D:\staging\LifeOS.ServiceHost.exe' `
  -NodeRuntimeSource 'D:\staging\node' `
  -PythonRuntimeSource 'D:\Hermes\lifeos-server\.venv' `
  -GatewayEntryPoint 'D:\Hermes\lifeos-server\main.py' `
  -ClipperIngestSecretSource 'D:\staging\clipper-ingest.secret' `
  -GoogleAIStudioApiKeySource 'D:\staging\google-ai-studio.key' `
  -EnableOpenFoodFacts `
  -OpenFoodFactsContactEmail 'operator@example.test' `
  -EnableBankingAppId 'registered-enable-banking-app' `
  -EnableBankingPrivateKeySource 'D:\staging\enable-banking.key' `
  -EnableBankingCertificateSource 'D:\staging\enable-banking.crt' `
  -EnableBankingApiBaseUrl 'https://api.enablebanking.com' `
  -EnableBankingRedirectUri 'https://registered.example.test/callback'
```

Enable Banking is enabled only when all five values are supplied together.
Clipper and Google AI Studio are enabled only when their protected source file
is supplied. The installer rejects partial banking configuration and fails
closed when a required secret file cannot be read. PayPal is not enabled by
this toolkit: it still requires official account/reporting-scope eligibility
and a separate server-side OAuth implementation.

## Required preflight inputs

The trusted-edge token is required. Before preflight, an operator must create
the canonical file `D:\Hermes\lifeos-secrets\tailscale-edge.token` with
exactly 32-256 printable ASCII bytes and no newline or UTF-8 BOM. Pass its path
as `-TailscaleEdgeTokenSource` to both preflight and install. No raw token is
accepted as a parameter. The scripts validate ownership, reparse safety,
format, and broad ACLs without displaying the value; a missing or invalid
source fails closed with an operator-actionable diagnostic. The installer
records only the canonical path in `gateway.app.json` and the rollback
manifest, applies the gateway read ACL in place, and never creates, copies,
serializes, logs, or transfers the token value.

The Python and Node inputs are explicit so an operator can choose the exact
installed runtimes. `-PythonRuntimeSource` accepts a runtime directory, its
`python.exe`, or a standard Windows venv's `Scripts\python.exe`; the resolver
rejects missing, reparse, and ambiguous layouts. If omitted, the scripts try
only machine-owned candidates (`D:\Hermes\lifeos-api\node-runtime`, `node`,
Program Files Node.js, a server `.venv`/`venv`, and machine Python 3.12
locations). The reviewed gateway entry point is the exact `main.py` file; pass
`-GatewayEntryPoint` when it is not at the gateway source root.

```powershell
$deploy = 'D:\Hermes\lifeos-services\deploy'
& "$deploy\preflight.ps1" `
  -ServiceHostBinarySource 'D:\staging\LifeOS.ServiceHost.exe' `
  -NodeRuntimeSource 'D:\staging\node' `
  -PythonRuntimeSource 'D:\Hermes\lifeos-server\.venv' `
  -GatewayEntryPoint 'D:\Hermes\lifeos-server\main.py' `
  -TailscaleEdgeTokenSource 'D:\Hermes\lifeos-secrets\tailscale-edge.token'
```

Preflight is read-only. It requires an elevated PowerShell, confirms the
Tailscale SCM service and legacy task, rejects reparse/user-profile inputs,
refuses an unattributed listener on legacy port `8421`, and refuses to proceed
without the existing Claude secret in the legacy gateway location. It also
executes both transferred deployment coverage files before any deployment
mutation. Serve inspection allows unrelated routes on other ports, but fails
closed on unsupported state, public-tunnel flags, ambiguity, or a route/port
collision on `8420`. A staged gateway source does not change the legacy data
source; pass `-LegacyGatewaySource` explicitly when that root differs from the
default.

## Install and verify

Run the same explicit source parameters for install. Do not pass credentials,
bearer values, usernames, tailnet hostnames, or IP addresses to these scripts.

```powershell
& "$deploy\install.ps1" `
  -ServiceHostBinarySource 'D:\staging\LifeOS.ServiceHost.exe' `
  -NodeRuntimeSource 'D:\staging\node' `
  -PythonRuntimeSource 'D:\Hermes\lifeos-server\.venv' `
  -GatewayEntryPoint 'D:\Hermes\lifeos-server\main.py' `
  -TailscaleEdgeTokenSource 'D:\Hermes\lifeos-secrets\tailscale-edge.token'

& "$deploy\verify.ps1"
```

`LifeOSAPI` is automatic-start under `NT SERVICE\LifeOSAPI`. `LifeOSGateway`
is delayed automatic-start under `NT SERVICE\LifeOSGateway`, dependent on
`LifeOSAPI` and the `Tailscale` SCM service. Both services use unrestricted
service SIDs and restart-only recovery of 60s/60s/60s with a 86400-second
reset period. No reboot action is configured or requested.

The generated listeners are loopback-only: API `127.0.0.1:8787`, Gateway
`127.0.0.1:8421`. The Python gateway launcher validates the exact private
Serve mapping, derives the local Tailscale login at runtime, sets the
machine-owned data root and external Claude secret path, and runs the reviewed
FastAPI app through uvicorn. After both health checks pass, the installer
adds only the free Tailscale Serve route `:8420/ ->
http://127.0.0.1:8421`; existing routes on other ports remain in place. A
route or port collision, ambiguous status, unsupported field, or truthy
public-tunnel flag fails verification before mutation. It never invokes the
public tunnel mode. The old
`LifeOSSyncServer` task is exported into the locked install backup and is
disabled only after both services and Serve pass cutover. If its detached
listener was present while the task reported `Ready`, the installer verifies
the exact Python runtime/main.py identity, disables the task, and stops only
that attributed PID. It is never deleted.
The Codex collector task is registered once at the late cutover boundary, after
the Node runtime, API release, ACLs, secrets, configs, and catalog are ready. If
cutover fails, its saved XML/state is restored; if it did not exist before the
install, the newly-created Codex task is removed during rollback. Install
backup entries are journaled to the manifest as each migration completes.
The installer also snapshots the two LifeOS SCM registrations before the first
stop. A failed install restores their prior start mode/dependencies and running
state, or removes a service that did not exist before the attempt.

The reviewed launcher requires the private Serve route before starting the
Gateway, so production install does not support skipping Serve configuration.
If Serve cannot be queried or configured, install stops before cutover and
restores the legacy task and listener when either was changed, including the
detached-listener/`Ready` case.

### Trusted-edge request path

Tailscale Serve supplies the canonical `Tailscale-User-Login` identity header
and, when the tailnet policy grants the configured capability, the
`Tailscale-App-Capabilities` JSON header. The exact route is configured with
`--accept-app-caps=lifeos.example/trusted-edge`; the capability name is public
policy metadata, not the secret. The tailnet administrator must grant that
capability to the intended users/devices. See the [Tailscale Serve capability
example](https://tailscale.com/docs/reference/examples/serve) and [Serve
reference](https://tailscale.com/docs/reference/tailscale-cli/serve).

`gateway_launcher.py` accepts exactly one well-formed capability header only
after a Windows transport proof succeeds. It maps the exact established
loopback connection to its owning PID with `GetExtendedTcpTable` and compares
that PID with the currently running `Tailscale` SCM service using
`QueryServiceStatusEx`. A direct local caller cannot inject the private header
by copying the canonical login or app-capability headers; missing, ambiguous,
non-loopback, non-established, unknown-service, and OS-query-error cases all
fail closed. The adapter strips the public capability and every
client-supplied `X-LifeOS-Trusted-Edge` header before forwarding the request.

Only after that OS-bound transport proof does it add the private header inside
the local ASGI scope using the token read from the canonical file. The token
is also set only in the gateway process's `LIFEOS_TAILSCALE_EDGE_TOKEN`
environment contract because the reviewed gateway requires that variable. It
is never sent to Tailscale, the network, SCM arguments, JSON, manifests,
logs, or the client. `LIFEOS_TAILSCALE_SERVICE_NAME` carries only the
allowlisted SCM service name. Requests without both the Serve identity and
this locally-derived exact token fail closed; health remains available for
diagnostics.

## Rollback

Rollback requires the install manifest printed by `install.ps1`:

```powershell
& "$deploy\rollback.ps1" `
  -ManifestPath 'D:\Hermes\lifeos-backups\install-...\manifest.json'
```

It stops the new SCM services, restores their pre-install registration/state
from the manifest (or leaves legacy manifests' services disabled), restores
explicitly backed-up code, runtime, configs, data, and secrets, and restores
the prior legacy task/listener and Codex task definitions/states. New file artifacts with no
prior backup are moved to rollback backup names rather than deleted;
the failed-install Codex task is the intentional exception because restoring
the exact pre-install task state requires removing a task that did not exist
before. Tailscale Serve rollback compares the authenticated pre-install and
post-install snapshots, removes only the LifeOS `:8420/` route, and verifies
that unrelated Serve entries and their capability selections are unchanged.
It never resets the whole Serve configuration. If a post-install snapshot is
missing or the current state changed concurrently, rollback fails closed for
operator-led recovery. Older manifests without a Serve snapshot or the
optional v17 token-path field remain accepted by the canonical rollback
validator and require operator-led restoration of any missing token setup.

## Static and behavioral checks

The static test can run before the scripts are copied to Windows and proves the
source contains the required service identities, recovery policy, ACL
boundaries, atomic migration hooks, task-preservation rules, loopback
endpoints, and no Funnel/delete/embedded-secret patterns. The behavioral test
executes the Serve decision, additive configuration, collision, concurrent
change, and targeted rollback paths against a local fake Tailscale executable;
it never contacts the real daemon. Keep both nested test files when
transferring this toolkit; preflight verifies and executes them before any
deployment state can be changed.

```powershell
& "$deploy\tests\Deployment.Static.Tests.ps1"
& "$deploy\tests\Deployment.Behavior.Tests.ps1"
```
