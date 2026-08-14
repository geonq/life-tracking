[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ServiceHostBinarySource,
    [string]$ApiSource = 'D:\Hermes\lifeos-api',
    [string]$GatewaySource = 'D:\Hermes\lifeos-server',
    [string]$NodeRuntimeSource,
    [string]$PythonRuntimeSource,
    [string]$GatewayEntryPoint,
    [string]$TailscaleExecutable,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$CodexTaskName = 'LifeOSCodexCollector'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

function Add-ManifestItem {
    param([Parameter(Mandatory)][System.Collections.IList]$List, [Parameter(Mandatory)][object]$Value)
    [void]$List.Add($Value)
}

function Copy-ApiReleaseBundle {
    param([Parameter(Mandatory)][string]$ApiRoot, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$BackupDirectory)
    $contracts = Resolve-ApiDependencyRoot $ApiRoot '@iphone-life-os\contracts'
    $zod = Resolve-ApiDependencyRoot $ApiRoot 'zod'
    $parent = Split-Path -Parent $Destination
    Ensure-Directory $parent
    $temp = Join-Path $parent ('.api-release-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    try {
        Copy-Item -LiteralPath (Join-Path $ApiRoot 'dist') -Destination (Join-Path $temp 'dist') -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $ApiRoot 'package.json') -Destination (Join-Path $temp 'package.json') -Force
        $contractTarget = Join-Path $temp 'node_modules\@iphone-life-os\contracts'
        Ensure-Directory (Split-Path -Parent $contractTarget)
        Ensure-Directory $contractTarget
        Copy-Item -LiteralPath (Join-Path $contracts 'dist') -Destination (Join-Path $contractTarget 'dist') -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $contracts 'package.json') -Destination (Join-Path $contractTarget 'package.json') -Force
        $zodTarget = Join-Path $temp 'node_modules\zod'
        Copy-Item -LiteralPath $zod -Destination $zodTarget -Recurse -Force
        # The source root intentionally is not compared with the release root:
        # the bundle is a selected production subset.
        $null = Get-TreeManifest (Join-Path $temp 'dist')
        Assert-ExistingFile (Join-Path $temp 'dist\server.js') 'Staged API entry point'
        Assert-ExistingFile (Join-Path $temp 'node_modules\@iphone-life-os\contracts\dist\index.js') 'Staged contracts entry point'
        Assert-ExistingFile (Join-Path $temp 'node_modules\zod\package.json') 'Staged zod package'
        $backup = $null
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            $backup = Join-Path $BackupDirectory 'previous-api-release'
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        return [pscustomobject]@{ Destination = $Destination; Backup = $backup }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Copy-GatewayCodeBundle {
    param([Parameter(Mandatory)][string]$GatewaySource, [Parameter(Mandatory)][string]$GatewayEntryPoint, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$LauncherSource, [Parameter(Mandatory)][string]$BackupDirectory)
    $parent = Split-Path -Parent $Destination
    Ensure-Directory $parent
    $temp = Join-Path $parent ('.gateway-release-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    try {
        $entryRelative = $GatewayEntryPoint.Substring((Get-FullPath $GatewaySource).TrimEnd('\').Length).TrimStart('\')
        if ($entryRelative -ne 'main.py') { throw 'Gateway release must contain only the reviewed root main.py entry point.' }
        Assert-ExistingFile $GatewayEntryPoint 'Gateway main.py'
        Assert-ExistingFile $LauncherSource 'Gateway launcher source'
        Copy-Item -LiteralPath $GatewayEntryPoint -Destination (Join-Path $temp 'main.py') -Force
        Copy-Item -LiteralPath $LauncherSource -Destination (Join-Path $temp 'gateway_launcher.py') -Force
        Write-JsonAtomic (Join-Path $temp 'gateway-release.manifest.json') ([ordered]@{
            mainSha256 = Get-FileSha256 (Join-Path $temp 'main.py')
            launcherSha256 = Get-FileSha256 (Join-Path $temp 'gateway_launcher.py')
        })
        $backup = $null
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            $backup = Join-Path $BackupDirectory 'previous-gateway-release'
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        return [pscustomobject]@{ Destination = $Destination; Backup = $backup; EntryRelative = $entryRelative }
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Get-ChildRuntimeStage {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][string]$BackupDirectory)
    $pyvenv = Join-Path $Source 'pyvenv.cfg'
    if (Test-Path -LiteralPath $pyvenv -PathType Leaf) {
        $cfg = Get-Content -LiteralPath $pyvenv -Raw -ErrorAction Stop
        $homeMatch = [regex]::Match($cfg, '(?m)^\s*home\s*=\s*(?<home>[^\r\n]+)\s*$')
        if (-not $homeMatch.Success) { throw "Python venv has no absolute home entry: $pyvenv" }
        $home = $homeMatch.Groups['home'].Value.Trim()
        Assert-ExistingDirectory $home 'Python base from pyvenv.cfg'
        $baseTarget = Join-Path $RuntimeRoot 'python312'
        $venvTarget = Join-Path $RuntimeRoot 'python-venv'
        $baseResult = Copy-TreeVerifiedAtomic $home $baseTarget $BackupDirectory
        $venvResult = Copy-TreeVerifiedAtomic $Source $venvTarget $BackupDirectory
        $targetCfg = Join-Path $venvTarget 'pyvenv.cfg'
        Assert-ExistingFile $targetCfg 'Staged pyvenv.cfg'
        $updated = Get-Content -LiteralPath $targetCfg -Raw
        $updated = [regex]::Replace($updated, '(?m)^\s*home\s*=\s*[^\r\n]+\s*$', ('home = ' + $baseTarget))
        $updated = [regex]::Replace($updated, '(?m)^\s*executable\s*=\s*[^\r\n]+\s*$', ('executable = ' + (Join-Path $baseTarget 'python.exe')))
        $updated = [regex]::Replace($updated, '(?m)^\s*command\s*=\s*[^\r\n]+\s*$', ('command = ' + (Join-Path $baseTarget 'python.exe') + ' -m venv ' + $venvTarget))
        $updated = $updated.Replace($Source, $venvTarget).Replace($home, $baseTarget)
        $tempCfg = Join-Path $venvTarget ('.pyvenv.cfg.' + [Guid]::NewGuid().ToString('N') + '.tmp')
        try {
            [IO.File]::WriteAllText($tempCfg, $updated, [Text.UTF8Encoding]::new($false))
            Move-Item -LiteralPath $tempCfg -Destination $targetCfg -Force
        } finally {
            if (Test-Path -LiteralPath $tempCfg) { Remove-Item -LiteralPath $tempCfg -Force -ErrorAction SilentlyContinue }
        }
        foreach ($metadata in (Get-ChildItem -LiteralPath $venvTarget -Recurse -Force -File | Where-Object { $_.Extension -in @('.cfg', '.ini', '.txt', '.cmd', '.bat', '.ps1') })) {
            $content = [IO.File]::ReadAllText($metadata.FullName)
            $content = $content.Replace($Source, $venvTarget).Replace($home, $baseTarget)
            [IO.File]::WriteAllText($metadata.FullName, $content, [Text.UTF8Encoding]::new($false))
            if ($content -match '(?i)[A-Za-z]:\\Users\\') { throw "Staged Python metadata retains a user-profile path: $($metadata.Name)" }
        }
        return [pscustomobject]@{ PythonPath = (Join-Path $venvTarget 'python.exe'); BaseTarget = $baseTarget; VenvTarget = $venvTarget; Base = $baseResult; Venv = $venvResult }
    }
    $baseTarget = Join-Path $RuntimeRoot 'python312'
    $baseResult = Copy-TreeVerifiedAtomic $Source $baseTarget $BackupDirectory
    return [pscustomobject]@{ PythonPath = (Join-Path $baseTarget 'python.exe'); BaseTarget = $baseTarget; VenvTarget = $null; Base = $baseResult; Venv = $null }
}

function Get-PathOnlyGatewayConfig {
    param(
        [Parameter(Mandatory)][string]$GatewayData,
        [Parameter(Mandatory)][string]$Documents,
        [Parameter(Mandatory)][string]$UsageHistory,
        [Parameter(Mandatory)][string]$ClaudeSecret,
        [Parameter(Mandatory)][string]$ApiUrl
    )
    return [ordered]@{
        bindHost = '127.0.0.1'
        port = 8421
        apiBaseUrl = $ApiUrl
        dataDirectory = $GatewayData
        calendarPath = (Join-Path $GatewayData 'calendar.json')
        documentsPath = $Documents
        claudeSecretPath = $ClaudeSecret
        tailscaleServePort = 8420
        funnel = $false
    }
}

function Get-ApiHostConfig {
    param(
        [Parameter(Mandatory)][string]$NodeExecutable,
        [Parameter(Mandatory)][string]$ApiDirectory,
        [Parameter(Mandatory)][string]$UsageHistory,
        [Parameter(Mandatory)][string]$ClaudeSecret,
        [Parameter(Mandatory)][string]$CodexSecret,
        [Parameter(Mandatory)][string]$TempDirectory,
        [Parameter(Mandatory)][string]$LogDirectory
    )
    $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
    return [ordered]@{
        executablePath = $NodeExecutable
        workingDirectory = $ApiDirectory
        arguments = @((Join-Path $ApiDirectory 'dist\server.js'))
        environment = [ordered]@{
            NODE_ENV = 'production'
            PORT = 8787
            USAGE_STORE_PATH = $UsageHistory
            CLAUDE_INGEST_ENABLED = $true
            CLAUDE_STATUSLINE_ENABLED = $true
            CLAUDE_INGEST_SECRET_FILE = $ClaudeSecret
            CODEX_INGEST_ENABLED = $true
            CODEX_INGEST_SECRET_FILE = $CodexSecret
            CODEX_LIVE_ENABLED = $false
            OPEN_FOOD_FACTS_ENABLED = $false
            SYSTEMROOT = $systemRoot
            TEMP = $TempDirectory
            TMP = $TempDirectory
            PATH = ($NodeExecutable | Split-Path -Parent) + ';' + (Join-Path $systemRoot 'System32')
        }
        healthUrl = 'http://127.0.0.1:8787/health'
        startupTimeoutSeconds = 45
        shutdownTimeoutSeconds = 15
        logDirectory = $LogDirectory
        logFileName = 'child.log'
        maxLogBytes = 10485760
        maxLogFiles = 5
    }
}

function Get-GatewayHostConfig {
    param(
        [Parameter(Mandatory)][string]$PythonExecutable,
        [Parameter(Mandatory)][string]$GatewayDirectory,
        [Parameter(Mandatory)][string]$GatewayEntryPoint,
        [Parameter(Mandatory)][string]$GatewayConfig,
        [Parameter(Mandatory)][string]$ClaudeSecret,
        [Parameter(Mandatory)][string]$TempDirectory,
        [Parameter(Mandatory)][string]$LogDirectory
    )
    $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
    $pythonDirectory = Split-Path -Parent $PythonExecutable
    return [ordered]@{
        executablePath = $PythonExecutable
        workingDirectory = $GatewayDirectory
        arguments = @($GatewayEntryPoint)
        environment = [ordered]@{
            SYSTEMROOT = $systemRoot
            TEMP = $TempDirectory
            TMP = $TempDirectory
            PATH = $pythonDirectory + ';' + (Join-Path $pythonDirectory 'Scripts') + ';' + (Join-Path $systemRoot 'System32')
        }
        healthUrl = 'http://127.0.0.1:8421/health'
        startupTimeoutSeconds = 45
        shutdownTimeoutSeconds = 15
        logDirectory = $LogDirectory
        logFileName = 'child.log'
        maxLogBytes = 10485760
        maxLogFiles = 5
    }
}

Assert-WindowsAdministrator
$paths = Get-LifeOSDefaultPaths
$preflightArgs = @('-ServiceHostBinarySource', $ServiceHostBinarySource, '-ApiSource', $ApiSource, '-GatewaySource', $GatewaySource,
    '-NodeRuntimeSource', $NodeRuntimeSource, '-PythonRuntimeSource', $PythonRuntimeSource, '-GatewayEntryPoint', $GatewayEntryPoint,
    '-TailscaleExecutable', $TailscaleExecutable, '-TailscaleServiceName', $TailscaleServiceName, '-LegacyTaskName', $LegacyTaskName)
& (Join-Path $PSScriptRoot 'preflight.ps1') @preflightArgs | Out-Host

$hostSource = Resolve-ServiceHostBinary $ServiceHostBinarySource $paths.ServiceHostPath
$nodeSource = Resolve-NodeRuntimeSource $NodeRuntimeSource $ApiSource
$pythonSource = Resolve-PythonRuntimeSource $PythonRuntimeSource $GatewaySource
$gatewayEntrySource = Resolve-GatewayEntryPoint $GatewayEntryPoint $GatewaySource
$apiRoot = Resolve-ApiReleaseRoot $ApiSource
$tailscale = Resolve-TailscaleExecutable $TailscaleExecutable
$operatorSid = Get-InteractiveOperatorSid
$apiAccount = Get-ServiceAccountName 'LifeOSAPI'
$gatewayAccount = Get-ServiceAccountName 'LifeOSGateway'

$backupDirectory = New-BackupDirectory $paths.BackupRoot 'install'
# Task XML and migration backups may contain existing credentials.  Lock the
# backup directory before exporting/copying any legacy material.
Set-BackupAcl $backupDirectory $operatorSid
$configDirectory = Join-Path $paths.InstallRoot 'host\config'
$hostTarget = Join-Path $paths.InstallRoot 'host\LifeOS.ServiceHost.exe'
$apiTarget = Join-Path $paths.InstallRoot 'api'
$gatewayTarget = Join-Path $paths.InstallRoot 'gateway'
$launcherSource = Join-Path $PSScriptRoot 'gateway_launcher.py'
Assert-ExistingFile $launcherSource 'Gateway launcher'
$nodeTarget = Join-Path $paths.RuntimeRoot 'node'
$apiData = Join-Path $paths.DataRoot 'api'
$gatewayData = Join-Path $paths.DataRoot 'gateway'
$apiTemp = Join-Path $apiData 'tmp'
$gatewayTemp = Join-Path $gatewayData 'tmp'
$apiLogs = Join-Path $paths.LogRoot 'api'
$gatewayLogs = Join-Path $paths.LogRoot 'gateway'
$claudeSecret = Join-Path $paths.SecretRoot 'claude-ingest.secret'
$codexSecret = Join-Path $paths.SecretRoot 'codex-ingest.secret'
$usageHistory = Join-Path $apiData 'usage-history.jsonl'
$gatewayConfig = Join-Path $configDirectory 'gateway.app.json'
$apiConfig = Join-Path $configDirectory 'LifeOSAPI.json'
$gatewayServiceConfig = Join-Path $configDirectory 'LifeOSGateway.json'
$stateChanges = New-Object System.Collections.ArrayList

$legacy = Get-ScheduledTaskSnapshot -TaskName $LegacyTaskName -BackupDirectory $backupDirectory
$codexTask = Get-ScheduledTaskSnapshot -TaskName $CodexTaskName -BackupDirectory $backupDirectory
$operatorName = Get-InteractiveOperatorName
$manifest = [ordered]@{
    schemaVersion = 1
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    operatorSid = $operatorSid
    legacyTask = [ordered]@{ Exists = $legacy.Exists; Enabled = $legacy.Enabled; Backup = $legacy.Backup }
    codexTask = [ordered]@{ Exists = $codexTask.Exists; Enabled = $codexTask.Enabled; Backup = $codexTask.Backup; Operator = $operatorName }
    services = @('LifeOSAPI', 'LifeOSGateway')
    paths = [ordered]@{
        host = $hostTarget; api = $apiTarget; gateway = $gatewayTarget; node = $nodeTarget
        apiData = $apiData; gatewayData = $gatewayData; apiLogs = $apiLogs; gatewayLogs = $gatewayLogs
        secretRoot = $paths.SecretRoot; claudeSecret = $claudeSecret; codexSecret = $codexSecret
        usageHistory = $usageHistory; configDirectory = $configDirectory; apiConfig = $apiConfig; gatewayConfig = $gatewayServiceConfig
        gatewayAppConfig = $gatewayConfig; backupDirectory = $backupDirectory
    }
    backups = New-Object System.Collections.ArrayList
    tailscaleStatusBefore = $null
}
Write-JsonAtomic (Join-Path $backupDirectory 'manifest.json') $manifest

foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) { Stop-LifeOSService $serviceName }

$apiStage = Copy-ApiReleaseBundle $apiRoot $apiTarget $backupDirectory
Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'api-release'; source = $apiRoot; destination = $apiTarget; backup = $apiStage.Backup })
Register-CodexCollectorTask $CodexTaskName $operatorName (Join-Path $nodeTarget 'node.exe') $apiTarget
$gatewayStage = Copy-GatewayCodeBundle $GatewaySource $gatewayEntrySource $gatewayTarget $launcherSource $backupDirectory
Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'gateway-release'; source = $GatewaySource; destination = $gatewayTarget; backup = $gatewayStage.Backup })
$hostStage = Copy-FileVerifiedAtomic $hostSource $hostTarget $backupDirectory
Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'file'; source = $hostSource; destination = $hostTarget; backup = $hostStage.Backup })
$nodeStage = Copy-TreeVerifiedAtomic $nodeSource $nodeTarget $backupDirectory
Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'tree'; source = $nodeSource; destination = $nodeTarget; backup = $nodeStage.Backup })
$pythonStage = Get-ChildRuntimeStage $pythonSource $paths.RuntimeRoot $backupDirectory
Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'tree'; source = $pythonSource; destination = $pythonStage.BaseTarget; backup = $pythonStage.Base.Backup })
if ($null -ne $pythonStage.Venv) { Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'tree'; source = $pythonSource; destination = $pythonStage.VenvTarget; backup = $pythonStage.Venv.Backup }) }
Invoke-NativeChecked $pythonStage.PythonPath @('-c', 'import fastapi,httpx,uvicorn,multipart') -Quiet | Out-Null

