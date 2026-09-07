import asyncio
import importlib.util
import json
import re
from tempfile import TemporaryDirectory
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "services" / "windows-service-host" / "deploy"


def read(name: str) -> str:
    return (DEPLOY / name).read_text(encoding="utf-8")


def test_gateway_uses_separate_serve_and_identity_payloads() -> None:
    source = read("gateway_launcher.py")
    writer = read("tailscale_snapshot.ps1")
    # The gateway service account cannot reach Tailscale's Administrators-only
    # LocalAPI pipe, so the launcher must never shell out to it. Check the
    # import statements rather than the whole file: a future comment or
    # docstring mentioning subprocess must not fail this, and an import hidden
    # inside a function must not pass it.
    assert not re.search(r"(?m)^\s*(?:import\s+subprocess\b|from\s+subprocess\b)", source)
    assert "_run_tailscale" not in source
    assert "_tailscale_login" not in source
    assert "serve_status, expected_dns_name, login = _read_tailscale_snapshot()" in source
    # The writer produces both halves, so this is a consistency check on one
    # payload, not independent validation -- but it still catches a truncated
    # or malformed write.
    assert "_tailscale_dns_name(identity)" in source
    assert "_serve_is_exact(serve_status, expected_dns_name=expected_dns_name)" in source
    assert "LIFEOS_TAILSCALE_SNAPSHOT_PATH" in source
    assert "TAILSCALE_SNAPSHOT_MAX_AGE_SECONDS = 90" in source
    assert "TAILSCALE_SNAPSHOT_MAX_FUTURE_SECONDS = 5" in source
    assert "GetExtendedTcpTable" in source
    assert "QueryServiceStatusEx" in source
    assert "_is_tailscale_service_peer" in source
    assert "LIFEOS_TAILSCALE_SERVICE_NAME" in source
    assert "'serve', 'status', '--json'" in writer
    assert "'status', '--json'" in writer
    # The identity half is pruned to the one field the reader consumes so the
    # snapshot cannot leak peers, node keys, or tailnet addresses.
    assert "$prunedIdentity = [ordered]@{" in writer
    assert "Self = [ordered]@{ DNSName = $dnsName }" in writer
    # `$profile` is an automatic variable; the local must not shadow it.
    assert "$profile =" not in writer
    assert "$userProfile =" in writer
    assert "Tailscale snapshot payload is oversized." in writer


