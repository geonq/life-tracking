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
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [switch]$AllowNonZero,
        [switch]$Quiet
    )
    $output = & $FilePath @ArgumentList 2>&1
    $exitCode = $LASTEXITCODE
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
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) { $candidates += $Requested }
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
        $path = $candidate
        if (Test-Path -LiteralPath $path -PathType Leaf) { $path = Split-Path -Parent $path }
        if ((Test-Path -LiteralPath $path -PathType Container) -and
            (Test-Path -LiteralPath (Join-Path $path 'python.exe') -PathType Leaf)) {
            Assert-NoReparsePath $path
            return (Get-FullPath $path)
        }
    }
    throw 'An installed Python 3.12 base or venv containing python.exe is required; pass -PythonRuntimeSource explicitly.'
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

function Copy-FileVerifiedAtomic {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$BackupDirectory)
    Assert-ExistingFile $Source 'Copy source'
    $parent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $parent
    $sourceHash = Get-FileSha256 $Source
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Assert-NoReparsePath $Destination
        if ((Get-FileSha256 $Destination) -eq $sourceHash) {
            return [pscustomobject]@{ Destination = $Destination; SourceHash = $sourceHash; Backup = $null; Changed = $false }
        }
    }
    $backup = $null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        $backup = Backup-File $Destination $BackupDirectory ("previous-" + [IO.Path]::GetFileName($Destination))
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temp -Force
        Assert-NoReparsePath $temp
        if ((Get-FileSha256 $temp) -ne $sourceHash) { throw "Atomic copy hash verification failed for $Source." }
        Move-Item -LiteralPath $temp -Destination $Destination -Force
        if ((Get-FileSha256 $Destination) -ne $sourceHash) { throw "Destination hash verification failed for $Destination." }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Destination = $Destination; SourceHash = $sourceHash; Backup = $backup; Changed = $true }
}

function Copy-TreeVerifiedAtomic {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$BackupDirectory)
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
            $backup = Join-Path $BackupDirectory ('previous-' + [IO.Path]::GetFileName($Destination))
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        if (-not (Compare-TreeManifest $Source $Destination)) { throw "Staged tree verification failed for $Destination." }
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
    param([Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Value, [Parameter(Mandatory)][string]$BackupDirectory)
    if ($Value.Length -lt 32 -or $Value.Length -gt 256 -or $Value -match '[^\x21-\x7E]') { throw 'Generated secret did not satisfy the bounded printable format.' }
    $parent = Split-Path -Parent (Get-FullPath $Destination)
    Ensure-Directory $parent
    $backup = $null
    if (Test-Path -LiteralPath $Destination -PathType Leaf) {
        Assert-NoReparsePath $Destination
        $existing = (Get-Content -LiteralPath $Destination -Raw -ErrorAction Stop)
        if ($existing -eq $Value) { return $null }
        $backup = Backup-File $Destination $BackupDirectory ('previous-' + [IO.Path]::GetFileName($Destination))
    }
    $temp = Join-Path $parent ('.' + [IO.Path]::GetFileName($Destination) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temp, $Value, [Text.UTF8Encoding]::new($false))
        Assert-NoReparsePath $temp
        Move-Item -LiteralPath $temp -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    return $backup
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
    $args = @($Path, '/inheritance:r', '/grant:r') + $grant
    if (-not $File) { $args += @('/T', '/C') }
    Invoke-NativeChecked 'icacls.exe' ([string[]]$args) -Quiet | Out-Null
}

function Set-SecretAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [Parameter(Mandatory)][string[]]$ReadSids)
    Set-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -File
}

function Set-BackupAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid)
    Set-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids @() -ModifySids @()
}

function Set-DirectoryTraversalAcl {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$OperatorSid, [Parameter(Mandatory)][string[]]$ReadSids)
    Ensure-Directory $Path
    $grant = @("${OperatorSid}:(F)", 'S-1-5-18:(F)', 'S-1-5-32-544:(F)')
    foreach ($sid in $ReadSids) { $grant += "${sid}:(RX)" }
    Invoke-NativeChecked 'icacls.exe' ([string[]](@($Path, '/inheritance:r', '/grant:r') + $grant)) -Quiet | Out-Null
}

function Assert-NoBroadAcl {
    param([Parameter(Mandatory)][string]$Path)
    $acl = Get-Acl -LiteralPath $Path
    foreach ($entry in $acl.Access) {
        $name = [string]$entry.IdentityReference.Value
        if ($entry.AccessControlType -eq 'Allow' -and $name -match '(?i)(^|\\)(Everyone|Users|Authenticated Users|INTERACTIVE|ANONYMOUS LOGON|NETWORK|LOCAL SERVICE|NETWORK SERVICE|BUILTIN\\Users)$') {
            throw "Broad or shared allow ACL is not permitted on $Path."
        }
    }
}

function Get-ScheduledTaskSnapshot {
    param([Parameter(Mandatory)][string]$TaskName, [Parameter(Mandatory)][string]$BackupDirectory)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return [pscustomobject]@{ Exists = $false; Enabled = $false; Xml = $null; Backup = $null } }
    Ensure-Directory $BackupDirectory
    $xml = Export-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $backup = Join-Path $BackupDirectory ($TaskName + '.xml')
    [IO.File]::WriteAllText($backup, $xml, [Text.UTF8Encoding]::new($false))
    return [pscustomobject]@{ Exists = $true; Enabled = ($task.State -ne 'Disabled'); Xml = $xml; Backup = $backup }
}

