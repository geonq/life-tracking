[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deploy = Split-Path -Parent $PSScriptRoot
. (Join-Path $deploy 'Deployment.Common.ps1')

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'FAIL: native progress tests require Windows.'
}

function Assert-Native {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-NativeThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "FAIL: expected native rejection: $Message" }
}

function Assert-NativeThrowsSpecific {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$ExpectedMessage
    )
    $caught = $null
    try { & $Action } catch { $caught = $_ }
    if ($null -eq $caught) { throw "FAIL: expected native rejection: $Message" }
    $exception = $caught.Exception
    while ($null -ne $exception -and [string]$exception.Message -cne $ExpectedMessage) {
        $exception = $exception.InnerException
    }
    if ($null -eq $exception) {
        throw "FAIL: rejection did not match the expected error: $Message; actual: $($caught.Exception.Message)"
    }
}

function Get-NativeLeaseBytes {
    param([Parameter(Mandatory)]$Lease)
    if (-not $Lease.Native.HasLeaf -or $null -eq $Lease.Stream) { throw 'FAIL: native lease has no readable leaf.' }
    $position = $Lease.Stream.Position
    try {
        $Lease.Stream.Position = 0
        $bytes = New-Object byte[] ([int]$Lease.Stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $chunk = $Lease.Stream.Read($bytes, $read, $bytes.Length - $read)
            if ($chunk -le 0) { throw 'FAIL: retained stream ended before its advertised length.' }
            $read += $chunk
        }
        return ,$bytes
    } finally { $Lease.Stream.Position = $position }
}

function Get-NativeHandleLeaseBytes {
    param([Parameter(Mandatory)]$Lease)
    if (-not $Lease.HasLeaf -or $null -eq $Lease.Stream) { throw 'FAIL: native handle lease has no readable leaf.' }
    $position = $Lease.Stream.Position
    try {
        $Lease.Stream.Position = 0
        $bytes = New-Object byte[] ([int]$Lease.Stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $chunk = $Lease.Stream.Read($bytes, $read, $bytes.Length - $read)
            if ($chunk -le 0) { throw 'FAIL: native handle lease ended before its advertised length.' }
            $read += $chunk
        }
        return ,$bytes
    } finally { $Lease.Stream.Position = $position }
}

$nativeOperatorSid = ([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value

function New-NativeProgressFixture {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-native-' + [Guid]::NewGuid().ToString('N'))
    $backup = Join-Path $root 'backup'
    Ensure-Directory $backup
    $manifestPath = Join-Path $backup 'manifest.json'
    $manifest = [pscustomobject]@{
        transactionId = ('native-' + [Guid]::NewGuid().ToString('N'))
        generation = 'native-generation'; operatorSid = $nativeOperatorSid; manifestPath = $manifestPath
        paths = [pscustomobject]@{ backupDirectory = $backup }
    }
    $unit = [pscustomobject]@{
        destination = (Join-Path $root 'destination.json'); backup = ''; pre = 'absent'; post = 'absent'
        phase = 'pending'; stagingPath = (Join-Path $root '.stage')
    }
    $journal = [pscustomobject]@{
        schemaVersion = 1; transactionId = $manifest.transactionId; generation = $manifest.generation
        operatorSid = $manifest.operatorSid; manifestPath = $manifest.manifestPath; units = @($unit)
        unitCount = 1; treeRoots = @($root); phase = 'artifacts'; progressPath = (Get-RecoveryProgressPath $manifest)
        progressSequence = 0
    }
    return [pscustomobject]@{
        Root = $root; Backup = $backup; Manifest = $manifest; Journal = $journal; Unit = $unit
        Source = $null; Destination = $null; Staged = $null; RenamedDestination = $null
        ManifestBackup = $null; OutsideRoot = $null; OutsideSentinel = $null
        OriginalBytes = $null; ReplacementBytes = $null; ManifestBackupBytes = $null
    }
}

function Remove-NativeProgressFixture {
    param([AllowNull()]$Fixture)
    if ($null -ne $Fixture) { Remove-Item -LiteralPath $Fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
}

function Get-NativeArtifactBytes {
    param([Parameter(Mandatory)]$Artifact)
    if (-not $Artifact.Native.HasLeaf -or $null -eq $Artifact.Native.Stream) {
        throw 'FAIL: native artifact has no readable leaf.'
    }
    $position = $Artifact.Native.Stream.Position
    try {
        $Artifact.Native.Stream.Position = 0
        $bytes = New-Object byte[] ([int]$Artifact.Native.Stream.Length)
        $read = 0
        while ($read -lt $bytes.Length) {
            $chunk = $Artifact.Native.Stream.Read($bytes, $read, $bytes.Length - $read)
            if ($chunk -le 0) { throw 'FAIL: native artifact stream ended before its advertised length.' }
            $read += $chunk
        }
        return ,$bytes
    } finally { $Artifact.Native.Stream.Position = $position }
}

function Get-NativeBytesSha256 {
    param([Parameter(Mandatory)][byte[]]$Bytes)
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($hash.ComputeHash($Bytes)) -replace '-', '').ToLowerInvariant() }
    finally { $hash.Dispose() }
}

function New-NativeProgressPayloadText {
    param(
        [Parameter(Mandatory)]$Fixture,
        [long]$Sequence = 1,
        [int]$UnitIndex = 0,
        [string]$Phase = 'complete',
        [string]$TransactionId = $null,
        [string]$Generation = $null,
        [string]$OperatorSid = $null,
        [string]$ManifestPath = $null
    )
    if (-not $PSBoundParameters.ContainsKey('TransactionId')) { $TransactionId = [string]$Fixture.Manifest.transactionId }
    if (-not $PSBoundParameters.ContainsKey('Generation')) { $Generation = [string]$Fixture.Manifest.generation }
    if (-not $PSBoundParameters.ContainsKey('OperatorSid')) { $OperatorSid = [string]$Fixture.Manifest.operatorSid }
    if (-not $PSBoundParameters.ContainsKey('ManifestPath')) { $ManifestPath = [string]$Fixture.Manifest.manifestPath }
    $record = [ordered]@{
        sequence = $Sequence; transactionId = $TransactionId; generation = $Generation
        operatorSid = $OperatorSid; manifestPath = $ManifestPath; unitIndex = $UnitIndex; phase = $Phase
    }
    return [string]($record | ConvertTo-Json -Compress)
}

function Convert-NativeProgressPayloadText {
    param([Parameter(Mandatory)][string]$Text)
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Text)
    return ,$bytes
}

function Write-NativeProgressFrame {
    param([Parameter(Mandatory)]$Lease, [Parameter(Mandatory)]$Frame)
    $stream = $Lease.Stream
    $offset = [long]$stream.Length
    $stream.Position = $offset
    $stream.Write($Frame.Header, 0, $Frame.Header.Length)
    $stream.Write($Frame.HeaderDigest, 0, $Frame.HeaderDigest.Length)
    $stream.Write($Frame.Payload, 0, $Frame.Payload.Length)
    $stream.Write($Frame.Digest, 0, $Frame.Digest.Length)
    $stream.Write($Frame.Commit, 0, $Frame.Commit.Length)
    $stream.Flush($true)
    return $offset
}

function Get-NativeProgressFrameBytes {
    param([Parameter(Mandatory)]$Frame)
    $bytes = New-Object byte[] ([int]$Frame.TotalBytes)
    $offset = 0
    [Array]::Copy($Frame.Header, 0, $bytes, $offset, $Frame.Header.Length)
    $offset += $Frame.Header.Length
    [Array]::Copy($Frame.HeaderDigest, 0, $bytes, $offset, $Frame.HeaderDigest.Length)
    $offset += $Frame.HeaderDigest.Length
    [Array]::Copy($Frame.Payload, 0, $bytes, $offset, $Frame.Payload.Length)
    $offset += $Frame.Payload.Length
    [Array]::Copy($Frame.Digest, 0, $bytes, $offset, $Frame.Digest.Length)
    $offset += $Frame.Digest.Length
    [Array]::Copy($Frame.Commit, 0, $bytes, $offset, $Frame.Commit.Length)
    return ,$bytes
}

function New-NativeArtifactFixture {
    $fixture = New-NativeProgressFixture
    $fixture.Source = Join-Path $fixture.Root 'source.bin'
    $fixture.Destination = Join-Path $fixture.Root 'destination.bin'
    $fixture.Staged = Join-Path $fixture.Root ('.rollback-restore-' + $fixture.Manifest.transactionId + '-0')
    $fixture.RenamedDestination = Join-Path $fixture.Root 'renamed-destination.bin'
    $fixture.ManifestBackup = Join-Path $fixture.Backup 'manifest.backup.json'
    $fixture.OutsideRoot = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-native-outside-' + [Guid]::NewGuid().ToString('N'))
    $fixture.OutsideSentinel = Join-Path $fixture.OutsideRoot 'sentinel.txt'
    Ensure-Directory $fixture.OutsideRoot
    $original = [Text.UTF8Encoding]::new($false).GetBytes(('original-' + ('A' * 32768)))
    $replacement = [Text.UTF8Encoding]::new($false).GetBytes(('replacement-' + ('B' * 16384)))
    [IO.File]::WriteAllBytes($fixture.Source, $original)
    [IO.File]::WriteAllBytes($fixture.Destination, $original)
    [IO.File]::WriteAllBytes($fixture.Staged, $replacement)
    $fixture.OriginalBytes = $original
    $fixture.ReplacementBytes = $replacement
    $fixture.ManifestBackupBytes = [Text.UTF8Encoding]::new($false).GetBytes('manifest-backup-v1')
    [IO.File]::WriteAllBytes($fixture.ManifestBackup, $fixture.ManifestBackupBytes)
    [IO.File]::WriteAllText($fixture.OutsideSentinel, 'outside-sentinel-v1', [Text.UTF8Encoding]::new($false))
    $fixture.Unit.destination = $fixture.Destination
    $fixture.Unit.backup = $fixture.ManifestBackup
    $fixture.Unit.pre = 'file:' + (Get-NativeBytesSha256 $original)
    $fixture.Unit.post = 'file:' + (Get-NativeBytesSha256 $replacement)
    $fixture.Unit.stagingPath = $fixture.Staged
    return $fixture
}