def test_tailscale_snapshot_task_is_system_owned_acl_bound_and_reversible() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    rollback = read("rollback.ps1")
    verify = read("verify.ps1")
    preflight = read("preflight.ps1")
    config = (
        ROOT / "services" / "windows-service-host" / "src" / "ServiceHostConfig.cs"
    ).read_text(encoding="utf-8")
    assert "function Register-TailscaleSnapshotTask" in common
    assert "function Start-TailscaleSnapshotTaskAndVerify" in common
    assert "function Assert-TailscaleSnapshotFile" in common
    assert "function Restore-TailscaleSnapshotTask" in common
    assert "<UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel>" in common
    assert "<UserId>S-1-5-18</UserId><LogonType>ServiceAccount</LogonType>" not in common
    assert "<Interval>PT1M</Interval>" in common
    # The snapshot file survives a reboot but its observedAt does not, and the
    # gateway is delayed-auto: without a boot trigger the launcher can lose the
    # startup race and exit.
    assert "<BootTrigger><Enabled>true</Enabled><Delay>PT15S</Delay></BootTrigger>" in common
    # Below the repetition interval, so one slow run cannot skip the next under
    # IgnoreNew and open a two-interval gap.
    assert "<ExecutionTimeLimit>PT30S</ExecutionTimeLimit>" in common
    assert "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File" in common
    assert "dnsName,identity,login,observedAt,schemaVersion,serve" in common
    # Principal and enabled state say nothing about what the task runs.
    assert "function Get-TailscaleSnapshotTaskAction" in common
    assert "function Assert-TailscaleSnapshotTaskAction" in common
    assert "Get-LegacyTaskActionFingerprint ([string]$xml)) -ne $expected" in common
    # LastTaskResult is a uint32; [int] overflows on an HRESULT.
    assert "[int]$info.LastTaskResult" not in common
    assert "[long]$info.LastTaskResult -ne 0" in common
    # Rollback must remove the task install registered at the root path even
    # when it is restoring a pre-existing one from a different folder.
    assert "Unregister-ScheduledTask -TaskName $TaskName -TaskPath '\\'" in common
    # `$` also matches before a trailing newline in .NET, so the PowerShell
    # validators must not use it where the reader uses re.fullmatch.
    assert "'\\A[A-Za-z0-9._+\\-]+@[A-Za-z0-9.-]+\\z'" in common
    assert "$login -notmatch '^[A-Za-z0-9" not in common
    # The snapshot is machine state; a gateway able to write it could forge the
    # identity assertion the launcher trusts.
    assert "$stateDirectory = Join-Path $paths.InstallRoot 'host\\state'" in install
    # SYSTEM is this directory's intended writer, so its grant must be
    # inheritable or tailscale-state.json carries no SYSTEM ACE at all.
    assert (
        "Set-RestrictedAcl -Path $stateDirectory -OperatorSid $operatorSid "
        "-ReadSids @($gatewaySid) -InheritableSystemFullControl"
    ) in install
    assert "if (-not $File -and $InheritableSystemFullControl) { $grant += '*S-1-5-18:(OI)(CI)(F)' }" in common
    assert "Assert-NoBroadAcl $stateDirectory" in install
    # The gateway must not outrace the SYSTEM task that republishes the
    # snapshot it refuses to start without.
    assert install.count("@('LifeOSAPI', $TailscaleServiceName, 'Schedule')") == 2
    assert "@('LifeOSAPI', $TailscaleServiceName, 'Schedule') 'delayed-auto'" in verify
    assert "LIFEOS_TAILSCALE_SNAPSHOT_PATH = $TailscaleSnapshotPath" in install
    assert "Register-TailscaleSnapshotTask -TaskName $TailscaleSnapshotTaskName" in install
    assert "Start-TailscaleSnapshotTaskAndVerify -TaskName $TailscaleSnapshotTaskName" in install
    assert "Restore-TailscaleSnapshotTask $snapshotTask $TailscaleSnapshotTaskName" in install
    assert "Restore-TailscaleSnapshotTask $snapshotTaskSnapshot $TailscaleSnapshotTaskName" in rollback
    assert "Assert-TailscaleSnapshotFile -Path $tailscaleSnapshot" in verify
    assert "$broadAclPaths += $stateDirectory" in verify
    # Neither Assert-NoBroadAcl nor Assert-RestrictedAcl would catch a Modify
    # grant to the gateway's own SID on the state it is only allowed to read.
    assert "function Assert-SidHasNoWriteAcl" in verify
    assert "Assert-SidHasNoWriteAcl -Path $stateDirectory -Sid $gatewaySid" in verify
    assert "Assert-SidHasNoWriteAcl -Path $tailscaleSnapshot -Sid $gatewaySid" in verify
    assert "Assert-SidHasNoAllowAcl -Path $stateDirectory -Sid $apiSid" in verify
    # Get-Acl renders virtual service accounts as NT SERVICE\\<name>; compare
    # translated SIDs so a forbidden service ACE cannot pass silently.
    assert "function Assert-ServiceSidNotAllowed" in verify
    assert "IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value" in verify
    assert not re.search(r"IdentityReference\.Value.*DeniedSid", verify)
    # SYSTEM runs the staged script with -ExecutionPolicy Bypass every minute.
    assert "Get-FileSha256 $tailscaleSnapshotScript) -ne (Get-FileSha256 $reviewedSnapshotScript)" in verify
    assert "Assert-TailscaleSnapshotTaskAction -TaskName $TailscaleSnapshotTaskName" in verify
    # Get-ScheduledTask normalizes well-known principals.
    assert "function Resolve-TaskPrincipalSid" in verify
    assert "'S-1-5-18', 'SYSTEM', 'NT AUTHORITY\\SYSTEM'" in verify
    # A transient ExecutionTimeLimit stop is not a verification failure; the
    # published file is the verdict.
    assert "[long]$snapshotInfo.LastTaskResult -ne 0" in verify
    assert "Write-Warning ('The Tailscale snapshot task last reported result" in verify
    # The v18 path keys are optional in the canonical validator, so verify must
    # not dereference them on a pre-v18 manifest under Set-StrictMode.
    assert "function Get-OptionalManifestPath" in verify
    assert "$manifest.paths.stateDirectory" not in verify
    assert "$manifest.paths.tailscaleSnapshot" not in verify
    assert "tailscale_snapshot.ps1" in preflight
    assert "WindowsPowerShell\\v1.0\\powershell.exe" in preflight
    assert "unsafeLink = $null -ne $linkType -and [string]$linkType -ne 'HardLink'" in common
    assert "unsafeTarget = $null -ne $target -and [string]$linkType -ne 'HardLink'" in common
    assert '"LIFEOS_TAILSCALE_SNAPSHOT_PATH",' in config
    assert 'or "LIFEOS_TAILSCALE_SNAPSHOT_PATH")' in config


