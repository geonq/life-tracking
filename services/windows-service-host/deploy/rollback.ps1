[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$CodexTaskName = 'LifeOSCodexCollector'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

Assert-SafeTaskName $LegacyTaskName
Assert-SafeTaskName $CodexTaskName
Assert-WindowsAdministrator
Assert-ExistingFile $ManifestPath 'Rollback manifest'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$manifestPath = (Get-FullPath $ManifestPath)
Assert-CanonicalRollbackManifest -Manifest $manifest -ManifestPath $manifestPath
$currentOperatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($currentOperatorSid -ne [string]$manifest.operatorSid) {
    throw 'Rollback must be run by the operator that created the install manifest.'
}
if ([string]$manifest.legacyTask.Name -ne $LegacyTaskName -or [string]$manifest.codexTask.Name -ne $CodexTaskName) {
    throw 'Rollback task names do not match the names bound into the install manifest.'
}
$backupDirectory = [string]$manifest.paths.backupDirectory
Assert-ExistingDirectory $backupDirectory 'Rollback backup directory'

foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) { Stop-LifeOSService $serviceName }

# Restore only artifacts explicitly recorded by install.ps1.  A current file
# with no prior backup is moved into the rollback directory rather than
# deleted, so recovery remains inspectable and reversible.
Restore-ManifestArtifacts $manifest $backupDirectory
Restore-AclSnapshots $manifest

$legacySnapshot = [pscustomobject]@{
    Exists = [bool]$manifest.legacyTask.Exists
    Enabled = [bool]$manifest.legacyTask.Enabled
    State = if ($null -ne $manifest.legacyTask.PSObject.Properties['State']) { [string]$manifest.legacyTask.State } else { 'Stopped' }
    TaskPath = if ($null -ne $manifest.legacyTask.PSObject.Properties['TaskPath']) { [string]$manifest.legacyTask.TaskPath } else { '\' }
    Xml = $null
}
if ($legacySnapshot.Exists) {
    $taskBackup = [string]$manifest.legacyTask.Backup
    Assert-ExistingFile $taskBackup 'Legacy task backup'
    $legacySnapshot.Xml = Get-Content -LiteralPath $taskBackup -Raw -ErrorAction Stop
}
Restore-LegacyTask $legacySnapshot $LegacyTaskName
if ($null -ne $manifest.PSObject.Properties['legacyListener'] -and [bool]$manifest.legacyListener.Exists) {
    Restore-LegacyGatewayListener -TaskSnapshot $legacySnapshot -ListenerSnapshot $manifest.legacyListener -TaskName $LegacyTaskName -TaskPath ([string]$legacySnapshot.TaskPath) -Port 8421
}

$codexSnapshot = [pscustomobject]@{ Exists = $false; Enabled = $false; State = 'Stopped'; TaskPath = '\'; Xml = $null }
if ($null -ne $manifest.PSObject.Properties['codexTask']) {
    $codexSnapshot.Exists = [bool]$manifest.codexTask.Exists
    $codexSnapshot.Enabled = [bool]$manifest.codexTask.Enabled
    if ($null -ne $manifest.codexTask.PSObject.Properties['State']) { $codexSnapshot.State = [string]$manifest.codexTask.State }
    if ($null -ne $manifest.codexTask.PSObject.Properties['TaskPath']) { $codexSnapshot.TaskPath = [string]$manifest.codexTask.TaskPath }
    if ($codexSnapshot.Exists) {
        $codexBackup = [string]$manifest.codexTask.Backup
        Assert-ExistingFile $codexBackup 'Codex task backup'
        $codexSnapshot.Xml = Get-Content -LiteralPath $codexBackup -Raw -ErrorAction Stop
    }
    Restore-CodexCollectorTask $codexSnapshot $CodexTaskName
}

if ($null -ne $manifest.PSObject.Properties['serviceSnapshots']) {
    foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) {
        $snapshotProperty = $manifest.serviceSnapshots.PSObject.Properties[$serviceName]
        if ($null -ne $snapshotProperty) {
            Restore-LifeOSServiceSnapshot $snapshotProperty.Value
        }
    }
} else {
    # Manifests written before SCM snapshots remain safe but cannot restore a
    # prior start mode, so leave their new service registrations disabled.
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
        }
    }
}

if ($null -ne $manifest.PSObject.Properties['tailscaleStatusBefore'] -and
    $null -ne $manifest.tailscaleStatusBefore -and
    $null -ne $manifest.paths.PSObject.Properties['tailscaleExecutable']) {
    $tailscaleExpectedAfter = ''
    if ($null -ne $manifest.PSObject.Properties['tailscaleStatusAfter']) {
        $tailscaleExpectedAfter = [string]$manifest.tailscaleStatusAfter
    }
    Restore-TailscaleServeSnapshot -TailscaleExecutable ([string]$manifest.paths.tailscaleExecutable) -Json ([string]$manifest.tailscaleStatusBefore) -ExpectedAfterJson $tailscaleExpectedAfter
} else {
    Write-Warning 'This older manifest has no Tailscale Serve snapshot; no Serve mutation was attempted by rollback.'
}

Write-Warning 'Rollback restores prior LifeOS service registrations/state when the install manifest contains SCM snapshots; it never deletes the legacy LifeOSSyncServer task.'
Write-Host 'LifeOS Windows rollback completed. New service state is disabled and prior task/data/code artifacts were restored or moved to the rollback backup.'
