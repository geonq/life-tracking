[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deploy = Split-Path -Parent $PSScriptRoot
. (Join-Path $deploy 'Deployment.Common.ps1')

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
Assert-Behavior (-not (Test-TailscaleServeEmpty $unrelated)) 'non-empty unrelated Serve state is not misclassified as empty.'
Assert-Behavior ((Get-TailscaleServeFingerprint $withLifeOS -ExcludeLifeOSRoute) -eq (Get-TailscaleServeFingerprint $unrelated -ExcludeLifeOSRoute)) 'unrelated Serve fingerprint is unchanged by the LifeOS route.'

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
