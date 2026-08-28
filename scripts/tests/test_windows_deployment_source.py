from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEPLOY = ROOT / "services" / "windows-service-host" / "deploy"


def read(name: str) -> str:
    return (DEPLOY / name).read_text(encoding="utf-8")


def test_gateway_uses_separate_serve_and_identity_payloads() -> None:
    source = read("gateway_launcher.py")
    assert '"serve", "status", "--json"' in source
    assert '"status", "--json"' in source
    assert "_tailscale_dns_name(identity_status)" in source
    assert "_serve_is_exact(serve_status, expected_dns_name=expected_dns_name)" in source
    assert "_tailscale_login(tailscale, identity_status)" in source


def test_codex_task_has_file_only_secret_argument_and_cutover_gate() -> None:
    common = read("Deployment.Common.ps1")
    install = read("install.ps1")
    assert "[Parameter(Mandatory)][string]$SecretFile" in common
    assert "--secret-file" in common
    assert "Start-CodexCollectorAndVerify" in install
    assert "-SecretFile $codexSecret" in install
    assert "Wait-CodexUsageObservation" in common


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