def test_gateway_launcher_token_fixture_is_present_missing_and_redacted() -> None:
    launcher_path = DEPLOY / "gateway_launcher.py"
    spec = importlib.util.spec_from_file_location("lifeos_deployment_launcher_fixture", launcher_path)
    assert spec is not None and spec.loader is not None
    launcher = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(launcher)

    token = "t" * 32
    with TemporaryDirectory() as directory:
        root = Path(directory)
        present = root / "tailscale-edge.token"
        present.write_bytes(token.encode("ascii"))
        assert launcher._read_edge_token(present) == token

        missing = root / "missing.token"
        try:
            launcher._read_edge_token(missing)
        except launcher.EdgeTokenConfigurationError as exc:
            assert "missing" in str(exc)
            assert token not in str(exc)
        else:
            raise AssertionError("missing token fixture did not fail closed")

        invalid = root / "invalid.token"
        invalid.write_bytes((b"i" * 31) + b"\n")
        try:
            launcher._read_edge_token(invalid)
        except launcher.EdgeTokenConfigurationError as exc:
            assert "invalid" in str(exc)
            assert token not in str(exc)
        else:
            raise AssertionError("invalid token fixture did not fail closed")

        captured: dict = {}

        async def app(scope, _receive, _send):
            captured.update(scope)

        header = json.dumps({launcher.TRUSTED_EDGE_APP_CAPABILITY: [{"src": ["*"]}]}).encode("ascii")
        adapter = launcher.TrustedEdgeHeaderAdapter(app, token, peer_verifier=lambda _scope: True)
        asyncio.run(adapter({"type": "http", "headers": [
            (b"Tailscale-User-Login", b"operator@example.com"),
            (b"Tailscale-App-Capabilities", header),
            (b"X-LifeOS-Trusted-Edge", b"attacker-value"),
        ]}, None, None))
        assert (launcher.TRUSTED_EDGE_HEADER, token.encode("ascii")) in captured["headers"]
        assert all(name.lower() != launcher.TAILSCALE_APP_CAPABILITIES_HEADER for name, _ in captured["headers"])
        assert token not in repr(header)

        captured.clear()
        rejected = launcher.TrustedEdgeHeaderAdapter(app, token, peer_verifier=lambda _scope: False)
        asyncio.run(rejected({"type": "http", "headers": [
            (b"Tailscale-User-Login", b"operator@example.com"),
            (b"Tailscale-App-Capabilities", header),
            (b"X-LifeOS-Trusted-Edge", b"attacker-value"),
        ]}, None, None))
        assert all(name.lower() != launcher.TRUSTED_EDGE_HEADER for name, _ in captured["headers"])


def test_codex_task_has_file_only_secret_argument_and_cutover_gate() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    assert "[Parameter(Mandatory)][string]$SecretFile" in common
    assert "--secret-file" in common
    assert "Start-CodexCollectorAndVerify" in install
    assert "-SecretFile $codexSecret" in install
    assert "Wait-CodexUsageObservation" in common


def test_install_serializes_transactions_and_reports_tree_hash_path() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    rollback = read("rollback.ps1")
    assert "Global\\LifeOSDeploymentTransaction" in common
    assert "function Enter-LifeOSDeploymentTransaction" in common
    assert "WaitOne(0)" in common
    assert "function Exit-LifeOSDeploymentTransaction" in common
    assert "Could not hash tree item" in common
    assert "Enter-LifeOSDeploymentTransaction" in install
    assert "Exit-LifeOSDeploymentTransaction $deploymentMutex" in install
    assert "Enter-LifeOSDeploymentTransaction" in rollback
    assert "Exit-LifeOSDeploymentTransaction $deploymentMutex" in rollback
    assert install.index("$deploymentMutex = Enter-LifeOSDeploymentTransaction") < install.index("$apiIntent = New-ManifestIntent")


def test_rollback_requires_canonical_manifest_and_acl_snapshots() -> None:
    common = read("Deployment.Common.ps1")
    rollback = read("rollback.ps1")
    install = read("install.ps1")
    assert "Assert-CanonicalRollbackManifest" in rollback
    assert "schemaVersion -ne 2" in common
    assert "aclSnapshots" in common and "Restore-AclSnapshots" in common
    assert "aclSnapshots = New-Object System.Collections.ArrayList" in install
    for field in ("pythonBase", "pythonVenv", "installRoot", "runtimeRoot", "dataRoot", "logRoot", "gatewayDocuments"):
        assert f"{field} =" in install
    assert "Name = $LegacyTaskName" in install and "Name = $CodexTaskName" in install
    assert "Assert-AuthenticatedBackup" in common
    assert "observedAt -ge $NotBefore.ToUniversalTime()" in common
    assert "S-1-1-0" in common
    assert "Translate([Security.Principal.SecurityIdentifier])" in common


def test_legacy_listener_is_fail_closed_and_ready_state_safe() -> None:
    common = read("Deployment.Common.ps1")
    preflight = read("preflight.ps1")
    install = read("install.ps1")
    rollback = read("rollback.ps1")
    assert "Get-NetTCPConnection -LocalPort $Port -State Listen" in common
    assert "Test-LoopbackAddress" in common
    assert "Win32_Process" in common
    assert "CreationTimeUtc" in common
    assert "ExecutableSha256" in common and "MainSha256" in common
    assert "Get-LegacyGatewayApproval" in common
    assert "Get-LegacyTaskActionFingerprint" in common
    assert "Assert-LegacyTaskUnchanged" in common
    assert "SelectSingleNode('task:WorkingDirectory', $namespace)" in common
    assert "$action.WorkingDirectory" not in common
    assert "runtimePaths.Count -ne 1" in common
    assert "mainPaths.Count -ne 1" in common
    assert "Stop-Process -Id ([int]$Expected.ProcessId)" in common
    assert "Stop-LegacyGatewayForCutover" in install
    assert "Restore-LegacyGatewayListener" in rollback
    assert "legacyListener = [ordered]@{" in install
    assert "TaskMutated = $false" in install
    listener_block = install.split("legacyListener = [ordered]@{", 1)[1].split("    }", 1)[0]
    assert "CommandLine" not in listener_block
    assert "Write-Host" not in listener_block
    assert "Legacy 8421 listener is attributable" in preflight
    assert "State -eq 'Running'" not in install


