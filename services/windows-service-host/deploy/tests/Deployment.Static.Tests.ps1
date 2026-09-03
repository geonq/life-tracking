[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -File -Include '*.ps1', '*.py' -Recurse |
    Where-Object { $_.FullName -ne $PSCommandPath })
$text = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$installText = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw

function Assert-Text {
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    if ($text -notmatch $Pattern) { throw "FAIL: $Message" }
}

function Assert-NotText {
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    if ($text -match $Pattern) { throw "FAIL: $Message" }
}

function Assert-InstallOrder {
    param([Parameter(Mandatory)][string]$First, [Parameter(Mandatory)][string]$Then, [Parameter(Mandatory)][string]$Message)
    $firstIndex = $installText.IndexOf($First, [StringComparison]::Ordinal)
    $thenIndex = $installText.IndexOf($Then, [StringComparison]::Ordinal)
    if ($firstIndex -lt 0 -or $thenIndex -lt 0 -or $firstIndex -ge $thenIndex) { throw "FAIL: $Message" }
}

$preflightNamedArgs = [regex]::Match(
    $installText,
    '(?ms)\$preflightArgs\s*=\s*@\{(?<body>.*?)\r?\n\}\s*& \(Join-Path \$PSScriptRoot ''preflight\.ps1''\) @preflightArgs'
)
if (-not $preflightNamedArgs.Success) { throw 'FAIL: Preflight must be invoked with a named hashtable splat.' }
if ($installText -match '(?m)\$preflightArgs\s*=\s*@\(') { throw 'FAIL: Preflight arguments must not use an array splat.' }
foreach ($parameter in @(
    'ServiceHostBinarySource', 'ApiSource', 'GatewaySource', 'LegacyGatewaySource',
    'NodeRuntimeSource', 'PythonRuntimeSource', 'GatewayEntryPoint',
    'TailscaleExecutable', 'TailscaleEdgeTokenSource', 'TailscaleServiceName',
    'LegacyTaskName', 'CodexTaskName'
)) {
    $parameterPattern = '(?m)^\s+{0}\s*=\s+\${0}\s*$' -f [regex]::Escape($parameter)
    if ($preflightNamedArgs.Groups['body'].Value -notmatch $parameterPattern) {
        throw "FAIL: Preflight parameter is not bound by name: $parameter"
    }
}

