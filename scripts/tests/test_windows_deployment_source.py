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
    assert "function New-LifeOSManagedAcl" in common
    assert "function Set-LifeOSAclWithBoundHandle" in common
    assert "SetDacl" in common
    assert "Assert-NoBroadAcl $stateDirectory" in install
    # The gateway must not outrace the SYSTEM task that republishes the
    # snapshot it refuses to start without.
    assert install.count("@('LifeOSAPI', $TailscaleServiceName, 'Schedule')") == 2
    assert "-Dependencies @('LifeOSAPI', $TailscaleServiceName, 'Schedule') -Mode 'delayed-auto'" in verify
    assert "LIFEOS_TAILSCALE_SNAPSHOT_PATH = $TailscaleSnapshotPath" in install
    assert "Register-TailscaleSnapshotTask -TaskName $TailscaleSnapshotTaskName" in install
    assert "Invoke-LifeOSBeforeGatewayStart -TaskName $TailscaleSnapshotTaskName" in install
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
    assert "unsafeTarget = $null -ne $target -and [string]$target -ne 'HardLink'" not in common
    bounded_tree = common.split("function Get-LifeOSBoundedTreeItem", 1)[1].split("function Get-TreeManifestIndex", 1)[0]
    assert "$linkType" in bounded_tree and "$target" not in bounded_tree
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
        adapter = launcher.TrustedEdgeHeaderAdapter(app, token, peer_verifier=lambda _scope: True, expected_identity=("fixture.ts.net", "operator@example.com"))
        # Header/token unit fixture only; runtime lease behavior is covered in test_gateway_launcher.py.
        adapter._snapshot_valid = lambda: True
        asyncio.run(adapter({"type": "http", "headers": [
            (b"Tailscale-User-Login", b"operator@example.com"),
            (b"Tailscale-App-Capabilities", header),
            (b"X-LifeOS-Trusted-Edge", b"attacker-value"),
        ]}, None, None))
        assert (launcher.TRUSTED_EDGE_HEADER, token.encode("ascii")) in captured["headers"]
        assert all(name.lower() != launcher.TAILSCALE_APP_CAPABILITIES_HEADER for name, _ in captured["headers"])
        assert token not in repr(header)
        adapter._reader.shutdown(wait=True)

        captured.clear()
        rejected = launcher.TrustedEdgeHeaderAdapter(app, token, peer_verifier=lambda _scope: False, expected_identity=("fixture.ts.net", "operator@example.com"))
        rejected._snapshot_valid = lambda: True
        rejected_messages: list[dict] = []

        async def rejected_send(message: dict) -> None:
            rejected_messages.append(message)

        asyncio.run(rejected({"type": "http", "headers": [
            (b"Tailscale-User-Login", b"operator@example.com"),
            (b"Tailscale-App-Capabilities", header),
            (b"X-LifeOS-Trusted-Edge", b"attacker-value"),
        ]}, None, rejected_send))
        assert rejected_messages == [
            {"type": "http.response.start", "status": 503,
             "headers": [(b"cache-control", b"no-store")]},
            {"type": "http.response.body", "body": b"Edge unavailable"},
        ]
        assert captured == {}
        rejected._reader.shutdown(wait=True)


def test_codex_task_has_file_only_secret_argument_and_cutover_gate() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    assert "[Parameter(Mandatory)][string]$SecretFile" in common
    assert "--secret-file" in common
    assert "Start-AttributedCodexCollector" in install
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
    assert "$legacy.State -eq 'Running'" not in install


def test_legacy_launcher_runtime_shape_is_static_and_exact() -> None:
    common = read("Deployment.Common.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")

    assert "function Get-LegacyLauncherRuntimeCandidates" not in common
    assert "Get-LegacyLauncherRuntimeCandidates" not in static
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
    assert "Migrate-LegacyDataFile" not in install
    assert "256 * 1024" in install
    assert "Assert-BoundedFile" in common
    assert "-MaxBytes $entry.maxBytes" in install
    assert "New-ManifestIntent" in install
    assert "phase = 'pending'" in install
    assert "Copy-FileVerifiedAtomic -Source $source" in install
    assert "'enablebanking-connections.json' = 256 * 1024" in install
    assert "'finance-summary.json' = 256 * 1024" in install
    assert "'calendar.json.retry.json' = 512" in install
    assert "'enablebanking-revoked.json' = 64 * 1024" in install
    assert "'calendar.json.state.json' = 6 * 1024 * 1024" in install
    assert "'calendar.json.meta.json' = 4 * 1024 * 1024" in install
    assert "'finance-summary.json.meta.json' = 4 * 1024 * 1024" in install
    assert "'enablebanking-revocation.json' = 8 * 1024 * 1024" in install
    assert "'finance-imported.json' = 8 * 1024 * 1024" in install
    gateway_main = (ROOT / "services" / "gateway" / "main.py").read_text(encoding="utf-8")
    enablebanking = (ROOT / "services" / "gateway" / "enablebanking.py").read_text(encoding="utf-8")
    for source, constant, expected_mib in (
        (gateway_main, "CALENDAR_STATE_MAX_SIZE", 6),
        (gateway_main, "CALENDAR_METADATA_MAX_SIZE", 4),
        (gateway_main, "FINANCE_IMPORTED_MAX_STATE_SIZE", 8),
        (enablebanking, "MAX_FINANCE_STATE_SIZE", 6),
        (enablebanking, "MAX_FINANCE_METADATA_SIZE", 4),
        (enablebanking, "MAX_REVOCATION_STATE_SIZE", 8),
    ):
        match = re.search(rf"(?m)^\s*{re.escape(constant)}\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024\s*$", source)
        assert match and int(match.group(1)) == expected_mib
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


def test_serve_validators_share_the_exact_paired_https_mirror_contract() -> None:
    common = read("Deployment.Common.ps1")
    launcher = read("gateway_launcher.py")
    behavior = read("tests/Deployment.Behavior.Tests.ps1")
    assert "function Test-TailscaleServeTcpHttpsMirror" in common
    assert "[string]$Record.Key -cne '8420'" in common
    assert "fields.Count -ne 1 -or $fields[0].Name -cne 'HTTPS'" in common
    assert "def _is_exact_tcp_https_mirror" in launcher
    assert 'endpoint != "8420"' in launcher
    assert 'set(value) == {"HTTPS"}' in launcher
    assert 'type(value["HTTPS"]) is bool' in launcher
    assert "$pairedLifeOS" in behavior and "$unsafePairedLifeOS" in behavior


def test_unused_deployment_helpers_are_removed_with_their_orphans() -> None:
    common = read("Deployment.Common.ps1")
    behavior = read("tests/Deployment.Behavior.Tests.ps1")
    static = read("tests/Deployment.Static.Tests.ps1")
    assert "function Assert-LoopbackUri" not in common
    assert "function Test-TailscaleServeEmpty" not in common
    assert "Assert-LoopbackUri" not in behavior and "Test-TailscaleServeEmpty" not in behavior
    assert "Get-LegacyLauncherRuntimeCandidates" not in static


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
    expected_bindings = {
        "CandidateRoot": "candidateRootFull",
        "ExpectedSourceSha": "ExpectedSourceSha",
    }
    expected_bindings.update({
        parameter: parameter for parameter in (
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
        )
    })
    for parameter, variable in expected_bindings.items():
        assert re.search(rf"(?m)^\s+{parameter}\s*=\s*\${variable}\s*$", body)
    assert "$preflightNamedArgs = [regex]::Match" in static
    assert "Preflight must be invoked with a named hashtable splat." in static
    assert "Preflight arguments must not use an array splat." in static


def test_install_and_preflight_require_an_independently_verified_candidate() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    preflight = read("preflight.ps1")
    verifier = read("verify-candidate.ps1")

    assert "function Assert-LifeOSCandidateRoot" in common
    assert "function Assert-LifeOSCandidateSourceBindings" in common
    assert "-ExpectedSourceSha $ExpectedSourceSha" in common
    assert "SOURCE_SHA.txt" in verifier
    assert "-VerifyCandidate" in install
    assert "-VerifyCandidate" in preflight
    assert "-DeploymentScriptRoot $PSScriptRoot" in install
    assert "-DeploymentScriptRoot $PSScriptRoot" in preflight
    assert "CandidateRoot = $candidateRootFull" in install
    assert "ExpectedSourceSha = $ExpectedSourceSha" in install
    assert "[string]$CandidateRoot" in preflight
    assert "[string]$ExpectedSourceSha" in preflight
    assert "Assert-LifeOSCandidateSourceBindings" in preflight
    assert "LegacyGatewaySource" in preflight
    assert "ExpectedSourceSha" in install.split("function Invoke-LifeOSInstall", 1)[1].split("$deploymentMutex", 1)[0]


def test_empty_listener_query_is_narrow_and_preflight_stays_isolated() -> None:
    common = read("Deployment.Common.ps1")
    owner = common.split("function Get-LoopbackPortOwner {", 1)[1].split(
        "function Convert-CimCreationDateUtc", 1
    )[0]
    assert "-ErrorAction Stop" in owner
    assert "SilentlyContinue" not in owner
    assert "'CmdletizationQuery_NotFound,Get-NetTCPConnection'" in owner
    assert "[System.Management.Automation.ErrorCategory]::ObjectNotFound" in owner
    assert "return $null" in owner
    assert "\n        throw\n" in owner
    behavior = read("tests/Deployment.Behavior.Tests.ps1")
    for case in ("empty", "not-found", "permission", "query-failure", "wrong-category", "listener"):
        assert f"'{case}'" in behavior
    assert "($null -eq $result)" in behavior
    preflight = read("preflight.ps1")
    assert "Invoke-NativeChecked -FilePath $deploymentTest -ArgumentList ([string[]]@())" in preflight
    assert "& $deploymentTest" not in preflight


