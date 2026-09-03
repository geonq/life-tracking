Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Shared, side-effect-aware helpers for the LifeOS Windows installer.  The
# defaults intentionally describe machine-owned locations, not user profiles.
$script:LifeOSDefaultPaths = [ordered]@{
    ApiSource       = 'D:\Hermes\lifeos-api'
    GatewaySource   = 'D:\Hermes\lifeos-server'
    InstallRoot     = 'D:\Hermes\lifeos-services'
    RuntimeRoot     = 'D:\Hermes\lifeos-runtime'
    DataRoot        = 'D:\Hermes\lifeos-data'
    SecretRoot      = 'D:\Hermes\lifeos-secrets'
    LogRoot         = 'D:\Hermes\lifeos-logs'
    BackupRoot      = 'D:\Hermes\lifeos-backups'
    ServiceHostPath = 'D:\Hermes\lifeos-services\host\LifeOS.ServiceHost.exe'
}

# This is a public, non-secret Tailscale app-capability name. Tailscale Serve
# forwards the capability assertion in Tailscale-App-Capabilities; the local
# launcher translates a valid assertion into the private gateway header using
# the operator-managed token. The token itself never belongs in Serve flags.
$script:LifeOSTrustedEdgeCapability = 'lifeos.example/trusted-edge'
$script:LifeOSTailscaleEdgeTokenFileName = 'tailscale-edge.token'

function Get-LifeOSDefaultPaths {
    return [ordered]@{
        ApiSource       = $script:LifeOSDefaultPaths.ApiSource
        GatewaySource   = $script:LifeOSDefaultPaths.GatewaySource
        InstallRoot     = $script:LifeOSDefaultPaths.InstallRoot
        RuntimeRoot     = $script:LifeOSDefaultPaths.RuntimeRoot
        DataRoot        = $script:LifeOSDefaultPaths.DataRoot
        SecretRoot      = $script:LifeOSDefaultPaths.SecretRoot
        LogRoot         = $script:LifeOSDefaultPaths.LogRoot
        BackupRoot      = $script:LifeOSDefaultPaths.BackupRoot
        ServiceHostPath = $script:LifeOSDefaultPaths.ServiceHostPath
    }
}

function Get-LifeOSTrustedEdgeCapability {
    return $script:LifeOSTrustedEdgeCapability
}

function Get-LifeOSTailscaleEdgeTokenPath {
    param([Parameter(Mandatory)][string]$SecretRoot)
    return (Join-Path $SecretRoot $script:LifeOSTailscaleEdgeTokenFileName)
}

function Assert-WindowsAdministrator {
    $windowsHost = ($PSVersionTable.PSEdition -eq 'Desktop') -or ($env:OS -eq 'Windows_NT')
    if (-not $windowsHost) {
        throw 'This deployment must run in Windows PowerShell or PowerShell 7 on Windows.'
    }
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'An elevated Administrator PowerShell is required.'
    }
}

function Assert-SafeAbsolutePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.IndexOf([char]0) -ge 0 -or
        -not [IO.Path]::IsPathRooted($Path) -or $Path.Contains("`r") -or $Path.Contains("`n")) {
        throw "$Name must be a rooted path without control characters."
    }
}

function Get-FullPath {
    param([Parameter(Mandatory)][string]$Path)
    Assert-SafeAbsolutePath -Path $Path -Name 'Path'
    return [IO.Path]::GetFullPath($Path)
}

function Normalize-WindowsAbsolutePath {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-FullPath $Path
    $normalized = $full.Replace('/', '\')
    if ($normalized.Length -gt 3) { $normalized = $normalized.TrimEnd('\') }
    return $normalized
}

function Assert-NoReparsePath {
    param([Parameter(Mandatory)][string]$Path, [switch]$AllowMissingLeaf)
    $full = Get-FullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { throw "Path root is invalid: $Path" }
    # Keep the separator on a drive root.  "C:" is drive-relative in
    # Windows, while "C:\" remains rooted when Join-Path adds a segment.
    $current = $root
    $remainder = $full.Substring($root.Length)
    foreach ($segment in ($remainder -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            if ($AllowMissingLeaf) { continue }
            throw "Path component does not exist: $current"
        }
        $linkType = if ($null -ne $item.PSObject.Properties['LinkType']) { $item.LinkType } else { $null }
        $target = if ($null -ne $item.PSObject.Properties['Target']) { $item.Target } else { $null }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $null -ne $linkType -or $null -ne $target) {
            throw "Reparse points and symbolic links are not permitted: $current"
        }
    }
}

function Assert-ExistingDirectory {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Assert-SafeAbsolutePath $Path $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "$Name does not exist: $Path" }
    Assert-NoReparsePath $Path
}

function Assert-ExistingFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    Assert-SafeAbsolutePath $Path $Name
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "$Name does not exist: $Path" }
    Assert-NoReparsePath $Path
}

function Assert-TailscaleEdgeTokenBytes {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $bytes = [IO.File]::ReadAllBytes($Path)
    } catch {
        throw 'LIFEOS_TAILSCALE_EDGE_TOKEN source could not be read; the operator-managed token value was not displayed.'
    }
    if ($bytes.Length -lt 32 -or $bytes.Length -gt 256) {
        throw 'LIFEOS_TAILSCALE_EDGE_TOKEN source is invalid; expected 32-256 printable ASCII bytes with no newline. The token value was not displayed.'
    }
    foreach ($byte in $bytes) {
        if ([int]$byte -lt 0x21 -or [int]$byte -gt 0x7e) {
            throw 'LIFEOS_TAILSCALE_EDGE_TOKEN source is invalid; expected printable ASCII bytes with no newline. The token value was not displayed.'
        }
    }
}

function Assert-TailscaleEdgeTokenSource {
    param(
        [string]$Path,
        [Parameter(Mandatory)][string]$ExpectedPath,
        [Parameter(Mandatory)][string]$OperatorSid
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'LIFEOS_TAILSCALE_EDGE_TOKEN is required: pass -TailscaleEdgeTokenSource for the pre-created operator-managed token file. The installer never generates, copies, logs, or serializes the token.'
    }
    Assert-SafeAbsolutePath $Path 'LIFEOS_TAILSCALE_EDGE_TOKEN source'
    $full = Get-FullPath $Path
    $expected = Get-FullPath $ExpectedPath
    if ($full -ne $expected) {
        throw "LIFEOS_TAILSCALE_EDGE_TOKEN source must be the pre-created operator-managed file $expected; pass its path with -TailscaleEdgeTokenSource. The token value is never accepted as a parameter."
    }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "LIFEOS_TAILSCALE_EDGE_TOKEN source file is missing: $full. Create the operator-managed token file before preflight; the token value was not displayed."
    }
    Assert-ExistingFile $full 'LIFEOS_TAILSCALE_EDGE_TOKEN source'
    Assert-TrustedSourcePath $full $OperatorSid
    Assert-TailscaleEdgeTokenBytes $full
    return $full
}

function Test-LoopbackAddress {
    param([Parameter(Mandatory)][string]$Address)
    try {
        return [Net.IPAddress]::IsLoopback([Net.IPAddress]::Parse($Address))
    } catch {
        return $false
    }
}

function Assert-CanonicalLegacyListenerManifest {
    param([Parameter(Mandatory)][psobject]$Listener, [Parameter(Mandatory)][psobject]$Manifest)
    $required = @(
        'Exists', 'Port', 'LocalAddresses', 'ProcessId', 'CreationTimeUtc',
        'ExecutablePath', 'ExecutableSha256', 'MainPath', 'MainSha256',
        'LauncherPath', 'LauncherSha256', 'TaskName', 'TaskPath',
        'TaskState', 'TaskEnabled', 'TaskMutated', 'Stopped'
    )
    $optional = @(
        'ParentProcessId', 'ParentCreationTimeUtc', 'ParentExecutablePath',
        'ParentExecutableSha256', 'ParentMainPath', 'ParentMainSha256',
        'RuntimeRelationship', 'ChainDepth'
    )
    $allowed = $required + $optional
    $actual = @($Listener.PSObject.Properties.Name)
    if (@($required | Where-Object { $_ -notin $actual }).Count -ne 0 -or
        @($actual | Where-Object { $_ -notin $allowed }).Count -ne 0) {
        throw 'Legacy listener manifest fields are not canonical.'
    }
    $chainProperties = @($actual | Where-Object { $_ -in $optional })
    if ($chainProperties.Count -ne 0 -and $chainProperties.Count -ne $optional.Count) {
        throw 'Legacy listener chain identity fields must be complete when present.'
    }
    $hasChainMetadata = $chainProperties.Count -eq $optional.Count
    foreach ($booleanField in @('Exists', 'TaskEnabled', 'TaskMutated', 'Stopped')) {
        if ($Listener.PSObject.Properties[$booleanField].Value -isnot [bool]) { throw "Legacy listener manifest field is not boolean: $booleanField" }
    }
    if ([int]$Listener.Port -ne 8421) { throw 'Legacy listener manifest is not bound to port 8421.' }
    if ([string]$Listener.TaskName -ne [string]$Manifest.legacyTask.Name -or
        [string]$Listener.TaskPath -ne [string]$Manifest.legacyTask.TaskPath) {
        throw 'Legacy listener manifest is not bound to the canonical legacy task.'
    }
    foreach ($address in @($Listener.LocalAddresses)) {
        if (-not (Test-LoopbackAddress ([string]$address))) { throw 'Legacy listener manifest contains a non-loopback address.' }
    }
    if (-not [bool]$Listener.Exists) {
        if (@($Listener.LocalAddresses).Count -ne 0 -or [int]$Listener.ProcessId -ne 0 -or
            -not [string]::IsNullOrEmpty([string]$Listener.CreationTimeUtc) -or
            -not [string]::IsNullOrEmpty([string]$Listener.ExecutablePath) -or
            -not [string]::IsNullOrEmpty([string]$Listener.ExecutableSha256) -or
            -not [string]::IsNullOrEmpty([string]$Listener.MainPath) -or
            -not [string]::IsNullOrEmpty([string]$Listener.MainSha256) -or
            -not [string]::IsNullOrEmpty([string]$Listener.LauncherPath) -or
            -not [string]::IsNullOrEmpty([string]$Listener.LauncherSha256) -or
            ($hasChainMetadata -and (
                [int]$Listener.ParentProcessId -ne 0 -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentCreationTimeUtc) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentExecutablePath) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentExecutableSha256) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentMainPath) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentMainSha256) -or
                -not [string]::IsNullOrEmpty([string]$Listener.RuntimeRelationship) -or
                [int]$Listener.ChainDepth -ne 0
            )) -or
            [bool]$Listener.Stopped) {
            throw 'Absent legacy listener manifest contains process identity or stop state.'
        }
        return
    }
    if ([int]$Listener.ProcessId -le 0 -or @($Listener.LocalAddresses).Count -eq 0 -or
        [string]::IsNullOrWhiteSpace([string]$Listener.CreationTimeUtc) -or
        [string]$Listener.ExecutableSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]$Listener.MainSha256 -notmatch '^[0-9a-f]{64}$' -or
        [string]::IsNullOrWhiteSpace([string]$Listener.ExecutablePath) -or
        [string]::IsNullOrWhiteSpace([string]$Listener.MainPath)) {
        throw 'Present legacy listener manifest lacks verified process identity.'
    }
    try { $null = [DateTimeOffset]::Parse([string]$Listener.CreationTimeUtc) } catch { throw 'Legacy listener creation time is invalid.' }
    foreach ($pathRecord in @(
        [pscustomobject]@{ Path = [string]$Listener.ExecutablePath; Hash = [string]$Listener.ExecutableSha256; Name = 'Legacy listener executable' }
        [pscustomobject]@{ Path = [string]$Listener.MainPath; Hash = [string]$Listener.MainSha256; Name = 'Legacy gateway main.py' })) {
        Assert-ExistingFile $pathRecord.Path $pathRecord.Name
        if ((Get-FileSha256 $pathRecord.Path) -ne $pathRecord.Hash) { throw "$($pathRecord.Name) no longer matches the authenticated listener manifest." }
    }
    if ([string]::IsNullOrWhiteSpace([string]$Listener.LauncherPath)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$Listener.LauncherSha256)) { throw 'Legacy launcher hash is present without a launcher path.' }
    } else {
        if ([string]$Listener.LauncherSha256 -notmatch '^[0-9a-f]{64}$') { throw 'Legacy launcher hash is invalid.' }
        Assert-ExistingFile ([string]$Listener.LauncherPath) 'Legacy gateway launcher'
        if ((Get-FileSha256 ([string]$Listener.LauncherPath)) -ne [string]$Listener.LauncherSha256) { throw 'Legacy gateway launcher no longer matches the authenticated listener manifest.' }
    }
    if ($hasChainMetadata) {
        $relationship = [string]$Listener.RuntimeRelationship
        if ($relationship -notin @('', 'pyvenv-base-redirector')) {
            throw 'Legacy listener runtime relationship is not canonical.'
        }
        if ([string]::IsNullOrWhiteSpace($relationship)) {
            if ([int]$Listener.ParentProcessId -ne 0 -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentCreationTimeUtc) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentExecutablePath) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentExecutableSha256) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentMainPath) -or
                -not [string]::IsNullOrEmpty([string]$Listener.ParentMainSha256) -or
                [int]$Listener.ChainDepth -ne 0) {
                throw 'Direct legacy listener manifests cannot carry parent identity.'
            }
        } else {
            if ([int]$Listener.ParentProcessId -le 0 -or
                [int]$Listener.ChainDepth -ne 1 -or
                [string]::IsNullOrWhiteSpace([string]$Listener.ParentCreationTimeUtc) -or
                [string]$Listener.ParentExecutableSha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]$Listener.ParentMainSha256 -notmatch '^[0-9a-f]{64}$' -or
                [string]::IsNullOrWhiteSpace([string]$Listener.ParentExecutablePath) -or
                [string]::IsNullOrWhiteSpace([string]$Listener.ParentMainPath)) {
                throw 'Redirector listener manifests lack verified parent identity.'
            }
            try { $null = [DateTimeOffset]::Parse([string]$Listener.ParentCreationTimeUtc) } catch { throw 'Legacy listener parent creation time is invalid.' }
            $expectedVenvRuntime = Normalize-WindowsAbsolutePath (Join-Path $script:LifeOSDefaultPaths.GatewaySource 'venv\Scripts\python.exe')
            if ([string]$Listener.ParentExecutablePath -ine $expectedVenvRuntime) {
                throw 'Redirector listener parent is not the exact approved venv runtime.'
            }
            $relationshipProof = Get-PythonVenvBaseRelationship -VenvRuntimePath $expectedVenvRuntime
            if ([string]$Listener.ExecutablePath -ine [string]$relationshipProof.BaseExecutable) {
                throw 'Redirector listener executable is not the pyvenv base interpreter.'
            }
            if ([string]$Listener.ParentMainPath -ine [string]$Listener.MainPath) {
                throw 'Redirector listener parent and child do not identify the same main.py.'
            }
            foreach ($pathRecord in @(
                [pscustomobject]@{ Path = [string]$Listener.ParentExecutablePath; Hash = [string]$Listener.ParentExecutableSha256; Name = 'Legacy listener parent executable' }
                [pscustomobject]@{ Path = [string]$Listener.ParentMainPath; Hash = [string]$Listener.ParentMainSha256; Name = 'Legacy listener parent main.py' })) {
                Assert-ExistingFile $pathRecord.Path $pathRecord.Name
                if ((Get-FileSha256 $pathRecord.Path) -ne $pathRecord.Hash) { throw "$($pathRecord.Name) no longer matches the authenticated listener manifest." }
            }
        }
    }
}

