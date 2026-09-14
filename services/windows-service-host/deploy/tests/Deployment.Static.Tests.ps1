[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$staticTestPath = [IO.Path]::GetFullPath($PSCommandPath)
$files = @(Get-ChildItem -LiteralPath $root -File -Include '*.ps1', '*.py' -Recurse |
    Where-Object {
        $_.Extension -in @('.ps1', '.py') -and
        -not [String]::Equals($_.Name, 'Deployment.Static.Tests.ps1', [StringComparison]::OrdinalIgnoreCase) -and
        -not [String]::Equals([IO.Path]::GetFullPath($_.FullName), $staticTestPath, [StringComparison]::OrdinalIgnoreCase)
    })
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
    '(?ms)\$preflightArgs\s*=\s*@\{(?<body>.*?)\r?\n\}'
)
$preflightInvocation = [regex]::Match(
    $installText,
    '(?m)^[ \t]*& \(Join-Path \$PSScriptRoot ''preflight\.ps1''\) @preflightArgs(?:[ \t]*\|[ \t]*Out-Host)?[ \t]*(?=\r?\n|\z)'
)
if (-not $preflightNamedArgs.Success -or
    -not $preflightInvocation.Success -or
    $preflightInvocation.Index -lt $preflightNamedArgs.Index) {
    throw 'FAIL: Preflight must be invoked with a named hashtable splat.'
}
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
Assert-Text 'function Initialize-LifeOSRecoveryProgressNative' 'Progress I/O has a Windows native handle implementation.'
Assert-Text 'NtCreateFile' 'Progress ancestors and the leaf are opened through native relative handles.'
Assert-Text 'FileOpenReparsePoint' 'Progress opens inspect reparse points without traversing them.'
Assert-Text 'FileShareRead' 'Progress handles deny write and delete sharing.'
Assert-Text 'FileCreate' 'Fresh progress leaves use create-new semantics.'
Assert-Text 'GetSecurityInfo' 'Progress ACL validation reads security from the retained leaf handle.'
Assert-Text 'NumberOfLinks != 1' 'Progress leaves reject multiple hard links.'
Assert-Text 'Poison-RecoveryProgressLease' 'Progress mutation failures poison the retained lease.'
Assert-Text 'Close-RecoveryProgressLeaseHolder' 'Progress handles have an explicit deterministic disposal path.'
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
$nativeSource = ($commonText -split 'function Initialize-LifeOSRecoveryProgressNative', 2)[1] -split 'function New-RecoveryProgressLeaseHolder', 2
if ($nativeSource[0] -match 'FileFlagOpenReparsePoint' -or
    $nativeSource[0] -notmatch 'private const uint FileOpenReparsePoint' -or
    $nativeSource[0] -notmatch 'OpenExistingOrRetainedParent' -or
    $nativeSource[0] -notmatch 'CreateLeaf') {
    throw 'FAIL: Recovery progress native source has an inconsistent reparse constant or retained-parent create path.'
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    . (Join-Path $root 'Deployment.Common.ps1')
    Initialize-LifeOSRecoveryProgressNative
}
$recoveryReaderBody = ($commonText -split 'function Read-RecoveryJournal', 2)[1] -split 'function Save-CollectorReceipt', 2
if (-not $recoveryReaderBody[0].Contains('Get-LifeOSBoundedTreeItem -Root $root') -or
    -not $recoveryReaderBody[0].Contains('Get-LifeOSFileDigest -Path $filePath') -or
    $recoveryReaderBody[0].Contains('Get-RecoveryTreeManifestIndex -Root $root -Cache $treeIndexCache')) {
    throw 'FAIL: Recovery journal validation must stream one bounded, identity-checked tree scan without a duplicate tree index.'
}
if (-not $recoveryReaderBody[0].Contains("Get-JournalProperty `$unit 'phase') -ne 'complete'")) {
    throw 'FAIL: Recovery journal completion checks must retain case-insensitive phase compatibility.'
}
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
$phaseAwareProgressRead = 'Read-RecoveryProgress -Manifest $Manifest -Journal $journal -JournalUnits $journalUnits -Strict:($Strict -or [string]$journal.phase -eq ''completed'') -ProgressLeaseHolder $ProgressLeaseHolder'
if (-not $recoveryReaderBody[0].Contains($phaseAwareProgressRead)) {
    throw 'FAIL: Completed recovery journals must select strict progress validation while nonterminal reads retain caller strictness.'
}
$progressReaderBody = ($commonText -split 'function Read-RecoveryProgress', 2)[1] -split 'function Test-RecoveryAuthorityPath', 2
if ($progressReaderBody[0].Contains('[IO.File]::Open') -or
    $progressReaderBody[0].Contains('Get-Acl') -or
    $progressReaderBody[0].Contains('Test-Path')) {
    throw 'FAIL: progress replay and append must not reopen or revalidate the pathname after lease acquisition.'
}
$progressSecurityBody = ($commonText -split 'function Assert-RecoveryProgressLeaseSecurity', 2)[1] -split 'function New-RecoveryProgressLease', 2
$progressSecurityBoundary = $progressSecurityBody[0].IndexOf("throw 'Recovery progress ACL contains an ACE outside the management boundary.'", [StringComparison]::Ordinal)
$progressSecurityRepair = $progressSecurityBody[0].IndexOf('if ($needsRepair)', [StringComparison]::Ordinal)
if ($progressSecurityBoundary -lt 0 -or $progressSecurityRepair -lt 0 -or $progressSecurityBoundary -ge $progressSecurityRepair) {
    throw 'FAIL: Progress ACLs must reject out-of-boundary owners/ACEs before any repair path.'
}
$holderContextBody = ($commonText -split 'function Assert-RecoveryProgressLeaseHolderContext', 2)[1] -split 'function Get-RecoveryJournalUnits', 2
if ($holderContextBody[0].Contains('Get-RecoveryProgressLeaseHolderContext -Journal') -or
    -not $holderContextBody[0].Contains('ValidatedUnitPhases') -or
    -not $holderContextBody[0].Contains('Get-RecoveryProgressUnitContent $unit')) {
    throw 'FAIL: Cached progress holder validation must use the captured context and validated phases without rebuilding the inventory.'
}
$progressAppendBody = ($commonText -split 'function Append-RecoveryProgress', 2)[1] -split 'function Assert-RecoveryProgressCapacity', 2
if (-not $progressAppendBody[0].Contains('Get-RecoveryProgressUnitCount -Journal $Journal -JournalUnits $unitsValue -ProgressLeaseHolder $ProgressLeaseHolder') -or
    -not $progressAppendBody[0].Contains('-CreateIfMissing') -or
    $progressAppendBody[0].Contains('-CreateNewOnly')) {
    throw 'FAIL: Progress append must use the holder count fast path and create only after a missing leaf is established.'
}
if (-not $progressAppendBody[0].Contains('ValidatedUnitPhases[$UnitIndex] = $Phase')) {
    throw 'FAIL: Progress phase cache must advance only after the durable frame commit.'
}
$boundedTreeBody = ($commonText -split 'function Get-LifeOSBoundedTreeItem', 2)[1] -split 'function Get-TreeManifestIndex', 2
if ($boundedTreeBody[0] -match '\$unsafeTarget|\$target\s*=') {
    throw 'FAIL: bounded tree reparse checks must use LinkType and never compare Target as a link type.'
}
$stageStart = $commonText.IndexOf('function Invoke-RecoveryStage', [StringComparison]::Ordinal)
$stageEnd = $commonText.IndexOf('function Restore-LifeOSServiceSnapshots', $stageStart, [StringComparison]::Ordinal)
if ($stageStart -lt 0 -or $stageEnd -le $stageStart) { throw 'FAIL: Recovery stage source boundary is missing.' }
$stageText = $commonText.Substring($stageStart, $stageEnd - $stageStart)
$completedStart = $stageText.IndexOf('if ($journal.phase -eq ''completed'')', [StringComparison]::Ordinal)
$artifactsGate = $stageText.IndexOf('if ($journal.phase -ne ''artifacts-complete'')', $completedStart, [StringComparison]::Ordinal)
if ($completedStart -lt 0 -or $artifactsGate -le $completedStart) { throw 'FAIL: Completed recovery stage branch is missing.' }
$completedBranch = $stageText.Substring($completedStart, $artifactsGate - $completedStart)
if (-not $completedBranch.Contains('if ([string]$stageState -ne ''complete'')') -or
    -not $completedBranch.Contains('$stageScopeSucceeded = $true') -or
    -not $completedBranch.Contains('return')) {
    throw 'FAIL: Completed recovery stages must validate, mark success, and return.'
}
foreach ($callbackInvocation in @('& $Action', '& $LiveAction', '& $Postcondition', 'Write-JsonAtomic')) {
    if ($completedBranch.Contains($callbackInvocation)) {
        throw "FAIL: Completed recovery stages must not invoke callbacks or checkpoint the stage: $callbackInvocation"
    }
}
$artifactsCompleteStart = $stageText.IndexOf('if ([string]$stageState -eq ''complete'')', $artifactsGate, [StringComparison]::Ordinal)
$restoringStart = $stageText.IndexOf('Set-JournalProperty $stages $Name ''restoring''', $artifactsCompleteStart, [StringComparison]::Ordinal)
if ($artifactsCompleteStart -lt 0 -or $restoringStart -le $artifactsCompleteStart) { throw 'FAIL: Artifacts-complete stage branch is missing.' }
$artifactsCompleteBranch = $stageText.Substring($artifactsCompleteStart, $restoringStart - $artifactsCompleteStart)
if (-not $artifactsCompleteBranch.Contains('& $LiveAction') -or
    -not $artifactsCompleteBranch.Contains('& $Postcondition') -or
    $artifactsCompleteBranch.IndexOf('& $LiveAction', [StringComparison]::Ordinal) -ge
    $artifactsCompleteBranch.IndexOf('& $Postcondition', [StringComparison]::Ordinal)) {
    throw 'FAIL: An artifacts-complete stage must run LiveAction before Postcondition.'
}
if (-not $stageText.Contains('Read-RecoveryJournal $Manifest') -or
    $stageText.IndexOf('Read-RecoveryJournal $Manifest', [StringComparison]::Ordinal) -gt $stageText.IndexOf('& $Action', [StringComparison]::Ordinal)) {
    throw 'FAIL: Recovery stages must authenticate the journal before acting.'
}
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

