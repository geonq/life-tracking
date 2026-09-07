[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$TailscaleExecutable,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$TailscaleSnapshotTaskName = 'LifeOSTailscaleSnapshot'
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
    $sidType = Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('qsidtype', $Name))
    if (($sidType.Output -join "`n") -notmatch '(?i)UNRESTRICTED') { throw "Service SID is not unrestricted: $Name" }
    $failure = Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('qfailure', $Name))
    $failureText = $failure.Output -join "`n"
    if ($failureText -notmatch '(?i)RESET_PERIOD.*86400' -or
        ([regex]::Matches($failureText, '(?i)RESTART.*60000')).Count -lt 3 -or
        $failureText -match '(?i)reboot') { throw "SCM recovery policy is not restart-only 60s/60s/60s for $Name" }
}

function Assert-ServiceSidNotAllowed {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$DeniedSid)
    $acl = Get-Acl -LiteralPath $Path
    foreach ($entry in $acl.Access) {
        if ($entry.AccessControlType -ne 'Allow') { continue }
        # Get-Acl commonly renders a virtual service account as
        # `NT SERVICE\\LifeOSGateway`, while Get-ServiceSid returns its
        # canonical S-1-5-80-* SID. Compare identities in SID form or fail
        # closed when Windows cannot translate the ACE.
        try { $entrySid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "ACL identity could not be resolved: $Path" }
        if ($entrySid -eq $DeniedSid) {
            throw "Unexpected cross-service ACL on $Path."
        }
    }
}

function Get-OptionalManifestPath {
    param([Parameter(Mandatory)][psobject]$Paths, [Parameter(Mandatory)][string]$Name)
    # Assert-CanonicalRollbackManifest deliberately keeps the v17 and v18 path
    # keys optional so older manifests stay readable by rollback. Under
    # Set-StrictMode a direct dereference of a missing key throws a raw
    # PropertyNotFoundException instead of a diagnosable message.
    $property = $Paths.PSObject.Properties[$Name]
    if ($null -eq $property) { return '' }
    return [string]$property.Value
}

function Assert-SidHasNoWriteAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Label
    )
    # Assert-NoBroadAcl only rejects well-known broad principals and
    # Assert-RestrictedAcl only validates ACE identities, never rights. Neither
    # would catch a Modify grant to the gateway's own service SID -- the single
    # mistake that would let the gateway rewrite the identity assertion it then
    # reads back and trusts.
    $writeRights = [Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership
    foreach ($entry in (Get-Acl -LiteralPath $Path -ErrorAction Stop).Access) {
        if ($entry.AccessControlType -ne 'Allow') { continue }
        try { $entrySid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "ACL identity could not be resolved: $Path" }
        if ($entrySid -ne $Sid) { continue }
        if (([int]$entry.FileSystemRights -band [int]$writeRights) -ne 0) {
            throw "$Label must not grant write, delete, or permission-change access to ${Sid}: $Path"
        }
    }
}

function Assert-SidHasNoAllowAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][string]$Label
    )
    # Assert-ServiceSidNotAllowed compares IdentityReference.Value, which is
    # the resolved account name for a virtual service account and therefore
    # never equals the SID string passed to it. Translate before comparing so
    # this assertion actually fires.
    foreach ($entry in (Get-Acl -LiteralPath $Path -ErrorAction Stop).Access) {
        if ($entry.AccessControlType -ne 'Allow') { continue }
        try { $entrySid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "ACL identity could not be resolved: $Path" }
        if ($entrySid -eq $Sid) { throw "$Label must not grant any access to ${Sid}: $Path" }
    }
}