function Assert-CanonicalRollbackManifest {
    param([Parameter(Mandatory)][psobject]$Manifest, [Parameter(Mandatory)][string]$ManifestPath)
    $required = @('schemaVersion', 'createdAt', 'operatorSid', 'legacyTask', 'codexTask', 'serviceSnapshots', 'services', 'paths', 'backups', 'aclSnapshots', 'tailscaleStatusBefore')
    $optional = @('apiServiceSid', 'gatewayServiceSid', 'supplementCatalogInitialized', 'tailscaleStatusAfter', 'cutoverCompletedAt', 'legacyListener')
    $actual = @($Manifest.PSObject.Properties.Name | Sort-Object)
    $unknown = @($actual | Where-Object { $_ -notin ($required + $optional) })
    $missing = @($required | Where-Object { $_ -notin $actual })
    if ($unknown.Count -ne 0 -or $missing.Count -ne 0) {
        throw 'Rollback manifest fields are not the canonical install schema.'
    }
    if ([int]$Manifest.schemaVersion -ne 2) {
        throw 'Only schemaVersion 2 rollback manifests are accepted automatically; older schemas require operator-led recovery.'
    }
    Assert-ExistingFile $ManifestPath 'Rollback manifest'
    $defaults = Get-LifeOSDefaultPaths
    $backupDirectory = Get-FullPath ([string]$Manifest.paths.backupDirectory)
    $backupRoot = (Get-FullPath $defaults.BackupRoot).TrimEnd('\')
    if (-not $backupDirectory.StartsWith($backupRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($backupDirectory) -notmatch '^install-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$') {
        throw 'Rollback backup directory is outside the canonical install backup root.'
    }
    $manifestFull = Get-FullPath $ManifestPath
    if ($manifestFull -ne (Join-Path $backupDirectory 'manifest.json')) {
        throw 'Rollback manifest must be the manifest.json inside its own install backup directory.'
    }
    if ([string]$Manifest.operatorSid -notmatch '^S-1-[0-9-]+$') { throw 'Rollback operator SID is invalid.' }
    foreach ($taskRecord in @(
        [pscustomobject]@{ Name = 'legacyTask'; Value = $Manifest.legacyTask }
        [pscustomobject]@{ Name = 'codexTask'; Value = $Manifest.codexTask })) {
        if ($null -eq $taskRecord.Value -or $null -eq $taskRecord.Value.PSObject.Properties['Name']) {
            throw "Rollback manifest is missing the bound $($taskRecord.Name) name."
        }
        Assert-SafeTaskName ([string]$taskRecord.Value.Name)
        if ($null -eq $taskRecord.Value.PSObject.Properties['TaskPath']) {
            throw "Rollback manifest is missing the bound $($taskRecord.Name) path."
        }
        Assert-SafeTaskPath ([string]$taskRecord.Value.TaskPath)
    }
    $paths = $Manifest.paths
    $expected = [ordered]@{
        host = (Join-Path $defaults.InstallRoot 'host\LifeOS.ServiceHost.exe')
        api = (Join-Path $defaults.InstallRoot 'api')
        gateway = (Join-Path $defaults.InstallRoot 'gateway')
        node = (Join-Path $defaults.RuntimeRoot 'node')
        pythonBase = (Join-Path $defaults.RuntimeRoot 'python312')
        pythonVenv = (Join-Path $defaults.RuntimeRoot 'python-venv')
        installRoot = $defaults.InstallRoot
        runtimeRoot = $defaults.RuntimeRoot
        dataRoot = $defaults.DataRoot
        logRoot = $defaults.LogRoot
        hostDirectory = (Join-Path $defaults.InstallRoot 'host')
        apiTemp = (Join-Path $defaults.DataRoot 'api\tmp')
        gatewayTemp = (Join-Path $defaults.DataRoot 'gateway\tmp')
        gatewayDocuments = (Join-Path $defaults.DataRoot 'gateway\documents')
        apiData = (Join-Path $defaults.DataRoot 'api')
        gatewayData = (Join-Path $defaults.DataRoot 'gateway')
        apiLogs = (Join-Path $defaults.LogRoot 'api')
        gatewayLogs = (Join-Path $defaults.LogRoot 'gateway')
        secretRoot = $defaults.SecretRoot
        claudeSecret = (Join-Path $defaults.SecretRoot 'claude-ingest.secret')
        codexSecret = (Join-Path $defaults.SecretRoot 'codex-ingest.secret')
        clipperSecret = (Join-Path $defaults.SecretRoot 'clipper-ingest.secret')
        googleAIStudioApiKey = (Join-Path $defaults.SecretRoot 'google-ai-studio.key')
        enableBankingPrivateKey = (Join-Path $defaults.SecretRoot 'enable-banking.private-key')
        enableBankingCertificate = (Join-Path $defaults.SecretRoot 'enable-banking.certificate')
        usageHistory = (Join-Path $defaults.DataRoot 'api\usage-history.jsonl')
        supplementCatalog = (Join-Path $defaults.DataRoot 'gateway\supplements.sqlite3')
        configDirectory = (Join-Path $defaults.InstallRoot 'host\config')
        apiConfig = (Join-Path $defaults.InstallRoot 'host\config\LifeOSAPI.json')
        gatewayConfig = (Join-Path $defaults.InstallRoot 'host\config\LifeOSGateway.json')
        gatewayAppConfig = (Join-Path $defaults.InstallRoot 'host\config\gateway.app.json')
    }
    # v17 adds only a canonical path reference for the operator-managed edge
    # token.  Keep it optional when reading older v2 manifests so rollback
    # remains compatible, while rejecting every non-canonical path.
    $optionalExpected = [ordered]@{
        tailscaleEdgeToken = (Get-LifeOSTailscaleEdgeTokenPath $defaults.SecretRoot)
    }
    $pathAllowed = @($expected.Keys) + @($optionalExpected.Keys) + @('backupDirectory', 'tailscaleExecutable')
    $pathActual = @($paths.PSObject.Properties.Name)
    if (@($pathActual | Where-Object { $_ -notin $pathAllowed }).Count -ne 0 -or
        @($expected.Keys | Where-Object { $_ -notin $pathActual }).Count -ne 0 -or
        'backupDirectory' -notin $pathActual -or 'tailscaleExecutable' -notin $pathActual) {
        throw 'Rollback manifest paths are not the canonical install schema.'
    }
    foreach ($property in $expected.Keys) {
        $actualPath = Get-FullPath ([string]$paths.$property)
        if ($actualPath -ne (Get-FullPath ([string]$expected[$property]))) {
            throw "Rollback manifest path is not canonical: $property"
        }
    }
    foreach ($property in $optionalExpected.Keys) {
        if ($property -notin $pathActual) { continue }
        $actualPath = Get-FullPath ([string]$paths.$property)
        if ($actualPath -ne (Get-FullPath ([string]$optionalExpected[$property]))) {
            throw "Rollback manifest path is not canonical: $property"
        }
    }
    $backupPath = Get-FullPath ([string]$paths.backupDirectory)
    if ($backupPath -ne $backupDirectory) { throw 'Rollback manifest backupDirectory does not match its containing directory.' }
    $tailscale = Get-FullPath ([string]$paths.tailscaleExecutable)
    $trustedTailscale = @(
        (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tailscale\tailscale.exe'),
        (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Tailscale\tailscale.exe')) |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Get-FullPath $_ }
    if ($tailscale -notin $trustedTailscale) { throw 'Rollback Tailscale executable is not a trusted installed path.' }
    Assert-ExistingFile $tailscale 'Rollback Tailscale executable'
    if ($null -ne $Manifest.PSObject.Properties['legacyListener']) {
        Assert-CanonicalLegacyListenerManifest -Listener $Manifest.legacyListener -Manifest $Manifest
    }
    $backupPrefix = $backupDirectory.TrimEnd('\') + '\'
    Assert-AuthenticatedBackup -Manifest $Manifest -ManifestPath $ManifestPath -BackupDirectory $backupDirectory
    foreach ($taskRecord in @(
        [pscustomobject]@{ Name = 'LifeOSSyncServer'; Value = $Manifest.legacyTask },
        [pscustomobject]@{ Name = 'LifeOSCodexCollector'; Value = $Manifest.codexTask })) {
        $task = $taskRecord.Value
        Assert-SafeTaskName $taskRecord.Name
        Assert-SafeTaskPath ([string]$task.TaskPath)
        if ([bool]$task.Exists) {
            $taskBackup = Get-FullPath ([string]$task.Backup)
            if (-not $taskBackup.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase) -or
                [IO.Path]::GetExtension($taskBackup) -ne '.xml') { throw 'Rollback task backup escapes its install backup directory.' }
            Assert-ExistingFile $taskBackup 'Rollback task backup'
        }
    }
    $canonicalArtifactDestinations = @($expected.Values | ForEach-Object { Get-FullPath ([string]$_) }) + @(
        (Get-FullPath (Join-Path ([string]$expected['gatewayData']) 'calendar.json')),
        (Get-FullPath (Join-Path ([string]$expected['gatewayData']) 'enablebanking-connections.json')),
        (Get-FullPath (Join-Path ([string]$expected['gatewayData']) 'finance-summary.json'))
    )
    foreach ($item in @($Manifest.backups)) {
        foreach ($field in @('destination', 'backup')) {
            $value = [string]$item.$field
            if ([string]::IsNullOrWhiteSpace($value)) { continue }
            $full = Get-FullPath $value
            if ($field -eq 'backup') {
                if (-not $full.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Rollback artifact backup escapes its install backup directory.' }
            } elseif ($full -notin $canonicalArtifactDestinations) {
                throw 'Rollback artifact destination is not one of the canonical LifeOS destinations.'
            }
        }
        if ($item.PSObject.Properties['priorExists'] -eq $null -or $item.PSObject.Properties['changed'] -eq $null -or
            $item.PSObject.Properties['phase'] -eq $null -or [string]$item.phase -ne 'complete') {
            throw 'Rollback artifact intent is incomplete.'
        }
    }
    foreach ($snapshot in @($Manifest.aclSnapshots)) {
        if ($snapshot.PSObject.Properties['destination'] -eq $null -or $snapshot.PSObject.Properties['backup'] -eq $null -or
            $snapshot.PSObject.Properties['mode'] -eq $null -or [string]$snapshot.mode -notin @('sddl', 'tree')) {
            throw 'Rollback ACL snapshot is incomplete.'
        }
        $destination = Get-FullPath ([string]$snapshot.destination)
        $canonicalAclDestinations = @($expected.Values | ForEach-Object { Get-FullPath ([string]$_) })
        foreach ($property in $optionalExpected.Keys) {
            if ($property -in $pathActual) { $canonicalAclDestinations += Get-FullPath ([string]$optionalExpected[$property]) }
        }
        if (-not $canonicalAclDestinations.Contains($destination)) {
            throw 'Rollback ACL snapshot destination is not canonical.'
        }
        $snapshotBackup = Get-FullPath ([string]$snapshot.backup)
        $expectedExtension = if ([string]$snapshot.mode -eq 'tree') { '.acl' } else { '.sddl' }
        if (-not $snapshotBackup.StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetExtension($snapshotBackup) -ne $expectedExtension) { throw 'Rollback ACL snapshot escapes its install backup directory.' }
        Assert-ExistingFile $snapshotBackup 'Rollback ACL snapshot'
    }
}

function Assert-TrustedSourcePath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid)
    Assert-NoReparsePath $Path
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    try { $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value } catch { throw "Could not resolve source owner: $Path" }
    if ($ownerSid -ne $OperatorSid -and $ownerSid -ne 'S-1-5-32-544') { throw "Source is not operator/admin-owned: $Path" }
    foreach ($entry in $acl.Access) {
        $name = [string]$entry.IdentityReference.Value
        if ($entry.AccessControlType -eq 'Allow' -and $name -match '(?i)(Everyone|\\Users$|Authenticated Users|INTERACTIVE)' -and
            (($entry.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -ne 0 -or
             ($entry.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Modify) -ne 0 -or
             ($entry.FileSystemRights -band [Security.AccessControl.FileSystemRights]::FullControl) -ne 0)) {
            throw "Source has a broad write ACL: $Path"
        }
    }
}

function Ensure-Directory {
    param([Parameter(Mandatory)][string]$Path)
    Assert-SafeAbsolutePath $Path 'Directory'
    if (Test-Path -LiteralPath $Path -PathType Leaf) { throw "A file occupies the directory path: $Path" }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
    Assert-NoReparsePath $Path
}

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [switch]$AllowNonZero,
        [switch]$Quiet
    )
    # The deployment suites use a PowerShell fake for native tools. A script
    # that returns normally does not overwrite LASTEXITCODE, so a non-zero
    # value left by an earlier native command must not turn that script into a
    # false failure. Clear the value only for .ps1 invocation, then restore
    # the caller's value after observing the script result.
    $isPowerShellScript = [IO.Path]::GetExtension($FilePath) -ieq '.ps1'
    $previousLocalLastExitCode = Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue
    $previousCallerLastExitCode = Get-Variable -Name LASTEXITCODE -Scope 1 -ErrorAction SilentlyContinue
    $previousGlobalLastExitCode = Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue
    $hadLocalLastExitCode = $null -ne $previousLocalLastExitCode
    $hadCallerLastExitCode = $null -ne $previousCallerLastExitCode
    $hadGlobalLastExitCode = $null -ne $previousGlobalLastExitCode
    $localLastExitCodeValue = if ($hadLocalLastExitCode) { [int]$previousLocalLastExitCode.Value } else { 0 }
    $callerLastExitCodeValue = if ($hadCallerLastExitCode) { [int]$previousCallerLastExitCode.Value } else { 0 }
    $globalLastExitCodeValue = if ($hadGlobalLastExitCode) { [int]$previousGlobalLastExitCode.Value } else { 0 }
    if ($isPowerShellScript) {
        if ($hadLocalLastExitCode) { Set-Variable -Name LASTEXITCODE -Value 0 -Scope 0 }
        if ($hadCallerLastExitCode) { Set-Variable -Name LASTEXITCODE -Value 0 -Scope 1 }
        $global:LASTEXITCODE = 0
    }
    try {
        $output = & $FilePath @ArgumentList 2>&1
        # PowerShell scripts do not necessarily initialize LASTEXITCODE. Read
        # the automatic variable through the provider so StrictMode does not
        # turn a successful script invocation into an unbound-variable
        # failure. A present value still goes through the normal integer
        # conversion and non-zero failure path below.
        if ($isPowerShellScript) {
            $observedExitCodes = @(
                (Get-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue)
                (Get-Variable -Name LASTEXITCODE -Scope 1 -ErrorAction SilentlyContinue)
                (Get-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue)
            )
            $exitCode = 0
            foreach ($observedExitCode in $observedExitCodes) {
                if ($null -ne $observedExitCode -and [int]$observedExitCode.Value -ne 0) {
                    $exitCode = [int]$observedExitCode.Value
                    break
                }
            }
        } else {
            $lastExitCodeVariable = Get-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
            $exitCode = if ($null -eq $lastExitCodeVariable) { 0 } else { [int]$lastExitCodeVariable.Value }
        }
    } finally {
        if ($isPowerShellScript) {
            if ($hadLocalLastExitCode) { Set-Variable -Name LASTEXITCODE -Value $localLastExitCodeValue -Scope 0 }
            else { Remove-Variable -Name LASTEXITCODE -Scope 0 -ErrorAction SilentlyContinue }
            if ($hadCallerLastExitCode) { Set-Variable -Name LASTEXITCODE -Value $callerLastExitCodeValue -Scope 1 }
            else { Remove-Variable -Name LASTEXITCODE -Scope 1 -ErrorAction SilentlyContinue }
            if ($hadGlobalLastExitCode) { Set-Variable -Name LASTEXITCODE -Value $globalLastExitCodeValue -Scope Global }
            else { Remove-Variable -Name LASTEXITCODE -Scope Global -ErrorAction SilentlyContinue }
        }
    }
    if (-not $AllowNonZero -and $exitCode -ne 0) {
        throw "Native command failed ($FilePath, exit code $exitCode)."
    }
    if ($Quiet) { return $exitCode }
    return [pscustomobject]@{ ExitCode = $exitCode; Output = @($output | ForEach-Object { [string]$_ }) }
}

function Get-InteractiveOperatorSid {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $name = [string]$computer.UserName
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '^(NT AUTHORITY|NT SERVICE)\\') {
        throw 'No interactive operator account could be derived from the current Windows session.'
    }
    try {
        return ([Security.Principal.NTAccount]::new($name)).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw 'The current interactive operator account could not be translated to a SID.'
    }
}

function Get-InteractiveOperatorName {
    $computer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
    $name = [string]$computer.UserName
    if ([string]::IsNullOrWhiteSpace($name) -or $name -match '^(NT AUTHORITY|NT SERVICE)\\') { throw 'No interactive operator account was found.' }
    return $name
}

function Get-ServiceSid {
    param([Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9_.-]{1,80}$')][string]$ServiceName)
    $account = "NT SERVICE\$ServiceName"
    try {
        return ([Security.Principal.NTAccount]::new($account)).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch {
        throw "The virtual service account $account is not resolvable. Create the service before provisioning its ACL."
    }
}

function Get-ServiceAccountName {
    param([Parameter(Mandatory)][string]$ServiceName)
    return "NT SERVICE\$ServiceName"
}

function Assert-SafeTaskName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9_.-]{1,80}$') { throw "Unsafe scheduled-task name: $Name" }
}

function Assert-SafeTaskPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 256 -or
        $Path -notmatch '^\\(?:[^\\/:*?"<>|]+\\)*$' -or $Path -match '(?i)(^|\\)\.\.(?:\\|$)') {
        throw "Unsafe scheduled-task path: $Path"
    }
}

function Resolve-NodeRuntimeSource {
    param([string]$Requested, [Parameter(Mandatory)][string]$ApiSource)
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates += $Requested }
    else {
        $candidates += @(
            (Join-Path $ApiSource 'node-runtime'),
            (Join-Path $ApiSource 'node'),
            (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'nodejs'),
            (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'nodejs')
        )
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $path = $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) { $path = Split-Path -Parent $path }
        if ((Test-Path -LiteralPath $path -PathType Container) -and (Test-Path -LiteralPath (Join-Path $path 'node.exe') -PathType Leaf)) {
            Assert-NoReparsePath $path
            return (Get-FullPath $path)
        }
    }
    throw 'An exact Node runtime directory containing node.exe is required; pass -NodeRuntimeSource explicitly.'
}

function Resolve-ApiReleaseRoot {
    param([Parameter(Mandatory)][string]$ApiSource)
    foreach ($candidate in @($ApiSource, (Join-Path $ApiSource 'services\api'))) {
        $dist = Join-Path $candidate 'dist\server.js'
        $package = Join-Path $candidate 'package.json'
        $contracts = Join-Path $candidate '..\..\packages\contracts'
        if ((Test-Path -LiteralPath $dist -PathType Leaf) -and (Test-Path -LiteralPath $package -PathType Leaf)) {
            if (-not (Test-Path -LiteralPath (Join-Path $contracts 'dist') -PathType Container)) {
                $contracts = Join-Path $candidate 'node_modules\@iphone-life-os\contracts'
            }
            if (Test-Path -LiteralPath (Join-Path $contracts 'dist') -PathType Container) {
                return (Get-FullPath $candidate)
            }
        }
    }
    throw 'API source must contain dist/server.js, package.json, and a real contracts/dist tree.'
}