# Phase 1 exposes a handle-bound artifact capability beside the retained
# progress lease. Keep the source contract narrow until the artifact loop is
# deliberately wired in a later phase.
$nativeStart = $commonText.IndexOf('    private static void AssertLeaf', [StringComparison]::Ordinal)
$nativeEnd = $commonText.IndexOf('function New-RecoveryProgressLeaseHolder', $nativeStart, [StringComparison]::Ordinal)
$artifactNativeText = if ($nativeStart -ge 0 -and $nativeEnd -gt $nativeStart) {
    $commonText.Substring($nativeStart, $nativeEnd - $nativeStart)
} else { '' }
$wrapperStart = $commonText.IndexOf('function Test-RecoveryArtifactPathUnderRoot', [StringComparison]::Ordinal)
$wrapperEnd = $commonText.IndexOf('function Assert-RecoveryProgressCapacity', $wrapperStart, [StringComparison]::Ordinal)
$artifactWrapperText = if ($wrapperStart -ge 0 -and $wrapperEnd -gt $wrapperStart) {
    $commonText.Substring($wrapperStart, $wrapperEnd - $wrapperStart)
} else { '' }
$restoreStart = $commonText.IndexOf('function Restore-ManifestArtifacts', [StringComparison]::Ordinal)
$restoreEnd = $commonText.IndexOf('function Copy-FileVerifiedAtomic', $restoreStart, [StringComparison]::Ordinal)
$restoreText = if ($restoreStart -ge 0 -and $restoreEnd -gt $restoreStart) {
    $commonText.Substring($restoreStart, $restoreEnd - $restoreStart)
} else { '' }
if ([string]::IsNullOrEmpty($artifactNativeText) -or [string]::IsNullOrEmpty($artifactWrapperText) -or
    [string]::IsNullOrEmpty($restoreText)) {
    throw 'FAIL: phase 1 artifact source boundaries are missing.'
}
$appendStart = $commonText.IndexOf('function Append-RecoveryProgress', [StringComparison]::Ordinal)
$appendEnd = $commonText.IndexOf('# Phase one binds retained handles', $appendStart, [StringComparison]::Ordinal)
$appendText = if ($appendStart -ge 0 -and $appendEnd -gt $appendStart) {
    $commonText.Substring($appendStart, $appendEnd - $appendStart)
} else { '' }
if (-not $artifactNativeText.Contains('CommitRecoveryProgressFrame') -or
    -not $appendText.Contains('CommitRecoveryProgressFrame') -or
    $appendText.Contains('$nextPhases')) {
    throw 'FAIL: recovery progress phase updates must replace one native token after flush without copying the full inventory.'
}
if ($artifactNativeText.Contains('public static RecoveryPhaseToken AdvanceRecoveryPhaseAuthority') -or
    -not $artifactNativeText.Contains('authority.Advance(unitIndex, nextPhase);') -or
    -not $artifactNativeText.Contains('progressLease.Stream.Flush(true);')) {
    throw 'FAIL: phase authority advancement must stay inside the retained-stream frame commit.'
}
foreach ($parserContract in @(
    'public sealed class RecoveryProgressRecord',
    'private sealed class RecoveryProgressPayloadParser',
    'new UTF8Encoding(false, true)',
    'int fieldMask = 0',
    'ParseRecoveryProgressRecord(payload',
    'authority.ExpectedTransactionId')) {
    if (-not $artifactNativeText.Contains($parserContract)) {
        throw "FAIL: strict recovery-progress payload parser contract is missing: $parserContract"
    }
}
if ($artifactNativeText.Contains('payloadText.IndexOf') -or
    $artifactNativeText.Contains('sequenceNeedle') -or
    $artifactNativeText.Contains('unitNeedle') -or
    $artifactNativeText.Contains('phaseNeedle')) {
    throw 'FAIL: recovery-progress payload authentication must not use substring needles.'
}
foreach ($nativeContract in @(
    'ArtifactDirectoryLease', 'ArtifactFileLease', 'ArtifactQuarantineLease',
    'ArtifactCopyReceipt', 'ArtifactMutationContext', 'OpenArtifactRelative',
    'FileCreate', 'FileOpenReparsePoint', 'FileShareRead', 'DeleteAccess',
    'FileStreamInformation', 'MaxStreamInformationBytes', 'ArtifactCopyBufferBytes',
    'Flush(true)', 'TransformBlock', 'NumberOfLinks', 'SetFileInformationByHandle',
    'NtSetInformationFile', 'FileDispositionInformationEx', 'FileDispositionDelete',
    'FileRenameInformation', 'ReplaceIfExists = 0', 'AssertArtifactNameBinding',
    'AssertDefaultDataStreamOnly')) {
    if (-not $artifactNativeText.Contains($nativeContract)) {
        throw "FAIL: phase 1 native artifact contract is missing: $nativeContract"
    }
}
$phaseAuthorityStart = $artifactNativeText.IndexOf('public sealed class RecoveryPhaseAuthority', [StringComparison]::Ordinal)
$phaseAuthorityEnd = $artifactNativeText.IndexOf('public sealed class ArtifactMutationContext', $phaseAuthorityStart, [StringComparison]::Ordinal)
$phaseAuthorityText = if ($phaseAuthorityStart -ge 0 -and $phaseAuthorityEnd -gt $phaseAuthorityStart) {
    $artifactNativeText.Substring($phaseAuthorityStart, $phaseAuthorityEnd - $phaseAuthorityStart)
} else { '' }
foreach ($authorityContract in @(
    'public sealed class RecoveryPhaseAuthority',
    'private readonly RecoveryPhaseToken[] tokens;',
    'private RecoveryPhaseAuthority(string[] committedPhases)',
    'internal static RecoveryPhaseAuthority Create(string[] committedPhases)',
    'tokens = new RecoveryPhaseToken[committedPhases.Length];',
    'public long UpdateCount { get { return updateCount; } }',
    'public RecoveryPhaseToken GetToken(int unitIndex)',
    'internal RecoveryPhaseToken Advance(int unitIndex, string nextPhase)',
    'tokens[unitIndex] = replacement;',
    'public string GetPhase(int unitIndex)',
    'public bool Matches(int unitIndex, string expectedPhase)')) {
    if (-not $phaseAuthorityText.Contains($authorityContract)) {
        throw "FAIL: immutable recovery phase authority contract is missing: $authorityContract"
    }
}
if (-not $artifactNativeText.Contains('public sealed class RecoveryPhaseToken')) {
    throw 'FAIL: immutable per-unit recovery phase tokens are missing.'
}
if ($phaseAuthorityText.Contains('public RecoveryPhaseAuthority(') -or
    -not $artifactNativeText.Contains('return RecoveryPhaseAuthority.Create(committedPhases);')) {
    throw 'FAIL: PowerShell must not receive a public phase-authority constructor; the native facade must use the validated factory.'
}
$holderContextStart = $commonText.IndexOf('function Assert-RecoveryProgressLeaseHolderContext', [StringComparison]::Ordinal)
$holderContextEnd = $commonText.IndexOf('function Get-RecoveryJournalUnits', $holderContextStart, [StringComparison]::Ordinal)
$holderContextText = if ($holderContextStart -ge 0 -and $holderContextEnd -gt $holderContextStart) {
    $commonText.Substring($holderContextStart, $holderContextEnd - $holderContextStart)
} else { '' }
$artifactBindingStart = $commonText.IndexOf('function Get-RecoveryArtifactMutationBinding', [StringComparison]::Ordinal)
$artifactBindingEnd = $commonText.IndexOf('function Assert-RecoveryArtifactMutationBinding', $artifactBindingStart, [StringComparison]::Ordinal)
$artifactBindingContract = if ($artifactBindingStart -ge 0 -and $artifactBindingEnd -gt $artifactBindingStart) {
    $commonText.Substring($artifactBindingStart, $artifactBindingEnd - $artifactBindingStart)
} else { '' }
foreach ($indexedContract in @(
    'if ($UnitIndex -ge 0)',
    '$Holder.IndexedUnitValidationCount = [long]$Holder.IndexedUnitValidationCount + 1',
    '$unit = Get-RecoveryProgressUnit -Units $ownedUnits -UnitIndex $UnitIndex',
    '$authorityPhase = [string]$Holder.PhaseAuthority.GetPhase($UnitIndex)',
    '-not [object]::ReferenceEquals($Holder.UnitReferences[$UnitIndex], $unit)',
    'function Get-RecoveryArtifactMutationBinding',
    'Assert-RecoveryProgressLeaseHolderContext -Holder $ProgressLeaseHolder -Journal $Journal -JournalUnits $units -UnitCount $unitCount -UnitIndex $UnitIndex')) {
    $haystack = if ($indexedContract.StartsWith('function Get-RecoveryArtifactMutationBinding')) { $artifactBindingContract } else { $holderContextText + $artifactBindingContract }
    if (-not $haystack.Contains($indexedContract)) {
        throw "FAIL: indexed recovery artifact validation contract is missing: $indexedContract"
    }
}
if ($artifactBindingContract.Contains('-ValidateAllUnits') -or
    -not $holderContextText.Contains('$Holder.FullUnitValidationCount = [long]$Holder.FullUnitValidationCount + 1') -or
    -not $holderContextText.Contains('return')) {
    throw 'FAIL: artifact validation must use the indexed holder path and reserve full inventory validation for setup/rebinding.'
}
if (-not $artifactNativeText.Contains('private readonly RecoveryPhaseAuthority phaseAuthority;') -or
    -not $artifactNativeText.Contains('private readonly RecoveryPhaseToken phaseToken;') -or
    -not $artifactNativeText.Contains('phaseAuthority.IsCurrent(UnitIndex, phaseToken)') -or
    -not $artifactNativeText.Contains('!retainedPhaseAuthority.Matches(unitIndex, "restoring")') -or
    -not $artifactWrapperText.Contains('-not [object]::ReferenceEquals($Context.PhaseAuthority, $binding.PhaseAuthority)') -or
    -not $artifactWrapperText.Contains('-not [object]::ReferenceEquals($Context.PhaseToken, $binding.PhaseToken)') -or
    -not $artifactWrapperText.Contains('-not [object]::ReferenceEquals($Context.Native.PhaseAuthority, $Context.PhaseAuthority)') -or
    -not $artifactWrapperText.Contains('-not [object]::ReferenceEquals($Context.Native.PhaseToken, $Context.PhaseToken)')) {
    throw 'FAIL: artifact mutation contexts must remain bound to the immutable phase authority reference.'
}
foreach ($wrapperName in @(
    'Get-RecoveryArtifactMutationBinding', 'Assert-RecoveryArtifactMutationBinding',
    'Assert-RecoveryArtifactCapability', 'New-RecoveryArtifactMutationContext',
    'Close-RecoveryArtifactMutationContext', 'New-RecoveryArtifactQuarantineSibling',
    'Open-RecoveryArtifactDestination', 'Open-RecoveryArtifactStaged',
    'Copy-RecoveryArtifactToQuarantine', 'Remove-RecoveryArtifactDestination',
    'Publish-RecoveryArtifactStaged')) {
    if (-not $artifactWrapperText.Contains("function $wrapperName")) {
        throw "FAIL: typed phase 1 artifact wrapper is missing: $wrapperName"
    }
}
foreach ($requiredParameter in @(
    '[Parameter(Mandatory)][psobject]$Context',
    '[Parameter(Mandatory)][psobject]$Manifest',
    '[Parameter(Mandatory)][psobject]$Journal',
    '[Parameter(Mandatory)][int]$UnitIndex')) {
    if (-not $artifactWrapperText.Contains($requiredParameter)) {
        throw "FAIL: artifact wrappers must expose the explicit binding parameter: $requiredParameter"
    }
}
if (-not $artifactWrapperText.Contains('[Parameter(Mandatory)][psobject]$Unit') -or
    -not $artifactWrapperText.Contains('[Parameter(Mandatory)][psobject]$ProgressLeaseHolder') -or
    -not $artifactWrapperText.Contains('CreateGeneratedQuarantineSibling($QuarantineNonce')) {
    throw 'FAIL: artifact context construction must bind the journal unit and retained holder and generate its quarantine name natively.'
}
foreach ($forbiddenFallback in @('Copy-Item', 'Remove-Item', 'Move-Item', '[IO.File]::', '[System.IO.File]::', 'QuarantinePath')) {
    if ($artifactWrapperText.Contains($forbiddenFallback)) {
        throw "FAIL: phase 1 artifact wrappers contain a forbidden pathname fallback: $forbiddenFallback"
    }
}
if ($restoreText.Contains('New-RecoveryArtifactMutationContext') -or
    $restoreText.Contains('New-RecoveryArtifactQuarantineSibling') -or
    $restoreText.Contains('Copy-RecoveryArtifactToQuarantine') -or
    $restoreText.Contains('Remove-RecoveryArtifactDestination') -or
    $restoreText.Contains('Publish-RecoveryArtifactStaged') -or
    -not $restoreText.Contains('Restore-Artifact $restore')) {
    throw 'FAIL: phase 1 artifact capability must remain unwired from Restore-ManifestArtifacts.'
}
Write-Host 'PASS: phase 1 native artifact capability is typed, handle-bound, and unwired'
Write-Host 'PASS: remaining Windows deployment/recovery static assertions'