function Remove-NativeArtifactFixture {
    param([AllowNull()]$Fixture)
    if ($null -eq $Fixture) { return }
    if ($null -ne $Fixture.OutsideRoot) {
        Remove-Item -LiteralPath $Fixture.OutsideRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-NativeProgressFixture $Fixture
}

function New-NativeArtifactLease {
    param([Parameter(Mandatory)]$Fixture, [long]$MaxBytes = 1024 * 1024)
    [void](Append-RecoveryProgress -Manifest $Fixture.Manifest -Journal $Fixture.Journal -UnitIndex 0 -Phase 'restoring')
    $holder = New-RecoveryProgressLeaseHolder
    try {
        [void](Read-RecoveryProgress -Manifest $Fixture.Manifest -Journal $Fixture.Journal -JournalUnits $Fixture.Journal.units -ProgressLeaseHolder $holder)
        $context = New-RecoveryArtifactMutationContext -Manifest $Fixture.Manifest -Journal $Fixture.Journal -UnitIndex 0 -Unit $Fixture.Unit -ProgressLeaseHolder $holder -MaxBytes $MaxBytes
        return [pscustomobject]@{ Holder = $holder; Context = $context }
    } catch {
        Close-RecoveryProgressLeaseHolder $holder
        throw
    }
}

function Close-NativeArtifactLease {
    param([AllowNull()]$Lease)
    if ($null -eq $Lease) { return }
    if ($null -ne $Lease.Context) { try { Close-RecoveryArtifactMutationContext $Lease.Context } catch { } }
    if ($null -ne $Lease.Holder) { try { Close-RecoveryProgressLeaseHolder $Lease.Holder } catch { } }
}

function Assert-NativeProgressCanReopen {
    param([Parameter(Mandatory)]$Fixture)
    $holder = New-RecoveryProgressLeaseHolder
    try {
        [void](Read-RecoveryProgress -Manifest $Fixture.Manifest -Journal $Fixture.Journal -JournalUnits $Fixture.Journal.units -ProgressLeaseHolder $holder)
        Assert-Native ($holder.Lease.Native.HasLeaf -and $holder.Parsed) 'progress lease can be reopened after artifact capability disposal.'
    } finally { Close-RecoveryProgressLeaseHolder $holder }
}

function Invoke-NativeArtifactTestRename {
    param(
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$SourceHandle,
        [Parameter(Mandatory)][Microsoft.Win32.SafeHandles.SafeFileHandle]$ParentHandle,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq ('LifeOSNativeArtifactTestRename' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LifeOSNativeArtifactTestRename
{
    [StructLayout(LayoutKind.Sequential)]
    private struct IoStatusBlock
    {
        public IntPtr Status;
        public IntPtr Information;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct FileRenameInformationData
    {
        public byte ReplaceIfExists;
        public IntPtr RootDirectory;
        public uint FileNameLength;
        public byte FileName;
    }

    [DllImport("ntdll.dll")]
    private static extern uint NtSetInformationFile(
        IntPtr fileHandle, out IoStatusBlock ioStatusBlock, IntPtr fileInformation,
        uint length, uint fileInformationClass);

    [DllImport("ntdll.dll")]
    private static extern uint RtlNtStatusToDosError(uint status);

    public static void Rename(SafeFileHandle source, SafeFileHandle parent, string name)
    {
        if (source == null || source.IsInvalid || source.IsClosed ||
            parent == null || parent.IsInvalid || parent.IsClosed ||
            String.IsNullOrEmpty(name) || name.IndexOf('\\') >= 0 || name.IndexOf('/') >= 0)
        {
            throw new ArgumentException("The test rename binding is invalid.");
        }
        byte[] nameBytes = System.Text.Encoding.Unicode.GetBytes(name);
        int nameOffset = (int)Marshal.OffsetOf(typeof(FileRenameInformationData), "FileName");
        IntPtr buffer = Marshal.AllocHGlobal(nameOffset + nameBytes.Length +
            Marshal.SizeOf(typeof(FileRenameInformationData)));
        try
        {
            FileRenameInformationData information = new FileRenameInformationData {
                ReplaceIfExists = 0,
                RootDirectory = parent.DangerousGetHandle(),
                FileNameLength = (uint)nameBytes.Length,
                FileName = 0
            };
            Marshal.StructureToPtr(information, buffer, false);
            Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
            IoStatusBlock ioStatus;
            uint status = NtSetInformationFile(source.DangerousGetHandle(), out ioStatus, buffer,
                (uint)(nameOffset + nameBytes.Length), 10u);
            if (status != 0) {
                uint error = RtlNtStatusToDosError(status);
                throw new Win32Exception((int)(error == 0 ? 1 : error));
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }
}
'@ -ErrorAction Stop | Out-Null
    }
    [LifeOSNativeArtifactTestRename]::Rename($SourceHandle, $ParentHandle, $Name)
}

# Retained leaf and ancestor handles deny replacement while a lease is active,
# and the chain remains inspectable after acquisition.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
    $sameLength = [IO.File]::ReadAllBytes($progressPath)
    $holder = New-RecoveryProgressLeaseHolder
    try {
        $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder
        Assert-Native ($null -ne $lease -and $lease.Native.AncestorHandles.Count -ge 2) 'lease retains every opened ancestor.'
        Assert-Native ($lease.Native.AncestorIdentities.Count -eq $lease.Native.AncestorHandles.Count -and
            -not [string]::IsNullOrWhiteSpace($lease.Native.LeafIdentity)) 'lease retains the validated identity chain.'
        Assert-NativeThrows { [IO.File]::WriteAllBytes($lease.Path, $sameLength) } 'same-length replacement while the leaf is leased.'
        Assert-NativeThrows { Move-Item -LiteralPath $fixture.Backup -Destination ($fixture.Root + '-moved') -Force } 'ancestor replacement while the lease is active.'
        $lease.Stream.Position = 0
        Assert-Native ($lease.Stream.ReadByte() -ge 0) 'the retained stream remains usable without a pathname reopen.'
    } finally { Close-RecoveryProgressLeaseHolder $holder }
    $hardLink = Join-Path $fixture.Root 'progress-hard-link.jsonl'
    New-Item -ItemType HardLink -Path $hardLink -Target $progressPath | Out-Null
    try { Assert-NativeThrows { Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder (New-RecoveryProgressLeaseHolder) } 'hard-link leaf' }
    finally { Remove-Item -LiteralPath $hardLink -Force }
} finally { Remove-NativeProgressFixture $fixture }

# A reparse-point ancestor is rejected at the component handle, before a leaf
# can be opened through the junction.
$fixture = New-NativeProgressFixture
$junction = $null
try {
    $target = Join-Path $fixture.Root 'target'
    $junction = Join-Path $fixture.Root 'junction'
    Ensure-Directory $target
    New-Item -ItemType Junction -Path $junction -Target $target | Out-Null
    $fixture.Manifest.paths.backupDirectory = $junction
    $fixture.Journal.progressPath = Get-RecoveryProgressPath $fixture.Manifest
    $holder = New-RecoveryProgressLeaseHolder
    try { Assert-NativeThrows { Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder } 'reparse ancestor' }
    finally { Close-RecoveryProgressLeaseHolder $holder }
} finally { Remove-NativeProgressFixture $fixture }

# A reparse-point leaf is rejected before its target can be opened as a file.
$fixture = New-NativeProgressFixture
try {
    $leafTarget = Join-Path $fixture.Root 'leaf-target'
    $leafReparse = Get-RecoveryProgressPath $fixture.Manifest
    Ensure-Directory $leafTarget
    New-Item -ItemType Junction -Path $leafReparse -Target $leafTarget | Out-Null
    Assert-NativeThrows { Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder (New-RecoveryProgressLeaseHolder) } 'leaf reparse'
} finally { Remove-NativeProgressFixture $fixture }

# Any owner or ACE outside the management boundary is rejected before repair.
# Users FullControl must leave both the progress bytes and the ACL unchanged.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
    $acl = Get-Acl -LiteralPath $progressPath
    $acl.SetAccessRuleProtection($false, $true)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')),
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $progressPath -AclObject $acl
    $before = [IO.File]::ReadAllBytes($progressPath)
    $beforeAcl = (Get-Acl -LiteralPath $progressPath).GetSecurityDescriptorBinaryForm()
    $strictHolder = New-RecoveryProgressLeaseHolder
    try { Assert-NativeThrows { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -Strict -ProgressLeaseHolder $strictHolder } 'unrestricted DACL in strict mode' }
    finally { Close-RecoveryProgressLeaseHolder $strictHolder }
    $repairHolder = New-RecoveryProgressLeaseHolder
    try { Assert-NativeThrows { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $repairHolder } 'unrestricted DACL is outside the repair boundary' }
    finally { Close-RecoveryProgressLeaseHolder $repairHolder }
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($progressPath)) -ceq [Convert]::ToBase64String($before)) 'strict ACL rejection preserves bytes.'
    $afterAcl = (Get-Acl -LiteralPath $progressPath).GetSecurityDescriptorBinaryForm()
    Assert-Native ([Convert]::ToBase64String($afterAcl) -ceq [Convert]::ToBase64String($beforeAcl)) 'out-of-boundary ACL rejection preserves the ACL.'
} finally { Remove-NativeProgressFixture $fixture }

# This management-only deficient ACL repair path is allowed. A deficient DACL
# containing only management SIDs is repairable. This is the
# supported non-strict repair path and is separately verified after the
# out-of-boundary rejection above.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
    $repairAcl = New-RecoveryProgressAcl -OperatorSid $nativeOperatorSid
    $repairAcl.RemoveAccessRuleAll([Security.AccessControl.FileSystemAccessRule]::new(
        ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')),
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $progressPath -AclObject $repairAcl
    $repairHolder = New-RecoveryProgressLeaseHolder
    try { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $repairHolder }
    finally { Close-RecoveryProgressLeaseHolder $repairHolder }
    $strictLeaseHolder = New-RecoveryProgressLeaseHolder
    try { Assert-Native ($null -ne (Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $strictLeaseHolder -Strict)) 'repaired DACL passes strict validation.' }
    finally { Close-RecoveryProgressLeaseHolder $strictLeaseHolder }
} finally { Remove-NativeProgressFixture $fixture }

# A first-frame interruption leaves a valid empty leaf after the reader
# truncates the matching partial prefix. Resume must append to that retained
# leaf instead of issuing CreateNewOnly against its existing name.
$fixture = New-NativeProgressFixture
$firstFrameHolder = $null
$resumeHolder = $null
try {
    $firstFrameHolder = New-RecoveryProgressLeaseHolder
    $firstFrameLease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $firstFrameHolder
    $firstFrameLease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $firstFrameHolder -CreateIfMissing
    $record = New-RecoveryProgressRecord -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -Sequence 0 -UnitCount 1
    $frame = New-RecoveryProgressFrame $record
    $firstFrameLease.Stream.Write($frame.Header, 0, 4)
    $firstFrameLease.Stream.Flush($true)
    Close-RecoveryProgressLeaseHolder $firstFrameHolder
    $firstFrameHolder = $null

    $resumeHolder = New-RecoveryProgressLeaseHolder
    Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $resumeHolder
    Assert-Native ($resumeHolder.Lease.Native.HasLeaf -and [long]$resumeHolder.Lease.Length -eq 0 -and $fixture.Journal.progressSequence -eq 0) 'first-frame recovery retains the validated empty leaf at sequence zero.'
    Assert-Native (Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $resumeHolder) 'first-frame recovery resumes by appending to the retained empty leaf.'
} finally {
    if ($null -ne $firstFrameHolder) { Close-RecoveryProgressLeaseHolder $firstFrameHolder }
    if ($null -ne $resumeHolder) { Close-RecoveryProgressLeaseHolder $resumeHolder }
    Remove-NativeProgressFixture $fixture
}

# A valid next frame prefix is recoverable; a durable checkpoint shortfall is
# rejected before that prefix can be truncated, and strict reads preserve it.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
    $committedLength = [long](Get-Item -LiteralPath $progressPath).Length
    $nextRecord = New-RecoveryProgressRecord -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -Sequence 1 -UnitCount 1
    $nextFrame = New-RecoveryProgressFrame $nextRecord
    $tail = New-Object byte[] ($nextFrame.Header.Length + 4)
    [Array]::Copy($nextFrame.Header, 0, $tail, 0, $nextFrame.Header.Length)
    [Array]::Copy($nextFrame.HeaderDigest, 0, $tail, $nextFrame.Header.Length, 4)
    $tailWriter = [IO.File]::Open($progressPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $tailWriter.Write($tail, 0, $tail.Length) } finally { $tailWriter.Dispose() }
    $fixture.Journal.progressSequence = 2
    $beforeCheckpointShortfall = [IO.File]::ReadAllBytes($progressPath)
    Assert-NativeThrows { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units } 'checkpoint shortfall before tail truncation'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($progressPath)) -ceq [Convert]::ToBase64String($beforeCheckpointShortfall)) 'checkpoint shortfall preserves exact bytes.'
    $fixture.Journal.progressSequence = 1
    $beforeStrict = [IO.File]::ReadAllBytes($progressPath)
    Assert-NativeThrows { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -Strict } 'strict torn-tail read'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($progressPath)) -ceq [Convert]::ToBase64String($beforeStrict)) 'strict torn-tail read preserves exact bytes.'
    Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units
    Assert-Native ([long](Get-Item -LiteralPath $progressPath).Length -eq $committedLength) 'non-strict torn-tail read truncates exactly to the committed offset.'
} finally { Remove-NativeProgressFixture $fixture }

