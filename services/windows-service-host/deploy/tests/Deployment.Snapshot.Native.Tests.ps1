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

function Get-SnapshotExceptionDetails {
    param([Parameter(Mandatory)]$ErrorRecord)

    $exception = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $ErrorRecord.Exception
    } elseif ($ErrorRecord -is [Exception]) {
        $ErrorRecord
    } else {
        [Exception]::new([string]$ErrorRecord)
    }

    # PowerShell method calls and reflection add invocation wrappers around
    # the exception thrown by the managed method. Strip only those wrappers;
    # an AggregateException remains visible so a cleanup failure cannot be
    # mistaken for the primary operation failure.
    while ($exception -is [System.Management.Automation.MethodInvocationException] -or
           $exception -is [System.Reflection.TargetInvocationException]) {
        if ($null -eq $exception.InnerException) { break }
        $exception = $exception.InnerException
    }

    $isAggregate = $exception -is [AggregateException]
    $primary = $exception
    if ($isAggregate -and $exception.InnerExceptions.Count -gt 0) {
        $primary = $exception.InnerExceptions[0]
        while ($primary -is [System.Management.Automation.MethodInvocationException] -or
               $primary -is [System.Reflection.TargetInvocationException]) {
            if ($null -eq $primary.InnerException) { break }
            $primary = $primary.InnerException
        }
    }
    return [pscustomobject]@{
        Exception = $exception
        Primary = $primary
        IsAggregate = $isAggregate
    }
}

function Assert-SnapshotThrowsMatching {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Pattern,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][int]$MaxElapsedMilliseconds,
        [Type]$ExpectedExceptionType = [Exception]
    )
    $failure = $null
    $started = Get-Date
    try { & $Action } catch { $failure = $_ }
    $elapsedMilliseconds = [int]((Get-Date) - $started).TotalMilliseconds
    Assert-SnapshotTest ($null -ne $failure) ($Message + ' raises an exception')
    if ($null -ne $failure) {
        $details = Get-SnapshotExceptionDetails -ErrorRecord $failure
        $primaryType = $details.Primary.GetType()
        Assert-SnapshotTest ($details.Primary -is $ExpectedExceptionType) (
            $Message + ' reports the concrete primary exception type ' + $ExpectedExceptionType.FullName +
            ' (actual ' + $primaryType.FullName + ')')
        $failureText = [string]$details.Primary.ToString()
        Assert-SnapshotTest ($failureText.IndexOf($Pattern, [StringComparison]::Ordinal) -ge 0) (
            $Message + ' reports the expected failure kind from the primary exception')
        Assert-SnapshotTest (-not $details.IsAggregate) (
            $Message + ' rejects a cleanup aggregate after recognizing primary ' + $primaryType.FullName)
    }
    Assert-SnapshotTest ($elapsedMilliseconds -le $MaxElapsedMilliseconds) ($Message + ' completes within its bound')
}

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    Write-Host 'SKIP: native snapshot tests require Windows PowerShell 5.1.'
    exit 0
}