function Resolve-TaskPrincipalSid {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Value)
    # Get-ScheduledTask normalizes well-known principals, so a correctly
    # installed task can report SYSTEM or NT AUTHORITY\SYSTEM rather than the
    # SID that was registered. Resolve instead of string-matching.
    if ([string]::IsNullOrWhiteSpace($Value)) { return '' }
    try {
        if ($Value -match '\AS-1-[0-9-]+\z') { return ([Security.Principal.SecurityIdentifier]$Value).Value }
        return (New-Object Security.Principal.NTAccount($Value)).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { return '' }
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
$stateDirectory = Get-OptionalManifestPath $manifest.paths 'stateDirectory'
$tailscaleSnapshot = Get-OptionalManifestPath $manifest.paths 'tailscaleSnapshot'
$tailscaleSnapshotScript = Get-OptionalManifestPath $manifest.paths 'tailscaleSnapshotScript'
$manifestTailscale = Get-OptionalManifestPath $manifest.paths 'tailscaleExecutable'
# A pre-v18 manifest carries none of these keys. Verification of the snapshot
# boundary is skipped loudly rather than crashing on a missing property.
$hasSnapshotContract = -not (
    [string]::IsNullOrWhiteSpace($stateDirectory) -or [string]::IsNullOrWhiteSpace($tailscaleSnapshot) -or
    [string]::IsNullOrWhiteSpace($tailscaleSnapshotScript) -or [string]::IsNullOrWhiteSpace($manifestTailscale))

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
if ($hasSnapshotContract) {
    Assert-ExistingDirectory $stateDirectory 'Tailscale snapshot state directory'
    Assert-ExistingFile $tailscaleSnapshotScript 'Staged Tailscale snapshot script'
}
Assert-PathOnlyJson $apiConfig
Assert-PathOnlyJson $gatewayConfig
Assert-PathOnlyJson $gatewayAppConfig

Set-StrictMode -Version Latest
$apiAccount = Get-ServiceAccountName 'LifeOSAPI'
$gatewayAccount = Get-ServiceAccountName 'LifeOSGateway'
Assert-ServiceContract 'LifeOSAPI' $apiAccount $hostBinary @() 'auto'
# `Schedule` is asserted because the gateway refuses to start on a snapshot
# older than 90 seconds and must not outrace the SYSTEM task that writes it.
Assert-ServiceContract 'LifeOSGateway' $gatewayAccount $hostBinary @('LifeOSAPI', $TailscaleServiceName, 'Schedule') 'delayed-auto'
$apiSid = Get-ServiceSid 'LifeOSAPI'
$gatewaySid = Get-ServiceSid 'LifeOSGateway'
Assert-ServiceSidNotAllowed ([string]$manifest.paths.api) $gatewaySid
Assert-ServiceSidNotAllowed ([string]$manifest.paths.gateway) $apiSid
Assert-ServiceSidNotAllowed ([string]$manifest.paths.apiData) $gatewaySid
Assert-ServiceSidNotAllowed ([string]$manifest.paths.gatewayData) $apiSid
Assert-ServiceSidNotAllowed $codexSecret $gatewaySid

$broadAclPaths = @($configDirectory, $claudeSecret, $codexSecret, $apiData, $gatewayData, $apiLogs, $gatewayLogs)
if ($hasSnapshotContract) { $broadAclPaths += $stateDirectory }
foreach ($path in $broadAclPaths) {
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

# The gateway service account cannot query Tailscale, so the SYSTEM snapshot
# task is part of the running security boundary: assert its principal, the
# exact action it runs, the integrity of the script it runs, the ACLs that keep
# the gateway out of the writer role, and that the published file is still
# fresh and exact.
if ($hasSnapshotContract) {
    Assert-SafeTaskName $TailscaleSnapshotTaskName
    $snapshotTasks = @(Get-ScheduledTask -TaskName $TailscaleSnapshotTaskName -ErrorAction SilentlyContinue)
    if ($snapshotTasks.Count -ne 1) { throw "The Tailscale snapshot task is missing or ambiguous: $TailscaleSnapshotTaskName" }
    $snapshotTask = $snapshotTasks[0]
    if ([string]$snapshotTask.State -eq 'Disabled') { throw "The Tailscale snapshot task is disabled: $TailscaleSnapshotTaskName" }
    $snapshotPrincipal = [string]$snapshotTask.Principal.UserId
    if ((Resolve-TaskPrincipalSid $snapshotPrincipal) -ne 'S-1-5-18' -and
        $snapshotPrincipal -notin @('S-1-5-18', 'SYSTEM', 'NT AUTHORITY\SYSTEM')) {
        throw 'The Tailscale snapshot task does not run as SYSTEM.'
    }
    if ([string]$snapshotTask.Principal.LogonType -ne 'ServiceAccount') {
        throw 'The Tailscale snapshot task does not run as the SYSTEM service account.'
    }
    $snapshotTaskPath = [string]$snapshotTask.TaskPath
    if ([string]::IsNullOrWhiteSpace($snapshotTaskPath)) { $snapshotTaskPath = '\' }
    Assert-TailscaleSnapshotTaskAction -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath -ScriptPath $tailscaleSnapshotScript -TailscaleExecutable $manifestTailscale -OutputPath $tailscaleSnapshot
    # SYSTEM executes the staged script with -ExecutionPolicy Bypass every 60
    # seconds, which makes it the highest-value persistence target on the box.
    # Hash it against the reviewed source that shipped in this bundle.
    $reviewedSnapshotScript = Join-Path $PSScriptRoot 'tailscale_snapshot.ps1'
    Assert-ExistingFile $reviewedSnapshotScript 'Reviewed Tailscale snapshot script'
    if ((Get-FileSha256 $tailscaleSnapshotScript) -ne (Get-FileSha256 $reviewedSnapshotScript)) {
        throw 'The staged Tailscale snapshot script does not match the reviewed source.'
    }
    # The gateway must be able to read this state and nothing more; the API
    # service has no business here at all.
    Assert-ExistingFile $tailscaleSnapshot 'Tailscale snapshot'
    Assert-SidHasNoWriteAcl -Path $stateDirectory -Sid $gatewaySid -Label 'The Tailscale snapshot state directory'
    Assert-SidHasNoWriteAcl -Path $tailscaleSnapshot -Sid $gatewaySid -Label 'The Tailscale snapshot file'
    Assert-SidHasNoWriteAcl -Path $tailscaleSnapshotScript -Sid $gatewaySid -Label 'The staged Tailscale snapshot script'
    Assert-SidHasNoAllowAcl -Path $stateDirectory -Sid $apiSid -Label 'The Tailscale snapshot state directory'
    Assert-SidHasNoAllowAcl -Path $tailscaleSnapshot -Sid $apiSid -Label 'The Tailscale snapshot file'
    # A transient non-zero result -- 0x41306 for an ExecutionTimeLimit stop, for
    # instance -- is not a failure when the file below is fresh and exact, and
    # that file check is the real verdict. LastTaskResult is a uint32, so the
    # cast must be [long] or an HRESULT overflows Int32.
    $snapshotInfo = Get-ScheduledTaskInfo -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath -ErrorAction Stop
    if ([long]$snapshotInfo.LastTaskResult -ne 0) {
        Write-Warning ('The Tailscale snapshot task last reported result {0}; the published snapshot is validated below.' -f $snapshotInfo.LastTaskResult)
    }
    $tailscaleIdentity = Get-TailscaleIdentityFacts $tailscale
    Assert-TailscaleSnapshotFile -Path $tailscaleSnapshot -ExpectedDnsName $tailscaleIdentity.DnsName -ExpectedLoginName $tailscaleIdentity.LoginName
} else {
    Write-Warning 'This manifest predates the SYSTEM Tailscale snapshot; its task, ACL, and freshness checks were skipped.'
}
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8787/health') 10)) { throw 'LifeOSAPI health check failed.' }
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8421/health') 10)) { throw 'LifeOSGateway health check failed.' }

Write-Host 'LifeOS Windows deployment verification passed.'
Write-Host ("Manifest: {0}" -f $manifestFile)
Write-Host 'Both services use virtual accounts, unrestricted service SIDs, least-privilege ACLs, and restart-only recovery.'
