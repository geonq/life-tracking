# LifeOS Windows Service Host

This is one parameterized Windows Service host. Each SCM service process starts
exactly one configured foreground child. The same published `win-x64` binary is
used for `LifeOSAPI` and `LifeOSGateway`; the services have separate config
files, service identities, working directories, and log directories.

The host does not bind a socket. The child owns its listener. The host launches
the child with `UseShellExecute=false` and `ProcessStartInfo.ArgumentList`,
passes only the environment entries in the config, redirects both output streams
to bounded rotating logs, and does not print child/config values. It waits for a
successful 2xx response from the configured literal loopback HTTP URL before
the Windows Service lifetime reports `Running`. A child exit after readiness
sets a non-zero process exit code and stops the service so SCM can apply its
failure/recovery policy.

## Exact config schema

The UTF-8 JSON file is capped at 64 KiB, has no comments/trailing commas, and
rejects unknown or duplicate properties. All fields below are required:

```json
{
  "executablePath": "C:\\Program Files\\nodejs\\node.exe",
  "workingDirectory": "C:\\Program Files\\LifeOS\\api",
  "arguments": ["C:\\Program Files\\LifeOS\\api\\dist\\server.js"],
  "environment": {
    "NODE_ENV": "production",
    "PORT": 8787,
    "USAGE_STORE_PATH": "C:\\ProgramData\\LifeOS\\state\\api-usage-history.jsonl",
    "CLAUDE_INGEST_ENABLED": false,
    "CLAUDE_INGEST_SECRET_FILE": "C:\\ProgramData\\LifeOS\\secrets\\claude-ingest.secret",
    "CODEX_INGEST_ENABLED": false,
    "CODEX_INGEST_SECRET_FILE": "C:\\ProgramData\\LifeOS\\secrets\\codex-ingest.secret",
    "CODEX_LIVE_ENABLED": false,
    "SYSTEMROOT": "C:\\Windows",
    "TEMP": "C:\\Windows\\Temp",
    "TMP": "C:\\Windows\\Temp",
    "PATH": "C:\\Windows\\System32;C:\\Program Files\\nodejs"
  },
  "healthUrl": "http://127.0.0.1:8787/health",
  "startupTimeoutSeconds": 30,
  "shutdownTimeoutSeconds": 15,
  "logDirectory": "C:\\ProgramData\\LifeOS\\logs\\api",
  "logFileName": "child.log",
  "maxLogBytes": 10485760,
  "maxLogFiles": 5
}
```

`environment` is an explicit allowlist. Supported service API keys include
`PORT`, `NODE_ENV`, `USAGE_STORE_PATH`, the `*_ENABLED` and `*_LIVE_ENABLED`
flags, `CLAUDE_INGEST_SECRET_FILE`, `CODEX_INGEST_SECRET_FILE`, and the
runtime path keys `SYSTEMROOT`, `TEMP`, `TMP`, and `PATH`. The optional
Open Food Facts integration adds exactly two names: `OPEN_FOOD_FACTS_ENABLED`
(the literal boolean `true`/`false`) and
`OPEN_FOOD_FACTS_CONTACT_EMAIL`. When the flag is `true`, the contact field is
required and must be a bounded (254-character maximum), ASCII syntax-valid
email without whitespace, NUL, or newline characters. Invalid or missing
integration configuration is passed only as a fail-closed configuration state;
the API makes no upstream request. The contact is never printed or returned.
Unknown
names, secret-valued names, newline/NUL values, relative paths,
and values that are not paths, booleans, or bounded integers are rejected.
Tailscale is an independently installed/configured Windows service; no
Tailscale auth key or Tailscale-specific environment variable is passed to
either child.
Secret values never belong in this file: put them in the child-owned secret
files and pass only their absolute file paths. The host never reads their
contents. A secret-file path may be absent while its corresponding ingestion
flag is `false`; enabling that feature makes the file a required startup
dependency.

The host requires executable, working, log, and referenced secret/config paths
to exist and rejects reparse points/symbolic links where the OS exposes them.
The usage-store path may be a new file, but its parent directory must exist and
be non-reparse. Health URLs must be `http://` and literal loopback (`127.0.0.1`,
`::1`, or `localhost`) with no credentials, query, or fragment.

