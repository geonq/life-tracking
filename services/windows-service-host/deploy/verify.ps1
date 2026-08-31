[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$TailscaleExecutable,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

function Resolve-LatestManifest {
    param([string]$Requested, [Parameter(Mandatory)][string]$BackupRoot)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { Assert-ExistingFile $Requested 'Manifest'; return $Requested }
    $candidate = Get-ChildItem -LiteralPath $BackupRoot -Directory -Filter 'install-*' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { Join-Path $_.FullName 'manifest.json' } |
        Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($candidate)) { throw 'No installation manifest was found; pass -ManifestPath explicitly.' }
    return $candidate
}

function Assert-ServiceContract {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Account, [Parameter(Mandatory)][string]$Binary, [Parameter(Mandatory)][string[]]$Dependencies, [Parameter(Mandatory)][ValidateSet('auto','delayed-auto')][string]$Mode)
    $record = Get-ServiceRecord $Name
    if ($null -eq $record) { throw "Service is missing: $Name" }
    if ([string]$record.StartName -ne $Account) { throw "Service account mismatch: $Name" }
    if ([string]$record.PathName -notlike ("*{0}*" -f $Binary) -or [string]$record.PathName -notmatch ('--service-name\s+' + [regex]::Escape($Name))) { throw "Service binary/identity invocation mismatch: $Name" }
    $actualDependencies = @(Get-ServiceDependencies $Name)
    foreach ($dependency in $Dependencies) {
        if ($actualDependencies -notcontains $dependency) { throw "Service dependency missing: $Name -> $dependency" }
    }
    if ($Mode -eq 'auto' -and [string]$record.StartMode -ne 'Auto') { throw "API is not automatic-start: $Name" }
    if ($Mode -eq 'delayed-auto') {
        $key = Get-ItemProperty -LiteralPath ("HKLM:\SYSTEM\CurrentControlSet\Services\{0}" -f $Name) -ErrorAction Stop
        if ([int]$key.Start -ne 2 -or [int]$key.DelayedAutoStart -ne 1) { throw "Gateway is not delayed automatic-start: $Name" }
    }
    $sidType = Invoke-NativeChecked 'sc.exe' @('qsidtype', $Name)
    if (($sidType.Output -join "`n") -notmatch '(?i)UNRESTRICTED') { throw "Service SID is not unrestricted: $Name" }
    $failure = Invoke-NativeChecked 'sc.exe' @('qfailure', $Name)
    $failureText = $failure.Output -join "`n"
    if ($failureText -notmatch '(?i)RESET_PERIOD.*86400' -or
        ([regex]::Matches($failureText, '(?i)RESTART.*60000')).Count -lt 3 -or
        $failureText -match '(?i)reboot') { throw "SCM recovery policy is not restart-only 60s/60s/60s for $Name" }
}

function Assert-ServiceSidNotAllowed {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$DeniedSid)
    $acl = Get-Acl -LiteralPath $Path
    foreach ($entry in $acl.Access) {
        if ($entry.AccessControlType -eq 'Allow' -and [string]$entry.IdentityReference.Value -eq $DeniedSid) {
            throw "Unexpected cross-service ACL on $Path."
        }
    }
}

Assert-WindowsAdministrator
$paths = Get-LifeOSDefaultPaths
$manifestFile = Resolve-LatestManifest $ManifestPath $paths.BackupRoot
$manifest = Get-Content -LiteralPath $manifestFile -Raw | ConvertFrom-Json -ErrorAction Stop
$configDirectory = [string]$manifest.paths.configDirectory
$apiConfig = [string]$manifest.paths.apiConfig
$gatewayConfig = [string]$manifest.paths.gatewayConfig
$gatewayAppConfig = [string]$manifest.paths.gatewayAppConfig
$hostBinary = [string]$manifest.paths.host
$claudeSecret = [string]$manifest.paths.claudeSecret
$codexSecret = [string]$manifest.paths.codexSecret
$apiData = [string]$manifest.paths.apiData
$gatewayData = [string]$manifest.paths.gatewayData
$apiLogs = [string]$manifest.paths.apiLogs
$gatewayLogs = [string]$manifest.paths.gatewayLogs

Assert-ExistingFile $apiConfig 'API service config'
Assert-ExistingFile $gatewayConfig 'Gateway service config'
Assert-ExistingFile $gatewayAppConfig 'Gateway application config'
Assert-ExistingFile $hostBinary 'Service host binary'
Assert-ExistingFile $claudeSecret 'Claude secret'
Assert-ExistingFile $codexSecret 'Codex secret'
Assert-ExistingDirectory $apiData 'API data directory'
Assert-ExistingDirectory $gatewayData 'Gateway data directory'
Assert-ExistingDirectory $apiLogs 'API log directory'
Assert-ExistingDirectory $gatewayLogs 'Gateway log directory'
Assert-PathOnlyJson $apiConfig
Assert-PathOnlyJson $gatewayConfig
Assert-PathOnlyJson $gatewayAppConfig

Set-StrictMode -Version Latest
$apiAccount = Get-ServiceAccountName 'LifeOSAPI'
$gatewayAccount = Get-ServiceAccountName 'LifeOSGateway'
Assert-ServiceContract 'LifeOSAPI' $apiAccount $hostBinary @() 'auto'
Assert-ServiceContract 'LifeOSGateway' $gatewayAccount $hostBinary @('LifeOSAPI', $TailscaleServiceName) 'delayed-auto'
$apiSid = Get-ServiceSid 'LifeOSAPI'
$gatewaySid = Get-ServiceSid 'LifeOSGateway'
Assert-ServiceSidNotAllowed ([string]$manifest.paths.api) $gatewaySid
Assert-ServiceSidNotAllowed ([string]$manifest.paths.gateway) $apiSid
Assert-ServiceSidNotAllowed ([string]$manifest.paths.apiData) $gatewaySid
Assert-ServiceSidNotAllowed ([string]$manifest.paths.gatewayData) $apiSid
Assert-ServiceSidNotAllowed $codexSecret $gatewaySid

foreach ($path in @($configDirectory, $claudeSecret, $codexSecret, $apiData, $gatewayData, $apiLogs, $gatewayLogs)) {
    Assert-NoBroadAcl $path
}
$task = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
if ($null -ne $task) {
    if ($task.State -ne 'Disabled') { throw "Legacy task remains enabled after a completed cutover: $LegacyTaskName" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.legacyTask.Backup) -or
        -not (Test-Path -LiteralPath ([string]$manifest.legacyTask.Backup) -PathType Leaf)) {
        throw 'Legacy task backup is missing.'
    }
}

$tailscale = Resolve-TailscaleExecutable $TailscaleExecutable
$status = Get-TailscaleStatusJson $tailscale
if (-not (Test-TailscaleServeExact $status)) { throw 'Tailscale Serve is not the required loopback mapping or a truthy Funnel flag was reported.' }
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8787/health') 10)) { throw 'LifeOSAPI health check failed.' }
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8421/health') 10)) { throw 'LifeOSGateway health check failed.' }

Write-Host 'LifeOS Windows deployment verification passed.'
Write-Host ("Manifest: {0}" -f $manifestFile)
Write-Host 'Both services use virtual accounts, unrestricted service SIDs, least-privilege ACLs, and restart-only recovery.'