# Register the stopped SCM objects before creating any service-readable
# directory, so the service SIDs can be resolved before ACLs are applied.
New-ServiceOrConfigure 'LifeOSAPI' $hostTarget 'auto' $apiAccount @()
New-ServiceOrConfigure 'LifeOSGateway' $hostTarget 'delayed-auto' $gatewayAccount @('LifeOSAPI', $TailscaleServiceName)
$apiSid = Get-ServiceSid 'LifeOSAPI'
$gatewaySid = Get-ServiceSid 'LifeOSGateway'
$manifest.apiServiceSid = $apiSid
$manifest.gatewayServiceSid = $gatewaySid

# Lock parent roots before sensitive children are created.  Every child then
# gets its own service-specific ACL before migration writes any bytes.
Set-DirectoryTraversalAcl $paths.DataRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $paths.LogRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $paths.SecretRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $configDirectory $operatorSid @($apiSid, $gatewaySid)
foreach ($directory in @($apiData, $apiTemp, $apiLogs)) { Ensure-Directory $directory; Set-RestrictedAcl $directory $operatorSid @() @($apiSid) }
foreach ($directory in @($gatewayData, $gatewayTemp, (Join-Path $gatewayData 'documents'), $gatewayLogs)) { Ensure-Directory $directory; Set-RestrictedAcl $directory $operatorSid @() @($gatewaySid) }

