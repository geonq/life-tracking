[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$CodexTaskName = 'LifeOSCodexCollector',
    [string]$TailscaleSnapshotTaskName = 'LifeOSTailscaleSnapshot'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

Assert-SafeTaskName $LegacyTaskName
Assert-SafeTaskName $CodexTaskName
Assert-SafeTaskName $TailscaleSnapshotTaskName
Assert-WindowsAdministrator
$deploymentMutex = $null
$rollbackCompleted = $false
try {
Assert-ExistingFile $ManifestPath 'Rollback manifest'
$manifest = Read-LifeOSBoundedJsonFile -Path $ManifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Rollback manifest'
$manifestPath = (Get-FullPath $ManifestPath)
Assert-CanonicalRollbackManifest -Manifest $manifest -ManifestPath $manifestPath -AllowPending
$serviceSnapshots = Get-LifeOSServiceSnapshotMap $manifest.serviceSnapshots
$currentOperatorSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
if ($currentOperatorSid -ne [string]$manifest.operatorSid) {
    throw 'Rollback must be run by the operator that created the install manifest.'
}
if ([string]$manifest.legacyTask.Name -ne $LegacyTaskName -or [string]$manifest.codexTask.Name -ne $CodexTaskName) {
    throw 'Rollback task names do not match the names bound into the install manifest.'
}
$backupDirectory = [string]$manifest.paths.backupDirectory
Assert-ExistingDirectory $backupDirectory 'Rollback backup directory'

# Older manifests have no complete authority provenance. Generic artifact
# recovery could discard acknowledged writes; require manual reconciliation.
$authorityRecords = @($manifest.backups | Where-Object { $_.kind -eq 'authority-set' })
$dataIntents = @($manifest.backups | Where-Object { $_.destination -eq $manifest.paths.usageHistory -or
    ([string]$_.destination).StartsWith([string]$manifest.paths.gatewayData, [StringComparison]::OrdinalIgnoreCase) })
if ($authorityRecords.Count -gt 1 -or ($authorityRecords.Count -eq 0 -and $dataIntents.Count -gt 0)) {
    throw 'Rollback requires exactly one authority provenance record; manual recovery required.'
}
if ($null -ne $manifest.PSObject.Properties['codexCollectorVerification']) {
    $verification = $manifest.codexCollectorVerification
    if ($null -eq $verification.PSObject.Properties['terminalCompleted'] -or
        $verification.terminalCompleted -ne $true -or
        $null -eq $verification.PSObject.Properties['lastRunTime']) {
        throw 'Collector terminal provenance missing; manual recovery required.'
    }
}
$deploymentMutex = Enter-LifeOSDeploymentTransaction -AllowRecovery -RecoveryManifest $manifest -RecoveryManifestPath $manifestPath
if ($null -ne $manifest.PSObject.Properties['snapshotTask'] -and [string]$manifest.snapshotTask.Name -ne $TailscaleSnapshotTaskName) { throw 'Snapshot task name does not match manifest.' }
Stop-DeploymentTaskBarrier $manifest $manifestPath
foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) { Stop-LifeOSService $serviceName }

    # Uncertain/changed authority must never be rolled back by generic restore.
    $resumeJournal = Read-RecoveryJournal $manifest
    if ($null -eq $resumeJournal) {
    foreach ($item in @($manifest.backups | Where-Object { $_.kind -eq 'authority-set' })) {
        if ($item.phase -ne 'complete' -or $null -eq $item.PSObject.Properties['afterTree'] -or
            ((@(Get-TreeManifest $item.destination) | ConvertTo-Json -Depth 8 -Compress) -ne
             (@($item.afterTree) | ConvertTo-Json -Depth 8 -Compress))) {
            throw 'Authority provenance changed or incomplete; recovery_required. Writers remain stopped.'
        }
        $usagePath = [string]$manifest.paths.usageHistory
        $usageHash = if (Test-Path -LiteralPath $usagePath -PathType Leaf) { Get-FileSha256 $usagePath } else { '' }
        if ($null -eq $item.PSObject.Properties['usageAfterSha256'] -or ($usageHash -ne [string]$item.usageAfterSha256 -and -not (Test-CollectorUsagePreserved $manifest))) {
            throw 'Usage authority changed or has no provenance; recovery_required.'
        }
        if ($item.changed -and (-not (Test-Path -LiteralPath $item.backup -PathType Container) -or
            ((@(Get-TreeManifest $item.backup) | ConvertTo-Json -Depth 8 -Compress) -ne
             (@($item.beforeTree) | ConvertTo-Json -Depth 8 -Compress)))) {
            throw 'Authority backup provenance invalid; recovery_required.'
        }
    }
    }
# Restore only artifacts explicitly recorded by install.ps1.  A current file
# with no prior backup is moved into the rollback directory rather than
# deleted, so recovery remains inspectable and reversible.
Restore-ManifestArtifacts $manifest $backupDirectory
Invoke-RecoveryStage $manifest 'Restore-AclSnapshots' { Restore-AclSnapshots $manifest }

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
    $legacySnapshot.Xml = Read-LifeOSCappedFileText -Path $taskBackup -MaxBytes (1 * 1024 * 1024) -Description 'Legacy task recovery XML'
}
Enable-RecoveryWriterRestoration $manifest
Restore-LegacyTask $legacySnapshot $LegacyTaskName
if ($null -ne $manifest.PSObject.Properties['legacyListener'] -and [bool]$manifest.legacyListener.Exists) {
    Restore-LegacyGatewayListener -TaskSnapshot $legacySnapshot -ListenerSnapshot $manifest.legacyListener -TaskName $LegacyTaskName -TaskPath ([string]$legacySnapshot.TaskPath) -Port 8421
}
Reconcile-LifeOSScheduledTaskSnapshotState $legacySnapshot $LegacyTaskName