Assert-Text 'LifeOSAPI' 'API service identity is present.'
Assert-Text 'LifeOSGateway' 'Gateway service identity is present.'
Assert-Text 'NT SERVICE\\LifeOSAPI' 'API virtual account is used.'
Assert-Text 'NT SERVICE\\LifeOSGateway' 'Gateway virtual account is used.'
Assert-Text 'sidtype.*unrestricted' 'Service SID mode is unrestricted.'
Assert-Text 'delayed-auto' 'Gateway is delayed automatic-start.'
Assert-Text 'LifeOSAPI.*Tailscale|Tailscale.*LifeOSAPI' 'Gateway depends on API and Tailscale.'
Assert-Text 'restart/60000/restart/60000/restart/60000' 'Recovery is restart-only at 60-second intervals.'
Assert-Text 'reset.*86400|86400.*reset' 'Recovery reset period is one day.'
Assert-Text '127\.0\.0\.1:8787' 'API loopback port is fixed.'
Assert-Text '127\.0\.0\.1:8421' 'Gateway loopback port is fixed.'
Assert-Text 'https=8420' 'Serve uses port 8420.'
Assert-Text 'usage-history\.jsonl' 'Usage history migration is present.'
Assert-Text 'Copy-FileVerifiedAtomic' 'Atomic hash-verified file migration is present.'
Assert-Text 'Disable-LegacyTaskAfterCutover' 'Legacy task is disabled only through the cutover helper.'
Assert-Text 'Restore-LegacyTask' 'Rollback restores the legacy task.'
Assert-Text 'Restore-CodexCollectorTask' 'Rollback restores the Codex collector task.'
Assert-Text 'RandomNumberGenerator' 'Codex secret is generated from the OS CSPRNG.'
Assert-Text 'gateway_launcher\.py' 'Gateway uses the reviewed Python launcher.'
Assert-Text 'uvicorn' 'Gateway launcher runs the FastAPI app under uvicorn.'
Assert-Text 'LIFEOS_DATA_DIR' 'Gateway data root is explicitly supplied.'
Assert-Text 'CLAUDE_INGEST_SECRET_FILE' 'Claude secret is supplied by path.'
Assert-Text 'LIFEOS_TAILSCALE_EDGE_TOKEN' 'Trusted edge token environment contract is present.'
Assert-Text 'TailscaleEdgeTokenSource' 'Trusted edge token is supplied by operator-managed path only.'
Assert-Text 'Assert-TailscaleEdgeTokenSource' 'Trusted edge token source is validated before deployment.'
Assert-Text 'tailscaleEdgeTokenPath' 'Gateway receives only the canonical edge token path.'
Assert-Text 'Assert-TailscaleEdgeTokenBytes' 'Trusted edge token bytes are bounded and printable.'
Assert-Text 'token value was not displayed' 'Token diagnostics are value-redacted.'
Assert-Text 'TrustedEdgeHeaderAdapter' 'Launcher bridges the trusted edge capability in-process.'
Assert-Text 'Tailscale-App-Capabilities' 'Launcher consumes the Tailscale app capability header.'
Assert-Text 'x-lifeos-trusted-edge' 'Launcher emits only the private trusted-edge header internally.'
Assert-Text 'TRUSTED_EDGE_APP_CAPABILITY' 'The public trusted-edge capability name is explicit.'
Assert-Text 'GetExtendedTcpTable' 'Launcher binds ingress to the Windows TCP owner table.'
Assert-Text 'QueryServiceStatusEx' 'Launcher binds ingress to the running Tailscale SCM service.'
Assert-Text '_is_tailscale_service_peer' 'Launcher requires an OS-bound Tailscale transport proof.'
Assert-Text 'LIFEOS_TAILSCALE_SERVICE_NAME' 'Gateway receives the allowlisted Tailscale SCM service name.'
Assert-Text 'accept-app-caps=' 'Serve requests the trusted-edge app capability.'
Assert-Text "bundleVersion = 'v17'" 'The gateway release bundle is versioned as v17.'
Assert-Text 'bundleFiles' 'The gateway release bundle records every staged file hash.'
Assert-Text 'CLIPPER_INGEST_SECRET_FILE' 'Clipper secret is supplied by path when opted in.'
Assert-Text 'GOOGLE_AI_STUDIO_API_KEY_FILE' 'Google AI Studio key is supplied by path when opted in.'
Assert-Text 'LIFEOS_SUPPLEMENT_CATALOG_PATH' 'Supplement catalog path is supplied to the gateway.'
Assert-Text 'ENABLE_BANKING_PRIVATE_KEY_PATH' 'Enable Banking key is supplied by path when fully configured.'
Assert-Text 'Initialize-SupplementCatalog' 'Reviewed supplement seed initialization is present.'
Assert-Text 'enablebanking\.py' 'Gateway bundle stages the Enable Banking module.'
Assert-Text 'supplement_catalog\.py' 'Gateway bundle stages the supplement module.'
Assert-Text 'gatewayImportCheck' 'Gateway dependency/import closure is checked.'
Assert-Text 'LIFEOS_DEPLOY_PREFLIGHT_IMPORT_CHECK' 'Preflight import payload crosses the native boundary through a temporary environment variable.'
Assert-Text 'LIFEOS_DEPLOY_STAGED_IMPORT_CHECK' 'Install import payload crosses the native boundary through a temporary environment variable.'
Assert-Text 'gatewayImportRunner' 'Python import checks use a quote-safe native runner.'
Assert-NotText 'gatewayImportCheck, \$GatewaySource, \$PSScriptRoot' 'Preflight does not pass paths after a native Python -c payload.'
Assert-NotText 'gatewayImportCheck, \$gatewayTarget' 'Install does not pass paths after a native Python -c payload.'
Assert-Text 'integrity_check' 'Supplement database integrity is checked.'
Assert-Text 'foreign_key_check' 'Supplement database foreign keys are checked.'
Assert-Text 'Get-LifeOSServiceSnapshot' 'Pre-install SCM state is journaled.'
Assert-Text 'Restore-LifeOSServiceSnapshot' 'Failed installs restore SCM state.'
Assert-Text 'Get-Variable -Name LifeOSAclSnapshotContext -Scope Script' 'First-use ACL hardening tolerates an uninitialized snapshot context.'
Assert-Text 'DelayedAutoStart' 'Delayed-start state is journaled and restored.'
Assert-Text 'ServiceSidType' 'Service SID state is journaled and restored.'
Assert-Text 'FailureActions' 'SCM recovery actions are journaled and restored.'
Assert-Text 'FailureFlag' 'SCM failure flags are journaled and restored.'
Assert-Text 'TaskPath' 'Scheduled task paths are journaled and restored.'
Assert-Text 'Get-TailscaleServeDecision' 'Serve ownership uses an explicit collision decision.'
Assert-Text 'Get-TailscaleServeFingerprint' 'Serve rollback fingerprints unrelated configuration.'
Assert-Text 'Remove-LifeOSTailscaleServeRoute' 'Serve rollback removes only the LifeOS route.'
Assert-Text 'ExpectedAfterJson' 'Serve rollback requires an authenticated post-install snapshot.'
Assert-Text 'Deployment.Behavior.Tests.ps1' 'Behavioral deployment coverage is transferred.'
Assert-Text 'Restore-TailscaleServeSnapshot' 'Tailscale Serve state is restored on rollback.'
Assert-Text 'Set-SecretAcl \$tailscaleEdgeTokenPath' 'Gateway service can read only the token file.'
Assert-Text 'Assert-NoBroadAcl \$tailscaleEdgeTokenPath' 'Trusted edge token ACL is checked for broad grants.'
Assert-Text 'Get-LegacyGatewayListenerSnapshot' 'Legacy 8421 ownership is snapshotted before cutover.'
Assert-Text 'Get-LoopbackPortOwner' 'Legacy listener inspection is limited to the loopback port.'
Assert-Text 'Get-LegacyGatewayApproval' 'Legacy listener attribution is tied to the scheduled-task definition.'
Assert-Text 'Assert-LegacyTaskUnchanged' 'Cutover and rollback revalidate the saved legacy task action.'
Assert-Text 'Get-LegacyLauncherRuntimeCandidates' 'Legacy launcher attribution uses a dedicated fail-closed parser.'
Assert-Text 'Get-LegacyLauncherApprovalShape' 'Legacy launcher approval validates the complete fixed-root uvicorn shape.'
Assert-Text 'function Normalize-WindowsAbsolutePath' 'Windows runtime paths are normalized before exact comparison.'
Assert-Text 'rootAssignmentLines.Count -ne 1' 'Dynamic or multiply-assigned launcher roots are rejected.'
Assert-Text 'rootAssignments.Count -ne 1' 'Only one fixed absolute launcher root assignment is accepted.'
Assert-Text 'locationInvocations.Count -ne 1' 'The launcher must change to its fixed root exactly once.'
Assert-Text 'runtimeInvocations.Count -ne 1' 'Zero or multiple Python invocations are rejected.'
Assert-Text 'literalPaths.Count -ne 0' 'Literal absolute Python paths cannot bypass the approved launcher shape.'
Assert-Text 'root\\\\venv\\\\Scripts\\\\python\\.exe' 'The exact static venv launcher expression is required.'
Assert-Text 'rootInvocation.Count -ne 1' 'Relative, dynamic, or alternate launcher expressions are rejected.'
Assert-Text ([regex]::Escape('-m\s+uvicorn\s+main:app')) 'The approved launcher must invoke uvicorn with main:app.'
Assert-Text ([regex]::Escape('--host\s+127\.0\.0\.1\s+--port\s+8421')) 'The approved launcher binds the reviewed loopback gateway endpoint.'
Assert-Text '\$resolved\s+-ine\s+\$expected' 'Launcher runtime must match the exact approved resolved path.'
Assert-Text 'Test-Path -LiteralPath \$resolved -PathType Leaf' 'The resolved launcher runtime must exist as a file.'
Assert-Text 'resolvedMain = Normalize-WindowsAbsolutePath' 'The fixed-root main.py path is resolved without evaluating launcher code.'
Assert-Text 'Test-Path -LiteralPath \$resolvedMain -PathType Leaf' 'The fixed-root main.py must exist as a file.'
Assert-Text 'must identify exactly one run_server.ps1 launcher' 'Missing or ambiguous legacy launchers are rejected.'
Assert-Text 'taskLiteralMainPaths' 'Task actions containing a literal alternate main.py are rejected.'
Assert-Text 'literal main\.py' 'Literal main.py paths are rejected in task and process command lines.'
Assert-Text 'moduleInvocations.Count -ne 1' 'Zero or multiple uvicorn module invocations are rejected.'
Assert-Text 'moduleInvocation.Groups.*server.*uvicorn' 'Only the approved uvicorn server token is accepted.'
Assert-Text 'moduleInvocation.Groups.*module.*main:app' 'Only the approved main:app module token is accepted.'
Assert-Text 'app-dir\|reload-dir' 'Uvicorn module-root overrides are rejected.'
Assert-Text 'fixed uvicorn loopback 8421 shape' 'Observed listener processes must use the exact reviewed endpoint shape.'
Assert-Text 'ExpectedExecutablePath' 'Listener command lines are bound to their observed executable paths.'
Assert-Text 'Get-PythonVenvBaseRelationship' 'Python redirector attribution proves the venv/base relationship from pyvenv.cfg.'
Assert-Text 'pyvenv\.cfg' 'Redirector attribution reads the venv metadata file.'
Assert-Text 'BaseExecutable' 'Redirector attribution binds the child to the pyvenv base interpreter.'
Assert-Text 'ParentProcessId' 'Listener parent process identity is captured.'
Assert-Text 'ParentExecutablePath' 'Listener parent executable identity is captured.'
Assert-Text 'ParentCreationTimeUtc' 'Listener parent creation time is captured for PID-reuse protection.'
Assert-Text 'ParentExecutableSha256' 'Listener parent executable is hash-verified.'
Assert-Text 'ParentMainPath' 'Listener parent main.py identity is captured.'
Assert-Text 'ParentMainSha256' 'Listener parent main.py is hash-verified.'
Assert-Text 'RuntimeRelationship' 'Listener runtime relationship is journaled.'
Assert-Text 'ChainDepth' 'Listener chain depth is journaled.'
Assert-Text 'parentProcesses.Count -ne 1' 'Ambiguous immediate parents are rejected.'
Assert-Text 'grandparentProcesses.Count -gt 1' 'Multiple listener grandparents remain rejected.'
Assert-Text 'grandparentProcesses.Count -eq 0' 'An exited task-shell grandparent has an explicit orphaned-chain path.'
Assert-Text 'unexpected deeper Python or uvicorn parent' 'Deeper Python or uvicorn chains are rejected.'
Assert-Text 'pyvenv-base-redirector' 'The approved child/parent relationship is explicit.'
Assert-Text 'launcher directory does not match its fixed root' 'Launcher paths outside their declared root are rejected.'
Assert-Text 'working directory does not match the fixed launcher root' 'Task working directories outside the fixed root are rejected.'
Assert-Text 'SelectSingleNode\(''task:WorkingDirectory'', \$namespace\)' 'Optional scheduled-task working directory is read from XML without strict-mode property access.'
Assert-NotText '\$action\.WorkingDirectory' 'Legacy task parsing does not require the optional WorkingDirectory XML child.'
Assert-Text 'Stop-AttributedLegacyGatewayListener' 'Only a revalidated legacy PID can be stopped.'
Assert-Text 'currentListener' 'Cutover rejects a listener that appears after the preflight snapshot.'
Assert-Text 'CreationTimeUtc' 'Legacy process creation time is journaled for PID-reuse protection.'
Assert-Text 'ExecutableSha256' 'Legacy runtime identity is hash-verified.'
Assert-Text 'MainSha256' 'Legacy main.py identity is hash-verified.'
Assert-Text 'Restore-LegacyGatewayListener' 'Rollback restores a detached legacy listener.'
Assert-Text 'LegacyGatewaySource' 'Legacy data source is separate from the staged gateway source.'
Assert-Text 'enablebanking-connections\.json' 'Enable Banking connection state is migrated.'
Assert-Text 'finance-summary\.json' 'Finance summary state is migrated.'
Assert-Text 'Assert-BoundedFile' 'Legacy Finance migrations enforce a size bound.'
Assert-Text '256 \* 1024' 'Enable Banking migration bound is 256 KiB.'
Assert-Text '1 \* 1024 \* 1024' 'Finance summary migration bound is 1 MiB.'
Assert-Text 'Migrate-LegacyDataFile' 'Legacy Finance migrations use the journaled migration helper.'
Assert-Text "@\('-I', '-c'" 'Staged Python imports run in isolated mode.'
Assert-Text 'function Resolve-PythonRuntimeSource' 'Python runtime resolution is centralized.'
Assert-Text 'rootInterpreter = Join-Path \$sourceRoot ''python\.exe''' 'Root-layout Python is resolved explicitly.'
Assert-Text 'scriptsInterpreter = Join-Path \$sourceRoot ''Scripts\\python\.exe''' 'Windows venv Python is resolved from Scripts.'
Assert-Text 'Assert-NoReparsePath \$rootInterpreter -AllowMissingLeaf' 'Root-layout interpreter path rejects reparses.'
Assert-Text 'Assert-NoReparsePath \$scriptsInterpreter -AllowMissingLeaf' 'Scripts-layout interpreter path rejects reparses.'
Assert-Text 'hasRootInterpreter' 'Root-layout presence is checked.'
Assert-Text 'hasScriptsInterpreter' 'Scripts-layout presence is checked.'
Assert-Text 'both python\.exe and Scripts\\python\.exe exist' 'Ambiguous Python layouts fail closed.'
Assert-Text 'sys\.version_info\[:2\].*\(3,12\)' 'The reviewed Python 3.12 requirement remains enforced.'
Assert-Text 'PythonPath = \$stagedVenvRuntime\.Executable' 'Staged venv returns its resolved interpreter.'
Assert-Text 'PythonPath = \$stagedBaseRuntime\.Executable' 'Staged base runtime returns its resolved interpreter.'
Assert-Text 'pythonRoot = if \(\[IO\.Path\]::GetFileName\(\$pythonDirectory\) -ieq .Scripts.' 'Gateway PATH derives the venv root from Scripts.'
Assert-Text 'PATH = \$pythonRoot.*Join-Path \$pythonRoot .Scripts.' 'Gateway PATH includes the resolved runtime root and Scripts directory.'
Assert-NotText 'Join-Path \$pythonSource ''python\.exe''' 'Preflight does not assume a root-level interpreter.'
Assert-NotText 'Join-Path \$venvTarget ''python\.exe''' 'Staged venv does not assume a root-level interpreter.'
Assert-NotText 'Join-Path \$pythonDirectory ''Scripts''' 'Gateway PATH does not append Scripts below an already-selected Scripts directory.'
Assert-Text 'tailscaleExecutable' 'Rollback has the Tailscale executable path.'
Assert-Text 'optionalExpected' 'Rollback accepts the optional v17 token path without rejecting old manifests.'
Assert-Text 'canonicalAclDestinations' 'Rollback ACL destinations remain canonical, including v17 token path.'
Assert-Text "New-ManifestIntent.*-Kind 'config'" 'New config paths use the canonical manifest intent journal.'
Assert-InstallOrder "-Kind 'config'" 'Write-JsonAtomic $gatewayConfig' 'New config paths are journaled before creation.'
Assert-Text 'Unregister-ScheduledTask' 'A newly-created Codex task can be removed on rollback.'
Assert-InstallOrder 'Copy-TreeVerifiedAtomic $nodeSource $nodeTarget' 'Register-CodexCollectorTask' 'Node is staged before Codex task registration.'
Assert-InstallOrder 'Set-RestrictedAcl $directory $operatorSid @() @($gatewaySid)' '$catalogInitialized = Initialize-SupplementCatalog' 'Supplement database is initialized after gateway data ACL setup.'
Assert-InstallOrder 'Start-CodexCollectorAndVerify' 'Stop-LegacyGatewayForCutover' 'Legacy cutover occurs only after the new API/usage gate.'
Assert-InstallOrder 'Assert-TailscaleEdgeTokenSource' 'New-BackupDirectory' 'Token source validation occurs before backup/mutation.'