function Resolve-ApiDependencyRoot {
    param([Parameter(Mandatory)][string]$ApiRoot, [Parameter(Mandatory)][string]$Name)
    $candidates = @(
        (Join-Path $ApiRoot ('node_modules\' + $Name)),
        (Join-Path $ApiRoot ('..\..\node_modules\' + $Name)),
        (Join-Path $ApiRoot ('..\..\services\api\node_modules\' + $Name))
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) { Assert-NoReparsePath $candidate; return (Get-FullPath $candidate) }
    }
    throw "Production API dependency was not found: $Name"
}

function Resolve-PythonRuntimeSource {
    param([string]$Requested, [Parameter(Mandatory)][string]$GatewaySource)
    $explicit = -not [string]::IsNullOrWhiteSpace($Requested)
    $candidates = @()
    if ($explicit) { $candidates += $Requested }
    else {
        $candidates += @(
            (Join-Path $GatewaySource '.venv'),
            (Join-Path $GatewaySource 'venv'),
            (Join-Path $GatewaySource 'python312'),
            'C:\Python312',
            (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Python312')
        )
    }
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $candidateFull = Get-FullPath $candidate
        $candidateItem = Get-Item -LiteralPath $candidateFull -Force -ErrorAction SilentlyContinue
        if ($null -eq $candidateItem) {
            if ($explicit) { throw "Python runtime source does not exist: $candidate" }
            continue
        }

        $candidateIsFile = -not [bool]$candidateItem.PSIsContainer
        if ($candidateIsFile) {
            if ([IO.Path]::GetFileName($candidateFull) -ine 'python.exe') {
                throw 'Python runtime source must be a runtime directory or an exact python.exe path.'
            }
            $parent = Split-Path -Parent $candidateFull
            $sourceRoot = if ([IO.Path]::GetFileName($parent) -ieq 'Scripts') {
                Split-Path -Parent $parent
            } else {
                $parent
            }
        } elseif ([bool]$candidateItem.PSIsContainer) {
            $sourceRoot = $candidateFull
        } else {
            throw 'Python runtime source is neither a directory nor a file.'
        }

        Assert-ExistingDirectory $sourceRoot 'Python runtime source directory'
        $rootInterpreter = Join-Path $sourceRoot 'python.exe'
        $scriptsInterpreter = Join-Path $sourceRoot 'Scripts\python.exe'
        # Inspect both supported locations even when one is absent. This
        # catches a reparse-point Scripts directory, broken-link leaf, or
        # alternate interpreter before layout selection can hide it.
        Assert-NoReparsePath $rootInterpreter -AllowMissingLeaf
        Assert-NoReparsePath $scriptsInterpreter -AllowMissingLeaf
        $hasRootInterpreter = Test-Path -LiteralPath $rootInterpreter -PathType Leaf
        $hasScriptsInterpreter = Test-Path -LiteralPath $scriptsInterpreter -PathType Leaf
        if ($hasRootInterpreter -and $hasScriptsInterpreter) {
            throw "Python runtime source is ambiguous; both python.exe and Scripts\python.exe exist: $sourceRoot"
        }
        if (-not $hasRootInterpreter -and -not $hasScriptsInterpreter) {
            throw "An installed Python 3.12 base or venv containing python.exe or Scripts\python.exe is required: $sourceRoot"
        }

        $interpreter = if ($hasRootInterpreter) { $rootInterpreter } else { $scriptsInterpreter }
        Assert-ExistingFile $interpreter 'Python interpreter'
        $interpreterFull = Get-FullPath $interpreter
        if ($candidateIsFile -and $candidateFull -ine $interpreterFull) {
            throw "Python runtime source does not resolve to the requested interpreter: $candidate"
        }
        return [pscustomobject]@{
            Root = (Get-FullPath $sourceRoot)
            Executable = $interpreterFull
            Layout = if ($hasRootInterpreter) { 'root' } else { 'Scripts' }
            IsVirtualEnvironment = [bool](Test-Path -LiteralPath (Join-Path $sourceRoot 'pyvenv.cfg') -PathType Leaf)
        }
    }
    throw 'An installed Python 3.12 base or venv containing python.exe or Scripts\python.exe is required; pass -PythonRuntimeSource explicitly.'
}

function Get-PythonVenvBaseRelationship {
    param([Parameter(Mandatory)][string]$VenvRuntimePath)
    $venvRuntime = Normalize-WindowsAbsolutePath $VenvRuntimePath
    $scriptsDirectory = Split-Path -Parent $venvRuntime
    if ([IO.Path]::GetFileName($scriptsDirectory) -ine 'Scripts' -or
        [IO.Path]::GetFileName($venvRuntime) -ine 'python.exe') {
        throw 'The approved Python venv runtime must be Scripts\python.exe.'
    }
    $venvRoot = Normalize-WindowsAbsolutePath (Split-Path -Parent $scriptsDirectory)
    Assert-ExistingDirectory $venvRoot 'Python virtual environment root'
    $configPath = Normalize-WindowsAbsolutePath (Join-Path $venvRoot 'pyvenv.cfg')
    Assert-ExistingFile $configPath 'Python venv metadata'
    $config = Get-Content -LiteralPath $configPath -Raw -ErrorAction Stop
    $homeMatch = [regex]::Match($config, '(?im)^\s*home\s*=\s*(?<home>[^\r\n]+?)\s*$')
    $executableMatch = [regex]::Match($config, '(?im)^\s*executable\s*=\s*(?<executable>[^\r\n]+?)\s*$')
    if (-not $homeMatch.Success -or -not $executableMatch.Success) {
        throw 'Python venv metadata must identify both an absolute base home and executable.'
    }
    $baseRoot = Normalize-WindowsAbsolutePath $homeMatch.Groups['home'].Value.Trim().Trim([char]0x22)
    $baseExecutable = Normalize-WindowsAbsolutePath $executableMatch.Groups['executable'].Value.Trim().Trim([char]0x22)
    $expectedBaseExecutable = Normalize-WindowsAbsolutePath (Join-Path $baseRoot 'python.exe')
    $baseExecutableParent = Normalize-WindowsAbsolutePath (Split-Path -Parent $baseExecutable)
    if ([IO.Path]::GetFileName($baseExecutable) -ine 'python.exe' -or
        $baseExecutable -ine $expectedBaseExecutable -or
        $baseExecutableParent -ine $baseRoot -or
        $baseExecutable -ieq $venvRuntime) {
        throw 'Python venv metadata does not prove a distinct base python.exe relationship.'
    }
    Assert-ExistingDirectory $baseRoot 'Python venv base directory'
    Assert-ExistingFile $baseExecutable 'Python venv base interpreter'
    return [pscustomobject]@{
        VenvRoot = $venvRoot
        VenvRuntime = $venvRuntime
        ConfigPath = $configPath
        BaseRoot = $baseRoot
        BaseExecutable = $baseExecutable
    }
}

function Resolve-GatewayEntryPoint {
    param([string]$Requested, [Parameter(Mandatory)][string]$GatewaySource)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        Assert-ExistingFile $Requested 'Gateway entry point'
        if ([IO.Path]::GetFileName($Requested) -ne 'main.py') { throw 'The reviewed gateway bundle requires the exact main.py entry point.' }
        return (Get-FullPath $Requested)
    }
    $candidate = Join-Path $GatewaySource 'main.py'
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { Assert-NoReparsePath $candidate; return (Get-FullPath $candidate) }
    throw 'A gateway Python entry point is required; pass -GatewayEntryPoint explicitly.'
}

function Resolve-ServiceHostBinary {
    param([string]$Requested, [Parameter(Mandatory)][string]$DefaultPath)
    $candidate = if ([string]::IsNullOrWhiteSpace($Requested)) { $DefaultPath } else { $Requested }
    Assert-ExistingFile $candidate 'LifeOS.ServiceHost.exe'
    if ([IO.Path]::GetFileName($candidate) -ne 'LifeOS.ServiceHost.exe') { throw 'The service host source must be LifeOS.ServiceHost.exe.' }
    return (Get-FullPath $candidate)
}

function Resolve-TailscaleExecutable {
    param([string]$Requested)
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        Assert-ExistingFile $Requested 'Tailscale executable'
        return (Get-FullPath $Requested)
    }
    foreach ($candidate in @(
            (Join-Path ([Environment]::GetFolderPath('ProgramFiles')) 'Tailscale\tailscale.exe'),
            (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'Tailscale\tailscale.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { Assert-NoReparsePath $candidate; return (Get-FullPath $candidate) }
    }
    throw 'tailscale.exe was not found; pass -TailscaleExecutable explicitly.'
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    Assert-ExistingFile $Path 'Hash input'
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-BoundedFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][string]$Name
    )
    Assert-ExistingFile $Path $Name
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.Length -gt $MaxBytes) {
        throw "$Name exceeds its bounded migration size."
    }
    return [pscustomobject]@{ Length = [long]$item.Length; Sha256 = Get-FileSha256 $Path }
}

function Get-TreeManifest {
    param([Parameter(Mandatory)][string]$Root)
    Assert-ExistingDirectory $Root 'Manifest root'
    $rootFull = (Get-FullPath $Root).TrimEnd('\')
    $items = @()
    foreach ($item in (Get-ChildItem -LiteralPath $rootFull -Recurse -Force -File -ErrorAction Stop)) {
        $linkType = if ($null -ne $item.PSObject.Properties['LinkType']) { $item.LinkType } else { $null }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $linkType) {
            throw "Reparse point found below code/runtime root: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\')
        $items += [ordered]@{ path = $relative; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant(); length = $item.Length }
    }
    return @($items | Sort-Object -Property path)
}

function Compare-TreeManifest {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination)
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { return $false }
    $left = @(Get-TreeManifest $Source | ConvertTo-Json -Depth 8 -Compress)
    $right = @(Get-TreeManifest $Destination | ConvertTo-Json -Depth 8 -Compress)
    return (($left -join '') -eq ($right -join ''))
}

function New-BackupDirectory {
    param([Parameter(Mandatory)][string]$BackupRoot, [Parameter(Mandatory)][string]$Label)
    Ensure-Directory $BackupRoot
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    $path = Join-Path $BackupRoot ("{0}-{1}-{2}" -f $Label, $stamp, [Guid]::NewGuid().ToString('N').Substring(0, 8))
    Ensure-Directory $path
    return $path
}

function Backup-File {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$BackupDirectory, [string]$Name)
    Assert-ExistingFile $Source 'Backup source'
    Ensure-Directory $BackupDirectory
    $targetName = if ([string]::IsNullOrWhiteSpace($Name)) { [IO.Path]::GetFileName($Source) } else { $Name }
    $target = Join-Path $BackupDirectory $targetName
    Copy-Item -LiteralPath $Source -Destination $target -Force
    if ((Get-FileSha256 $Source) -ne (Get-FileSha256 $target)) { throw "Backup hash verification failed for $Source." }
    return $target
}

function Move-CurrentOutOfTheWay {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$BackupDirectory)
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-NoReparsePath $Path
    $leaf = [IO.Path]::GetFileName($Path.TrimEnd('\'))
    $destination = Join-Path $BackupDirectory ("rollback-current-{0}-{1}" -f $leaf, [Guid]::NewGuid().ToString('N'))
    Move-Item -LiteralPath $Path -Destination $destination -Force
}

function Restore-Artifact {
    param([Parameter(Mandatory)][psobject]$Artifact, [Parameter(Mandatory)][string]$BackupDirectory)
    $destination = [string]$Artifact.destination
    $backup = [string]$Artifact.backup
    if ([string]::IsNullOrWhiteSpace($destination)) { return }
    # Older manifests predate the changed flag and are treated conservatively
    # as changed. New manifests skip no-op copies so rollback never moves an
    # unchanged destination out of the way.
    $changed = $true
    $phase = 'complete'
    $priorExists = $true
    if ($Artifact -is [System.Collections.IDictionary] -and $Artifact.Contains('changed')) {
        $changed = [bool]$Artifact['changed']
        if ($Artifact.Contains('phase')) { $phase = [string]$Artifact['phase'] }
        if ($Artifact.Contains('priorExists')) { $priorExists = [bool]$Artifact['priorExists'] }
    } elseif ($null -ne $Artifact.PSObject.Properties['changed']) {
        $changed = [bool]$Artifact.changed
        if ($null -ne $Artifact.PSObject.Properties['phase']) { $phase = [string]$Artifact.phase }
        if ($null -ne $Artifact.PSObject.Properties['priorExists']) { $priorExists = [bool]$Artifact.priorExists }
    }
    if (-not $changed) { return }
    Assert-SafeAbsolutePath $destination 'Rollback destination'
    if ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup)) {
        # A copy helper restores its original destination on an in-process
        # failure and may consume its temporary backup before the outer catch
        # runs. A pending intent with a known prior destination is therefore
        # already restored; never move it away a second time.
        if ($phase -eq 'pending' -and $priorExists) { return }
        Move-CurrentOutOfTheWay $destination $BackupDirectory
        return
    }
    Assert-NoReparsePath $backup
    $parent = Split-Path -Parent $destination
    Ensure-Directory $parent
    # Never consume the manifest backup. Rollback can be retried after a
    # partial failure, so stage a copy first and keep the original snapshot
    # available for the next attempt.
    $staged = Join-Path $parent ('.rollback-restore-' + [Guid]::NewGuid().ToString('N'))
    try {
        Copy-Item -LiteralPath $backup -Destination $staged -Recurse -Force
        Assert-NoReparsePath $staged
        if (Test-Path -LiteralPath $backup -PathType Leaf) {
            if ((Get-FileSha256 $backup) -ne (Get-FileSha256 $staged)) { throw "Rollback staging hash verification failed: $backup" }
        } elseif (-not (Compare-TreeManifest $backup $staged)) {
            throw "Rollback staging manifest verification failed: $backup"
        }
        Move-CurrentOutOfTheWay $destination $BackupDirectory
        Move-Item -LiteralPath $staged -Destination $destination -Force
    } finally {
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Restore-ManifestArtifacts {
    param([Parameter(Mandatory)][psobject]$Manifest, [Parameter(Mandatory)][string]$BackupDirectory)
    $artifacts = @($Manifest.backups)
    for ($index = $artifacts.Count - 1; $index -ge 0; $index--) {
        Restore-Artifact $artifacts[$index] $BackupDirectory
    }
}

function Copy-FileVerifiedAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [string]$BackupName,
        [long]$MaxBytes = 0
    )
    $sourceItem = Get-Item -LiteralPath $Source -Force -ErrorAction SilentlyContinue
    if ($null -ne $sourceItem -and $sourceItem.PSIsContainer) { throw 'Copy source must be a file.' }
    if ($MaxBytes -gt 0) { $sourceInfo = Assert-BoundedFile $Source $MaxBytes 'Bounded copy source' }
    else {
        Assert-ExistingFile $Source 'Copy source'
        $sourceInfo = [pscustomobject]@{ Length = [long](Get-Item -LiteralPath $Source -Force -ErrorAction Stop).Length }
    }
    $parent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $parent
    $sourceHash = Get-FileSha256 $Source
    if (Test-Path -LiteralPath $Destination -PathType Container) {
        throw 'Copy destination cannot be a directory.'
    }
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Assert-NoReparsePath $Destination
        if ((Get-FileSha256 $Destination) -eq $sourceHash) {
            return [pscustomobject]@{ Destination = $Destination; SourceHash = $sourceHash; SourceLength = $sourceInfo.Length; Backup = $null; Changed = $false }
        }
    }
    $backup = $null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backupLeaf = if ([string]::IsNullOrWhiteSpace($BackupName)) { "previous-" + [IO.Path]::GetFileName($Destination) } else { $BackupName }
        $backup = Backup-File $Destination $BackupDirectory $backupLeaf
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        Assert-NoReparsePath $temp
        if ($MaxBytes -gt 0 -and (Get-Item -LiteralPath $temp -Force -ErrorAction Stop).Length -gt $MaxBytes) {
            throw 'Atomic copy source exceeded its bounded migration size.'
        }
        if ((Get-FileSha256 $temp) -ne $sourceHash) { throw "Atomic copy hash verification failed for $Source." }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
        if ((Get-FileSha256 $Destination) -ne $sourceHash) { throw "Destination hash verification failed for $Destination." }
    } catch {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
            Move-Item -LiteralPath $backup -Destination $Destination -Force
        } elseif (Test-Path -LiteralPath $Destination) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Destination = $Destination; SourceHash = $sourceHash; SourceLength = $sourceInfo.Length; Backup = $backup; Changed = $true }
}

function Copy-TreeVerifiedAtomic {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$BackupDirectory, [string]$BackupName)
    Assert-ExistingDirectory $Source 'Tree source'
    $sourceManifest = @(Get-TreeManifest $Source)
    if (Compare-TreeManifest $Source $Destination) {
        return [pscustomobject]@{ Destination = $Destination; Backup = $null; Manifest = $sourceManifest; Changed = $false }
    }
    $destinationParent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $destinationParent
    $temp = Join-Path $destinationParent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.staging')
    $backup = $null
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Recurse -Force
        if (-not (Compare-TreeManifest $Source $temp)) { throw "Tree hash verification failed for $Source." }
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            Assert-NoReparsePath $Destination
            $backupLeaf = if ([string]::IsNullOrWhiteSpace($BackupName)) { 'previous-' + [IO.Path]::GetFileName($Destination) } else { $BackupName }
            $backup = Join-Path $BackupDirectory $backupLeaf
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        if (-not (Compare-TreeManifest $Source $Destination)) { throw "Staged tree verification failed for $Destination." }
    } catch {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
            Move-Item -LiteralPath $backup -Destination $Destination -Force
        } elseif (Test-Path -LiteralPath $Destination) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Destination = $Destination; Backup = $backup; Manifest = $sourceManifest; Changed = $true }
}

function New-RandomSecret {
    $bytes = New-Object byte[] 48
    $generator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $generator.GetBytes($bytes) } finally { $generator.Dispose() }
    return ([Convert]::ToBase64String($bytes).TrimEnd('=') -replace '\+', '-' -replace '/', '_')
}

