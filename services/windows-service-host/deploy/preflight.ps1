[CmdletBinding()]
param(
    [string]$ServiceHostBinarySource,
    [string]$ApiSource = 'D:\Hermes\lifeos-api',
    [string]$GatewaySource = 'D:\Hermes\lifeos-server',
    [string]$LegacyGatewaySource = 'D:\Hermes\lifeos-server',
    [string]$NodeRuntimeSource,
    [string]$PythonRuntimeSource,
    [string]$GatewayEntryPoint,
    [string]$TailscaleExecutable,
    # Path only: the operator must pre-create the canonical token file. The
    # raw LIFEOS_TAILSCALE_EDGE_TOKEN value is never accepted here.
    [string]$TailscaleEdgeTokenSource,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$CodexTaskName = 'LifeOSCodexCollector'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

function Assert-SafeServiceName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9_.-]{1,80}$') { throw "Unsafe service/task name: $Name" }
}

Assert-WindowsAdministrator
Assert-SafeServiceName 'LifeOSAPI'
Assert-SafeServiceName 'LifeOSGateway'
Assert-SafeServiceName $TailscaleServiceName
Assert-SafeServiceName $LegacyTaskName
Assert-SafeTaskName $CodexTaskName

$paths = Get-LifeOSDefaultPaths
$operatorSid = Get-InteractiveOperatorSid
$null = Assert-TailscaleEdgeTokenSource -Path $TailscaleEdgeTokenSource -ExpectedPath (Get-LifeOSTailscaleEdgeTokenPath $paths.SecretRoot) -OperatorSid $operatorSid
Assert-ExistingDirectory $ApiSource 'API source'
Assert-ExistingDirectory $GatewaySource 'Gateway source'
Assert-TrustedSourcePath $ApiSource $operatorSid
Assert-TrustedSourcePath $GatewaySource $operatorSid
Assert-ExistingDirectory $LegacyGatewaySource 'Legacy gateway source'
Assert-TrustedSourcePath $LegacyGatewaySource $operatorSid
$apiRoot = Resolve-ApiReleaseRoot $ApiSource
Assert-TrustedSourcePath $apiRoot $operatorSid
$contractsRoot = Resolve-ApiDependencyRoot $apiRoot '@iphone-life-os\contracts'
$zodRoot = Resolve-ApiDependencyRoot $apiRoot 'zod'
Assert-ExistingFile (Join-Path $contractsRoot 'package.json') 'Contracts package manifest'
Assert-ExistingFile (Join-Path $contractsRoot 'dist\index.js') 'Contracts production entry point'
Assert-ExistingFile (Join-Path $zodRoot 'package.json') 'Zod package manifest'
if (-not (Test-Path -LiteralPath (Join-Path $apiRoot 'dist\server.js') -PathType Leaf)) { throw 'Built API dist/server.js is missing.' }
$null = Get-TreeManifest (Join-Path $apiRoot 'dist')
$null = Get-TreeManifest (Join-Path $contractsRoot 'dist')
$null = Get-TreeManifest $zodRoot
$nodeSource = Resolve-NodeRuntimeSource $NodeRuntimeSource $ApiSource
$pythonRuntime = Resolve-PythonRuntimeSource $PythonRuntimeSource $GatewaySource
$pythonSource = $pythonRuntime.Root
$pythonExecutable = $pythonRuntime.Executable
$gatewayEntry = Resolve-GatewayEntryPoint $GatewayEntryPoint $GatewaySource
$gatewayLauncher = Join-Path $PSScriptRoot 'gateway_launcher.py'
Assert-ExistingFile $gatewayLauncher 'Gateway launcher'
$staticDeploymentTest = Join-Path $PSScriptRoot 'tests\Deployment.Static.Tests.ps1'
Assert-ExistingFile $staticDeploymentTest 'Deployment static test'
$behaviorDeploymentTest = Join-Path $PSScriptRoot 'tests\Deployment.Behavior.Tests.ps1'
Assert-ExistingFile $behaviorDeploymentTest 'Deployment behavioral test'
$legacyServeDeploymentTest = Join-Path $PSScriptRoot 'tests\Deployment.LegacyServe.Tests.ps1'
Assert-ExistingFile $legacyServeDeploymentTest 'Legacy Serve deployment test'
$hostSource = Resolve-ServiceHostBinary $ServiceHostBinarySource $paths.ServiceHostPath
$tailscale = Resolve-TailscaleExecutable $TailscaleExecutable
$tailscaleStatus = Get-TailscaleStatusJson $tailscale
$tailscaleDecision = Get-TailscaleServeDecision $tailscaleStatus
Write-Host ("Tailscale Serve decision: {0}; unrelated routes are preserved." -f $tailscaleDecision.Action)
Assert-TrustedSourcePath $nodeSource $operatorSid
Assert-TrustedSourcePath $pythonSource $operatorSid
Assert-TrustedSourcePath $pythonExecutable $operatorSid
Assert-TrustedSourcePath $gatewayEntry $operatorSid
Assert-TrustedSourcePath $hostSource $operatorSid

