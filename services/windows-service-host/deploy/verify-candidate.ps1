[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Root,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{40}$')][string]$ExpectedSourceSha
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

function Get-CandidateRelativePath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RootPath
    )
    $fullPath = [IO.Path]::GetFullPath($Path)
    $directorySeparators = [char[]]@([char]'\', [char]'/')
    $rootFull = ([IO.Path]::GetFullPath($RootPath)).TrimEnd($directorySeparators)
    $prefix = $rootFull + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Candidate path escapes the candidate root: $Path"
    }
    return $fullPath.Substring($prefix.Length).Replace('\', '/')
}

function Assert-CandidatePeFile {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name)
    $bytes = Read-LifeOSPrefixBytes -Path $Path -Count 2 -Description $Name
    if ($bytes.Length -ne 2 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
        throw "$Name is not a Windows PE executable."
    }
}

function Sort-CandidatePaths {
    param([Parameter(Mandatory)][System.Collections.IEnumerable]$Paths)
    $sorted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) { [void]$sorted.Add([string]$path) }
    $sorted.Sort([System.StringComparer]::Ordinal)
    $sorted
}

function Assert-ExactJsonPropertySet {
    param(
        [Parameter(Mandatory)][object]$Object,
        [Parameter(Mandatory)][string[]]$ExpectedNames,
        [Parameter(Mandatory)][string]$Label
    )
    if ($Object -isnot [System.Management.Automation.PSCustomObject]) {
        throw "$Label must be a JSON object."
    }
    $actualNames = @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
    $expectedSorted = @($ExpectedNames | Sort-Object)
    if (($actualNames -join "`n") -cne ($expectedSorted -join "`n")) {
        throw "$Label has an unexpected property set. Expected: $($expectedSorted -join ', '). Actual: $($actualNames -join ', ')."
    }
}

$script:LifeOSGatewayDependencyLockMaxBytes = 1024 * 1024
$script:LifeOSGatewayDependencyMaxPackages = 1024
$script:LifeOSGatewayWheelMaxFileBytes = 64 * 1024 * 1024

function Normalize-CandidateDependencyName {
    param([Parameter(Mandatory)][string]$Name)
    if ($Name -notmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z') {
        throw 'Gateway dependency lock contains an invalid distribution name.'
    }
    return ([regex]::Replace($Name, '[-_.]+', '-')).ToLowerInvariant()
}