# A missing-leaf holder remains bound to its original journal and unit
# collection before any competing journal can create or attach a leaf.
$fixture = New-NativeProgressFixture
try {
    $cachedHolder = New-RecoveryProgressLeaseHolder
    try {
        Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $cachedHolder
        $firstUnits = $fixture.Journal.units
        $secondUnit = [pscustomobject]@{
            destination = $fixture.Unit.destination; backup = $fixture.Unit.backup; pre = $fixture.Unit.pre; post = $fixture.Unit.post
            phase = 'pending'; stagingPath = $fixture.Unit.stagingPath
        }
        $secondUnits = @($secondUnit)
        $secondJournal = [pscustomobject]@{
            schemaVersion = 1; transactionId = $fixture.Journal.transactionId; generation = $fixture.Journal.generation
            operatorSid = $fixture.Journal.operatorSid; manifestPath = $fixture.Journal.manifestPath; units = $secondUnits; unitCount = 1
            treeRoots = $fixture.Journal.treeRoots; phase = 'artifacts'; progressPath = (Get-RecoveryProgressPath $fixture.Manifest); progressSequence = 0
        }
        Assert-NativeThrows {
            Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $secondJournal -JournalUnits $secondUnits -ProgressLeaseHolder $cachedHolder
        } 'missing-leaf holder rejects a mismatched journal collection before rebinding'
        Assert-Native (-not (Test-Path -LiteralPath (Get-RecoveryProgressPath $fixture.Manifest))) 'mismatched missing-leaf read does not create a progress leaf.'
        Assert-NativeThrows {
            Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $secondJournal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $cachedHolder
        } 'missing-leaf holder rejects a mismatched journal before creation'
        Assert-Native (-not (Test-Path -LiteralPath (Get-RecoveryProgressPath $fixture.Manifest))) 'mismatched missing-leaf append does not create a progress leaf.'
        Assert-Native ([object]::ReferenceEquals($cachedHolder.JournalReference, $fixture.Journal) -and
            [object]::ReferenceEquals($cachedHolder.UnitCollectionReference, $firstUnits)) 'mismatched journal attempts preserve the original holder binding.'
        Assert-Native (Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $cachedHolder) 'the original missing-leaf holder remains usable after a rejected competitor.'
    } finally { Close-RecoveryProgressLeaseHolder $cachedHolder }
} finally { Remove-NativeProgressFixture $fixture }

# Replay always reconstructs the native phase ledger from the pending baseline.
# A restarted reader must publish that reconstructed state into the mutable
# journal and holder mirrors before the cached-context validation runs.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring')
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $fixture.Journal.progressSequence = 0
    $fixture.Unit.phase = 'pending'
    $restartHolder = New-RecoveryProgressLeaseHolder
    try {
        Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $restartHolder
        Assert-Native ($restartHolder.Parsed -and
            $restartHolder.ValidatedUnitPhases[0] -ceq 'complete' -and
            $fixture.Unit.phase -ceq 'complete' -and
            [long]$fixture.Journal.progressSequence -eq 2 -and
            $restartHolder.PhaseAuthority.GetPhase(0) -ceq 'complete' -and
            [long]$restartHolder.PhaseAuthority.NextSequence -eq 2) 'restart replay publishes both phase transitions into the journal and holder mirrors.'
    } finally { Close-RecoveryProgressLeaseHolder $restartHolder }
} finally { Remove-NativeProgressFixture $fixture }

# Cached phase state is validated independently of mutable journal content.
# A restoring-to-complete mutation cannot become a false idempotent append or
# be accepted by a cached read without a durable completion frame.
$fixture = New-NativeProgressFixture
try {
    $cachedHolder = New-RecoveryProgressLeaseHolder
    try {
        [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring' -ProgressLeaseHolder $cachedHolder)
        $beforeCachedTransition = Get-NativeLeaseBytes $cachedHolder.Lease
        $fixture.Unit.phase = 'complete'
        Assert-NativeThrows { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $cachedHolder } 'cached restoring-to-complete read transition'
        Assert-NativeThrows { Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $cachedHolder } 'cached restoring-to-complete append transition'
        Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $cachedHolder.Lease)) -ceq [Convert]::ToBase64String($beforeCachedTransition) -and
            $fixture.Journal.progressSequence -eq 1) 'cached phase rejection preserves the committed restoring frame.'
        $fixture.Unit.phase = 'restoring'
        Assert-Native (Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $cachedHolder) 'cached phase completes after restoring context is repaired.'
    } finally { Close-RecoveryProgressLeaseHolder $cachedHolder }
} finally { Remove-NativeProgressFixture $fixture }

# Arbitrary bytes do not identify a recoverable frame tail and remain
# byte-preserving even for a non-strict reader.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
    $tailWriter = [IO.File]::Open($progressPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $tailWriter.Write([byte[]](1, 2, 3, 4), 0, 4) } finally { $tailWriter.Dispose() }
    $beforeCorruptTail = [IO.File]::ReadAllBytes($progressPath)
    Assert-NativeThrows { Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units } 'arbitrary corrupt tail'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($progressPath)) -ceq [Convert]::ToBase64String($beforeCorruptTail)) 'arbitrary corrupt tail preserves exact bytes.'
} finally { Remove-NativeProgressFixture $fixture }

# Transaction, sequence, length, and same-phase checks use the parsed retained
# lease. A poisoned failure is disposed before each independent retry.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $samePhase = Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete'
    Assert-Native (-not $samePhase -and $fixture.Journal.progressSequence -eq 1) 'same-phase append is idempotent.'
    $fixture.Journal.transactionId = 'other-transaction'
    Assert-NativeThrows { Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' } 'transaction binding mismatch'
    $fixture.Journal.transactionId = $fixture.Manifest.transactionId
    $fixture.Journal.progressSequence = 2
    Assert-NativeThrows { Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' } 'sequence beyond retained progress'
    $fixture.Journal.progressSequence = 1
    $holder = New-RecoveryProgressLeaseHolder
    try {
        $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder
        $lease.Length++
        Assert-NativeThrows { Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $holder } 'retained length mismatch'
    } finally { Close-RecoveryProgressLeaseHolder $holder }
} finally { Remove-NativeProgressFixture $fixture }

# Strict mode revalidates a cached handle, even when the parsed transaction
# fields and sequence still look unchanged.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $cachedHolder = New-RecoveryProgressLeaseHolder
    try {
        Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $cachedHolder
        $badAcl = Get-Acl -LiteralPath (Get-RecoveryProgressPath $fixture.Manifest)
        $badAcl.SetAccessRuleProtection($false, $true)
        $badAcl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-545')),
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.AccessControlType]::Allow))
        [LifeOSRecoveryProgressNative]::SetProtectedDacl(
            $cachedHolder.Lease.Native.LeafHandle, $badAcl.GetSecurityDescriptorBinaryForm())
        Assert-NativeThrows {
            Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -Strict -ProgressLeaseHolder $cachedHolder
        } 'cached strict ACL revalidation'
    } finally { Close-RecoveryProgressLeaseHolder $cachedHolder }
} finally { Remove-NativeProgressFixture $fixture }

# A second journal object with matching scalar fields cannot reuse a parsed
# holder unless it is the same journal and unit collection.
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $cachedHolder = New-RecoveryProgressLeaseHolder
    try {
        Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $cachedHolder
        $secondJournal = [pscustomobject]@{
            schemaVersion = 1; transactionId = $fixture.Journal.transactionId; generation = $fixture.Journal.generation
            operatorSid = $fixture.Journal.operatorSid; manifestPath = $fixture.Journal.manifestPath
            units = $fixture.Journal.units; unitCount = 1; treeRoots = $fixture.Journal.treeRoots
            phase = 'artifacts'; progressPath = (Get-RecoveryProgressPath $fixture.Manifest); progressSequence = 1
        }
        Assert-NativeThrows {
            Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $secondJournal -JournalUnits $secondJournal.units -ProgressLeaseHolder $cachedHolder
        } 'independently reopened journal object'
    } finally { Close-RecoveryProgressLeaseHolder $cachedHolder }
} finally { Remove-NativeProgressFixture $fixture }

