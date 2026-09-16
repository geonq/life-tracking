[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TailscaleExecutable,
    [Parameter(Mandatory)][string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Mirrors Get-TailscalePropertyValue in Deployment.Common.ps1. This script is
# staged into host\ on its own, without the deployment module, so the null-safe
# accessor is replicated rather than dot-sourced: under Set-StrictMode a raw
# $Object.PSObject.Properties['X'].Value throws PropertyNotFoundException when
# tailscaled is still starting and reports no Self at all.
function Get-SnapshotPropertyValue {
    param([object]$Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'The Tailscale snapshot writer requires Windows.'
}

# This script is staged on its own and runs as a scheduled SYSTEM task. Keep
# the small native boundary here instead of dot-sourcing the much larger
# deployment module. The writer validates every existing path component and
# holds those directory handles without FILE_SHARE_DELETE while it publishes;
# kernel32 FileRenameInfo is then given the absolute destination path because
# current Windows builds reject its documented non-null RootDirectory form.
if ($null -eq ('LifeOSSnapshotNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

public sealed class LifeOSSnapshotPathInfo
{
    public string Identity;
    public uint Attributes;
    public uint NumberOfLinks;
    public bool IsDirectory;
}

public static class LifeOSSnapshotNative
{
    private const uint GenericRead = 0x80000000u;
    private const uint GenericWrite = 0x40000000u;
    private const uint FileReadAttributes = 0x00000080u;
    private const uint ReadControl = 0x00020000u;
    private const uint Delete = 0x00010000u;
    private const uint DeleteChild = 0x00000040u;
    private const uint FileAddFile = 0x00000002u;
    private const uint FileShareRead = 0x00000001u;
    private const uint FileShareWrite = 0x00000002u;
    private const uint FileShareDelete = 0x00000004u;
    private const uint OpenExisting = 3u;
    private const uint FileFlagBackupSemantics = 0x02000000u;
    private const uint FileFlagOpenReparsePoint = 0x00200000u;
    private const uint FileFlagSequentialScan = 0x08000000u;
    private const int FileRenameInfo = 3;
    private const int FileDispositionInfo = 4;
    private const uint CreateNew = 1u;

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

    [StructLayout(LayoutKind.Sequential)]
    private struct FileDispositionInformation
    {
        public byte DeleteFile;
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

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFileInformationByHandle(
        SafeFileHandle handle,
        int fileInformationClass,
        IntPtr fileInformation,
        uint bufferSize);

    private static void ThrowLastError(string operation)
    {
        int error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, operation + " failed (Win32 " + error + ").");
    }

    private static SafeFileHandle Open(
        string path, uint desiredAccess, uint shareMode, uint creationDisposition, uint flags)
    {
        SafeFileHandle handle = CreateFile(
            path,
            desiredAccess,
            shareMode,
            IntPtr.Zero,
            creationDisposition,
            flags,
            IntPtr.Zero);
        if (handle == null || handle.IsInvalid) { ThrowLastError("Opening " + path); }
        return handle;
    }

    public static SafeFileHandle OpenDirectory(string path)
    {
        return Open(
            path,
            FileReadAttributes | ReadControl | FileAddFile | DeleteChild,
            FileShareRead | FileShareWrite,
            OpenExisting,
            FileFlagBackupSemantics | FileFlagOpenReparsePoint);
    }

    public static SafeFileHandle CreateExclusiveForWrite(string path)
    {
        return Open(
            path,
            GenericRead | GenericWrite | Delete,
            FileShareRead | FileShareWrite | FileShareDelete,
            CreateNew,
            FileFlagOpenReparsePoint | FileFlagSequentialScan);
    }

    public static LifeOSSnapshotPathInfo InspectHandle(SafeFileHandle handle)
    {
        if (handle == null || handle.IsInvalid) { throw new IOException("Invalid file handle."); }
        ByHandleFileInformation information;
        if (!GetFileInformationByHandle(handle, out information)) {
            ThrowLastError("Reading file identity");
        }
        return new LifeOSSnapshotPathInfo {
            Identity = string.Format(
                "{0:X8}:{1:X8}{2:X8}",
                information.VolumeSerialNumber,
                information.FileIndexHigh,
                information.FileIndexLow),
            Attributes = information.FileAttributes,
            NumberOfLinks = information.NumberOfLinks,
            IsDirectory = (information.FileAttributes & 0x10u) != 0u
        };
    }

    public static LifeOSSnapshotPathInfo Inspect(string path, bool directory)
    {
        using (SafeFileHandle handle = Open(
            path,
            FileReadAttributes | ReadControl,
            FileShareRead | FileShareWrite | FileShareDelete,
            OpenExisting,
            FileFlagOpenReparsePoint | (directory ? FileFlagBackupSemantics : 0u)))
        {
            return InspectHandle(handle);
        }
    }

    public static void RenameWithHeldParent(
        SafeFileHandle source, SafeFileHandle parent, string destinationPath, bool replaceExisting)
    {
        if (source == null || source.IsInvalid || parent == null || parent.IsInvalid) {
            throw new IOException("Snapshot rename received an invalid handle.");
        }
        // Modern Windows builds reject a non-null FILE_RENAME_INFO.RootDirectory
        // with ERROR_INVALID_PARAMETER, even though the public structure
        // documents relative names. The caller still holds this validated
        // parent handle (and every ancestor) without FILE_SHARE_DELETE, so an
        // attacker cannot replace the inspected directory while this absolute
        // path is resolved. The final component is a rename target entry, not
        // a file-open operation, so a reparse-point target cannot redirect it.
        bool localDrivePath = destinationPath != null && destinationPath.Length >= 3 &&
            Char.IsLetter(destinationPath[0]) && destinationPath[1] == ':' &&
            (destinationPath[2] == '\\' || destinationPath[2] == '/');
        if (String.IsNullOrEmpty(destinationPath) || !localDrivePath ||
            destinationPath.IndexOf('\0') >= 0 || destinationPath.IndexOf('\r') >= 0 ||
            destinationPath.IndexOf('\n') >= 0) {
            throw new ArgumentException(
                "Snapshot destination path is invalid (local drive=" + localDrivePath +
                ", length=" + (destinationPath == null ? -1 : destinationPath.Length) +
                ").", "destinationPath");
        }
        byte[] name = Encoding.Unicode.GetBytes(destinationPath + "\0");
        int rootOffset = IntPtr.Size == 8 ? 8 : 4;
        int lengthOffset = rootOffset + IntPtr.Size;
        int nameOffset = lengthOffset + 4;
        int size = nameOffset + name.Length;
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            for (int i = 0; i < size; i++) { Marshal.WriteByte(buffer, i, 0); }
            Marshal.WriteByte(buffer, 0, (byte)(replaceExisting ? 1 : 0));
            Marshal.WriteIntPtr(buffer, rootOffset, IntPtr.Zero);
            Marshal.WriteInt32(buffer, lengthOffset, name.Length - sizeof(char));
            Marshal.Copy(name, 0, IntPtr.Add(buffer, nameOffset), name.Length);
            if (!SetFileInformationByHandle(source, FileRenameInfo, buffer, (uint)size)) {
                ThrowLastError("Publishing snapshot");
            }
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public static void DeleteByHandle(SafeFileHandle handle)
    {
        if (handle == null || handle.IsInvalid) { return; }
        FileDispositionInformation info = new FileDispositionInformation { DeleteFile = 1 };
        int size = Marshal.SizeOf(typeof(FileDispositionInformation));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(info, buffer, false);
            if (!SetFileInformationByHandle(handle, FileDispositionInfo, buffer, (uint)size)) {
                ThrowLastError("Deleting temporary snapshot");
            }
        }
        finally { Marshal.FreeHGlobal(buffer); }
    }

    public static byte[] ReadBounded(SafeFileHandle handle, int maxBytes)
    {
        if (handle == null || handle.IsInvalid) { throw new IOException("Invalid snapshot handle."); }
        using (FileStream stream = new FileStream(handle, FileAccess.Read, 8192, false))
        using (MemoryStream memory = new MemoryStream())
        {
            stream.Position = 0;
            byte[] buffer = new byte[8192];
            int total = 0;
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) {
                if (count > maxBytes - total) { throw new InvalidDataException("Snapshot exceeds its byte bound."); }
                memory.Write(buffer, 0, count);
                total += count;
            }
            return memory.ToArray();
        }
    }

    private static string QuoteArgument(string value)
    {
        if (value == null) { return "\"\""; }
        bool quote = value.Length == 0;
        for (int i = 0; i < value.Length && !quote; i++) {
            quote = Char.IsWhiteSpace(value[i]) || value[i] == '\"';
        }
        if (!quote) { return value; }
        StringBuilder result = new StringBuilder();
        result.Append('\"');
        int slashes = 0;
        for (int i = 0; i < value.Length; i++) {
            char current = value[i];
            if (current == '\\') { slashes++; continue; }
            if (current == '\"') {
                result.Append('\\', slashes * 2 + 1);
                result.Append('\"');
            } else {
                result.Append('\\', slashes);
                result.Append(current);
            }
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        result.Append('\"');
        return result.ToString();
    }

    private static string ReadOutput(Stream stream, int maxBytes, CancellationToken token)
    {
        using (MemoryStream memory = new MemoryStream())
        {
            byte[] buffer = new byte[8192];
            int total = 0;
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) {
                token.ThrowIfCancellationRequested();
                if (count > maxBytes - total) { throw new InvalidDataException("Tailscale output exceeds its byte bound."); }
                memory.Write(buffer, 0, count);
                total += count;
            }
            return new UTF8Encoding(false, true).GetString(memory.ToArray());
        }
    }

    public static string RunBounded(string executable, string[] arguments, int timeoutMs, int maxBytes)
    {
        ProcessStartInfo startInfo = new ProcessStartInfo {
            FileName = executable,
            Arguments = String.Join(" ", Array.ConvertAll(arguments, QuoteArgument)),
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = Environment.SystemDirectory
        };
        using (Process process = new Process { StartInfo = startInfo })
        using (CancellationTokenSource cancellation = new CancellationTokenSource())
        {
            if (!process.Start()) { throw new InvalidOperationException("Tailscale process did not start."); }
            Task<string> output = Task.Factory.StartNew(
                () => ReadOutput(process.StandardOutput.BaseStream, maxBytes, cancellation.Token),
                cancellation.Token, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            Task<string> error = Task.Factory.StartNew(
                () => ReadOutput(process.StandardError.BaseStream, maxBytes, cancellation.Token),
                cancellation.Token, TaskCreationOptions.LongRunning, TaskScheduler.Default);
            try
            {
                Task all = Task.WhenAll(output, error);
                if (!all.Wait(timeoutMs)) {
                    cancellation.Cancel();
                    try { if (!process.HasExited) { process.Kill(); } } catch { }
                    try { process.WaitForExit(2000); } catch { }
                    try { Task.WaitAll(new Task[] { output, error }, 2000); } catch { }
                    throw new TimeoutException("Tailscale query timed out.");
                }
                // A bounded reader can fault before the child exits (for
                // example when stdout crosses the cap). Never wait forever on
                // a child whose pipe reader has already stopped consuming.
                if (output.IsFaulted || error.IsFaulted || !process.HasExited) {
                    cancellation.Cancel();
                    try { if (!process.HasExited) { process.Kill(); } } catch { }
                    try { process.WaitForExit(2000); } catch { }
                    try { Task.WaitAll(new Task[] { output, error }, 2000); } catch { }
                    if (output.IsFaulted) { throw output.Exception.InnerException; }
                    if (error.IsFaulted) { throw error.Exception.InnerException; }
                    throw new IOException("Tailscale output reader stopped before process exit.");
                }
                process.WaitForExit();
                if (process.ExitCode != 0) {
                    throw new InvalidOperationException("Tailscale query failed with exit code " + process.ExitCode + ".");
                }
                return output.Result;
            }
            catch
            {
                cancellation.Cancel();
                try { if (!process.HasExited) { process.Kill(); } } catch { }
                try { process.WaitForExit(2000); } catch { }
                try { Task.WaitAll(new Task[] { output, error }, 2000); } catch { }
                throw;
            }
        }
    }
}
'@ -ErrorAction Stop | Out-Null
}

function Get-SnapshotFullPath {
    param([Parameter(Mandatory)][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not [IO.Path]::IsPathRooted($Path) -or
        $Path.IndexOf([char]0) -ge 0 -or $Path.Contains("`r") -or $Path.Contains("`n")) {
        throw 'Tailscale snapshot path must be an absolute path without NUL bytes.'
    }
    $full = [IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^[A-Za-z]:\\') { throw 'Tailscale snapshot path must use a fully qualified local drive path.' }
    return $full
}

function Get-SnapshotIdentityChain {
    param([Parameter(Mandatory)][string]$Path)
    $full = Get-SnapshotFullPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    $current = $root
    $chain = New-Object 'System.Collections.Generic.List[object]'
    foreach ($segment in ($full.Substring($root.Length) -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $segment
        $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        $info = [LifeOSSnapshotNative]::Inspect($current, [bool]$item.PSIsContainer)
        if (([uint32]$info.Attributes -band [uint32]0x400) -ne [uint32]0) { throw "Snapshot path contains a reparse point: $current" }
        [void]$chain.Add([pscustomobject]@{
            Path = [IO.Path]::GetFullPath($current)
            Identity = [string]$info.Identity
            Attributes = [uint32]$info.Attributes
            NumberOfLinks = [uint32]$info.NumberOfLinks
            IsDirectory = [bool]$info.IsDirectory
        })
    }
    if ($chain.Count -eq 0) { throw 'Snapshot path has no existing components.' }
    return $chain.ToArray()
}

function Assert-SnapshotIdentityChain {
    param([Parameter(Mandatory)][object[]]$Expected, [Parameter(Mandatory)][string]$Description)
    $actual = @(Get-SnapshotIdentityChain ([string]$Expected[$Expected.Count - 1].Path))
    if ($actual.Count -ne $Expected.Count) { throw "$Description ancestor identity changed." }
    for ($index = 0; $index -lt $Expected.Count; $index++) {
        if ([string]$actual[$index].Identity -cne [string]$Expected[$index].Identity -or
            [uint32]$actual[$index].Attributes -ne [uint32]$Expected[$index].Attributes -or
            [bool]$actual[$index].IsDirectory -ne [bool]$Expected[$index].IsDirectory) {
            throw "$Description ancestor identity changed."
        }
    }
}

function ConvertTo-SnapshotSid {
    param([Parameter(Mandatory)][object]$Identity)
    try {
        if ($Identity -is [Security.Principal.SecurityIdentifier]) { return [string]$Identity.Value }
        return [string]([Security.Principal.NTAccount]::new([string]$Identity)).Translate([Security.Principal.SecurityIdentifier]).Value
    } catch { throw 'Snapshot ACL contains an identity that cannot be resolved to a SID.' }
}

function Get-SnapshotGatewaySid {
    try {
        return ConvertTo-SnapshotSid ([Security.Principal.NTAccount]::new('NT SERVICE\LifeOSGateway'))
    } catch { throw 'The LifeOSGateway service SID is not resolvable.' }
}

function Get-SnapshotAllowedOwnerSids {
    param([Parameter(Mandatory)][string]$GatewaySid)
    $allowed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', $GatewaySid)) { [void]$allowed.Add($sid) }
    try { [void]$allowed.Add(([Security.Principal.WindowsIdentity]::GetCurrent()).User.Value) } catch { }
    try {
        $operatorName = [string](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).UserName
        if (-not [string]::IsNullOrWhiteSpace($operatorName)) { [void]$allowed.Add((ConvertTo-SnapshotSid $operatorName)) }
    } catch { }
    return @($allowed)
}

function Assert-SnapshotReaderAccess {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$GatewaySid, [Parameter(Mandatory)][object]$Acl)
    $readMask = [int64][Security.AccessControl.FileSystemRights]::Read
    $mutationMask = [int64]([Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $hasRead = $false
    foreach ($rule in @($Acl.Access)) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = ConvertTo-SnapshotSid $rule.IdentityReference
        if ($sid -cne $GatewaySid) { continue }
        $rights = [int64]$rule.FileSystemRights
        if (($rights -band $mutationMask) -ne 0) { throw "Snapshot grants LifeOSGateway write access: $Path" }
        if (($rights -band $readMask) -ne 0) { $hasRead = $true }
    }
    if (-not $hasRead) { throw "Snapshot does not grant LifeOSGateway read access: $Path" }
}

function Assert-SnapshotSecurity {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$GatewaySid)
    try { $acl = Get-Acl -LiteralPath $Path -ErrorAction Stop } catch { throw "Cannot inspect snapshot security: $Path" }
    $ownerSid = ConvertTo-SnapshotSid $acl.Owner
    if ($ownerSid -notin @(Get-SnapshotAllowedOwnerSids -GatewaySid $GatewaySid)) {
        throw "Snapshot path has an unsafe owner: $Path"
    }
    $broadSids = @('S-1-1-0', 'S-1-2-0', 'S-1-5-4', 'S-1-5-11', 'S-1-5-32-545')
    $mutationMask = [int64]([Security.AccessControl.FileSystemRights]::WriteData -bor
        [Security.AccessControl.FileSystemRights]::AppendData -bor
        [Security.AccessControl.FileSystemRights]::WriteExtendedAttributes -bor
        [Security.AccessControl.FileSystemRights]::WriteAttributes -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $trustedWriterSids = @('S-1-5-18', 'S-1-5-32-544') + @(Get-SnapshotAllowedOwnerSids -GatewaySid $GatewaySid)
    foreach ($rule in @($acl.Access)) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        $sid = ConvertTo-SnapshotSid $rule.IdentityReference
        $hasMutation = (([int64]$rule.FileSystemRights -band $mutationMask) -ne 0)
        if ($hasMutation -and $sid -notin $trustedWriterSids) {
            throw "Snapshot path grants mutation access to an untrusted SID: $Path"
        }
        if ($hasMutation -and $sid -in $broadSids) {
            throw "Snapshot path grants broad write access: $Path"
        }
    }
    Assert-SnapshotReaderAccess -Path $Path -GatewaySid $GatewaySid -Acl $acl
}

function Set-SnapshotRestrictedFileSecurity {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$GatewaySid)
    $security = [Security.AccessControl.FileSecurity]::new()
    $security.SetAccessRuleProtection($true, $false)
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $admins = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    foreach ($account in @($system, $admins)) {
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            $account,
            [Security.AccessControl.FileSystemRights]::FullControl,
            [Security.AccessControl.InheritanceFlags]::None,
            [Security.AccessControl.PropagationFlags]::None,
            [Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }
    $gateway = [Security.Principal.SecurityIdentifier]::new($GatewaySid)
    $gatewayRule = [Security.AccessControl.FileSystemAccessRule]::new(
        $gateway,
        [Security.AccessControl.FileSystemRights]::Read,
        [Security.AccessControl.InheritanceFlags]::None,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($gatewayRule)
    $security.SetOwner($system)
    Set-Acl -LiteralPath $Path -AclObject $security -ErrorAction Stop
    Assert-SnapshotSecurity -Path $Path -GatewaySid $GatewaySid
}

function Get-JsonFromTailscale {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $TailscaleExecutable -PathType Leaf)) {
        throw 'Tailscale executable is missing.'
    }
    $runner = $TailscaleExecutable
    $runnerArguments = [System.Collections.Generic.List[string]]::new()
    if ([IO.Path]::GetExtension($TailscaleExecutable) -ieq '.ps1') {
        # The behavior suite uses a PowerShell fake. Production task actions
        # point at the reviewed tailscale.exe and stay on the direct native
        # path; this explicit fixture adapter keeps the same bounded process
        # contract without handing a script to CreateProcess.
        $runner = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw 'Windows PowerShell host is missing.' }
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $TailscaleExecutable)) {
            [void]$runnerArguments.Add([string]$argument)
        }
    }
    foreach ($argument in $Arguments) { [void]$runnerArguments.Add([string]$argument) }
    $json = [LifeOSSnapshotNative]::RunBounded($runner, $runnerArguments.ToArray(), 15000, 256 * 1024)
    if ([string]::IsNullOrWhiteSpace($json)) { throw 'Tailscale status query returned no output.' }
    try {
        $value = $json | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw 'Tailscale status query returned invalid JSON.'
    }
    if ($null -eq $value -or $value -isnot [System.Management.Automation.PSCustomObject]) {
        throw 'Tailscale status query returned a non-object JSON value.'
    }
    return $value
}

function Get-TailscaleLogin {
    param([Parameter(Mandatory)][psobject]$Identity)
    $self = Get-SnapshotPropertyValue -Object $Identity -Name 'Self'
    $login = $null
    if ($null -ne $self) {
        $users = Get-SnapshotPropertyValue -Object $Identity -Name 'User'
        $userId = Get-SnapshotPropertyValue -Object $self -Name 'UserID'
        if ($null -ne $users -and $null -ne $userId) {
            # `$profile` would shadow the automatic PowerShell profile path
            # variable under Set-StrictMode; keep this local name distinct.
            $userProfile = Get-SnapshotPropertyValue -Object $users -Name ([string]$userId)
            if ($null -ne $userProfile) {
                $login = [string](Get-SnapshotPropertyValue -Object $userProfile -Name 'LoginName')
            }
        }
        if ([string]::IsNullOrWhiteSpace($login)) {
            $userProfile = Get-SnapshotPropertyValue -Object $self -Name 'UserProfile'
            if ($null -ne $userProfile) {
                $login = [string](Get-SnapshotPropertyValue -Object $userProfile -Name 'LoginName')
            }
        }
    }
    # `$` also matches immediately before a trailing newline in .NET, so a
    # login carrying one would pass here and be rejected by the reader's
    # re.fullmatch after cutover. \A and \z anchor the whole string.
    if ([string]::IsNullOrWhiteSpace($login) -or $login.Length -gt 256 -or $login -notmatch '\A[A-Za-z0-9._+\-]+@[A-Za-z0-9.-]+\z' -or $login.Split('@').Count -ne 2) {
        throw 'Tailscale login could not be resolved.'
    }
    return $login
}

function Get-TailscaleDnsName {
    param([Parameter(Mandatory)][psobject]$Identity)
    $self = Get-SnapshotPropertyValue -Object $Identity -Name 'Self'
    $dnsName = ([string](Get-SnapshotPropertyValue -Object $self -Name 'DNSName')).TrimEnd('.')
    if ([string]::IsNullOrWhiteSpace($dnsName) -or $dnsName.Length -gt 253 -or $dnsName -notmatch '\A(?i:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)(?:\.(?i:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?))*\z') {
        throw 'Tailscale DNS name could not be resolved.'
    }
    return $dnsName
}

$identity = Get-JsonFromTailscale @('status', '--json')
$serve = Get-JsonFromTailscale @('serve', 'status', '--json')
$dnsName = Get-TailscaleDnsName $identity
$login = Get-TailscaleLogin $identity
# `tailscale status --json` carries the whole tailnet: every peer, node key,
# and Tailscale IP. The gateway reads only `Self.DNSName`, so publish that one
# field. A pruned identity cannot leak the topology into a file the gateway
# service account can read, and it keeps the payload far below the reader's
# 256 KiB bound.
$prunedIdentity = [ordered]@{
    Self = [ordered]@{ DNSName = $dnsName }
}
$payload = [ordered]@{
    schemaVersion = 1
    observedAt = (Get-Date).ToUniversalTime().ToString('o')
    dnsName = $dnsName
    login = $login
    serve = $serve
    identity = $prunedIdentity
}
$outputFull = Get-SnapshotFullPath $OutputPath
$parent = Split-Path -Parent $outputFull
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Tailscale snapshot parent directory is missing.' }
$leaf = [IO.Path]::GetFileName($outputFull)
if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -in @('.', '..') -or $leaf.Length -gt 255 -or
    $leaf.TrimEnd(' .') -cne $leaf -or $leaf -match '[:<>"/\\|?*]' -or
    $leaf -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
    throw 'Tailscale snapshot leaf name is invalid.'
}
$gatewaySid = Get-SnapshotGatewaySid
$parentChain = @(Get-SnapshotIdentityChain $parent)
Assert-SnapshotSecurity -Path $parent -GatewaySid $gatewaySid
$ancestorHandles = @()
$parentHandle = $null
$tempHandle = $null
$stream = $null
$tempHandleInfo = $null
$temp = Join-Path $parent ('.tailscale-state.' + [Guid]::NewGuid().ToString('N') + '.tmp')
$published = $false
$priorDestination = $null
if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
    $priorDestination = [LifeOSSnapshotNative]::Inspect($outputFull, $false)
    if (([uint32]$priorDestination.Attributes -band [uint32]0x400) -ne [uint32]0 -or $priorDestination.NumberOfLinks -ne 1) {
        throw 'Existing Tailscale snapshot is a reparse point or hardlink.'
    }
    Assert-SnapshotSecurity -Path $outputFull -GatewaySid $gatewaySid
} elseif (Test-Path -LiteralPath $outputFull) {
    throw 'Tailscale snapshot destination is not a regular file.'
}
# ServeConfig nests Web -> endpoint -> Handlers -> path -> handler fields;
# depth 20 keeps every reviewed level plus room for an unknown future field.
# PowerShell truncates silently past -Depth, so the reader's exact-shape check
# would reject a truncated payload rather than accept a wrong one.
$json = $payload | ConvertTo-Json -Depth 20
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
# Refuse to publish what the gateway would reject at startup: the writer fails
# loudly here instead of leaving an oversized file behind.
if ($bytes.Length -gt (256 * 1024)) { throw 'Tailscale snapshot payload is oversized.' }
try {
    Assert-SnapshotIdentityChain -Expected $parentChain -Description 'Tailscale snapshot parent'
    foreach ($ancestor in $parentChain) {
        $ancestorHandles += [LifeOSSnapshotNative]::OpenDirectory([string]$ancestor.Path)
    }
    $parentHandle = $ancestorHandles[$ancestorHandles.Count - 1]
    $parentHandleInfo = [LifeOSSnapshotNative]::InspectHandle($parentHandle)
    if ([string]$parentHandleInfo.Identity -cne [string]$parentChain[$parentChain.Count - 1].Identity) {
        throw 'Tailscale snapshot parent changed before opening.'
    }
    $tempHandle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($temp)
    $stream = [IO.FileStream]::new($tempHandle, [IO.FileAccess]::ReadWrite, 8192, $false)
    Set-SnapshotRestrictedFileSecurity -Path $temp -GatewaySid $gatewaySid
    if ($bytes.Length -gt 256 * 1024) { throw 'Tailscale snapshot payload is oversized.' }
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Flush($true)
    Assert-SnapshotSecurity -Path $temp -GatewaySid $gatewaySid
    $tempHandleInfo = [LifeOSSnapshotNative]::InspectHandle($tempHandle)
    if (([uint32]$tempHandleInfo.Attributes -band [uint32]0x400) -ne [uint32]0 -or $tempHandleInfo.NumberOfLinks -ne 1) {
        throw 'Temporary Tailscale snapshot is a reparse point or hardlink.'
    }
    Assert-SnapshotIdentityChain -Expected $parentChain -Description 'Tailscale snapshot parent'
    $destinationNowExists = Test-Path -LiteralPath $outputFull -PathType Leaf
    if ($null -ne $priorDestination) {
        if (-not $destinationNowExists) { throw 'Tailscale snapshot destination disappeared before publication.' }
        $destinationBeforePublish = [LifeOSSnapshotNative]::Inspect($outputFull, $false)
        if ([string]$destinationBeforePublish.Identity -cne [string]$priorDestination.Identity -or
            ([uint32]$destinationBeforePublish.Attributes -band [uint32]0x400) -ne [uint32]0 -or
            $destinationBeforePublish.NumberOfLinks -ne 1) {
            throw 'Tailscale snapshot destination changed before publication.'
        }
        Assert-SnapshotSecurity -Path $outputFull -GatewaySid $gatewaySid
    } elseif ($destinationNowExists) {
        throw 'Tailscale snapshot destination appeared before publication.'
    }
    [LifeOSSnapshotNative]::RenameWithHeldParent($tempHandle, $parentHandle, $outputFull, $null -ne $priorDestination)
    $published = $true
    $final = [LifeOSSnapshotNative]::InspectHandle($tempHandle)
    if ([string]$final.Identity -cne [string]$tempHandleInfo.Identity -or
        ([uint32]$final.Attributes -band [uint32]0x400) -ne [uint32]0 -or $final.NumberOfLinks -ne 1) {
        throw 'Published Tailscale snapshot identity verification failed.'
    }
    $finalPath = [LifeOSSnapshotNative]::Inspect($outputFull, $false)
    if ([string]$finalPath.Identity -cne [string]$final.Identity -or
        ([uint32]$finalPath.Attributes -band [uint32]0x400) -ne [uint32]0 -or
        $finalPath.NumberOfLinks -ne 1) {
        throw 'Published Tailscale snapshot destination identity verification failed.'
    }
    Assert-SnapshotSecurity -Path $outputFull -GatewaySid $gatewaySid
    $finalBytes = [LifeOSSnapshotNative]::ReadBounded($tempHandle, 256 * 1024)
    if (-not [Convert]::ToBase64String($finalBytes).Equals([Convert]::ToBase64String($bytes), [StringComparison]::Ordinal)) {
        throw 'Published Tailscale snapshot byte verification failed.'
    }
    Assert-SnapshotIdentityChain -Expected $parentChain -Description 'Tailscale snapshot parent'
} finally {
    if (-not $published -and $null -ne $tempHandle) {
        try { [LifeOSSnapshotNative]::DeleteByHandle($tempHandle) } catch { }
    }
    if ($null -ne $stream) {
        $stream.Dispose()
        $stream = $null
    }
    if ($null -ne $tempHandle) { $tempHandle.Dispose(); $tempHandle = $null }
    for ($index = $ancestorHandles.Count - 1; $index -ge 0; $index--) {
        if ($null -ne $ancestorHandles[$index]) { $ancestorHandles[$index].Dispose() }
    }
    $ancestorHandles = @()
    $parentHandle = $null
}
