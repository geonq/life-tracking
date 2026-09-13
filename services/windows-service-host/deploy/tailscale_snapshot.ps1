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

function Get-JsonFromTailscale {
    param([Parameter(Mandatory)][string[]]$Arguments)
    if (-not (Test-Path -LiteralPath $TailscaleExecutable -PathType Leaf)) {
        throw 'Tailscale executable is missing.'
    }
    # `&` writes $LASTEXITCODE only for a native process or a script that calls
    # `exit`. Seed it immediately before the call so the read below is this
    # invocation's own result and never whatever sits in the scope chain.
    $global:LASTEXITCODE = 0
    $output = @(& $TailscaleExecutable @Arguments 2>$null)
    $exitCode = [int]$global:LASTEXITCODE
    if ($exitCode -ne 0 -or $output.Count -eq 0) {
        throw 'Tailscale status query failed.'
    }
    try {
        $value = ($output -join "`n") | ConvertFrom-Json -ErrorAction Stop
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
$parent = Split-Path -Parent $OutputPath
if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'Tailscale snapshot parent directory is missing.' }
# ServeConfig nests Web -> endpoint -> Handlers -> path -> handler fields;
# depth 20 keeps every reviewed level plus room for an unknown future field.
# PowerShell truncates silently past -Depth, so the reader's exact-shape check
# would reject a truncated payload rather than accept a wrong one.
$json = $payload | ConvertTo-Json -Depth 20
$bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
# Refuse to publish what the gateway would reject at startup: the writer fails
# loudly here instead of leaving an oversized file behind.
if ($bytes.Length -gt (256 * 1024)) { throw 'Tailscale snapshot payload is oversized.' }
$temp = Join-Path $parent ('.tailscale-state.' + [Guid]::NewGuid().ToString('N') + '.tmp')
try {
    [IO.File]::WriteAllBytes($temp, $bytes)
    Move-Item -LiteralPath $temp -Destination $OutputPath -Force
} finally {
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