function Read-CandidateGatewayDependencyLock {
    param([Parameter(Mandatory)][string]$Path)
    Assert-ExistingFile $Path 'Candidate gateway dependency lock'
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer -or [long]$item.Length -gt [long]$script:LifeOSGatewayDependencyLockMaxBytes) {
        throw 'Candidate gateway dependency lock exceeds its bounded size.'
    }
    $text = Read-LifeOSCappedFileText -Path $Path -MaxBytes $script:LifeOSGatewayDependencyLockMaxBytes -Description 'Candidate gateway dependency lock'
    if ($text.IndexOf([char]0xfeff) -ge 0 -or $text -notmatch '\r?\n\z') {
        throw 'Candidate gateway dependency lock must be UTF-8 text without a BOM and end with one newline.'
    }
    $packages = New-Object 'System.Collections.Generic.List[object]'
    $packageNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    $lastName = $null
    $reader = [IO.StringReader]::new($text)
    try {
        while ($true) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { break }
            if ($line.Length -gt 1024) { throw 'Candidate gateway dependency lock contains an oversized line.' }
            $trimmed = $line.Trim()
            if ([string]::IsNullOrEmpty($trimmed) -or $trimmed.StartsWith('#', [StringComparison]::Ordinal)) { continue }
            $match = [regex]::Match($line, '\A(?<name>[A-Za-z0-9][A-Za-z0-9._-]{0,127})==(?<version>[A-Za-z0-9][A-Za-z0-9.!+_-]{0,127})\s+--hash=sha256:(?<hash>[0-9a-f]{64})\s+#\s+(?<wheel>[A-Za-z0-9][A-Za-z0-9._+!-]{0,255}\.whl)\z')
            if (-not $match.Success) { throw 'Candidate gateway dependency lock must name its reviewed wheel.' }
            $normalizedName = Normalize-CandidateDependencyName $match.Groups['name'].Value
            if (-not $packageNames.Add($normalizedName)) { throw 'Candidate gateway dependency lock contains duplicate normalized names.' }
            if ($null -ne $lastName -and [string]::CompareOrdinal($lastName, $normalizedName) -ge 0) {
                throw 'Candidate gateway dependency lock is not sorted by normalized name.'
            }
            $wheelMatch = [regex]::Match($match.Groups['wheel'].Value, '\A(?<distribution>[A-Za-z0-9][A-Za-z0-9._-]{0,127})-(?<version>[A-Za-z0-9][A-Za-z0-9.!+_-]{0,127})-(?<python>[A-Za-z0-9.]+)-(?<abi>[A-Za-z0-9]+)-(?<platform>[A-Za-z0-9_]+)\.whl\z')
            if (-not $wheelMatch.Success) { throw 'Candidate gateway dependency lock contains an invalid wheel filename.' }
            $wheelDistribution = Normalize-CandidateDependencyName $wheelMatch.Groups['distribution'].Value
            if ($wheelDistribution -cne $normalizedName -or $wheelMatch.Groups['version'].Value -cne $match.Groups['version'].Value) {
                throw 'Candidate wheel filename does not match its locked distribution or version.'
            }
            $pythonTag = [string]$wheelMatch.Groups['python'].Value
            $abiTag = [string]$wheelMatch.Groups['abi'].Value
            $platformTag = [string]$wheelMatch.Groups['platform'].Value
            $pureWheel = ($pythonTag -ceq 'py3' -or $pythonTag -ceq 'py2.py3') -and $abiTag -ceq 'none' -and $platformTag -ceq 'any'
            $abi3WindowsWheel = $platformTag -ceq 'win_amd64' -and $pythonTag -match '\Acp[0-9]+\z' -and $abiTag -ceq 'abi3'
            $cp312WindowsWheel = $pythonTag -ceq 'cp312' -and $abiTag -ceq 'cp312' -and $platformTag -ceq 'win_amd64'
            if (-not ($pureWheel -or $abi3WindowsWheel -or $cp312WindowsWheel)) {
                throw 'Candidate wheel is not compatible with Windows CPython 3.12.'
            }
            [void]$packages.Add([pscustomobject]@{
                NormalizedName = $normalizedName
                Version = [string]$match.Groups['version'].Value
                Sha256 = [string]$match.Groups['hash'].Value
                Filename = [string]$match.Groups['wheel'].Value
                PythonTag = $pythonTag
                AbiTag = $abiTag
                PlatformTag = $platformTag
            })
            $lastName = $normalizedName
            if ($packages.Count -gt $script:LifeOSGatewayDependencyMaxPackages) { throw 'Candidate gateway dependency lock contains too many packages.' }
        }
    } finally {
        $reader.Dispose()
    }
    if ($packages.Count -eq 0) { throw 'Candidate gateway dependency lock is empty.' }
    return [pscustomobject]@{
        Sha256 = [string](Get-FileSha256 $Path)
        PackageCount = [int]$packages.Count
        Wheels = [object[]]$packages.ToArray()
    }
}

$expectedSha = $ExpectedSourceSha.ToLowerInvariant()
$rootFull = [IO.Path]::GetFullPath($Root)
Assert-ExistingDirectory $rootFull 'Candidate root'
$rootName = ([IO.DirectoryInfo]$rootFull).Name
if ($rootName -cne ('lifeos-release-' + $expectedSha)) {
    throw 'Candidate directory name must be lifeos-release-<full-source-sha>.'
}

$gatewayDependencyLock = Read-CandidateGatewayDependencyLock -Path (Join-Path $rootFull 'gateway\requirements.lock')

