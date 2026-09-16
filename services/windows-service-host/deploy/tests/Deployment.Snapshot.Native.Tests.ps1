[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-SnapshotTest {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "PASS: $Message"
}

function Assert-SnapshotThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    Assert-SnapshotTest $threw $Message
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: native snapshot tests require Windows PowerShell 5.1.'
    exit 0
}

$sourcePath = Join-Path $PSScriptRoot '..\tailscale_snapshot.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -ErrorAction Stop
$definitionStart = $source.IndexOf('function Get-SnapshotPropertyValue', [StringComparison]::Ordinal)
$definitionEnd = $source.IndexOf("`n`$identity = Get-JsonFromTailscale", [StringComparison]::Ordinal)
if ($definitionStart -lt 0 -or $definitionEnd -le $definitionStart) { throw 'FAIL: snapshot writer definition boundary is missing.' }
. ([scriptblock]::Create($source.Substring($definitionStart, $definitionEnd - $definitionStart)))

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('.lifeos-snapshot-native-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
$destination = Join-Path $testRoot 'tailscale-state.json'
$tempPath = Join-Path $testRoot '.test-temp'
$parentHandle = $null
$tempHandle = $null
$stream = $null

function Publish-TestBytes {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][bool]$Replace
    )
    $parent = $null
    $handle = $null
    $writer = $null
    $temporary = Join-Path $Root ('.test-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $published = $false
    try {
        $parent = [LifeOSSnapshotNative]::OpenDirectory($Root)
        $handle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($temporary)
        $writer = [IO.FileStream]::new($handle, [IO.FileAccess]::ReadWrite, 8192, $false)
        $writer.Write($Bytes, 0, $Bytes.Length)
        $writer.Flush($true)
        [LifeOSSnapshotNative]::RenameWithHeldParent(
            $handle, $parent, $Destination, $Replace)
        $published = $true
        $info = [LifeOSSnapshotNative]::Inspect($Destination, $false)
        $expected = [LifeOSSnapshotNative]::InspectHandle($handle)
        Assert-SnapshotTest ([string]$info.Identity -ceq [string]$expected.Identity) 'published path resolves to the retained file handle'
        Assert-SnapshotTest ($info.NumberOfLinks -eq 1) 'published snapshot has one hardlink'
        $actual = [LifeOSSnapshotNative]::ReadBounded($handle, 256 * 1024)
        Assert-SnapshotTest ([Convert]::ToBase64String($actual) -ceq [Convert]::ToBase64String($Bytes)) 'published bytes match the flushed bytes'
    } finally {
        if (-not $published -and $null -ne $handle) { try { [LifeOSSnapshotNative]::DeleteByHandle($handle) } catch { } }
        if ($null -ne $writer) { $writer.Dispose() }
        if ($null -ne $handle) { $handle.Dispose() }
        if ($null -ne $parent) { $parent.Dispose() }
    }
}