function Write-SecretAtomic {
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$BackupDirectory, [string]$BackupName)
    if ($Value.Length -lt 32 -or $Value.Length -gt 256 -or $Value -match '[^\x21-\x7E]') { throw 'Generated secret did not satisfy the bounded printable format.' }
    $parent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $parent
    $backup = $null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Assert-NoReparsePath $Destination
        $existing = (Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop)
        if ($existing -eq $Value) { return [pscustomobject]@{ Backup = $null; Changed = $false } }
        $backupLeaf = if ([string]::IsNullOrWhiteSpace($BackupName)) { 'previous-' + [IO.Path]::GetFileName($Destination) } else { $BackupName }
        $backup = Backup-File $Destination $BackupDirectory $backupLeaf
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Value, [Text.UTF8Encoding]::new($false))
        Assert-NoReparsePath $temp
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    } catch {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
            Move-Item -LiteralPath $backup -Destination $Destination -Force
        } elseif (Test-Path -LiteralPath $Destination) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Backup = $backup; Changed = $true }
}

function Set-RestrictedAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OperatorSid,
        [string[]]$ReadSids = @(),
        [string[]]$ModifySids = @(),
        [switch]$File
    )
    if ($File) { Assert-ExistingFile $Path 'ACL file' } else { Ensure-Directory $Path }
    Assert-ExplicitAclAllowTree -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids
    Register-AclSnapshot $Path
    # Use well-known SIDs instead of localized account names.
    $grant = @("${OperatorSid}:(F)", 'S-1-5-18:(F)', 'S-1-5-32-544:(F)')
    if (-not $File) { $grant += "${OperatorSid}:(OI)(CI)(F)" }
    foreach ($sid in $ReadSids) {
        if ($File) { $grant += "${sid}:(R)" }
        else { $grant += "${sid}:(OI)(CI)(RX)"; $grant += "${sid}:(RX)" }
    }
    foreach ($sid in $ModifySids) {
        if ($File) { $grant += "${sid}:(M)" }
        else { $grant += "${sid}:(OI)(CI)(M)"; $grant += "${sid}:(M)" }
    }
    $broadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4', 'S-1-5-7', 'S-1-5-2', 'S-1-5-19', 'S-1-5-20')
    $args = @($Path, '/inheritance:r', '/remove:g') + $broadSids + @('/grant:r') + $grant
    if (-not $File) { $args += @('/T', '/C') }
    Invoke-NativeChecked 'icacls.exe' ([string[]]$args) -Quiet | Out-Null
    Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids
}

function Set-SecretAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [Parameter(Mandatory)][string[]]$ReadSids)
    Set-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -File
}

function Set-BackupAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid)
    Set-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids @() -ModifySids @()
}

function Assert-AuthenticatedBackup {
    param(
        [Parameter(Mandatory)][psobject]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$BackupDirectory
    )
    Assert-NoReparsePath $BackupDirectory
    Assert-NoReparsePath $ManifestPath
    $allowed = @([string]$Manifest.operatorSid, 'S-1-5-18', 'S-1-5-32-544')
    foreach ($target in @($BackupDirectory, $ManifestPath)) {
        $acl = Get-Acl -LiteralPath $target -ErrorAction Stop
        try { $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "Rollback backup owner could not be resolved: $target" }
        if ($ownerSid -notin $allowed) { throw "Rollback backup owner is not trusted: $target" }
        foreach ($entry in $acl.Access) {
            if ($entry.AccessControlType -ne 'Allow') { continue }
            try { $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { throw "Rollback backup ACL identity could not be resolved: $target" }
            if ($sid -notin $allowed) { throw "Rollback backup has an unexpected allow ACL: $target" }
        }
    }
}

function Set-DirectoryTraversalAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [Parameter(Mandatory)][string[]]$ReadSids)
    Ensure-Directory $Path
    Assert-ExplicitAclAllowTree -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @()
    Register-AclSnapshot $Path
    $grant = @("${OperatorSid}:(F)", 'S-1-5-18:(F)', 'S-1-5-32-544:(F)')
    foreach ($sid in $ReadSids) { $grant += "${sid}:(RX)" }
    $broadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4', 'S-1-5-7', 'S-1-5-2', 'S-1-5-19', 'S-1-5-20')
    Invoke-NativeChecked 'icacls.exe' ([string[]](@($Path, '/inheritance:r', '/remove:g') + $broadSids + @('/grant:r') + $grant)) -Quiet | Out-Null
    Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @()
}

function Assert-ExplicitAclAllowSet {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [string[]]$ReadSids = @(), [string[]]$ModifySids = @())
    $allowed = @($OperatorSid, 'S-1-5-18', 'S-1-5-32-544') + $ReadSids + $ModifySids
    foreach ($entry in (Get-Acl -LiteralPath $Path -ErrorAction Stop).Access) {
        if ($entry.AccessControlType -ne 'Allow' -or $entry.IsInherited) { continue }
        try { $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "ACL identity could not be resolved before mutation: $Path" }
        if ($sid -notin $allowed) { throw "Unexpected explicit allow ACL identity on ${Path}: $sid" }
    }
}

function Assert-ExplicitAclAllowTree {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [string[]]$ReadSids = @(), [string[]]$ModifySids = @())
    Assert-NoReparsePath $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $targets = @($item)
    if ($item.PSIsContainer) { $targets += @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction Stop) }
    foreach ($target in $targets) {
        if (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not permitted in an ACL mutation tree: $($target.FullName)"
        }
        Assert-ExplicitAclAllowSet -Path ([string]$target.FullName) -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids
    }
}

function Assert-RestrictedAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [string[]]$ReadSids = @(), [string[]]$ModifySids = @())
    $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop
    if (-not $acl.AreAccessRulesProtected) { throw "ACL inheritance remains enabled on $Path" }
    $allowed = @($OperatorSid, 'S-1-5-18', 'S-1-5-32-544') + $ReadSids + $ModifySids
    foreach ($entry in $acl.Access) {
        if ($entry.AccessControlType -ne 'Allow') { continue }
        try { $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "ACL identity could not be resolved after mutation: $Path" }
        if ($sid -notin $allowed) { throw "Unexpected explicit allow ACL identity on ${Path}: $sid" }
    }
}

function Set-AclSnapshotContext {
    param([Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][string]$ManifestPath, [Parameter(Mandatory)][string]$BackupDirectory)
    $script:LifeOSAclSnapshotContext = [pscustomobject]@{ Manifest = $Manifest; ManifestPath = $ManifestPath; BackupDirectory = $BackupDirectory }
}

function Register-AclSnapshot {
    param([Parameter(Mandatory)][string]$Path)
    # New backup roots are ACL-locked before the install manifest exists. In
    # strict mode, reading an as-yet-uninitialized script variable throws, so
    # discover the optional context without making first-use ACL hardening
    # depend on manifest initialization order.
    $contextVariable = Get-Variable -Name LifeOSAclSnapshotContext -Scope Script -ErrorAction SilentlyContinue
    $context = if ($null -eq $contextVariable) { $null } else { $contextVariable.Value }
    if ($null -eq $context) { return }
    $full = Get-FullPath $Path
    Assert-NoReparsePath $full
    if (@($context.Manifest.aclSnapshots | Where-Object { (Get-FullPath ([string]$_.destination)) -eq $full }).Count -gt 0) { return }
    $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
    if ($item.PSIsContainer) {
        # Set-RestrictedAcl applies /T. icacls /save records the complete
        # tree's DACLs in one bounded artifact while the manifest remains
        # bound to the one canonical root being changed.
        $snapshotPath = Join-Path $context.BackupDirectory ('acl-' + ([Guid]::NewGuid().ToString('N')) + '.acl')
        Invoke-NativeChecked 'icacls.exe' ([string[]]@($full, '/save', $snapshotPath, '/T', '/C')) -Quiet | Out-Null
        [void]$context.Manifest.aclSnapshots.Add([ordered]@{ destination = $full; backup = $snapshotPath; priorExists = $true; mode = 'tree' })
    } else {
        $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
        $snapshotPath = Join-Path $context.BackupDirectory ('acl-' + ([Guid]::NewGuid().ToString('N')) + '.sddl')
        [IO.File]::WriteAllText($snapshotPath, [string]$acl.Sddl, [Text.UTF8Encoding]::new($false))
        [void]$context.Manifest.aclSnapshots.Add([ordered]@{ destination = $full; backup = $snapshotPath; priorExists = $true; mode = 'sddl' })
    }
    Write-JsonAtomic $context.ManifestPath $context.Manifest
}

function Restore-AclSnapshots {
    param([Parameter(Mandatory)][psobject]$Manifest)
    foreach ($snapshot in @($Manifest.aclSnapshots | Sort-Object -Property destination -Descending)) {
        $destination = [string]$snapshot.destination
        $backup = [string]$snapshot.backup
        Assert-ExistingFile $backup 'ACL rollback snapshot'
        if (-not (Test-Path -LiteralPath $destination)) { continue }
        Assert-NoReparsePath $destination
        if ([string]$snapshot.mode -eq 'tree') {
            Invoke-NativeChecked 'icacls.exe' ([string[]]@($destination, '/restore', $backup, '/C')) -Quiet | Out-Null
        } else {
            $acl = Get-Acl -LiteralPath $destination -ErrorAction Stop
            $acl.SetSecurityDescriptorSddlForm((Get-Content -LiteralPath $backup -Raw -ErrorAction Stop))
            Set-Acl -LiteralPath $destination -AclObject $acl -ErrorAction Stop
        }
    }
}

function Assert-NoBroadAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    $broadSids = @('S-1-1-0', 'S-1-5-11', 'S-1-5-32-545', 'S-1-5-4', 'S-1-5-7', 'S-1-5-2', 'S-1-5-19', 'S-1-5-20')
    foreach ($entry in $acl.Access) {
        try { $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
        catch { throw "ACL identity could not be resolved: $Path" }
        if ($entry.AccessControlType -eq 'Allow' -and $sid -in $broadSids) {
            throw "Broad or shared allow ACL is not permitted on $Path."
        }
    }
}

