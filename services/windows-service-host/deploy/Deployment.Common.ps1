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
$script:LifeOSDeploymentMutexName = 'Global\LifeOSDeploymentTransaction'
$script:LifeOSDeploymentMarkerName = '.lifeos-deployment-transaction.json'
# Recovery roots are a bounded manifest concern; file units are a bounded
# package/data concern.  The 65,536-unit ceiling is finite and leaves room for
# a legitimately expanded artifact tree without accepting an unbounded scan.
$script:LifeOSRecoveryMaxTreeRoots = 256
$script:LifeOSRecoveryMaxFileUnits = 65536
# File count alone is not a sufficient resource bound: a small inventory can
# still force an expensive hash/restore of very large files. Keep the limits
# finite and shared by tree indexing, journal validation, and recovery. The
# machine's Python base runtime can legitimately be larger than 512 MiB on
# Windows because the rollback snapshot preserves the prior interpreter in
# full; this remains a finite, exact per-tree and aggregate inventory bound.
$script:LifeOSRecoveryMaxTreeBytes = 1024 * 1024 * 1024
$script:LifeOSRecoveryMaxFileBytes = 64 * 1024 * 1024
# A standalone Windows node.exe is an explicitly allowlisted candidate file.
# Keep its larger runtime bound separate from the 64 MiB recovery/file bound so
# other candidate files and all recovery artifacts retain the smaller ceiling.
$script:LifeOSCandidateNodeMaxFileBytes = 256 * 1024 * 1024
# The self-contained win-x64 service host is a second explicitly allowlisted
# candidate file. Keep its finite bound separate from both ordinary files and
# the Node runtime so a same-basename file elsewhere cannot opt in.
$script:LifeOSCandidateServiceHostMaxFileBytes = 256 * 1024 * 1024
$script:LifeOSCandidateServiceHostRelativePath = 'service-host/LifeOS.ServiceHost.exe'
$script:LifeOSRecoveryMaxInventoryBytes = 1024 * 1024 * 1024
$script:LifeOSRecoveryMaxPathLength = 4096
$script:LifeOSDeploymentMarkerMaxBytes = 64 * 1024
$script:LifeOSGenerationManifestMaxBytes = 16 * 1024 * 1024
$script:LifeOSRecoveryJournalMaxBytes = 64 * 1024 * 1024
$script:LifeOSRecoveryProgressMaxBytes = 64 * 1024 * 1024
$script:LifeOSRecoveryProgressMaxRecords = $script:LifeOSRecoveryMaxFileUnits * 2
$script:LifeOSRecoveryProgressMaxRecordBytes = 16 * 1024
$script:LifeOSRecoveryProgressMagic = [byte[]]@(0x4c, 0x50, 0x52, 0x47)
$script:LifeOSRecoveryProgressVersion = [byte]1
$script:LifeOSRecoveryProgressCommitMarker = [byte]0xa5
$script:LifeOSRecoveryProgressHeaderBytes = 9
$script:LifeOSRecoveryProgressHeaderDigestBytes = 32
$script:LifeOSRecoveryProgressFrameHeaderBytes = $script:LifeOSRecoveryProgressHeaderBytes + $script:LifeOSRecoveryProgressHeaderDigestBytes
$script:LifeOSRecoveryProgressDigestBytes = 32
$script:LifeOSRecoveryProgressTrailerBytes = 33
$script:LifeOSRecoveryStageNames = [string[]]@(
    'Restore-AclSnapshots',
    'service-LifeOSAPI',
    'service-LifeOSGateway',
    'service-state-reconcile',
    'Restore-TailscaleServeSnapshot',
    'Restore-CodexCollectorTask',
    'Restore-TailscaleSnapshotTask'
)
$script:LifeOSCollectorReceiptMaxBytes = 1 * 1024 * 1024
$script:LifeOSTailscaleSnapshotMaxBytes = 256 * 1024
$script:LifeOSPathOnlyJsonMaxBytes = 1 * 1024 * 1024
$script:LifeOSMaxCappedReadBytes = 256 * 1024 * 1024

function Get-LifeOSNativeFileIdentity {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        throw "$Description file identity cannot be confirmed outside Windows."
    }
    try {
        if ($null -eq ('LifeOSNativeFileIdentity' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

public static class LifeOSNativeFileIdentity
{
    private const uint GenericRead = 0x80000000u;
    private const uint FileReadAttributes = 0x00000080;
    private const uint ReadControl = 0x00020000;
    private const uint WriteDac = 0x00040000;
    private const uint FileShareRead = 0x00000001;
    private const uint FileShareWrite = 0x00000002;
    private const uint FileShareDelete = 0x00000004;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const uint FileFlagOpenReparsePoint = 0x00200000;
    private const uint FileFlagSequentialScan = 0x08000000;
    private const uint DaclSecurityInformation = 0x00000004;
    private const uint ProtectedDaclSecurityInformation = 0x80000000u;
    private const uint UnprotectedDaclSecurityInformation = 0x20000000u;
    private const int SeFileObject = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct ByHandleFileInformation
    {
        public uint FileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
        public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
        public uint VolumeSerialNumber;
        public uint FileSizeHigh;
        public uint FileSizeLow;
        public uint NumberOfLinks;
        public uint FileIndexHigh;
        public uint FileIndexLow;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetFileInformationByHandle(
        SafeFileHandle handle,
        out ByHandleFileInformation information);

    [DllImport("advapi32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSecurityDescriptorDacl(
        IntPtr securityDescriptor,
        [MarshalAs(UnmanagedType.Bool)] out bool daclPresent,
        out IntPtr dacl,
        [MarshalAs(UnmanagedType.Bool)] out bool daclDefaulted);

    [DllImport("advapi32.dll", SetLastError = true)]
    private static extern uint SetSecurityInfo(
        IntPtr handle,
        int objectType,
        uint securityInformation,
        IntPtr owner,
        IntPtr group,
        IntPtr dacl,
        IntPtr sacl);

    private static ByHandleFileInformation ReadInformation(SafeFileHandle handle)
    {
        if (handle == null || handle.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        ByHandleFileInformation information;
        if (!GetFileInformationByHandle(handle, out information))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return information;
    }

    private static SafeFileHandle Open(string path, uint desiredAccess, uint shareMode, uint flags)
    {
        SafeFileHandle handle = CreateFile(
            path, desiredAccess, shareMode, IntPtr.Zero, OpenExisting, flags, IntPtr.Zero);
        if (handle == null || handle.IsInvalid)
        {
            throw new Win32Exception(Marshal.GetLastWin32Error());
        }
        return handle;
    }

    // FILE_FLAG_OPEN_REPARSE_POINT makes the final component itself the
    // object being inspected. The caller rejects its reparse attribute before
    // reading, so a junction/symlink is never silently followed.
    public static SafeFileHandle OpenRead(string path)
    {
        return Open(path, GenericRead, FileShareRead,
            FileFlagOpenReparsePoint | FileFlagSequentialScan);
    }

    // This handle is held while an ACL operation invokes an external Windows
    // tool. It does not make a pathname-based tool handle-bound by itself; the
    // caller also revalidates this object and every ancestor immediately before
    // and after the mutation and fails closed on any observed change.
    public static SafeFileHandle OpenForAcl(string path, bool directory)
    {
        uint flags = FileFlagOpenReparsePoint | (directory ? FileFlagBackupSemantics : 0u);
        return Open(path, ReadControl | WriteDac | FileReadAttributes,
            FileShareRead | FileShareWrite | FileShareDelete, flags);
    }

    public static string Get(SafeFileHandle handle)
    {
        ByHandleFileInformation information = ReadInformation(handle);
        return string.Format(
            "{0:X8}:{1:X8}{2:X8}",
            information.VolumeSerialNumber,
            information.FileIndexHigh,
            information.FileIndexLow);
    }

    public static uint GetAttributes(SafeFileHandle handle)
    {
        return ReadInformation(handle).FileAttributes;
    }

    // Apply a managed FileSecurity/DirectorySecurity descriptor through the
    // already-open handle. This avoids making Set-Acl reopen a mutable path.
    public static void SetDacl(SafeFileHandle handle, byte[] descriptor, bool protectDacl)
    {
        if (descriptor == null || descriptor.Length == 0)
        {
            throw new ArgumentException("Security descriptor is empty.", "descriptor");
        }
        GCHandle pinned = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
        try
        {
            bool present;
            bool defaulted;
            IntPtr dacl = IntPtr.Zero;
            if (!GetSecurityDescriptorDacl(
                pinned.AddrOfPinnedObject(), out present, out dacl, out defaulted))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            // A descriptor without a DACL and a descriptor with a present
            // NULL DACL are distinct Win32 states. SetSecurityInfo expects a
            // null pointer for both, but only the former requires us to
            // discard the output pointer; a present NULL DACL must remain
            // NULL so the descriptor's unrestricted semantics are preserved.
            if (!present) { dacl = IntPtr.Zero; }
            uint securityInformation = DaclSecurityInformation |
                (protectDacl ? ProtectedDaclSecurityInformation : UnprotectedDaclSecurityInformation);
            uint result = SetSecurityInfo(
                handle.DangerousGetHandle(), SeFileObject, securityInformation,
                IntPtr.Zero, IntPtr.Zero, dacl, IntPtr.Zero);
            if (result != 0) { throw new Win32Exception((int)result); }
        }
        finally
        {
            pinned.Free();
        }
    }

    public static string Get(string path)
    {
        using (SafeFileHandle handle = CreateFile(
            path,
            FileReadAttributes,
            FileShareRead | FileShareWrite | FileShareDelete,
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint,
            IntPtr.Zero))
        {
            if (handle == null || handle.IsInvalid)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            ByHandleFileInformation information;
            if (!GetFileInformationByHandle(handle, out information))
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }
            return string.Format(
                "{0:X8}:{1:X8}{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow);
        }
    }
}
'@ -ErrorAction Stop | Out-Null
        }
        $identity = [LifeOSNativeFileIdentity]::Get((Get-FullPath $Path))
        if ([string]::IsNullOrWhiteSpace([string]$identity)) { throw 'native identity was empty' }
        return [string]$identity
    } catch {
        throw "$Description file identity could not be confirmed."
    }
}

function Get-LifeOSFileReadSignature {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    $chain = @(Get-LifeOSPathIdentityChain -Path $Path -Description $Description)
    if ($chain.Count -le 0) { throw "$Description has no readable path identity." }
    $leaf = $chain[$chain.Count - 1]
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($item.PSIsContainer) { throw "$Description is a directory." }
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point."
    }
    if ($null -eq $item.PSObject.Properties['Length'] -or
        $null -eq $item.PSObject.Properties['LastWriteTimeUtc'] -or
        $null -eq $item.PSObject.Properties['CreationTimeUtc']) {
        throw "$Description did not expose a complete file identity."
    }
    return [pscustomobject]@{
        FullName = [string]$leaf.Path
        FileId = [string]$leaf.FileId
        Length = [long]$item.Length
        LastWriteTimeUtc = [DateTime]$item.LastWriteTimeUtc
        CreationTimeUtc = [DateTime]$item.CreationTimeUtc
        Attributes = [int]$item.Attributes
    }
}

function Assert-LifeOSFileReadSignature {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][psobject]$Expected,
        [Parameter(Mandatory)][string]$Description
    )
    $actual = Get-LifeOSFileReadSignature -Path $Path -Description $Description
    if ([string]$actual.FullName -ine [string]$Expected.FullName -or
        [string]$actual.FileId -cne [string]$Expected.FileId -or
        [long]$actual.Length -ne [long]$Expected.Length -or
        [DateTime]$actual.LastWriteTimeUtc -ne [DateTime]$Expected.LastWriteTimeUtc -or
        [DateTime]$actual.CreationTimeUtc -ne [DateTime]$Expected.CreationTimeUtc -or
        [int]$actual.Attributes -ne [int]$Expected.Attributes) {
        throw "$Description changed while it was being read or validated."
    }
    return $actual
}

function Read-LifeOSCappedFileBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][string]$Description
    )
    if ($MaxBytes -le 0 -or $MaxBytes -gt $script:LifeOSMaxCappedReadBytes) {
        throw "$Description has an invalid bounded read size."
    }
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $beforeChain = $null
        $beforeLeaf = $null
        $handle = $null
        $stream = $null
        $retry = $false
        try {
            Assert-ExistingFile $Path $Description
            $beforeChain = @(Get-LifeOSPathIdentityChain -Path $Path -Description $Description)
            if ($beforeChain.Count -le 0) { throw "$Description has no readable path identity." }
            $beforeLeaf = $beforeChain[$beforeChain.Count - 1]
            $handle = [LifeOSNativeFileIdentity]::OpenRead((Get-FullPath $Path))
            $attributes = [LifeOSNativeFileIdentity]::GetAttributes($handle)
            if (($attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                $handle.Dispose()
                $handle = $null
                throw "$Description is a reparse point."
            }
            if ([string][LifeOSNativeFileIdentity]::Get($handle) -cne [string]$beforeLeaf.FileId) {
                $handle.Dispose()
                $handle = $null
                throw "$Description changed while it was being opened."
            }
            # The FileStream is created from the already-validated SafeFileHandle;
            # it owns that handle and is the only source of bytes below. The
            # native open uses FILE_SHARE_READ, blocking ordinary writer, delete,
            # and replace operations until the read has finished.
            $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read, 65536, $false)
            $openedLength = [long]$stream.Length
            if ($openedLength -gt $MaxBytes) { throw "$Description exceeds its bounded read size." }
            $buffer = New-Object byte[] ([int]$MaxBytes + 1)
            [int]$offset = 0
            while ($offset -lt $buffer.Length) {
                $read = $stream.Read($buffer, $offset, $buffer.Length - $offset)
                if ($read -le 0) { break }
                $offset += $read
            }
            if ($offset -gt [int]$MaxBytes -or $offset -ne [int]$openedLength) {
                throw "$Description grew or changed while it was being read."
            }
            if ([long]$stream.Length -ne $openedLength -or $stream.Position -ne $openedLength) {
                throw "$Description was truncated while it was being read."
            }
            if ([string][LifeOSNativeFileIdentity]::Get($stream.SafeFileHandle) -cne [string]$beforeLeaf.FileId) {
                throw "$Description identity changed while it was being read."
            }
            Assert-LifeOSPathIdentityChain -Expected $beforeChain -Description $Description | Out-Null
            $result = New-Object byte[] $offset
            if ($offset -gt 0) { [Array]::Copy($buffer, $result, $offset) }
            return ,$result
        } catch {
            $message = [string]$_.Exception.Message
            if ($attempt -lt 2 -and $message -like '*ancestor identity changed.') {
                $retry = $true
            } else {
                throw "$Description could not be read as a stable bounded file: $message"
            }
        } finally {
            if ($null -ne $stream) { $stream.Dispose() }
            elseif ($null -ne $handle) { $handle.Dispose() }
        }
        if ($retry) { Start-Sleep -Milliseconds 50 }
    }
}

function Read-LifeOSCappedFileText {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][string]$Description
    )
    $bytes = Read-LifeOSCappedFileBytes -Path $Path -MaxBytes $MaxBytes -Description $Description
    try {
        return ,([Text.UTF8Encoding]::new($false, $true).GetString($bytes))
    } catch {
        throw "$Description is not valid UTF-8 text."
    }
}

function Read-LifeOSPrefixBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$Count,
        [Parameter(Mandatory)][string]$Description
    )
    if ($Count -le 0 -or $Count -gt 4096) { throw "$Description has an invalid prefix size." }
    Assert-ExistingFile $Path $Description
    $beforeChain = @(Get-LifeOSPathIdentityChain -Path $Path -Description $Description)
    $beforeLeaf = $beforeChain[$beforeChain.Count - 1]
    $handle = $null
    $stream = $null
    try {
        $handle = [LifeOSNativeFileIdentity]::OpenRead((Get-FullPath $Path))
        $attributes = [LifeOSNativeFileIdentity]::GetAttributes($handle)
        if (($attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -or
            [string][LifeOSNativeFileIdentity]::Get($handle) -cne [string]$beforeLeaf.FileId) {
            throw "$Description changed while it was being opened."
        }
        $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read, $Count, $false)
        $buffer = New-Object byte[] $Count
        $read = $stream.Read($buffer, 0, $Count)
        if ([string][LifeOSNativeFileIdentity]::Get($stream.SafeFileHandle) -cne [string]$beforeLeaf.FileId) {
            throw "$Description identity changed while it was being read."
        }
        Assert-LifeOSPathIdentityChain -Expected $beforeChain -Description $Description | Out-Null
        $result = New-Object byte[] $read
        if ($read -gt 0) { [Array]::Copy($buffer, $result, $read) }
        return ,$result
    } catch {
        throw "$Description could not be read as a stable prefix: $($_.Exception.Message)"
    } finally {
        if ($null -ne $stream) { $stream.Dispose() }
        elseif ($null -ne $handle) { $handle.Dispose() }
    }
}

function Read-LifeOSBoundedJsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][string]$Description
    )
    if ($MaxBytes -le 0) { throw 'JSON reader byte bound is invalid.' }
    $raw = Read-LifeOSCappedFileText -Path $Path -MaxBytes $MaxBytes -Description $Description
    return ($raw | ConvertFrom-Json -ErrorAction Stop)
}

function New-LifeOSTreeItemIdentity {
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$Description)
    if ($null -eq $Item -or $null -eq $Item.PSObject.Properties['FullName'] -or
        $null -eq $Item.PSObject.Properties['PSIsContainer'] -or
        $null -eq $Item.PSObject.Properties['Attributes'] -or
        $null -eq $Item.PSObject.Properties['LastWriteTimeUtc'] -or
        $null -eq $Item.PSObject.Properties['CreationTimeUtc']) {
        throw "$Description did not expose a complete tree-item identity."
    }
    if (($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point."
    }
    return [pscustomobject]@{
        FullName = Get-FullPath ([string]$Item.FullName)
        FileId = Get-LifeOSNativeFileIdentity -Path ([string]$Item.FullName) -Description $Description
        IsContainer = [bool]$Item.PSIsContainer
        Attributes = [int]$Item.Attributes
        LastWriteTimeUtc = [DateTime]$Item.LastWriteTimeUtc
        CreationTimeUtc = [DateTime]$Item.CreationTimeUtc
        Length = if ($Item.PSIsContainer) { [long]0 } else { [long]$Item.Length }
    }
}

function Assert-LifeOSTreeItemIdentity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Expected,
        [Parameter(Mandatory)][string]$Description
    )
    Assert-NoReparsePath $Path
    $current = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $actual = New-LifeOSTreeItemIdentity -Item $current -Description $Description
    if ([string]$actual.FullName -ine [string]$Expected.FullName -or
        [string]$actual.FileId -cne [string]$Expected.FileId -or
        [bool]$actual.IsContainer -ne [bool]$Expected.IsContainer -or
        [int]$actual.Attributes -ne [int]$Expected.Attributes -or
        [DateTime]$actual.LastWriteTimeUtc -ne [DateTime]$Expected.LastWriteTimeUtc -or
        [DateTime]$actual.CreationTimeUtc -ne [DateTime]$Expected.CreationTimeUtc -or
        [long]$actual.Length -ne [long]$Expected.Length) {
        throw "$Description changed while it was being inventoried."
    }
    return $current
}

function Get-LifeOSDeploymentMarkerPath {
    return (Join-Path $script:LifeOSDefaultPaths.BackupRoot $script:LifeOSDeploymentMarkerName)
}

function Enter-LifeOSDeploymentTransaction {
    param([switch]$AllowRecovery, [object]$RecoveryManifest, [string]$RecoveryManifestPath)
    # Every installer mutation, including rollback, must be serialized. A
    # named OS mutex is released by Windows if an operator shell dies. The
    # companion marker makes an abandoned owner fail closed on the next
    # install; only an explicit rollback may classify and clear that state.
    # Wait(0) deliberately fails fast: a second installer must not inspect or
    # mutate trees while the first transaction is hashing, staging, or
    # restoring them.
    $mutex = [Threading.Mutex]::new($false, $script:LifeOSDeploymentMutexName)
    $ownsMutex = $false
    $marker = $null
    $previousMarkerState = ''
    $previousManifestPath = ''
    $previousGeneration = ''
    $markerPath = Get-LifeOSDeploymentMarkerPath
    try {
        try {
            $ownsMutex = $mutex.WaitOne(0)
        } catch [Threading.AbandonedMutexException] {
            # The previous owner exited without releasing the mutex. The
            # runtime grants ownership to this waiter, but a new install must
            # still stop here until an explicit rollback classifies recovery.
            $ownsMutex = $true
            if (-not $AllowRecovery) {
                throw 'A previous LifeOS deployment transaction was abandoned; explicit rollback/recovery is required before install.'
            }
        }
        if (-not $ownsMutex) {
            throw 'Another LifeOS deployment transaction is already active; refusing concurrent install or rollback.'
        }
        if ((Test-Path -LiteralPath $markerPath) -and -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) { throw 'Deployment marker is not a regular file.' }
        if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
            Assert-NoReparsePath $markerPath
            Assert-RestrictedAcl $markerPath (Get-InteractiveOperatorSid) @() @() -AllowInherited
            $marker = Read-LifeOSBoundedJsonFile -Path $markerPath -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes -Description 'Deployment marker'
            if ([string]$marker.state -notin @('active', 'recovery_required', 'installed', 'recovered') -or
                [string]$marker.transactionId -notmatch '^[0-9a-f-]{36}$') {
                throw 'The LifeOS deployment marker is invalid; operator-led recovery is required.'
            }
            if (-not $AllowRecovery -and [string]$marker.state -in @('active', 'recovery_required')) {
                throw 'A previous LifeOS deployment did not report a clean terminal state; explicit rollback/recovery is required before install.'
            }
            if ([string]$marker.state -eq 'recovered' -and $null -ne $marker.PSObject.Properties['recoveryArchivePath']) {
                $archivePath = Get-FullPath ([string]$marker.recoveryArchivePath)
                $manifestDirectory = (Get-FullPath (Split-Path -Parent ([string]$marker.manifestPath))).TrimEnd('\')
                if (-not $archivePath.StartsWith($manifestDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'Recovered deployment archive is outside its transaction directory.'
                }
                Assert-ExistingFile $archivePath 'Completed recovery archive'
                Assert-RestrictedAcl $archivePath ([string]$marker.operatorSid) @() @() -AllowInherited
                $archive = Read-LifeOSBoundedJsonFile -Path $archivePath -MaxBytes $script:LifeOSRecoveryJournalMaxBytes -Description 'Completed recovery archive'
                if ([string](Get-JournalProperty $archive 'transactionId') -cne [string]$marker.transactionId -or
                    [string](Get-JournalProperty $archive 'phase') -cne 'completed') {
                    throw 'Recovered deployment archive is not marker-bound.'
                }
            }
            $previousMarkerState = [string]$marker.state
            if ($null -ne $marker.PSObject.Properties['manifestPath']) { $previousManifestPath = [string]$marker.manifestPath }
            if ($null -ne $marker.PSObject.Properties['generation']) { $previousGeneration = [string]$marker.generation }
        }
        $transactionId = [Guid]::NewGuid().ToString()
        if ($AllowRecovery) {
            if ($null -eq $RecoveryManifest -or -not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
                throw 'Recovery requires the transaction-owned marker and manifest.'
            }
            Assert-RecoveryIdentity $marker $RecoveryManifest $RecoveryManifestPath
            $transactionId = [string]$marker.transactionId
            # Preserve the recovered transaction's identity while marking the
            # recovery live. A killed rollback must block a subsequent install.
            Set-JournalProperty $marker 'state' 'active'
            Set-JournalProperty $marker 'updatedAtUtc' ((Get-Date).ToUniversalTime().ToString('o'))
            [void](Assert-LifeOSDeploymentMarkerCheckpointCapacity $marker)
            Write-JsonAtomic $markerPath $marker -OperatorSid $marker.operatorSid -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes
        }
        # Acquire serialization without publishing a lock that has no journal.
        # Install binds the marker only after its first usable manifest exists.
        return [pscustomobject]@{ Mutex = $mutex; MarkerPath = $markerPath; TransactionId = $transactionId; Recovery = [bool]$AllowRecovery; PreviousState = $previousMarkerState; PreviousManifestPath = $previousManifestPath; PreviousGeneration = $previousGeneration }

    } catch {
        if ($ownsMutex) {
            try { $mutex.ReleaseMutex() } catch [ApplicationException] { }
        }
        $mutex.Dispose()
        throw
    }
}

function Exit-LifeOSDeploymentTransaction {
    param([AllowNull()][object]$Transaction, [switch]$Completed)
    if ($null -eq $Transaction) { return }
    $mutex = $Transaction.Mutex
    try {
        if ($Completed -and (Test-Path -LiteralPath $Transaction.MarkerPath -PathType Leaf)) {
            Assert-NoReparsePath $Transaction.MarkerPath
            $marker = Read-LifeOSBoundedJsonFile -Path $Transaction.MarkerPath -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes -Description 'Deployment marker'
            if ([string]$marker.transactionId -eq [string]$Transaction.TransactionId) {
                if ($Transaction.Recovery) {
                    Assert-ExistingFile ([string]$marker.manifestPath) 'Recovery manifest'
                    $recoveryManifest = Read-LifeOSBoundedJsonFile -Path ([string]$marker.manifestPath) -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Recovery manifest'
                    $archivePath = Complete-LifeOSRecoveryState $recoveryManifest
                    Set-JournalProperty $marker 'recoveryArchivePath' $archivePath
                    Set-JournalProperty $marker 'recoveryFinalizedAtUtc' ((Get-Date).ToUniversalTime().ToString('o'))
                }
                $terminalState = if ($Transaction.Recovery) { 'recovered' } else { 'installed' }
                if ([string]$marker.state -ne $terminalState) {
                    Set-JournalProperty $marker 'state' $terminalState
                    Set-JournalProperty $marker 'updatedAtUtc' ((Get-Date).ToUniversalTime().ToString('o'))
                    [void](Assert-LifeOSDeploymentMarkerCheckpointCapacity $marker)
                    Write-JsonAtomic $Transaction.MarkerPath $marker -OperatorSid $marker.operatorSid -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes
                }
            }
        } elseif (Test-Path -LiteralPath $Transaction.MarkerPath -PathType Leaf) {
            # Keep an explicit recovery marker when the outer transaction did
            # not reach a verified terminal state. A later install then fails
            # closed until rollback has been run deliberately.
            try {
                Assert-NoReparsePath $Transaction.MarkerPath
                $marker = Read-LifeOSBoundedJsonFile -Path $Transaction.MarkerPath -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes -Description 'Deployment marker'
                if ([string]$marker.transactionId -eq [string]$Transaction.TransactionId) {
                    if ([string]$marker.state -ne 'recovery_required') {
                        $marker.state = 'recovery_required'
                        Set-JournalProperty $marker 'updatedAtUtc' ((Get-Date).ToUniversalTime().ToString('o'))
                        [void](Assert-LifeOSDeploymentMarkerCheckpointCapacity $marker)
                        Write-JsonAtomic $Transaction.MarkerPath $marker -OperatorSid $marker.operatorSid -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes
                    }
                }
            } catch { Write-Warning ('Could not persist recovery diagnostics: ' + $_.Exception.Message) }
        }
    } finally {
        # Terminal checkpoint failures must not strand the process-owned mutex.
        # The marker/journal remain fail-closed for the next invocation, while
        # that invocation can still acquire the mutex to perform recovery.
        try { $mutex.ReleaseMutex() } catch [ApplicationException] { }
        $mutex.Dispose()
    }
}

function Set-JournalProperty {
    param($Object, [string]$Name, $Value)
    if ($Object -is [System.Collections.IDictionary]) { $Object[$Name] = $Value }
    else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Get-JournalProperty {
    param($Object, [string]$Name)
    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) { return $Object[$Name] }
    } elseif ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Get-LifeOSJsonSerializedByteCount {
    param([Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 20
    return [long][Text.UTF8Encoding]::new($false).GetByteCount([string]$json)
}

function Copy-LifeOSJsonValue {
    param([Parameter(Mandatory)][object]$Value)
    $json = $Value | ConvertTo-Json -Depth 20 -Compress
    return ($json | ConvertFrom-Json -ErrorAction Stop)
}

function New-LifeOSGenerationManifestCandidate {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [AllowNull()][object]$BackupItem = $null,
        [AllowNull()][object]$AclSnapshot = $null,
        [AllowNull()][System.Collections.IDictionary]$Properties = $null
    )
    $candidate = Copy-LifeOSJsonValue $Manifest
    if ($null -ne $Properties) {
        foreach ($name in $Properties.Keys) { Set-JournalProperty $candidate ([string]$name) $Properties[$name] }
    }
    if ($null -ne $BackupItem) {
        $backups = @()
        $existingBackups = Get-JournalProperty $candidate 'backups'
        if ($null -ne $existingBackups) { $backups = @($existingBackups) }
        $backups += Copy-LifeOSJsonValue $BackupItem
        Set-JournalProperty $candidate 'backups' $backups
    }
    if ($null -ne $AclSnapshot) {
        $aclSnapshots = @()
        $existingSnapshots = Get-JournalProperty $candidate 'aclSnapshots'
        if ($null -ne $existingSnapshots) { $aclSnapshots = @($existingSnapshots) }
        $aclSnapshots += Copy-LifeOSJsonValue $AclSnapshot
        Set-JournalProperty $candidate 'aclSnapshots' $aclSnapshots
    }
    return $candidate
}

function Assert-LifeOSGenerationManifestPropertiesCapacity {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Properties
    )
    $candidate = New-LifeOSGenerationManifestCandidate -Manifest $Manifest -Properties $Properties
    [void](Assert-LifeOSGenerationManifestCheckpointCapacity -Manifest $candidate)
}

function Assert-LifeOSDeploymentMarkerCheckpointCapacity {
    param([Parameter(Mandatory)][object]$Marker)
    $maximumBytes = [long]0
    # The marker changes state and timestamp at recovery, terminal install,
    # and terminal rollback. Measure every state through the same serializer
    # used by Write-JsonAtomic before publishing the first marker.
    foreach ($state in @('active', 'recovery_required', 'installed', 'recovered')) {
        $candidate = ($Marker | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json -ErrorAction Stop
        Set-JournalProperty $candidate 'state' $state
        Set-JournalProperty $candidate 'updatedAtUtc' ((Get-Date).ToUniversalTime().ToString('o'))
        $candidateBytes = Get-LifeOSJsonSerializedByteCount $candidate
        if ($candidateBytes -gt $maximumBytes) { $maximumBytes = $candidateBytes }
    }
    if ($maximumBytes -gt $script:LifeOSDeploymentMarkerMaxBytes) {
        throw 'Deployment marker future checkpoint exceeds its bounded serialized size.'
    }
}

function Assert-LifeOSGenerationManifestCheckpointCapacity {
    param(
        [Parameter(Mandatory)][object]$Manifest,
        [AllowNull()][object[]]$FutureCheckpoints = @()
    )
    $candidates = @($Manifest)
    if ($null -ne $FutureCheckpoints) { $candidates += @($FutureCheckpoints) }
    foreach ($candidate in $candidates) {
        if ($null -eq $candidate) { throw 'Generation manifest checkpoint candidate is missing.' }
        $candidateBytes = Get-LifeOSJsonSerializedByteCount $candidate
        if ($candidateBytes -gt $script:LifeOSGenerationManifestMaxBytes) {
            throw 'Generation manifest checkpoint exceeds its bounded serialized size.'
        }
    }
}

function Assert-RecoveryIdentity {
    param($Marker, $Manifest, [string]$ManifestPath)
    foreach ($name in @('transactionId', 'generation', 'operatorSid', 'manifestPath')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-JournalProperty $Manifest $name)) -or
            [string](Get-JournalProperty $Manifest $name) -cne [string](Get-JournalProperty $Marker $name)) { throw 'Recovery manifest belongs to an unrelated transaction or generation.' }
    }
    if ([string]$Marker.state -eq 'recovered' -or [string]$Manifest.manifestPath -ne (Get-FullPath $ManifestPath) -or
        [string]$Manifest.operatorSid -ne (Get-InteractiveOperatorSid)) { throw 'Recovery manifest ownership is invalid or already recovered.' }
}

function Bind-LifeOSDeploymentManifest {
    param($Transaction, $Manifest, [string]$ManifestPath)
    $marker = [ordered]@{
        schemaVersion = 2; state = 'active'; transactionId = $Transaction.TransactionId
        generation = $Manifest.generation; operatorSid = $Manifest.operatorSid
        manifestPath = (Get-FullPath $ManifestPath)
        acquiredAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    }
    [void](Assert-LifeOSDeploymentMarkerCheckpointCapacity $marker)
    Write-JsonAtomic $Transaction.MarkerPath $marker -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes
}

function Get-LocalApiBearerHeaders {
    param([string]$SecretFile = (Join-Path $script:LifeOSDefaultPaths.SecretRoot 'local-api.secret'))
    $bytes = Read-LifeOSCappedFileBytes -Path $SecretFile -MaxBytes 256 -Description 'Local API credential'
    if ($bytes.Length -lt 32 -or $bytes.Length -gt 256 -or
        @($bytes | Where-Object { $_ -lt 33 -or $_ -gt 126 }).Count -gt 0) {
        throw 'Local API credential is malformed.'
    }
    return @{ Authorization = 'Bearer ' + [Text.Encoding]::ASCII.GetString($bytes) }
}