def test_legacy_launcher_runtime_shape_is_static_and_exact() -> None:
    common = read("Deployment.Common.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")

    assert "function Get-LegacyLauncherRuntimeCandidates" in common
    assert "rootAssignmentLines.Count -ne 1" in common
    assert "rootAssignments.Count -ne 1" in common
    assert "runtimeInvocations.Count -ne 1" in common
    assert r'"\$root\\venv\\Scripts\\python\.exe"' in common
    assert "literalPaths.Count -ne 0" in common
    assert "rootInvocation.Count -ne 1" in common
    assert "$resolved -ine $expected" in common
    assert "function Normalize-WindowsAbsolutePath" in common
    assert "$normalized = $full.Replace('/', '\\')" in common
    assert "$normalized = $normalized.TrimEnd('\\')" in common
    assert "$expected = Normalize-WindowsAbsolutePath $ExpectedRuntimePath" in common
    assert "$resolved = Normalize-WindowsAbsolutePath (Join-Path $root 'venv\\Scripts\\python.exe')" in common
    assert "Test-Path -LiteralPath $resolved -PathType Leaf" in common
    assert "must identify exactly one run_server.ps1 launcher" in common
    assert "function Get-LegacyLauncherApprovalShape" in common
    assert "Get-LegacyLauncherApprovalShape -LauncherText $launcherText" in common
    assert "Assert-Text 'Get-LegacyLauncherRuntimeCandidates'" in static
    assert "Assert-Text 'runtimeInvocations.Count -ne 1'" in static
    assert r"Assert-Text '\$resolved\s+-ine\s+\$expected'" in static


def test_legacy_launcher_uvicorn_shape_and_rejection_cases_are_guarded() -> None:
    common = read("Deployment.Common.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")

    # These fixtures mirror the proven legacy run_server.ps1 shape and the
    # text-level rejection cases that must remain fail-closed.
    fixtures = {
        "approved": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "$root\\venv\\Scripts\\python.exe" -m uvicorn main:app '
            "--host 127.0.0.1 --port 8421\n"
        ),
        "literal_main_py": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "$root\\venv\\Scripts\\python.exe" main.py '
            "--host 127.0.0.1 --port 8421\n"
        ),
        "alternate_absolute_main_py": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "D:\\Other\\venv\\Scripts\\python.exe" main.py\n'
        ),
        "multiple_modules": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "$root\\venv\\Scripts\\python.exe" -m uvicorn main:app '
            "--host 127.0.0.1 --port 8421\n"
            '& "$root\\venv\\Scripts\\python.exe" -m uvicorn other:app\n'
        ),
        "dynamic_module": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "$root\\venv\\Scripts\\python.exe" -m uvicorn $module '
            "--host 127.0.0.1 --port 8421\n"
        ),
        "mismatched_root": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "$otherRoot\\venv\\Scripts\\python.exe" -m uvicorn main:app '
            "--host 127.0.0.1 --port 8421\n"
        ),
        "module_root_override": (
            '$root = "D:\\Hermes\\lifeos-server"\n'
            "Set-Location $root\n"
            '& "$root\\venv\\Scripts\\python.exe" -m uvicorn main:app '
            "--app-dir D:\\Other --host 127.0.0.1 --port 8421\n"
        ),
    }
    approved = fixtures["approved"]
    assert '$root = "D:\\Hermes\\lifeos-server"' in approved
    assert "Set-Location $root" in approved
    assert (
        '& "$root\\venv\\Scripts\\python.exe" -m uvicorn main:app '
        "--host 127.0.0.1 --port 8421"
    ) in approved
    assert "main.py" not in approved
    assert "main.py" in fixtures["literal_main_py"]
    assert "D:\\Other\\venv\\Scripts\\python.exe" in fixtures["alternate_absolute_main_py"]
    assert fixtures["multiple_modules"].count("-m uvicorn") == 2
    assert "-m uvicorn $module" in fixtures["dynamic_module"]
    assert "$otherRoot\\venv\\Scripts\\python.exe" in fixtures["mismatched_root"]
    assert "--app-dir" in fixtures["module_root_override"]
    literal_approved_invocation = r"-m\s+uvicorn\s+main:app\s+--host\s+127\.0\.0\.1\s+--port\s+8421"
    assert literal_approved_invocation in common
    assert r"Assert-Text ([regex]::Escape('-m\s+uvicorn\s+main:app'))" in static
    assert r"Assert-Text ([regex]::Escape('--host\s+127\.0\.0\.1\s+--port\s+8421'))" in static
    assert r"Assert-Text '-m\s+uvicorn\s+main:app'" not in static
    assert "moduleInvocation.Groups['module'].Value -cne 'main:app'" in common

    for marker in (
        "function Get-LegacyLauncherApprovalShape",
        "rootAssignmentLines.Count -ne 1",
        "rootAssignments.Count -ne 1",
        "locationInvocations.Count -ne 1",
        "runtimeInvocations.Count -ne 1",
        r"-m\s+uvicorn\s+main:app",
        r"--host\s+127\.0\.0\.1\s+--port\s+8421",
        "resolvedMain = Normalize-WindowsAbsolutePath",
        "Test-Path -LiteralPath $resolvedMain -PathType Leaf",
        "taskLiteralMainPaths",
        "literal main.py",
        "moduleInvocations.Count -ne 1",
        "moduleInvocation.Groups['server'].Value -cne 'uvicorn'",
        "moduleInvocation.Groups['module'].Value -cne 'main:app'",
        "app-dir|reload-dir",
        "launcher directory does not match its fixed root",
        "working directory does not match the fixed launcher root",
    ):
        assert marker in common

    for marker in (
        "Assert-Text 'Get-LegacyLauncherApprovalShape'",
        "Assert-Text 'locationInvocations.Count -ne 1'",
        r"Assert-Text ([regex]::Escape('-m\s+uvicorn\s+main:app'))",
        r"Assert-Text ([regex]::Escape('--host\s+127\.0\.0\.1\s+--port\s+8421'))",
        "Assert-Text 'resolvedMain =",
        r"Assert-Text 'Test-Path -LiteralPath \$resolvedMain -PathType Leaf'",
        "Assert-Text 'taskLiteralMainPaths'",
        r"Assert-Text 'literal main\.py'",
        "Assert-Text 'moduleInvocations.Count -ne 1'",
        "Assert-Text 'moduleInvocation.Groups.*server.*uvicorn'",
        "Assert-Text 'moduleInvocation.Groups.*module.*main:app'",
        r"Assert-Text 'app-dir\|reload-dir'",
        "Assert-Text 'launcher directory does not match its fixed root'",
        "Assert-Text 'working directory does not match the fixed launcher root'",
    ):
        assert marker in static