function Get-ScheduledTaskSnapshot {
    param([Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)][string]$BackupDirectory)
    Assert-SafeTaskName $TaskName
    $tasks = @(Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) { return [pscustomobject]@{ Exists = $false; Enabled = $false; State = 'Stopped'; TaskPath = '\'; Xml = $null; Backup = $null } }
    if ($tasks.Count -ne 1) { throw "Scheduled task name is ambiguous across task paths: $TaskName" }
    $task = $tasks[0]
    $taskPath = [string]$task.TaskPath
    if ([string]::IsNullOrWhiteSpace($taskPath)) { $taskPath = '\' }
    Assert-SafeTaskPath $taskPath
    Ensure-Directory $BackupDirectory
    $xml = Export-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction Stop
    $backup = Join-Path $BackupDirectory ($TaskName + '.xml')
    [IO.File]::WriteAllText($backup, $xml, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Exists = $true; Enabled = ($task.State -ne 'Disabled'); State = [string]$task.State; TaskPath = $taskPath; Xml = $xml; Backup = $backup }
}

function Get-LegacyTaskActionFingerprint {
    param([Parameter(Mandatory)][string]$Xml)
    $document = New-Object System.Xml.XmlDocument
    try { $document.LoadXml($Xml) } catch { throw 'The legacy scheduled-task definition is not valid XML.' }
    $namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespace.AddNamespace('task', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $actions = @($document.SelectNodes('/task:Task/task:Actions/task:Exec', $namespace))
    if ($actions.Count -ne 1) { throw 'The legacy task must have exactly one executable action.' }
    $action = $actions[0]
    $workingDirectoryNode = $action.SelectSingleNode('task:WorkingDirectory', $namespace)
    # The task fingerprint binds the exact executable action, arguments, and
    # optional working directory. Approval separately validates the launcher
    # shape and its fixed root before a listener can be attributed to the task.
    $workingDirectory = if ($null -ne $workingDirectoryNode) { [string]$workingDirectoryNode.InnerText } else { '' }
    return @(
        [string]$action.Command
        [string]$action.Arguments
        $workingDirectory
    ) -join "`n"
}

function Assert-LegacyTaskUnchanged {
    param(
        [Parameter(Mandatory)][psobject]$TaskSnapshot,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath
    )
    if (-not [bool]$TaskSnapshot.Exists) { return }
    $current = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $current) { throw 'The legacy task disappeared before its definition could be verified.' }
    $currentXml = Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    if ((Get-LegacyTaskActionFingerprint ([string]$currentXml)) -ne (Get-LegacyTaskActionFingerprint ([string]$TaskSnapshot.Xml))) {
        throw 'The legacy task definition changed after the reviewed snapshot; refusing deployment.'
    }
}

function Get-AbsolutePathCandidatesByLeaf {
    param([Parameter(Mandatory)][string]$Text, [Parameter(Mandatory)][string]$LeafPattern)
    $found = New-Object System.Collections.ArrayList
    $patterns = @(
        ('(?i)"(?<value>[A-Z]:\\[^"\r\n]*\\' + $LeafPattern + ')"'),
        ('(?i)(?<value>[A-Z]:\\[^\s"''<>|&;]+\\' + $LeafPattern + ')')
    )
    foreach ($pattern in $patterns) {
        foreach ($match in [regex]::Matches($Text, $pattern)) {
            $candidate = [Environment]::ExpandEnvironmentVariables($match.Groups['value'].Value)
            try {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                    Assert-NoReparsePath $candidate
                    $full = Get-FullPath $candidate
                    if ($full -notin $found) { [void]$found.Add($full) }
                }
            } catch {
                throw 'A legacy gateway approval path could not be verified.'
            }
        }
    }
    return @($found)
}

function Get-LegacyLauncherApprovalShape {
    param(
        [Parameter(Mandatory)][string]$LauncherText,
        [Parameter(Mandatory)][string]$ExpectedRuntimePath
    )

    # The legacy launcher is accepted only when its root is one absolute
    # literal assignment and its sole Python invocation is the exact static
    # expression below.  Do not evaluate PowerShell or follow PATH/env vars.
    $rootAssignmentLines = @([regex]::Matches($LauncherText, '(?im)^\s*\$root\s*='))
    $rootAssignments = @()
    $rootAssignments += @([regex]::Matches($LauncherText, '(?im)^\s*\$root\s*=\s*"(?<root>[A-Z]:\\[^"\r\n]+)"\s*$'))
    $rootAssignments += @([regex]::Matches($LauncherText, '(?im)^\s*\$root\s*=\s*''(?<root>[A-Z]:\\[^''\r\n]+)''\s*$'))
    if ($rootAssignmentLines.Count -ne 1 -or $rootAssignments.Count -ne 1) { return $null }

    try {
        $root = Normalize-WindowsAbsolutePath ([string]$rootAssignments[0].Groups['root'].Value)
        Assert-NoReparsePath $root
        $expected = Normalize-WindowsAbsolutePath $ExpectedRuntimePath
    } catch {
        return $null
    }

    $locationInvocations = @([regex]::Matches($LauncherText, '(?im)^\s*Set-Location\s+\$root\s*$'))
    if ($locationInvocations.Count -ne 1) { return $null }

    # Count executable-looking Python invocations, including dynamic and
    # relative forms, so a second unsafe invocation cannot hide beside the
    # approved shape.
    $runtimeInvocations = @([regex]::Matches(
        $LauncherText,
        '(?im)(?:^|[;&|])\s*(?:&|Start-Process)\s+[^#\r\n;&|]*(?:\bpython(?:3)?(?:\.exe)?\b|\$[A-Za-z_][A-Za-z0-9_]*(?:python|interpreter)[A-Za-z0-9_]*)[^#\r\n;&|]*'))
    if ($runtimeInvocations.Count -ne 1) { return $null }

    $invocationText = [string]$runtimeInvocations[0].Value
    $literalPaths = @(Get-AbsolutePathCandidatesByLeaf $invocationText 'python(?:3)?\.exe')
    if ($literalPaths.Count -ne 0) { return $null }
    $rootInvocation = @([regex]::Matches(
        $invocationText,
        '(?im)^\s*&\s*"\$root\\venv\\Scripts\\python\.exe"\s+-m\s+uvicorn\s+main:app\s+--host\s+127\.0\.0\.1\s+--port\s+8421\s*$'))
    if ($rootInvocation.Count -ne 1) { return $null }
    if ($invocationText -match '(?i)(?:^|[\s"'';&|])(?:[A-Z]:\\[^\s"'';&|]*\\)?main\.py(?:[\s"'';&|]|$)') { return $null }

    $resolved = Normalize-WindowsAbsolutePath (Join-Path $root 'venv\Scripts\python.exe')
    if ($resolved -ine $expected -or -not (Test-Path -LiteralPath $resolved -PathType Leaf)) { return $null }
    $resolvedMain = Normalize-WindowsAbsolutePath (Join-Path $root 'main.py')
    if (-not (Test-Path -LiteralPath $resolvedMain -PathType Leaf)) { return $null }
    try {
        Assert-NoReparsePath $resolved
        Assert-NoReparsePath $resolvedMain
    } catch {
        return $null
    }
    return [pscustomobject]@{
        RootPath = $root
        RuntimePath = $resolved
        MainPath = $resolvedMain
        InvocationText = $invocationText
    }
}

function Get-LegacyLauncherRuntimeCandidates {
    param(
        [Parameter(Mandatory)][string]$LauncherText,
        [Parameter(Mandatory)][string]$ExpectedRuntimePath
    )
    $shape = Get-LegacyLauncherApprovalShape -LauncherText $LauncherText -ExpectedRuntimePath $ExpectedRuntimePath
    if ($null -eq $shape) { return @() }
    return @([string]$shape.RuntimePath)
}

function Get-LegacyGatewayApproval {
    param([Parameter(Mandatory)][psobject]$TaskSnapshot)
    if (-not [bool]$TaskSnapshot.Exists -or [string]::IsNullOrWhiteSpace([string]$TaskSnapshot.Xml)) {
        throw 'A legacy listener cannot be approved without its scheduled-task definition.'
    }
    $document = New-Object System.Xml.XmlDocument
    try { $document.LoadXml([string]$TaskSnapshot.Xml) } catch { throw 'The legacy scheduled-task definition is not valid XML.' }
    $namespace = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $namespace.AddNamespace('task', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $actions = @($document.SelectNodes('/task:Task/task:Actions/task:Exec', $namespace))
    if ($actions.Count -ne 1) { throw 'The legacy task must have exactly one executable action for listener attribution.' }
    $action = $actions[0]
    $command = [string]$action.Command
    $arguments = [string]$action.Arguments
    $workingDirectoryNode = $action.SelectSingleNode('task:WorkingDirectory', $namespace)
    $workingDirectory = if ($null -ne $workingDirectoryNode) { [string]$workingDirectoryNode.InnerText } else { '' }
    if ([string]::IsNullOrWhiteSpace($command)) { throw 'The legacy task executable action has no command.' }

    $scriptPaths = @(Get-AbsolutePathCandidatesByLeaf (($command + ' ' + $arguments)) 'run_server\.ps1')
    if ($scriptPaths.Count -ne 1) { throw 'The legacy task must identify exactly one run_server.ps1 launcher.' }
    $launcherPath = $scriptPaths[0]
    $launcherText = ''
    $launcherSha256 = ''
    $launcherText = Get-Content -LiteralPath $launcherPath -Raw -ErrorAction Stop
    $launcherSha256 = Get-FileSha256 $launcherPath
    $taskText = $command + "`n" + $arguments
    $taskLiteralMainPaths = @(Get-AbsolutePathCandidatesByLeaf $taskText 'main\.py')
    if ($taskLiteralMainPaths.Count -ne 0 -or $taskText -match '(?i)(^|[\s''"&./\\])main\.py([\s''"&]|$)') {
        throw 'The legacy task contains a literal alternate main.py; refusing listener attribution.'
    }
    $expectedRuntimePath = Join-Path $script:LifeOSDefaultPaths.GatewaySource 'venv\Scripts\python.exe'
    $launcherShape = Get-LegacyLauncherApprovalShape -LauncherText $launcherText -ExpectedRuntimePath $expectedRuntimePath
    if ($null -eq $launcherShape) {
        throw 'The legacy launcher must use exactly one fixed-root approved Python uvicorn main:app invocation.'
    }
    $launcherDirectory = Normalize-WindowsAbsolutePath (Split-Path -Parent $launcherPath)
    if ($launcherDirectory -ine [string]$launcherShape.RootPath) {
        throw 'The legacy launcher directory does not match its fixed root.'
    }
    $runtimePaths = @([string]$launcherShape.RuntimePath)
    $mainPaths = @([string]$launcherShape.MainPath)

    # PATH-based Python invocations are deliberately not accepted: the exact
    # runtime path must be present in the reviewed task/script so an arbitrary
    # interpreter cannot claim the legacy listener.
    if ($runtimePaths.Count -ne 1) { throw 'The legacy task does not identify exactly one approved absolute Python runtime.' }

    $workingDirectoryPath = ''
    if (-not [string]::IsNullOrWhiteSpace($workingDirectory)) {
        $expandedWorkingDirectory = [Environment]::ExpandEnvironmentVariables($workingDirectory.Trim('"'))
        if (-not (Test-Path -LiteralPath $expandedWorkingDirectory -PathType Container)) {
            throw 'The legacy task working directory does not exist.'
        }
        Assert-NoReparsePath $expandedWorkingDirectory
        $workingDirectoryPath = Normalize-WindowsAbsolutePath $expandedWorkingDirectory
        if ($workingDirectoryPath -ine [string]$launcherShape.RootPath) {
            throw 'The legacy task working directory does not match the fixed launcher root.'
        }
    }
    if ($mainPaths.Count -ne 1) { throw 'The legacy task does not identify exactly one approved main.py.' }
    return [pscustomobject]@{
        RuntimePaths = @($runtimePaths)
        MainPaths = @($mainPaths)
        LauncherPath = $launcherPath
        LauncherSha256 = $launcherSha256
        WorkingDirectory = $workingDirectoryPath
    }
}

function Get-LoopbackPortOwner {
    param([Parameter(Mandatory)][int]$Port)
    $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    if ($connections.Count -eq 0) { return $null }
    foreach ($connection in $connections) {
        if (-not (Test-LoopbackAddress ([string]$connection.LocalAddress))) {
            throw "Port $Port is occupied outside loopback; refusing deployment."
        }
    }
    $processIds = @($connections | ForEach-Object { [int]$_.OwningProcess } | Sort-Object -Unique)
    if ($processIds.Count -ne 1 -or $processIds[0] -le 0) {
        throw "Port $Port has an ambiguous listener owner; refusing deployment."
    }
    return [pscustomobject]@{
        ProcessId = [int]$processIds[0]
        LocalAddresses = @($connections | ForEach-Object { [string]$_.LocalAddress } | Sort-Object -Unique)
    }
}

function Convert-CimCreationDateUtc {
    param([Parameter(Mandatory)][object]$Value)
    try {
        if ($Value -is [datetime]) { return $Value.ToUniversalTime().ToString('o') }
        return ([System.Management.ManagementDateTimeConverter]::ToDateTime([string]$Value)).ToUniversalTime().ToString('o')
    } catch {
        throw 'The legacy listener process creation time could not be verified.'
    }
}

function Get-LegacyProcessMainPath {
    param(
        [Parameter(Mandatory)][string]$CommandLine,
        [Parameter(Mandatory)][psobject]$Approval,
        [string]$ExpectedExecutablePath = ''
    )
    $absolute = @(Get-AbsolutePathCandidatesByLeaf $CommandLine 'main\.py')
    if ($absolute.Count -ne 0 -or $CommandLine -match '(?i)(^|[\s''"&./\\])main\.py([\s''"&]|$)') {
        throw 'The legacy listener command contains a literal main.py path.'
    }

    $fixedShape = [regex]::Match(
        $CommandLine.Trim(),
        '(?i)^(?:"(?<quotedExecutable>[^"\r\n]+)"|(?<bareExecutable>[^\s]+))\s+-m\s+uvicorn\s+main:app\s+--host\s+127\.0\.0\.1\s+--port\s+8421\s*$')
    if (-not $fixedShape.Success) {
        throw 'The legacy listener command is not the fixed uvicorn loopback 8421 shape.'
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedExecutablePath)) {
        try {
            $expectedExecutable = Normalize-WindowsAbsolutePath $ExpectedExecutablePath
            $commandExecutable = if ($fixedShape.Groups['quotedExecutable'].Success) {
                [string]$fixedShape.Groups['quotedExecutable'].Value
            } else {
                [string]$fixedShape.Groups['bareExecutable'].Value
            }
            $commandExecutable = Normalize-WindowsAbsolutePath $commandExecutable
        } catch {
            throw 'The legacy listener command executable could not be normalized.'
        }
        if ($commandExecutable -ine $expectedExecutable) {
            throw 'The legacy listener command executable does not match its observed executable.'
        }
    }

    $moduleInvocations = @([regex]::Matches(
        $CommandLine,
        '(?im)(?:^|\s)-m\s+(?<server>[^\s]+)\s+(?<module>[^\s]+)(?=\s|$)'))
    if ($moduleInvocations.Count -ne 1) {
        throw 'The legacy listener command must identify exactly one uvicorn module invocation.'
    }
    $moduleInvocation = $moduleInvocations[0]
    if ([string]$moduleInvocation.Groups['server'].Value -cne 'uvicorn' -or
        [string]$moduleInvocation.Groups['module'].Value -cne 'main:app') {
        throw 'The legacy listener command does not identify the approved uvicorn main:app module.'
    }
    if ($CommandLine -match '(?i)(?:^|\s)--(?:app-dir|reload-dir)(?:=|\s)') {
        throw 'The legacy listener command changes the uvicorn module root.'
    }
    if (@($Approval.MainPaths).Count -ne 1) {
        throw 'The approved uvicorn main:app invocation is ambiguous.'
    }
    return [string]$Approval.MainPaths[0]
}

function Get-LegacyGatewayListenerSnapshot {
    param(
        [Parameter(Mandatory)][psobject]$TaskSnapshot,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [int]$Port = 8421
    )
    $owner = Get-LoopbackPortOwner $Port
    $base = [ordered]@{
        Exists = ($null -ne $owner)
        Port = $Port
        LocalAddresses = if ($null -ne $owner) { @($owner.LocalAddresses) } else { @() }
        ProcessId = if ($null -ne $owner) { [int]$owner.ProcessId } else { 0 }
        CreationTimeUtc = ''
        ExecutablePath = ''
        ExecutableSha256 = ''
        MainPath = ''
        MainSha256 = ''
        LauncherPath = ''
        LauncherSha256 = ''
        ParentProcessId = 0
        ParentCreationTimeUtc = ''
        ParentExecutablePath = ''
        ParentExecutableSha256 = ''
        ParentMainPath = ''
        ParentMainSha256 = ''
        RuntimeRelationship = ''
        ChainDepth = 0
        TaskName = $TaskName
        TaskPath = $TaskPath
        TaskState = if ($null -ne $TaskSnapshot.PSObject.Properties['State']) { [string]$TaskSnapshot.State } else { 'Stopped' }
        TaskEnabled = if ($null -ne $TaskSnapshot.PSObject.Properties['Enabled']) { [bool]$TaskSnapshot.Enabled } else { $false }
        TaskMutated = $false
        Stopped = $false
    }
    if ($null -eq $owner) { return [pscustomobject]$base }
    if (-not [bool]$TaskSnapshot.Exists) { throw "Port $Port is occupied but the approved legacy task is absent." }
    $approval = Get-LegacyGatewayApproval $TaskSnapshot
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $owner.ProcessId) -ErrorAction Stop)
    if ($processes.Count -ne 1) { throw "Port $Port has no uniquely queryable process owner." }
    $process = $processes[0]
    $executablePath = [string]$process.ExecutablePath
    $commandLine = [string]$process.CommandLine
    if ([string]::IsNullOrWhiteSpace($executablePath) -or [string]::IsNullOrWhiteSpace($commandLine)) {
        throw 'The legacy listener process does not expose a verifiable executable and main.py command.'
    }
    Assert-ExistingFile $executablePath 'Legacy listener executable'
    $executablePath = Normalize-WindowsAbsolutePath $executablePath
    $approvedRuntimePaths = @($approval.RuntimePaths | ForEach-Object { Normalize-WindowsAbsolutePath ([string]$_) })
    if ($approvedRuntimePaths.Count -ne 1) {
        throw 'The approved legacy listener runtime is ambiguous.'
    }
    $approvedRuntimePath = [string]$approvedRuntimePaths[0]
    $expectedVenvRuntime = Normalize-WindowsAbsolutePath (Join-Path $script:LifeOSDefaultPaths.GatewaySource 'venv\Scripts\python.exe')
    if ($approvedRuntimePath -ine $expectedVenvRuntime) {
        throw 'The approved legacy listener runtime is not the canonical venv runtime.'
    }
    $mainPath = Normalize-WindowsAbsolutePath (Get-LegacyProcessMainPath -CommandLine $commandLine -Approval $approval -ExpectedExecutablePath $executablePath)
    if ($mainPath -notin @($approval.MainPaths)) { throw 'The legacy listener main.py is not the task-approved file.' }
    Assert-ExistingFile $mainPath 'Legacy gateway main.py'
    $creationDate = if ($null -ne $process.PSObject.Properties['CreationDate']) { Convert-CimCreationDateUtc $process.CreationDate } else { throw 'The legacy listener process has no creation timestamp.' }
    $base.CreationTimeUtc = $creationDate
    $base.ExecutablePath = $executablePath
    $base.ExecutableSha256 = Get-FileSha256 $executablePath
    $base.MainPath = Get-FullPath $mainPath
    $base.MainSha256 = Get-FileSha256 $mainPath
    $base.LauncherPath = $approval.LauncherPath
    $base.LauncherSha256 = $approval.LauncherSha256

    if ($executablePath -ieq $approvedRuntimePath) {
        return [pscustomobject]$base
    }

    $relationshipProof = Get-PythonVenvBaseRelationship -VenvRuntimePath $approvedRuntimePath
    if ($executablePath -ine [string]$relationshipProof.BaseExecutable) {
        throw 'The legacy listener executable is neither the approved venv runtime nor its proven pyvenv base interpreter.'
    }
    if ($null -eq $process.PSObject.Properties['ParentProcessId']) {
        throw 'The legacy listener redirector has no verifiable immediate parent.'
    }
    $parentProcessId = [int]$process.ParentProcessId
    if ($parentProcessId -le 0 -or $parentProcessId -eq [int]$owner.ProcessId) {
        throw 'The legacy listener redirector has an invalid immediate parent identity.'
    }
    $parentProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $parentProcessId) -ErrorAction Stop)
    if ($parentProcesses.Count -ne 1) {
        throw 'The legacy listener redirector has an ambiguous immediate parent.'
    }
    $parentProcess = $parentProcesses[0]
    $parentExecutablePath = [string]$parentProcess.ExecutablePath
    $parentCommandLine = [string]$parentProcess.CommandLine
    if ([string]::IsNullOrWhiteSpace($parentExecutablePath) -or [string]::IsNullOrWhiteSpace($parentCommandLine)) {
        throw 'The legacy listener immediate parent does not expose a verifiable executable and command.'
    }
    Assert-ExistingFile $parentExecutablePath 'Legacy listener parent executable'
    $parentExecutablePath = Normalize-WindowsAbsolutePath $parentExecutablePath
    if ($parentExecutablePath -ine $approvedRuntimePath) {
        throw 'The legacy listener immediate parent is not the exact approved venv runtime.'
    }
    $parentMainPath = Normalize-WindowsAbsolutePath (Get-LegacyProcessMainPath -CommandLine $parentCommandLine -Approval $approval -ExpectedExecutablePath $parentExecutablePath)
    if ($parentMainPath -notin @($approval.MainPaths) -or $parentMainPath -ine $mainPath) {
        throw 'The legacy listener parent does not identify the same approved main.py.'
    }
    if ($null -eq $parentProcess.PSObject.Properties['CreationDate']) {
        throw 'The legacy listener immediate parent has no creation timestamp.'
    }
    $parentCreationDate = Convert-CimCreationDateUtc $parentProcess.CreationDate

    if ($null -eq $parentProcess.PSObject.Properties['ParentProcessId']) {
        throw 'The legacy listener immediate parent has no verifiable chain parent.'
    }
    $grandparentProcessId = [int]$parentProcess.ParentProcessId
    if ($grandparentProcessId -le 0 -or $grandparentProcessId -eq $parentProcessId -or
        $grandparentProcessId -eq [int]$owner.ProcessId) {
        throw 'The legacy listener process chain is missing or self-referential.'
    }
    $grandparentProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $grandparentProcessId) -ErrorAction Stop)
    # The task/launcher approval and exact child/parent checks above are
    # complete before this query. A scheduled-task shell may have exited after
    # starting the approved venv redirector; zero is safe only in that case.
    # Multiple results remain ambiguous and therefore fail closed.
    if ($grandparentProcesses.Count -eq 0) {
        # The approved task shell may already have exited; the exact child and
        # direct-parent checks above are the complete orphaned-chain proof.
    } elseif ($grandparentProcesses.Count -gt 1) {
        throw 'The legacy listener process chain has an ambiguous grandparent.'
    } elseif ($grandparentProcesses.Count -eq 1) {
        $grandparentProcess = $grandparentProcesses[0]
        $grandparentExecutablePath = [string]$grandparentProcess.ExecutablePath
        $grandparentCommandLine = [string]$grandparentProcess.CommandLine
        if ([string]::IsNullOrWhiteSpace($grandparentExecutablePath)) {
            throw 'The legacy listener process chain has no verifiable grandparent executable.'
        }
        Assert-ExistingFile $grandparentExecutablePath 'Legacy listener grandparent executable'
        $grandparentExecutablePath = Normalize-WindowsAbsolutePath $grandparentExecutablePath
        if ($grandparentExecutablePath -ieq [string]$relationshipProof.BaseExecutable -or
            $grandparentExecutablePath -ieq $approvedRuntimePath -or
            [IO.Path]::GetFileName($grandparentExecutablePath) -match '(?i)^(?:python(?:w)?|py(?:w)?)(?:3(?:\.\d+)?)?\.exe$' -or
            $grandparentCommandLine -match '(?i)(?:^|\s)-m\s+uvicorn(?:\s|$)' -or
            $grandparentCommandLine -match '(?i)\bmain:app\b') {
            throw 'The legacy listener process chain contains an unexpected deeper Python or uvicorn parent.'
        }
    }
    $base.ParentProcessId = $parentProcessId
    $base.ParentCreationTimeUtc = $parentCreationDate
    $base.ParentExecutablePath = $parentExecutablePath
    $base.ParentExecutableSha256 = Get-FileSha256 $parentExecutablePath
    $base.ParentMainPath = $parentMainPath
    $base.ParentMainSha256 = Get-FileSha256 $parentMainPath
    $base.RuntimeRelationship = 'pyvenv-base-redirector'
    $base.ChainDepth = 1
    return [pscustomobject]$base
}