# A PowerShell/reflection wrapper around an operation-plus-cleanup aggregate
# must be rejected even when the first branch is the expected timeout. This
# keeps the matcher focused on the concrete primary type and prevents a
# cleanup branch from being accepted through aggregate text matching.
$aggregateMatcherRejected = $false
$aggregateMatcherFailure = $null
try {
    Assert-SnapshotThrowsMatching -Action {
        $primary = [TimeoutException]::new('Tailscale query timed out.')
        $cleanup = [IOException]::new('Tailscale child cleanup was incomplete.')
        $aggregate = [AggregateException]::new(
            'Tailscale child operation and cleanup both failed.',
            [Exception[]]@($primary, $cleanup))
        throw [System.Reflection.TargetInvocationException]::new(
            'PowerShell invocation wrapper', $aggregate)
    } -Pattern 'Tailscale query timed out.' -ExpectedExceptionType ([TimeoutException]) `
        -MaxElapsedMilliseconds 1000 -Message 'matcher rejects a wrapped timeout-plus-cleanup aggregate'
} catch {
    $aggregateMatcherRejected = $true
    $aggregateMatcherFailure = $_
}
Assert-SnapshotTest $aggregateMatcherRejected 'matcher rejects a wrapped timeout-plus-cleanup aggregate'
Assert-SnapshotTest ($aggregateMatcherFailure.Exception.Message -like '*cleanup aggregate*') 'matcher reports the cleanup aggregate rejection'
Assert-SnapshotTest ($aggregateMatcherFailure.Exception.ToString().IndexOf('TimeoutException', [StringComparison]::Ordinal) -ge 0) 'matcher recognized the primary timeout before rejecting the cleanup aggregate'

$sourcePath = Join-Path $PSScriptRoot '..\tailscale_snapshot.ps1'
$source = Get-Content -LiteralPath $sourcePath -Raw -ErrorAction Stop
$nativeStart = $source.IndexOf('if ($null -eq (''LifeOSSnapshotNative'' -as [type])) {', [StringComparison]::Ordinal)
$nativeEnd = $source.IndexOf('function Get-SnapshotFullPath', $nativeStart, [StringComparison]::Ordinal)
$definitionStart = $source.IndexOf('function Get-SnapshotPropertyValue', [StringComparison]::Ordinal)
$definitionEnd = $source.IndexOf("`n`$identity = Get-JsonFromTailscale", [StringComparison]::Ordinal)
$recoveryStart = $source.IndexOf('function Get-SnapshotFileObservation', [StringComparison]::Ordinal)
if ($nativeStart -lt 0 -or $nativeEnd -le $nativeStart -or
    $definitionStart -lt 0 -or $definitionEnd -le $definitionStart -or
    $recoveryStart -lt 0) {
    throw 'FAIL: snapshot writer definition boundary is missing.'
}
# The native type is embedded before the writer functions. Load only that
# preamble and the definition-only helpers; dot-sourcing the whole writer would
# query Tailscale and publish a file during this fixture.
. ([scriptblock]::Create($source.Substring($nativeStart, $nativeEnd - $nativeStart)))
. ([scriptblock]::Create($source.Substring($definitionStart, $definitionEnd - $definitionStart)))
$publicationStart = $source.IndexOf('function Invoke-SnapshotPublication', [StringComparison]::Ordinal)
$publicationEnd = $source.IndexOf("`nInvoke-SnapshotPublication -OutputPath", $publicationStart, [StringComparison]::Ordinal)
if ($publicationStart -lt 0 -or $publicationEnd -le $publicationStart) { throw 'FAIL: snapshot publication definition boundary is missing.' }
. ([scriptblock]::Create($source.Substring($recoveryStart, $publicationEnd - $recoveryStart)))

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
        [Parameter(Mandatory)][bool]$Replace,
        [Parameter(Mandatory)][string]$GatewaySid
    )
    $parent = $null
    $handle = $null
    $writer = $null
    $temporary = Join-Path $Root ('.test-' + [Guid]::NewGuid().ToString('N') + '.tmp')
    $published = $false
    try {
        $parent = [LifeOSSnapshotNative]::OpenDirectory($Root)
        $handle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($temporary, $GatewaySid)
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

$gatewayTestSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

try {
    $first = [Text.UTF8Encoding]::new($false).GetBytes('{"schemaVersion":1,"value":"first"}')
    $second = [Text.UTF8Encoding]::new($false).GetBytes('{"schemaVersion":1,"value":"second"}')
    Publish-TestBytes -Root $testRoot -Destination $destination -Bytes $first -Replace:$false -GatewaySid $gatewayTestSid
    Assert-SnapshotTest (Test-Path -LiteralPath $destination -PathType Leaf) 'absent destination is published atomically'
    Publish-TestBytes -Root $testRoot -Destination $destination -Bytes $second -Replace:$true -GatewaySid $gatewayTestSid
    Assert-SnapshotTest ([Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($destination)) -ceq [Text.Encoding]::UTF8.GetString($second)) 'repeated replacement updates the destination'

    $oldBytes = [IO.File]::ReadAllBytes($destination)
    Assert-SnapshotThrows {
        $existing = [LifeOSSnapshotNative]::CreateExclusiveForWrite($tempPath, $gatewayTestSid)
        try { [LifeOSSnapshotNative]::CreateExclusiveForWrite($tempPath, $gatewayTestSid) | Out-Null }
        finally { [LifeOSSnapshotNative]::DeleteByHandle($existing); $existing.Dispose() }
    } 'exclusive temporary creation rejects a colliding path'
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($oldBytes)) 'failed temporary creation preserves the previous snapshot'

    $oversizedPath = Join-Path $testRoot 'oversized'
    [IO.File]::WriteAllBytes($oversizedPath, (New-Object byte[] 2048))
    $oversizedStream = [IO.File]::OpenRead($oversizedPath)
    try { Assert-SnapshotThrows { [LifeOSSnapshotNative]::ReadBounded($oversizedStream.SafeFileHandle, 1024) } 'bounded reader rejects oversized content' }
    finally { $oversizedStream.Dispose() }
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($oldBytes)) 'oversized input does not alter the destination'

    # ReadBounded must borrow the caller handle without closing it. Keep the
    # writer stream alive across the native read and continue writing through
    # that same SafeFileHandle before either owner is disposed.
    $preservedPath = Join-Path $testRoot 'handle-preserved'
    $preservedHandle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($preservedPath, $gatewayTestSid)
    $preservedWriter = $null
    try {
        $preservedWriter = [IO.FileStream]::new($preservedHandle, [IO.FileAccess]::ReadWrite, 8192, $false)
        $preservedBytes = [Text.UTF8Encoding]::new($false).GetBytes('writer-before-native-read')
        $preservedWriter.Write($preservedBytes, 0, $preservedBytes.Length)
        $preservedWriter.Flush($true)
        $beforeReadInfo = [LifeOSSnapshotNative]::InspectHandle($preservedHandle)
        $readWhileWriterOpen = [LifeOSSnapshotNative]::ReadBounded($preservedHandle, 256 * 1024)
        Assert-SnapshotTest ([Convert]::ToBase64String($readWhileWriterOpen) -ceq [Convert]::ToBase64String($preservedBytes)) 'native bounded read returns the caller file bytes'
        Assert-SnapshotTest (-not $preservedHandle.IsClosed -and -not $preservedHandle.IsInvalid) 'native bounded read leaves the caller SafeFileHandle valid while the writer stream is in scope'
        $continuation = [Text.UTF8Encoding]::new($false).GetBytes('-writer-continued')
        $preservedWriter.Write($continuation, 0, $continuation.Length)
        $preservedWriter.Flush($true)
        $expectedPreserved = [Text.UTF8Encoding]::new($false).GetString([byte[]]($preservedBytes + $continuation))
        $actualPreserved = [Text.Encoding]::UTF8.GetString([LifeOSSnapshotNative]::ReadBounded($preservedHandle, 256 * 1024))
        Assert-SnapshotTest ($actualPreserved -ceq $expectedPreserved) 'writer stream remains usable after native bounded read'
        $afterReadInfo = [LifeOSSnapshotNative]::InspectHandle($preservedHandle)
        Assert-SnapshotTest ([string]$afterReadInfo.Identity -ceq [string]$beforeReadInfo.Identity) 'caller handle identity remains stable after native bounded read'
    } finally {
        if ($null -ne $preservedWriter) { $preservedWriter.Dispose() }
        if ($null -ne $preservedHandle) {
            try { [LifeOSSnapshotNative]::DeleteByHandle($preservedHandle) } catch { }
            $preservedHandle.Dispose()
        }
    }

    # Inspect the descriptor installed by CreateFile before the defensive
    # pathname Set-Acl call. This catches an inherited-DACL window at creation.
    $preHardeningPath = Join-Path $testRoot 'pre-hardening'
    $preHardeningHandle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($preHardeningPath, $gatewayTestSid)
    try {
        $preHardeningAcl = Get-Acl -LiteralPath $preHardeningPath -ErrorAction Stop
        Assert-SnapshotTest ((ConvertTo-SnapshotSid $preHardeningAcl.Owner) -ceq 'S-1-5-18') 'create-time snapshot ACL assigns SYSTEM as owner before pathname hardening'
        Assert-SnapshotSecurity -Path $preHardeningPath -GatewaySid $gatewayTestSid
        Set-SnapshotRestrictedFileSecurity -Path $preHardeningPath -GatewaySid $gatewayTestSid
    } finally {
        if ($null -ne $preHardeningHandle) {
            try { [LifeOSSnapshotNative]::DeleteByHandle($preHardeningHandle) } catch { }
            $preHardeningHandle.Dispose()
        }
    }

    $heldParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
    $movedRoot = $testRoot + '.moved'
    try {
        Assert-SnapshotThrows { Move-Item -LiteralPath $testRoot -Destination $movedRoot -ErrorAction Stop } 'held ancestor prevents pathname replacement'
    } finally { $heldParent.Dispose() }
    Assert-SnapshotTest (Test-Path -LiteralPath $testRoot -PathType Container) 'held parent remains at its validated path'

    $powershell = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $powershell -PathType Leaf) {
        if ($null -eq ('LifeOSSnapshotInheritanceTestNative' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

public static class LifeOSSnapshotInheritanceTestNative
{
    [StructLayout(LayoutKind.Sequential)]
    private struct SecurityAttributes
    {
        public int Length;
        public IntPtr SecurityDescriptor;
        public int InheritHandle;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateFileW")]
    private static extern SafeFileHandle CreateFile(
        string path,
        uint desiredAccess,
        uint shareMode,
        ref SecurityAttributes securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    public static SafeFileHandle CreateInheritableReadHandle(string path)
    {
        SecurityAttributes attributes = new SecurityAttributes {
            Length = Marshal.SizeOf(typeof(SecurityAttributes)),
            SecurityDescriptor = IntPtr.Zero,
            InheritHandle = 1
        };
        SafeFileHandle handle = CreateFile(
            path, 0x80000000u, 0x7u, ref attributes, 3u, 0x80u, IntPtr.Zero);
        if (handle == null || handle.IsInvalid)
        {
            int error = Marshal.GetLastWin32Error();
            if (handle != null) { handle.Dispose(); }
            throw new Win32Exception(error, "Creating inheritable sentinel");
        }
        return handle;
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
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
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
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    public static void LaunchWithAllInheritableHandles(
        string executable,
        string probe,
        string handleValue,
        string expected,
        string resultPath)
    {
        // The disposable test paths contain no spaces. This deliberately
        // omits STARTUPINFOEX so the positive control inherits all inheritable
        // parent handles, including the sentinel.
        StringBuilder commandLine = new StringBuilder(
            executable + " -NoProfile -NonInteractive -File " + probe + " " +
            handleValue + " " + expected + " " + resultPath);
        StartupInfo startup = new StartupInfo { cb = Marshal.SizeOf(typeof(StartupInfo)) };
        ProcessInformation processInformation;
        if (!CreateProcess(
                executable,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                true,
                0x08000000u,
                IntPtr.Zero,
                Environment.SystemDirectory,
                ref startup,
                out processInformation))
        {
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Launching inheritable-handle positive control");
        }
        try
        {
            if (WaitForSingleObject(processInformation.Process, 5000u) != 0u)
            {
                throw new TimeoutException("Inheritable-handle positive control timed out.");
            }
        }
        finally
        {
            CloseHandle(processInformation.Thread);
            CloseHandle(processInformation.Process);
        }
    }
}
'@ -ErrorAction Stop | Out-Null
        }
        $processTreeNativeSource = @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;

public static class LifeOSSnapshotProcessTreeTestNative
{
    private const uint CreateNoWindow = 0x08000000u;
    private const int StartfUseStdHandles = 0x00000100;

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
    private struct ProcessInformation
    {
        public IntPtr Process;
        public IntPtr Thread;
        public uint ProcessId;
        public uint ThreadId;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
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
        ref StartupInfo startupInfo,
        out ProcessInformation processInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);

    private static string QuoteArgument(string value)
    {
        if (value == null) { return "\"\""; }
        bool quote = value.Length == 0;
        for (int index = 0; index < value.Length && !quote; index++) {
            quote = Char.IsWhiteSpace(value[index]) || value[index] == '\"';
        }
        if (!quote) { return value; }
        StringBuilder result = new StringBuilder();
        result.Append('\"');
        int slashes = 0;
        for (int index = 0; index < value.Length; index++) {
            char current = value[index];
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

    public static void LaunchChildAndReturn(string executable, string[] arguments)
    {
        StringBuilder commandLine = new StringBuilder(QuoteArgument(executable));
        if (arguments != null) {
            for (int index = 0; index < arguments.Length; index++) {
                commandLine.Append(' ');
                commandLine.Append(QuoteArgument(arguments[index]));
            }
        }
        StartupInfo startup = new StartupInfo {
            cb = Marshal.SizeOf(typeof(StartupInfo)),
            dwFlags = StartfUseStdHandles,
            hStdInput = GetStdHandle(-10),
            hStdOutput = GetStdHandle(-11),
            hStdError = GetStdHandle(-12)
        };
        ProcessInformation processInformation;
        if (!CreateProcess(
                executable,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                CreateNoWindow,
                IntPtr.Zero,
                Environment.SystemDirectory,
                ref startup,
                out processInformation)) {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Launching inherited-output descendant");
        }
        CloseHandle(processInformation.Thread);
        CloseHandle(processInformation.Process);
        // Close the synthetic parent's copies too. The descendant is created
        // without inheriting the wrapper pipes, and its script closes its own
        // standard handles before sleeping. This lets the wrapper observe the
        // parent exit while job accounting still sees the sleeper.
        CloseHandle(GetStdHandle(-11));
        CloseHandle(GetStdHandle(-12));
        System.Threading.Thread.Sleep(250);
        // PowerShell can retain host-level duplicates after the standard
        // handles are closed. Exit the synthetic parent so all of its copies
        // are released before the wrapper evaluates job accounting.
        Environment.Exit(0);
    }
}
'@
        if ($null -eq ('LifeOSSnapshotProcessTreeTestNative' -as [type])) {
            Add-Type -TypeDefinition $processTreeNativeSource -ErrorAction Stop | Out-Null
        }
        $ordinaryOutput = [LifeOSSnapshotNative]::RunBounded(
            $powershell,
            @('-NoProfile', '-NonInteractive', '-Command', '[Console]::Write("ordinary-success")'),
            5000,
            4096)
        Assert-SnapshotTest ($ordinaryOutput -ceq 'ordinary-success') 'native process reader preserves ordinary successful commands'
        $missingExecutable = Join-Path $testRoot 'missing-tailscale.exe'
        Assert-SnapshotThrowsMatching -Action {
            [LifeOSSnapshotNative]::RunBounded($missingExecutable, @(), 1000, 4096) | Out-Null
        } -Pattern 'Starting Tailscale process failed' -ExpectedExceptionType ([ComponentModel.Win32Exception]) `
            -MaxElapsedMilliseconds 4000 -Message 'native process reader reports a launch failure'
        Assert-SnapshotThrowsMatching -Action {
            [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-Command', 'Start-Sleep -Seconds 3'), 250, 4096) | Out-Null
        } -Pattern 'Tailscale query timed out.' -ExpectedExceptionType ([TimeoutException]) `
            -MaxElapsedMilliseconds 5000 -Message 'native process reader enforces a total timeout'
        Assert-SnapshotThrowsMatching -Action {
            [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-Command', '[Console]::Write(("x" * 8192))'), 5000, 1024) | Out-Null
        } -Pattern 'Tailscale stdout output exceeds its byte bound.' -ExpectedExceptionType ([IO.InvalidDataException]) `
            -MaxElapsedMilliseconds 4000 -Message 'native process reader enforces an output bound'
        Assert-SnapshotThrowsMatching -Action {
            [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-Command', '[Console]::Error.Write(("e" * 8192))'), 5000, 1024) | Out-Null
        } -Pattern 'Tailscale stderr output exceeds its byte bound.' -ExpectedExceptionType ([IO.InvalidDataException]) `
            -MaxElapsedMilliseconds 4000 -Message 'native process reader enforces a separate stderr output bound'

        # The wrapper must own the whole process tree. The outer PowerShell
        # creates a child that records its PID and would otherwise outlive its
        # timed-out parent; both are assigned to the native job before resume.
        $descendantPidPath = Join-Path $testRoot 'descendant.pid'
        $childCommandTemplate = '[IO.File]::WriteAllText(''{0}'',[string]$PID); Start-Sleep -Seconds 30'
        $childCommand = $childCommandTemplate -f $descendantPidPath.Replace("'", "''")
        $descendantCommandTemplate = '$null = Start-Process -FilePath ''{0}'' -ArgumentList @(''-NoProfile'',''-NonInteractive'',''-Command'', ''{1}'') -PassThru; Start-Sleep -Seconds 30'
        $descendantCommand = $descendantCommandTemplate -f $powershell.Replace("'", "''"), $childCommand.Replace("'", "''")
        $descendantPid = $null
        try {
            Assert-SnapshotThrowsMatching -Action {
                [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-NonInteractive', '-Command', $descendantCommand), 3000, 4096) | Out-Null
            } -Pattern 'Tailscale query timed out.' -ExpectedExceptionType ([TimeoutException]) `
                -MaxElapsedMilliseconds 6000 -Message 'native process job terminates descendants on timeout'
            $pidDeadline = (Get-Date).ToUniversalTime().AddSeconds(3)
            while ($null -eq $descendantPid -and (Get-Date).ToUniversalTime() -lt $pidDeadline) {
                if (Test-Path -LiteralPath $descendantPidPath -PathType Leaf) {
                    try { $descendantPid = [int](Get-Content -LiteralPath $descendantPidPath -Raw -ErrorAction Stop) } catch { $descendantPid = $null }
                }
                if ($null -eq $descendantPid) { Start-Sleep -Milliseconds 50 }
            }
            Assert-SnapshotTest ($null -ne $descendantPid) 'descendant test records the child process id'
            $childGone = $false
            $goneDeadline = (Get-Date).ToUniversalTime().AddSeconds(3)
            while ((Get-Date).ToUniversalTime() -lt $goneDeadline) {
                $childProcess = Get-Process -Id $descendantPid -ErrorAction SilentlyContinue
                if ($null -eq $childProcess) { $childGone = $true; break }
                Start-Sleep -Milliseconds 50
            }
            Assert-SnapshotTest $childGone 'native process job removes the outliving child within a bounded wait'
        } finally {
            if ($null -ne $descendantPid) {
                Get-Process -Id $descendantPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }

        $overflowPidPath = Join-Path $testRoot 'overflow-descendant.pid'
        $overflowChildCommand = $childCommandTemplate -f $overflowPidPath.Replace("'", "''")
        $overflowCommandTemplate = '$null = Start-Process -FilePath ''{0}'' -ArgumentList @(''-NoProfile'',''-NonInteractive'',''-Command'', ''{1}'') -PassThru; Start-Sleep -Milliseconds 500; [Console]::Write(("x" * 8192)); Start-Sleep -Seconds 30'
        $overflowCommand = $overflowCommandTemplate -f $powershell.Replace("'", "''"), $overflowChildCommand.Replace("'", "''")
        $overflowPid = $null
        try {
            Assert-SnapshotThrowsMatching -Action {
                [LifeOSSnapshotNative]::RunBounded($powershell, @('-NoProfile', '-NonInteractive', '-Command', $overflowCommand), 5000, 1024) | Out-Null
            } -Pattern 'Tailscale stdout output exceeds its byte bound.' -ExpectedExceptionType ([IO.InvalidDataException]) `
                -MaxElapsedMilliseconds 4000 -Message 'native process reader rejects output overflow with a descendant'
            $overflowPidDeadline = (Get-Date).ToUniversalTime().AddSeconds(3)
            while ($null -eq $overflowPid -and (Get-Date).ToUniversalTime() -lt $overflowPidDeadline) {
                if (Test-Path -LiteralPath $overflowPidPath -PathType Leaf) {
                    try { $overflowPid = [int](Get-Content -LiteralPath $overflowPidPath -Raw -ErrorAction Stop) } catch { $overflowPid = $null }
                }
                if ($null -eq $overflowPid) { Start-Sleep -Milliseconds 50 }
            }
            Assert-SnapshotTest ($null -ne $overflowPid) 'output overflow test records the descendant process id'
            $overflowChildGone = $false
            $overflowGoneDeadline = (Get-Date).ToUniversalTime().AddSeconds(3)
            while ((Get-Date).ToUniversalTime() -lt $overflowGoneDeadline) {
                $overflowProcess = Get-Process -Id $overflowPid -ErrorAction SilentlyContinue
                if ($null -eq $overflowProcess) { $overflowChildGone = $true; break }
                Start-Sleep -Milliseconds 50
            }
            Assert-SnapshotTest $overflowChildGone 'native process job removes descendants on output overflow'
        } finally {
            if ($null -ne $overflowPid) {
                Get-Process -Id $overflowPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
        }

        # A successful parent can close the inherited stdout/stderr handles
        # through a child and then exit while that child keeps sleeping. The
        # wrapper must observe the non-zero job accounting count and fail
        # safely, rather than returning the parent's zero exit code as success.
        $closedOutputChildScriptPath = Join-Path $testRoot 'closed-output-child.ps1'
        $closedOutputParentScriptPath = Join-Path $testRoot 'closed-output-parent.ps1'
        $closedOutputPidPath = Join-Path $testRoot 'closed-output-descendant.pid'
        $closedOutputChildScript = @'
param([Parameter(Mandatory)][string]$PidPath)
[IO.File]::WriteAllText($PidPath, [string]$PID, [Text.UTF8Encoding]::new($false))
Add-Type -TypeDefinition @"
using System;
using System.IO;
using System.Runtime.InteropServices;
public static class LifeOSClosedOutputHandles
{
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int standardHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetStdHandle(int standardHandle, IntPtr handle);
    public static void CloseStandardOutputAndError()
    {
        IntPtr output = GetStdHandle(-11);
        IntPtr error = GetStdHandle(-12);
        try { Console.Out.Flush(); } catch (IOException) { }
        try { Console.Error.Flush(); } catch (IOException) { }
        try { Console.Out.Close(); } catch (IOException) { }
        try { Console.Error.Close(); } catch (IOException) { }
        SetStdHandle(-11, IntPtr.Zero);
        SetStdHandle(-12, IntPtr.Zero);
        CloseHandle(output);
        CloseHandle(error);
    }
}
"@ -ErrorAction Stop | Out-Null
[LifeOSClosedOutputHandles]::CloseStandardOutputAndError()
Start-Sleep -Seconds 30
'@
        [IO.File]::WriteAllText($closedOutputChildScriptPath, $closedOutputChildScript, [Text.UTF8Encoding]::new($false))
        $closedOutputParentScript =
            "param([string]`$PowerShellPath, [string]`$ChildScriptPath, [string]`$PidPath)" + [Environment]::NewLine +
            "Add-Type -TypeDefinition @'" + [Environment]::NewLine +
            $processTreeNativeSource + [Environment]::NewLine +
            "'@ -ErrorAction Stop" + [Environment]::NewLine +
            "[LifeOSSnapshotProcessTreeTestNative]::LaunchChildAndReturn(`$PowerShellPath, @('-NoProfile', '-NonInteractive', '-File', `$ChildScriptPath, '-PidPath', `$PidPath))"
        [IO.File]::WriteAllText($closedOutputParentScriptPath, $closedOutputParentScript, [Text.UTF8Encoding]::new($false))
        $closedOutputPid = $null
        try {
            Assert-SnapshotThrowsMatching -Action {
                [LifeOSSnapshotNative]::RunBounded(
                    $powershell,
                    @('-NoProfile', '-NonInteractive', '-File', $closedOutputParentScriptPath,
                      '-PowerShellPath', $powershell, '-ChildScriptPath', $closedOutputChildScriptPath,
                      '-PidPath', $closedOutputPidPath),
                    5000,
                    4096) | Out-Null
            } -Pattern 'active job process' -ExpectedExceptionType ([IO.IOException]) `
                -MaxElapsedMilliseconds 8000 -Message 'native process reader rejects a successful parent with an active closed-output descendant'
            $pidDeadline = (Get-Date).ToUniversalTime().AddSeconds(3)
            while ($null -eq $closedOutputPid -and (Get-Date).ToUniversalTime() -lt $pidDeadline) {
                if (Test-Path -LiteralPath $closedOutputPidPath -PathType Leaf) {
                    try { $closedOutputPid = [int](Get-Content -LiteralPath $closedOutputPidPath -Raw -ErrorAction Stop) } catch { $closedOutputPid = $null }
                }
                if ($null -eq $closedOutputPid) { Start-Sleep -Milliseconds 50 }
            }
            Assert-SnapshotTest ($null -ne $closedOutputPid) 'closed-output descendant records its process id'
            $closedOutputGone = $false
            $goneDeadline = (Get-Date).ToUniversalTime().AddSeconds(3)
            while ((Get-Date).ToUniversalTime() -lt $goneDeadline) {
                if ($null -eq (Get-Process -Id $closedOutputPid -ErrorAction SilentlyContinue)) {
                    $closedOutputGone = $true
                    break
                }
                Start-Sleep -Milliseconds 50
            }
            Assert-SnapshotTest $closedOutputGone 'accounting failure cleanup removes the closed-output descendant'
        } finally {
            if ($null -ne $closedOutputPid) {
                Get-Process -Id $closedOutputPid -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            foreach ($path in @($closedOutputChildScriptPath, $closedOutputParentScriptPath, $closedOutputPidPath)) {
                if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
            }
        }

        # An unrelated inheritable handle must not cross the STARTUPINFOEX
        # boundary. The child receives the numeric value only as a probe; it
        # can read the unique marker only when the kernel inherited the handle.
        $sentinelPath = Join-Path $testRoot 'inheritance-sentinel.txt'
        $sentinelMarker = 'lifeos-unlisted-inheritance-sentinel-9f5c'
        [IO.File]::WriteAllText($sentinelPath, $sentinelMarker, [Text.UTF8Encoding]::new($false))
        $sentinelHandle = $null
        $probePath = Join-Path $testRoot 'inheritance-probe.ps1'
        $positiveResultPath = Join-Path $testRoot 'inheritance-positive-result.txt'
        $probeScript = @'
param([string]$HandleValue, [string]$Expected, [string]$ResultPath)
$safe = $null
$stream = $null
$result = 'absent'
try {
    $safe = [Microsoft.Win32.SafeHandles.SafeFileHandle]::new([IntPtr]::new([Int64]$HandleValue), $false)
    $stream = [IO.FileStream]::new($safe, [IO.FileAccess]::Read, 1024, $false)
    $buffer = New-Object byte[] 256
    $count = $stream.Read($buffer, 0, $buffer.Length)
    $observed = [Text.Encoding]::UTF8.GetString($buffer, 0, $count)
    if ($observed -ceq $Expected) { $result = 'inherited' }
} catch { $result = 'absent' }
finally {
    if ($null -ne $stream) { $stream.Dispose() }
    if ($null -ne $safe) { $safe.Dispose() }
}
[IO.File]::WriteAllText($ResultPath, $result, [Text.UTF8Encoding]::new($false))
[Console]::Write($result)
'@
        [IO.File]::WriteAllText($probePath, $probeScript, [Text.UTF8Encoding]::new($false))
        try {
            $sentinelHandle = [LifeOSSnapshotInheritanceTestNative]::CreateInheritableReadHandle($sentinelPath)
            $sentinelValue = [string]$sentinelHandle.DangerousGetHandle().ToInt64()
            [LifeOSSnapshotInheritanceTestNative]::LaunchWithAllInheritableHandles(
                $powershell, $probePath, $sentinelValue, $sentinelMarker, $positiveResultPath)
            Assert-SnapshotTest ([IO.File]::ReadAllText($positiveResultPath) -ceq 'inherited') 'positive inheritance control reads the sentinel'
            # The positive control consumed the shared file cursor. Reopen the
            # inheritable handle so a wrongly unrestricted production launch
            # cannot pass the negative probe merely by reading EOF.
            $sentinelHandle.Dispose()
            $sentinelHandle = [LifeOSSnapshotInheritanceTestNative]::CreateInheritableReadHandle($sentinelPath)
            $sentinelValue = [string]$sentinelHandle.DangerousGetHandle().ToInt64()
            $probeOutput = [LifeOSSnapshotNative]::RunBounded(
                $powershell,
                @('-NoProfile', '-NonInteractive', '-File', $probePath, $sentinelValue, $sentinelMarker, $positiveResultPath),
                5000,
                4096)
            Assert-SnapshotTest ($probeOutput -ceq 'absent') 'native process child receives only listed stdio handles'
        } finally {
            if ($null -ne $sentinelHandle) { $sentinelHandle.Dispose() }
            if (Test-Path -LiteralPath $probePath) { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $sentinelPath) { Remove-Item -LiteralPath $sentinelPath -Force -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $positiveResultPath) { Remove-Item -LiteralPath $positiveResultPath -Force -ErrorAction SilentlyContinue }
        }
    } else {
        Write-Host 'SKIP: Windows PowerShell executable is unavailable for process-bound tests.'
    }

    Set-SnapshotRestrictedFileSecurity -Path $destination -GatewaySid $gatewayTestSid
    Assert-SnapshotSecurity -Path $destination -GatewaySid $gatewayTestSid
    Assert-SnapshotReaderAccess -Path $destination -GatewaySid $gatewayTestSid -Acl (Get-Acl -LiteralPath $destination)
    Write-Host 'PASS: final snapshot ACL has explicit reader access and no untrusted mutation grant'

    & {
        $script:snapshotAclFixture = [pscustomobject]@{
            Owner = [Security.Principal.SecurityIdentifier]::new($gatewayTestSid)
            Access = @()
        }
        function Get-Acl {
            [CmdletBinding()]
            param([string]$LiteralPath)
            return $script:snapshotAclFixture
        }
        try {
            Assert-SnapshotTest ($gatewayTestSid -notin @(Get-SnapshotAllowedOwnerSids)) 'Gateway SID is excluded from allowed snapshot owners'
            Assert-SnapshotThrows { Assert-SnapshotSecurity -Path 'gateway-owned-fixture' -GatewaySid $gatewayTestSid } 'Gateway-owned snapshot object is rejected'
        } finally {
            Remove-Variable -Name snapshotAclFixture -Scope Script -ErrorAction SilentlyContinue
        }
    }

    # Keep the old identity open at its rollback sibling while the new file is
    # published. A deliberate post-publication failure must delete the new
    # file by handle and put the exact old identity and bytes back.
    Set-SnapshotRestrictedFileSecurity -Path $testRoot -GatewaySid $gatewayTestSid
    $previousSnapshotInfo = [LifeOSSnapshotNative]::Inspect($destination, $false)
    $previousSnapshotBytes = [IO.File]::ReadAllBytes($destination)
    $replacementBytes = [Text.UTF8Encoding]::new($false).GetBytes('{"schemaVersion":1,"value":"replacement"}')
    $script:replacementCallbackRan = $false
    $script:replacementCallbackIdentity = $null
    $script:replacementCallbackBytes = $null
    $publicationFailure = $null
    try {
        Invoke-SnapshotPublication -OutputPath $destination -GatewaySid $gatewayTestSid -Bytes $replacementBytes -PostPublicationVerification {
            $script:replacementCallbackRan = $true
            $script:replacementCallbackIdentity = [string]([LifeOSSnapshotNative]::Inspect($destination, $false).Identity)
            $callbackHandle = [LifeOSSnapshotNative]::OpenExistingForRename($destination)
            try {
                $script:replacementCallbackBytes = [LifeOSSnapshotNative]::ReadBounded($callbackHandle, 256 * 1024)
            } finally {
                $callbackHandle.Dispose()
            }
            throw 'deliberate post-publication verification failure'
        }
    } catch { $publicationFailure = $_ }
    Assert-SnapshotTest ($null -ne $publicationFailure) 'post-publication verification failure is surfaced'
    if (-not $script:replacementCallbackRan) {
        Write-Host "INFO: publication failed before callback: $($publicationFailure.Exception.Message)"
    }
    Assert-SnapshotTest $script:replacementCallbackRan 'post-publication callback observed the replacement before failure'
    Assert-SnapshotTest ($script:replacementCallbackIdentity -ne [string]$previousSnapshotInfo.Identity) 'post-publication callback observed a new snapshot identity'
    Assert-SnapshotTest ($null -ne $script:replacementCallbackBytes) 'post-publication callback read the replacement bytes'
    Assert-SnapshotTest ([Convert]::ToBase64String($script:replacementCallbackBytes) -ceq [Convert]::ToBase64String($replacementBytes)) 'post-publication callback observed replacement bytes'
    $restoredSnapshotInfo = [LifeOSSnapshotNative]::Inspect($destination, $false)
    Assert-SnapshotTest ([string]$restoredSnapshotInfo.Identity -ceq [string]$previousSnapshotInfo.Identity) 'post-publication failure restores the previous snapshot identity'
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($previousSnapshotBytes)) 'post-publication failure restores the previous snapshot bytes'
    Assert-SnapshotTest (@(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.rollback' -Force -ErrorAction Stop).Count -eq 0) 'post-publication rollback leaves no rollback artifact'

    # ERROR_UNABLE_TO_REMOVE_REPLACED (1175) and ERROR_UNABLE_TO_MOVE_REPLACEMENT
    # (1176) with a backup path specified leave the original and replacement
    # under their original names. Inject both errors at the existing
    # TestReplaceFileOperation seam so the real publication catch path performs
    # identity recovery and preserves the original Win32 error.
    foreach ($replaceFileState in @(1175, 1176)) {
        $script:replaceStateInjectionRan = $false
        Assert-SnapshotThrowsMatching -Action {
            Invoke-SnapshotPublication `
                -OutputPath $destination `
                -GatewaySid $gatewayTestSid `
                -Bytes $replacementBytes `
                -TestReplaceFileOperation {
                    param($injectedDestination, $injectedReplacement, $injectedRollback)
                    $script:replaceStateInjectionRan = $true
                    throw [ComponentModel.Win32Exception]::new(
                        [int]$replaceFileState,
                        ('simulated ReplaceFileW failure ' + $replaceFileState))
                }
        } -Pattern ('Win32 ' + $replaceFileState) -ExpectedExceptionType ([System.Management.Automation.RuntimeException]) `
            -MaxElapsedMilliseconds 5000 -Message ('publication recovers injected ReplaceFileW state ' + $replaceFileState)
        Assert-SnapshotTest $script:replaceStateInjectionRan ('publication invoked the ReplaceFileW injection seam for ' + $replaceFileState)
        $stateRestoredInfo = [LifeOSSnapshotNative]::Inspect($destination, $false)
        Assert-SnapshotTest ([string]$stateRestoredInfo.Identity -ceq [string]$previousSnapshotInfo.Identity) ('ReplaceFileW state ' + $replaceFileState + ' restores the original identity')
        Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($previousSnapshotBytes)) ('ReplaceFileW state ' + $replaceFileState + ' restores the original bytes')
        Assert-SnapshotTest (@(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.tmp' -Force -ErrorAction Stop).Count -eq 0) ('ReplaceFileW state ' + $replaceFileState + ' leaves no temporary artifact')
        Assert-SnapshotTest (@(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.rollback' -Force -ErrorAction Stop).Count -eq 0) ('ReplaceFileW state ' + $replaceFileState + ' leaves no rollback artifact')
    }

    # Model ReplaceFileW's documented partial state where the replacement
    # remains at its temporary name and the original is at the backup name.
    # Recovery must restore by identity and delete only the known replacement.
    $partialTempPath = Join-Path $testRoot '.partial-replacement.tmp'
    $partialRollbackPath = Join-Path $testRoot '.partial-replacement.rollback'
    $partialParentHandle = $null
    $partialOriginalHandle = $null
    $partialReplacementHandle = $null
    $partialWriter = $null
    try {
        $partialParentHandle = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
        $partialOriginalHandle = [LifeOSSnapshotNative]::OpenExistingForRename($destination)
        [LifeOSSnapshotNative]::RenameWithHeldParent(
            $partialOriginalHandle, $partialParentHandle, $partialRollbackPath, $false)
        $partialOriginalHandle.Dispose()
        $partialOriginalHandle = $null
        $partialReplacementHandle = [LifeOSSnapshotNative]::CreateExclusiveForWrite($partialTempPath, $gatewayTestSid)
        $partialWriter = [IO.FileStream]::new($partialReplacementHandle, [IO.FileAccess]::ReadWrite, 8192, $false)
        $partialWriter.Write($replacementBytes, 0, $replacementBytes.Length)
        $partialWriter.Flush($true)
        $partialReplacementInfo = [LifeOSSnapshotNative]::InspectHandle($partialReplacementHandle)
        $partialWriter.Dispose()
        $partialWriter = $null
        $partialReplacementHandle.Dispose()
        $partialReplacementHandle = $null
        Assert-SnapshotTest (Recover-SnapshotReplacementFailure `
            -DestinationPath $destination `
            -ReplacementPath $partialTempPath `
            -RollbackPath $partialRollbackPath `
            -ExpectedReplacement $partialReplacementInfo `
            -ExpectedOriginal $previousSnapshotInfo `
            -ParentHandle $partialParentHandle) 'partial ReplaceFileW state restores by identity'
        $partialRestoredInfo = [LifeOSSnapshotNative]::Inspect($destination, $false)
        Assert-SnapshotTest ([string]$partialRestoredInfo.Identity -ceq [string]$previousSnapshotInfo.Identity) 'partial ReplaceFileW state restores the original identity'
        Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($previousSnapshotBytes)) 'partial ReplaceFileW state restores the original bytes'
        Assert-SnapshotTest (-not (Test-Path -LiteralPath $partialTempPath) -and -not (Test-Path -LiteralPath $partialRollbackPath)) 'partial ReplaceFileW state leaves no orphan paths'
    } finally {
        if ($null -ne $partialWriter) { $partialWriter.Dispose() }
        if ($null -ne $partialReplacementHandle) { try { [LifeOSSnapshotNative]::DeleteByHandle($partialReplacementHandle) } catch { }; $partialReplacementHandle.Dispose() }
        if ($null -ne $partialOriginalHandle) { $partialOriginalHandle.Dispose() }
        if ($null -ne $partialParentHandle) { $partialParentHandle.Dispose() }
    }

    # Route a simulated ERROR_UNABLE_TO_MOVE_REPLACEMENT_2 through the actual
    # publication catch path. This keeps the identity recovery test coupled to
    # the production flags rather than only testing the helper in isolation.
    $script:injectedPartialRan = $false
    $injectedPartialFailure = $null
    try {
        Invoke-SnapshotPublication -OutputPath $destination -GatewaySid $gatewayTestSid -Bytes $replacementBytes -TestReplaceFileOperation {
            param($injectedDestination, $injectedReplacement, $injectedRollback)
            $script:injectedPartialRan = $true
            $injectedParent = $null
            $injectedOld = $null
            try {
                $injectedParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
                $injectedOld = [LifeOSSnapshotNative]::OpenExistingForRename($injectedDestination)
                [LifeOSSnapshotNative]::RenameWithHeldParent(
                    $injectedOld, $injectedParent, $injectedRollback, $false)
            } finally {
                if ($null -ne $injectedOld) { $injectedOld.Dispose() }
                if ($null -ne $injectedParent) { $injectedParent.Dispose() }
            }
            throw [ComponentModel.Win32Exception]::new(1177, 'simulated replacement move failure')
        }
    } catch { $injectedPartialFailure = $_ }
    Assert-SnapshotTest ($null -ne $injectedPartialFailure) 'injected ReplaceFileW partial failure is surfaced'
    Assert-SnapshotTest $script:injectedPartialRan 'injected ReplaceFileW partial failure reached the native catch path'
    Assert-SnapshotTest ($injectedPartialFailure.Exception.ToString().IndexOf('1177', [StringComparison]::Ordinal) -ge 0) 'injected ReplaceFileW partial failure preserves the native error'
    $injectedRestoredInfo = [LifeOSSnapshotNative]::Inspect($destination, $false)
    Assert-SnapshotTest ([string]$injectedRestoredInfo.Identity -ceq [string]$previousSnapshotInfo.Identity) 'injected ReplaceFileW partial failure restores the original identity'
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($destination)) -ceq [Convert]::ToBase64String($previousSnapshotBytes)) 'injected ReplaceFileW partial failure restores the original bytes'
    Assert-SnapshotTest (@(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.rollback' -Force -ErrorAction Stop).Count -eq 0) 'injected ReplaceFileW partial failure leaves no rollback artifact'

    # Force the post-swap reopen to see an unexpected leaf. The production
    # catch path must leave both the unauthorized leaf and the moved expected
    # replacement untouched while retaining the old rollback copy.
    $reopenMovedPath = Join-Path $testRoot '.reopen-moved'
    $reopenUnauthorizedText = 'unauthorized-reopen-object'
    $reopenFailure = $null
    try {
        Invoke-SnapshotPublication -OutputPath $destination -GatewaySid $gatewayTestSid -Bytes $replacementBytes -TestAfterReplaceOperation {
            param($reopenDestination, $reopenReplacement, $reopenRollback)
            $reopenParent = $null
            $reopenHandle = $null
            try {
                $reopenParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
                $reopenHandle = [LifeOSSnapshotNative]::OpenExistingForRename($reopenDestination)
                [LifeOSSnapshotNative]::RenameWithHeldParent(
                    $reopenHandle, $reopenParent, $reopenMovedPath, $false)
            } finally {
                if ($null -ne $reopenHandle) { $reopenHandle.Dispose() }
                if ($null -ne $reopenParent) { $reopenParent.Dispose() }
            }
            [IO.File]::WriteAllText($reopenDestination, $reopenUnauthorizedText, [Text.UTF8Encoding]::new($false))
        }
    } catch { $reopenFailure = $_ }
    Assert-SnapshotTest ($null -ne $reopenFailure) 'post-swap reopen identity failure is surfaced'
    Assert-SnapshotTest ([IO.File]::ReadAllText($destination) -ceq $reopenUnauthorizedText) 'post-swap reopen leaves the unexpected destination untouched'
    Assert-SnapshotTest ([IO.File]::ReadAllText($reopenMovedPath) -ceq [Text.Encoding]::UTF8.GetString($replacementBytes)) 'post-swap reopen leaves the expected replacement untouched'
    $reopenRollback = @(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.rollback' -Force -ErrorAction Stop)
    Assert-SnapshotTest ($reopenRollback.Count -eq 1) 'post-swap reopen retains the rollback artifact'
    $reopenRollbackInfo = [LifeOSSnapshotNative]::Inspect($reopenRollback[0].FullName, $false)
    Assert-SnapshotTest ([string]$reopenRollbackInfo.Identity -ceq [string]$previousSnapshotInfo.Identity) 'post-swap reopen retains the original identity'
    Remove-Item -LiteralPath $destination -Force
    Remove-Item -LiteralPath $reopenMovedPath -Force
    $reopenParent = $null
    $reopenOld = $null
    try {
        $reopenParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
        $reopenOld = [LifeOSSnapshotNative]::OpenExistingForRename($reopenRollback[0].FullName)
        [LifeOSSnapshotNative]::RenameWithHeldParent($reopenOld, $reopenParent, $destination, $false)
    } finally {
        if ($null -ne $reopenOld) { $reopenOld.Dispose() }
        if ($null -ne $reopenParent) { $reopenParent.Dispose() }
    }
    Assert-SnapshotTest (-not (Test-Path -LiteralPath $reopenRollback[0].FullName)) 'post-swap reopen rollback artifact is cleaned after manual recovery'

    # A conflicting directory at the destination must make restoration fail
    # safely. The rollback copy is retained with the exact old identity and
    # bytes until the operator removes the conflict and recovery completes.
    $script:rollbackMoveHandle = $null
    $script:rollbackMoveParent = $null
    $movedReplacementPath = Join-Path $testRoot '.replacement-moved'
    $rollbackFailure = $null
    try {
        Invoke-SnapshotPublication -OutputPath $destination -GatewaySid $gatewayTestSid -Bytes $replacementBytes -PostPublicationVerification {
            $script:rollbackMoveParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
            $script:rollbackMoveHandle = [LifeOSSnapshotNative]::OpenExistingForRename($destination)
            [LifeOSSnapshotNative]::RenameWithHeldParent(
                $script:rollbackMoveHandle, $script:rollbackMoveParent, $movedReplacementPath, $false)
            $script:rollbackMoveHandle.Dispose()
            $script:rollbackMoveHandle = $null
            $script:rollbackMoveParent.Dispose()
            $script:rollbackMoveParent = $null
            [IO.Directory]::CreateDirectory($destination) | Out-Null
            throw 'deliberate rollback-retention failure'
        }
    } catch { $rollbackFailure = $_ }
    Assert-SnapshotTest ($null -ne $rollbackFailure) 'failed restoration is surfaced'
    $retainedRollback = @(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.rollback' -Force -ErrorAction Stop)
    Assert-SnapshotTest ($retainedRollback.Count -eq 1) 'failed restoration retains one rollback artifact'
    $onePreservedPathDiagnostic = 'preserved paths: ' + $retainedRollback[0].FullName + '; recovery failure:'
    Assert-SnapshotTest ($rollbackFailure.Exception.Message.IndexOf($onePreservedPathDiagnostic, [StringComparison]::Ordinal) -ge 0) 'publication failure diagnostics report exactly one preserved path'
    $retainedRollbackInfo = [LifeOSSnapshotNative]::Inspect($retainedRollback[0].FullName, $false)
    Assert-SnapshotTest ([string]$retainedRollbackInfo.Identity -ceq [string]$previousSnapshotInfo.Identity) 'retained rollback preserves the original identity'
    Assert-SnapshotTest ([Convert]::ToBase64String([IO.File]::ReadAllBytes($retainedRollback[0].FullName)) -ceq [Convert]::ToBase64String($previousSnapshotBytes)) 'retained rollback preserves the original bytes'
    if ($null -ne $script:rollbackMoveHandle) { $script:rollbackMoveHandle.Dispose(); $script:rollbackMoveHandle = $null }
    if ($null -ne $script:rollbackMoveParent) { $script:rollbackMoveParent.Dispose(); $script:rollbackMoveParent = $null }
    if (Test-Path -LiteralPath $destination -PathType Container) { Remove-Item -LiteralPath $destination -Recurse -Force }
    if (Test-Path -LiteralPath $movedReplacementPath) { Remove-Item -LiteralPath $movedReplacementPath -Force }
    $retainedParent = $null
    $retainedOld = $null
    try {
        $retainedParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
        $retainedOld = [LifeOSSnapshotNative]::OpenExistingForRename($retainedRollback[0].FullName)
        [LifeOSSnapshotNative]::RenameWithHeldParent($retainedOld, $retainedParent, $destination, $false)
    } finally {
        if ($null -ne $retainedOld) { $retainedOld.Dispose() }
        if ($null -ne $retainedParent) { $retainedParent.Dispose() }
    }
    Assert-SnapshotTest (-not (Test-Path -LiteralPath $retainedRollback[0].FullName)) 'retained rollback is removable after the blocker is released'

    # Exercise the diagnostic cardinality explicitly. Fail before
    # rollbackPathPublished is set so the production recovery catch path owns
    # the state observation and reports the paths it had to preserve.
    $diagnosticDestination = Join-Path $testRoot 'diagnostic-state.json'
    Publish-TestBytes -Root $testRoot -Destination $diagnosticDestination -Bytes $previousSnapshotBytes -Replace:$false -GatewaySid $gatewayTestSid
    $zeroDiagnosticFailure = $null
    try {
        Invoke-SnapshotPublication `
            -OutputPath $diagnosticDestination `
            -GatewaySid $gatewayTestSid `
            -Bytes $replacementBytes `
            -TestReplaceFileOperation {
                param($zeroDestination, $zeroReplacement, $zeroRollback)
                $zeroDestinationHandle = $null
                $zeroReplacementHandle = $null
                try {
                    $zeroDestinationHandle = [LifeOSSnapshotNative]::OpenExistingForDelete($zeroDestination)
                    [LifeOSSnapshotNative]::DeleteByHandle($zeroDestinationHandle)
                    $zeroReplacementHandle = [LifeOSSnapshotNative]::OpenExistingForDelete($zeroReplacement)
                    [LifeOSSnapshotNative]::DeleteByHandle($zeroReplacementHandle)
                } finally {
                    if ($null -ne $zeroDestinationHandle) { $zeroDestinationHandle.Dispose() }
                    if ($null -ne $zeroReplacementHandle) { $zeroReplacementHandle.Dispose() }
                }
                throw [ComponentModel.Win32Exception]::new(1175, 'simulated zero-path ReplaceFileW failure')
            }
    } catch { $zeroDiagnosticFailure = $_ }
    Assert-SnapshotTest ($null -ne $zeroDiagnosticFailure) 'zero preserved-path recovery failure is surfaced'
    Assert-SnapshotTest ($zeroDiagnosticFailure.Exception.Message.IndexOf(
        'preserved paths: none; recovery failure:', [StringComparison]::Ordinal) -ge 0) 'publication failure diagnostics report zero preserved paths'
    if (Test-Path -LiteralPath $diagnosticDestination -PathType Container) { Remove-Item -LiteralPath $diagnosticDestination -Recurse -Force }
    Publish-TestBytes -Root $testRoot -Destination $diagnosticDestination -Bytes $previousSnapshotBytes -Replace:$false -GatewaySid $gatewayTestSid

    # Leave both the replacement temporary path and the rollback path as
    # regular files while the destination is an uncounted directory blocker.
    # The resulting diagnostic must list both paths in candidate order.
    $script:multipleDiagnosticTempPath = $null
    $script:multipleDiagnosticRollbackPath = $null
    $multipleDiagnosticFailure = $null
    try {
        Invoke-SnapshotPublication `
            -OutputPath $diagnosticDestination `
            -GatewaySid $gatewayTestSid `
            -Bytes $replacementBytes `
            -TestReplaceFileOperation {
                param($multipleDestination, $multipleReplacement, $multipleRollback)
                $script:multipleDiagnosticTempPath = $multipleReplacement
                $script:multipleDiagnosticRollbackPath = $multipleRollback
                $multipleParent = $null
                $multipleCurrentHandle = $null
                try {
                    $multipleParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
                    $multipleCurrentHandle = [LifeOSSnapshotNative]::OpenExistingForRename($diagnosticDestination)
                    [LifeOSSnapshotNative]::RenameWithHeldParent(
                        $multipleCurrentHandle, $multipleParent, $multipleRollback, $false)
                    [IO.Directory]::CreateDirectory($diagnosticDestination) | Out-Null
                } finally {
                    if ($null -ne $multipleCurrentHandle) { $multipleCurrentHandle.Dispose() }
                    if ($null -ne $multipleParent) { $multipleParent.Dispose() }
                }
                throw [ComponentModel.Win32Exception]::new(1176, 'simulated multiple-path ReplaceFileW failure')
            }
    } catch { $multipleDiagnosticFailure = $_ }
    Assert-SnapshotTest ($null -ne $multipleDiagnosticFailure) 'multiple preserved-path recovery failure is surfaced'
    $multiplePreservedPathDiagnostic =
        'preserved paths: ' + $script:multipleDiagnosticTempPath + ', ' + $script:multipleDiagnosticRollbackPath + '; recovery failure:'
    Assert-SnapshotTest ($multipleDiagnosticFailure.Exception.Message.IndexOf(
        $multiplePreservedPathDiagnostic, [StringComparison]::Ordinal) -ge 0) 'publication failure diagnostics report multiple preserved paths in candidate order'
    if (Test-Path -LiteralPath $diagnosticDestination -PathType Container) { Remove-Item -LiteralPath $diagnosticDestination -Recurse -Force }
    if (Test-Path -LiteralPath $script:multipleDiagnosticTempPath) { Remove-Item -LiteralPath $script:multipleDiagnosticTempPath -Force }
    $multipleRestoreParent = $null
    $multipleRestoreHandle = $null
    try {
        $multipleRestoreParent = [LifeOSSnapshotNative]::OpenDirectory($testRoot)
        $multipleRestoreHandle = [LifeOSSnapshotNative]::OpenExistingForRename($script:multipleDiagnosticRollbackPath)
        [LifeOSSnapshotNative]::RenameWithHeldParent(
            $multipleRestoreHandle, $multipleRestoreParent, $diagnosticDestination, $false)
    } finally {
        if ($null -ne $multipleRestoreHandle) { $multipleRestoreHandle.Dispose() }
        if ($null -ne $multipleRestoreParent) { $multipleRestoreParent.Dispose() }
    }
    Assert-SnapshotTest (-not (Test-Path -LiteralPath $script:multipleDiagnosticRollbackPath)) 'multiple preserved-path diagnostic rollback is cleaned after manual recovery'

    $noPriorDestination = Join-Path $testRoot 'no-prior-snapshot.json'
    $script:noPriorCallbackRan = $false
    Assert-SnapshotThrows {
        Invoke-SnapshotPublication -OutputPath $noPriorDestination -GatewaySid $gatewayTestSid -Bytes $replacementBytes -PostPublicationVerification {
            $script:noPriorCallbackRan = $true
            throw 'deliberate post-publication verification failure without a prior snapshot'
        }
    } 'post-publication failure without a prior snapshot is surfaced'
    Assert-SnapshotTest $script:noPriorCallbackRan 'no-prior post-publication callback was reached before failure'
    Assert-SnapshotTest (-not (Test-Path -LiteralPath $noPriorDestination)) 'failed publication without a prior snapshot removes the new file by handle'
    Assert-SnapshotTest (@(Get-ChildItem -LiteralPath $testRoot -Filter '.tailscale-state.*.rollback' -Force -ErrorAction Stop).Count -eq 0) 'failed publication without a prior snapshot leaves no rollback artifact'

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