# At the exact record limit, a same-phase resume remains idempotent; only a
# new phase is rejected.
$savedMaxRecords = $script:LifeOSRecoveryProgressMaxRecords
$script:LifeOSRecoveryProgressMaxRecords = 1
$fixture = New-NativeProgressFixture
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    Assert-Native (-not (Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')) 'exact-limit same-phase resume remains idempotent.'
    $beforeLimitReject = [IO.File]::ReadAllBytes((Get-RecoveryProgressPath $fixture.Manifest))
    Assert-NativeThrows { Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring' } 'exact-limit new record'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Get-RecoveryProgressPath $fixture.Manifest))) -ceq [Convert]::ToBase64String($beforeLimitReject)) 'exact-limit rejection preserves bytes.'
} finally {
    Remove-NativeProgressFixture $fixture
    $script:LifeOSRecoveryProgressMaxRecords = $savedMaxRecords
}

# A missing leaf keeps the opened parent chain, so replacing that parent is
# rejected and creation can use the retained handle without reacquisition.
$fixture = New-NativeProgressFixture
try {
    $holder = New-RecoveryProgressLeaseHolder
    try {
        $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder
        Assert-Native ($null -ne $lease -and -not [bool]$lease.Native.HasLeaf) 'missing leaf retains an ancestor-only lease.'
        Assert-NativeThrows { Move-Item -LiteralPath $fixture.Backup -Destination ($fixture.Root + '-missing-parent-moved') -Force } 'missing-parent race'
        $created = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder -CreateIfMissing
        Assert-Native ($created.Native.HasLeaf -and $created.Created) 'missing leaf is created relative to the retained parent.'
    } finally { Close-RecoveryProgressLeaseHolder $holder }
} finally { Remove-NativeProgressFixture $fixture }

# A competing leaf is never adopted by FILE_CREATE; failed acquisition closes
# every ancestor so the competitor can be removed and independently reopened.
$fixture = New-NativeProgressFixture
try {
    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
    [IO.File]::WriteAllText($progressPath, 'competitor')
    Assert-NativeThrows { New-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -CreateNewOnly } 'missing-leaf create collision'
    Assert-Native ([IO.File]::ReadAllText($progressPath) -ceq 'competitor') 'create collision never adopts or overwrites the competitor.'
    Remove-Item -LiteralPath $progressPath -Force
    [IO.File]::WriteAllText($progressPath, 'independent')
    Remove-Item -LiteralPath $progressPath -Force
} finally { Remove-NativeProgressFixture $fixture }

# The artifact primitive keeps its quarantine and destination operations on
# native handles while the original progress parent/leaf lease is retained.
# The fixture also keeps a source, a manifest backup, and an outside sentinel
# so every failure path can prove byte preservation.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $sourceBefore = [IO.File]::ReadAllBytes($fixture.Source)
    $outsideBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantine = New-RecoveryArtifactQuarantineSibling -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantinePath = Join-Path $fixture.Backup $quarantine.Name
    Assert-Native ($quarantine.Name -match '^lifeos-quarantine-[0-9a-f]{32}\.bin$') 'quarantine name is generated by the native capability.'
    Assert-Native ([IO.Path]::GetDirectoryName($quarantinePath) -ieq $fixture.Backup -and [IO.File]::Exists($quarantinePath)) 'quarantine is a fresh sibling in BackupDirectory.'
    $staged = Open-RecoveryArtifactStaged -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    Assert-Native ($staged.Native.HasLeaf -and $staged.Native.Length -eq $fixture.ReplacementBytes.Length) 'staged post-state is verified before deletion.'
    $receipt = Copy-RecoveryArtifactToQuarantine -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine
    Assert-Native ($receipt.Verified -and $receipt.Native.Verified -and $receipt.Length -eq $sourceBefore.Length) 'copy receipt is verified and bounded by the native length.'
    Assert-Native ($receipt.Sha256 -ceq (Get-NativeBytesSha256 $sourceBefore)) 'copy receipt digest matches the source bytes.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeArtifactBytes $quarantine)) -ceq [Convert]::ToBase64String($sourceBefore)) 'quarantine bytes were copied through the retained handle.'
    Assert-Native ($quarantine.Native.FileAttributes -eq $destination.Native.FileAttributes -and
        $quarantine.Native.CreationTime -eq $destination.Native.CreationTime -and
        $quarantine.Native.LastWriteTime -eq $destination.Native.LastWriteTime) 'basic artifact metadata is preserved through handles.'
    [void](Remove-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine -CopyReceipt $receipt)
    Assert-Native (-not [IO.File]::Exists($fixture.Destination)) 'original destination is removed by handle-bound disposition.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Source)) -ceq [Convert]::ToBase64String($sourceBefore)) 'source fixture remains unchanged after deletion.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore)) 'manifest backup remains unchanged after deletion.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore)) 'progress stream remains unchanged after artifact mutation.'
    [void](Publish-RecoveryArtifactStaged -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Staged $staged)
    Assert-Native ([IO.File]::Exists($fixture.Destination) -and -not [IO.File]::Exists($fixture.Staged)) 'staged publication creates the destination and consumes the staged name.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Destination)) -ceq [Convert]::ToBase64String($fixture.ReplacementBytes)) 'publication leaves the staged bytes at the destination.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($outsideBefore)) 'outside sentinel is unchanged after successful publication.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Remove-NativeArtifactFixture $fixture
}

# Deletion cannot proceed from a verified pre-state and quarantine receipt
# alone. Both the direct native boundary and its PowerShell wrapper reject a
# context whose staged capability has never been opened.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$destination = $null
$quarantine = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $destinationBefore = [IO.File]::ReadAllBytes($fixture.Destination)
    $stagedBefore = [IO.File]::ReadAllBytes($fixture.Staged)
    $outsideBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantine = New-RecoveryArtifactQuarantineSibling -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantinePath = Join-Path $fixture.Backup $quarantine.Name
    $receipt = Copy-RecoveryArtifactToQuarantine -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine
    Assert-NativeThrowsSpecific {
        $artifactLease.Context.Native.DeleteDestinationAfterVerifiedCopy($receipt.Native)
    } 'delete without staged capability reaches the native boundary' 'Artifact deletion requires the active context-bound staged lease.'
    Assert-NativeThrowsSpecific {
        Remove-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine -CopyReceipt $receipt
    } 'delete without staged capability reaches the PowerShell boundary' 'Recovery artifact deletion requires a staged capability opened through Open-RecoveryArtifactStaged.'
    Assert-Native ([IO.File]::Exists($fixture.Destination) -and
        [Convert]::ToBase64String((Get-NativeArtifactBytes $destination)) -ceq [Convert]::ToBase64String($destinationBefore)) 'delete without staged capability preserves the destination.'
    Assert-Native ([IO.File]::Exists($quarantinePath) -and
        [Convert]::ToBase64String((Get-NativeArtifactBytes $quarantine)) -ceq [Convert]::ToBase64String($fixture.OriginalBytes)) 'delete without staged capability preserves the quarantine.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Staged)) -ceq [Convert]::ToBase64String($stagedBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($outsideBefore)) 'delete without staged capability preserves staged, manifest, progress, and outside bytes.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# Same-length destination bytes that do not match the journal pre-state are
# rejected before the destination can become a copy/delete source.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $wrongDestinationBytes = New-Object byte[] $fixture.OriginalBytes.Length
    [Array]::Copy($fixture.OriginalBytes, $wrongDestinationBytes, $wrongDestinationBytes.Length)
    $wrongDestinationBytes[0] = [byte]0x7f
    [IO.File]::WriteAllBytes($fixture.Destination, $wrongDestinationBytes)
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $sourceBefore = [IO.File]::ReadAllBytes($fixture.Source)
    $stagedBefore = [IO.File]::ReadAllBytes($fixture.Staged)
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $outsideBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    Assert-NativeThrows {
        Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    } 'wrong destination bytes'
    Assert-Native ([IO.File]::Exists($fixture.Destination) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Destination)) -ceq [Convert]::ToBase64String($wrongDestinationBytes)) 'wrong destination bytes preserve the destination.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Source)) -ceq [Convert]::ToBase64String($sourceBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Staged)) -ceq [Convert]::ToBase64String($stagedBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($outsideBefore)) 'wrong destination bytes preserve recovery evidence and the outside sentinel.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# Same-length staged bytes that do not match the journal post-state are
# rejected before destination deletion.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$destination = $null
try {
    $wrongStagedBytes = New-Object byte[] $fixture.ReplacementBytes.Length
    for ($index = 0; $index -lt $wrongStagedBytes.Length; $index++) { $wrongStagedBytes[$index] = [byte]0x63 }
    [IO.File]::WriteAllBytes($fixture.Staged, $wrongStagedBytes)
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $destinationBefore = [IO.File]::ReadAllBytes($fixture.Destination)
    $sourceBefore = [IO.File]::ReadAllBytes($fixture.Source)
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $outsideBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    Assert-NativeThrows {
        Open-RecoveryArtifactStaged -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    } 'wrong staged bytes'
    Assert-Native ([IO.File]::Exists($fixture.Destination) -and
        [Convert]::ToBase64String((Get-NativeArtifactBytes $destination)) -ceq [Convert]::ToBase64String($destinationBefore)) 'wrong staged bytes preserve the destination before deletion.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Staged)) -ceq [Convert]::ToBase64String($wrongStagedBytes) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Source)) -ceq [Convert]::ToBase64String($sourceBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($outsideBefore)) 'wrong staged bytes preserve staging and recovery evidence.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# Wrapper scalar, path, and index swaps are rejected against the recomputed
# journal binding before any native artifact operation can run.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $context = $artifactLease.Context
    $mutations = @(
        [pscustomobject]@{ Name = 'mutated expected state'; Property = 'ExpectedPreState'; Value = 'file:' + ('0' * 64) },
        [pscustomobject]@{ Name = 'mutated expected post-state'; Property = 'ExpectedPostState'; Value = 'file:' + ('0' * 64) },
        [pscustomobject]@{ Name = 'mutated destination path'; Property = 'DestinationPath'; Value = (Join-Path $fixture.Root 'mutated-destination.bin') },
        [pscustomobject]@{ Name = 'mutated staging path'; Property = 'StagingPath'; Value = (Join-Path $fixture.Root 'mutated-staged.bin') },
        [pscustomobject]@{ Name = 'mutated unit index'; Property = 'UnitIndex'; Value = 1 },
        [pscustomobject]@{ Name = 'mutated byte bound'; Property = 'MaxBytes'; Value = [long]$context.MaxBytes - 1 },
        [pscustomobject]@{ Name = 'mutated progress path'; Property = 'ProgressPath'; Value = (Join-Path $fixture.Backup 'other-progress.jsonl') },
        [pscustomobject]@{ Name = 'mutated progress leaf identity'; Property = 'ProgressLeafIdentity'; Value = '00000000:0000000000000000' }
    )
    foreach ($mutation in $mutations) {
        $oldValue = $context.($mutation.Property)
        $context.($mutation.Property) = $mutation.Value
        Assert-NativeThrows {
            Assert-RecoveryArtifactMutationBinding -Context $context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
        } $mutation.Name
        $context.($mutation.Property) = $oldValue
    }
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# A valid restoring context remains tied to the sealed phase snapshot. Changing
# both mutable mirrors cannot mint a new restoring capability or authorize an
# existing context after the committed snapshot has been created.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $authority = $artifactLease.Holder.PhaseAuthority
    Assert-Native ($authority.GetPhase(0) -ceq 'restoring') 'valid restoring context has an immutable restoring phase authority.'
    $fullValidationsBefore = [long]$artifactLease.Holder.FullUnitValidationCount
    $indexedValidationsBefore = [long]$artifactLease.Holder.IndexedUnitValidationCount
    for ($validationIndex = 0; $validationIndex -lt 8; $validationIndex++) {
        [void](Assert-RecoveryArtifactMutationBinding -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0)
    }
    Assert-Native ([long]$artifactLease.Holder.FullUnitValidationCount -eq $fullValidationsBefore -and
        [long]$artifactLease.Holder.IndexedUnitValidationCount -ge $indexedValidationsBefore + 8) 'artifact binding uses indexed validation without a repeated full inventory scan.'
    $fixture.Unit.phase = 'complete'
    $artifactLease.Holder.ValidatedUnitPhases[0] = 'complete'
    Assert-Native ([object]::ReferenceEquals($artifactLease.Context.PhaseAuthority, $authority)) 'artifact context retains the original phase authority reference.'
    Assert-NativeThrows {
        Assert-RecoveryArtifactMutationBinding -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    } 'mutating both phase mirrors cannot authorize an existing context'
    Assert-NativeThrows {
        New-RecoveryArtifactMutationContext -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Unit $fixture.Unit -ProgressLeaseHolder $artifactLease.Holder
    } 'mutating both phase mirrors cannot mint a new context'
} finally {
    Close-NativeArtifactLease $artifactLease
    Remove-NativeArtifactFixture $fixture
}