# Recovery diagnostics are an opt-in observation path. Keep the entry-point
# wiring separate from normal deployment and assert the bounded record
# contract so a later refactor cannot turn diagnostics into a second recovery
# authority or enable them during definition-only source inspection.
$rollbackText = Get-Content -LiteralPath (Join-Path $root 'rollback.ps1') -Raw
foreach ($diagnosticContract in @(
    'function Start-LifeOSRecoveryDiagnostics',
    'function Stop-LifeOSRecoveryDiagnostics',
    'function Start-LifeOSRecoveryDiagnosticScope',
    'function Stop-LifeOSRecoveryDiagnosticScope',
    '$script:LifeOSRecoveryDiagnosticsMaxScopes = 64',
    '$script:LifeOSRecoveryDiagnosticsMaxRecordBytes = 1024',
    '$script:LifeOSRecoveryDiagnosticsMaxDetailRecords = 64',
    '$script:LifeOSRecoveryDiagnosticsMaxHeartbeatRecords = 47',
    '$script:LifeOSRecoveryDiagnosticsMaxTotalRecords',
    'state-precondition',
    'rootsSkipped',
    'Start-LifeOSRecoveryDiagnosticDetailPhase',
    'Stop-LifeOSRecoveryDiagnosticDetailPhase',
    'Write-LifeOSRecoveryDiagnosticDetailHeartbeat',
    'Get-LifeOSRecoveryDiagnosticDetailDelta',
    'journalReadCalls',
    'journalScanPasses',
    'progressReadCalls',
    'progressFileOpens',
    'progressReadBytes',
    'Write-Information',
    'LifeOSRecoveryDiagnostics'
)) {
    if (-not $commonText.Contains($diagnosticContract)) {
        throw "FAIL: recovery diagnostics contract is missing: $diagnosticContract"
    }
}
if ($installText -notmatch '(?m)^\s*\[switch\]\$RecoveryDiagnostics\s*$' -or
    $rollbackText -notmatch '(?m)^\s*\[switch\]\$RecoveryDiagnostics\s*$') {
    throw 'FAIL: install and rollback must expose the opt-in diagnostics switch.'
}
$installPreamble = ($installText -split 'function Invoke-LifeOSInstall', 2)[0]
if ($installPreamble.Contains('Start-LifeOSRecoveryDiagnostics')) {
    throw 'FAIL: -DefineOnly source loading must not activate recovery diagnostics.'
}
$installTransactionIndex = $installText.IndexOf('$deploymentMutex = Enter-LifeOSDeploymentTransaction', [StringComparison]::Ordinal)
$installStartIndex = $installText.IndexOf('Start-LifeOSRecoveryDiagnostics -Enabled:$true', [StringComparison]::Ordinal)
$installExitIndex = $installText.LastIndexOf('Exit-LifeOSDeploymentTransaction', [StringComparison]::Ordinal)
$installStopIndex = $installText.LastIndexOf('Stop-LifeOSRecoveryDiagnostics', [StringComparison]::Ordinal)
if ($installTransactionIndex -lt 0 -or $installStartIndex -le $installTransactionIndex -or
    $installExitIndex -lt 0 -or $installStopIndex -le $installExitIndex) {
    throw 'FAIL: install diagnostics must begin after transaction acquisition and stop after transaction exit.'
}
$rollbackTryIndex = $rollbackText.IndexOf('try {', [StringComparison]::Ordinal)
$rollbackStartIndex = $rollbackText.IndexOf('Start-LifeOSRecoveryDiagnostics -Enabled:$RecoveryDiagnostics', [StringComparison]::Ordinal)
$rollbackExitIndex = $rollbackText.LastIndexOf('Exit-LifeOSDeploymentTransaction', [StringComparison]::Ordinal)
$rollbackStopIndex = $rollbackText.LastIndexOf('Stop-LifeOSRecoveryDiagnostics', [StringComparison]::Ordinal)
if ($rollbackTryIndex -lt 0 -or $rollbackStartIndex -le $rollbackTryIndex -or
    $rollbackExitIndex -lt 0 -or $rollbackStopIndex -le $rollbackExitIndex) {
    throw 'FAIL: rollback diagnostics must begin inside the outer try and stop after transaction exit.'
}
if (-not $commonText.Contains('detailReservedEndRecords') -or
    -not $commonText.Contains('phaseStartUnits') -or
    -not $commonText.Contains('lastHeartbeatUnits') -or
    -not $commonText.Contains('-SinceHeartbeat')) {
    throw 'FAIL: detail telemetry must reserve close records and use independent phase and heartbeat baselines.'
}
if ($commonText.Contains('detailTreePhaseActive') -or
    -not $commonText.Contains('detailDigestPhaseDepth') -or
    -not $commonText.Contains('detailDigestSessionId')) {
    throw 'FAIL: digest telemetry must be scoped to the active diagnostics session and phase depth.'
}
$detailReaderStart = $commonText.IndexOf('function Read-RecoveryProgress', [StringComparison]::Ordinal)
$detailReaderEnd = $commonText.IndexOf('function Read-RecoveryJournal', [StringComparison]::Ordinal)
if ($detailReaderStart -lt 0 -or $detailReaderEnd -le $detailReaderStart) {
    throw 'FAIL: recovery progress reader source boundary is missing.'
}
$detailReaderText = $commonText.Substring($detailReaderStart, $detailReaderEnd - $detailReaderStart)
if (-not $detailReaderText.Contains('finally') -or
    -not $detailReaderText.Contains('Stop-LifeOSRecoveryDiagnosticDetailPhase') -or
    -not $detailReaderText.Contains("-Phase 'progress-read'") -or
    -not $detailReaderText.Contains("-Phase 'progress-replay'")) {
    throw 'FAIL: progress reader detail phases must close in finally blocks.'
}
$digestStart = $commonText.IndexOf('function Get-LifeOSFileDigest', [StringComparison]::Ordinal)
$digestEnd = $commonText.IndexOf('function Get-FileSha256', [StringComparison]::Ordinal)
if ($digestStart -lt 0 -or $digestEnd -le $digestStart) { throw 'FAIL: digest source boundary is missing.' }
$digestText = $commonText.Substring($digestStart, $digestEnd - $digestStart)
if (-not $digestText.Contains('$hasher.ComputeHash($stream)') -or
    -not $digestText.Contains('Add-LifeOSRecoveryDiagnosticDigestSample') -or
    -not $digestText.Contains('diagnosticHashSucceeded')) {
    throw 'FAIL: file digest telemetry must count only successfully validated descriptor-bound hashes.'
}
if ($digestText.Contains('Add-LifeOSRecoveryDiagnosticDigestSample -ElapsedMs $diagnosticMs')) {
    throw 'FAIL: digest telemetry must not be emitted from finally after a failed validation.'
}
$treeIndexStart = $commonText.IndexOf('function Get-TreeManifestIndex', [StringComparison]::Ordinal)
$treeIndexEnd = $commonText.IndexOf('function Get-TreeManifest {', [StringComparison]::Ordinal)
if ($treeIndexStart -lt 0 -or $treeIndexEnd -le $treeIndexStart) { throw 'FAIL: tree-index source boundary is missing.' }
$treeIndexText = $commonText.Substring($treeIndexStart, $treeIndexEnd - $treeIndexStart)
$treeHashCall = $treeIndexText.IndexOf('Get-LifeOSFileDigest', [StringComparison]::Ordinal)
$treeIdentityCheck = $treeIndexText.IndexOf('Assert-LifeOSTreeItemIdentity', [StringComparison]::Ordinal)
$treeLengthCheck = $treeIndexText.IndexOf('[long]$hashRecord.Length -ne $enumeratedLength', [StringComparison]::Ordinal)
$treeDigestCommit = $treeIndexText.LastIndexOf('Add-LifeOSRecoveryDiagnosticDigestSample', [StringComparison]::Ordinal)
if ($treeHashCall -lt 0 -or $treeIdentityCheck -le $treeHashCall -or
    $treeLengthCheck -le $treeIdentityCheck -or $treeDigestCommit -le $treeLengthCheck) {
    throw 'FAIL: tree-index digest accounting must follow identity and enumerated-length validation.'
}
$recoveryTreeStart = $commonText.IndexOf("`$treePhase = Start-LifeOSRecoveryDiagnosticDetailPhase -Phase 'tree-validation'", [StringComparison]::Ordinal)
$recoveryTreeEnd = $commonText.IndexOf("`$statePhase = Start-LifeOSRecoveryDiagnosticDetailPhase -Phase 'state-validation'", $recoveryTreeStart, [StringComparison]::Ordinal)
if ($recoveryTreeStart -lt 0 -or $recoveryTreeEnd -le $recoveryTreeStart) { throw 'FAIL: recovery tree-validation source boundary is missing.' }
$recoveryTreeText = $commonText.Substring($recoveryTreeStart, $recoveryTreeEnd - $recoveryTreeStart)
$recoveryHashCall = $recoveryTreeText.IndexOf('Get-LifeOSFileDigest', [StringComparison]::Ordinal)
$recoveryIdentityCheck = $recoveryTreeText.IndexOf('Assert-LifeOSTreeItemIdentity', [StringComparison]::Ordinal)
$recoveryLengthCheck = $recoveryTreeText.IndexOf('[long]$hashRecord.Length -ne [long]$item.Length', [StringComparison]::Ordinal)
$recoveryDigestCommit = $recoveryTreeText.LastIndexOf('Add-LifeOSRecoveryDiagnosticDigestSample', [StringComparison]::Ordinal)
if ($recoveryHashCall -lt 0 -or $recoveryIdentityCheck -le $recoveryHashCall -or
    $recoveryLengthCheck -le $recoveryIdentityCheck -or $recoveryDigestCommit -le $recoveryLengthCheck) {
    throw 'FAIL: recovery tree digest accounting must follow identity and enumerated-length validation.'
}
Write-Host 'PASS: recovery diagnostics are opt-in, bounded, and transaction-scoped'
