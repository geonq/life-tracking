[CmdletBinding()]
param(
    [string]$CandidateRoot,
    [string]$ExpectedSourceSha,
    [string]$ServiceHostBinarySource,
    [string]$ApiSource = 'D:\Hermes\lifeos-api',
    [string]$GatewaySource = 'D:\Hermes\lifeos-server',
    [string]$LegacyGatewaySource = 'D:\Hermes\lifeos-server',
    [string]$NodeRuntimeSource,
    [string]$PythonRuntimeSource,
    [string]$GatewayEntryPoint,
    [string]$TailscaleExecutable,
    # Path only: the operator must pre-create the canonical token file. The
    # raw LIFEOS_TAILSCALE_EDGE_TOKEN value is never an installer parameter.
    [string]$TailscaleEdgeTokenSource,
    [string]$TailscaleServiceName = 'Tailscale',
    [string]$LegacyTaskName = 'LifeOSSyncServer',
    [string]$CodexTaskName = 'LifeOSCodexCollector',
    # Optional provider installation path. It is never inferred or passed as
    # a command argument; the API service receives it through its cleared,
    # allowlisted environment. Live Codex remains disabled by default.
    [string]$CodexExecutablePath,
    [string]$TailscaleSnapshotTaskName = 'LifeOSTailscaleSnapshot',
    # Optional provider inputs are file paths, never raw credentials. Runtime
    # Enable Banking uses the app id, private key, API base URL, and redirect
    # URI. The public certificate is retained only for provider registration.
    [string]$ClipperIngestSecretSource,
    [string]$GoogleAIStudioApiKeySource,
    [string]$GoogleAIStudioFoodModel,
    [string]$GoogleAIStudioFoodModelVersion,
    [switch]$EnableOpenFoodFacts,
    [string]$OpenFoodFactsContactEmail,
    [string]$EnableBankingAppId,
    [string]$EnableBankingPrivateKeySource,
    [string]$EnableBankingCertificateSource,
    [string]$EnableBankingApiBaseUrl,
    [string]$EnableBankingRedirectUri,
    [switch]$DefineOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')
$script:LifeOSInstallScriptRoot = $PSScriptRoot

Assert-SafeTaskName $LegacyTaskName
Assert-SafeTaskName $CodexTaskName
Assert-SafeTaskName $TailscaleSnapshotTaskName

function Add-ManifestItem {
    param([Parameter(Mandatory)][System.Collections.IList]$List, [Parameter(Mandatory)][object]$Value)
    [void]$List.Add($Value)
}

function Save-InstallManifest {
    param([Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][string]$Path)
    [void](Assert-LifeOSGenerationManifestCheckpointCapacity $Manifest)
    Write-JsonAtomic $Path $Manifest -MaxBytes $script:LifeOSGenerationManifestMaxBytes
}

function New-ManifestIntent {
    param(
        [Parameter(Mandatory)][System.Collections.IList]$List,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][string]$Kind,
        [string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$Backup,
        [Parameter(Mandatory)][bool]$PriorExists,
        [Parameter(Mandatory)][bool]$Changed,
        [AllowNull()][System.Collections.IDictionary]$PendingFields = $null,
        [AllowNull()][System.Collections.IDictionary]$CompletionFields = $null
    )
    $item = [ordered]@{
        kind = $Kind
        source = $Source
        destination = $Destination
        backup = $Backup
        priorExists = $PriorExists
        changed = $Changed
        phase = 'pending'
    }
    if ($null -ne $PendingFields) {
        foreach ($name in $PendingFields.Keys) { $item[[string]$name] = $PendingFields[$name] }
    }
    $completedItem = [ordered]@{}
    foreach ($name in $item.Keys) { $completedItem[$name] = $item[$name] }
    $completedItem['phase'] = 'complete'
    if ($null -ne $CompletionFields) {
        foreach ($name in $CompletionFields.Keys) { $completedItem[[string]$name] = $CompletionFields[$name] }
    }
    # Complete-ManifestIntent may add these fields after a verified copy. Size
    # the preflight against their largest valid representation before a target
    # is changed, while the writer still enforces the actual 16 MiB bound.
    if (-not $completedItem.Contains('sourceSha256')) { $completedItem['sourceSha256'] = 'f' * 64 }
    if (-not $completedItem.Contains('sourceLength')) { $completedItem['sourceLength'] = [long]::MaxValue }
    $pendingCandidate = New-LifeOSGenerationManifestCandidate -Manifest $Manifest -BackupItem $item
    $completedCandidate = New-LifeOSGenerationManifestCandidate -Manifest $Manifest -BackupItem $completedItem
    [void](Assert-LifeOSGenerationManifestCheckpointCapacity -Manifest $Manifest -FutureCheckpoints @($pendingCandidate, $completedCandidate))
    Add-ManifestItem $List $item
    Save-InstallManifest $Manifest $ManifestPath
    return $item
}

function Complete-ManifestIntent {
    param(
        [Parameter(Mandatory)][object]$Item,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath,
        [Parameter(Mandatory)][object]$Result
    )
    $Item['backup'] = $Result.Backup
    $Item['changed'] = [bool]$Result.Changed
    if ($null -ne $Result.PSObject.Properties['SourceHash']) { $Item['sourceSha256'] = $Result.SourceHash }
    if ($null -ne $Result.PSObject.Properties['SourceLength']) { $Item['sourceLength'] = [long]$Result.SourceLength }
    $Item['phase'] = 'complete'
    Save-InstallManifest $Manifest $ManifestPath
}

function Assert-AuthorityJsonBounds {
    param($Value, [int]$Depth = 0, [ref]$Nodes)
    $Nodes.Value++
    if ($Depth -gt 64 -or $Nodes.Value -gt 100000) { throw 'Authority JSON structural bound exceeded.' }
    if ($Value -is [double] -and ([double]::IsNaN($Value) -or [double]::IsInfinity($Value))) { throw 'Authority JSON contains non-finite numbers.' }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in $Value.PSObject.Properties) { Assert-AuthorityJsonBounds $property.Value ($Depth + 1) $Nodes }
    } elseif ($Value -is [array]) {
        foreach ($element in $Value) { Assert-AuthorityJsonBounds $element ($Depth + 1) $Nodes }
    }
}

function Start-AttributedCodexCollector {
    param(
        [string]$TaskName,
        [uri]$UsageUri,
        [switch]$AllowProviderUnavailable,
        [int]$TimeoutSeconds = 45
    )
    $before = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    $initial = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    if ([string]$initial.State -ne 'Ready') { throw 'Collector is not idle before attribution.' }
    $startedAt = Get-Date
    Start-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
    $deadline = $startedAt.AddSeconds($TimeoutSeconds)
    $sawRunning = $false
    $observedRun = $null
    do {
        $task = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        $info = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
        if ($sawRunning -and $info.LastRunTime -ne $observedRun) { throw 'Collector run changed during attribution.' }
        if ([string]$task.State -eq 'Running' -and $info.LastRunTime -gt $before.LastRunTime) { $sawRunning = $true; $observedRun = $info.LastRunTime }
        # A cached result, queued task, 0x41301, or missed fast run is not proof.
        if ($sawRunning -and [string]$task.State -eq 'Ready' -and
            $info.LastRunTime -gt $before.LastRunTime -and $info.LastRunTime -ge $startedAt.AddSeconds(-1)) {
            $confirm = Get-ScheduledTaskInfo -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
            $terminal = Get-ScheduledTask -TaskName $TaskName -TaskPath '\' -ErrorAction Stop
            if ([string]$terminal.State -ne 'Ready' -or $confirm.LastRunTime -ne $info.LastRunTime -or
                $confirm.LastTaskResult -ne $info.LastTaskResult) { throw 'Collector terminal attribution changed.' }
            $exitCode = [long]$confirm.LastTaskResult
            if ($exitCode -eq 2) {
                if (-not $AllowProviderUnavailable) { throw 'Collector provider unavailable without explicit allowance.' }
                return [pscustomobject]@{ status='provider_unavailable'; exitCode=2; observation='unverified'; terminalCompleted=$true; lastRunTime=$info.LastRunTime.ToUniversalTime().ToString('o') }
            }
            if ($exitCode -ne 0) { throw "Collector terminal failure: $exitCode" }
            if (-not (Wait-CodexUsageObservation $UsageUri $TimeoutSeconds $startedAt)) { throw 'Collector ingestion remains unverified.' }
            return [pscustomobject]@{ status='observed'; exitCode=0; observation='observed'; terminalCompleted=$true; lastRunTime=$info.LastRunTime.ToUniversalTime().ToString('o') }
        }
        Start-Sleep -Milliseconds 100
    } while ((Get-Date) -lt $deadline)
    throw 'Collector terminal completed observation missing; cutover refused.'
}