function Assert-LegacyListenerIdentity {
    param([Parameter(Mandatory)][psobject]$Observed, [Parameter(Mandatory)][psobject]$Expected)
    Assert-LegacyListenerCodeIdentity $Observed $Expected
    if ([int]$Observed.ProcessId -ne [int]$Expected.ProcessId -or
        [string]$Observed.CreationTimeUtc -ne [string]$Expected.CreationTimeUtc) {
        throw 'The legacy listener process identity changed; refusing process mutation.'
    }
    if ($null -ne $Expected.PSObject.Properties['RuntimeRelationship'] -and
        [string]$Expected.RuntimeRelationship -eq 'pyvenv-base-redirector' -and
        ([int]$Observed.ParentProcessId -ne [int]$Expected.ParentProcessId -or
         [string]$Observed.ParentCreationTimeUtc -ne [string]$Expected.ParentCreationTimeUtc)) {
        throw 'The legacy listener immediate parent identity changed; refusing process mutation.'
    }
}

function Assert-LegacyListenerCodeIdentity {
    param([Parameter(Mandatory)][psobject]$Observed, [Parameter(Mandatory)][psobject]$Expected)
    if ($null -eq $Observed -or -not [bool]$Observed.Exists -or
        [string]$Observed.ExecutablePath -ne [string]$Expected.ExecutablePath -or
        [string]$Observed.ExecutableSha256 -ne [string]$Expected.ExecutableSha256 -or
        [string]$Observed.MainPath -ne [string]$Expected.MainPath -or
        [string]$Observed.MainSha256 -ne [string]$Expected.MainSha256 -or
        [string]$Observed.LauncherPath -ne [string]$Expected.LauncherPath -or
        [string]$Observed.LauncherSha256 -ne [string]$Expected.LauncherSha256) {
        throw 'The restored legacy listener code identity changed; refusing to accept it.'
    }
    if ($null -ne $Expected.PSObject.Properties['RuntimeRelationship']) {
        foreach ($field in @(
            'ParentProcessId', 'ParentCreationTimeUtc', 'ParentExecutablePath',
            'ParentExecutableSha256', 'ParentMainPath', 'ParentMainSha256',
            'RuntimeRelationship', 'ChainDepth')) {
            if ($null -eq $Observed.PSObject.Properties[$field] -or $null -eq $Expected.PSObject.Properties[$field]) {
                throw 'The restored legacy listener chain identity is incomplete; refusing to accept it.'
            }
        }
        if ([string]$Observed.ParentExecutablePath -ine [string]$Expected.ParentExecutablePath -or
            [string]$Observed.ParentExecutableSha256 -ne [string]$Expected.ParentExecutableSha256 -or
            [string]$Observed.ParentMainPath -ine [string]$Expected.ParentMainPath -or
            [string]$Observed.ParentMainSha256 -ne [string]$Expected.ParentMainSha256 -or
            [string]$Observed.RuntimeRelationship -ne [string]$Expected.RuntimeRelationship -or
            [int]$Observed.ChainDepth -ne [int]$Expected.ChainDepth) {
            throw 'The restored legacy listener chain code identity changed; refusing to accept it.'
        }
    }
}

function Stop-AttributedLegacyGatewayListener {
    param(
        [Parameter(Mandatory)][psobject]$TaskSnapshot,
        [Parameter(Mandatory)][psobject]$Expected,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [int]$Port = 8421
    )
    $observed = Get-LegacyGatewayListenerSnapshot $TaskSnapshot $TaskName $TaskPath $Port
    if (-not [bool]$observed.Exists) { return $false }
    Assert-LegacyListenerIdentity $observed $Expected
    Stop-Process -Id ([int]$Expected.ProcessId) -ErrorAction Stop
    if (-not (Wait-PortFree $Port 30)) { throw "The attributable legacy listener did not release port $Port." }
    return $true
}

function Wait-LegacyGatewayListener {
    param(
        [Parameter(Mandatory)][psobject]$TaskSnapshot,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [int]$Port = 8421,
        [int]$TimeoutSeconds = 30
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $observed = Get-LegacyGatewayListenerSnapshot $TaskSnapshot $TaskName $TaskPath $Port
        if ([bool]$observed.Exists) { return $observed }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    throw "The legacy gateway did not restore its listener on port $Port."
}

function Stop-LegacyGatewayForCutover {
    param(
        [Parameter(Mandatory)][psobject]$TaskSnapshot,
        [Parameter(Mandatory)][psobject]$ListenerSnapshot,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [int]$Port = 8421
    )
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $task -and ([bool]$TaskSnapshot.Exists -or [bool]$ListenerSnapshot.Exists)) {
        throw 'The legacy task disappeared before cutover; refusing deployment.'
    }
    if ($null -ne $task -and -not [bool]$TaskSnapshot.Exists) {
        throw 'A legacy task appeared after the reviewed snapshot; refusing deployment.'
    }
    Assert-LegacyTaskUnchanged $TaskSnapshot $TaskName $TaskPath
    $taskMutated = $false
    if ($null -ne $task) {
        $currentEnabled = ([string]$task.State -ne 'Disabled')
        if ($currentEnabled -ne [bool]$TaskSnapshot.Enabled) {
            throw 'The legacy task enabled state changed before cutover; refusing deployment.'
        }
        if ([string]$task.State -eq 'Running') {
            $Manifest.legacyListener.TaskMutated = $true
            Save-InstallManifest $Manifest $ManifestPath
            Stop-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
            $taskMutated = $true
        }
        $taskAfterStop = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
        if ($null -ne $taskAfterStop -and [string]$taskAfterStop.State -ne 'Disabled') {
            $Manifest.legacyListener.TaskMutated = $true
            Save-InstallManifest $Manifest $ManifestPath
            Disable-LegacyTaskAfterCutover $TaskName $TaskPath
            $taskMutated = $true
        }
    }
    if ([bool]$ListenerSnapshot.Exists) {
        $Manifest.legacyListener.Stopped = $true
        Save-InstallManifest $Manifest $ManifestPath
        $null = Stop-AttributedLegacyGatewayListener $TaskSnapshot $ListenerSnapshot $TaskName $TaskPath $Port
    } else {
        $currentListener = Get-LegacyGatewayListenerSnapshot $TaskSnapshot $TaskName $TaskPath $Port
        if ([bool]$currentListener.Exists) {
            throw "Port $Port became occupied after the reviewed snapshot; refusing deployment."
        }
    }
    if (-not (Wait-PortFree $Port 30)) { throw "Port $Port remained occupied after legacy cutover." }
    return [pscustomobject]@{ TaskMutated = $taskMutated; ListenerStopped = [bool]$ListenerSnapshot.Exists }
}

function Restore-LegacyGatewayListener {
    param(
        [Parameter(Mandatory)][psobject]$TaskSnapshot,
        [Parameter(Mandatory)][psobject]$ListenerSnapshot,
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [int]$Port = 8421
    )
    if (-not [bool]$ListenerSnapshot.Exists) { return }
    Assert-LegacyTaskUnchanged $TaskSnapshot $TaskName $TaskPath
    $existing = Get-LegacyGatewayListenerSnapshot $TaskSnapshot $TaskName $TaskPath $Port
    if ([bool]$existing.Exists) {
        Assert-LegacyListenerCodeIdentity $existing $ListenerSnapshot
        return
    }
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $task) { throw 'Cannot restore a legacy listener without its scheduled task.' }
    $temporarilyEnabled = $false
    if ([string]$task.State -eq 'Disabled') {
        Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Out-Null
        $temporarilyEnabled = -not [bool]$ListenerSnapshot.TaskEnabled
    }
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    if ([string]$task.State -ne 'Running') {
        Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    }
    $restored = Wait-LegacyGatewayListener $TaskSnapshot $TaskName $TaskPath $Port 30
    Assert-LegacyListenerCodeIdentity $restored $ListenerSnapshot
    if ($temporarilyEnabled) {
        Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Out-Null
    }
}

function Disable-LegacyTaskAfterCutover {
    param([Parameter(Mandatory)][string]$TaskName, [string]$TaskPath = '\')
    Assert-SafeTaskName $TaskName
    Assert-SafeTaskPath $TaskPath
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction SilentlyContinue
    if ($null -eq $task) { return }
    Disable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Out-Null
}

function Restore-LegacyTask {
    param([Parameter(Mandatory)][psobject]$Snapshot, [Parameter(Mandatory)][string]$TaskName)
    if (-not $Snapshot.Exists) { return }
    if ([string]::IsNullOrWhiteSpace([string]$Snapshot.Xml)) { throw "Legacy task backup is empty: $TaskName" }
    $taskPath = if ($null -ne $Snapshot.PSObject.Properties['TaskPath']) { [string]$Snapshot.TaskPath } else { '\' }
    Assert-SafeTaskName $TaskName
    Assert-SafeTaskPath $taskPath
    # Force is intentional here: rollback must restore the saved definition,
    # not merely toggle the state of the task created by the failed install.
    Register-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Xml ([string]$Snapshot.Xml) -Force -ErrorAction Stop | Out-Null
    if ($Snapshot.Enabled) { Enable-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction Stop | Out-Null }
    if ([string]$Snapshot.State -eq 'Running') { Start-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction Stop }
}

function Register-CodexCollectorTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$OperatorName,
        [Parameter(Mandatory)][string]$NodeExecutable,
        [Parameter(Mandatory)][string]$ApiDirectory,
        [Parameter(Mandatory)][string]$SecretFile
    )
    Assert-ExistingFile $NodeExecutable 'Codex collector runtime'
    Assert-ExistingDirectory $ApiDirectory 'Codex collector working directory'
    Assert-ExistingFile $SecretFile 'Codex collector secret'
    $collector = Join-Path $ApiDirectory 'dist\codex-collector.js'
    Assert-ExistingFile $collector 'Codex collector entry point'
    $esc = { param([string]$Value) [Security.SecurityElement]::Escape($Value) }
    $nodeXml = & $esc $NodeExecutable
    $secretXml = & $esc $SecretFile
    $argsXml = & $esc ('"' + $collector + '" --secret-file "' + $secretXml + '"')
    $workXml = & $esc $ApiDirectory
    $userXml = & $esc $OperatorName
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>LifeOS Codex usage collector</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>$userXml</UserId><Repetition><Interval>PT5M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>$userXml</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT2M</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>$nodeXml</Command><Arguments>$argsXml</Arguments><WorkingDirectory>$workXml</WorkingDirectory></Exec></Actions>
</Task>
"@
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $xml -Force -ErrorAction Stop | Out-Null
}

function Start-CodexCollectorAndVerify {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][uri]$UsageUri,
        [int]$TimeoutSeconds = 45
    )
    Assert-SafeTaskName $TaskName
    $startedAt = Get-Date
    Start-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $completed = $false
    do {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        if ($info.LastRunTime -ge $startedAt.AddSeconds(-2) -and [string]$task.State -ne 'Running') {
            if ([int]$info.LastTaskResult -ne 0) {
                throw ('Codex collector task failed with result {0}.' -f $info.LastTaskResult)
            }
            $completed = $true
            break
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (-not $completed) { throw 'Codex collector task did not complete successfully before cutover.' }
    if (-not (Wait-CodexUsageObservation $UsageUri $TimeoutSeconds $startedAt)) {
        throw 'Codex collector completed but /api/usage did not expose an observation from this run.'
    }
}

function Wait-CodexUsageObservation {
    param([Parameter(Mandatory)][uri]$Uri, [int]$TimeoutSeconds = 45, [Parameter(Mandatory)][datetime]$NotBefore)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $body = $response.Content | ConvertFrom-Json -ErrorAction Stop
                foreach ($window in @($body.windows)) {
                    if ([string]$window.provider -ne 'codex' -or [string]$window.availability -ne 'observed') { continue }
                    try {
                        $observedAt = [DateTimeOffset]::Parse([string]$window.provenance.observedAt).UtcDateTime
                        if ($observedAt -ge $NotBefore.ToUniversalTime()) { return $true }
                    } catch { }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Restore-CodexCollectorTask {
    param([Parameter(Mandatory)][psobject]$Snapshot, [Parameter(Mandatory)][string]$TaskName)
    Assert-SafeTaskName $TaskName
    if ($Snapshot.Exists) {
        Restore-LegacyTask $Snapshot $TaskName
        return
    }
    $taskPath = if ($null -ne $Snapshot.PSObject.Properties['TaskPath']) { [string]$Snapshot.TaskPath } else { '\' }
    Assert-SafeTaskPath $taskPath
    $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if ($null -ne $task) {
        # This is the newly-created, non-legacy task. Removing it restores the
        # exact pre-install state; the legacy task has a separate name/path.
        Unregister-ScheduledTask -TaskName $TaskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
    }
}

function Get-ServiceRecord {
    param([Parameter(Mandatory)][string]$Name)
    $record = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction SilentlyContinue
    if ($null -eq $record) { return $null }
    return $record
}

function Get-ServiceDependencies {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) { return @() }
    return @($service.ServicesDependedOn | ForEach-Object { [string]$_.Name })
}

function Get-SnapshotValue {
    param([Parameter(Mandatory)][psobject]$Snapshot, [Parameter(Mandatory)][string]$Name, [object]$Default = $null)
    if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains($Name)) { return $Snapshot[$Name] }
    $property = $Snapshot.PSObject.Properties[$Name]
    if ($null -ne $property) { return $property.Value }
    return $Default
}

function Get-LifeOSServiceRegistrySnapshot {
    param([Parameter(Mandatory)][string]$Name)
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    $properties = Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop
    $delayedProperty = $properties.PSObject.Properties['DelayedAutoStart']
    $sidProperty = $properties.PSObject.Properties['ServiceSidType']
    $failureProperty = $properties.PSObject.Properties['FailureActions']
    $failureFlagProperty = $properties.PSObject.Properties['FailureActionsOnNonCrashFailures']
    $sidType = $null
    if ($null -ne $sidProperty) {
        $sidType = switch ([int]$sidProperty.Value) {
            0 { 'none'; break }
            1 { 'unrestricted'; break }
            2 { 'restricted'; break }
            default { throw "Unsupported ServiceSidType for ${Name}: $($sidProperty.Value)" }
        }
    }
    $failureActions = @()
    if ($null -ne $failureProperty) {
        $failureActions = @([byte[]]$failureProperty.Value | ForEach-Object { [int]$_ })
    }
    return [ordered]@{
        DelayedAutoStartPresent = ($null -ne $delayedProperty)
        DelayedAutoStart = if ($null -ne $delayedProperty) { [int]$delayedProperty.Value } else { $null }
        ServiceSidTypePresent = ($null -ne $sidProperty)
        ServiceSidType = $sidType
        FailureActionsPresent = ($null -ne $failureProperty)
        FailureActions = $failureActions
        FailureFlagPresent = ($null -ne $failureFlagProperty)
        FailureFlag = if ($null -ne $failureFlagProperty) { [int]$failureFlagProperty.Value } else { $null }
    }
}

function Restore-LifeOSServiceRegistrySnapshot {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][psobject]$Snapshot)
    $registryPath = "HKLM:\SYSTEM\CurrentControlSet\Services\$Name"
    if (-not (Test-Path -LiteralPath $registryPath)) { throw "Service registry key is missing: $Name" }

    $delayedPresent = [bool](Get-SnapshotValue $Snapshot 'DelayedAutoStartPresent' $false)
    if ($delayedPresent) {
        New-ItemProperty -LiteralPath $registryPath -Name 'DelayedAutoStart' -PropertyType DWord -Value ([int](Get-SnapshotValue $Snapshot 'DelayedAutoStart' 0)) -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $registryPath -Name 'DelayedAutoStart' -ErrorAction SilentlyContinue
    }

    $sidPresent = [bool](Get-SnapshotValue $Snapshot 'ServiceSidTypePresent' $false)
    $sidType = [string](Get-SnapshotValue $Snapshot 'ServiceSidType' 'none')
    if ($sidType -notin @('none', 'unrestricted', 'restricted')) { throw "Unsupported prior service SID mode for ${Name}: $sidType" }
    Invoke-NativeChecked 'sc.exe' @('sidtype', $Name, $sidType) -Quiet | Out-Null
    if (-not $sidPresent) {
        Remove-ItemProperty -LiteralPath $registryPath -Name 'ServiceSidType' -ErrorAction SilentlyContinue
    }

    $failurePresent = [bool](Get-SnapshotValue $Snapshot 'FailureActionsPresent' $false)
    if ($failurePresent) {
        $failureBytes = [byte[]]@((Get-SnapshotValue $Snapshot 'FailureActions' @()) | ForEach-Object { [byte][int]$_ })
        New-ItemProperty -LiteralPath $registryPath -Name 'FailureActions' -PropertyType Binary -Value $failureBytes -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $registryPath -Name 'FailureActions' -ErrorAction SilentlyContinue
    }

    $failureFlagPresent = [bool](Get-SnapshotValue $Snapshot 'FailureFlagPresent' $false)
    if ($failureFlagPresent) {
        New-ItemProperty -LiteralPath $registryPath -Name 'FailureActionsOnNonCrashFailures' -PropertyType DWord -Value ([int](Get-SnapshotValue $Snapshot 'FailureFlag' 0)) -Force | Out-Null
    } else {
        Remove-ItemProperty -LiteralPath $registryPath -Name 'FailureActionsOnNonCrashFailures' -ErrorAction SilentlyContinue
    }
}