$legacyData = Join-Path $GatewaySource 'data'
$legacyCalendar = Join-Path $legacyData 'calendar.json'
if (Test-Path -LiteralPath $legacyCalendar -PathType Leaf) {
    $result = Copy-FileVerifiedAtomic $legacyCalendar (Join-Path $gatewayData 'calendar.json') $backupDirectory
    Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'file'; source = $legacyCalendar; destination = (Join-Path $gatewayData 'calendar.json'); backup = $result.Backup })
}
$legacyDocuments = Join-Path $legacyData 'documents'
if (Test-Path -LiteralPath $legacyDocuments -PathType Container) {
    $result = Copy-TreeVerifiedAtomic $legacyDocuments (Join-Path $gatewayData 'documents') $backupDirectory
    Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'tree'; source = $legacyDocuments; destination = (Join-Path $gatewayData 'documents'); backup = $result.Backup })
}
$legacyUsage = Join-Path $legacyData 'usage-history.jsonl'
if (Test-Path -LiteralPath $legacyUsage -PathType Leaf) {
    $result = Copy-FileVerifiedAtomic $legacyUsage $usageHistory $backupDirectory
    Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'usage-history'; source = $legacyUsage; destination = $usageHistory; backup = $result.Backup; sourceSha256 = $result.SourceHash })
}
$legacyClaude = Join-Path $legacyData 'claude-ingest.secret'
$secretResult = Copy-FileVerifiedAtomic $legacyClaude $claudeSecret $backupDirectory
Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'secret'; source = $legacyClaude; destination = $claudeSecret; backup = $secretResult.Backup; sourceSha256 = $secretResult.SourceHash })
if (Test-Path -LiteralPath $codexSecret -PathType Leaf) {
    Assert-ExistingFile $codexSecret 'Existing Codex secret'
} else {
    $codexValue = New-RandomSecret
    $codexBackup = Write-SecretAtomic $codexSecret $codexValue $backupDirectory
    $codexValue = $null
    Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'generated-secret'; destination = $codexSecret; backup = $codexBackup })
}

