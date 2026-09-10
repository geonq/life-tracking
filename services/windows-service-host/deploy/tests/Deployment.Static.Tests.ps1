[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -File -Include '*.ps1', '*.py' -Recurse |
    Where-Object { $_.FullName -ne $PSCommandPath })
$text = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
$installText = Get-Content -LiteralPath (Join-Path $root 'install.ps1') -Raw
$verifyText = Get-Content -LiteralPath (Join-Path $root 'verify.ps1') -Raw

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
    'CandidateRoot', 'ExpectedSourceSha',
    'ServiceHostBinarySource', 'ApiSource', 'GatewaySource', 'LegacyGatewaySource',
    'NodeRuntimeSource', 'PythonRuntimeSource', 'GatewayEntryPoint',
    'TailscaleExecutable', 'TailscaleEdgeTokenSource', 'TailscaleServiceName',
    'LegacyTaskName', 'CodexTaskName'
)) {
    $boundVariable = if ($parameter -eq 'CandidateRoot') { 'candidateRootFull' } else { $parameter }
    $parameterPattern = '(?m)^\s+{0}\s*=\s+\${1}\s*$' -f [regex]::Escape($parameter), [regex]::Escape($boundVariable)
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
Assert-Text 'Enter-LifeOSDeploymentTransaction' 'Install acquires the OS deployment transaction lock.'
Assert-Text 'function Assert-LifeOSCandidateRoot' 'Install has a shared candidate-root verification gate.'
Assert-Text 'function Assert-LifeOSCandidateSourceBindings' 'Install binds runtime inputs to the verified candidate paths.'
Assert-Text '-VerifyCandidate' 'Install and preflight run the candidate verifier before deployment work.'
Assert-Text 'CandidateRoot = \$candidateRootFull' 'Install forwards the verified candidate root to preflight.'
Assert-Text 'ExpectedSourceSha = \$ExpectedSourceSha' 'Install forwards the independently supplied source SHA to preflight.'
Assert-Text 'Assert-LifeOSCandidateSourceBindings' 'Preflight verifies exact candidate source mappings.'
Assert-Text 'Exit-LifeOSDeploymentTransaction' 'Install releases the OS deployment transaction lock.'
Assert-Text 'Register-AclSnapshot \$paths\.RuntimeRoot -RootOnly' 'Legacy runtime parents use bounded root-only ACL snapshots.'
Assert-Text 'WaitOne\(0\)' 'Concurrent deployment fails fast instead of racing tree scans.'
Assert-Text 'Could not hash tree item' 'Tree hash failures expose the exact failing path.'
Assert-InstallOrder '$deploymentMutex = Enter-LifeOSDeploymentTransaction' '$apiIntent = New-ManifestIntent' 'Deployment lock is acquired before mutations are journaled.'
Assert-Text 'Disable-LegacyTaskAfterCutover' 'Legacy task is disabled only through the cutover helper.'
Assert-Text 'Restore-LegacyTask' 'Rollback restores the legacy task.'
Assert-Text 'Restore-CodexCollectorTask' 'Rollback restores the Codex collector task.'
Assert-Text 'AllowProviderUnavailable' 'Codex provider unavailability is an explicit degraded install state.'
Assert-Text '\$exitCode -eq 2' 'Only the typed provider-unavailable collector result can use degraded install state.'
Assert-Text 'codexCollectorVerification' 'Codex collector verification status is persisted in the install manifest.'
Assert-Text 'Register-TailscaleSnapshotTask' 'A SYSTEM task publishes the Tailscale state the service account cannot query.'
Assert-Text 'Start-TailscaleSnapshotTaskAndVerify' 'The snapshot is verified against an independent Tailscale query before cutover.'
Assert-Text 'Restore-TailscaleSnapshotTask' 'Rollback restores or removes the Tailscale snapshot task.'
Assert-Text '_read_tailscale_snapshot' 'The launcher reads the SYSTEM snapshot instead of Tailscale LocalAPI.'
Assert-Text 'LIFEOS_TAILSCALE_SNAPSHOT_PATH' 'The gateway receives the snapshot path by allowlisted environment name.'
Assert-Text 'tailscale_snapshot\.ps1' 'The reviewed snapshot writer is part of the deployment source.'
Assert-Text 'Set-RestrictedAcl -Path \$stateDirectory -OperatorSid \$operatorSid -ReadSids @\(\$gatewaySid\)' 'The gateway can only read the snapshot state directory.'
Assert-Text 'S-1-5-18</UserId><RunLevel>HighestAvailable' 'The snapshot task runs as the SYSTEM service account.'
Assert-NotText 'S-1-5-18</UserId><LogonType>ServiceAccount' 'The snapshot task uses the Windows-compatible SYSTEM XML shape.'
Assert-Text '<BootTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></BootTrigger>' 'The snapshot is republished after a reboot before the delayed-auto gateway starts.'
Assert-Text '<ExecutionTimeLimit>PT30S</ExecutionTimeLimit>' 'One slow snapshot run cannot skip the next under IgnoreNew.'
Assert-Text 'Assert-TailscaleSnapshotTaskAction' 'Verification binds the exact command the snapshot task runs.'
Assert-Text '@\(''LifeOSAPI'', \$TailscaleServiceName, ''Schedule''\)' 'The gateway depends on Task Scheduler so it cannot outrace the snapshot writer.'
Assert-Text 'InheritableSystemFullControl' 'SYSTEM owns an inheritable grant on the directory it is the writer of.'
Assert-Text 'Assert-SidHasNoWriteAcl' 'Verification rejects a write grant to the gateway on the state it may only read.'
Assert-Text '(?s)function Assert-ServiceSidNotAllowed.*IdentityReference\.Translate' 'Cross-service ACL checks compare canonical service SIDs.'
Assert-NotText 'IdentityReference\.Value.*DeniedSid' 'Cross-service ACL checks do not compare rendered account names with SIDs.'
Assert-NotText '\$login -notmatch ''\^\[A-Za-z0-9' 'Identity validation is anchored so a trailing newline cannot pass.'
Assert-NotText 'subprocess\.run\(\[str\(executable\)' 'The gateway launcher never shells out to Tailscale.'
Assert-Text 'Get-NetTCPConnection -LocalPort \$Port -State Listen -ErrorAction SilentlyContinue' 'A free-port probe treats no matching connection as the expected result.'
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
Assert-Text "bundleVersion = 'v18'" 'The gateway release bundle is versioned as v18.'
Assert-Text 'bundleFiles' 'The gateway release bundle records every staged file hash.'
Assert-Text 'function Read-GatewayDependencyLock' 'The installer parses a bounded canonical gateway dependency lock.'
Assert-Text 'function Normalize-GatewayDependencyName' 'Dependency names use normalized comparison semantics.'
Assert-Text 'function Assert-PythonRuntimeDependencyInventory' 'The installer verifies the exact final Python inventory.'
Assert-Text 'function Assert-GatewayWheelhouse' 'The installer authenticates the staged wheelhouse.'
Assert-Text 'function Assert-PythonWheelInstallReport' 'The installer binds pip output to the reviewed wheels.'
Assert-Text 'function Assert-PythonPackagingToolsAbsent' 'The final runtime removes packaging tools.'
Assert-Text 'function New-PythonVirtualEnvironmentAtomic' 'The installer creates a fresh isolated venv.'
Assert-Text 'metadata.distributions\(\)' 'Runtime verification enumerates every installed Python distribution.'
Assert-Text 'distribution_count > 1027' 'Runtime verification caps installed distribution enumeration.'
Assert-Text 'if actual != expected:' 'Runtime verification rejects missing, mismatched, and extra distributions.'
Assert-Text 'if sys\.version_info\[:2\] != \(3, 12\)' 'Runtime verification requires the reviewed Python 3.12 interpreter.'
Assert-Text "ArgumentList \(\[string\[\]\]@\('-B', '-I', '-c', \`$pythonRunner\)\)" 'Runtime verification uses isolated Python execution.'
Assert-Text '-m.*venv.*--clear' 'The fresh venv is created by the staged base interpreter.'
Assert-Text '--no-index' 'Dependency installation cannot reach an index.'
Assert-Text '--find-links' 'Dependency installation is bound to the staged wheelhouse.'
Assert-Text '--require-hashes' 'Dependency installation requires reviewed hashes.'
Assert-Text '--only-binary=:all:' 'Dependency installation rejects source distributions.'
Assert-Text '--report' 'Pip installation emits a bounded provenance report.'
Assert-Text 'Assert-TrustedSourcePath \$baseRuntime.Root \$OperatorSid' 'Only the trusted base runtime source can be staged.'
Assert-Text 'Assert-TrustedSourcePath \$baseRuntime.Executable \$OperatorSid' 'The trusted base interpreter itself is ACL-checked.'
Assert-Text 'never crosses this boundary' 'A supplied legacy venv is never copied into the service runtime.'
Assert-Text '-m.*venv.*--clear.*--copies' 'Fresh venv creation copies from the base runtime instead of linking to it.'
Assert-Text '\$preflightArgs\.PythonRuntimeSource = \$preflightVenvRuntime\.Root' 'Preflight uses a freshly-built venv.'
Assert-Text 'Gateway dependency lock changed during preflight' 'The dependency lock is reauthenticated after preflight.'
Assert-Text 'Re-run the candidate verifier after the temporary preflight environment is' 'The candidate is reverified after preflight.'
Assert-Text 'PackagingToolsRemoved = \$true' 'The install manifest records removal of packaging tools.'
Assert-Text 'Get-LifeOSBoundedTreeItem -Root \$venvRoot' 'The final venv is checked against bounded tree limits.'
Assert-Text 'venvTreeBytes' 'The install manifest records bounded venv evidence.'
Assert-InstallOrder '$gatewayDependencyContract = Read-GatewayDependencyLock' '$deploymentMutex = Enter-LifeOSDeploymentTransaction' 'The authenticated dependency contract is established before the deployment transaction opens.'
Assert-Text 'RequireDependencyContract' 'Production gateway staging requires the dependency contract.'
Assert-Text 'dependencyLockSha256' 'The authenticated lock digest is retained in install manifest evidence.'
Assert-Text 'dependencyInventoryContract' 'The install manifest identifies the exact inventory contract.'
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
Assert-Text "'-B', '-I'" 'Deployment Python probes cannot mutate reviewed trees with bytecode.'
Assert-NotText 'gatewayImportCheck, \$GatewaySource, \$PSScriptRoot' 'Preflight does not pass paths after a native Python -c payload.'
Assert-NotText 'gatewayImportCheck, \$gatewayTarget' 'Install does not pass paths after a native Python -c payload.'
Assert-Text 'integrity_check' 'Supplement database integrity is checked.'
Assert-Text 'foreign_key_check' 'Supplement database foreign keys are checked.'
Assert-Text 'Get-LifeOSServiceSnapshot' 'Pre-install SCM state is journaled.'
Assert-Text 'Restore-LifeOSServiceSnapshot' 'Failed installs restore SCM state.'
Assert-Text 'Get-Variable -Name LifeOSAclSnapshotContext -Scope Script' 'First-use ACL hardening tolerates an uninitialized snapshot context.'
Assert-Text 'Get-LifeOSTreeRelativePath -Root \$destination' 'Tree ACL rollback restores entries relative to the saved destination root.'
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
Assert-Text 'Invoke-NativeChecked -FilePath \$deploymentTest' 'Preflight runs deployment suites in isolated PowerShell processes.'
Assert-Text 'Restore-TailscaleServeSnapshot' 'Tailscale Serve state is restored on rollback.'
Assert-Text 'Set-SecretAcl \$tailscaleEdgeTokenPath' 'Gateway service can read only the token file.'
Assert-Text 'Assert-NoBroadAcl \$tailscaleEdgeTokenPath' 'Trusted edge token ACL is checked for broad grants.'
Assert-Text 'function New-LifeOSManagedAcl' 'ACL grants are built from canonical SID-qualified managed rules.'
Assert-Text 'function Set-LifeOSAclWithBoundHandle' 'ACL grants are applied through a validated object handle.'
Assert-Text 'SetDacl' 'The native ACL boundary applies DACLs through the validated handle.'
Assert-Text 'function Get-LifeOSFileDigest' 'File hashes and lengths come from one validated handle-bound stream.'
Assert-Text 'function Read-LifeOSPrefixBytes' 'Bounded prefix reads use the validated file handle.'
Assert-Text 'function Get-LifeOSPathIdentityChain' 'Reads bind every existing path ancestor.'
Assert-Text 'return \$chain\.ToArray\(\)' 'Path identity chains emit individual records for PowerShell collection capture.'
Assert-NotText 'return ,\$chain\.ToArray\(\)' 'Path identity chains do not return a nested array under PowerShell 5.1.'
Assert-NotText 'return ,\$actual' 'Path identity validation does not return a nested revalidation array.'
Assert-Text 'Assert-LifeOSPathIdentityChain -Expected \$beforeChain -Description \$Description \| Out-Null' 'Capped readers suppress validator output so only the requested bytes escape.'
Assert-Text '\[IO\.Directory\]::EnumerateFileSystemEntries' 'Tree enumeration uses an unsorted .NET enumerator.'
Assert-Text '\$enumerator\.MoveNext\(\)' 'Tree enumeration advances one child at a time before retaining it.'
Assert-Text '\$enumerator\.Dispose\(\)' 'Tree enumeration disposes its incremental enumerator.'
Assert-NotText 'Get-ChildItem -LiteralPath \$directory' 'Tree enumeration does not use the materializing filesystem-provider pipeline.'
Assert-Text '\$seenPaths\.Add\(\$fullName\)' 'Tree enumeration rejects duplicate child paths before retaining them.'
Assert-Text 'Bounded tree contains a duplicate path' 'Tree enumeration has an explicit duplicate failure.'
Assert-Text 'Bounded tree contains too many files' 'Tree enumeration preserves the file limit.'
Assert-Text 'Bounded tree contains too many directories' 'Tree enumeration preserves the directory limit.'
Assert-Text 'Bounded tree exceeds its byte limit' 'Tree enumeration preserves the byte limit.'
Assert-Text 'Get-LifeOSFileIntegrity' 'Candidate and installed integrity use the handle-bound digest primitive.'
Assert-Text 'Get-LegacyGatewayListenerSnapshot' 'Legacy 8421 ownership is snapshotted before cutover.'
Assert-Text 'Get-LoopbackPortOwner' 'Legacy listener inspection is limited to the loopback port.'
Assert-Text 'Get-LegacyGatewayApproval' 'Legacy listener attribution is tied to the scheduled-task definition.'
Assert-Text 'Assert-LegacyTaskUnchanged' 'Cutover and rollback revalidate the saved legacy task action.'
Assert-Text 'Get-LegacyLauncherApprovalShape' 'Legacy launcher approval validates the complete fixed-root uvicorn shape.'
Assert-Text 'function Normalize-WindowsAbsolutePath' 'Windows runtime paths are normalized before exact comparison.'
Assert-Text 'unsafeLink = \$null -ne \$linkType -and \[string\]\$linkType -ne ''HardLink''' 'Safe hardlinks are accepted while path-redirection links remain rejected.'
Assert-Text 'rootAssignmentLines.Count -ne 1' 'Dynamic or multiply-assigned launcher roots are rejected.'
Assert-Text 'rootAssignments.Count -ne 1' 'Only one fixed absolute launcher root assignment is accepted.'

$verifyText = Get-Content -LiteralPath (Join-Path $root 'verify.ps1') -Raw
if ($verifyText -match '(?m)\.TryAdd\s*\(') { throw 'FAIL: Candidate verification must support Windows PowerShell 5.1 without Dictionary.TryAdd.' }
foreach ($required in @(
    '\$hashes\.ContainsKey\(\$relative\)',
    '\[void\]\$hashes\.Add\(\$relative',
    '\$expected\.ContainsKey\(\$tail\)',
    '\[void\]\$expected\.Add\(\$tail',
    '\$candidateByInstalled\.ContainsKey\(\$installedName\)',
    '\[void\]\$candidateByInstalled\.Add\(\$installedName'
)) {
    if ($verifyText -notmatch $required) { throw "FAIL: Candidate verifier duplicate guard is missing: $required" }
}
foreach ($message in @(
    'Candidate inventory manifest contains a duplicate',
    'candidate mapping is duplicated or empty',
    'duplicate installed mapping'
)) {
    if ($verifyText -notmatch [regex]::Escape($message)) { throw "FAIL: Candidate verifier duplicate behavior is not preserved: $message" }
}

$restoreStart = $text.IndexOf('function Restore-AclSnapshots', [StringComparison]::Ordinal)
$restoreEnd = $text.IndexOf('function Assert-NoBroadAcl', [StringComparison]::Ordinal)
if ($restoreStart -lt 0 -or $restoreEnd -le $restoreStart) { throw 'FAIL: ACL restore function is missing.' }
$restoreText = $text.Substring($restoreStart, $restoreEnd - $restoreStart)
if ($restoreText -match '(?i)icacls(?:\.exe)?[^\r\n]*/restore') { throw 'FAIL: ACL rollback must not invoke pathname-based icacls /restore.' }
foreach ($required in @(
    'Read-LifeOSBoundedJsonFile -Path \$backup',
    'LifeOSAclTreeV1',
    'Get-LifeOSTreeRelativePath',
    'Set-LifeOSAclWithBoundHandle -Path \$entry\.Path',
    'ACL restore tree contents changed since the snapshot.'
)) {
    if ($restoreText -notmatch $required) { throw "FAIL: Handle-bound ACL rollback invariant is missing: $required" }
}
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
Assert-Text "'enablebanking-connections\.json' = 256 \* 1024" 'Enable Banking connection migration bound is 256 KiB.'
Assert-Text "'finance-summary\.json' = 256 \* 1024" 'Finance summary migration bound is 256 KiB.'
Assert-Text "'calendar\.json\.state\.json' = 6 \* 1024 \* 1024" 'Calendar state migration matches the gateway 6 MiB bound.'
Assert-Text "'calendar\.json\.meta\.json' = 4 \* 1024 \* 1024" 'Calendar metadata migration matches the gateway 4 MiB bound.'
Assert-Text "'finance-summary\.json\.meta\.json' = 4 \* 1024 \* 1024" 'Finance metadata migration matches the gateway 4 MiB bound.'
Assert-Text "'enablebanking-revocation\.json' = 8 \* 1024 \* 1024" 'Enable Banking revocation migration matches the gateway 8 MiB bound.'
Assert-Text "'finance-imported\.json' = 8 \* 1024 \* 1024" 'Imported finance migration matches the gateway 8 MiB bound.'
Assert-NotText 'Migrate-LegacyDataFile' 'Legacy Finance migration has no unused helper path.'
Assert-NotText 'Start-CodexCollectorAndVerify' 'Collector verification has no unused helper path.'
Assert-Text "@\('-B', '-I', '-c'" 'Staged Python imports run in isolated mode without writing bytecode.'
Assert-Text 'function Resolve-PythonRuntimeSource' 'Python runtime resolution is centralized.'
Assert-NotText '\$home\s*=' 'Deployment scripts do not assign the read-only PowerShell HOME variable.'
Assert-Text '\$script:LifeOSCandidateNodeMaxFileBytes = 256 \* 1024 \* 1024' 'The allowlisted standalone Node runtime has an explicit 256 MiB bound.'
Assert-Text '\$script:LifeOSCandidateServiceHostMaxFileBytes = 256 \* 1024 \* 1024' 'The allowlisted self-contained service host has an explicit 256 MiB bound.'
Assert-Text '\$maxCandidateNodeFileBytes = \[long\]\$script:LifeOSCandidateNodeMaxFileBytes' 'Candidate verification consumes the explicit Node runtime bound.'
Assert-Text 'node-runtime/node\.exe.*\$maxCandidateNodeFileBytes' 'Candidate verification scopes the larger bound to the standalone Node path.'
Assert-Text 'service-host/LifeOS\.ServiceHost\.exe.*\$maxCandidateServiceHostFileBytes' 'Candidate verification scopes the larger bound to the exact service-host path.'
Assert-Text 'Write-JsonAtomic -Path \$releaseManifestPath -Value \(\[ordered\]@\{' 'Gateway release manifests use the real atomic JSON writer call.'
Assert-Text 'LargeFileRelativePath \$nodeLargeFileRelativePath' 'Installation passes the explicit Node runtime file contract.'
Assert-Text 'function Get-LifeOSBoundedFileMaxBytes' 'Tree scans resolve per-file limits by relative path.'
Assert-Text 'function Get-LifeOSRecoveryFileMaxBytes' 'Recovery resolves the Node exception for exact runtime files.'
Assert-Text 'AllowServiceHostBinary' 'Recovery resolves the service-host exception only from manifest provenance.'
Assert-Text '-LargeFileContracts \$effectiveLargeFileContracts' 'Manifest hashing receives the exact candidate contract map.'
Assert-Text '-LargeFileContracts \$LargeFileContracts' 'Recovery tree indexing preserves an explicit contract map.'
Assert-Text 'Copy-TreeVerifiedAtomic' 'Tree copy remains covered by the bounded manifest path.'
Assert-Text 'Copy-FileVerifiedAtomic \$hostSource \$hostTarget \$backupDirectory -MaxBytes \$hostMaxFileBytes' 'Service-host install copy applies the finite host bound.'
Assert-Text 'same-basename service host' 'Behavioral coverage rejects misleading service-host paths.'
Assert-Text 'Get-LifeOSRecoveryFileMaxBytes -Path \$Path' 'Recovery artifact state uses the path-aware file limit.'
Assert-Text 'linkType -ne ''HardLink''' 'Runtime manifests allow safe hardlinks but reject path-redirection links.'
Assert-Text 'activationScriptNames' 'Deployed Python venvs omit profile-bound activation helpers.'
Assert-Text 'rootInterpreter = Join-Path \$sourceRoot ''python\.exe''' 'Root-layout Python is resolved explicitly.'
Assert-Text 'scriptsInterpreter = Join-Path \$sourceRoot ''Scripts\\python\.exe''' 'Windows venv Python is resolved from Scripts.'
Assert-Text 'Assert-NoReparsePath \$rootInterpreter -AllowMissingLeaf' 'Root-layout interpreter path rejects reparses.'
Assert-Text 'Assert-NoReparsePath \$scriptsInterpreter -AllowMissingLeaf' 'Scripts-layout interpreter path rejects reparses.'
Assert-Text 'hasRootInterpreter' 'Root-layout presence is checked.'
Assert-Text 'hasScriptsInterpreter' 'Scripts-layout presence is checked.'
Assert-Text 'both python\.exe and Scripts\\python\.exe exist' 'Ambiguous Python layouts fail closed.'
Assert-Text 'sys\.version_info\[:2\].*\(3,12\)' 'The reviewed Python 3.12 requirement remains enforced.'
Assert-Text 'PythonPath = \$stagedVenvRuntime\.Executable' 'Staged venv returns its resolved interpreter.'
Assert-Text 'BaseTarget = \$baseTarget' 'Fresh venv staging records its base-runtime target.'
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
Assert-InstallOrder 'Set-RestrictedAcl $directory $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -InheritableSystemFullControl' '$catalogInitialized = Initialize-SupplementCatalog' 'Supplement database is initialized after gateway data ACL setup.'
Assert-InstallOrder '$legacyCutover = Stop-LegacyGatewayForCutover' '$authorityFiles = ' 'Legacy writer is quiesced before authority inventory.'
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

# Migration is an explicit, canonical recovery unit, never a legacy directory copy.
foreach ($name in @('calendar.json', 'calendar.json.state.json', 'calendar.json.meta.json', 'calendar.json.retry.json', 'finance-summary.json', 'finance-summary.json.state.json', 'finance-summary.json.meta.json', 'enablebanking-connections.json', 'enablebanking-revocation.json', 'enablebanking-revoked.json', 'enablebanking-partial.json', 'enablebanking-runtime.json', 'finance-imported.json', 'documents.json')) {
    if (-not $installText.Contains("'" + $name + "' =")) { throw "FAIL: Missing authority allowlist entry: $name" }
}
Assert-Text "'finance-summary\.json\.state\.json' = 6 \* 1024 \* 1024" 'Finance state migration matches the gateway 6 MiB bound.'
Assert-Text "'finance-imported\.json' = 8 \* 1024 \* 1024" 'Gateway-owned imported finance state has the gateway 8 MiB bound.'

$gatewayRoot = Join-Path $root '..\..\gateway'
if (-not (Test-Path -LiteralPath $gatewayRoot -PathType Container)) {
    # Release candidates flatten deploy/ beside gateway/, while the source
    # checkout keeps gateway under services/. Keep the suite valid in both
    # reviewed layouts without reaching outside the candidate root.
    $gatewayRoot = Join-Path $root '..\gateway'
}
if (-not (Test-Path -LiteralPath $gatewayRoot -PathType Container)) { throw 'FAIL: gateway source root is missing.' }
$enableBankingText = Get-Content -LiteralPath (Join-Path $gatewayRoot 'enablebanking.py') -Raw
$enableBankingStateMatch = [regex]::Match($enableBankingText, '(?m)^\s*MAX_FINANCE_STATE_SIZE\s*=\s*(?<value>\d+)\s*\*\s*1024\s*\*\s*1024\s*$')
$installerStateMatch = [regex]::Match($installText, "(?m)^\s*'finance-summary\.json\.state\.json'\s*=\s*(?<value>\d+)\s*\*\s*1024\s*\*\s*1024\s*$")
if (-not $enableBankingStateMatch.Success -or -not $installerStateMatch.Success) {
    throw 'FAIL: canonical Enable Banking state or installer state bound is missing.'
}
$gatewayStateBytes = [long]$enableBankingStateMatch.Groups['value'].Value * 1024 * 1024
$installerStateBytes = [long]$installerStateMatch.Groups['value'].Value * 1024 * 1024
if ($gatewayStateBytes -ne $installerStateBytes) {
    throw "FAIL: installer finance state bound $installerStateBytes differs from gateway bound $gatewayStateBytes."
}

$gatewayMainText = Get-Content -LiteralPath (Join-Path $gatewayRoot 'main.py') -Raw
$gatewayImportedStateMatch = [regex]::Match($gatewayMainText, '(?m)^\s*FINANCE_IMPORTED_MAX_STATE_SIZE\s*=\s*(?<value>\d+)\s*\*\s*1024\s*\*\s*1024\s*$')
$installerImportedStateMatch = [regex]::Match($installText, "(?m)^\s*'finance-imported\.json'\s*=\s*(?<value>\d+)\s*\*\s*1024\s*\*\s*1024\s*$")
if (-not $gatewayImportedStateMatch.Success -or -not $installerImportedStateMatch.Success) {
    throw 'FAIL: canonical imported-finance state or installer bound is missing.'
}
$gatewayImportedStateBytes = [long]$gatewayImportedStateMatch.Groups['value'].Value * 1024 * 1024
$installerImportedStateBytes = [long]$installerImportedStateMatch.Groups['value'].Value * 1024 * 1024
if ($gatewayImportedStateBytes -ne $installerImportedStateBytes) {
    throw "FAIL: installer imported-finance bound $installerImportedStateBytes differs from gateway bound $gatewayImportedStateBytes."
}
Assert-Text 'Assert-AuthorityJsonBounds' 'Authority JSON has structural bounds.'
Assert-Text 'preserve-installed' 'Reinstall preserves the installed authority set.'
Assert-Text 'Authority backup provenance invalid' 'Missing or altered authority backup blocks rollback.'
Assert-Text 'Authority provenance changed or incomplete' 'Post-migration writes block unsafe rollback.'
Assert-Text 'terminalCompleted' 'Collector journals terminal completion evidence.'
Assert-Text '\$sawRunning -and' 'Collector requires observed running-to-ready completion.'
Assert-Text '\$exitCode -eq 2' 'Only provider unavailable is explicitly degraded.'

Assert-Text 'Usage authority changed or has no provenance' 'Usage writes also block stale authority rollback.'
Assert-Text 'function Test-AuthorityRecoveryBaseline' 'Recovered early transactions require a complete authority baseline.'
Assert-Text 'function Get-LifeOSServiceConfigArguments' 'Install and rollback share service-manager argument encoding.'
Assert-Text 'function Assert-CompleteLifeOSServiceSnapshot' 'Service rollback requires a complete snapshot.'
Assert-Text "(?s)stageState -eq 'complete'.*?return" 'Completed recovery stages are idempotent.'

# Inspect the verifier array itself, so matching strings elsewhere cannot mask
# an obsolete allowlist. The Python source suite checks the compiler-derived
# transitive import/export closure and imports/starts an isolated Node package.
$candidateVerifierText = Get-Content -LiteralPath (Join-Path $root 'verify-candidate.ps1') -Raw
Assert-Text 'function Read-CandidateGatewayDependencyLock' 'Candidate verification parses the gateway dependency lock.'
Assert-Text 'Normalize-CandidateDependencyName' 'Candidate verification normalizes dependency names.'
Assert-Text "manifestHashes\['gateway/requirements.lock'\]" 'Candidate manifest hashing is explicitly bound to the dependency lock.'
Assert-Text 'Candidate manifest does not bind the gateway dependency lock digest' 'Candidate verification refuses an unbound lock digest.'
Assert-Text 'gateway/wheelhouse/ALLOWLIST\.sha256' 'Candidate verification requires the deterministic wheelhouse allowlist.'
Assert-Text 'Candidate wheel provenance does not match the dependency lock' 'Candidate verification binds each wheel to its lock hash.'
Assert-Text 'expectedAllowlistLines' 'Candidate verification derives wheelhouse names from the lock.'
$candidateAllowlistMatch = [regex]::Match($candidateVerifierText, '(?ms)^\$expectedFiles = @\(\r?\n(?<body>.*?)^\)')
if (-not $candidateAllowlistMatch.Success) { throw 'FAIL: Candidate verifier allowlist is missing.' }
$candidateEntries = @([regex]::Matches($candidateAllowlistMatch.Groups['body'].Value, '(?m)^\s+''([^'']+)''\s*$') |
    ForEach-Object { $_.Groups[1].Value })
if ($candidateEntries.Count -ne @($candidateEntries | Sort-Object -Unique).Count) {
    throw 'FAIL: Candidate allowlist contains duplicate paths.'
}
foreach ($entry in $candidateEntries) {
    if ($entry -cnotmatch '\A[A-Za-z0-9_@./-]+\z' -or $entry.StartsWith('/') -or
        @($entry.Split('/') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -gt 0) {
        throw "FAIL: Candidate allowlist must contain literal safe paths: $entry"
    }
}
foreach ($requiredModule in @(
    'api/dist/local-auth.js'
)) {
    if ($candidateEntries -cnotcontains $requiredModule) {
        throw "FAIL: Candidate allowlist omits runtime module: $requiredModule"
    }
}
Write-Output 'PASS: Candidate runtime module allowlist regression checks.'

Assert-Text 'LIFEOS_LOCAL_API_ENABLED = ''true''' 'Local API bearer contract is explicitly enabled.'
Assert-Text 'LIFEOS_LOCAL_API_SECRET_FILE' 'Local API callers use the separate file contract.'
Assert-Text 'Invoke-WebRequest -Uri \$Uri -Headers \$headers' 'Protected verification transmits authentication.'
Assert-Text 'Assert-RecoveryIdentity' 'Recovery binds generation, manifest, and operator.'
Assert-Text 'Read-RecoveryJournal' 'Rollback resumes durable artifact progress.'
Assert-Text 'Assert-RecoveryUnitState' 'Recovery accepts only permitted pre/post states.'
Assert-Text '\$script:LifeOSRecoveryMaxTreeRoots = 256' 'Recovery bounds the number of artifact roots.'
Assert-Text '\$script:LifeOSRecoveryMaxFileUnits = 65536' 'Recovery allows expanded trees within a finite file-unit bound.'
Assert-Text '\$script:LifeOSRecoveryMaxTreeBytes = 1024 \* 1024 \* 1024' 'Recovery bounds each indexed tree by bytes.'
Assert-Text '\$script:LifeOSRecoveryMaxFileBytes = 64 \* 1024 \* 1024' 'Recovery bounds each indexed file by bytes.'
Assert-Text '\$script:LifeOSRecoveryMaxInventoryBytes = 1024 \* 1024 \* 1024' 'Recovery bounds the aggregate indexed inventory by bytes.'
Assert-Text 'function Assert-RecoveryInventoryBounds' 'Recovery validates inventory bounds before restoration.'
Assert-Text 'function Get-TreeManifestIndex' 'Tree validation hashes each bounded tree in one indexed pass.'
Assert-Text 'function Get-RecoveryTreeManifestIndex' 'Recovery reuses indexed parent trees instead of rescanning descendants.'
Assert-Text 'function Get-RecoveryCanonicalTreeRoots' 'Overlapping recovery roots are canonicalized before scanning.'
Assert-Text 'Read-LifeOSBoundedJsonFile' 'Deployment JSON readers enforce a byte bound before parsing.'
Assert-Text '\$script:LifeOSRecoveryProgressMaxBytes = 64 \* 1024 \* 1024' 'Recovery progress has a finite serialized-size bound.'
Assert-Text 'function Append-RecoveryProgress' 'Recovery records per-unit progress without rewriting the full journal.'
Assert-Text 'function Write-RecoveryProgressFramePart' 'Recovery progress records have explicit framed write boundaries.'
Assert-Text 'SetLength\(\$committedOffset\)' 'Recovery truncates only an uncommitted progress tail.'
Assert-Text 'Recovery progress committed record digest is invalid' 'Committed progress-record corruption is rejected.'
Assert-Text 'function Get-LifeOSScheduledTaskExact' 'Scheduled-task absence is distinguished from provider failure.'
Assert-Text 'FullyQualifiedErrorId' 'Scheduled-task absence classification authenticates the provider error.'
Assert-Text '\[switch\]\$DeferStart' 'Service configuration restoration can defer starting services.'
Assert-Text 'function Restore-LifeOSServiceSnapshots' 'Service recovery restores all configuration before dependency reconciliation.'
Assert-Text "service-state-reconcile" 'Service state reconciliation has its own durable recovery stage.'
Assert-Text '\[switch\]\$VerifyHealth' 'Service recovery verifies loopback health before terminal success.'
Assert-Text 'function Assert-LifeOSServiceSnapshotState' 'Service recovery verifies the complete typed snapshot state.'
Assert-Text 'function Complete-LifeOSRecoveryState' 'Recovery state is archived only after verified terminal stages.'
Assert-Text 'recoveryArchivePath' 'Recovered markers bind the durable recovery archive.'
Assert-Text 'Stop-DeploymentTaskBarrier' 'Scheduled writers join the recovery barrier.'
Assert-Text 'Get-TaskRecoveryIdentity' 'Task action/principal/path are verified before mutation.'
Assert-Text 'function Reconcile-LifeOSScheduledTaskSnapshotState' 'Scheduled task state is reconciled after recovery retries.'
Assert-Text '(?s)\[AllowEmptyString\(\)\].*?\$MarkerState' 'Fresh installs explicitly allow an empty marker state.'
Assert-Text 'foreach \(\$key in \$Reference.Keys\)' 'Generation references validate dictionary keys.'
Assert-Text 'Get-AuthorityInstallMode' 'Authority completeness is classified explicitly.'
Assert-Text 'Test-CollectorUsagePreserved' 'Installer observations are preserved and attributed.'
Assert-Text 'Assert-AclRoleRights' 'ACL checks required and forbidden role rights.'
Assert-InstallOrder 'Save-InstallManifest $manifest $manifestPath' 'Bind-LifeOSDeploymentManifest $deploymentMutex' 'No marker without a manifest.'
Assert-InstallOrder 'Stop-DeploymentTaskBarrier $manifest $manifestPath' '$apiIntent = New-ManifestIntent' 'Scheduled writers stop before code changes.'
Write-Host 'PASS: transaction-owned recovery static assertions'


# Scope these assertions to production bodies; test fixtures must not satisfy them.
$commonText = Get-Content -LiteralPath (Join-Path $root 'Deployment.Common.ps1') -Raw
$gatewayBundleBody = ($installText -split 'function Copy-GatewayCodeBundle', 2)[1] -split 'function Initialize-SupplementCatalog', 2
$bundleFilesAssignment = [regex]::Match($gatewayBundleBody[0], '(?ms)\$bundleFiles\s*=\s*@\(.*?\}\)(?<tail>[^\r\n]*)')
if (-not $bundleFilesAssignment.Success -or $bundleFilesAssignment.Groups['tail'].Value -match '-MaxBytes') {
    throw 'FAIL: Gateway bundle byte bounds must not be attached to the bundleFiles array expression.'
}
if ($gatewayBundleBody[0] -notmatch '(?ms)Write-JsonAtomic\s+-Path\s+\$releaseManifestPath\s+-Value\s+\(\[ordered\]@\{.*?bundleFiles\s*=\s*\$bundleFiles.*?\}\)\s+-MaxBytes\s+\$script:LifeOSGenerationManifestMaxBytes') {
    throw 'FAIL: Gateway release manifest must pass its byte bound to Write-JsonAtomic.'
}
$chainCallLines = @($commonText -split "`r?`n" | Where-Object { $_ -match 'Get-LifeOSPathIdentityChain -Path' })
if ($chainCallLines.Count -lt 10 -or @($chainCallLines | Where-Object { $_ -notmatch '@\(.*Get-LifeOSPathIdentityChain -Path' }).Count -gt 0) {
    throw 'FAIL: Every path identity chain caller must capture the flat pipeline contract with @(...).'
}

$durableBody = ($commonText -split 'function Write-LifeOSDurableBytes', 2)[1] -split 'function Write-JsonAtomic', 2
if ($durableBody[0].IndexOf('$stream.Flush($true)', [StringComparison]::Ordinal) -lt 0 -or
    $durableBody[0].IndexOf('$stream.Dispose()', [StringComparison]::Ordinal) -lt 0) {
    throw 'FAIL: durable checkpoint writer must flush contents and close its handle.'
}
$jsonAtomicBody = ($commonText -split 'function Write-JsonAtomic', 2)[1] -split 'function Assert-PathOnlyJson', 2
if ($jsonAtomicBody[0].IndexOf('Write-LifeOSDurableBytes', [StringComparison]::Ordinal) -lt 0 -or
    $jsonAtomicBody[0].IndexOf('Move-Item -LiteralPath $temp', [StringComparison]::Ordinal) -lt 0 -or
    $jsonAtomicBody[0].IndexOf('Write-LifeOSDurableBytes', [StringComparison]::Ordinal) -gt
    $jsonAtomicBody[0].IndexOf('Move-Item -LiteralPath $temp', [StringComparison]::Ordinal) -or
    $jsonAtomicBody[0].Contains('[IO.File]::WriteAllBytes($temp, $bytes)')) {
    throw 'FAIL: JSON checkpoint bytes must be durably flushed before atomic replacement.'
}
Assert-Text 'Write-JsonAtomic \$Path \$Manifest -OperatorSid \$Manifest\.operatorSid' 'Install manifests retain the operator-bound ACL on every checkpoint.'
Assert-Text 'Write-JsonAtomic \$path \$journal -OperatorSid \$Manifest\.operatorSid' 'Recovery journals retain the operator-bound ACL on every checkpoint.'
Assert-Text 'Write-LifeOSDurableBytes \$snapshotPath' 'Leaf ACL snapshots are durably written after their restricted ACL is applied.'
$boundedTreeBody = ($commonText -split 'function Get-LifeOSBoundedTreeItem', 2)[1] -split 'function Get-TreeManifestIndex', 2
if ($boundedTreeBody[0] -match '\$unsafeTarget|\$target\s*=') {
    throw 'FAIL: bounded tree reparse checks must use LinkType and never compare Target as a link type.'
}
$stageBody = ($commonText -split 'function Invoke-RecoveryStage', 2)[1] -split 'function Get-RecoveryJournalPath', 2
if (-not $stageBody[0].Contains('Read-RecoveryJournal $Manifest') -or
    $stageBody[0].IndexOf('Read-RecoveryJournal') -gt $stageBody[0].IndexOf('& $Action')) { throw 'FAIL: Recovery stages must authenticate the journal before acting.' }
Assert-InstallOrder 'Save-CollectorReceipt $manifest' '$manifest.codexCollectorVerification = ' 'Collector receipt is durable before replacing manifest observations.'
if (-not $commonText.Contains('Executable = $false') -or -not $commonText.Contains("@('.exe', '.dll')")) { throw 'FAIL: Service image ACLs require execution rights.' }
$frozenTreeBody = ($commonText -split 'function Get-LifeOSFrozenTreeInventory', 2)[1] -split 'function Add-LifeOSManagedAccessRule', 2
$managedAclBody = ($commonText -split 'function New-LifeOSManagedAcl', 2)[1] -split 'function Set-LifeOSAclWithBoundHandle', 2
$traversalAclBody = ($commonText -split 'function Set-DirectoryTraversalAcl', 2)[1] -split 'function Assert-ExplicitAclAllowSet', 2
$snapshotBody = ($commonText -split 'function Register-AclSnapshot', 2)[1] -split 'function Assert-NoBroadAcl', 2
if (-not $frozenTreeBody[0].Contains('if (-not $File -and -not $RootOnly)') -or
    $frozenTreeBody[0].IndexOf('if (-not $File -and -not $RootOnly)') -gt $frozenTreeBody[0].IndexOf('Get-LifeOSBoundedTreeItem')) {
    throw 'FAIL: RootOnly tree inventory must stop before descendant enumeration.'
}
foreach ($required in @(
    'Register-AclSnapshot $Path -RootOnly:$RootOnly',
    'Get-LifeOSFrozenTreeInventory -Path $Path -RootOnly:$RootOnly',
    'Remove-TransientLogonAclRules $Path -Recurse:(!$RootOnly)',
    'Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @() -Recurse:(!$RootOnly)',
    '[switch]$Executable',
    '$IsContainer -or $Executable',
    "[IO.Path]::GetExtension([string]`$entry.Path) -in @('.exe', '.dll')",
    '-Executable:$isExecutable',
    '-InheritableSystemFullControl:($InheritToChildren -and $RootOnly)',
    'if ($item.PSIsContainer -and -not $RootOnly)',
    'Set-LifeOSAclWithBoundHandle -Path $destination -Acl $acl -Directory ([bool]$destinationItem.PSIsContainer)'
)) {
    if (-not ($traversalAclBody[0] + $managedAclBody[0] + $snapshotBody[0]).Contains($required)) {
        throw "FAIL: Directory traversal ACL contract is missing: $required"
    }
}
if (-not $commonText.Contains('function Assert-LifeOSExpectedImmediateChildren') -or
    -not $commonText.Contains('[IO.SearchOption]::TopDirectoryOnly') -or
    -not $commonText.Contains('New-LifeOSTreeItemIdentity -Item $childItem') -or
    -not $commonText.Contains('Get-LifeOSPathIdentityChain -Path $childPath') -or
    -not $commonText.Contains('Shared-root child grants cross-service access')) {
    throw 'FAIL: Shared data/log roots must use a bounded, identity-checked immediate-child contract.'
}
$immediateChildrenBody = ($commonText -split 'function Assert-LifeOSExpectedImmediateChildren', 2)[1] -split 'function Set-AclSnapshotContext', 2
if ($immediateChildrenBody[0].Contains('$rootComparison') -or
    -not $immediateChildrenBody[0].Contains('$parentPath.TrimEnd(') -or
    -not $immediateChildrenBody[0].Contains('-ine $rootFull')) {
    throw 'FAIL: Shared-root parent comparison must use the function-local normalized root path.'
}
if ($traversalAclBody[0].Contains('Get-LifeOSFrozenTreeInventory -Path $Path)') -or
    $traversalAclBody[0].Contains('Get-LifeOSBoundedTreeItem')) {
    throw 'FAIL: RootOnly ACL setup must not directly enumerate descendants.'
}
foreach ($runtimeRoot in @(
    'Set-DirectoryTraversalAcl $apiTarget $operatorSid @($apiSid) -RootOnly -InheritToChildren',
    'Set-DirectoryTraversalAcl $gatewayTarget $operatorSid @($gatewaySid) -RootOnly -InheritToChildren',
    'Set-DirectoryTraversalAcl $nodeTarget $operatorSid @($apiSid) -RootOnly -InheritToChildren',
    "Set-DirectoryTraversalAcl (Join-Path `$paths.RuntimeRoot 'python312') `$operatorSid @(`$gatewaySid) -RootOnly -InheritToChildren"
)) {
    if (-not $installText.Contains($runtimeRoot)) { throw "FAIL: Runtime ACL boundary is not inherited by the launched tree: $runtimeRoot" }
}
foreach ($parentRoot in @(
    'Set-DirectoryTraversalAcl $paths.DataRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly',
    'Set-DirectoryTraversalAcl $paths.LogRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly'
)) {
    if (-not $installText.Contains($parentRoot)) { throw "FAIL: Shared traversal parent is not direct root-only: $parentRoot" }
}
# The native reinstall behavior suite exercises existing descendants on
# Windows; this source contract is the fallback on hosts without PowerShell.
if ($installText -match '(?m)^\s*Set-DirectoryTraversalAcl \$paths\.(DataRoot|LogRoot) \$operatorSid @\(\$apiSid, \$gatewaySid\) -RootOnly -InheritToChildren\s*$') {
    throw 'FAIL: Data/log traversal parents must not inherit service access.'
}
Assert-InstallOrder 'Set-DirectoryTraversalAcl $paths.DataRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly' 'foreach ($directory in @($apiData, $apiTemp, $apiLogs))' 'Data traversal boundary must precede API writable-tree hardening.'
Assert-InstallOrder 'Set-DirectoryTraversalAcl $paths.LogRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly' 'foreach ($directory in @($apiData, $apiTemp, $apiLogs))' 'Log traversal boundary must precede scoped writable-tree hardening.'
foreach ($expectedCall in @(
    'Assert-LifeOSExpectedImmediateChildren -Root $paths.DataRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll',
    'Assert-LifeOSExpectedImmediateChildren -Root $paths.LogRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll',
    'Assert-LifeOSExpectedImmediateChildren -Root $dataRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll',
    'Assert-LifeOSExpectedImmediateChildren -Root $logRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll'
)) {
    if (-not ($installText + $verifyText).Contains($expectedCall)) { throw "FAIL: Shared-root child validation is missing: $expectedCall" }
}
foreach ($writableTree in @(
    'Set-RestrictedAcl $directory $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -InheritableSystemFullControl',
    'Set-RestrictedAcl $directory $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -InheritableSystemFullControl',
    'Assert-RestrictedAcl $apiData $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse',
    'Assert-RestrictedAcl $gatewayData $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse',
    'Assert-RestrictedAcl $apiLogs $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse',
    'Assert-RestrictedAcl $gatewayLogs $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse'
)) {
    if (-not ($installText + $commonText + $verifyText).Contains($writableTree)) { throw "FAIL: Managed writable ACL contract is missing: $writableTree" }
}
if (-not $commonText.Contains('[string[]]$AllowedOwnerSids = @()') -or
    -not $commonText.Contains("Allowed ACL owner must be a service SID with Modify rights on this managed writable tree.")) {
    throw 'FAIL: Service-owned writable tree owner scope is not explicit and role-bound.'
}
if (-not $commonText.Contains('@($AllowedOwnerSids).Count -gt 0 -and -not $File -and -not $InheritableSystemFullControl') -or
    -not $installText.Contains('Set-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -File -AllowedOwnerSids @($gatewaySid)') -or
    -not $verifyText.Contains('Assert-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited')) {
    throw 'FAIL: Supplement catalog owner scope must remain gateway-specific and file-safe.'
}
$catalogVerifyLine = [regex]::Match($verifyText, '(?m)^\s*Assert-RestrictedAcl \$supplementCatalog \$operatorSid .* -AllowInherited\s*$').Value
if ($installText -match '(?m)^\s*Set-RestrictedAcl \$supplementCatalog \$operatorSid .* -File\s*$' -or
    ($catalogVerifyLine -and $catalogVerifyLine -notmatch '-AllowedOwnerSids')) {
    throw 'FAIL: Supplement catalog must not use an unscoped service-owner relaxation.'
}
Write-Host 'PASS: remaining Windows deployment/recovery static assertions'
