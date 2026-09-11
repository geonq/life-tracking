[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deploy = Split-Path -Parent $PSScriptRoot
. (Join-Path $deploy 'Deployment.Common.ps1')
# Keep the install transaction helpers available for the later manifest and
# checkpoint fixtures. Loading definition-only at script scope is required on
# Windows PowerShell 5.1; a dot-source nested in an `& {}` fixture expires
# with that child scope.
. (Join-Path $deploy 'install.ps1') -DefineOnly

function Assert-Behavior {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-BehaviorThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "FAIL: expected rejection: $Message" }
}

function Assert-BehaviorThrowsSafe {
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][string]$Message,
        [Parameter(Mandatory)][string]$ForbiddenText
    )
    $caught = $null
    try { & $Action } catch { $caught = $_.Exception.Message }
    if ($null -eq $caught) { throw "FAIL: expected rejection: $Message" }
    if ($caught -notlike "*$Message*") { throw "FAIL: rejection diagnostic was not precise: $Message" }
    if ($caught -like "*$ForbiddenText*") { throw "FAIL: token value was not displayed: rejection diagnostic exposed token material: $Message" }
}

& {
    # Windows PowerShell promotes native stderr merged by 2>&1 into a
    # terminating error under ErrorActionPreference Stop. The installer must
    # therefore query the fresh venv first and uninstall only tools that are
    # actually present, rather than asking pip to warn about every absent tool.
    $script:packagingToolNativeCalls = New-Object System.Collections.ArrayList
    function Invoke-NativeChecked {
        param([string]$FilePath, [string[]]$ArgumentList, [switch]$Quiet)
        [void]$script:packagingToolNativeCalls.Add([pscustomobject]@{ FilePath = $FilePath; Arguments = @($ArgumentList) })
        if ($ArgumentList -contains 'uninstall') {
            return [pscustomobject]@{ ExitCode = 0; Output = @() }
        }
        return [pscustomobject]@{ ExitCode = 0; Output = @('pip', 'setuptools') }
    }
    try {
        Remove-PythonPackagingTools -PythonExecutable 'fixture-python.exe'
        $uninstallCalls = @($script:packagingToolNativeCalls | Where-Object { $_.Arguments -contains 'uninstall' })
        Assert-Behavior ($uninstallCalls.Count -eq 1) 'packaging removal invokes pip exactly once when tools are installed.'
        Assert-Behavior (($uninstallCalls[0].Arguments -join '|') -ceq '-B|-I|-m|pip|uninstall|--disable-pip-version-check|--no-input|-y|pip|setuptools') 'packaging removal passes only the discovered tools, avoiding absent-package warnings.'

        $script:packagingToolNativeCalls = New-Object System.Collections.ArrayList
        function Get-PythonPackagingToolNames { param([string]$PythonExecutable) return @() }
        Remove-PythonPackagingTools -PythonExecutable 'fixture-python.exe'
        Assert-Behavior ($script:packagingToolNativeCalls.Count -eq 0) 'packaging removal skips pip when no packaging tools are installed.'
    } finally {
        Remove-Variable -Name packagingToolNativeCalls -Scope Script -ErrorAction SilentlyContinue
    }
}

