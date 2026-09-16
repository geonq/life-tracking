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
    // Keep these native constants named at the call sites. The job is the
    // descendant cleanup boundary, while the suspended process prevents a
    // child from escaping before it is assigned to that job.
    private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000u;
    private const uint CREATE_SUSPENDED = 0x00000004u;
    private const uint CREATE_NO_WINDOW = 0x08000000u;
    private const int JobObjectExtendedLimitInformationClass = 9;
    private const uint FileBegin = 0u;
    private const uint FileCurrent = 1u;
    private const uint ErrorHandleEof = 38u;
    private const uint ErrorInsufficientBuffer = 122u;
    private const uint ErrorAccessDenied = 5u;
    private const uint DuplicateSameAccess = 2u;
    private const uint HandleFlagInherit = 1u;
    private const uint WaitObject0 = 0u;
    private const uint WaitTimeout = 258u;
    private const uint WaitFailed = 0xFFFFFFFFu;
    private const uint CleanupTimeoutMilliseconds = 2000u;
    private const int StartfUseStdHandles = 0x00000100;
    private const uint ExtendedStartupInfoPresent = 0x00080000u;
    private const uint ProcThreadAttributeHandleList = 0x00020002u;
    private const int FileRenameInfo = 3;
    private const int FileDispositionInfo = 4;
    private const int JobObjectBasicAccountingInformationClass = 1;
    private const uint CreateNew = 1u;
    // REPLACEFILE_WRITE_THROUGH is documented as unsupported. Passing zero
    // keeps the ReplaceFileW contract portable across supported Windows builds.
    private const uint ReplaceFileFlags = 0u;

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

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeSecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfo
    {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct StartupInfoEx
    {
        public StartupInfo StartupInfo;
        public IntPtr AttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicAccountingInformation
    {
        public long TotalUserTime;
        public long TotalKernelTime;
        public long ThisPeriodTotalUserTime;
        public long ThisPeriodTotalKernelTime;
        public uint TotalPageFaultCount;
        public uint TotalProcesses;
        public uint ActiveProcesses;
        public uint TotalTerminatedProcesses;
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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
    private static extern SafeFileHandle CreateFileWithSecurity(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        ref NativeSecurityAttributes securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ConvertStringSecurityDescriptorToSecurityDescriptor(
        string stringSecurityDescriptor,
        uint stringSDRevision,
        out IntPtr securityDescriptor,
        out uint securityDescriptorSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DuplicateHandle(
        IntPtr sourceProcessHandle,
        SafeFileHandle sourceHandle,
        IntPtr targetProcessHandle,
        out IntPtr targetHandle,
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint options);

    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetFilePointerEx(
        SafeFileHandle handle,
        long distanceToMove,
        out long newFilePointer,
        uint moveMethod);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadFile(
        SafeFileHandle handle,
        [Out] byte[] buffer,
        uint bytesToRead,
        out uint bytesRead,
        IntPtr overlapped);

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

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "ReplaceFileW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReplaceFileWithBackup(
        string replacedFileName,
        string replacementFileName,
        string backupFileName,
        uint replaceFlags,
        IntPtr exclude,
        IntPtr reserved);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr CreateJobObject(
        IntPtr jobAttributes,
        string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        SafeFileHandle job,
        int informationClass,
        IntPtr information,
        uint informationLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryInformationJobObject(
        SafeFileHandle job,
        int informationClass,
        out JobObjectBasicAccountingInformation information,
        uint informationLength,
        out uint returnLength);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(
        SafeFileHandle job,
        SafeFileHandle process);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateJobObject(
        SafeFileHandle job,
        uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(
        SafeFileHandle handle,
        uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetExitCodeProcess(
        SafeFileHandle process,
        out uint exitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(SafeFileHandle thread);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreatePipe(
        out IntPtr readPipe,
        out IntPtr writePipe,
        ref NativeSecurityAttributes pipeAttributes,
        uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetHandleInformation(
        IntPtr handle,
        uint mask,
        uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr attributeList,
        int attributeCount,
        uint flags,
        ref IntPtr size);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr attributeList,
        uint flags,
        IntPtr attribute,
        IntPtr value,
        IntPtr size,
        IntPtr previousValue,
        IntPtr returnSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(
        string applicationName,
        StringBuilder commandLine,
        IntPtr processAttributes,
        IntPtr threadAttributes,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
        uint creationFlags,
        IntPtr environment,
        string currentDirectory,
        ref StartupInfoEx startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool TerminateProcess(
        SafeFileHandle process,
        uint exitCode);

    private static void ThrowLastError(string operation)
    {
        int error = Marshal.GetLastWin32Error();
        throw new Win32Exception(error, operation + " failed (Win32 " + error + ").");
    }

    private static void ThrowLastError(string operation, int error)
    {
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

    public static SafeFileHandle CreateExclusiveForWrite(string path, string gatewaySid)
    {
        string normalizedGatewaySid;
        try
        {
            normalizedGatewaySid =
                new System.Security.Principal.SecurityIdentifier(gatewaySid).Value;
        }
        catch (Exception error)
        {
            throw new ArgumentException("The Gateway SID is invalid.", "gatewaySid", error);
        }

        // The descriptor is installed by CreateFile itself. There is no
        // inherited or default-DACL window before the later PowerShell
        // validation and the defensive Set-Acl pass.
        string securityDescriptorText =
            "O:SYD:P(A;;FA;;;SY)(A;;FA;;;BA)(A;;FR;;;" + normalizedGatewaySid + ")";
        IntPtr securityDescriptor = IntPtr.Zero;
        try
        {
            uint securityDescriptorSize;
            if (!ConvertStringSecurityDescriptorToSecurityDescriptor(
                    securityDescriptorText,
                    1u,
                    out securityDescriptor,
                    out securityDescriptorSize))
            {
                ThrowLastError("Building temporary snapshot security");
            }
            NativeSecurityAttributes securityAttributes = new NativeSecurityAttributes {
                Length = Marshal.SizeOf(typeof(NativeSecurityAttributes)),
                SecurityDescriptor = securityDescriptor,
                InheritHandle = 0
            };
            SafeFileHandle handle = CreateFileWithSecurity(
                path,
                GenericRead | GenericWrite | Delete,
                FileShareRead | FileShareWrite | FileShareDelete,
                ref securityAttributes,
                CreateNew,
                FileFlagOpenReparsePoint | FileFlagSequentialScan,
                IntPtr.Zero);
            if (handle == null || handle.IsInvalid)
            {
                int error = Marshal.GetLastWin32Error();
                if (handle != null) { handle.Dispose(); }
                ThrowLastError("Creating exclusive temporary snapshot", error);
            }
            return handle;
        }
        finally
        {
            if (securityDescriptor != IntPtr.Zero) { LocalFree(securityDescriptor); }
        }
    }

    public static SafeFileHandle OpenExistingForRename(string path)
    {
        return Open(
            path,
            GenericRead | ReadControl | Delete,
            // Keep the validated handle composable with post-publication
            // verification and rollback code that opens the same leaf.
            FileShareRead | FileShareWrite | FileShareDelete,
            OpenExisting,
            FileFlagOpenReparsePoint | FileFlagSequentialScan);
    }

    public static SafeFileHandle OpenExistingForDelete(string path)
    {
        return Open(
            path,
            GenericRead | ReadControl | Delete,
            FileShareRead | FileShareWrite | FileShareDelete,
            OpenExisting,
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

    public static void ReplaceFileAtomically(
        string destinationPath, string replacementPath, string backupPath)
    {
        string[] paths = new string[] { destinationPath, replacementPath, backupPath };
        for (int index = 0; index < paths.Length; index++)
        {
            string path = paths[index];
            bool localDrivePath = path != null && path.Length >= 3 &&
                Char.IsLetter(path[0]) && path[1] == ':' &&
                (path[2] == '\\' || path[2] == '/');
            if (String.IsNullOrEmpty(path) || !localDrivePath ||
                path.IndexOf('\0') >= 0 || path.IndexOf('\r') >= 0 || path.IndexOf('\n') >= 0)
            {
                throw new ArgumentException("Snapshot replacement path is invalid.", "path");
            }
        }
        if (!ReplaceFileWithBackup(
                destinationPath,
                replacementPath,
                backupPath,
                ReplaceFileFlags,
                IntPtr.Zero,
                IntPtr.Zero))
        {
            ThrowLastError("Atomically replacing snapshot");
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
        if (maxBytes < 0) { throw new ArgumentOutOfRangeException("maxBytes"); }

        // DuplicateHandle gives this method a private lifetime, but Windows
        // duplicates share the file object's cursor. Save and restore the
        // caller position; callers must not use this handle concurrently.
        // The caller's SafeFileHandle remains open and owned by the caller,
        // including when it is still wrapped by a writer FileStream.
        IntPtr duplicateRaw;
        if (!DuplicateHandle(
                GetCurrentProcess(),
                handle,
                GetCurrentProcess(),
                out duplicateRaw,
                0u,
                false,
                DuplicateSameAccess))
        {
            ThrowLastError("Duplicating snapshot read handle");
        }
        using (SafeFileHandle duplicate = new SafeFileHandle(duplicateRaw, true))
        using (MemoryStream memory = new MemoryStream())
        {
            long originalPosition;
            if (!SetFilePointerEx(handle, 0L, out originalPosition, FileCurrent)) {
                ThrowLastError("Reading snapshot handle position");
            }
            long position;
            if (!SetFilePointerEx(duplicate, 0L, out position, FileBegin)) {
                ThrowLastError("Seeking snapshot read handle");
            }
            try
            {
                byte[] buffer = new byte[8192];
                int total = 0;
                while (true) {
                    uint count;
                    if (!ReadFile(duplicate, buffer, (uint)buffer.Length, out count, IntPtr.Zero)) {
                        int error = Marshal.GetLastWin32Error();
                        if ((uint)error == ErrorHandleEof) { break; }
                        ThrowLastError("Reading snapshot");
                    }
                    if (count == 0u) { break; }
                    if ((long)count > (long)maxBytes - total) {
                        throw new InvalidDataException("Snapshot exceeds its byte bound.");
                    }
                    memory.Write(buffer, 0, (int)count);
                    total += (int)count;
                }
                return memory.ToArray();
            }
            finally
            {
                // Windows duplicates share the file object's current pointer.
                // Restore it so a caller-owned FileStream can continue using
                // its handle after this bounded read returns or throws.
                long restoredPosition;
                if (!SetFilePointerEx(handle, originalPosition, out restoredPosition, FileBegin)) {
                    ThrowLastError("Restoring snapshot handle position");
                }
            }
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

    private static string ReadOutput(Stream stream, int maxBytes, CancellationToken token, string streamName)
    {
        using (MemoryStream memory = new MemoryStream())
        {
            byte[] buffer = new byte[8192];
            int total = 0;
            int count;
            while ((count = stream.Read(buffer, 0, buffer.Length)) > 0) {
                token.ThrowIfCancellationRequested();
                if (count > maxBytes - total) {
                    throw new InvalidDataException(
                        "Tailscale " + streamName + " output exceeds its byte bound.");
                }
                memory.Write(buffer, 0, count);
                total += count;
            }
            return new UTF8Encoding(false, true).GetString(memory.ToArray());
        }
    }

    private static SafeFileHandle CreateKillOnCloseJob()
    {
        IntPtr rawJob = CreateJobObject(IntPtr.Zero, null);
        if (rawJob == IntPtr.Zero) { ThrowLastError("Creating Tailscale process job"); }
        SafeFileHandle job = new SafeFileHandle(rawJob, true);
        JobObjectExtendedLimitInformation limits =
            new JobObjectExtendedLimitInformation();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        int size = Marshal.SizeOf(typeof(JobObjectExtendedLimitInformation));
        IntPtr buffer = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, buffer, false);
            if (!SetInformationJobObject(job, JobObjectExtendedLimitInformationClass, buffer, (uint)size)) {
                int error = Marshal.GetLastWin32Error();
                job.Dispose();
                ThrowLastError("Configuring Tailscale process job", error);
            }
            return job;
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    private static SafeFileHandle CreateInheritedNullInput()
    {
        NativeSecurityAttributes attributes = new NativeSecurityAttributes {
            Length = Marshal.SizeOf(typeof(NativeSecurityAttributes)),
            SecurityDescriptor = IntPtr.Zero,
            InheritHandle = 1
        };
        SafeFileHandle input = CreateFileWithSecurity(
            "NUL",
            GenericRead,
            FileShareRead | FileShareWrite,
            ref attributes,
            OpenExisting,
            0u,
            IntPtr.Zero);
        if (input == null || input.IsInvalid) {
            int error = Marshal.GetLastWin32Error();
            if (input != null) { input.Dispose(); }
            ThrowLastError("Opening child standard input", error);
        }
        return input;
    }

    private static string BuildCommandLine(string executable, string[] arguments)
    {
        StringBuilder commandLine = new StringBuilder(QuoteArgument(executable));
        if (arguments != null) {
            for (int index = 0; index < arguments.Length; index++) {
                commandLine.Append(' ');
                commandLine.Append(QuoteArgument(arguments[index]));
            }
        }
        return commandLine.ToString();
    }

    private static Exception GetReaderException(Task<string> reader)
    {
        if (reader != null && reader.Exception != null &&
            reader.Exception.InnerException != null) {
            return reader.Exception.InnerException;
        }
        return new IOException("Tailscale output reader stopped unexpectedly.");
    }

    private static uint GetActiveProcessCount(SafeFileHandle job)
    {
        if (job == null || job.IsInvalid) { return 0u; }
        JobObjectBasicAccountingInformation accounting;
        uint returnLength;
        if (!QueryInformationJobObject(
                job,
                JobObjectBasicAccountingInformationClass,
                out accounting,
                (uint)Marshal.SizeOf(typeof(JobObjectBasicAccountingInformation)),
                out returnLength)) {
            ThrowLastError("Querying Tailscale process job");
        }
        return accounting.ActiveProcesses;
    }

    private static long CreateDeadline(uint milliseconds)
    {
        long now = Stopwatch.GetTimestamp();
        double tickCount = ((double)milliseconds * (double)Stopwatch.Frequency) / 1000.0;
        if (tickCount >= (double)Int64.MaxValue) { return Int64.MaxValue; }
        long duration = (long)Math.Ceiling(tickCount);
        if (duration <= 0L) { duration = 1L; }
        if (now > Int64.MaxValue - duration) { return Int64.MaxValue; }
        return now + duration;
    }

    private static uint RemainingMilliseconds(long deadline)
    {
        long remainingTicks = deadline - Stopwatch.GetTimestamp();
        if (remainingTicks <= 0L) { return 0u; }
        double remaining = ((double)remainingTicks * 1000.0) / (double)Stopwatch.Frequency;
        if (remaining >= (double)UInt32.MaxValue) { return UInt32.MaxValue; }
        return (uint)Math.Ceiling(remaining);
    }

    private static void WaitForJobToEmpty(SafeFileHandle job, long deadline)
    {
        uint activeProcesses = GetActiveProcessCount(job);
        while (activeProcesses != 0u) {
            uint remaining = RemainingMilliseconds(deadline);
            if (remaining == 0u) {
                throw new IOException(
                    "Tailscale child cleanup left " + activeProcesses + " active job process(es).");
            }
            Thread.Sleep((int)Math.Min(25u, remaining));
            activeProcesses = GetActiveProcessCount(job);
        }
    }

    private static void TerminateProcessAndWait(SafeFileHandle process, long deadline)
    {
        if (process == null || process.IsInvalid) { return; }
        StringBuilder cleanupFailures = new StringBuilder();
        bool terminated = TerminateProcess(process, 1u);
        int terminationError = terminated ? 0 : Marshal.GetLastWin32Error();
        // ERROR_ACCESS_DENIED can mean the process exited between the failure
        // and this cleanup call. The wait below is the authoritative check.
        if (!terminated && terminationError != (int)ErrorAccessDenied) {
            cleanupFailures.Append("TerminateProcess Win32 ");
            cleanupFailures.Append(terminationError);
        }
        uint processWait = WaitForSingleObject(process, RemainingMilliseconds(deadline));
        if (processWait != WaitObject0) {
            if (cleanupFailures.Length > 0) { cleanupFailures.Append(';'); }
            cleanupFailures.Append("process wait result ");
            cleanupFailures.Append(processWait);
        }
        if (cleanupFailures.Length > 0) {
            throw new IOException("Tailscale child cleanup was incomplete: " + cleanupFailures.ToString());
        }
    }

    private static void TerminateJobAndWait(
        SafeFileHandle job,
        SafeFileHandle process,
        long deadline)
    {
        StringBuilder cleanupFailures = new StringBuilder();
        if (job != null && !job.IsInvalid) {
            bool terminated = TerminateJobObject(job, 1u);
            int terminationError = terminated ? 0 : Marshal.GetLastWin32Error();
            if (!terminated && terminationError != (int)ErrorAccessDenied) {
                cleanupFailures.Append("TerminateJobObject Win32 ");
                cleanupFailures.Append(terminationError);
            }
        }
        if (process != null && !process.IsInvalid) {
            uint processWait = WaitForSingleObject(process, RemainingMilliseconds(deadline));
            if (processWait != WaitObject0) {
                if (cleanupFailures.Length > 0) { cleanupFailures.Append(';'); }
                cleanupFailures.Append("process wait result ");
                cleanupFailures.Append(processWait);
            }
        }
        if (job != null && !job.IsInvalid) {
            try {
                // A job handle is not a general completion notification. Query
                // the accounting object until ActiveProcesses reaches zero.
                WaitForJobToEmpty(job, deadline);
            } catch (Exception error) {
                if (cleanupFailures.Length > 0) { cleanupFailures.Append(';'); }
                cleanupFailures.Append(error.Message);
            }
        }
        if (cleanupFailures.Length > 0) {
            throw new IOException("Tailscale child cleanup was incomplete: " + cleanupFailures.ToString());
        }
    }

    public static string RunBounded(string executable, string[] arguments, int timeoutMs, int maxBytes)
    {
        if (String.IsNullOrWhiteSpace(executable)) {
            throw new ArgumentException("Executable is required.", "executable");
        }
        if (timeoutMs <= 0) { throw new ArgumentOutOfRangeException("timeoutMs"); }
        if (maxBytes < 0) { throw new ArgumentOutOfRangeException("maxBytes"); }

        long deadline = CreateDeadline((uint)timeoutMs);
        SafeFileHandle job = null;
        SafeFileHandle processHandle = null;
        SafeFileHandle threadHandle = null;
        SafeFileHandle stdinHandle = null;
        SafeFileHandle stdoutReadHandle = null;
        SafeFileHandle stdoutWriteHandle = null;
        SafeFileHandle stderrReadHandle = null;
        SafeFileHandle stderrWriteHandle = null;
        FileStream stdoutStream = null;
        FileStream stderrStream = null;
        CancellationTokenSource cancellation = null;
        Task<string> output = null;
        Task<string> error = null;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr inheritedHandleList = IntPtr.Zero;
        bool attributeListInitialized = false;
        try
        {
            job = CreateKillOnCloseJob();
            NativeSecurityAttributes pipeAttributes = new NativeSecurityAttributes {
                Length = Marshal.SizeOf(typeof(NativeSecurityAttributes)),
                SecurityDescriptor = IntPtr.Zero,
                InheritHandle = 1
            };
            IntPtr rawRead;
            IntPtr rawWrite;
            if (!CreatePipe(out rawRead, out rawWrite, ref pipeAttributes, 0u)) {
                ThrowLastError("Creating Tailscale stdout pipe");
            }
            stdoutReadHandle = new SafeFileHandle(rawRead, true);
            stdoutWriteHandle = new SafeFileHandle(rawWrite, true);
            if (!SetHandleInformation(
                    stdoutReadHandle.DangerousGetHandle(),
                    HandleFlagInherit,
                    0u)) {
                ThrowLastError("Protecting Tailscale stdout pipe");
            }
            if (!CreatePipe(out rawRead, out rawWrite, ref pipeAttributes, 0u)) {
                ThrowLastError("Creating Tailscale stderr pipe");
            }
            stderrReadHandle = new SafeFileHandle(rawRead, true);
            stderrWriteHandle = new SafeFileHandle(rawWrite, true);
            if (!SetHandleInformation(
                    stderrReadHandle.DangerousGetHandle(),
                    HandleFlagInherit,
                    0u)) {
                ThrowLastError("Protecting Tailscale stderr pipe");
            }
            stdinHandle = CreateInheritedNullInput();

            StartupInfoEx startup = new StartupInfoEx {
                StartupInfo = new StartupInfo {
                cb = Marshal.SizeOf(typeof(StartupInfoEx)),
                dwFlags = StartfUseStdHandles,
                hStdInput = stdinHandle.DangerousGetHandle(),
                hStdOutput = stdoutWriteHandle.DangerousGetHandle(),
                hStdError = stderrWriteHandle.DangerousGetHandle()
                }
            };
            IntPtr attributeListSize = IntPtr.Zero;
            bool sizingSucceeded = InitializeProcThreadAttributeList(
                IntPtr.Zero, 1, 0u, ref attributeListSize);
            int sizingError = Marshal.GetLastWin32Error();
            if (sizingSucceeded || attributeListSize == IntPtr.Zero ||
                (uint)sizingError != ErrorInsufficientBuffer) {
                ThrowLastError("Sizing child process attributes", sizingError);
            }
            attributeList = Marshal.AllocHGlobal(attributeListSize);
            if (!InitializeProcThreadAttributeList(
                    attributeList, 1, 0u, ref attributeListSize)) {
                ThrowLastError("Initializing child process attributes");
            }
            attributeListInitialized = true;
            IntPtr[] inheritedHandles = new IntPtr[] {
                stdinHandle.DangerousGetHandle(),
                stdoutWriteHandle.DangerousGetHandle(),
                stderrWriteHandle.DangerousGetHandle()
            };
            inheritedHandleList = Marshal.AllocHGlobal(IntPtr.Size * inheritedHandles.Length);
            for (int index = 0; index < inheritedHandles.Length; index++) {
                Marshal.WriteIntPtr(inheritedHandleList, index * IntPtr.Size, inheritedHandles[index]);
            }
            if (!UpdateProcThreadAttribute(
                    attributeList,
                    0u,
                    new IntPtr(unchecked((long)ProcThreadAttributeHandleList)),
                    inheritedHandleList,
                    new IntPtr(IntPtr.Size * inheritedHandles.Length),
                    IntPtr.Zero,
                    IntPtr.Zero)) {
                ThrowLastError("Restricting child inherited handles");
            }
            startup.AttributeList = attributeList;
            ProcessInformation processInformation;
            StringBuilder commandLine =
                new StringBuilder(BuildCommandLine(executable, arguments));
            if (!CreateProcess(
                    executable,
                    commandLine,
                    IntPtr.Zero,
                    IntPtr.Zero,
                    true,
                    CREATE_SUSPENDED | CREATE_NO_WINDOW | ExtendedStartupInfoPresent,
                    IntPtr.Zero,
                    Environment.SystemDirectory,
                    ref startup,
                    out processInformation)) {
                ThrowLastError("Starting Tailscale process");
            }
            if (attributeListInitialized) {
                DeleteProcThreadAttributeList(attributeList);
                attributeListInitialized = false;
            }
            if (inheritedHandleList != IntPtr.Zero) {
                Marshal.FreeHGlobal(inheritedHandleList);
                inheritedHandleList = IntPtr.Zero;
            }
            processHandle = new SafeFileHandle(processInformation.Process, true);
            threadHandle = new SafeFileHandle(processInformation.Thread, true);

            stdoutWriteHandle.Dispose();
            stdoutWriteHandle = null;
            stderrWriteHandle.Dispose();
            stderrWriteHandle = null;
            stdinHandle.Dispose();
            stdinHandle = null;

            // CREATE_SUSPENDED makes this assignment precede all child code.
            // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE then covers every descendant
            // created after resume, and closing the SafeFileHandle is the final
            // native cleanup even on an exception path.
            if (!AssignProcessToJobObject(job, processHandle)) {
                int errorCode = Marshal.GetLastWin32Error();
                Exception cleanupFailure = null;
                long cleanupDeadline = CreateDeadline(CleanupTimeoutMilliseconds);
                try {
                    TerminateProcessAndWait(processHandle, cleanupDeadline);
                } catch (Exception cleanupError) {
                    cleanupFailure = cleanupError;
                }
                Exception assignmentFailure = new Win32Exception(
                    errorCode,
                    "Assigning Tailscale process job failed (Win32 " + errorCode + ").");
                if (cleanupFailure != null) {
                    throw new AggregateException(
                        "Tailscale child assignment and cleanup both failed.",
                        assignmentFailure,
                        cleanupFailure);
                }
                throw assignmentFailure;
            }
            if (ResumeThread(threadHandle) == UInt32.MaxValue) {
                int errorCode = Marshal.GetLastWin32Error();
                Exception cleanupFailure = null;
                long cleanupDeadline = CreateDeadline(CleanupTimeoutMilliseconds);
                try {
                    TerminateJobAndWait(job, processHandle, cleanupDeadline);
                } catch (Exception cleanupError) {
                    cleanupFailure = cleanupError;
                }
                Exception resumeFailure = new Win32Exception(
                    errorCode,
                    "Resuming Tailscale process failed (Win32 " + errorCode + ").");
                if (cleanupFailure != null) {
                    throw new AggregateException(
                        "Tailscale process resume and cleanup both failed.",
                        resumeFailure,
                        cleanupFailure);
                }
                throw resumeFailure;
            }
            threadHandle.Dispose();
            threadHandle = null;

            stdoutStream = new FileStream(stdoutReadHandle, FileAccess.Read, 8192, false);
            stderrStream = new FileStream(stderrReadHandle, FileAccess.Read, 8192, false);
            cancellation = new CancellationTokenSource();
            output = Task.Factory.StartNew(
                () => ReadOutput(stdoutStream, maxBytes, cancellation.Token, "stdout"),
                cancellation.Token,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
            error = Task.Factory.StartNew(
                () => ReadOutput(stderrStream, maxBytes, cancellation.Token, "stderr"),
                cancellation.Token,
                TaskCreationOptions.LongRunning,
                TaskScheduler.Default);
            Task all = Task.WhenAll(output, error);
            bool processExited = false;
            while (!processExited || !all.IsCompleted)
            {
                if (output.IsFaulted) { throw GetReaderException(output); }
                if (error.IsFaulted) { throw GetReaderException(error); }
                uint processWait = WaitForSingleObject(processHandle, 0u);
                if (processWait == WaitObject0) {
                    processExited = true;
                } else if (processWait == WaitFailed) {
                    ThrowLastError("Waiting for Tailscale process");
                }
                if (processExited && all.IsCompleted) { break; }
                uint remaining = RemainingMilliseconds(deadline);
                if (remaining == 0u) {
                    throw new TimeoutException("Tailscale query timed out.");
                }
                Thread.Sleep((int)Math.Min(25u, remaining));
            }
            if (output.IsFaulted) { throw GetReaderException(output); }
            if (error.IsFaulted) { throw GetReaderException(error); }
            // A successful parent and completed output readers do not prove
            // that a descendant has exited. A descendant may close both
            // inherited output handles and leave the readers completed while
            // it continues running. Require job accounting to reach zero
            // before returning success; if it does not, the catch path
            // terminates the whole job and reports failure safely.
            long settleDeadline = CreateDeadline(CleanupTimeoutMilliseconds);
            WaitForJobToEmpty(job, settleDeadline);
            uint exitCode;
            if (!GetExitCodeProcess(processHandle, out exitCode)) {
                ThrowLastError("Reading Tailscale process exit code");
            }
            if (exitCode != 0u) {
                throw new InvalidOperationException(
                    "Tailscale query failed with exit code " + exitCode + ".");
            }
            return output.Result;
        }
        catch (Exception failure)
        {
            if (cancellation != null) { cancellation.Cancel(); }
            Exception cleanupFailure = null;
            long cleanupDeadline = CreateDeadline(CleanupTimeoutMilliseconds);
            try { TerminateJobAndWait(job, processHandle, cleanupDeadline); }
            catch (Exception cleanupError) { cleanupFailure = cleanupError; }
            if (stdoutStream != null) {
                try { stdoutStream.Dispose(); } catch { }
            }
            if (stderrStream != null) {
                try { stderrStream.Dispose(); } catch { }
            }
            try {
                Task[] readers = new Task[] { output, error };
                if (output != null && error != null) {
                    Task.WaitAll(readers, (int)RemainingMilliseconds(cleanupDeadline));
                }
            } catch { }
            if (cleanupFailure != null) {
                throw new AggregateException(
                    "Tailscale child operation and cleanup both failed.", failure, cleanupFailure);
            }
            throw;
        }
        finally
        {
            if (attributeListInitialized && attributeList != IntPtr.Zero) {
                DeleteProcThreadAttributeList(attributeList);
            }
            if (inheritedHandleList != IntPtr.Zero) {
                Marshal.FreeHGlobal(inheritedHandleList);
            }
            if (attributeList != IntPtr.Zero) {
                Marshal.FreeHGlobal(attributeList);
            }
            if (cancellation != null) { cancellation.Dispose(); }
            if (stdoutStream != null) { stdoutStream.Dispose(); }
            if (stderrStream != null) { stderrStream.Dispose(); }
            if (stdoutReadHandle != null) { stdoutReadHandle.Dispose(); }
            if (stdoutWriteHandle != null) { stdoutWriteHandle.Dispose(); }
            if (stderrReadHandle != null) { stderrReadHandle.Dispose(); }
            if (stderrWriteHandle != null) { stderrWriteHandle.Dispose(); }
            if (stdinHandle != null) { stdinHandle.Dispose(); }
            if (threadHandle != null) { threadHandle.Dispose(); }
            if (processHandle != null) { processHandle.Dispose(); }
            if (job != null) { job.Dispose(); }
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
    # The gateway is a reader only. Keep ownership to the two administrative
    # identities used by the create-time descriptor and the SYSTEM writer.
    return @('S-1-5-18', 'S-1-5-32-544')
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
    if ($ownerSid -notin @(Get-SnapshotAllowedOwnerSids)) {
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
    $trustedWriterSids = @('S-1-5-18', 'S-1-5-32-544')
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
$gatewaySid = Get-SnapshotGatewaySid
# ServeConfig nests Web -> endpoint -> Handlers -> path -> handler fields;
# depth 20 keeps every reviewed level plus room for an unknown future field.
# PowerShell truncates silently past -Depth, so the reader's exact-shape check
# would reject a truncated payload rather than accept a wrong one.
$json = $payload | ConvertTo-Json -Depth 20
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
# Refuse to publish what the gateway would reject at startup: the writer fails
# loudly here instead of leaving an oversized file behind.
if ($bytes.Length -gt (256 * 1024)) { throw 'Tailscale snapshot payload is oversized.' }

function Get-SnapshotFileObservation {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Snapshot recovery path is not a regular file: $Path"
    }
    $handle = $null
    try {
        # OPEN_REPARSE_POINT is applied by the native opener. Inspecting the
        # opened object, rather than trusting the pathname, is the authority
        # for every recovery action below.
        $handle = [LifeOSSnapshotNative]::OpenExistingForRename($Path)
        $info = [LifeOSSnapshotNative]::InspectHandle($handle)
        if (([uint32]$info.Attributes -band [uint32]0x400) -ne [uint32]0 -or
            $info.NumberOfLinks -ne 1) {
            throw "Snapshot recovery path is a reparse point or hardlink: $Path"
        }
        return [pscustomobject]@{ Path = $Path; Handle = $handle; Info = $info }
    } catch {
        if ($null -ne $handle) { $handle.Dispose() }
        throw
    }
}

function Get-SnapshotFailureDescription {
    param([Parameter(Mandatory)]$ErrorRecord)
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $exception = $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [Exception]) {
        $exception = $ErrorRecord
    } else {
        $exception = [Exception]::new([string]$ErrorRecord)
    }
    $messages = @()
    while ($null -ne $exception) {
        if ($exception -is [ComponentModel.Win32Exception]) {
            return ($exception.Message + ' (Win32 ' + $exception.NativeErrorCode + ').')
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$exception.Message)) {
            $messages += [string]$exception.Message
        }
        $exception = $exception.InnerException
    }
    if ($messages.Count -gt 0) { return ($messages -join ' -> ') }
    return 'unknown snapshot failure'
}

function Recover-SnapshotReplacementFailure {
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$ReplacementPath,
        [Parameter(Mandatory)][string]$RollbackPath,
        [Parameter(Mandatory)][psobject]$ExpectedReplacement,
        [Parameter(Mandatory)][psobject]$ExpectedOriginal,
        [Parameter(Mandatory)]$ParentHandle
    )
    if ([string]$ExpectedReplacement.Identity -ceq [string]$ExpectedOriginal.Identity) {
        throw 'Snapshot replacement and original identities unexpectedly match.'
    }
    $observed = @()
    $observationFailures = @()
    try {
        foreach ($candidate in @(
            [pscustomobject]@{ Label = 'destination'; Path = $DestinationPath },
            [pscustomobject]@{ Label = 'replacement'; Path = $ReplacementPath },
            [pscustomobject]@{ Label = 'rollback'; Path = $RollbackPath }
        )) {
            try {
                $record = Get-SnapshotFileObservation -Path $candidate.Path
                if ($null -ne $record) { $observed += $record }
            } catch {
                $observationFailures += ($candidate.Label + ': ' + $_.Exception.Message)
            }
        }
        if ($observationFailures.Count -gt 0) {
            throw ('Snapshot replacement state could not be safely observed: ' + ($observationFailures -join '; '))
        }

        $unexpected = @($observed | Where-Object {
            $_.Info.Identity -cne [string]$ExpectedReplacement.Identity -and
            $_.Info.Identity -cne [string]$ExpectedOriginal.Identity
        })
        if ($unexpected.Count -gt 0) {
            throw ('Snapshot replacement state contains an unexpected file identity at ' +
                (($unexpected | ForEach-Object { $_.Path }) -join ', ') + '.')
        }
        $replacementLocations = @($observed | Where-Object {
            $_.Info.Identity -ceq [string]$ExpectedReplacement.Identity
        })
        $originalLocations = @($observed | Where-Object {
            $_.Info.Identity -ceq [string]$ExpectedOriginal.Identity
        })
        if ($replacementLocations.Count -gt 1) {
            throw 'Snapshot replacement identity exists at more than one path.'
        }
        if ($originalLocations.Count -gt 1) {
            throw 'Snapshot original identity exists at more than one path.'
        }
        if ($originalLocations.Count -eq 0) {
            throw 'Snapshot replacement failure lost the original identity.'
        }

        $destination = @($observed | Where-Object { $_.Path -ceq $DestinationPath }) | Select-Object -First 1
        $rollback = @($observed | Where-Object { $_.Path -ceq $RollbackPath }) | Select-Object -First 1
        $replacement = @($observed | Where-Object { $_.Path -ceq $ReplacementPath }) | Select-Object -First 1
        $original = $originalLocations[0]
        if ($null -ne $destination -and
            $destination.Info.Identity -ceq [string]$ExpectedOriginal.Identity) {
            if ($null -ne $rollback) {
                throw 'Snapshot original identity is duplicated at the destination and rollback path.'
            }
        } elseif ($null -ne $destination -and
            $destination.Info.Identity -ceq [string]$ExpectedReplacement.Identity) {
            if ($null -eq $rollback -or
                $original.Path -cne $RollbackPath) {
                throw 'Snapshot replacement occupies the destination without a recoverable original.'
            }
            # The identity check above is the authorization for this delete.
            # Never delete a path merely because it has the expected name.
            [LifeOSSnapshotNative]::DeleteByHandle($destination.Handle)
            $destination.Handle.Dispose()
            $destination = $null
            $replacement = $null
        } elseif ($null -eq $destination) {
            if ($null -eq $rollback -or $original.Path -cne $RollbackPath) {
                throw 'Snapshot replacement failure left no destination and no rollback original.'
            }
        } else {
            throw 'Snapshot replacement failure left an unauthorized destination object.'
        }

        if ($null -ne $rollback) {
            [LifeOSSnapshotNative]::RenameWithHeldParent(
                $rollback.Handle, $ParentHandle, $DestinationPath, $false)
            $rollback = $null
        }
        if ($null -ne $replacement) {
            if ($replacement.Path -cne $ReplacementPath) {
                throw 'Snapshot replacement identity was found at an unexpected cleanup path.'
            }
            # The replacement identity was observed from this held handle.
            [LifeOSSnapshotNative]::DeleteByHandle($replacement.Handle)
        }
        $final = [LifeOSSnapshotNative]::Inspect($DestinationPath, $false)
        if ([string]$final.Identity -cne [string]$ExpectedOriginal.Identity -or
            ([uint32]$final.Attributes -band [uint32]0x400) -ne [uint32]0 -or
            $final.NumberOfLinks -ne 1) {
            throw 'Snapshot replacement failure recovery did not restore the original identity.'
        }
        return $true
    } finally {
        foreach ($record in $observed) {
            if ($null -ne $record.Handle) { $record.Handle.Dispose() }
        }
    }
}

function Invoke-SnapshotPublication {
    param(
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string]$GatewaySid,
        [Parameter(Mandatory)][byte[]]$Bytes,
        [AllowNull()][scriptblock]$PostPublicationVerification = $null,
        # These seams are used only by the colocated failure-state suite. The
        # production call leaves both null and always invokes the native API.
        [AllowNull()][scriptblock]$TestReplaceFileOperation = $null,
        [AllowNull()][scriptblock]$TestAfterReplaceOperation = $null
    )
    $outputFull = Get-SnapshotFullPath $OutputPath
    $parent = Split-Path -Parent $outputFull
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Tailscale snapshot parent directory is missing.' }
    $leaf = [IO.Path]::GetFileName($outputFull)
    if ([string]::IsNullOrWhiteSpace($leaf) -or $leaf -in @('.', '..') -or $leaf.Length -gt 255 -or
        $leaf.TrimEnd(' .') -cne $leaf -or $leaf -match '[:<>"/\\|?*]' -or
        $leaf -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\..*)?$') {
        throw 'Tailscale snapshot leaf name is invalid.'
    }
    $parentChain = @(Get-SnapshotIdentityChain $parent)
    Assert-SnapshotSecurity -Path $parent -GatewaySid $GatewaySid
    $ancestorHandles = @()
    $parentHandle = $null
    $tempHandle = $null
    $previousHandle = $null
    $stream = $null
    $tempHandleInfo = $null
    $previousMoved = $false
    $rollbackPathPublished = $false
    $rollbackArtifactRetained = $false
    $replaceOperationStarted = $false
    $partialRecoveryAttempted = $false
    $tempHandleMatchesReplacement = $false
    $published = $false
    $temp = Join-Path $parent ('.tailscale-state.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $rollbackPath = Join-Path $parent ('.tailscale-state.' + [Guid]::NewGuid().ToString('N') + '.rollback')
    $priorDestination = $null
    if (Test-Path -LiteralPath $outputFull -PathType Leaf) {
        $priorDestination = [LifeOSSnapshotNative]::Inspect($outputFull, $false)
        if (([uint32]$priorDestination.Attributes -band [uint32]0x400) -ne [uint32]0 -or $priorDestination.NumberOfLinks -ne 1) {
            throw 'Existing Tailscale snapshot is a reparse point or hardlink.'
        }
        Assert-SnapshotSecurity -Path $outputFull -GatewaySid $GatewaySid
    } elseif (Test-Path -LiteralPath $outputFull) {
        throw 'Tailscale snapshot destination is not a regular file.'
    }
    if ($Bytes.Length -gt (256 * 1024)) { throw 'Tailscale snapshot payload is oversized.' }
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
        $tempHandle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($temp, $GatewaySid)
        # This validation intentionally observes the create-time descriptor
        # before the defensive pathname-based Set-Acl pass below.
        Assert-SnapshotSecurity -Path $temp -GatewaySid $GatewaySid
        $stream = [IO.FileStream]::new($tempHandle, [IO.FileAccess]::ReadWrite, 8192, $false)
        Set-SnapshotRestrictedFileSecurity -Path $temp -GatewaySid $GatewaySid
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
        Assert-SnapshotSecurity -Path $temp -GatewaySid $GatewaySid
        $tempHandleInfo = [LifeOSSnapshotNative]::InspectHandle($tempHandle)
        if (([uint32]$tempHandleInfo.Attributes -band [uint32]0x400) -ne [uint32]0 -or $tempHandleInfo.NumberOfLinks -ne 1) {
            throw 'Temporary Tailscale snapshot is a reparse point or hardlink.'
        }
        $tempHandleMatchesReplacement = $true
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
            Assert-SnapshotSecurity -Path $outputFull -GatewaySid $GatewaySid
            if (Test-Path -LiteralPath $rollbackPath) {
                throw 'Tailscale snapshot rollback path already exists.'
            }
            # ReplaceFileW is the primary atomic swap and rollback-copy
            # operation. Its documented partial-failure states are reconciled
            # by identity in the catch path below. The held ancestor handles
            # pin the validated directory chain while the final leaf changes.
            # The replacement file must be closed before ReplaceFileW opens it.
            # Keep its validated identity so the published path can be reopened
            # and checked immediately after the swap.
            if ($null -ne $stream) {
                $stream.Dispose()
                $stream = $null
            }
            if ($null -ne $tempHandle) {
                $tempHandle.Dispose()
                $tempHandle = $null
            }
            $tempHandleMatchesReplacement = $false
            $replaceOperationStarted = $true
            if ($null -ne $TestReplaceFileOperation) {
                & $TestReplaceFileOperation $outputFull $temp $rollbackPath
            } else {
                [LifeOSSnapshotNative]::ReplaceFileAtomically($outputFull, $temp, $rollbackPath)
            }
            $rollbackPathPublished = $true
            $published = $true
            if ($null -ne $TestAfterReplaceOperation) {
                & $TestAfterReplaceOperation $outputFull $temp $rollbackPath
            }
            $tempHandle = [LifeOSSnapshotNative]::OpenExistingForRename($outputFull)
            $publishedInfo = [LifeOSSnapshotNative]::InspectHandle($tempHandle)
            if ([string]$publishedInfo.Identity -cne [string]$tempHandleInfo.Identity -or
                ([uint32]$publishedInfo.Attributes -band [uint32]0x400) -ne [uint32]0 -or
                $publishedInfo.NumberOfLinks -ne 1) {
                throw 'Published replacement handle does not retain the created replacement identity.'
            }
            $tempHandleMatchesReplacement = $true
            $previousHandle = [LifeOSSnapshotNative]::OpenExistingForRename($rollbackPath)
            $previousHandleInfo = [LifeOSSnapshotNative]::InspectHandle($previousHandle)
            if ([string]$previousHandleInfo.Identity -cne [string]$priorDestination.Identity -or
                ([uint32]$previousHandleInfo.Attributes -band [uint32]0x400) -ne [uint32]0 -or
                $previousHandleInfo.NumberOfLinks -ne 1) {
                throw 'Published snapshot rollback copy does not retain the previous identity.'
            }
            $previousMoved = $true
        } elseif ($destinationNowExists) {
            throw 'Tailscale snapshot destination appeared before publication.'
        }
        if ($null -eq $priorDestination) {
            [LifeOSSnapshotNative]::RenameWithHeldParent(
                $tempHandle, $parentHandle, $outputFull, $false)
            $published = $true
        }
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
        Assert-SnapshotSecurity -Path $outputFull -GatewaySid $GatewaySid
        $finalBytes = [LifeOSSnapshotNative]::ReadBounded($tempHandle, 256 * 1024)
        if (-not [Convert]::ToBase64String($finalBytes).Equals([Convert]::ToBase64String($Bytes), [StringComparison]::Ordinal)) {
            throw 'Published Tailscale snapshot byte verification failed.'
        }
        Assert-SnapshotIdentityChain -Expected $parentChain -Description 'Tailscale snapshot parent'
        if ($null -ne $PostPublicationVerification) { & $PostPublicationVerification }
        if ($previousMoved) {
            [LifeOSSnapshotNative]::DeleteByHandle($previousHandle)
            $previousMoved = $false
            $rollbackPathPublished = $false
        }
    } catch {
        $failure = $_
        $failureDescription = Get-SnapshotFailureDescription -ErrorRecord $failure
        $recoveryFailure = $null
        if ($replaceOperationStarted -and -not $rollbackPathPublished) {
            $partialRecoveryAttempted = $true
            try {
                Recover-SnapshotReplacementFailure `
                    -DestinationPath $outputFull `
                    -ReplacementPath $temp `
                    -RollbackPath $rollbackPath `
                    -ExpectedReplacement $tempHandleInfo `
                    -ExpectedOriginal $priorDestination `
                    -ParentHandle $parentHandle | Out-Null
                $published = $false
            } catch {
                $recoveryFailure = $_
                $rollbackArtifactRetained = Test-Path -LiteralPath $rollbackPath -PathType Leaf
            }
        }
        if (-not $partialRecoveryAttempted) {
            if ($null -ne $tempHandle) {
                if ($tempHandleMatchesReplacement) {
                    try { [LifeOSSnapshotNative]::DeleteByHandle($tempHandle) }
                    catch { $recoveryFailure = $_ }
                } else {
                    $recoveryFailure = [InvalidOperationException]::new(
                        'Refused to delete a snapshot handle whose identity was not validated as the replacement.')
                }
                $published = $false
            }
            if ($null -ne $stream) {
                try { $stream.Dispose() } catch { }
                $stream = $null
            }
            if ($null -ne $tempHandle) {
                try { $tempHandle.Dispose() } catch { }
                $tempHandle = $null
            }
            if ($null -eq $tempHandle -and -not $rollbackPathPublished -and
                $null -ne $tempHandleInfo -and (Test-Path -LiteralPath $temp -PathType Leaf)) {
                $cleanupHandle = $null
                try {
                    $cleanupHandle = [LifeOSSnapshotNative]::OpenExistingForDelete($temp)
                    $cleanupInfo = [LifeOSSnapshotNative]::InspectHandle($cleanupHandle)
                    if ([string]$cleanupInfo.Identity -cne [string]$tempHandleInfo.Identity -or
                        ([uint32]$cleanupInfo.Attributes -band [uint32]0x400) -ne [uint32]0 -or
                        $cleanupInfo.NumberOfLinks -ne 1) {
                        throw 'Temporary Tailscale snapshot changed before safe cleanup.'
                    }
                    [LifeOSSnapshotNative]::DeleteByHandle($cleanupHandle)
                } catch {
                    $recoveryFailure = $_
                } finally {
                    if ($null -ne $cleanupHandle) { $cleanupHandle.Dispose() }
                }
            }
        }
        if ($previousMoved) {
            try {
                [LifeOSSnapshotNative]::RenameWithHeldParent(
                    $previousHandle, $parentHandle, $outputFull, $false)
                $previousMoved = $false
                $rollbackPathPublished = $false
            } catch {
                $recoveryFailure = $_
                $rollbackArtifactRetained = $true
            }
        } elseif ($rollbackPathPublished) {
            # The backup exists but could not be opened/validated. Keep the
            # last good bytes for operator recovery rather than deleting them.
            $rollbackArtifactRetained = $true
        }
        if ($null -ne $recoveryFailure) {
            $preservedPaths = @(
                @($outputFull, $temp, $rollbackPath) | Where-Object {
                    Test-Path -LiteralPath $_ -PathType Leaf
                }
            )
            $preservedDescription = if ($preservedPaths.Count -gt 0) {
                $preservedPaths -join ', '
            } else { 'none' }
            $recoveryDescription = Get-SnapshotFailureDescription -ErrorRecord $recoveryFailure
            throw "Tailscale snapshot publication failed and recovery could not prove a clean state; original failure: ${failureDescription}; preserved paths: ${preservedDescription}; recovery failure: ${recoveryDescription}"
        }
        if ($rollbackArtifactRetained) {
            throw "Tailscale snapshot publication failed; rollback artifact retained at ${rollbackPath}: ${failureDescription}"
        }
        if ($partialRecoveryAttempted) {
            throw "Tailscale snapshot publication failed after restoring the previous snapshot: ${failureDescription}"
        }
        throw $failure
    } finally {
        if ($null -ne $stream) {
            $stream.Dispose()
            $stream = $null
        }
        if ($null -ne $tempHandle) {
            if (-not $published -and $tempHandleMatchesReplacement) {
                try { [LifeOSSnapshotNative]::DeleteByHandle($tempHandle) } catch { }
            }
            $tempHandle.Dispose()
            $tempHandle = $null
        }
        if ($null -ne $previousHandle) {
            if ($previousMoved -and -not $rollbackArtifactRetained) {
                try { [LifeOSSnapshotNative]::DeleteByHandle($previousHandle) } catch { }
                $previousMoved = $false
            }
            $previousHandle.Dispose()
            $previousHandle = $null
        }
        for ($index = $ancestorHandles.Count - 1; $index -ge 0; $index--) {
            if ($null -ne $ancestorHandles[$index]) { $ancestorHandles[$index].Dispose() }
        }
        $ancestorHandles = @()
        $parentHandle = $null
    }
}

Invoke-SnapshotPublication -OutputPath $OutputPath -GatewaySid $gatewaySid -Bytes $bytes