function Get-AuthorityInstallMode {
    param(
        [string[]]$Installed,
        [string[]]$Legacy,
        [string[]]$Expected,
        [bool]$Versioned,
        [bool]$CodePresent,
        [string[]]$SupportedEvolution = @('enablebanking-partial.json', 'enablebanking-runtime.json', 'finance-imported.json')
    )
    $installedValues = @()
    $legacyValues = @()
    $expectedValues = @()
    $supportedValues = @()
    if ($null -ne $Installed) { $installedValues = @($Installed) }
    if ($null -ne $Legacy) { $legacyValues = @($Legacy) }
    if ($null -ne $Expected) { $expectedValues = @($Expected) }
    if ($null -ne $SupportedEvolution) { $supportedValues = @($SupportedEvolution) }
    if ($installedValues.Count -gt 256 -or $legacyValues.Count -gt 256 -or $expectedValues.Count -gt 256 -or $supportedValues.Count -gt 3) {
        throw 'Authority inventory is too large; recovery required.'
    }
    $recognizedEvolution = @('enablebanking-partial.json', 'enablebanking-runtime.json', 'finance-imported.json')
    $supportedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $supportedValues) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or $name -notin $recognizedEvolution) {
            throw 'Authority evolution policy contains an unsupported sidecar.'
        }
        [void]$supportedSet.Add([string]$name)
    }
    $installedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $expectedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $expectedValues) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or -not $expectedSet.Add([string]$name)) {
            throw 'Expected authority inventory is duplicated or malformed; recovery required.'
        }
    }
    foreach ($name in $installedValues) {
        if ([string]::IsNullOrWhiteSpace([string]$name) -or -not $installedSet.Add([string]$name)) {
            throw 'Installed authority inventory is duplicated or malformed; recovery required.'
        }
        if (-not $expectedSet.Contains([string]$name) -and -not $supportedSet.Contains([string]$name)) {
            throw ('Unclassified installed authority evolution; recovery required: ' + [string]$name)
        }
        if ($supportedSet.Contains([string]$name)) { [void]$expectedSet.Add([string]$name) }
    }
    foreach ($name in $legacyValues) {
        if ([string]::IsNullOrWhiteSpace([string]$name)) { throw 'Legacy authority inventory is malformed; recovery required.' }
    }
    foreach ($names in @($installedValues, $legacyValues)) {
        $nameSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($name in $names) {
            if (-not $nameSet.Add([string]$name)) { throw 'Authority inventory is duplicated; recovery required.' }
        }
        foreach ($name in $names) {
            if ($name -match '^(.+\.json)\.(state|meta|retry)\.json$' -and -not $nameSet.Contains($Matches[1])) {
                throw 'Orphan authority companion; recovery required.'
            }
        }
    }
    if (-not $Versioned -and $CodePresent) { throw 'Installed code has no versioned authority provenance; recovery required.' }
    if ($installedValues.Count -eq 0) {
        if ($Versioned -and $expectedValues.Count -gt 0) { throw 'Partial installed authority set; recovery required.' }
        if ($Versioned) { return $(if ($CodePresent) { 'upgrade' } else { 'repair' }) }
        if ($legacyValues.Count -gt 0) { return 'legacy' }
        return 'fresh'
    }
    if (-not $Versioned -or $expectedSet.Count -eq 0 -or $installedSet.Count -ne $expectedSet.Count) {
        throw 'Partial or unclassified installed authority set; recovery required.'
    }
    foreach ($name in $expectedSet) {
        if (-not $installedSet.Contains([string]$name)) {
            throw 'Partial or unclassified installed authority set; recovery required.'
        }
    }
    if (-not $CodePresent) { return 'repair' }
    return 'upgrade'
}

function Test-AuthorityRecoveryBaseline {
    param([AllowNull()][object]$AuthorityRecord)
    if ($null -eq $AuthorityRecord) { return $false }
    $beforeTreeProperty = $AuthorityRecord.PSObject.Properties['beforeTree']
    $afterTreeProperty = $AuthorityRecord.PSObject.Properties['afterTree']
    if ($null -eq $beforeTreeProperty -or $null -eq $afterTreeProperty) { return $false }
    $beforeTree = $beforeTreeProperty.Value
    $afterTree = $afterTreeProperty.Value
    return [string](Get-JournalProperty $AuthorityRecord 'phase') -ceq 'complete' -and
        $beforeTree -is [System.Collections.IEnumerable] -and $beforeTree -isnot [string] -and
        $afterTree -is [System.Collections.IEnumerable] -and $afterTree -isnot [string]
}

function Assert-LifeOSGenerationReference {
    param([AllowNull()][object]$Reference)
    if ($null -eq $Reference) { throw 'Prior installed generation reference is missing.' }
    $expectedFields = @('manifestPath', 'generation', 'manifestSha256')
    $actualFields = @(
        if ($Reference -is [System.Collections.IDictionary]) {
            foreach ($key in $Reference.Keys) { [string]$key }
        } else {
            foreach ($property in $Reference.PSObject.Properties) { [string]$property.Name }
        }
    )
    $fieldSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($field in $actualFields) {
        if (-not $fieldSet.Add($field)) { throw 'Prior installed generation reference contains duplicate fields.' }
    }
    if ($fieldSet.Count -ne $expectedFields.Count) { throw 'Prior installed generation reference schema is invalid.' }
    foreach ($field in $expectedFields) {
        if (-not $fieldSet.Contains($field)) { throw 'Prior installed generation reference schema is incomplete.' }
    }
    $manifestPath = Get-JournalProperty $Reference 'manifestPath'
    $generation = Get-JournalProperty $Reference 'generation'
    $manifestSha256 = Get-JournalProperty $Reference 'manifestSha256'
    if ($manifestPath -isnot [string] -or [string]::IsNullOrWhiteSpace($manifestPath) -or $manifestPath.Length -gt 4096 -or
        $generation -isnot [string] -or $generation -notmatch '^[0-9a-f-]{36}$' -or
        $manifestSha256 -isnot [string] -or $manifestSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Prior installed generation reference values are malformed.'
    }
}

function New-LifeOSGenerationReference {
    param([Parameter(Mandatory)][psobject]$Manifest, [Parameter(Mandatory)][string]$ManifestPath)
    $reference = [ordered]@{
        manifestPath = Get-FullPath $ManifestPath
        generation = [string](Get-JournalProperty $Manifest 'generation')
        manifestSha256 = Get-FileSha256 $ManifestPath
    }
    Assert-LifeOSGenerationReference $reference
    return ,$reference
}

function Resolve-LifeOSGenerationReference {
    param([Parameter(Mandatory)][object]$Reference, [Parameter(Mandatory)][string]$OperatorSid)
    Assert-LifeOSGenerationReference $Reference
    $manifestPath = Get-FullPath ([string](Get-JournalProperty $Reference 'manifestPath'))
    Assert-ExistingFile $manifestPath 'Prior installed generation manifest'
    $manifest = Read-LifeOSBoundedJsonFile -Path $manifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Prior installed generation manifest'
    Assert-CanonicalRollbackManifest $manifest $manifestPath
    if ([string]$manifest.operatorSid -cne $OperatorSid -or
        [string]$manifest.manifestPath -cne $manifestPath -or
        [string]$manifest.generation -cne [string](Get-JournalProperty $Reference 'generation') -or
        (Get-FileSha256 $manifestPath) -cne [string](Get-JournalProperty $Reference 'manifestSha256')) {
        throw 'Prior installed generation reference authentication failed.'
    }
    return [pscustomobject]@{ Manifest = $manifest; Reference = $Reference }
}

function Get-LifeOSPreviousInstalledGeneration {
    param([Parameter(Mandatory=$false)][AllowNull()][AllowEmptyString()][string]$MarkerState = '', [string]$ManifestPath, [Parameter(Mandatory)][string]$OperatorSid, [string]$ExpectedGeneration = '')
    if ([string]::IsNullOrEmpty($MarkerState)) { return $null }
    if ($MarkerState -notin @('installed', 'recovered')) { throw 'Deployment marker state is invalid.' }
    if ([string]::IsNullOrWhiteSpace($ManifestPath)) { throw 'Terminal deployment marker has no manifest reference.' }
    if ([string]::IsNullOrWhiteSpace($ExpectedGeneration) -or $ExpectedGeneration -notmatch '^[0-9a-f-]{36}$') { throw 'Terminal deployment marker has no valid generation reference.' }
    $path = Get-FullPath $ManifestPath
    Assert-ExistingFile $path 'Previous deployment manifest'
    $manifest = Read-LifeOSBoundedJsonFile -Path $path -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Previous deployment manifest'
    Assert-CanonicalRollbackManifest $manifest $path -AllowPending:($MarkerState -eq 'recovered')
    if ([string]$manifest.generation -cne $ExpectedGeneration) { throw 'Previous deployment manifest generation is not marker-bound.' }
    if ([string]$manifest.operatorSid -cne $OperatorSid -or [string]$manifest.manifestPath -cne $path) {
        throw 'Previous deployment manifest identity is invalid.'
    }
    if ($MarkerState -eq 'installed') {
        return [pscustomobject]@{ Manifest = $manifest; InstalledManifest = $manifest; Reference = (New-LifeOSGenerationReference $manifest $path) }
    }
    $referenceProperty = $manifest.PSObject.Properties['priorInstalledGeneration']
    if ($null -eq $referenceProperty) {
        return [pscustomobject]@{ Manifest = $manifest; InstalledManifest = $null; Reference = $null }
    }
    $resolved = Resolve-LifeOSGenerationReference $referenceProperty.Value $OperatorSid
    return [pscustomobject]@{ Manifest = $manifest; InstalledManifest = $resolved.Manifest; Reference = $resolved.Reference }
}

function Get-TaskRecoveryIdentity {
    param([string]$Xml, [string]$TaskPath)
    $document = New-Object System.Xml.XmlDocument
    $document.LoadXml($Xml)
    $ns = New-Object System.Xml.XmlNamespaceManager($document.NameTable)
    $ns.AddNamespace('task', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
    $principals = @($document.SelectNodes('/task:Task/task:Principals/task:Principal', $ns))
    if ($principals.Count -ne 1) { throw 'Task principal is ambiguous.' }
    $principal = $principals[0]
    $values = @{}
    foreach ($name in @('UserId', 'GroupId', 'LogonType', 'RunLevel')) {
        $node = $principal.SelectSingleNode('task:' + $name, $ns)
        $values[$name] = if ($null -eq $node) { '' } else { [string]$node.InnerText }
    }
    if ($values.UserId -and $values.UserId -notmatch '^S-1-') {
        $values.UserId = ([Security.Principal.NTAccount]::new($values.UserId)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    if ($values.UserId -eq 'S-1-5-18' -and -not $values.LogonType) { $values.LogonType = 'ServiceAccount' }
    $material = (@($TaskPath, (Get-LegacyTaskActionFingerprint $Xml), $values.UserId, $values.GroupId, $values.LogonType, $values.RunLevel) -join "`n").ToLowerInvariant()
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Save-TaskRegistrationIntent {
    param([string]$TaskName, [string]$Xml)
    $context = $script:LifeOSAclSnapshotContext
    $record = @($context.Manifest.codexTask, $context.Manifest.snapshotTask) | Where-Object { $_.Name -eq $TaskName }
    if (@($record).Count -ne 1) { throw 'Task registration is not transaction owned.' }
    Set-JournalProperty $record 'installedIdentity' (Get-TaskRecoveryIdentity $Xml '\')
    Write-JsonAtomic $context.ManifestPath $context.Manifest -OperatorSid $context.Manifest.operatorSid -MaxBytes $script:LifeOSGenerationManifestMaxBytes
}

function Stop-DeploymentTaskBarrier {
    param($Manifest, [string]$ManifestPath, [int]$TimeoutSeconds = 45)
    # Validate both writers before disabling either. XML remains only in the
    # protected task backup; the journal contains non-secret identity hashes.
    $validated = @()
    foreach ($record in @($Manifest.codexTask, $Manifest.snapshotTask)) {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { [string]$_.TaskName -eq [string]$record.Name })
        foreach ($task in $tasks) {
            $path = [string]$task.TaskPath
            if ($path -notin @('\', [string]$record.TaskPath)) { throw 'Task path is not deployment owned.' }
            $identity = Get-TaskRecoveryIdentity (Export-ScheduledTask -TaskName $record.Name -TaskPath $path -ErrorAction Stop) $path
            $permitted = @()
            if ($record.Exists -and $path -eq [string]$record.TaskPath) {
                $permitted += Get-TaskRecoveryIdentity (Read-LifeOSCappedFileText -Path $record.Backup -MaxBytes (1 * 1024 * 1024) -Description 'Scheduled task recovery XML') $path
            }
            if ($path -eq '\' -and $null -ne $record.PSObject.Properties['installedIdentity']) { $permitted += [string]$record.installedIdentity }
            # Ordered dictionaries are used by the running installer.
            if ($path -eq '\' -and $record -is [System.Collections.IDictionary] -and $record.Contains('installedIdentity')) { $permitted += [string]$record['installedIdentity'] }
            if ($identity -notin $permitted) { throw 'Task action/principal/path changed; recovery refused.' }
            $validated += [pscustomobject]@{ Name=$record.Name; Path=$path; Identity=$identity; Record=$record }
        }
    }
    foreach ($unit in $validated) {
        Set-JournalProperty $unit.Record 'barrierPhase' 'stopping'
        Write-JsonAtomic $ManifestPath $Manifest -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSGenerationManifestMaxBytes
        try { Disable-ScheduledTask -TaskName $unit.Name -TaskPath $unit.Path -ErrorAction Stop | Out-Null }
        catch {
            if (@(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $unit.Name -and $_.TaskPath -eq $unit.Path }).Count -gt 0) { throw }
            continue
        }
        $task = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $unit.Name -and $_.TaskPath -eq $unit.Path })
        if ($task.Count -eq 0) { continue }
        try { Stop-ScheduledTask -TaskName $unit.Name -TaskPath $unit.Path -ErrorAction Stop }
        catch {
            if (@(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $unit.Name -and $_.TaskPath -eq $unit.Path }).Count -gt 0) { throw }
            continue
        }
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        do {
            $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $unit.Name -and $_.TaskPath -eq $unit.Path })
            if ($tasks.Count -eq 0) { break }
            if ($tasks.Count -ne 1) { throw 'Scheduled writer identity is ambiguous.' }
            $task = $tasks[0]
            $info = Get-ScheduledTaskInfo -TaskName $unit.Name -TaskPath $unit.Path -ErrorAction Stop
            if ([string]$task.State -eq 'Disabled' -and [long]$info.LastTaskResult -notin @(0x41301, 0x41325)) { break }
            if ((Get-Date) -ge $deadline) { throw 'Scheduled writer terminal-completion barrier timed out.' }
            Start-Sleep -Milliseconds 100
        } while ($true)
        $remaining = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $unit.Name -and $_.TaskPath -eq $unit.Path })
        if ($remaining.Count -gt 0 -and (Get-TaskRecoveryIdentity (Export-ScheduledTask -TaskName $unit.Name -TaskPath $unit.Path -ErrorAction Stop) $unit.Path) -ne $unit.Identity) { throw 'Task identity changed during shutdown.' }
        Set-JournalProperty $unit.Record 'barrierPhase' 'stopped'
        Write-JsonAtomic $ManifestPath $Manifest -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSGenerationManifestMaxBytes
    }
}

function Get-RecoveryArtifactState {
    param(
        [string]$Path,
        [switch]$AllowNodeRuntime,
        [switch]$AllowServiceHostBinary,
        [psobject]$Manifest
    )
    if ($AllowNodeRuntime -and $AllowServiceHostBinary) { throw 'Recovery artifact cannot use two large-file contracts.' }
    if ($AllowServiceHostBinary -and ($null -eq $Manifest -or -not (Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $Path))) {
        throw 'Service-host recovery bound requires an exact manifest-bound artifact path.'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    Assert-NoReparsePath $Path
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $maxFileBytes = Get-LifeOSRecoveryFileMaxBytes -Path $Path -AllowNodeRuntime:$AllowNodeRuntime -AllowServiceHostBinary:$AllowServiceHostBinary -Manifest $Manifest
        if ([long]$item.Length -gt $maxFileBytes) {
            throw 'Recovery artifact exceeds its bounded file size.'
        }
        return 'file:' + (Get-FileSha256 $Path)
    }
    if ($AllowServiceHostBinary) { throw 'Service-host recovery contract cannot be applied to a directory.' }
    $largeFileRelativePath = if ($AllowNodeRuntime) { 'node.exe' } else { '' }
    $largeFileMaxBytes = if ($AllowNodeRuntime) { [long]$script:LifeOSCandidateNodeMaxFileBytes } else { [long]0 }
    return 'tree:' + (@(Get-TreeManifest $Path -LargeFileRelativePath $largeFileRelativePath -LargeFileMaxBytes $largeFileMaxBytes) | ConvertTo-Json -Depth 8 -Compress)
}

function Assert-RecoveryUnitState {
    param($Unit, [string]$Current)
    if ($Current -eq [string]$Unit.post) { return }
    if ($Unit.phase -eq 'complete' -or $Current -notin @([string]$Unit.pre, 'absent')) { throw 'Recovery unit has an unrelated current state.' }
    if ($Current -eq 'absent' -and $Unit.phase -ne 'restoring' -and $Unit.pre -ne 'absent') { throw 'Recovery unit disappeared before restore intent.' }
}

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
        # Windows system executables can be exposed as hardlinks into WinSxS.
        # A hardlink does not redirect path resolution, so it is safe here;
        # junctions, symbolic links, and other reparse/path-redirection links
        # remain rejected. Keep the Target fallback for hosts that expose a
        # target without a LinkType property.
        $unsafeLink = $null -ne $linkType -and [string]$linkType -ne 'HardLink'
        $unsafeTarget = $null -ne $target -and [string]$linkType -ne 'HardLink'
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or
            $unsafeLink -or $unsafeTarget) {
            throw "Reparse points and path-redirection links are not permitted: $current"
        }
    }
}

function Get-LifeOSPathIdentityChain {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)
    $full = Get-FullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) { throw "$Description path root is invalid." }
    $current = $root
    $chain = New-Object 'System.Collections.Generic.List[object]'
    $remainder = $full.Substring($root.Length)
    foreach ($segment in ($remainder -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "$Description contains a reparse point: $current"
        }
        $linkType = if ($null -ne $item.PSObject.Properties['LinkType']) { $item.LinkType } else { $null }
        $target = if ($null -ne $item.PSObject.Properties['Target']) { $item.Target } else { $null }
        if (($null -ne $linkType -and [string]$linkType -ne 'HardLink') -or
            ($null -ne $target -and [string]$linkType -ne 'HardLink')) {
            throw "$Description contains a path-redirection link: $current"
        }
        [void]$chain.Add([pscustomobject]@{
            Path = Get-FullPath $current
            FileId = Get-LifeOSNativeFileIdentity -Path $current -Description $Description
            Attributes = [int]$item.Attributes
            IsContainer = [bool]$item.PSIsContainer
            Length = if ($item.PSIsContainer) { [long]0 } else { [long]$item.Length }
            LastWriteTimeUtc = [DateTime]$item.LastWriteTimeUtc
            CreationTimeUtc = [DateTime]$item.CreationTimeUtc
        })
    }
    if ($chain.Count -le 0) { throw "$Description has no existing path components." }
    # Emit one identity record per pipeline item. Every caller captures this
    # function with @(...), which keeps one-component paths indexable while
    # preserving every ancestor on multi-component paths. A unary comma here
    # would make @(...) contain one nested object[] under Windows PowerShell 5.1.
    return $chain.ToArray()
}

function Assert-LifeOSPathIdentityChain {
    param(
        [Parameter(Mandatory)][object[]]$Expected,
        [Parameter(Mandatory)][string]$Description
    )
    $actual = @(Get-LifeOSPathIdentityChain -Path ([string]$Expected[$Expected.Count - 1].Path) -Description $Description)
    if ($actual.Count -ne $Expected.Count) { throw "$Description ancestor identity changed." }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        # Directory timestamps are mutable metadata: creating or removing a
        # sibling staging entry updates an ancestor even when this exact path
        # was never replaced. File ID, type, and attributes still detect an
        # ancestor replacement or reparse transition. Keep the stronger
        # timestamp/length check for the descriptor's leaf file itself.
        $identityChanged = [string]$actual[$index].Path -ine [string]$Expected[$index].Path -or
            [string]$actual[$index].FileId -cne [string]$Expected[$index].FileId -or
            [int]$actual[$index].Attributes -ne [int]$Expected[$index].Attributes -or
            [bool]$actual[$index].IsContainer -ne [bool]$Expected[$index].IsContainer
        if ($index -eq $Expected.Count - 1) {
            $identityChanged = $identityChanged -or
                [long]$actual[$index].Length -ne [long]$Expected[$index].Length -or
                [DateTime]$actual[$index].LastWriteTimeUtc -ne [DateTime]$Expected[$index].LastWriteTimeUtc -or
                [DateTime]$actual[$index].CreationTimeUtc -ne [DateTime]$Expected[$index].CreationTimeUtc
        }
        if ($identityChanged) {
            if ($index -eq $Expected.Count - 1) { throw "$Description file identity changed." }
            throw "$Description ancestor identity changed."
        }
    }
    return $actual
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
        $bytes = Read-LifeOSCappedFileBytes -Path $Path -MaxBytes 256 -Description 'LIFEOS_TAILSCALE_EDGE_TOKEN source'
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

