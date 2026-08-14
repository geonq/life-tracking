[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)][string]$ManifestPath,
    [string]$LegacyTaskName = 'LifeOSSyncServer'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

function Move-CurrentOutOfTheWay {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BackupDirectory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $leaf = [IO.Path]::GetFileName($Path.TrimEnd('\'))
    $destination = Join-Path $BackupDirectory ("rollback-current-{0}-{1}" -f $leaf, [Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $Path -Destination $destination -Force
}

function Restore-Artifact {
    param([Parameter(Mandatory)][psobject]$Artifact, [Parameter(Mandatory)][string]$BackupDirectory)
    $destination = [string]$Artifact.destination
    $backup = [string]$Artifact.backup
    if ([string]::IsNullOrWhiteSpace($destination)) { return }
    if ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup)) {
        Move-CurrentOutOfTheWay $destination $BackupDirectory
        return
    }
    Move-CurrentOutOfTheWay $destination $BackupDirectory
    $parent = Split-Path -Parent $destination
    Ensure-Directory $parent
    Move-Item -LiteralPath $backup -Destination $destination -Force
}

Assert-WindowsAdministrator
Assert-ExistingFile $ManifestPath 'Rollback manifest'
$manifest = Get-Content -LiteralPath $ManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
$backupDirectory = [string]$manifest.paths.backupDirectory
Assert-ExistingDirectory $backupDirectory 'Rollback backup directory'

foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) { Stop-LifeOSService $serviceName }

# Restore only artifacts explicitly recorded by install.ps1.  A current file
# with no prior backup is moved into the rollback directory rather than
# deleted, so recovery remains inspectable and reversible.
foreach ($artifact in @($manifest.backups | Sort-Object -Property kind -Descending)) {
    Restore-Artifact $artifact $backupDirectory
}

$legacySnapshot = [pscustomobject]@{
    Exists = [bool]$manifest.legacyTask.Exists
    Enabled = [bool]$manifest.legacyTask.Enabled
    Xml = $null
}
if ($legacySnapshot.Exists) {
    $taskBackup = [string]$manifest.legacyTask.Backup
    Assert-ExistingFile $taskBackup 'Legacy task backup'
    $legacySnapshot.Xml = Get-Content -LiteralPath $taskBackup -Raw -ErrorAction Stop
}
Restore-LegacyTask $legacySnapshot $LegacyTaskName

foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
    $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
    if ($null -ne $service) {
        Set-Service -Name $serviceName -StartupType Disabled -ErrorAction Stop
    }
}

Write-Warning 'Rollback leaves LifeOSAPI/LifeOSGateway registered but disabled; it never deletes the legacy LifeOSSyncServer task.'
Write-Warning 'The prior Tailscale Serve status was preserved in the install backup; this script does not reset Serve or invoke Funnel because that could affect unrelated routes.'
Write-Host 'LifeOS Windows rollback completed. New service state is disabled and prior task/data/code artifacts were restored or moved to the rollback backup.'
