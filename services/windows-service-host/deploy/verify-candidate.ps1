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
    $stream = $null
    try {
        $stream = [IO.File]::OpenRead($Path)
        $bytes = New-Object byte[] 2
        if ($stream.Read($bytes, 0, 2) -ne 2 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) {
            throw "$Name is not a Windows PE executable."
        }
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
    }
}

function Sort-CandidatePaths {
    param([Parameter(Mandatory)][System.Collections.IEnumerable]$Paths)
    $sorted = New-Object 'System.Collections.Generic.List[string]'
    foreach ($path in $Paths) { [void]$sorted.Add([string]$path) }
    $sorted.Sort([System.StringComparer]::Ordinal)
    $sorted
}

$expectedSha = $ExpectedSourceSha.ToLowerInvariant()
$rootFull = [IO.Path]::GetFullPath($Root)
Assert-ExistingDirectory $rootFull 'Candidate root'
$rootName = ([IO.DirectoryInfo]$rootFull).Name
if ($rootName -cne ('lifeos-release-' + $expectedSha)) {
    throw 'Candidate directory name must be lifeos-release-<full-source-sha>.'
}

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
    'deploy/verify-candidate.ps1'
    'deploy/verify.ps1'
    'deploy/tests/Deployment.Behavior.Tests.ps1'
    'deploy/tests/Deployment.LegacyServe.Tests.ps1'
    'deploy/tests/Deployment.Static.Tests.ps1'
)

$expectedSet = @{}
foreach ($relativePath in $expectedFiles) {
    if ($expectedSet.ContainsKey($relativePath)) { throw "Candidate allowlist contains a duplicate: $relativePath" }
    $expectedSet[$relativePath] = $true
}

$allItems = @(Get-ChildItem -LiteralPath $rootFull -Recurse -Force -ErrorAction Stop)
$actualFiles = New-Object System.Collections.ArrayList
$actualDirectories = New-Object System.Collections.ArrayList
foreach ($item in $allItems) {
    $linkType = if ($null -ne $item.PSObject.Properties['LinkType']) { $item.LinkType } else { $null }
    $target = if ($null -ne $item.PSObject.Properties['Target']) { $item.Target } else { $null }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $null -ne $linkType -or $null -ne $target) {
        throw "Candidate contains a reparse point or symbolic link: $($item.FullName)"
    }
    $relativePath = Get-CandidateRelativePath -Path $item.FullName -RootPath $rootFull
    if ($item.PSIsContainer) { [void]$actualDirectories.Add($relativePath) }
    else { [void]$actualFiles.Add($relativePath) }
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

$allowedDirectories = @{}
foreach ($relativePath in $expectedFiles) {
    $parent = Split-Path -Parent $relativePath
    while (-not [string]::IsNullOrEmpty($parent)) {
        $allowedDirectories[$parent.Replace('\', '/')] = $true
        $parent = Split-Path -Parent $parent
    }
}
foreach ($relativePath in $actualDirectories) {
    if (-not $allowedDirectories.ContainsKey($relativePath)) {
        throw "Candidate contains an unexpected directory: $relativePath"
    }
}

$sourceShaPath = Join-Path $rootFull 'SOURCE_SHA.txt'
$sourceShaText = [IO.File]::ReadAllText($sourceShaPath)
if ($sourceShaText -notmatch ('^' + [regex]::Escape($expectedSha) + "`r?`n?$")) {
    throw 'SOURCE_SHA.txt does not contain exactly the expected full source SHA.'
}

$manifestPath = Join-Path $rootFull 'CANDIDATE-MANIFEST.sha256'
$manifestText = [IO.File]::ReadAllText($manifestPath)
if ($manifestText.IndexOf([char]0xfeff) -ge 0 -or $manifestText -notmatch "`r?`n$") {
    throw 'Candidate manifest must be UTF-8 text without a BOM and end with one newline.'
}
$manifestPaths = New-Object System.Collections.ArrayList
$manifestHashes = @{}
foreach ($line in @([IO.File]::ReadAllLines($manifestPath))) {
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
if ((@(Sort-CandidatePaths $manifestPaths) -join "`n") -ne (@($manifestPaths) -join "`n")) {
    throw 'Candidate manifest paths are not sorted deterministically.'
}
$manifestKey = @(Sort-CandidatePaths $manifestPaths) -join "`n"
if ($manifestKey -ne $actualKey) {
    throw 'Candidate manifest file set does not match the candidate file set.'
}
foreach ($relativePath in $manifestPaths) {
    $candidatePath = Join-Path $rootFull ($relativePath.Replace('/', '\'))
    $actualHash = (Get-FileHash -LiteralPath $candidatePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -cne [string]$manifestHashes[$relativePath]) {
        throw "Candidate manifest hash mismatch: $relativePath"
    }
}

Assert-CandidatePeFile -Path (Join-Path $rootFull 'node-runtime\node.exe') -Name 'Node runtime'
Assert-CandidatePeFile -Path (Join-Path $rootFull 'service-host\LifeOS.ServiceHost.exe') -Name 'Service host'

$apiPackage = Get-Content -LiteralPath (Join-Path $rootFull 'api\package.json') -Raw | ConvertFrom-Json -ErrorAction Stop
if ([string]$apiPackage.name -ne '@iphone-life-os/api' -or [string]$apiPackage.version -ne '0.1.0' -or
    -not [bool]$apiPackage.private -or [string]$apiPackage.type -ne 'module') {
    throw 'Candidate API package metadata is not the reviewed production shape.'
}
if ([string]$apiPackage.dependencies.'@iphone-life-os/contracts' -ne '0.1.0' -or
    [string]$apiPackage.dependencies.zod -ne '^3.25.76' -or
    $null -ne $apiPackage.PSObject.Properties['devDependencies'] -or
    [string]$apiPackage.dependencies.'@iphone-life-os/contracts' -match '(?i)^file:') {
    throw 'Candidate API package contains an unsafe or non-installer-shaped dependency declaration.'
}

Write-Host ("PASS: candidate {0} verified ({1} files; source {0})." -f $expectedSha, $manifestPaths.Count)