function Get-LifeOSServiceSnapshot {
    param([Parameter(Mandatory)][string]$Name)
    Assert-SafeTaskName $Name
    $record = Get-ServiceRecord $Name
    if ($null -eq $record) {
        return [ordered]@{ Name = $Name; Exists = $false; State = 'Stopped'; StartMode = 'Disabled'; StartName = $null; BinaryPath = $null; Dependencies = @(); DelayedAutoStartPresent = $false; DelayedAutoStart = $null; ServiceSidTypePresent = $false; ServiceSidType = $null; FailureActionsPresent = $false; FailureActions = @(); FailureFlagPresent = $false; FailureFlag = $null }
    }
    $registry = Get-LifeOSServiceRegistrySnapshot $Name
    return [ordered]@{
        Name = $Name
        Exists = $true
        State = [string]$record.State
        StartMode = [string]$record.StartMode
        StartName = [string]$record.StartName
        BinaryPath = [string]$record.PathName
        Dependencies = @(Get-ServiceDependencies $Name)
        DelayedAutoStartPresent = $registry.DelayedAutoStartPresent
        DelayedAutoStart = $registry.DelayedAutoStart
        ServiceSidTypePresent = $registry.ServiceSidTypePresent
        ServiceSidType = $registry.ServiceSidType
        FailureActionsPresent = $registry.FailureActionsPresent
        FailureActions = $registry.FailureActions
        FailureFlagPresent = $registry.FailureFlagPresent
        FailureFlag = $registry.FailureFlag
    }
}

function Restore-LifeOSServiceSnapshot {
    param([Parameter(Mandatory)][psobject]$Snapshot)
    $name = [string](Get-SnapshotValue $Snapshot 'Name' '')
    $exists = [bool](Get-SnapshotValue $Snapshot 'Exists' $false)
    $startModeValue = [string](Get-SnapshotValue $Snapshot 'StartMode' '')
    $stateValue = [string](Get-SnapshotValue $Snapshot 'State' '')
    $binaryPath = [string](Get-SnapshotValue $Snapshot 'BinaryPath' '')
    $startName = [string](Get-SnapshotValue $Snapshot 'StartName' '')
    $dependencyValues = Get-SnapshotValue $Snapshot 'Dependencies' @()
    Assert-SafeTaskName $name
    $current = Get-ServiceRecord $name
    if (-not $exists) {
        if ($null -ne $current) {
            Stop-LifeOSService $name
            Invoke-NativeChecked 'sc.exe' @('delete', $name) -Quiet | Out-Null
        }
        return
    }
    if ($null -eq $current) { throw "Cannot restore missing pre-existing service: $name" }
    $startMode = switch ($startModeValue) {
        'Auto' { 'auto'; break }
        'Manual' { 'demand'; break }
        'Disabled' { 'disabled'; break }
        default { throw "Unsupported prior start mode for ${name}: $startModeValue" }
    }
    $dependencies = @($dependencyValues) -join '/'
    if ([string]::IsNullOrWhiteSpace($binaryPath) -or [string]::IsNullOrWhiteSpace($startName)) {
        throw "Prior service configuration is incomplete: $name"
    }
    Invoke-NativeChecked 'sc.exe' @('config', $name, 'binPath=', $binaryPath, 'obj=', $startName, 'password=', '', 'start=', $startMode, 'depend=', $dependencies) -Quiet | Out-Null
    Restore-LifeOSServiceRegistrySnapshot $name $Snapshot
    if ($stateValue -eq 'Running') { Start-Service -Name $name -ErrorAction Stop }
    else { Stop-LifeOSService $name }
}

function Assert-ServiceIdentity {
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$ExpectedAccount, [Parameter(Mandatory)][string]$ExpectedBinary)
    $record = Get-ServiceRecord $Name
    if ($null -eq $record) { return }
    if ([string]$record.StartName -ne $ExpectedAccount) { throw "Existing service $Name has an unexpected account; refusing to take it over." }
    if ([string]$record.PathName -notlike ("*{0}*" -f $ExpectedBinary)) { throw "Existing service $Name has an unexpected binary path." }
}

function New-ServiceOrConfigure {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BinaryPath,
        [Parameter(Mandatory)][ValidateSet('auto','delayed-auto')][string]$StartMode,
        [Parameter(Mandatory)][string]$Account,
        [string[]]$Dependencies = @()
    )
    $quoted = '"{0}" --service-name {1} --config "{2}"' -f $BinaryPath, $Name, (Join-Path (Split-Path -Parent $BinaryPath) ('config\' + $Name + '.json'))
    $existing = Get-ServiceRecord $Name
    if ($null -eq $existing) {
        Invoke-NativeChecked 'sc.exe' @('create', $Name, 'binPath=', $quoted, 'obj=', $Account, 'password=', '', 'start=', $StartMode) -Quiet | Out-Null
    } else {
        Assert-ServiceIdentity -Name $Name -ExpectedAccount $Account -ExpectedBinary $BinaryPath
        Invoke-NativeChecked 'sc.exe' @('config', $Name, 'binPath=', $quoted, 'obj=', $Account, 'password=', '', 'start=', $StartMode) -Quiet | Out-Null
    }
    Invoke-NativeChecked 'sc.exe' @('sidtype', $Name, 'unrestricted') -Quiet | Out-Null
    $dependencyValue = ($Dependencies -join '/')
    if ($Dependencies.Count -eq 0) {
        Invoke-NativeChecked 'sc.exe' @('config', $Name, 'depend=', '') -Quiet | Out-Null
    } else {
        Invoke-NativeChecked 'sc.exe' @('config', $Name, 'depend=', $dependencyValue) -Quiet | Out-Null
    }
    Invoke-NativeChecked 'sc.exe' @('failure', $Name, 'reset=', '86400', 'actions=', 'restart/60000/restart/60000/restart/60000') -Quiet | Out-Null
    Invoke-NativeChecked 'sc.exe' @('failureflag', $Name, '1') -Quiet | Out-Null
}

function Stop-LifeOSService {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -ne $service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
    }
}

function Start-LifeOSService {
    param([Parameter(Mandatory)][string]$Name)
    Start-Service -Name $Name -ErrorAction Stop
}