# The native authority owns the retained lease and replay/commit cursor. The
# public facades must derive sequence and offset from that state while keeping
# exact frame bytes on the retained stream.
$fixture = New-NativeProgressFixture
$holder = $null
try {
    $holder = New-RecoveryProgressLeaseHolder
    $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder
    $authority = New-RecoveryProgressPhaseAuthority -Phases @('pending') -TransactionId $fixture.Manifest.transactionId -Generation $fixture.Manifest.generation -OperatorSid $fixture.Manifest.operatorSid -ManifestPath $fixture.Manifest.manifestPath -ProgressLease $lease -Checkpoint 0
    $holder.PhaseAuthority = $authority
    Assert-Native ([object]::ReferenceEquals($authority, $holder.PhaseAuthority) -and
        $authority.IsBoundTo($lease.Native) -and
        $authority.Lifecycle -ceq 'AwaitingInitialLeaf' -and
        [long]$authority.CommittedOffset -eq 0 -and
        [long]$authority.NextSequence -eq 0 -and
        [long]$authority.Checkpoint -eq 0) 'new authority owns the retained ancestor lease and starts with an immutable zero cursor.'
    $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder -CreateIfMissing
    Assert-Native ($authority.Lifecycle -ceq 'Replaying' -and
        $authority.IsBoundTo($lease.Native) -and $lease.Native.HasLeaf -and
        [long]$authority.CommittedOffset -eq 0 -and [long]$authority.NextSequence -eq 0) 'created progress leaf attaches to the same native authority lease.'

    $record0 = New-RecoveryProgressRecord -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring' -Sequence 0 -UnitCount 1
    $frame0 = New-RecoveryProgressFrame $record0
    $replayOffset = Write-NativeProgressFrame -Lease $lease -Frame $frame0
    Assert-Native ([long]$replayOffset -eq [long]$authority.CommittedOffset) 'replay frame is written at the authority-owned offset.'
    $replayed = [LifeOSRecoveryProgressNative]::ReplayRecoveryProgressFrame(
        $authority, $frame0.Header, $frame0.HeaderDigest, $frame0.Payload, $frame0.Digest, $frame0.Commit)
    Assert-Native ($replayed.Sequence -eq 0 -and $replayed.UnitIndex -eq 0 -and
        $replayed.Phase -ceq 'restoring' -and [long]$authority.NextSequence -eq 1 -and
        [long]$authority.CommittedOffset -eq [long]$frame0.TotalBytes) 'replay derives and publishes the next sequence and exact byte offset.'
    [LifeOSRecoveryProgressNative]::SealRecoveryProgressReplay($authority)
    Assert-Native ($authority.IsReady -and $authority.Lifecycle -ceq 'Ready') 'sealed replay transitions the authority to Ready.'

    $record1 = New-RecoveryProgressRecord -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -Sequence 1 -UnitCount 1
    $frame1 = New-RecoveryProgressFrame $record1
    $commitOffset = Write-NativeProgressFrame -Lease $lease -Frame $frame1
    Assert-Native ([long]$commitOffset -eq [long]$authority.CommittedOffset -and
        [long]$authority.NextSequence -eq 1) 'commit frame is appended at the authority cursor without caller-supplied offset or sequence.'
    $committed = [LifeOSRecoveryProgressNative]::CommitRecoveryProgressFrame(
        $authority, 0, 'complete', $frame1.Header, $frame1.HeaderDigest, $frame1.Payload,
        $frame1.Digest, $frame1.Commit)
    Assert-Native ($committed.Sequence -eq 1 -and $committed.Phase -ceq 'complete' -and
        [long]$authority.NextSequence -eq 2 -and
        [long]$authority.CommittedOffset -eq [long]($frame0.TotalBytes + $frame1.TotalBytes) -and
        [long]$lease.Stream.Length -eq [long]$authority.CommittedOffset) 'commit derives and publishes sequence and offset after exact retained-stream readback.'
    $expectedBytes = New-Object byte[] ([int]($frame0.TotalBytes + $frame1.TotalBytes))
    $expectedFrame0 = Get-NativeProgressFrameBytes $frame0
    $expectedFrame1 = Get-NativeProgressFrameBytes $frame1
    [Array]::Copy($expectedFrame0, 0, $expectedBytes, 0, $expectedFrame0.Length)
    [Array]::Copy($expectedFrame1, 0, $expectedBytes, $expectedFrame0.Length, $expectedFrame1.Length)
    Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $lease)) -ceq
        [Convert]::ToBase64String($expectedBytes)) 'replay and commit preserve the exact durable frame byte sequence.'
    [LifeOSRecoveryProgressNative]::CloseRecoveryPhaseAuthority($authority)
    Assert-Native ($authority.Lifecycle -ceq 'Closed' -and -not $authority.IsReady) 'close facade makes the native authority terminal.'
} finally {
    if ($null -ne $holder) { Close-RecoveryProgressLeaseHolder $holder }
    Remove-NativeProgressFixture $fixture
}

# Replay rejects the record at the configured limit before publishing a token
# or cursor. The durable candidate remains inspectable for the caller's
# recovery decision, while the authority is poisoned for a fresh replay.
$savedMaxRecords = $script:LifeOSRecoveryProgressMaxRecords
$script:LifeOSRecoveryProgressMaxRecords = 1
$fixture = New-NativeProgressFixture
$holder = $null
try {
    $holder = New-RecoveryProgressLeaseHolder
    $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder
    $authority = New-RecoveryProgressPhaseAuthority -Phases @('pending') -TransactionId $fixture.Manifest.transactionId -Generation $fixture.Manifest.generation -OperatorSid $fixture.Manifest.operatorSid -ManifestPath $fixture.Manifest.manifestPath -ProgressLease $lease -Checkpoint 0
    $holder.PhaseAuthority = $authority
    $lease = Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder -CreateIfMissing
    $record0 = New-RecoveryProgressRecord -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring' -Sequence 0 -UnitCount 1
    $frame0 = New-RecoveryProgressFrame $record0
    [void](Write-NativeProgressFrame -Lease $lease -Frame $frame0)
    [void]([LifeOSRecoveryProgressNative]::ReplayRecoveryProgressFrame(
        $authority, $frame0.Header, $frame0.HeaderDigest, $frame0.Payload, $frame0.Digest, $frame0.Commit))
    $record1 = [ordered]@{
        sequence = 1; transactionId = [string]$fixture.Manifest.transactionId
        generation = [string]$fixture.Manifest.generation; operatorSid = [string]$fixture.Manifest.operatorSid
        manifestPath = [string]$fixture.Manifest.manifestPath; unitIndex = 0; phase = 'complete'
    }
    $frame1 = New-RecoveryProgressFrame $record1
    [void](Write-NativeProgressFrame -Lease $lease -Frame $frame1)
    $beforeLimitBytes = Get-NativeLeaseBytes $lease
    $beforeLimitOffset = [long]$authority.CommittedOffset
    $beforeLimitSequence = [long]$authority.NextSequence
    $beforeLimitToken = $authority.GetToken(0)
    Assert-NativeThrows {
        [LifeOSRecoveryProgressNative]::ReplayRecoveryProgressFrame(
            $authority, $frame1.Header, $frame1.HeaderDigest, $frame1.Payload, $frame1.Digest, $frame1.Commit)
    } 'native replay record limit'
    Assert-Native ($authority.IsPoisoned -and
        [long]$authority.CommittedOffset -eq $beforeLimitOffset -and
        [long]$authority.NextSequence -eq $beforeLimitSequence -and
        [long]$authority.UpdateCount -eq 1 -and
        [object]::ReferenceEquals($authority.GetToken(0), $beforeLimitToken) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $lease)) -ceq [Convert]::ToBase64String($beforeLimitBytes)) 'native replay limit rejection preserves the published cursor, token, and exact durable bytes.'
} finally {
    if ($null -ne $holder) { Close-RecoveryProgressLeaseHolder $holder }
    Remove-NativeProgressFixture $fixture
    $script:LifeOSRecoveryProgressMaxRecords = $savedMaxRecords
}

# A failed native commit poisons the authority without changing its cursor,
# token, or retained bytes, and poisoned state cannot authorize artifact access.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $authority = $artifactLease.Holder.PhaseAuthority
    $lease = $artifactLease.Holder.Lease
    $baseBytes = Get-NativeLeaseBytes $lease
    $baseOffset = [long]$authority.CommittedOffset
    $baseSequence = [long]$authority.NextSequence
    $baseToken = $authority.GetToken(0)
    Assert-Native ($authority.IsReady -and $authority.Lifecycle -ceq 'Ready' -and
        $authority.IsBoundTo($lease.Native) -and $baseOffset -eq [long]$lease.Length -and
        $baseSequence -eq [long]$lease.Sequence) 'artifact access starts from a Ready authority bound to the retained lease cursor.'
    $invalidFramePart = New-Object byte[] 0
    Assert-NativeThrows {
        [LifeOSRecoveryProgressNative]::CommitRecoveryProgressFrame(
            $authority, 0, 'complete', $invalidFramePart, $invalidFramePart,
            $invalidFramePart, $invalidFramePart, $invalidFramePart)
    } 'invalid native commit poisons the authority'
    Assert-Native ($authority.IsPoisoned -and $authority.Lifecycle -ceq 'Poisoned' -and
        [long]$authority.CommittedOffset -eq $baseOffset -and
        [long]$authority.NextSequence -eq $baseSequence -and
        [long]$authority.UpdateCount -eq 1 -and
        [object]::ReferenceEquals($authority.GetToken(0), $baseToken)) 'poisoned commit leaves the native cursor and token unchanged.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $lease)) -ceq
        [Convert]::ToBase64String($baseBytes)) 'poisoned commit leaves the retained progress bytes unchanged.'
    Assert-NativeThrows { $artifactLease.Context.Native.OpenDestination() } 'poisoned authority cannot authorize an artifact operation.'
    [LifeOSRecoveryProgressNative]::CloseRecoveryPhaseAuthority($authority)
    Assert-Native ($authority.Lifecycle -ceq 'Closed') 'closed facade remains terminal after poisoning.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Remove-NativeArtifactFixture $fixture
}