## Invocation and SCM identity

The only CLI values are the non-secret config path and service name:

```text
LifeOS.ServiceHost.exe --service-name LifeOSAPI --config C:\ProgramData\LifeOS\services\LifeOSAPI.json
LifeOS.ServiceHost.exe --service-name LifeOSGateway --config C:\ProgramData\LifeOS\services\LifeOSGateway.json
```

Install each service with a distinct virtual service account and unrestricted
service SID. The commands below are examples to run on Windows during
installation; this repository does not run or mutate SCM/ACL state:

```powershell
sc.exe create LifeOSAPI binPath= '"C:\Program Files\LifeOS\ServiceHost\LifeOS.ServiceHost.exe" --service-name LifeOSAPI --config "C:\ProgramData\LifeOS\services\LifeOSAPI.json"' obj= 'NT SERVICE\LifeOSAPI' password= '' start= auto
sc.exe sidtype LifeOSAPI unrestricted
sc.exe create LifeOSGateway binPath= '"C:\Program Files\LifeOS\ServiceHost\LifeOS.ServiceHost.exe" --service-name LifeOSGateway --config "C:\ProgramData\LifeOS\services\LifeOSGateway.json"' obj= 'NT SERVICE\LifeOSGateway' password= '' start= auto
sc.exe sidtype LifeOSGateway unrestricted
```

The installer, not the host, owns ACL provisioning. The host verifies that log
ACLs do not grant allow access to `Everyone`, `Users`, `Authenticated Users`,
interactive users, or shared service accounts; it never broadens or rewrites
ACLs. Grant only the matching service SID plus `SYSTEM` and local
Administrators. Config and secret directories should grant the service SID
read access; state and log directories should grant it modify access:

```powershell
icacls C:\ProgramData\LifeOS\services /inheritance:r
icacls C:\ProgramData\LifeOS\services /grant:r "NT SERVICE\LifeOSAPI:(R)" "NT SERVICE\LifeOSGateway:(R)" "SYSTEM:(F)" "Administrators:(F)"
icacls C:\ProgramData\LifeOS\logs\api /inheritance:r
icacls C:\ProgramData\LifeOS\logs\api /grant:r "NT SERVICE\LifeOSAPI:(M)" "SYSTEM:(F)" "Administrators:(F)"
```

Use separate equivalent ACLs for gateway logs/state. A broad ACL causes the
host to fail before the child starts.

On Windows the host also requires the log directory ACL to be explicitly
protected. A newly-created child log may inherit that directory's entries, so
the file check permits inheritance only when every effective `Allow` SID is the
directory owner/current service identity, `SYSTEM`, or local `Administrators`;
an unrelated user, group, service SID, reparse path, or broad principal fails
closed. This is covered by the cross-platform SID-classification tests and
must be exercised again in a Windows integration run after deployment; the
macOS/Linux test suite intentionally skips OS ACL inspection.

On stop, the host makes a best-effort graceful request by closing redirected
stdin and calling `CloseMainWindow`; console Node/FastAPI children generally do
not treat either as a shutdown signal. Therefore the configured grace period is
a bounded opportunity for a child that implements one of those hooks, followed
by `Kill(entireProcessTree: true)` so descendants cannot survive the service.
The child should flush/close its own state on its supported shutdown signal; the
host never writes child state or history.

## Build, test, and publish

From this directory with the .NET 9 SDK:

```powershell
dotnet restore src\LifeOS.ServiceHost.csproj
dotnet build src\LifeOS.ServiceHost.csproj -c Release
dotnet test tests\LifeOS.ServiceHost.Tests.csproj -c Release
dotnet publish src\LifeOS.ServiceHost.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o publish\win-x64
```

The published output contains one self-contained `LifeOS.ServiceHost.exe`
that bundles the .NET runtime and host dependencies; that executable is
deployed for both services. Only the SCM arguments and private JSON/ACL paths differ. No secrets are accepted on
the CLI, in the host config, or in host-generated exception messages/log
prefixes. Child output is passed through a conservative secret-pattern
redactor before rotation.
