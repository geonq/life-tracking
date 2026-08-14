[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$files = @(Get-ChildItem -LiteralPath $root -File -Include '*.ps1', '*.py' -Recurse |
    Where-Object { $_.FullName -ne $PSCommandPath })
$text = ($files | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"

function Assert-Text {
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    if ($text -notmatch $Pattern) { throw "FAIL: $Message" }
}

function Assert-NotText {
    param([Parameter(Mandatory)][string]$Pattern, [Parameter(Mandatory)][string]$Message)
    if ($text -match $Pattern) { throw "FAIL: $Message" }
}

Assert-Text 'LifeOSAPI' 'API service identity is present.'
Assert-Text 'LifeOSGateway' 'Gateway service identity is present.'
Assert-Text 'NT SERVICE\\LifeOSAPI' 'API virtual account is used.'
Assert-Text 'NT SERVICE\\LifeOSGateway' 'Gateway virtual account is used.'
Assert-Text 'sidtype.*unrestricted' 'Service SID mode is unrestricted.'
Assert-Text 'delayed-auto' 'Gateway is delayed automatic-start.'
Assert-Text 'LifeOSAPI.*Tailscale|Tailscale.*LifeOSAPI' 'Gateway depends on API and Tailscale.'
Assert-Text 'restart/60000/restart/60000/restart/60000' 'Recovery is restart-only at 60-second intervals.'
Assert-Text 'reset.*86400|86400.*reset' 'Recovery reset period is one day.'
Assert-Text '127\.0\.0\.1:8787' 'API loopback port is fixed.'
Assert-Text '127\.0\.0\.1:8421' 'Gateway loopback port is fixed.'
Assert-Text 'https=8420' 'Serve uses port 8420.'
Assert-Text 'usage-history\.jsonl' 'Usage history migration is present.'
Assert-Text 'Copy-FileVerifiedAtomic' 'Atomic hash-verified file migration is present.'
Assert-Text 'Disable-LegacyTaskAfterCutover' 'Legacy task is disabled only through the cutover helper.'
Assert-Text 'Restore-LegacyTask' 'Rollback restores the legacy task.'
Assert-Text 'RandomNumberGenerator' 'Codex secret is generated from the OS CSPRNG.'
Assert-Text 'gateway_launcher\.py' 'Gateway uses the reviewed Python launcher.'
Assert-Text 'uvicorn' 'Gateway launcher runs the FastAPI app under uvicorn.'
Assert-Text 'LIFEOS_DATA_DIR' 'Gateway data root is explicitly supplied.'
Assert-Text 'CLAUDE_INGEST_SECRET_FILE' 'Claude secret is supplied by path.'
Assert-NotText '(?i)\b(LocalSystem|LocalService|NetworkService)\b' 'Broad built-in service accounts are not used.'
Assert-NotText '(?i)\bdomke\\|C:\\Users\\|/Users/' 'Usernames and user-profile paths are not embedded.'
Assert-NotText '(?i)tailscale\s+funnel' 'The toolkit never invokes Funnel.'
Assert-NotText '(?i)(Unregister-ScheduledTask|Remove-ScheduledTask)' 'The legacy task is never deleted.'
Assert-NotText '(?i)restart\s*/\s*\d+\s*/\s*reboot' 'SCM recovery never reboots.'
Assert-NotText '(?i)shell\s*=\s*True' 'The Python launcher never uses a shell.'

Write-Host ("PASS: {0} deployment static assertions" -f 25)