$expectedFiles = @(
    'SOURCE_SHA.txt'
    'api/package.json'
    'api/dist/atomic-file.js'
    'api/dist/calendar-store.js'
    'api/dist/claude-ingest.js'
    'api/dist/clipper-store.js'
    'api/dist/codex-adapter.js'
    'api/dist/codex-collector.js'
    'api/dist/finance-connectors.js'
    'api/dist/history.js'
    'api/dist/ingest-secret.js'
    'api/dist/json-boundary.js'
    'api/dist/local-auth.js'
    'api/dist/nutrition-photo.js'
    'api/dist/open-food-facts.js'
    'api/dist/projection.js'
    'api/dist/server.js'
    'api/node_modules/@iphone-life-os/contracts/package.json'
    'api/node_modules/@iphone-life-os/contracts/dist/clipper.js'
    'api/node_modules/@iphone-life-os/contracts/dist/fitness-retention.js'
    'api/node_modules/@iphone-life-os/contracts/dist/index.js'
    'api/node_modules/@iphone-life-os/contracts/dist/nutrition-barcode.js'
    'api/node_modules/@iphone-life-os/contracts/dist/nutrition-benchmark.js'
    'api/node_modules/@iphone-life-os/contracts/dist/nutrition.js'
    'api/node_modules/@iphone-life-os/contracts/dist/supplements.js'
    'api/node_modules/@iphone-life-os/contracts/dist/sync.js'
    'api/node_modules/@iphone-life-os/contracts/dist/usage.js'
    'api/node_modules/zod/package.json'
    'api/node_modules/zod/index.cjs'
    'api/node_modules/zod/index.js'
    'api/node_modules/zod/v3/ZodError.cjs'
    'api/node_modules/zod/v3/ZodError.js'
    'api/node_modules/zod/v3/errors.cjs'
    'api/node_modules/zod/v3/errors.js'
    'api/node_modules/zod/v3/external.cjs'
    'api/node_modules/zod/v3/external.js'
    'api/node_modules/zod/v3/helpers/enumUtil.cjs'
    'api/node_modules/zod/v3/helpers/enumUtil.js'
    'api/node_modules/zod/v3/helpers/errorUtil.cjs'
    'api/node_modules/zod/v3/helpers/errorUtil.js'
    'api/node_modules/zod/v3/helpers/parseUtil.cjs'
    'api/node_modules/zod/v3/helpers/parseUtil.js'
    'api/node_modules/zod/v3/helpers/partialUtil.cjs'
    'api/node_modules/zod/v3/helpers/partialUtil.js'
    'api/node_modules/zod/v3/helpers/typeAliases.cjs'
    'api/node_modules/zod/v3/helpers/typeAliases.js'
    'api/node_modules/zod/v3/helpers/util.cjs'
    'api/node_modules/zod/v3/helpers/util.js'
    'api/node_modules/zod/v3/index.cjs'
    'api/node_modules/zod/v3/index.js'
    'api/node_modules/zod/v3/locales/en.cjs'
    'api/node_modules/zod/v3/locales/en.js'
    'api/node_modules/zod/v3/standard-schema.cjs'
    'api/node_modules/zod/v3/standard-schema.js'
    'api/node_modules/zod/v3/types.cjs'
    'api/node_modules/zod/v3/types.js'
    'gateway/main.py'
    'gateway/enablebanking.py'
    'gateway/supplement_catalog.py'
    'gateway/supplement_catalog_schema.sql'
    'gateway/supplement_catalog_seed.sql'
    'gateway/requirements.txt'
    'gateway/requirements.lock'
    'gateway/wheelhouse/ALLOWLIST.sha256'
    'gateway/test_enablebanking.py'
    'gateway/test_gateway.py'
    'gateway/test_gateway_launcher.py'
    'gateway/test_supplement_catalog.py'
    'windows-service-host/deploy/gateway_launcher.py'
    'node-runtime/node.exe'
    'service-host/LifeOS.ServiceHost.exe'
    'deploy/Deployment.Common.ps1'
    'deploy/README.md'
    'deploy/gateway_launcher.py'
    'deploy/install.ps1'
    'deploy/preflight.ps1'
    'deploy/rollback.ps1'
    'deploy/tailscale_snapshot.ps1'
    'deploy/verify-candidate.ps1'
    'deploy/verify.ps1'
    'deploy/tests/Deployment.Behavior.Tests.ps1'
    'deploy/tests/Deployment.LegacyServe.Tests.ps1'
    'deploy/tests/Deployment.Static.Tests.ps1'
)