# Native commit owns the exact stream boundary. A valid frame followed by a
# torn byte or a complete extra frame is rejected before the authority can
# publish the transition.
function Invoke-NativeCommitSuffixRejection {
    param([Parameter(Mandatory)][ValidateSet('byte', 'complete-frames')][string]$SuffixKind)
    $fixture = New-NativeArtifactFixture
    $artifactLease = $null
    try {
        $artifactLease = New-NativeArtifactLease $fixture
        $authority = $artifactLease.Holder.PhaseAuthority
        $lease = $artifactLease.Holder.Lease
        $frameRecord = New-RecoveryProgressRecord -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -Sequence 1 -UnitCount 1
        $candidate = New-RecoveryProgressFrame $frameRecord
        if ($SuffixKind -ceq 'byte') {
            $suffix = [byte[]]@(0x7f)
        } else {
            $frameBytes = Get-NativeProgressFrameBytes $candidate
            $suffix = New-Object byte[] ($frameBytes.Length * 2)
            [Array]::Copy($frameBytes, 0, $suffix, 0, $frameBytes.Length)
            [Array]::Copy($frameBytes, 0, $suffix, $frameBytes.Length, $frameBytes.Length)
        }
        $baseBytes = Get-NativeLeaseBytes $lease
        $lease.Stream.Position = $lease.Stream.Length
        $lease.Stream.Write($suffix, 0, $suffix.Length)
        $lease.Stream.Flush($true)
        $expectedBytes = New-Object byte[] ($baseBytes.Length + $suffix.Length)
        [Array]::Copy($baseBytes, 0, $expectedBytes, 0, $baseBytes.Length)
        [Array]::Copy($suffix, 0, $expectedBytes, $baseBytes.Length, $suffix.Length)
        $baseOffset = [long]$authority.CommittedOffset
        $baseSequence = [long]$authority.NextSequence
        $baseToken = $authority.GetToken(0)
        Assert-NativeThrows {
            [LifeOSRecoveryProgressNative]::CommitRecoveryProgressFrame(
                $authority, 0, 'complete', $candidate.Header, $candidate.HeaderDigest,
                $candidate.Payload, $candidate.Digest, $candidate.Commit)
        } "native commit rejects a $SuffixKind suffix"
        Assert-Native ($authority.IsPoisoned -and
            [long]$authority.CommittedOffset -eq $baseOffset -and
            [long]$authority.NextSequence -eq $baseSequence -and
            [long]$authority.UpdateCount -eq 1 -and
            [object]::ReferenceEquals($authority.GetToken(0), $baseToken) -and
            [Convert]::ToBase64String((Get-NativeLeaseBytes $lease)) -ceq [Convert]::ToBase64String($expectedBytes)) "native commit $SuffixKind rejection preserves cursor, token, and exact bytes"
    } finally {
        Close-NativeArtifactLease $artifactLease
        Remove-NativeArtifactFixture $fixture
    }
}
Invoke-NativeCommitSuffixRejection -SuffixKind 'byte'
Invoke-NativeCommitSuffixRejection -SuffixKind 'complete-frames'

# A committed phase transition replaces only the affected native token. A
# context created before that transition is stale even though the ledger object
# itself remains shared with the holder.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $authority = $artifactLease.Context.PhaseAuthority
    $token = $artifactLease.Context.PhaseToken
    $updatesBefore = [long]$authority.UpdateCount
    Assert-Native ($authority.IsReady -and $authority.IsBoundTo($artifactLease.Holder.Lease.Native) -and
        [long]$authority.CommittedOffset -eq [long]$artifactLease.Holder.Lease.Length -and
        [long]$authority.NextSequence -eq [long]$artifactLease.Holder.Lease.Sequence) 'stale-token test begins from the ready authority-owned cursor.'
    Assert-Native (Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $artifactLease.Holder) 'committed phase transition advances the native ledger.'
    Assert-Native ([object]::ReferenceEquals($artifactLease.Holder.PhaseAuthority, $authority) -and
        -not [object]::ReferenceEquals($authority.GetToken(0), $token) -and
        [long]$authority.UpdateCount -eq $updatesBefore + 1) 'phase transition replaces one token without rebuilding the authority inventory.'
    Assert-NativeThrowsSpecific {
        $artifactLease.Context.Native.OpenDestination()
    } 'stale native context after committed phase transition' 'Recovery artifact access is not bound to the ready progress authority.'
    Assert-NativeThrowsSpecific {
        Assert-RecoveryArtifactMutationBinding -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    } 'stale wrapper context after committed phase transition' 'Recovery artifact mutation requires a journal-bound restoring unit.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Remove-NativeArtifactFixture $fixture
}

# Native payload validation must bind decoded fields, rather than accepting a
# matching substring inside a larger or otherwise different JSON value.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $lease = $artifactLease.Holder.Lease
    $authority = $artifactLease.Holder.PhaseAuthority
    $baseLength = [long]$lease.Length
    $baseSequence = [long]$lease.Sequence
    $baseToken = $authority.GetToken(0)
    $baseBytes = Get-NativeLeaseBytes $lease
    $validText = New-NativeProgressPayloadText -Fixture $fixture
    $reorderedRecord = [ordered]@{
        phase = 'complete'; manifestPath = [string]$fixture.Manifest.manifestPath
        operatorSid = [string]$fixture.Manifest.operatorSid; generation = [string]$fixture.Manifest.generation
        transactionId = [string]$fixture.Manifest.transactionId; unitIndex = 0; sequence = 1
    }
    $reorderedText = [string]($reorderedRecord | ConvertTo-Json -Compress)
    $reorderedText = $reorderedText.Replace('{', '{ ').Replace('}', ' }').Replace(',"', ', "').Replace('":', '" : ')
    $reorderedText = $reorderedText.Replace('"phase" : "complete"', '"phase" : "\u0063omplete"')
    Assert-Native $reorderedText.Contains('\u0063omplete') 'positive escaped phase payload contains the intended escape.'
    $reorderedPayload = Convert-NativeProgressPayloadText $reorderedText
    $reorderedRecordNative = [LifeOSRecoveryProgressNative]::ParseRecoveryProgressRecord(
        $reorderedPayload, 1, 0, 'complete', $fixture.Manifest.transactionId,
        $fixture.Manifest.generation, $fixture.Manifest.operatorSid, $fixture.Manifest.manifestPath)
    Assert-Native ($reorderedRecordNative.Sequence -eq 1 -and $reorderedRecordNative.UnitIndex -eq 0 -and
        $reorderedRecordNative.Phase -ceq 'complete') 'reordered whitespace and escaped phase payload is accepted.'
    $surrogateText = $validText.Replace(('"transactionId":"' + $fixture.Manifest.transactionId + '"'), '"transactionId":"native-\uD83D\uDE00"')
    $surrogatePayload = Convert-NativeProgressPayloadText $surrogateText
    $surrogateExpectedIdentity = 'native-' + [char]::ConvertFromUtf32(0x1f600)
    $surrogateRecordNative = [LifeOSRecoveryProgressNative]::ParseRecoveryProgressRecord(
        $surrogatePayload, 1, 0, 'complete', $surrogateExpectedIdentity,
        $fixture.Manifest.generation, $fixture.Manifest.operatorSid, $fixture.Manifest.manifestPath)
    Assert-Native ($surrogateRecordNative.TransactionId -ceq $surrogateExpectedIdentity) 'valid surrogate-pair identity is decoded.'
    $cases = @(
        [pscustomobject]@{
            Name = 'sequence prefix mismatch'; Expected = 'Recovery progress payload sequence binding is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":10'))
        },
        [pscustomobject]@{
            Name = 'unit index prefix mismatch'; Expected = 'Recovery progress payload unit binding is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"unitIndex":0', '"unitIndex":10'))
        },
        [pscustomobject]@{
            Name = 'duplicate field'; Expected = 'Recovery progress payload contains a duplicate field.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(',"phase":"complete"}', ',"phase":"complete","phase":"complete"}'))
        },
        [pscustomobject]@{
            Name = 'escaped duplicate field'; Expected = 'Recovery progress payload contains a duplicate field.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1,', '"sequence":1,"\u0073equence":1,'))
        },
        [pscustomobject]@{
            Name = 'missing identity'; Expected = 'Recovery progress payload schema is incomplete.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace((' ,"transactionId":"' + $fixture.Manifest.transactionId + '"').TrimStart(), ''))
        },
        [pscustomobject]@{
            Name = 'unknown field'; Expected = 'Recovery progress payload contains an unknown field.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(',"phase":"complete"}', ',"phase":"complete","unknown":1}'))
        },
        [pscustomobject]@{
            Name = 'trailing JSON'; Expected = 'Recovery progress payload JSON has trailing data.'
            Payload = Convert-NativeProgressPayloadText ($validText + '{}')
        },
        [pscustomobject]@{
            Name = 'invalid UTF-8'; Expected = 'Recovery progress payload encoding is invalid.'
            Payload = [byte[]]@(0x7b, 0xff, 0x7d)
        },
        [pscustomobject]@{
            Name = 'malformed escape'; Expected = 'Recovery progress payload JSON contains an invalid escape.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(('"transactionId":"' + $fixture.Manifest.transactionId + '"'), '"transactionId":"\q"'))
        },
        [pscustomobject]@{
            Name = 'quoted sequence'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":"1"'))
        },
        [pscustomobject]@{
            Name = 'fractional sequence'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":1.0'))
        },
        [pscustomobject]@{
            Name = 'exponent sequence'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":1e0'))
        },
        [pscustomobject]@{
            Name = 'sequence overflow'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":9223372036854775808'))
        },
        [pscustomobject]@{
            Name = 'signed sequence'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":-1'))
        },
        [pscustomobject]@{
            Name = 'leading zero sequence'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"sequence":1', '"sequence":01'))
        },
        [pscustomobject]@{
            Name = 'unit index overflow'; Expected = 'Recovery progress payload number is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"unitIndex":0', '"unitIndex":2147483648'))
        },
        [pscustomobject]@{
            Name = 'case variant field'; Expected = 'Recovery progress payload contains an unknown field.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace('"phase":"complete"', '"Phase":"complete"'))
        },
        [pscustomobject]@{
            Name = 'invalid unicode escape'; Expected = 'Recovery progress payload JSON is invalid.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(('"transactionId":"' + $fixture.Manifest.transactionId + '"'), '"transactionId":"\uZZZZ"'))
        },
        [pscustomobject]@{
            Name = 'unpaired high surrogate'; Expected = 'Recovery progress payload JSON contains an unpaired surrogate.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(('"transactionId":"' + $fixture.Manifest.transactionId + '"'), '"transactionId":"\uD800"'))
        },
        [pscustomobject]@{
            Name = 'unpaired low surrogate'; Expected = 'Recovery progress payload JSON contains an unpaired surrogate.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(('"transactionId":"' + $fixture.Manifest.transactionId + '"'), '"transactionId":"\uDC00"'))
        },
        [pscustomobject]@{
            Name = 'unescaped control character'; Expected = 'Recovery progress payload JSON contains an unescaped control character.'
            Payload = Convert-NativeProgressPayloadText ($validText.Replace(('"transactionId":"' + $fixture.Manifest.transactionId + '"'), ('"transactionId":"a' + [char]1 + 'b"')))
        },
        [pscustomobject]@{
            Name = 'identity string too long'; Expected = 'Recovery progress payload string is too long.'
            Payload = Convert-NativeProgressPayloadText (New-NativeProgressPayloadText -Fixture $fixture -TransactionId ('x' * 4097))
        },
        [pscustomobject]@{
            Name = 'transaction identity mismatch'; Expected = 'Recovery progress payload identity binding is invalid.'
            Payload = Convert-NativeProgressPayloadText (New-NativeProgressPayloadText -Fixture $fixture -TransactionId 'wrong-transaction')
        },
        [pscustomobject]@{
            Name = 'generation identity mismatch'; Expected = 'Recovery progress payload identity binding is invalid.'
            Payload = Convert-NativeProgressPayloadText (New-NativeProgressPayloadText -Fixture $fixture -Generation 'wrong-generation')
        },
        [pscustomobject]@{
            Name = 'operator identity mismatch'; Expected = 'Recovery progress payload identity binding is invalid.'
            Payload = Convert-NativeProgressPayloadText (New-NativeProgressPayloadText -Fixture $fixture -OperatorSid 'S-1-5-18')
        },
        [pscustomobject]@{
            Name = 'manifest identity mismatch'; Expected = 'Recovery progress payload identity binding is invalid.'
            Payload = Convert-NativeProgressPayloadText (New-NativeProgressPayloadText -Fixture $fixture -ManifestPath (Join-Path $fixture.Backup 'other.json'))
        }
    )
    foreach ($case in $cases) {
        $bytesBeforeReject = Get-NativeLeaseBytes $lease
        Assert-NativeThrowsSpecific {
            [LifeOSRecoveryProgressNative]::ParseRecoveryProgressRecord(
                $case.Payload, $baseSequence, 0, 'complete', $fixture.Manifest.transactionId,
                $fixture.Manifest.generation, $fixture.Manifest.operatorSid, $fixture.Manifest.manifestPath)
        } $case.Name $case.Expected
        $bytesAfterReject = Get-NativeLeaseBytes $lease
        Assert-Native ([Convert]::ToBase64String($bytesAfterReject) -ceq
            [Convert]::ToBase64String($bytesBeforeReject)) "$($case.Name) does not rewrite the retained stream."
        Assert-Native ([long]$authority.UpdateCount -eq 1 -and
            [object]::ReferenceEquals($authority.GetToken(0), $baseToken) -and
            [long]$authority.CommittedOffset -eq $baseLength -and
            [long]$authority.NextSequence -eq $baseSequence -and
            $authority.IsReady) "$($case.Name) leaves the native token and authority cursor unchanged."
        Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $lease)) -ceq
            [Convert]::ToBase64String($baseBytes)) "$($case.Name) leaves the committed progress bytes unchanged."
    }
    Assert-Native (Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete' -ProgressLeaseHolder $artifactLease.Holder) 'strict parser accepts a valid complete frame.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Remove-NativeArtifactFixture $fixture
}

