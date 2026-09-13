[CmdletBinding()]
param(
    [string]$ManifestPath,
    [string]$TailscaleExecutable,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$TailscaleSnapshotTaskName = 'LifeOSTailscaleSnapshot',
    [string]$CandidateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

# Override the shared helper for this verifier: the SCM contract is stricter
# than a generic JSON readiness check and requires the exact response bytes.
function Wait-LoopbackReadiness {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [int]$TimeoutSeconds = 45
    )
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Method Get -MaximumRedirection 0 -TimeoutSec 3
            if ($response.StatusCode -eq 200 -and [string]$response.Content -ceq '{"readiness":"ready"}') {
                return $true
            }
        } catch {
            # The service may still be binding its listener or deliberately
            # reject a non-contract response while it is warming up.
        }
        Start-Sleep -Milliseconds 250
    }
    return $false
}

function Assert-ServiceHostProbeContract {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$Name
    )
    $config = Read-LifeOSBoundedJsonFile -Path $ConfigPath -MaxBytes 65536 -Description "$Name service config"
    $expectedHealth = "http://127.0.0.1:${Port}/health"
    $expectedReadiness = "http://127.0.0.1:${Port}/ready"
    if ([string]$config.healthUrl -cne $expectedHealth -or [string]$config.readinessUrl -cne $expectedReadiness) {
        throw "$Name service config has an unexpected health/readiness probe contract."
    }
}

function Assert-VerificationMarker {
    param(
        [Parameter(Mandatory)][psobject]$Marker,
        [Parameter(Mandatory)][string]$MarkerPath,
        [Parameter(Mandatory)][string]$OperatorSid,
        [Parameter(Mandatory)][string]$BackupRoot
    )
    $required = @('schemaVersion', 'state', 'transactionId', 'generation', 'operatorSid', 'manifestPath', 'acquiredAtUtc', 'updatedAtUtc')
    $actual = @($Marker.PSObject.Properties.Name)
    if (@($actual | Where-Object { $_ -notin $required }).Count -ne 0 -or
        @($required | Where-Object { $_ -notin $actual }).Count -ne 0) {
        throw 'Deployment marker schema is unsupported; full certification is refused.'
    }
    if (-not (Test-LifeOSIntegralNumber $Marker.schemaVersion) -or [int]$Marker.schemaVersion -ne 2) {
        throw 'Deployment marker schema is unsupported; full certification is refused.'
    }
    if ([string]$Marker.state -cne 'installed') {
        throw 'Deployment marker is not in the installed terminal state; full certification is refused.'
    }
    foreach ($field in @('transactionId', 'generation', 'operatorSid', 'manifestPath', 'acquiredAtUtc', 'updatedAtUtc')) {
        $value = Get-JournalProperty $Marker $field
        if ($value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value) -or ([string]$value).Length -gt 4096) {
            throw "Deployment marker field is malformed: $field"
        }
    }
    if ([string]$Marker.transactionId -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or
        [string]$Marker.generation -notmatch '\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z' -or
        [string]$Marker.operatorSid -notmatch '\AS-1-[0-9-]+\z' -or
        [string]$Marker.operatorSid -cne $OperatorSid) {
        throw 'Deployment marker transaction identity is invalid; full certification is refused.'
    }
    foreach ($timestamp in @('acquiredAtUtc', 'updatedAtUtc')) {
        try { [void][DateTimeOffset]::Parse([string](Get-JournalProperty $Marker $timestamp)) }
        catch { throw "Deployment marker timestamp is invalid: $timestamp" }
    }
    $expectedMarkerPath = Get-FullPath (Get-LifeOSDeploymentMarkerPath)
    if ((Get-FullPath $MarkerPath) -ine $expectedMarkerPath) {
        throw 'Deployment marker path is not the canonical machine-owned marker.'
    }
    $manifestPath = Get-FullPath ([string]$Marker.manifestPath)
    $backupRootFull = (Get-FullPath $BackupRoot).TrimEnd('\')
    $manifestDirectory = (Split-Path -Parent $manifestPath).TrimEnd('\')
    $directoryName = [IO.Path]::GetFileName($manifestDirectory)
    if (-not $manifestDirectory.StartsWith($backupRootFull + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $directoryName -notmatch '\Ainstall-[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{8}\z' -or
        [IO.Path]::GetFileName($manifestPath) -cne 'manifest.json') {
        throw 'Deployment marker manifest path is outside the canonical install transaction.'
    }
    return $manifestPath
}

function Assert-ServiceContract {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Account,
        [Parameter(Mandatory)][string]$Binary,
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string[]]$Dependencies,
        [Parameter(Mandatory)][ValidateSet('auto','delayed-auto')][string]$Mode
    )
    $record = Get-ServiceRecord $Name
    if ($null -eq $record) { throw "Service is missing: $Name" }
    if ([string]$record.StartName -ne $Account) { throw "Service account mismatch: $Name" }
    $expectedInvocation = Get-LifeOSServiceInvocation -Name $Name -BinaryPath $Binary -ConfigPath $ConfigPath
    if ([string]$record.PathName -ine $expectedInvocation) { throw "Service binary, service name, config path, or extra invocation argument mismatch: $Name" }
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

function Assert-RunningLifeOSServiceProcess {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Binary,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    $record = Get-ServiceRecord $Name
    if ($null -eq $record -or [string]$record.State -cne 'Running') {
        throw "Expected service is not running: $Name"
    }
    $processId = [int]$record.ProcessId
    if ($processId -le 0) { throw "Expected service has no attributed process: $Name" }
    $processes = @(Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId={0}" -f $processId) -ErrorAction Stop)
    if ($processes.Count -ne 1) { throw "Expected service process could not be attributed: $Name" }
    $process = $processes[0]
    $expectedBinary = Get-FullPath $Binary
    if ([string]::IsNullOrWhiteSpace([string]$process.ExecutablePath) -or
        [string]$process.ExecutablePath -ine $expectedBinary) {
        throw "Expected service process executable does not match the installed host: $Name"
    }
    $expectedInvocation = Get-LifeOSServiceInvocation -Name $Name -BinaryPath $Binary -ConfigPath $ConfigPath
    if ([string]::IsNullOrWhiteSpace([string]$process.CommandLine) -or
        [string]$process.CommandLine -ine $expectedInvocation) {
        throw "Expected service process command line does not match its reviewed service invocation: $Name"
    }
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

function Assert-ExactJsonPropertySet {
    param([Parameter(Mandatory)][object]$Object, [Parameter(Mandatory)][string[]]$ExpectedNames, [Parameter(Mandatory)][string]$Label)
    if ($null -eq $Object -or $Object -is [array] -or $Object -is [string]) { throw "$Label is not an object." }
    $actual = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
    $expected = @($ExpectedNames | Sort-Object)
    if (($actual -join "`n") -cne ($expected -join "`n")) {
        throw "$Label has an unexpected property set."
    }
}

function Get-LifeOSCandidateHashMap {
    param([Parameter(Mandatory)][string]$CandidateRoot)
    $root = Get-FullPath $CandidateRoot
    Assert-ExistingDirectory $root 'Candidate root for installed verification'
    $manifestPath = Join-Path $root 'CANDIDATE-MANIFEST.sha256'
    $manifestText = Read-LifeOSCappedFileText -Path $manifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Candidate inventory manifest'
    if ($manifestText.IndexOf([char]0xfeff) -ge 0 -or $manifestText -notmatch "`r?`n$") {
        throw 'Candidate inventory manifest must be UTF-8 text without a BOM and end with one newline.'
    }
    $hashes = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    $paths = New-Object System.Collections.Generic.List[string]
    $reader = [IO.StringReader]::new($manifestText)
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line -notmatch '^(?<hash>[0-9a-f]{64})  \./(?<path>[A-Za-z0-9@][A-Za-z0-9@._/-]*)$') {
                throw 'Candidate inventory manifest contains a non-canonical line.'
            }
            $relative = [string]$Matches['path']
            if ($relative -match '(^|/)(?:\.{1,2})(?:/|$)|//|/$') { throw 'Candidate inventory manifest contains an unsafe path.' }
            if ($hashes.ContainsKey($relative)) { throw "Candidate inventory manifest contains a duplicate: $relative" }
            [void]$hashes.Add($relative, [string]$Matches['hash'])
            [void]$paths.Add($relative)
        }
    } finally { $reader.Dispose() }
    if ($paths.Count -eq 0 -or (@($paths) -join "`n") -cne (@($paths | Sort-Object) -join "`n")) {
        throw 'Candidate inventory manifest is empty or not deterministically sorted.'
    }
    return [pscustomobject]@{ Root = $root; Hashes = $hashes }
}