foreach ($wheel in @($gatewayDependencyLock.Wheels)) {
    $wheelPath = 'gateway/wheelhouse/' + [string]$wheel.Filename
    if ($wheel.Filename -match '[\r\n\\]' -or $wheel.Filename -notmatch '\A[A-Za-z0-9][A-Za-z0-9._+!-]{0,255}\.whl\z') {
        throw 'Candidate wheel filename is unsafe.'
    }
    if ($expectedFiles -contains $wheelPath) { throw "Candidate wheel allowlist contains a duplicate: $wheelPath" }
    $expectedFiles += $wheelPath
}

$expectedSet = @{}
foreach ($relativePath in $expectedFiles) {
    if ($expectedSet.ContainsKey($relativePath)) { throw "Candidate allowlist contains a duplicate: $relativePath" }
    $expectedSet[$relativePath] = $true
}

$allowedDirectories = @{}
foreach ($relativePath in $expectedFiles) {
    $parent = Split-Path -Parent $relativePath
    while (-not [string]::IsNullOrEmpty($parent)) {
        $allowedDirectories[$parent.Replace('\', '/')] = $true
        $parent = Split-Path -Parent $parent
    }
}
# Every candidate limit is derived from the reviewed file allowlist. The
# shared breadth-first walker counts files, directories, and bytes before any
# later hashing or manifest parsing, and rejects reparses before enqueueing.
$maxCandidateFiles = [int]$expectedFiles.Count + 1 # allow CANDIDATE-MANIFEST.sha256
$maxCandidateDirectories = [int]$allowedDirectories.Count + 1 # allow the root
$maxCandidateFileBytes = [long]$script:LifeOSRecoveryMaxFileBytes
$maxCandidateNodeFileBytes = [long]$script:LifeOSCandidateNodeMaxFileBytes
$maxCandidateServiceHostFileBytes = [long]$script:LifeOSCandidateServiceHostMaxFileBytes
# The only candidate file allowed above the general 64 MiB bound is the
# explicitly allowlisted standalone node runtime and self-contained service
# host. Keep the aggregate bound equally tight: ordinary files plus exactly
# one Node runtime and one service host.
$maxCandidateBytes = [long]($expectedFiles.Count - 2) * $maxCandidateFileBytes + $maxCandidateNodeFileBytes + $maxCandidateServiceHostFileBytes
$largeFileContracts = [ordered]@{
    'node-runtime/node.exe' = $maxCandidateNodeFileBytes
    'service-host/LifeOS.ServiceHost.exe' = $maxCandidateServiceHostFileBytes
}
$allItems = @(Get-LifeOSBoundedTreeItem -Root $rootFull -MaxFiles $maxCandidateFiles -MaxDirectories $maxCandidateDirectories -MaxBytes $maxCandidateBytes -MaxFileBytes $maxCandidateFileBytes -LargeFileContracts $largeFileContracts)
$actualFiles = New-Object System.Collections.ArrayList
$actualDirectories = New-Object System.Collections.ArrayList
$actualFileIdentities = @{}
foreach ($item in $allItems) {
    $relativePath = Get-CandidateRelativePath -Path $item.FullName -RootPath $rootFull
    if ($item.PSIsContainer) { [void]$actualDirectories.Add($relativePath) }
    else {
        $itemMaxBytes = if ($relativePath -ceq 'node-runtime/node.exe') {
            $maxCandidateNodeFileBytes
        } elseif ($relativePath -ceq 'service-host/LifeOS.ServiceHost.exe') {
            $maxCandidateServiceHostFileBytes
        } else {
            $maxCandidateFileBytes
        }
        if ([long]$item.Length -gt $itemMaxBytes) {
            throw "Candidate file exceeds its bounded size: $relativePath"
        }
        [void]$actualFiles.Add($relativePath)
        if ($actualFileIdentities.ContainsKey($relativePath)) { throw "Candidate contains a duplicate path: $relativePath" }
        $actualFileIdentities[$relativePath] = New-LifeOSTreeItemIdentity -Item $item -Description 'Candidate file inventory item'
    }
}

$actualFileSet = @{}
foreach ($relativePath in $actualFiles) {
    if ($actualFileSet.ContainsKey($relativePath)) { throw "Candidate contains a duplicate path: $relativePath" }
    $actualFileSet[$relativePath] = $true
}
$actualFilesWithoutManifest = @($actualFiles | Where-Object { $_ -cne 'CANDIDATE-MANIFEST.sha256' })
$actualKey = @(Sort-CandidatePaths $actualFilesWithoutManifest) -join "`n"
$expectedKey = @(Sort-CandidatePaths $expectedFiles) -join "`n"
if ($actualKey -ne $expectedKey) {
    $unexpected = @($actualFilesWithoutManifest | Where-Object { -not $expectedSet.ContainsKey($_) })
    $missing = @($expectedFiles | Where-Object { -not $actualFileSet.ContainsKey($_) })
    throw "Candidate file allowlist mismatch. Missing: $($missing -join ', '). Unexpected: $($unexpected -join ', ')."
}
if (-not $actualFileSet.ContainsKey('CANDIDATE-MANIFEST.sha256')) {
    throw 'Candidate manifest is missing.'
}

foreach ($relativePath in $actualDirectories) {
    if (-not $allowedDirectories.ContainsKey($relativePath)) {
        throw "Candidate contains an unexpected directory: $relativePath"
    }
}

$sourceShaPath = Join-Path $rootFull 'SOURCE_SHA.txt'
$sourceShaItem = Get-Item -LiteralPath $sourceShaPath -Force -ErrorAction Stop
if ($sourceShaItem.PSIsContainer -or [long]$sourceShaItem.Length -gt $maxCandidateFileBytes) {
    throw 'SOURCE_SHA.txt exceeds the candidate file bound.'
}
$sourceShaText = Read-LifeOSCappedFileText -Path $sourceShaPath -MaxBytes $maxCandidateFileBytes -Description 'SOURCE_SHA.txt'
if ($sourceShaText -notmatch ('^' + [regex]::Escape($expectedSha) + "`r?`n?$")) {
    throw 'SOURCE_SHA.txt does not contain exactly the expected full source SHA.'
}

$manifestPath = Join-Path $rootFull 'CANDIDATE-MANIFEST.sha256'
$candidateManifestMaxBytes = [long]($expectedFiles.Count + 1) * 16 * 1024
$manifestItem = Get-Item -LiteralPath $manifestPath -Force -ErrorAction Stop
if ($manifestItem.PSIsContainer -or [long]$manifestItem.Length -gt $candidateManifestMaxBytes) {
    throw 'Candidate manifest exceeds its allowlist-derived parse bound.'
}
$manifestText = Read-LifeOSCappedFileText -Path $manifestPath -MaxBytes $candidateManifestMaxBytes -Description 'Candidate manifest'
if ($manifestText.IndexOf([char]0xfeff) -ge 0 -or $manifestText -notmatch "`r?`n$") {
    throw 'Candidate manifest must be UTF-8 text without a BOM and end with one newline.'
}
$manifestPaths = New-Object System.Collections.ArrayList
$manifestHashes = @{}
$manifestReader = [IO.StringReader]::new($manifestText)
try {
    while ($true) {
        $line = $manifestReader.ReadLine()
        if ($null -eq $line) { break }
        if ($line -notmatch '^(?<hash>[0-9a-f]{64})  \./(?<path>[A-Za-z0-9@][A-Za-z0-9@._/-]*)$') {
            throw "Candidate manifest line is not canonical: $line"
        }
        $relativePath = [string]$Matches['path']
        if ($relativePath -match '(^|/)(?:\.{1,2})(?:/|$)|//|/$' -or $relativePath -eq 'CANDIDATE-MANIFEST.sha256') {
            throw "Candidate manifest path is unsafe: $relativePath"
        }
        if ($manifestHashes.ContainsKey($relativePath)) { throw "Candidate manifest contains a duplicate: $relativePath" }
        $manifestHashes[$relativePath] = [string]$Matches['hash']
        [void]$manifestPaths.Add($relativePath)
    }
} finally {
    $manifestReader.Dispose()
}
if ((@(Sort-CandidatePaths $manifestPaths) -join "`n") -ne (@($manifestPaths) -join "`n")) {
    throw 'Candidate manifest paths are not sorted deterministically.'
}
$manifestKey = @(Sort-CandidatePaths $manifestPaths) -join "`n"
if ($manifestKey -ne $actualKey) {
    throw 'Candidate manifest file set does not match the candidate file set.'
}
foreach ($relativePath in $manifestPaths) {
    $candidatePath = Join-Path $rootFull ($relativePath.Replace('/', '\'))
    if (-not $actualFileIdentities.ContainsKey($relativePath)) {
        throw "Candidate manifest file was not present in the frozen inventory: $relativePath"
    }
    Assert-LifeOSTreeItemIdentity -Path $candidatePath -Expected $actualFileIdentities[$relativePath] -Description "Candidate file $relativePath" | Out-Null
    $actualDigest = Get-LifeOSFileDigest -Path $candidatePath -Description "Candidate file $relativePath" -ExpectedFileId ([string]$actualFileIdentities[$relativePath].FileId)
    if ([string]$actualDigest.Sha256 -cne [string]$manifestHashes[$relativePath]) {
        throw "Candidate manifest hash mismatch: $relativePath"
    }
}

if ([string]$manifestHashes['gateway/requirements.lock'] -cne [string]$gatewayDependencyLock.Sha256) {
    throw 'Candidate manifest does not bind the gateway dependency lock digest.'
}

$wheelhouseRoot = Join-Path $rootFull 'gateway\wheelhouse'
$wheelhouseAllowlistPath = Join-Path $wheelhouseRoot 'ALLOWLIST.sha256'
$wheelhouseAllowlistMaxBytes = [long]($gatewayDependencyLock.PackageCount + 1) * 160
$allowlistItem = Get-Item -LiteralPath $wheelhouseAllowlistPath -Force -ErrorAction Stop
if ($allowlistItem.PSIsContainer -or [long]$allowlistItem.Length -gt $wheelhouseAllowlistMaxBytes) {
    throw 'Candidate wheelhouse allowlist exceeds its derived parse bound.'
}
$allowlistText = Read-LifeOSCappedFileText -Path $wheelhouseAllowlistPath -MaxBytes $wheelhouseAllowlistMaxBytes -Description 'Candidate wheelhouse allowlist'
if ($allowlistText.IndexOf([char]0xfeff) -ge 0 -or $allowlistText -notmatch '\r?\n\z') {
    throw 'Candidate wheelhouse allowlist must be UTF-8 text without a BOM and end with one newline.'
}
$allowlistLines = New-Object 'System.Collections.Generic.List[string]'
$allowlistHashes = @{}
$allowlistReader = [IO.StringReader]::new($allowlistText)
try {
    while ($true) {
        $line = $allowlistReader.ReadLine()
        if ($null -eq $line) { break }
        if ($line -notmatch '\A(?<hash>[0-9a-f]{64})  \./(?<name>[A-Za-z0-9][A-Za-z0-9._+!-]{0,255}\.whl)\z') {
            throw 'Candidate wheelhouse allowlist contains a non-canonical line.'
        }
        $name = [string]$Matches['name']
        if ($allowlistHashes.ContainsKey($name)) { throw 'Candidate wheelhouse allowlist contains a duplicate.' }
        $allowlistHashes[$name] = [string]$Matches['hash']
        [void]$allowlistLines.Add($name)
    }
} finally {
    $allowlistReader.Dispose()
}
$expectedAllowlistLines = @($gatewayDependencyLock.Wheels | ForEach-Object { [string]$_.Filename } | Sort-Object)
$sortedAllowlistLines = Sort-CandidatePaths $allowlistLines
if (($sortedAllowlistLines.ToArray() -join "`n") -ne ($allowlistLines.ToArray() -join "`n") -or
    ($allowlistLines.ToArray() -join "`n") -ne ($expectedAllowlistLines -join "`n")) {
    throw 'Candidate wheelhouse allowlist does not match the sorted dependency lock.'
}
foreach ($wheel in @($gatewayDependencyLock.Wheels)) {
    $relativeWheelPath = 'gateway/wheelhouse/' + [string]$wheel.Filename
    $candidateWheelPath = Join-Path $rootFull ('gateway\wheelhouse\' + [string]$wheel.Filename)
    $wheelItem = Get-Item -LiteralPath $candidateWheelPath -Force -ErrorAction Stop
    if ($wheelItem.PSIsContainer -or [long]$wheelItem.Length -le 0 -or [long]$wheelItem.Length -gt [long]$script:LifeOSGatewayWheelMaxFileBytes) {
        throw "Candidate wheel exceeds its bounded size: $($wheel.Filename)"
    }
    if ([string]$manifestHashes[$relativeWheelPath] -cne [string]$wheel.Sha256 -or
        [string]$allowlistHashes[$wheel.Filename] -cne [string]$wheel.Sha256) {
        throw "Candidate wheel provenance does not match the dependency lock: $($wheel.Filename)"
    }
    $wheelDigest = Get-LifeOSFileDigest -Path $candidateWheelPath -Description "Candidate wheel $($wheel.Filename)"
    if ([string]$wheelDigest.Sha256 -cne [string]$wheel.Sha256) {
        throw "Candidate wheel hash mismatch: $($wheel.Filename)"
    }
}

Assert-CandidatePeFile -Path (Join-Path $rootFull 'node-runtime\node.exe') -Name 'Node runtime'
Assert-CandidatePeFile -Path (Join-Path $rootFull 'service-host\LifeOS.ServiceHost.exe') -Name 'Service host'

$apiPackage = Read-LifeOSBoundedJsonFile -Path (Join-Path $rootFull 'api\package.json') -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Candidate API package metadata'
Assert-ExactJsonPropertySet -Object $apiPackage -ExpectedNames @('name', 'version', 'private', 'type', 'dependencies') -Label 'Candidate API package metadata'
if ($apiPackage.name -isnot [string] -or [string]$apiPackage.name -cne '@iphone-life-os/api' -or
    $apiPackage.version -isnot [string] -or [string]$apiPackage.version -cne '0.1.0' -or
    $apiPackage.private -isnot [bool] -or -not [bool]$apiPackage.private -or
    $apiPackage.type -isnot [string] -or [string]$apiPackage.type -cne 'module') {
    throw 'Candidate API package metadata is not the reviewed production shape.'
}
Assert-ExactJsonPropertySet -Object $apiPackage.dependencies -ExpectedNames @('@iphone-life-os/contracts', 'zod') -Label 'Candidate API dependencies'
if ($apiPackage.dependencies.'@iphone-life-os/contracts' -isnot [string] -or
    [string]$apiPackage.dependencies.'@iphone-life-os/contracts' -cne '0.1.0' -or
    $apiPackage.dependencies.zod -isnot [string] -or
    [string]$apiPackage.dependencies.zod -cne '^3.25.76' -or
    [string]$apiPackage.dependencies.'@iphone-life-os/contracts' -match '(?i)^file:') {
    throw 'Candidate API package contains an unsafe or non-installer-shaped dependency declaration.'
}

Write-Host ("PASS: candidate {0} verified ({1} files; source {0}; gateway lock {2} packages {3})." -f $expectedSha, $manifestPaths.Count, $gatewayDependencyLock.PackageCount, $gatewayDependencyLock.Sha256)