function Get-LifeOSPropertyNames {
    param([AllowNull()][object]$Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-LifeOSInstalledIntegrityContract {
    param([Parameter(Mandatory)][psobject]$Manifest)
    $property = $Manifest.PSObject.Properties['installedIntegrity']
    if ($null -eq $property -or $null -eq $property.Value) { return }
    $integrity = $property.Value
    $requiredNames = @('schemaVersion', 'host', 'api', 'gateway', 'node', 'pythonBase', 'apiConfig', 'gatewayConfig', 'gatewayAppConfig', 'snapshotScript')
    $optionalNames = @('pythonVenv')
    $actualNames = @(Get-LifeOSPropertyNames $integrity)
    $unknownNames = @($actualNames | Where-Object { $_ -notin ($requiredNames + $optionalNames) })
    $missingNames = @($requiredNames | Where-Object { $_ -notin $actualNames })
    if ($unknownNames.Count -ne 0 -or $missingNames.Count -ne 0 -or
        $actualNames.Count -ne @($requiredNames + @($actualNames | Where-Object { $_ -in $optionalNames })).Count) {
        throw 'Installed integrity inventory has a non-canonical property set.'
    }
    $schemaVersion = Get-JournalProperty $integrity 'schemaVersion'
    if (-not (Test-LifeOSIntegralNumber $schemaVersion) -or [int]$schemaVersion -ne 1) {
        throw 'Installed integrity inventory schema is unsupported.'
    }

    $records = @(
        [pscustomobject]@{ Name = 'host'; Kind = 'file'; Path = $Manifest.paths.host }
        [pscustomobject]@{ Name = 'api'; Kind = 'tree'; Path = $Manifest.paths.api }
        [pscustomobject]@{ Name = 'gateway'; Kind = 'tree'; Path = $Manifest.paths.gateway }
        [pscustomobject]@{ Name = 'node'; Kind = 'tree'; Path = $Manifest.paths.node }
        [pscustomobject]@{ Name = 'pythonBase'; Kind = 'tree'; Path = $Manifest.paths.pythonBase }
        [pscustomobject]@{ Name = 'apiConfig'; Kind = 'file'; Path = $Manifest.paths.apiConfig }
        [pscustomobject]@{ Name = 'gatewayConfig'; Kind = 'file'; Path = $Manifest.paths.gatewayConfig }
        [pscustomobject]@{ Name = 'gatewayAppConfig'; Kind = 'file'; Path = $Manifest.paths.gatewayAppConfig }
        [pscustomobject]@{ Name = 'snapshotScript'; Kind = 'file'; Path = $Manifest.paths.tailscaleSnapshotScript }
    )
    if ($actualNames -contains 'pythonVenv') {
        $records += [pscustomobject]@{ Name = 'pythonVenv'; Kind = 'tree'; Path = $Manifest.paths.pythonVenv }
    }
    foreach ($recordSpec in $records) {
        $record = Get-JournalProperty $integrity $recordSpec.Name
        if ($null -eq $record) { throw "Installed integrity record is missing: $($recordSpec.Name)" }
        $expectedRecordNames = if ($recordSpec.Kind -eq 'file') {
            @('path', 'length', 'sha256')
        } else {
            @('path', 'fileCount', 'totalBytes', 'manifestSha256')
        }
        $recordNames = @(Get-LifeOSPropertyNames $record)
        if ($recordNames.Count -ne $expectedRecordNames.Count -or
            @($expectedRecordNames | Where-Object { $_ -notin $recordNames }).Count -ne 0 -or
            @($recordNames | Where-Object { $_ -notin $expectedRecordNames }).Count -ne 0) {
            throw "Installed integrity record has a non-canonical property set: $($recordSpec.Name)"
        }
        $recordPath = Get-JournalProperty $record 'path'
        if ($recordPath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$recordPath)) {
            throw "Installed integrity record path is malformed: $($recordSpec.Name)"
        }
        $expectedPath = Get-FullPath ([string]$recordSpec.Path)
        $actualPath = Get-FullPath ([string]$recordPath)
        if ($recordSpec.Kind -eq 'tree') {
            $expectedPath = $expectedPath.TrimEnd('\')
            $actualPath = $actualPath.TrimEnd('\')
        }
        if ($actualPath -ine $expectedPath) {
            throw "Installed integrity record is bound to the wrong path: $($recordSpec.Name)"
        }
        if ($recordSpec.Kind -eq 'file') {
            $length = Get-JournalProperty $record 'length'
            $hash = Get-JournalProperty $record 'sha256'
            if (-not (Test-LifeOSIntegralNumber $length) -or [long]$length -lt 0 -or
                [long]$length -gt [long]$script:LifeOSMaxCappedReadBytes -or
                $hash -isnot [string] -or [string]$hash -cnotmatch '^[0-9a-f]{64}$') {
                throw "Installed integrity file record is malformed: $($recordSpec.Name)"
            }
        } else {
            $fileCount = Get-JournalProperty $record 'fileCount'
            $totalBytes = Get-JournalProperty $record 'totalBytes'
            $hash = Get-JournalProperty $record 'manifestSha256'
            if (-not (Test-LifeOSIntegralNumber $fileCount) -or [long]$fileCount -lt 0 -or
                [long]$fileCount -gt [long]$script:LifeOSRecoveryMaxFileUnits -or
                -not (Test-LifeOSIntegralNumber $totalBytes) -or [long]$totalBytes -lt 0 -or
                [long]$totalBytes -gt [long]$script:LifeOSRecoveryMaxTreeBytes -or
                $hash -isnot [string] -or [string]$hash -cnotmatch '^[0-9a-f]{64}$') {
                throw "Installed integrity tree record is malformed: $($recordSpec.Name)"
            }
        }
    }
}

function Assert-CanonicalRollbackManifest {
    param([Parameter(Mandatory)][psobject]$Manifest, [Parameter(Mandatory)][string]$ManifestPath, [switch]$AllowPending)
    $required = @('schemaVersion', 'createdAt', 'operatorSid', 'legacyTask', 'codexTask', 'serviceSnapshots', 'services', 'paths', 'backups', 'aclSnapshots', 'tailscaleStatusBefore')
    $optional = @('apiServiceSid', 'gatewayServiceSid', 'supplementCatalogInitialized', 'tailscaleStatusAfter', 'cutoverCompletedAt', 'legacyListener', 'snapshotTask', 'codexCollectorVerification', 'transactionId', 'generation', 'manifestPath', 'installMode', 'collectorTransition', 'priorInstalledGeneration', 'installedIntegrity')
    $actual = @($Manifest.PSObject.Properties.Name | Sort-Object)
    $unknown = @($actual | Where-Object { $_ -notin ($required + $optional) })
    $missing = @($required | Where-Object { $_ -notin $actual })
    if ($unknown.Count -ne 0 -or $missing.Count -ne 0) {
        throw 'Rollback manifest fields are not the canonical install schema.'
    }
    if ([int]$Manifest.schemaVersion -ne 2) {
        throw 'Only schemaVersion 2 rollback manifests are accepted automatically; older schemas require operator-led recovery.'
    }
    foreach ($textField in @(
        [pscustomobject]@{ Name = 'createdAt'; Maximum = 128; Required = $true }
        [pscustomobject]@{ Name = 'operatorSid'; Maximum = 256; Required = $true }
        [pscustomobject]@{ Name = 'transactionId'; Maximum = 128; Required = $false }
        [pscustomobject]@{ Name = 'generation'; Maximum = 128; Required = $false }
        [pscustomobject]@{ Name = 'manifestPath'; Maximum = 4096; Required = $false }
    )) {
        $value = Get-JournalProperty $Manifest $textField.Name
        if ($null -eq $value -and -not $textField.Required) { continue }
        if ($value -isnot [string]) { throw "Rollback manifest string field is malformed: $($textField.Name)" }
        if ([string]::IsNullOrWhiteSpace([string]$value) -or $value.Length -gt [int]$textField.Maximum) {
            throw "Rollback manifest string field is malformed: $($textField.Name)"
        }
    }
    if ($null -eq $Manifest.services -or $Manifest.services -is [string] -or
        $Manifest.services -isnot [System.Collections.IEnumerable]) {
        throw 'Rollback manifest service collection is malformed.'
    }
    $serviceSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($serviceName in @($Manifest.services)) {
        if ($serviceName -isnot [string] -or -not $serviceSet.Add([string]$serviceName) -or
            [string]$serviceName -notin @('LifeOSAPI', 'LifeOSGateway')) {
            throw 'Rollback manifest service collection is not canonical.'
        }
    }
    if ($serviceSet.Count -ne 2) { throw 'Rollback manifest service collection is not canonical.' }
    foreach ($collection in @(
        [pscustomobject]@{ Name = 'backups'; Value = $Manifest.backups; Maximum = $script:LifeOSRecoveryMaxTreeRoots }
        [pscustomobject]@{ Name = 'aclSnapshots'; Value = $Manifest.aclSnapshots; Maximum = $script:LifeOSRecoveryMaxTreeRoots }
    )) {
        # Windows PowerShell 5.1 materializes an empty JSON array as a null
        # pipeline value. The required property still exists, so treat that
        # representation as an empty bounded collection.
        if ($null -ne $collection.Value -and $collection.Value -is [string]) {
            throw "Rollback manifest collection is malformed: $($collection.Name)"
        }
        if ($null -ne $collection.Value -and $collection.Value -isnot [System.Collections.IEnumerable]) {
            # Windows PowerShell 5.1 unwraps a one-item JSON array when it is
            # assigned to a property. Accept that representation only when it
            # has the exact minimum fields of the owned item type; scalar or
            # unrelated objects remain rejected.
            $itemFields = if ($collection.Name -eq 'backups') {
                @('destination', 'backup', 'priorExists', 'changed', 'phase')
            } else { @('destination', 'backup', 'priorExists', 'mode') }
            $properties = @($collection.Value.PSObject.Properties.Name)
            if (@($itemFields | Where-Object { $_ -notin $properties }).Count -ne 0) {
                throw "Rollback manifest collection is malformed: $($collection.Name)"
            }
        }
        # An `if` expression unwraps a one-item array under Windows
        # PowerShell 5.1. Count the normalized wrapper inline so a single
        # manifest item cannot lose its collection shape before validation.
        $itemCount = if ($null -eq $collection.Value) { 0 } else { @($collection.Value).Count }
        if ($itemCount -gt [int]$collection.Maximum) {
            throw "Rollback manifest collection is too large: $($collection.Name)"
        }
    }
    if ($null -ne $Manifest.PSObject.Properties['priorInstalledGeneration']) {
        Assert-LifeOSGenerationReference $Manifest.priorInstalledGeneration
    }
    if ($null -ne $Manifest.PSObject.Properties['codexCollectorVerification']) {
        $verification = $Manifest.codexCollectorVerification
        if ($null -eq $verification -or $null -eq $verification.PSObject.Properties['status'] -or
            $null -eq $verification.PSObject.Properties['exitCode'] -or $null -eq $verification.PSObject.Properties['observation'] -or
            $null -eq $verification.PSObject.Properties['verifiedAt']) {
            throw 'Codex collector verification evidence is incomplete.'
        }
        $verificationStatus = [string]$verification.status
        $verificationExit = [int]$verification.exitCode
        $verificationObservation = [string]$verification.observation
        if (($verificationStatus -eq 'observed' -and ($verificationExit -ne 0 -or $verificationObservation -ne 'observed')) -or
            ($verificationStatus -eq 'provider_unavailable' -and ($verificationExit -ne 2 -or $verificationObservation -ne 'unverified')) -or
            $verificationStatus -notin @('observed', 'provider_unavailable')) {
            throw 'Codex collector verification evidence has an invalid status.'
        }
        try { [void][DateTimeOffset]::Parse([string]$verification.verifiedAt) } catch { throw 'Codex collector verification timestamp is invalid.' }
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
    $taskRecords = @(
        [pscustomobject]@{ Name = 'legacyTask'; Value = $Manifest.legacyTask }
        [pscustomobject]@{ Name = 'codexTask'; Value = $Manifest.codexTask })
    if ($null -ne $Manifest.PSObject.Properties['snapshotTask']) {
        $taskRecords += [pscustomobject]@{ Name = 'snapshotTask'; Value = $Manifest.snapshotTask }
    }
    foreach ($taskRecord in $taskRecords) {
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
    # v17 added a canonical path reference for the operator-managed edge
    # token; v18 adds the SYSTEM-written Tailscale snapshot, its state
    # directory, and the staged snapshot script.  Keep them optional when
    # reading older manifests so rollback remains compatible, while rejecting
    # every non-canonical path.
    $optionalExpected = [ordered]@{
        localApiSecret = (Join-Path $defaults.SecretRoot 'local-api.secret')
        tailscaleEdgeToken = (Get-LifeOSTailscaleEdgeTokenPath $defaults.SecretRoot)
        stateDirectory = (Join-Path $defaults.InstallRoot 'host\state')
        tailscaleSnapshot = (Join-Path $defaults.InstallRoot 'host\state\tailscale-state.json')
        tailscaleSnapshotScript = (Join-Path $defaults.InstallRoot 'host\tailscale_snapshot.ps1')
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
    Assert-LifeOSInstalledIntegrityContract -Manifest $Manifest
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
    $backupTaskRecords = @(
        [pscustomobject]@{ Name = 'LifeOSSyncServer'; Value = $Manifest.legacyTask },
        [pscustomobject]@{ Name = 'LifeOSCodexCollector'; Value = $Manifest.codexTask })
    if ($null -ne $Manifest.PSObject.Properties['snapshotTask']) {
        $backupTaskRecords += [pscustomobject]@{ Name = [string]$Manifest.snapshotTask.Name; Value = $Manifest.snapshotTask }
    }
    foreach ($taskRecord in $backupTaskRecords) {
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
    # Only the staged snapshot writer is ever copied through a backup intent.
    # `stateDirectory` and `tailscaleSnapshot` are created and written in
    # place, never restored, so leaving them out keeps a manifest from
    # declaring `tailscale-state.json` as an artifact restore destination.
    # Both still belong to $canonicalAclDestinations below because
    # Set-RestrictedAcl registers an ACL snapshot for the state directory.
    foreach ($property in @('tailscaleSnapshotScript', 'localApiSecret')) {
        if ($property -in $pathActual) { $canonicalArtifactDestinations += Get-FullPath ([string]$optionalExpected[$property]) }
    }
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
            $item.PSObject.Properties['phase'] -eq $null -or ([string]$item.phase -ne 'complete' -and -not ($AllowPending -and [string]$item.phase -eq 'pending'))) {
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
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]]$ArgumentList,
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
        if ($isPowerShellScript) {
            # Windows PowerShell 5.1 cannot reliably splat an array containing
            # named script parameters through the call operator: a later item
            # such as `-OutputPath` can be rebound to this wrapper and fail
            # before the child script starts. Invoke the reviewed Windows
            # PowerShell host as a native process instead; its -File boundary
            # receives the argv array exactly as the script declares it.
            $windowsPowerShell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
                throw 'Windows PowerShell host is missing.'
            }
            $output = & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $FilePath @ArgumentList 2>&1
        } else {
            $output = & $FilePath @ArgumentList 2>&1
        }
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
    $config = Read-LifeOSCappedFileText -Path $configPath -MaxBytes 64 * 1024 -Description 'Python venv metadata'
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

function Assert-LifeOSCandidateRoot {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$ExpectedSourceSha,
        [string]$DeploymentScriptRoot,
        [switch]$VerifyCandidate
    )
    if ($ExpectedSourceSha -notmatch '\A[0-9a-fA-F]{40}\z') {
        throw 'Expected source SHA must be a full 40-character hexadecimal Git object id supplied by a trusted release record.'
    }
    $rootFull = Get-FullPath $Root
    Assert-ExistingDirectory $rootFull 'LifeOS candidate root'
    $expectedName = 'lifeos-release-' + $ExpectedSourceSha.ToLowerInvariant()
    if (([IO.DirectoryInfo]$rootFull).Name -cne $expectedName) {
        throw 'Candidate directory name must be lifeos-release-<full-source-sha>.'
    }
    if (-not [string]::IsNullOrWhiteSpace($DeploymentScriptRoot)) {
        $expectedDeployRoot = Get-FullPath (Join-Path $rootFull 'deploy')
        if ((Get-FullPath $DeploymentScriptRoot) -ine $expectedDeployRoot) {
            throw 'Deployment scripts must execute from the exact deploy directory inside the verified candidate.'
        }
    }
    $candidateVerifier = Join-Path $rootFull 'deploy\verify-candidate.ps1'
    Assert-ExistingFile $candidateVerifier 'Candidate verifier'
    if ($VerifyCandidate) {
        & $candidateVerifier -Root $rootFull -ExpectedSourceSha $ExpectedSourceSha | Out-Host
    }
    return $rootFull
}

function Assert-LifeOSCandidateSourceBindings {
    param(
        [Parameter(Mandatory)][string]$CandidateRoot,
        [Parameter(Mandatory)][string]$ApiRoot,
        [Parameter(Mandatory)][string]$GatewayRoot,
        [Parameter(Mandatory)][string]$NodeRuntimeRoot,
        [Parameter(Mandatory)][string]$ServiceHostBinary,
        [Parameter(Mandatory)][string]$GatewayEntryPoint,
        [Parameter(Mandatory)][string]$DeploymentScriptRoot
    )
    $rootFull = Get-FullPath $CandidateRoot
    $bindings = @(
        [pscustomobject]@{ Name = 'API source'; Actual = $ApiRoot; Relative = 'api' },
        [pscustomobject]@{ Name = 'gateway source'; Actual = $GatewayRoot; Relative = 'gateway' },
        [pscustomobject]@{ Name = 'Node runtime source'; Actual = $NodeRuntimeRoot; Relative = 'node-runtime' },
        [pscustomobject]@{ Name = 'service host source'; Actual = $ServiceHostBinary; Relative = 'service-host\LifeOS.ServiceHost.exe' },
        [pscustomobject]@{ Name = 'gateway entry point'; Actual = $GatewayEntryPoint; Relative = 'gateway\main.py' },
        [pscustomobject]@{ Name = 'deployment script root'; Actual = $DeploymentScriptRoot; Relative = 'deploy' }
    )
    foreach ($binding in $bindings) {
        $expected = Get-FullPath (Join-Path $rootFull $binding.Relative)
        $actual = Get-FullPath $binding.Actual
        if ($actual -ine $expected) {
            throw "$($binding.Name) is not bound to the verified candidate: expected $expected, got $actual."
        }
    }
    return $rootFull
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

function Get-LifeOSFileDigest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [string]$ExpectedFileId = ''
    )
    for ($attempt = 0; $attempt -lt 3; $attempt++) {
        $beforeChain = $null
        $beforeLeaf = $null
        $handle = $null
        $stream = $null
        $hasher = $null
        $retry = $false
        try {
            Assert-ExistingFile $Path $Description
            $beforeChain = @(Get-LifeOSPathIdentityChain -Path $Path -Description $Description)
            if ($beforeChain.Count -le 0) { throw "$Description has no readable path identity." }
            $beforeLeaf = $beforeChain[$beforeChain.Count - 1]
            $handle = [LifeOSNativeFileIdentity]::OpenRead((Get-FullPath $Path))
            $attributes = [LifeOSNativeFileIdentity]::GetAttributes($handle)
            if (($attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) {
                $handle.Dispose()
                $handle = $null
                throw "$Description is a reparse point."
            }
            $openedId = [string][LifeOSNativeFileIdentity]::Get($handle)
            if ($openedId -cne [string]$beforeLeaf.FileId -or
                (-not [string]::IsNullOrWhiteSpace($ExpectedFileId) -and $openedId -cne $ExpectedFileId)) {
                $handle.Dispose()
                $handle = $null
                throw "$Description changed while it was being opened."
            }
            # Hashing consumes the descriptor-bound stream. The path is only used
            # for the ancestor-chain revalidation after the descriptor is read.
            $stream = [IO.FileStream]::new($handle, [IO.FileAccess]::Read, 65536, $false)
            $openedLength = [long]$stream.Length
            if ($openedLength -gt $script:LifeOSMaxCappedReadBytes) {
                throw "$Description exceeds its bounded hash size."
            }
            $hasher = [Security.Cryptography.SHA256]::Create()
            $digest = $hasher.ComputeHash($stream)
            if ([long]$stream.Length -ne $openedLength -or $stream.Position -ne $openedLength -or
                [string][LifeOSNativeFileIdentity]::Get($stream.SafeFileHandle) -cne $openedId) {
                throw "$Description changed while it was being read."
            }
            Assert-LifeOSPathIdentityChain -Expected $beforeChain -Description $Description | Out-Null
            if ($null -eq $digest -or $digest.Length -ne 32) {
                throw "Hash operation returned no SHA-256 value for $Path."
            }
            return [pscustomobject]@{
                Length = $openedLength
                Sha256 = ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
                FileId = $openedId
            }
        } catch {
            $message = [string]$_.Exception.Message
            if ($attempt -lt 2 -and $message -like '*ancestor identity changed.') {
                $retry = $true
            } else {
                throw "Could not hash ${Path}: $message"
            }
        } finally {
            if ($null -ne $hasher) { $hasher.Dispose() }
            if ($null -ne $stream) { $stream.Dispose() }
            elseif ($null -ne $handle) { $handle.Dispose() }
        }
        if ($retry) { Start-Sleep -Milliseconds 50 }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)
    $digest = Get-LifeOSFileDigest -Path $Path -Description 'Hash input'
    return [string]$digest.Sha256
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
    $integrity = Get-LifeOSFileIntegrity -Path $Path -Description $Name
    return [pscustomobject]@{ Length = [long]$integrity.length; Sha256 = [string]$integrity.sha256 }
}

function Get-LifeOSDefaultLargeFileRelativePath {
    param([Parameter(Mandatory)][string]$Root)
    $rootFull = (Get-FullPath $Root).TrimEnd('\')
    # Only the canonical installed runtime root may infer the exception. All
    # candidate, staging, and recovery callers pass the exact relative path
    # explicitly, so an arbitrary directory named `node` cannot opt in.
    $canonicalNodeRoot = (Get-FullPath (Join-Path $script:LifeOSDefaultPaths.RuntimeRoot 'node')).TrimEnd('\')
    if ($rootFull -ieq $canonicalNodeRoot) { return 'node.exe' }
    return ''
}

function Test-LifeOSNodeRuntimeArtifactPath {
    param(
        [Parameter(Mandatory)][psobject]$Manifest,
        [Parameter(Mandatory)][string]$Path,
        [switch]$TreeRoot
    )
    $pathFull = (Get-FullPath $Path).TrimEnd('\')
    $rootSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifestPaths = Get-JournalProperty $Manifest 'paths'
    $manifestNodeRoot = Get-JournalProperty $manifestPaths 'node'
    if ($manifestNodeRoot -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$manifestNodeRoot)) {
        [void]$rootSet.Add((Get-FullPath ([string]$manifestNodeRoot)).TrimEnd('\'))
    }
    $manifestBackups = Get-JournalProperty $Manifest 'backups'
    foreach ($artifact in @($manifestBackups)) {
        if ($null -eq $artifact -or (Get-JournalProperty $artifact 'kind') -cne 'node-runtime') { continue }
        foreach ($field in @('destination', 'backup')) {
            $rootValue = Get-JournalProperty $artifact $field
            if ($rootValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$rootValue)) {
                [void]$rootSet.Add((Get-FullPath ([string]$rootValue)).TrimEnd('\'))
            }
        }
    }
    foreach ($root in $rootSet) {
        if ($TreeRoot) {
            if ($pathFull -ieq $root) { return $true }
        } elseif ($pathFull -ieq (Join-Path $root 'node.exe')) {
            return $true
        }
    }
    return $false
}

function Test-LifeOSServiceHostArtifactPath {
    param(
        [Parameter(Mandatory)][psobject]$Manifest,
        [Parameter(Mandatory)][string]$Path
    )
    $pathFull = (Get-FullPath $Path).TrimEnd('\')
    $rootSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $manifestPaths = Get-JournalProperty $Manifest 'paths'
    $manifestHost = Get-JournalProperty $manifestPaths 'host'
    if ($manifestHost -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$manifestHost)) {
        [void]$rootSet.Add((Get-FullPath ([string]$manifestHost)).TrimEnd('\'))
    }
    $manifestBackups = Get-JournalProperty $Manifest 'backups'
    foreach ($artifact in @($manifestBackups)) {
        if ($null -eq $artifact -or (Get-JournalProperty $artifact 'kind') -cne 'host-binary') { continue }
        foreach ($field in @('destination', 'backup')) {
            $pathValue = Get-JournalProperty $artifact $field
            if ($pathValue -is [string] -and -not [string]::IsNullOrWhiteSpace([string]$pathValue)) {
                [void]$rootSet.Add((Get-FullPath ([string]$pathValue)).TrimEnd('\'))
            }
        }
    }
    foreach ($expectedPath in $rootSet) {
        if ($pathFull -ieq $expectedPath) { return $true }
    }
    return $false
}

function Assert-LifeOSNodeRuntimeStagingRelativePath {
    param([Parameter(Mandatory)][string]$RelativePath)
    if ($RelativePath -notmatch '\A(?:[A-Za-z0-9@._-]+/)*\.rollback-restore-[0-9a-fA-F-]+-[0-9]+(?:/node\.exe)?\z') {
        throw 'Node runtime staging path is not canonical.'
    }
}

function Get-LifeOSNodeRuntimeStagingRelativePaths {
    param(
        [Parameter(Mandatory)][psobject]$Manifest,
        [Parameter(Mandatory)][psobject]$Journal,
        [Parameter(Mandatory)][string]$Root
    )
    $rootFull = (Get-FullPath $Root).TrimEnd('\')
    $transactionId = [string](Get-JournalProperty $Manifest 'transactionId')
    if ([string]::IsNullOrWhiteSpace($transactionId) -or $transactionId.Length -gt 128) {
        throw 'Node runtime staging transaction identity is malformed.'
    }
    $journalUnits = Get-JournalProperty $Journal 'units'
    if ($null -eq $journalUnits) { return ,@() }
    $relativePaths = New-Object 'System.Collections.Generic.List[string]'
    $unitIndex = 0
    foreach ($unit in @($journalUnits)) {
        if ($null -eq $unit) { throw 'Recovery journal unit is malformed.' }
        if ([string](Get-JournalProperty $unit 'phase') -eq 'restoring') {
            $destination = [string](Get-JournalProperty $unit 'destination')
            $isNodeArtifact = -not [string]::IsNullOrWhiteSpace($destination) -and
                (Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $destination)
            if ($isNodeArtifact) {
                $expectedStage = Join-Path (Split-Path -Parent $destination) ('.rollback-restore-' + $transactionId + '-' + $unitIndex)
                $recordedStage = [string](Get-JournalProperty $unit 'stagingPath')
                if ([string]::IsNullOrWhiteSpace($recordedStage) -or
                    (Get-FullPath $recordedStage) -ine (Get-FullPath $expectedStage)) {
                    throw 'Node runtime staging path is not bound to its recovery journal unit.'
                }
                $stageFull = (Get-FullPath $recordedStage).TrimEnd('\')
                if ($stageFull.StartsWith($rootFull + '\', [StringComparison]::OrdinalIgnoreCase)) {
                    $relativeStage = $stageFull.Substring($rootFull.Length).TrimStart('\').Replace('\', '/')
                    Assert-LifeOSNodeRuntimeStagingRelativePath $relativeStage
                    [void]$relativePaths.Add($relativeStage)
                }
            }
        }
        $unitIndex++
    }
    return ,@($relativePaths.ToArray() | Sort-Object -Unique)
}

function Assert-LifeOSLargeFileContract {
    param(
        [Parameter(Mandatory)][string]$RelativePath,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][long]$DefaultMaxBytes
    )
    if ($MaxBytes -le $DefaultMaxBytes) {
        throw 'Large-file contract must be strictly larger than the ordinary file bound.'
    }
    if ($RelativePath -in @('node.exe', 'node-runtime/node.exe')) {
        if ($MaxBytes -gt $script:LifeOSCandidateNodeMaxFileBytes) {
            throw 'Large-file contract exceeds the reviewed standalone Node runtime bound.'
        }
        return
    }
    if ([string]$RelativePath -ieq [string]$script:LifeOSCandidateServiceHostRelativePath) {
        if ($MaxBytes -gt $script:LifeOSCandidateServiceHostMaxFileBytes) {
            throw 'Large-file contract exceeds the reviewed service-host bound.'
        }
        return
    }
    if ($RelativePath -notmatch '\A(?:[A-Za-z0-9@._-]+/)*\.rollback-restore-[0-9a-fA-F-]+-[0-9]+(?:/node\.exe)?\z' -or
        $MaxBytes -gt $script:LifeOSCandidateNodeMaxFileBytes) {
        throw 'Large-file contract is not an exact reviewed runtime or recovery exception.'
    }
}

function Get-LifeOSBoundedFileMaxBytes {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][long]$DefaultMaxBytes,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [string[]]$LargeFileRelativePaths = @(),
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    if ($DefaultMaxBytes -le 0) { throw 'Default bounded file limit is invalid.' }
    $legacyContractPaths = New-Object 'System.Collections.Generic.List[string]'
    if (-not [string]::IsNullOrWhiteSpace($LargeFileRelativePath)) { [void]$legacyContractPaths.Add($LargeFileRelativePath) }
    if ($null -ne $LargeFileRelativePaths) {
        foreach ($relativePath in $LargeFileRelativePaths) {
            if (-not [string]::IsNullOrWhiteSpace([string]$relativePath)) { [void]$legacyContractPaths.Add([string]$relativePath) }
        }
    }
    $hasExplicitContracts = $null -ne $LargeFileContracts -and $LargeFileContracts.Count -gt 0
    if ($hasExplicitContracts -and $legacyContractPaths.Count -gt 0) {
        throw 'Large-file contracts must use either the exact contract map or the legacy single-bound arguments.'
    }
    $contracts = [ordered]@{}
    if ($hasExplicitContracts) {
        foreach ($key in $LargeFileContracts.Keys) {
            $relativePath = [string]$key
            if ([string]::IsNullOrWhiteSpace($relativePath) -or $contracts.Contains($relativePath)) {
                throw 'Large-file contract map contains a duplicate or empty path.'
            }
            $contracts[$relativePath] = [long]$LargeFileContracts[$key]
        }
    } elseif ($legacyContractPaths.Count -gt 0) {
        $effectiveMaxBytes = if ($LargeFileMaxBytes -eq 0) { [long]$script:LifeOSCandidateNodeMaxFileBytes } else { $LargeFileMaxBytes }
        foreach ($relativePath in $legacyContractPaths) {
            if ($contracts.Contains([string]$relativePath)) { throw 'Large-file contract contains a duplicate path.' }
            $contracts[[string]$relativePath] = $effectiveMaxBytes
        }
    } else {
        if ($LargeFileMaxBytes -ne 0) { throw 'Large-file byte limit has no relative path.' }
        $defaultRelativePath = Get-LifeOSDefaultLargeFileRelativePath -Root $Root
        if (-not [string]::IsNullOrWhiteSpace($defaultRelativePath)) {
            $contracts[$defaultRelativePath] = [long]$script:LifeOSCandidateNodeMaxFileBytes
        }
    }
    foreach ($relativePath in $contracts.Keys) {
        Assert-LifeOSLargeFileContract -RelativePath ([string]$relativePath) -MaxBytes ([long]$contracts[$relativePath]) -DefaultMaxBytes $DefaultMaxBytes
    }
    $relativePath = Get-LifeOSTreeRelativePath -Root $Root -Path $Path
    foreach ($contractPath in $contracts.Keys) {
        if ($relativePath -ieq [string]$contractPath) { return [long]$contracts[$contractPath] }
    }
    return $DefaultMaxBytes
}

function Get-LifeOSRecoveryFileMaxBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [switch]$AllowNodeRuntime,
        [switch]$AllowServiceHostBinary,
        [psobject]$Manifest
    )
    if ($AllowNodeRuntime -and $AllowServiceHostBinary) { throw 'Recovery file cannot use two large-file contracts.' }
    $fullPath = Get-FullPath $Path
    $leaf = [IO.Path]::GetFileName($fullPath)
    # The caller must prove that this exact path belongs to the manifest's
    # runtime artifact. The switch only selects the bound after that proof; a
    # same-basename file elsewhere remains at 64 MiB.
    if ($AllowNodeRuntime) {
        if ($leaf -ine 'node.exe' -or $null -eq $Manifest -or -not (Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $fullPath)) {
            throw 'Node-runtime recovery bound requires an exact manifest-bound artifact path.'
        }
        return $script:LifeOSCandidateNodeMaxFileBytes
    }
    if ($AllowServiceHostBinary) {
        if ($null -eq $Manifest -or -not (Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $fullPath)) {
            throw 'Service-host recovery bound requires an exact manifest-bound artifact path.'
        }
        return $script:LifeOSCandidateServiceHostMaxFileBytes
    }
    return $script:LifeOSRecoveryMaxFileBytes
}

function Get-LifeOSBoundedTreeItem {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaxFiles = $script:LifeOSRecoveryMaxFileUnits,
        [int]$MaxDirectories = $script:LifeOSRecoveryMaxFileUnits,
        [long]$MaxBytes = $script:LifeOSRecoveryMaxTreeBytes,
        [long]$MaxFileBytes = $script:LifeOSRecoveryMaxFileBytes,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [string[]]$LargeFileRelativePaths = @(),
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    if ($MaxFiles -le 0 -or $MaxDirectories -le 0 -or $MaxBytes -le 0 -or $MaxFileBytes -le 0) {
        throw 'Bounded tree resource limits are invalid.'
    }
    Assert-ExistingDirectory $Root 'Bounded tree root'
    $rootFull = Get-FullPath $Root
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    $rootIdentity = New-LifeOSTreeItemIdentity -Item $rootItem -Description 'Bounded tree root'
    if (-not $rootIdentity.IsContainer) { throw 'Bounded tree root is not a directory.' }
    $pending = [System.Collections.Generic.Queue[object]]::new()
    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    [void]$seenPaths.Add($rootFull)
    [void]$pending.Enqueue([pscustomobject]@{ Path = $rootFull; Identity = $rootIdentity })
    $state = [pscustomobject]@{ Files = 0; Directories = 1; Bytes = [long]0 }
    while ($pending.Count -gt 0) {
        $queuedDirectory = $pending.Dequeue()
        $directory = [string]$queuedDirectory.Path
        $directoryItem = Assert-LifeOSTreeItemIdentity -Path $directory -Expected $queuedDirectory.Identity -Description 'Bounded tree directory'
        # The PowerShell filesystem provider may enumerate and materialize a
        # complete directory before its pipeline emits the first object. Use
        # the .NET enumerator directly so each child is bounded before it is
        # retained in the queue or emitted to the caller.
        $enumerator = $null
        try {
            $enumerator = [IO.Directory]::EnumerateFileSystemEntries(
                $directory, '*', [IO.SearchOption]::TopDirectoryOnly).GetEnumerator()
            while ($enumerator.MoveNext()) {
                $fullName = [string]$enumerator.Current
                $discoveredItem = Get-Item -LiteralPath $fullName -Force -ErrorAction Stop
                $fullName = [string]$discoveredItem.FullName
                if ($fullName.Length -gt $script:LifeOSRecoveryMaxPathLength) {
                    throw "Bounded tree path is too long: $fullName"
                }
                # The enumerator yields a path-level observation. Re-open that
                # exact path and compare the identity before counting,
                # enqueueing, hashing, or mutating it; a junction replacement
                # between parent enumeration and descent must fail closed.
                $item = Assert-LifeOSTreeItemIdentity -Path $fullName -Expected (New-LifeOSTreeItemIdentity -Item $discoveredItem -Description 'Bounded tree child') -Description 'Bounded tree child'
                $linkType = if ($null -ne $item.PSObject.Properties['LinkType']) { $item.LinkType } else { $null }
                # LinkType is the filesystem provider's type discriminator.
                # Target is a path-like property for redirecting links and is
                # never a valid hardlink type, so it must not be compared as
                # though it were link metadata.
                $unsafeLink = $null -ne $linkType -and [string]$linkType -ne 'HardLink'
                # Reject before emitting or enqueueing the item. A reparse must
                # never become a trusted descendant through a later traversal.
                if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $unsafeLink) {
                    throw "Reparse point found below bounded tree root: $fullName"
                }
                if ($item.PSIsContainer) {
                    $state.Directories = [int]$state.Directories + 1
                    if ($state.Directories -gt $MaxDirectories) { throw 'Bounded tree contains too many directories.' }
                } else {
                    $state.Files = [int]$state.Files + 1
                    if ($state.Files -gt $MaxFiles) { throw 'Bounded tree contains too many files.' }
                    $length = [long]$item.Length
                    $itemMaxBytes = Get-LifeOSBoundedFileMaxBytes -Root $rootFull -Path $fullName -DefaultMaxBytes $MaxFileBytes -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileRelativePaths $LargeFileRelativePaths -LargeFileContracts $LargeFileContracts
                    if ($length -lt 0 -or $length -gt $itemMaxBytes -or $length -gt ($MaxBytes - $state.Bytes)) {
                        throw "Bounded tree exceeds its byte limit: $fullName"
                    }
                    $state.Bytes = $state.Bytes + $length
                }
                if (-not $seenPaths.Add($fullName)) { throw "Bounded tree contains a duplicate path: $fullName" }
                if ($item.PSIsContainer) {
                    [void]$pending.Enqueue([pscustomobject]@{ Path = $fullName; Identity = (New-LifeOSTreeItemIdentity -Item $item -Description 'Bounded tree child directory') })
                }
                Write-Output $item
            }
        } finally {
            if ($null -ne $enumerator) { $enumerator.Dispose() }
        }
        # Directory metadata changes when a child is added, removed, or
        # replaced. Do not certify an inventory assembled across such a race.
        Assert-LifeOSTreeItemIdentity -Path $directory -Expected $queuedDirectory.Identity -Description 'Bounded tree directory' | Out-Null
    }
}

function Get-TreeManifestIndex {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaxFiles = $script:LifeOSRecoveryMaxFileUnits,
        [int]$MaxDirectories = $script:LifeOSRecoveryMaxFileUnits,
        [long]$MaxBytes = $script:LifeOSRecoveryMaxTreeBytes,
        [long]$MaxFileBytes = $script:LifeOSRecoveryMaxFileBytes,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [string[]]$LargeFileRelativePaths = @(),
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    if ($MaxFiles -le 0 -or $MaxDirectories -le 0 -or $MaxBytes -le 0 -or $MaxFileBytes -le 0) {
        throw 'Tree manifest resource bounds are invalid.'
    }
    Assert-ExistingDirectory $Root 'Manifest root'
    $rootFull = Get-FullPath $Root
    $rootComparison = $rootFull.TrimEnd('\')
    $effectiveLargeFileRelativePath = $LargeFileRelativePath
    $effectiveLargeFileMaxBytes = $LargeFileMaxBytes
    $effectiveLargeFileContracts = $LargeFileContracts
    if ($null -ne $LargeFileContracts -and $LargeFileContracts.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($LargeFileRelativePath) -or $LargeFileRelativePaths.Count -gt 0 -or $LargeFileMaxBytes -ne 0) {
            throw 'Large-file contracts must use either the exact contract map or the legacy single-bound arguments.'
        }
    } elseif ([string]::IsNullOrWhiteSpace($effectiveLargeFileRelativePath)) {
        if ($LargeFileMaxBytes -ne 0) { throw 'Large-file byte limit has no relative path.' }
        $effectiveLargeFileRelativePath = Get-LifeOSDefaultLargeFileRelativePath -Root $rootFull
        if (-not [string]::IsNullOrWhiteSpace($effectiveLargeFileRelativePath)) {
            $effectiveLargeFileMaxBytes = $script:LifeOSCandidateNodeMaxFileBytes
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveLargeFileRelativePath)) {
        Assert-LifeOSLargeFileContract -RelativePath $effectiveLargeFileRelativePath -MaxBytes $effectiveLargeFileMaxBytes -DefaultMaxBytes $MaxFileBytes
    }
    $items = New-Object 'System.Collections.Generic.List[object]'
    $byPath = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
    [long]$totalBytes = 0
    Get-LifeOSBoundedTreeItem -Root $rootFull -MaxFiles $MaxFiles -MaxDirectories $MaxDirectories -MaxBytes $MaxBytes -MaxFileBytes $MaxFileBytes -LargeFileRelativePath $effectiveLargeFileRelativePath -LargeFileMaxBytes $effectiveLargeFileMaxBytes -LargeFileRelativePaths $LargeFileRelativePaths -LargeFileContracts $effectiveLargeFileContracts |
        Where-Object { -not $_.PSIsContainer } | ForEach-Object {
        if ($items.Count -ge $MaxFiles) { throw 'Tree manifest contains too many files.' }
        $item = $_
        $linkType = if ($null -ne $item.PSObject.Properties['LinkType']) { $item.LinkType } else { $null }
        # uv-backed Python installs may use hardlinks for ordinary package
        # files. Copy-Item materializes those as regular files; only links
        # that redirect path resolution remain unsafe here.
        $unsafeLink = $null -ne $linkType -and [string]$linkType -ne 'HardLink'
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 -or $unsafeLink) {
            throw "Reparse point found below code/runtime root: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($rootFull.Length).TrimStart('\')
        if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Length -gt $script:LifeOSRecoveryMaxPathLength -or
            $item.FullName.Length -gt $script:LifeOSRecoveryMaxPathLength) {
            throw "Tree manifest path is too long: $($item.FullName)"
        }
        $enumeratedLength = [long]$item.Length
        $itemMaxBytes = Get-LifeOSBoundedFileMaxBytes -Root $rootFull -Path $item.FullName -DefaultMaxBytes $MaxFileBytes -LargeFileRelativePath $effectiveLargeFileRelativePath -LargeFileMaxBytes $effectiveLargeFileMaxBytes -LargeFileRelativePaths $LargeFileRelativePaths -LargeFileContracts $effectiveLargeFileContracts
        if ($enumeratedLength -lt 0 -or $enumeratedLength -gt $itemMaxBytes -or $enumeratedLength -gt $MaxBytes - $totalBytes) {
            throw "Tree manifest exceeds its bounded byte size: $($item.FullName)"
        }
        $itemIdentity = New-LifeOSTreeItemIdentity -Item $item -Description 'Tree manifest item'
        if ($byPath.ContainsKey($relative)) { throw "Tree manifest contains a duplicate path: $relative" }
        try {
            $hashRecord = Get-LifeOSFileDigest -Path $item.FullName -Description 'Tree manifest item' -ExpectedFileId ([string]$itemIdentity.FileId)
            Assert-LifeOSTreeItemIdentity -Path $item.FullName -Expected $itemIdentity -Description 'Tree manifest item' | Out-Null
        } catch {
            throw "Could not hash tree item $($item.FullName): $($_.Exception.Message)"
        }
        if ($null -eq $hashRecord -or [string]$hashRecord.Sha256 -notmatch '^[0-9a-f]{64}$' -or
            [long]$hashRecord.Length -ne $enumeratedLength) {
            throw "Hash operation returned no SHA-256 value for tree item $($item.FullName)."
        }
        $entry = [ordered]@{ path = $relative; sha256 = ([string]$hashRecord.Sha256).ToLowerInvariant(); length = [long]$hashRecord.Length }
        [void]$items.Add($entry)
        $byPath[$relative] = $entry
        $totalBytes += [long]$hashRecord.Length
    }
    $sortedItems = @($items | Sort-Object -Property path)
    return ,([pscustomobject]@{
        Root = $rootFull
        Entries = $sortedItems
        ByPath = $byPath
        FileCount = $items.Count
        TotalBytes = $totalBytes
        LargeFileRelativePath = $effectiveLargeFileRelativePath
        LargeFileMaxBytes = $effectiveLargeFileMaxBytes
        LargeFileRelativePaths = @($LargeFileRelativePaths)
        LargeFileContracts = $effectiveLargeFileContracts
    })
}

function Get-TreeManifest {
    param(
        [Parameter(Mandatory)][string]$Root,
        [int]$MaxFiles = $script:LifeOSRecoveryMaxFileUnits,
        [int]$MaxDirectories = $script:LifeOSRecoveryMaxFileUnits,
        [long]$MaxBytes = $script:LifeOSRecoveryMaxTreeBytes,
        [long]$MaxFileBytes = $script:LifeOSRecoveryMaxFileBytes,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [string[]]$LargeFileRelativePaths = @(),
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    $index = Get-TreeManifestIndex -Root $Root -MaxFiles $MaxFiles -MaxDirectories $MaxDirectories -MaxBytes $MaxBytes -MaxFileBytes $MaxFileBytes -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileRelativePaths $LargeFileRelativePaths -LargeFileContracts $LargeFileContracts
    return @($index.Entries)
}

function Get-LifeOSFileIntegrity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [string]$ExpectedFileId = ''
    )
    $digest = Get-LifeOSFileDigest -Path $Path -Description $Description -ExpectedFileId $ExpectedFileId
    return [ordered]@{
        path = Get-FullPath $Path
        length = [long]$digest.Length
        sha256 = [string]$digest.Sha256
    }
}

function Get-LifeOSTreeIntegrity {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Description,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    Assert-ExistingDirectory $Path $Description
    $index = Get-TreeManifestIndex -Root $Path -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileContracts $LargeFileContracts
    $serialized = $index.Entries | ConvertTo-Json -Depth 8 -Compress
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$serialized)
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $digest = $hasher.ComputeHash($bytes) } finally { $hasher.Dispose() }
    return [ordered]@{
        path = (Get-FullPath $Path).TrimEnd('\')
        fileCount = [int]$index.FileCount
        totalBytes = [long]$index.TotalBytes
        manifestSha256 = ([BitConverter]::ToString($digest) -replace '-', '').ToLowerInvariant()
    }
}

function Get-RecoveryTreeManifestIndex {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Cache,
        [Parameter(Mandatory)][ref]$TotalBytes,
        [switch]$AllowNodeRuntime,
        [string[]]$LargeFileRelativePaths = @(),
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    $rootFull = (Get-FullPath $Root).TrimEnd('\')
    if ($AllowNodeRuntime -and $null -ne $LargeFileContracts -and $LargeFileContracts.Count -gt 0) {
        throw 'Recovery tree index cannot combine the Node runtime switch with an explicit large-file contract map.'
    }
    $largeFileRelativePath = if ($AllowNodeRuntime) { 'node.exe' } else { '' }
    $largeFileMaxBytes = if ($AllowNodeRuntime) { [long]$script:LifeOSCandidateNodeMaxFileBytes } else { [long]0 }
    $largeFilePaths = @($LargeFileRelativePaths | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Sort-Object -Unique)
    $contractKey = if ($null -ne $LargeFileContracts -and $LargeFileContracts.Count -gt 0) {
        @($LargeFileContracts.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f [string]$_, [long]$LargeFileContracts[$_] }) -join ','
    } else { '' }
    $policyKey = if ($AllowNodeRuntime) { 'node-runtime' } elseif ($contractKey) { 'contracts' } else { 'default' }
    $cacheKey = $rootFull + '|policy=' + $policyKey + '|paths=' + ($largeFilePaths -join ',') + '|contracts=' + $contractKey
    if (Test-Path -LiteralPath $rootFull -PathType Container) {
        # A derived child view is still a filesystem authority. Validate its
        # complete path before trusting entries inherited from a cached parent.
        Assert-ExistingDirectory $rootFull 'Recovery tree root'
    }
    if ($Cache.Contains($cacheKey)) { return $Cache[$cacheKey] }

    # A previously indexed parent contains every descendant entry already.
    # Derive a child view from that index instead of walking and hashing the
    # same filesystem subtree again. A request for a parent of a cached child
    # falls through to one bounded scan of the parent.
    foreach ($cachedKey in @($Cache.Keys)) {
        $cachedIndex = $Cache[$cachedKey]
        if ($null -eq $cachedIndex -or $null -eq $cachedIndex.PSObject.Properties['Root']) { continue }
        $cachedContracts = if ($null -ne $cachedIndex.PSObject.Properties['LargeFileContracts']) { $cachedIndex.LargeFileContracts } else { $null }
        $cachedContractKey = if ($null -ne $cachedContracts -and $cachedContracts.Count -gt 0) {
            @($cachedContracts.Keys | Sort-Object | ForEach-Object { '{0}={1}' -f [string]$_, [long]$cachedContracts[$_] }) -join ','
        } else { '' }
        if ([string]$cachedIndex.LargeFileRelativePath -cne $largeFileRelativePath -or
            [long]$cachedIndex.LargeFileMaxBytes -ne $largeFileMaxBytes -or
            ((@($cachedIndex.LargeFileRelativePaths) -join ',') -cne ($largeFilePaths -join ',') -or
            $cachedContractKey -ne $contractKey)) { continue }
        $cachedRoot = ([string]$cachedIndex.Root).TrimEnd('\')
        $cachedPrefix = $cachedRoot + '\'
        if (-not $rootFull.StartsWith($cachedPrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $relativePrefix = $rootFull.Substring($cachedPrefix.Length).TrimEnd('\') + '\'
        $entries = New-Object 'System.Collections.Generic.List[object]'
        $byPath = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($entry in $cachedIndex.Entries) {
            $entryPath = [string]$entry.path
            if (-not $entryPath.StartsWith($relativePrefix, [StringComparison]::OrdinalIgnoreCase)) { continue }
            $childPath = $entryPath.Substring($relativePrefix.Length)
            if ([string]::IsNullOrWhiteSpace($childPath)) { continue }
            $childEntry = [ordered]@{ path = $childPath; sha256 = [string]$entry.sha256; length = [long]$entry.length }
            [void]$entries.Add($childEntry)
            $byPath[$childPath] = $childEntry
        }
        $derived = [pscustomobject]@{
            Root = $rootFull
            Entries = @($entries | Sort-Object -Property path)
            ByPath = $byPath
            FileCount = $entries.Count
            TotalBytes = [long](@($entries | Measure-Object -Property length -Sum).Sum)
            LargeFileRelativePath = $largeFileRelativePath
            LargeFileMaxBytes = $largeFileMaxBytes
            LargeFileRelativePaths = @($largeFilePaths)
            LargeFileContracts = $LargeFileContracts
        }
        $Cache[$cacheKey] = $derived
        return $derived
    }

    $index = Get-TreeManifestIndex -Root $rootFull -MaxFiles $script:LifeOSRecoveryMaxFileUnits -MaxBytes $script:LifeOSRecoveryMaxTreeBytes -MaxFileBytes $script:LifeOSRecoveryMaxFileBytes -LargeFileRelativePath $largeFileRelativePath -LargeFileMaxBytes $largeFileMaxBytes -LargeFileRelativePaths $largeFilePaths -LargeFileContracts $LargeFileContracts
    $TotalBytes.Value += [long]$index.TotalBytes
    if ($TotalBytes.Value -gt $script:LifeOSRecoveryMaxInventoryBytes) {
        throw 'Recovery inventory exceeds its bounded byte size.'
    }
    $Cache[$cacheKey] = $index
    return $index
}

function Compare-TreeManifest {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    if (-not (Test-Path -LiteralPath $Destination -PathType Container)) { return $false }
    if ($null -ne $LargeFileContracts -and $LargeFileContracts.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($LargeFileRelativePath) -or $LargeFileMaxBytes -ne 0) {
            throw 'Large-file contracts must use either the exact contract map or the legacy single-bound arguments.'
        }
        $left = @(Get-TreeManifest $Source -LargeFileContracts $LargeFileContracts | ConvertTo-Json -Depth 8 -Compress)
        $right = @(Get-TreeManifest $Destination -LargeFileContracts $LargeFileContracts | ConvertTo-Json -Depth 8 -Compress)
        return (($left -join '') -eq ($right -join ''))
    }
    $effectiveLargeFileRelativePath = $LargeFileRelativePath
    $effectiveLargeFileMaxBytes = $LargeFileMaxBytes
    if ([string]::IsNullOrWhiteSpace($effectiveLargeFileRelativePath)) {
        if ($LargeFileMaxBytes -ne 0) { throw 'Large-file byte limit has no relative path.' }
        $effectiveLargeFileRelativePath = Get-LifeOSDefaultLargeFileRelativePath -Root $Source
        if (-not [string]::IsNullOrWhiteSpace($effectiveLargeFileRelativePath)) {
            $effectiveLargeFileMaxBytes = $script:LifeOSCandidateNodeMaxFileBytes
        }
    }
    $left = @(Get-TreeManifest $Source -LargeFileRelativePath $effectiveLargeFileRelativePath -LargeFileMaxBytes $effectiveLargeFileMaxBytes | ConvertTo-Json -Depth 8 -Compress)
    $right = @(Get-TreeManifest $Destination -LargeFileRelativePath $effectiveLargeFileRelativePath -LargeFileMaxBytes $effectiveLargeFileMaxBytes | ConvertTo-Json -Depth 8 -Compress)
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
    param(
        [Parameter(Mandatory)][psobject]$Artifact,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [switch]$AllowNodeRuntime,
        [switch]$AllowServiceHostBinary,
        [psobject]$Manifest
    )
    if ($AllowNodeRuntime -and $AllowServiceHostBinary) { throw 'Rollback artifact cannot use two large-file contracts.' }
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
    if ($AllowNodeRuntime -and ($null -eq $Manifest -or -not (Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $destination))) {
        throw 'Node-runtime rollback bound requires an exact manifest-bound destination.'
    }
    if ($AllowServiceHostBinary -and ($null -eq $Manifest -or -not (Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $destination))) {
        throw 'Service-host rollback bound requires an exact manifest-bound destination.'
    }
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
    $largeFileRelativePath = if ($AllowNodeRuntime) { 'node.exe' } else { '' }
    $largeFileMaxBytes = if ($AllowNodeRuntime) { [long]$script:LifeOSCandidateNodeMaxFileBytes } else { [long]0 }
    $backupIsLeaf = Test-Path -LiteralPath $backup -PathType Leaf
    if ($backupIsLeaf) {
        $maxFileBytes = Get-LifeOSRecoveryFileMaxBytes -Path $backup -AllowNodeRuntime:$AllowNodeRuntime -AllowServiceHostBinary:$AllowServiceHostBinary -Manifest $Manifest
        $backupLength = [long](Get-Item -LiteralPath $backup -Force -ErrorAction Stop).Length
        if ($backupLength -lt 0 -or $backupLength -gt $maxFileBytes) {
            throw "Rollback file exceeds its bounded size: $backup"
        }
    } else {
        if ($AllowServiceHostBinary) { throw 'Service-host rollback artifact must be an exact file.' }
        [void](Get-TreeManifest $backup -LargeFileRelativePath $largeFileRelativePath -LargeFileMaxBytes $largeFileMaxBytes)
    }
    $parent = Split-Path -Parent $destination
    Ensure-Directory $parent
    # Never consume the manifest backup. Rollback can be retried after a
    # partial failure, so stage a copy first and keep the original snapshot
    # available for the next attempt.
    $ownedStage = Get-JournalProperty $Artifact 'recoveryStagePath'
    $staged = if ($ownedStage) { [string]$ownedStage } else { Join-Path $parent ('.rollback-restore-' + [Guid]::NewGuid().ToString('N')) }
    try {
        if (Test-Path -LiteralPath $staged) {
            Assert-NoReparsePath $staged
            Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction Stop
        }
        Copy-Item -LiteralPath $backup -Destination $staged -Recurse -Force
        Assert-NoReparsePath $staged
        if ($backupIsLeaf) {
            $stagedLength = [long](Get-Item -LiteralPath $staged -Force -ErrorAction Stop).Length
            if ($stagedLength -lt 0 -or $stagedLength -gt $maxFileBytes) {
                throw "Rollback file exceeds its bounded size: $backup"
            }
            if ((Get-FileSha256 $backup) -ne (Get-FileSha256 $staged)) { throw "Rollback staging hash verification failed: $backup" }
        } elseif (-not (Compare-TreeManifest $backup $staged -LargeFileRelativePath $largeFileRelativePath -LargeFileMaxBytes $largeFileMaxBytes)) {
            throw "Rollback staging manifest verification failed: $backup"
        }
        Move-CurrentOutOfTheWay $destination $BackupDirectory
        Move-Item -LiteralPath $staged -Destination $destination -Force
    } finally {
        if (Test-Path -LiteralPath $staged) { Remove-Item -LiteralPath $staged -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-RecoveryStage {
    param(
        $Manifest,
        [string]$Name,
        [scriptblock]$Action,
        [AllowNull()][scriptblock]$Postcondition = $null,
        [AllowNull()][scriptblock]$LiveAction = $null
    )
    if ([string]::IsNullOrWhiteSpace($Name) -or $Name.Length -gt 128 -or $Name -notmatch '\A[A-Za-z0-9-]+\z') {
        throw 'Recovery stage name is malformed.'
    }
    $path = Get-RecoveryJournalPath $Manifest
    $journal = Read-RecoveryJournal $Manifest
    if ($null -eq $journal) { throw 'Recovery artifacts are not complete.' }
    $stages = Get-JournalProperty $journal 'stages'
    if ($null -eq $stages) { $stages = [pscustomobject]@{}; Set-JournalProperty $journal 'stages' $stages }
    $stageState = Get-JournalProperty $stages $Name
    if ($null -ne $stageState -and [string]$stageState -notin @('restoring', 'complete')) {
        throw "Recovery stage has an invalid state: $Name"
    }
    if ($journal.phase -eq 'completed') {
        if ([string]$stageState -ne 'complete') { throw "Completed recovery stage is not durably complete: $Name" }
        if ($null -ne $LiveAction) { & $LiveAction }
        if ($null -ne $Postcondition) { & $Postcondition }
        return
    }
    if ($journal.phase -ne 'artifacts-complete') { throw 'Recovery artifacts are not complete.' }
    # A completed stage is a durable commit point. Re-running the outer
    # recovery after a process restart must not repeat a destructive action,
    # but its live postcondition still has to be reconciled after a barrier.
    if ([string]$stageState -eq 'complete') {
        if ($null -ne $LiveAction) { & $LiveAction }
        if ($null -ne $Postcondition) { & $Postcondition }
        return
    }
    Set-JournalProperty $stages $Name 'restoring'
    Write-JsonAtomic $path $journal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
    & $Action
    if ($null -ne $Postcondition) { & $Postcondition }
    Set-JournalProperty $stages $Name 'complete'
    Write-JsonAtomic $path $journal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
}

function Restore-LifeOSServiceSnapshots {
    param(
        [Parameter(Mandatory)][object]$Snapshots,
        [Parameter(Mandatory)]$Manifest,
        [switch]$ContinueOnFailure,
        [switch]$VerifyHealth,
        [AllowNull()][scriptblock]$BeforeGatewayStart = $null
    )
    # Validate the complete map before the first SCM mutation. Callers may
    # invoke this helper directly, so relying on rollback.ps1's earlier map
    # validation would leave a partial map with a mutation path.
    $validatedSnapshots = Get-LifeOSServiceSnapshotMap $Snapshots
    $failures = New-Object System.Collections.ArrayList
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
        try {
            Invoke-RecoveryStage $Manifest ('service-' + $serviceName) { Restore-LifeOSServiceSnapshot $validatedSnapshots[$serviceName] -DeferStart }
        } catch {
            if (-not $ContinueOnFailure) { throw }
            [void]$failures.Add($_)
        }
    }
    if ($failures.Count -ne 0) {
        $messages = @($failures | ForEach-Object { [string]$_.Exception.Message })
        throw ('Service configuration recovery failed: ' + ($messages -join '; '))
    }
    # Restore-LifeOSServiceSnapshot always leaves an existing service stopped
    # when DeferStart is used. Only this dependency-ordered reconciliation may
    # start the captured running state. The reconciliation itself is a
    # journaled stage: a failed start/health transition is retried on the next
    # rollback while the marker remains recovery_required.
    Invoke-RecoveryStage $Manifest 'service-state-reconcile' {
        Reconcile-LifeOSServiceSnapshotState -Snapshots $validatedSnapshots -VerifyHealth:$VerifyHealth -BeforeGatewayStart $BeforeGatewayStart
    } -LiveAction {
        Reconcile-LifeOSServiceSnapshotState -Snapshots $validatedSnapshots -VerifyHealth:$VerifyHealth -BeforeGatewayStart $BeforeGatewayStart
    } -Postcondition {
        Assert-LifeOSServiceSnapshotState -Snapshots $validatedSnapshots -VerifyHealth:$VerifyHealth
    }
}

function Get-RecoveryJournalPath {
    param($Manifest)
    return (Join-Path $Manifest.paths.backupDirectory 'recovery.json')
}

function Get-RecoveryProgressPath {
    param($Manifest)
    return (Join-Path $Manifest.paths.backupDirectory 'recovery.progress.jsonl')
}

function Assert-RecoveryProgressPath {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Manifest)
    $expected = Get-FullPath (Get-RecoveryProgressPath $Manifest)
    if ((Get-FullPath $Path) -cne $expected) { throw 'Recovery progress path is not transaction-owned.' }
    if ($Path.Length -gt 4096) { throw 'Recovery progress path is too long.' }
}

function Test-LifeOSIntegralNumber {
    param($Value)
    return $Value -is [byte] -or $Value -is [sbyte] -or
        $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or
        $Value -is [int64] -or $Value -is [uint64]
}

function Get-LifeOSProgressFieldNames {
    param([Parameter(Mandatory)]$Object)
    if ($Object -is [System.Collections.IDictionary]) {
        return @($Object.Keys | ForEach-Object { [string]$_ })
    }
    return @($Object.PSObject.Properties | ForEach-Object { [string]$_.Name })
}

function Assert-RecoveryProgressRecord {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)][int]$UnitCount,
        [long]$ExpectedSequence = -1
    )
    if ($UnitCount -le 0 -or $UnitCount -gt $script:LifeOSRecoveryMaxFileUnits) {
        throw 'Recovery progress unit count is out of bounds.'
    }
    $isObjectRecord = $Record -is [psobject] -or $Record -is [System.Collections.IDictionary]
    if ($null -eq $Record -or $Record -is [string] -or -not $isObjectRecord) {
        throw 'Recovery progress record is not a JSON object.'
    }
    $expectedFields = @('sequence', 'transactionId', 'generation', 'operatorSid', 'manifestPath', 'unitIndex', 'phase')
    $actualFields = @(Get-LifeOSProgressFieldNames $Record)
    $fieldSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($field in $actualFields) { [void]$fieldSet.Add($field) }
    if ($fieldSet.Count -ne $expectedFields.Count -or
        @($expectedFields | Where-Object { -not $fieldSet.Contains($_) }).Count -ne 0) {
        throw 'Recovery progress record schema is invalid.'
    }
    $recordSequence = Get-JournalProperty $Record 'sequence'
    $recordIndex = Get-JournalProperty $Record 'unitIndex'
    if (-not (Test-LifeOSIntegralNumber $recordSequence) -or
        (-not (Test-LifeOSIntegralNumber $recordIndex))) {
        throw 'Recovery progress record ordering or state is invalid.'
    }
    $sequence = [long]$recordSequence
    $index = [long]$recordIndex
    if ($sequence -lt 0 -or $sequence -ge $script:LifeOSRecoveryProgressMaxRecords -or
        ($ExpectedSequence -ge 0 -and $sequence -ne $ExpectedSequence) -or
        $index -lt 0 -or $index -ge $UnitCount) {
        throw 'Recovery progress record ordering or state is invalid.'
    }
    $phase = Get-JournalProperty $Record 'phase'
    if ($phase -isnot [string] -or [string]$phase -notin @('restoring', 'complete')) {
        throw 'Recovery progress record ordering or state is invalid.'
    }
    foreach ($identity in @('transactionId', 'generation', 'operatorSid', 'manifestPath')) {
        $value = Get-JournalProperty $Record $identity
        if ($value -isnot [string]) { throw 'Recovery progress record identity is invalid.' }
        $expectedIdentity = Get-JournalProperty $Manifest $identity
        if ($expectedIdentity -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value) -or
            $value.Length -gt 4096 -or [string]$value -cne [string]$expectedIdentity) {
            throw 'Recovery progress record identity is invalid.'
        }
    }
}

function New-RecoveryProgressDigestInput {
    param(
        [Parameter(Mandatory)][byte[]]$Header,
        [Parameter(Mandatory)][byte[]]$Payload
    )
    # Every frame has the exact byte layout
    # [header][header-digest][payload][record-digest][commit]. The record
    # digest covers only [header][payload]; keeping that construction in one
    # helper prevents the writer and reader from hashing different slices.
    $input = New-Object byte[] ($Header.Length + $Payload.Length)
    [Array]::Copy($Header, 0, $input, 0, $Header.Length)
    [Array]::Copy($Payload, 0, $input, $Header.Length, $Payload.Length)
    return ,$input
}

function New-RecoveryProgressFrame {
    param([Parameter(Mandatory)]$Record)
    if (-not [BitConverter]::IsLittleEndian) { throw 'Recovery progress framing requires little-endian byte order.' }
    $json = $Record | ConvertTo-Json -Depth 5 -Compress
    $payload = [Text.UTF8Encoding]::new($false).GetBytes([string]$json)
    if ($payload.Length -le 0 -or $payload.Length -gt $script:LifeOSRecoveryProgressMaxRecordBytes) {
        throw 'Recovery progress record is too large.'
    }
    $header = New-Object byte[] $script:LifeOSRecoveryProgressHeaderBytes
    [Array]::Copy($script:LifeOSRecoveryProgressMagic, 0, $header, 0, $script:LifeOSRecoveryProgressMagic.Length)
    $header[4] = $script:LifeOSRecoveryProgressVersion
    [Array]::Copy([BitConverter]::GetBytes([int]$payload.Length), 0, $header, 5, 4)
    $headerDigest = [Security.Cryptography.SHA256]::Create()
    try { $headerHash = $headerDigest.ComputeHash($header) } finally { $headerDigest.Dispose() }
    $content = New-RecoveryProgressDigestInput -Header $header -Payload $payload
    $digest = [Security.Cryptography.SHA256]::Create()
    try { $hash = $digest.ComputeHash($content) } finally { $digest.Dispose() }
    return [pscustomobject]@{
        Header = $header
        HeaderDigest = $headerHash
        Payload = $payload
        Digest = $hash
        Commit = [byte[]]@($script:LifeOSRecoveryProgressCommitMarker)
        TotalBytes = [long]$header.Length + $headerHash.Length + $payload.Length + $hash.Length + 1
    }
}

function New-RecoveryProgressRecord {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][int]$UnitIndex,
        [Parameter(Mandatory)][ValidateSet('restoring', 'complete')][string]$Phase,
        [Parameter(Mandatory)][long]$Sequence,
        [Parameter(Mandatory)][int]$UnitCount
    )
    $record = [ordered]@{
        sequence = $Sequence
        transactionId = [string](Get-JournalProperty $Journal 'transactionId')
        generation = [string](Get-JournalProperty $Journal 'generation')
        operatorSid = [string](Get-JournalProperty $Journal 'operatorSid')
        manifestPath = [string](Get-JournalProperty $Journal 'manifestPath')
        unitIndex = $UnitIndex
        phase = $Phase
    }
    Assert-RecoveryProgressRecord -Record $record -Manifest $Manifest -UnitCount $UnitCount -ExpectedSequence $Sequence
    return ,$record
}

function Get-RecoveryProgressUnit {
    param([Parameter(Mandatory)]$Units, [Parameter(Mandatory)][int]$UnitIndex)
    if ($Units -is [System.Collections.IDictionary]) {
        if ($UnitIndex -ne 0) { return $null }
        return ,$Units
    }
    if ($Units -is [System.Collections.IEnumerable] -and $Units -isnot [string]) {
        return ,($Units[$UnitIndex])
    }
    if ($UnitIndex -eq 0 -and $Units -is [System.Management.Automation.PSCustomObject]) { return ,$Units }
    return $null
}

function Get-RecoveryJournalUnits {
    param([Parameter(Mandatory)]$Journal)
    # Read the owned collection value directly. Calling a pipeline-producing
    # property accessor here would materialize every unit for each append.
    if ($Journal -is [System.Collections.IDictionary]) {
        if ($Journal.Contains('units')) { return ,$Journal['units'] }
    } elseif ($null -ne $Journal) {
        $property = $Journal.PSObject.Properties['units']
        if ($null -ne $property) { return ,$property.Value }
    }
    return $null
}

function Write-RecoveryProgressFramePart {
    param(
        [Parameter(Mandatory)][IO.FileStream]$Stream,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][ValidateSet('header', 'header-digest', 'payload', 'digest', 'commit')][string]$Boundary
    )
    if ($Bytes.Length -eq 0) { throw "Recovery progress $Boundary frame part is empty." }
    $Stream.Write($Bytes, 0, $Bytes.Length)
    $Stream.Flush($true)
}

function Read-RecoveryProgress {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][object[]]$JournalUnits
    )
    $progressPathValue = Get-JournalProperty $Journal 'progressPath'
    $progressPath = if ($null -eq $progressPathValue) {
        Get-RecoveryProgressPath $Manifest
    } else {
        if ($progressPathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$progressPathValue)) {
            throw 'Recovery progress path is malformed.'
        }
        [string]$progressPathValue
    }
    Assert-RecoveryProgressPath $progressPath $Manifest
    Set-JournalProperty $Journal 'progressPath' (Get-FullPath $progressPath)
    if (-not (Test-Path -LiteralPath $progressPath)) {
        Set-JournalProperty $Journal 'progressSequence' 0
        return
    }
    Assert-ExistingFile $progressPath 'Recovery progress log'
    Assert-NoReparsePath $progressPath
    try {
        Assert-RestrictedAcl $progressPath $Manifest.operatorSid @() @() -AllowInherited
    } catch {
        # A pre-fix recovery attempt could have created this transaction-owned
        # log with the parent ACL (the observed failure was an admin-only ACL
        # with no SYSTEM/operator entries). Repair only when the current owner
        # and every explicit allow identity are already within the management
        # boundary; any broad or unknown grant remains fail-closed.
        $currentAcl = Get-Acl -LiteralPath $progressPath -ErrorAction Stop
        $allowedRecoverySids = @([string]$Manifest.operatorSid, 'S-1-5-18', 'S-1-5-32-544')
        $currentOwner = $currentAcl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($currentOwner -notin $allowedRecoverySids) { throw }
        foreach ($accessRule in @($currentAcl.Access)) {
            if ($accessRule.AccessControlType -ne 'Allow') { continue }
            try { $accessSid = $accessRule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { throw }
            if ($accessSid -notin $allowedRecoverySids) { throw }
        }
        Set-RestrictedAcl -Path $progressPath -OperatorSid $Manifest.operatorSid -ReadSids @() -ModifySids @() -File -SkipSnapshot
        Assert-RestrictedAcl $progressPath $Manifest.operatorSid @() @() -AllowInherited
    }
    $progressItem = Get-Item -LiteralPath $progressPath -Force -ErrorAction Stop
    if ($progressItem.PSIsContainer -or [long]$progressItem.Length -gt $script:LifeOSRecoveryProgressMaxBytes) {
        throw 'Recovery progress log exceeds its bounded parse size.'
    }
    if (-not [BitConverter]::IsLittleEndian) { throw 'Recovery progress framing requires little-endian byte order.' }
    $buffer = New-Object byte[] ([int]$progressItem.Length)
    $stream = [IO.File]::Open($progressPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $read = 0
        while ($read -lt $buffer.Length) {
            $chunk = $stream.Read($buffer, $read, $buffer.Length - $read)
            if ($chunk -le 0) { throw 'Recovery progress log changed while it was being read.' }
            $read += $chunk
        }
        if ([long]$stream.Length -ne [long]$buffer.Length) { throw 'Recovery progress log changed while it was being read.' }
    } finally { $stream.Dispose() }

    $sequence = [long]0
    $offset = [long]0
    $committedOffset = [long]0
    $incompleteTail = $false
    while ($offset -lt $buffer.Length) {
        $remaining = [long]$buffer.Length - $offset
        if ($remaining -lt $script:LifeOSRecoveryProgressHeaderBytes) {
            $magicBytesAvailable = [Math]::Min([int]$remaining, [int]$script:LifeOSRecoveryProgressMagic.Length)
            for ($prefixIndex = 0; $prefixIndex -lt $magicBytesAvailable; $prefixIndex++) {
                if ($buffer[[int]$offset + $prefixIndex] -ne $script:LifeOSRecoveryProgressMagic[$prefixIndex]) {
                    throw 'Recovery progress log contains a corrupt non-frame tail.'
                }
            }
            if ($remaining -gt $script:LifeOSRecoveryProgressMagic.Length -and
                $buffer[[int]$offset + $script:LifeOSRecoveryProgressMagic.Length] -ne $script:LifeOSRecoveryProgressVersion) {
                throw 'Recovery progress log contains a corrupt non-frame tail.'
            }
            $incompleteTail = $true
            break
        }
        $magicMatches = $true
        for ($magicIndex = 0; $magicIndex -lt $script:LifeOSRecoveryProgressMagic.Length; $magicIndex++) {
            if ($buffer[[int]$offset + $magicIndex] -ne $script:LifeOSRecoveryProgressMagic[$magicIndex]) { $magicMatches = $false; break }
        }
        if (-not $magicMatches) { throw 'Recovery progress log contains corruption before its tail.' }
        $version = $buffer[[int]$offset + 4]
        $payloadLength = [BitConverter]::ToInt32($buffer, [int]$offset + 5)
        if ($version -ne $script:LifeOSRecoveryProgressVersion -or
            $payloadLength -le 0 -or $payloadLength -gt $script:LifeOSRecoveryProgressMaxRecordBytes) {
            throw 'Recovery progress frame header is corrupt.'
        }
        $header = New-Object byte[] $script:LifeOSRecoveryProgressHeaderBytes
        [Array]::Copy($buffer, [int]$offset, $header, 0, $header.Length)
        $expectedHeaderDigest = [Security.Cryptography.SHA256]::Create()
        try { $headerHash = $expectedHeaderDigest.ComputeHash($header) } finally { $expectedHeaderDigest.Dispose() }
        $headerDigestAvailable = $remaining - $script:LifeOSRecoveryProgressHeaderBytes
        if ($headerDigestAvailable -lt $script:LifeOSRecoveryProgressHeaderDigestBytes) {
            for ($headerDigestIndex = 0; $headerDigestIndex -lt $headerDigestAvailable; $headerDigestIndex++) {
                if ($buffer[[int]$offset + $script:LifeOSRecoveryProgressHeaderBytes + $headerDigestIndex] -ne $headerHash[$headerDigestIndex]) {
                    throw 'Recovery progress frame header digest is corrupt.'
                }
            }
            $incompleteTail = $true
            break
        }
        for ($headerDigestIndex = 0; $headerDigestIndex -lt $script:LifeOSRecoveryProgressHeaderDigestBytes; $headerDigestIndex++) {
            if ($buffer[[int]$offset + $script:LifeOSRecoveryProgressHeaderBytes + $headerDigestIndex] -ne $headerHash[$headerDigestIndex]) {
                throw 'Recovery progress frame header digest is corrupt.'
            }
        }
        $frameBytes = [long]$script:LifeOSRecoveryProgressFrameHeaderBytes + $payloadLength + $script:LifeOSRecoveryProgressTrailerBytes
        if ($frameBytes -gt $remaining) {
            $incompleteTail = $true
            break
        }
        $commitOffset = [int]($offset + $frameBytes - 1)
        if ($buffer[$commitOffset] -ne $script:LifeOSRecoveryProgressCommitMarker) {
            throw 'Recovery progress committed frame marker is corrupt.'
        }
        $payload = New-Object byte[] $payloadLength
        [Array]::Copy($buffer, [int]$offset + $script:LifeOSRecoveryProgressFrameHeaderBytes, $payload, 0, $payloadLength)
        $storedDigest = New-Object byte[] $script:LifeOSRecoveryProgressDigestBytes
        [Array]::Copy($buffer, [int]$offset + $script:LifeOSRecoveryProgressFrameHeaderBytes + $payloadLength, $storedDigest, 0, $script:LifeOSRecoveryProgressDigestBytes)
        $content = New-RecoveryProgressDigestInput -Header $header -Payload $payload
        $digest = [Security.Cryptography.SHA256]::Create()
        try { $actualDigest = $digest.ComputeHash($content) } finally { $digest.Dispose() }
        $digestMatches = $true
        for ($digestIndex = 0; $digestIndex -lt $script:LifeOSRecoveryProgressDigestBytes; $digestIndex++) {
            if ($storedDigest[$digestIndex] -ne $actualDigest[$digestIndex]) { $digestMatches = $false; break }
        }
        if (-not $digestMatches) { throw 'Recovery progress committed record digest is invalid.' }
        $record = ([Text.UTF8Encoding]::new($false, $true).GetString($payload)) | ConvertFrom-Json -ErrorAction Stop
        Assert-RecoveryProgressRecord -Record $record -Manifest $Manifest -UnitCount $JournalUnits.Count -ExpectedSequence $sequence
        $progressUnit = $JournalUnits[[int](Get-JournalProperty $record 'unitIndex')]
        Set-JournalProperty $progressUnit 'phase' ([string](Get-JournalProperty $record 'phase'))
        $sequence++
        $offset += $frameBytes
        $committedOffset = $offset
        if ($sequence -gt $script:LifeOSRecoveryProgressMaxRecords) { throw 'Recovery progress log contains too many records.' }
    }
    if ($incompleteTail) {
        $truncate = [IO.File]::Open($progressPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        try {
            $truncate.SetLength($committedOffset)
            $truncate.Flush($true)
        } finally { $truncate.Dispose() }
        Assert-NoReparsePath $progressPath
    }
    Set-JournalProperty $Journal 'progressSequence' $sequence
}

function Append-RecoveryProgress {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][int]$UnitIndex,
        [Parameter(Mandatory)][ValidateSet('restoring', 'complete')][string]$Phase
    )
    $unitsValue = Get-RecoveryJournalUnits $Journal
    if ($null -eq $unitsValue) { throw 'Recovery progress journal units are missing.' }
    $unitCountValue = Get-JournalProperty $Journal 'unitCount'
    if ($null -eq $unitCountValue) {
        $unitCount = if ($unitsValue -is [System.Collections.IEnumerable] -and $unitsValue -isnot [string]) {
            [int]$unitsValue.Count
        } elseif ($unitsValue -is [System.Management.Automation.PSCustomObject] -or
            $unitsValue -is [System.Collections.IDictionary]) { 1 } else { throw 'Recovery progress journal units are malformed.' }
        Set-JournalProperty $Journal 'unitCount' $unitCount
    } elseif (Test-LifeOSIntegralNumber $unitCountValue) {
        $unitCount = [int]$unitCountValue
    } else { throw 'Recovery progress journal unit count is malformed.' }
    if ($unitCount -le 0 -or $unitCount -gt $script:LifeOSRecoveryMaxFileUnits -or
        $UnitIndex -lt 0 -or $UnitIndex -ge $unitCount) { throw 'Recovery progress unit index is out of bounds.' }
    $unit = Get-RecoveryProgressUnit -Units $unitsValue -UnitIndex $UnitIndex
    if ($null -eq $unit) { throw 'Recovery progress unit index is out of bounds.' }
    $currentPhase = Get-JournalProperty $unit 'phase'
    if ($currentPhase -is [string] -and [string]$currentPhase -ceq $Phase) { return $false }
    $progressPathValue = Get-JournalProperty $Journal 'progressPath'
    $progressPath = if ($null -eq $progressPathValue) { Get-RecoveryProgressPath $Manifest } else { [string]$progressPathValue }
    Assert-RecoveryProgressPath $progressPath $Manifest
    $sequenceValue = Get-JournalProperty $Journal 'progressSequence'
    $sequence = if ($null -eq $sequenceValue) { [long]0 } elseif (Test-LifeOSIntegralNumber $sequenceValue) { [long]$sequenceValue } else { throw 'Recovery progress sequence is malformed.' }
    if ($sequence -lt 0 -or $sequence -ge $script:LifeOSRecoveryProgressMaxRecords) { throw 'Recovery progress log contains too many records.' }
    $record = New-RecoveryProgressRecord -Manifest $Manifest -Journal $Journal -UnitIndex $UnitIndex -Phase $Phase -Sequence $sequence -UnitCount $unitCount
    $frame = New-RecoveryProgressFrame $record
    Ensure-Directory (Split-Path -Parent $progressPath)
    Assert-NoReparsePath $progressPath -AllowMissingLeaf
    if (-not (Test-Path -LiteralPath $progressPath)) {
        # A newly-created progress log starts with the same protected DACL as
        # every other recovery artifact before any bytes are appended. This
        # avoids validating the inherited default ACL and then writing through
        # it during the recovery boundary.
        $progressStream = $null
        try {
            $progressStream = [IO.File]::Open($progressPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        } finally {
            if ($null -ne $progressStream) { $progressStream.Dispose() }
        }
        Assert-NoReparsePath $progressPath
        Set-RestrictedAcl -Path $progressPath -OperatorSid $Manifest.operatorSid -ReadSids @() -ModifySids @() -File -SkipSnapshot
    }
    Assert-ExistingFile $progressPath 'Recovery progress log'
    Assert-NoReparsePath $progressPath
    Assert-RestrictedAcl $progressPath $Manifest.operatorSid @() @() -AllowInherited
    $item = Get-Item -LiteralPath $progressPath -Force -ErrorAction Stop
    if ([long]$item.Length + $frame.TotalBytes -gt $script:LifeOSRecoveryProgressMaxBytes) {
        throw 'Recovery progress log exceeds its bounded write size.'
    }
    $stream = [IO.File]::Open($progressPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try {
        Write-RecoveryProgressFramePart -Stream $stream -Bytes $frame.Header -Boundary 'header'
        Write-RecoveryProgressFramePart -Stream $stream -Bytes $frame.HeaderDigest -Boundary 'header-digest'
        Write-RecoveryProgressFramePart -Stream $stream -Bytes $frame.Payload -Boundary 'payload'
        Write-RecoveryProgressFramePart -Stream $stream -Bytes $frame.Digest -Boundary 'digest'
        Write-RecoveryProgressFramePart -Stream $stream -Bytes $frame.Commit -Boundary 'commit'
    } finally { $stream.Dispose() }
    Assert-NoReparsePath $progressPath
    Set-JournalProperty $unit 'phase' $Phase
    Set-JournalProperty $Journal 'progressPath' (Get-FullPath $progressPath)
    Set-JournalProperty $Journal 'progressSequence' ($sequence + 1)
    return $true
}

function Assert-RecoveryProgressCapacity {
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$Journal)
    $unitsValue = Get-RecoveryJournalUnits $Journal
    $unitCountValue = Get-JournalProperty $Journal 'unitCount'
    if ($null -eq $unitsValue -or -not (Test-LifeOSIntegralNumber $unitCountValue)) {
        throw 'Recovery progress journal inventory is malformed.'
    }
    $unitCount = [int]$unitCountValue
    if ($unitCount -le 0 -or $unitCount -gt $script:LifeOSRecoveryMaxFileUnits) {
        throw 'Recovery progress unit count is out of bounds.'
    }
    $sequenceValue = Get-JournalProperty $Journal 'progressSequence'
    $sequence = if ($null -eq $sequenceValue) { [long]0 } elseif (Test-LifeOSIntegralNumber $sequenceValue) { [long]$sequenceValue } else { throw 'Recovery progress sequence is malformed.' }
    if ($sequence -lt 0 -or $sequence -gt $script:LifeOSRecoveryProgressMaxRecords) {
        throw 'Recovery progress log contains too many records.'
    }
    $progressPathValue = Get-JournalProperty $Journal 'progressPath'
    $progressPath = if ($null -eq $progressPathValue) { Get-RecoveryProgressPath $Manifest } else {
        if ($progressPathValue -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$progressPathValue)) { throw 'Recovery progress path is malformed.' }
        [string]$progressPathValue
    }
    Assert-RecoveryProgressPath $progressPath $Manifest
    [long]$requiredBytes = 0
    if (Test-Path -LiteralPath $progressPath) {
        Assert-ExistingFile $progressPath 'Recovery progress log'
        Assert-NoReparsePath $progressPath
        Assert-RestrictedAcl $progressPath $Manifest.operatorSid @() @() -AllowInherited
        $progressItem = Get-Item -LiteralPath $progressPath -Force -ErrorAction Stop
        if ($progressItem.PSIsContainer -or [long]$progressItem.Length -gt $script:LifeOSRecoveryProgressMaxBytes) {
            throw 'Recovery progress log exceeds its bounded write size.'
        }
        $requiredBytes = [long]$progressItem.Length
    }
    for ($index = 0; $index -lt $unitCount; $index++) {
        $unit = Get-RecoveryProgressUnit -Units $unitsValue -UnitIndex $index
        if ($null -eq $unit) { throw 'Recovery progress unit index is out of bounds.' }
        $unitDestination = [string](Get-JournalProperty $unit 'destination')
        $allowNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $unitDestination
        $allowServiceHostBinary = Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $unitDestination
        $current = Get-RecoveryArtifactState $unitDestination -AllowNodeRuntime:$allowNodeRuntime -AllowServiceHostBinary:$allowServiceHostBinary -Manifest $Manifest
        Assert-RecoveryUnitState $unit $current
        $phases = @()
        $currentPhase = [string](Get-JournalProperty $unit 'phase')
        if ($current -eq [string](Get-JournalProperty $unit 'post')) {
            if ($currentPhase -cne 'complete') { $phases = @('complete') }
        } elseif ($currentPhase -ceq 'pending') {
            $phases = @('restoring', 'complete')
        } elseif ($currentPhase -ceq 'restoring') {
            $phases = @('complete')
        } else {
            throw 'Recovery progress unit phase is invalid for its current state.'
        }
        foreach ($phase in $phases) {
            if ($sequence -ge $script:LifeOSRecoveryProgressMaxRecords) { throw 'Recovery progress log contains too many records.' }
            $record = New-RecoveryProgressRecord -Manifest $Manifest -Journal $Journal -UnitIndex $index -Phase $phase -Sequence $sequence -UnitCount $unitCount
            $frame = New-RecoveryProgressFrame $record
            $requiredBytes += [long]$frame.TotalBytes
            if ($requiredBytes -gt $script:LifeOSRecoveryProgressMaxBytes) {
                throw 'Recovery progress log exceeds its bounded write size.'
            }
            $sequence++
        }
    }
    return [pscustomobject]@{ FinalSequence = $sequence; ProgressBytes = $requiredBytes }
}

function Assert-RecoveryJournalCheckpointCapacity {
    param(
        [Parameter(Mandatory)]$Manifest,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)][long]$FinalProgressSequence
    )
    if ($FinalProgressSequence -lt 0 -or $FinalProgressSequence -gt $script:LifeOSRecoveryProgressMaxRecords) {
        throw 'Recovery journal progress sequence is out of bounds.'
    }
    # Measure every journal shape that can be published after this point
    # before any artifact mutation. Restoring checkpoints are longer than
    # pending checkpoints, and stage/writer terminal metadata is added later.
    # Each candidate uses the same serializer and UTF-8 byte count as
    # Write-JsonAtomic, while cloning keeps this preflight side-effect free.
    $maximumBytes = [long]0
    $initialCheckpoint = ($Journal | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json -ErrorAction Stop
    $initialBytes = Get-LifeOSJsonSerializedByteCount $initialCheckpoint
    if ($initialBytes -gt $maximumBytes) { $maximumBytes = $initialBytes }

    $restoringCheckpoint = ($Journal | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json -ErrorAction Stop
    Set-JournalProperty $restoringCheckpoint 'progressSequence' $FinalProgressSequence
    $restoringUnits = Get-RecoveryJournalUnits $restoringCheckpoint
    if ($null -eq $restoringUnits) { throw 'Recovery journal restoring checkpoint inventory is malformed.' }
    $restoringUnitValues = if ($restoringUnits -is [System.Collections.IEnumerable] -and $restoringUnits -isnot [string]) {
        @($restoringUnits)
    } elseif ($restoringUnits -is [System.Management.Automation.PSCustomObject] -or
        $restoringUnits -is [System.Collections.IDictionary]) {
        @($restoringUnits)
    } else { throw 'Recovery journal restoring checkpoint inventory is malformed.' }
    foreach ($restoringUnit in $restoringUnitValues) { Set-JournalProperty $restoringUnit 'phase' 'restoring' }
    $restoringBytes = Get-LifeOSJsonSerializedByteCount $restoringCheckpoint
    if ($restoringBytes -gt $maximumBytes) { $maximumBytes = $restoringBytes }

    $terminalCheckpoint = ($Journal | ConvertTo-Json -Depth 20 -Compress) | ConvertFrom-Json -ErrorAction Stop
    Set-JournalProperty $terminalCheckpoint 'phase' 'artifacts-complete'
    Set-JournalProperty $terminalCheckpoint 'progressSequence' $FinalProgressSequence
    $checkpointUnits = Get-RecoveryJournalUnits $terminalCheckpoint
    if ($null -eq $checkpointUnits) { throw 'Recovery journal checkpoint inventory is malformed.' }
    $checkpointUnitValues = if ($checkpointUnits -is [System.Collections.IEnumerable] -and $checkpointUnits -isnot [string]) {
        @($checkpointUnits)
    } elseif ($checkpointUnits -is [System.Management.Automation.PSCustomObject] -or
        $checkpointUnits -is [System.Collections.IDictionary]) {
        @($checkpointUnits)
    } else { throw 'Recovery journal checkpoint inventory is malformed.' }
    foreach ($checkpointUnit in $checkpointUnitValues) { Set-JournalProperty $checkpointUnit 'phase' 'complete' }
    $terminalBytes = Get-LifeOSJsonSerializedByteCount $terminalCheckpoint
    if ($terminalBytes -gt $maximumBytes) { $maximumBytes = $terminalBytes }

    # A stage is published first as restoring and then as complete. Measure
    # both states for each stage and include the writer-release boundary.
    Set-JournalProperty $terminalCheckpoint 'writersReleased' $true
    $stageValues = [ordered]@{}
    Set-JournalProperty $terminalCheckpoint 'stages' ([pscustomobject]$stageValues)
    $writerBoundaryBytes = Get-LifeOSJsonSerializedByteCount $terminalCheckpoint
    if ($writerBoundaryBytes -gt $maximumBytes) { $maximumBytes = $writerBoundaryBytes }
    foreach ($stageName in $script:LifeOSRecoveryStageNames) {
        $stageValues[$stageName] = 'restoring'
        Set-JournalProperty $terminalCheckpoint 'stages' ([pscustomobject]$stageValues)
        $restoringBytes = Get-LifeOSJsonSerializedByteCount $terminalCheckpoint
        if ($restoringBytes -gt $maximumBytes) { $maximumBytes = $restoringBytes }
        $stageValues[$stageName] = 'complete'
        Set-JournalProperty $terminalCheckpoint 'stages' ([pscustomobject]$stageValues)
        $completeBytes = Get-LifeOSJsonSerializedByteCount $terminalCheckpoint
        if ($completeBytes -gt $maximumBytes) { $maximumBytes = $completeBytes }
    }
    if ($maximumBytes -gt $script:LifeOSRecoveryJournalMaxBytes) {
        throw 'Recovery journal checkpoint exceeds its bounded serialized size.'
    }
    return [long]$maximumBytes
}

function Test-RecoveryAuthorityPath {
    param($Manifest, [string]$Path)
    $full = Get-FullPath $Path
    $gateway = (Get-FullPath $Manifest.paths.gatewayData).TrimEnd('\')
    return $full -eq (Get-FullPath $Manifest.paths.usageHistory) -or $full -eq $gateway -or
        $full.StartsWith($gateway + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Assert-RecoveryInventoryBounds {
    param(
        [AllowNull()][object]$TreeRoots,
        [AllowNull()][object]$FileUnits,
        [AllowNull()][object]$ManifestBackups
    )
    $rootValues = @()
    $unitValues = @()
    $backupValues = @()
    if ($null -ne $TreeRoots) { $rootValues = @($TreeRoots) }
    if ($null -ne $FileUnits) { $unitValues = @($FileUnits) }
    if ($null -ne $ManifestBackups) { $backupValues = @($ManifestBackups) }
    if ($rootValues.Count -gt $script:LifeOSRecoveryMaxTreeRoots) {
        throw 'Recovery inventory contains too many tree roots.'
    }
    if ($unitValues.Count -gt $script:LifeOSRecoveryMaxFileUnits) {
        throw 'Recovery inventory contains too many file units.'
    }
    if ($backupValues.Count -gt $script:LifeOSRecoveryMaxTreeRoots) {
        throw 'Recovery manifest contains too many artifact roots.'
    }
    foreach ($root in $rootValues) {
        if ($root -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$root) -or
            ([string]$root).Length -gt $script:LifeOSRecoveryMaxPathLength) {
            throw 'Recovery inventory contains an invalid tree-root path.'
        }
    }
    foreach ($unit in $unitValues) {
        if ($null -eq $unit) { throw 'Recovery inventory contains a null file unit.' }
        $destination = Get-JournalProperty $unit 'destination'
        if ($destination -is [string] -and $destination.Length -gt $script:LifeOSRecoveryMaxPathLength) {
            throw 'Recovery inventory contains an oversized destination path.'
        }
    }
}

function Get-RecoveryCanonicalTreeRoots {
    param([Parameter(Mandatory)][object[]]$Roots)
    Assert-RecoveryInventoryBounds -TreeRoots $Roots -FileUnits @() -ManifestBackups @()
    $unique = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $Roots) {
        $normalized = (Get-FullPath ([string]$root)).TrimEnd('\')
        [void]$unique.Add($normalized)
    }
    # Sort parents before descendants so overlapping roots are indexed once.
    $ordered = @($unique | Sort-Object @{ Expression = { $_.Length }; Ascending = $true }, @{ Expression = { $_ }; Ascending = $true })
    $canonical = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in $ordered) {
        $covered = $false
        foreach ($parent in $canonical) {
            if ($candidate -eq $parent -or $candidate.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $covered = $true
                break
            }
        }
        if (-not $covered) { [void]$canonical.Add($candidate) }
    }
    return $canonical.ToArray()
}

function Enable-RecoveryWriterRestoration {
    param($Manifest)
    $journal = Read-RecoveryJournal $Manifest
    if ($null -eq $journal -or $journal.phase -notin @('artifacts-complete', 'completed')) { throw 'Cannot release writers before artifact restoration.' }
    if ((Get-JournalProperty $journal 'writersReleased') -eq $true) { return }
    # After this durable boundary no recovery attempt may restore authority
    # files again. Prior writers can acknowledge new observations immediately.
    Set-JournalProperty $journal 'writersReleased' $true
    Write-JsonAtomic (Get-RecoveryJournalPath $Manifest) $journal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
}

function Complete-LifeOSRecoveryState {
    param([Parameter(Mandatory)][psobject]$Manifest)
    $journalPath = Get-RecoveryJournalPath $Manifest
    $journal = Read-RecoveryJournal $Manifest
    if ($null -eq $journal) { throw 'Verified recovery has no durable recovery journal.' }
    $archivePath = Join-Path $Manifest.paths.backupDirectory ('recovery.completed.' + [string]$Manifest.transactionId + '.json')
    Assert-SafeAbsolutePath $archivePath 'Completed recovery archive'
    if ($journal.phase -eq 'completed') {
        Assert-ExistingFile $archivePath 'Completed recovery archive'
        Assert-RestrictedAcl $archivePath $Manifest.operatorSid @() @() -AllowInherited
        $archived = Read-LifeOSBoundedJsonFile -Path $archivePath -MaxBytes $script:LifeOSRecoveryJournalMaxBytes -Description 'Completed recovery archive'
        if ([string](Get-JournalProperty $archived 'transactionId') -cne [string]$Manifest.transactionId -or
            [string](Get-JournalProperty $archived 'phase') -cne 'completed') {
            throw 'Completed recovery archive is not marker-bound.'
        }
        return (Get-FullPath $archivePath)
    }
    if ($journal.phase -ne 'artifacts-complete' -or (Get-JournalProperty $journal 'writersReleased') -ne $true) {
        throw 'Recovery cannot be finalized before artifacts and writer boundaries are complete.'
    }
    $stages = Get-JournalProperty $journal 'stages'
    if ($null -eq $stages) { throw 'Recovery cannot be finalized without durable stage state.' }
    foreach ($requiredStage in @('Restore-AclSnapshots', 'service-LifeOSAPI', 'service-LifeOSGateway', 'service-state-reconcile', 'Restore-CodexCollectorTask', 'Restore-TailscaleSnapshotTask')) {
        $stageState = Get-JournalProperty $stages $requiredStage
        if ([string]$stageState -cne 'complete') {
            throw "Recovery stage is not durably complete: $requiredStage"
        }
    }
    foreach ($stageProperty in $stages.PSObject.Properties) {
        if ([string]$stageProperty.Value -cne 'complete') {
            throw "Recovery contains an incomplete stage: $($stageProperty.Name)"
        }
    }
    $terminal = Copy-LifeOSJsonValue $journal
    Set-JournalProperty $terminal 'phase' 'completed'
    Set-JournalProperty $terminal 'completedAtUtc' ((Get-Date).ToUniversalTime().ToString('o'))
    Set-JournalProperty $terminal 'archivePath' (Get-FullPath $archivePath)
    [void](Assert-RecoveryJournalCheckpointCapacity -Manifest $Manifest -Journal $terminal -FinalProgressSequence ([long](Get-JournalProperty $journal 'progressSequence')))
    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        Write-JsonAtomic $archivePath $terminal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
    } else {
        Assert-ExistingFile $archivePath 'Completed recovery archive'
        Assert-RestrictedAcl $archivePath $Manifest.operatorSid @() @() -AllowInherited
        $archived = Read-LifeOSBoundedJsonFile -Path $archivePath -MaxBytes $script:LifeOSRecoveryJournalMaxBytes -Description 'Completed recovery archive'
        if ([string](Get-JournalProperty $archived 'transactionId') -cne [string]$Manifest.transactionId -or
            [string](Get-JournalProperty $archived 'phase') -cne 'completed') {
            throw 'Completed recovery archive belongs to another transaction.'
        }
    }
    # Publish the terminal journal only after the archive is durable. If this
    # checkpoint is interrupted, a later recovery can safely repeat this
    # function and reuse the verified archive without replaying mutations.
    Write-JsonAtomic $journalPath $terminal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
    $verified = Read-RecoveryJournal $Manifest
    if ($null -eq $verified -or [string]$verified.phase -cne 'completed') { throw 'Completed recovery journal verification failed.' }
    return (Get-FullPath $archivePath)
}

function Read-RecoveryJournal {
    param($Manifest)
    $path = Get-RecoveryJournalPath $Manifest
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    Assert-ExistingFile $path 'Recovery journal'
    Assert-RestrictedAcl $path $Manifest.operatorSid @() @() -AllowInherited
    $journal = Read-LifeOSBoundedJsonFile -Path $path -MaxBytes $script:LifeOSRecoveryJournalMaxBytes -Description 'Recovery journal'
    foreach ($name in @('transactionId', 'generation', 'operatorSid', 'manifestPath')) {
        $manifestIdentity = Get-JournalProperty $Manifest $name
        $journalIdentity = Get-JournalProperty $journal $name
        if ($manifestIdentity -isnot [string] -or $journalIdentity -isnot [string] -or
            [string]::IsNullOrWhiteSpace([string]$manifestIdentity) -or
            $manifestIdentity.Length -gt 4096 -or $journalIdentity.Length -gt 4096 -or
            [string]$journalIdentity -cne [string]$manifestIdentity) { throw 'Recovery journal belongs to another transaction.' }
    }
    if ($journal.schemaVersion -ne 1 -or $journal.phase -notin @('artifacts', 'artifacts-complete', 'completed')) { throw 'Recovery journal schema is invalid.' }
    if ($journal.phase -eq 'completed') {
        $expectedArchivePath = Get-FullPath (Join-Path $Manifest.paths.backupDirectory ('recovery.completed.' + [string]$Manifest.transactionId + '.json'))
        $recordedArchivePath = Get-JournalProperty $journal 'archivePath'
        if ($recordedArchivePath -isnot [string] -or (Get-FullPath $recordedArchivePath) -cne $expectedArchivePath) {
            throw 'Completed recovery journal archive binding is invalid.'
        }
        Assert-ExistingFile $expectedArchivePath 'Completed recovery archive'
        Assert-NoReparsePath $expectedArchivePath
        Assert-RestrictedAcl $expectedArchivePath $Manifest.operatorSid @() @() -AllowInherited
    }
    # A matching transaction does not authorize arbitrary journal paths. Every
    # file unit must remain within the manifest's canonical recovery roots and
    # retain the staging path generated by this transaction, in journal order.
    if ($null -eq $journal.treeRoots -or $null -eq $journal.units) {
        throw 'Recovery journal inventory is malformed.'
    }
    # Windows PowerShell 5.1 unwraps one-item JSON arrays when they are
    # assigned to a property. Normalize that owned representation back to a
    # collection, while rejecting scalar unit values and empty inventories.
    $treeRoots = @(
        if ($journal.treeRoots -is [string]) {
            @([string]$journal.treeRoots)
        } elseif ($journal.treeRoots -is [System.Collections.IEnumerable]) {
            @($journal.treeRoots)
        } else { throw 'Recovery journal tree-root collection is malformed.' }
    )
    $journalUnits = @(
        if ($journal.units -is [System.Collections.IEnumerable] -and $journal.units -isnot [string]) {
            @($journal.units)
        } elseif ($journal.units -is [System.Management.Automation.PSCustomObject] -or
            $journal.units -is [System.Collections.IDictionary]) {
            @($journal.units)
        } else { throw 'Recovery journal unit collection is malformed.' }
    )
    if ($treeRoots.Count -eq 0 -or $journalUnits.Count -eq 0) { throw 'Recovery journal inventory is empty.' }
    Set-JournalProperty $journal 'treeRoots' $treeRoots
    Set-JournalProperty $journal 'units' $journalUnits
    $recordedUnitCount = Get-JournalProperty $journal 'unitCount'
    if ($null -eq $recordedUnitCount) {
        Set-JournalProperty $journal 'unitCount' $journalUnits.Count
    } elseif (-not (Test-LifeOSIntegralNumber $recordedUnitCount) -or [int]$recordedUnitCount -ne $journalUnits.Count) {
        throw 'Recovery journal unit count is inconsistent.'
    }
    $manifestBackups = @($Manifest.backups)
    Assert-RecoveryInventoryBounds -TreeRoots $treeRoots -FileUnits $journalUnits -ManifestBackups $manifestBackups
    Read-RecoveryProgress -Manifest $Manifest -Journal $journal -JournalUnits $journalUnits
    $allowedRoots = @($Manifest.paths.gatewayData, $Manifest.paths.usageHistory) + @($manifestBackups | ForEach-Object { $_.destination })
    $allowedRoots = @($allowedRoots | ForEach-Object { (Get-FullPath $_).TrimEnd('\') })
    if ($allowedRoots.Count -gt ($script:LifeOSRecoveryMaxTreeRoots + 2)) { throw 'Recovery inventory contains too many allowed roots.' }
    $allowedRootSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($allowedRoot in $allowedRoots) { [void]$allowedRootSet.Add($allowedRoot) }
    $backupPrefix = (Get-FullPath $Manifest.paths.backupDirectory).TrimEnd('\') + '\'
    $validatedTreeRoots = New-Object 'System.Collections.Generic.List[string]'
    $treeRootSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $treeRoots) {
        if ($root -isnot [string]) { throw 'Recovery journal tree root is malformed.' }
        $rootText = [string]$root
        if ([string]::IsNullOrWhiteSpace($rootText) -or $rootText.Length -gt $script:LifeOSRecoveryMaxPathLength) { throw 'Recovery journal tree root is malformed.' }
        $normalizedRoot = (Get-FullPath $rootText).TrimEnd('\')
        if (-not $treeRootSet.Add($normalizedRoot) -or -not $allowedRootSet.Contains($normalizedRoot)) {
            throw 'Recovery journal tree root is not manifest owned or is duplicated.'
        }
        [void]$validatedTreeRoots.Add($normalizedRoot)
    }
    $scanRootCandidates = New-Object 'System.Collections.Generic.List[string]'
    foreach ($root in $validatedTreeRoots) { [void]$scanRootCandidates.Add($root) }
    $destinationSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $stagingSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $unitIndex = 0
    foreach ($unit in $journalUnits) {
        if ($null -eq $unit) { throw 'Recovery journal unit is malformed.' }
        $expectedUnitFields = @('destination', 'backup', 'pre', 'post', 'phase', 'stagingPath')
        $unitFields = @($unit.PSObject.Properties | ForEach-Object { [string]$_.Name })
        $unitFieldSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($field in $unitFields) { [void]$unitFieldSet.Add($field) }
        if ($unitFieldSet.Count -ne $expectedUnitFields.Count -or
            @($expectedUnitFields | Where-Object { -not $unitFieldSet.Contains($_) }).Count -ne 0) {
            throw 'Recovery journal unit schema is invalid.'
        }
        foreach ($field in @('destination', 'backup', 'pre', 'post', 'phase', 'stagingPath')) {
            $value = Get-JournalProperty $unit $field
            if ($value -isnot [string]) { throw 'Recovery journal unit contains a malformed string.' }
            if ($value.Length -gt 4096) { throw 'Recovery journal unit contains an oversized string.' }
        }
        $destination = Get-FullPath $unit.destination
        if ($destination.Length -gt 4096) { throw 'Recovery journal destination path is too long.' }
        $ancestor = $destination
        $permitted = $false
        for ($depth = 0; $depth -le 256; $depth++) {
            if ($allowedRootSet.Contains($ancestor.TrimEnd('\'))) { $permitted = $true; break }
            $parent = Split-Path -Parent $ancestor
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $ancestor) { break }
            $ancestor = $parent
        }
        $stage = Join-Path (Split-Path -Parent $destination) ('.rollback-restore-' + $Manifest.transactionId + '-' + $unitIndex)
        if (-not $permitted -or -not $destinationSet.Add($destination) -or $unit.stagingPath -ne $stage -or
            $unit.phase -notin @('pending', 'restoring', 'complete') -or
            $unit.pre -cnotmatch '^(absent|file:[0-9a-f]{64})$' -or $unit.post -cnotmatch '^(absent|file:[0-9a-f]{64})$') { throw 'Recovery journal unit is not canonical.' }
        if ($unit.backup -and -not (Get-FullPath $unit.backup).StartsWith($backupPrefix, [StringComparison]::OrdinalIgnoreCase)) { throw 'Recovery journal backup escapes the transaction.' }
        if ($unit.phase -eq 'restoring') {
            $stageFull = Get-FullPath $unit.stagingPath
            if (-not $stagingSet.Add($stageFull)) {
                throw 'Recovery journal staging paths are duplicated.'
            }
            $isNodeArtifact = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $destination
            if ($isNodeArtifact) {
                # Expanded tree recovery journals contain one unit per file.
                # Restore-Artifact therefore stages node.exe as this exact
                # sibling file, rather than as <stage>\node.exe.
                [void]$stagingSet.Add($stageFull)
            }
        }
        $unitIndex++
    }
    Assert-RecoveryInventoryBounds -TreeRoots $scanRootCandidates.ToArray() -FileUnits $journalUnits -ManifestBackups $manifestBackups
    $scanRoots = @(Get-RecoveryCanonicalTreeRoots -Roots $scanRootCandidates.ToArray())
    $writerState = Get-JournalProperty $journal 'writersReleased'
    if ($null -ne $writerState -and $writerState -isnot [bool]) { throw 'Recovery writer boundary is not boolean.' }
    $writersReleased = $writerState -eq $true
    if ($writersReleased -and ($journal.phase -notin @('artifacts-complete', 'completed') -or
        @($journal.units | Where-Object { $_.phase -ne 'complete' }).Count -gt 0)) { throw 'Recovery writer boundary precedes artifact completion.' }
    if ($journal.phase -eq 'completed' -and ($writersReleased -ne $true -or
        @($journal.units | Where-Object { $_.phase -ne 'complete' }).Count -gt 0)) {
        throw 'Completed recovery journal is not a verified terminal state.'
    }
    $discoveredFileCount = 0
    [long]$discoveredBytes = 0
    $treeIndexCache = [ordered]@{}
    $indexedStates = [System.Collections.Generic.Dictionary[string,string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $scanRoots) {
        if ($writersReleased -and (Test-RecoveryAuthorityPath $Manifest $root)) { continue }
        if (Test-Path -LiteralPath $root -PathType Container) {
            # Build one bounded index for each disjoint root. This avoids the
            # repeated recursive scans that made overlapping journal roots
            # scale with root-count multiplied by file-count.
            $allowNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $root -TreeRoot
            $largeFileRelativePaths = @(Get-LifeOSNodeRuntimeStagingRelativePaths -Manifest $Manifest -Journal $journal -Root $root)
            $treeIndex = Get-RecoveryTreeManifestIndex -Root $root -Cache $treeIndexCache -TotalBytes ([ref]$discoveredBytes) -AllowNodeRuntime:$allowNodeRuntime -LargeFileRelativePaths $largeFileRelativePaths
            $discoveredFileCount += [int]$treeIndex.FileCount
            if ($discoveredFileCount -gt $script:LifeOSRecoveryMaxFileUnits) { throw 'Recovery inventory contains too many files.' }
            foreach ($entry in $treeIndex.Entries) {
                $filePath = Get-FullPath (Join-Path $root $entry.path)
                if (-not $destinationSet.Contains($filePath)) {
                    if (-not $stagingSet.Contains($filePath)) { throw 'Unjournaled file appeared during recovery.' }
                    Assert-NoReparsePath $filePath
                }
                $indexedStates[$filePath] = 'file:' + [string]$entry.sha256
            }
        }
    }
    foreach ($unit in $journalUnits) {
        if ($writersReleased -and (Test-RecoveryAuthorityPath $Manifest $unit.destination)) { continue }
        $unitDestination = Get-FullPath $unit.destination
        $allowNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $unitDestination
        $allowServiceHostBinary = Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $unitDestination
        $current = if ($indexedStates.ContainsKey($unitDestination)) { $indexedStates[$unitDestination] } else { Get-RecoveryArtifactState $unitDestination -AllowNodeRuntime:$allowNodeRuntime -AllowServiceHostBinary:$allowServiceHostBinary -Manifest $Manifest }
        Assert-RecoveryUnitState $unit $current
    }
    return $journal
}

function Save-CollectorReceipt {
    param($Manifest)
    $receipt = [ordered]@{ schemaVersion=1; transactionId=$Manifest.transactionId; generation=$Manifest.generation; operatorSid=$Manifest.operatorSid; manifestPath=$Manifest.manifestPath; transition=$Manifest.collectorTransition }
    Write-JsonAtomic (Join-Path $Manifest.paths.backupDirectory 'collector-receipt.json') $receipt -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSCollectorReceiptMaxBytes
}

function Get-CollectorTransition {
    param($Manifest)
    $transition = Get-JournalProperty $Manifest 'collectorTransition'
    $path = Join-Path $Manifest.paths.backupDirectory 'collector-receipt.json'
    if (-not (Test-Path -LiteralPath $path)) { return $transition }
    Assert-ExistingFile $path 'Collector receipt'
    Assert-RestrictedAcl $path $Manifest.operatorSid @() @() -AllowInherited
    $receipt = Read-LifeOSBoundedJsonFile -Path $path -MaxBytes $script:LifeOSCollectorReceiptMaxBytes -Description 'Collector receipt'
    foreach ($name in @('transactionId', 'generation', 'operatorSid', 'manifestPath')) {
        if ([string]::IsNullOrWhiteSpace([string](Get-JournalProperty $Manifest $name)) -or
            [string](Get-JournalProperty $receipt $name) -cne [string](Get-JournalProperty $Manifest $name)) { throw 'Collector receipt belongs to another transaction.' }
    }
    if ($receipt.schemaVersion -ne 1 -or $null -eq $transition -or
        $receipt.transition.phase -ne 'terminal' -or
        $receipt.transition.usageBefore -cne $transition.usageBefore -or
        $receipt.transition.startedAtUtc -cne $transition.startedAtUtc) { throw 'Collector receipt is not bound to the recorded run.' }
    if ($transition.phase -eq 'terminal' -and $receipt.transition.usageAfter -cne $transition.usageAfter) { throw 'Collector terminal receipt changed.' }
    return $receipt.transition
}

function Test-CollectorUsagePreserved {
    param($Manifest)
    $transition = Get-CollectorTransition $Manifest
    if ($null -eq $transition) { return $false }
    $current = Get-RecoveryArtifactState $Manifest.paths.usageHistory
    if ($transition.phase -eq 'running') {
        if ($current -ne $transition.usageBefore) { throw 'Unattributed collector write; recovery_required.' }
        return $false
    }
    if ($transition.phase -ne 'terminal' -or $current -ne $transition.usageAfter) {
        throw 'Collector transition changed; recovery_required.'
    }
    # Preserve acknowledged observations in place across code rollback. Never
    # treat an installer's successful POST as permission to delete its receipt.
    return $transition.usageBefore -ne $transition.usageAfter
}

function Restore-ManifestArtifacts {
    param([Parameter(Mandatory)][psobject]$Manifest, [Parameter(Mandatory)][string]$BackupDirectory)
    $journalPath = Get-RecoveryJournalPath $Manifest
    $journal = Read-RecoveryJournal $Manifest
    $journalCreated = $false
    if ($null -ne $journal) {
        Assert-RecoveryInventoryBounds -TreeRoots $journal.treeRoots -FileUnits $journal.units -ManifestBackups @($Manifest.backups)
    }
    if ($null -ne $journal -and $journal.phase -in @('artifacts-complete', 'completed')) { return }
    if ($null -eq $journal) {
        $units = [ordered]@{}
        $treeRoots = @($Manifest.paths.gatewayData)
        [long]$inventoryBytes = 0
        $treeIndexCache = [ordered]@{}
        # Authority and usage remain guarded even when no migration changed
        # them. Expand trees into file units so restoring one companion does
        # not invalidate the permitted states of all remaining companions.
        $guards = @($Manifest.paths.gatewayData, $Manifest.paths.usageHistory)
        foreach ($guard in $guards) {
            if (Test-Path -LiteralPath $guard -PathType Container) {
                $treeIndex = Get-RecoveryTreeManifestIndex -Root $guard -Cache $treeIndexCache -TotalBytes ([ref]$inventoryBytes)
                foreach ($entry in $treeIndex.Entries) {
                    $filePath = Get-FullPath (Join-Path $guard $entry.path)
                    if (-not $units.Contains($filePath) -and $units.Count -ge $script:LifeOSRecoveryMaxFileUnits) {
                        throw 'Recovery inventory contains too many file units.'
                    }
                    $state = 'file:' + [string]$entry.sha256
                    $units[$filePath] = [ordered]@{ destination=$filePath; backup=''; pre=$state; post=$state; phase='pending' }
                }
            } elseif (Test-Path -LiteralPath $guard -PathType Leaf) {
                if (-not $units.Contains($guard) -and $units.Count -ge $script:LifeOSRecoveryMaxFileUnits) {
                    throw 'Recovery inventory contains too many file units.'
                }
                $state = Get-RecoveryArtifactState $guard
                $units[$guard] = [ordered]@{ destination=$guard; backup=''; pre=$state; post=$state; phase='pending' }
            } elseif ($guard -eq $Manifest.paths.usageHistory) {
                if (-not $units.Contains($guard) -and $units.Count -ge $script:LifeOSRecoveryMaxFileUnits) {
                    throw 'Recovery inventory contains too many file units.'
                }
                $units[$guard] = [ordered]@{ destination=$guard; backup=''; pre='absent'; post='absent'; phase='pending' }
            }
        }
        $preserveUsage = Test-CollectorUsagePreserved $Manifest
        $artifacts = @($Manifest.backups)
        for ($index = $artifacts.Count - 1; $index -ge 0; $index--) {
            $artifact = $artifacts[$index]
            if (-not $artifact.changed) { continue }
            if ($preserveUsage -and $artifact.destination -eq $Manifest.paths.usageHistory) { continue }
            $destination = [string]$artifact.destination
            $backup = [string]$artifact.backup
            if ($artifact.priorExists -and ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup))) {
                if ($artifact.phase -eq 'pending') { continue }
                throw 'Recovery backup missing for prior artifact.'
            }
            $isTree = (Test-Path -LiteralPath $destination -PathType Container) -or
                (-not [string]::IsNullOrWhiteSpace($backup) -and (Test-Path -LiteralPath $backup -PathType Container))
            $relativePaths = @('')
            if ($isTree) {
                $allowNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $destination -TreeRoot
                $treeRoots += $destination
                Assert-RecoveryInventoryBounds -TreeRoots $treeRoots -FileUnits $units.Values -ManifestBackups $artifacts
                $relativePaths = @()
                if (Test-Path -LiteralPath $destination -PathType Container) {
                    $destinationIndex = Get-RecoveryTreeManifestIndex -Root $destination -Cache $treeIndexCache -TotalBytes ([ref]$inventoryBytes) -AllowNodeRuntime:$allowNodeRuntime
                    $relativePaths += @($destinationIndex.Entries | ForEach-Object { $_.path })
                }
                if (-not [string]::IsNullOrWhiteSpace($backup) -and (Test-Path -LiteralPath $backup -PathType Container)) {
                    $backupIndex = Get-RecoveryTreeManifestIndex -Root $backup -Cache $treeIndexCache -TotalBytes ([ref]$inventoryBytes) -AllowNodeRuntime:$allowNodeRuntime
                    $relativePaths += @($backupIndex.Entries | ForEach-Object { $_.path })
                }
            }
            foreach ($relative in @($relativePaths | Sort-Object -Unique)) {
                $target = if ($relative) { Join-Path $destination $relative } else { $destination }
                if (-not $units.Contains($target) -and $units.Count -ge $script:LifeOSRecoveryMaxFileUnits) {
                    throw 'Recovery inventory contains too many file units.'
                }
                $source = if ([string]::IsNullOrWhiteSpace($backup)) { '' } elseif ($relative) { Join-Path $backup $relative } else { $backup }
                $sourceAllowsNodeRuntime = $source -and (Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $source)
                $sourceAllowsServiceHostBinary = $source -and (Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $source)
                $post = if ($source -and (Test-Path -LiteralPath $source -PathType Leaf)) { Get-RecoveryArtifactState $source -AllowNodeRuntime:$sourceAllowsNodeRuntime -AllowServiceHostBinary:$sourceAllowsServiceHostBinary -Manifest $Manifest } else { 'absent' }
                if ($artifact.priorExists -and -not $isTree -and $post -eq 'absent') {
                    if ($artifact.phase -eq 'pending') { continue }
                    throw 'Recovery backup missing for prior artifact.'
                }
                $targetAllowsNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $target
                $targetAllowsServiceHostBinary = Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $target
                $units[$target] = [ordered]@{ destination=$target; backup=$source; pre=(Get-RecoveryArtifactState $target -AllowNodeRuntime:$targetAllowsNodeRuntime -AllowServiceHostBinary:$targetAllowsServiceHostBinary -Manifest $Manifest); post=$post; phase='pending' }
            }
        }
        $canonicalTreeRoots = @(Get-RecoveryCanonicalTreeRoots -Roots $treeRoots)
        Assert-RecoveryInventoryBounds -TreeRoots $canonicalTreeRoots -FileUnits $units.Values -ManifestBackups $artifacts
        $unitIndex = 0
        foreach ($unit in $units.Values) {
            $stage = Join-Path (Split-Path -Parent $unit.destination) ('.rollback-restore-' + $Manifest.transactionId + '-' + $unitIndex)
            Set-JournalProperty $unit 'stagingPath' $stage
            $unitIndex++
        }
        $journal = [pscustomobject]@{
            schemaVersion=1; transactionId=$Manifest.transactionId; generation=$Manifest.generation
            operatorSid=$Manifest.operatorSid; manifestPath=$Manifest.manifestPath
            units=@($units.Values); unitCount=$units.Count; treeRoots=$canonicalTreeRoots; phase='artifacts'
            progressPath=(Get-RecoveryProgressPath $Manifest)
        }
        $progressCapacity = Assert-RecoveryProgressCapacity -Manifest $Manifest -Journal $journal
        Assert-RecoveryJournalCheckpointCapacity -Manifest $Manifest -Journal $journal -FinalProgressSequence $progressCapacity.FinalSequence
        Write-JsonAtomic $journalPath $journal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
        $journalCreated = $true
    }
    if (-not $journalCreated) {
        $progressCapacity = Assert-RecoveryProgressCapacity -Manifest $Manifest -Journal $journal
        Assert-RecoveryJournalCheckpointCapacity -Manifest $Manifest -Journal $journal -FinalProgressSequence $progressCapacity.FinalSequence
    }
    $unitIndex = 0
    foreach ($unit in @($journal.units)) {
        $allowNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $unit.destination
        $allowServiceHostBinary = Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $unit.destination
        $current = Get-RecoveryArtifactState $unit.destination -AllowNodeRuntime:$allowNodeRuntime -AllowServiceHostBinary:$allowServiceHostBinary -Manifest $Manifest
        Assert-RecoveryUnitState $unit $current
        if ($current -ne $unit.post) {
            Append-RecoveryProgress -Manifest $Manifest -Journal $journal -UnitIndex $unitIndex -Phase 'restoring'
            if ($unit.post -ne 'absent') {
                $backupAllowsNodeRuntime = Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $unit.backup
                $backupAllowsServiceHostBinary = Test-LifeOSServiceHostArtifactPath -Manifest $Manifest -Path $unit.backup
                if ((Get-RecoveryArtifactState $unit.backup -AllowNodeRuntime:$backupAllowsNodeRuntime -AllowServiceHostBinary:$backupAllowsServiceHostBinary -Manifest $Manifest) -ne $unit.post) { throw 'Recovery unit backup changed.' }
            }
            $restore = [pscustomobject]@{ recoveryStagePath=$unit.stagingPath; destination=$unit.destination; backup=$(if ($unit.post -eq 'absent') { '' } else { $unit.backup }); changed=$true; priorExists=($unit.post -ne 'absent'); phase='complete' }
            Restore-Artifact $restore $BackupDirectory -AllowNodeRuntime:$allowNodeRuntime -AllowServiceHostBinary:$allowServiceHostBinary -Manifest $Manifest
            if ((Get-RecoveryArtifactState $unit.destination -AllowNodeRuntime:$allowNodeRuntime -AllowServiceHostBinary:$allowServiceHostBinary -Manifest $Manifest) -ne $unit.post) { throw 'Recovery unit post-state verification failed.' }
        }
        if (Test-Path -LiteralPath $unit.stagingPath) {
            Assert-NoReparsePath $unit.stagingPath
            Remove-Item -LiteralPath $unit.stagingPath -Force -ErrorAction Stop
        }
        Append-RecoveryProgress -Manifest $Manifest -Journal $journal -UnitIndex $unitIndex -Phase 'complete'
        $unitIndex++
    }
    Set-JournalProperty $journal 'phase' 'artifacts-complete'
    Write-JsonAtomic $journalPath $journal -OperatorSid $Manifest.operatorSid -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
}

function Copy-FileVerifiedAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [string]$BackupName,
        [long]$MaxBytes = 0,
        [switch]$DeferMove
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
            return [pscustomobject]@{ Destination = $Destination; SourceHash = $sourceHash; SourceLength = $sourceInfo.Length; Backup = $null; Changed = $false; StagedPath = $null }
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
        if (-not $DeferMove) {
            Move-Item -LiteralPath $temp -Destination $Destination -Force
            if ((Get-FileSha256 $Destination) -ne $sourceHash) { throw "Destination hash verification failed for $Destination." }
        }
    } catch {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
            Move-Item -LiteralPath $backup -Destination $Destination -Force
        } elseif (Test-Path -LiteralPath $Destination) {
            Move-CurrentOutOfTheWay $Destination $BackupDirectory
        }
        throw
    } finally {
        if (-not $DeferMove -and (Test-Path -LiteralPath $temp)) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Destination = $Destination; SourceHash = $sourceHash; SourceLength = $sourceInfo.Length; Backup = $backup; Changed = $true; StagedPath = if ($DeferMove) { $temp } else { $null } }
}

function Copy-TreeVerifiedAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [string]$BackupName,
        [string]$LargeFileRelativePath = '',
        [long]$LargeFileMaxBytes = 0,
        [System.Collections.IDictionary]$LargeFileContracts = $null
    )
    Assert-ExistingDirectory $Source 'Tree source'
    $sourceManifest = @(Get-TreeManifest $Source -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileContracts $LargeFileContracts)
    if (Compare-TreeManifest $Source $Destination -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileContracts $LargeFileContracts) {
        return [pscustomobject]@{ Destination = $Destination; Backup = $null; Manifest = $sourceManifest; Changed = $false }
    }
    $destinationParent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $destinationParent
    $temp = Join-Path $destinationParent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.staging')
    $backup = $null
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Recurse -Force
        if (-not (Compare-TreeManifest $Source $temp -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileContracts $LargeFileContracts)) { throw "Tree hash verification failed for $Source." }
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            Assert-NoReparsePath $Destination
            $backupLeaf = if ([string]::IsNullOrWhiteSpace($BackupName)) { 'previous-' + [IO.Path]::GetFileName($Destination) } else { $BackupName }
            $backup = Join-Path $BackupDirectory $backupLeaf
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        if (-not (Compare-TreeManifest $Source $Destination -LargeFileRelativePath $LargeFileRelativePath -LargeFileMaxBytes $LargeFileMaxBytes -LargeFileContracts $LargeFileContracts)) { throw "Staged tree verification failed for $Destination." }
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
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$BackupDirectory, [string]$BackupName, [string]$OperatorSid = (Get-InteractiveOperatorSid))
    if ($Value.Length -lt 32 -or $Value.Length -gt 256 -or $Value -match '[^\x21-\x7E]') { throw 'Generated secret did not satisfy the bounded printable format.' }
    $parent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $parent
    $backup = $null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Assert-NoReparsePath $Destination
        $existing = Read-LifeOSCappedFileText -Path $Destination -MaxBytes 256 -Description 'Existing generated secret'
        if ($existing -eq $Value) { return [pscustomobject]@{ Backup = $null; Changed = $false } }
        $backupLeaf = if ([string]::IsNullOrWhiteSpace($BackupName)) { 'previous-' + [IO.Path]::GetFileName($Destination) } else { $BackupName }
        $backup = Backup-File $Destination $BackupDirectory $backupLeaf
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllBytes($temp, [byte[]]@())
        Set-RestrictedAcl -Path $temp -OperatorSid $OperatorSid -File -SkipSnapshot
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

function Get-LifeOSTreeRelativePath {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$Path
    )
    $rootFull = (Get-FullPath $Root).TrimEnd('\')
    $pathFull = (Get-FullPath $Path).TrimEnd('\')
    if ($pathFull -ieq $rootFull) { return '' }
    $prefix = $rootFull + '\'
    if (-not $pathFull.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'ACL snapshot path escapes its canonical root.'
    }
    $relative = $pathFull.Substring($prefix.Length).Replace('\', '/')
    if ([string]::IsNullOrWhiteSpace($relative) -or $relative.Length -gt $script:LifeOSRecoveryMaxPathLength -or
        $relative -match '(^|/)(?:\.{1,2})(?:/|$)|//|/$|:') {
        throw 'ACL snapshot relative path is unsafe.'
    }
    return $relative
}

function Get-LifeOSFrozenTreeInventory {
    param([Parameter(Mandatory)][string]$Path, [switch]$File, [switch]$RootOnly)
    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($File -and $root.PSIsContainer) { throw "ACL file path is a directory: $Path" }
    if (-not $File -and -not $root.PSIsContainer) { throw "ACL tree path is a file: $Path" }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    $rootIdentity = New-LifeOSTreeItemIdentity -Item $root -Description 'ACL mutation root'
    [void]$entries.Add([pscustomobject]@{
        Path = Get-FullPath $Path
        IsContainer = [bool]$root.PSIsContainer
        Identity = $rootIdentity
        PathIdentityChain = @(Get-LifeOSPathIdentityChain -Path $Path -Description 'ACL mutation root')
    })
    if (-not $File -and -not $RootOnly) {
        foreach ($item in @(Get-LifeOSBoundedTreeItem -Root (Get-FullPath $Path))) {
            $identity = New-LifeOSTreeItemIdentity -Item $item -Description 'ACL mutation inventory item'
            [void]$entries.Add([pscustomobject]@{
                Path = Get-FullPath ([string]$item.FullName)
                IsContainer = [bool]$item.PSIsContainer
                Identity = $identity
                PathIdentityChain = @(Get-LifeOSPathIdentityChain -Path ([string]$item.FullName) -Description 'ACL mutation inventory item')
            })
        }
    }
    if ($entries.Count -le 0) { throw 'ACL mutation inventory is empty.' }
    return @($entries.ToArray())
}

function Add-LifeOSManagedAccessRule {
    param(
        [Parameter(Mandatory)][object]$Acl,
        [Parameter(Mandatory)][string]$Sid,
        [Parameter(Mandatory)][Security.AccessControl.FileSystemRights]$Rights,
        [Security.AccessControl.InheritanceFlags]$Inheritance = ([Security.AccessControl.InheritanceFlags]::None),
        [Security.AccessControl.PropagationFlags]$Propagation = ([Security.AccessControl.PropagationFlags]::None)
    )
    $identity = [Security.Principal.SecurityIdentifier]::new($Sid)
    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
        $identity, $Rights, $Inheritance, $Propagation,
        [Security.AccessControl.AccessControlType]::Allow)
    [void]$Acl.AddAccessRule($rule)
}

function New-LifeOSManagedAcl {
    param(
        [Parameter(Mandatory)][string]$OperatorSid,
        [string[]]$ReadSids = @(),
        [string[]]$ModifySids = @(),
        [Parameter(Mandatory)][bool]$IsContainer,
        [switch]$Executable,
        [switch]$InheritToChildren,
        [switch]$InheritableSystemFullControl
    )
    $acl = if ($IsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
    # Build the same explicit role set as the reviewed icacls contract, then
    # apply its DACL through a validated object handle. No external tool gets
    # a chance to reopen a path between validation and mutation.
    $acl.SetAccessRuleProtection($true, $false)
    $inheritance = if ($IsContainer -and $InheritToChildren) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else { [Security.AccessControl.InheritanceFlags]::None }
    $propagation = [Security.AccessControl.PropagationFlags]::None
    $full = [Security.AccessControl.FileSystemRights]::FullControl
    Add-LifeOSManagedAccessRule $acl $OperatorSid $full
    Add-LifeOSManagedAccessRule $acl 'S-1-5-18' $full
    Add-LifeOSManagedAccessRule $acl 'S-1-5-32-544' $full
    if ($inheritance -ne [Security.AccessControl.InheritanceFlags]::None) {
        Add-LifeOSManagedAccessRule $acl $OperatorSid $full $inheritance $propagation
        Add-LifeOSManagedAccessRule $acl 'S-1-5-32-544' $full $inheritance $propagation
        if ($InheritableSystemFullControl) { Add-LifeOSManagedAccessRule $acl 'S-1-5-18' $full $inheritance $propagation }
    }
    foreach ($sid in $ReadSids) {
        # A protected code/runtime tree cannot rely on inherited directory
        # rights for image loading. Keep ordinary files (including data,
        # config, and secret files) read-only, while granting the service
        # identity the minimum image access required by executable files.
        $rights = if ($IsContainer -or $Executable) { [Security.AccessControl.FileSystemRights]::ReadAndExecute } else { [Security.AccessControl.FileSystemRights]::Read }
        Add-LifeOSManagedAccessRule $acl $sid $rights
        if ($inheritance -ne [Security.AccessControl.InheritanceFlags]::None) { Add-LifeOSManagedAccessRule $acl $sid $rights $inheritance $propagation }
    }
    foreach ($sid in $ModifySids) {
        $rights = [Security.AccessControl.FileSystemRights]::Modify
        Add-LifeOSManagedAccessRule $acl $sid $rights
        if ($inheritance -ne [Security.AccessControl.InheritanceFlags]::None) { Add-LifeOSManagedAccessRule $acl $sid $rights $inheritance $propagation }
    }
    return $acl
}

function Set-LifeOSAclWithBoundHandle {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object]$Acl,
        [Parameter(Mandatory)][bool]$Directory,
        [object[]]$ExpectedChain
    )
    $chain = if ($null -ne $ExpectedChain) { @($ExpectedChain) } else { @(Get-LifeOSPathIdentityChain -Path $Path -Description 'ACL mutation target') }
    if ($chain.Count -le 0) { throw "ACL mutation target has no identity: $Path" }
    $handle = $null
    try {
        # OpenForAcl sets FILE_FLAG_OPEN_REPARSE_POINT and retains the object
        # handle while SetSecurityInfo mutates its DACL. Path revalidation is
        # still required for ancestor replacement because a path-based caller
        # cannot be made handle-bound merely by opening a separate handle.
        $handle = [LifeOSNativeFileIdentity]::OpenForAcl((Get-FullPath $Path), $Directory)
        $attributes = [LifeOSNativeFileIdentity]::GetAttributes($handle)
        if (($attributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0) { throw "ACL mutation target is a reparse point: $Path" }
        $openedId = [LifeOSNativeFileIdentity]::Get($handle)
        if ($openedId -cne [string]$chain[$chain.Count - 1].FileId) { throw "ACL mutation target changed while opening: $Path" }
        Assert-LifeOSPathIdentityChain -Expected $chain -Description 'ACL mutation target' | Out-Null
        $descriptor = $Acl.GetSecurityDescriptorBinaryForm()
        [LifeOSNativeFileIdentity]::SetDacl($handle, $descriptor, [bool]$Acl.AreAccessRulesProtected)
        if ([LifeOSNativeFileIdentity]::Get($handle) -cne $openedId) { throw "ACL mutation target identity changed: $Path" }
        Assert-LifeOSPathIdentityChain -Expected $chain -Description 'ACL mutation target' | Out-Null
    } finally {
        if ($null -ne $handle) { $handle.Dispose() }
    }
}

function Set-RestrictedAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OperatorSid,
        [string[]]$ReadSids = @(),
        [string[]]$ModifySids = @(),
        [switch]$File,
        [switch]$SkipSnapshot,
        # Managed writable service trees pass the service SID here because a
        # file created by that service may carry the service SID as owner.
        # The scope is deliberately constrained to a service SID that also
        # has the tree's Modify role; it is never a global owner exemption.
        [string[]]$AllowedOwnerSids = @(),
        # SYSTEM must inherit on managed writable service trees so recursively
        # verified files created after deployment retain the management grant.
        [switch]$InheritableSystemFullControl,
        [int]$MaxAttempts = 5,
        [int]$RetryDelayMilliseconds = 500
    )
    if (@($AllowedOwnerSids).Count -gt 0 -and -not $File -and -not $InheritableSystemFullControl) {
        throw 'Service-owned writable ACL scope requires inheritable SYSTEM management rights.'
    }
    foreach ($ownerSid in @($AllowedOwnerSids)) {
        if ([string]::IsNullOrWhiteSpace([string]$ownerSid) -or
            [string]$ownerSid -notmatch '\AS-1-5-80-[0-9-]+\z' -or
            [string]$ownerSid -notin @($ModifySids)) {
            throw 'Allowed ACL owner must be a service SID with Modify rights on this managed writable tree.'
        }
    }
    if ($File) { Assert-ExistingFile $Path 'ACL file' } else { Ensure-Directory $Path }
    if (-not $SkipSnapshot) { Register-AclSnapshot $Path }
    Remove-TransientLogonAclRules $Path -Recurse -KeepServiceSids @($ReadSids + $ModifySids)
    Assert-ExplicitAclAllowTree -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids

    # Freeze the exact set of objects before changing any ACL. Each native
    # call below receives one path and is preceded by identity/reparse
    # validation; /T is deliberately avoided because it would enumerate and
    # mutate a live tree after this inventory had been approved.
    $inventory = @(Get-LifeOSFrozenTreeInventory -Path $Path -File:$File)
    foreach ($entry in @($inventory | Sort-Object -Property @(
        @{ Expression = { ([string]$_.Path).Split('\').Count }; Descending = $true },
        @{ Expression = { [string]$_.Path }; Descending = $false }
    ))) {
        Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'ACL mutation target' | Out-Null
        # Windows can briefly hold a newly-created executable while Defender
        # or the service manager inspects it. Retry only this bounded single
        # object mutation; persistent failures still abort the transaction.
        $aclAttempt = 0
        while ($true) {
            try {
                $acl = New-LifeOSManagedAcl -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids -IsContainer ([bool]$entry.IsContainer) -InheritToChildren -InheritableSystemFullControl:$InheritableSystemFullControl
                Set-LifeOSAclWithBoundHandle -Path $entry.Path -Acl $acl -Directory ([bool]$entry.IsContainer) -ExpectedChain $entry.PathIdentityChain
                break
            } catch {
                $aclAttempt++
                if ($aclAttempt -ge $MaxAttempts) { throw }
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
                Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'ACL mutation retry target' | Out-Null
                Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain -Description 'ACL mutation retry target' | Out-Null
            }
        }
    }
    Remove-TransientLogonAclRules $Path -Recurse -KeepServiceSids @($ReadSids + $ModifySids)
    Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids -AllowedOwnerSids $AllowedOwnerSids -Recurse:(!$File)
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

function Remove-TransientLogonAclRules {
    param([Parameter(Mandatory)][string]$Path, [switch]$Recurse, [string[]]$KeepServiceSids = @())
    Assert-NoReparsePath $Path
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    $targets = New-Object 'System.Collections.Generic.List[object]'
    [void]$targets.Add($item)
    if ($Recurse -and $item.PSIsContainer) {
        foreach ($target in @(Get-LifeOSBoundedTreeItem -Root $Path)) { [void]$targets.Add($target) }
    }

    # Build and validate the complete mutation inventory before changing a
    # single ACL. Descendant reparses, identity changes, or ACL read failures
    # therefore abort the whole operation while the original tree is intact.
    $inventory = New-Object 'System.Collections.Generic.List[object]'
    foreach ($target in $targets) {
        $targetPath = Get-FullPath ([string]$target.FullName)
        Assert-NoReparsePath $targetPath
        $currentItem = Get-Item -LiteralPath $targetPath -Force -ErrorAction Stop
        if ([bool]$currentItem.PSIsContainer -ne [bool]$target.PSIsContainer) {
            throw "ACL mutation target changed type before inventory completed: $targetPath"
        }
        $acl = Get-Acl -LiteralPath $targetPath -ErrorAction Stop
        $rules = @($acl.Access | Where-Object {
            if ($_.AccessControlType -ne 'Allow') { return $false }
            try { $identitySid = $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { $identitySid = [string]$_.IdentityReference.Value }
            $identitySid.StartsWith('S-1-5-5-') -or
            ($identitySid.StartsWith('S-1-5-80-') -and $identitySid -notin $KeepServiceSids)
        })
        [void]$inventory.Add([pscustomobject]@{
            Path = $targetPath
            IsContainer = [bool]$currentItem.PSIsContainer
            Identity = New-LifeOSTreeItemIdentity -Item $currentItem -Description 'Transient ACL inventory item'
            PathIdentityChain = @(Get-LifeOSPathIdentityChain -Path $targetPath -Description 'Transient ACL inventory item')
            OriginalSddl = [string]$acl.Sddl
            Rules = $rules
        })
    }

    # Mutate deepest targets first. That keeps an intentional parent ACL
    # change from looking like an out-of-band descendant change during the
    # immediate pre-mutation revalidation below.
    foreach ($entry in @($inventory | Sort-Object -Property @(
        @{ Expression = { ([string]$_.Path).Split('\').Count }; Descending = $true },
        @{ Expression = { [string]$_.Path }; Descending = $false }
    ))) {
        Assert-NoReparsePath $entry.Path
        Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'Transient ACL mutation target' | Out-Null
        $freshItem = Get-Item -LiteralPath $entry.Path -Force -ErrorAction Stop
        if ([bool]$freshItem.PSIsContainer -ne [bool]$entry.IsContainer) {
            throw "ACL mutation target changed type before mutation: $($entry.Path)"
        }
        $acl = Get-Acl -LiteralPath $entry.Path -ErrorAction Stop
        if ([string]$acl.Sddl -cne [string]$entry.OriginalSddl) {
            throw "ACL mutation target changed before mutation: $($entry.Path)"
        }
        # Remove every ACE for the transient identity, not only one exact
        # rights/inheritance tuple.  A parent traversal grant can be
        # materialized on a descendant with a different tuple, and
        # RemoveAccessRule() may leave that sibling ACE behind.
        foreach ($rule in $entry.Rules) { $acl.RemoveAccessRuleAll($rule) }
        if ($entry.Rules.Count -gt 0) {
            Set-LifeOSAclWithBoundHandle -Path $entry.Path -Acl $acl -Directory ([bool]$entry.IsContainer) -ExpectedChain $entry.PathIdentityChain
        }
    }
}

function Set-DirectoryTraversalAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OperatorSid,
        [Parameter(Mandatory)][string[]]$ReadSids,
        [switch]$RootOnly,
        [switch]$InheritToChildren,
        [int]$MaxAttempts = 5,
        [int]$RetryDelayMilliseconds = 500
    )
    if ($InheritToChildren -and -not $RootOnly) {
        throw 'InheritToChildren is only valid with RootOnly.'
    }
    Ensure-Directory $Path
    # Some existing Hermes roots carry transient LogonSessionId ACEs or stale
    # virtual-service SID ACEs from a prior service registration. Neither is
    # stable across this transaction and must not survive hardening. Run both
    # before and after /inheritance:r because Windows can materialize inherited
    # ACEs as explicit on descendants during that call.
    Register-AclSnapshot $Path -RootOnly:$RootOnly
    Remove-TransientLogonAclRules $Path -Recurse:(!$RootOnly) -KeepServiceSids $ReadSids
    if ($RootOnly) {
        Assert-ExplicitAclAllowSet -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @()
    } else {
        Assert-ExplicitAclAllowTree -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @()
    }
    # Freeze the complete target set before mutation. Every invocation is
    # single-object and identity-checked; no recursive native ACL mutation
    # walks a tree that may have been replaced after validation.
    $inventory = @(Get-LifeOSFrozenTreeInventory -Path $Path -RootOnly:$RootOnly)
    foreach ($entry in @($inventory | Sort-Object -Property @(
        @{ Expression = { ([string]$_.Path).Split('\').Count }; Descending = $true },
        @{ Expression = { [string]$_.Path }; Descending = $false }
    ))) {
        Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'Directory traversal ACL target' | Out-Null
        $aclAttempt = 0
        while ($true) {
            try {
                $isExecutable = -not [bool]$entry.IsContainer -and ([IO.Path]::GetExtension([string]$entry.Path) -in @('.exe', '.dll'))
                $acl = New-LifeOSManagedAcl -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @() -IsContainer ([bool]$entry.IsContainer) -Executable:$isExecutable -InheritToChildren:($InheritToChildren -and $RootOnly) -InheritableSystemFullControl:($InheritToChildren -and $RootOnly)
                Set-LifeOSAclWithBoundHandle -Path $entry.Path -Acl $acl -Directory ([bool]$entry.IsContainer) -ExpectedChain $entry.PathIdentityChain
                break
            } catch {
                $aclAttempt++
                if ($aclAttempt -ge $MaxAttempts) { throw }
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
                Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'Directory traversal ACL retry target' | Out-Null
                Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain -Description 'Directory traversal ACL retry target' | Out-Null
            }
        }
    }
    Remove-TransientLogonAclRules $Path -Recurse:(!$RootOnly) -KeepServiceSids $ReadSids
    Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @() -Recurse:(!$RootOnly)
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
    if ($item.PSIsContainer) { $targets += @(Get-LifeOSBoundedTreeItem -Root $Path) }
    foreach ($target in $targets) {
        if (($target.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Reparse points are not permitted in an ACL mutation tree: $($target.FullName)"
        }
        Assert-ExplicitAclAllowSet -Path ([string]$target.FullName) -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids $ModifySids
    }
}

function Assert-AclRoleRights {
    param([string]$Role, [long]$Granted, [long]$Denied, [bool]$Directory, [bool]$Executable = $false)
    $required = switch ($Role) {
        'owner' { [long][Security.AccessControl.FileSystemRights]::FullControl }
        'modify' { [long][Security.AccessControl.FileSystemRights]::Modify }
        'read' { if ($Directory -or $Executable) { [long][Security.AccessControl.FileSystemRights]::ReadAndExecute } else { [long][Security.AccessControl.FileSystemRights]::Read } }
        default { throw 'Unknown ACL role.' }
    }
    $permitted = switch ($Role) {
        'owner' { [long][Security.AccessControl.FileSystemRights]::FullControl }
        'modify' { [long][Security.AccessControl.FileSystemRights]::Modify -bor [long][Security.AccessControl.FileSystemRights]::Synchronize }
        'read' { [long][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [long][Security.AccessControl.FileSystemRights]::Synchronize }
    }
    if (($Granted -band $required) -ne $required -or ($Denied -band $required) -ne 0 -or
        ($Granted -band (-bnot $permitted)) -ne 0) {
        throw ("ACL role has missing required or forbidden rights: role={0}; granted={1}; denied={2}; required={3}; permitted={4}; directory={5}; executable={6}" -f
            $Role, $Granted, $Denied, $required, $permitted, $Directory, $Executable)
    }
}

function Assert-RestrictedAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$OperatorSid,
        [string[]]$ReadSids = @(),
        [string[]]$ModifySids = @(),
        # Only writable service trees may opt into service-owned children.
        # Callers must supply the same service SID in ModifySids, so an owner
        # never receives implicit rights from this parameter.
        [string[]]$AllowedOwnerSids = @(),
        [switch]$AllowInherited,
        [switch]$Recurse
    )
    Assert-NoReparsePath $Path
    $targets = @(Get-Item -LiteralPath $Path -Force -ErrorAction Stop)
    if ($Recurse -and $targets[0].PSIsContainer) { $targets += @(Get-LifeOSBoundedTreeItem -Root $Path) }
    $managementOwners = @($OperatorSid, 'S-1-5-18', 'S-1-5-32-544')
    $scopedOwners = @($AllowedOwnerSids | Sort-Object -Unique)
    foreach ($ownerSid in $scopedOwners) {
        if ([string]::IsNullOrWhiteSpace([string]$ownerSid) -or
            [string]$ownerSid -notmatch '\AS-1-5-80-[0-9-]+\z' -or
            [string]$ownerSid -notin @($ModifySids)) {
            throw 'Allowed ACL owner must be a service SID with Modify rights on this managed writable tree.'
        }
    }
    $owners = $managementOwners + $scopedOwners
    $allowed = $managementOwners + $ReadSids + $ModifySids
    foreach ($target in $targets) {
        Assert-NoReparsePath $target.FullName
        $acl = Get-Acl -LiteralPath $target.FullName -ErrorAction Stop
        if (-not $AllowInherited -and -not $acl.AreAccessRulesProtected) { throw "ACL inheritance remains enabled on $Path" }
        $ownerSid = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        if ($ownerSid -notin $owners) { throw 'ACL owner is outside the deployment management boundary.' }
        $granted = @{}; $denied = @{}
        foreach ($sid in $allowed) { $granted[$sid] = [long]0; $denied[$sid] = [long]0 }
        foreach ($entry in $acl.Access) {
            try { $sid = $entry.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
            catch { throw "ACL identity could not be resolved after mutation: $Path" }
            if ($entry.AccessControlType -eq 'Allow' -and $sid -notin $allowed) { throw "Unexpected explicit allow ACL identity on ${Path}: $sid" }
            if ($entry.AccessControlType -ne 'Allow') { throw 'Deny ACL prevents proving the required role rights.' }
            if ($sid -notin $allowed) { continue }
            # InheritOnly grants do not satisfy this object's required rights.
            if (($entry.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
            if ($entry.AccessControlType -eq 'Allow') { $granted[$sid] = $granted[$sid] -bor [long]$entry.FileSystemRights }
            else { $denied[$sid] = $denied[$sid] -bor [long]$entry.FileSystemRights }
        }
        foreach ($sid in $allowed) {
            # Scoped service owners remain the modify role. Ownership is an
            # accepted provenance for the writable tree, never a FullControl
            # grant that could bypass the service ACE check below.
            $role = if ($sid -in $managementOwners) { 'owner' } elseif ($sid -in $ModifySids) { 'modify' } else { 'read' }
            try {
                Assert-AclRoleRights $role $granted[$sid] $denied[$sid] $target.PSIsContainer ([IO.Path]::GetExtension($target.FullName) -in @('.exe', '.dll'))
            } catch {
                throw ("ACL role verification failed: path={0}; identity={1}; {2}" -f
                    $target.FullName, $sid, $_.Exception.Message)
            }
        }
    }
}

function Assert-LifeOSExpectedImmediateChildren {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedChildren,
        [switch]$RequireAll
    )
    if ($null -eq $ExpectedChildren -or $ExpectedChildren.Count -le 0) {
        throw 'Expected shared-root child contract is empty.'
    }

    $rootFull = (Get-FullPath $Root).TrimEnd('\')
    Assert-ExistingDirectory $rootFull 'Expected shared-root parent'
    $rootItem = Get-Item -LiteralPath $rootFull -Force -ErrorAction Stop
    $rootIdentity = New-LifeOSTreeItemIdentity -Item $rootItem -Description 'Expected shared-root parent'
    $expectedNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $serviceSids = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($key in @($ExpectedChildren.Keys)) {
        $name = [string]$key
        if ([string]::IsNullOrWhiteSpace($name) -or
            [IO.Path]::GetFileName($name) -cne $name -or $name -match '[\\/:*?"<>|]' -or
            -not $expectedNames.Add($name)) {
            throw "Expected shared-root child name is invalid or duplicated: $name"
        }
        $serviceSid = [string]$ExpectedChildren[$key]
        if ([string]::IsNullOrWhiteSpace($serviceSid) -or
            $serviceSid -notmatch '\AS-1-5-80-[0-9-]+\z' -or
            -not $serviceSids.Add($serviceSid)) {
            throw "Expected shared-root child service SID is invalid or duplicated: $name"
        }
    }
    if ($serviceSids.Count -ne $expectedNames.Count) {
        throw 'Expected shared-root child contract must map every child to a distinct service SID.'
    }

    $seenNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $children = New-Object 'System.Collections.Generic.List[object]'
    $enumerator = $null
    try {
        # Enumerate only the immediate namespace. The expected-name bound makes
        # an unexpected child fail before it can be retained or traversed.
        $enumerator = [IO.Directory]::EnumerateFileSystemEntries(
            $rootFull, '*', [IO.SearchOption]::TopDirectoryOnly).GetEnumerator()
        while ($enumerator.MoveNext()) {
            if ($seenNames.Count -ge $expectedNames.Count) {
                throw "Unexpected child below shared-root parent: $rootFull"
            }
            $enumeratedPath = [string]$enumerator.Current
            $childItem = Get-Item -LiteralPath $enumeratedPath -Force -ErrorAction Stop
            $childPath = Get-FullPath ([string]$childItem.FullName)
            $parentPath = Get-FullPath (Split-Path -Parent $childPath)
            if ($parentPath.TrimEnd('\') -ine $rootFull) {
                throw "Immediate-child enumeration escaped its shared-root parent: $childPath"
            }
            $name = [IO.Path]::GetFileName($childPath)
            if (-not $expectedNames.Contains($name) -or -not $seenNames.Add($name)) {
                throw "Unexpected or duplicate child below shared-root parent: $name"
            }
            if (-not $childItem.PSIsContainer) {
                throw "Expected shared-root child is not a directory: $childPath"
            }

            $childIdentity = New-LifeOSTreeItemIdentity -Item $childItem -Description 'Expected shared-root child'
            $childChain = @(Get-LifeOSPathIdentityChain -Path $childPath -Description 'Expected shared-root child')
            $expectedServiceSid = $null
            foreach ($key in @($ExpectedChildren.Keys)) {
                if ([string]$key -ieq $name) {
                    $expectedServiceSid = [string]$ExpectedChildren[$key]
                    break
                }
            }
            if ([string]::IsNullOrWhiteSpace($expectedServiceSid)) {
                throw "Expected shared-root child has no service owner mapping: $childPath"
            }

            # This direct-child check catches a service-readable path crossing
            # from the API subtree into the gateway subtree (or vice versa).
            # The existing recursive Assert-RestrictedAcl calls below continue
            # to prove the complete role and rights contract for each subtree.
            $acl = Get-Acl -LiteralPath $childPath -ErrorAction Stop
            foreach ($accessRule in @($acl.Access)) {
                if ($accessRule.AccessControlType -ne 'Allow') { continue }
                try { $accessSid = $accessRule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }
                catch { throw "ACL identity could not be resolved for shared-root child: $childPath" }
                if ($accessSid -in $serviceSids -and $accessSid -ne $expectedServiceSid) {
                    throw "Shared-root child grants cross-service access: $childPath"
                }
            }
            Assert-LifeOSTreeItemIdentity -Path $childPath -Expected $childIdentity -Description 'Expected shared-root child' | Out-Null
            Assert-LifeOSPathIdentityChain -Expected $childChain -Description 'Expected shared-root child' | Out-Null
            [void]$children.Add([pscustomobject]@{
                Name = $name
                Path = $childPath
                Identity = $childIdentity
                PathIdentityChain = $childChain
                ServiceSid = $expectedServiceSid
            })
        }
    } finally {
        if ($null -ne $enumerator) { $enumerator.Dispose() }
    }
    Assert-LifeOSTreeItemIdentity -Path $rootFull -Expected $rootIdentity -Description 'Expected shared-root parent' | Out-Null
    if ($RequireAll -and $seenNames.Count -ne $expectedNames.Count) {
        throw "Expected shared-root child is missing below: $rootFull"
    }
    return @($children.ToArray())
}

function Set-AclSnapshotContext {
    param([Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][string]$ManifestPath, [Parameter(Mandatory)][string]$BackupDirectory)
    $script:LifeOSAclSnapshotContext = [pscustomobject]@{ Manifest = $Manifest; ManifestPath = $ManifestPath; BackupDirectory = $BackupDirectory }
}

function Register-AclSnapshot {
    param([Parameter(Mandatory)][string]$Path, [switch]$RootOnly)
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
    if ($item.PSIsContainer -and -not $RootOnly) {
        # Validate and freeze the complete bounded tree before reading any ACL.
        # The snapshot is read-only, but a post-read identity pass still fails
        # closed if a directory, junction, or child was replaced during it.
        $frozenInventory = @(Get-LifeOSFrozenTreeInventory -Path $full)
        $snapshotEntries = New-Object 'System.Collections.Generic.List[object]'
        [long]$estimatedSnapshotBytes = 0
        $utf8 = [Text.UTF8Encoding]::new($false)
        foreach ($entry in $frozenInventory) {
            Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'ACL snapshot inventory item' | Out-Null
            Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain -Description 'ACL snapshot inventory item' | Out-Null
            $acl = Get-Acl -LiteralPath $entry.Path -ErrorAction Stop
            Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'ACL snapshot inventory item' | Out-Null
            Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain -Description 'ACL snapshot inventory item' | Out-Null
            $sddl = [string]$acl.Sddl
            if ([string]::IsNullOrWhiteSpace($sddl) -or $sddl.Length -gt (256 * 1024)) {
                throw 'ACL snapshot descriptor is empty or exceeds its bounded size.'
            }
            $relative = Get-LifeOSTreeRelativePath -Root $full -Path $entry.Path
            # Reserve a conservative JSON overhead budget before retaining the
            # descriptor. Write-JsonAtomic performs the exact final byte check.
            [long]$entryBytes = [long]$utf8.GetByteCount($relative) + [long]$utf8.GetByteCount($sddl) + 256
            if ($estimatedSnapshotBytes -gt ($script:LifeOSGenerationManifestMaxBytes - $entryBytes)) {
                throw 'ACL snapshot exceeds its bounded serialized size.'
            }
            $estimatedSnapshotBytes += $entryBytes
            [void]$snapshotEntries.Add([ordered]@{
                relative = $relative
                isContainer = [bool]$entry.IsContainer
                sddl = $sddl
            })
        }
        $snapshotPath = Join-Path $context.BackupDirectory ('acl-' + ([Guid]::NewGuid().ToString('N')) + '.acl')
        $snapshotDocument = [ordered]@{
            format = 'LifeOSAclTreeV1'
            destination = $full
            entries = @($snapshotEntries.ToArray())
        }
        Write-JsonAtomic $snapshotPath $snapshotDocument -OperatorSid $context.Manifest.operatorSid -MaxBytes $script:LifeOSGenerationManifestMaxBytes
        [void]$context.Manifest.aclSnapshots.Add([ordered]@{ destination = $full; backup = $snapshotPath; priorExists = $true; mode = 'tree' })
    } else {
        $acl = Get-Acl -LiteralPath $full -ErrorAction Stop
        $snapshotPath = Join-Path $context.BackupDirectory ('acl-' + ([Guid]::NewGuid().ToString('N')) + '.sddl')
        [IO.File]::WriteAllBytes($snapshotPath, [byte[]]@())
        Set-RestrictedAcl -Path $snapshotPath -OperatorSid $context.Manifest.operatorSid -File -SkipSnapshot
        Write-LifeOSDurableBytes $snapshotPath ([Text.UTF8Encoding]::new($false).GetBytes([string]$acl.Sddl))
        [void]$context.Manifest.aclSnapshots.Add([ordered]@{ destination = $full; backup = $snapshotPath; priorExists = $true; mode = 'sddl' })
    }
    Write-JsonAtomic $context.ManifestPath $context.Manifest -OperatorSid $context.Manifest.operatorSid -MaxBytes $script:LifeOSGenerationManifestMaxBytes
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
            # Tree snapshots contain one SDDL descriptor per relative path.
            # Restore descendants before their parents so a restrictive parent
            # DACL cannot remove traversal rights needed by the next target.
            $snapshotDocument = Read-LifeOSBoundedJsonFile -Path $backup -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'ACL rollback tree snapshot'
            $snapshotProperties = @($snapshotDocument.PSObject.Properties.Name)
            $requiredSnapshotProperties = @('destination', 'entries', 'format')
            if ($snapshotProperties.Count -ne $requiredSnapshotProperties.Count -or
                @($requiredSnapshotProperties | Where-Object { $_ -notin $snapshotProperties }).Count -ne 0 -or
                @($snapshotProperties | Where-Object { $_ -notin $requiredSnapshotProperties }).Count -ne 0 -or
                [string]$snapshotDocument.format -cne 'LifeOSAclTreeV1' -or
                (Get-FullPath ([string]$snapshotDocument.destination)) -ine (Get-FullPath $destination)) {
                throw 'ACL rollback tree snapshot is not canonical.'
            }
            if ($null -eq $snapshotDocument.entries -or $snapshotDocument.entries -is [string]) {
                throw 'ACL rollback tree snapshot entries are malformed.'
            }
            $snapshotEntries = @($snapshotDocument.entries)
            if ($snapshotEntries.Count -le 0 -or $snapshotEntries.Count -gt $script:LifeOSRecoveryMaxFileUnits + 1) {
                throw 'ACL rollback tree snapshot has too many entries.'
            }
            $snapshotByRelative = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            $utf8 = [Text.UTF8Encoding]::new($false)
            [long]$snapshotBytes = 0
            foreach ($record in $snapshotEntries) {
                if ($null -eq $record) { throw 'ACL rollback tree snapshot contains a null entry.' }
                $recordProperties = @($record.PSObject.Properties.Name)
                $requiredRecordProperties = @('isContainer', 'relative', 'sddl')
                if ($recordProperties.Count -ne $requiredRecordProperties.Count -or
                    @($requiredRecordProperties | Where-Object { $_ -notin $recordProperties }).Count -ne 0 -or
                    @($recordProperties | Where-Object { $_ -notin $requiredRecordProperties }).Count -ne 0 -or
                    $record.relative -isnot [string] -or $record.isContainer -isnot [bool] -or
                    $record.sddl -isnot [string]) {
                    throw 'ACL rollback tree snapshot entry is malformed.'
                }
                $relative = [string]$record.relative
                if (($relative.Length -gt 0 -and ($relative.Length -gt $script:LifeOSRecoveryMaxPathLength -or
                    $relative -match '(^|/)(?:\.{1,2})(?:/|$)|//|/$|^/|\\|:')) -or
                    $record.sddl.Length -eq 0 -or $record.sddl.Length -gt (256 * 1024)) {
                    throw 'ACL rollback tree snapshot entry is unsafe or oversized.'
                }
                [long]$recordBytes = [long]$utf8.GetByteCount($relative) + [long]$utf8.GetByteCount([string]$record.sddl) + 256
                if ($snapshotBytes -gt ($script:LifeOSGenerationManifestMaxBytes - $recordBytes)) {
                    throw 'ACL rollback tree snapshot exceeds its bounded serialized size.'
                }
                $snapshotBytes += $recordBytes
                if ($snapshotByRelative.ContainsKey($relative)) {
                    throw "ACL rollback tree snapshot contains a duplicate path: $relative"
                }
                [void]$snapshotByRelative.Add($relative, $record)
            }

            $restoreInventory = @(Get-LifeOSFrozenTreeInventory -Path $destination)
            $currentByRelative = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $restoreInventory) {
                $relative = Get-LifeOSTreeRelativePath -Root $destination -Path $entry.Path
                if ($currentByRelative.ContainsKey($relative)) {
                    throw "ACL restore inventory contains a duplicate path: $relative"
                }
                [void]$currentByRelative.Add($relative, $entry)
            }
            if ($currentByRelative.Count -ne $snapshotByRelative.Count) {
                throw 'ACL restore tree contents changed since the snapshot.'
            }
            foreach ($relative in $snapshotByRelative.Keys) {
                if (-not $currentByRelative.ContainsKey($relative)) {
                    throw "ACL restore tree is missing its snapshot path: $relative"
                }
            }
            foreach ($relative in $currentByRelative.Keys) {
                if (-not $snapshotByRelative.ContainsKey($relative)) {
                    throw "ACL restore tree contains an unexpected path: $relative"
                }
            }

            foreach ($entry in @($restoreInventory | Sort-Object -Property @(
                @{ Expression = { ([string]$_.Path).Split('\').Count }; Descending = $true },
                @{ Expression = { [string]$_.Path }; Descending = $false }
            ))) {
                $relative = Get-LifeOSTreeRelativePath -Root $destination -Path $entry.Path
                $record = $snapshotByRelative[$relative]
                if ([bool]$record.isContainer -ne [bool]$entry.IsContainer) {
                    throw "ACL restore tree type changed: $relative"
                }
                # These checks are immediately before the handle-bound native
                # mutation and immediately after it. A replacement of either
                # an ancestor or the leaf therefore fails closed.
                Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'ACL restore inventory item' | Out-Null
                Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain -Description 'ACL restore inventory item' | Out-Null
                $acl = if ($entry.IsContainer) { [Security.AccessControl.DirectorySecurity]::new() } else { [Security.AccessControl.FileSecurity]::new() }
                $acl.SetSecurityDescriptorSddlForm([string]$record.sddl)
                Set-LifeOSAclWithBoundHandle -Path $entry.Path -Acl $acl -Directory ([bool]$entry.IsContainer) -ExpectedChain $entry.PathIdentityChain
                Assert-LifeOSTreeItemIdentity -Path $entry.Path -Expected $entry.Identity -Description 'ACL restore inventory item' | Out-Null
                Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain -Description 'ACL restore inventory item' | Out-Null
            }
        } else {
            $destinationChain = @(Get-LifeOSPathIdentityChain -Path $destination -Description 'ACL rollback destination')
            $destinationItem = Get-Item -LiteralPath $destination -Force -ErrorAction Stop
            $acl = Get-Acl -LiteralPath $destination -ErrorAction Stop
            $acl.SetSecurityDescriptorSddlForm((Read-LifeOSCappedFileText -Path $backup -MaxBytes (256 * 1024) -Description 'ACL rollback descriptor'))
            Set-LifeOSAclWithBoundHandle -Path $destination -Acl $acl -Directory ([bool]$destinationItem.PSIsContainer) -ExpectedChain $destinationChain
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
    $tasks = @(Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $TaskName })
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
    $launcherText = Read-LifeOSCappedFileText -Path $launcherPath -MaxBytes (1 * 1024 * 1024) -Description 'Legacy gateway launcher'
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
    try {
        $connections = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop)
    } catch {
        # CDXML reports an empty filtered CIM result as a terminating error on
        # Windows. Match its structured error identity, never localized text
        # or CimJobException alone: permission/provider failures stay fatal.
        if ($_.FullyQualifiedErrorId -eq 'CmdletizationQuery_NotFound,Get-NetTCPConnection' -and
            $_.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound) {
            return $null
        }
        throw
    }
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
        # The grandparent is used only as a process-chain guard against a
        # deeper Python/uvicorn parent.  Task Scheduler commonly launches the
        # approved PowerShell wrapper through a Windows system executable that
        # is reported as a reparse path; the exact task fingerprint and
        # immediate approved venv-parent checks above already provide the
        # identity proof needed for cutover.  Require an existing file here,
        # but do not reject that legitimate system-wrapper representation.
        if (-not (Test-Path -LiteralPath $grandparentExecutablePath -PathType Leaf)) {
            throw 'The legacy listener grandparent executable does not exist.'
        }
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
    Save-TaskRegistrationIntent $TaskName $xml
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $xml -Force -ErrorAction Stop | Out-Null
}

function Wait-CodexUsageObservation {
    param([Parameter(Mandatory)][uri]$Uri, [int]$TimeoutSeconds = 45, [Parameter(Mandatory)][datetime]$NotBefore, [string]$LocalApiSecretFile = (Join-Path $script:LifeOSDefaultPaths.SecretRoot 'local-api.secret'))
    if ($Uri.AbsoluteUri -ne 'http://127.0.0.1:8787/api/usage') { throw 'Protected usage verification requires the canonical loopback URI.' }
    $headers = Get-LocalApiBearerHeaders $LocalApiSecretFile
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Headers $headers -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 3 -ErrorAction Stop
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
    Restore-TailscaleSnapshotTask $Snapshot $TaskName
}

function Get-TailscaleSnapshotTaskAction {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$TailscaleExecutable,
        [Parameter(Mandatory)][string]$OutputPath
    )
    # One definition of the executable action, shared by registration and by
    # verification, so verify.ps1 cannot drift from what install registers.
    # `$script` is the PowerShell scope-modifier prefix; keep this name distinct.
    $snapshotScript = Get-FullPath $ScriptPath
    Assert-ExistingFile $snapshotScript 'Tailscale snapshot script'
    $tailscale = Get-FullPath $TailscaleExecutable
    Assert-ExistingFile $tailscale 'Tailscale executable'
    $output = Get-FullPath $OutputPath
    $workingDirectory = Split-Path -Parent $snapshotScript
    Assert-ExistingDirectory $workingDirectory 'Tailscale snapshot working directory'
    # SYSTEM runs this script with -ExecutionPolicy Bypass, so write access to
    # the script or its host is SYSTEM code execution. Resolve the Windows
    # PowerShell host explicitly instead of trusting PATH or a shell variable.
    $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Assert-ExistingFile $powershell 'Windows PowerShell host'
    # The field is WorkDir rather than the obvious name: the static suite pins
    # that this file never dereferences a task action's working-directory
    # property directly, because Get-LegacyTaskActionFingerprint must read that
    # XML node through SelectSingleNode -- a missing node would otherwise throw
    # under Set-StrictMode.
    return [pscustomobject]@{
        Command = $powershell
        Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $snapshotScript + '" -TailscaleExecutable "' + $tailscale + '" -OutputPath "' + $output + '"')
        WorkDir = $workingDirectory
        ScriptPath = $snapshotScript
        OutputPath = $output
    }
}

function Register-TailscaleSnapshotTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$TailscaleExecutable,
        [Parameter(Mandatory)][string]$OutputPath
    )
    # The gateway service account is deliberately barred from Tailscale's
    # Administrators-only LocalAPI pipe. This SYSTEM task is the only writer of
    # the bounded, non-secret state file the gateway reads instead.
    Assert-SafeTaskName $TaskName
    $action = Get-TailscaleSnapshotTaskAction -ScriptPath $ScriptPath -TailscaleExecutable $TailscaleExecutable -OutputPath $OutputPath
    $outputParent = Split-Path -Parent $action.OutputPath
    Ensure-Directory $outputParent
    Assert-NoReparsePath $outputParent
    $esc = { param([string]$Value) [Security.SecurityElement]::Escape($Value) }
    $commandXml = & $esc ([string]$action.Command)
    $argsXml = & $esc ([string]$action.Arguments)
    $workXml = & $esc ([string]$action.WorkDir)
    $startBoundary = & $esc ((Get-Date).ToUniversalTime().ToString('s') + 'Z')
    # The gateway is delayed-auto and refuses to start on a snapshot older than
    # 90 seconds, so the file surviving a reboot is not enough: its observedAt
    # does not. A BootTrigger republishes the snapshot before the gateway's
    # delayed autostart, instead of relying on the repetition of a
    # ScheduleByDay trigger resuming after boot. ExecutionTimeLimit is below
    # the repetition interval so one slow run cannot skip the next one under
    # IgnoreNew and open a two-interval gap.
    # Windows' ScheduledTasks cmdlets generate a SYSTEM principal with the
    # SID and RunLevel only. This host rejects the otherwise documented
    # explicit <LogonType>ServiceAccount</LogonType> XML value with error 5,91.
    # Task Scheduler infers the service-account logon type from S-1-5-18 and
    # Get-ScheduledTask reports ServiceAccount after registration.
    $xml = @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>LifeOS Tailscale state snapshot</Description></RegistrationInfo>
  <Triggers><BootTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></BootTrigger><CalendarTrigger><Enabled>true</Enabled><StartBoundary>$startBoundary</StartBoundary><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay><Repetition><Interval>PT1M</Interval><StopAtDurationEnd>false</StopAtDurationEnd></Repetition></CalendarTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings><MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy><DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries><StopIfGoingOnBatteries>false</StopIfGoingOnBatteries><StartWhenAvailable>true</StartWhenAvailable><ExecutionTimeLimit>PT30S</ExecutionTimeLimit><Enabled>true</Enabled></Settings>
  <Actions Context="Author"><Exec><Command>$commandXml</Command><Arguments>$argsXml</Arguments><WorkingDirectory>$workXml</WorkingDirectory></Exec></Actions>
</Task>
"@
    Save-TaskRegistrationIntent $TaskName $xml
    Register-ScheduledTask -TaskName $TaskName -TaskPath '\' -Xml $xml -Force -ErrorAction Stop | Out-Null
}

function Assert-TailscaleSnapshotTaskAction {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$TailscaleExecutable,
        [Parameter(Mandatory)][string]$OutputPath
    )
    # Principal and enabled state say nothing about what the task runs. Bind
    # the exact command, arguments, and working directory so a task repointed
    # at another script fails verification.
    Assert-SafeTaskName $TaskName
    Assert-SafeTaskPath $TaskPath
    $action = Get-TailscaleSnapshotTaskAction -ScriptPath $ScriptPath -TailscaleExecutable $TailscaleExecutable -OutputPath $OutputPath
    $expected = @([string]$action.Command, [string]$action.Arguments, [string]$action.WorkDir) -join "`n"
    $xml = Export-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    # Case-insensitive, like Assert-LegacyTaskUnchanged: the fingerprint is
    # three Windows paths, and Task Scheduler is free to normalize their case.
    if ((Get-LegacyTaskActionFingerprint ([string]$xml)) -ne $expected) {
        throw 'The Tailscale snapshot task does not run the reviewed snapshot writer invocation.'
    }
}

function Assert-TailscaleSnapshotFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ExpectedDnsName,
        [Parameter(Mandatory)][string]$ExpectedLoginName,
        [int]$MaxAgeSeconds = 90,
        [int]$MaxFutureSeconds = 5
    )
    # This mirrors the launcher's reader byte for byte in intent: exact field
    # set, schema version, freshness window, identity match, and Serve shape.
    # Keep the window in sync with TAILSCALE_SNAPSHOT_MAX_AGE_SECONDS and
    # TAILSCALE_SNAPSHOT_MAX_FUTURE_SECONDS in gateway_launcher.py. Nothing
    # read here is ever written to output; the assertions are the only signal.
    Assert-ExistingFile $Path 'Tailscale snapshot'
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ([long]$item.Length -gt $script:LifeOSTailscaleSnapshotMaxBytes) { throw 'Tailscale snapshot is oversized.' }
    try { $snapshot = Read-LifeOSBoundedJsonFile -Path $Path -MaxBytes $script:LifeOSTailscaleSnapshotMaxBytes -Description 'Tailscale snapshot' }
    catch { throw 'Tailscale snapshot is not readable JSON.' }
    if ($null -eq $snapshot -or $snapshot -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Tailscale snapshot is not a JSON object.'
    }
    $fieldNames = @($snapshot.PSObject.Properties | ForEach-Object { [string]$_.Name } | Sort-Object)
    if (($fieldNames -join ',') -cne 'dnsName,identity,login,observedAt,schemaVersion,serve') {
        throw 'Tailscale snapshot field set is not the reviewed schema.'
    }
    # The reader compares `!= 1` against the decoded JSON value, so the string
    # "1" is rejected there. A [int] cast here would coerce it and let the two
    # mirrored validators disagree; require the number ConvertFrom-Json emits.
    if ($snapshot.schemaVersion -isnot [int] -or [int]$snapshot.schemaVersion -ne 1) { throw 'Tailscale snapshot schema version is not 1.' }
    try {
        $observedAt = [DateTimeOffset]::Parse(
            [string]$snapshot.observedAt,
            [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::RoundtripKind).UtcDateTime
    }
    catch { throw 'Tailscale snapshot timestamp is invalid.' }
    $ageSeconds = ((Get-Date).ToUniversalTime() - $observedAt).TotalSeconds
    if ($ageSeconds -lt (0 - $MaxFutureSeconds) -or $ageSeconds -gt $MaxAgeSeconds) {
        throw 'Tailscale snapshot is stale or clock-skewed.'
    }
    if ([string]$snapshot.dnsName -ine $ExpectedDnsName) {
        throw 'Tailscale snapshot DNS name does not match the observed node identity.'
    }
    if ([string]$snapshot.login -cne $ExpectedLoginName) {
        throw 'Tailscale snapshot login does not match the observed node identity.'
    }
    $identitySelf = Get-TailscalePropertyValue -Object $snapshot.identity -Name 'Self'
    $identityDnsName = ([string](Get-TailscalePropertyValue -Object $identitySelf -Name 'DNSName')).TrimEnd('.')
    if ($identityDnsName -ine $ExpectedDnsName) {
        throw 'Tailscale snapshot identity payload does not match its own DNS name.'
    }
    if (-not (Test-TailscaleServeExact ($snapshot.serve | ConvertTo-Json -Depth 20))) {
        throw 'Tailscale snapshot does not record the required private Serve mapping.'
    }
}

function Start-TailscaleSnapshotTaskAndVerify {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [string]$TaskPath = '\',
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ExpectedDnsName,
        [Parameter(Mandatory)][string]$ExpectedLoginName,
        [int]$TimeoutSeconds = 30
    )
    Assert-SafeTaskName $TaskName
    Assert-SafeTaskPath $TaskPath
    $startedAt = Get-Date
    Start-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $completed = $false
    do {
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop
        if ($info.LastRunTime -ge $startedAt.AddSeconds(-2) -and [string]$task.State -ne 'Running') {
            # LastTaskResult is a uint32; the collector uses the same terminal
            # result contract as this snapshot task.
            if ([long]$info.LastTaskResult -ne 0) {
                throw ('Tailscale snapshot task failed with result {0}.' -f $info.LastTaskResult)
            }
            $completed = $true
            break
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if (-not $completed) { throw 'Tailscale snapshot task did not complete successfully before cutover.' }
    # Re-read the file the gateway will read, and re-derive the verdict from
    # the installer's own elevated Tailscale query rather than trusting the
    # task's report that it succeeded.
    Assert-TailscaleSnapshotFile -Path $OutputPath -ExpectedDnsName $ExpectedDnsName -ExpectedLoginName $ExpectedLoginName
}

function Publish-LifeOSTailscaleSnapshotForGatewayStart {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$ExpectedDnsName,
        [Parameter(Mandatory)][string]$ExpectedLoginName,
        [int]$TimeoutSeconds = 30,
        [switch]$RestoreTaskEnabled
    )
    Assert-SafeTaskName $TaskName
    Assert-SafeTaskPath $TaskPath
    $tasks = @(Get-LifeOSScheduledTaskExact -TaskName $TaskName -TaskPath $TaskPath)
    if ($tasks.Count -ne 1) { throw 'The Tailscale snapshot task is not uniquely available for recovery publication.' }
    # Recovery keeps scheduled writers disabled while artifacts and service
    # state are being restored. Open one explicit, bounded task run only after
    # Serve has been restored; close the task again before the gateway starts.
    $stoppedSnapshot = [pscustomobject]@{ Exists = $true; Enabled = [bool]$RestoreTaskEnabled; State = 'Stopped'; TaskPath = $TaskPath }
    Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshot $TaskName
    Enable-ScheduledTask -TaskName $TaskName -TaskPath $TaskPath -ErrorAction Stop | Out-Null
    try {
        Start-TailscaleSnapshotTaskAndVerify -TaskName $TaskName -TaskPath $TaskPath -OutputPath $OutputPath -ExpectedDnsName $ExpectedDnsName -ExpectedLoginName $ExpectedLoginName -TimeoutSeconds $TimeoutSeconds
    } finally {
        # A failed publication must leave the scheduled writer closed and must
        # propagate the original failure so the caller cannot certify recovery.
        Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshot $TaskName
    }
}

function Invoke-LifeOSBeforeGatewayStart {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$TailscaleExecutable,
        [switch]$RestoreTaskEnabled
    )
    # This is the single gateway-start boundary used by install and recovery.
    # The snapshot is published only after the current Serve configuration and
    # identity are re-read, and the caller cannot start the gateway if this
    # helper fails closed. Recovery leaves the periodic task disabled until its
    # final task-state stage; a successful install restores it enabled.
    $identity = Get-TailscaleIdentityFacts $TailscaleExecutable
    Publish-LifeOSTailscaleSnapshotForGatewayStart -TaskName $TaskName -TaskPath $TaskPath -OutputPath $OutputPath -ExpectedDnsName $identity.DnsName -ExpectedLoginName $identity.LoginName -RestoreTaskEnabled:$RestoreTaskEnabled
}

function Restore-TailscaleSnapshotTask {
    param([Parameter(Mandatory)][psobject]$Snapshot, [Parameter(Mandatory)][string]$TaskName, [switch]$KeepStopped)
    Assert-SafeTaskName $TaskName
    $priorPath = if ($null -ne $Snapshot.PSObject.Properties['TaskPath']) { [string]$Snapshot.TaskPath } else { '\' }
    if ([string]::IsNullOrWhiteSpace($priorPath)) { $priorPath = '\' }
    Assert-SafeTaskPath $priorPath
    # Register-TailscaleSnapshotTask always registers at the root task path.
    # When a task of this name pre-existed under some other folder, install
    # created a *second* one at '\'; restoring only the original would leave a
    # SYSTEM task running -ExecutionPolicy Bypass every minute. Remove ours
    # first in that case. When the prior task was itself at '\', the restore
    # below overwrites it in place, so nothing is deleted before it is put
    # back.
    if (($priorPath -ne '\' -or -not [bool]$Snapshot.Exists) -and
        -not ($KeepStopped -and -not [bool]$Snapshot.Exists)) {
        $created = Get-ScheduledTask -ErrorAction Stop | Where-Object { $_.TaskName -eq $TaskName -and $_.TaskPath -eq '\' }
        if ($null -ne $created) {
            Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\' -Confirm:$false -ErrorAction Stop
        }
    }
    if ([bool]$Snapshot.Exists) {
        # Recovery may need the task definition in place before the gateway is
        # started, but the task itself is a privileged state writer. Restore
        # its XML and leave it closed until the explicit publication boundary.
        $restoreSnapshot = $Snapshot
        if ($KeepStopped) {
            $restoreSnapshot = [pscustomobject]@{
                Exists = $true
                Enabled = $false
                State = 'Stopped'
                TaskPath = $priorPath
                Xml = [string]$Snapshot.Xml
            }
        }
        Restore-LegacyTask $restoreSnapshot $TaskName
    } elseif ($KeepStopped) {
        # A new install may be recovering a gateway that predates the
        # snapshot task. Keep the transaction-owned task registered by the
        # failed cutover available for one fresh publication; the final
        # restore stage removes it again when the prior snapshot was absent.
        $current = @(Get-LifeOSScheduledTaskExact -TaskName $TaskName -TaskPath '\')
        if ($current.Count -ne 1) { throw 'The transaction-owned Tailscale snapshot task is unavailable for recovery publication.' }
    }
    if ($KeepStopped) {
        $stoppedSnapshot = [pscustomobject]@{ Exists = $true; Enabled = $false; State = 'Stopped'; TaskPath = $priorPath }
        Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshot $TaskName
    }
}

function Get-ServiceRecord {
    param([Parameter(Mandatory)][string]$Name)
    $record = Get-CimInstance -ClassName Win32_Service -Filter ("Name='{0}'" -f $Name.Replace("'", "''")) -ErrorAction Stop
    if ($null -eq $record) { return $null }
    return $record
}

function Get-ServiceDependencies {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-Service -ErrorAction Stop | Where-Object { $_.Name -eq $Name }
    if ($null -eq $service) { return @() }
    return @($service.ServicesDependedOn | ForEach-Object { [string]$_.Name })
}

function Get-SnapshotValue {
    param([Parameter(Mandatory)][object]$Snapshot, [Parameter(Mandatory)][string]$Name, [object]$Default = $null)
    if ($Snapshot -is [System.Collections.IDictionary] -and $Snapshot.Contains($Name)) { return ,$Snapshot[$Name] }
    $property = $Snapshot.PSObject.Properties[$Name]
    if ($null -ne $property) { return ,$property.Value }
    return ,$Default
}

function Get-LifeOSScheduledTaskExact {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$TaskPath
    )
    # A successful unfiltered enumeration is the only reliable absence test.
    # Provider errors, including ObjectNotFound raised during enumeration, are
    # transport/provider failures and must remain visible to the caller.
    $matches = New-Object System.Collections.ArrayList
    $enumeration = [pscustomobject]@{ Count = 0 }
    Get-ScheduledTask -ErrorAction Stop | ForEach-Object {
        $enumeration.Count++
        if ($enumeration.Count -gt 8192) { throw 'Scheduled task inventory exceeds its bounded enumeration size.' }
        $task = $_
        if ($null -eq $task.PSObject.Properties['TaskName'] -or $null -eq $task.PSObject.Properties['TaskPath']) {
            throw "Scheduled task provider returned an incomplete task record: $TaskName"
        }
        $actualTaskPath = [string]$task.TaskPath
        if ([string]::IsNullOrWhiteSpace($actualTaskPath)) { $actualTaskPath = '\' }
        if ([string]$task.TaskName -ceq $TaskName -and $actualTaskPath -ceq $TaskPath) {
            [void]$matches.Add($task)
        }
    }
    return @($matches.ToArray())
}

function Reconcile-LifeOSScheduledTaskSnapshotState {
    param(
        [Parameter(Mandatory)][object]$Snapshot,
        [Parameter(Mandatory)][string]$TaskName,
        [int]$TimeoutSeconds = 45
    )
    Assert-SafeTaskName $TaskName
    if ($TimeoutSeconds -le 0 -or $TimeoutSeconds -gt 300) { throw 'Scheduled task reconciliation timeout is invalid.' }

    $exists = Get-SnapshotValue $Snapshot 'Exists' $null
    $enabled = Get-SnapshotValue $Snapshot 'Enabled' $null
    $state = Get-SnapshotValue $Snapshot 'State' $null
    if ($exists -isnot [bool] -or $enabled -isnot [bool] -or
        $state -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$state) -or
        [string]$state -notin @('Unknown', 'Disabled', 'Queued', 'Ready', 'Running', 'Stopped')) {
        throw 'Scheduled task snapshot state is malformed.'
    }
    $taskPath = Get-SnapshotValue $Snapshot 'TaskPath' '\'
    if ($taskPath -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$taskPath)) { $taskPath = '\' }
    Assert-SafeTaskPath ([string]$taskPath)
    $expectedRunning = [string]$state -ceq 'Running'
    $expectedEnabled = [bool]$enabled
    if ($expectedRunning -and -not $expectedEnabled) { throw 'Scheduled task snapshot is internally inconsistent.' }

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $enableRequested = $false
    $disableRequested = $false
    $startRequested = $false
    $stopRequested = $false
    do {
        $tasks = @(Get-LifeOSScheduledTaskExact -TaskName $TaskName -TaskPath ([string]$taskPath))
        if (-not [bool]$exists) {
            if ($tasks.Count -ne 0) { throw "Scheduled task remains after recovery: $TaskName" }
            return
        }
        if ($tasks.Count -ne 1) { throw "Scheduled task state is ambiguous after recovery: $TaskName" }
        $task = $tasks[0]
        if ($null -eq $task.PSObject.Properties['TaskPath'] -or $null -eq $task.PSObject.Properties['State']) {
            throw "Scheduled task state is incomplete after recovery: $TaskName"
        }
        $actualPath = [string]$task.TaskPath
        if ([string]::IsNullOrWhiteSpace($actualPath)) { $actualPath = '\' }
        if ($actualPath -cne [string]$taskPath) { throw "Scheduled task path changed during recovery: $TaskName" }
        $actualState = [string]$task.State
        $actualRunning = $actualState -ceq 'Running'
        $actualEnabled = $actualState -cne 'Disabled'
        if ($actualRunning -eq $expectedRunning -and $actualEnabled -eq $expectedEnabled) { return }

        if ($actualRunning -and -not $expectedRunning) {
            if (-not $stopRequested) {
                Stop-ScheduledTask -TaskName $TaskName -TaskPath ([string]$taskPath) -ErrorAction Stop
                $stopRequested = $true
            }
        } elseif ($expectedRunning -and -not $actualRunning) {
            if (-not $actualEnabled -and -not $enableRequested) {
                Enable-ScheduledTask -TaskName $TaskName -TaskPath ([string]$taskPath) -ErrorAction Stop | Out-Null
                $enableRequested = $true
            } elseif ($actualEnabled -and -not $startRequested) {
                Start-ScheduledTask -TaskName $TaskName -TaskPath ([string]$taskPath) -ErrorAction Stop
                $startRequested = $true
            }
        } elseif ($actualEnabled -ne $expectedEnabled) {
            if ($expectedEnabled -and -not $enableRequested) {
                Enable-ScheduledTask -TaskName $TaskName -TaskPath ([string]$taskPath) -ErrorAction Stop | Out-Null
                $enableRequested = $true
            } elseif (-not $expectedEnabled -and -not $disableRequested) {
                Disable-ScheduledTask -TaskName $TaskName -TaskPath ([string]$taskPath) -ErrorAction Stop | Out-Null
                $disableRequested = $true
            }
        }
        if ((Get-Date) -ge $deadline) { throw "Scheduled task did not reach its captured state during recovery: $TaskName" }
        Start-Sleep -Milliseconds 100
    } while ($true)
}

function Get-LifeOSScEmptyArgument {
    # Windows PowerShell 5.1 can drop a literal empty array element when it
    # crosses into a native process. Two quotes are an explicit empty argv
    # value, so sc.exe still receives the password slot.
    return '""'
}

function Get-LifeOSServiceDependencyValue {
    param([AllowNull()][AllowEmptyCollection()][object[]]$Dependencies = @())
    $values = @()
    if ($null -ne $Dependencies) { $values = @($Dependencies) }
    if ($values.Count -gt 64) { throw 'Service dependency list is too large.' }
    foreach ($dependency in $values) {
        if ($dependency -isnot [string]) { throw 'Service dependency values are malformed.' }
        $dependencyText = [string]$dependency
        if ([string]::IsNullOrWhiteSpace($dependencyText) -or $dependencyText.Length -gt 256 -or
            $dependencyText -match '[\x00-\x1F\x7F/"]') {
            throw 'Service dependency values are malformed.'
        }
    }
    if ($values.Count -eq 0) { return '/' }
    return ($values -join '/')
}

function Get-LifeOSServiceConfigArguments {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BinaryPath,
        [Parameter(Mandatory)][string]$StartName,
        [Parameter(Mandatory)][ValidateSet('auto', 'demand', 'disabled', 'delayed-auto')][string]$StartMode,
        [AllowNull()][AllowEmptyCollection()][object[]]$Dependencies = @()
    )
    Assert-SafeTaskName $Name
    if ([string]::IsNullOrWhiteSpace($BinaryPath) -or $BinaryPath.Length -gt 8192 -or [string]$BinaryPath -match '[\x00-\x1F\x7F]') {
        throw "Service binary path is malformed: $Name"
    }
    if ([string]::IsNullOrWhiteSpace($StartName) -or $StartName.Length -gt 256 -or [string]$StartName -match '[\x00-\x1F\x7F"]') {
        throw "Service account is malformed: $Name"
    }
    $dependencyValue = Get-LifeOSServiceDependencyValue $Dependencies
    return [string[]]@(
        'config', $Name, 'binPath=', $BinaryPath, 'obj=', $StartName,
        'password=', (Get-LifeOSScEmptyArgument), 'start=', $StartMode,
        'depend=', $dependencyValue
    )
}

function Get-LifeOSServiceInvocation {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$BinaryPath,
        [Parameter(Mandatory)][string]$ConfigPath
    )
    Assert-SafeTaskName $Name
    $binary = Get-FullPath $BinaryPath
    $config = Get-FullPath $ConfigPath
    if ($binary.Length -gt 8192 -or $config.Length -gt 8192 -or
        $binary -match '[\x00-\x1F\x7F]' -or $config -match '[\x00-\x1F\x7F]') {
        throw "Service invocation paths are malformed: $Name"
    }
    return '"{0}" --service-name {1} --config "{2}"' -f $binary, $Name, $config
}

function Assert-LifeOSSnapshotInteger {
    param([object]$Value, [string]$Field, [string]$Name, [long]$Minimum = 0, [long]$Maximum = [long]::MaxValue)
    $isInteger = $Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or
        $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64]
    if (-not $isInteger -or [long]$Value -lt $Minimum -or [long]$Value -gt $Maximum) {
        throw "Service snapshot field is out of bounds: ${Name}.${Field}"
    }
}

function Assert-CompleteLifeOSServiceSnapshot {
    param([Parameter(Mandatory)][psobject]$Snapshot)
    if ($null -eq $Snapshot) { throw 'Service snapshot is missing.' }
    $expectedFields = @(
        'Name', 'Exists', 'State', 'StartMode', 'StartName', 'BinaryPath', 'Dependencies',
        'DelayedAutoStartPresent', 'DelayedAutoStart', 'ServiceSidTypePresent', 'ServiceSidType',
        'FailureActionsPresent', 'FailureActions', 'FailureFlagPresent', 'FailureFlag'
    )
    $fieldNames = if ($Snapshot -is [System.Collections.IDictionary]) {
        @($Snapshot.Keys | ForEach-Object { [string]$_ })
    } else {
        @($Snapshot.PSObject.Properties | ForEach-Object { [string]$_.Name })
    }
    $fieldSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($fieldName in $fieldNames) {
        if (-not $fieldSet.Add([string]$fieldName)) { throw 'Service snapshot contains duplicate fields.' }
    }
    if ($fieldSet.Count -ne $expectedFields.Count) {
        throw 'Service snapshot is partial or contains unknown fields.'
    }
    foreach ($fieldName in $expectedFields) {
        if (-not $fieldSet.Contains($fieldName)) { throw 'Service snapshot is partial or contains unknown fields.' }
    }

    $nameValue = Get-SnapshotValue $Snapshot 'Name' $null
    if ($nameValue -isnot [string] -or [string]::IsNullOrWhiteSpace($nameValue) -or
        $nameValue -cnotin @('LifeOSAPI', 'LifeOSGateway')) {
        throw 'Service snapshot name is not deployment-owned.'
    }
    Assert-SafeTaskName $nameValue

    $exists = Get-SnapshotValue $Snapshot 'Exists' $null
    if ($exists -isnot [bool]) { throw "Service snapshot existence flag is malformed: $nameValue" }
    $state = Get-SnapshotValue $Snapshot 'State' $null
    $startMode = Get-SnapshotValue $Snapshot 'StartMode' $null
    if ($state -isnot [string] -or $state -cnotin @('Running', 'Stopped')) { throw "Service snapshot state is incomplete: $nameValue" }
    if ($startMode -isnot [string] -or $startMode -cnotin @('Auto', 'Manual', 'Disabled')) { throw "Service snapshot start mode is incomplete: $nameValue" }

    $dependencyValue = Get-SnapshotValue $Snapshot 'Dependencies' $null
    if ($null -eq $dependencyValue -or $dependencyValue -is [string] -or
        $dependencyValue -isnot [System.Collections.IEnumerable]) {
        throw "Service snapshot dependencies are incomplete: $nameValue"
    }
    $dependencies = @($dependencyValue)
    if ($dependencies.Count -gt 64) { throw "Service snapshot dependencies are too large: $nameValue" }
    foreach ($dependency in $dependencies) {
        if ($dependency -isnot [string]) { throw "Service snapshot dependencies are malformed: $nameValue" }
        if ([string]::IsNullOrWhiteSpace($dependency) -or $dependency.Length -gt 256 -or
            $dependency -match '[\x00-\x1F\x7F/"]') {
            throw "Service snapshot dependencies are malformed: $nameValue"
        }
    }
    $dependencySet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dependency in $dependencies) {
        if (-not $dependencySet.Add([string]$dependency)) { throw "Service snapshot dependencies are duplicated: $nameValue" }
    }

    foreach ($field in @('DelayedAutoStartPresent', 'ServiceSidTypePresent', 'FailureActionsPresent', 'FailureFlagPresent')) {
        if ((Get-SnapshotValue $Snapshot $field $null) -isnot [bool]) {
            throw "Service snapshot presence flag is malformed: ${nameValue}.${field}"
        }
    }

    $delayedPresent = Get-SnapshotValue $Snapshot 'DelayedAutoStartPresent' $false
    $delayedValue = Get-SnapshotValue $Snapshot 'DelayedAutoStart' $null
    if ($delayedPresent) {
        Assert-LifeOSSnapshotInteger $delayedValue 'DelayedAutoStart' $nameValue 0 1
    } elseif ($null -ne $delayedValue) {
        throw "Service snapshot has an unpaired delayed-start value: $nameValue"
    }

    $sidPresent = Get-SnapshotValue $Snapshot 'ServiceSidTypePresent' $false
    $sidValue = Get-SnapshotValue $Snapshot 'ServiceSidType' $null
    if ($sidPresent) {
        if ($sidValue -isnot [string] -or $sidValue -cnotin @('none', 'unrestricted', 'restricted')) {
            throw "Service snapshot SID mode is malformed: $nameValue"
        }
    } elseif ($null -ne $sidValue) {
        throw "Service snapshot has an unpaired SID mode: $nameValue"
    }

    $failurePresent = Get-SnapshotValue $Snapshot 'FailureActionsPresent' $false
    $failureValue = Get-SnapshotValue $Snapshot 'FailureActions' $null
    if ($null -eq $failureValue -or $failureValue -is [string] -or $failureValue -isnot [System.Collections.IEnumerable]) {
        throw "Service snapshot failure actions are incomplete: $nameValue"
    }
    $failureActions = @($failureValue)
    if ($failureActions.Count -gt 4096) { throw "Service snapshot failure actions are too large: $nameValue" }
    foreach ($action in $failureActions) {
        Assert-LifeOSSnapshotInteger $action 'FailureActions' $nameValue 0 255
    }
    if (-not $failurePresent -and $failureActions.Count -ne 0) {
        throw "Service snapshot has unpaired failure actions: $nameValue"
    }

    $failureFlagPresent = Get-SnapshotValue $Snapshot 'FailureFlagPresent' $false
    $failureFlag = Get-SnapshotValue $Snapshot 'FailureFlag' $null
    if ($failureFlagPresent) {
        Assert-LifeOSSnapshotInteger $failureFlag 'FailureFlag' $nameValue 0 1
    } elseif ($null -ne $failureFlag) {
        throw "Service snapshot has an unpaired failure flag: $nameValue"
    }

    $startNameValue = Get-SnapshotValue $Snapshot 'StartName' $null
    $binaryPathValue = Get-SnapshotValue $Snapshot 'BinaryPath' $null
    if ($exists) {
        if ($startNameValue -isnot [string] -or [string]::IsNullOrWhiteSpace($startNameValue) -or $startNameValue.Length -gt 256 -or
            $startNameValue -match '[\x00-\x1F\x7F]' -or
            $binaryPathValue -isnot [string] -or [string]::IsNullOrWhiteSpace($binaryPathValue) -or $binaryPathValue.Length -gt 8192 -or
            $binaryPathValue -match '[\x00-\x1F\x7F]') {
            throw "Existing service snapshot configuration is incomplete: $nameValue"
        }
    } elseif ($state -cne 'Stopped' -or $startMode -cne 'Disabled' -or
        $null -ne $startNameValue -or $null -ne $binaryPathValue -or $dependencies.Count -ne 0 -or
        $delayedPresent -or $null -ne $delayedValue -or $sidPresent -or $null -ne $sidValue -or
        $failurePresent -or $failureActions.Count -ne 0 -or $failureFlagPresent -or $null -ne $failureFlag) {
        throw "Absent service snapshot is inconsistent: $nameValue"
    }
}

function Get-LifeOSServiceSnapshotMap {
    param([AllowNull()][object]$Snapshots)
    if ($null -eq $Snapshots) { throw 'Service snapshot map is missing.' }
    $requiredNames = @('LifeOSAPI', 'LifeOSGateway')
    $requiredSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($name in $requiredNames) { [void]$requiredSet.Add($name) }
    $entries = New-Object 'System.Collections.Generic.List[object]'
    if ($Snapshots -is [System.Collections.IDictionary]) {
        foreach ($key in $Snapshots.Keys) {
            if ($entries.Count -ge $requiredNames.Count) { throw 'Service snapshot map must contain exactly both deployment services.' }
            [void]$entries.Add([pscustomobject]@{ Key = [string]$key; Value = $Snapshots[$key] })
        }
    } else {
        foreach ($property in $Snapshots.PSObject.Properties) {
            if ($entries.Count -ge $requiredNames.Count) { throw 'Service snapshot map must contain exactly both deployment services.' }
            [void]$entries.Add([pscustomobject]@{ Key = [string]$property.Name; Value = $property.Value })
        }
    }
    if ($entries.Count -ne $requiredNames.Count) { throw 'Service snapshot map must contain exactly both deployment services.' }
    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $map = [ordered]@{}
    foreach ($entry in $entries) {
        if (-not $requiredSet.Contains($entry.Key) -or -not $seen.Add($entry.Key) -or $null -eq $entry.Value) {
            throw 'Service snapshot map contains an unknown or duplicate service entry.'
        }
        Assert-CompleteLifeOSServiceSnapshot $entry.Value
        $snapshotName = Get-SnapshotValue $entry.Value 'Name' $null
        if ($snapshotName -isnot [string] -or [string]$snapshotName -cne $entry.Key) {
            throw 'Service snapshot map key does not match the enclosed service name.'
        }
        $map[$entry.Key] = $entry.Value
    }
    foreach ($name in $requiredNames) {
        if (-not $seen.Contains($name)) { throw 'Service snapshot map is missing a deployment service entry.' }
    }
    return ,$map
}

function Reconcile-LifeOSServiceSnapshotState {
    param(
        [Parameter(Mandatory)][object]$Snapshots,
        [switch]$VerifyHealth,
        [AllowNull()][scriptblock]$BeforeGatewayStart = $null
    )
    $validatedSnapshots = Get-LifeOSServiceSnapshotMap $Snapshots
    $currentRecords = [System.Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    # Read both SCM records before mutating either service. A provider failure
    # must leave the pair in its prior state rather than half-reconciling it.
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
        $currentRecords[$serviceName] = Get-ServiceRecord $serviceName
    }
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
        $snapshot = $validatedSnapshots[$serviceName]
        $exists = [bool](Get-SnapshotValue $snapshot 'Exists' $false)
        $expectedState = [string](Get-SnapshotValue $snapshot 'State' '')
        $expectedStartMode = [string](Get-SnapshotValue $snapshot 'StartMode' '')
        $current = $currentRecords[$serviceName]
        if (-not $exists) {
            if ($null -ne $current) {
                Stop-LifeOSService $serviceName
                Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('delete', $serviceName)) -Quiet | Out-Null
            }
            for ($attempt = 1; $attempt -le 20; $attempt++) {
                $current = Get-ServiceRecord $serviceName
                if ($null -eq $current) { break }
                if ($attempt -eq 20) { throw "Service remains after rollback deletion: $serviceName" }
                Start-Sleep -Milliseconds 100
            }
            continue
        }
        if ($null -eq $current) { throw "Previously existing service is missing after rollback: $serviceName" }
        if ($expectedState -eq 'Running' -and [string]$current.State -ne 'Running') {
            if ($serviceName -eq 'LifeOSGateway' -and $null -ne $BeforeGatewayStart) { & $BeforeGatewayStart }
            Start-LifeOSService $serviceName
        } elseif ($expectedState -eq 'Stopped' -and [string]$current.State -ne 'Stopped') {
            Stop-LifeOSService $serviceName
        }
        $current = Get-ServiceRecord $serviceName
        if ($null -eq $current -or [string]$current.State -cne $expectedState -or [string]$current.StartMode -cne $expectedStartMode) {
            throw "Service state does not match the captured rollback snapshot: $serviceName"
        }
        if ($VerifyHealth -and $expectedState -eq 'Running') {
            $healthUri = Get-LifeOSServiceHealthUri $serviceName
            if (-not (Wait-LoopbackHealth -Uri $healthUri -TimeoutSeconds 45)) {
                throw "Service health check failed after rollback: $serviceName"
            }
            if (-not (Wait-LoopbackReadiness -Uri (Get-LifeOSServiceReadinessUri $serviceName) -TimeoutSeconds 45)) {
                throw "Service readiness check failed after rollback: $serviceName"
            }
        }
    }
}

function Get-LifeOSServiceHealthUri {
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'LifeOSAPI' { return [uri]'http://127.0.0.1:8787/health' }
        'LifeOSGateway' { return [uri]'http://127.0.0.1:8421/health' }
        default { throw "Unknown LifeOS service health endpoint: $Name" }
    }
}

function Get-LifeOSServiceReadinessUri {
    param([Parameter(Mandatory)][string]$Name)
    switch ($Name) {
        'LifeOSAPI' { return [uri]'http://127.0.0.1:8787/ready' }
        'LifeOSGateway' { return [uri]'http://127.0.0.1:8421/ready' }
        default { throw "Unknown LifeOS service readiness endpoint: $Name" }
    }
}

function Assert-LifeOSServiceSnapshotState {
    param(
        [Parameter(Mandatory)][object]$Snapshots,
        [switch]$VerifyHealth
    )
    $validatedSnapshots = Get-LifeOSServiceSnapshotMap $Snapshots
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
        $snapshot = $validatedSnapshots[$serviceName]
        $exists = [bool](Get-SnapshotValue $snapshot 'Exists' $false)
        $current = Get-ServiceRecord $serviceName
        if (-not $exists) {
            if ($null -ne $current) { throw "Service remains after rollback deletion: $serviceName" }
            continue
        }
        $expectedState = [string](Get-SnapshotValue $snapshot 'State' '')
        $expectedStartMode = [string](Get-SnapshotValue $snapshot 'StartMode' '')
        if ($null -eq $current -or [string]$current.State -cne $expectedState -or [string]$current.StartMode -cne $expectedStartMode) {
            throw "Service state does not match the captured rollback snapshot: $serviceName"
        }
        if ($VerifyHealth -and $expectedState -eq 'Running') {
            if (-not (Wait-LoopbackHealth -Uri (Get-LifeOSServiceHealthUri $serviceName) -TimeoutSeconds 45)) {
                throw "Service health check failed after rollback: $serviceName"
            }
            if (-not (Wait-LoopbackReadiness -Uri (Get-LifeOSServiceReadinessUri $serviceName) -TimeoutSeconds 45)) {
                throw "Service readiness check failed after rollback: $serviceName"
            }
        }
    }
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
    Assert-CompleteLifeOSServiceSnapshot $Snapshot
    if ([string](Get-SnapshotValue $Snapshot 'Name' '') -cne $Name) { throw "Service snapshot name does not match the restore target: $Name" }
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
    Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('sidtype', $Name, $sidType)) -Quiet | Out-Null
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
        $snapshot = [ordered]@{ Name = $Name; Exists = $false; State = 'Stopped'; StartMode = 'Disabled'; StartName = $null; BinaryPath = $null; Dependencies = @(); DelayedAutoStartPresent = $false; DelayedAutoStart = $null; ServiceSidTypePresent = $false; ServiceSidType = $null; FailureActionsPresent = $false; FailureActions = @(); FailureFlagPresent = $false; FailureFlag = $null }
        Assert-CompleteLifeOSServiceSnapshot $snapshot
        return $snapshot
    }
    $registry = Get-LifeOSServiceRegistrySnapshot $Name
    $snapshot = [ordered]@{
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
    Assert-CompleteLifeOSServiceSnapshot $snapshot
    return $snapshot
}

function Restore-LifeOSServiceSnapshot {
    param([Parameter(Mandatory)][psobject]$Snapshot, [switch]$DeferStart)
    Assert-CompleteLifeOSServiceSnapshot $Snapshot
    $name = [string](Get-SnapshotValue $Snapshot 'Name' '')
    $exists = [bool](Get-SnapshotValue $Snapshot 'Exists' $false)
    $startModeValue = [string](Get-SnapshotValue $Snapshot 'StartMode' '')
    $stateValue = [string](Get-SnapshotValue $Snapshot 'State' '')
    $binaryPath = [string](Get-SnapshotValue $Snapshot 'BinaryPath' '')
    $startName = [string](Get-SnapshotValue $Snapshot 'StartName' '')
    $dependencyValues = Get-SnapshotValue $Snapshot 'Dependencies' @()
    $current = Get-ServiceRecord $name
    if (-not $exists) {
        if ($null -ne $current) {
            Stop-LifeOSService $name
            Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('delete', $name)) -Quiet | Out-Null
        }
        return
    }
    if ($null -eq $current) { throw "Cannot restore missing pre-existing service: $name" }
    # Both deployment services are restored while stopped. The caller starts
    # them only after every service configuration has been restored, which
    # prevents Gateway from observing a temporary API configuration.
    Stop-LifeOSService $name
    $startMode = switch ($startModeValue) {
        'Auto' { 'auto'; break }
        'Manual' { 'demand'; break }
        'Disabled' { 'disabled'; break }
        default { throw "Unsupported prior start mode for ${name}: $startModeValue" }
    }
    Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList (Get-LifeOSServiceConfigArguments -Name $name -BinaryPath $binaryPath -StartName $startName -StartMode $startMode -Dependencies $dependencyValues) -Quiet | Out-Null
    Restore-LifeOSServiceRegistrySnapshot $name $Snapshot
    if (-not $DeferStart -and $stateValue -eq 'Running') { Start-LifeOSService $name }
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
        [string[]]$Dependencies = @(),
        [string]$ExpectedExistingBinary = ''
    )
    if ([string]::IsNullOrWhiteSpace($ExpectedExistingBinary)) { $ExpectedExistingBinary = $BinaryPath }
    $quoted = Get-LifeOSServiceInvocation -Name $Name -BinaryPath $BinaryPath -ConfigPath (Join-Path (Split-Path -Parent $BinaryPath) ('config\' + $Name + '.json'))
    $existing = Get-ServiceRecord $Name
    $created = $false
    if ($null -eq $existing) {
        # Virtual service accounts do not need a password.  Omitting the
        # password pair also avoids passing an empty positional argument to
        # PowerShell 5.1's native-command wrapper.
        # A previous `sc delete` can leave a service marked for deletion for a
        # short interval. Treat only ERROR_SERVICE_EXISTS as retryable, then
        # re-read the service before configuring it.
        for ($attempt = 1; $attempt -le 20; $attempt++) {
            $createExit = Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('create', $Name, 'binPath=', $quoted, 'obj=', $Account, 'start=', $StartMode)) -AllowNonZero -Quiet
            if ($createExit -eq 0) { $created = $true; break }
            if ($createExit -ne 1073) { throw "Service creation failed for ${Name} (exit code $createExit)." }
            $existing = Get-ServiceRecord $Name
            if ($null -ne $existing) { break }
            if ($attempt -lt 20) { Start-Sleep -Seconds 1 }
        }
        if (-not $created -and $null -eq $existing) { throw "Service $Name remained unavailable after a bounded service-manager retry." }
    }
    if (-not $created) {
        Assert-ServiceIdentity -Name $Name -ExpectedAccount $Account -ExpectedBinary $ExpectedExistingBinary
    }
    # Use the same argv contract for a newly created service and for rollback:
    # the quoted empty password and `/` dependency sentinel survive the
    # Windows PowerShell 5.1 native boundary as explicit values.
    Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList (Get-LifeOSServiceConfigArguments -Name $Name -BinaryPath $quoted -StartName $Account -StartMode $StartMode -Dependencies $Dependencies) -Quiet | Out-Null
    Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('sidtype', $Name, 'unrestricted')) -Quiet | Out-Null
    Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('failure', $Name, 'reset=', '86400', 'actions=', 'restart/60000/restart/60000/restart/60000')) -Quiet | Out-Null
    Invoke-NativeChecked -FilePath 'sc.exe' -ArgumentList ([string[]]@('failureflag', $Name, '1')) -Quiet | Out-Null
}

function Wait-LifeOSServiceState {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('Running', 'Stopped')][string]$ExpectedState,
        [int]$TimeoutSeconds = 30
    )
    if ($TimeoutSeconds -le 0) { throw 'Service state timeout must be positive.' }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        $record = Get-ServiceRecord $Name
        if ($null -eq $record) { throw "Service disappeared during state transition: $Name" }
        if ([string]$record.State -ceq $ExpectedState) { return }
        if ((Get-Date) -ge $deadline) { break }
        Start-Sleep -Milliseconds 100
    } while ($true)
    throw "Service did not reach its expected state during recovery: $Name ($ExpectedState)"
}