# Exercise the transferred source before any service, task, data, ACL, or
# Serve mutation. The behavioral fixture uses a local fake Tailscale command;
# it never contacts or changes the machine's real Tailscale state.
& $staticDeploymentTest | Out-Host
& $behaviorDeploymentTest | Out-Host
& $legacyServeDeploymentTest | Out-Host

# Validate the complete source-side Python import closure before any service
# is stopped. The installer later stages these exact files, so an import
# failure cannot be deferred until the Windows service has been cut over.
$gatewayImportCheck = 'import importlib,os,pathlib,sys; assert sys.version_info[:2] == (3,12),sys.version; from zoneinfo import ZoneInfo; ZoneInfo("Europe/Berlin"); roots=[pathlib.Path(os.environ["LIFEOS_DEPLOY_PREFLIGHT_GATEWAY_SOURCE"]).resolve(),pathlib.Path(os.environ["LIFEOS_DEPLOY_PREFLIGHT_LAUNCHER_SOURCE"]).resolve()]; sys.path[:0]=[str(root) for root in roots]; names=("main","enablebanking","supplement_catalog","gateway_launcher"); modules=[importlib.import_module(name) for name in names]; expected=[roots[0],roots[0],roots[0],roots[1]]; assert all(pathlib.Path(module.__file__).resolve().parent == root for module,root in zip(modules,expected)), [(name,module.__file__) for name,module in zip(names,modules)]'
$previousAllowedLogin = $env:LIFEOS_TAILSCALE_ALLOWED_LOGIN
$previousGatewayImportSource = $env:LIFEOS_DEPLOY_PREFLIGHT_GATEWAY_SOURCE
$previousLauncherImportSource = $env:LIFEOS_DEPLOY_PREFLIGHT_LAUNCHER_SOURCE
$previousGatewayImportCheck = $env:LIFEOS_DEPLOY_PREFLIGHT_IMPORT_CHECK
try {
    # main.py validates this required identity at import time. A bounded
    # non-production value proves module closure without borrowing or printing
    # the operator's real Tailscale identity.
    $env:LIFEOS_TAILSCALE_ALLOWED_LOGIN = 'preflight@lifeos.invalid'
    # Windows PowerShell can re-tokenize a native -c payload when it contains
    # embedded quotes and trailing argv values. Keep the check and its roots
    # out of the native argv boundary; the runner itself contains no double
    # quotes and therefore arrives as one Python argument on PS 5.1.
    $env:LIFEOS_DEPLOY_PREFLIGHT_GATEWAY_SOURCE = $GatewaySource
    $env:LIFEOS_DEPLOY_PREFLIGHT_LAUNCHER_SOURCE = $PSScriptRoot
    $env:LIFEOS_DEPLOY_PREFLIGHT_IMPORT_CHECK = $gatewayImportCheck
    # Keep the native `-c` payload quote-free for Windows PowerShell 5.1,
    # which strips nested quote characters while binding native arguments.
    $gatewayImportRunner = 'import os;exec(next(v for v in os.environ.values() if v.startswith(chr(105)+chr(109)+chr(112)+chr(111)+chr(114)+chr(116)+chr(32))))'
    Invoke-NativeChecked $pythonExecutable @('-I', '-c', $gatewayImportRunner) -Quiet | Out-Null
} finally {
    if ($null -eq $previousAllowedLogin) { Remove-Item Env:LIFEOS_TAILSCALE_ALLOWED_LOGIN -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_TAILSCALE_ALLOWED_LOGIN = $previousAllowedLogin }
    if ($null -eq $previousGatewayImportSource) { Remove-Item Env:LIFEOS_DEPLOY_PREFLIGHT_GATEWAY_SOURCE -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_DEPLOY_PREFLIGHT_GATEWAY_SOURCE = $previousGatewayImportSource }
    if ($null -eq $previousLauncherImportSource) { Remove-Item Env:LIFEOS_DEPLOY_PREFLIGHT_LAUNCHER_SOURCE -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_DEPLOY_PREFLIGHT_LAUNCHER_SOURCE = $previousLauncherImportSource }
    if ($null -eq $previousGatewayImportCheck) { Remove-Item Env:LIFEOS_DEPLOY_PREFLIGHT_IMPORT_CHECK -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_DEPLOY_PREFLIGHT_IMPORT_CHECK = $previousGatewayImportCheck }
}