# Isolate the fake CIM command in a child scope; it must never escape into
# the real preflight listener query after this suite returns.
& {
    $script:listenerFixtureMode = 'empty'
    function Get-NetTCPConnection {
        [CmdletBinding()]
        param([int]$LocalPort, [string]$State)
        Assert-Behavior ($LocalPort -eq 8421 -and $State -eq 'Listen') 'listener query is port/state bounded.'
        switch ($script:listenerFixtureMode) {
            'empty' { return }
            'listener' { return [pscustomobject]@{ LocalAddress = '127.0.0.1'; OwningProcess = 4242 } }
            'not-found' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('Localized CIM no-match fixture'),
                    'CmdletizationQuery_NotFound',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            'permission' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [UnauthorizedAccessException]::new('Access denied fixture'),
                    'CimAccessDenied',
                    [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            'wrong-category' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('Provider failed fixture'),
                    'CmdletizationQuery_NotFound',
                    [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            'query-failure' { throw 'CIM provider unavailable fixture' }
            default { throw 'Unknown listener fixture mode' }
        }
    }
    try {
        foreach ($mode in @('empty', 'not-found')) {
            $script:listenerFixtureMode = $mode
            $result = Get-LoopbackPortOwner -Port 8421
            Assert-Behavior ($null -eq $result) "empty listener state is exactly null: $mode"
        }
        foreach ($mode in @('permission', 'query-failure', 'wrong-category')) {
            $script:listenerFixtureMode = $mode
            Assert-BehaviorThrows { Get-LoopbackPortOwner -Port 8421 } "listener query fails closed: $mode"
        }
        $script:listenerFixtureMode = 'listener'
        $result = Get-LoopbackPortOwner -Port 8421
        Assert-Behavior ($result.ProcessId -eq 4242 -and $result.LocalAddresses.Count -eq 1 -and
            $result.LocalAddresses[0] -ceq '127.0.0.1') 'listener owner and address are retained exactly.'
    } finally {
        Remove-Variable -Name listenerFixtureMode -Scope Script
    }
}

$empty = '{"Web":{},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$unrelated = '{"Web":{"https://node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$lifeosEndpoint = '{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421","AcceptAppCaps":["lifeos.example/trusted-edge"]}}}'
$withLifeOS = '{"Web":{"https://node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},"https://node.example.ts.net:8420":' + $lifeosEndpoint + '},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'

$emptyDecision = Get-TailscaleServeDecision $empty
Assert-Behavior ($emptyDecision.Action -eq 'Add') 'empty Serve state is eligible for an additive route.'
$unrelatedDecision = Get-TailscaleServeDecision $unrelated
Assert-Behavior ($unrelatedDecision.Action -eq 'Add') 'unrelated routes on another port are eligible for coexistence.'
$lifeosDecision = Get-TailscaleServeDecision $withLifeOS
Assert-Behavior ($lifeosDecision.Action -eq 'AlreadyConfigured') 'the exact LifeOS route is idempotent alongside an unrelated route.'
Assert-Behavior (Test-TailscaleServeExact $withLifeOS) 'exact route detection accepts unrelated routes outside 8420.'
Assert-Behavior ((Get-TailscaleServeFingerprint $withLifeOS -ExcludeLifeOSRoute) -eq (Get-TailscaleServeFingerprint $unrelated -ExcludeLifeOSRoute)) 'unrelated Serve fingerprint is unchanged by the LifeOS route.'
$pairedLifeOS = $withLifeOS.Replace('"TCP":{}', '"TCP":{"8420":{"HTTPS":true}}')
$pairedDecision = Get-TailscaleServeDecision $pairedLifeOS
Assert-Behavior ($pairedDecision.Action -eq 'AlreadyConfigured') 'the exact paired HTTPS TCP mirror is idempotent.'
Assert-Behavior (Test-TailscaleServeExact $pairedLifeOS) 'the PowerShell validator accepts the paired HTTPS TCP mirror.'
$unsafePairedLifeOS = $pairedLifeOS.Replace('"HTTPS":true', '"HTTPS":true,"TCPForward":"127.0.0.1:9000"')
Assert-Behavior (-not (Test-TailscaleServeExact $unsafePairedLifeOS)) 'the PowerShell validator rejects extra fields on the paired TCP mirror.'

$routeCollision = '{"Web":{"https://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:9000"}}}},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$pathCollision = '{"Web":{"https://node.example.ts.net:8420":{"Handlers":{"/other":{"Proxy":"http://127.0.0.1:9000"}}}},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$tcpCollision = '{"Web":{},"TCP":{"8420":"tcp://127.0.0.1:9000"},"Services":{},"AllowFunnel":false,"Foreground":false}'
$serviceCollision = '{"Web":{},"TCP":{},"Services":{"svc:other":{"endpoints":{"tcp:8420":"http://127.0.0.1:9000"}}},"AllowFunnel":false,"Foreground":false}'
$rangeCollision = '{"Web":{"https://node.example.ts.net:8419-8421":' + $lifeosEndpoint + '},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$ambiguous = '{"Web":{"https://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}},"http://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}}},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$funnel = '{"Web":{},"TCP":{},"Services":{},"AllowFunnel":{"https://node.example.ts.net:8420":true},"Foreground":false}'
$unsupported = '{"Web":{},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false,"FutureMode":{"enabled":true}}'
$foreground = '{"Web":{},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":true}'
foreach ($fixture in @(
    [pscustomobject]@{ Json = $routeCollision; Name = 'route collision' }
    [pscustomobject]@{ Json = $pathCollision; Name = 'path collision' }
    [pscustomobject]@{ Json = $tcpCollision; Name = 'TCP port collision' }
    [pscustomobject]@{ Json = $serviceCollision; Name = 'service endpoint collision' }
    [pscustomobject]@{ Json = $rangeCollision; Name = 'Web port range collision' }
    [pscustomobject]@{ Json = $ambiguous; Name = 'ambiguous Web endpoint' }
    [pscustomobject]@{ Json = $funnel; Name = 'public tunnel flag' }
    [pscustomobject]@{ Json = $unsupported; Name = 'unsupported state' }
    [pscustomobject]@{ Json = $foreground; Name = 'foreground state' }
)) {
    Assert-BehaviorThrows { Get-TailscaleServeDecision $fixture.Json } $fixture.Name
}

$fixtureToken = ('t' * 32) -join ''
$tokenRoot = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-edge-token-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tokenRoot -Force | Out-Null
try {
    $presentToken = Join-Path $tokenRoot 'tailscale-edge.token'
    [IO.File]::WriteAllBytes($presentToken, [Text.Encoding]::ASCII.GetBytes($fixtureToken))
    Assert-TailscaleEdgeTokenBytes $presentToken
    $missingToken = Join-Path $tokenRoot 'missing.token'
    Assert-BehaviorThrowsSafe {
        Assert-TailscaleEdgeTokenSource -Path $missingToken -ExpectedPath $missingToken -OperatorSid 'S-1-5-21-1-2-3-4'
    } 'LIFEOS_TAILSCALE_EDGE_TOKEN source file is missing' $fixtureToken
    $invalidToken = Join-Path $tokenRoot 'invalid.token'
    [IO.File]::WriteAllBytes($invalidToken, [Text.Encoding]::ASCII.GetBytes((('i' * 31) -join '') + "`n"))
    # Windows may update the newly-created temp directory metadata after the
    # first handle-based read. Let that filesystem transition settle so the
    # assertion reaches the invalid-byte branch rather than a correct,
    # transient stability rejection.
    Start-Sleep -Milliseconds 100
    $stableInvalidToken = $false
    for ($attempt = 0; $attempt -lt 5 -and -not $stableInvalidToken; $attempt++) {
        try {
            $null = Read-LifeOSCappedFileBytes -Path $invalidToken -MaxBytes 256 -Description 'invalid token fixture'
            $stableInvalidToken = $true
        } catch { Start-Sleep -Milliseconds 100 }
    }
    Assert-Behavior $stableInvalidToken 'invalid token fixture becomes readable before its content diagnostic is asserted.'
    Assert-BehaviorThrowsSafe { Assert-TailscaleEdgeTokenBytes $invalidToken } 'LIFEOS_TAILSCALE_EDGE_TOKEN source is invalid' $fixtureToken
} finally {
    Remove-Item -LiteralPath $tokenRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-deploy-behavior-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$fakeTailscale = Join-Path $tempRoot 'fake-tailscale.ps1'
$statePath = Join-Path $tempRoot 'serve-state.json'
$fakeScript = @'
param()
$Arguments = @($args | ForEach-Object { [string]$_ })
$statePath = $env:LIFEOS_BEHAVIOR_STATE_PATH
[void]($state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json)
if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'serve' -and $Arguments[1] -eq 'status') {
    Write-Output (Get-Content -LiteralPath $statePath -Raw)
    exit 0
}
if ($Arguments.Count -ge 2 -and $Arguments[0] -eq 'status' -and $Arguments[1] -eq '--json') {
    Write-Output $env:LIFEOS_BEHAVIOR_IDENTITY_JSON
    exit 0
}
if ($Arguments -contains '--https=8420' -and $Arguments -contains 'off') {
    if ($Arguments -notcontains '--accept-app-caps=lifeos.example/trusted-edge') { throw 'targeted rollback omitted the LifeOS app capability.' }
    if ($null -ne $state.PSObject.Properties['Web'] -and $state.Web -is [System.Management.Automation.PSCustomObject]) {
        [void]$state.Web.PSObject.Properties.Remove('https://node.example.ts.net:8420')
        if (@($state.Web.PSObject.Properties).Count -eq 0) { [void]$state.PSObject.Properties.Remove('Web') }
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 20 -Compress))
    return
}
if ($Arguments -contains '--https=8420') {
    if ($Arguments -notcontains '--accept-app-caps=lifeos.example/trusted-edge') { throw 'additive Serve configuration omitted the LifeOS app capability.' }
    if ($null -eq $state.PSObject.Properties['Web']) { [void]($state | Add-Member -NotePropertyName Web -NotePropertyValue ([pscustomobject]@{})) }
    [void]($state.Web | Add-Member -NotePropertyName 'https://node.example.ts.net:8420' -NotePropertyValue ([pscustomobject]@{ Handlers = [pscustomobject]@{ '/' = [pscustomobject]@{ Proxy = 'http://127.0.0.1:8421'; AcceptAppCaps = @('lifeos.example/trusted-edge') } } }))
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 20 -Compress))
    return
}
throw 'unexpected fake Tailscale invocation'
'@
[IO.File]::WriteAllText($fakeTailscale, $fakeScript, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($statePath, $unrelated, [Text.UTF8Encoding]::new($false))
$fixtureDnsName = 'node.example.ts.net'
$fixtureLogin = 'operator@example.com'
$fixtureIdentity = '{"Self":{"DNSName":"node.example.ts.net.","UserID":"1001","TailscaleIPs":["100.64.0.1"]},"User":{"1001":{"LoginName":"operator@example.com"}}}'
$previousStatePath = $env:LIFEOS_BEHAVIOR_STATE_PATH
$previousIdentityJson = $env:LIFEOS_BEHAVIOR_IDENTITY_JSON
try {
    $env:LIFEOS_BEHAVIOR_STATE_PATH = $statePath
    $configured = Configure-TailscaleServe $fakeTailscale
    Assert-Behavior ((Get-TailscaleServeDecision $configured).Action -eq 'AlreadyConfigured') 'fixture Configure adds the LifeOS route.'
    Assert-Behavior ((Get-TailscaleServeFingerprint $configured -ExcludeLifeOSRoute) -eq (Get-TailscaleServeFingerprint $unrelated -ExcludeLifeOSRoute)) 'fixture Configure preserves unrelated routes.'
    Restore-TailscaleServeSnapshot -TailscaleExecutable $fakeTailscale -Json $unrelated -ExpectedAfterJson $configured | Out-Null
    $restored = Get-TailscaleStatusJson $fakeTailscale
    Assert-Behavior ((Get-TailscaleServeDecision $restored).Action -eq 'Add') 'fixture rollback removes only the LifeOS route.'
    Assert-Behavior ((Get-TailscaleServeFingerprint $restored -ExcludeLifeOSRoute) -eq (Get-TailscaleServeFingerprint $unrelated -ExcludeLifeOSRoute)) 'fixture rollback preserves unrelated routes.'

    [IO.File]::WriteAllText($statePath, $configured, [Text.UTF8Encoding]::new($false))
    $changed = $configured | ConvertFrom-Json
    $changed.Web.PSObject.Properties['https://node.example.ts.net:443'].Value.Handlers.'/'.Proxy = 'http://127.0.0.1:3001'
    [IO.File]::WriteAllText($statePath, ($changed | ConvertTo-Json -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
    Assert-BehaviorThrows { Restore-TailscaleServeSnapshot -TailscaleExecutable $fakeTailscale -Json $unrelated -ExpectedAfterJson $configured } 'concurrent unrelated Serve change'
    [IO.File]::WriteAllText($statePath, $configured, [Text.UTF8Encoding]::new($false))
    Assert-BehaviorThrows { Restore-TailscaleServeSnapshot -TailscaleExecutable $fakeTailscale -Json $unrelated } 'missing post-install Serve snapshot'

    # The gateway service account cannot query Tailscale, so the SYSTEM writer
    # and the launcher's reader must agree on one exact file. Drive the real
    # writer against the fake and assert the installer-side validation half.
    # Registering the task itself needs Windows and is exercised on the host.
    $env:LIFEOS_BEHAVIOR_IDENTITY_JSON = $fixtureIdentity
    [IO.File]::WriteAllText($statePath, $configured, [Text.UTF8Encoding]::new($false))
    $snapshotWriter = Join-Path $deploy 'tailscale_snapshot.ps1'
    Assert-ExistingFile $snapshotWriter 'Tailscale snapshot script'
    $snapshotFile = Join-Path $tempRoot 'tailscale-state.json'
    Invoke-NativeChecked -FilePath $snapshotWriter -ArgumentList ([string[]]@('-TailscaleExecutable', $fakeTailscale, '-OutputPath', $snapshotFile)) -Quiet | Out-Null
    $identityFacts = Get-TailscaleIdentityFacts $fakeTailscale
    Assert-Behavior ($identityFacts.DnsName -ceq $fixtureDnsName) 'the installer derives the node DNS name from its own Tailscale query.'
    Assert-Behavior ($identityFacts.LoginName -ceq $fixtureLogin) 'the installer derives the node login from its own Tailscale query.'
    Assert-TailscaleSnapshotFile -Path $snapshotFile -ExpectedDnsName $fixtureDnsName -ExpectedLoginName $fixtureLogin
    $writtenSnapshot = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
    Assert-Behavior ((@($writtenSnapshot.identity.Self.PSObject.Properties | ForEach-Object { [string]$_.Name }) -join ',') -ceq 'DNSName') 'the snapshot publishes only the consumed identity field, never the tailnet topology.'
    Assert-BehaviorThrows { Assert-TailscaleSnapshotFile -Path $snapshotFile -ExpectedDnsName $fixtureDnsName -ExpectedLoginName 'someone-else@example.com' } 'snapshot login mismatch'
    Assert-BehaviorThrows { Assert-TailscaleSnapshotFile -Path $snapshotFile -ExpectedDnsName 'other.example.ts.net' -ExpectedLoginName $fixtureLogin } 'snapshot DNS mismatch'
    Assert-BehaviorThrows { Assert-TailscaleSnapshotFile -Path $snapshotFile -ExpectedDnsName $fixtureDnsName -ExpectedLoginName $fixtureLogin -MaxAgeSeconds 0 -MaxFutureSeconds 0 } 'stale snapshot'
    $tamperedFile = Join-Path $tempRoot 'tampered-state.json'
    $tampered = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
    [void]($tampered | Add-Member -NotePropertyName 'extraField' -NotePropertyValue $true)
    [IO.File]::WriteAllText($tamperedFile, ($tampered | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Assert-BehaviorThrows { Assert-TailscaleSnapshotFile -Path $tamperedFile -ExpectedDnsName $fixtureDnsName -ExpectedLoginName $fixtureLogin } 'snapshot with an unexpected field'
    [IO.File]::WriteAllText($statePath, $unrelated, [Text.UTF8Encoding]::new($false))
    $noRouteFile = Join-Path $tempRoot 'no-route-state.json'
    Invoke-NativeChecked -FilePath $snapshotWriter -ArgumentList ([string[]]@('-TailscaleExecutable', $fakeTailscale, '-OutputPath', $noRouteFile)) -Quiet | Out-Null
    Assert-BehaviorThrows { Assert-TailscaleSnapshotFile -Path $noRouteFile -ExpectedDnsName $fixtureDnsName -ExpectedLoginName $fixtureLogin } 'snapshot without the private Serve mapping'

    # tailscaled still starting reports BackendState NoState and no Self at
    # all. Under Set-StrictMode an unguarded property read would crash with
    # PropertyNotFoundException; both validators must refuse cleanly and
    # publish nothing.
    [IO.File]::WriteAllText($statePath, $configured, [Text.UTF8Encoding]::new($false))
    $env:LIFEOS_BEHAVIOR_IDENTITY_JSON = '{"BackendState":"NoState","Version":"1.0"}'
    $noSelfFile = Join-Path $tempRoot 'no-self-state.json'
    Assert-BehaviorThrows { Invoke-NativeChecked -FilePath $snapshotWriter -ArgumentList ([string[]]@('-TailscaleExecutable', $fakeTailscale, '-OutputPath', $noSelfFile)) -Quiet } 'a Tailscale status carrying no Self node'
    Assert-Behavior (-not (Test-Path -LiteralPath $noSelfFile)) 'a Tailscale status without Self publishes no snapshot file.'
    Assert-BehaviorThrows { Get-TailscaleIdentityFacts $fakeTailscale } 'installer identity derivation without a Self node'

    # In .NET `$` also matches immediately before a trailing newline, so a
    # login carrying one used to pass both PowerShell validators and then be
    # rejected by the reader's re.fullmatch after cutover.
    $env:LIFEOS_BEHAVIOR_IDENTITY_JSON = '{"Self":{"DNSName":"node.example.ts.net.","UserID":"1001"},"User":{"1001":{"LoginName":"operator@example.com\n"}}}'
    Assert-BehaviorThrows { Get-TailscaleIdentityFacts $fakeTailscale } 'a node login with a trailing newline'
    $newlineFile = Join-Path $tempRoot 'newline-login-state.json'
    Assert-BehaviorThrows { Invoke-NativeChecked -FilePath $snapshotWriter -ArgumentList ([string[]]@('-TailscaleExecutable', $fakeTailscale, '-OutputPath', $newlineFile)) -Quiet } 'a node login with a trailing newline reaching the snapshot'
    Assert-Behavior (-not (Test-Path -LiteralPath $newlineFile)) 'a login with a trailing newline is never published.'

    # The launcher compares schemaVersion against the JSON number 1, so this
    # mirror must reject the string "1" instead of coercing it to 1.
    $stringVersionFile = Join-Path $tempRoot 'string-version-state.json'
    $stringVersion = Get-Content -LiteralPath $snapshotFile -Raw | ConvertFrom-Json
    $stringVersion.schemaVersion = '1'
    [IO.File]::WriteAllText($stringVersionFile, ($stringVersion | ConvertTo-Json -Depth 20), [Text.UTF8Encoding]::new($false))
    Assert-BehaviorThrows { Assert-TailscaleSnapshotFile -Path $stringVersionFile -ExpectedDnsName $fixtureDnsName -ExpectedLoginName $fixtureLogin } 'a snapshot whose schemaVersion is the string "1"'
} finally {
    if ($null -eq $previousStatePath) { Remove-Item Env:LIFEOS_BEHAVIOR_STATE_PATH -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_BEHAVIOR_STATE_PATH = $previousStatePath }
    if ($null -eq $previousIdentityJson) { Remove-Item Env:LIFEOS_BEHAVIOR_IDENTITY_JSON -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_BEHAVIOR_IDENTITY_JSON = $previousIdentityJson }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: deployment behavioral assertions'


& {
    function Get-InteractiveOperatorSid { return 'S-1-5-21-1-2-3-4' }
    function Get-FullPath { param($Path) return $Path }
    $manifest = [pscustomobject]@{ transactionId='11111111-1111-1111-1111-111111111111'; generation='22222222-2222-2222-2222-222222222222'; operatorSid='S-1-5-21-1-2-3-4'; manifestPath='D:\backup\manifest.json' }
    $marker = $manifest | ConvertTo-Json | ConvertFrom-Json
    Set-JournalProperty $marker 'state' 'active'
    Assert-RecoveryIdentity $marker $manifest $manifest.manifestPath
    foreach ($property in @('transactionId', 'generation', 'operatorSid', 'manifestPath')) {
        $changed = $manifest | ConvertTo-Json | ConvertFrom-Json
        $changed.$property = 'unrelated'
        Assert-BehaviorThrows { Assert-RecoveryIdentity $marker $changed $manifest.manifestPath } "marker ownership rejects $property"
    }
    Set-JournalProperty $marker 'updatedAtUtc' 'diagnostic-preserved'
    Set-JournalProperty $marker 'state' 'recovery_required'
    Assert-Behavior ($marker.updatedAtUtc -eq 'diagnostic-preserved') 'marker updates add properties under StrictMode.'
    $marker.state = 'recovered'
    Assert-BehaviorThrows { Assert-RecoveryIdentity $marker $manifest $manifest.manifestPath } 'older completed recovery cannot be reused'
}
Assert-Behavior ((Get-AuthorityInstallMode @() @() @() $false $false) -eq 'fresh') 'empty authority is fresh.'
Assert-Behavior ((Get-AuthorityInstallMode @() @('calendar.json') @() $false $false) -eq 'legacy') 'legacy-only authority is imported.'
Assert-BehaviorThrows { Get-AuthorityInstallMode @('calendar.json') @('documents.json') @() $false $true } 'one leftover never suppresses unrelated migration'
Assert-BehaviorThrows { Get-AuthorityInstallMode @('calendar.json') @() @('calendar.json', 'calendar.json.state.json') $true $true } 'partial versioned authority is rejected'
Assert-BehaviorThrows { Get-AuthorityInstallMode @() @() @('calendar.json') $true $true } 'missing versioned authority is rejected'
Assert-Behavior ((Get-AuthorityInstallMode @('calendar.json') @() @('calendar.json') $true $true) -eq 'upgrade') 'complete versioned authority upgrades.'
Assert-Behavior ((Get-AuthorityInstallMode @('calendar.json') @() @('calendar.json') $true $false) -eq 'repair') 'complete authority without code is repair.'
Assert-Behavior ((Get-AuthorityInstallMode @('calendar.json', 'enablebanking-runtime.json') @() @('calendar.json') $true $true -SupportedEvolution @('enablebanking-runtime.json')) -eq 'upgrade') 'supported authority sidecar evolution is accepted.'
Assert-BehaviorThrows { Get-AuthorityInstallMode @('calendar.json', 'unknown-sidecar.json') @() @('calendar.json') $true $true -SupportedEvolution @('enablebanking-runtime.json') } 'unknown authority sidecar evolution is rejected'
Assert-Behavior ((Get-AuthorityInstallMode @('calendar.json', 'finance-imported.json') @() @('calendar.json') $true $true) -eq 'upgrade') 'gateway-created imported finance state is accepted by the default evolution policy.'
Assert-BehaviorThrows { Get-AuthorityInstallMode @('calendar.json', 'finance-imported.json') @() @('calendar.json') $true $true -SupportedEvolution @('enablebanking-runtime.json') } 'unlisted gateway-owned authority evolution is rejected'
Assert-Behavior (-not (Test-AuthorityRecoveryBaseline ([pscustomobject]@{ phase='pending' }))) 'an early recovered transaction has no usable authority baseline.'
Assert-Behavior (Test-AuthorityRecoveryBaseline ([pscustomobject]@{ phase='complete'; beforeTree=@([pscustomobject]@{ path='gatewayData' }); afterTree=@([pscustomobject]@{ path='gatewayData' }) })) 'a complete recovered authority baseline is recognized.'
Assert-Behavior ($null -eq (Get-LifeOSPreviousInstalledGeneration -MarkerState '' -OperatorSid 'fixture')) 'fresh install with no deployment marker takes the no-marker call path.'
Assert-Behavior ($null -eq (Get-LifeOSPreviousInstalledGeneration -OperatorSid 'fixture')) 'omitted marker state is an explicit empty optional value.'
Assert-BehaviorThrows { Get-LifeOSPreviousInstalledGeneration -MarkerState 'active' -OperatorSid 'fixture' } 'non-empty invalid marker state remains strict.'

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-generation-reference-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $manifestPath = Join-Path $temp 'installed.json'
    $recoveredPath = Join-Path $temp 'recovered.json'
    $manifest = [pscustomobject]@{
        schemaVersion = 2; generation = '11111111-1111-1111-1111-111111111111'; operatorSid = 'fixture'; manifestPath = $manifestPath; backups = @()
    }
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath
    function Get-FullPath { param($Path) return $Path }
    function Assert-ExistingFile { param($Path, $Name) }
    function Assert-CanonicalRollbackManifest { param($Manifest, $ManifestPath, [switch]$AllowPending) }
    function Get-FileSha256 { param($Path) return ('a' * 64) }
    try {
        $constructorReference = New-LifeOSGenerationReference $manifest $manifestPath
        Assert-Behavior ($constructorReference -is [System.Collections.IDictionary]) 'generation reference constructor returns its owned dictionary representation.'
        Assert-LifeOSGenerationReference $constructorReference
        $installed = Get-LifeOSPreviousInstalledGeneration -MarkerState 'installed' -ManifestPath $manifestPath -OperatorSid 'fixture' -ExpectedGeneration $manifest.generation
        Assert-Behavior ($installed.Reference -is [System.Collections.IDictionary]) 'normal upgrade binds the constructor dictionary output.'
        $resolved = Resolve-LifeOSGenerationReference $constructorReference 'fixture'
        Assert-Behavior ($resolved.Manifest.generation -eq $manifest.generation -and $resolved.Reference -is [System.Collections.IDictionary]) 'recovery binds the constructor dictionary output.'
        $recovered = [pscustomobject]@{
            schemaVersion = 2; generation = '22222222-2222-2222-2222-222222222222'; operatorSid = 'fixture'; manifestPath = $recoveredPath
            priorInstalledGeneration = $constructorReference; backups = @()
        }
        $recovered | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recoveredPath
        $recoveredResult = Get-LifeOSPreviousInstalledGeneration -MarkerState 'recovered' -ManifestPath $recoveredPath -OperatorSid 'fixture' -ExpectedGeneration $recovered.generation
        Assert-Behavior ($recoveredResult.InstalledManifest.generation -eq $manifest.generation) 'recovered upgrade resolves a serialized constructor reference.'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-recovered-upgrade-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $priorPath = Join-Path $temp 'prior.json'
    $recoveredPath = Join-Path $temp 'recovered.json'
    $prior = [pscustomobject]@{
        schemaVersion = 2; generation = '11111111-1111-1111-1111-111111111111'; operatorSid = 'fixture'; manifestPath = $priorPath
        installMode = 'upgrade'
        backups = @([pscustomobject]@{ kind = 'authority-set'; phase = 'complete'; beforeTree = @([pscustomobject]@{ path = 'calendar.json' }); afterTree = @([pscustomobject]@{ path = 'calendar.json' }) })
    }
    $reference = [pscustomobject]@{ manifestPath = $priorPath; generation = $prior.generation; manifestSha256 = ('a' * 64) }
    $recovered = [pscustomobject]@{
        schemaVersion = 2; generation = '22222222-2222-2222-2222-222222222222'; operatorSid = 'fixture'; manifestPath = $recoveredPath
        priorInstalledGeneration = $reference; backups = @()
    }
    $prior | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $priorPath
    $recovered | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $recoveredPath
    function Get-FullPath { param($Path) return $Path }
    function Assert-ExistingFile { param($Path, $Name) }
    function Assert-CanonicalRollbackManifest { param($Manifest, $ManifestPath, [switch]$AllowPending) }
    function Get-FileSha256 { param($Path) return ('a' * 64) }
    try {
        $nextInstallReference = Get-LifeOSPreviousInstalledGeneration -MarkerState 'recovered' -ManifestPath $recoveredPath -OperatorSid 'fixture' -ExpectedGeneration ([string]$recovered.generation)
        Assert-Behavior ($nextInstallReference.Manifest.backups.Count -eq 0) 'recovered upgrade manifest may have no authority record.'
        Assert-Behavior ($nextInstallReference.InstalledManifest.generation -eq $prior.generation) 'recovered upgrade keeps the authenticated prior generation.'
        $expected = @($nextInstallReference.InstalledManifest.backups[0].afterTree | ForEach-Object { $_.path })
        Assert-Behavior ((Get-AuthorityInstallMode @('calendar.json') @() $expected $true $true) -eq 'upgrade') 'recovered upgrade carries its authority to the next install.'
        Assert-BehaviorThrows { Get-LifeOSPreviousInstalledGeneration -MarkerState 'recovered' -ManifestPath $recoveredPath -OperatorSid 'fixture' -ExpectedGeneration ([string]$prior.generation) } 'recovered marker generation mismatch is rejected'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    # Dot-source the actual installer in definition-only mode. The Windows job
    # can then execute the same intent and transaction functions with only
    # file/ACL boundaries substituted.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-output-contract-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $installPath = Join-Path $deploy 'install.ps1'
    $script:outputContractMarkerPath = Join-Path $temp $script:LifeOSDeploymentMarkerName
    try {
        . $installPath -DefineOnly
        function Get-LifeOSDeploymentMarkerPath { return $script:outputContractMarkerPath }
        function Get-InteractiveOperatorSid { return 'S-1-5-21-1-2-3-1001' }
        function Assert-NoReparsePath { param($Path, [switch]$AllowMissingLeaf) }
        function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
        function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl) }
        $manifestPath = Join-Path $temp 'manifest.json'
        $manifest = [ordered]@{
            schemaVersion = 2; transactionId = '11111111-1111-1111-1111-111111111111'; generation = 'generation'; operatorSid = 'S-1-5-21-1-2-3-1001'; manifestPath = $manifestPath
            paths = [ordered]@{ backupDirectory = $temp }; backups = (New-Object System.Collections.ArrayList); aclSnapshots = @()
        }
        $intentResult = @(New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifestPath -Kind 'fixture' -Source (Join-Path $temp 'source') -Destination (Join-Path $temp 'destination') -Backup (Join-Path $temp 'backup') -PriorExists $true -Changed $true)
        Assert-Behavior ($intentResult.Count -eq 1 -and $intentResult[0] -is [System.Collections.IDictionary] -and $intentResult[0].kind -eq 'fixture') 'manifest intent creation returns exactly one owned dictionary.'

        $marker = [ordered]@{
            schemaVersion = 2; state = 'active'; transactionId = $manifest.transactionId; generation = $manifest.generation; operatorSid = $manifest.operatorSid
            manifestPath = $manifestPath; acquiredAtUtc = (Get-Date).ToUniversalTime().ToString('o'); updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        [IO.File]::WriteAllText($script:outputContractMarkerPath, ($marker | ConvertTo-Json -Depth 20))
        $recoveryResult = @(Enter-LifeOSDeploymentTransaction -AllowRecovery -RecoveryManifest $manifest -RecoveryManifestPath $manifestPath)
        Assert-Behavior ($recoveryResult.Count -eq 1 -and $recoveryResult[0] -is [pscustomobject] -and $recoveryResult[0].Recovery -eq $true) 'recovery acquisition returns exactly one typed transaction object.'
        Exit-LifeOSDeploymentTransaction $recoveryResult[0]
    } finally {
        Remove-Variable -Name outputContractMarkerPath -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    # Parse the actual installer in definition-only mode and stage the same
    # bounded gateway release helper used by installation. This catches a
    # PowerShell 5.1 parse regression where -MaxBytes was attached to the
    # bundleFiles array expression instead of the JSON writer call.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-gateway-bundle-' + [Guid]::NewGuid().ToString('N'))
    $gatewaySource = Join-Path $temp 'gateway-source'
    $gatewayDestination = Join-Path $temp 'gateway-stage'
    $backupDirectory = Join-Path $temp 'backup'
    Ensure-Directory $gatewaySource; Ensure-Directory $backupDirectory
    try {
        foreach ($name in @('main.py', 'gateway_launcher.py', 'enablebanking.py', 'supplement_catalog.py', 'supplement_catalog_schema.sql', 'supplement_catalog_seed.sql')) {
            [IO.File]::WriteAllText((Join-Path $gatewaySource $name), "fixture-$name")
        }
        . (Join-Path $deploy 'install.ps1') -DefineOnly -GatewaySource $gatewaySource
        $stage = Copy-GatewayCodeBundle -GatewaySource $gatewaySource -GatewayEntryPoint (Join-Path $gatewaySource 'main.py') -Destination $gatewayDestination -LauncherSource (Join-Path $gatewaySource 'gateway_launcher.py') -BackupDirectory $backupDirectory
        $releaseManifest = Read-LifeOSBoundedJsonFile -Path (Join-Path $gatewayDestination 'gateway-release.manifest.json') -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'gateway bundle fixture manifest'
        $bundleFiles = @($releaseManifest.bundleFiles)
        $bundleNames = @($bundleFiles | ForEach-Object { [string]$_.path })
        $expectedBundleNames = @('main.py', 'gateway_launcher.py', 'enablebanking.py', 'supplement_catalog.py', 'supplement_catalog_schema.sql', 'supplement_catalog_seed.sql')
        $missingBundleNames = @($expectedBundleNames | Where-Object { $_ -notin $bundleNames })
        Assert-Behavior ($stage.Changed -and [string]$releaseManifest.bundleVersion -ceq 'v18' -and $bundleFiles.Count -eq 6 -and
            $missingBundleNames.Count -eq 0) 'the parsed gateway bundle helper stages every file and publishes a bounded v18 manifest.'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$emptyServiceArguments = Get-LifeOSServiceConfigArguments -Name 'LifeOSAPI' -BinaryPath '"D:\host.exe"' -StartName 'NT SERVICE\LifeOSAPI' -StartMode 'auto' -Dependencies @()
Assert-Behavior ($emptyServiceArguments[6] -ceq 'password=' -and $emptyServiceArguments[7] -ceq '""' -and
    $emptyServiceArguments[10] -ceq 'depend=' -and $emptyServiceArguments[11] -ceq '/') 'empty service values retain explicit native argv slots.'
$populatedServiceArguments = Get-LifeOSServiceConfigArguments -Name 'LifeOSGateway' -BinaryPath '"D:\host.exe"' -StartName 'NT SERVICE\LifeOSGateway' -StartMode 'delayed-auto' -Dependencies @('LifeOSAPI', 'Schedule')
Assert-Behavior ($populatedServiceArguments[7] -ceq '""' -and $populatedServiceArguments[11] -ceq 'LifeOSAPI/Schedule') 'populated service dependencies use the shared native encoding.'
Assert-BehaviorThrows { Get-LifeOSServiceConfigArguments -Name 'LifeOSGateway' -BinaryPath '"D:\host.exe"' -StartName 'NT SERVICE\LifeOSGateway' -StartMode 'auto' -Dependencies @('LifeOSAPI', '') } 'empty dependency entries are rejected'

function Copy-BehaviorServiceSnapshot {
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Snapshot)
    $copy = [ordered]@{}
    foreach ($key in $Snapshot.Keys) {
        $value = $Snapshot[$key]
        $copy[$key] = if ($value -is [Array]) { ,([object[]]$value) } else { $value }
    }
    return $copy
}

$presentServiceSnapshot = [ordered]@{ Name='LifeOSGateway'; Exists=$true; State='Stopped'; StartMode='Auto'; StartName='NT SERVICE\LifeOSGateway'; BinaryPath='"D:\host.exe"'; Dependencies=@('LifeOSAPI'); DelayedAutoStartPresent=$false; DelayedAutoStart=$null; ServiceSidTypePresent=$false; ServiceSidType=$null; FailureActionsPresent=$false; FailureActions=@(); FailureFlagPresent=$false; FailureFlag=$null }
Assert-CompleteLifeOSServiceSnapshot $presentServiceSnapshot
Assert-BehaviorThrows { Assert-CompleteLifeOSServiceSnapshot ([pscustomobject]@{ Name='LifeOSGateway'; Exists=$true }) } 'partial existing service snapshots are rejected'
$inconsistentAbsentSnapshot = Copy-BehaviorServiceSnapshot $presentServiceSnapshot
$inconsistentAbsentSnapshot.Name = 'LifeOSAPI'; $inconsistentAbsentSnapshot.Exists = $false; $inconsistentAbsentSnapshot.State = 'Stopped'; $inconsistentAbsentSnapshot.StartMode = 'Disabled'; $inconsistentAbsentSnapshot.StartName = ''; $inconsistentAbsentSnapshot.BinaryPath = $null; $inconsistentAbsentSnapshot.Dependencies = @()
Assert-BehaviorThrows { Assert-CompleteLifeOSServiceSnapshot $inconsistentAbsentSnapshot } 'inconsistent absent service snapshots are rejected'
$apiServiceSnapshot = Copy-BehaviorServiceSnapshot $presentServiceSnapshot
$apiServiceSnapshot.Name = 'LifeOSAPI'; $apiServiceSnapshot.State = 'Running'; $apiServiceSnapshot.StartName = 'NT SERVICE\LifeOSAPI'; $apiServiceSnapshot.Dependencies = @()
$serviceSnapshotMap = [ordered]@{ LifeOSAPI = $apiServiceSnapshot; LifeOSGateway = $presentServiceSnapshot }
$validatedServiceSnapshotMap = Get-LifeOSServiceSnapshotMap $serviceSnapshotMap
Assert-Behavior ($validatedServiceSnapshotMap.Count -eq 2) 'complete service snapshot map is accepted.'
Assert-BehaviorThrows { Get-LifeOSServiceSnapshotMap ([ordered]@{}) } 'empty service snapshot map is rejected'
Assert-BehaviorThrows { Get-LifeOSServiceSnapshotMap ([ordered]@{ LifeOSAPI = $apiServiceSnapshot }) } 'one-entry service snapshot map is rejected'
$mismatchedServiceSnapshotMap = [ordered]@{ LifeOSAPI = $presentServiceSnapshot; LifeOSGateway = $apiServiceSnapshot }
Assert-BehaviorThrows { Get-LifeOSServiceSnapshotMap $mismatchedServiceSnapshotMap } 'mismatched service snapshot key is rejected'
$unknownServiceSnapshotMap = [ordered]@{ LifeOSAPI = $apiServiceSnapshot; LifeOSGateway = $presentServiceSnapshot; LifeOSUnknown = $presentServiceSnapshot }
Assert-BehaviorThrows { Get-LifeOSServiceSnapshotMap $unknownServiceSnapshotMap } 'unknown service snapshot entries are rejected'
$unknownServiceSnapshotField = Copy-BehaviorServiceSnapshot $presentServiceSnapshot; $unknownServiceSnapshotField['Unexpected'] = 'fixture'
Assert-BehaviorThrows { Assert-CompleteLifeOSServiceSnapshot $unknownServiceSnapshotField } 'unknown service snapshot fields are rejected'

& {
    $script:retryServiceStates = [ordered]@{ LifeOSAPI = 'Running'; LifeOSGateway = 'Stopped' }
    $script:retryStartFailure = $false
    $script:outerRollbackAttempt = 0
    function Get-ServiceRecord { param($Name) return [pscustomobject]@{ State = [string]$script:retryServiceStates[$Name]; StartMode = 'Auto' } }
    function Stop-LifeOSService { param($Name) $script:retryServiceStates[$Name] = 'Stopped' }
    function Start-Service {
        [CmdletBinding()]
        param([string]$Name)
        if (-not $script:retryStartFailure) { $script:retryServiceStates[$Name] = 'Running' }
    }
    function Invoke-OuterRollbackRetryFixture {
        $script:outerRollbackAttempt++
        foreach ($serviceName in @('LifeOSGateway', 'LifeOSAPI')) { Stop-LifeOSService $serviceName }
        if ($script:outerRollbackAttempt -eq 1) { throw 'interrupted outer rollback fixture' }
        # Both service stages are already complete in the recovery journal, so
        # a retry must reconcile live state after the stage no-ops.
        Reconcile-LifeOSServiceSnapshotState $serviceSnapshotMap
        if ($script:retryServiceStates['LifeOSAPI'] -ne 'Running') { throw 'rollback success with running service stopped' }
    }
    Assert-BehaviorThrows { Invoke-OuterRollbackRetryFixture } 'interrupted outer rollback retry fixture'
    $script:retryStartFailure = $true
    Assert-BehaviorThrows { Reconcile-LifeOSServiceSnapshotState $serviceSnapshotMap } 'rollback never reports success with a running service stopped'
    $script:retryStartFailure = $false
    Invoke-OuterRollbackRetryFixture
    Assert-Behavior ($script:retryServiceStates['LifeOSAPI'] -eq 'Running' -and $script:retryServiceStates['LifeOSGateway'] -eq 'Stopped') 'interrupted outer rollback retry restores running services.'
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-service-orchestration-' + [Guid]::NewGuid().ToString('N'))
    $data = Join-Path $temp 'data'; $backup = Join-Path $temp 'backup'
    Ensure-Directory $data; Ensure-Directory $backup
    $destination = Join-Path $data 'stable.json'; [IO.File]::WriteAllText($destination, 'stable')
    $gatewayRunningSnapshot = Copy-BehaviorServiceSnapshot $presentServiceSnapshot
    $gatewayRunningSnapshot.State = 'Running'
    $serviceRecoveryMap = [ordered]@{ LifeOSAPI = $apiServiceSnapshot; LifeOSGateway = $gatewayRunningSnapshot }
    $script:orchestrationServiceStates = [ordered]@{ LifeOSAPI = 'Running'; LifeOSGateway = 'Running' }
    $script:orchestrationServiceConfiguration = [ordered]@{ LifeOSAPI = 'temporary'; LifeOSGateway = 'temporary' }
    $script:orchestrationServiceEvents = New-Object System.Collections.ArrayList
    $script:orchestrationPhase = 'install'
    $script:orchestrationApiRegistrationFailure = $true
    function Get-ServiceRecord {
        param($Name)
        return [pscustomobject]@{ State = [string]$script:orchestrationServiceStates[$Name]; StartMode = 'Auto'; StartName = ('NT SERVICE\' + $Name); PathName = 'D:\temporary-host.exe' }
    }
    function Stop-LifeOSService { param($Name) [void]$script:orchestrationServiceEvents.Add("stop:$Name"); $script:orchestrationServiceStates[$Name] = 'Stopped' }
    function Restore-LifeOSServiceRegistrySnapshot {
        param($Name, $Snapshot)
        $script:orchestrationServiceConfiguration[$Name] = 'restored'
        [void]$script:orchestrationServiceEvents.Add("registry:$Name")
    }
    function Invoke-NativeChecked {
        [CmdletBinding()]
        param([string]$FilePath, [object[]]$ArgumentList, [switch]$Quiet)
        if ($FilePath -eq 'sc.exe' -and $ArgumentList.Count -ge 2 -and $ArgumentList[0] -eq 'config') {
            $name = [string]$ArgumentList[1]
            $script:orchestrationServiceConfiguration[$name] = if ($script:orchestrationPhase -eq 'install') { 'temporary' } else { 'restored' }
            [void]$script:orchestrationServiceEvents.Add("config:$name")
            if ($script:orchestrationPhase -eq 'recovery' -and $name -eq 'LifeOSAPI' -and $script:orchestrationApiRegistrationFailure) {
                throw 'fixture failed after temporary API service registration'
            }
        }
        return [pscustomobject]@{ Output = @(); ExitCode = 0 }
    }
    function Invoke-InstallerFailureThenRollback {
        New-ServiceOrConfigure -Name 'LifeOSAPI' -BinaryPath 'D:\temporary-host.exe' -StartMode 'auto' -Account 'NT SERVICE\LifeOSAPI' -Dependencies @() -ExpectedExistingBinary 'D:\temporary-host.exe'
        New-ServiceOrConfigure -Name 'LifeOSGateway' -BinaryPath 'D:\temporary-host.exe' -StartMode 'delayed-auto' -Account 'NT SERVICE\LifeOSGateway' -Dependencies @('LifeOSAPI') -ExpectedExistingBinary 'D:\temporary-host.exe'
        try { throw 'installer failed after temporary service registration' } catch {
            $script:orchestrationPhase = 'recovery'
            Restore-LifeOSServiceSnapshots -Snapshots $serviceRecoveryMap -Manifest $recoveryManifest -ContinueOnFailure
        }
    }
    function Start-Service {
        [CmdletBinding()]
        param([string]$Name)
        if ($Name -eq 'LifeOSAPI' -and $script:orchestrationServiceConfiguration['LifeOSAPI'] -ne 'restored') {
            throw 'API attempted to start with temporary configuration.'
        }
        if ($Name -eq 'LifeOSGateway' -and $script:orchestrationServiceConfiguration['LifeOSAPI'] -ne 'restored') {
            throw 'Gateway attempted to start with temporary API configuration.'
        }
        $script:orchestrationServiceStates[$Name] = 'Running'
        [void]$script:orchestrationServiceEvents.Add("start:$Name")
    }
    try {
        $recoveryManifest = [pscustomobject]@{
            transactionId = 'service-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json'); backups = @()
            paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $temp 'usage.jsonl') }
        }
        $stableState = Get-RecoveryArtifactState $destination
        $recoveryJournal = [pscustomobject]@{
            schemaVersion = 1; transactionId = $recoveryManifest.transactionId; generation = $recoveryManifest.generation; operatorSid = $recoveryManifest.operatorSid; manifestPath = $recoveryManifest.manifestPath
            units = @([pscustomobject]@{ destination = $destination; backup = ''; pre = $stableState; post = $stableState; phase = 'complete'; stagingPath = (Join-Path $data '.rollback-restore-service-fixture-0') }); unitCount = 1; treeRoots = @($data); phase = 'artifacts-complete'; progressPath = (Get-RecoveryProgressPath $recoveryManifest)
        }
        function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
        $realJsonWriter = ${function:Write-JsonAtomic}
        function Write-JsonAtomic {
            param([string]$Path, [object]$Value, [string]$OperatorSid, [long]$MaxBytes = 0)
            # This fixture uses a non-SID operator label. Preserve the real
            # durable journal bytes while its ACL adapter remains mocked.
            & $realJsonWriter -Path $Path -Value $Value -MaxBytes $MaxBytes
        }
        Write-JsonAtomic (Get-RecoveryJournalPath $recoveryManifest) $recoveryJournal -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
        Assert-BehaviorThrows { Invoke-InstallerFailureThenRollback } 'actual installer failure after temporary registration enters rollback orchestration.'
        Assert-Behavior (-not (@($script:orchestrationServiceEvents | Where-Object { $_ -like 'start:*' }).Count)) 'recovery restores service configuration without starting either service.'
        Assert-Behavior ($script:orchestrationServiceConfiguration['LifeOSAPI'] -eq 'restored' -and
            $script:orchestrationServiceConfiguration['LifeOSGateway'] -eq 'restored') 'failed temporary API configuration is gone before dependent service reconciliation.'
        $script:orchestrationApiRegistrationFailure = $false
        Restore-LifeOSServiceSnapshots -Snapshots $serviceRecoveryMap -Manifest $recoveryManifest -ContinueOnFailure
        $startEvents = @($script:orchestrationServiceEvents | Where-Object { $_ -like 'start:*' })
        Assert-Behavior ($startEvents.Count -eq 2 -and $startEvents[0] -eq 'start:LifeOSAPI' -and $startEvents[1] -eq 'start:LifeOSGateway') 'actual recovery orchestration starts services in dependency order after configuration restore.'
        $firstStartIndex = -1
        $lastConfigurationIndex = -1
        for ($eventIndex = 0; $eventIndex -lt $script:orchestrationServiceEvents.Count; $eventIndex++) {
            if ($firstStartIndex -lt 0 -and [string]$script:orchestrationServiceEvents[$eventIndex] -like 'start:*') { $firstStartIndex = $eventIndex }
            if ([string]$script:orchestrationServiceEvents[$eventIndex] -like 'config:*') { $lastConfigurationIndex = $eventIndex }
        }
        Assert-Behavior ($firstStartIndex -gt $lastConfigurationIndex) 'actual rollback publishes no service start before the last restored configuration checkpoint.'
    } finally {
        Remove-Variable -Name orchestrationServiceStates -Scope Script
        Remove-Variable -Name orchestrationServiceConfiguration -Scope Script
        Remove-Variable -Name orchestrationServiceEvents -Scope Script
        Remove-Variable -Name orchestrationPhase -Scope Script
        Remove-Variable -Name orchestrationApiRegistrationFailure -Scope Script
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-bounded-json-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $script:boundedJsonParseCalls = 0
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function ConvertFrom-Json {
        [CmdletBinding()]
        param([Parameter(ValueFromPipeline=$true)][object]$InputObject)
        process {
        $script:boundedJsonParseCalls++
        throw 'fixture parser must not run for an oversized bounded JSON file.'
        }
    }
    try {
        foreach ($fixture in @(
            [pscustomobject]@{ Name = 'Deployment marker'; Maximum = [long]$script:LifeOSDeploymentMarkerMaxBytes; File = (Join-Path $temp 'marker.json') }
            [pscustomobject]@{ Name = 'Recovery journal'; Maximum = [long]$script:LifeOSRecoveryJournalMaxBytes; File = (Join-Path $temp 'recovery.json') }
            [pscustomobject]@{ Name = 'Recovery progress log'; Maximum = [long]$script:LifeOSRecoveryProgressMaxBytes; File = (Join-Path $temp 'progress.jsonl') }
            [pscustomobject]@{ Name = 'Generation manifest'; Maximum = [long]$script:LifeOSGenerationManifestMaxBytes; File = (Join-Path $temp 'manifest.json') }
        )) {
            $stream = [IO.File]::Open($fixture.File, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
            try { $stream.SetLength($fixture.Maximum + 1) } finally { $stream.Dispose() }
            Assert-BehaviorThrows { Read-LifeOSBoundedJsonFile -Path $fixture.File -MaxBytes $fixture.Maximum -Description $fixture.Name } "oversized bounded JSON file is rejected: $($fixture.Name)"
        }
        $recoveryManifest = [pscustomobject]@{
            transactionId = 'bounded-journal-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $temp 'manifest.json')
            paths = [pscustomobject]@{ backupDirectory = $temp; gatewayData = (Join-Path $temp 'data'); usageHistory = (Join-Path $temp 'usage.jsonl') }
        }
        Assert-BehaviorThrows { Read-RecoveryJournal $recoveryManifest } 'the recovery journal reader rejects an oversized file before parsing.'
        Assert-Behavior ($script:boundedJsonParseCalls -eq 0) 'oversized bounded JSON files are rejected before parsing.'
    } finally {
        Remove-Variable -Name boundedJsonParseCalls -Scope Script
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    # Exercise the frozen-file and tree identity gates with real filesystem
    # objects. The Windows-only junction fixture is optional on hosts where
    # the account cannot create reparse points; production Windows runs must
    # execute it with the deployment test account's normal privileges.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-frozen-inventory-' + [Guid]::NewGuid().ToString('N'))
    $root = Join-Path $temp 'candidate'; $outside = Join-Path $temp 'outside'
    Ensure-Directory $root; Ensure-Directory $outside
    try {
        $stable = Join-Path $root 'stable.txt'
        [IO.File]::WriteAllText($stable, 'before')
        $stableItem = Get-Item -LiteralPath $stable -Force
        $stableIdentity = New-LifeOSTreeItemIdentity -Item $stableItem -Description 'frozen file fixture'
        [IO.File]::WriteAllText($stable, 'changed-after-inventory')
        Assert-BehaviorThrows { Assert-LifeOSTreeItemIdentity -Path $stable -Expected $stableIdentity -Description 'changed candidate bytes' } 'changed candidate bytes are rejected by identity revalidation.'

        $replacement = Join-Path $root 'replacement.txt'
        $replacementTemp = Join-Path $root 'replacement.tmp'
        [IO.File]::WriteAllText($replacement, 'original')
        $replacementIdentity = New-LifeOSTreeItemIdentity -Item (Get-Item -LiteralPath $replacement -Force) -Description 'replacement fixture'
        $replacementChain = @(Get-LifeOSPathIdentityChain -Path $replacement -Description 'replacement ACL fixture')
        [IO.File]::WriteAllText($replacementTemp, 'new-file')
        Remove-Item -LiteralPath $replacement -Force
        Move-Item -LiteralPath $replacementTemp -Destination $replacement -Force
        Assert-BehaviorThrows { Assert-LifeOSTreeItemIdentity -Path $replacement -Expected $replacementIdentity -Description 'replacement candidate identity' } 'a replaced candidate path is rejected by its frozen identity.'
        $emptyAcl = [Security.AccessControl.FileSecurity]::new()
        Assert-BehaviorThrows {
            Set-LifeOSAclWithBoundHandle -Path $replacement -Acl $emptyAcl -Directory $false -ExpectedChain $replacementChain
        } 'an ACL mutation fails closed when the path is replaced after validation.'

        $bounded = Join-Path $root 'bounded.txt'
        [IO.File]::WriteAllText($bounded, '0123456789')
        Assert-BehaviorThrows { Read-LifeOSCappedFileText -Path $bounded -MaxBytes 4 -Description 'oversized candidate text' } 'a capped whole-file reader rejects growth beyond its bound.'

        $nestedCandidateDirectory = Join-Path $root 'nested\candidate\payload'
        Ensure-Directory $nestedCandidateDirectory
        $nestedCandidate = Join-Path $nestedCandidateDirectory 'SOURCE_SHA.txt'
        [IO.File]::WriteAllText($nestedCandidate, 'stable-source-sha')
        $nestedChain = @(Get-LifeOSPathIdentityChain -Path $nestedCandidate -Description 'nested candidate source SHA')
        Assert-Behavior ($nestedChain.Count -gt 1 -and $nestedChain[0] -isnot [Array] -and
            $nestedChain[$nestedChain.Count - 1].Path -ieq (Get-FullPath $nestedCandidate)) 'nested candidate paths return a flat identity chain with the leaf last.'
        Assert-Behavior ((Read-LifeOSCappedFileText -Path $nestedCandidate -MaxBytes 64 -Description 'nested candidate source SHA') -ceq 'stable-source-sha') 'a stable nested candidate SOURCE_SHA file passes the capped reader.'
        $nestedReplacement = Join-Path $nestedCandidateDirectory 'SOURCE_SHA.replacement'
        [IO.File]::WriteAllText($nestedReplacement, 'replacement-source-sha')
        Remove-Item -LiteralPath $nestedCandidate -Force
        Move-Item -LiteralPath $nestedReplacement -Destination $nestedCandidate -Force
        Assert-BehaviorThrows { Assert-LifeOSPathIdentityChain -Expected $nestedChain -Description 'nested candidate source SHA replacement' } 'an identity/path change on a nested candidate file is rejected.'

        $hardLink = Join-Path $root 'hardlink.txt'
        $hardLinkCreated = $false
        try {
            New-Item -ItemType HardLink -Path $hardLink -Target $stable -ErrorAction Stop | Out-Null
            $hardLinkCreated = $true
        } catch {
            $category = [string]$_.CategoryInfo.Category
            if ($category -notin @('PermissionDenied', 'InvalidOperation', 'NotImplemented', 'NotSupported')) { throw }
            Write-Host "SKIP: hardlink fixture unavailable ($category)."
        }
        if ($hardLinkCreated) {
            try {
                @(Get-LifeOSBoundedTreeItem -Root $root) | Out-Null
                Assert-Behavior $true 'bounded inventory accepts a provider-reported hardlink when LinkType is HardLink.'
            } finally {
                Remove-Item -LiteralPath $hardLink -Force -ErrorAction SilentlyContinue
            }
        }

        $junction = Join-Path $root 'junction'
        $junctionCreated = $false
        try {
            New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop | Out-Null
            $junctionCreated = $true
        } catch {
            Write-Warning 'SKIP: account could not create the Windows junction fixture for bounded inventory testing.'
        }
        if ($junctionCreated) {
            Assert-BehaviorThrows { @(Get-LifeOSBoundedTreeItem -Root $root) } 'bounded inventory rejects a junction before descent.'
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    # Keep the two larger allowances scoped to the exact reviewed candidate
    # paths. Use small fixture limits so candidate enumeration, manifest hash,
    # atomic copy, and recovery boundaries are exercised without allocating
    # 64/256 MiB on the deployment test host.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-file-limit-contract-' + [Guid]::NewGuid().ToString('N'))
    $candidate = Join-Path $temp 'candidate'
    $nodeDirectory = Join-Path $candidate 'node-runtime'
    $hostDirectory = Join-Path $candidate 'service-host'
    $copyBackup = Join-Path $temp 'copy-backup'
    Ensure-Directory $nodeDirectory; Ensure-Directory $hostDirectory; Ensure-Directory $copyBackup
    try {
        $node = Join-Path $nodeDirectory 'node.exe'
        $candidateHost = Join-Path $hostDirectory 'LifeOS.ServiceHost.exe'
        [IO.File]::WriteAllBytes($node, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
        [IO.File]::WriteAllBytes($candidateHost, [byte[]]@(8, 7, 6, 5, 4, 3, 2, 1))
        $contracts = [ordered]@{
            'node-runtime/node.exe' = 8
            'service-host/LifeOS.ServiceHost.exe' = 8
        }
        $candidateItems = @(Get-LifeOSBoundedTreeItem -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 16 -MaxFileBytes 4 -LargeFileContracts $contracts)
        Assert-Behavior ($candidateItems.Count -eq 4) 'the exact candidate Node and service-host paths may use their scoped larger bounds.'
        $candidateIndex = Get-TreeManifestIndex -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 16 -MaxFileBytes 4 -LargeFileContracts $contracts
        $serviceHostEntries = @($candidateIndex.Entries | Where-Object {
            ([string]$_.path).Replace('\', '/') -ceq 'service-host/LifeOS.ServiceHost.exe'
        })
        Assert-Behavior ($candidateIndex.FileCount -eq 2 -and $serviceHostEntries.Count -eq 1) 'the exact contract map reaches manifest hashing.'
        $copyDestination = Join-Path $temp 'copied-candidate'
        $oldCopyMax = $script:LifeOSRecoveryMaxFileBytes
        $script:LifeOSRecoveryMaxFileBytes = 4
        try {
            $copyResult = Copy-TreeVerifiedAtomic -Source $candidate -Destination $copyDestination -BackupDirectory $copyBackup -LargeFileContracts $contracts
        } finally { $script:LifeOSRecoveryMaxFileBytes = $oldCopyMax }
        Assert-Behavior ($copyResult.Changed -and (Get-Item -LiteralPath (Join-Path (Join-Path $copyDestination 'service-host') 'LifeOS.ServiceHost.exe')).Length -eq 8) 'the exact contract map reaches atomic tree copy and post-copy hashing.'
        [IO.File]::WriteAllBytes($node, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8, 9))
        Assert-BehaviorThrows {
            @(Get-LifeOSBoundedTreeItem -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 17 -MaxFileBytes 4 -LargeFileContracts $contracts)
        } 'the scoped Node exception still rejects a file above its larger bound.'
        [IO.File]::WriteAllBytes($node, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8))
        [IO.File]::WriteAllBytes($candidateHost, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8, 9))
        Assert-BehaviorThrows {
            @(Get-LifeOSBoundedTreeItem -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 17 -MaxFileBytes 4 -LargeFileContracts $contracts)
        } 'the scoped service-host exception still rejects a file above its larger bound.'
        [IO.File]::WriteAllBytes($candidateHost, [byte[]]@(8, 7, 6, 5, 4, 3, 2, 1))

        $other = Join-Path $candidate 'other.bin'
        [IO.File]::WriteAllBytes($other, [byte[]]@(1, 2, 3, 4))
        $generalBoundaryItems = @(Get-LifeOSBoundedTreeItem -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 20 -MaxFileBytes 4 -LargeFileContracts $contracts)
        Assert-Behavior ($generalBoundaryItems.Count -eq 5) 'an ordinary file at the general boundary remains accepted.'
        [IO.File]::WriteAllBytes($other, [byte[]]@(1, 2, 3, 4))
        $misleadingDirectory = Join-Path $candidate 'other-service-host'
        Ensure-Directory $misleadingDirectory
        $misleadingHost = Join-Path $misleadingDirectory 'LifeOS.ServiceHost.exe'
        [IO.File]::WriteAllBytes($misleadingHost, [byte[]]@(1, 2, 3, 4))
        $acceptedMisleadingBasename = $true
        try {
            @(Get-LifeOSBoundedTreeItem -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 24 -MaxFileBytes 4 -LargeFileContracts $contracts) | Out-Null
        } catch { $acceptedMisleadingBasename = $false }
        Assert-Behavior $acceptedMisleadingBasename 'a same-basename service host at the ordinary bound remains readable outside the exact contract path.'
        [IO.File]::WriteAllBytes($misleadingHost, [byte[]]@(1, 2, 3, 4, 5))
        Assert-BehaviorThrows {
            @(Get-LifeOSBoundedTreeItem -Root $candidate -MaxFiles 8 -MaxDirectories 8 -MaxBytes 25 -MaxFileBytes 4 -LargeFileContracts $contracts)
        } 'a same-basename service host outside the exact candidate path remains at the ordinary bound.'

        $oldRecoveryMax = $script:LifeOSRecoveryMaxFileBytes
        $oldHostMax = $script:LifeOSCandidateServiceHostMaxFileBytes
        try {
            $script:LifeOSRecoveryMaxFileBytes = 4
            $script:LifeOSCandidateServiceHostMaxFileBytes = 8
            $hostTarget = Join-Path (Join-Path $temp 'installed-host') 'LifeOS.ServiceHost.exe'
            $hostBackup = Join-Path (Join-Path $temp 'host-backup') 'LifeOS.ServiceHost.exe'
            Ensure-Directory (Split-Path -Parent $hostTarget); Ensure-Directory (Split-Path -Parent $hostBackup)
            [IO.File]::WriteAllBytes($hostTarget, [byte[]]@(9, 9, 9, 9, 9, 9, 9, 9))
            [IO.File]::WriteAllBytes($hostBackup, [byte[]]@(1, 1, 1, 1, 1, 1, 1, 1))
            $nodeTarget = Join-Path (Join-Path $temp 'installed-node') 'node.exe'
            Ensure-Directory (Split-Path -Parent $nodeTarget)
            $recoveryManifest = [pscustomobject]@{
                paths = [pscustomobject]@{ host = $hostTarget; node = (Split-Path -Parent $nodeTarget) }
                backups = @(
                    [pscustomobject]@{ kind = 'host-binary'; destination = $hostTarget; backup = $hostBackup }
                    [pscustomobject]@{ kind = 'node-runtime'; destination = (Split-Path -Parent $nodeTarget); backup = (Join-Path $temp 'node-backup') }
                )
            }
            Assert-Behavior ((Get-LifeOSRecoveryFileMaxBytes $hostTarget -AllowServiceHostBinary -Manifest $recoveryManifest) -eq 8) 'the manifest-bound service host uses the finite host recovery limit.'
            Assert-Behavior ((Get-LifeOSRecoveryFileMaxBytes $nodeTarget -AllowNodeRuntime -Manifest $recoveryManifest) -eq 256 * 1024 * 1024) 'the manifest-bound Node runtime uses the finite Node recovery limit.'
            Assert-Behavior ((Get-LifeOSRecoveryFileMaxBytes (Join-Path (Join-Path $temp 'other') 'LifeOS.ServiceHost.exe')) -eq 4) 'unrelated recovery files retain the ordinary bound.'
            Assert-BehaviorThrows { Get-LifeOSRecoveryFileMaxBytes (Join-Path (Join-Path $temp 'other') 'LifeOS.ServiceHost.exe') -AllowServiceHostBinary -Manifest $recoveryManifest } 'a same-basename host cannot opt into the host recovery limit.'
            Assert-BehaviorThrows { Get-LifeOSRecoveryFileMaxBytes (Join-Path (Join-Path $temp 'other') 'node.exe') -AllowNodeRuntime -Manifest $recoveryManifest } 'a same-basename Node file cannot opt into the Node recovery limit.'

            $installTarget = Join-Path (Join-Path $temp 'atomic-install') 'LifeOS.ServiceHost.exe'
            $installBackup = Join-Path $temp 'atomic-install-backup'
            Ensure-Directory $installBackup
            $copyResult = Copy-FileVerifiedAtomic -Source $candidateHost -Destination $installTarget -BackupDirectory $installBackup -MaxBytes 8
            Assert-Behavior ($copyResult.Changed -and (Get-Item -LiteralPath $installTarget).Length -eq 8) 'service-host install copy enforces and preserves the finite bound.'
            [IO.File]::WriteAllBytes($candidateHost, [byte[]]@(1, 2, 3, 4, 5, 6, 7, 8, 9))
            Assert-BehaviorThrows { Copy-FileVerifiedAtomic -Source $candidateHost -Destination $installTarget -BackupDirectory $installBackup -MaxBytes 8 } 'oversized service-host install input is rejected before copy.'
            Assert-Behavior ((Get-Item -LiteralPath $installTarget).Length -eq 8) 'rejected service-host install input leaves its destination unchanged.'
            [IO.File]::WriteAllBytes($candidateHost, [byte[]]@(8, 7, 6, 5, 4, 3, 2, 1))

            $rollbackArtifact = [pscustomobject]@{ kind = 'host-binary'; destination = $hostTarget; backup = $hostBackup; changed = $true; phase = 'complete'; priorExists = $true }
            $rollbackWork = Join-Path $temp 'rollback-work'; Ensure-Directory $rollbackWork
            Restore-Artifact $rollbackArtifact $rollbackWork -AllowServiceHostBinary -Manifest $recoveryManifest
            Assert-Behavior ([IO.File]::ReadAllBytes($hostTarget).Length -eq 8) 'service-host rollback restores the manifest-bound backup.'
            [IO.File]::WriteAllBytes($hostBackup, [byte[]]@(1, 1, 1, 1, 1, 1, 1, 1, 1))
            $oversizedRollbackWork = Join-Path $temp 'rollback-work-oversized'; Ensure-Directory $oversizedRollbackWork
            Assert-BehaviorThrows { Restore-Artifact $rollbackArtifact $oversizedRollbackWork -AllowServiceHostBinary -Manifest $recoveryManifest } 'oversized service-host rollback input is rejected before destination mutation.'
            Assert-Behavior ([IO.File]::ReadAllBytes($hostTarget).Length -eq 8) 'rejected service-host rollback input leaves the installed host unchanged.'
        } finally {
            $script:LifeOSRecoveryMaxFileBytes = $oldRecoveryMax
            $script:LifeOSCandidateServiceHostMaxFileBytes = $oldHostMax
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    # A transition can fail after SCM has already changed the service state or
    # after the process is healthy enough to answer later. The recovery stage
    # must stay in restoring state until a later retry verifies the whole pair.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-service-state-retry-' + [Guid]::NewGuid().ToString('N'))
    $data = Join-Path $temp 'data'; $backup = Join-Path $temp 'backup'
    Ensure-Directory $data; Ensure-Directory $backup
    $destination = Join-Path $data 'stable.json'; [IO.File]::WriteAllText($destination, 'stable')
    $apiRunningSnapshot = Copy-BehaviorServiceSnapshot $apiServiceSnapshot; $apiRunningSnapshot.State = 'Running'; $apiRunningSnapshot.StartMode = 'Auto'
    $gatewayRunningSnapshot = Copy-BehaviorServiceSnapshot $presentServiceSnapshot; $gatewayRunningSnapshot.State = 'Running'; $gatewayRunningSnapshot.StartMode = 'Auto'
    $retrySnapshotMap = [ordered]@{ LifeOSAPI = $apiRunningSnapshot; LifeOSGateway = $gatewayRunningSnapshot }
    $script:serviceTransitionStates = [ordered]@{ LifeOSAPI = 'Stopped'; LifeOSGateway = 'Stopped' }
    $script:serviceTransitionEvents = @()
    $script:serviceTransitionWaitFailures = 1
    $script:serviceTransitionHealthFailures = 1
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    $realJsonWriter = ${function:Write-JsonAtomic}
    function Write-JsonAtomic {
        param([string]$Path, [object]$Value, [string]$OperatorSid, [long]$MaxBytes = 0)
        & $realJsonWriter -Path $Path -Value $Value -MaxBytes $MaxBytes
    }
    function Get-ServiceRecord {
        param($Name)
        return [pscustomobject]@{ State = [string]$script:serviceTransitionStates[$Name]; StartMode = 'Auto' }
    }
    function Start-Service {
        [CmdletBinding()]
        param([string]$Name)
        $script:serviceTransitionStates[$Name] = 'Running'
        $script:serviceTransitionEvents += ('start:' + $Name)
    }
    function Wait-LifeOSServiceState {
        param([string]$Name, [string]$ExpectedState, [int]$TimeoutSeconds)
        if ($script:serviceTransitionWaitFailures -gt 0) {
            $script:serviceTransitionWaitFailures--
            throw 'fixture service transition failed after SCM start'
        }
        if ([string]$script:serviceTransitionStates[$Name] -cne $ExpectedState) {
            throw 'fixture service did not reach the expected state'
        }
    }
    function Wait-LoopbackHealth {
        param([uri]$Uri, [int]$TimeoutSeconds)
        if ($script:serviceTransitionHealthFailures -gt 0) {
            $script:serviceTransitionHealthFailures--
            return $false
        }
        return $true
    }
    function Wait-LoopbackReadiness {
        param([uri]$Uri, [int]$TimeoutSeconds)
        return $true
    }
    try {
        $manifest = [pscustomobject]@{
            transactionId = 'service-state-retry'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json')
            paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $temp 'usage.jsonl') }; backups = @()
        }
        $stableState = Get-RecoveryArtifactState $destination
        $journal = [pscustomobject]@{
            schemaVersion = 1; transactionId = $manifest.transactionId; generation = $manifest.generation; operatorSid = $manifest.operatorSid; manifestPath = $manifest.manifestPath
            units = @([pscustomobject]@{ destination = $destination; backup = ''; pre = $stableState; post = $stableState; phase = 'complete'; stagingPath = (Join-Path $data '.rollback-restore-service-state-retry-0') }); unitCount = 1
            treeRoots = @($data); phase = 'artifacts-complete'; progressPath = (Get-RecoveryProgressPath $manifest); stages = [pscustomobject]@{ 'service-state-reconcile' = 'restoring' }
        }
        Write-JsonAtomic (Get-RecoveryJournalPath $manifest) $journal -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
        Assert-BehaviorThrows { Invoke-RecoveryStage $manifest 'service-state-reconcile' { Reconcile-LifeOSServiceSnapshotState -Snapshots $retrySnapshotMap -VerifyHealth -BeforeGatewayStart { $script:serviceTransitionEvents += 'before-gateway' } } -Postcondition { } } 'service state transition failure remains retryable'
        $afterTransitionFailure = Read-RecoveryJournal $manifest
        Assert-Behavior ([string]$afterTransitionFailure.stages.'service-state-reconcile' -ceq 'restoring') 'failed service state transition stays durably in restoring state.'
        Assert-Behavior ([string]$script:serviceTransitionStates['LifeOSAPI'] -eq 'Running' -and [string]$script:serviceTransitionStates['LifeOSGateway'] -eq 'Stopped') 'a failed service wait leaves the actual transition state observable for retry.'
        Assert-BehaviorThrows { Invoke-RecoveryStage $manifest 'service-state-reconcile' { Reconcile-LifeOSServiceSnapshotState -Snapshots $retrySnapshotMap -VerifyHealth -BeforeGatewayStart { $script:serviceTransitionEvents += 'before-gateway' } } -Postcondition { } } 'service health failure remains retryable'
        Assert-Behavior ([string](Read-RecoveryJournal $manifest).stages.'service-state-reconcile' -ceq 'restoring') 'failed service health verification stays durably in restoring state.'
        Invoke-RecoveryStage $manifest 'service-state-reconcile' { Reconcile-LifeOSServiceSnapshotState -Snapshots $retrySnapshotMap -VerifyHealth -BeforeGatewayStart { $script:serviceTransitionEvents += 'before-gateway' } } -Postcondition { }
        $completed = Read-RecoveryJournal $manifest
        Assert-Behavior ([string]$completed.stages.'service-state-reconcile' -ceq 'complete') 'service state recovery commits only after a verified retry succeeds.'
        Assert-Behavior ((($script:serviceTransitionEvents -join ',') -ceq 'start:LifeOSAPI,before-gateway,start:LifeOSGateway')) 'service recovery publishes the gateway pre-start evidence immediately before its one actual start across retries.'
    } finally {
        Remove-Variable -Name serviceTransitionStates -Scope Script
        Remove-Variable -Name serviceTransitionEvents -Scope Script
        Remove-Variable -Name serviceTransitionWaitFailures -Scope Script
        Remove-Variable -Name serviceTransitionHealthFailures -Scope Script
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $oldJournalMaxBytes = $script:LifeOSRecoveryJournalMaxBytes
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-recovery-writer-parity-' + [Guid]::NewGuid().ToString('N'))
    $data = Join-Path $temp 'data'; $backup = Join-Path $temp 'backup'
    Ensure-Directory $data; Ensure-Directory $backup
    $destination = Join-Path $data 'stable.json'; [IO.File]::WriteAllText($destination, 'stable')
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    try {
        $manifest = [pscustomobject]@{
            transactionId = 'writer-parity-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json')
            paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $temp 'usage.jsonl') }; backups = @()
        }
        $stableState = Get-RecoveryArtifactState $destination
        $journal = [pscustomobject]@{
            schemaVersion = 1; transactionId = $manifest.transactionId; generation = $manifest.generation; operatorSid = $manifest.operatorSid; manifestPath = $manifest.manifestPath
            units = @([pscustomobject]@{ destination = $destination; backup = ''; pre = $stableState; post = $stableState; phase = 'pending'; stagingPath = (Join-Path $data '.rollback-restore-writer-parity-fixture-0') }); unitCount = 1; treeRoots = @($data); phase = 'artifacts'; progressPath = (Get-RecoveryProgressPath $manifest)
        }
        Write-JsonAtomic (Get-RecoveryJournalPath $manifest) $journal
        Assert-Behavior ($null -ne (Read-RecoveryJournal $manifest)) 'writer output stays within the real reader serialized-size contract.'

        $oversizedBackup = Join-Path $temp 'oversized-backup'; Ensure-Directory $oversizedBackup
        $oversizedSource = Join-Path $oversizedBackup 'stable.json'; [IO.File]::WriteAllText($oversizedSource, 'prior')
        $script:parityMutationCalled = $false
        $script:LifeOSRecoveryJournalMaxBytes = 1024
        function Restore-Artifact {
            param($Artifact, $BackupDirectory)
            $script:parityMutationCalled = $true
        }
        $oversizedManifest = [pscustomobject]@{
            transactionId = ('x' * 2048); generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $oversizedBackup 'manifest.json'); collectorTransition = $null
            paths = [pscustomobject]@{ backupDirectory = $oversizedBackup; gatewayData = $data; usageHistory = (Join-Path $temp 'missing-usage.jsonl') }
            backups = @([pscustomobject]@{ destination = $destination; backup = $oversizedSource; changed = $true; priorExists = $true; phase = 'complete' })
        }
        Assert-BehaviorThrows { Write-JsonAtomic (Join-Path $backup 'recovery.json') ([pscustomobject]@{ padding = ('x' * 2048) }) } 'the real JSON writer rejects a serialized recovery value over its configured bound.'
        Assert-BehaviorThrows { Restore-ManifestArtifacts $oversizedManifest $backup } 'an oversized count-valid recovery journal is rejected before artifact mutation.'
        Assert-Behavior (-not $script:parityMutationCalled) 'oversized recovery inventory is rejected before Restore-Artifact.'
    } finally {
        $script:LifeOSRecoveryJournalMaxBytes = $oldJournalMaxBytes
        Remove-Variable -Name parityMutationCalled -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $oldProgressMaxRecords = $script:LifeOSRecoveryProgressMaxRecords
    $oldProgressMaxBytes = $script:LifeOSRecoveryProgressMaxBytes
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-capacity-' + [Guid]::NewGuid().ToString('N'))
    $data = Join-Path $temp 'data'; $backup = Join-Path $temp 'backup'
    Ensure-Directory $data; Ensure-Directory $backup
    $destination = Join-Path $data 'writer.json'; $source = Join-Path $backup 'writer.json'
    [IO.File]::WriteAllText($destination, 'temporary'); [IO.File]::WriteAllText($source, 'prior')
    $script:progressCapacityMutationCalled = $false
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Restore-Artifact { param($Artifact, $BackupDirectory) $script:progressCapacityMutationCalled = $true }
    try {
        $manifest = [pscustomobject]@{
            transactionId = 'progress-capacity-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json'); collectorTransition = $null
            paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $temp 'usage.jsonl') }
            backups = @([pscustomobject]@{ destination = $destination; backup = $source; changed = $true; priorExists = $true; phase = 'complete' })
        }
        $script:LifeOSRecoveryProgressMaxRecords = $oldProgressMaxRecords
        $script:LifeOSRecoveryProgressMaxBytes = 1
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'progress capacity is rejected before artifact mutation'
        Assert-Behavior (-not $script:progressCapacityMutationCalled) 'progress capacity rejection occurs before Restore-Artifact.'
    } finally {
        $script:LifeOSRecoveryProgressMaxRecords = $oldProgressMaxRecords
        $script:LifeOSRecoveryProgressMaxBytes = $oldProgressMaxBytes
        Remove-Variable -Name progressCapacityMutationCalled -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $oldMarkerMaxBytes = $script:LifeOSDeploymentMarkerMaxBytes
    $oldManifestMaxBytes = $script:LifeOSGenerationManifestMaxBytes
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-checkpoint-capacity-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    # Write-JsonAtomic is being exercised as a bounded writer here. Keep its
    # ACL side effect behind the same test seam used by the other recovery
    # fixtures; the real ACL adapter is covered by the dedicated Windows
    # deployment behavior and host preflight suites.
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl) }
    try {
        $marker = [ordered]@{
            schemaVersion = 2; state = 'active'; transactionId = '11111111-1111-1111-1111-111111111111'; generation = 'generation'; operatorSid = 'fixture'
            manifestPath = (Join-Path $temp 'manifest.json'); acquiredAtUtc = (Get-Date).ToUniversalTime().ToString('o'); updatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        }
        $markerBytes = [long]$script:LifeOSDeploymentMarkerMaxBytes
        $markerPath = Join-Path $temp $script:LifeOSDeploymentMarkerName
        Write-JsonAtomic $markerPath $marker -OperatorSid 'fixture' -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes
        $readMarker = Read-LifeOSBoundedJsonFile -Path $markerPath -MaxBytes $script:LifeOSDeploymentMarkerMaxBytes -Description 'near-limit marker'
        Assert-Behavior ($readMarker.state -eq 'active') 'near-limit marker writer output is accepted by its bounded reader.'
        $markerCurrentBytes = Get-LifeOSJsonSerializedByteCount $marker
        $script:LifeOSDeploymentMarkerMaxBytes = $markerCurrentBytes - 1
        Assert-BehaviorThrows { Assert-LifeOSDeploymentMarkerCheckpointCapacity $marker } 'marker terminal checkpoint growth is rejected before publication.'

        $manifest = [ordered]@{
            schemaVersion = 2; transactionId = 'manifest-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $temp 'manifest.json')
            paths = [ordered]@{ backupDirectory = $temp; gatewayData = (Join-Path $temp 'data'); usageHistory = (Join-Path $temp 'usage.jsonl') }; backups = (New-Object System.Collections.ArrayList); aclSnapshots = @()
        }
        $intent = [ordered]@{ kind = 'authority-set'; source = (Join-Path $temp 'legacy'); destination = (Join-Path $temp 'data'); backup = (Join-Path $temp 'previous-data'); priorExists = $true; changed = $true; phase = 'pending' }
        $completedIntent = [ordered]@{}
        foreach ($name in $intent.Keys) { $completedIntent[$name] = $intent[$name] }
        $completedIntent.phase = 'complete'
        $completedIntent.sourceSha256 = 'f' * 64
        $completedIntent.sourceLength = [long]::MaxValue
        $completedCandidate = New-LifeOSGenerationManifestCandidate -Manifest $manifest -BackupItem $completedIntent
        $completionBytes = Get-LifeOSJsonSerializedByteCount $completedCandidate
        $script:LifeOSGenerationManifestMaxBytes = $completionBytes - 1
        $beforeIntentCount = $manifest.backups.Count
        Assert-BehaviorThrows { New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifest.manifestPath -Kind 'authority-set' -Source $intent.source -Destination $intent.destination -Backup $intent.backup -PriorExists $true -Changed $true } 'authority pending/completed checkpoint growth is rejected before publication.'
        Assert-Behavior ($manifest.backups.Count -eq $beforeIntentCount) 'authority capacity rejection leaves the manifest inventory unchanged before target mutation.'

        $script:LifeOSGenerationManifestMaxBytes = $completionBytes
        Assert-Behavior ($completionBytes -gt 0 -and $completionBytes -le (16 * 1024 * 1024) -and $script:LifeOSGenerationManifestMaxBytes -eq $completionBytes) 'authority completion is preflighted near the 16 MiB writer boundary.'
        $acceptedIntent = @(New-ManifestIntent -List $manifest.backups -Manifest $manifest -ManifestPath $manifest.manifestPath -Kind 'authority-set' -Source $intent.source -Destination $intent.destination -Backup $intent.backup -PriorExists $true -Changed $true)
        Assert-Behavior ($acceptedIntent.Count -eq 1 -and $acceptedIntent[0].kind -eq 'authority-set') 'operation-specific manifest preflight accepts a complete near-limit intent.'
        Complete-ManifestIntent $acceptedIntent[0] $manifest $manifest.manifestPath ([pscustomobject]@{ Backup = $intent.backup; Changed = $true; SourceHash = ('a' * 64); SourceLength = [long]123 })
        $readManifest = Read-LifeOSBoundedJsonFile -Path $manifest.manifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes -Description 'near-limit manifest'
        Assert-Behavior ($readManifest.transactionId -eq 'manifest-fixture' -and $readManifest.backups[0].phase -eq 'complete') 'operation-specific manifest writer output is accepted by its bounded reader after completion.'
        Assert-Behavior ($readManifest.backups[0].kind -eq 'authority-set' -and $readManifest.backups[0].phase -eq 'complete' -and [string]$readManifest.backups[0].sourceSha256 -eq ('a' * 64) -and [long]$readManifest.backups[0].sourceLength -eq 123) 'persisted authority completion is accepted by the bounded reader.'
    } finally {
        $script:LifeOSDeploymentMarkerMaxBytes = $oldMarkerMaxBytes
        $script:LifeOSGenerationManifestMaxBytes = $oldManifestMaxBytes
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-linear-' + [Guid]::NewGuid().ToString('N'))
    $firstRoot = Join-Path $temp 'first'
    $secondRoot = Join-Path $temp 'second'
    Ensure-Directory $firstRoot
    Ensure-Directory $secondRoot
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl, [int]$MaxAttempts = 5, [int]$RetryDelayMilliseconds = 500) }
    function Measure-RecoveryProgressOutput {
        param([string]$Root, [int]$Count)
        $manifestPath = Join-Path $Root 'manifest.json'
        $manifest = [pscustomobject]@{ transactionId='linear-fixture'; generation='generation'; operatorSid='fixture'; manifestPath=$manifestPath; paths=[pscustomobject]@{ backupDirectory=$Root } }
        $units = New-Object object[] $Count
        for ($index = 0; $index -lt $Count; $index++) { $units[$index] = [pscustomobject]@{ phase='pending' } }
        $journal = [pscustomobject]@{ transactionId='linear-fixture'; generation='generation'; operatorSid='fixture'; manifestPath=$manifestPath; units=@($units); unitCount=$Count; progressPath=(Get-RecoveryProgressPath $manifest); progressSequence=0 }
        for ($index = 0; $index -lt $Count; $index++) {
            [void](Append-RecoveryProgress -Manifest $manifest -Journal $journal -UnitIndex $index -Phase 'complete')
        }
        return [long](Get-Item -LiteralPath (Get-RecoveryProgressPath $manifest) -Force).Length
    }
    try {
        $smallBytes = Measure-RecoveryProgressOutput $firstRoot 512
        $largeBytes = Measure-RecoveryProgressOutput $secondRoot 1024
        Assert-Behavior ($smallBytes -gt 0 -and $largeBytes -gt $smallBytes -and $largeBytes -lt ($smallBytes * 2.5)) 'linear recovery progress serialization stays proportional as inventory grows.'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

& {
    $realFramePart = ${function:Write-RecoveryProgressFramePart}
    $script:interruptedProgressBoundary = ''
    $temp = $null
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl, [int]$MaxAttempts = 5, [int]$RetryDelayMilliseconds = 500) }
    function Write-RecoveryProgressFramePart {
        param($Stream, $Bytes, $Boundary)
        & $realFramePart -Stream $Stream -Bytes $Bytes -Boundary $Boundary
        if ($script:interruptedProgressBoundary -eq $Boundary) { throw "fixture interruption after progress $Boundary boundary" }
    }
    function New-ProgressFixture {
        param([int]$UnitCount = 2)
        $root = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-fixture-' + [Guid]::NewGuid().ToString('N'))
        $data = Join-Path $root 'data'; $backup = Join-Path $root 'backup'
        Ensure-Directory $data; Ensure-Directory $backup
        $manifest = [pscustomobject]@{
            transactionId = 'framed-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json'); collectorTransition = $null
            paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $root 'usage.jsonl') }; backups = @()
        }
        $units = New-Object object[] $UnitCount
        $frames = New-Object object[] $UnitCount
        for ($index = 0; $index -lt $UnitCount; $index++) {
            $destination = Join-Path $data ('stable-' + $index + '.json')
            [IO.File]::WriteAllText($destination, 'stable-' + $index)
            $state = Get-RecoveryArtifactState $destination
            $units[$index] = [pscustomobject]@{
                destination = $destination; backup = ''; pre = $state; post = $state; phase = 'pending'
                stagingPath = (Join-Path $data ('.rollback-restore-framed-fixture-' + $index))
            }
        }
        $journal = [pscustomobject]@{
            schemaVersion = 1; transactionId = $manifest.transactionId; generation = $manifest.generation; operatorSid = $manifest.operatorSid; manifestPath = $manifest.manifestPath
            units = @($units); unitCount = $UnitCount; treeRoots = @($data); phase = 'artifacts'; progressPath = (Get-RecoveryProgressPath $manifest)
        }
        Write-JsonAtomic (Get-RecoveryJournalPath $manifest) $journal -MaxBytes $script:LifeOSRecoveryJournalMaxBytes
        for ($index = 0; $index -lt $UnitCount; $index++) {
            $record = New-RecoveryProgressRecord -Manifest $manifest -Journal $journal -UnitIndex $index -Phase 'complete' -Sequence $index -UnitCount $UnitCount
            $frames[$index] = New-RecoveryProgressFrame $record
        }
        return [pscustomobject]@{ Root = $root; Manifest = $manifest; Journal = $journal; Frames = $frames }
    }
    try {
        foreach ($boundary in @('header', 'header-digest', 'payload', 'digest', 'commit')) {
            $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-tail-' + [Guid]::NewGuid().ToString('N'))
            $data = Join-Path $temp 'data'; $backup = Join-Path $temp 'backup'
            Ensure-Directory $data; Ensure-Directory $backup
            $destination = Join-Path $data 'writer.json'; $source = Join-Path $backup 'writer.json'
            [IO.File]::WriteAllText($destination, 'temporary'); [IO.File]::WriteAllText($source, 'prior')
            $manifest = [pscustomobject]@{
                transactionId = 'framed-tail-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json'); collectorTransition = $null
                paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $temp 'usage.jsonl') }
                backups = @([pscustomobject]@{ destination = $destination; backup = $source; changed = $true; priorExists = $true; phase = 'complete' })
            }
            $script:interruptedProgressBoundary = $boundary
            try {
                Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } "a torn progress tail interrupts at the $boundary boundary"
                $script:interruptedProgressBoundary = ''
                $journal = Read-RecoveryJournal $manifest
                Assert-Behavior ($null -ne $journal) "the reader recovers a torn $boundary progress tail"
                Restore-ManifestArtifacts $manifest $backup
                Assert-Behavior ((Get-Content -LiteralPath $destination -Raw) -eq 'prior') "restore resumes after a torn $boundary progress tail"
                Assert-Behavior ($null -ne (Read-RecoveryJournal $manifest)) "the restored journal remains readable after a torn $boundary progress tail"
            } finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
        }

        $roundTrip = New-ProgressFixture -UnitCount 2
        try {
            Append-RecoveryProgress -Manifest $roundTrip.Manifest -Journal $roundTrip.Journal -UnitIndex 0 -Phase 'complete'
            Append-RecoveryProgress -Manifest $roundTrip.Manifest -Journal $roundTrip.Journal -UnitIndex 1 -Phase 'complete'
            $roundTripRead = Read-RecoveryJournal $roundTrip.Manifest
            Assert-Behavior ($roundTripRead.progressSequence -eq 2 -and @($roundTripRead.units | Where-Object { $_.phase -ne 'complete' }).Count -eq 0) 'writer output round-trips through the real recovery progress reader.'
        } finally { Remove-Item -LiteralPath $roundTrip.Root -Recurse -Force -ErrorAction SilentlyContinue }

        $realRestoreArtifact = ${function:Restore-Artifact}
        function Restore-Artifact {
            param($Artifact, $BackupDirectory)
            $script:corruptRestoreMutation = $true
            & $realRestoreArtifact $Artifact $BackupDirectory
        }
        foreach ($position in @('interior', 'final')) {
            foreach ($corruption in @('header', 'length', 'header-digest', 'payload', 'digest', 'commit')) {
                $fixture = New-ProgressFixture -UnitCount 2
                try {
                    Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 0 -Phase 'complete'
                    Append-RecoveryProgress -Manifest $fixture.Manifest -Journal $fixture.Journal -UnitIndex 1 -Phase 'complete'
                    $progressPath = Get-RecoveryProgressPath $fixture.Manifest
                    $progressBytes = [IO.File]::ReadAllBytes($progressPath)
                    $frameOffset = if ($position -eq 'interior') { [long]0 } else { [long]$fixture.Frames[0].TotalBytes }
                    $payloadLength = [BitConverter]::ToInt32($progressBytes, [int]$frameOffset + 5)
                    $corruptionOffset = switch ($corruption) {
                        'header' { [int]$frameOffset }
                        'length' { [int]$frameOffset + 5 }
                        'header-digest' { [int]$frameOffset + $script:LifeOSRecoveryProgressHeaderBytes }
                        'payload' { [int]$frameOffset + $script:LifeOSRecoveryProgressFrameHeaderBytes }
                        'digest' { [int]$frameOffset + $script:LifeOSRecoveryProgressFrameHeaderBytes + $payloadLength }
                        'commit' { [int]$frameOffset + $script:LifeOSRecoveryProgressFrameHeaderBytes + $payloadLength + $script:LifeOSRecoveryProgressDigestBytes }
                    }
                    $progressBytes[$corruptionOffset] = [byte]($progressBytes[$corruptionOffset] -bxor 1)
                    [IO.File]::WriteAllBytes($progressPath, $progressBytes)
                    $beforeLength = [long](Get-Item -LiteralPath $progressPath -Force).Length
                    $script:corruptRestoreMutation = $false
                    Assert-BehaviorThrows { Read-RecoveryJournal $fixture.Manifest } "committed $position $corruption corruption is rejected by the real reader"
                    Assert-BehaviorThrows { Restore-ManifestArtifacts $fixture.Manifest $fixture.Manifest.paths.backupDirectory } "committed $position $corruption corruption is rejected by the real restore path"
                    Assert-Behavior (-not $script:corruptRestoreMutation) "committed $position $corruption corruption is rejected before artifact mutation"
                    Assert-Behavior ([long](Get-Item -LiteralPath $progressPath -Force).Length -eq $beforeLength) "committed $position $corruption is never discarded as a torn tail"
                    Remove-Variable -Name corruptRestoreMutation -Scope Script -ErrorAction SilentlyContinue
                } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        foreach ($partialLength in 1..8) {
            $fixture = New-ProgressFixture -UnitCount 2
            try {
                $prefix = New-Object byte[] $partialLength
                [Array]::Copy($fixture.Frames[0].Header, 0, $prefix, 0, $partialLength)
                [IO.File]::WriteAllBytes((Get-RecoveryProgressPath $fixture.Manifest), $prefix)
                $readJournal = Read-RecoveryJournal $fixture.Manifest
                Assert-Behavior ($readJournal.progressSequence -eq 0 -and [long](Get-Item -LiteralPath (Get-RecoveryProgressPath $fixture.Manifest) -Force).Length -eq 0) "a final partial progress header of $partialLength bytes is safely discarded"
                Restore-ManifestArtifacts $fixture.Manifest $fixture.Manifest.paths.backupDirectory
                Assert-Behavior ((Read-RecoveryJournal $fixture.Manifest).phase -eq 'artifacts-complete') "recovery resumes after a $partialLength-byte final partial progress header"
            } finally { Remove-Item -LiteralPath $fixture.Root -Recurse -Force -ErrorAction SilentlyContinue }
        }
    } finally {
        Remove-Variable -Name interruptedProgressBoundary -Scope Script
        Remove-Variable -Name corruptRestoreMutation -Scope Script -ErrorAction SilentlyContinue
        if ($null -ne $temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

& {
    $oldMaxRecords = $script:LifeOSRecoveryProgressMaxRecords
    $oldMaxBytes = $script:LifeOSRecoveryProgressMaxBytes
    $realFramePart = ${function:Write-RecoveryProgressFramePart}
    $script:progressCommitCount = 0
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl, [int]$MaxAttempts = 5, [int]$RetryDelayMilliseconds = 500) }
    function Write-RecoveryProgressFramePart {
        param($Stream, $Bytes, $Boundary)
        & $realFramePart -Stream $Stream -Bytes $Bytes -Boundary $Boundary
        if ($Boundary -eq 'commit') {
            $script:progressCommitCount++
            if ($script:progressCommitCount -eq 3) { throw 'fixture interruption after the actual final durable transition' }
        }
    }
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-progress-retry-budget-' + [Guid]::NewGuid().ToString('N'))
    $data = Join-Path $temp 'data'; $backup = Join-Path $temp 'backup'
    Ensure-Directory $data; Ensure-Directory $backup
    $destination = Join-Path $data 'writer.json'; $source = Join-Path $backup 'writer.json'
    [IO.File]::WriteAllText($destination, 'temporary'); [IO.File]::WriteAllText($source, 'prior')
    $manifest = [pscustomobject]@{
        transactionId = 'retry-budget-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json'); collectorTransition = $null
        paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = (Join-Path $temp 'usage.jsonl') }
        backups = @([pscustomobject]@{ destination = $destination; backup = $source; changed = $true; priorExists = $true; phase = 'complete' })
    }
    try {
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'retry budget fixture interrupts after the actual final durable transition'
        $boundedBytes = [long](Get-Item -LiteralPath (Get-RecoveryProgressPath $manifest) -Force).Length
        $durableJournal = Read-RecoveryJournal $manifest
        Assert-Behavior ($durableJournal.progressSequence -eq 3 -and @($durableJournal.units | Where-Object { $_.phase -ne 'complete' }).Count -eq 0) 'retry budget fixture records a complete inventory before the terminal checkpoint retry.'
        $script:LifeOSRecoveryProgressMaxRecords = 3
        $script:LifeOSRecoveryProgressMaxBytes = $boundedBytes
        $script:progressCommitCount = 100
        $realJsonWriter = ${function:Write-JsonAtomic}
        $script:terminalCheckpointFailures = 2
        function Write-JsonAtomic {
            param([string]$Path, [object]$Value, [string]$OperatorSid, [long]$MaxBytes = 0)
            if ($Path -eq (Get-RecoveryJournalPath $manifest) -and
                [string](Get-JournalProperty $Value 'phase') -ceq 'artifacts-complete' -and
                $script:terminalCheckpointFailures -gt 0) {
                $script:terminalCheckpointFailures--
                throw 'fixture interruption before the terminal checkpoint publication'
            }
            & $realJsonWriter -Path $Path -Value $Value -OperatorSid $OperatorSid -MaxBytes $MaxBytes
        }
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'first terminal checkpoint interruption leaves progress complete.'
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'second terminal checkpoint interruption leaves progress complete.'
        $afterRepeatedFailureJournal = Read-RecoveryJournal $manifest
        $afterRepeatedFailureBytes = [long](Get-Item -LiteralPath (Get-RecoveryProgressPath $manifest) -Force).Length
        Assert-Behavior ($afterRepeatedFailureBytes -eq $boundedBytes -and $afterRepeatedFailureJournal.progressSequence -eq 3 -and
            @($afterRepeatedFailureJournal.units | Where-Object { $_.phase -ne 'complete' }).Count -eq 0 -and
            $afterRepeatedFailureJournal.phase -eq 'artifacts') 'durable complete transitions are skipped at record and byte limits while terminal publication is retried.'
        Restore-ManifestArtifacts $manifest $backup
        $finalJournal = Read-RecoveryJournal $manifest
        Assert-Behavior ((Get-Content -LiteralPath $destination -Raw) -eq 'prior' -and $finalJournal.phase -eq 'artifacts-complete' -and
            [long](Get-Item -LiteralPath (Get-RecoveryProgressPath $manifest) -Force).Length -eq $boundedBytes) 'repeated recovery remains readable after the terminal checkpoint retry.'
    } finally {
        $script:LifeOSRecoveryProgressMaxRecords = $oldMaxRecords
        $script:LifeOSRecoveryProgressMaxBytes = $oldMaxBytes
        Remove-Variable -Name progressCommitCount -Scope Script
        Remove-Variable -Name terminalCheckpointFailures -Scope Script -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-task-retry-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $xml = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Actions><Exec><Command>D:\host\writer.exe</Command><Arguments>--snapshot</Arguments><WorkingDirectory>D:\host</WorkingDirectory></Exec></Actions></Task>'
    $codexBackup = Join-Path $temp 'codex.xml'
    $snapshotBackup = Join-Path $temp 'snapshot.xml'
    [IO.File]::WriteAllText($codexBackup, $xml)
    [IO.File]::WriteAllText($snapshotBackup, $xml)
    $script:taskRetryStates = [ordered]@{ LifeOSCodexCollector = 'Running'; LifeOSTailscaleSnapshot = 'Running' }
    $script:taskRetrySnapshotFailure = $true
    $script:taskRetryJournal = [pscustomobject]@{
        schemaVersion = 1; transactionId = 'task-retry-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = 'fixture'
        phase = 'artifacts-complete'; stages = [pscustomobject]@{ 'Restore-CodexCollectorTask' = 'complete'; 'Restore-TailscaleSnapshotTask' = 'restoring' }
    }
    $codexRecord = [pscustomobject]@{ Name = 'LifeOSCodexCollector'; Exists = $true; Enabled = $true; State = 'Running'; TaskPath = '\'; Backup = $codexBackup; Xml = $xml }
    $snapshotRecord = [pscustomobject]@{ Name = 'LifeOSTailscaleSnapshot'; Exists = $true; Enabled = $true; State = 'Running'; TaskPath = '\'; Backup = $snapshotBackup; Xml = $xml }
    $manifest = [pscustomobject]@{
        transactionId = 'task-retry-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = 'fixture'
        paths = [pscustomobject]@{ backupDirectory = $temp }; codexTask = $codexRecord; snapshotTask = $snapshotRecord
    }
    function Read-RecoveryJournal { param($Manifest) return $script:taskRetryJournal }
    function Write-JsonAtomic { param($Path, $Value, $OperatorSid, $MaxBytes) }
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName, [string]$TaskPath)
        $names = if ([string]::IsNullOrWhiteSpace($TaskName)) { @($script:taskRetryStates.Keys) } else { @($TaskName) }
        foreach ($name in $names) {
            if ($script:taskRetryStates.Contains($name)) {
                [pscustomobject]@{ TaskName = $name; TaskPath = '\'; State = [string]$script:taskRetryStates[$name] }
            }
        }
    }
    function Export-ScheduledTask { [CmdletBinding()] param($TaskName, $TaskPath) return $xml }
    function Get-ScheduledTaskInfo { [CmdletBinding()] param($TaskName, $TaskPath) return [pscustomobject]@{ LastTaskResult = 0 } }
    function Disable-ScheduledTask { [CmdletBinding()] param($TaskName, $TaskPath) $script:taskRetryStates[$TaskName] = 'Disabled' }
    function Stop-ScheduledTask { [CmdletBinding()] param($TaskName, $TaskPath) $script:taskRetryStates[$TaskName] = 'Disabled' }
    function Enable-ScheduledTask { [CmdletBinding()] param($TaskName, $TaskPath) $script:taskRetryStates[$TaskName] = 'Ready' }
    function Start-ScheduledTask { [CmdletBinding()] param($TaskName, $TaskPath) $script:taskRetryStates[$TaskName] = 'Running' }
    function Register-ScheduledTask {
        [CmdletBinding()]
        param($TaskName, $TaskPath, $Xml, [switch]$Force)
        if ($TaskName -eq 'LifeOSTailscaleSnapshot' -and $script:taskRetrySnapshotFailure) { throw 'fixture snapshot restoration failure' }
        $script:taskRetryStates[$TaskName] = 'Ready'
    }
    function Invoke-TaskRollbackRetryFixture {
        $success = $false
        try {
            Stop-DeploymentTaskBarrier $manifest 'fixture'
            Invoke-RecoveryStage $manifest 'Restore-CodexCollectorTask' { Restore-CodexCollectorTask $codexRecord 'LifeOSCodexCollector' } -Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState $codexRecord 'LifeOSCodexCollector' }
            Invoke-RecoveryStage $manifest 'Restore-TailscaleSnapshotTask' { Restore-TailscaleSnapshotTask $snapshotRecord 'LifeOSTailscaleSnapshot' } -Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState $snapshotRecord 'LifeOSTailscaleSnapshot' }
            Reconcile-LifeOSScheduledTaskSnapshotState $codexRecord 'LifeOSCodexCollector'
            Reconcile-LifeOSScheduledTaskSnapshotState $snapshotRecord 'LifeOSTailscaleSnapshot'
            $success = $true
        } catch { }
        return $success
    }
    try {
        Assert-Behavior (-not (Invoke-TaskRollbackRetryFixture)) 'outer rollback does not report success after snapshot task restoration failure.'
        Assert-Behavior ($script:taskRetryStates['LifeOSCodexCollector'] -eq 'Running' -and $script:taskRetryStates['LifeOSTailscaleSnapshot'] -eq 'Disabled') 'collector retry restores its writer while snapshot restoration is still failed.'
        $script:taskRetrySnapshotFailure = $false
        Assert-Behavior (Invoke-TaskRollbackRetryFixture) 'outer rollback retry succeeds only after both task restorations.'
        Assert-Behavior ($script:taskRetryStates['LifeOSCodexCollector'] -eq 'Running' -and $script:taskRetryStates['LifeOSTailscaleSnapshot'] -eq 'Running') 'successful recovery leaves previously running writers running and enabled.'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    $script:scheduledTaskLookupMode = 'not-found'
    $script:scheduledTaskEnumerationCount = 0
    function Get-ScheduledTask {
        [CmdletBinding()]
        param([string]$TaskName, [string]$TaskPath)
        Assert-Behavior ([string]::IsNullOrWhiteSpace($TaskName) -and [string]::IsNullOrWhiteSpace($TaskPath)) 'scheduled task reconciliation uses successful unfiltered enumeration.'
        switch ($script:scheduledTaskLookupMode) {
            'empty' { return }
            'matching' {
                return @(
                    [pscustomobject]@{ TaskName = 'UnrelatedFixture'; TaskPath = '\'; State = 'Ready' }
                    [pscustomobject]@{ TaskName = 'LifeOSAbsentFixture'; TaskPath = '\'; State = 'Ready' }
                )
            }
            'over-limit' {
                for ($index = 0; $index -lt 9000; $index++) {
                    $script:scheduledTaskEnumerationCount++
                    [pscustomobject]@{ TaskName = 'OtherFixture'; TaskPath = '\'; State = 'Ready' }
                }
            }
            'not-found' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('exact task is absent'),
                    'CmdletizationQuery_NotFound,Get-ScheduledTask',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            'access-denied' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [UnauthorizedAccessException]::new('scheduled task access denied fixture'),
                    'GetScheduledTaskCommand_AccessDenied',
                    [System.Management.Automation.ErrorCategory]::PermissionDenied, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            'provider-failure' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('scheduled task provider unavailable fixture'),
                    'GetScheduledTaskCommand_ProviderFailure',
                    [System.Management.Automation.ErrorCategory]::InvalidOperation, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            'unrelated-not-found' {
                $record = [System.Management.Automation.ErrorRecord]::new(
                    [Exception]::new('scheduled task provider enumeration failed fixture'),
                    'ProviderEnumerationFailed,Get-ScheduledTask',
                    [System.Management.Automation.ErrorCategory]::ObjectNotFound, $null)
                $PSCmdlet.ThrowTerminatingError($record)
            }
            default { throw 'unknown scheduled task fixture mode' }
        }
    }
    $absentSnapshot = [pscustomobject]@{ Exists = $false; Enabled = $false; State = 'Stopped'; TaskPath = '\' }
    try {
        $script:scheduledTaskLookupMode = 'empty'
        Reconcile-LifeOSScheduledTaskSnapshotState $absentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1
        Assert-Behavior $true 'an empty scheduled task enumeration is a successful terminal state.'
        Assert-Behavior $true 'an absent scheduled task is a successful terminal state.'
        $presentSnapshot = [pscustomobject]@{ Exists = $true; Enabled = $true; State = 'Ready'; TaskPath = '\' }
        $script:scheduledTaskLookupMode = 'matching'
        Reconcile-LifeOSScheduledTaskSnapshotState $presentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1
        Assert-Behavior $true 'successful enumeration exact-filters the requested task name and path.'
        $script:scheduledTaskLookupMode = 'not-found'
        Assert-BehaviorThrows { Reconcile-LifeOSScheduledTaskSnapshotState $absentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1 } 'scheduled task enumeration ObjectNotFound is not treated as absent.'
        $script:scheduledTaskLookupMode = 'access-denied'
        Assert-BehaviorThrows { Reconcile-LifeOSScheduledTaskSnapshotState $absentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1 } 'scheduled task access denied is not treated as absent.'
        $script:scheduledTaskLookupMode = 'provider-failure'
        Assert-BehaviorThrows { Reconcile-LifeOSScheduledTaskSnapshotState $absentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1 } 'scheduled task provider failure is not treated as absent.'
        $script:scheduledTaskLookupMode = 'unrelated-not-found'
        Assert-BehaviorThrows { Reconcile-LifeOSScheduledTaskSnapshotState $absentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1 } 'unrelated ObjectNotFound provider errors are not treated as absent.'
        $script:scheduledTaskLookupMode = 'over-limit'
        Assert-BehaviorThrows { Reconcile-LifeOSScheduledTaskSnapshotState $absentSnapshot 'LifeOSAbsentFixture' -TimeoutSeconds 1 } 'scheduled task inventory cap fails closed.'
        Assert-Behavior ($script:scheduledTaskEnumerationCount -eq 8193) 'scheduled task enumeration stops at the first record beyond its cap.'
    } finally {
        Remove-Variable -Name scheduledTaskLookupMode -Scope Script
        Remove-Variable -Name scheduledTaskEnumerationCount -Scope Script
    }
}

& {
    $script:barrierEvents = @(); $script:barrierState = 'Running'; $script:tamperedTask = $false
    $xml = '<Task xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"><Principals><Principal><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals><Actions><Exec><Command>D:\host\writer.exe</Command><Arguments>--snapshot</Arguments><WorkingDirectory>D:\host</WorkingDirectory></Exec></Actions></Task>'
    $record = [pscustomobject]@{ Name='LifeOSTailscaleSnapshot'; TaskPath='\'; Exists=$false; installedIdentity=(Get-TaskRecoveryIdentity $xml '\') }
    $manifest = [pscustomobject]@{ operatorSid='fixture'; codexTask=$record; snapshotTask=[pscustomobject]@{ Name='LifeOSCodexCollector'; Exists=$false; TaskPath='\' } }
    function Get-ScheduledTask { param($TaskName, $TaskPath) if ($TaskName -ne 'LifeOSCodexCollector') { return [pscustomobject]@{ TaskName='LifeOSTailscaleSnapshot'; TaskPath='\'; State=$script:barrierState } } }
    function Export-ScheduledTask { param($TaskName, $TaskPath) if ($script:tamperedTask) { return $xml.Replace('HighestAvailable', 'LeastPrivilege') }; return $xml }
    function Write-JsonAtomic { param($Path, $Value, $OperatorSid, $MaxBytes) $script:barrierEvents += 'journal' }
    function Disable-ScheduledTask { param($TaskName, $TaskPath) $script:barrierEvents += 'disable' }
    function Stop-ScheduledTask { param($TaskName, $TaskPath) $script:barrierEvents += 'stop'; $script:barrierState='Disabled' }
    function Get-ScheduledTaskInfo { param($TaskName, $TaskPath) $script:barrierEvents += 'terminal'; return [pscustomobject]@{ LastTaskResult=0 } }
    $script:tamperedTask = $true
    Assert-BehaviorThrows { Stop-DeploymentTaskBarrier $manifest 'fixture' } 'task principal mismatch before disable'
    Assert-Behavior ($script:barrierEvents.Count -eq 0) 'task tampering causes zero mutations.'
    $script:tamperedTask = $false
    Stop-DeploymentTaskBarrier $manifest 'fixture'
    Assert-Behavior (($script:barrierEvents -join ',') -eq 'journal,disable,stop,terminal,journal') 'task barrier journals disable/stop/terminal before restore.'
    Assert-Behavior ($record.barrierPhase -eq 'stopped') 'task barrier completion is durable.'
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-recovery-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $data = Join-Path $temp 'data'; Ensure-Directory $data
    $backup = Join-Path $temp 'backup'; Ensure-Directory $backup
    $usage = Join-Path $temp 'usage.jsonl'
    $first = Join-Path $data 'first.json'; $second = Join-Path $data 'second.json'
    $firstBackup = Join-Path $backup 'first.json'; $secondBackup = Join-Path $backup 'second.json'
    foreach ($file in @($first, $second)) { [IO.File]::WriteAllText($file, 'new') }
    foreach ($file in @($firstBackup, $secondBackup)) { [IO.File]::WriteAllText($file, 'old') }
    $manifest = [pscustomobject]@{ transactionId='fixture'; generation='generation'; operatorSid='fixture'; manifestPath=(Join-Path $backup 'manifest.json'); collectorTransition=$null; paths=[pscustomobject]@{ backupDirectory=$backup; gatewayData=$data; usageHistory=$usage }; backups=@(
        [pscustomobject]@{ destination=$first; backup=$firstBackup; changed=$true; priorExists=$true; phase='complete' },
        [pscustomobject]@{ destination=$second; backup=$secondBackup; changed=$true; priorExists=$true; phase='complete' }
    ) }
    # Real file/hash/journal operations; only the Windows ACL adapter is fake.
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl) }
    $realRestore = ${function:Restore-Artifact}; $script:interruptRecovery = $true
    function Restore-Artifact {
        param($Artifact, $BackupDirectory)
        & $realRestore $Artifact $BackupDirectory
        if ($script:interruptRecovery) { $script:interruptRecovery=$false; throw 'fixture interruption after rename' }
    }
    try {
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'rollback interruption after one artifact'
        $journalPath = Get-RecoveryJournalPath $manifest
        $interrupted = Get-Content -LiteralPath $journalPath -Raw | ConvertFrom-Json
        $pending = @($interrupted.units | Where-Object { $_.phase -eq 'pending' })[0]
        $pending.phase = 'restoring'
        Write-JsonAtomic $journalPath $interrupted
        [IO.File]::WriteAllText($pending.stagingPath, 'partial-copy')
        Restore-ManifestArtifacts $manifest $backup
        Assert-Behavior ((Get-Content $first -Raw) -eq 'old' -and (Get-Content $second -Raw) -eq 'old') 'rollback resumes permitted pre/post states.'
        Restore-ManifestArtifacts $manifest $backup
        Assert-Behavior (Test-Path $firstBackup) 'retry does not consume backups.'
        $canonicalJournal = Get-Content -LiteralPath $journalPath -Raw
        $badJournal = $canonicalJournal | ConvertFrom-Json
        $badJournal.units[0].stagingPath = Join-Path $temp 'unowned-stage'
        Write-JsonAtomic $journalPath $badJournal
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'matching transaction cannot delete an unowned staging path'
        $badJournal = $canonicalJournal | ConvertFrom-Json
        $badJournal.units[0].destination = Join-Path $temp 'outside-authority.txt'
        Write-JsonAtomic $journalPath $badJournal
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'matching transaction cannot restore outside manifest roots'
        $badJournal = $canonicalJournal | ConvertFrom-Json
        $badJournal.units[0].backup = Join-Path $temp 'outside-backup.txt'
        Write-JsonAtomic $journalPath $badJournal
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'matching transaction cannot read an unrelated backup'
        [IO.File]::WriteAllText($journalPath, $canonicalJournal)
        Assert-Behavior (-not (Test-Path $pending.stagingPath)) 'interrupted partial staging copy is safely retried.'
        [IO.File]::WriteAllText($first, 'unrelated')
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $backup } 'completed unit rejects later writes'
        [IO.File]::WriteAllText($usage, 'observation')
        $manifest.collectorTransition = [pscustomobject]@{ phase='running'; usageBefore='absent' }
        Assert-BehaviorThrows { Test-CollectorUsagePreserved $manifest } 'unattributed collector write fails closed'
        $manifest.collectorTransition = [pscustomobject]@{ phase='terminal'; usageBefore='absent'; usageAfter=(Get-RecoveryArtifactState $usage); acknowledged=$true }
        Assert-Behavior (Test-CollectorUsagePreserved $manifest) 'acknowledged collector observations survive rollback.'
        [IO.File]::WriteAllText($usage, 'later-observation')
        Assert-BehaviorThrows { Test-CollectorUsagePreserved $manifest } 'later observations cannot be attributed to install'
        $secret = Join-Path $temp 'local.secret'
        [IO.File]::WriteAllText($secret, ('x' * 48))
        Assert-Behavior ((Get-LocalApiBearerHeaders $secret).Authorization -ceq ('Bearer ' + ('x' * 48))) 'verification sends exact bearer.'
        [IO.File]::WriteAllText($secret, ('x' * 48) + "`n")
        Assert-BehaviorThrows { Get-LocalApiBearerHeaders $secret } 'malformed local credential fails closed'
        Assert-BehaviorThrows { Get-LocalApiBearerHeaders (Join-Path $temp 'missing.secret') } 'missing local credential fails closed'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    Assert-BehaviorThrows {
        Assert-RecoveryInventoryBounds -TreeRoots @('fixture-root') -FileUnits (0..$script:LifeOSRecoveryMaxFileUnits) -ManifestBackups @()
    } 'recovery rejects an over-limit file inventory before mutation.'
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-recovery-expanded-tree-' + [Guid]::NewGuid().ToString('N'))
    $data = Join-Path $temp 'data'; Ensure-Directory $data
    $backup = Join-Path $temp 'backup'; Ensure-Directory $backup
    $usage = Join-Path $temp 'usage.jsonl'
    for ($index = 0; $index -lt 257; $index++) {
        [IO.File]::WriteAllText((Join-Path $data ('file-{0:D3}.json' -f $index)), 'stable')
    }
    $manifest = [pscustomobject]@{
        transactionId = 'expanded-tree-fixture'; generation = 'generation'; operatorSid = 'fixture'; manifestPath = (Join-Path $backup 'manifest.json')
        collectorTransition = $null; paths = [pscustomobject]@{ backupDirectory = $backup; gatewayData = $data; usageHistory = $usage }; backups = @()
    }
    $script:inventoryRestoreCalled = $false
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl) }
    $realRestore = ${function:Restore-Artifact}
    function Restore-Artifact {
        param($Artifact, $BackupDirectory)
        $script:inventoryRestoreCalled = $true
        & $realRestore $Artifact $BackupDirectory
    }
    try {
        Restore-ManifestArtifacts $manifest $backup
        $journal = Get-Content -LiteralPath (Get-RecoveryJournalPath $manifest) -Raw | ConvertFrom-Json
        $fileUnits = @($journal.units | Where-Object { [string]$_.destination -like ($data + '\*') })
        Assert-Behavior ($fileUnits.Count -eq 257) 'a realistic 257-file inventory is accepted before artifact mutation.'
        Assert-Behavior (-not $script:inventoryRestoreCalled) 'an accepted expanded inventory performs no artifact mutation when states already match.'
        $oversizedRoot = Join-Path $temp 'oversized'; Ensure-Directory $oversizedRoot
        [IO.File]::WriteAllText((Join-Path $oversizedRoot 'oversized.bin'), 'oversized')
        $oldMaxFileBytes = $script:LifeOSRecoveryMaxFileBytes
        try {
            $script:LifeOSRecoveryMaxFileBytes = 4
            Assert-BehaviorThrows { Get-TreeManifestIndex -Root $oversizedRoot } 'an oversized tree file is rejected before hashing the file.'
        } finally { $script:LifeOSRecoveryMaxFileBytes = $oldMaxFileBytes }
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-durable-checkpoint-failure-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $path = Join-Path $temp 'checkpoint.json'
    function Write-LifeOSDurableBytes {
        param([string]$Path, [byte[]]$Bytes)
        throw 'fixture durable checkpoint flush failure'
    }
    try {
        Assert-BehaviorThrows { Write-JsonAtomic -Path $path -Value ([pscustomobject]@{ state = 'fixture' }) } 'durable checkpoint failure is surfaced before replacement'
        Assert-Behavior (@(Get-ChildItem -LiteralPath $temp -Force -ErrorAction Stop).Count -eq 0) 'durable checkpoint failure cleans up its temporary file handle and bytes'
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
$readRights = [long][Security.AccessControl.FileSystemRights]::ReadAndExecute -bor [long][Security.AccessControl.FileSystemRights]::Synchronize
$modifyRights = [long][Security.AccessControl.FileSystemRights]::Modify -bor [long][Security.AccessControl.FileSystemRights]::Synchronize
Assert-AclRoleRights 'read' $readRights 0 $true
Assert-AclRoleRights 'modify' $modifyRights 0 $true
Assert-BehaviorThrows { Assert-AclRoleRights 'read' $modifyRights 0 $true } 'code/runtime reader cannot write'
Assert-BehaviorThrows { Assert-AclRoleRights 'modify' $readRights 0 $true } 'data writer requires modify'
Assert-BehaviorThrows { Assert-AclRoleRights 'owner' $modifyRights 0 $true } 'management owner requires full control'
Assert-BehaviorThrows { Assert-AclRoleRights 'read' $readRights ([long][Security.AccessControl.FileSystemRights]::ReadData) $false } 'deny ACE cancels required secret read'
Assert-BehaviorThrows { Assert-AclRoleRights 'modify' ($modifyRights -bor [long][Security.AccessControl.FileSystemRights]::ChangePermissions) 0 $true } 'data writer cannot rewrite ACLs'
Write-Host 'PASS: transaction-owned security recovery behavioral assertions'


& {
    # Shared data/log parents must expose exactly two service subtrees. Use
    # real filesystem identities and a small ACL adapter so the helper's
    # bounded immediate enumeration and cross-service rejection are exercised
    # without requiring a privileged ACL mutation.
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-shared-root-' + [Guid]::NewGuid().ToString('N'))
    $dataRootFixture = Join-Path $temp 'data'
    Ensure-Directory (Join-Path $dataRootFixture 'api')
    Ensure-Directory (Join-Path $dataRootFixture 'gateway')
    $operator = 'S-1-5-21-1-2-3-4'
    $api = 'S-1-5-80-1-2-3-4-5'
    $gateway = 'S-1-5-80-9-8-7-6-5'
    $script:sharedRootCrossService = $false
    function Get-Acl {
        param($LiteralPath)
        $name = [IO.Path]::GetFileName([string]$LiteralPath)
        $serviceSid = if ($name -ieq 'api') { $api } else { $gateway }
        $entries = @()
        foreach ($sid in @($operator, 'S-1-5-18', 'S-1-5-32-544', $serviceSid)) {
            $identity = [pscustomobject]@{ Value = $sid }
            $identity | Add-Member -MemberType ScriptMethod -Name Translate -Value { param($Type) return $this }
            $entries += [pscustomobject]@{ IdentityReference = $identity; AccessControlType = 'Allow' }
        }
        if ($script:sharedRootCrossService -and $name -ieq 'api') {
            $identity = [pscustomobject]@{ Value = $gateway }
            $identity | Add-Member -MemberType ScriptMethod -Name Translate -Value { param($Type) return $this }
            $entries += [pscustomobject]@{ IdentityReference = $identity; AccessControlType = 'Allow' }
        }
        return [pscustomobject]@{ Access = $entries }
    }
    try {
        $mapping = [ordered]@{ api = $api; gateway = $gateway }
        $children = @(Assert-LifeOSExpectedImmediateChildren -Root $dataRootFixture -ExpectedChildren $mapping -RequireAll)
        Assert-Behavior ($children.Count -eq 2) 'shared-root validation returns both expected service subtrees.'

        Remove-Item -LiteralPath (Join-Path $dataRootFixture 'gateway') -Recurse -Force
        Assert-BehaviorThrows { Assert-LifeOSExpectedImmediateChildren -Root $dataRootFixture -ExpectedChildren $mapping -RequireAll } 'missing shared-root child is rejected'
        Ensure-Directory (Join-Path $dataRootFixture 'gateway')

        [IO.File]::WriteAllText((Join-Path $dataRootFixture 'unexpected.txt'), 'unexpected')
        Assert-BehaviorThrows { Assert-LifeOSExpectedImmediateChildren -Root $dataRootFixture -ExpectedChildren $mapping -RequireAll } 'unexpected shared-root files are rejected'
        Remove-Item -LiteralPath (Join-Path $dataRootFixture 'unexpected.txt') -Force

        Remove-Item -LiteralPath (Join-Path $dataRootFixture 'gateway') -Recurse -Force
        [IO.File]::WriteAllText((Join-Path $dataRootFixture 'gateway'), 'wrong type')
        Assert-BehaviorThrows { Assert-LifeOSExpectedImmediateChildren -Root $dataRootFixture -ExpectedChildren $mapping -RequireAll } 'expected shared-root file is rejected as a child directory'
        Remove-Item -LiteralPath (Join-Path $dataRootFixture 'gateway') -Force
        Ensure-Directory (Join-Path $dataRootFixture 'gateway')

        $script:sharedRootCrossService = $true
        Assert-BehaviorThrows { Assert-LifeOSExpectedImmediateChildren -Root $dataRootFixture -ExpectedChildren $mapping -RequireAll } 'cross-service shared-root access is rejected'

        # Junction creation can be unavailable to an unprivileged test
        # account. When the host permits it, the actual reparse rejection is
        # required; otherwise record the external native gate explicitly.
        $reparseTarget = Join-Path $temp 'reparse-target'
        Ensure-Directory $reparseTarget
        $reparsePath = Join-Path $dataRootFixture 'gateway'
        Remove-Item -LiteralPath $reparsePath -Recurse -Force
        $reparseCreated = $false
        try {
            New-Item -ItemType Junction -Path $reparsePath -Target $reparseTarget -ErrorAction Stop | Out-Null
            $reparseCreated = $true
        } catch {
            $category = [string]$_.CategoryInfo.Category
            if ($category -notin @('PermissionDenied', 'InvalidOperation', 'NotImplemented')) { throw }
            Write-Host "SKIP: shared-root reparse fixture unavailable ($category)."
        }
        if ($reparseCreated) {
            try {
                Assert-BehaviorThrows { Assert-LifeOSExpectedImmediateChildren -Root $dataRootFixture -ExpectedChildren $mapping -RequireAll } 'reparse shared-root child is rejected'
            } finally {
                Remove-Item -LiteralPath $reparsePath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Variable -Name sharedRootCrossService -Scope Script -ErrorAction SilentlyContinue
    }
}


& {
    # Exercise owner and inheritance with the real ACL validator while isolating
    # the Windows filesystem adapter from the rest of the behavioral suite.
    $script:aclOwner = 'S-1-5-21-1-2-3-4'; $script:aclProtected = $true
    function Assert-NoReparsePath { param($Path) }
    function Get-Item { param($LiteralPath, [switch]$Force) return [pscustomobject]@{ FullName=$LiteralPath; PSIsContainer=$false } }
    function Get-Acl {
        param($LiteralPath)
        $entries = @()
        foreach ($sid in @('S-1-5-21-1-2-3-4', 'S-1-5-18', 'S-1-5-32-544')) {
            $identity = [pscustomobject]@{ Value=$sid }
            $identity | Add-Member -MemberType ScriptMethod -Name Translate -Value { param($Type) return $this }
            $entries += [pscustomobject]@{ IdentityReference=$identity; AccessControlType='Allow'; PropagationFlags=0; FileSystemRights=[long][Security.AccessControl.FileSystemRights]::FullControl }
        }
        $acl = [pscustomobject]@{ AreAccessRulesProtected=$script:aclProtected; Access=$entries }
        $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($Type) return [pscustomobject]@{ Value=$script:aclOwner } }
        return $acl
    }
    Assert-RestrictedAcl 'fixture' 'S-1-5-21-1-2-3-4'
    $script:aclOwner = 'S-1-5-32-545'
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture' 'S-1-5-21-1-2-3-4' } 'untrusted ACL owner is rejected'
    $script:aclOwner = 'S-1-5-21-1-2-3-4'; $script:aclProtected = $false
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture' 'S-1-5-21-1-2-3-4' } 'unprotected inheritance is rejected'
}


Assert-BehaviorThrows { Get-AuthorityInstallMode @() @('calendar.json') @() $false $true } 'installed code cannot authorize legacy leftovers'
Assert-BehaviorThrows { Get-AuthorityInstallMode @() @('calendar.json.retry.json') @() $false $false } 'orphan legacy companion is not complete authority'
Assert-Behavior ((Get-AuthorityInstallMode @() @('calendar.json') @() $true $true) -eq 'upgrade') 'versioned empty authority never imports legacy leftovers'
Assert-BehaviorThrows { Assert-AclRoleRights 'read' ([long][Security.AccessControl.FileSystemRights]::Read) 0 $false $true } 'service executable requires execute rights'

& {
    # A missing object is a no-op; a denied provider is not evidence of absence.
    function Get-ScheduledTask { return @() }
    function Get-Service { return @() }
    function Disable-ScheduledTask { throw 'unexpected mutation' }
    function Stop-ScheduledTask { throw 'unexpected mutation' }
    function Stop-Service { throw 'unexpected mutation' }
    function Unregister-ScheduledTask { throw 'unexpected mutation' }
    $record = [pscustomobject]@{ Name='LifeOSCodexCollector'; Exists=$false; TaskPath='\' }
    $manifest = [pscustomobject]@{ codexTask=$record; snapshotTask=[pscustomobject]@{ Name='LifeOSTailscaleSnapshot'; Exists=$false; TaskPath='\' } }
    Stop-DeploymentTaskBarrier $manifest 'unused'
    Stop-LifeOSService 'LifeOSAPI'
    $script:serviceRecordReads = 0
    function Get-ServiceRecord { $script:serviceRecordReads++; return $null }
    function Invoke-NativeChecked { throw 'absent service must not mutate SCM' }
    Assert-BehaviorThrows { Restore-LifeOSServiceSnapshot ([pscustomobject]@{ Name='LifeOSAPI'; Exists=$false }) } 'partial service snapshots are rejected before SCM mutation'
    $partialServiceMap = [ordered]@{ LifeOSAPI = $apiServiceSnapshot }
    $partialServiceManifest = [pscustomobject]@{}
    Assert-BehaviorThrows { Restore-LifeOSServiceSnapshots -Snapshots $partialServiceMap -Manifest $partialServiceManifest } 'partial service snapshot maps are rejected before SCM mutation'
    Assert-Behavior ($script:serviceRecordReads -eq 0) 'partial service snapshot maps perform no SCM reads or mutations.'
    $absentServiceSnapshot = [ordered]@{ Name='LifeOSAPI'; Exists=$false; State='Stopped'; StartMode='Disabled'; StartName=$null; BinaryPath=$null; Dependencies=@(); DelayedAutoStartPresent=$false; DelayedAutoStart=$null; ServiceSidTypePresent=$false; ServiceSidType=$null; FailureActionsPresent=$false; FailureActions=@(); FailureFlagPresent=$false; FailureFlag=$null }
    Assert-CompleteLifeOSServiceSnapshot $absentServiceSnapshot
    Restore-LifeOSServiceSnapshot $absentServiceSnapshot
    Restore-CodexCollectorTask $record 'LifeOSCodexCollector'
    Restore-TailscaleSnapshotTask $record 'LifeOSTailscaleSnapshot'
    function Get-ScheduledTask { throw 'provider unavailable' }
    Assert-BehaviorThrows { Stop-DeploymentTaskBarrier $manifest 'unused' } 'task enumeration errors fail closed'
    function Get-Service { throw 'provider unavailable' }
    Assert-BehaviorThrows { Stop-LifeOSService 'LifeOSAPI' } 'service enumeration errors fail closed'
    Remove-Variable -Name serviceRecordReads -Scope Script
}

& {
    $script:restoredTaskEvents = @()
    function Get-ScheduledTask { return [pscustomobject]@{ TaskName='LifeOSCodexCollector'; TaskPath='\' } }
    function Unregister-ScheduledTask { param($TaskName, $TaskPath, [switch]$Confirm) $script:restoredTaskEvents += 'remove-root' }
    function Restore-LegacyTask { param($Snapshot, $TaskName) $script:restoredTaskEvents += ('restore-' + $Snapshot.TaskPath) }
    Restore-CodexCollectorTask ([pscustomobject]@{ Exists=$true; TaskPath='\Previous\' }) 'LifeOSCodexCollector'
    Assert-Behavior (($script:restoredTaskEvents -join ',') -eq 'remove-root,restore-\Previous\') 'collector rollback removes the replacement at root before restoring the prior folder'
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-receipt-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $data = Join-Path $temp 'data'; Ensure-Directory $data
    $usage = Join-Path $temp 'usage.jsonl'
    $manifestPath = Join-Path $temp 'manifest.json'
    $code = Join-Path $temp 'code.js'; $codeBackup = Join-Path $temp 'previous-code.js'
    [IO.File]::WriteAllText($code, 'new-code'); [IO.File]::WriteAllText($codeBackup, 'prior-code')
    $script:unexpectedRecoveryAction = $false
    $manifest = [pscustomobject]@{ transactionId='receipt-fixture'; generation='generation'; operatorSid='fixture'; manifestPath=$manifestPath; collectorTransition=[pscustomobject]@{ phase='running'; usageBefore='absent'; startedAtUtc='fixture-run' }; paths=[pscustomobject]@{ backupDirectory=$temp; gatewayData=$data; usageHistory=$usage }; backups=@([pscustomobject]@{ destination=$code; backup=$codeBackup; priorExists=$true; changed=$true; phase='complete' }) }
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl) }
    try {
        Write-JsonAtomic $manifestPath $manifest
        [IO.File]::WriteAllText($usage, 'acknowledged-observation')
        $manifest.collectorTransition.phase = 'terminal'
        Set-JournalProperty $manifest.collectorTransition 'usageAfter' (Get-RecoveryArtifactState $usage)
        Save-CollectorReceipt $manifest
        $realWrite = ${function:Write-JsonAtomic}
        function Write-JsonAtomic {
            param($Path, $Value, $OperatorSid, $MaxBytes)
            if ($Path -eq $manifestPath) { throw 'fixture manifest write failure' }
            & $realWrite -Path $Path -Value $Value -OperatorSid $OperatorSid -MaxBytes $MaxBytes
        }
        Assert-BehaviorThrows { Write-JsonAtomic $manifestPath $manifest } 'collector manifest write fault is injected'
        $persisted = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
        Assert-Behavior ($persisted.collectorTransition.phase -eq 'running') 'failed manifest write preserves the previous rollback baseline'
        Assert-Behavior (Test-CollectorUsagePreserved $persisted) 'terminal receipt preserves observations after a failed manifest write'
        Restore-ManifestArtifacts $persisted $temp
        $script:stageAttempts = 0
        Assert-BehaviorThrows { Invoke-RecoveryStage $persisted 'fixture-stage' { $script:stageAttempts++; throw 'fixture stage failure' } } 'stage failure after authority restoration'
        Invoke-RecoveryStage $persisted 'fixture-stage' { $script:stageAttempts++ }
        Assert-Behavior ($script:stageAttempts -eq 2) 'recovery stage retries after authority is restored'
        Invoke-RecoveryStage $persisted 'fixture-stage' { $script:stageAttempts += 100 }
        Assert-Behavior ($script:stageAttempts -eq 2) 'completed recovery stages are idempotent'
        Assert-Behavior ((Get-Content -LiteralPath $usage -Raw) -eq 'acknowledged-observation') 'rollback keeps the last observation'
        $other = $persisted | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $other.generation = 'unrelated'
        Assert-BehaviorThrows { Invoke-RecoveryStage $other 'fixture-stage' { $script:unexpectedRecoveryAction = $true } } 'foreign recovery stage journal is rejected'
        Assert-BehaviorThrows { Test-CollectorUsagePreserved $other } 'foreign collector receipt is rejected'
        [IO.File]::WriteAllText($usage, 'later-observation')
        Assert-BehaviorThrows { Invoke-RecoveryStage $persisted 'fixture-stage-guard' { $script:unexpectedRecoveryAction = $true } } 'stage rejects later authority writes'
        [IO.File]::WriteAllText($usage, 'acknowledged-observation')
        Enable-RecoveryWriterRestoration $persisted
        Enable-RecoveryWriterRestoration $persisted
        [IO.File]::WriteAllText($usage, 'prior-writer-new-observation')
        [IO.File]::WriteAllText((Join-Path $data 'new-authority.json'), 'prior-writer-new-authority')
        Restore-ManifestArtifacts $persisted $temp
        Invoke-RecoveryStage $persisted 'fixture-stage' { $script:stageAttempts++ }
        Assert-Behavior ((Get-Content -LiteralPath $usage -Raw) -eq 'prior-writer-new-observation') 'released prior writers retain observations on a later recovery retry'
        Assert-Behavior (Test-Path -LiteralPath (Join-Path $data 'new-authority.json')) 'released authority trees are never restored a second time'
        Assert-BehaviorThrows { Invoke-RecoveryStage $other 'fixture-stage' { $script:unexpectedRecoveryAction = $true } } 'writer release never bypasses transaction ownership'
        [IO.File]::WriteAllText($code, 'unrelated-code')
        Assert-BehaviorThrows { Invoke-RecoveryStage $persisted 'fixture-stage' { $script:unexpectedRecoveryAction = $true } } 'writer release never bypasses restored code integrity'
        Assert-Behavior (-not $script:unexpectedRecoveryAction) 'rejected recovery stages perform no action'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-absent-usage-' + [Guid]::NewGuid().ToString('N'))
    Ensure-Directory $temp
    $data = Join-Path $temp 'data'; Ensure-Directory $data
    $usage = Join-Path $temp 'usage.jsonl'
    $manifest = [pscustomobject]@{ transactionId='absent'; generation='generation'; operatorSid='fixture'; manifestPath=(Join-Path $temp 'manifest.json'); collectorTransition=$null; paths=[pscustomobject]@{ backupDirectory=$temp; gatewayData=$data; usageHistory=$usage }; backups=@() }
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$AllowInherited) }
    function Set-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, [switch]$File, [switch]$SkipSnapshot, [string[]]$AllowedOwnerSids, [switch]$InheritableSystemFullControl) }
    try {
        Restore-ManifestArtifacts $manifest $temp
        [IO.File]::WriteAllText($usage, 'new-observation')
        Assert-BehaviorThrows { Restore-ManifestArtifacts $manifest $temp } 'an absent usage baseline still guards future writes'
    } finally { Remove-Item -LiteralPath $temp -Recurse -Force }
}

& {
    # Real role aggregation with Windows-shaped ACEs, not just the pure mask helper.
    $operator = 'S-1-5-21-1-2-3-4'; $serviceSid = 'S-1-5-80-1-2-3-4-5'
    $otherServiceSid = 'S-1-5-80-9-8-7-6-5'
    $script:aclOwner = $operator
    $script:serviceGrant = [long][Security.AccessControl.FileSystemRights]::ReadAndExecute
    $script:servicePropagation = 0; $script:includeService = $true
    function Assert-NoReparsePath { param($Path) }
    function Get-Item { param($LiteralPath, [switch]$Force) return [pscustomobject]@{ FullName=$LiteralPath; PSIsContainer=$false } }
    function Get-Acl {
        param($LiteralPath)
        $entries = @()
        $sids = @($operator, 'S-1-5-18', 'S-1-5-32-544')
        if ($script:includeService) { $sids += $serviceSid }
        foreach ($sid in $sids) {
            $identity = [pscustomobject]@{ Value=$sid }
            $identity | Add-Member -MemberType ScriptMethod -Name Translate -Value { param($Type) return $this }
            $entries += [pscustomobject]@{ IdentityReference=$identity; AccessControlType='Allow'; PropagationFlags=$(if ($sid -eq $serviceSid) { $script:servicePropagation } else { 0 }); FileSystemRights=$(if ($sid -eq $serviceSid) { $script:serviceGrant } else { [long][Security.AccessControl.FileSystemRights]::FullControl }) }
        }
        $acl = [pscustomobject]@{ AreAccessRulesProtected=$true; Access=$entries; Owner=$script:aclOwner }
        $acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { param($Type) return [pscustomobject]@{ Value=$this.Owner } }
        return $acl
    }
    Assert-RestrictedAcl 'fixture.exe' $operator @($serviceSid)
    $script:serviceGrant = [long][Security.AccessControl.FileSystemRights]::Read
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.exe' $operator @($serviceSid) } 'actual service identity must execute the image'
    Assert-RestrictedAcl 'fixture.secret' $operator @($serviceSid)
    $script:serviceGrant = [long][Security.AccessControl.FileSystemRights]::Modify
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.secret' $operator @($serviceSid) } 'actual service identity cannot write its secret'
    $script:serviceGrant = [long][Security.AccessControl.FileSystemRights]::Read
    $script:servicePropagation = [Security.AccessControl.PropagationFlags]::InheritOnly
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.secret' $operator @($serviceSid) } 'inherit-only service grant cannot read this object'
    # A service-created writable child may have the service SID as owner, but
    # that provenance is accepted only for the matching Modify role and only
    # when the caller explicitly scopes the writable tree.
    $script:serviceGrant = $modifyRights
    $script:servicePropagation = 0
    $script:aclOwner = $serviceSid
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.data' $operator @() @($serviceSid) } 'service-owned writable child is rejected without an explicit scope'
    Assert-RestrictedAcl 'fixture.data' $operator @() @($serviceSid) -AllowedOwnerSids @($serviceSid)
    # The supplement catalog is a gateway-owned file, so the same explicit
    # owner scope applies without requiring directory inheritance.
    Assert-RestrictedAcl 'supplements.sqlite3' $operator @() @($serviceSid) -AllowedOwnerSids @($serviceSid)
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.data' $operator @() @($serviceSid) -AllowedOwnerSids @('S-1-5-32-545') } 'owner scope rejects non-service identities'
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.data' $operator @($serviceSid) @() -AllowedOwnerSids @($serviceSid) } 'owner scope requires the service Modify role'

    # A different service or an ordinary account can never use the matching
    # service's writable-tree exception.  The same service owner is also
    # rejected on protected code, secrets, and authenticated backups.
    $script:aclOwner = $otherServiceSid
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.data' $operator @() @($serviceSid) -AllowedOwnerSids @($serviceSid) } 'other service owner is rejected in a writable tree'
    Assert-BehaviorThrows { Assert-RestrictedAcl 'supplements.sqlite3' $operator @() @($serviceSid) -AllowedOwnerSids @($serviceSid) } 'other service owner is rejected on the gateway supplement catalog'
    $script:aclOwner = 'S-1-5-32-545'
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.data' $operator @() @($serviceSid) -AllowedOwnerSids @($serviceSid) } 'non-service owner is rejected in a writable tree'
    $script:aclOwner = $serviceSid
    $script:serviceGrant = [long][Security.AccessControl.FileSystemRights]::ReadAndExecute
    $script:servicePropagation = 0; $script:includeService = $true
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.exe' $operator @($serviceSid) } 'service ownership is rejected on protected code'
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.secret' $operator @($serviceSid) } 'service ownership is rejected on protected secrets'
    $backupManifest = [pscustomobject]@{ operatorSid = $operator }
    Assert-BehaviorThrows { Assert-AuthenticatedBackup -Manifest $backupManifest -ManifestPath 'fixture.backup' -BackupDirectory 'fixture.backup' } 'service ownership is rejected on authenticated backups'
    $script:aclOwner = $operator
    $script:servicePropagation = 0; $script:includeService = $false
    Assert-BehaviorThrows { Assert-RestrictedAcl 'fixture.secret' $operator @($serviceSid) } 'owner rights do not substitute for actual service rights'

    # A scoped owner exception is also valid for the catalog file itself;
    # file ACLs have no descendants and therefore need no inheritable SYSTEM
    # grant. Stub only the mutation boundary after the real ACL assertions so
    # this specifically exercises Set-RestrictedAcl's file contract.
    $catalogFile = [IO.Path]::GetTempFileName()
    function Register-AclSnapshot { param($Path) }
    function Remove-TransientLogonAclRules { param($Path, [switch]$Recurse, $KeepServiceSids) }
    function Assert-ExplicitAclAllowTree { param($Path, $OperatorSid, $ReadSids, $ModifySids) }
    function Get-LifeOSFrozenTreeInventory { param($Path, [switch]$File) return @() }
    function Assert-RestrictedAcl { param($Path, $OperatorSid, $ReadSids, $ModifySids, $AllowedOwnerSids, [switch]$AllowInherited, [switch]$Recurse) }
    try {
        Set-RestrictedAcl $catalogFile $operator @() @($serviceSid) -File -AllowedOwnerSids @($serviceSid)
        Assert-Behavior $true 'gateway supplement catalog file owner scope does not require inheritable SYSTEM rights'
    } finally { Remove-Item -LiteralPath $catalogFile -Force -ErrorAction SilentlyContinue }
}
Write-Host 'PASS: remaining Windows deployment/recovery behavioral assertions'


& {
    $script:serveRetryState = '{"Web":{"node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}}},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
    $before = $script:serveRetryState
    function Get-TailscaleStatusJson { param($TailscaleExecutable) return $script:serveRetryState }
    function Invoke-NativeChecked { throw 'already-restored Serve must not mutate' }
    Restore-TailscaleServeSnapshot -TailscaleExecutable 'fixture' -Json $before -ExpectedAfterJson '{}'
    $script:serveRetryState = $before.Replace('127.0.0.1:8421', '127.0.0.1:9000')
    Assert-BehaviorThrows { Restore-TailscaleServeSnapshot -TailscaleExecutable 'fixture' -Json $before -ExpectedAfterJson '{}' } 'Serve retry rejects a changed route after restoration'
}
Write-Host 'PASS: exact legacy Serve restoration is retryable without route mutation'