def test_complete_authority_migration_and_reinstall_provenance() -> None:
    install = read("install.ps1")
    expected = {
        "calendar.json", "calendar.json.state.json", "calendar.json.meta.json",
        "calendar.json.retry.json", "finance-summary.json", "finance-summary.json.state.json",
        "finance-summary.json.meta.json", "enablebanking-connections.json",
        "enablebanking-revocation.json", "enablebanking-revoked.json",
        "enablebanking-partial.json", "enablebanking-runtime.json", "finance-imported.json",
        "documents.json",
    }
    inventory = install.split("$authorityFiles = [ordered]@{", 1)[1].split("\n}", 1)[0]
    assert set(re.findall(r"'([^']+)' =", inventory)) == expected
    assert install.index("$legacyCutover = Stop-LegacyGatewayForCutover") < install.index("$authorityFiles =")
    assert "Unclassified legacy authority file" in install
    assert "$authoritySidecars = @('enablebanking-partial.json', 'enablebanking-runtime.json')" in install
    assert "$allowedSet.Contains([string]$entry.Name)" in install
    assert "$gatewayAllowedEntries = @($authorityFiles.Keys) + @('documents', 'tmp', 'supplements.sqlite3')" in install
    assert "Assert-AuthorityJsonBounds $decoded" in install
    assert "$Depth -gt 64 -or $Nodes.Value -gt 100000" in install
    assert "-Kind 'authority-set'" in install
    assert "'preserve-installed'" in install
    assert "if (-not $preserveInstalledAuthority)" in install
    assert "Copy-Item -LiteralPath $legacyData" not in install
    assert "Quiesced authority changed during migration" in install
    common = read("Deployment.Common.ps1")
    assert "function Test-AuthorityRecoveryBaseline" in common
    assert "Test-AuthorityRecoveryBaseline $previousAuthority[0]" in install
    assert "SupportedEvolution" in common and "-SupportedEvolution $authoritySidecars" in install
    for source in (install, read("rollback.ps1")):
        assert "Authority provenance changed or incomplete" in source
        assert "Authority backup provenance invalid" in source
        assert "Usage authority changed or has no provenance" in source
        assert "@($item.beforeTree)" in source and "@($item.afterTree)" in source
        assert source.index("Authority provenance changed or incomplete") < source.index("Restore-ManifestArtifacts $manifest")


def test_collector_requires_terminal_attributed_completion() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    body = install.split("function Start-AttributedCodexCollector", 1)[1].split("function Copy-ApiReleaseBundle", 1)[0]
    assert "$sawRunning -and [string]$task.State -eq 'Ready'" in body
    assert "$info.LastRunTime -gt $before.LastRunTime" in body
    assert "$confirm.LastRunTime -ne $info.LastRunTime" in body
    assert "$confirm.LastTaskResult -ne $info.LastTaskResult" in body
    assert "$exitCode -eq 2" in body and "$exitCode -ne 0" in body
    assert "Wait-CodexUsageObservation" in body
    assert "terminal completed observation missing" in body
    assert "terminalCompleted = [bool]$codexVerification.terminalCompleted" in install
    assert "Start-CodexCollectorAndVerify -TaskName" not in install
    assert "function Start-CodexCollectorAndVerify" not in common
    assert "$info.LastRunTime -ne $observedRun" in body
    assert "Rollback requires exactly one authority provenance record" in read("rollback.ps1")


# Compile the current source in memory: stale dist files and erased type-only
# imports must not hide (or invent) a release runtime dependency.
def _release_runtime_modules() -> dict:
    import subprocess

    result = subprocess.run(
        ["node", "-e", r"""
const ts = require('typescript');
const path = require('node:path');
const modules = {};
for (const [project, prefix] of [
  ['services/api', 'api/dist/'],
  ['packages/contracts', 'api/node_modules/@iphone-life-os/contracts/dist/'],
]) {
  const configPath = path.resolve(project, 'tsconfig.json');
  const config = ts.readConfigFile(configPath, ts.sys.readFile);
  if (config.error) throw new Error('Cannot read ' + configPath);
  const parsed = ts.parseJsonConfigFileContent(config.config, ts.sys, path.dirname(configPath));
  if (parsed.errors.length) throw new Error('Invalid ' + configPath);
  const program = ts.createProgram(parsed.fileNames, parsed.options);
  const emitted = program.emit(undefined, (file, text) => {
    if (!file.endsWith('.js')) return;
    const name = prefix + path.relative(parsed.options.outDir, file).split(path.sep).join('/');
    const ast = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.JS);
    const imports = [];
    function visit(node) {
      if ((ts.isImportDeclaration(node) || ts.isExportDeclaration(node)) && node.moduleSpecifier) {
        imports.push(node.moduleSpecifier.text);
      }
      if (ts.isCallExpression(node) &&
          (node.expression.kind === ts.SyntaxKind.ImportKeyword ||
           (ts.isIdentifier(node.expression) && node.expression.text === 'require'))) {
        if (node.arguments.length !== 1 || !ts.isStringLiteralLike(node.arguments[0])) {
          throw new Error('Nonliteral runtime dependency requires review: ' + name);
        }
        imports.push(node.arguments[0].text);
      }
      ts.forEachChild(node, visit);
    }
    visit(ast);
    modules[name] = {text, imports};
  });
  if (emitted.emitSkipped) throw new Error('Compiler skipped ' + project);
}
process.stdout.write(JSON.stringify(modules));
"""],
        cwd=ROOT, text=True, capture_output=True, timeout=90,
    )
    assert result.returncode == 0, result.stderr
    return json.loads(result.stdout)


def _release_allowlists() -> tuple[set[str], set[str]]:
    builder = (ROOT / "scripts/build_windows_release.sh").read_text(encoding="utf-8")
    planned = set()
    for name, prefix in (
        ("api_dist_files", "api/dist/"),
        ("contract_dist_files", "api/node_modules/@iphone-life-os/contracts/dist/"),
        ("zod_root_files", "api/node_modules/zod/"),
        ("zod_files", "api/node_modules/zod/"),
    ):
        match = re.search(rf"(?ms)^{name}=\((.*?)\)", builder)
        assert match, name
        entries = match[1].split()
        assert len(entries) == len(set(entries)), name
        for entry in entries:
            assert re.fullmatch(r"[A-Za-z0-9._/-]+", entry), entry
            assert all(part not in {"", ".", ".."} for part in entry.split("/")), entry
            planned.add(prefix + entry)
    match = re.search(r"(?ms)^\$expectedFiles = @\(\n(.*?)^\)", read("verify-candidate.ps1"))
    assert match
    verified = re.findall(r"(?m)^\s+'([^']+)'\s*$", match[1])
    assert len(verified) == len(set(verified))
    return planned, set(verified)


def _assert_release_runtime_closure(modules: dict, allowed: set[str]) -> None:
    import posixpath

    # The collector is a separate executable entry; check every packaged module
    # too, including calendar-store, which is retained as an explicit fixture.
    pending = sorted({"api/dist/server.js", "api/dist/codex-collector.js",
                      "api/node_modules/@iphone-life-os/contracts/dist/index.js"}
                     | (set(modules) & allowed))
    visited = set()
    while pending:
        name = pending.pop()
        if name in visited:
            continue
        assert name in allowed, f"runtime module absent from package allowlist: {name}"
        assert name in modules, f"runtime module absent from compiler output: {name}"
        visited.add(name)
        for specifier in modules[name]["imports"]:
            if specifier.startswith("node:"):
                continue
            if specifier == "zod":
                assert "api/node_modules/zod/package.json" in allowed
                continue
            if specifier == "@iphone-life-os/contracts":
                target = "api/node_modules/@iphone-life-os/contracts/dist/index.js"
            else:
                assert specifier.startswith("."), f"unreviewed runtime dependency: {name}: {specifier}"
                target = posixpath.normpath(posixpath.join(posixpath.dirname(name), specifier))
            assert target in allowed, f"{name} imports {specifier}, absent from package allowlist: {target}"
            pending.append(target)


def test_release_allowlists_cover_current_source_runtime_import_export_closure() -> None:
    modules = _release_runtime_modules()
    planned, verified = _release_allowlists()
    for allowed in (planned, verified):
        _assert_release_runtime_closure(modules, allowed)
        # Regression proof: independently omitting any reviewed missing module
        # must fail even when builder and verifier have the same obsolete list.
        for missing in ("api/dist/local-auth.js",):
            try:
                _assert_release_runtime_closure(modules, allowed - {missing})
            except AssertionError as error:
                assert missing in str(error)
            else:
                raise AssertionError(f"closure accepted missing runtime module: {missing}")