# A pending unit and a forged in-memory restoring phase are not durable
# recovery authorization.
$fixture = New-NativeArtifactFixture
$holder = $null
try {
    $holder = New-RecoveryProgressLeaseHolder
    [void](Get-RecoveryProgressLease -Manifest $fixture.Manifest -Journal $fixture.Journal -Holder $holder -CreateIfMissing)
    Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $holder
    Assert-NativeThrowsSpecific {
        New-RecoveryArtifactMutationContext -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Unit $fixture.Unit -ProgressLeaseHolder $holder
    } 'pending phase rejection' 'Recovery artifact mutation requires a journal-bound restoring unit.'
    $fixture.Unit.phase = 'restoring'
    $holder.ValidatedUnitPhases[0] = 'restoring'
    Assert-NativeThrowsSpecific {
        New-RecoveryArtifactMutationContext -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Unit $fixture.Unit -ProgressLeaseHolder $holder
    } 'forged in-memory phase' 'Recovery progress lease holder unit identity, content, or phase changed.'
} finally {
    if ($null -ne $holder) { Close-RecoveryProgressLeaseHolder $holder }
    Remove-NativeArtifactFixture $fixture
}

# A durable complete unit cannot be reused as the restoring artifact context.
$fixture = New-NativeArtifactFixture
$holder = $null
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete')
    $holder = New-RecoveryProgressLeaseHolder
    Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $holder
    Assert-NativeThrows {
        New-RecoveryArtifactMutationContext -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Unit $fixture.Unit -ProgressLeaseHolder $holder
    } 'complete phase rejection'
} finally {
    if ($null -ne $holder) { Close-RecoveryProgressLeaseHolder $holder }
    Remove-NativeArtifactFixture $fixture
}

# An unknown in-memory phase is rejected by the retained holder phase ledger.
$fixture = New-NativeArtifactFixture
$holder = $null
try {
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring')
    $holder = New-RecoveryProgressLeaseHolder
    Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $holder
    $fixture.Unit.phase = 'unknown'
    Assert-NativeThrows {
        New-RecoveryArtifactMutationContext -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Unit $fixture.Unit -ProgressLeaseHolder $holder
    } 'unknown phase rejection'
} finally {
    if ($null -ne $holder) { Close-RecoveryProgressLeaseHolder $holder }
    Remove-NativeArtifactFixture $fixture
}

# Native construction accepts only absent or file:<64 lowercase hex SHA-256;
# malformed state strings never produce an artifact context.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $badStates = @(
        'present',
        'tree:' + ('x' * 64),
        'file:' + ('A' * 64),
        'file:' + ('a' * 63),
        'file:' + ('a' * 65),
        'file:' + ('a' * 64) + ' ',
        'file:' + ('a' * 64) + "`n"
    )
    foreach ($position in @('pre', 'post')) {
        foreach ($badState in $badStates) {
            $expectedPreState = if ($position -eq 'pre') { $badState } else { [string]$fixture.Unit.pre }
            $expectedPostState = if ($position -eq 'post') { $badState } else { [string]$fixture.Unit.post }
            Assert-NativeThrows {
                [void][LifeOSRecoveryProgressNative]::NewArtifactMutationContext(
                    $artifactLease.Context.Native.ProgressLease,
                    $artifactLease.Context.Native.BackupDirectoryHandle,
                    $artifactLease.Context.Native.BackupDirectoryIdentity,
                    $artifactLease.Context.Native.DestinationPath,
                    $artifactLease.Context.Native.StagedPath,
                    0,
                    [long]$artifactLease.Context.MaxBytes,
                    $fixture.Manifest.transactionId,
                    $fixture.Manifest.generation,
                    $fixture.Manifest.manifestPath,
                    $expectedPreState,
                    $expectedPostState,
                    $artifactLease.Context.Native.PhaseAuthority)
            } ('malformed expected state ' + $position + ': ' + $badState)
        }
    }
    $absentPreContext = [LifeOSRecoveryProgressNative]::NewArtifactMutationContext(
        $artifactLease.Context.Native.ProgressLease,
        $artifactLease.Context.Native.BackupDirectoryHandle,
        $artifactLease.Context.Native.BackupDirectoryIdentity,
        $artifactLease.Context.Native.DestinationPath,
        $artifactLease.Context.Native.StagedPath,
        0,
        [long]$artifactLease.Context.MaxBytes,
        $fixture.Manifest.transactionId,
        $fixture.Manifest.generation,
        $fixture.Manifest.manifestPath,
        'absent',
        $fixture.Unit.post,
        $artifactLease.Context.Native.PhaseAuthority)
    try {
        Assert-NativeThrows { $absentPreContext.OpenDestination() } 'absent destination source rejection'
    } finally { $absentPreContext.Dispose() }
    $absentPostContext = [LifeOSRecoveryProgressNative]::NewArtifactMutationContext(
        $artifactLease.Context.Native.ProgressLease,
        $artifactLease.Context.Native.BackupDirectoryHandle,
        $artifactLease.Context.Native.BackupDirectoryIdentity,
        $artifactLease.Context.Native.DestinationPath,
        $artifactLease.Context.Native.StagedPath,
        0,
        [long]$artifactLease.Context.MaxBytes,
        $fixture.Manifest.transactionId,
        $fixture.Manifest.generation,
        $fixture.Manifest.manifestPath,
        $fixture.Unit.pre,
        'absent',
        $artifactLease.Context.Native.PhaseAuthority)
    try {
        Assert-NativeThrows { $absentPostContext.OpenStaged() } 'absent staged source rejection'
    } finally { $absentPostContext.Dispose() }
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# The exact file length is accepted at the native byte bound.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture -MaxBytes ([long]$fixture.OriginalBytes.Length)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $staged = Open-RecoveryArtifactStaged -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    Assert-Native ($destination.Native.Length -eq $fixture.OriginalBytes.Length -and
        $staged.Native.Length -eq $fixture.ReplacementBytes.Length) 'exact-bound artifact files are accepted.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# One byte below the destination length is rejected before any mutation.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture -MaxBytes ([long]$fixture.OriginalBytes.Length - 1)
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $destinationBefore = [IO.File]::ReadAllBytes($fixture.Destination)
    $stagedBefore = [IO.File]::ReadAllBytes($fixture.Staged)
    $sourceBefore = [IO.File]::ReadAllBytes($fixture.Source)
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $outsideBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    Assert-NativeThrows {
        Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    } 'one-byte-over-bound'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Destination)) -ceq [Convert]::ToBase64String($destinationBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Staged)) -ceq [Convert]::ToBase64String($stagedBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Source)) -ceq [Convert]::ToBase64String($sourceBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($outsideBefore)) 'one-byte-over-bound rejection preserves every evidence file.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# A failed copy after the destination and generated sibling are both retained
