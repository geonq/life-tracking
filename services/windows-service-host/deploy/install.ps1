[CmdletBinding()]
param(
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
    # Optional provider inputs are file paths, never raw credentials. Their
    # presence opts into the corresponding live adapter during this install.
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
    [string]$EnableBankingRedirectUri
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Deployment.Common.ps1')

Assert-SafeTaskName $LegacyTaskName
Assert-SafeTaskName $CodexTaskName

function Add-ManifestItem {
    param([Parameter(Mandatory)][System.Collections.IList]$List, [Parameter(Mandatory)][object]$Value)
    [void]$List.Add($Value)
}

function Save-InstallManifest {
    param([Parameter(Mandatory)][object]$Manifest, [Parameter(Mandatory)][string]$Path)
    Write-JsonAtomic $Path $Manifest
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
        [Parameter(Mandatory)][bool]$Changed
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

function Migrate-LegacyDataFile {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string]$BackupName,
        [Parameter(Mandatory)][string]$Kind,
        [Parameter(Mandatory)][long]$MaxBytes,
        [Parameter(Mandatory)][string]$BackupDirectory,
        [Parameter(Mandatory)][System.Collections.IList]$ManifestBackups,
        [Parameter(Mandatory)][object]$Manifest,
        [Parameter(Mandatory)][string]$ManifestPath
    )
    if (-not (Test-Path -LiteralPath $Source)) { return }
    $sourceInfo = Assert-BoundedFile $Source $MaxBytes ("Legacy {0} source" -f $Kind)
    $destinationExists = Test-Path -LiteralPath $Destination
    if ($destinationExists -and -not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        throw ("Legacy {0} destination is not a file." -f $Kind)
    }
    $destinationHash = if ($destinationExists) { Get-FileSha256 $Destination } else { '' }
    $changed = -not ($destinationExists -and $sourceInfo.Sha256 -eq $destinationHash)
    $intent = New-ManifestIntent -List $ManifestBackups -Manifest $Manifest -ManifestPath $ManifestPath -Kind $Kind -Source $Source -Destination $Destination -Backup (Join-Path $BackupDirectory $BackupName) -PriorExists $destinationExists -Changed $changed
    $intent['maxBytes'] = $MaxBytes
    $intent['sourceLength'] = [long]$sourceInfo.Length
    Save-InstallManifest $Manifest $ManifestPath
    $result = Copy-FileVerifiedAtomic -Source $Source -Destination $Destination -BackupDirectory $BackupDirectory -BackupName $BackupName -MaxBytes $MaxBytes
    Complete-ManifestIntent $intent $Manifest $ManifestPath $result
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
        # v17 is the reviewed gateway bundle contract. Keep the file list and
        # per-file hashes inside the staged bundle so the transferred release
        # is reproducible and cannot silently omit a reviewed module.
        $releaseManifestPath = Join-Path $temp 'gateway-release.manifest.json'
        Write-JsonAtomic $releaseManifestPath ([ordered]@{
            bundleVersion = 'v17'
            mainSha256 = Get-FileSha256 (Join-Path $temp 'main.py')
            launcherSha256 = Get-FileSha256 (Join-Path $temp 'gateway_launcher.py')
            bundleFiles = $bundleFiles
        })
        $writtenManifest = Get-Content -LiteralPath $releaseManifestPath -Raw | ConvertFrom-Json -ErrorAction Stop
        if ([string]$writtenManifest.bundleVersion -ne 'v17') { throw 'Gateway release manifest version is not v17.' }
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
        Invoke-NativeChecked $PythonExecutable @('-I', '-c', $pythonRunner, $temporaryCatalog, $existingCatalog, $schema, $seed) -Quiet | Out-Null
        Assert-ExistingFile $temporaryCatalog 'Staged supplement catalog database'
        Assert-NoReparsePath $temporaryCatalog
        $backup = $null
        if ($catalogPriorExists) {
            $backup = Backup-File $CatalogPath $BackupDirectory 'previous-supplements.sqlite3'
            Assert-NoReparsePath $CatalogPath
        }
        # Journal the replacement before moving the staged file so a failure
        # during the move still leaves enough information for rollback.
        $catalogIntent = [ordered]@{
            kind = 'supplement-catalog'
            source = $CatalogPath
            destination = $CatalogPath
            backup = $backup
            priorExists = $catalogPriorExists
            changed = $true
            phase = 'pending'
        }
        Add-ManifestItem $ManifestBackups $catalogIntent
        Save-InstallManifest $Manifest $ManifestPath
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
        $cfg = Get-Content -LiteralPath $pyvenv -Raw -ErrorAction Stop
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
        $baseChanged = -not (Compare-TreeManifest $homeRoot $baseTarget)
        $baseIntent = New-ManifestIntent $Manifest.backups $Manifest $ManifestPath 'python-base' $homeRoot $baseTarget (Join-Path $BackupDirectory 'previous-python312') $basePriorExists $baseChanged
        $baseResult = $null
        $venvResult = $null
        $venvIntent = $null
        try {
            $baseResult = Copy-TreeVerifiedAtomic $homeRoot $baseTarget $BackupDirectory 'previous-python312'
            Complete-ManifestIntent $baseIntent $Manifest $ManifestPath $baseResult
            $venvPriorExists = Test-Path -LiteralPath $venvTarget -PathType Container
            $venvChanged = -not (Compare-TreeManifest $sourceRoot $venvTarget)
            $venvIntent = New-ManifestIntent $Manifest.backups $Manifest $ManifestPath 'python-venv' $sourceRoot $venvTarget (Join-Path $BackupDirectory 'previous-python-venv') $venvPriorExists $venvChanged
            $venvResult = Copy-TreeVerifiedAtomic $sourceRoot $venvTarget $BackupDirectory 'previous-python-venv'
            $targetCfg = Join-Path $venvTarget 'pyvenv.cfg'
            Assert-ExistingFile $targetCfg 'Staged pyvenv.cfg'
            $updated = Get-Content -LiteralPath $targetCfg -Raw
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
            foreach ($metadata in (Get-ChildItem -LiteralPath $venvTarget -Recurse -Force -File | Where-Object { $_.Extension -in @('.cfg', '.ini', '.txt', '.cmd', '.bat', '.ps1') })) {
                $content = [IO.File]::ReadAllText($metadata.FullName)
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
    $baseChanged = -not (Compare-TreeManifest $sourceRoot $baseTarget)
    $baseIntent = New-ManifestIntent $Manifest.backups $Manifest $ManifestPath 'python-base' $sourceRoot $baseTarget (Join-Path $BackupDirectory 'previous-python312') $basePriorExists $baseChanged
    $baseResult = Copy-TreeVerifiedAtomic $sourceRoot $baseTarget $BackupDirectory 'previous-python312'
    Complete-ManifestIntent $baseIntent $Manifest $ManifestPath $baseResult
    $stagedBaseRuntime = Resolve-PythonRuntimeSource -Requested $baseTarget -GatewaySource $baseTarget
    return [pscustomobject]@{ PythonPath = $stagedBaseRuntime.Executable; PythonRoot = $stagedBaseRuntime.Root; PythonLayout = $stagedBaseRuntime.Layout; BaseTarget = $baseTarget; VenvTarget = $null; Base = $baseResult; Venv = $null }
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
        [Parameter(Mandatory)][string]$TempDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][string]$ClipperStorePath,
        [string]$ClipperSecret,
        [string]$GoogleAIStudioApiKey,
        [string]$GoogleAIStudioFoodModel,
        [string]$GoogleAIStudioFoodModelVersion,
        [switch]$OpenFoodFactsEnabled,
        [string]$OpenFoodFactsContactEmail
    )
    $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
    $environment = [ordered]@{
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
        [Parameter(Mandatory)][string]$SupplementCatalogPath,
        [Parameter(Mandatory)][string]$TempDirectory,
        [Parameter(Mandatory)][string]$LogDirectory,
        [string]$EnableBankingAppId,
        [string]$EnableBankingPrivateKeyPath,
        [string]$EnableBankingCertificatePath,
        [string]$EnableBankingApiBaseUrl,
        [string]$EnableBankingRedirectUri,
        [string]$TailscaleServiceName = 'Tailscale'
    )
    $systemRoot = if ([string]::IsNullOrWhiteSpace($env:SystemRoot)) { 'C:\Windows' } else { $env:SystemRoot }
    $pythonDirectory = Split-Path -Parent $PythonExecutable
    $pythonRoot = if ([IO.Path]::GetFileName($pythonDirectory) -ieq 'Scripts') {
        Split-Path -Parent $pythonDirectory
    } else {
        $pythonDirectory
    }
    $environment = [ordered]@{
        SYSTEMROOT = $systemRoot
        TEMP = $TempDirectory
        TMP = $TempDirectory
        PATH = $pythonRoot + ';' + (Join-Path $pythonRoot 'Scripts') + ';' + (Join-Path $systemRoot 'System32')
        LIFEOS_SUPPLEMENT_CATALOG_PATH = $SupplementCatalogPath
        LIFEOS_TAILSCALE_SERVICE_NAME = $TailscaleServiceName
    }
    $bankingValues = @($EnableBankingAppId, $EnableBankingPrivateKeyPath, $EnableBankingCertificatePath, $EnableBankingApiBaseUrl, $EnableBankingRedirectUri)
    $bankingMissingCount = @($bankingValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count
    $bankingProvidedCount = $bankingValues.Count - $bankingMissingCount
    if ($bankingMissingCount -gt 0 -and $bankingProvidedCount -gt 0) {
        throw 'Enable Banking configuration must provide app id, key, certificate, API base URL, and redirect URI together.'
    }
    if ($bankingMissingCount -eq 0) {
        $environment.ENABLE_BANKING_APP_ID = $EnableBankingAppId
        $environment.ENABLE_BANKING_PRIVATE_KEY_PATH = $EnableBankingPrivateKeyPath
        $environment.ENABLE_BANKING_CERTIFICATE_PATH = $EnableBankingCertificatePath
        $environment.ENABLE_BANKING_API_BASE_URL = $EnableBankingApiBaseUrl
        $environment.ENABLE_BANKING_REDIRECT_URI = $EnableBankingRedirectUri
    }
    return [ordered]@{
        executablePath = $PythonExecutable
        workingDirectory = $GatewayDirectory
        arguments = @($GatewayEntryPoint)
        environment = $environment
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
$operatorSid = Get-InteractiveOperatorSid
$tailscaleEdgeTokenPath = Assert-TailscaleEdgeTokenSource -Path $TailscaleEdgeTokenSource -ExpectedPath (Get-LifeOSTailscaleEdgeTokenPath $paths.SecretRoot) -OperatorSid $operatorSid
$preflightArgs = @{
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

$hostSource = Resolve-ServiceHostBinary $ServiceHostBinarySource $paths.ServiceHostPath
$nodeSource = Resolve-NodeRuntimeSource $NodeRuntimeSource $ApiSource
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
$bankingValues = @($EnableBankingAppId, $EnableBankingPrivateKeySource, $EnableBankingCertificateSource, $EnableBankingApiBaseUrl, $EnableBankingRedirectUri)
$hasBankingValue = @($bankingValues | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
$hasAllBankingValues = @($bankingValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0
if ($hasBankingValue -and -not $hasAllBankingValues) {
    throw 'Enable Banking configuration must provide app id, key, certificate, API base URL, and redirect URI together.'
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
$legacyListener = Get-LegacyGatewayListenerSnapshot -TaskSnapshot $legacy -TaskName $LegacyTaskName -TaskPath ([string]$legacy.TaskPath) -Port 8421
$serviceSnapshots = [ordered]@{}
foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) {
    $serviceSnapshots[$serviceName] = Get-LifeOSServiceSnapshot $serviceName
}
$operatorName = Get-InteractiveOperatorName
$manifest = [ordered]@{
    schemaVersion = 2
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
    serviceSnapshots = $serviceSnapshots
    services = @('LifeOSAPI', 'LifeOSGateway')
    paths = [ordered]@{
        host = $hostTarget; api = $apiTarget; gateway = $gatewayTarget; node = $nodeTarget
        pythonBase = (Join-Path $paths.RuntimeRoot 'python312'); pythonVenv = (Join-Path $paths.RuntimeRoot 'python-venv')
        installRoot = $paths.InstallRoot; runtimeRoot = $paths.RuntimeRoot; dataRoot = $paths.DataRoot; logRoot = $paths.LogRoot
        hostDirectory = (Join-Path $paths.InstallRoot 'host')
        apiTemp = $apiTemp; gatewayTemp = $gatewayTemp; gatewayDocuments = (Join-Path $gatewayData 'documents')
        apiData = $apiData; gatewayData = $gatewayData; apiLogs = $apiLogs; gatewayLogs = $gatewayLogs
        secretRoot = $paths.SecretRoot; claudeSecret = $claudeSecret; codexSecret = $codexSecret
        clipperSecret = $clipperSecret; googleAIStudioApiKey = $googleAIStudioApiKey
        enableBankingPrivateKey = $enableBankingPrivateKey; enableBankingCertificate = $enableBankingCertificate
        tailscaleEdgeToken = $tailscaleEdgeTokenPath
        usageHistory = $usageHistory; supplementCatalog = $supplementCatalog
        configDirectory = $configDirectory; apiConfig = $apiConfig; gatewayConfig = $gatewayServiceConfig
        gatewayAppConfig = $gatewayConfig; backupDirectory = $backupDirectory; tailscaleExecutable = $tailscale
    }
    backups = New-Object System.Collections.ArrayList
    aclSnapshots = New-Object System.Collections.ArrayList
    tailscaleStatusBefore = $tailscaleStatusBefore
}
Save-InstallManifest $manifest $manifestPath
Set-AclSnapshotContext -Manifest $manifest -ManifestPath $manifestPath -BackupDirectory $backupDirectory
# Capture ACLs of pre-existing deployment targets before any replacement. A
# later snapshot of a newly-created path is still useful for a retry, while
# these early snapshots preserve the old target's ACL for rollback.
foreach ($aclTarget in @($hostTarget, $apiTarget, $gatewayTarget, $nodeTarget, $paths.RuntimeRoot, $paths.DataRoot, $paths.LogRoot, $paths.SecretRoot, $configDirectory, $tailscaleEdgeTokenPath)) {
    if (Test-Path -LiteralPath $aclTarget) { Register-AclSnapshot $aclTarget }
}

$legacyTaskMutated = $false
$hostStage = $null
try {
    foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway')) { Stop-LifeOSService $serviceName }

$apiIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'api-release' -Source $apiRoot -Destination $apiTarget -Backup (Join-Path $backupDirectory 'previous-api-release') -PriorExists (Test-Path -LiteralPath $apiTarget -PathType Container) -Changed $true
$apiStage = Copy-ApiReleaseBundle $apiRoot $apiTarget $backupDirectory 'previous-api-release'
Complete-ManifestIntent $apiIntent $manifest $manifestPath $apiStage
$gatewayIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'gateway-release' -Source $GatewaySource -Destination $gatewayTarget -Backup (Join-Path $backupDirectory 'previous-gateway-release') -PriorExists (Test-Path -LiteralPath $gatewayTarget -PathType Container) -Changed $true
$gatewayStage = Copy-GatewayCodeBundle $GatewaySource $gatewayEntrySource $gatewayTarget $launcherSource $backupDirectory 'previous-gateway-release'
Complete-ManifestIntent $gatewayIntent $manifest $manifestPath $gatewayStage
$hostPriorExists = Test-Path -LiteralPath $hostTarget -PathType Leaf
$hostChanged = -not ($hostPriorExists -and (Get-FileSha256 $hostSource) -eq (Get-FileSha256 $hostTarget))
$hostIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'host-binary' -Source $hostSource -Destination $hostTarget -Backup (Join-Path $backupDirectory ('previous-' + [IO.Path]::GetFileName($hostTarget))) -PriorExists $hostPriorExists -Changed $hostChanged
$hostStage = $null
$pythonStage = Get-ChildRuntimeStage $pythonSource $paths.RuntimeRoot $backupDirectory $manifest $manifestPath
Invoke-NativeChecked $pythonStage.PythonPath @('-I', '-c', 'import fastapi,httpx,uvicorn,multipart') -Quiet | Out-Null
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
    Invoke-NativeChecked $pythonStage.PythonPath @('-I', '-c', $gatewayImportRunner) -Quiet | Out-Null
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
$nodeIntent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'node-runtime' -Source $nodeSource -Destination $nodeTarget -Backup (Join-Path $backupDirectory 'previous-node') -PriorExists (Test-Path -LiteralPath $nodeTarget -PathType Container) -Changed (-not (Compare-TreeManifest $nodeSource $nodeTarget))
$nodeStage = Copy-TreeVerifiedAtomic $nodeSource $nodeTarget $backupDirectory 'previous-node'
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
New-ServiceOrConfigure 'LifeOSGateway' $serviceRegistrationTarget 'delayed-auto' $gatewayAccount @('LifeOSAPI', $TailscaleServiceName) -ExpectedExistingBinary $hostTarget
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

# Lock parent roots before sensitive children are created.  Every child then
# gets its own service-specific ACL before migration writes any bytes.
Set-DirectoryTraversalAcl $paths.DataRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $paths.LogRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $paths.SecretRoot $operatorSid @($apiSid, $gatewaySid)
Set-DirectoryTraversalAcl $configDirectory $operatorSid @($apiSid, $gatewaySid)
foreach ($directory in @($apiData, $apiTemp, $apiLogs)) { Ensure-Directory $directory; Set-RestrictedAcl $directory $operatorSid @() @($apiSid) }
foreach ($directory in @($gatewayData, $gatewayTemp, (Join-Path $gatewayData 'documents'), $gatewayLogs)) { Ensure-Directory $directory; Set-RestrictedAcl $directory $operatorSid @() @($gatewaySid) }
$hostDirectory = Split-Path -Parent $hostTarget
# Prepare the shared host boundary before creating the executable staging
# file.  Its inheritable child grants become the final PE ACL without a
# Defender-sensitive icacls mutation on the executable itself.
Set-DirectoryTraversalAcl $hostDirectory $operatorSid @($apiSid, $gatewaySid) -RootOnly -InheritToChildren
$hostStage = Copy-FileVerifiedAtomic $hostSource $hostTarget $backupDirectory -DeferMove
$catalogInitialized = Initialize-SupplementCatalog -PythonExecutable $pythonStage.PythonPath -GatewayDirectory $gatewayTarget -CatalogPath $supplementCatalog -BackupDirectory $backupDirectory -ManifestBackups $manifest.backups -Manifest $manifest -ManifestPath $manifestPath
$manifest.supplementCatalogInitialized = $catalogInitialized
Save-InstallManifest $manifest $manifestPath

$legacyData = Join-Path $LegacyGatewaySource 'data'
$legacyCalendar = Join-Path $legacyData 'calendar.json'
if (Test-Path -LiteralPath $legacyCalendar -PathType Leaf) {
    $destination = Join-Path $gatewayData 'calendar.json'
    $priorExists = Test-Path -LiteralPath $destination -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $legacyCalendar) -eq (Get-FileSha256 $destination))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'calendar-data' -Source $legacyCalendar -Destination $destination -Backup (Join-Path $backupDirectory 'previous-calendar.json') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $legacyCalendar $destination $backupDirectory 'previous-calendar.json'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
$legacyEnableBankingConnections = Join-Path $legacyData 'enablebanking-connections.json'
Migrate-LegacyDataFile -Source $legacyEnableBankingConnections -Destination (Join-Path $gatewayData 'enablebanking-connections.json') -BackupName 'previous-enablebanking-connections.json' -Kind 'enablebanking-connections' -MaxBytes (256 * 1024) -BackupDirectory $backupDirectory -ManifestBackups $manifest.backups -Manifest $manifest -ManifestPath $manifestPath
$legacyFinanceSummary = Join-Path $legacyData 'finance-summary.json'
Migrate-LegacyDataFile -Source $legacyFinanceSummary -Destination (Join-Path $gatewayData 'finance-summary.json') -BackupName 'previous-finance-summary.json' -Kind 'finance-summary' -MaxBytes (1 * 1024 * 1024) -BackupDirectory $backupDirectory -ManifestBackups $manifest.backups -Manifest $manifest -ManifestPath $manifestPath
$legacyDocuments = Join-Path $legacyData 'documents'
if (Test-Path -LiteralPath $legacyDocuments -PathType Container) {
    $destination = Join-Path $gatewayData 'documents'
    $priorExists = Test-Path -LiteralPath $destination -PathType Container
    $changed = -not (Compare-TreeManifest $legacyDocuments $destination)
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'documents-data' -Source $legacyDocuments -Destination $destination -Backup (Join-Path $backupDirectory 'previous-documents') -PriorExists $priorExists -Changed $changed
    $result = Copy-TreeVerifiedAtomic $legacyDocuments $destination $backupDirectory 'previous-documents'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
}
$legacyUsage = Join-Path $legacyData 'usage-history.jsonl'
if (Test-Path -LiteralPath $legacyUsage -PathType Leaf) {
    $priorExists = Test-Path -LiteralPath $usageHistory -PathType Leaf
    $changed = -not ($priorExists -and (Get-FileSha256 $legacyUsage) -eq (Get-FileSha256 $usageHistory))
    $intent = New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'usage-history' -Source $legacyUsage -Destination $usageHistory -Backup (Join-Path $backupDirectory 'previous-usage-history.jsonl') -PriorExists $priorExists -Changed $changed
    $result = Copy-FileVerifiedAtomic $legacyUsage $usageHistory $backupDirectory 'previous-usage-history.jsonl'
    Complete-ManifestIntent $intent $manifest $manifestPath $result
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
$apiHost = Get-ApiHostConfig -NodeExecutable (Join-Path $nodeTarget 'node.exe') -ApiDirectory $apiTarget -UsageHistory $usageHistory -ClaudeSecret $claudeSecret -CodexSecret $codexSecret -ClipperStorePath (Join-Path $apiData 'clipper-snapshot.json') -ClipperSecret $(if ([string]::IsNullOrWhiteSpace($ClipperIngestSecretSource)) { '' } else { $clipperSecret }) -GoogleAIStudioApiKey $(if ([string]::IsNullOrWhiteSpace($GoogleAIStudioApiKeySource)) { '' } else { $googleAIStudioApiKey }) -GoogleAIStudioFoodModel $GoogleAIStudioFoodModel -GoogleAIStudioFoodModelVersion $GoogleAIStudioFoodModelVersion -OpenFoodFactsEnabled:$EnableOpenFoodFacts -OpenFoodFactsContactEmail $OpenFoodFactsContactEmail -TempDirectory $apiTemp -LogDirectory $apiLogs
Write-JsonAtomic $apiConfig $apiHost
$configIntents[$apiConfig]['backup'] = if ([bool]$configIntents[$apiConfig]['priorExists']) { Join-Path $backupDirectory ('previous-' + [IO.Path]::GetFileName($apiConfig)) } else { $null }
$configIntents[$apiConfig]['phase'] = 'complete'
Save-InstallManifest $manifest $manifestPath
$launcherTarget = Join-Path $gatewayTarget 'gateway_launcher.py'
$gatewayHost = Get-GatewayHostConfig -PythonExecutable $pythonStage.PythonPath -GatewayDirectory $gatewayTarget -GatewayEntryPoint $gatewayEntryTarget -GatewayConfig $gatewayConfig -ClaudeSecret $claudeSecret -SupplementCatalogPath $supplementCatalog -TempDirectory $gatewayTemp -LogDirectory $gatewayLogs -EnableBankingAppId $EnableBankingAppId -EnableBankingPrivateKeyPath $(if ($hasAllBankingValues) { $enableBankingPrivateKey } else { '' }) -EnableBankingCertificatePath $(if ($hasAllBankingValues) { $enableBankingCertificate } else { '' }) -EnableBankingApiBaseUrl $EnableBankingApiBaseUrl -EnableBankingRedirectUri $EnableBankingRedirectUri -TailscaleServiceName $TailscaleServiceName
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
New-ServiceOrConfigure 'LifeOSGateway' $hostTarget 'delayed-auto' $gatewayAccount @('LifeOSAPI', $TailscaleServiceName) -ExpectedExistingBinary $serviceRegistrationTarget
Assert-RestrictedAcl $apiTarget $operatorSid @($apiSid) @() -AllowInherited
Assert-RestrictedAcl $gatewayTarget $operatorSid @($gatewaySid) @() -AllowInherited
Assert-RestrictedAcl $nodeTarget $operatorSid @($apiSid) @() -AllowInherited
Assert-RestrictedAcl (Join-Path $paths.RuntimeRoot 'python312') $operatorSid @($gatewaySid) @() -AllowInherited
if ($null -ne $pythonStage.VenvTarget) { Assert-RestrictedAcl $pythonStage.VenvTarget $operatorSid @($gatewaySid) @() -AllowInherited }
Set-RestrictedAcl $apiConfig $operatorSid @($apiSid) @() -File
Set-RestrictedAcl $gatewayServiceConfig $operatorSid @($gatewaySid) @() -File
Set-RestrictedAcl $gatewayConfig $operatorSid @($gatewaySid) @() -File
Set-DirectoryTraversalAcl $paths.SecretRoot $operatorSid @($apiSid, $gatewaySid)
Set-SecretAcl $claudeSecret $operatorSid @($apiSid, $gatewaySid)
Set-SecretAcl $codexSecret $operatorSid @($apiSid)
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
    Set-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -File
    Assert-NoBroadAcl $supplementCatalog
}

Save-InstallManifest $manifest $manifestPath

    # Register the collector only after its runtime, API release, secrets,
    # configuration, ACLs, and data stores are all ready. Keeping this inside
    # the cutover transaction restores the prior definition on failure.
    Register-CodexCollectorTask -TaskName $CodexTaskName -OperatorName $operatorName -NodeExecutable (Join-Path $nodeTarget 'node.exe') -ApiDirectory $apiTarget -SecretFile $codexSecret
    Start-LifeOSService 'LifeOSAPI'
    if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8787/health') 45)) { throw 'LifeOSAPI did not pass its loopback health check.' }
    Start-CodexCollectorAndVerify -TaskName $CodexTaskName -UsageUri ([uri]'http://127.0.0.1:8787/api/usage')
    $legacyCutover = Stop-LegacyGatewayForCutover -TaskSnapshot $legacy -ListenerSnapshot $manifest.legacyListener -Manifest $manifest -ManifestPath $manifestPath -TaskName $LegacyTaskName -TaskPath ([string]$legacy.TaskPath) -Port 8421
    $legacyTaskMutated = [bool]$legacyCutover.TaskMutated
    # Configure is idempotent and records the authenticated post-mutation
    # state before the gateway is started, so a later failure cannot remove a
    # route that appeared concurrently or was not created by this install.
    $serveStatus = Configure-TailscaleServe $tailscale
    $manifest.tailscaleStatusAfter = $serveStatus
    Save-InstallManifest $manifest $manifestPath
    Start-LifeOSService 'LifeOSGateway'
    if (-not (Wait-LoopbackHealth ([uri]'http://127.0.0.1:8421/health') 45)) { throw 'LifeOSGateway did not pass its loopback health check.' }
    $serveStatus = Configure-TailscaleServe $tailscale
    $manifest.tailscaleStatusAfter = $serveStatus
    $manifest.cutoverCompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    Save-InstallManifest $manifest $manifestPath
    Write-Host 'LifeOS cutover completed; the legacy task was disabled but preserved.'
} catch {
    if ($null -ne $hostStage -and $null -ne $hostStage.PSObject.Properties['StagedPath'] -and
        -not [string]::IsNullOrWhiteSpace([string]$hostStage.StagedPath) -and
        (Test-Path -LiteralPath ([string]$hostStage.StagedPath))) {
        Remove-Item -LiteralPath ([string]$hostStage.StagedPath) -Force -ErrorAction SilentlyContinue
    }
    foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) {
        try { Stop-LifeOSService $serviceName } catch { Write-Warning ("Could not stop {0} during rollback: {1}" -f $serviceName, $_.Exception.Message) }
    }
    try {
        Restore-CodexCollectorTask $codexTask $CodexTaskName
    } catch {
        Write-Warning ("Could not restore Codex collector task: {0}" -f $_.Exception.Message)
    }
    try {
        Restore-ManifestArtifacts $manifest $backupDirectory
    } catch {
        Write-Warning ("Could not restore all deployment artifacts: {0}" -f $_.Exception.Message)
    }
    try {
        Restore-AclSnapshots $manifest
    } catch {
        Write-Warning ("Could not restore ACL snapshots: {0}" -f $_.Exception.Message)
    }
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
        } catch {
            Write-Warning ("Could not restore legacy task/listener: {0}" -f $_.Exception.Message)
        }
    }
    foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) {
        try {
            Restore-LifeOSServiceSnapshot $serviceSnapshots[$serviceName]
        } catch {
            Write-Warning ("Could not restore service {0}: {1}" -f $serviceName, $_.Exception.Message)
        }
    }
    try {
        $tailscaleExpectedAfter = ''
        if ($manifest.Keys -contains 'tailscaleStatusAfter') { $tailscaleExpectedAfter = [string]$manifest.tailscaleStatusAfter }
        Restore-TailscaleServeSnapshot -TailscaleExecutable $tailscale -Json $tailscaleStatusBefore -ExpectedAfterJson $tailscaleExpectedAfter
    } catch {
        Write-Warning ("Could not restore Tailscale Serve state: {0}" -f $_.Exception.Message)
    }
    throw
}

Write-Host ("Install manifest: {0}" -f (Join-Path $backupDirectory 'manifest.json'))
Write-Host 'No reboot was requested.'