function Stop-LifeOSService {
    param([Parameter(Mandatory)][string]$Name)
    $service = Get-Service -ErrorAction Stop | Where-Object { $_.Name -eq $Name }
    if ($null -ne $service -and $service.Status -ne 'Stopped') {
        Stop-Service -Name $Name -Force -ErrorAction Stop
        $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        Wait-LifeOSServiceState -Name $Name -ExpectedState 'Stopped'
    }
}

function Start-LifeOSService {
    param([Parameter(Mandatory)][string]$Name)
    Start-Service -Name $Name -ErrorAction Stop
    Wait-LifeOSServiceState -Name $Name -ExpectedState 'Running'
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

function Wait-LoopbackReadiness {
    param([Parameter(Mandatory)][uri]$Uri, [int]$TimeoutSeconds = 45)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -MaximumRedirection 0 -TimeoutSec 3 -ErrorAction Stop
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
                $content = [string]$response.Content
                if ([Text.Encoding]::UTF8.GetByteCount($content) -le 16 * 1024) {
                    $payload = $content | ConvertFrom-Json -ErrorAction Stop
                    if ([string]$payload.readiness -ceq 'ready') { return $true }
                }
            }
        } catch { }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Wait-PortFree {
    param([Parameter(Mandatory)][int]$Port, [int]$TimeoutSeconds = 30)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        # Get-NetTCPConnection throws when the CIM query has no matching
        # rows.  An empty listener set is the successful condition here, so
        # treat that expected result as an empty collection rather than
        # turning a completed legacy cutover into a rollback.
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
        if ($listeners.Count -eq 0) { return $true }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-TailscaleStatusJson {
    param([Parameter(Mandatory)][string]$TailscaleExecutable)
    Assert-ExistingFile $TailscaleExecutable 'Tailscale executable'
    $result = Invoke-NativeChecked -FilePath $TailscaleExecutable -ArgumentList ([string[]]@('serve', 'status', '--json'))
    return ($result.Output -join "`n")
}

function Get-TailscaleIdentityFacts {
    param([Parameter(Mandatory)][string]$TailscaleExecutable)
    # Serve configuration and node identity are different Tailscale payloads.
    # The installer runs elevated and can still reach the LocalAPI, so it
    # derives the expected identity itself and never has to trust the SYSTEM
    # snapshot it is verifying. The login is returned for comparison only and
    # is never written to output.
    Assert-ExistingFile $TailscaleExecutable 'Tailscale executable'
    $result = Invoke-NativeChecked -FilePath $TailscaleExecutable -ArgumentList ([string[]]@('status', '--json'))
    try { $state = ($result.Output -join "`n") | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Tailscale status returned invalid JSON; refusing to derive a node identity.' }
    if ($null -eq $state -or $state -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Tailscale status returned a non-object JSON document; refusing to derive a node identity.'
    }
    $self = Get-TailscalePropertyValue -Object $state -Name 'Self'
    $dnsName = ([string](Get-TailscalePropertyValue -Object $self -Name 'DNSName')).TrimEnd('.')
    # `$` also matches immediately before a trailing newline in .NET; \A and
    # \z anchor the whole string, matching the reader's re.fullmatch.
    if ([string]::IsNullOrWhiteSpace($dnsName) -or $dnsName.Length -gt 253 -or
        $dnsName -notmatch '\A(?i:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.(?i:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*\z') {
        throw 'Tailscale node DNS name could not be resolved.'
    }
    # `$profile` is an automatic PowerShell variable; keep this local distinct.
    $login = ''
    $userId = Get-TailscalePropertyValue -Object $self -Name 'UserID'
    $users = Get-TailscalePropertyValue -Object $state -Name 'User'
    if ($null -ne $userId -and $null -ne $users) {
        $userProfile = Get-TailscalePropertyValue -Object $users -Name ([string]$userId)
        if ($null -ne $userProfile) { $login = [string](Get-TailscalePropertyValue -Object $userProfile -Name 'LoginName') }
    }
    if ([string]::IsNullOrWhiteSpace($login)) {
        $userProfile = Get-TailscalePropertyValue -Object $self -Name 'UserProfile'
        if ($null -ne $userProfile) { $login = [string](Get-TailscalePropertyValue -Object $userProfile -Name 'LoginName') }
    }
    if ([string]::IsNullOrWhiteSpace($login) -or $login.Length -gt 256 -or
        $login -notmatch '\A[A-Za-z0-9._+\-]+@[A-Za-z0-9.-]+\z' -or $login.Split('@').Count -ne 2) {
        throw 'Tailscale node login could not be resolved.'
    }
    return [pscustomobject]@{ DnsName = $dnsName; LoginName = $login }
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
    Invoke-NativeChecked -FilePath $TailscaleExecutable -ArgumentList ([string[]]@('serve', '--yes', $trustedCapabilityArgument, '--https=8420', '--set-path=/', 'off')) -Quiet | Out-Null
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
        Invoke-NativeChecked -FilePath $TailscaleExecutable -ArgumentList ([string[]]@('serve', '--yes', '--bg', $trustedCapabilityArgument, '--https=8420', '--set-path=/', 'http://127.0.0.1:8421')) -Quiet | Out-Null
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
    Invoke-NativeChecked -FilePath $TailscaleExecutable -ArgumentList ([string[]]@('serve', '--yes', $trustedCapabilityArgument, '--https=8420', '--set-path=/', 'off')) -Quiet | Out-Null
    $afterOff = Get-TailscaleStatusJson $TailscaleExecutable
    $afterOffDecision = Get-TailscaleServeDecision $afterOff
    if ($afterOffDecision.Action -ne 'Add' -or
        (Get-TailscaleServeFingerprint $afterOff -ExcludeLifeOSRoute) -ne $unrelatedBefore) {
        throw 'Legacy Serve rollback changed the route set while removing the LifeOS mapping; refusing to continue.'
    }

    # Omitting AcceptAppCaps is deliberate: the pre-install handler was
    # exactly proxy-only. The final authenticated snapshot comparison below
    # proves that Tailscale restored the same Web/TCP representation.
    Invoke-NativeChecked -FilePath $TailscaleExecutable -ArgumentList ([string[]]@('serve', '--yes', '--bg', '--https=8420', '--set-path=/', 'http://127.0.0.1:8421')) -Quiet | Out-Null
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
    # A completed restore may precede the journal completion write. Exact
    # pre-install state is already restored, including a legacy proxy route.
    if ((Get-TailscaleServeFingerprint $current) -eq (Get-TailscaleServeFingerprint $Json)) { return }
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

function Write-LifeOSDurableBytes {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][byte[]]$Bytes
    )
    $stream = $null
    try {
        # FileShare.Read prevents a concurrent replacement while the bytes are
        # being written. Flush($true) asks the filesystem to commit the file
        # contents before the caller performs the atomic rename.
        $stream = [IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        if ($Bytes.Length -gt 0) { $stream.Write($Bytes, 0, $Bytes.Length) }
        $stream.Flush($true)
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }
    }
}

function Write-JsonAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Value, [string]$OperatorSid, [long]$MaxBytes = 0)
    if ($MaxBytes -lt 0) { throw 'Atomic JSON byte bound is invalid.' }
    $fullPath = Get-FullPath $Path
    $parent = Split-Path -Parent $fullPath
    Ensure-Directory $parent
    $json = $Value | ConvertTo-Json -Depth 20
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes([string]$json)
    $leaf = [IO.Path]::GetFileName($fullPath)
    $effectiveMaxBytes = $MaxBytes
    if ($effectiveMaxBytes -eq 0) {
        if ($leaf -ieq 'recovery.json') {
            $effectiveMaxBytes = $script:LifeOSRecoveryJournalMaxBytes
        } elseif ($leaf -ieq $script:LifeOSDeploymentMarkerName) {
            $effectiveMaxBytes = $script:LifeOSDeploymentMarkerMaxBytes
        } elseif ($leaf -ieq 'manifest.json') {
            $effectiveMaxBytes = $script:LifeOSGenerationManifestMaxBytes
        } else {
            # Generic JSON is still bounded when a caller omits the optional
            # contract. State documents above pass their exact cap explicitly.
            $effectiveMaxBytes = $script:LifeOSPathOnlyJsonMaxBytes
        }
    }
    if ($leaf -ieq $script:LifeOSDeploymentMarkerName) {
        Assert-LifeOSDeploymentMarkerCheckpointCapacity $Value | Out-Null
    } elseif ($leaf -ieq 'manifest.json') {
        Assert-LifeOSGenerationManifestCheckpointCapacity $Value | Out-Null
    }
    if ($effectiveMaxBytes -gt 0 -and $bytes.Length -gt $effectiveMaxBytes) {
        throw 'Atomic JSON value exceeds its bounded serialized size.'
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($fullPath) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        if ($OperatorSid) {
            [IO.File]::WriteAllBytes($temp, [byte[]]@())
            Set-RestrictedAcl -Path $temp -OperatorSid $OperatorSid -File -SkipSnapshot
        }
        Write-LifeOSDurableBytes -Path $temp -Bytes $bytes
        Assert-NoReparsePath $temp
        Move-Item -LiteralPath $temp -Destination $fullPath -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
}

function Assert-PathOnlyJson {
    param([Parameter(Mandatory)][string]$Path)
    $raw = Read-LifeOSCappedFileText -Path $Path -MaxBytes $script:LifeOSPathOnlyJsonMaxBytes -Description 'Path-only JSON config'
    if ($raw -match '(?i)(bearer|password|token|secret-value|api[-_]?key|private[-_]?key)\s*[:=]') {
        throw "Path-only config contains a secret-like field: $Path"
    }
    $null = $raw | ConvertFrom-Json -ErrorAction Stop
}