def test_allowlisted_node_package_imports_and_starts_without_workspace_dependencies() -> None:
    import os
    import shutil
    import subprocess

    modules = _release_runtime_modules()
    planned, verified = _release_allowlists()
    assert planned <= verified
    with TemporaryDirectory(prefix="lifeos-package-smoke-") as temporary:
        stage = Path(temporary)
        for name in sorted(planned):
            destination = stage / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            if name in modules:
                destination.write_text(modules[name]["text"], encoding="utf-8")
            else:
                assert name.startswith("api/node_modules/zod/"), name
                shutil.copyfile(ROOT / name.removeprefix("api/"), destination)
        contracts = stage / "api/node_modules/@iphone-life-os/contracts/package.json"
        shutil.copyfile(ROOT / "packages/contracts/package.json", contracts)
        (stage / "api/package.json").write_text('{"type":"module"}\n', encoding="utf-8")
        script = r"""
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
// Import every allowed first-party module, including the collector entry.
for (const name of JSON.parse(process.argv[1])) await import(pathToFileURL(name));
const { startApiServer } = await import('./api/dist/server.js');
const started = await startApiServer({port: 0});
try {
  const address = started.server.address();
  assert.equal(address.address, '127.0.0.1');
  assert.ok(address.port > 0);
  const response = await fetch(`http://127.0.0.1:${address.port}/health`);
  assert.equal(response.status, 200);
  await response.arrayBuffer();
} finally {
  await started.shutdown();
  await started.closed;
}
console.log('packaged imports, loopback startup, health, shutdown passed');
"""
        # An explicit environment prevents developer credentials, feature flags,
        # NODE_OPTIONS and NODE_PATH from affecting this secret-free smoke test.
        result = subprocess.run(
            [shutil.which("node"), "--input-type=module", "-e", script,
             json.dumps([str(stage / name) for name in sorted(planned & modules.keys())])],
            cwd=stage, env={"NODE_ENV": "test", **{key: os.environ[key] for key in ("SystemRoot", "WINDIR") if key in os.environ}}, text=True, capture_output=True, timeout=30,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        assert "packaged imports, loopback startup, health, shutdown passed" in result.stdout
        builder = (ROOT / 'scripts/build_windows_release.sh').read_text(encoding='utf-8')
        payload = builder.split("<<'JS'\n", 1)[1].split('\nJS\n', 1)[0]
        imports = subprocess.run([shutil.which('node'), '--input-type=module', '-', str(stage)],
                                 input=payload, cwd=stage, env={'NODE_ENV': 'test'},
                                 text=True, capture_output=True, timeout=30)
        assert imports.returncode == 0, imports.stdout + imports.stderr



def test_local_bearer_provisioning_is_separate_protected_and_exact() -> None:
    common, install = read('Deployment.Common.ps1'), read('install.ps1')
    assert install.count("LIFEOS_LOCAL_API_ENABLED = 'true'") == 2
    assert install.count('LIFEOS_LOCAL_API_SECRET_FILE =') == 2
    assert 'Write-SecretAtomic $localApiSecret $localValue' in install
    assert '$localValue = New-RandomSecret' in install
    assert "$localIntent['sourceSha256'] = Get-FileSha256 $localApiSecret" in install
    assert 'Set-SecretAcl $localApiSecret $operatorSid @($apiSid, $gatewaySid)' in install
    secret = common.split('function Write-SecretAtomic', 1)[1].split('function Set-RestrictedAcl', 1)[0]
    assert secret.index('Set-RestrictedAcl -Path $temp') < secret.index('WriteAllText($temp, $Value')
    usage = common.split('function Wait-CodexUsageObservation', 1)[1].split('function Restore-CodexCollectorTask', 1)[0]
    assert '-Headers $headers' in usage and 'Get-LocalApiBearerHeaders' in usage
    assert 'MaximumRedirection 0' in usage
    assert "return @{ Authorization = 'Bearer ' + [Text.Encoding]::ASCII.GetString($bytes) }" in common


def test_recovery_marker_identity_precedes_mutation_and_preflight_has_no_marker() -> None:
    common, install, rollback = read('Deployment.Common.ps1'), read('install.ps1'), read('rollback.ps1')
    enter = common.split('function Enter-LifeOSDeploymentTransaction', 1)[1].split('function Exit-LifeOSDeploymentTransaction', 1)[0]
    recovery_branch = enter.split('        if ($AllowRecovery) {', 1)[1].split('        # Acquire serialization', 1)[0]
    assert recovery_branch.index('Assert-RecoveryIdentity') < recovery_branch.index('Write-JsonAtomic')
    assert "Set-JournalProperty $marker 'state' 'active'" in recovery_branch
    assert 'Write-JsonAtomic' not in enter.split('        if ($AllowRecovery) {', 1)[0]
    assert 'Assert-RecoveryIdentity $marker $RecoveryManifest $RecoveryManifestPath' in enter
    identity = common.split('function Assert-RecoveryIdentity', 1)[1].split('function Bind-LifeOSDeploymentManifest', 1)[0]
    for field in ('transactionId', 'generation', 'operatorSid', 'manifestPath'):
        assert repr(field) in identity
    assert 'Get-InteractiveOperatorSid' in identity and "'recovered'" in identity
    assert rollback.index('Assert-CanonicalRollbackManifest') < rollback.index('Enter-LifeOSDeploymentTransaction -AllowRecovery') < rollback.index('Stop-DeploymentTaskBarrier')
    assert install.index('Save-InstallManifest $manifest $manifestPath') < install.index('Bind-LifeOSDeploymentManifest $deploymentMutex')
    assert "Set-JournalProperty $marker 'updatedAtUtc'" in common
    assert 'Split-Path -Parent ([string]$marker.manifestPath)' in common
    assert 'Completed recovery archive' in common
    assert '-Completed:($deploymentCompleted -or $deploymentRecoveryCompleted)' in install
    assert install.index("throw 'Task recovery failed; services remain stopped.'") < install.index('$deploymentRecoveryCompleted = $true')


def test_recovery_has_per_file_journal_and_validated_task_barriers() -> None:
    common, install, rollback = read('Deployment.Common.ps1'), read('install.ps1'), read('rollback.ps1')
    restore = common.split('function Restore-ManifestArtifacts', 1)[1].split('function Copy-FileVerifiedAtomic', 1)[0]
    assert 'Read-RecoveryJournal $Manifest' in restore
    assert 'Assert-RecoveryUnitState $unit $current' in restore
    assert restore.index("Append-RecoveryProgress -Manifest $Manifest -Journal $journal -UnitIndex $unitIndex -Phase 'restoring'") < restore.index('Restore-Artifact $restore') < restore.index("Append-RecoveryProgress -Manifest $Manifest -Journal $journal -UnitIndex $unitIndex -Phase 'complete'")
    assert "Set-JournalProperty $unit 'phase'" not in restore
    assert 'Unjournaled file appeared during recovery' in common
    for source in (install, rollback):
        assert 'if ($null -eq $resumeJournal)' in source and 'Invoke-RecoveryStage $manifest' in source
        assert source.index('Stop-DeploymentTaskBarrier $manifest') < source.index('Restore-ManifestArtifacts $manifest')
    barrier = common.split('function Stop-DeploymentTaskBarrier', 1)[1].split('function Get-RecoveryArtifactState', 1)[0]
    assert '@($Manifest.codexTask, $Manifest.snapshotTask)' in barrier
    assert barrier.index('Task action/principal/path changed') < barrier.index('Disable-ScheduledTask') < barrier.index('Stop-ScheduledTask') < barrier.index('Get-ScheduledTaskInfo')
    assert '0x41301, 0x41325' in barrier
    assert 'SilentlyContinue' not in barrier
    assert 'Get-ScheduledTask -ErrorAction Stop' in barrier
    assert rollback.index('Restore-TailscaleServeSnapshot -TailscaleExecutable') < rollback.index('Restore-CodexCollectorTask $codexSnapshot')


def test_authority_completeness_collector_attribution_and_acl_role_regressions() -> None:
    common, install, behavior = read('Deployment.Common.ps1'), read('install.ps1'), read('tests/Deployment.Behavior.Tests.ps1')
    assert '$preserveInstalledAuthority = $true' not in install
    assert 'Get-LifeOSPreviousInstalledGeneration' in common
    assert '-ExpectedGeneration ([string]$deploymentMutex.PreviousGeneration)' in install
    assert 'Get-AuthorityInstallMode -Installed $installedNames' in install
    assert install.index("$manifest['collectorTransition']") < install.index('$codexVerification = Start-AttributedCodexCollector')
    assert 'if ($preserveUsage -and $artifact.destination -eq $Manifest.paths.usageHistory) { continue }' in common
    for case in ('marker ownership rejects', 'partial versioned authority', 'task principal mismatch', 'rollback interruption after one artifact', 'acknowledged collector observations survive', 'code/runtime reader cannot write'):
        assert case in behavior
    acl = common.split('function Assert-RestrictedAcl', 1)[1].split('function Set-AclSnapshotContext', 1)[0]
    for check in ('GetOwner', 'AreAccessRulesProtected', 'InheritOnly', 'FileSystemRights', 'Assert-AclRoleRights', '[switch]$Recurse'):
        assert check in acl


def test_directory_acl_scope_and_runtime_rights_are_explicit() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    frozen = common.split('function Get-LifeOSFrozenTreeInventory', 1)[1].split('function Add-LifeOSManagedAccessRule', 1)[0]
    managed = common.split('function New-LifeOSManagedAcl', 1)[1].split('function Set-LifeOSAclWithBoundHandle', 1)[0]
    traversal = common.split('function Set-DirectoryTraversalAcl', 1)[1].split('function Assert-ExplicitAclAllowSet', 1)[0]
    snapshot = common.split('function Register-AclSnapshot', 1)[1].split('function Restore-AclSnapshots', 1)[0]

    # RootOnly may inspect and mutate the root object, but it must not enter
    # the bounded descendant enumerator through any of the ACL setup paths.
    assert 'if (-not $File -and -not $RootOnly)' in frozen
    assert frozen.index('if (-not $File -and -not $RootOnly)') < frozen.index('Get-LifeOSBoundedTreeItem')
    assert 'Register-AclSnapshot $Path -RootOnly:$RootOnly' in traversal
    assert 'Get-LifeOSFrozenTreeInventory -Path $Path -RootOnly:$RootOnly' in traversal
    assert 'Remove-TransientLogonAclRules $Path -Recurse:(!$RootOnly)' in traversal
    assert 'Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @() -Recurse:(!$RootOnly)' in traversal
    assert 'Get-LifeOSFrozenTreeInventory -Path $Path)' not in traversal
    assert 'Get-LifeOSBoundedTreeItem' not in traversal
    assert 'if ($item.PSIsContainer -and -not $RootOnly)' in snapshot

    # Recursive protected code/runtime files get the same RX contract already
    # enforced by Assert-RestrictedAcl, while ordinary files retain Read.
    assert '[switch]$Executable' in managed
    assert '$IsContainer -or $Executable' in managed
    assert "[IO.Path]::GetExtension([string]$entry.Path) -in @('.exe', '.dll')" in traversal
    assert '-Executable:$isExecutable' in traversal
    assert '-InheritableSystemFullControl:($InheritToChildren -and $RootOnly)' in traversal
    assert 'Assert-RestrictedAcl -Path $Path -OperatorSid $OperatorSid -ReadSids $ReadSids -ModifySids @() -Recurse:(!$RootOnly)' in traversal
    for runtime_root in (
        "Set-DirectoryTraversalAcl $apiTarget $operatorSid @($apiSid) -RootOnly -InheritToChildren",
        "Set-DirectoryTraversalAcl $gatewayTarget $operatorSid @($gatewaySid) -RootOnly -InheritToChildren",
        "Set-DirectoryTraversalAcl $nodeTarget $operatorSid @($apiSid) -RootOnly -InheritToChildren",
        "Set-DirectoryTraversalAcl (Join-Path $paths.RuntimeRoot 'python312') $operatorSid @($gatewaySid) -RootOnly -InheritToChildren",
    ):
        assert runtime_root in install
    assert 'Set-LifeOSAclWithBoundHandle -Path $destination -Acl $acl -Directory ([bool]$destinationItem.PSIsContainer)' in common
    immediate = common.split('function Assert-LifeOSExpectedImmediateChildren', 1)[1].split('function Set-AclSnapshotContext', 1)[0]
    assert '[IO.SearchOption]::TopDirectoryOnly' in immediate
    assert '$seenNames = [System.Collections.Generic.HashSet[string]]::new' in immediate
    assert '$expectedNames.Contains($name)' in immediate
    assert 'New-LifeOSTreeItemIdentity -Item $childItem' in immediate
    assert 'Get-LifeOSPathIdentityChain -Path $childPath' in immediate
    assert 'Assert-LifeOSTreeItemIdentity -Path $rootFull -Expected $rootIdentity' in immediate
    assert 'Shared-root child grants cross-service access' in immediate
    assert 'if ($RequireAll -and $seenNames.Count -ne $expectedNames.Count)' in immediate
    assert '$rootComparison' not in immediate
    assert '$parentPath.TrimEnd(' in immediate
    assert '-ine $rootFull' in immediate


def test_install_scopes_shared_data_and_log_parent_hardening_before_reinstall() -> None:
    install = read("install.ps1")
    verify = read("verify.ps1")
    data_boundary = "Set-DirectoryTraversalAcl $paths.DataRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly"
    log_boundary = "Set-DirectoryTraversalAcl $paths.LogRoot $operatorSid @($apiSid, $gatewaySid) -RootOnly"
    api_writable = "foreach ($directory in @($apiData, $apiTemp, $apiLogs))"
    gateway_writable = "foreach ($directory in @($gatewayData, $gatewayTemp, (Join-Path $gatewayData 'documents'), $gatewayLogs))"

    for boundary in (data_boundary, log_boundary):
        assert boundary in install
        assert install.count(boundary) == 1
        assert not re.search(
            rf"(?m)^\s*{re.escape(boundary)} -InheritToChildren\s*$",
            install,
        )
    assert install.index(data_boundary) < install.index(api_writable)
    assert install.index(log_boundary) < install.index(api_writable)
    assert install.index(api_writable) < install.index(gateway_writable)
    assert install.index("-AllowedOwnerSids @($apiSid) -InheritableSystemFullControl") > install.index(data_boundary)
    assert install.index("-AllowedOwnerSids @($gatewaySid) -InheritableSystemFullControl") > install.index(log_boundary)
    # The recursive verification is deliberately below both service-specific
    # hardening loops, so existing service-owned descendants are evaluated by
    # the matching scoped contract on reinstall.
    api_verify = "Assert-RestrictedAcl $apiData $operatorSid @() @($apiSid) -AllowedOwnerSids @($apiSid) -AllowInherited -Recurse"
    gateway_verify = "Assert-RestrictedAcl $gatewayData $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited -Recurse"
    assert install.index(api_writable) < install.index(api_verify)
    assert install.index(gateway_writable) < install.index(gateway_verify)
    for call in (
        "Assert-LifeOSExpectedImmediateChildren -Root $paths.DataRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll",
        "Assert-LifeOSExpectedImmediateChildren -Root $paths.LogRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll",
    ):
        assert call in install
    for call in (
        "Assert-LifeOSExpectedImmediateChildren -Root $dataRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll",
        "Assert-LifeOSExpectedImmediateChildren -Root $logRoot -ExpectedChildren ([ordered]@{ api = $apiSid; gateway = $gatewaySid }) -RequireAll",
    ):
        assert call in verify


def test_writable_service_trees_inherit_management_and_scope_service_owned_children() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    verify = read('verify.ps1')
    restricted = common.split('function Set-RestrictedAcl', 1)[1].split('function Set-SecretAcl', 1)[0]
    asserted = common.split('function Assert-RestrictedAcl', 1)[1].split('function Set-AclSnapshotContext', 1)[0]

    # The service-owned exception is explicit, service-SID-shaped, and tied
    # to ModifySids. It must not change the global management-owner set or
    # turn ownership into an implicit FullControl role.
    assert '[string[]]$AllowedOwnerSids = @()' in restricted
    assert "'Allowed ACL owner must be a service SID with Modify rights on this managed writable tree.'" in common
    assert "-notmatch '\\AS-1-5-80-[0-9-]+\\z'" in asserted
    assert '[string]$ownerSid -notin @($ModifySids)' in asserted
    assert '-AllowedOwnerSids $AllowedOwnerSids' in restricted
    assert '$owners = $managementOwners + $scopedOwners' in asserted
    assert '$allowed = $managementOwners + $ReadSids + $ModifySids' in asserted
    assert '$role = if ($sid -in $managementOwners) { \'owner\' } elseif ($sid -in $ModifySids) { \'modify\' }' in asserted
    assert 'Service-owned writable ACL scope requires inheritable SYSTEM management rights.' in restricted
    assert '@($AllowedOwnerSids).Count -gt 0 -and -not $File -and -not $InheritableSystemFullControl' in restricted

    for service_sid in ('apiSid', 'gatewaySid'):
        assert f'-AllowedOwnerSids @(${service_sid}) -InheritableSystemFullControl' in install
    for tree, sid in (('apiData', 'apiSid'), ('gatewayData', 'gatewaySid'), ('apiLogs', 'apiSid'), ('gatewayLogs', 'gatewaySid')):
        call = f'Assert-RestrictedAcl ${tree} $operatorSid @() @(${sid}) -AllowedOwnerSids @(${sid}) -AllowInherited -Recurse'
        assert call in install
        assert call in verify

    # No broad owner relaxation may be added to the other protected trees.
    assert 'Assert-RestrictedAcl $apiCode $operatorSid @($apiSid) @() -AllowedOwnerSids' not in verify
    assert 'Assert-RestrictedAcl $gatewayCode $operatorSid @($gatewaySid) @() -AllowedOwnerSids' not in verify
    assert 'Set-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -File -AllowedOwnerSids @($gatewaySid)' in install
    assert 'Assert-RestrictedAcl $supplementCatalog $operatorSid @() @($gatewaySid) -AllowedOwnerSids @($gatewaySid) -AllowInherited' in verify


def test_service_rollback_uses_shared_native_encoding_and_complete_snapshots() -> None:
    common = read('Deployment.Common.ps1')
    rollback = read('rollback.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    restore = common.split('function Restore-LifeOSServiceSnapshot {', 1)[1].split('function Assert-ServiceIdentity', 1)[0]
    install_service = common.split('function New-ServiceOrConfigure', 1)[1].split('function Stop-LifeOSService', 1)[0]
    assert 'function Get-LifeOSScEmptyArgument' in common
    assert "return '\"\"'" in common
    assert 'function Get-LifeOSServiceDependencyValue' in common
    assert "return ,$Snapshot[$Name]" in common and "return ,$property.Value" in common
    assert 'Get-LifeOSServiceConfigArguments' in restore
    assert 'Get-LifeOSServiceConfigArguments' in install_service
    assert "'password=', ''," not in common
    assert "'depend=', $dependencies" not in common
    assert "'depend=', $dependencyValue" in common
    assert "Assert-CompleteLifeOSServiceSnapshot $Snapshot" in restore
    assert restore.index('Assert-CompleteLifeOSServiceSnapshot $Snapshot') < restore.index('Get-ServiceRecord $name')
    assert 'function Get-LifeOSServiceSnapshotMap' in common
    assert '$serviceSnapshots = Get-LifeOSServiceSnapshotMap $manifest.serviceSnapshots' in rollback
    assert rollback.index('$serviceSnapshots = Get-LifeOSServiceSnapshotMap') < rollback.index('Enter-LifeOSDeploymentTransaction')
    assert rollback.count('Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure') >= 2
    assert 'Assert-LifeOSServiceSnapshotState -Snapshots $serviceSnapshots -VerifyHealth' not in rollback
    assert 'Reconcile-LifeOSServiceSnapshotState $serviceSnapshots' not in rollback
    assert rollback.index('Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure') < rollback.index('$rollbackCompleted = $true')
    assert 'empty service snapshot map is rejected' in behavior
    assert 'one-entry service snapshot map is rejected' in behavior
    assert 'mismatched service snapshot key is rejected' in behavior
    assert 'unknown service snapshot entries are rejected' in behavior
    assert 'unknown service snapshot fields are rejected' in behavior
    assert 'interrupted outer rollback retry restores running services' in behavior
    assert 'empty service values retain explicit native argv slots' in behavior
    assert 'populated service dependencies use the shared native encoding' in behavior
    assert 'partial service snapshots are rejected before SCM mutation' in behavior


def test_recovery_state_transitions_are_idempotent_and_early_recovery_is_not_a_baseline() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    stage = common.split('function Invoke-RecoveryStage', 1)[1].split('function Get-RecoveryJournalPath', 1)[0]
    assert "stageState -eq 'complete'" in stage and 'return' in stage
    assert "stageState -notin @('restoring', 'complete')" in stage
    assert "Get-JournalProperty $journal 'writersReleased'" in common
    assert 'Test-AuthorityRecoveryBaseline $previousAuthority[0]' in install
    assert 'function Get-LifeOSPreviousInstalledGeneration' in common
    assert 'function Resolve-LifeOSGenerationReference' in common
    assert 'function Complete-LifeOSRecoveryState' in common
    assert 'recovery.completed.' in common
    assert "Set-JournalProperty $terminal 'phase' 'completed'" in common
    assert "Set-JournalProperty $marker 'recoveryArchivePath'" in common
    assert '$previousGeneration = Get-LifeOSPreviousInstalledGeneration' in install
    assert "priorInstalledGeneration" in install
    assert 'recovered upgrade carries its authority to the next install' in behavior
    assert 'recovered marker generation mismatch is rejected' in behavior
    assert 'completed recovery stages are idempotent' in behavior
    assert 'early recovered transaction has no usable authority baseline' in behavior


def test_fresh_marker_and_generation_reference_contracts_are_exercised() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    assert "[AllowEmptyString()][string]$MarkerState = ''" in common
    assert "if ([string]::IsNullOrEmpty($MarkerState)) { return $null }" in common
    assert "if ($MarkerState -notin @('installed', 'recovered')) { throw 'Deployment marker state is invalid.' }" in common
    assert 'Reference -is [System.Collections.IDictionary]' in common
    assert 'foreach ($key in $Reference.Keys)' in common
    assert 'param([Parameter(Mandatory)][object]$Reference' in common
    assert '$previousGeneration = Get-LifeOSPreviousInstalledGeneration -MarkerState $deploymentMutex.PreviousState' in install
    for case in ('fresh install with no deployment marker takes the no-marker call path',
                 'generation reference constructor returns its owned dictionary representation',
                 'normal upgrade binds the constructor dictionary output',
                 'recovery binds the constructor dictionary output',
                 'recovered upgrade resolves a serialized constructor reference'):
        assert case in behavior


def test_scheduled_task_recovery_reconciles_live_state_after_retries() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    rollback = read('rollback.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    lookup = common.split('function Get-LifeOSScheduledTaskExact', 1)[1].split('function Reconcile-LifeOSScheduledTaskSnapshotState', 1)[0]
    reconciliation = common.split('function Reconcile-LifeOSScheduledTaskSnapshotState', 1)[1].split('function Get-LifeOSScEmptyArgument', 1)[0]
    assert 'Get-ScheduledTask -ErrorAction Stop | ForEach-Object' in lookup
    assert '$enumeration = [pscustomobject]@{ Count = 0 }' in lookup
    assert '$enumeration.Count++' in lookup
    assert 'foreach ($task in $tasks)' not in lookup
    assert 'actualTaskPath -ceq $TaskPath' in lookup
    assert '[string]$task.TaskName -ceq $TaskName' in lookup
    assert 'Scheduled task inventory exceeds its bounded enumeration size' in lookup
    assert '$actualRunning -eq $expectedRunning -and $actualEnabled -eq $expectedEnabled' in reconciliation
    assert 'Scheduled task state is ambiguous after recovery' in reconciliation
    assert 'Scheduled task did not reach its captured state during recovery' in reconciliation
    stage = common.split('function Invoke-RecoveryStage', 1)[1].split('function Get-RecoveryJournalPath', 1)[0]
    assert '[AllowNull()][scriptblock]$Postcondition = $null' in stage
    assert '& $Postcondition' in stage
    for source, completed in ((install, '$deploymentRecoveryCompleted = $true'), (rollback, '$rollbackCompleted = $true')):
        assert '-Postcondition { Reconcile-LifeOSScheduledTaskSnapshotState' in source
        assert source.rfind('Reconcile-LifeOSScheduledTaskSnapshotState') < source.index(completed)
    for case in ('outer rollback does not report success after snapshot task restoration failure',
                 'collector retry restores its writer while snapshot restoration is still failed',
                 'successful recovery leaves previously running writers running and enabled',
                 'an empty scheduled task enumeration is a successful terminal state',
                 'an absent scheduled task is a successful terminal state',
                 'successful enumeration exact-filters the requested task name and path',
                 'scheduled task enumeration ObjectNotFound is not treated as absent',
                 'scheduled task access denied is not treated as absent',
                 'scheduled task provider failure is not treated as absent',
                 'unrelated ObjectNotFound provider errors are not treated as absent',
                 'scheduled task inventory cap fails closed',
                 'scheduled task enumeration stops at the first record beyond its cap'):
        assert case in behavior


def test_scheduled_task_lookup_requires_successful_enumeration() -> None:
    common = read('Deployment.Common.ps1')
    helper = common.split('function Get-LifeOSScheduledTaskExact', 1)[1].split('function Reconcile-LifeOSScheduledTaskSnapshotState', 1)[0]
    assert 'Get-ScheduledTask -ErrorAction Stop' in helper
    assert 'Get-ScheduledTask -ErrorAction Stop | ForEach-Object' in helper
    assert '$enumeration.Count++' in helper
    assert 'foreach ($task in $tasks)' not in helper
    assert '[string]$task.TaskName -ceq $TaskName' in helper
    assert 'actualTaskPath -ceq $TaskPath' in helper
    assert 'Scheduled task inventory exceeds its bounded enumeration size' in helper
    assert 'ProviderEnumerationFailed,Get-ScheduledTask' in read('tests/Deployment.Behavior.Tests.ps1')
    assert 'for ($index = 0; $index -lt 9000; $index++)' in read('tests/Deployment.Behavior.Tests.ps1')
    assert 'throw' in helper
    assert 'ErrorAction SilentlyContinue' not in helper


def test_service_recovery_restores_all_configuration_before_dependency_start() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    rollback = read('rollback.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    restore = common.split('function Restore-LifeOSServiceSnapshot {', 1)[1].split('function Assert-ServiceIdentity', 1)[0]
    orchestration = common.split('function Restore-LifeOSServiceSnapshots', 1)[1].split('function Get-RecoveryJournalPath', 1)[0]
    reconcile = common.split('function Reconcile-LifeOSServiceSnapshotState', 1)[1].split('function Get-LifeOSServiceRegistrySnapshot', 1)[0]
    assert '[switch]$DeferStart' in restore
    assert 'Stop-LifeOSService $name' in restore
    assert 'if (-not $DeferStart -and $stateValue -eq \'Running\')' in restore
    assert "foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway'))" in reconcile
    assert "foreach ($serviceName in @('LifeOSAPI', 'LifeOSGateway'))" in orchestration
    assert orchestration.index("Invoke-RecoveryStage $Manifest 'service-state-reconcile'") < orchestration.index('Reconcile-LifeOSServiceSnapshotState -Snapshots $validatedSnapshots')
    assert 'Assert-LifeOSServiceSnapshotState -Snapshots $validatedSnapshots -VerifyHealth:$VerifyHealth' in orchestration
    for source in (install, rollback):
        assert 'Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots -Manifest $manifest -ContinueOnFailure' in source
        assert '-VerifyHealth' in source
    install_recovery = install.split('$deploymentRollbackSucceeded = $true', 1)[1]
    assert "if (-not $deploymentRollbackSucceeded) { throw 'Service recovery failed; writers remain stopped.' }" in install_recovery
    assert install_recovery.index('Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots') < install_recovery.index("Service recovery failed; writers remain stopped.")
    assert 'function Invoke-InstallerFailureThenRollback' in behavior
    assert 'New-ServiceOrConfigure -Name \'LifeOSAPI\'' in behavior
    assert 'Restore-LifeOSServiceSnapshots -Snapshots $serviceRecoveryMap -Manifest $recoveryManifest -ContinueOnFailure' in behavior
    service_fixture = behavior.split('function Invoke-InstallerFailureThenRollback', 1)[1].split('function Start-Service', 1)[0]
    assert 'function Invoke-RecoveryStage' not in service_fixture
    assert 'fixture failed after temporary API service registration' in behavior
    assert 'failed temporary API configuration is gone before dependent service reconciliation' in behavior
    assert 'actual recovery orchestration starts services in dependency order after configuration restore' in behavior
    assert 'partial service snapshot maps are rejected before SCM mutation' in behavior
    assert 'service state transition failure remains retryable' in behavior
    assert 'failed service state transition stays durably in restoring state.' in behavior
    assert 'service recovery publishes the gateway pre-start evidence immediately before its one actual start across retries.' in behavior


def test_production_recovery_restores_serve_and_fresh_snapshot_before_gateway() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    rollback = read('rollback.ps1')
    for source in (install, rollback):
        serve = source.index("Invoke-RecoveryStage $manifest 'Restore-TailscaleServeSnapshot'")
        service = source.index('Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots', serve)
        helper = source.index('Invoke-LifeOSBeforeGatewayStart', service)
        barrier = source.index('Stop-DeploymentTaskBarrier $manifest $manifestPath', helper)
        post_barrier_service = source.index('Restore-LifeOSServiceSnapshots -Snapshots $serviceSnapshots', barrier)
        assert serve < service < helper < barrier < post_barrier_service
        assert 'fresh Tailscale snapshot' in source or 'Tailscale snapshot' in source
        assert "Restore-TailscaleSnapshotTask $snapshotTask" in source or "Restore-TailscaleSnapshotTask $snapshotTaskSnapshot" in source
    assert 'function Publish-LifeOSTailscaleSnapshotForGatewayStart' in common
    assert 'function Invoke-LifeOSBeforeGatewayStart' in common
    assert 'Start-TailscaleSnapshotTaskAndVerify -TaskName $TaskName -TaskPath $TaskPath' in common
    assert 'Reconcile-LifeOSScheduledTaskSnapshotState $stoppedSnapshot $TaskName' in common
    helper = common.split('function Invoke-LifeOSBeforeGatewayStart', 1)[1].split('function Restore-TailscaleSnapshotTask', 1)[0]
    assert helper.index('Get-TailscaleIdentityFacts') < helper.index('Publish-LifeOSTailscaleSnapshotForGatewayStart')
    assert 'RestoreTaskEnabled' in helper
    assert '[switch]$KeepStopped' in common and '-KeepStopped' in install and '-KeepStopped' in rollback
    assert "-LiveAction { Restore-TailscaleSnapshotTask $snapshotTask $TailscaleSnapshotTaskName }" in install
    assert "-LiveAction { Restore-TailscaleSnapshotTask $snapshotTaskSnapshot $TailscaleSnapshotTaskName }" in rollback


def test_candidate_verifier_uses_allowlist_derived_bounded_inventory() -> None:
    candidate = read('verify-candidate.ps1')
    allowlist = candidate.index('$expectedFiles = @(')
    directories = candidate.index('$allowedDirectories = @{}')
    walker = candidate.index('Get-LifeOSBoundedTreeItem -Root $rootFull')
    manifest_guard = candidate.index('$manifestItem = Get-Item -LiteralPath $manifestPath')
    manifest_read = candidate.index('$manifestText = Read-LifeOSCappedFileText -Path $manifestPath')
    assert allowlist < directories < walker
    assert manifest_guard < manifest_read
    assert '$maxCandidateFiles = [int]$expectedFiles.Count + 1' in candidate
    assert '$maxCandidateDirectories = [int]$allowedDirectories.Count + 1' in candidate
    assert '$maxCandidateBytes = [long]($expectedFiles.Count - 2) * $maxCandidateFileBytes + $maxCandidateNodeFileBytes + $maxCandidateServiceHostFileBytes' in candidate
    assert '$candidateManifestMaxBytes = [long]($expectedFiles.Count + 1) * 16 * 1024' in candidate
    assert 'MaxDirectories $maxCandidateDirectories' in candidate
    assert 'MaxBytes $maxCandidateBytes' in candidate
    assert 'MaxFileBytes $maxCandidateFileBytes' in candidate
    assert "'node-runtime/node.exe' = $maxCandidateNodeFileBytes" in candidate
    assert "'service-host/LifeOS.ServiceHost.exe' = $maxCandidateServiceHostFileBytes" in candidate
    assert '-LargeFileContracts $largeFileContracts' in candidate
    assert "$relativePath -ceq 'service-host/LifeOS.ServiceHost.exe'" in candidate
    assert 'Get-ChildItem -LiteralPath $rootFull -Recurse' not in candidate
    assert 'Read-LifeOSPrefixBytes -Path $Path -Count 2' in candidate
    assert 'Read-LifeOSCappedFileText -Path $manifestPath' in candidate
    assert 'Get-LifeOSFileDigest -Path $candidatePath' in candidate
    assert 'Assert-LifeOSTreeItemIdentity -Path $candidatePath' in candidate


def test_verifier_binds_installed_marker_before_paths_and_certifies_readiness() -> None:
    verify = read('verify.ps1')
    marker = verify.split('function Assert-VerificationMarker', 1)[1].split('function Assert-ServiceContract', 1)[0]
    binding = verify.split('Assert-WindowsAdministrator', 1)[1].split('$codexVerificationProperty', 1)[0]
    assert 'Get-LifeOSDeploymentMarkerPath' in binding
    assert 'Read-LifeOSBoundedJsonFile -Path $markerFile' in binding
    assert 'Assert-VerificationMarker -Marker $marker' in binding
    assert binding.index('Assert-VerificationMarker') < binding.index('Read-LifeOSBoundedJsonFile -Path $manifestFile')
    assert binding.index('Read-LifeOSBoundedJsonFile -Path $manifestFile') < binding.index('Assert-RecoveryIdentity')
    assert binding.index('Assert-RecoveryIdentity') < binding.index('Assert-CanonicalRollbackManifest')
    assert 'Assert-AuthenticatedBackup -Manifest $manifest' in binding
    assert "[string]$Marker.state -cne 'installed'" in marker
    assert 'Unsupported legacy deployment shape' in verify
    for tree in ('$apiCode', '$gatewayCode', '$nodeRuntime', '$pythonBase', '$apiData', '$gatewayData', '$apiLogs', '$gatewayLogs', '$stateDirectory', '$localApiSecret'):
        assert f'Assert-RestrictedAcl {tree}' in verify
    assert 'Get-LifeOSScheduledTaskExact -TaskName $TailscaleSnapshotTaskName' in verify
    assert 'Get-ScheduledTask -TaskName $TailscaleSnapshotTaskName -ErrorAction SilentlyContinue' not in verify
    assert "Wait-LoopbackReadiness ([uri]'http://127.0.0.1:8787/ready')" in verify
    assert "Wait-LoopbackReadiness ([uri]'http://127.0.0.1:8421/ready')" in verify
    assert 'Get-LifeOSCandidateHashMap' in verify
    assert 'Assert-LifeOSInstalledTreeMatchesCandidate' in verify
    assert 'Assert-LifeOSGatewayReleaseMatchesCandidate' in verify
    assert 'Assert-LifeOSInstalledIntegrity -Manifest $manifest' in verify
    assert 'function Assert-RunningLifeOSServiceProcess' in verify
    assert 'CommandLine -ine $expectedInvocation' in verify
    assert 'ConfigPath $apiConfig' in verify
    assert 'ConfigPath $gatewayConfig' in verify


def test_recovery_progress_is_append_only_and_bounded_per_unit() -> None:
    common = read('Deployment.Common.ps1')
    restore = common.split('function Restore-ManifestArtifacts', 1)[1].split('function Copy-FileVerifiedAtomic', 1)[0]
    progress = common.split('function Read-RecoveryProgress', 1)[1].split('function Test-RecoveryAuthorityPath', 1)[0]
    assert '$script:LifeOSRecoveryProgressMaxBytes = 64 * 1024 * 1024' in common
    assert '$script:LifeOSRecoveryProgressMaxRecords = $script:LifeOSRecoveryMaxFileUnits * 2' in common
    assert '$script:LifeOSRecoveryProgressMaxRecordBytes = 16 * 1024' in common
    assert '$script:LifeOSRecoveryProgressCommitMarker' in common
    assert '$script:LifeOSRecoveryProgressDigestBytes = 32' in common
    assert 'function New-RecoveryProgressDigestInput' in common
    assert common.count('New-RecoveryProgressDigestInput -Header $header -Payload $payload') == 2
    assert 'function Append-RecoveryProgress' in common
    assert 'function Write-RecoveryProgressFramePart' in common
    assert 'function Assert-RecoveryProgressRecord' in common
    assert 'function Assert-RecoveryProgressCapacity' in common
    assert 'function Assert-RecoveryJournalCheckpointCapacity' in common
    checkpoint = common.split('function Assert-RecoveryJournalCheckpointCapacity', 1)[1].split('function Test-RecoveryAuthorityPath', 1)[0]
    assert '$initialCheckpoint' in checkpoint
    assert '$restoringCheckpoint' in checkpoint
    assert '$terminalCheckpoint' in checkpoint
    assert "'restoring'" in checkpoint
    assert 'foreach ($stageName in $script:LifeOSRecoveryStageNames)' in checkpoint
    unit_loop = restore.rsplit('$unitIndex = 0', 1)[1].split("Set-JournalProperty $journal 'phase' 'artifacts-complete'", 1)[0]
    assert 'Assert-RecoveryProgressCapacity -Manifest $Manifest -Journal $journal' in restore
    assert restore.index('Assert-RecoveryProgressCapacity -Manifest $Manifest -Journal $journal') < restore.index('Write-JsonAtomic $journalPath $journal')
    assert restore.index('Assert-RecoveryProgressCapacity -Manifest $Manifest -Journal $journal') < restore.index('Restore-Artifact $restore')
    assert 'Append-RecoveryProgress -Manifest $Manifest -Journal $journal -UnitIndex $unitIndex -Phase' in unit_loop
    assert 'Write-JsonAtomic' not in unit_loop
    assert 'Get-Content -LiteralPath $progressPath' not in progress
    assert 'incompleteTail' in progress
    assert '$magicBytesAvailable = [Math]::Min' in progress
    assert '$remaining -gt $script:LifeOSRecoveryProgressMagic.Length' in progress
    assert 'SetLength($committedOffset)' in progress
    assert 'Recovery progress committed record digest is invalid' in progress
    assert '$sequence -ge $script:LifeOSRecoveryProgressMaxRecords' in progress
    assert '$item.Length + $frame.TotalBytes -gt $script:LifeOSRecoveryProgressMaxBytes' in progress
    assert '@($Journal.units)' not in progress
    assert 'unitCount' in progress
    assert 'currentPhase -is [string] -and [string]$currentPhase -ceq $Phase' in progress
    assert 'Flush($true)' in progress
    units_accessor = common.split('function Get-RecoveryJournalUnits', 1)[1].split('function Write-RecoveryProgressFramePart', 1)[0]
    append = common.split('function Append-RecoveryProgress', 1)[1].split('function Assert-RecoveryProgressCapacity', 1)[0]
    assert "return ,$Journal['units']" in units_accessor
    assert 'return ,$property.Value' in units_accessor
    assert "Get-JournalProperty $Journal 'units'" not in append
    behavior_lower = read('tests/Deployment.Behavior.Tests.ps1').lower()
    for case in ('the reader recovers a torn', 'writer output round-trips through the real recovery progress reader',
                 'durable complete transitions are skipped at record and byte limits',
                 'writer output stays within the real reader serialized-size contract',
                 'oversized count-valid recovery journal is rejected before artifact mutation',
                 'progress capacity is rejected before artifact mutation'):
        assert case in behavior_lower
    assert "foreach ($position in @('interior', 'final'))" in read('tests/Deployment.Behavior.Tests.ps1')
    assert "foreach ($corruption in @('header', 'length', 'header-digest', 'payload', 'digest', 'commit'))" in read('tests/Deployment.Behavior.Tests.ps1')
    assert 'foreach ($partialLength in 1..8)' in read('tests/Deployment.Behavior.Tests.ps1')


def test_deployment_json_readers_reject_oversized_files_before_convert_from_json() -> None:
    common = read('Deployment.Common.ps1')
    rollback = read('rollback.ps1')
    install = read('install.ps1')
    verify = read('verify.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    bounded = common.split('function Read-LifeOSCappedFileBytes', 1)[1].split('function New-LifeOSTreeItemIdentity', 1)[0]
    assert 'OpenRead' in bounded
    assert 'SafeFileHandle' in bounded
    assert 'Assert-LifeOSPathIdentityChain' in bounded
    assert '$openedLength -gt $MaxBytes' in bounded
    assert 'stream.SafeFileHandle' in bounded
    assert 'GetFileInformationByHandle' in common
    assert 'FileId = Get-LifeOSNativeFileIdentity' in common
    assert '[string]$actual.FileId -cne [string]$Expected.FileId' in common
    assert 'buffer.Length' in bounded
    assert 'function Read-LifeOSPrefixBytes' in common
    assert 'function Get-LifeOSFileDigest' in common
    assert 'ExpectedFileId' in common
    assert 'Get-LifeOSFileIntegrity' in common
    json_reader = common.split('function Read-LifeOSBoundedJsonFile', 1)[1].split('function Get-LifeOSDeploymentMarkerPath', 1)[0]
    assert 'Read-LifeOSCappedFileText -Path $Path -MaxBytes $MaxBytes' in json_reader
    assert '$raw | ConvertFrom-Json' in json_reader
    assert '$script:LifeOSDeploymentMarkerMaxBytes = 64 * 1024' in common
    assert '$script:LifeOSGenerationManifestMaxBytes = 16 * 1024 * 1024' in common
    assert 'function Assert-LifeOSGenerationManifestCheckpointCapacity' in common
    assert '[AllowNull()][object[]]$FutureCheckpoints = @()' in common
    checkpoint = common.split('function Assert-LifeOSGenerationManifestCheckpointCapacity', 1)[1].split('function Assert-RecoveryIdentity', 1)[0]
    assert '$candidates = @($Manifest)' in checkpoint
    assert '$candidates += @($FutureCheckpoints)' in checkpoint
    assert '$candidateBytes -gt $script:LifeOSGenerationManifestMaxBytes' in checkpoint
    assert '$script:LifeOSRecoveryJournalMaxBytes = 64 * 1024 * 1024' in common
    writer = common.split('function Write-JsonAtomic', 1)[1].split('function Assert-PathOnlyJson', 1)[0]
    assert '[long]$MaxBytes = 0' in writer
    assert '$effectiveMaxBytes = $MaxBytes' in writer
    assert '$script:LifeOSRecoveryJournalMaxBytes' in writer
    assert '$bytes = [Text.UTF8Encoding]::new($false).GetBytes' in writer
    assert 'MaxBytes $script:LifeOSDeploymentMarkerMaxBytes' in common
    assert 'Assert-LifeOSDeploymentMarkerCheckpointCapacity' in common
    assert 'Assert-LifeOSGenerationManifestCheckpointCapacity $Manifest' in read('install.ps1')
    install = read('install.ps1')
    intent = install.split('function New-ManifestIntent', 1)[1].split('function Complete-ManifestIntent', 1)[0]
    assert '$pendingCandidate = New-LifeOSGenerationManifestCandidate' in intent
    assert '$completedCandidate = New-LifeOSGenerationManifestCandidate' in intent
    assert 'FutureCheckpoints @($pendingCandidate, $completedCandidate)' in intent
    assert "'sourceSha256'" in intent and "'sourceLength'" in intent
    assert 'Read-LifeOSBoundedJsonFile -Path $path -MaxBytes $script:LifeOSRecoveryJournalMaxBytes' in common
    assert 'Read-LifeOSBoundedJsonFile -Path $manifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes' in common
    assert 'Read-LifeOSBoundedJsonFile -Path $ManifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes' in rollback
    assert 'Read-LifeOSBoundedJsonFile -Path $manifestPath -MaxBytes $script:LifeOSGenerationManifestMaxBytes' in install
    assert 'Read-LifeOSBoundedJsonFile -Path $manifestFile -MaxBytes $script:LifeOSGenerationManifestMaxBytes' in verify
    assert 'oversized bounded JSON files are rejected before parsing' in behavior
    assert 'the recovery journal reader rejects an oversized file before parsing' in behavior
    assert 'the real JSON writer rejects a serialized recovery value over its configured bound' in behavior
    assert 'Generation manifest checkpoint exceeds its bounded serialized size.' in common
    assert 'near-limit marker writer output is accepted by its bounded reader.' in behavior
    assert 'marker terminal checkpoint growth is rejected before publication.' in behavior
    assert 'operation-specific manifest writer output is accepted by its bounded reader after completion.' in behavior
    assert 'authority pending/completed checkpoint growth is rejected before publication.' in behavior
    assert 'authority completion is preflighted near the 16 MiB writer boundary' in behavior
    assert 'persisted authority completion is accepted by the bounded reader' in behavior


def test_windows_powershell_51_path_chain_and_gateway_bundle_contracts_are_regressed() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    static = read('tests/Deployment.Static.Tests.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')

    chain = common.split('function Get-LifeOSPathIdentityChain', 1)[1].split('function Assert-LifeOSPathIdentityChain', 1)[0]
    assert 'return $chain.ToArray()' in chain
    assert 'return ,$chain.ToArray()' not in chain
    validation = common.split('function Assert-LifeOSPathIdentityChain', 1)[1].split('function Assert-ExistingDirectory', 1)[0]
    assert 'return $actual' in validation
    assert 'return ,$actual' not in validation
    for line in common.splitlines():
        if 'Get-LifeOSPathIdentityChain -Path' in line:
            assert '@(Get-LifeOSPathIdentityChain -Path' in line

    gateway = install.split('function Copy-GatewayCodeBundle', 1)[1].split('function Initialize-SupplementCatalog', 1)[0]
    bundle_assignment = re.search(r'\$bundleFiles\s*=\s*@\(.*?\}\)(?P<tail>[^\r\n]*)', gateway, re.S)
    assert bundle_assignment and '-MaxBytes' not in bundle_assignment.group('tail')
    assert re.search(
        r'Write-JsonAtomic\s+-Path\s+\$releaseManifestPath\s+-Value\s+\(\[ordered\]@\{.*?'
        r'bundleFiles\s*=\s*\$bundleFiles.*?\}\)\s+-MaxBytes\s+'
        r'\$script:LifeOSGenerationManifestMaxBytes',
        gateway,
        re.S,
    )
    assert 'nested candidate paths return a flat identity chain with the leaf last.' in behavior
    assert 'a stable nested candidate SOURCE_SHA file passes the capped reader.' in behavior
    assert 'an identity/path change on a nested candidate file is rejected.' in behavior
    assert 'Parse the actual installer in definition-only mode' in behavior
    assert 'Copy-GatewayCodeBundle' in behavior
    assert 'the parsed gateway bundle helper stages every file and publishes a bounded v18 manifest.' in behavior
    assert 'Gateway bundle byte bounds must not be attached to the bundleFiles array expression.' in static
    assert 'Gateway release manifest must pass its byte bound to Write-JsonAtomic.' in static


def test_fresh_backend_identity_repairs_have_static_and_behavior_regressions() -> None:
    common = read('Deployment.Common.ps1')
    install = read('install.ps1')
    rollback = read('rollback.ps1')
    candidate = read('verify-candidate.ps1')
    verify = read('verify.ps1')
    static = read('tests/Deployment.Static.Tests.ps1')
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    launcher = read('gateway_launcher.py')
    launcher_test = (ROOT / 'services' / 'gateway' / 'test_gateway_launcher.py').read_text(encoding='utf-8')
    clipper = (ROOT / 'services' / 'api' / 'src' / 'clipper-store.ts').read_text(encoding='utf-8')
    clipper_test = (ROOT / 'services' / 'api' / 'src' / 'clipper-store.test.ts').read_text(encoding='utf-8')

    assert '_safe_path(value["dataDirectory"], file=False, directory=True)' in launcher
    assert 'def _read_bounded_regular_file' in launcher
    assert 'os.fstat(descriptor)' in launcher
    assert 'O_NOFOLLOW' in launcher and 'FILE_FLAG_OPEN_REPARSE_POINT' in launcher
    assert 'path identity changed while it was being read' in launcher
    assert 'test_read_config_accepts_a_valid_config_without_mocking_path_validation' in launcher_test
    assert 'test_bounded_config_and_secret_reads_fail_closed_on_growth_or_replacement' in launcher_test

    generation_guard = clipper.split('if (!(await this.fileStillMatches(state.signature))) continue;', 1)[1]
    assert 'this.loaded || this.loadGeneration !== generation' in generation_guard
    assert 'rechecks the generation after a delayed file identity check' in clipper_test

    assert 'OpenRead' in common and 'Get(SafeFileHandle' in common
    assert 'OpenForAcl' in common and 'SetDacl' in common
    assert 'function Set-LifeOSAclWithBoundHandle' in common
    assert 'Assert-LifeOSPathIdentityChain -Expected $chain' in common
    bounded_tree = common.split('function Get-LifeOSBoundedTreeItem', 1)[1].split('function Get-TreeManifestIndex', 1)[0]
    assert '[IO.Directory]::EnumerateFileSystemEntries' in bounded_tree
    assert '$enumerator.MoveNext()' in bounded_tree
    assert '$enumerator.Dispose()' in bounded_tree
    assert 'Get-ChildItem' not in bounded_tree
    assert 'MaxFiles' in bounded_tree and 'MaxDirectories' in bounded_tree and 'MaxBytes' in bounded_tree
    assert '$seenPaths = [System.Collections.Generic.HashSet[string]]::new' in bounded_tree
    assert '$seenPaths.Add($fullName)' in bounded_tree
    assert 'Bounded tree contains a duplicate path' in bounded_tree
    assert 'Bounded tree contains too many files.' in bounded_tree
    assert 'Bounded tree contains too many directories.' in bounded_tree
    assert 'Bounded tree exceeds its byte limit' in bounded_tree
    assert "Assert-LifeOSTreeItemIdentity -Path $directory -Expected $queuedDirectory.Identity -Description 'Bounded tree directory' | Out-Null" in common
    assert 'Get-LifeOSFileDigest -Path $item.FullName' in common
    assert 'Get-LifeOSFileIntegrity -Path $Path' in common
    assert 'Read-LifeOSCappedFileText -Path $pyvenv' in install
    assert 'Get-ChildItem -LiteralPath $root -Force -ErrorAction Stop | ForEach-Object' in install
    assert 'Read-LifeOSCappedFileText -Path $source' in install
    assert 'Read-LifeOSCappedFileText -Path $taskBackup' in rollback
    assert 'Read-LifeOSPrefixBytes -Path $Path -Count 2' in candidate
    assert 'Get-LifeOSFileDigest -Path $candidatePath' in candidate
    assert 'Get-LifeOSFileIntegrity -Path $candidatePath' in verify
    assert 'Get-LifeOSFileIntegrity -Path $installedPath' in verify

    assert 'function New-LifeOSManagedAcl' in static
    assert 'function Set-LifeOSAclWithBoundHandle' in static
    assert 'replacement candidate' in behavior.lower()
    assert 'ACL mutation fails closed when the path is replaced after validation' in behavior
    assert 'bounded inventory rejects a junction before descent' in behavior

    restore = common.split('function Restore-AclSnapshots', 1)[1].split('function Assert-NoBroadAcl', 1)[0]
    assert '/restore' not in restore.lower()
    assert 'Read-LifeOSBoundedJsonFile -Path $backup' in restore
    assert 'LifeOSAclTreeV1' in restore
    assert 'Get-LifeOSTreeRelativePath' in restore
    assert 'Set-LifeOSAclWithBoundHandle -Path $entry.Path' in restore
    restore_set = restore.index('Set-LifeOSAclWithBoundHandle -Path $entry.Path')
    assert 'Assert-LifeOSTreeItemIdentity -Path $entry.Path' in restore[restore_set:]
    assert 'Assert-LifeOSPathIdentityChain -Expected $entry.PathIdentityChain' in restore[restore_set:]
    assert 'ACL restore tree contents changed since the snapshot.' in restore


def test_windows_powershell_51_duplicate_guards_use_compatible_add() -> None:
    verify = read('verify.ps1')
    assert '.TryAdd(' not in verify
    for contains_key, add_call, duplicate_message in (
        ('$hashes.ContainsKey($relative)', '[void]$hashes.Add($relative, [string]$Matches[\'hash\'])', 'Candidate inventory manifest contains a duplicate'),
        ('$expected.ContainsKey($tail)', '[void]$expected.Add($tail, $relative)', 'candidate mapping is duplicated or empty'),
        ('$candidateByInstalled.ContainsKey($installedName)', '[void]$candidateByInstalled.Add($installedName, [string]$mapping.Candidate)', 'duplicate installed mapping'),
    ):
        assert contains_key in verify
        assert add_call in verify
        assert duplicate_message in verify


def test_native_acl_and_descriptor_stream_contracts_are_synchronous_and_bool_safe() -> None:
    common = read('Deployment.Common.ps1')
    native = common.split("Add-Type -TypeDefinition @'", 1)[1].split("'@ -ErrorAction Stop", 1)[0]

    assert '[return: MarshalAs(UnmanagedType.Bool)]\n    private static extern bool GetSecurityDescriptorDacl' in native
    assert 'if (!GetSecurityDescriptorDacl(' in native
    assert 'throw new Win32Exception(Marshal.GetLastWin32Error());' in native
    assert 'if (!present) { dacl = IntPtr.Zero; }' in native
    assert 'uint result = GetSecurityDescriptorDacl' not in native

    streams = [line.strip() for line in common.splitlines() if '[IO.FileStream]::new' in line]
    assert len(streams) == 3
    assert all(line.endswith('$false)') for line in streams)


def test_recovery_inventory_uses_bounded_hash_sets_without_per_file_full_scans() -> None:
    common = read('Deployment.Common.ps1')
    reader = common.split('function Read-RecoveryJournal', 1)[1].split('function Save-CollectorReceipt', 1)[0]
    restore = common.split('function Restore-ManifestArtifacts', 1)[1].split('function Copy-FileVerifiedAtomic', 1)[0]
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    inventory = reader.split('foreach ($root in $scanRoots)', 1)[1].split('foreach ($unit in $journalUnits)', 1)[0]
    assert '$destinationSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)' in reader
    assert '$stagingSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)' in reader
    assert '$allowedRootSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)' in reader
    assert '$treeRootSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)' in reader
    assert '$script:LifeOSRecoveryMaxTreeRoots = 256' in common
    assert '$script:LifeOSRecoveryMaxFileUnits = 65536' in common
    assert '$script:LifeOSRecoveryMaxTreeBytes = 512 * 1024 * 1024' in common
    assert '$script:LifeOSRecoveryMaxFileBytes = 64 * 1024 * 1024' in common
    assert '$script:LifeOSRecoveryMaxInventoryBytes = 512 * 1024 * 1024' in common
    assert "function Get-LifeOSDefaultLargeFileRelativePath" in common
    assert "function Get-LifeOSBoundedFileMaxBytes" in common
    assert "function Get-LifeOSRecoveryFileMaxBytes" in common
    manifest_index = common.split("function Get-TreeManifestIndex", 1)[1].split("function Get-TreeManifest {", 1)[0]
    assert "-LargeFileContracts $effectiveLargeFileContracts" in manifest_index
    recovery_index = common.split("function Get-RecoveryTreeManifestIndex", 1)[1].split("function Compare-TreeManifest", 1)[0]
    assert "[System.Collections.IDictionary]$LargeFileContracts" in recovery_index
    assert "-LargeFileContracts $LargeFileContracts" in recovery_index
    compare = common.split("function Compare-TreeManifest", 1)[1].split("function New-BackupDirectory", 1)[0]
    assert "Get-TreeManifest $Source -LargeFileContracts $LargeFileContracts" in compare
    copy_tree = common.split("function Copy-TreeVerifiedAtomic", 1)[1].split("function New-RandomSecret", 1)[0]
    assert "-LargeFileContracts $LargeFileContracts" in copy_tree
    staging = common.split('function Get-LifeOSNodeRuntimeStagingRelativePaths', 1)[1].split('function Assert-LifeOSLargeFileContract', 1)[0]
    assert 'Test-LifeOSNodeRuntimeArtifactPath -Manifest $Manifest -Path $destination)' in staging
    assert 'Assert-LifeOSNodeRuntimeStagingRelativePath $relativeStage' in staging
    assert "relativeStage + '/node.exe'" not in staging
    assert "'node-runtime/node.exe' = $maxCandidateNodeFileBytes" in read('verify-candidate.ps1')
    assert "'service-host/LifeOS.ServiceHost.exe' = $maxCandidateServiceHostFileBytes" in read('verify-candidate.ps1')
    assert "LargeFileRelativePath $nodeLargeFileRelativePath" in read('install.ps1')
    assert "-MaxBytes $hostMaxFileBytes" in read('install.ps1')
    assert "AllowServiceHostBinary" in common
    assert 'function Assert-RecoveryInventoryBounds' in common
    assert 'function Get-RecoveryTreeManifestIndex' in common
    assert 'function Get-RecoveryCanonicalTreeRoots' in common
    artifact_state = common.split('function Get-RecoveryArtifactState', 1)[1].split('function Assert-RecoveryUnitState', 1)[0]
    assert "Get-LifeOSRecoveryFileMaxBytes -Path $Path" in artifact_state
    assert '$item.Length -gt $maxFileBytes' in artifact_state
    assert 'Assert-RecoveryInventoryBounds -TreeRoots $treeRoots -FileUnits $journalUnits -ManifestBackups $manifestBackups' in reader
    assert '$treeRoots.Count -gt 256 -or $journalUnits.Count -gt 256' not in reader
    assert '$journalUnits.Count -gt 256' not in reader
    assert '$manifestBackups.Count -gt 256' not in reader
    assert reader.index('Assert-RecoveryInventoryBounds -TreeRoots $treeRoots') < reader.index('$scanRoots =')
    assert 'Get-RecoveryTreeManifestIndex -Root $root -Cache $treeIndexCache' in inventory
    assert 'destinationSet.Contains($filePath)' in inventory
    assert 'stagingSet.Contains($filePath)' in inventory
    assert '[void]$stagingSet.Add($stageFull)' in reader
    assert '-LargeFileRelativePaths $LargeFileRelativePaths' in common
    assert '$discoveredFileCount -gt $script:LifeOSRecoveryMaxFileUnits' in inventory
    assert 'allowedRoots | Where-Object' not in inventory
    assert 'journal.units | Where-Object' not in inventory
    assert '@($journal.units | ForEach-Object { $_.destination })' not in inventory
    assert 'Assert-RecoveryInventoryBounds -TreeRoots $canonicalTreeRoots -FileUnits $units.Values -ManifestBackups $artifacts' in restore
    assert 'Get-RecoveryTreeManifestIndex -Root $guard -Cache $treeIndexCache' in restore
    assert 'Get-RecoveryTreeManifestIndex -Root $destination -Cache $treeIndexCache -TotalBytes ([ref]$inventoryBytes) -AllowNodeRuntime:$allowNodeRuntime' in restore
    assert 'Get-RecoveryTreeManifestIndex -Root $backup -Cache $treeIndexCache -TotalBytes ([ref]$inventoryBytes) -AllowNodeRuntime:$allowNodeRuntime' in restore
    assert 'Restore-Artifact $restore $BackupDirectory -AllowNodeRuntime:$allowNodeRuntime' in restore
    assert 'Get-RecoveryArtifactState $unit.destination -AllowNodeRuntime:$allowNodeRuntime' in restore
    assert restore.index('Assert-RecoveryInventoryBounds -TreeRoots $canonicalTreeRoots') < restore.index('Write-JsonAtomic $journalPath $journal')
    for case in ('recovery rejects an over-limit file inventory before mutation',
                 'a realistic 257-file inventory is accepted before artifact mutation',
                 'an accepted expanded inventory performs no artifact mutation when states already match',
                 'partial service snapshot maps are rejected before SCM mutation',
                 'service health failure remains retryable',
                 'an oversized tree file is rejected before hashing the file'):
        assert case in behavior



def test_remaining_recovery_invariants_are_wired_into_production() -> None:
    common, install, rollback = read('Deployment.Common.ps1'), read('install.ps1'), read('rollback.ps1')
    stage = common.split('function Invoke-RecoveryStage', 1)[1].split('function Get-RecoveryJournalPath', 1)[0]
    assert stage.index('Read-RecoveryJournal $Manifest') < stage.index('& $Action')
    assert "journal.phase -ne 'artifacts-complete'" in stage
    assert "pre='absent'; post='absent'" in common
    assert 'Assert-CanonicalRollbackManifest -Manifest $manifest -ManifestPath $manifestPath -AllowPending' in rollback
    recovery = install.split('$deploymentRollbackSucceeded = $true', 1)[1]
    assert recovery.index('$manifest = $recoveryManifest') < recovery.index('Stop-DeploymentTaskBarrier $manifest $manifestPath')
    assert "PreviousState -eq 'recovered'" in install and '$previousAuthority[0].beforeTree' in install
    assert "Installed code has no versioned authority provenance" in common
    assert "Orphan authority companion" in common
    receipt = common.split('function Get-CollectorTransition', 1)[1].split('function Test-CollectorUsagePreserved', 1)[0]
    for field in ('transactionId', 'generation', 'operatorSid', 'manifestPath', 'usageBefore', 'startedAtUtc'):
        assert field in receipt
    assert install.index('Save-CollectorReceipt $manifest') < install.index('$manifest.codexCollectorVerification = ')
    assert 'Get-CollectorTransition $Manifest' in common
    assert 'Get-Service -ErrorAction Stop | Where-Object' in common
    assert "([IO.Path]::GetExtension($target.FullName) -in @('.exe', '.dll'))" in common
    assert '[long]$rights::' not in common  # Windows PowerShell 5.1 uses the concrete enum type.


def test_windows_behavior_suite_exercises_failure_and_service_identity_adapters() -> None:
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    for case in ('failed manifest write preserves the previous rollback baseline',
                 'recovery stage retries after authority is restored',
                 'foreign recovery stage journal is rejected',
                 'an absent usage baseline still guards future writes',
                 'task enumeration errors fail closed',
                 'service enumeration errors fail closed',
                 'actual service identity must execute the image',
                 'actual service identity cannot write its secret',
                 'owner rights do not substitute for actual service rights',
                 'service-owned writable child is rejected without an explicit scope',
                 'shared-root validation returns both expected service subtrees',
                 'missing shared-root child is rejected',
                 'unexpected shared-root files are rejected',
                 'expected shared-root file is rejected as a child directory',
                 'cross-service shared-root access is rejected',
                 'reparse shared-root child is rejected',
                 'gateway supplement catalog',
                 'does not require inheritable SYSTEM rights',
                 'owner scope rejects non-service identities',
                 'owner scope requires the service Modify role',
                 'other service owner is rejected in a writable tree',
                 'non-service owner is rejected in a writable tree',
                 'service ownership is rejected on protected code',
                 'service ownership is rejected on protected secrets',
                 'service ownership is rejected on authenticated backups'):
        assert case in behavior
    assert '$script:aclOwner' in behavior
    assert 'Owner=$script:aclOwner' in behavior



def test_recovery_writer_boundary_preserves_new_authority_without_rebasing_code() -> None:
    common = read('Deployment.Common.ps1')
    reader = common.split('function Read-RecoveryJournal', 1)[1].split('function Save-CollectorReceipt', 1)[0]
    assert reader.index('Recovery journal belongs to another transaction') < reader.index('$writersReleased =')
    assert "journal.phase -notin @('artifacts-complete', 'completed')" in reader
    assert 'Test-RecoveryAuthorityPath $Manifest $unit.destination' in reader
    assert '$indexedStates.ContainsKey($unitDestination)' in reader
    assert 'Assert-RecoveryUnitState $unit $current' in reader
    restore = common.split('function Restore-ManifestArtifacts', 1)[1].split('function Copy-FileVerifiedAtomic', 1)[0]
    assert restore.index("$journal.phase -in @('artifacts-complete', 'completed')) { return }") < restore.index('Restore-Artifact $restore')
    for source, first_writer in ((read('install.ps1'), 'Restore-LegacyTask $legacy $LegacyTaskName'),
                                 (read('rollback.ps1'), 'Restore-LegacyTask $legacySnapshot $LegacyTaskName')):
        assert source.index('Enable-RecoveryWriterRestoration $manifest') < source.index(first_writer)
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    assert 'released prior writers retain observations on a later recovery retry' in behavior
    assert 'writer release never bypasses transaction ownership' in behavior



def test_recovery_accepts_exact_restored_serve_without_replaying_commands() -> None:
    common = read('Deployment.Common.ps1')
    restore = common.split('function Restore-TailscaleServeSnapshot', 1)[1].split('function Write-JsonAtomic', 1)[0]
    restored = "if ((Get-TailscaleServeFingerprint $current) -eq (Get-TailscaleServeFingerprint $Json)) { return }"
    assert restored in restore
    assert restore.index(restored) < restore.index('Restore-TailscaleServeLegacyMapping')
    assert 'Serve retry rejects a changed route after restoration' in read('tests/Deployment.Behavior.Tests.ps1')



def test_transaction_identity_never_authorizes_unowned_journal_paths() -> None:
    reader = read('Deployment.Common.ps1').split('function Read-RecoveryJournal', 1)[1].split('function Save-CollectorReceipt', 1)[0]
    for guard in ('Recovery journal tree root is not manifest owned', 'Recovery journal unit is not canonical',
                  'Recovery journal backup escapes the transaction', 'Recovery writer boundary is not boolean'):
        assert guard in reader
    assert "$unit.stagingPath -ne $stage" in reader
    behavior = read('tests/Deployment.Behavior.Tests.ps1')
    for case in ('matching transaction cannot delete an unowned staging path',
                 'matching transaction cannot restore outside manifest roots',
                 'matching transaction cannot read an unrelated backup'):
        assert case in behavior
