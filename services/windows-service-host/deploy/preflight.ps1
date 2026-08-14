[CmdletBinding()]
param(
    [string]$ServiceHostBinarySource,
    [string]$ApiSource = 'D:\Hermes\lifeos-api',
    [string]$GatewaySource = 'D:\Hermes\lifeos-server',
    [string]$NodeRuntimeSource,
    [string]$PythonRuntimeSource,
    [string]$GatewayEntryPoint,
    [string]$TailscaleExecutable,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer'
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

$paths = Get-LifeOSDefaultPaths
$operatorSid = Get-InteractiveOperatorSid
Assert-ExistingDirectory $ApiSource 'API source'
Assert-ExistingDirectory $GatewaySource 'Gateway source'
Assert-TrustedSourcePath $ApiSource $operatorSid
Assert-TrustedSourcePath $GatewaySource $operatorSid
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
$pythonSource = Resolve-PythonRuntimeSource $PythonRuntimeSource $GatewaySource
$gatewayEntry = Resolve-GatewayEntryPoint $GatewayEntryPoint $GatewaySource
$hostSource = Resolve-ServiceHostBinary $ServiceHostBinarySource $paths.ServiceHostPath
$tailscale = Resolve-TailscaleExecutable $TailscaleExecutable
Assert-TrustedSourcePath $nodeSource $operatorSid
Assert-TrustedSourcePath $pythonSource $operatorSid
Assert-TrustedSourcePath $gatewayEntry $operatorSid
Assert-TrustedSourcePath $hostSource $operatorSid

$tailscaleService = Get-Service -Name $TailscaleServiceName -ErrorAction SilentlyContinue
if ($null -eq $tailscaleService) { throw "The required Tailscale SCM service was not found: $TailscaleServiceName" }
$legacyTask = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
if ($null -eq $legacyTask) {
    Write-Warning "The expected legacy task was not found: $LegacyTaskName. No task will be disabled by this toolkit."
} else {
    Write-Host ("Legacy task present; state is {0}. It will be backed up and preserved." -f $legacyTask.State)
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

$legacyData = Join-Path $GatewaySource 'data'
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

Write-Host 'LifeOS Windows deployment preflight passed.'
Write-Host ("Operator SID: {0}" -f $operatorSid)
Write-Host ("API source: {0}" -f $ApiSource)
Write-Host ("Gateway source: {0}" -f $GatewaySource)
Write-Host ("Node runtime source: {0}" -f $nodeSource)
Write-Host ("Python runtime source: {0}" -f $pythonSource)
Write-Host ("Gateway entry point: {0}" -f $gatewayEntry)
Write-Host ("Service host source: {0}" -f $hostSource)
Write-Host 'No service, ACL, task, data, or Tailscale state was changed.'