# A raw token value must never cross a PowerShell argument, manifest, or JSON
# assignment. The launcher may assign the already-read value only to the
# required in-process environment contract.
Assert-NotText '(?i)LIFEOS_TAILSCALE_EDGE_TOKEN\s*[:=]\s*["''][^"'']+["'']' 'No raw edge token literal is embedded in deployment source.'
Assert-NotText '(?i)(?:TailscaleEdgeToken|tailscaleEdgeToken)\s*[:=]\s*["''][^"'']+["'']' 'No raw edge token is persisted in a path/config assignment.'
Assert-NotText '(?i)tailscale\s+funnel' 'Deployment never invokes Tailscale Funnel.'

$listenerCommandShape = '(?i)^(?:"[^"\r\n]+"|[^\s]+)\s+-m\s+uvicorn\s+main:app\s+--host\s+127\.0\.0\.1\s+--port\s+8421\s*$'
$approvedParentExecutable = 'D:\Hermes\lifeos-server\venv\Scripts\python.exe'
$approvedBaseExecutableFromPyvenv = 'C:\Python312\python.exe'
$listenerFixtures = @(
    [pscustomobject]@{
        Name = 'observed-child-redirector'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        GrandparentCommand = 'powershell -File D:\Hermes\lifeos-server\run_server.ps1'
        GrandparentCount = 1
        Expected = $true
    }
    [pscustomobject]@{
        Name = 'orphaned-grandparent'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = ''
        GrandparentCommand = ''
        GrandparentCount = 0
        Expected = $true
    }
    [pscustomobject]@{
        Name = 'orphaned-unrelated-parent'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = 'D:\Other\python.exe'
        ParentCommand = '"D:\Other\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = ''
        GrandparentCommand = ''
        GrandparentCount = 0
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'unrelated-parent'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = 'D:\Other\python.exe'
        ParentCommand = '"D:\Other\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = 'C:\Windows\System32\cmd.exe'
        GrandparentCommand = 'cmd.exe /c launcher.cmd'
        GrandparentCount = 1
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'alternate-child-runtime'
        ChildExecutable = 'C:\Python311\python.exe'
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python311\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = 'C:\Windows\System32\cmd.exe'
        GrandparentCommand = 'cmd.exe /c launcher.cmd'
        GrandparentCount = 1
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'missing-parent'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = ''
        ParentCommand = ''
        ParentCount = 0
        GrandparentExecutable = ''
        GrandparentCommand = ''
        GrandparentCount = 0
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'wrong-port'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 9999'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = 'C:\Windows\System32\cmd.exe'
        GrandparentCommand = 'cmd.exe /c launcher.cmd'
        GrandparentCount = 1
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'wrong-module'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn other:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = 'C:\Windows\System32\cmd.exe'
        GrandparentCommand = 'cmd.exe /c launcher.cmd'
        GrandparentCount = 1
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'ambiguous-parent'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 2
        GrandparentExecutable = 'C:\Windows\System32\cmd.exe'
        GrandparentCommand = 'cmd.exe /c launcher.cmd'
        GrandparentCount = 1
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'ambiguous-grandparent'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = 'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe'
        GrandparentCommand = 'powershell -File D:\Hermes\lifeos-server\run_server.ps1'
        GrandparentCount = 2
        Expected = $false
    }
    [pscustomobject]@{
        Name = 'deeper-python-chain'
        ChildExecutable = $approvedBaseExecutableFromPyvenv
        BaseExecutableFromPyvenv = $approvedBaseExecutableFromPyvenv
        ChildCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentExecutable = $approvedParentExecutable
        ParentCommand = '"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        ParentCount = 1
        GrandparentExecutable = $approvedBaseExecutableFromPyvenv
        GrandparentCommand = '"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421'
        GrandparentCount = 1
        Expected = $false
    }
)
foreach ($fixture in $listenerFixtures) {
    $childShape = [regex]::IsMatch([string]$fixture.ChildCommand, $listenerCommandShape)
    $parentShape = $fixture.ParentCount -eq 1 -and [regex]::IsMatch([string]$fixture.ParentCommand, $listenerCommandShape)
    $baseRelationship = [string]$fixture.ChildExecutable -ieq [string]$fixture.BaseExecutableFromPyvenv
    $parentApproved = [string]$fixture.ParentExecutable -ieq $approvedParentExecutable
    $grandparentLeaf = [IO.Path]::GetFileName([string]$fixture.GrandparentExecutable)
    $grandparentMissing = $fixture.GrandparentCount -eq 0
    $grandparentSafe = $grandparentMissing -or ($fixture.GrandparentCount -eq 1 -and
        $grandparentLeaf -notmatch '(?i)^(?:python(?:w)?|py(?:w)?)(?:3(?:\.\d+)?)?\.exe$' -and
        [string]$fixture.GrandparentCommand -notmatch '(?i)(?:^|\s)-m\s+uvicorn(?:\s|$)|\bmain:app\b')
    $accepted = $childShape -and $parentShape -and $baseRelationship -and $parentApproved -and $grandparentSafe
    if ([bool]$fixture.Expected -ne [bool]$accepted) {
        throw "FAIL: listener chain fixture classification mismatch: $($fixture.Name)"
    }
}

$registrationCount = [regex]::Matches($installText, '(?m)^\s*Register-CodexCollectorTask\b').Count
if ($registrationCount -ne 1) { throw "FAIL: expected exactly one Codex collector registration, found $registrationCount" }
Assert-NotText '(?i)\b(LocalSystem|LocalService|NetworkService)\b' 'Broad built-in service accounts are not used.'
Assert-NotText '(?i)\bdomke\\|C:\\Users\\|/Users/' 'Usernames and user-profile paths are not embedded.'
Assert-NotText '(?i)tailscale\s+funnel' 'The toolkit never invokes Funnel.'
Assert-NotText '(?i)Unregister-ScheduledTask[^\r\n]*LegacyTaskName' 'The legacy task is never deleted.'
Assert-NotText '(?i)Remove-ScheduledTask[^\r\n]*LegacyTaskName' 'The legacy task is never deleted.'
Assert-NotText '(?i)restart\s*/\s*\d+\s*/\s*reboot' 'SCM recovery never reboots.'
Assert-NotText '(?i)shell\s*=\s*True' 'The Python launcher never uses a shell.'

Write-Host 'PASS: deployment static assertions'
