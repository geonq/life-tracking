# LifeOS Windows deployment toolkit

This directory contains a Windows-only, administrator-run deployment flow for
two independent SCM services. It does not SSH to a machine or mutate a remote
host. The service host binary is the self-contained `win-x64`
`LifeOS.ServiceHost.exe`; only the generated service-host JSON and SCM
identity differ between services.

The defaults preserve the existing source locations:

- API source: `D:\Hermes\lifeos-api`
- Gateway source: `D:\Hermes\lifeos-server`
- machine-owned runtime: `D:\Hermes\lifeos-runtime`
- machine-owned service/code, data, logs, secrets, and backups under
  `D:\Hermes\lifeos-*`

The installer copies a minimal API release (`dist`, package manifest, the real
contracts package, and production `zod`) plus Python gateway code and a reviewed
`gateway_launcher.py` into those machine-owned locations; it never grants a
service access to the source checkout, venv, or node workspace. Original source,
venv, and legacy data remain untouched. Every copy is hash-verified. Existing
destinations are moved into an ACL-locked install backup before replacement.
`usage-history.jsonl` is copied atomically from the legacy gateway `data`
directory into the API-owned data directory. `calendar.json` and `documents`
are copied into the Gateway-owned data directory. The legacy
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

## Required preflight inputs

The Python and Node inputs are explicit so an operator can choose the exact
installed runtimes. If omitted, the scripts try only machine-owned candidates
(`D:\Hermes\lifeos-api\node-runtime`, `node`, Program Files Node.js, a server
`.venv`/`venv`, and machine Python 3.12 locations). A gateway entry point must
be an existing file; `gateway.py`, `server.py`, and `main.py` are checked in
that order when no explicit path is supplied.

```powershell
$deploy = 'D:\Hermes\lifeos-services\deploy'
& "$deploy\preflight.ps1" `
  -ServiceHostBinarySource 'D:\staging\LifeOS.ServiceHost.exe' `
  -NodeRuntimeSource 'D:\staging\node' `
  -PythonRuntimeSource 'D:\Hermes\lifeos-server\.venv' `
  -GatewayEntryPoint 'D:\Hermes\lifeos-server\gateway.py'
```

Preflight is read-only. It requires an elevated PowerShell, confirms the
Tailscale SCM service and legacy task, rejects reparse/user-profile inputs,
and refuses to proceed without the existing Claude secret in the legacy
gateway location.

## Install and verify

Run the same explicit source parameters for install. Do not pass credentials,
bearer values, usernames, tailnet hostnames, or IP addresses to these scripts.

```powershell
& "$deploy\install.ps1" `
  -ServiceHostBinarySource 'D:\staging\LifeOS.ServiceHost.exe' `
  -NodeRuntimeSource 'D:\staging\node' `
  -PythonRuntimeSource 'D:\Hermes\lifeos-server\.venv' `
  -GatewayEntryPoint 'D:\Hermes\lifeos-server\gateway.py'

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
configures only Tailscale Serve `:8420 -> http://127.0.0.1:8421`. It never
invokes the public tunnel mode and fails verification if a truthy public-tunnel
flag is reported. The old
`LifeOSSyncServer` task is exported into the locked install backup and is
disabled only after both services and Serve pass cutover. It is never deleted.

The reviewed launcher requires the private Serve route before starting the
Gateway, so production install does not support skipping Serve configuration.
If Serve cannot be queried or configured, install stops before cutover and
restarts the legacy task when it had been running.

## Rollback

Rollback requires the install manifest printed by `install.ps1`:

```powershell
& "$deploy\rollback.ps1" `
  -ManifestPath 'D:\Hermes\lifeos-backups\install-...\manifest.json'
```

It stops and disables the new SCM services without deleting their registrations,
restores explicitly backed-up code, runtime, configs, data, and secrets, and
restores the prior legacy task state. New artifacts with no prior backup are
moved to rollback backup names rather than deleted. Tailscale Serve is not
reset because doing so could damage unrelated Serve routes; the saved status is
kept with the manifest for an operator-led restoration.

## Static checks

The Pester-like test is intentionally static: it can run before the scripts are
copied to Windows and proves the source contains the required service identities,
recovery policy, ACL boundaries, atomic migration hooks, task-preservation
rules, loopback endpoints, and no Funnel/delete/embedded-secret patterns.

```powershell
& "$deploy\tests\Deployment.Static.Tests.ps1"
```