function Copy-ApiReleaseBundle {
    param([Parameter(Mandatory)][string]$ApiRoot, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$BackupDirectory, [string]$BackupName = 'previous-api-release')
    $contracts = Resolve-ApiDependencyRoot $ApiRoot '@iphone-life-os\contracts'
    $zod = Resolve-ApiDependencyRoot $ApiRoot 'zod'
    $parent = Split-Path -Parent $Destination
    Ensure-Directory $parent
    $temp = Join-Path $parent ('.api-release-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $backup = $null
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
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            $backup = Join-Path $BackupDirectory $BackupName
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        return [pscustomobject]@{ Destination = $Destination; Backup = $backup; Changed = $true }
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
}

function Copy-GatewayCodeBundle {
    param([Parameter(Mandatory)][string]$GatewaySource, [Parameter(Mandatory)][string]$GatewayEntryPoint, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$LauncherSource, [Parameter(Mandatory)][string]$BackupDirectory, [string]$BackupName = 'previous-gateway-release')
    $parent = Split-Path -Parent $Destination
    Ensure-Directory $parent
    $temp = Join-Path $parent ('.gateway-release-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $backup = $null
    try {
        $entryRelative = $GatewayEntryPoint.Substring((Get-FullPath $GatewaySource).TrimEnd('\').Length).TrimStart('\')
        if ($entryRelative -ne 'main.py') { throw 'Gateway release must contain only the reviewed root main.py entry point.' }
        Assert-ExistingFile $GatewayEntryPoint 'Gateway main.py'
        Assert-ExistingFile $LauncherSource 'Gateway launcher source'
        Copy-Item -LiteralPath $GatewayEntryPoint -Destination (Join-Path $temp 'main.py') -Force
        Copy-Item -LiteralPath $LauncherSource -Destination (Join-Path $temp 'gateway_launcher.py') -Force
        # main.py imports these modules directly. Keep the staged bundle
        # explicit and fail closed rather than producing a gateway that only
        # fails later during its health check.
        foreach ($gatewayFile in @('enablebanking.py', 'supplement_catalog.py', 'supplement_catalog_schema.sql', 'supplement_catalog_seed.sql')) {
            $gatewaySourceFile = Join-Path $GatewaySource $gatewayFile
            Assert-ExistingFile $gatewaySourceFile "Gateway bundle file $gatewayFile"
            Copy-Item -LiteralPath $gatewaySourceFile -Destination (Join-Path $temp $gatewayFile) -Force
            if ((Get-FileSha256 $gatewaySourceFile) -ne (Get-FileSha256 (Join-Path $temp $gatewayFile))) {
                throw "Gateway bundle hash verification failed for $gatewayFile."
            }
        }
        $bundleFiles = @(Get-ChildItem -LiteralPath $temp -File | Where-Object { $_.Name -ne 'gateway-release.manifest.json' } | ForEach-Object {
            [ordered]@{ path = $_.Name; sha256 = Get-FileSha256 $_.FullName; length = $_.Length }
        })
        # v18 is the reviewed gateway bundle contract. Its file list is
        # unchanged from v17; the version marks the launcher no longer
        # shelling out to Tailscale and reading the SYSTEM-written snapshot
        # instead. The snapshot writer itself is not part of this bundle: it
        # is staged separately from $PSScriptRoot into host\. Keep the file
        # list and per-file hashes inside the staged bundle so the transferred
        # release is reproducible and cannot silently omit a reviewed module.
        $releaseManifestPath = Join-Path $temp 'gateway-release.manifest.json'
        Write-JsonAtomic -Path $releaseManifestPath -Value ([ordered]@{
            bundleVersion = 'v18'
            mainSha256 = Get-FileSha256 (Join-Path $temp 'main.py')
            launcherSha256 = Get-FileSha256 (Join-Path $temp 'gateway_launcher.py')
            bundleFiles = $bundleFiles
        }) -MaxBytes $script:LifeOSGenerationManifestMaxBytes
        $writtenManifest = Read-LifeOSBoundedJsonFile -Path $releaseManifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Gateway release manifest'
        if ([string]$writtenManifest.bundleVersion -ne 'v18') { throw 'Gateway release manifest version is not v18.' }
        foreach ($bundleFile in @($writtenManifest.bundleFiles)) {
            $bundlePath = Join-Path $temp ([string]$bundleFile.path)
            Assert-ExistingFile $bundlePath 'Gateway bundle manifest file'
            if ([long](Get-Item -LiteralPath $bundlePath -Force).Length -ne [long]$bundleFile.length -or
                (Get-FileSha256 $bundlePath) -ne [string]$bundleFile.sha256) {
                throw "Gateway bundle manifest hash verification failed for $($bundleFile.path)."
            }
        }
        if (Test-Path -LiteralPath $Destination -PathType Container) {
            $backup = Join-Path $BackupDirectory $BackupName
            Ensure-Directory $BackupDirectory
            Move-Item -LiteralPath $Destination -Destination $backup
        }
        Move-Item -LiteralPath $temp -Destination $Destination
        return [pscustomobject]@{ Destination = $Destination; Backup = $backup; EntryRelative = $entryRelative; Changed = $true }
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
}

function Initialize-SupplementCatalog {
    param(
        [Parameter(Mandatory)][string]$PythonExecutable,
        [Parameter(Mandatory)][string]$GatewayDirectory,
        [Parameter(Mandatory)][string]$CatalogPath,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][System.Collections.IList]$ManifestBackups,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath
    )
    $schema = Join-Path $GatewayDirectory 'supplement_catalog_schema.sql'
    $seed = Join-Path $GatewayDirectory 'supplement_catalog_seed.sql'
    Assert-ExistingFile $schema 'Supplement catalog schema'
    Assert-ExistingFile $seed 'Supplement catalog seed'
    $catalogParent = Split-Path -Parent (Get-FullPath $CatalogPath)
    Ensure-Directory $catalogParent
    Assert-NoReparsePath $CatalogPath -AllowMissingLeaf
    $temporaryCatalog = Join-Path $catalogParent ('.supplements-' + [Guid]::NewGuid().ToString('N') + '.sqlite3')

    # sqlite3 is part of the Python standard library. Paths are argv values,
    # not interpolated shell text; the SQL stays out of process arguments.
    # Build and validate a temporary database first, then replace the live
    # file only after integrity and foreign-key checks pass.  An existing
    # catalog is copied into the staging database before schema/seed updates,
    # so local reference rows survive an installer upgrade.
    # Windows PowerShell 5.1 drops empty strings at the native argv boundary.
    # Use a bounded sentinel when there is no existing catalog, then decode it
    # inside Python so the four-argument contract remains stable.
    $catalogPriorExists = Test-Path -LiteralPath $CatalogPath -PathType Leaf
    $existingCatalog = if ($catalogPriorExists) { $CatalogPath } else { '-' }
    if ($catalogPriorExists) { Assert-NoReparsePath $existingCatalog }
    $pythonCode = 'import sqlite3,sys; database,existing_path,schema_path,seed_path=sys.argv[1:]; con=sqlite3.connect(database); con.execute("PRAGMA foreign_keys=ON"); source=None if existing_path in ("","-") else sqlite3.connect(existing_path); source.backup(con) if source is not None else None; source.close() if source is not None else None; con.executescript(open(schema_path,encoding="utf-8").read()); con.executescript(open(seed_path,encoding="utf-8").read()); assert con.execute("PRAGMA integrity_check").fetchone()[0] == "ok"; assert not con.execute("PRAGMA foreign_key_check").fetchone(); con.commit(); con.close()'
    $previousCatalogCheck = $env:LIFEOS_DEPLOY_SUPPLEMENT_CATALOG_CHECK
    try {
        # Keep the Python source out of the native argv boundary.  Windows
        # PowerShell 5.1 strips nested quote characters from `-c` arguments;
        # argv still carries only the four explicit filesystem paths.
        $env:LIFEOS_DEPLOY_SUPPLEMENT_CATALOG_CHECK = $pythonCode
        $pythonRunner = 'import os;exec(os.environ.get(chr(76)+chr(73)+chr(70)+chr(69)+chr(79)+chr(83)+chr(95)+chr(68)+chr(69)+chr(80)+chr(76)+chr(79)+chr(89)+chr(95)+chr(83)+chr(85)+chr(80)+chr(80)+chr(76)+chr(69)+chr(77)+chr(69)+chr(78)+chr(84)+chr(95)+chr(67)+chr(65)+chr(84)+chr(65)+chr(76)+chr(79)+chr(71)+chr(95)+chr(67)+chr(72)+chr(69)+chr(67)+chr(75)))'
        Invoke-NativeChecked -FilePath $PythonExecutable -ArgumentList ([string[]]@('-B', '-I', '-c', $pythonRunner, $temporaryCatalog, $existingCatalog, $schema, $seed)) -Quiet | Out-Null
        Assert-ExistingFile $temporaryCatalog 'Staged supplement catalog database'
        Assert-NoReparsePath $temporaryCatalog
        $backup = $null
        if ($catalogPriorExists) {
            $backup = Backup-File $CatalogPath $BackupDirectory 'previous-supplements.sqlite3'
            Assert-NoReparsePath $CatalogPath
        }
        # Journal the replacement before moving the staged file so a failure
        # during the move still leaves enough information for rollback.
        $catalogIntent = New-ManifestIntent -List $ManifestBackups -Manifest $Manifest -ManifestPath $ManifestPath -Kind 'supplement-catalog' -Source $CatalogPath -Destination $CatalogPath -Backup $backup -PriorExists $catalogPriorExists -Changed $true
        Move-Item -LiteralPath $temporaryCatalog -Destination $CatalogPath -Force
        Assert-ExistingFile $CatalogPath 'Supplement catalog database'
        $catalogIntent['phase'] = 'complete'
        Save-InstallManifest $Manifest $ManifestPath
        return $true
    } finally {
        if ($null -eq $previousCatalogCheck) { Remove-Item Env:LIFEOS_DEPLOY_SUPPLEMENT_CATALOG_CHECK -ErrorAction SilentlyContinue }
        else { $env:LIFEOS_DEPLOY_SUPPLEMENT_CATALOG_CHECK = $previousCatalogCheck }
        if (Test-Path -LiteralPath $temporaryCatalog) {
            Remove-Item -LiteralPath $temporaryCatalog -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-ChildRuntimeStage {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$RuntimeRoot, [Parameter(Mandatory)][string]$BackupDirectory, [Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][string]$ManifestPath)
    $sourceRuntime = Resolve-PythonRuntimeSource -Requested $Source -GatewaySource $Source
    $sourceRoot = $sourceRuntime.Root
    $pyvenv = Join-Path $sourceRoot 'pyvenv.cfg'
    if ($sourceRuntime.IsVirtualEnvironment) {
        Assert-ExistingFile $pyvenv 'Python venv metadata'
        $cfg = Read-LifeOSCappedFileText -Path $pyvenv -MaxBytes $script:LifeOSRecoveryMaxFileBytes -Description 'Python venv metadata'
        $homeMatch = [regex]::Match($cfg, '(?m)^\s*home\s*=\s*(?<home>[^\r\n]+)\s*$')
        if (-not $homeMatch.Success) { throw "Python venv has no absolute home entry: $pyvenv" }
        # `$HOME` is a read-only automatic variable in Windows PowerShell;
        # use a task-specific name for the venv's base-runtime path.
        $pythonHomePath = $homeMatch.Groups['home'].Value.Trim()
        $homeRuntime = Resolve-PythonRuntimeSource -Requested $pythonHomePath -GatewaySource $pythonHomePath
        $homeRoot = $homeRuntime.Root
        $baseTarget = Join-Path $RuntimeRoot 'python312'
        $venvTarget = Join-Path $RuntimeRoot 'python-venv'
        $basePriorExists = Test-Path -LiteralPath $baseTarget -PathType Container
        # The staged base intentionally omits the operator's global packages
        # and other non-runtime content, so a normal full-tree comparison is
        # both too large and semantically wrong here. The specialized copier
        # below builds and verifies the bounded runtime view.
        $baseChanged = $true
        $baseIntent = New-ManifestIntent $Manifest.backups $Manifest $ManifestPath 'python-base' $homeRoot $baseTarget (Join-Path $BackupDirectory 'previous-python312') $basePriorExists $baseChanged
        $baseResult = $null
        $venvResult = $null
        $venvIntent = $null
        try {
            $baseResult = Copy-PythonBaseRuntimeAtomic $homeRoot $baseTarget $BackupDirectory 'previous-python312'
            Complete-ManifestIntent $baseIntent $Manifest $ManifestPath $baseResult
            $venvPriorExists = Test-Path -LiteralPath $venvTarget -PathType Container
            $venvChanged = -not (Compare-TreeManifest $sourceRoot $venvTarget)
            $venvIntent = New-ManifestIntent $Manifest.backups $Manifest $ManifestPath 'python-venv' $sourceRoot $venvTarget (Join-Path $BackupDirectory 'previous-python-venv') $venvPriorExists $venvChanged
            $venvResult = Copy-TreeVerifiedAtomic $sourceRoot $venvTarget $BackupDirectory 'previous-python-venv'
            $targetCfg = Join-Path $venvTarget 'pyvenv.cfg'
            Assert-ExistingFile $targetCfg 'Staged pyvenv.cfg'
            $updated = Read-LifeOSCappedFileText -Path $targetCfg -MaxBytes $script:LifeOSRecoveryMaxFileBytes -Description 'Staged pyvenv.cfg'
            $updated = [regex]::Replace($updated, '(?m)^\s*home\s*=\s*[^\r\n]+\s*$', ('home = ' + $baseTarget))
            $baseTargetInterpreter = if ($homeRuntime.Layout -eq 'root') {
                Join-Path $baseTarget 'python.exe'
            } else {
                Join-Path $baseTarget 'Scripts\python.exe'
            }
            $updated = [regex]::Replace($updated, '(?m)^\s*executable\s*=\s*[^\r\n]+\s*$', ('executable = ' + $baseTargetInterpreter))
            $updated = [regex]::Replace($updated, '(?m)^\s*command\s*=\s*[^\r\n]+\s*$', ('command = ' + $baseTargetInterpreter + ' -m venv ' + $venvTarget))
            $updated = $updated.Replace($sourceRoot, $venvTarget).Replace($homeRoot, $baseTarget)
            $tempCfg = Join-Path $venvTarget ('.pyvenv.cfg.' + [Guid]::NewGuid().ToString('N') + '.tmp')
            try {
                [IO.File]::WriteAllText($tempCfg, $updated, [Text.UTF8Encoding]::new($false))
                Move-Item -LiteralPath $tempCfg -Destination $targetCfg -Force
            } finally {
                if (Test-Path -LiteralPath $tempCfg) { Remove-Item -LiteralPath $tempCfg -Force -ErrorAction SilentlyContinue }
            }
            # Activation helpers are operator-shell conveniences, not part of
            # the service runtime. Standard venv activation scripts retain
            # the creator's user-profile path and would otherwise make a
            # deployed runtime depend on that profile.
            $activationScriptNames = @('Activate.ps1', 'activate.bat', 'activate')
            foreach ($activationScriptName in $activationScriptNames) {
                $activationScript = Join-Path $venvTarget ('Scripts\' + $activationScriptName)
                if (Test-Path -LiteralPath $activationScript -PathType Leaf) {
                    Assert-NoReparsePath $activationScript
                    Remove-Item -LiteralPath $activationScript -Force
                }
            }
            # Walk the staged venv incrementally through the shared bounded,
            # reparse-rejecting inventory. A recursive Get-ChildItem array and
            # ReadAllText would let one large tree or metadata file escape the
            # deployment resource contract.
            Get-LifeOSBoundedTreeItem -Root $venvTarget |
                Where-Object { -not $_.PSIsContainer -and $_.Extension -in @('.cfg', '.ini', '.txt', '.cmd', '.bat', '.ps1') } |
                ForEach-Object {
                $metadata = $_
                $content = Read-LifeOSCappedFileText -Path $metadata.FullName -MaxBytes $script:LifeOSRecoveryMaxFileBytes -Description "Staged Python metadata $($metadata.Name)"
                $content = $content.Replace($sourceRoot, $venvTarget).Replace($homeRoot, $baseTarget)
                [IO.File]::WriteAllText($metadata.FullName, $content, [Text.UTF8Encoding]::new($false))
                if ($content -match '(?i)[A-Za-z]:\\Users\\') { throw "Staged Python metadata retains a user-profile path: $($metadata.Name)" }
            }
            Complete-ManifestIntent $venvIntent $Manifest $ManifestPath $venvResult
        } catch {
            throw
        }
        $stagedVenvRuntime = Resolve-PythonRuntimeSource -Requested $venvTarget -GatewaySource $venvTarget
        return [pscustomobject]@{ PythonPath = $stagedVenvRuntime.Executable; PythonRoot = $stagedVenvRuntime.Root; PythonLayout = $stagedVenvRuntime.Layout; BaseTarget = $baseTarget; VenvTarget = $venvTarget; Base = $baseResult; Venv = $venvResult }
    }
    $baseTarget = Join-Path $RuntimeRoot 'python312'
    $basePriorExists = Test-Path -LiteralPath $baseTarget -PathType Container
    $baseChanged = $true
    $baseIntent = New-ManifestIntent $Manifest.backups $Manifest $ManifestPath 'python-base' $sourceRoot $baseTarget (Join-Path $BackupDirectory 'previous-python312') $basePriorExists $baseChanged
    $baseResult = Copy-PythonBaseRuntimeAtomic $sourceRoot $baseTarget $BackupDirectory 'previous-python312'
    Complete-ManifestIntent $baseIntent $Manifest $ManifestPath $baseResult
    $stagedBaseRuntime = Resolve-PythonRuntimeSource -Requested $baseTarget -GatewaySource $baseTarget
    return [pscustomobject]@{ PythonPath = $stagedBaseRuntime.Executable; PythonRoot = $stagedBaseRuntime.Root; PythonLayout = $stagedBaseRuntime.Layout; BaseTarget = $baseTarget; VenvTarget = $null; Base = $baseResult; Venv = $null }
}

function Copy-PythonBaseRuntimeAtomic {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [string]$BackupName = 'previous-python312'
    )
    # A Windows Python installation may contain an unrelated global
    # site-packages tree, documentation, and test modules. The service uses
    # the virtual environment's site-packages; copying the global packages
    # would exceed the 512 MiB bounded-tree contract and would make the
    # deployed runtime depend on arbitrary packages from the operator profile.
    # Copy the base interpreter and standard library in bounded subtrees while
    # preserving the same per-file identity/hash checks as every other stage.
    Assert-ExistingDirectory $Source 'Python base runtime source'
    $sourceRoot = Get-FullPath $Source
    $sourceItem = Get-Item -LiteralPath $sourceRoot -Force -ErrorAction Stop
    $sourceIdentity = New-LifeOSTreeItemIdentity -Item $sourceItem -Description 'Python base runtime source'
    $destinationFull = Get-FullPath $Destination
    $destinationParent = Split-Path -Parent $destinationFull
    Ensure-Directory $destinationParent
    $temp = Join-Path $destinationParent ('.' + [IO.Path]::GetFileName($destinationFull) + '.' + [Guid]::NewGuid().ToString('N') + '.staging')
    $backup = $null
    $excludedRootDirectories = @('Doc')
    $excludedLibDirectories = @('site-packages', 'test', 'idlelib', 'turtledemo')
    try {
        Ensure-Directory $temp
        foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force -ErrorAction Stop)) {
            $name = [string]$item.Name
            $target = Join-Path $temp $name
            Assert-NoReparsePath $item.FullName
            if ($item.PSIsContainer -and $excludedRootDirectories -contains $name) { continue }
            if ($name -ieq 'Lib' -and $item.PSIsContainer) {
                Ensure-Directory $target
                foreach ($libItem in @(Get-ChildItem -LiteralPath $item.FullName -Force -ErrorAction Stop)) {
                    Assert-NoReparsePath $libItem.FullName
                    if ($libItem.PSIsContainer -and $excludedLibDirectories -contains ([string]$libItem.Name)) { continue }
                    $libTarget = Join-Path $target ([string]$libItem.Name)
                    if ($libItem.PSIsContainer) {
                        [void](Copy-TreeVerifiedAtomic -Source $libItem.FullName -Destination $libTarget -BackupDirectory $BackupDirectory -BackupName ('python-base-' + $libItem.Name))
                    } else {
                        [void](Copy-FileVerifiedAtomic -Source $libItem.FullName -Destination $libTarget -BackupDirectory $BackupDirectory -BackupName ('python-base-' + $libItem.Name))
                    }
                }
            } elseif ($item.PSIsContainer) {
                [void](Copy-TreeVerifiedAtomic -Source $item.FullName -Destination $target -BackupDirectory $BackupDirectory -BackupName ('python-base-' + $name))
            } else {
                [void](Copy-FileVerifiedAtomic -Source $item.FullName -Destination $target -BackupDirectory $BackupDirectory -BackupName ('python-base-' + $name))
            }
        }
        Assert-LifeOSTreeItemIdentity -Path $sourceRoot -Expected $sourceIdentity -Description 'Python base runtime source' | Out-Null
        $stagedManifest = @(Get-TreeManifest $temp)
        if ($stagedManifest.Count -le 0) { throw 'Python base runtime staging produced no files.' }
        if (Test-Path -LiteralPath $destinationFull -PathType Container) {
            Assert-NoReparsePath $destinationFull
            Ensure-Directory $BackupDirectory
            $backup = Join-Path $BackupDirectory $BackupName
            Move-Item -LiteralPath $destinationFull -Destination $backup -Force
        }
        Move-Item -LiteralPath $temp -Destination $destinationFull -Force
        $installedManifest = @(Get-TreeManifest $destinationFull)
        if (($stagedManifest | ConvertTo-Json -Depth 8 -Compress) -join '' -cne (($installedManifest | ConvertTo-Json -Depth 8 -Compress) -join '')) {
            throw "Staged Python base runtime verification failed for $destinationFull."
        }
    } catch {
        if ($null -ne $backup -and (Test-Path -LiteralPath $backup)) {
            if (Test-Path -LiteralPath $destinationFull) { Move-CurrentOutOfTheWay $destinationFull $BackupDirectory }
            Move-Item -LiteralPath $backup -Destination $destinationFull -Force
        } elseif (Test-Path -LiteralPath $destinationFull) {
            Move-CurrentOutOfTheWay $destinationFull $BackupDirectory
        }
        throw
    } finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return [pscustomobject]@{ Destination = $destinationFull; Backup = $backup; Manifest = $stagedManifest; Changed = $true }
}

function Get-PathOnlyGatewayConfig {
    param(
        [Parameter(Mandatory)][string]$GatewayData,
        [Parameter(Mandatory)][string]$Documents,
        [Parameter(Mandatory)][string]$UsageHistory,
        [Parameter(Mandatory)][string]$ClaudeSecret,
        [Parameter(Mandatory)][string]$TailscaleEdgeTokenPath,
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
        tailscaleEdgeTokenPath = $TailscaleEdgeTokenPath
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
        [string]$CodexExecutablePath,
        [Parameter(Mandatory)][string]$TempDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$ClipperStorePath,
        [string]$ClipperSecret,
        [string]$GoogleAIStudioApiKey,
        [string]$GoogleAIStudioFoodModel,
        [string]$GoogleAIStudioFoodModelVersion,
        [switch]$OpenFoodFactsEnabled,
        [string]$OpenFoodFactsContactEmail,
        [Parameter(Mandatory)][string]$ManagementSid
    )
    $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
    $environment = [ordered]@{
        LIFEOS_LOCAL_API_ENABLED = 'true'
        LIFEOS_LOCAL_API_SECRET_FILE = (Join-Path $script:LifeOSDefaultPaths.SecretRoot 'local-api.secret')
        NODE_ENV = 'production'
        PORT = 8787
        USAGE_STORE_PATH = $UsageHistory
        CLIPPER_STORE_PATH = $ClipperStorePath
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
    if (-not [string]::IsNullOrWhiteSpace($CodexExecutablePath)) {
        $environment.CODEX_EXECUTABLE_PATH = $CodexExecutablePath
    }
    if (-not [string]::IsNullOrWhiteSpace($ClipperSecret)) {
        $environment.CLIPPER_INGEST_ENABLED = $true
        $environment.CLIPPER_INGEST_SECRET_FILE = $ClipperSecret
    } else {
        $environment.CLIPPER_INGEST_ENABLED = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($GoogleAIStudioApiKey)) {
        $environment.GOOGLE_AI_STUDIO_ENABLED = $true
        $environment.GOOGLE_AI_STUDIO_API_KEY_FILE = $GoogleAIStudioApiKey
        if (-not [string]::IsNullOrWhiteSpace($GoogleAIStudioFoodModel)) {
            $environment.GOOGLE_AI_STUDIO_FOOD_MODEL = $GoogleAIStudioFoodModel
        }
        if (-not [string]::IsNullOrWhiteSpace($GoogleAIStudioFoodModelVersion)) {
            $environment.GOOGLE_AI_STUDIO_FOOD_MODEL_VERSION = $GoogleAIStudioFoodModelVersion
        }
    } else {
        $environment.GOOGLE_AI_STUDIO_ENABLED = $false
    }
    if ($OpenFoodFactsEnabled) {
        $environment.OPEN_FOOD_FACTS_ENABLED = $true
        $environment.OPEN_FOOD_FACTS_CONTACT_EMAIL = $OpenFoodFactsContactEmail
    }
    return [ordered]@{
        executablePath = $NodeExecutable
        workingDirectory = $ApiDirectory
        arguments = @((Join-Path $ApiDirectory 'dist\server.js'))
        environment = $environment
        healthUrl = 'http://127.0.0.1:8787/health'
        readinessUrl = 'http://127.0.0.1:8787/ready'
        startupTimeoutSeconds = 45
        shutdownTimeoutSeconds = 15
        logDirectory = $LogDirectory
        logFileName = 'child.log'
        maxLogBytes = 10485760
        maxLogFiles = 5
        managementSid = $ManagementSid
    }
}

function Get-GatewayHostConfig {
    param(
        [Parameter(Mandatory)][string]$PythonExecutable,
        [Parameter(Mandatory)][string]$GatewayDirectory,
        [Parameter(Mandatory)][string]$GatewayEntryPoint,
        [Parameter(Mandatory)][string]$GatewayConfig,
        [Parameter(Mandatory)][string]$ClaudeSecret,
        [Parameter(Mandatory)][string]$SupplementCatalogPath,
        [Parameter(Mandatory)][string]$TempDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [string]$EnableBankingAppId,
        [string]$EnableBankingPrivateKeyPath,
        [string]$EnableBankingCertificatePath,
        [string]$EnableBankingApiBaseUrl,
        [string]$EnableBankingRedirectUri,
        [string]$TailscaleServiceName = 'Tailscale',
        [Parameter(Mandatory)][string]$TailscaleSnapshotPath,
        [Parameter(Mandatory)][string]$ManagementSid
    )
    $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
    $pythonDirectory = Split-Path -Parent $PythonExecutable
    $pythonRoot = if ([IO.Path]::GetFileName($pythonDirectory) -ieq 'Scripts') {
        Split-Path -Parent $pythonDirectory
    } else {
        $pythonDirectory
    }
    $environment = [ordered]@{
        LIFEOS_LOCAL_API_ENABLED = 'true'
        LIFEOS_LOCAL_API_SECRET_FILE = (Join-Path $script:LifeOSDefaultPaths.SecretRoot 'local-api.secret')
        SYSTEMROOT = $systemRoot
        TEMP = $TempDirectory
        TMP = $TempDirectory
        PATH = $pythonRoot + ';' + (Join-Path $pythonRoot 'Scripts') + ';' + (Join-Path $systemRoot 'System32')
        LIFEOS_SUPPLEMENT_CATALOG_PATH = $SupplementCatalogPath
        LIFEOS_TAILSCALE_SERVICE_NAME = $TailscaleServiceName
        LIFEOS_TAILSCALE_SNAPSHOT_PATH = $TailscaleSnapshotPath
    }
    # The public certificate is a registration artifact for Enable Banking;
    # the runtime adapter authenticates with a JWT signed by the private key.
    $bankingValues = @($EnableBankingAppId, $EnableBankingPrivateKeyPath, $EnableBankingApiBaseUrl, $EnableBankingRedirectUri)
    $bankingMissingCount = @($bankingValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
    $bankingProvidedCount = $bankingValues.Count - $bankingMissingCount
    if ($bankingMissingCount -gt 0 -and $bankingProvidedCount -gt 0) {
        throw 'Enable Banking configuration must provide app id, private key, API base URL, and redirect URI together.'
    }
    if ($bankingMissingCount -eq 0) {
        $environment.ENABLE_BANKING_APP_ID = $EnableBankingAppId
        $environment.ENABLE_BANKING_PRIVATE_KEY_PATH = $EnableBankingPrivateKeyPath
        $environment.ENABLE_BANKING_API_BASE_URL = $EnableBankingApiBaseUrl
        $environment.ENABLE_BANKING_REDIRECT_URI = $EnableBankingRedirectUri
    }
    return [ordered]@{
        executablePath = $PythonExecutable
        workingDirectory = $GatewayDirectory
        arguments = @($GatewayEntryPoint)
        environment = $environment
        healthUrl = 'http://127.0.0.1:8421/health'
        readinessUrl = 'http://127.0.0.1:8421/ready'
        startupTimeoutSeconds = 45
        shutdownTimeoutSeconds = 15
        logDirectory = $LogDirectory
        logFileName = 'child.log'
        maxLogBytes = 10485760
        maxLogFiles = 5
        managementSid = $ManagementSid
    }
}

function Invoke-LifeOSInstall {
Assert-WindowsAdministrator
# Verify the immutable candidate identity before acquiring the deployment
# transaction or creating any marker/backup state. The expected SHA is an
# independently supplied release value; it is never derived from the
# candidate's SOURCE_SHA.txt.
if ([string]::IsNullOrWhiteSpace($CandidateRoot) -or [string]::IsNullOrWhiteSpace($ExpectedSourceSha)) {
    throw 'CandidateRoot and ExpectedSourceSha are required for an install; use -DefineOnly only for source inspection.'
}
$candidateRootFull = Assert-LifeOSCandidateRoot -Root $CandidateRoot -ExpectedSourceSha $ExpectedSourceSha -DeploymentScriptRoot $PSScriptRoot -VerifyCandidate
$deploymentMutex = $null
$deploymentCompleted = $false
$deploymentRollbackSucceeded = $false
$deploymentRecoveryCompleted = $false
try {
$paths = Get-LifeOSDefaultPaths
$operatorSid = Get-InteractiveOperatorSid
$codexPathProvided = -not [string]::IsNullOrWhiteSpace($CodexExecutablePath)
if ($codexPathProvided) {
    # Keep this optional input path-only and fail closed before any deployment
    # mutation. The service-host validator repeats the checks on the rendered
    # configuration, so a later config edit cannot bypass this boundary.
    if ($CodexExecutablePath.Length -gt 4096 -or
        $CodexExecutablePath -notmatch '^[A-Za-z]:[\\/]' -or
        $CodexExecutablePath -match '[\x00-\x1F\x7F"<>|?*%&^!;]' -or
        ($CodexExecutablePath.Length -gt 2 -and $CodexExecutablePath.IndexOf(':', 2) -ge 0) -or
        ([IO.Path]::GetFileName($CodexExecutablePath) -notmatch '(?i)^codex\.(cmd|exe)$')) {
        throw 'Optional Codex executable path failed bounded absolute-path validation.'
    }
    try {
        Assert-ExistingFile $CodexExecutablePath 'Optional Codex executable'
        Assert-TrustedSourcePath $CodexExecutablePath $operatorSid
    } catch {
        throw 'Optional Codex executable path failed file, ownership, or reparse-point validation.'
    }
}
$tailscaleEdgeTokenPath = Assert-TailscaleEdgeTokenSource -Path $TailscaleEdgeTokenSource -ExpectedPath (Get-LifeOSTailscaleEdgeTokenPath $paths.SecretRoot) -OperatorSid $operatorSid
$preflightArgs = @{
    CandidateRoot = $candidateRootFull
    ExpectedSourceSha = $ExpectedSourceSha
    ServiceHostBinarySource = $ServiceHostBinarySource
    ApiSource = $ApiSource
    GatewaySource = $GatewaySource
    LegacyGatewaySource = $LegacyGatewaySource
    NodeRuntimeSource = $NodeRuntimeSource
    PythonRuntimeSource = $PythonRuntimeSource
    GatewayEntryPoint = $GatewayEntryPoint
    TailscaleExecutable = $TailscaleExecutable
    TailscaleEdgeTokenSource = $TailscaleEdgeTokenSource
    TailscaleServiceName = $TailscaleServiceName
    LegacyTaskName = $LegacyTaskName
    CodexTaskName = $CodexTaskName
}
& (Join-Path $PSScriptRoot 'preflight.ps1') @preflightArgs | Out-Host

# Preflight is read-only and runs transaction fixtures in a child process. Do
# not hold the deployment mutex while those fixtures execute; acquire it only
# after every preflight gate has passed and before any journal or filesystem
# mutation begins.
$deploymentMutex = Enter-LifeOSDeploymentTransaction
$previousGeneration = Get-LifeOSPreviousInstalledGeneration -MarkerState $deploymentMutex.PreviousState -ManifestPath $deploymentMutex.PreviousManifestPath -OperatorSid $operatorSid -ExpectedGeneration ([string]$deploymentMutex.PreviousGeneration)

$hostSource = Resolve-ServiceHostBinary $ServiceHostBinarySource $paths.ServiceHostPath
$nodeSource = Resolve-NodeRuntimeSource $NodeRuntimeSource $ApiSource
$nodeLargeFileRelativePath = 'node.exe'
$nodeLargeFileMaxBytes = [long]$script:LifeOSCandidateNodeMaxFileBytes
$hostMaxFileBytes = [long]$script:LifeOSCandidateServiceHostMaxFileBytes
$pythonRuntime = Resolve-PythonRuntimeSource $PythonRuntimeSource $GatewaySource
$pythonSource = $pythonRuntime.Root
$gatewayEntrySource = Resolve-GatewayEntryPoint $GatewayEntryPoint $GatewaySource
$apiRoot = Resolve-ApiReleaseRoot $ApiSource
$tailscale = Resolve-TailscaleExecutable $TailscaleExecutable
# Inspect Serve before the first service/data mutation. The decision helper
# permits unrelated routes on other ports, but fails closed on unsupported
# state, public-tunnel flags, ambiguity, or any 8420 route/port collision.
$tailscaleStatusBefore = Get-TailscaleStatusJson $tailscale
$tailscaleDecision = Get-TailscaleServeDecision $tailscaleStatusBefore
$null = $tailscaleDecision
$optionalSourcePaths = @(
    $ClipperIngestSecretSource,
    $GoogleAIStudioApiKeySource,
    $EnableBankingPrivateKeySource,
    $EnableBankingCertificateSource
)
foreach ($optionalSource in ($optionalSourcePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    Assert-ExistingFile $optionalSource 'Optional provider secret/certificate source'
}
# The certificate may be staged for Enable Banking registration, but is not a
# runtime credential and must not be required by the gateway service config.
$bankingValues = @($EnableBankingAppId, $EnableBankingPrivateKeySource, $EnableBankingApiBaseUrl, $EnableBankingRedirectUri)
$hasBankingValue = @($bankingValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
$hasAllBankingValues = @($bankingValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
if ($hasBankingValue -and -not $hasAllBankingValues) {
    throw 'Enable Banking configuration must provide app id, private key, API base URL, and redirect URI together.'
}
if ($EnableOpenFoodFacts -and [string]::IsNullOrWhiteSpace($OpenFoodFactsContactEmail)) {
    throw 'Open Food Facts requires -OpenFoodFactsContactEmail when enabled.'
}
foreach ($optionalSource in ($optionalSourcePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
    Assert-TrustedSourcePath $optionalSource $operatorSid
}
$apiAccount = Get-ServiceAccountName 'LifeOSAPI'
$gatewayAccount = Get-ServiceAccountName 'LifeOSGateway'

$backupDirectory = New-BackupDirectory $paths.BackupRoot 'install'
# Task XML and migration backups may contain existing credentials.  Lock the
# backup directory before exporting/copying any legacy material.
Set-BackupAcl $backupDirectory $operatorSid
$manifestPath = Join-Path $backupDirectory 'manifest.json'
$configDirectory = Join-Path $paths.InstallRoot 'host\config'
# The snapshot is machine state, not gateway data. Keeping it out of the data
# root is deliberate: the gateway can write there, and a gateway that can
# rewrite its own identity assertion would defeat the SYSTEM writer boundary.
$stateDirectory = Join-Path $paths.InstallRoot 'host\state'
$tailscaleSnapshotPath = Join-Path $stateDirectory 'tailscale-state.json'
$hostTarget = Join-Path $paths.InstallRoot 'host\LifeOS.ServiceHost.exe'
$apiTarget = Join-Path $paths.InstallRoot 'api'
$gatewayTarget = Join-Path $paths.InstallRoot 'gateway'
$installedCodePresent = Test-Path -LiteralPath (Join-Path $gatewayTarget 'gateway-release.manifest.json') -PathType Leaf
$launcherSource = Join-Path $script:LifeOSInstallScriptRoot 'gateway_launcher.py'
Assert-ExistingFile $launcherSource 'Gateway launcher'
$snapshotScriptSource = Join-Path $script:LifeOSInstallScriptRoot 'tailscale_snapshot.ps1'
Assert-ExistingFile $snapshotScriptSource 'Tailscale snapshot script'
# SYSTEM runs this script with -ExecutionPolicy Bypass every minute, so write
# access to it is SYSTEM code execution. Stage it inside the host directory,
# whose inheritable DACL already grants the services read/execute only.
$snapshotScriptTarget = Join-Path $paths.InstallRoot 'host\tailscale_snapshot.ps1'
$nodeTarget = Join-Path $paths.RuntimeRoot 'node'
$apiData = Join-Path $paths.DataRoot 'api'
$gatewayData = Join-Path $paths.DataRoot 'gateway'
$apiTemp = Join-Path $apiData 'tmp'
$gatewayTemp = Join-Path $gatewayData 'tmp'
$apiLogs = Join-Path $paths.LogRoot 'api'
$gatewayLogs = Join-Path $paths.LogRoot 'gateway'
$claudeSecret = Join-Path $paths.SecretRoot 'claude-ingest.secret'
$codexSecret = Join-Path $paths.SecretRoot 'codex-ingest.secret'
$localApiSecret = Join-Path $paths.SecretRoot 'local-api.secret'
$clipperSecret = Join-Path $paths.SecretRoot 'clipper-ingest.secret'
$googleAIStudioApiKey = Join-Path $paths.SecretRoot 'google-ai-studio.key'
$enableBankingPrivateKey = Join-Path $paths.SecretRoot 'enable-banking.private-key'
$enableBankingCertificate = Join-Path $paths.SecretRoot 'enable-banking.certificate'
$supplementCatalog = Join-Path $gatewayData 'supplements.sqlite3'
$usageHistory = Join-Path $apiData 'usage-history.jsonl'
$gatewayConfig = Join-Path $configDirectory 'gateway.app.json'
$apiConfig = Join-Path $configDirectory 'LifeOSAPI.json'
$gatewayServiceConfig = Join-Path $configDirectory 'LifeOSGateway.json'
$stateChanges = New-Object System.Collections.ArrayList

$legacy = Get-ScheduledTaskSnapshot -TaskName $LegacyTaskName -BackupDirectory $backupDirectory
$codexTask = Get-ScheduledTaskSnapshot -TaskName $CodexTaskName -BackupDirectory $backupDirectory
$snapshotTask = Get-ScheduledTaskSnapshot -TaskName $TailscaleSnapshotTaskName -BackupDirectory $backupDirectory
$legacyListener = Get-LegacyGatewayListenerSnapshot -TaskSnapshot $legacy -TaskName $LegacyTaskName -TaskPath ([string]$legacy.TaskPath) -Port 8421
$serviceSnapshots = [ordered]@{}
foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
    $serviceSnapshots[$serviceName] = Get-LifeOSServiceSnapshot $serviceName
}
$operatorName = Get-InteractiveOperatorName
$manifest = [ordered]@{
    schemaVersion = 2
    collectorTransition = $null
    transactionId = $deploymentMutex.TransactionId
    generation = [Guid]::NewGuid().ToString()
    manifestPath = (Get-FullPath $manifestPath)
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    operatorSid = $operatorSid
    legacyTask = [ordered]@{ Name = $LegacyTaskName; Exists = $legacy.Exists; Enabled = $legacy.Enabled; State = $legacy.State; TaskPath = $legacy.TaskPath; Backup = $legacy.Backup }
    legacyListener = [ordered]@{
        Exists = [bool]$legacyListener.Exists
        Port = 8421
        LocalAddresses = @($legacyListener.LocalAddresses)
        ProcessId = [int]$legacyListener.ProcessId
        CreationTimeUtc = [string]$legacyListener.CreationTimeUtc
        ExecutablePath = [string]$legacyListener.ExecutablePath
        ExecutableSha256 = [string]$legacyListener.ExecutableSha256
        MainPath = [string]$legacyListener.MainPath
        MainSha256 = [string]$legacyListener.MainSha256
        LauncherPath = [string]$legacyListener.LauncherPath
        LauncherSha256 = [string]$legacyListener.LauncherSha256
        ParentProcessId = [int]$legacyListener.ParentProcessId
        ParentCreationTimeUtc = [string]$legacyListener.ParentCreationTimeUtc
        ParentExecutablePath = [string]$legacyListener.ParentExecutablePath
        ParentExecutableSha256 = [string]$legacyListener.ParentExecutableSha256
        ParentMainPath = [string]$legacyListener.ParentMainPath
        ParentMainSha256 = [string]$legacyListener.ParentMainSha256
        RuntimeRelationship = [string]$legacyListener.RuntimeRelationship
        ChainDepth = [int]$legacyListener.ChainDepth
        TaskName = $LegacyTaskName
        TaskPath = [string]$legacy.TaskPath
        TaskState = [string]$legacy.State
        TaskEnabled = [bool]$legacy.Enabled
        TaskMutated = $false
        Stopped = $false
    }
    codexTask = [ordered]@{ Name = $CodexTaskName; Exists = $codexTask.Exists; Enabled = $codexTask.Enabled; State = $codexTask.State; TaskPath = $codexTask.TaskPath; Backup = $codexTask.Backup; Operator = $operatorName }
    snapshotTask = [ordered]@{ Name = $TailscaleSnapshotTaskName; Exists = $snapshotTask.Exists; Enabled = $snapshotTask.Enabled; State = $snapshotTask.State; TaskPath = $snapshotTask.TaskPath; Backup = $snapshotTask.Backup }
    serviceSnapshots = $serviceSnapshots
    services = @('LifeOSAPI', 'LifeOSGateway')
    paths = [ordered]@{
        host = $hostTarget; api = $apiTarget; gateway = $gatewayTarget; node = $nodeTarget
        pythonBase = (Join-Path $paths.RuntimeRoot 'python312'); pythonVenv = (Join-Path $paths.RuntimeRoot 'python-venv')
        installRoot = $paths.InstallRoot; runtimeRoot = $paths.RuntimeRoot; dataRoot = $paths.DataRoot; logRoot = $paths.LogRoot
        hostDirectory = (Join-Path $paths.InstallRoot 'host')
        apiTemp = $apiTemp; gatewayTemp = $gatewayTemp; gatewayDocuments = (Join-Path $gatewayData 'documents')
        apiData = $apiData; gatewayData = $gatewayData; apiLogs = $apiLogs; gatewayLogs = $gatewayLogs
        localApiSecret = $localApiSecret; secretRoot = $paths.SecretRoot; claudeSecret = $claudeSecret; codexSecret = $codexSecret
        clipperSecret = $clipperSecret; googleAIStudioApiKey = $googleAIStudioApiKey
        enableBankingPrivateKey = $enableBankingPrivateKey; enableBankingCertificate = $enableBankingCertificate
        tailscaleEdgeToken = $tailscaleEdgeTokenPath
        usageHistory = $usageHistory; supplementCatalog = $supplementCatalog
        configDirectory = $configDirectory; apiConfig = $apiConfig; gatewayConfig = $gatewayServiceConfig
        stateDirectory = $stateDirectory; tailscaleSnapshot = $tailscaleSnapshotPath; tailscaleSnapshotScript = $snapshotScriptTarget
        gatewayAppConfig = $gatewayConfig; backupDirectory = $backupDirectory; tailscaleExecutable = $tailscale
    }
    backups = New-Object System.Collections.ArrayList
    aclSnapshots = New-Object System.Collections.ArrayList
    tailscaleStatusBefore = $tailscaleStatusBefore
}
if ($null -ne $previousGeneration -and $null -ne $previousGeneration.Reference) {
    $manifest['priorInstalledGeneration'] = $previousGeneration.Reference
}
Save-InstallManifest $manifest $manifestPath
Bind-LifeOSDeploymentManifest $deploymentMutex $manifest $manifestPath
Set-AclSnapshotContext -Manifest $manifest -ManifestPath $manifestPath -BackupDirectory $backupDirectory
# Capture ACLs of pre-existing deployment targets before any replacement. A
# later snapshot of a newly-created path is still useful for a retry, while
# these early snapshots preserve the old target's ACL for rollback.
foreach ($aclTarget in @($hostTarget, $apiTarget, $gatewayTarget, $nodeTarget, $paths.RuntimeRoot, $paths.DataRoot, $paths.LogRoot, $paths.SecretRoot, $configDirectory, $stateDirectory, $snapshotScriptTarget, $tailscaleEdgeTokenPath)) {
    if (Test-Path -LiteralPath $aclTarget) { Register-AclSnapshot $aclTarget }
}

$legacyTaskMutated = $false
$hostStage = $null
try {
    Stop-DeploymentTaskBarrier $manifest $manifestPath
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) { Stop-LifeOSService $serviceName }

    $legacyCutover = Stop-LegacyGatewayForCutover -TaskSnapshot $legacy -ListenerSnapshot $manifest.legacyListener -Manifest $manifest -ManifestPath $manifestPath -TaskName $LegacyTaskName -TaskPath ([string]$legacy.TaskPath) -Port 8421
    $legacyTaskMutated = [bool]$legacyCutover.TaskMutated
$apiIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'api-release' -Source $apiRoot -Destination $apiTarget -Backup (Join-Path $backupDirectory 'previous-api-release') -PriorExists (Test-Path -LiteralPath $apiTarget -PathType Container) -Changed $true
$apiStage = Copy-ApiReleaseBundle $apiRoot $apiTarget $backupDirectory 'previous-api-release'
Complete-ManifestIntent $apiIntent $manifest $manifestPath $apiStage
$gatewayIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'gateway-release' -Source $GatewaySource -Destination $gatewayTarget -Backup (Join-Path $backupDirectory 'previous-gateway-release') -PriorExists (Test-Path -LiteralPath $gatewayTarget -PathType Container) -Changed $true
$gatewayStage = Copy-GatewayCodeBundle $GatewaySource $gatewayEntrySource $gatewayTarget $launcherSource $backupDirectory 'previous-gateway-release'
Complete-ManifestIntent $gatewayIntent $manifest $manifestPath $gatewayStage
$hostPriorExists = Test-Path -LiteralPath $hostTarget -PathType Leaf
# The service host is the second explicitly allowlisted large candidate file.
# Reject it before any hash/copy operation can consume an oversized payload.
$hostSourceInfo = Assert-BoundedFile -Path $hostSource -MaxBytes $hostMaxFileBytes -Name 'Service host source'
$hostSourceHash = [string]$hostSourceInfo.Sha256
$hostChanged = -not ($hostPriorExists -and $hostSourceHash -eq (Get-FileSha256 $hostTarget))
$hostIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'host-binary' -Source $hostSource -Destination $hostTarget -Backup (Join-Path $backupDirectory ('previous-' + [IO.Path]::GetFileName($hostTarget))) -PriorExists $hostPriorExists -Changed $hostChanged
$hostStage = $null
$pythonStage = Get-ChildRuntimeStage $pythonSource $paths.RuntimeRoot $backupDirectory $manifest $manifestPath
Invoke-NativeChecked -FilePath $pythonStage.PythonPath -ArgumentList ([string[]]@('-B', '-I', '-c', 'import fastapi,httpx,uvicorn,multipart')) -Quiet | Out-Null
$gatewayImportCheck = 'import importlib,os,pathlib,sys; assert sys.version_info[:2] == (3,12),sys.version; from zoneinfo import ZoneInfo; ZoneInfo("Europe/Berlin"); roots=[pathlib.Path(os.environ["LIFEOS_DEPLOY_STAGED_GATEWAY_SOURCE"]).resolve()]; sys.path[:0]=[str(root) for root in roots]; names=("main","enablebanking","supplement_catalog","gateway_launcher"); modules=[importlib.import_module(name) for name in names]; assert all(pathlib.Path(module.__file__).resolve().parent == roots[0] for module in modules), [(name,module.__file__) for name,module in zip(names,modules)]'
$previousAllowedLogin = $env:LIFEOS_TAILSCALE_ALLOWED_LOGIN
$previousStagedGatewayImportSource = $env:LIFEOS_DEPLOY_STAGED_GATEWAY_SOURCE
$previousStagedGatewayImportCheck = $env:LIFEOS_DEPLOY_STAGED_IMPORT_CHECK
try {
    $env:LIFEOS_TAILSCALE_ALLOWED_LOGIN = 'staged-import@lifeos.invalid'
    $env:LIFEOS_DEPLOY_STAGED_GATEWAY_SOURCE = $gatewayTarget
    $env:LIFEOS_DEPLOY_STAGED_IMPORT_CHECK = $gatewayImportCheck
    # Keep the native `-c` payload quote-free for Windows PowerShell 5.1,
    # which strips nested quote characters while binding native arguments.
    $gatewayImportRunner = 'import os;exec(os.environ.get(chr(76)+chr(73)+chr(70)+chr(69)+chr(79)+chr(83)+chr(95)+chr(68)+chr(69)+chr(80)+chr(76)+chr(79)+chr(89)+chr(95)+chr(83)+chr(84)+chr(65)+chr(71)+chr(69)+chr(68)+chr(95)+chr(73)+chr(77)+chr(80)+chr(79)+chr(82)+chr(84)+chr(95)+chr(67)+chr(72)+chr(69)+chr(67)+chr(75)))'
    # The installed gateway is hashed and ACL-locked immediately after this
    # check.  Avoid creating __pycache__ beside its reviewed source bundle.
    Invoke-NativeChecked -FilePath $pythonStage.PythonPath -ArgumentList ([string[]]@('-B', '-I', '-c', $gatewayImportRunner)) -Quiet | Out-Null
} finally {
    if ($null -eq $previousAllowedLogin) { Remove-Item Env:LIFEOS_TAILSCALE_ALLOWED_LOGIN -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_TAILSCALE_ALLOWED_LOGIN = $previousAllowedLogin }
    if ($null -eq $previousStagedGatewayImportSource) { Remove-Item Env:LIFEOS_DEPLOY_STAGED_GATEWAY_SOURCE -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_DEPLOY_STAGED_GATEWAY_SOURCE = $previousStagedGatewayImportSource }
    if ($null -eq $previousStagedGatewayImportCheck) { Remove-Item Env:LIFEOS_DEPLOY_STAGED_IMPORT_CHECK -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_DEPLOY_STAGED_IMPORT_CHECK = $previousStagedGatewayImportCheck }
}

# Node must be staged before the collector task is registered; a clean host
# has no node.exe at the original source path.
$nodeIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'node-runtime' -Source $nodeSource -Destination $nodeTarget -Backup (Join-Path $backupDirectory 'previous-node') -PriorExists (Test-Path -LiteralPath $nodeTarget -PathType Container) -Changed (-not (Compare-TreeManifest $nodeSource $nodeTarget -LargeFileRelativePath $nodeLargeFileRelativePath -LargeFileMaxBytes $nodeLargeFileMaxBytes))
$nodeStage = Copy-TreeVerifiedAtomic $nodeSource $nodeTarget $backupDirectory 'previous-node' -LargeFileRelativePath $nodeLargeFileRelativePath -LargeFileMaxBytes $nodeLargeFileMaxBytes
Complete-ManifestIntent $nodeIntent $manifest $manifestPath $nodeStage

# Register the stopped SCM objects before creating any service-readable
# directory, so the service SIDs can be resolved before ACLs are applied.
# SCM can keep an image handle open even while a service is stopped. Use a
# trusted system image only during ACL provisioning, then point the services at
# the LifeOS host after the shared executable is fully protected. Existing
# services are validated against the canonical LifeOS image before this
# temporary transition.
$serviceRegistrationTarget = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\svchost.exe'
New-ServiceOrConfigure 'LifeOSAPI' $serviceRegistrationTarget 'auto' $apiAccount @() -ExpectedExistingBinary $hostTarget
# `Schedule` is the Task Scheduler service: the gateway now refuses to start
# on a snapshot older than 90 seconds, so it must not be started before the
# SYSTEM task that republishes it can run. Task Scheduler depends only on
# RpcSs, so this adds no cycle.
New-ServiceOrConfigure 'LifeOSGateway' $serviceRegistrationTarget 'delayed-auto' $gatewayAccount @('LifeOSAPI', $TailscaleServiceName, 'Schedule') -ExpectedExistingBinary $hostTarget
$apiSid = Get-ServiceSid 'LifeOSAPI'
$gatewaySid = Get-ServiceSid 'LifeOSGateway'
$manifest.apiServiceSid = $apiSid
$manifest.gatewayServiceSid = $gatewaySid
Save-InstallManifest $manifest $manifestPath
Set-AclSnapshotContext -Manifest $manifest -ManifestPath $manifestPath -BackupDirectory $backupDirectory

# Code and runtime trees are created from verified release sources.  Harden
# each tree's root with a service-specific inheritable boundary after the
# service SIDs exist; Windows propagates that DACL to the newly-created child
# files without racing Defender on individual source files.
Set-DirectoryTraversalAcl $apiTarget $operatorSid @($apiSid) -RootOnly -InheritToChildren
Set-DirectoryTraversalAcl $gatewayTarget $operatorSid @($gatewaySid) -RootOnly -InheritToChildren
Set-DirectoryTraversalAcl $paths.RuntimeRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly -InheritToChildren
Set-DirectoryTraversalAcl $nodeTarget $operatorSid @($apiSid) -RootOnly -InheritToChildren
Set-DirectoryTraversalAcl (Join-Path $paths.RuntimeRoot 'python312') $operatorSid @($gatewaySid) -RootOnly -InheritToChildren
if ($null -ne $pythonStage.VenvTarget) { Set-DirectoryTraversalAcl $pythonStage.VenvTarget $operatorSid @($gatewaySid) -RootOnly -InheritToChildren }

# Lock shared data/log traversal parents at their roots only.  These parents
# deliberately do not grant inheritable service access: only the named API and
# gateway subtrees receive service-specific inheritance below.
Set-DirectoryTraversalAcl $paths.DataRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly
Set-DirectoryTraversalAcl $paths.LogRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly
Set-DirectoryTraversalAcl $paths.SecretRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $configDirectory $operatorSid @($apiSid, $gatewaySid)
# These are the only trees where a service creates durable children.  Keep
# SYSTEM's management grant inheritable for recursive verification, and scope
# a possible service-owned child to the same service that receives Modify.
foreach ($directory in @($apiData, $apiTemp, $apiLogs)) {
    Ensure-Directory $directory
    Set-RestrictedAcl $directory $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -InheritableSystemFullControl
}
foreach ($directory in @($gatewayData, $gatewayTemp, (Join-Path $gatewayData 'documents'), $gatewayLogs)) {
    Ensure-Directory $directory
    Set-RestrictedAcl $directory $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -InheritableSystemFullControl
}
$hostDirectory = Split-Path -Parent $hostTarget
# Prepare the shared host boundary before creating the executable staging
# file.  Its inheritable child grants become the final PE ACL without a
# Defender-sensitive icacls mutation on the executable itself.
Set-DirectoryTraversalAcl $hostDirectory $operatorSid @($apiSid, $gatewaySid) -RootOnly -InheritToChildren
# The gateway may read its Tailscale snapshot and nothing more. Only the
# operator, SYSTEM, and Administrators can write the directory, so the SYSTEM
# task remains the single writer of that identity assertion. SYSTEM's grant is
# inheritable here because the intended writer of this directory *is* SYSTEM,
# and without an inheritable ACE tailscale-state.json would carry no SYSTEM
# entry at all and the writer's atomic replace would survive only on
# FILE_DELETE_CHILD from the parent. The service data/log trees above use the
# same management inheritance for a different reason: their future
# service-created children must remain recursively verifiable.
Ensure-Directory $stateDirectory
Set-RestrictedAcl -Path $stateDirectory -OperatorSid $operatorSid -ReadSids @($gatewaySid) -InheritableSystemFullControl
Assert-NoBroadAcl $stateDirectory
$snapshotScriptIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'tailscale-snapshot-script' -Source $snapshotScriptSource -Destination $snapshotScriptTarget -Backup (Join-Path $backupDirectory 'previous-tailscale_snapshot.ps1') -PriorExists (Test-Path -LiteralPath $snapshotScriptTarget -PathType Leaf) -Changed $true
$snapshotScriptStage = Copy-FileVerifiedAtomic $snapshotScriptSource $snapshotScriptTarget $backupDirectory 'previous-tailscale_snapshot.ps1'
Complete-ManifestIntent $snapshotScriptIntent $manifest $manifestPath $snapshotScriptStage
# The staged script inherited the hardened host-directory DACL; confirm it
# rather than assuming inheritance succeeded.
Assert-RestrictedAcl $snapshotScriptTarget $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
$hostStage = Copy-FileVerifiedAtomic $hostSource $hostTarget $backupDirectory -MaxBytes $hostMaxFileBytes -DeferMove
$catalogInitialized = Initialize-SupplementCatalog -PythonExecutable $pythonStage.PythonPath -GatewayDirectory $gatewayTarget -CatalogPath $supplementCatalog -BackupDirectory $backupDirectory -ManifestBackups $manifest.backups -Manifest $manifest -ManifestPath $manifestPath
$manifest.supplementCatalogInitialized = $catalogInitialized
Save-InstallManifest $manifest $manifestPath

$legacyData = Join-Path $LegacyGatewaySource 'data'
# Explicit authority inventory: tombstones/idempotency are embedded in the state
# envelopes; never infer additional authority from arbitrary legacy filenames.
$authorityFiles = [ordered]@{
    'calendar.json' = 256 * 1024
    'calendar.json.state.json' = 6 * 1024 * 1024
    'calendar.json.meta.json' = 4 * 1024 * 1024
    'calendar.json.retry.json' = 512
    'finance-summary.json' = 256 * 1024
    # Mirrors EnableBankingService.MAX_FINANCE_STATE_SIZE.
    'finance-summary.json.state.json' = 6 * 1024 * 1024
    'finance-summary.json.meta.json' = 4 * 1024 * 1024
    'enablebanking-connections.json' = 256 * 1024
    'enablebanking-revocation.json' = 8 * 1024 * 1024
    'enablebanking-revoked.json' = 64 * 1024
    # These two files are explicitly supported Enable Banking runtime
    # sidecars. Their presence may evolve after an older manifest was written,
    # but they remain bounded and part of the authority inventory.
    'enablebanking-partial.json' = 256 * 1024
    'enablebanking-runtime.json' = 4 * 1024
    # Gateway-owned manual-import state is allowed to appear after an older
    # install and remains covered by the gatewayData ACL/authority inventory.
    'finance-imported.json' = 8 * 1024 * 1024
    'documents.json' = 256 * 1024
}
$authoritySidecars = @('enablebanking-partial.json', 'enablebanking-runtime.json')
$authoritySidecars += 'finance-imported.json'
$legacyAllowedEntries = @($authorityFiles.Keys) + @('documents', 'usage-history.jsonl', 'claude-ingest.secret')
$gatewayAllowedEntries = @($authorityFiles.Keys) + @('documents', 'tmp', 'supplements.sqlite3')
$authorityNameSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($name in $authorityFiles.Keys) { [void]$authorityNameSet.Add([string]$name) }
foreach ($rootRecord in @(
    [pscustomobject]@{ Path = $legacyData; Allowed = $legacyAllowedEntries },
    [pscustomobject]@{ Path = $gatewayData; Allowed = $gatewayAllowedEntries }
)) {
    $root = [string]$rootRecord.Path
    if (-not (Test-Path -LiteralPath $root)) { continue }
    Assert-ExistingDirectory $root 'Authority inventory root'
    $allowedSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($allowed in @($rootRecord.Allowed)) { [void]$allowedSet.Add([string]$allowed) }
    $inventoryState = [pscustomobject]@{ Count = 0; Bytes = [long]0 }
    Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | ForEach-Object {
        $entry = $_
        $inventoryState.Count++
        if ($inventoryState.Count -gt 256) { throw 'Authority inventory root contains too many entries.' }
        if (-not $allowedSet.Contains([string]$entry.Name)) {
            throw "Unclassified legacy authority file or sidecar requires an explicit migration rule: $($entry.Name)"
        }
        if ($authorityNameSet.Contains([string]$entry.Name) -and $entry.PSIsContainer) {
            throw "Authority inventory entry is not a regular file: $($entry.Name)"
        }
        if ($entry.Name -in @('documents', 'tmp') -and -not $entry.PSIsContainer) {
            throw "Authority inventory entry must be a directory: $($entry.Name)"
        }
        if ($entry.Name -in @('usage-history.jsonl', 'claude-ingest.secret', 'supplements.sqlite3') -and $entry.PSIsContainer) {
            throw "Authority inventory entry must be a regular file: $($entry.Name)"
        }
        if (-not $entry.PSIsContainer) {
            $entryLength = [long]$entry.Length
            if ($entryLength -lt 0 -or $entryLength -gt $script:LifeOSRecoveryMaxFileBytes -or
                $entryLength -gt $script:LifeOSRecoveryMaxTreeBytes - $inventoryState.Bytes) {
                throw "Authority inventory exceeds its bounded byte size: $($entry.Name)"
            }
            $inventoryState.Bytes += $entryLength
        }
    }
}
$authorityInventory = New-Object 'System.Collections.Generic.List[object]'
$installedNames = @($authorityFiles.Keys | Where-Object { Test-Path -LiteralPath (Join-Path $gatewayData $_) -PathType Leaf })
$legacyNames = @($authorityFiles.Keys | Where-Object { Test-Path -LiteralPath (Join-Path $legacyData $_) -PathType Leaf })
$expectedNames = @()
$versionedAuthority = $false
if ($null -ne $previousGeneration) {
    $hasPriorInstalledReference = $null -ne $previousGeneration.InstalledManifest
    $authorityManifest = if ($hasPriorInstalledReference) { $previousGeneration.InstalledManifest } else { $previousGeneration.Manifest }
    $previousAuthority = @($authorityManifest.backups | Where-Object { $_.kind -eq 'authority-set' })
    if ($previousAuthority.Count -gt 1) { throw 'Installed generation has multiple classified authority sets.' }
    if ($hasPriorInstalledReference) {
        if ($previousAuthority.Count -ne 1 -or -not (Test-AuthorityRecoveryBaseline $previousAuthority[0])) {
            throw 'Prior installed generation has no complete authority baseline.'
        }
        $expectedNames = @($previousAuthority[0].afterTree | Where-Object { $_.path -in @($authorityFiles.Keys) } | ForEach-Object { $_.path })
        $versionedAuthority = $true
    } elseif ($deploymentMutex.PreviousState -eq 'recovered' -and $previousAuthority.Count -eq 1) {
        # A recovery can finish before the authority intent has durable,
        # complete before/after trees. That terminal marker is safe evidence
        # that recovery ran, but it is not a baseline for the next install.
        if (-not (Test-AuthorityRecoveryBaseline $previousAuthority[0])) {
            $previousAuthority = @()
        }
    }
    if ($previousAuthority.Count -eq 0) {
        if ($deploymentMutex.PreviousState -ne 'recovered') { throw 'Installed generation has no classified authority set.' }
        # The current roots still have to pass Get-AuthorityInstallMode below;
        # only the stale, unusable recovered manifest binding is discarded.
    } elseif (-not $hasPriorInstalledReference) {
        $expectedTree = if ($deploymentMutex.PreviousState -eq 'recovered') { $previousAuthority[0].beforeTree } else { $previousAuthority[0].afterTree }
        $expectedNames = @($expectedTree | Where-Object { $_.path -in @($authorityFiles.Keys) } | ForEach-Object { $_.path })
        $versionedAuthority = $deploymentMutex.PreviousState -ne 'recovered' -or (Get-JournalProperty $previousGeneration.Manifest 'installMode') -in @('upgrade', 'repair')
    }
}
$manifest['installMode'] = Get-AuthorityInstallMode -Installed $installedNames -Legacy $legacyNames -Expected $expectedNames -Versioned $versionedAuthority -CodePresent $installedCodePresent -SupportedEvolution $authoritySidecars
$preserveInstalledAuthority = $manifest.installMode -in @('upgrade', 'repair')
foreach ($name in $authorityFiles.Keys) {
    $source = Join-Path $legacyData $name
    $destination = Join-Path $gatewayData $name
    if (Test-Path -LiteralPath $destination) {
        [void](Assert-BoundedFile $destination $authorityFiles[$name] 'Installed authority')
    }
    if (-not (Test-Path -LiteralPath $source)) { continue }
    $info = Assert-BoundedFile $source $authorityFiles[$name] 'Legacy authority'
    $json = Read-LifeOSCappedFileText -Path $source -MaxBytes $authorityFiles[$name] -Description "Legacy authority $name"
    if ($json.TrimStart() -notmatch '^[{\[]') { throw "Invalid authority JSON container: $name" }
    $decoded = $json | ConvertFrom-Json -ErrorAction Stop
    if ($null -eq $decoded) { throw "Empty authority JSON: $name" }
    $nodes = 0
    Assert-AuthorityJsonBounds $decoded 0 ([ref]$nodes)
    [void]$authorityInventory.Add([ordered]@{ name = $name; sha256 = $info.Sha256; length = $info.Length; maxBytes = $authorityFiles[$name] })
}
# One canonical gatewayData intent keeps companion files in one recovery unit.
# Existing authority wins as a complete set: never backfill an old retry or
# revocation companion into a newer installed envelope on reinstall.
$authorityBeforeTree = @(Get-TreeManifest $gatewayData)
$authorityAfterTreeByPath = [ordered]@{}
foreach ($treeEntry in $authorityBeforeTree) { $authorityAfterTreeByPath[[string]$treeEntry.path] = $treeEntry }
if (-not $preserveInstalledAuthority) {
    foreach ($entry in $authorityInventory) {
        $authorityAfterTreeByPath[[string]$entry.name] = [ordered]@{
            path = [string]$entry.name
            sha256 = [string]$entry.sha256
            length = [long]$entry.length
        }
    }
}
$authorityAfterTree = @($authorityAfterTreeByPath.GetEnumerator() | Sort-Object -Property Key | ForEach-Object { $_.Value })
$authorityPendingFields = [ordered]@{
    authorityFiles = @($authorityInventory.ToArray())
    migrationMode = if ($preserveInstalledAuthority) { 'preserve-installed' } else { 'legacy-import' }
    beforeTree = $authorityBeforeTree
}
$authorityCompletionFields = [ordered]@{
    authorityFiles = @($authorityInventory.ToArray())
    migrationMode = $authorityPendingFields.migrationMode
    beforeTree = $authorityBeforeTree
    afterTree = $authorityAfterTree
    # Complete-ManifestIntent records the post-migration usage authority after
    # the copy. Reserve the largest valid hash representation before mutation.
    usageAfterSha256 = 'f' * 64
}
$authorityIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'authority-set' -Source $legacyData -Destination $gatewayData -Backup (Join-Path $backupDirectory 'previous-authority-set') -PriorExists $true -Changed (-not $preserveInstalledAuthority) -PendingFields $authorityPendingFields -CompletionFields $authorityCompletionFields
if (-not $preserveInstalledAuthority) {
    Copy-Item -LiteralPath $gatewayData -Destination $authorityIntent.backup -Recurse -Force -ErrorAction Stop
    if (-not (Compare-TreeManifest $gatewayData $authorityIntent.backup)) { throw 'Authority backup verification failed.' }
    foreach ($entry in $authorityInventory) {
        $source = Join-Path $legacyData $entry.name
        if ((Get-FileSha256 $source) -ne $entry.sha256) { throw 'Quiesced authority changed during migration.' }
        [void](Copy-FileVerifiedAtomic -Source $source -Destination (Join-Path $gatewayData $entry.name) -BackupDirectory $backupDirectory -BackupName ('previous-' + $entry.name) -MaxBytes $entry.maxBytes)
        if ((Get-FileSha256 (Join-Path $gatewayData $entry.name)) -ne $entry.sha256) { throw 'Migrated authority differs from journal inventory.' }
    }
}
$authorityIntent['afterTree'] = @(Get-TreeManifest $gatewayData)
$authorityIntent['phase'] = 'complete'
Save-InstallManifest $manifest $manifestPath
$legacyDocuments = Join-Path $legacyData 'documents'
if (-not $preserveInstalledAuthority -and (Test-Path -LiteralPath $legacyDocuments -PathType Container)) {
    $destination = Join-Path $gatewayData 'documents'
    $priorExists = Test-Path -LiteralPath $destination -PathType Container
    $changed = -not (Compare-TreeManifest $legacyDocuments $destination)
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'documents-data' -Source $legacyDocuments -Destination $destination -Backup (Join-Path $backupDirectory 'previous-documents') -PriorExists $priorExists -Changed $changed
    $result = Copy-TreeVerifiedAtomic $legacyDocuments $destination $backupDirectory 'previous-documents'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
$legacyUsage = Join-Path $legacyData 'usage-history.jsonl'
if (-not (Test-Path -LiteralPath $usageHistory) -and (Test-Path -LiteralPath $legacyUsage -PathType Leaf)) {
    $priorExists = Test-Path -LiteralPath $usageHistory -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $legacyUsage) -eq (Get-FileSha256 $usageHistory))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'usage-history' -Source $legacyUsage -Destination $usageHistory -Backup (Join-Path $backupDirectory 'previous-usage-history.jsonl') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $legacyUsage $usageHistory $backupDirectory 'previous-usage-history.jsonl'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
# The local bearer is independent of every provider/ingest credential. Protect
# the empty staging file before creating any bytes, then grant the two runtime readers.
if (Test-Path -LiteralPath $localApiSecret) {
    [void](Get-LocalApiBearerHeaders $localApiSecret)
    $localIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'generated-secret' -Destination $localApiSecret -PriorExists $true -Changed $false
    $localIntent['sourceSha256'] = Get-FileSha256 $localApiSecret
    $localIntent['phase'] = 'complete'
    Save-InstallManifest $manifest $manifestPath
} else {
    $localIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'generated-secret' -Destination $localApiSecret -Backup (Join-Path $backupDirectory 'previous-local-api.secret') -PriorExists $false -Changed $true
    $localValue = New-RandomSecret
    try { $localResult = Write-SecretAtomic $localApiSecret $localValue $backupDirectory 'previous-local-api.secret' }
    finally { $localValue = $null }
    $localIntent['sourceSha256'] = Get-FileSha256 $localApiSecret
    Complete-ManifestIntent $localIntent $manifest $manifestPath $localResult
}
$legacyClaude = Join-Path $legacyData 'claude-ingest.secret'
$claudePriorExists = Test-Path -LiteralPath $claudeSecret -PathType Leaf
$claudeChanged = -not ($claudePriorExists -and (Get-FileSha256 $legacyClaude) -eq (Get-FileSha256 $claudeSecret))
$claudeIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'secret' -Source $legacyClaude -Destination $claudeSecret -Backup (Join-Path $backupDirectory 'previous-claude-ingest.secret') -PriorExists $claudePriorExists -Changed $claudeChanged
$secretResult = Copy-FileVerifiedAtomic $legacyClaude $claudeSecret $backupDirectory 'previous-claude-ingest.secret'
Complete-ManifestIntent $claudeIntent $manifest $manifestPath $secretResult
if (Test-Path -LiteralPath $codexSecret -PathType Leaf) {
    Assert-ExistingFile $codexSecret 'Existing Codex secret'
} else {
    $codexValue = New-RandomSecret
    $codexIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'generated-secret' -Destination $codexSecret -Backup (Join-Path $backupDirectory 'previous-codex-ingest.secret') -PriorExists $false -Changed $true
    $codexResult = Write-SecretAtomic $codexSecret $codexValue $backupDirectory 'previous-codex-ingest.secret'
    $codexValue = $null
    Complete-ManifestIntent $codexIntent $manifest $manifestPath $codexResult
}

if (-not [string]::IsNullOrWhiteSpace($ClipperIngestSecretSource)) {
    $priorExists = Test-Path -LiteralPath $clipperSecret -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $ClipperIngestSecretSource) -eq (Get-FileSha256 $clipperSecret))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'secret' -Source $ClipperIngestSecretSource -Destination $clipperSecret -Backup (Join-Path $backupDirectory 'previous-clipper-ingest.secret') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $ClipperIngestSecretSource $clipperSecret $backupDirectory 'previous-clipper-ingest.secret'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
if (-not [string]::IsNullOrWhiteSpace($GoogleAIStudioApiKeySource)) {
    $priorExists = Test-Path -LiteralPath $googleAIStudioApiKey -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $GoogleAIStudioApiKeySource) -eq (Get-FileSha256 $googleAIStudioApiKey))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'secret' -Source $GoogleAIStudioApiKeySource -Destination $googleAIStudioApiKey -Backup (Join-Path $backupDirectory 'previous-google-ai-studio.key') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $GoogleAIStudioApiKeySource $googleAIStudioApiKey $backupDirectory 'previous-google-ai-studio.key'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
if (-not [string]::IsNullOrWhiteSpace($EnableBankingPrivateKeySource)) {
    $priorExists = Test-Path -LiteralPath $enableBankingPrivateKey -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $EnableBankingPrivateKeySource) -eq (Get-FileSha256 $enableBankingPrivateKey))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'banking-key' -Source $EnableBankingPrivateKeySource -Destination $enableBankingPrivateKey -Backup (Join-Path $backupDirectory 'previous-enable-banking.private-key') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $EnableBankingPrivateKeySource $enableBankingPrivateKey $backupDirectory 'previous-enable-banking.private-key'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
if (-not [string]::IsNullOrWhiteSpace($EnableBankingCertificateSource)) {
    $priorExists = Test-Path -LiteralPath $enableBankingCertificate -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $EnableBankingCertificateSource) -eq (Get-FileSha256 $enableBankingCertificate))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'banking-certificate' -Source $EnableBankingCertificateSource -Destination $enableBankingCertificate -Backup (Join-Path $backupDirectory 'previous-enable-banking.certificate') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $EnableBankingCertificateSource $enableBankingCertificate $backupDirectory 'previous-enable-banking.certificate'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}

$gatewayRelativeEntry = $gatewayEntrySource.Substring((Get-FullPath $GatewaySource).TrimEnd('\').Length).TrimStart('\')
$gatewayEntryTarget = Join-Path $gatewayTarget $gatewayRelativeEntry
Assert-ExistingFile $gatewayEntryTarget 'Staged gateway entry point'
$gatewayApp = Get-PathOnlyGatewayConfig -GatewayData $gatewayData -Documents (Join-Path $gatewayData 'documents') -UsageHistory $usageHistory -ClaudeSecret $claudeSecret -TailscaleEdgeTokenPath $tailscaleEdgeTokenPath -ApiUrl 'http://127.0.0.1:8787'
$configIntents = @{}
foreach ($configPath in @($gatewayConfig, $apiConfig, $gatewayServiceConfig)) {
    $configLeaf = [IO.Path]::GetFileName($configPath)
    $configBackupPath = Join-Path $backupDirectory ('previous-' + $configLeaf)
    $configPriorExists = Test-Path -LiteralPath $configPath -PathType Leaf
    $configBackup = $null
    $configIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'config' -Source $configPath -Destination $configPath -Backup $configBackupPath -PriorExists $configPriorExists -Changed $true
    $configBackup = $null
    if ($configPriorExists) {
        $configBackup = Backup-File $configPath $backupDirectory ('previous-' + $configLeaf)
    }
    $configIntents[$configPath] = $configIntent
}
Write-JsonAtomic $gatewayConfig $gatewayApp
Assert-PathOnlyJson $gatewayConfig
$configIntents[$gatewayConfig]['backup'] = if ([bool]$configIntents[$gatewayConfig]['priorExists']) { Join-Path $backupDirectory ('previous-' + [IO.Path]::GetFileName($gatewayConfig)) } else { $null }
$configIntents[$gatewayConfig]['phase'] = 'complete'
Save-InstallManifest $manifest $manifestPath
$apiHost = Get-ApiHostConfig -NodeExecutable (Join-Path $nodeTarget 'node.exe') -ApiDirectory $apiTarget -UsageHistory $usageHistory -ClaudeSecret $claudeSecret -CodexSecret $codexSecret -CodexExecutablePath $CodexExecutablePath -ClipperStorePath (Join-Path $apiData 'clipper-snapshot.json') -ClipperSecret $(if ([string]::IsNullOrWhiteSpace($ClipperIngestSecretSource)) { '' } else { $clipperSecret }) -GoogleAIStudioApiKey $(if ([string]::IsNullOrWhiteSpace($GoogleAIStudioApiKeySource)) { '' } else { $googleAIStudioApiKey }) -GoogleAIStudioFoodModel $GoogleAIStudioFoodModel -GoogleAIStudioFoodModelVersion $GoogleAIStudioFoodModelVersion -OpenFoodFactsEnabled:$EnableOpenFoodFacts -OpenFoodFactsContactEmail $OpenFoodFactsContactEmail -TempDirectory $apiTemp -LogDirectory $apiLogs -ManagementSid $operatorSid
Write-JsonAtomic $apiConfig $apiHost
$configIntents[$apiConfig]['backup'] = if ([bool]$configIntents[$apiConfig]['priorExists']) { Join-Path $backupDirectory ('previous-' + [IO.Path]::GetFileName($apiConfig)) } else { $null }
$configIntents[$apiConfig]['phase'] = 'complete'
Save-InstallManifest $manifest $manifestPath
$launcherTarget = Join-Path $gatewayTarget 'gateway_launcher.py'
$gatewayHost = Get-GatewayHostConfig -PythonExecutable $pythonStage.PythonPath -GatewayDirectory $gatewayTarget -GatewayEntryPoint $gatewayEntryTarget -GatewayConfig $gatewayConfig -ClaudeSecret $claudeSecret -SupplementCatalogPath $supplementCatalog -TempDirectory $gatewayTemp -LogDirectory $gatewayLogs -EnableBankingAppId $EnableBankingAppId -EnableBankingPrivateKeyPath $(if ($hasAllBankingValues) { $enableBankingPrivateKey } else { '' }) -EnableBankingCertificatePath $(if ($hasAllBankingValues) { $enableBankingCertificate } else { '' }) -EnableBankingApiBaseUrl $EnableBankingApiBaseUrl -EnableBankingRedirectUri $EnableBankingRedirectUri -TailscaleServiceName $TailscaleServiceName -TailscaleSnapshotPath $tailscaleSnapshotPath -ManagementSid $operatorSid
$gatewayHost.arguments = @($launcherTarget, '--config', $gatewayConfig, '--entry-point', $gatewayEntryTarget, '--tailscale', $tailscale)
Write-JsonAtomic $gatewayServiceConfig $gatewayHost
Assert-PathOnlyJson $apiConfig
Assert-PathOnlyJson $gatewayServiceConfig
$configIntents[$gatewayServiceConfig]['backup'] = if ([bool]$configIntents[$gatewayServiceConfig]['priorExists']) { Join-Path $backupDirectory ('previous-' + [IO.Path]::GetFileName($gatewayServiceConfig)) } else { $null }
$configIntents[$gatewayServiceConfig]['phase'] = 'complete'
Save-InstallManifest $manifest $manifestPath

# The ACL boundary is explicit: each service receives RX only to its own
# staged code/runtime; Modify only to its own data/log/temp directories.  The
# host binary is shared read-only; config files and secrets are per-service.
# No profile, Users, Everyone, or shared-service grant is created.
Set-DirectoryTraversalAcl $paths.InstallRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly
# The shared host directory was hardened before the staging file was
# created.  Keep this final section focused on validating and moving that
# already-verified file; never mutate a Defender-sensitive PE ACL with icacls.
if ($null -ne $hostStage.StagedPath) {
    # The randomized file inherited the already-hardened host-directory ACL.
    # Validate it without mutating the PE while Defender may have it open;
    # the final rename then preserves that DACL.
    Assert-RestrictedAcl $hostStage.StagedPath $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
    Move-Item -LiteralPath $hostStage.StagedPath -Destination $hostTarget -Force
    Assert-ExistingFile $hostTarget 'Hardened service host'
    if ((Get-FileSha256 $hostTarget) -ne [string]$hostStage.SourceHash) { throw 'Hardened service host hash verification failed.' }
    Assert-RestrictedAcl $hostTarget $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
    $hostStage.StagedPath = $null
} else {
    Assert-RestrictedAcl $hostTarget $operatorSid @($apiSid, $gatewaySid) @() -AllowInherited
}
Complete-ManifestIntent $hostIntent $manifest $manifestPath $hostStage
New-ServiceOrConfigure 'LifeOSAPI' $hostTarget 'auto' $apiAccount @() -ExpectedExistingBinary $serviceRegistrationTarget
New-ServiceOrConfigure 'LifeOSGateway' $hostTarget 'delayed-auto' $gatewayAccount @('LifeOSAPI', $TailscaleServiceName, 'Schedule') -ExpectedExistingBinary $serviceRegistrationTarget
Assert-RestrictedAcl $apiTarget $operatorSid @($apiSid) @() -AllowInherited -Recurse
Assert-RestrictedAcl $gatewayTarget $operatorSid @($gatewaySid) @() -AllowInherited -Recurse
Assert-RestrictedAcl $nodeTarget $operatorSid @($apiSid) @() -AllowInherited -Recurse
Assert-RestrictedAcl (Join-Path $paths.RuntimeRoot 'python312') $operatorSid @($gatewaySid) @() -AllowInherited -Recurse
if ($null -ne $pythonStage.VenvTarget) { Assert-RestrictedAcl $pythonStage.VenvTarget $operatorSid @($gatewaySid) @() -AllowInherited }
Assert-RestrictedAcl $apiData $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse
Assert-RestrictedAcl $gatewayData $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse
Assert-RestrictedAcl $apiLogs $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse
Assert-RestrictedAcl $gatewayLogs $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse
Assert-LifeOSExpectedImmediateChildren -Root $paths.DataRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll
Assert-LifeOSExpectedImmediateChildren -Root $paths.LogRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll
Set-RestrictedAcl $apiConfig $operatorSid @($apiSid) @() -File
Set-RestrictedAcl $gatewayServiceConfig $operatorSid @($gatewaySid) @() -File
Set-RestrictedAcl $gatewayConfig $operatorSid @($gatewaySid) @() -File
Set-DirectoryTraversalAcl $paths.SecretRoot $operatorSid @($apiSid, $gatewaySid)
Set-SecretAcl $claudeSecret $operatorSid @($apiSid, $gatewaySid)
Set-SecretAcl $codexSecret $operatorSid @($apiSid)
Set-SecretAcl $localApiSecret $operatorSid @($apiSid, $gatewaySid)
Assert-NoBroadAcl $localApiSecret
Set-SecretAcl $tailscaleEdgeTokenPath $operatorSid @($gatewaySid)
Assert-NoBroadAcl $claudeSecret
Assert-NoBroadAcl $codexSecret
Assert-NoBroadAcl $tailscaleEdgeTokenPath
if (Test-Path -LiteralPath $clipperSecret -PathType Leaf) {
    Set-SecretAcl $clipperSecret $operatorSid @($apiSid)
    Assert-NoBroadAcl $clipperSecret
}
if (Test-Path -LiteralPath $googleAIStudioApiKey -PathType Leaf) {
    Set-SecretAcl $googleAIStudioApiKey $operatorSid @($apiSid)
    Assert-NoBroadAcl $googleAIStudioApiKey
}
if (Test-Path -LiteralPath $enableBankingPrivateKey -PathType Leaf) {
    Set-SecretAcl $enableBankingPrivateKey $operatorSid @($gatewaySid)
    Assert-NoBroadAcl $enableBankingPrivateKey
}
if (Test-Path -LiteralPath $enableBankingCertificate -PathType Leaf) {
    Set-SecretAcl $enableBankingCertificate $operatorSid @($gatewaySid)
    Assert-NoBroadAcl $enableBankingCertificate
}
if (Test-Path -LiteralPath $supplementCatalog -PathType Leaf) {
    # The catalog is a gateway-owned writable file inside gatewayData. Scope
    # its owner exception to the gateway Modify role; file ACLs do not need an
    # inheritable SYSTEM grant because no children are created beneath them.
    Set-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -File -AllowedOwnerSids @($gatewaySid)
    Assert-NoBroadAcl $supplementCatalog
}

$installedIntegrity = [ordered]@{
    schemaVersion = 1
    host = Get-LifeOSFileIntegrity -Path $hostTarget -Description 'Installed service host'
    api = Get-LifeOSTreeIntegrity -Path $apiTarget -Description 'Installed API release'
    gateway = Get-LifeOSTreeIntegrity -Path $gatewayTarget -Description 'Installed gateway release'
    node = Get-LifeOSTreeIntegrity -Path $nodeTarget -Description 'Installed Node runtime' -LargeFileRelativePath $nodeLargeFileRelativePath -LargeFileMaxBytes $nodeLargeFileMaxBytes
    pythonBase = Get-LifeOSTreeIntegrity -Path (Join-Path $paths.RuntimeRoot 'python312') -Description 'Installed Python base runtime'
    apiConfig = Get-LifeOSFileIntegrity -Path $apiConfig -Description 'Installed API service config'
    gatewayConfig = Get-LifeOSFileIntegrity -Path $gatewayServiceConfig -Description 'Installed gateway service config'
    gatewayAppConfig = Get-LifeOSFileIntegrity -Path $gatewayConfig -Description 'Installed gateway application config'
    snapshotScript = Get-LifeOSFileIntegrity -Path $snapshotScriptTarget -Description 'Installed Tailscale snapshot script'
}
if ($null -ne $pythonStage.VenvTarget -and (Test-Path -LiteralPath $pythonStage.VenvTarget -PathType Container)) {
    $installedIntegrity['pythonVenv'] = Get-LifeOSTreeIntegrity -Path $pythonStage.VenvTarget -Description 'Installed Python virtual environment'
}
$manifest['installedIntegrity'] = $installedIntegrity
Save-InstallManifest $manifest $manifestPath

    $authorityIntent['afterTree'] = @(Get-TreeManifest $gatewayData)
    $authorityIntent['usageAfterSha256'] = if (Test-Path -LiteralPath $usageHistory -PathType Leaf) { Get-FileSha256 $usageHistory } else { '' }
    Save-InstallManifest $manifest $manifestPath
    # Register the collector only after its runtime, API release, secrets,
    # configuration, ACLs, and data stores are all ready. Keeping this inside
    # the cutover transaction restores the prior definition on failure.
    Register-CodexCollectorTask -TaskName $CodexTaskName -OperatorName $operatorName -NodeExecutable (Join-Path $nodeTarget 'node.exe') -ApiDirectory $apiTarget -SecretFile $codexSecret
    Register-TailscaleSnapshotTask -TaskName $TailscaleSnapshotTaskName -ScriptPath $snapshotScriptTarget -TailscaleExecutable $tailscale -OutputPath $tailscaleSnapshotPath
    Start-LifeOSService 'LifeOSAPI'
    if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8787/health') 45)) { throw 'LifeOSAPI did not pass its loopback health check.' }
    if (-not (Wait-LoopbackReadiness ([uri]'http://127.0.0.1:8787/ready') 45)) { throw 'LifeOSAPI did not pass its loopback readiness check.' }
    $manifest['collectorTransition'] = [ordered]@{ phase = 'running'; usageBefore = (Get-RecoveryArtifactState $usageHistory); startedAtUtc = (Get-Date).ToUniversalTime().ToString('o') }
    Save-InstallManifest $manifest $manifestPath
    $codexVerification = Start-AttributedCodexCollector -TaskName $CodexTaskName -UsageUri ([uri]'http://127.0.0.1:8787/api/usage') -AllowProviderUnavailable
    $manifest.collectorTransition['phase'] = 'terminal'
    $manifest.collectorTransition['usageAfter'] = Get-RecoveryArtifactState $usageHistory
    $manifest.collectorTransition['acknowledged'] = ($codexVerification.status -eq 'observed')
    Save-CollectorReceipt $manifest
    $manifest.codexCollectorVerification = [ordered]@{
        terminalCompleted = [bool]$codexVerification.terminalCompleted
        lastRunTime = [string]$codexVerification.lastRunTime
        status = [string]$codexVerification.status
        exitCode = [int]$codexVerification.exitCode
        observation = [string]$codexVerification.observation
        verifiedAt = (Get-Date).ToUniversalTime().ToString('o')
    }
    Save-InstallManifest $manifest $manifestPath
    # Configure is idempotent and records the authenticated post-mutation
    # state before the gateway is started, so a later failure cannot remove a
    # route that appeared concurrently or was not created by this install.
    $serveStatus = Configure-TailscaleServe $tailscale
    $manifest.tailscaleStatusAfter = $serveStatus
    Save-InstallManifest $manifest $manifestPath
    # Use the same fail-closed pre-start boundary as recovery. It publishes a
    # fresh snapshot immediately before the gateway process is started and
    # restores the periodic SYSTEM writer after a successful install.
    Invoke-LifeOSBeforeGatewayStart -TaskName $TailscaleSnapshotTaskName -TaskPath '\' -OutputPath $tailscaleSnapshotPath -TailscaleExecutable $tailscale -RestoreTaskEnabled
    Start-LifeOSService 'LifeOSGateway'
    if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8421/health') 45)) { throw 'LifeOSGateway did not pass its loopback health check.' }
    if (-not (Wait-LoopbackReadiness ([uri]'http://127.0.0.1:8421/ready') 45)) { throw 'LifeOSGateway did not pass its loopback readiness check.' }
    $serveStatus = Configure-TailscaleServe $tailscale
    $manifest.tailscaleStatusAfter = $serveStatus
    $manifest.cutoverCompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    Save-InstallManifest $manifest $manifestPath
    $deploymentCompleted = $true
    Write-Host 'LifeOS cutover completed; the legacy task was disabled but preserved.'
} catch {
    # A read-only preflight failure occurs before the transaction is acquired;
    # there is no journal or deployment mutation to recover in that case.
    if ($null -eq $deploymentMutex) { throw }
    $deploymentRollbackSucceeded = $true
    if ($null -ne $hostStage -and $null -ne $hostStage.PSObject.Properties['StagedPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$hostStage.StagedPath) -and
        (Test-Path -LiteralPath ([string]$hostStage.StagedPath))) {
        Remove-Item -LiteralPath ([string]$hostStage.StagedPath) -Force -ErrorAction SilentlyContinue
    }
    foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) {
        try { Stop-LifeOSService $serviceName } catch { $deploymentRollbackSucceeded = $false; Write-Warning ("Could not stop {0} during rollback: {1}" -f $serviceName, $_.Exception.Message) }
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Writer shutdown failed; recovery_required.' }
    # Discard unsaved in-memory mutations before the barrier journals its own
    # progress. A failed save must not silently replace the rollback baseline.
    $recoveryManifest = Read-LifeOSBoundedJsonFile -Path $manifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'Recovery manifest'
    $manifest = $recoveryManifest
    Stop-DeploymentTaskBarrier $manifest $manifestPath
    # Uncertain/changed authority must never be rolled back by generic restore.
    $resumeJournal = Read-RecoveryJournal $recoveryManifest
    if ($null -eq $resumeJournal) {
    foreach ($item in @($recoveryManifest.backups | Where-Object { $_.kind -eq 'authority-set' })) {
        if ($item.phase -ne 'complete' -or $null -eq $item.PSObject.Properties['afterTree'] -or
            ((@(Get-TreeManifest $item.destination) | ConvertTo-Json -Depth 8 -Compress) -ne
             (@($item.afterTree) | ConvertTo-Json -Depth 8 -Compress))) {
            $deploymentRollbackSucceeded = $false
            throw 'Authority provenance changed or incomplete; recovery_required. Writers remain stopped.'
        }
        $usagePath = [string]$manifest.paths.usageHistory
        $usageHash = if (Test-Path -LiteralPath $usagePath -PathType Leaf) { Get-FileSha256 $usagePath } else { '' }
        if ($null -eq $item.PSObject.Properties['usageAfterSha256'] -or ($usageHash -ne [string]$item.usageAfterSha256 -and -not (Test-CollectorUsagePreserved $recoveryManifest))) {
            $deploymentRollbackSucceeded = $false
            throw 'Usage authority changed or has no provenance; recovery_required.'
        }
        if ($item.changed -and (-not (Test-Path -LiteralPath $item.backup -PathType Container) -or
            ((@(Get-TreeManifest $item.backup) | ConvertTo-Json -Depth 8 -Compress) -ne
             (@($item.beforeTree) | ConvertTo-Json -Depth 8 -Compress)))) {
            $deploymentRollbackSucceeded = $false
            throw 'Authority backup provenance invalid; recovery_required.'
        }
    }
    }
    try {
        Restore-ManifestArtifacts $manifest $backupDirectory
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not restore all deployment artifacts: {0}" -f $_.Exception.Message)
    }
    try {
        Invoke-RecoveryStage $manifest 'Restore-AclSnapshots' { Restore-AclSnapshots $manifest }
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not restore ACL snapshots: {0}" -f $_.Exception.Message)
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Artifact or ACL recovery failed; writers remain stopped.' }
    Enable-RecoveryWriterRestoration $manifest
    $legacyWasMutated = $legacyTaskMutated
    if ($null -ne $manifest.PSObject.Properties['legacyListener']) {
        $legacyWasMutated = $legacyWasMutated -or [bool]$manifest.legacyListener.TaskMutated -or [bool]$manifest.legacyListener.Stopped
    }
    if ($legacyWasMutated) {
        try {
            Restore-LegacyTask $legacy $LegacyTaskName
            if ($null -ne $manifest.PSObject.Properties['legacyListener'] -and [bool]$manifest.legacyListener.Exists) {
                Restore-LegacyGatewayListener -TaskSnapshot $legacy -ListenerSnapshot $manifest.legacyListener -TaskName $LegacyTaskName -TaskPath ([string]$legacy.TaskPath) -Port 8421
            }
            Reconcile-LifeOSScheduledTaskSnapshotState $legacy $LegacyTaskName
        } catch {
            $deploymentRollbackSucceeded = $false
            Write-Warning ("Could not restore legacy task/listener: {0}" -f $_.Exception.Message)
        }
    }
    try {
        $tailscaleExpectedAfter = ''
        if ($null -ne $manifest.PSObject.Properties['tailscaleStatusAfter']) { $tailscaleExpectedAfter = [string]$manifest.tailscaleStatusAfter }
        Invoke-RecoveryStage $manifest 'Restore-TailscaleServeSnapshot' { Restore-TailscaleServeSnapshot -TailscaleExecutable $tailscale -Json $tailscaleStatusBefore -ExpectedAfterJson $tailscaleExpectedAfter }
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not restore Tailscale Serve state: {0}" -f $_.Exception.Message)
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Recovery incomplete; scheduled writers remain disabled.' }

    $gatewayNeedsSnapshot = [string](Get-SnapshotValue $serviceSnapshots['LifeOSGateway'] 'State' '') -ceq 'Running'
    $hasSnapshotContract = $null -ne $manifest.PSObject.Properties['snapshotTask'] -and
        $null -ne $manifest.paths.PSObject.Properties['stateDirectory'] -and
        $null -ne $manifest.paths.PSObject.Properties['tailscaleSnapshot'] -and
        $null -ne $manifest.paths.PSObject.Properties['tailscaleSnapshotScript'] -and
        $null -ne $manifest.paths.PSObject.Properties['tailscaleExecutable']
    if ($gatewayNeedsSnapshot -and -not $hasSnapshotContract) {
        throw 'Recovery cannot start the gateway without a transaction-owned Tailscale snapshot contract.'
    }
    if ($gatewayNeedsSnapshot) {
        $snapshotTaskPath = [string]$snapshotTask.TaskPath
        if ($null -ne $manifest.snapshotTask.PSObject.Properties['TaskPath']) {
            $snapshotTaskPath = [string]$manifest.snapshotTask.TaskPath
        }
        $stoppedSnapshotTask = [pscustomobject]@{ Exists = $true; Enabled = $false; State = 'Stopped'; TaskPath = $snapshotTaskPath }
        try {
            Invoke-RecoveryStage $manifest 'Restore-TailscaleSnapshotTask' {
                Restore-TailscaleSnapshotTask -Snapshot $snapshotTask -TaskName $TailscaleSnapshotTaskName -KeepStopped
            } -LiveAction {
                Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshotTask $TailscaleSnapshotTaskName
            } -Postcondition {
                Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshotTask $TailscaleSnapshotTaskName
            }
        } catch {
            $deploymentRollbackSucceeded = $false
            Write-Warning ("Could not publish a fresh Tailscale snapshot before gateway recovery: {0}" -f $_.Exception.Message)
        }
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Recovery incomplete; scheduled writers remain disabled.' }

    try {
        Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure -VerifyHealth -BeforeGatewayStart {
            Invoke-LifeOSBeforeGatewayStart -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath -OutputPath ([string]$manifest.paths.tailscaleSnapshot) -TailscaleExecutable $tailscale
        }
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not restore or reconcile services: {0}" -f $_.Exception.Message)
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Service recovery failed; writers remain stopped.' }

    Stop-DeploymentTaskBarrier $manifest $manifestPath
    # The barrier can run again after a completed journal stage. Reconcile the
    # live service state explicitly so a retry never treats a stopped service
    # as proof that the durable service-state stage is satisfied.
    try {
        Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure -VerifyHealth -BeforeGatewayStart {
            Invoke-LifeOSBeforeGatewayStart -TaskName $TailscaleSnapshotTaskName -TaskPath $snapshotTaskPath -OutputPath ([string]$manifest.paths.tailscaleSnapshot) -TailscaleExecutable $tailscale
        }
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not re-reconcile services after the writer barrier: {0}" -f $_.Exception.Message)
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Service recovery failed after the writer barrier; writers remain stopped.' }

    try {
        Invoke-RecoveryStage $manifest 'Restore-CodexCollectorTask' { Restore-CodexCollectorTask $codexTask $CodexTaskName } -Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState $codexTask $CodexTaskName }
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not restore Codex collector task: {0}" -f $_.Exception.Message)
    }
    try {
        Invoke-RecoveryStage $manifest 'Restore-TailscaleSnapshotTask' { Restore-TailscaleSnapshotTask $snapshotTask $TailscaleSnapshotTaskName } -LiveAction { Restore-TailscaleSnapshotTask $snapshotTask $TailscaleSnapshotTaskName } -Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState $snapshotTask $TailscaleSnapshotTaskName }
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not restore Tailscale snapshot task: {0}" -f $_.Exception.Message)
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Task recovery failed; services remain stopped.' }
    try {
        if ($legacyWasMutated) { Reconcile-LifeOSScheduledTaskSnapshotState $legacy $LegacyTaskName }
        Reconcile-LifeOSScheduledTaskSnapshotState $codexTask $CodexTaskName
        Reconcile-LifeOSScheduledTaskSnapshotState $snapshotTask $TailscaleSnapshotTaskName
    } catch {
        $deploymentRollbackSucceeded = $false
        Write-Warning ("Could not reconcile scheduled task state: {0}" -f $_.Exception.Message)
    }
    if (-not $deploymentRollbackSucceeded) { throw 'Task recovery state verification failed; services remain stopped.' }
    $recoveryArchivePath = Complete-LifeOSRecoveryState $manifest
    $deploymentRecoveryCompleted = $true
    throw
}
} finally {
    if ($deploymentRecoveryCompleted) { $deploymentMutex.Recovery = $true }
    Exit-LifeOSDeploymentTransaction $deploymentMutex -Completed:($deploymentCompleted -or $deploymentRecoveryCompleted)
}

Write-Host ("Install manifest: {0}" -f (Join-Path $backupDirectory 'manifest.json'))
Write-Host 'No reboot was requested.'
}

if (-not $DefineOnly) { Invoke-LifeOSInstall }