$gatewayRelativeEntry = $gatewayEntrySource.Substring((Get-FullPath $GatewaySource).TrimEnd('\').Length).TrimStart('\')
$gatewayEntryTarget = Join-Path $gatewayTarget $gatewayRelativeEntry
Assert-ExistingFile $gatewayEntryTarget 'Staged gateway entry point'
$gatewayApp = Get-PathOnlyGatewayConfig -GatewayData $gatewayData -Documents (Join-Path $gatewayData 'documents') -UsageHistory $usageHistory -ClaudeSecret $claudeSecret -ApiUrl 'http://127.0.0.1:8787'
foreach ($configPath in @($gatewayConfig, $apiConfig, $gatewayServiceConfig)) {
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $configBackup = Backup-File $configPath $backupDirectory ('previous-' + [IO.Path]::GetFileName($configPath))
        Add-ManifestItem $manifest.backups ([ordered]@{ kind = 'config'; source = $configPath; destination = $configPath; backup = $configBackup })
    }
}
Write-JsonAtomic $gatewayConfig $gatewayApp
Assert-PathOnlyJson $gatewayConfig
$apiHost = Get-ApiHostConfig -NodeExecutable (Join-Path $nodeTarget 'node.exe') -ApiDirectory $apiTarget -UsageHistory $usageHistory -ClaudeSecret $claudeSecret -CodexSecret $codexSecret -TempDirectory $apiTemp -LogDirectory $apiLogs
Write-JsonAtomic $apiConfig $apiHost
$launcherTarget = Join-Path $gatewayTarget 'gateway_launcher.py'
$gatewayHost = Get-GatewayHostConfig -PythonExecutable $pythonStage.PythonPath -GatewayDirectory $gatewayTarget -GatewayEntryPoint $gatewayEntryTarget -GatewayConfig $gatewayConfig -ClaudeSecret $claudeSecret -TempDirectory $gatewayTemp -LogDirectory $gatewayLogs
$gatewayHost.arguments = @($launcherTarget, '--config', $gatewayConfig, '--entry-point', $gatewayEntryTarget, '--tailscale', $tailscale)
Write-JsonAtomic $gatewayServiceConfig $gatewayHost
Assert-PathOnlyJson $apiConfig
Assert-PathOnlyJson $gatewayServiceConfig

# The ACL boundary is explicit: each service receives RX only to its own
# staged code/runtime; Modify only to its own data/log/temp directories.  The
# host binary is shared read-only; config files and secrets are per-service.
# No profile, Users, Everyone, or shared-service grant is created.
$hostDirectory = Split-Path -Parent $hostTarget
Set-DirectoryTraversalAcl $paths.InstallRoot $operatorSid @($apiSid, $gatewaySid)
Set-RestrictedAcl $hostDirectory $operatorSid @($apiSid, $gatewaySid) @()
Set-RestrictedAcl $apiTarget $operatorSid @($apiSid) @()
Set-RestrictedAcl $gatewayTarget $operatorSid @($gatewaySid) @()
Set-DirectoryTraversalAcl $paths.RuntimeRoot $operatorSid @($apiSid, $gatewaySid)
Set-RestrictedAcl $nodeTarget $operatorSid @($apiSid) @()
Set-RestrictedAcl (Join-Path $paths.RuntimeRoot 'python312') $operatorSid @($gatewaySid) @()
if ($null -ne $pythonStage.VenvTarget) { Set-RestrictedAcl $pythonStage.VenvTarget $operatorSid @($gatewaySid) @() }
Set-RestrictedAcl $apiConfig $operatorSid @($apiSid) @() -File
Set-RestrictedAcl $gatewayServiceConfig $operatorSid @($gatewaySid) @() -File
Set-RestrictedAcl $gatewayConfig $operatorSid @($gatewaySid) @() -File
Set-DirectoryTraversalAcl $paths.SecretRoot $operatorSid @($apiSid, $gatewaySid)
Set-SecretAcl $claudeSecret $operatorSid @($apiSid, $gatewaySid)
Set-SecretAcl $codexSecret $operatorSid @($apiSid)
Assert-NoBroadAcl $claudeSecret
Assert-NoBroadAcl $codexSecret

$manifest.tailscaleStatusBefore = Get-TailscaleStatusJson $tailscale
Write-JsonAtomic (Join-Path $backupDirectory 'manifest.json') $manifest

Start-LifeOSService 'LifeOSAPI'
if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8787/health') 45)) { throw 'LifeOSAPI did not pass its loopback health check.' }
$legacyStopped = $false
try {
    $legacyCurrent = Get-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
    if ($null -ne $legacyCurrent -and $legacyCurrent.State -eq 'Running') {
        Stop-ScheduledTask -TaskName $LegacyTaskName -ErrorAction Stop
        if (-not (Wait-PortFree 8421 30)) { throw 'The legacy task did not release gateway port 8421.' }
        $legacyStopped = $true
    }
    # Configure is idempotent and does not mutate an already exact mapping.
    $serveStatus = Configure-TailscaleServe $tailscale
    Start-LifeOSService 'LifeOSGateway'
    if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8421/health') 45)) { throw 'LifeOSGateway did not pass its loopback health check.' }
    $serveStatus = Configure-TailscaleServe $tailscale
    if ($null -ne $legacy -and $legacy.Exists) { Disable-LegacyTaskAfterCutover $LegacyTaskName }
    $manifest.tailscaleStatusAfter = $serveStatus
    $manifest.cutoverCompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    Write-JsonAtomic (Join-Path $backupDirectory 'manifest.json') $manifest
    Write-Host 'LifeOS cutover completed; the legacy task was disabled but preserved.'
} catch {
    Stop-LifeOSService 'LifeOSGateway'
    if ($legacyStopped -and $legacy.Exists -and $legacy.Enabled) {
        Start-ScheduledTask -TaskName $LegacyTaskName -ErrorAction SilentlyContinue
    }
    throw
}

Write-Host ("Install manifest: {0}" -f (Join-Path $backupDirectory 'manifest.json'))
Write-Host 'No reboot was requested.'