function Disable-LegacyTaskAfterCutover {
    param([Parameter(Mandatory)][string]$TaskName)
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) { return }
    Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null
}

function Restore-LegacyTask {
    param([Parameter(Mandatory)][psobject]$Snapshot, [Parameter(Mandatory)][string]$TaskName)
    if (-not $Snapshot.Exists) { return }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        if ([string]::IsNullOrWhiteSpace([string]$Snapshot.Xml)) { throw "Legacy task backup is empty: $TaskName" }
        Register-ScheduledTask -TaskName $TaskName -Xml ([string]$Snapshot.Xml) -Force -ErrorAction Stop | Out-Null
    }
    if ($Snapshot.Enabled) { Enable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
    else { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
}

function Register-CodexCollectorTask {
    param(
        [Parameter(Mandatory)][string]$TaskName,
        [Parameter(Mandatory)][string]$OperatorName,
        [Parameter(Mandatory)][string]$NodeExecutable,
        [Parameter(Mandatory)][string]$ApiDirectory
    )
    Assert-ExistingFile $NodeExecutable 'Codex collector runtime'
    Assert-ExistingDirectory $ApiDirectory 'Codex collector working directory'
    $collector = Join-Path $ApiDirectory 'dist\codex-collector.js'
    Assert-ExistingFile $collector 'Codex collector entry point'
    $esc = { param([string]$Value) [Security.SecurityElement]::Escape($Value) }
    $nodeXml = & $esc $NodeExecutable
    $argsXml = & $esc ('"' + $collector + '"')
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
    Register-ScheduledTask -TaskName $TaskName -Xml $xml -Force -ErrorAction Stop | Out-Null
}

function Restore-CodexCollectorTask {
    param([Parameter(Mandatory)][psobject]$Snapshot, [Parameter(Mandatory)][string]$TaskName)
    if ($Snapshot.Exists) {
        Restore-LegacyTask $Snapshot $TaskName
        return
    }
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $task) { Disable-ScheduledTask -TaskName $TaskName -ErrorAction Stop | Out-Null }
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
        $listeners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
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

function Get-TruthyTailscaleFlags {
    param([Parameter(Mandatory)][object]$Value)
    $found = New-Object System.Collections.ArrayList
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) {
            if ($property.Name -match '^(?i:Funnel|AllowFunnel)$' -and [bool]$property.Value) { [void]$found.Add($property.Name) }
            foreach ($nested in (Get-TruthyTailscaleFlags $property.Value)) { [void]$found.Add($nested) }
        }
    } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { foreach ($nested in (Get-TruthyTailscaleFlags $item)) { [void]$found.Add($nested) } }
    }
    return @($found)
}

function Test-TailscaleServeExact {
    param([Parameter(Mandatory)][string]$Json)
    try { $state = $Json | ConvertFrom-Json -ErrorAction Stop } catch { return $false }
    if ((@(Get-TruthyTailscaleFlags $state)).Count -gt 0) { return $false }
    $proxies = New-Object System.Collections.ArrayList
    function Find-ServeProxies([object]$Value) {
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $Value.PSObject.Properties) {
                if ($property.Name -eq 'Proxy' -and $property.Value -is [string]) { [void]$proxies.Add([string]$property.Value) }
                Find-ServeProxies $property.Value
            }
        } elseif ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
            foreach ($item in $Value) { Find-ServeProxies $item }
        }
    }
    Find-ServeProxies $state
    if (@($proxies | Where-Object { $_ -eq 'http://127.0.0.1:8421' }).Count -ne 1) { return $false }
    $web = $state.Web
    if ($null -ne $web) {
        foreach ($endpoint in $web.PSObject.Properties) {
            if ([string]$endpoint.Name -match ':8420$' -and $null -ne $endpoint.Value.Handlers) {
                $handler = $endpoint.Value.Handlers.PSObject.Properties['/']
                if ($null -ne $handler -and [string]$handler.Value.Proxy -eq 'http://127.0.0.1:8421') { return $true }
            }
        }
    }
    $tcp = $state.TCP
    if ($null -ne $tcp -and $null -ne $tcp.PSObject.Properties['8420']) {
        return (@($proxies | Where-Object { $_ -eq 'http://127.0.0.1:8421' }).Count -eq 1)
    }
    return $false
}

function Configure-TailscaleServe {
    param([Parameter(Mandatory)][string]$TailscaleExecutable)
    Assert-ExistingFile $TailscaleExecutable 'Tailscale executable'
    $status = Get-TailscaleStatusJson $TailscaleExecutable
    if (-not (Test-TailscaleServeExact $status)) {
        # This is deliberately the only Tailscale mutator here.  The installer
        # never invokes the alternate public tunnel command, and never exposes
        # the backend directly.
        Invoke-NativeChecked $TailscaleExecutable @('serve', '--bg', '--https=8420', 'http://127.0.0.1:8421') -Quiet | Out-Null
        $status = Get-TailscaleStatusJson $TailscaleExecutable
    }
    if (-not (Test-TailscaleServeExact $status)) {
        throw 'Tailscale Serve verification failed or Funnel state was reported.'
    }
    return $status
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