$tailscaleService = Get-Service -Name $TailscaleServiceName -ErrorAction SilentlyContinue
if ($null -eq $tailscaleService) { throw "The required Tailscale SCM service was not found: $TailscaleServiceName" }
$legacyTasks = @(Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue)
if ($legacyTasks.Count -gt 1) { throw "Scheduled task name is ambiguous across task paths: $LegacyTaskName" }
$legacyTask = if ($legacyTasks.Count -eq 1) { $legacyTasks[0] } else { $null }
if ($null -eq $legacyTask) {
    Write-Warning "The expected legacy task was not found: $LegacyTaskName. No task will be disabled by this toolkit."
} else {
    Write-Host ("Legacy task present; state is {0}. It will be backed up and preserved." -f $legacyTask.State)
}

$legacyTaskDefinition = if ($null -eq $legacyTask) {
    [pscustomobject]@{ Exists = $false; Enabled = $false; State = 'Stopped'; TaskPath = '\'; Xml = $null }
} else {
    $legacyTaskPath = [string]$legacyTask.TaskPath
    if ([string]::IsNullOrWhiteSpace($legacyTaskPath)) { $legacyTaskPath = '\' }
    Assert-SafeTaskPath $legacyTaskPath
    [pscustomobject]@{
        Exists = $true
        Enabled = ([string]$legacyTask.State -ne 'Disabled')
        State = [string]$legacyTask.State
        TaskPath = $legacyTaskPath
        Xml = (Export-ScheduledTask -TaskName $LegacyTaskName -TaskPath $legacyTaskPath -ErrorAction Stop)
    }
}
$legacyListener = Get-LegacyGatewayListenerSnapshot -TaskSnapshot $legacyTaskDefinition -TaskName $LegacyTaskName -TaskPath ([string]$legacyTaskDefinition.TaskPath) -Port 8421
if ([bool]$legacyListener.Exists) {
    Write-Host 'Legacy 8421 listener is attributable to the saved legacy task; no listener state was changed.'
}

$apiTarget = Join-Path $paths.InstallRoot 'api'
$gatewayTarget = Join-Path $paths.InstallRoot 'gateway'
$runtimeRoot = $paths.RuntimeRoot
$dataRoot = $paths.DataRoot
$secretRoot = $paths.SecretRoot
$logRoot = $paths.LogRoot

foreach ($path in @($paths.InstallRoot, $runtimeRoot, $dataRoot, $secretRoot, $logRoot, $paths.BackupRoot)) {
    Assert-SafeAbsolutePath $path 'machine-owned path'
    if (Test-Path -LiteralPath $path) { Assert-NoReparsePath $path }
}

$legacyData = Join-Path $LegacyGatewaySource 'data'
Assert-ExistingDirectory $legacyData 'Legacy gateway data directory'
$claudeSource = Join-Path $legacyData 'claude-ingest.secret'
$usageSource = Join-Path $legacyData 'usage-history.jsonl'
if (-not (Test-Path -LiteralPath $claudeSource -PathType Leaf)) {
    throw 'The existing Claude secret must be present in the legacy gateway location for migration; it is never generated in a service-writable directory.'
}
Assert-NoReparsePath $claudeSource
if (Test-Path -LiteralPath $usageSource) { Assert-NoReparsePath $usageSource }

$calendarSource = Join-Path $legacyData 'calendar.json'
if (Test-Path -LiteralPath $calendarSource) { Assert-NoReparsePath $calendarSource }

$enableBankingConnectionsSource = Join-Path $legacyData 'enablebanking-connections.json'
if (Test-Path -LiteralPath $enableBankingConnectionsSource) {
    $null = Assert-BoundedFile $enableBankingConnectionsSource (256 * 1024) 'Legacy Enable Banking connection store'
}
$financeSummarySource = Join-Path $legacyData 'finance-summary.json'
if (Test-Path -LiteralPath $financeSummarySource) {
    $null = Assert-BoundedFile $financeSummarySource (1 * 1024 * 1024) 'Legacy finance summary cache'
}

Write-Host 'LifeOS Windows deployment preflight passed.'
Write-Host ("Operator SID: {0}" -f $operatorSid)
Write-Host ("API source: {0}" -f $ApiSource)
Write-Host ("Gateway source: {0}" -f $GatewaySource)
Write-Host ("Node runtime source: {0}" -f $nodeSource)
Write-Host ("Python runtime source: {0}" -f $pythonSource)
Write-Host ("Python interpreter: {0}" -f $pythonExecutable)
Write-Host ("Gateway entry point: {0}" -f $gatewayEntry)
Write-Host ("Service host source: {0}" -f $hostSource)
Write-Host 'No service, ACL, task, data, or Tailscale state was changed.'