$codexSnapshot = [pscustomobject]@{ Exists = $false; Enabled = $false; State = 'Stopped'; TaskPath = '\'; Xml = $null }
if ($null -ne $manifest.PSObject.Properties['codexTask']) {
    $codexSnapshot.Exists = [bool]$manifest.codexTask.Exists
    $codexSnapshot.Enabled = [bool]$manifest.codexTask.Enabled
    if ($null -ne $manifest.codexTask.PSObject.Properties['State']) { $codexSnapshot.State = [string]$manifest.codexTask.State }
    if ($null -ne $manifest.codexTask.PSObject.Properties['TaskPath']) { $codexSnapshot.TaskPath = [string]$manifest.codexTask.TaskPath }
    if ($codexSnapshot.Exists) {
        $codexBackup = [string]$manifest.codexTask.Backup
        Assert-ExistingFile $codexBackup 'Codex task backup'
        $codexSnapshot.Xml = Read-LifeOSCappedFileText -Path $codexBackup -MaxBytes (1 * 1024 * 1024) -Description 'Codex task recovery XML'
    }

}

$snapshotTaskSnapshot = [pscustomobject]@{ Exists = $false; Enabled = $false; State = 'Stopped'; TaskPath = '\'; Xml = $null }
if ($null -ne $manifest.PSObject.Properties['snapshotTask']) {
    if ([string]$manifest.snapshotTask.Name -ne $TailscaleSnapshotTaskName) {
        throw 'Rollback Tailscale snapshot task name does not match the name bound into the install manifest.'
    }
    $snapshotTaskSnapshot.Exists = [bool]$manifest.snapshotTask.Exists
    $snapshotTaskSnapshot.Enabled = [bool]$manifest.snapshotTask.Enabled
    if ($null -ne $manifest.snapshotTask.PSObject.Properties['State']) { $snapshotTaskSnapshot.State = [string]$manifest.snapshotTask.State }
    if ($null -ne $manifest.snapshotTask.PSObject.Properties['TaskPath']) { $snapshotTaskSnapshot.TaskPath = [string]$manifest.snapshotTask.TaskPath }
    if ($snapshotTaskSnapshot.Exists) {
        $snapshotBackup = [string]$manifest.snapshotTask.Backup
        Assert-ExistingFile $snapshotBackup 'Tailscale snapshot task backup'
        $snapshotTaskSnapshot.Xml = Read-LifeOSCappedFileText -Path $snapshotBackup -MaxBytes (1 * 1024 * 1024) -Description 'Tailscale snapshot task recovery XML'
    }

}

$gatewayNeedsSnapshot = [string](Get-SnapshotValue $serviceSnapshots['LifeOSGateway'] 'State' '') -ceq 'Running'
$hasSnapshotContract = $null -ne $manifest.PSObject.Properties['snapshotTask'] -and
    $null -ne $manifest.paths.PSObject.Properties['stateDirectory'] -and
    $null -ne $manifest.paths.PSObject.Properties['tailscaleSnapshot'] -and
    $null -ne $manifest.paths.PSObject.Properties['tailscaleSnapshotScript'] -and
    $null -ne $manifest.paths.PSObject.Properties['tailscaleExecutable']
if ($gatewayNeedsSnapshot -and -not $hasSnapshotContract) {
    throw 'Recovery cannot start the gateway without a transaction-owned Tailscale snapshot contract.'
}

if ($null -ne $manifest.PSObject.Properties['tailscaleStatusBefore'] -and
    $null -ne $manifest.tailscaleStatusBefore -and
    $null -ne $manifest.paths.PSObject.Properties['tailscaleExecutable']) {
    $tailscaleExpectedAfter = ''
    if ($null -ne $manifest.PSObject.Properties['tailscaleStatusAfter']) {
        $tailscaleExpectedAfter = [string]$manifest.tailscaleStatusAfter
    }
    Invoke-RecoveryStage $manifest 'Restore-TailscaleServeSnapshot' { Restore-TailscaleServeSnapshot -TailscaleExecutable ([string]$manifest.paths.tailscaleExecutable) -Json ([string]$manifest.tailscaleStatusBefore) -ExpectedAfterJson $tailscaleExpectedAfter }
} else {
    if ($gatewayNeedsSnapshot) { throw 'Recovery cannot start the gateway without a transaction-owned Tailscale Serve snapshot.' }
}

if ($gatewayNeedsSnapshot) {
    $snapshotTaskPath = [string]$snapshotTaskSnapshot.TaskPath
    $stoppedSnapshotTask = [pscustomobject]@{ Exists = $true; Enabled = $false; State = 'Stopped'; TaskPath = $snapshotTaskPath }
    Invoke-RecoveryStage $manifest 'Restore-TailscaleSnapshotTask' {
        Restore-TailscaleSnapshotTask -Snapshot $snapshotTaskSnapshot -TaskName $TailscaleSnapshotTaskName -KeepStopped
    } -LiveAction {
        Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshotTask $TailscaleSnapshotTaskName
    } -Postcondition {
        Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshotTask $TailscaleSnapshotTaskName
    }
}

Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure -VerifyHealth -BeforeGatewayStart {
    Invoke-LifeOSBeforeGatewayStart -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath -OutputPath ([string]$manifest.paths.tailscaleSnapshot) -TailscaleExecutable ([string]$manifest.paths.tailscaleExecutable)
}

Stop-DeploymentTaskBarrier $manifest $manifestPath
Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure -VerifyHealth -BeforeGatewayStart {
    Invoke-LifeOSBeforeGatewayStart -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath -OutputPath ([string]$manifest.paths.tailscaleSnapshot) -TailscaleExecutable ([string]$manifest.paths.tailscaleExecutable)
}
Invoke-RecoveryStage $manifest 'Restore-CodexCollectorTask' { Restore-CodexCollectorTask $codexSnapshot $CodexTaskName } -Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState $codexSnapshot $CodexTaskName }
Invoke-RecoveryStage $manifest 'Restore-TailscaleSnapshotTask' { Restore-TailscaleSnapshotTask $snapshotTaskSnapshot $TailscaleSnapshotTaskName } -LiveAction { Restore-TailscaleSnapshotTask $snapshotTaskSnapshot $TailscaleSnapshotTaskName } -Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState $snapshotTaskSnapshot $TailscaleSnapshotTaskName }
Reconcile-LifeOSScheduledTaskSnapshotState $legacySnapshot $LegacyTaskName
Reconcile-LifeOSScheduledTaskSnapshotState $codexSnapshot $CodexTaskName
Reconcile-LifeOSScheduledTaskSnapshotState $snapshotTaskSnapshot $TailscaleSnapshotTaskName
$recoveryArchivePath = Complete-LifeOSRecoveryState $manifest
$rollbackCompleted = $true
Write-Host 'LifeOS Windows rollback completed. Prior task/data/code artifacts were restored or moved to the rollback backup, and captured service state was reconciled.'
} finally {
    Exit-LifeOSDeploymentTransaction $deploymentMutex -Completed:$rollbackCompleted
}