function Wait-LoopbackHealth {
    param([Parameter(Mandatory)][uri]$Uri, [int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { return $true }
        } catch { }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Wait-PortFree {
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
        if ($listeners.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Assert-LoopbackUri {
    param([Parameter(Mandatory)][uri]$Uri, [Parameter(Mandatory)][int]$Port)
    if ($Uri.Scheme -ne 'http' -or $Uri.Port -ne $Port -or $Uri.AbsolutePath -ne '/health' -or
        $Uri.Host -notin @('127.0.0.1', 'localhost', '::1') -or $Uri.Query -or $Uri.Fragment -or $Uri.UserInfo) {
        throw "Health URI is not the expected loopback endpoint on port $Port."
    }
}

function Get-TailscaleStatusJson {
    param([Parameter(Mandatory)][string]$TailscaleExecutable)
    Assert-ExistingFile $TailscaleExecutable 'Tailscale executable'
    $result = Invoke-NativeChecked $TailscaleExecutable @('serve', 'status', '--json')
    return ($result.Output -join "`n")
}

function ConvertFrom-TailscaleServeJson {
    param([Parameter(Mandatory)][string]$Json)
    try {
        $state = $Json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Tailscale Serve returned invalid JSON; refusing to inspect or mutate its configuration.'
    }
    if ($null -eq $state -or $state -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Tailscale Serve returned a non-object JSON document; refusing to inspect or mutate its configuration.'
    }
    return $state
}

function Get-TailscalePropertyValue {
    param([object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-TruthyTailscaleFlags {
    param(
        [object]$Value,
        [string]$PropertyName = '',
        [switch]$InsideFunnelFlag
    )
    $found = New-Object System.Collections.ArrayList
    $flagContext = $InsideFunnelFlag -or $PropertyName -match '^(?i:Funnel|AllowFunnel)$'
    if ($null -eq $Value) { return @($found) }
    if ($Value -is [bool]) {
        if ($flagContext -and [bool]$Value) { [void]$found.Add($PropertyName) }
        return @($found)
    }
    if ($Value -is [string]) {
        if ($flagContext -and $Value -ieq 'true') { [void]$found.Add($PropertyName) }
        return @($found)
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            foreach ($nested in @(Get-TruthyTailscaleFlags -Value $property.Value -PropertyName $property.Name -InsideFunnelFlag:$flagContext)) {
                [void]$found.Add($nested)
            }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) {
            foreach ($nested in @(Get-TruthyTailscaleFlags -Value $item -PropertyName $PropertyName -InsideFunnelFlag:$flagContext)) {
                [void]$found.Add($nested)
            }
        }
    }
    return @($found)
}

function Get-TailscaleProxyTargets {
    param([Parameter(Mandatory)][object]$Value)
    $found = New-Object System.Collections.ArrayList
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -eq 'Proxy' -and $property.Value -is [string]) { [void]$found.Add([string]$property.Value) }
            foreach ($nested in (Get-TailscaleProxyTargets $property.Value)) { [void]$found.Add($nested) }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { foreach ($nested in (Get-TailscaleProxyTargets $item)) { [void]$found.Add($nested) } }
    }
    return @($found)
}

function Test-TailscaleValueEmpty {
    param([object]$Value)
    if ($null -eq $Value -or $Value -is [bool] -and -not [bool]$Value) { return $true }
    if ($Value -is [string]) { return [string]::IsNullOrEmpty($Value) }
    if ($Value -is [System.Collections.IDictionary]) { return $Value.Count -eq 0 }
    if ($Value -is [System.Management.Automation.PSCustomObject]) { return @($Value.PSObject.Properties).Count -eq 0 }
    if ($Value -is [System.Collections.IEnumerable]) { return @($Value).Count -eq 0 }
    return $false
}

function Get-TailscaleEndpointPortRange {
    param([Parameter(Mandatory)][string]$EndpointKey)
    $match = [regex]::Match($EndpointKey, '(?i)(?:^|:)(?<start>[0-9]{1,5})(?:-(?<end>[0-9]{1,5}))?(?:$|[/])')
    if (-not $match.Success) { return $null }
    $start = [int]$match.Groups['start'].Value
    $end = if ($match.Groups['end'].Success) { [int]$match.Groups['end'].Value } else { $start }
    if ($start -lt 1 -or $end -gt 65535 -or $end -lt $start) {
        throw "Tailscale Serve endpoint has an invalid port range: $EndpointKey"
    }
    return [pscustomobject]@{ Start = $start; End = $end }
}

function Test-TailscaleEndpointUsesPort {
    param([Parameter(Mandatory)][string]$EndpointKey, [Parameter(Mandatory)][int]$Port)
    $range = Get-TailscaleEndpointPortRange $EndpointKey
    if ($null -eq $range) { return $false }
    return $range.Start -le $Port -and $range.End -ge $Port
}

function Test-TailscaleHttpsEndpointExact {
    param([Parameter(Mandatory)][string]$EndpointKey, [int]$Port = 8420)
    try { $uri = [Uri]$EndpointKey } catch { return $false }
    if ($null -eq $uri -or -not $uri.IsAbsoluteUri) { return $false }
    return ($uri.Scheme -ieq 'https' -and $uri.Port -eq $Port -and
        $uri.AbsolutePath -eq '/' -and [string]::IsNullOrEmpty($uri.Query) -and
        [string]::IsNullOrEmpty($uri.Fragment) -and [string]::IsNullOrEmpty($uri.UserInfo) -and
        -not [string]::IsNullOrWhiteSpace($uri.Host))
}

function Test-TailscaleBareHostnameEndpointExact {
    param([Parameter(Mandatory)][string]$EndpointKey, [int]$Port = 8420)
    # `tailscale serve status --json` emits Web keys as bare DNS names, for
    # example geonqserver.tail5f8789.ts.net:8420. Keep this deliberately
    # narrower than the port-range parser: only a hostname and the exact
    # target port are accepted, never an IP, path, range, or extra field.
    $label = '[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?'
    $pattern = '^(?i:' + $label + '(?:\.' + $label + ')*):' + [regex]::Escape([string]$Port) + '$'
    return $EndpointKey -match $pattern
}

function Test-TailscaleEndpointExact {
    param([Parameter(Mandatory)][string]$EndpointKey, [int]$Port = 8420)
    return (Test-TailscaleHttpsEndpointExact -EndpointKey $EndpointKey -Port $Port) -or
        (Test-TailscaleBareHostnameEndpointExact -EndpointKey $EndpointKey -Port $Port)
}

function Test-TailscaleTrustedEdgeAppCapability {
    param([object]$Value)
    if ($Value -is [string]) {
        $values = @($Value)
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $values = @($Value | ForEach-Object { [string]$_ })
    } else {
        return $false
    }
    return ($values.Count -eq 1 -and $values[0] -ceq (Get-LifeOSTrustedEdgeCapability))
}

function Test-TailscaleWebEndpointExact {
    param([object]$Endpoint)
    if ($null -eq $Endpoint -or $Endpoint -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $endpointProperties = @($Endpoint.PSObject.Properties)
    if ($endpointProperties.Count -ne 1 -or $endpointProperties[0].Name -ne 'Handlers') { return $false }
    $handlers = Get-TailscalePropertyValue -Object $Endpoint -Name 'Handlers'
    if ($handlers -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $handlerProperties = @($handlers.PSObject.Properties)
    if ($handlerProperties.Count -ne 1 -or $handlerProperties[0].Name -ne '/') { return $false }
    $handler = Get-TailscalePropertyValue -Object $handlers -Name '/'
    if ($handler -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $handlerFields = @($handler.PSObject.Properties)
    if ($handlerFields.Count -ne 2 -or
        @($handlerFields.Name | Where-Object { $_ -notin @('Proxy', 'AcceptAppCaps') }).Count -ne 0) {
        return $false
    }
    return ([string](Get-TailscalePropertyValue -Object $handler -Name 'Proxy') -eq 'http://127.0.0.1:8421' -and
        (Test-TailscaleTrustedEdgeAppCapability (Get-TailscalePropertyValue -Object $handler -Name 'AcceptAppCaps')))
}

function Test-TailscaleWebEndpointLegacyMapping {
    param(
        [Parameter(Mandatory)][string]$EndpointKey,
        [object]$Endpoint
    )
    if (-not (Test-TailscaleEndpointExact -EndpointKey $EndpointKey -Port 8420)) { return $false }
    if ($null -eq $Endpoint -or $Endpoint -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $endpointProperties = @($Endpoint.PSObject.Properties)
    if ($endpointProperties.Count -ne 1 -or $endpointProperties[0].Name -cne 'Handlers') { return $false }
    $handlers = Get-TailscalePropertyValue -Object $Endpoint -Name 'Handlers'
    if ($handlers -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $handlerProperties = @($handlers.PSObject.Properties)
    if ($handlerProperties.Count -ne 1 -or $handlerProperties[0].Name -cne '/') { return $false }
    $handler = Get-TailscalePropertyValue -Object $handlers -Name '/'
    if ($handler -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $handlerFields = @($handler.PSObject.Properties)
    if ($handlerFields.Count -ne 1 -or $handlerFields[0].Name -cne 'Proxy') { return $false }
    return ([string](Get-TailscalePropertyValue -Object $handler -Name 'Proxy') -ceq 'http://127.0.0.1:8421')
}

function Test-TailscaleServeTcpHttpsMirror {
    param([Parameter(Mandatory)][psobject]$Record)
    if ([string]$Record.Section -cne 'TCP' -or [string]$Record.Key -cne '8420') { return $false }
    $value = $Record.Value
    if ($null -eq $value -or $value -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $fields = @($value.PSObject.Properties)
    if ($fields.Count -ne 1 -or $fields[0].Name -cne 'HTTPS') { return $false }
    return ($fields[0].Value -is [bool] -and [bool]$fields[0].Value)
}

function Get-TailscaleServiceEndpointRecords {
    param([object]$Value, [string]$Path = 'Services')
    $found = New-Object System.Collections.ArrayList
    if (Test-TailscaleValueEmpty $Value) { return @($found) }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            $childPath = "$Path.$($property.Name)"
            if ($property.Name -ieq 'endpoints') {
                if ($property.Value -isnot [System.Management.Automation.PSCustomObject]) {
                    throw "Tailscale Serve service endpoints are not an inspectable object: $childPath"
                }
                foreach ($endpoint in $property.Value.PSObject.Properties) {
                    if (Test-TailscaleEndpointUsesPort -EndpointKey ([string]$endpoint.Name) -Port 8420) {
                        [void]$found.Add([pscustomobject]@{
                            Section = 'Services'
                            Key = [string]$endpoint.Name
                            Path = $childPath
                            Value = $endpoint.Value
                        })
                    }
                }
            } else {
                foreach ($nested in @(Get-TailscaleServiceEndpointRecords -Value $property.Value -Path $childPath)) {
                    [void]$found.Add($nested)
                }
            }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $index = 0
        foreach ($item in $Value) {
            foreach ($nested in @(Get-TailscaleServiceEndpointRecords -Value $item -Path "$Path[$index]")) {
                [void]$found.Add($nested)
            }
            $index++
        }
    } else {
        throw "Tailscale Serve services contain an uninspectable value at $Path."
    }
    return @($found)
}

function Get-TailscaleServeEndpointRecords {
    param([Parameter(Mandatory)][psobject]$State)
    $found = New-Object System.Collections.ArrayList
    foreach ($sectionName in @('Web', 'TCP')) {
        $section = Get-TailscalePropertyValue -Object $State -Name $sectionName
        if (Test-TailscaleValueEmpty $section) { continue }
        if ($section -isnot [System.Management.Automation.PSCustomObject]) {
            throw "Tailscale Serve $sectionName configuration is not an inspectable object."
        }
        foreach ($endpoint in $section.PSObject.Properties) {
            if (Test-TailscaleEndpointUsesPort -EndpointKey ([string]$endpoint.Name) -Port 8420) {
                [void]$found.Add([pscustomobject]@{
                    Section = $sectionName
                    Key = [string]$endpoint.Name
                    Path = $sectionName
                    Value = $endpoint.Value
                })
            }
        }
    }
    $services = Get-TailscalePropertyValue -Object $State -Name 'Services'
    foreach ($record in @(Get-TailscaleServiceEndpointRecords -Value $services)) { [void]$found.Add($record) }
    return @($found)
}

function Get-TailscaleServeDecision {
    param([Parameter(Mandatory)][string]$Json)
    $state = ConvertFrom-TailscaleServeJson $Json
    $known = @('Web', 'TCP', 'Services', 'AllowFunnel', 'Foreground')
    foreach ($property in $state.PSObject.Properties) {
        if ($property.Name -notin $known -and -not (Test-TailscaleValueEmpty $property.Value)) {
            throw "Tailscale Serve returned an unsupported non-empty field: $($property.Name)"
        }
    }
    $truthyFlags = @(Get-TruthyTailscaleFlags -Value $state)
    if ($truthyFlags.Count -gt 0) {
        throw "Tailscale Serve reports a public-tunnel flag ($($truthyFlags -join ', ')); refusing to proceed."
    }
    $foreground = Get-TailscalePropertyValue -Object $state -Name 'Foreground'
    if (-not (Test-TailscaleValueEmpty $foreground)) {
        throw 'Tailscale Serve is in foreground or otherwise non-canonical mode; refusing to take ownership.'
    }
    $records = @(Get-TailscaleServeEndpointRecords -State $state)
    $targetRecords = @($records | Where-Object { $_.Section -eq 'Web' -and (Test-TailscaleEndpointUsesPort -EndpointKey ([string]$_.Key) -Port 8420) })
    $tcpRecords = @($records | Where-Object { $_.Section -eq 'TCP' })
    $serviceRecords = @($records | Where-Object { $_.Section -eq 'Services' })
    # Get-TailscaleServeEndpointRecords already filters Web/TCP/Services to
    # port 8420. Non-8420 Web routes are deliberately absent here and must be
    # allowed to coexist unchanged.
    if ($targetRecords.Count -gt 1) {
        throw 'Tailscale Serve has multiple Web endpoints on port 8420; refusing an ambiguous route.'
    }
    if ($targetRecords.Count -eq 1) {
        $targetRange = Get-TailscaleEndpointPortRange ([string]$targetRecords[0].Key)
        if ($null -eq $targetRange -or $targetRange.Start -ne 8420 -or $targetRange.End -ne 8420) {
            throw 'Tailscale Serve route/port range covers 8420; refusing an ambiguous ownership decision.'
        }
        if (-not (Test-TailscaleEndpointExact -EndpointKey ([string]$targetRecords[0].Key) -Port 8420)) {
            throw 'Tailscale Serve route/port 8420 is not an exact HTTPS endpoint; refusing an ambiguous ownership decision.'
        }
        $nonMirrorTcp = @($tcpRecords | Where-Object { -not (Test-TailscaleServeTcpHttpsMirror $_) })
        if ($nonMirrorTcp.Count -gt 0 -or $serviceRecords.Count -gt 0) {
            throw 'Tailscale Serve port 8420 is already occupied by a non-LifeOS endpoint; refusing a port collision.'
        }
        $isConfigured = Test-TailscaleWebEndpointExact $targetRecords[0].Value
        $isLegacy = Test-TailscaleWebEndpointLegacyMapping -EndpointKey ([string]$targetRecords[0].Key) -Endpoint $targetRecords[0].Value
        if (-not $isConfigured -and -not $isLegacy) {
            throw 'Tailscale Serve route/port 8420 is occupied by a non-LifeOS mapping; refusing to overwrite it.'
        }
        $action = if ($isConfigured) { 'AlreadyConfigured' } else { 'UpgradeLegacyMapping' }
        return [pscustomobject]@{
            Action = $action
            State = $state
            TargetEndpoint = [string]$targetRecords[0].Key
            TargetPort = 8420
            TargetPath = '/'
            TargetProxy = 'http://127.0.0.1:8421'
            TcpMirrorCount = @($tcpRecords | Where-Object { Test-TailscaleServeTcpHttpsMirror $_ }).Count
        }
    }
    if ($tcpRecords.Count -gt 0 -or $serviceRecords.Count -gt 0) {
        throw 'Tailscale Serve port 8420 is already occupied by a non-LifeOS endpoint; refusing a port collision.'
    }
    return [pscustomobject]@{
        Action = 'Add'
        State = $state
        TargetEndpoint = $null
        TargetPort = 8420
        TargetPath = '/'
        TargetProxy = 'http://127.0.0.1:8421'
    }
}

function ConvertTo-TailscaleCanonicalValue {
    param([object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        foreach ($property in @($Value.PSObject.Properties | Sort-Object -Property Name)) {
            $ordered[$property.Name] = ConvertTo-TailscaleCanonicalValue $property.Value
        }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object { [string]$_ })) {
            $ordered[[string]$key] = ConvertTo-TailscaleCanonicalValue $Value[$key]
        }
        return [pscustomobject]$ordered
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = New-Object System.Collections.ArrayList
        foreach ($item in $Value) { [void]$items.Add((ConvertTo-TailscaleCanonicalValue $item)) }
        return ,([object[]]$items)
    }
    return $Value
}

function Remove-LifeOSTailscaleServeRoute {
    param([Parameter(Mandatory)][string]$TailscaleExecutable)
    $trustedCapabilityArgument = '--accept-app-caps=' + (Get-LifeOSTrustedEdgeCapability)
    Invoke-NativeChecked $TailscaleExecutable @('serve', '--yes', $trustedCapabilityArgument, '--https=8420', '--set-path=/', 'off') -Quiet | Out-Null
    $after = Get-TailscaleStatusJson $TailscaleExecutable
    $decision = Get-TailscaleServeDecision $after
    if ($decision.Action -ne 'Add') { throw 'Targeted Tailscale Serve rollback did not remove the LifeOS route.' }
    return $after
}

function Get-TailscaleServeFingerprint {
    param([Parameter(Mandatory)][string]$Json, [switch]$ExcludeLifeOSRoute)
    $state = ConvertFrom-TailscaleServeJson $Json
    if ($ExcludeLifeOSRoute) {
        $removedLifeOSWebRoute = $false
        $webProperty = $state.PSObject.Properties['Web']
        if ($null -ne $webProperty -and $webProperty.Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($endpoint in @($webProperty.Value.PSObject.Properties)) {
                if (Test-TailscaleEndpointUsesPort -EndpointKey ([string]$endpoint.Name) -Port 8420) {
                    $webProperty.Value.PSObject.Properties.Remove($endpoint.Name)
                    $removedLifeOSWebRoute = $true
                }
            }
            if (@($webProperty.Value.PSObject.Properties).Count -eq 0) {
                $state.PSObject.Properties.Remove('Web')
            }
        }
        # Tailscale emits TCP 8420 as a mirror for an HTTPS Web endpoint. It
        # is part of the targeted LifeOS route, not an unrelated listener, but
        # only the exact {HTTPS:true} mirror is eligible for this exclusion.
        if ($removedLifeOSWebRoute) {
            $tcpProperty = $state.PSObject.Properties['TCP']
            if ($null -ne $tcpProperty -and $tcpProperty.Value -is [System.Management.Automation.PSCustomObject]) {
                $mirrorNames = @($tcpProperty.Value.PSObject.Properties | Where-Object {
                    Test-TailscaleServeTcpHttpsMirror ([pscustomobject]@{ Section = 'TCP'; Key = [string]$_.Name; Value = $_.Value })
                } | ForEach-Object { [string]$_.Name })
                foreach ($mirrorName in $mirrorNames) { $tcpProperty.Value.PSObject.Properties.Remove($mirrorName) }
            }
        }
    }
    $canonical = ConvertTo-TailscaleCanonicalValue $state
    return [string]($canonical | ConvertTo-Json -Depth 50 -Compress)
}

function Test-TailscaleServeEmpty {
    param([Parameter(Mandatory)][string]$Json)
    try { $state = ConvertFrom-TailscaleServeJson $Json } catch { return $false }
    $known = @('Web', 'TCP', 'Services', 'AllowFunnel', 'Foreground')
    foreach ($property in $state.PSObject.Properties) {
        if ($property.Name -notin $known -and -not (Test-TailscaleValueEmpty $property.Value)) { return $false }
        if ($property.Name -in $known -and -not (Test-TailscaleValueEmpty $property.Value)) { return $false }
    }
    return $true
}

function Test-TailscaleServeExact {
    param([Parameter(Mandatory)][string]$Json)
    try {
        $decision = Get-TailscaleServeDecision $Json
        return $decision.Action -eq 'AlreadyConfigured'
    } catch {
        return $false
    }
}

function Configure-TailscaleServe {
    param([Parameter(Mandatory)][string]$TailscaleExecutable)
    Assert-ExistingFile $TailscaleExecutable 'Tailscale executable'
    $beforeStatus = Get-TailscaleStatusJson $TailscaleExecutable
    $decision = Get-TailscaleServeDecision $beforeStatus
    if ($decision.Action -eq 'AlreadyConfigured') { return $beforeStatus }
    $unrelatedBefore = Get-TailscaleServeFingerprint $beforeStatus -ExcludeLifeOSRoute
    try {
        # Tailscale Serve supports multiple mount points. This command adds
        # or upgrades only the reviewed HTTPS 8420 root route and never resets
        # other routes. The app capability is public policy metadata, not the
        # private token.
        $trustedCapabilityArgument = '--accept-app-caps=' + (Get-LifeOSTrustedEdgeCapability)
        Invoke-NativeChecked $TailscaleExecutable @('serve', '--yes', '--bg', $trustedCapabilityArgument, '--https=8420', '--set-path=/', 'http://127.0.0.1:8421') -Quiet | Out-Null
        $status = Get-TailscaleStatusJson $TailscaleExecutable
        $afterDecision = Get-TailscaleServeDecision $status
        if ($afterDecision.Action -ne 'AlreadyConfigured') { throw 'Tailscale Serve did not expose the requested LifeOS route after configuration.' }
        if ($decision.Action -eq 'UpgradeLegacyMapping' -and [string]$afterDecision.TargetEndpoint -cne [string]$decision.TargetEndpoint) {
            throw 'Tailscale Serve legacy upgrade changed the endpoint identity; refusing to accept the mutation.'
        }
        if ((Get-TailscaleServeFingerprint $status -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
            throw 'Tailscale Serve configuration changed an unrelated entry; refusing to accept the mutation.'
        }
        return $status
    } catch {
        $failure = $_
        try {
            $current = Get-TailscaleStatusJson $TailscaleExecutable
            $currentDecision = Get-TailscaleServeDecision $current
            if ((Get-TailscaleServeFingerprint $current -ExcludeLifeOSRoute) -eq $unrelatedBefore) {
                if ($decision.Action -eq 'UpgradeLegacyMapping' -and $currentDecision.Action -eq 'AlreadyConfigured') {
                    $null = Restore-TailscaleServeLegacyMapping -TailscaleExecutable $TailscaleExecutable -BeforeJson $beforeStatus -ExpectedAfterJson $current
                } elseif ($decision.Action -eq 'Add' -and $currentDecision.Action -eq 'AlreadyConfigured') {
                    $null = Remove-LifeOSTailscaleServeRoute $TailscaleExecutable
                } elseif ($currentDecision.Action -eq $decision.Action) {
                    # The command failed before changing the targeted state.
                    # No cleanup is needed; the original state is still exact.
                } else {
                    throw 'Automatic Tailscale Serve cleanup was refused because the targeted state is ambiguous.'
                }
            }
        } catch {
            throw "Tailscale Serve configuration failed and automatic cleanup was refused: $($_.Exception.Message). Original failure: $($failure.Exception.Message)"
        }
        throw $failure
    }
}

function Restore-TailscaleServeLegacyMapping {
    param(
        [Parameter(Mandatory)][string]$TailscaleExecutable,
        [Parameter(Mandatory)][string]$BeforeJson,
        [Parameter(Mandatory)][string]$ExpectedAfterJson
    )
    $beforeDecision = Get-TailscaleServeDecision $BeforeJson
    if ($beforeDecision.Action -ne 'UpgradeLegacyMapping') {
        throw 'Legacy Serve rollback requires an authenticated proxy-only legacy mapping snapshot.'
    }
    $expectedAfterDecision = Get-TailscaleServeDecision $ExpectedAfterJson
    if ($expectedAfterDecision.Action -ne 'AlreadyConfigured') {
        throw 'Legacy Serve rollback has an invalid post-install snapshot.'
    }
    $unrelatedBefore = Get-TailscaleServeFingerprint $BeforeJson -ExcludeLifeOSRoute
    $current = Get-TailscaleStatusJson $TailscaleExecutable
    if ((Get-TailscaleServeFingerprint $current) -ne (Get-TailscaleServeFingerprint $ExpectedAfterJson) -or
        (Get-TailscaleServeFingerprint $current -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
        throw 'Automatic Serve rollback is refused because the authenticated post-install state changed.'
    }

    # Remove only the reviewed 8420 root route, then recreate its original
    # proxy-only shape. This is intentionally not `tailscale serve reset`.
    $trustedCapabilityArgument = '--accept-app-caps=' + (Get-LifeOSTrustedEdgeCapability)
    Invoke-NativeChecked $TailscaleExecutable @('serve', '--yes', $trustedCapabilityArgument, '--https=8420', '--set-path=/', 'off') -Quiet | Out-Null
    $afterOff = Get-TailscaleStatusJson $TailscaleExecutable
    $afterOffDecision = Get-TailscaleServeDecision $afterOff
    if ($afterOffDecision.Action -ne 'Add' -or
        (Get-TailscaleServeFingerprint $afterOff -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
        throw 'Legacy Serve rollback changed the route set while removing the LifeOS mapping; refusing to continue.'
    }

    # Omitting AcceptAppCaps is deliberate: the pre-install handler was
    # exactly proxy-only. The final authenticated snapshot comparison below
    # proves that Tailscale restored the same Web/TCP representation.
    Invoke-NativeChecked $TailscaleExecutable @('serve', '--yes', '--bg', '--https=8420', '--set-path=/', 'http://127.0.0.1:8421') -Quiet | Out-Null
    $restored = Get-TailscaleStatusJson $TailscaleExecutable
    $restoredDecision = Get-TailscaleServeDecision $restored
    if ($restoredDecision.Action -ne 'UpgradeLegacyMapping' -or
        [string]$restoredDecision.TargetEndpoint -cne [string]$beforeDecision.TargetEndpoint -or
        (Get-TailscaleServeFingerprint $restored) -ne (Get-TailscaleServeFingerprint $BeforeJson) -or
        (Get-TailscaleServeFingerprint $restored -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
        throw 'Legacy Serve rollback did not restore the exact pre-install proxy-only mapping.'
    }
}

function Restore-TailscaleServeSnapshot {
    param(
        [Parameter(Mandatory)][string]$TailscaleExecutable,
        [Parameter(Mandatory)][string]$Json,
        [string]$ExpectedAfterJson
    )
    $beforeDecision = Get-TailscaleServeDecision $Json
    $current = Get-TailscaleStatusJson $TailscaleExecutable
    if ($beforeDecision.Action -eq 'AlreadyConfigured') {
        if ((Get-TailscaleServeFingerprint $current) -ne (Get-TailscaleServeFingerprint $Json)) {
            throw 'Automatic Serve rollback is refused because a pre-existing LifeOS or unrelated Serve entry changed after the snapshot.'
        }
        return
    }
    $unrelatedBefore = Get-TailscaleServeFingerprint $Json -ExcludeLifeOSRoute
    $currentDecision = Get-TailscaleServeDecision $current
    if ($beforeDecision.Action -eq 'Add' -and $currentDecision.Action -eq 'Add') {
        if ((Get-TailscaleServeFingerprint $current -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
            throw 'Automatic Serve rollback is refused because unrelated Serve entries changed after the snapshot.'
        }
        return
    }
    if ([string]::IsNullOrWhiteSpace($ExpectedAfterJson)) {
        throw 'Automatic Serve rollback is refused because the install has no authenticated post-mutation Serve snapshot.'
    }
    if ((Get-TailscaleServeFingerprint $current) -ne (Get-TailscaleServeFingerprint $ExpectedAfterJson)) {
        throw 'Automatic Serve rollback is refused because the authenticated post-install Serve state changed.'
    }
    if ((Get-TailscaleServeFingerprint $current -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
        throw 'Automatic Serve rollback is refused because unrelated Serve entries changed after cutover.'
    }
    if ($beforeDecision.Action -eq 'UpgradeLegacyMapping') {
        $null = Restore-TailscaleServeLegacyMapping -TailscaleExecutable $TailscaleExecutable -BeforeJson $Json -ExpectedAfterJson $ExpectedAfterJson
        return
    }
    if ($beforeDecision.Action -ne 'Add' -or $currentDecision.Action -ne 'AlreadyConfigured') {
        throw 'Automatic Serve rollback encountered an unsupported targeted state.'
    }
    $after = Remove-LifeOSTailscaleServeRoute $TailscaleExecutable
    if ((Get-TailscaleServeFingerprint $after) -ne (Get-TailscaleServeFingerprint $Json)) {
        throw 'Serve rollback did not restore the exact pre-install route state.'
    }
    if ((Get-TailscaleServeFingerprint $after -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
        throw 'Serve rollback changed an unrelated entry; refusing to report success.'
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value)
    $parent = Split-Path -Parent (Get-FullPath $Path)
    Ensure-Directory $parent
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Path) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth 20
        [IO.File]::WriteAllText($temp, $json, [Text.UTF8Encoding]::new($false))
        Assert-NoReparsePath $temp
        Move-Item -LiteralPath $temp -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-PathOnlyJson {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    if ($raw -match '(?i)(bearer|password|token|secret-value|api[-_]?key|private[-_]?key)\s*[:=]') {
        throw "Path-only config contains a secret-like field: $Path"
    }
    $null = $raw | ConvertFrom-Json -ErrorAction Stop
}