def test_legacy_listener_redirector_chain_fixtures_are_fail_closed() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")

    approved_parent = r"D:\Hermes\lifeos-server\venv\Scripts\python.exe"
    approved_base = r"C:\Python312\python.exe"
    shape = re.compile(
        r'^(?:"[^"\r\n]+"|[^\s]+)\s+-m\s+uvicorn\s+main:app'
        r'\s+--host\s+127\.0\.0\.1\s+--port\s+8421\s*$',
        re.IGNORECASE,
    )

    fixtures = (
        ("observed", approved_base, approved_base, approved_parent, 1,
         r'"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r'"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe", False, True),
        ("unrelated-parent", approved_base, approved_base, r"D:\Other\python.exe", 1,
         r'"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r'"D:\Other\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r"C:\Windows\System32\cmd.exe", False, False),
        ("alternate-runtime", r"C:\Python311\python.exe", approved_base, approved_parent, 1,
         r'"C:\Python311\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r'"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r"C:\Windows\System32\cmd.exe", False, False),
        ("missing-parent", approved_base, approved_base, "", 0, "", "", "", False, False),
        ("wrong-port", approved_base, approved_base, approved_parent, 1,
         r'"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 9999',
         r'"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r"C:\Windows\System32\cmd.exe", False, False),
        ("wrong-module", approved_base, approved_base, approved_parent, 1,
         r'"C:\Python312\python.exe" -m uvicorn other:app --host 127.0.0.1 --port 8421',
         r'"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r"C:\Windows\System32\cmd.exe", False, False),
        ("ambiguous-parent", approved_base, approved_base, approved_parent, 2,
         r'"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r'"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r"C:\Windows\System32\cmd.exe", False, False),
        ("deeper-python-chain", approved_base, approved_base, approved_parent, 1,
         r'"C:\Python312\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         r'"D:\Hermes\lifeos-server\venv\Scripts\python.exe" -m uvicorn main:app --host 127.0.0.1 --port 8421',
         approved_base, True, False),
    )
    for name, child, base, parent, parent_count, child_command, parent_command, grandparent, deeper_python, expected in fixtures:
        child_ok = bool(shape.fullmatch(child_command))
        parent_ok = parent_count == 1 and bool(shape.fullmatch(parent_command))
        relationship_ok = child.casefold() == base.casefold()
        parent_ok = parent_ok and parent.casefold() == approved_parent.casefold()
        grandparent_ok = not deeper_python and not bool(re.search(r"(?i)\bmain:app\b|(?:^|\s)-m\s+uvicorn(?:\s|$)", grandparent))
        assert (child_ok and parent_ok and relationship_ok and grandparent_ok) is expected, name

    for marker in (
        "function Get-PythonVenvBaseRelationship",
        "ExpectedExecutablePath",
        "pyvenv.cfg",
        "BaseExecutable",
        "ParentProcessId",
        "ParentCreationTimeUtc",
        "ParentExecutablePath",
        "ParentExecutableSha256",
        "ParentMainPath",
        "ParentMainSha256",
        "RuntimeRelationship = 'pyvenv-base-redirector'",
        "ChainDepth = 1",
        "parentProcesses.Count -ne 1",
        "grandparentProcesses.Count -gt 1",
        "grandparentProcesses.Count -eq 0",
        "grandparentProcesses.Count -eq 1",
        "unexpected deeper Python or uvicorn parent",
    ):
        assert marker in common
    for marker in (
        "ParentProcessId = [int]$legacyListener.ParentProcessId",
        "ParentExecutablePath = [string]$legacyListener.ParentExecutablePath",
        "RuntimeRelationship = [string]$legacyListener.RuntimeRelationship",
        "ChainDepth = [int]$legacyListener.ChainDepth",
    ):
        assert marker in install
    for marker in (
        "observed-child-redirector",
        "orphaned-grandparent",
        "orphaned-unrelated-parent",
        "unrelated-parent",
        "alternate-child-runtime",
        "missing-parent",
        "wrong-port",
        "wrong-module",
        "ambiguous-parent",
        "ambiguous-grandparent",
        "deeper-python-chain",
        "ParentCount = 2",
        "GrandparentCount = 0",
        "GrandparentCount = 2",
        "GrandparentExecutable = $approvedBaseExecutableFromPyvenv",
    ):
        assert marker in static


def test_legacy_finance_files_are_bounded_atomic_and_journaled() -> None:
    common = read("Deployment.Common.ps1")
    preflight = read("preflight.ps1")
    install = read("install.ps1")
    rollback = read("rollback.ps1")
    assert "LegacyGatewaySource" in preflight and "LegacyGatewaySource" in install
    assert "enablebanking-connections.json" in preflight
    assert "finance-summary.json" in preflight
    assert "Migrate-LegacyDataFile" in install
    assert "256 * 1024" in install and "1 * 1024 * 1024" in install
    assert "Assert-BoundedFile" in common
    assert "-MaxBytes $MaxBytes" in install
    assert "New-ManifestIntent" in install
    assert "phase = 'pending'" in install
    assert "Copy-FileVerifiedAtomic -Source $Source" in install
    assert "previous-enablebanking-connections.json" in install
    assert "previous-finance-summary.json" in install
    assert "Restore-ManifestArtifacts $manifest" in rollback
    assert "enablebanking-connections.json" in common
    assert "finance-summary.json" in common


def test_old_v2_manifests_remain_rollback_compatible() -> None:
    common = read("Deployment.Common.ps1")
    assert "'legacyListener'" in common
    assert "if ($null -ne $Manifest.PSObject.Properties['legacyListener'])" in common
    assert "if ($null -ne $manifest.PSObject.Properties['legacyListener']" in read("rollback.ps1")


def test_nested_static_suite_is_transferred_and_covers_manifest_gate() -> None:
    preflight = read("preflight.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")
    readme = read("README.md")
    assert "tests\\Deployment.Static.Tests.ps1" in preflight
    assert "Deployment static test" in preflight
    assert "New-ManifestIntent.*-Kind 'config'" in static
    assert "Assert-InstallOrder \"-Kind 'config'\" 'Write-JsonAtomic $gatewayConfig'" in static
    assert "tests\\Deployment.Static.Tests.ps1" in readme


def test_tailscale_serve_coexistence_and_targeted_rollback_are_wired() -> None:
    common = read("Deployment.Common.ps1")
    preflight = read("preflight.ps1")
    install = read("install.ps1")
    rollback = read("rollback.ps1")
    behavior = read("tests/Deployment.Behavior.Tests.ps1")
    readme = read("README.md")

    for marker in (
        "function Get-TailscaleServeDecision",
        "function Get-TailscaleServeFingerprint",
        "function Remove-LifeOSTailscaleServeRoute",
        "function Test-TailscaleTrustedEdgeAppCapability",
        "--accept-app-caps=",
        "--set-path=/",
        "route/port 8420",
        "route/port range covers 8420",
        "ExpectedAfterJson",
    ):
        assert marker in common
    assert "Get-TailscaleServeDecision $tailscaleStatus" in preflight
    assert "Deployment.Behavior.Tests.ps1" in preflight
    assert "Deployment.Static.Tests.ps1" in preflight
    assert "Save-InstallManifest $manifest $manifestPath" in install
    assert "$manifest.tailscaleStatusAfter = $serveStatus" in install
    assert "-ExpectedAfterJson $tailscaleExpectedAfter" in install
    assert "-ExpectedAfterJson $tailscaleExpectedAfter" in rollback
    assert "Configure-TailscaleServe $fakeTailscale" in behavior
    assert "concurrent unrelated Serve change" in behavior
    assert "missing post-install Serve snapshot" in behavior
    assert "Web port range collision" in behavior
    assert "It never resets the whole Serve" in readme


def test_tailscale_edge_token_is_path_only_and_fail_closed() -> None:
    common = read("Deployment.Common.ps1")
    preflight = read("preflight.ps1")
    install = read("install.ps1")
    launcher = read("gateway_launcher.py")
    behavior = read("tests/Deployment.Behavior.Tests.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")
    readme = read("README.md")

    for marker in (
        "function Assert-TailscaleEdgeTokenBytes",
        "function Assert-TailscaleEdgeTokenSource",
        "Get-LifeOSTailscaleEdgeTokenPath",
        "token value was not displayed",
        "optionalExpected",
        "tailscaleEdgeToken = (Get-LifeOSTailscaleEdgeTokenPath",
        "Test-TailscaleTrustedEdgeAppCapability",
        "--accept-app-caps=",
    ):
        assert marker in common
    for source in (preflight, install):
        assert "TailscaleEdgeTokenSource" in source
        assert "Assert-TailscaleEdgeTokenSource" in source
    assert "tailscaleEdgeTokenPath" in install
    assert "Set-SecretAcl $tailscaleEdgeTokenPath" in install
    assert "Assert-NoBroadAcl $tailscaleEdgeTokenPath" in install
    assert '"tailscaleEdgeTokenPath"' in launcher
    assert "_read_edge_token(Path(config[\"tailscaleEdgeTokenPath\"]))" in launcher
    assert '"LIFEOS_TAILSCALE_EDGE_TOKEN": edge_token' in launcher
    assert "class TrustedEdgeHeaderAdapter" in launcher
    assert "tailscale-app-capabilities" in launcher.lower()
    assert "TRUSTED_EDGE_HEADER" in launcher
    assert "Deployment.Behavior.Tests.ps1" in static
    assert "TailscaleEdgeTokenSource" in static
    assert "token value was not displayed" in behavior
    assert "tailscale-edge.token" in readme
    assert "Tailscale-App-Capabilities" in readme
    assert "no raw token" in readme.lower()
    assert not re.search(r"LIFEOS_TAILSCALE_EDGE_TOKEN\s*[:=]\s*['\"][^'\"]+['\"]", install)


def test_deployment_bundle_is_explicit_and_all_source_files_are_unignored() -> None:
    ignore = (ROOT / ".gitignore").read_text(encoding="utf-8")
    install = read("install.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")
    readme = read("README.md")
    for relative in (
        "Deployment.Common.ps1",
        "README.md",
        "gateway_launcher.py",
        "install.ps1",
        "preflight.ps1",
        "rollback.ps1",
        "tailscale_snapshot.ps1",
        "verify.ps1",
        "tests/Deployment.Behavior.Tests.ps1",
        "tests/Deployment.Static.Tests.ps1",
    ):
        assert f"services/windows-service-host/deploy/{relative}" in ignore
    assert "bundleVersion = 'v18'" in install
    assert "bundleFiles" in install
    assert "sourceSha256" in install
    assert "Get-TreeManifest" in install
    assert "bundleVersion" in static
    assert "v18" in readme


def test_static_suite_keeps_literal_powershell_variables_non_interpolated() -> None:
    static = read("tests/Deployment.Static.Tests.ps1")

    # Single-quote the PowerShell assertion pattern so strict mode does not
    # evaluate the literal $namespace while the transferred test starts.
    assert r"Assert-Text 'SelectSingleNode\(''task:WorkingDirectory'', \$namespace\)'" in static
    assert r'Assert-Text "SelectSingleNode\(' not in static


def test_python_runtime_resolver_supports_base_and_windows_venv_layouts() -> None:
    common = read("Deployment.Common.ps1")
    preflight = read("preflight.ps1")
    install = read("install.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")

    assert "function Resolve-PythonRuntimeSource" in common
    assert "rootInterpreter = Join-Path $sourceRoot 'python.exe'" in common
    assert "scriptsInterpreter = Join-Path $sourceRoot 'Scripts\\python.exe'" in common
    assert "Assert-NoReparsePath $rootInterpreter -AllowMissingLeaf" in common
    assert "Assert-NoReparsePath $scriptsInterpreter -AllowMissingLeaf" in common
    assert "hasRootInterpreter" in common and "hasScriptsInterpreter" in common
    assert "both python.exe and Scripts\\python.exe exist" in common
    assert "PythonPath = $stagedVenvRuntime.Executable" in install
    assert "PythonPath = $stagedBaseRuntime.Executable" in install
    assert "PythonLayout = $stagedVenvRuntime.Layout" in install
    assert "pythonRoot = if ([IO.Path]::GetFileName($pythonDirectory) -ieq 'Scripts')" in install
    assert "PATH = $pythonRoot + ';' + (Join-Path $pythonRoot 'Scripts')" in install
    assert "Assert-TrustedSourcePath $pythonSource $operatorSid" in preflight
    assert "Assert-TrustedSourcePath $pythonExecutable $operatorSid" in preflight
    assert "sys.version_info[:2] == (3,12)" in preflight
    assert "sys.version_info[:2] == (3,12)" in install
    assert "Invoke-NativeChecked -FilePath $pythonExecutable" in preflight
    assert "Join-Path $pythonSource 'python.exe'" not in preflight
    assert "Join-Path $venvTarget 'python.exe'" not in install
    assert "Resolve-PythonRuntimeSource -Requested $venvTarget" in install
    assert "Resolve-PythonRuntimeSource -Requested $baseTarget" in install
    assert r"Scripts\\python\.exe" in static
    assert "hasRootInterpreter" in static and "hasScriptsInterpreter" in static
    assert r"Assert-Text 'root\\\\venv\\\\Scripts\\\\python\\.exe'" in static


def test_python_import_checks_avoid_windows_native_c_argument_retokenization() -> None:
    preflight = read("preflight.ps1")
    install = read("install.ps1")

    assert 'os.environ["LIFEOS_DEPLOY_PREFLIGHT_GATEWAY_SOURCE"]' in preflight
    assert 'os.environ["LIFEOS_DEPLOY_PREFLIGHT_LAUNCHER_SOURCE"]' in preflight
    assert 'os.environ["LIFEOS_DEPLOY_STAGED_GATEWAY_SOURCE"]' in install
    # The runner spells the environment lookup with chr() so Windows
    # PowerShell 5.1 cannot strip quotes from the native -c argument. Assert
    # the safe runner shape and the bound variable instead of requiring the
    # unsafe, quote-bearing spelling.
    assert "$env:LIFEOS_DEPLOY_PREFLIGHT_IMPORT_CHECK = $gatewayImportCheck" in preflight
    assert "gatewayImportRunner = 'import os;exec(os.environ.get(chr(" in preflight
    assert "$env:LIFEOS_DEPLOY_STAGED_IMPORT_CHECK = $gatewayImportCheck" in install
    assert "gatewayImportRunner = 'import os;exec(os.environ.get(chr(" in install
    assert "Invoke-NativeChecked -FilePath $pythonExecutable -ArgumentList ([string[]]@('-I', '-c', $gatewayImportRunner)) -Quiet" in preflight
    assert "Invoke-NativeChecked -FilePath $pythonStage.PythonPath -ArgumentList ([string[]]@('-I', '-c', $gatewayImportRunner)) -Quiet" in install

    # A path after -c is the exact regression that made Python parse the
    # Windows API path as its program under Windows PowerShell 5.1.
    assert "Invoke-NativeChecked $pythonExecutable @('-I', '-c', $gatewayImportCheck, $GatewaySource, $PSScriptRoot)" not in preflight
    assert "Invoke-NativeChecked $pythonStage.PythonPath @('-I', '-c', $gatewayImportCheck, $gatewayTarget)" not in install


def test_native_invocations_bind_argument_arrays_by_name() -> None:
    sources = [
        read("Deployment.Common.ps1"),
        read("preflight.ps1"),
        read("install.ps1"),
        read("verify.ps1"),
        read("tests/Deployment.Behavior.Tests.ps1"),
        read("tests/Deployment.LegacyServe.Tests.ps1"),
    ]
    # Passing @('-flag', value) positionally lets PowerShell bind '-flag' to
    # Invoke-NativeChecked itself. Every call must bind the native argv array
    # through the declared ArgumentList parameter, preserving option-shaped
    # values for the child process.
    for source in sources:
        assert not re.search(r"Invoke-NativeChecked[^\r\n]*\s@\(", source)
    assert "-ArgumentList ([string[]]@('-I', '-c', $gatewayImportRunner))" in read("preflight.ps1")
    common = read("Deployment.Common.ps1")
    assert "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File $FilePath @ArgumentList" in common


def test_install_preflight_invocation_uses_named_parameter_splat() -> None:
    install = read("install.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")

    # An array splat passes alternating strings and values positionally. That
    # made the resolved Windows venv executable bind as an unexpected
    # positional argument. The preflight call must use a hashtable splat so
    # every value is bound to its named parameter.
    match = re.search(
        r"(?ms)\$preflightArgs\s*=\s*@\{(?P<body>.*?)\n\}\s*"
        r"& \(Join-Path \$PSScriptRoot 'preflight\.ps1'\) @preflightArgs",
        install,
    )
    assert match is not None
    assert not re.search(r"\$preflightArgs\s*=\s*@\(", install)
    body = match.group("body")
    for parameter in (
        "ServiceHostBinarySource",
        "ApiSource",
        "GatewaySource",
        "LegacyGatewaySource",
        "NodeRuntimeSource",
        "PythonRuntimeSource",
        "GatewayEntryPoint",
        "TailscaleExecutable",
        "TailscaleServiceName",
        "LegacyTaskName",
        "CodexTaskName",
    ):
        assert re.search(rf"(?m)^\s+{parameter}\s*=\s*\${parameter}\s*$", body)
    assert "$preflightNamedArgs = [regex]::Match" in static
    assert "Preflight must be invoked with a named hashtable splat." in static
    assert "Preflight arguments must not use an array splat." in static