try {
    $first = [Text.UTF8Encoding]::new($false).GetBytes('{"schemaVersion":1,"value":"first"}')
    $second = [Text.UTF8Encoding]::new($false).GetBytes('{"schemaVersion":1,"value":"second"}')
    Publish-TestBytes -Root $testRoot -Destination $destination -Bytes $first -Replace:$false
    Assert-SnapshotTest (Test-Path -LiteralPath $destination -PathType Leaf) 'absent destination is published atomically'
    Publish-TestBytes -Root $testRoot -Destination $destination -Bytes $second -Replace:$true
    Assert-SnapshotTest ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($destination)) -ceq [Text.Encoding]::UTF8.GetString($second)) 'repeated replacement updates the destination'

    $oldBytes = [IO.File]::ReadAllBytes($destination)
    Assert-SnapshotThrows {
        $existing = [LifeOSSnapshotNative]::CreateExclusiveForWrite($tempPath)
        try { [LifeOSSnapshotNative]::CreateExclusiveForWrite($tempPath) | Out-Null }
        finally { [LifeOSSnapshotNative]::DeleteByHandle($existing); $existing.Dispose() }
    } 'exclusive temporary creation rejects a colliding path'
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($oldBytes)) 'failed temporary creation preserves the previous snapshot'

    $oversizedPath = Join-Path $testRoot 'oversized'
    [IO.File]::WriteAllBytes($oversizedPath, (New-Object byte[] 2048))
    $oversizedStream = [IO.File]::OpenRead($oversizedPath)
    try { Assert-SnapshotThrows { [LifeOSSnapshotNative]::ReadBounded($oversizedStream.SafeFileHandle, 1024) } 'bounded reader rejects oversized content' }
    finally { $oversizedStream.Dispose() }
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($oldBytes)) 'oversized input does not alter the destination'

    $heldParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
    $movedRoot = $testRoot + '.moved'
    try {
        Assert-SnapshotThrows { Move-Item -LiteralPath $testRoot -Destination $movedRoot -ErrorAction Stop } 'held ancestor prevents pathname replacement'
    } finally { $heldParent.Dispose() }
    Assert-SnapshotTest (Test-Path -LiteralPath $testRoot -PathType Container) 'held parent remains at its validated path'

    $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $powershell -PathType Leaf) {
        Assert-SnapshotThrows {
            [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-Command', 'Start-Sleep -Seconds 3'), 250, 4096) | Out-Null
        } 'native process reader enforces a total timeout'
        Assert-SnapshotThrows {
            [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-Command', '[Console]::Write(("x" * 8192))'), 5000, 1024) | Out-Null
        } 'native process reader enforces an output bound'
    } else {
        Write-Host 'SKIP: Windows PowerShell executable is unavailable for process-bound tests.'
    }

    $gatewayTestSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    Set-SnapshotRestrictedFileSecurity -Path $destination -GatewaySid $gatewayTestSid
    Assert-SnapshotSecurity -Path $destination -GatewaySid $gatewayTestSid
    Assert-SnapshotReaderAccess -Path $destination -GatewaySid $gatewayTestSid -Acl (Get-Acl -LiteralPath $destination)
    Write-Host 'PASS: final snapshot ACL has explicit reader access and no untrusted mutation grant'

    $hardlink = Join-Path $testRoot 'hardlink'
    $fsutil = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\fsutil.exe'
    if (Test-Path -LiteralPath $fsutil -PathType Leaf) {
        & $fsutil hardlink create $hardlink $destination 2>$null
        if ($LASTEXITCODE -eq 0) {
            try {
                $linked = [LifeOSSnapshotNative]::Inspect($destination, $false)
                Assert-SnapshotTest ($linked.NumberOfLinks -gt 1) 'hardlink ambiguity is observable before publication'
            } finally { Remove-Item -LiteralPath $hardlink -Force -ErrorAction SilentlyContinue }
        } else { Write-Host 'SKIP: hardlink creation requires unavailable elevation.' }
    } else { Write-Host 'SKIP: fsutil is unavailable for hardlink test.' }

    $symlink = Join-Path $testRoot 'symlink'
    $symlinkCreated = $false
    try {
        New-Item -ItemType SymbolicLink -Path $symlink -Target $destination -ErrorAction Stop | Out-Null
        $symlinkCreated = $true
    } catch { Write-Host 'SKIP: symbolic-link creation requires unavailable elevation.' }
    if ($symlinkCreated) {
        try {
            $linked = [LifeOSSnapshotNative]::Inspect($symlink, $false)
            Assert-SnapshotTest (([uint32]$linked.Attributes -band [uint32]0x400) -ne [uint32]0) 'reparse ambiguity is observable before publication'
        } finally { Remove-Item -LiteralPath $symlink -Force -ErrorAction SilentlyContinue }
    }

    Write-Host 'PASS: native snapshot publication tests completed.'
} finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $tempHandle) { $tempHandle.Dispose() }
    if ($null -ne $parentHandle) { $parentHandle.Dispose() }
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
}
