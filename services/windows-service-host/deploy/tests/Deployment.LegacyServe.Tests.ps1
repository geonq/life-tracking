[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deploy = Split-Path -Parent $PSScriptRoot
. (Join-Path $deploy 'Deployment.Common.ps1')

function Assert-LegacyServe {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Message)
    if (-not $Condition) { throw "FAIL: $Message" }
}

function Assert-LegacyServeThrows {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Message)
    $threw = $false
    try { & $Action } catch { $threw = $true }
    if (-not $threw) { throw "FAIL: expected rejection: $Message" }
}

# A PowerShell script may complete without assigning LASTEXITCODE. This is the
# exact path exercised by the Windows fake Tailscale executable in the other
# deployment suites.
$nativeFixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-native-invocation-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $nativeFixtureRoot -Force | Out-Null
try {
    $successfulScript = Join-Path $nativeFixtureRoot 'successful.ps1'
    [IO.File]::WriteAllText($successfulScript, "Write-Output 'ok'`r`n", [Text.UTF8Encoding]::new($false))
    Remove-Variable -Name LASTEXITCODE -ErrorAction SilentlyContinue
    $successResult = Invoke-NativeChecked $successfulScript @()
    Assert-LegacyServe ([int]$successResult.ExitCode -eq 0) 'a successful PowerShell script without LASTEXITCODE is treated as exit code zero.'
    Assert-LegacyServe ([string]$successResult.Output[0] -eq 'ok') 'successful script output is preserved.'

    $failingScript = Join-Path $nativeFixtureRoot 'failing.ps1'
    [IO.File]::WriteAllText($failingScript, "Write-Output 'failure'`r`nexit 17`r`n", [Text.UTF8Encoding]::new($false))
    Assert-LegacyServeThrows { Invoke-NativeChecked $failingScript @() } 'a nonzero script exit remains a hard failure.'
} finally {
    Remove-Item -LiteralPath $nativeFixtureRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$legacy = '{"Web":{"https://node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},"https://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}}},"TCP":{"8420":{"HTTPS":true}},"Services":{},"AllowFunnel":false,"Foreground":false}'
$unrelated = '{"Web":{"https://node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}}},"TCP":{},"Services":{},"AllowFunnel":false,"Foreground":false}'
$configured = '{"Web":{"https://node.example.ts.net:443":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:3000"}}},"https://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421","AcceptAppCaps":["lifeos.example/trusted-edge"]}}}},"TCP":{"8420":{"HTTPS":true}},"Services":{},"AllowFunnel":false,"Foreground":false}'

$legacyDecision = Get-TailscaleServeDecision $legacy
Assert-LegacyServe ($legacyDecision.Action -eq 'UpgradeLegacyMapping') 'the exact proxy-only HTTPS route is classified as UpgradeLegacyMapping.'
Assert-LegacyServe ([int]$legacyDecision.TcpMirrorCount -eq 1) 'the exact TCP HTTPS mirror is recorded as paired route state.'
Assert-LegacyServe ((Get-TailscaleServeFingerprint $legacy -ExcludeLifeOSRoute) -eq (Get-TailscaleServeFingerprint $unrelated -ExcludeLifeOSRoute)) 'the paired TCP mirror is excluded only with its Web route.'
Assert-LegacyServe ((Get-TailscaleServeDecision $configured).Action -eq 'AlreadyConfigured') 'the capability-bearing route remains idempotent.'

$wrongProxy = $legacy.Replace('http://127.0.0.1:8421', 'http://127.0.0.1:9000')
$extraHandlerField = $legacy.Replace('"Proxy":"http://127.0.0.1:8421"', '"Proxy":"http://127.0.0.1:8421","Text":"unexpected"')
$extraPath = $legacy.Replace('"/":{"Proxy":"http://127.0.0.1:8421"}', '"/":{"Proxy":"http://127.0.0.1:8421"},"/other":{"Proxy":"http://127.0.0.1:8421"}')
$wrongScheme = $legacy.Replace('https://node.example.ts.net:8420', 'http://node.example.ts.net:8420')
$tcpCollision = $legacy.Replace('"8420":{"HTTPS":true}', '"8420":{"HTTPS":true,"TCPForward":"127.0.0.1:9000"}')
$serviceCollision = $legacy.Replace('"Services":{}', '"Services":{"svc:other":{"endpoints":{"tcp:8420":"http://127.0.0.1:9000"}}}')
$rangeCollision = $legacy.Replace('https://node.example.ts.net:8420', 'https://node.example.ts.net:8419-8421')
$ambiguous = $legacy.Replace('"https://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}}', '"https://node.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}},"https://other.example.ts.net:8420":{"Handlers":{"/":{"Proxy":"http://127.0.0.1:8421"}}}')
foreach ($fixture in @(
    [pscustomobject]@{ Json = $wrongProxy; Name = 'wrong proxy' }
    [pscustomobject]@{ Json = $extraHandlerField; Name = 'extra handler field' }
    [pscustomobject]@{ Json = $extraPath; Name = 'extra Web path' }
    [pscustomobject]@{ Json = $wrongScheme; Name = 'non-HTTPS endpoint' }
    [pscustomobject]@{ Json = $tcpCollision; Name = 'extra TCP fields' }
    [pscustomobject]@{ Json = $serviceCollision; Name = 'service endpoint collision' }
    [pscustomobject]@{ Json = $rangeCollision; Name = 'port range collision' }
    [pscustomobject]@{ Json = $ambiguous; Name = 'ambiguous Web endpoint' }
)) {
    Assert-LegacyServeThrows { Get-TailscaleServeDecision $fixture.Json } $fixture.Name
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('lifeos-legacy-serve-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null
$fakeTailscale = Join-Path $tempRoot 'fake-tailscale.ps1'
$statePath = Join-Path $tempRoot 'serve-state.json'
$argumentLog = Join-Path $tempRoot 'arguments.log'
$fakeScript = @'
param()
$Arguments = @($args)
$statePath = $env:LIFEOS_LEGACY_SERVE_STATE_PATH
$argumentLog = $env:LIFEOS_LEGACY_SERVE_ARGUMENT_LOG
[IO.File]::AppendAllText($argumentLog, (($Arguments -join '|') + "`r`n"), [Text.UTF8Encoding]::new($false))
$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json

if ($Arguments.Count -ge 3 -and $Arguments[0] -eq 'serve' -and $Arguments[1] -eq 'status') {
    Write-Output (Get-Content -LiteralPath $statePath -Raw)
    exit 0
}

$hasCapability = $Arguments -contains '--accept-app-caps=lifeos.example/trusted-edge'
$isOff = $Arguments -contains 'off'
if ($Arguments -contains '--https=8420' -and $isOff) {
    if (-not $hasCapability) { throw 'targeted removal omitted the public capability selector.' }
    if ($null -ne $state.PSObject.Properties['Web'] -and $state.Web -is [System.Management.Automation.PSCustomObject]) {
        $webKey = @($state.Web.PSObject.Properties | Where-Object { $_.Name -match '(?i)^https://[^/]+:8420$' } | Select-Object -First 1)
        if ($webKey.Count -eq 1) { [void]$state.Web.PSObject.Properties.Remove($webKey[0].Name) }
        if (@($state.Web.PSObject.Properties).Count -eq 0) { [void]$state.PSObject.Properties.Remove('Web') }
    }
    if ($null -ne $state.PSObject.Properties['TCP'] -and $state.TCP -is [System.Management.Automation.PSCustomObject]) {
        [void]$state.TCP.PSObject.Properties.Remove('8420')
    }
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
    exit 0
}

if ($Arguments -contains '--https=8420' -and $Arguments -contains 'http://127.0.0.1:8421') {
    if ($null -eq $state.PSObject.Properties['Web']) { [void]($state | Add-Member -NotePropertyName Web -NotePropertyValue ([pscustomobject]@{})) }
    $webKey = @($state.Web.PSObject.Properties | Where-Object { $_.Name -match '(?i)^https://[^/]+:8420$' } | Select-Object -First 1)
    $targetKey = if ($webKey.Count -eq 1) { [string]$webKey[0].Name } else { 'https://node.example.ts.net:8420' }
    $handler = [ordered]@{ Proxy = 'http://127.0.0.1:8421' }
    if ($hasCapability) { $handler.AcceptAppCaps = @('lifeos.example/trusted-edge') }
    $endpoint = [pscustomobject]@{ Handlers = [pscustomobject]@{ '/' = [pscustomobject]$handler } }
    if ($webKey.Count -eq 1) { [void]$state.Web.PSObject.Properties.Remove($targetKey) }
    [void]($state.Web | Add-Member -NotePropertyName $targetKey -NotePropertyValue $endpoint)
    if ($null -eq $state.PSObject.Properties['TCP']) { [void]($state | Add-Member -NotePropertyName TCP -NotePropertyValue ([pscustomobject]@{})) }
    [void]($state.TCP | Add-Member -NotePropertyName '8420' -NotePropertyValue ([pscustomobject]@{ HTTPS = $true }) -Force)
    [IO.File]::WriteAllText($statePath, ($state | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
    exit 0
}
throw 'unexpected fake Tailscale invocation'
'@
[IO.File]::WriteAllText($fakeTailscale, $fakeScript, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($statePath, $legacy, [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText($argumentLog, '', [Text.UTF8Encoding]::new($false))
$previousStatePath = $env:LIFEOS_LEGACY_SERVE_STATE_PATH
$previousArgumentLog = $env:LIFEOS_LEGACY_SERVE_ARGUMENT_LOG
try {
    $env:LIFEOS_LEGACY_SERVE_STATE_PATH = $statePath
    $env:LIFEOS_LEGACY_SERVE_ARGUMENT_LOG = $argumentLog

    $upgraded = Configure-TailscaleServe $fakeTailscale
    Assert-LegacyServe ((Get-TailscaleServeDecision $upgraded).Action -eq 'AlreadyConfigured') 'Configure upgrades the legacy proxy-only mapping.'
    Assert-LegacyServe ((Get-TailscaleServeFingerprint $upgraded -ExcludeLifeOSRoute) -eq (Get-TailscaleServeFingerprint $legacy -ExcludeLifeOSRoute)) 'legacy upgrade preserves unrelated Serve state.'
    $upgradeInvocation = @(Get-Content -LiteralPath $argumentLog | Where-Object { $_ -like '*--accept-app-caps=lifeos.example/trusted-edge*http://127.0.0.1:8421*' })
    Assert-LegacyServe ($upgradeInvocation.Count -ge 1) 'legacy upgrade sends the trusted capability flag.'

    Restore-TailscaleServeSnapshot -TailscaleExecutable $fakeTailscale -Json $legacy -ExpectedAfterJson $upgraded | Out-Null
    $restored = Get-TailscaleStatusJson $fakeTailscale
    Assert-LegacyServe ((Get-TailscaleServeDecision $restored).Action -eq 'UpgradeLegacyMapping') 'rollback restores the proxy-only legacy decision.'
    Assert-LegacyServe ((Get-TailscaleServeFingerprint $restored) -eq (Get-TailscaleServeFingerprint $legacy)) 'rollback restores the exact pre-install Web and TCP mapping.'
    Assert-LegacyServe ($restored -notmatch 'AcceptAppCaps') 'rollback output does not retain the app capability.'

    $configuredAgain = Configure-TailscaleServe $fakeTailscale
    $changed = $configuredAgain | ConvertFrom-Json
    $changed.Web.PSObject.Properties['https://node.example.ts.net:443'].Value.Handlers.'/'.Proxy = 'http://127.0.0.1:3001'
    [IO.File]::WriteAllText($statePath, ($changed | ConvertTo-Json -Depth 30 -Compress), [Text.UTF8Encoding]::new($false))
    $logCountBeforeRefusal = @(Get-Content -LiteralPath $argumentLog).Count
    Assert-LegacyServeThrows {
        Restore-TailscaleServeSnapshot -TailscaleExecutable $fakeTailscale -Json $legacy -ExpectedAfterJson $configuredAgain
    } 'unrelated concurrent Serve change'
    $logCountAfterRefusal = @(Get-Content -LiteralPath $argumentLog).Count
    Assert-LegacyServe ($logCountAfterRefusal -eq ($logCountBeforeRefusal + 1)) 'concurrent-change refusal performs only the status read and no mutation.'
} finally {
    if ($null -eq $previousStatePath) { Remove-Item Env:LIFEOS_LEGACY_SERVE_STATE_PATH -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_LEGACY_SERVE_STATE_PATH = $previousStatePath }
    if ($null -eq $previousArgumentLog) { Remove-Item Env:LIFEOS_LEGACY_SERVE_ARGUMENT_LOG -ErrorAction SilentlyContinue }
    else { $env:LIFEOS_LEGACY_SERVE_ARGUMENT_LOG = $previousArgumentLog }
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'PASS: legacy Serve upgrade/rollback assertions'