function Assert-LifeOSCandidateFileMatchesInstalled {
    param(
        [Parameter(Mandatory)][psobject]$Candidate,
        [Parameter(Mandatory)][string]$CandidateRelativePath,
        [Parameter(Mandatory)][string]$InstalledPath,
        [Parameter(Mandatory)][string]$Description
    )
    if (-not $Candidate.Hashes.ContainsKey($CandidateRelativePath)) {
        throw "$Description is absent from the reviewed candidate inventory."
    }
    $candidatePath = Join-Path $Candidate.Root ($CandidateRelativePath.Replace('/', '\'))
    Assert-ExistingFile $candidatePath "$Description candidate file"
    $candidateIntegrity = Get-LifeOSFileIntegrity -Path $candidatePath -Description "$Description candidate file"
    $expectedHash = [string]$Candidate.Hashes[$CandidateRelativePath]
    if ([string]$candidateIntegrity.sha256 -cne $expectedHash) { throw "$Description candidate bytes changed after candidate verification." }
    Assert-ExistingFile $InstalledPath "$Description installed file"
    $installedIntegrity = Get-LifeOSFileIntegrity -Path $InstalledPath -Description "$Description installed file"
    if ([string]$installedIntegrity.sha256 -cne $expectedHash -or
        [long]$installedIntegrity.length -ne [long]$candidateIntegrity.length) {
        throw "$Description installed bytes do not match the reviewed candidate inventory."
    }
}

function Assert-LifeOSInstalledTreeMatchesCandidate {
    param(
        [Parameter(Mandatory)][psobject]$Candidate,
        [Parameter(Mandatory)][string]$CandidatePrefix,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][string]$Description
    )
    $expected = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in $Candidate.Hashes.Keys) {
        if (-not $relative.StartsWith($CandidatePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $tail = $relative.Substring($CandidatePrefix.Length)
        if ([string]::IsNullOrWhiteSpace($tail)) {
            throw "$Description candidate mapping is duplicated or empty."
        }
        if ($expected.ContainsKey($tail)) { throw "$Description candidate mapping is duplicated or empty." }
        [void]$expected.Add($tail, $relative)
    }
    if ($expected.Count -eq 0) { throw "$Description has no candidate inventory entries." }
    $installedIndex = Get-TreeManifestIndex -Root $InstalledRoot
    if ($installedIndex.FileCount -ne $expected.Count) {
        throw "$Description contains an unexpected installed file set."
    }
    foreach ($tail in $expected.Keys) {
        $candidateRelative = [string]$expected[$tail]
        $candidatePath = Join-Path $Candidate.Root ($candidateRelative.Replace('/', '\'))
        $candidateIntegrity = Get-LifeOSFileIntegrity -Path $candidatePath -Description "$Description candidate file"
        if ([string]$candidateIntegrity.sha256 -cne [string]$Candidate.Hashes[$candidateRelative]) { throw "$Description candidate bytes changed after candidate verification." }
        if (-not $installedIndex.ByPath.ContainsKey($tail)) { throw "$Description is missing installed file: $tail" }
        $entry = $installedIndex.ByPath[$tail]
        if ([string]$entry.sha256 -cne [string]$Candidate.Hashes[$candidateRelative] -or
            [long]$entry.length -ne [long]$candidateIntegrity.length) {
            throw "$Description installed file does not match the reviewed candidate: $tail"
        }
    }
}

function Assert-LifeOSGatewayReleaseMatchesCandidate {
    param(
        [Parameter(Mandatory)][psobject]$Candidate,
        [Parameter(Mandatory)][string]$InstalledRoot,
        [Parameter(Mandatory)][string]$Description
    )
    $mappings = @(
        [pscustomobject]@{ Candidate = 'gateway/main.py'; Installed = 'main.py' }
        [pscustomobject]@{ Candidate = 'gateway/enablebanking.py'; Installed = 'enablebanking.py' }
        [pscustomobject]@{ Candidate = 'gateway/supplement_catalog.py'; Installed = 'supplement_catalog.py' }
        [pscustomobject]@{ Candidate = 'gateway/supplement_catalog_schema.sql'; Installed = 'supplement_catalog_schema.sql' }
        [pscustomobject]@{ Candidate = 'gateway/supplement_catalog_seed.sql'; Installed = 'supplement_catalog_seed.sql' }
        [pscustomobject]@{ Candidate = 'deploy/gateway_launcher.py'; Installed = 'gateway_launcher.py' }
    )
    $expectedInstalled = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $candidateByInstalled = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($mapping in $mappings) {
        [void]$expectedInstalled.Add([string]$mapping.Installed)
        $installedName = [string]$mapping.Installed
        if ($candidateByInstalled.ContainsKey($installedName)) { throw "$Description has a duplicate installed mapping." }
        [void]$candidateByInstalled.Add($installedName, [string]$mapping.Candidate)
        Assert-LifeOSCandidateFileMatchesInstalled -Candidate $Candidate -CandidateRelativePath $mapping.Candidate -InstalledPath (Join-Path $InstalledRoot $mapping.Installed) -Description "$Description $($mapping.Installed)"
    }

    $releaseManifestPath = Join-Path $InstalledRoot 'gateway-release.manifest.json'
    Assert-ExistingFile $releaseManifestPath "$Description release manifest"
    $releaseManifest = Read-LifeOSBoundedJsonFile -Path $releaseManifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description "$Description release manifest"
    Assert-ExactJsonPropertySet -Object $releaseManifest -ExpectedNames @('bundleVersion', 'mainSha256', 'launcherSha256', 'bundleFiles') -Label "$Description release manifest"
    if ([string]$releaseManifest.bundleVersion -cne 'v18' -or
        [string]$releaseManifest.mainSha256 -cne [string]$Candidate.Hashes['gateway/main.py'] -or
        [string]$releaseManifest.launcherSha256 -cne [string]$Candidate.Hashes['deploy/gateway_launcher.py']) {
        throw "$Description release manifest is not bound to the reviewed candidate."
    }
    $bundleFiles = @($releaseManifest.bundleFiles)
    if ($bundleFiles.Count -ne $mappings.Count) { throw "$Description release manifest has an unexpected file count." }
    $seenBundleFiles = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($bundleFile in $bundleFiles) {
        Assert-ExactJsonPropertySet -Object $bundleFile -ExpectedNames @('path', 'sha256', 'length') -Label "$Description bundle file"
        $installedName = [string]$bundleFile.path
        if (-not $candidateByInstalled.ContainsKey($installedName) -or -not $seenBundleFiles.Add($installedName) -or
            [string]$bundleFile.sha256 -notmatch '^[0-9a-f]{64}$' -or -not (Test-LifeOSIntegralNumber $bundleFile.length) -or [long]$bundleFile.length -lt 0) {
            throw "$Description release manifest contains an invalid or duplicate bundle file."
        }
        $candidateRelative = [string]$candidateByInstalled[$installedName]
        $candidatePath = Join-Path $Candidate.Root ($candidateRelative.Replace('/', '\'))
        $expectedHash = [string]$Candidate.Hashes[$candidateRelative]
        $candidateIntegrity = Get-LifeOSFileIntegrity -Path $candidatePath -Description "$Description candidate bundle file"
        if ([string]$candidateIntegrity.sha256 -cne $expectedHash -or [string]$bundleFile.sha256 -cne $expectedHash -or [long]$bundleFile.length -ne [long]$candidateIntegrity.length) {
            throw "$Description release manifest bundle file is not candidate-bound: $installedName"
        }
        $installedPath = Join-Path $InstalledRoot $installedName
        $installedIntegrity = Get-LifeOSFileIntegrity -Path $installedPath -Description "$Description installed bundle file"
        if ([string]$installedIntegrity.sha256 -cne $expectedHash -or
            [long]$installedIntegrity.length -ne [long]$bundleFile.length) {
            throw "$Description installed bundle file is not candidate-bound: $installedName"
        }
    }
    if ($seenBundleFiles.Count -ne $expectedInstalled.Count) { throw "$Description release manifest omits a bundle file." }
    $installedIndex = Get-TreeManifestIndex -Root $InstalledRoot
    if ($installedIndex.FileCount -ne ($expectedInstalled.Count + 1)) {
        throw "$Description contains files outside the reviewed gateway bundle."
    }
    foreach ($entry in $installedIndex.Entries) {
        if (-not $expectedInstalled.Contains([string]$entry.path) -and [string]$entry.path -cne 'gateway-release.manifest.json') {
            throw "$Description contains an unexpected installed file: $($entry.path)"
        }
    }
}

function Assert-LifeOSInstalledIntegrityFile {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    Assert-ExactJsonPropertySet -Object $Record -ExpectedNames @('path', 'length', 'sha256') -Label "$Description integrity record"
    if ([string]$Record.path -ine (Get-FullPath $Path) -or
        -not (Test-LifeOSIntegralNumber $Record.length) -or
        [long]$Record.length -lt 0 -or [string]$Record.sha256 -notmatch '^[0-9a-f]{64}$') {
        throw "$Description integrity record is malformed or bound to the wrong path."
    }
    $actual = Get-LifeOSFileIntegrity -Path $Path -Description $Description
    if ([long]$actual.length -ne [long]$Record.length -or [string]$actual.sha256 -cne [string]$Record.sha256) {
        throw "$Description changed after the reviewed installation snapshot."
    }
}

function Assert-LifeOSInstalledIntegrityTree {
    param([Parameter(Mandatory)][object]$Record, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    Assert-ExactJsonPropertySet -Object $Record -ExpectedNames @('path', 'fileCount', 'totalBytes', 'manifestSha256') -Label "$Description integrity record"
    if ([string]$Record.path -ine (Get-FullPath $Path).TrimEnd('\') -or
        [string]$Record.manifestSha256 -notmatch '^[0-9a-f]{64}$') {
        throw "$Description integrity record is malformed or bound to the wrong path."
    }
    $actual = Get-LifeOSTreeIntegrity -Path $Path -Description $Description
    if ([int]$actual.fileCount -ne [int]$Record.fileCount -or
        [long]$actual.totalBytes -ne [long]$Record.totalBytes -or
        [string]$actual.manifestSha256 -cne [string]$Record.manifestSha256) {
        throw "$Description changed after the reviewed installation snapshot."
    }
}

function Assert-LifeOSInstalledIntegrity {
    param([Parameter(Mandatory)][psobject]$Manifest)
    # The shared canonical validator owns the installer-shaped schema and path
    # binding. Keep the checks below focused on proving the recorded bytes
    # still match the live installation.
    Assert-LifeOSInstalledIntegrityContract -Manifest $Manifest
    $property = $Manifest.PSObject.Properties['installedIntegrity']
    if ($null -eq $property -or $null -eq $property.Value) {
        throw 'Installed integrity inventory is missing; full certification is refused.'
    }
    $integrity = $property.Value
    $expectedNames = @('schemaVersion', 'host', 'api', 'gateway', 'node', 'pythonBase', 'apiConfig', 'gatewayConfig', 'gatewayAppConfig', 'snapshotScript')
    $pythonVenvPath = [string]$Manifest.paths.pythonVenv
    $pythonVenvExists = Test-Path -LiteralPath $pythonVenvPath -PathType Container
    if ($pythonVenvExists) { $expectedNames += 'pythonVenv' }
    Assert-ExactJsonPropertySet -Object $integrity -ExpectedNames $expectedNames -Label 'Installed integrity inventory'
    if (-not (Test-LifeOSIntegralNumber $integrity.schemaVersion) -or [int]$integrity.schemaVersion -ne 1) {
        throw 'Installed integrity inventory schema is unsupported.'
    }
    Assert-LifeOSInstalledIntegrityFile $integrity.host ([string]$Manifest.paths.host) 'Installed service host'
    Assert-LifeOSInstalledIntegrityTree $integrity.api ([string]$Manifest.paths.api) 'Installed API release'
    Assert-LifeOSInstalledIntegrityTree $integrity.gateway ([string]$Manifest.paths.gateway) 'Installed gateway release'
    Assert-LifeOSInstalledIntegrityTree $integrity.node ([string]$Manifest.paths.node) 'Installed Node runtime'
    Assert-LifeOSInstalledIntegrityTree $integrity.pythonBase ([string]$Manifest.paths.pythonBase) 'Installed Python base runtime'
    Assert-LifeOSInstalledIntegrityFile $integrity.apiConfig ([string]$Manifest.paths.apiConfig) 'Installed API service config'
    Assert-LifeOSInstalledIntegrityFile $integrity.gatewayConfig ([string]$Manifest.paths.gatewayConfig) 'Installed gateway service config'
    Assert-LifeOSInstalledIntegrityFile $integrity.gatewayAppConfig ([string]$Manifest.paths.gatewayAppConfig) 'Installed gateway application config'
    Assert-LifeOSInstalledIntegrityFile $integrity.snapshotScript ([string]$Manifest.paths.tailscaleSnapshotScript) 'Installed Tailscale snapshot script'
    if ($pythonVenvExists) { Assert-LifeOSInstalledIntegrityTree $integrity.pythonVenv $pythonVenvPath 'Installed Python virtual environment' }
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
$operatorSid = Get-InteractiveOperatorSid
$markerFile = Get-LifeOSDeploymentMarkerPath
Assert-ExistingFile $markerFile 'Deployment marker'
Assert-RestrictedAcl $markerFile $operatorSid @() @() -AllowInherited
$marker = Read-LifeOSBoundedJsonFile -Path $markerFile -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes -Description 'Deployment marker'
$boundManifestFile = Assert-VerificationMarker -Marker $marker -MarkerPath $markerFile -OperatorSid $operatorSid -BackupRoot $paths.BackupRoot
$manifestFile = if ([string]::IsNullOrWhiteSpace($ManifestPath)) {
    $boundManifestFile
} else {
    $requestedManifestFile = Get-FullPath $ManifestPath
    if ($requestedManifestFile -ine $boundManifestFile) {
        throw 'Requested verification manifest is not the manifest bound by the installed deployment marker.'
    }
    $requestedManifestFile
}
$manifest = Read-LifeOSBoundedJsonFile -Path $manifestFile -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Verification manifest'
Assert-RecoveryIdentity $marker $manifest $manifestFile
Assert-CanonicalRollbackManifest -Manifest $manifest -ManifestPath $manifestFile
Assert-AuthenticatedBackup -Manifest $manifest -ManifestPath $manifestFile -BackupDirectory ([string]$manifest.paths.backupDirectory)
$codexVerificationProperty = $manifest.PSObject.Properties['codexCollectorVerification']
if ($null -ne $codexVerificationProperty) {
    $codexVerification = $codexVerificationProperty.Value
    if ([string]$codexVerification.status -eq 'provider_unavailable') {
        Write-Warning 'Codex collector is installed but its provider is currently unavailable; usage remains explicitly unverified.'
    } elseif ([string]$codexVerification.status -ne 'observed') {
        throw 'Codex collector verification evidence is invalid.'
    }
}
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
$apiCode = [string]$manifest.paths.api
$gatewayCode = [string]$manifest.paths.gateway
$runtimeRoot = [string]$manifest.paths.runtimeRoot
$nodeRuntime = [string]$manifest.paths.node
$pythonBase = [string]$manifest.paths.pythonBase
$pythonVenv = [string]$manifest.paths.pythonVenv
$hostDirectory = [string]$manifest.paths.hostDirectory
$dataRoot = [string]$manifest.paths.dataRoot
$logRoot = [string]$manifest.paths.logRoot
$secretRoot = [string]$manifest.paths.secretRoot
$localApiSecret = Get-OptionalManifestPath $manifest.paths 'localApiSecret'
$tailscaleEdgeToken = [string]$manifest.paths.tailscaleEdgeToken
$supplementCatalog = [string]$manifest.paths.supplementCatalog
$stateDirectory = Get-OptionalManifestPath $manifest.paths 'stateDirectory'
$tailscaleSnapshot = Get-OptionalManifestPath $manifest.paths 'tailscaleSnapshot'
$tailscaleSnapshotScript = Get-OptionalManifestPath $manifest.paths 'tailscaleSnapshotScript'
$manifestTailscale = Get-OptionalManifestPath $manifest.paths 'tailscaleExecutable'
# A pre-v18 manifest carries none of these keys. It is readable by rollback,
# but it cannot receive a full production certification because the gateway's
# independently verified Tailscale dependency is absent.
$hasSnapshotContract = -not (
    [string]::IsNullOrWhiteSpace($stateDirectory) -or [string]::IsNullOrWhiteSpace($tailscaleSnapshot) -or
    [string]::IsNullOrWhiteSpace($tailscaleSnapshotScript) -or [string]::IsNullOrWhiteSpace($manifestTailscale) -or
    $null -eq $manifest.PSObject.Properties['snapshotTask'])
if (-not $hasSnapshotContract) {
    throw 'Unsupported legacy deployment shape: the Tailscale snapshot contract is required for full certification.'
}
if ([string]::IsNullOrWhiteSpace($localApiSecret)) {
    throw 'Unsupported legacy deployment shape: the local API secret contract is required for full certification.'
}

Assert-ExistingFile $apiConfig 'API service config'
Assert-ExistingFile $gatewayConfig 'Gateway service config'
Assert-ExistingFile $gatewayAppConfig 'Gateway application config'
Assert-ExistingFile $hostBinary 'Service host binary'
Assert-ExistingFile $claudeSecret 'Claude secret'
Assert-ExistingFile $codexSecret 'Codex secret'
Assert-ExistingFile $localApiSecret 'Local API secret'
Assert-ExistingDirectory $apiData 'API data directory'
Assert-ExistingDirectory $gatewayData 'Gateway data directory'
Assert-ExistingDirectory $apiLogs 'API log directory'
Assert-ExistingDirectory $gatewayLogs 'Gateway log directory'
Assert-ExistingDirectory $apiCode 'API code directory'
Assert-ExistingDirectory $gatewayCode 'Gateway code directory'
Assert-ExistingDirectory $runtimeRoot 'Runtime root'
Assert-ExistingDirectory $nodeRuntime 'Node runtime directory'
Assert-ExistingDirectory $pythonBase 'Python base runtime directory'
Assert-ExistingDirectory $hostDirectory 'Service host directory'
Assert-ExistingDirectory $dataRoot 'Data root'
Assert-ExistingDirectory $logRoot 'Log root'
Assert-ExistingDirectory $secretRoot 'Secret root'
Assert-ExistingDirectory $stateDirectory 'Tailscale snapshot state directory'
Assert-ExistingFile $tailscaleSnapshotScript 'Staged Tailscale snapshot script'
Assert-ExistingFile $tailscaleSnapshot 'Tailscale snapshot'
Assert-ExistingFile $tailscaleEdgeToken 'Tailscale edge token'
Assert-PathOnlyJson $apiConfig
Assert-PathOnlyJson $gatewayConfig
Assert-PathOnlyJson $gatewayAppConfig
Assert-ServiceHostProbeContract -ConfigPath $apiConfig -Port 8787 -Name 'LifeOSAPI'
Assert-ServiceHostProbeContract -ConfigPath $gatewayConfig -Port 8421 -Name 'LifeOSGateway'

# A health response alone does not prove that the reviewed release is the one
# serving the port. Verify the candidate inventory that shipped with this
# verifier, then bind every installed code/runtime/config target to either its
# candidate hash or the install-time integrity inventory before checking ACLs
# and live service state.
$candidateRootFull = if ([string]::IsNullOrWhiteSpace($CandidateRoot)) {
    Get-FullPath (Join-Path $PSScriptRoot '..')
} else {
    Get-FullPath $CandidateRoot
}
Assert-ExistingDirectory $candidateRootFull 'Candidate root for installed verification'
Assert-NoReparsePath $candidateRootFull
$candidateNameMatch = [regex]::Match(([IO.DirectoryInfo]$candidateRootFull).Name, '\Alifeos-release-(?<sha>[0-9a-fA-F]{40})\z')
if (-not $candidateNameMatch.Success) { throw 'Candidate root must be named lifeos-release-<full-source-sha>.' }
$candidateSourceSha = [string]$candidateNameMatch.Groups['sha'].Value
$candidateVerifier = Join-Path $candidateRootFull 'deploy\verify-candidate.ps1'
Assert-ExistingFile $candidateVerifier 'Candidate verifier'
& $candidateVerifier -Root $candidateRootFull -ExpectedSourceSha $candidateSourceSha | Out-Null
$candidateInventory = Get-LifeOSCandidateHashMap -CandidateRoot $candidateRootFull
Assert-LifeOSCandidateFileMatchesInstalled -Candidate $candidateInventory -CandidateRelativePath 'service-host/LifeOS.ServiceHost.exe' -InstalledPath $hostBinary -Description 'Installed service host'
Assert-LifeOSCandidateFileMatchesInstalled -Candidate $candidateInventory -CandidateRelativePath 'deploy/tailscale_snapshot.ps1' -InstalledPath $tailscaleSnapshotScript -Description 'Installed Tailscale snapshot script'
Assert-LifeOSInstalledTreeMatchesCandidate -Candidate $candidateInventory -CandidatePrefix 'api/' -InstalledRoot $apiCode -Description 'Installed API release'
Assert-LifeOSInstalledTreeMatchesCandidate -Candidate $candidateInventory -CandidatePrefix 'node-runtime/' -InstalledRoot $nodeRuntime -Description 'Installed Node runtime'
Assert-LifeOSGatewayReleaseMatchesCandidate -Candidate $candidateInventory -InstalledRoot $gatewayCode -Description 'Installed gateway release'
Assert-LifeOSInstalledIntegrity -Manifest $manifest

Set-StrictMode -Version Latest
$apiAccount = Get-ServiceAccountName 'LifeOSAPI'
$gatewayAccount = Get-ServiceAccountName 'LifeOSGateway'
Assert-ServiceContract -Name 'LifeOSAPI' -Account $apiAccount -Binary $hostBinary -ConfigPath $apiConfig -Dependencies @() -Mode 'auto'
# `Schedule` is asserted because the gateway refuses to start on a snapshot
# older than 90 seconds and must not outrace the SYSTEM task that writes it.
Assert-ServiceContract -Name 'LifeOSGateway' -Account $gatewayAccount -Binary $hostBinary -ConfigPath $gatewayConfig -Dependencies @('LifeOSAPI', $TailscaleServiceName, 'Schedule') -Mode 'delayed-auto'
$apiSid = Get-ServiceSid 'LifeOSAPI'
$gatewaySid = Get-ServiceSid 'LifeOSGateway'
Assert-ServiceSidNotAllowed $apiCode $gatewaySid
Assert-ServiceSidNotAllowed $gatewayCode $apiSid
Assert-ServiceSidNotAllowed $apiData $gatewaySid
Assert-ServiceSidNotAllowed $gatewayData $apiSid
Assert-ServiceSidNotAllowed $codexSecret $gatewaySid

# Reuse the deployment ACL contract for every protected subtree. The
# recursive checks validate owner, every allow principal, deny absence, and
# the exact role rights on each descendant; the root-only checks cover the
# traversal parents whose children intentionally have service-specific roles.
Assert-RestrictedAcl $apiCode $operatorSid @($apiSid) @() -AllowInherited -Recurse
Assert-RestrictedAcl $gatewayCode $operatorSid @($gatewaySid) @() -AllowInherited -Recurse
Assert-RestrictedAcl $nodeRuntime $operatorSid @($apiSid) @() -AllowInherited -Recurse
Assert-RestrictedAcl $pythonBase $operatorSid @($gatewaySid) @() -AllowInherited -Recurse
if (Test-Path -LiteralPath $pythonVenv -PathType Container) {
    Assert-RestrictedAcl $pythonVenv $operatorSid @($gatewaySid) @() -AllowInherited -Recurse
}
# Service-owned children are permitted only in their own managed writable
# trees, and only because the matching service SID also has Modify rights.
Assert-RestrictedAcl $apiData $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse
Assert-RestrictedAcl $gatewayData $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse
Assert-RestrictedAcl $apiLogs $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse
Assert-RestrictedAcl $gatewayLogs $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse
Assert-RestrictedAcl $stateDirectory $operatorSid @($gatewaySid) @() -AllowInherited -Recurse
Assert-LifeOSExpectedImmediateChildren -Root $dataRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll
Assert-LifeOSExpectedImmediateChildren -Root $logRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll
foreach ($rootContract in @(
    [pscustomobject]@{ Path = $hostDirectory; Label = 'Service host traversal root'; ReadSids = @($apiSid, $gatewaySid) }
    [pscustomobject]@{ Path = $runtimeRoot; Label = 'Runtime traversal root'; ReadSids = @($apiSid, $gatewaySid) }
    [pscustomobject]@{ Path = $dataRoot; Label = 'Data traversal root'; ReadSids = @($apiSid, $gatewaySid) }
    [pscustomobject]@{ Path = $logRoot; Label = 'Log traversal root'; ReadSids = @($apiSid, $gatewaySid) }
    [pscustomobject]@{ Path = $secretRoot; Label = 'Secret traversal root'; ReadSids = @($apiSid, $gatewaySid) }
    [pscustomobject]@{ Path = $configDirectory; Label = 'Configuration traversal root'; ReadSids = @($apiSid, $gatewaySid) }
)) {
    Assert-RestrictedAcl $rootContract.Path $operatorSid $rootContract.ReadSids @() -AllowInherited
}

Assert-RestrictedAcl $hostBinary $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $apiConfig $operatorSid @($apiSid) @() -AllowInherited
Assert-RestrictedAcl $gatewayConfig $operatorSid @($gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $gatewayAppConfig $operatorSid @($gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $tailscaleSnapshotScript $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $tailscaleSnapshot $operatorSid @($gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $claudeSecret $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $codexSecret $operatorSid @($apiSid) @() -AllowInherited
Assert-RestrictedAcl $localApiSecret $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $tailscaleEdgeToken $operatorSid @($gatewaySid) @() -AllowInherited
if (Test-Path -LiteralPath $manifest.paths.clipperSecret -PathType Leaf) {
    Assert-RestrictedAcl ([string]$manifest.paths.clipperSecret) $operatorSid @($apiSid) @() -AllowInherited
}
if (Test-Path -LiteralPath $manifest.paths.googleAIStudioApiKey -PathType Leaf) {
    Assert-RestrictedAcl ([string]$manifest.paths.googleAIStudioApiKey) $operatorSid @($apiSid) @() -AllowInherited
}
if (Test-Path -LiteralPath $manifest.paths.enableBankingPrivateKey -PathType Leaf) {
    Assert-RestrictedAcl ([string]$manifest.paths.enableBankingPrivateKey) $operatorSid @($gatewaySid) @() -AllowInherited
}
if (Test-Path -LiteralPath $manifest.paths.enableBankingCertificate -PathType Leaf) {
    Assert-RestrictedAcl ([string]$manifest.paths.enableBankingCertificate) $operatorSid @($gatewaySid) @() -AllowInherited
}
if (Test-Path -LiteralPath $supplementCatalog -PathType Leaf) {
    Assert-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited
}

$broadAclPaths = @($configDirectory, $claudeSecret, $codexSecret, $apiData, $gatewayData, $apiLogs, $gatewayLogs)
$broadAclPaths += $stateDirectory
foreach ($path in $broadAclPaths) {
    Assert-NoBroadAcl $path
}
$legacyTaskPath = [string]$manifest.legacyTask.TaskPath
$legacyTasks = @(Get-LifeOSScheduledTaskExact -TaskName $LegacyTaskName -TaskPath $legacyTaskPath)
if ([bool]$manifest.legacyTask.Exists) {
    if ($legacyTasks.Count -ne 1) { throw "The bound legacy task is missing or ambiguous: $LegacyTaskName" }
    $task = $legacyTasks[0]
    if ($task.State -ne 'Disabled') { throw "Legacy task remains enabled after a completed cutover: $LegacyTaskName" }
    if ([string]::IsNullOrWhiteSpace([string]$manifest.legacyTask.Backup) -or
        -not (Test-Path -LiteralPath ([string]$manifest.legacyTask.Backup) -PathType Leaf)) {
        throw 'Legacy task backup is missing.'
    }
} elseif ($legacyTasks.Count -ne 0) {
    throw "An unexpected legacy task is present after a completed cutover: $LegacyTaskName"
}

$tailscale = Resolve-TailscaleExecutable $TailscaleExecutable
$status = Get-TailscaleStatusJson $tailscale
if (-not (Test-TailscaleServeExact $status)) { throw 'Tailscale Serve is not the required loopback mapping or a truthy Funnel flag was reported.' }

# The gateway service account cannot query Tailscale, so the SYSTEM snapshot
# task is part of the running security boundary: assert its principal, the
# exact action it runs, the integrity of the script it runs, the ACLs that keep
# the gateway out of the writer role, and that the published file is still
# fresh and exact.
Assert-SafeTaskName $TailscaleSnapshotTaskName
$snapshotTaskPath = [string]$manifest.snapshotTask.TaskPath
$snapshotTasks = @(Get-LifeOSScheduledTaskExact -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath)
if ($snapshotTasks.Count -ne 1) { throw "The Tailscale snapshot task is missing or ambiguous: $TailscaleSnapshotTaskName" }
$snapshotTask = $snapshotTasks[0]
if ([string]$snapshotTask.TaskPath -cne $snapshotTaskPath) {
    throw 'The Tailscale snapshot task path is not the manifest-bound path.'
}
    if ([string]$snapshotTask.State -eq 'Disabled') { throw "The Tailscale snapshot task is disabled: $TailscaleSnapshotTaskName" }
    $snapshotPrincipal = [string]$snapshotTask.Principal.UserId
    if ((Resolve-TaskPrincipalSid $snapshotPrincipal) -ne 'S-1-5-18' -and
        $snapshotPrincipal -notin @('S-1-5-18', 'SYSTEM', 'NT AUTHORITY\SYSTEM')) {
        throw 'The Tailscale snapshot task does not run as SYSTEM.'
    }
    if ([string]$snapshotTask.Principal.LogonType -ne 'ServiceAccount') {
        throw 'The Tailscale snapshot task does not run as the SYSTEM service account.'
    }
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
Assert-RunningLifeOSServiceProcess -Name 'LifeOSAPI' -Binary $hostBinary -ConfigPath $apiConfig
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8787/health') 10)) { throw 'LifeOSAPI health check failed.' }
Assert-RunningLifeOSServiceProcess -Name 'LifeOSAPI' -Binary $hostBinary -ConfigPath $apiConfig
if (-not (Wait-LoopbackReadiness ([uri]'http://127.0.0.1:8787/ready') 10)) { throw 'LifeOSAPI readiness check failed.' }
Assert-RunningLifeOSServiceProcess -Name 'LifeOSAPI' -Binary $hostBinary -ConfigPath $apiConfig
Assert-RunningLifeOSServiceProcess -Name 'LifeOSGateway' -Binary $hostBinary -ConfigPath $gatewayConfig
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8421/health') 10)) { throw 'LifeOSGateway health check failed.' }
Assert-RunningLifeOSServiceProcess -Name 'LifeOSGateway' -Binary $hostBinary -ConfigPath $gatewayConfig
if (-not (Wait-LoopbackReadiness ([uri]'http://127.0.0.1:8421/ready') 10)) { throw 'LifeOSGateway readiness check failed.' }
Assert-RunningLifeOSServiceProcess -Name 'LifeOSGateway' -Binary $hostBinary -ConfigPath $gatewayConfig

Write-Host 'LifeOS Windows deployment verification passed.'
Write-Host ("Manifest: {0}" -f $manifestFile)
Write-Host 'Both services use virtual accounts, unrestricted service SIDs, least-privilege ACLs, and restart-only recovery.'