# deletes the unverified sibling by handle and leaves all existing evidence.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$quarantinePath = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $sourceBefore = [IO.File]::ReadAllBytes($fixture.Source)
    $destinationBefore = [IO.File]::ReadAllBytes($fixture.Destination)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantine = New-RecoveryArtifactQuarantineSibling -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantinePath = Join-Path $fixture.Backup $quarantine.Name
    # A quarantine stream whose length changed behind its wrapper must be
    # rejected before copying. Its native leaf remains open so cleanup can
    # delete the unverified name by handle.
    $quarantine.Native.Stream.SetLength($fixture.OriginalBytes.Length + 1)
    Assert-NativeThrows { Copy-RecoveryArtifactToQuarantine -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine } 'unusable quarantine stream cleanup'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Source)) -ceq [Convert]::ToBase64String($sourceBefore)) 'failed copy preserves source bytes.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeArtifactBytes $destination)) -ceq [Convert]::ToBase64String($destinationBefore)) 'failed copy preserves destination bytes.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore)) 'failed copy preserves manifest backup bytes.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore)) 'failed copy preserves progress bytes.'
} finally {
    Close-NativeArtifactLease $artifactLease
    if ($null -ne $quarantinePath) { Assert-Native (-not [IO.File]::Exists($quarantinePath)) 'failed copy leaves no unverified quarantine orphan.' }
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# A competing reader opened first with FileShare.Read denies DELETE sharing.
# The retained mutation contract must therefore fail at destination handle
# acquisition with ERROR_SHARING_VIOLATION; a mutation handle cannot be made
# compatible by broadening its retained share flags.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$competingReader = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $destinationBefore = [IO.File]::ReadAllBytes($fixture.Destination)
    $competingReader = [IO.File]::Open($fixture.Destination, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $sharingError = $null
    try {
        [void](Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0)
    } catch [System.ComponentModel.Win32Exception] {
        $sharingError = $_.Exception
    }
    Assert-Native ($null -ne $sharingError -and $sharingError.NativeErrorCode -eq 32) 'retained mutation acquisition reports ERROR_SHARING_VIOLATION.'
    Assert-Native ([IO.File]::Exists($fixture.Destination) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Destination)) -ceq [Convert]::ToBase64String($destinationBefore)) 'failed acquisition preserves the destination.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore)) 'failed delete preserves manifest backup and progress.'
} finally {
    if ($null -ne $competingReader) { $competingReader.Dispose() }
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# Publication checks the destination name immediately before a no-replace
# rename. An adversarial competing leaf must make publication fail while the
# staged file, quarantine, progress, manifest backup, and sentinel remain.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$competingLease = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $stagedBefore = [IO.File]::ReadAllBytes($fixture.Staged)
    $outsideBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantine = New-RecoveryArtifactQuarantineSibling -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantinePath = Join-Path $fixture.Backup $quarantine.Name
    $staged = Open-RecoveryArtifactStaged -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $receipt = Copy-RecoveryArtifactToQuarantine -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine
    [void](Remove-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine -CopyReceipt $receipt)
    $competingAcl = New-RecoveryProgressAcl -OperatorSid $nativeOperatorSid
    $competingLease = [LifeOSRecoveryProgressNative]::CreateNew((Get-FullPath $fixture.Destination), $true, $competingAcl.GetSecurityDescriptorBinaryForm())
    $competingBytes = [Text.UTF8Encoding]::new($false).GetBytes('competing-destination')
    $competingLease.Stream.Write($competingBytes, 0, $competingBytes.Length)
    $competingLease.Stream.Flush($true)
    Assert-NativeThrows { Publish-RecoveryArtifactStaged -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Staged $staged } 'competing destination no-replace publication'
    Assert-Native ([Convert]::ToBase64String((Get-NativeHandleLeaseBytes $competingLease)) -ceq [Convert]::ToBase64String($competingBytes)) 'publication never replaces the competing destination.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeArtifactBytes $staged)) -ceq [Convert]::ToBase64String($stagedBefore)) 'failed publication preserves staged bytes.'
    Assert-Native ([IO.File]::Exists($quarantinePath) -and
        [Convert]::ToBase64String((Get-NativeArtifactBytes $quarantine)) -ceq [Convert]::ToBase64String($fixture.OriginalBytes)) 'failed publication preserves quarantine bytes.'
    Assert-Native ([Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($outsideBefore)) 'failed publication preserves recovery evidence and outside sentinel.'
} finally {
    if ($null -ne $competingLease) { try { $competingLease.Dispose() } catch { } }
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# Reparse ancestors and leaves, hard-linked leaves, and paths outside the
# journal roots are rejected before any quarantine or deletion is attempted.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$junction = $null
try {
    $redirectTarget = Join-Path $fixture.Root 'redirect-target'
    $junction = Join-Path $fixture.Root 'redirect'
    Ensure-Directory $redirectTarget
    [IO.File]::WriteAllBytes((Join-Path $redirectTarget 'destination.bin'), [Text.UTF8Encoding]::new($false).GetBytes('redirected'))
    [IO.File]::WriteAllBytes((Join-Path $redirectTarget 'staged.bin'), [Text.UTF8Encoding]::new($false).GetBytes('redirected-stage'))
    New-Item -ItemType Junction -Path $junction -Target $redirectTarget | Out-Null
    $fixture.Unit.destination = Join-Path $junction 'destination.bin'
    $fixture.Unit.stagingPath = Join-Path $junction 'staged.bin'
    $artifactLease = New-NativeArtifactLease $fixture
    Assert-NativeThrows { Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 } 'reparse ancestor'
} finally {
    Close-NativeArtifactLease $artifactLease
    if ($null -ne $junction) {
        try { [IO.Directory]::Delete($junction) } catch { }
    }
    Remove-NativeArtifactFixture $fixture
}

$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    [IO.File]::Delete($fixture.Destination)
    $leafTarget = Join-Path $fixture.Root 'leaf-target'
    Ensure-Directory $leafTarget
    New-Item -ItemType Junction -Path $fixture.Destination -Target $leafTarget | Out-Null
    $artifactLease = New-NativeArtifactLease $fixture
    Assert-NativeThrows { Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 } 'reparse leaf'
} finally {
    Close-NativeArtifactLease $artifactLease
    Remove-NativeArtifactFixture $fixture
}

$fixture = New-NativeArtifactFixture
$artifactLease = $null
$hardLink = $null
try {
    $hardLink = Join-Path $fixture.Root 'destination-hard-link.bin'
    New-Item -ItemType HardLink -Path $hardLink -Target $fixture.Destination | Out-Null
    $artifactLease = New-NativeArtifactLease $fixture
    Assert-NativeThrows { Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 } 'hard-link destination'
} finally {
    Close-NativeArtifactLease $artifactLease
    if ($null -ne $hardLink) { Remove-Item -LiteralPath $hardLink -Force -ErrorAction SilentlyContinue }
    Remove-NativeArtifactFixture $fixture
}

$fixture = New-NativeArtifactFixture
$holder = $null
try {
    [IO.File]::WriteAllText((Join-Path $fixture.OutsideRoot 'foreign-destination.bin'), 'foreign-destination', [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $fixture.OutsideRoot 'foreign-staged.bin'), 'foreign-staged', [Text.UTF8Encoding]::new($false))
    $foreignBefore = [IO.File]::ReadAllBytes($fixture.OutsideSentinel)
    $fixture.Unit.destination = Join-Path $fixture.OutsideRoot 'foreign-destination.bin'
    $fixture.Unit.stagingPath = Join-Path $fixture.OutsideRoot 'foreign-staged.bin'
    [void](Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'restoring')
    $holder = New-RecoveryProgressLeaseHolder
    [void](Read-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -JournalUnits $fixture.Journal.units -ProgressLeaseHolder $holder)
    Assert-NativeThrowsSpecific {
        New-RecoveryArtifactMutationContext -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Unit $fixture.Unit -ProgressLeaseHolder $holder
    } 'foreign artifact parent' 'Recovery artifact mutation path is outside the journal tree roots.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.OutsideSentinel)) -ceq [Convert]::ToBase64String($foreignBefore)) 'foreign parent rejection preserves outside sentinel.'
} finally {
    if ($null -ne $holder) { Close-RecoveryProgressLeaseHolder $holder }
    Remove-NativeArtifactFixture $fixture
}

# A deterministic nonce can only collide with an existing name; the generated
# CreateNew operation never opens or overwrites that competitor.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
try {
    $nonce = [Guid]::NewGuid()
    $collisionPath = Join-Path $fixture.Backup ('lifeos-quarantine-' + $nonce.ToString('N') + '.bin')
    [IO.File]::WriteAllText($collisionPath, 'quarantine-collision', [Text.UTF8Encoding]::new($false))
    $collisionBefore = [IO.File]::ReadAllBytes($collisionPath)
    $artifactLease = New-NativeArtifactLease $fixture
    Assert-NativeThrows { New-RecoveryArtifactQuarantineSibling -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -QuarantineNonce $nonce } 'generated quarantine CreateNew collision'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($collisionPath)) -ceq [Convert]::ToBase64String($collisionBefore)) 'quarantine collision is never opened or overwritten.'
} finally {
    Close-NativeArtifactLease $artifactLease
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

# Rename the retained destination handle away, then create a regular-file substitution at its old name. Name revalidation must detect the identity change before copy or deletion and remove the unverified quarantine sibling.
$fixture = New-NativeArtifactFixture
$artifactLease = $null
$replacementLease = $null
$quarantinePath = $null
try {
    $artifactLease = New-NativeArtifactLease $fixture
    $progressBefore = Get-NativeLeaseBytes $artifactLease.Holder.Lease
    $manifestBackupBefore = [IO.File]::ReadAllBytes($fixture.ManifestBackup)
    $oldBytes = [IO.File]::ReadAllBytes($fixture.Destination)
    $sourceBefore = [IO.File]::ReadAllBytes($fixture.Source)
    $destination = Open-RecoveryArtifactDestination -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantine = New-RecoveryArtifactQuarantineSibling -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0
    $quarantinePath = Join-Path $fixture.Backup $quarantine.Name
    Invoke-NativeArtifactTestRename -SourceHandle $destination.Native.LeafHandle -ParentHandle $destination.Native.Parent.ParentHandle -Name ([IO.Path]::GetFileName($fixture.RenamedDestination))
    $replacementAcl = New-RecoveryProgressAcl -OperatorSid $nativeOperatorSid
    $replacementLease = [LifeOSRecoveryProgressNative]::CreateNew((Get-FullPath $fixture.Destination), $true, $replacementAcl.GetSecurityDescriptorBinaryForm())
    $replacementBytes = [Text.UTF8Encoding]::new($false).GetBytes('replacement-at-old-name')
    $replacementLease.Stream.Write($replacementBytes, 0, $replacementBytes.Length)
    $replacementLease.Stream.Flush($true)
    Assert-NativeThrows { Copy-RecoveryArtifactToQuarantine -Context $artifactLease.Context -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Destination $destination -Quarantine $quarantine } 'replaced destination leaf identity'
    Assert-Native ([Convert]::ToBase64String((Get-NativeArtifactBytes $destination)) -ceq [Convert]::ToBase64String($oldBytes) -and
        [Convert]::ToBase64String((Get-NativeHandleLeaseBytes $replacementLease)) -ceq [Convert]::ToBase64String($replacementBytes)) 'leaf replacement leaves both identities and bytes distinct.'
    Assert-Native ([Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.Source)) -ceq [Convert]::ToBase64String($sourceBefore) -and
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($fixture.ManifestBackup)) -ceq [Convert]::ToBase64String($manifestBackupBefore) -and
        [Convert]::ToBase64String((Get-NativeLeaseBytes $artifactLease.Holder.Lease)) -ceq [Convert]::ToBase64String($progressBefore)) 'leaf replacement rejection preserves source, manifest backup, and progress.'
} finally {
    if ($null -ne $replacementLease) { try { $replacementLease.Dispose() } catch { } }
    Close-NativeArtifactLease $artifactLease
    if ($null -ne $quarantinePath) { Assert-Native (-not [IO.File]::Exists($quarantinePath)) 'leaf replacement leaves no unverified quarantine orphan.' }
    Assert-NativeProgressCanReopen $fixture
    Remove-NativeArtifactFixture $fixture
}

Write-Host 'PASS: native recovery progress and artifact capability assertions'
