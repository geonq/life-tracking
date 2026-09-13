#!/usr/bin/env python3
"""Install the Claude Code usage forwarder without replacing user settings.

The installer is deliberately explicit: it only writes after ``--apply`` and
never stores a credential.  It configures Claude Code's documented statusLine
command plus a per-user launchd agent that drains the private spool to the
already authenticated LifeOS gateway.
"""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

try:
    from .claude_usage_uploader import validate_endpoint
except ImportError:  # pragma: no cover - direct script execution
    from claude_usage_uploader import validate_endpoint  # type: ignore[no-redef]


DEFAULT_ENDPOINT = "https://geonqserver.tail5f8789.ts.net:8420/usage/claude-ingest"
AGENT_LABEL = "com.lifeos.claude-usage-uploader"


def _private_directory(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    if path.is_symlink() or not path.is_dir():
        raise RuntimeError(f"state path is not a real directory: {path}")
    os.chmod(path, 0o700)


def _read_settings(path: Path) -> dict[str, Any]:
    if os.path.lexists(os.fspath(path)) and path.is_symlink():
        raise RuntimeError(f"settings path must not be a symlink: {path}")
    if not path.exists():
        return {}
    if not path.is_file():
        raise RuntimeError(f"settings path is not a regular file: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise RuntimeError(f"cannot read Claude settings: {path}") from exc
    if not isinstance(value, dict):
        raise RuntimeError("Claude settings root must be an object")
    return value


def _write_private_json(path: Path, value: Any) -> None:
    _private_directory(path.parent)
    encoded = (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=os.fspath(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            fd = -1
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if fd != -1:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _write_private_plist(path: Path, value: dict[str, Any]) -> None:
    _private_directory(path.parent)
    encoded = plistlib.dumps(value, fmt=plistlib.FMT_XML, sort_keys=False)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=os.fspath(path.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb", closefd=True) as stream:
            fd = -1
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    finally:
        if fd != -1:
            os.close(fd)
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def _backup_settings(path: Path, state_dir: Path) -> Path | None:
    if not path.exists():
        return None
    # Fixed name, written only once: the first --apply run captures the
    # pristine pre-LifeOS settings, and every rerun after that must leave
    # this file untouched so it stays the recovery point.
    backup = state_dir / "settings.json.before-lifeos"
    if not backup.exists():
        shutil.copy2(path, backup)
        os.chmod(backup, 0o600)
    return backup


def build_plan(
    *,
    repo_root: Path,
    home: Path,
    endpoint: str = DEFAULT_ENDPOINT,
    state_dir: Path | None = None,
) -> dict[str, Any]:
    """Build all paths and payloads without touching the user's machine."""

    validated_endpoint = validate_endpoint(endpoint)
    resolved_repo = repo_root.expanduser().resolve()
    if not (resolved_repo / "scripts/usage/claude_statusline_collector.py").is_file():
        raise RuntimeError("repo root does not contain the Claude usage collector")
    resolved_home = home.expanduser().resolve()
    resolved_state = (state_dir or resolved_home / ".lifeos" / "claude-usage").expanduser().resolve()
    claude_dir = resolved_home / ".claude"
    settings_path = claude_dir / "settings.json"
    collector = resolved_repo / "scripts/usage/claude_statusline_collector.py"
    uploader = resolved_repo / "scripts/usage/claude_usage_uploader.py"
    python = Path(shutil.which("python3") or shutil.which("python") or sys.executable)
    if not python.is_absolute():
        python = python.resolve()
    if not python.exists():
        raise RuntimeError(f"python interpreter not found: {python}")
    spool = resolved_state / "claude-usage.json"
    config = resolved_state / "endpoint.json"
    plist = resolved_home / "Library" / "LaunchAgents" / f"{AGENT_LABEL}.plist"

    status_command = " ".join([
        shlex.quote(os.fspath(python)),
        shlex.quote(os.fspath(collector)),
        "--spool",
        shlex.quote(os.fspath(spool)),
    ])
    launchd = {
        "Label": AGENT_LABEL,
        "ProgramArguments": [os.fspath(python), os.fspath(uploader), "--spool", os.fspath(spool), "--config", os.fspath(config)],
        "RunAtLoad": True,
        "StartInterval": 60,
        "ProcessType": "Background",
        "LowPriorityIO": True,
        "ThrottleInterval": 30,
        "StandardOutPath": os.fspath(resolved_state / "uploader.stdout.log"),
        "StandardErrorPath": os.fspath(resolved_state / "uploader.stderr.log"),
    }
    return {
        "endpoint": validated_endpoint,
        "repo_root": resolved_repo,
        "home": resolved_home,
        "state_dir": resolved_state,
        "claude_dir": claude_dir,
        "settings_path": settings_path,
        "collector": collector,
        "uploader": uploader,
        "python": python,
        "spool": spool,
        "config": config,
        "plist": plist,
        "status_command": status_command,
        "launchd": launchd,
    }


def apply_plan(plan: dict[str, Any], *, load_agent: bool = False) -> None:
    state_dir: Path = plan["state_dir"]
    claude_dir: Path = plan["claude_dir"]
    settings_path: Path = plan["settings_path"]
    plist: Path = plan["plist"]
    _private_directory(state_dir)
    _private_directory(claude_dir)
    _private_directory(plist.parent)

    settings = _read_settings(settings_path)
    backup = _backup_settings(settings_path, state_dir)
    existing_status_line = settings.get("statusLine")
    # Keep documented presentation options such as ``padding`` when a user
    # already has a command status line. The collector command is the only
    # behavior this installer owns.
    status_line = dict(existing_status_line) if isinstance(existing_status_line, dict) else {}
    status_line.update({
        "type": "command",
        "command": plan["status_command"],
    })
    settings["statusLine"] = status_line
    _write_private_json(settings_path, settings)
    _write_private_json(plan["config"], {"endpoint": plan["endpoint"]})
    _write_private_plist(plist, plan["launchd"])

    if load_agent:
        uid = os.getuid()
        domain = f"gui/{uid}"
        subprocess.run(["launchctl", "bootout", domain, os.fspath(plist)], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        subprocess.run(["launchctl", "bootstrap", domain, os.fspath(plist)], check=True)

    print(json.dumps({
        "status": "installed",
        "settings": os.fspath(settings_path),
        "settings_backup": os.fspath(backup) if backup else None,
        "spool": os.fspath(plan["spool"]),
        "endpoint_config": os.fspath(plan["config"]),
        "launch_agent": os.fspath(plist),
        "agent_loaded": load_agent,
    }, sort_keys=True))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--home", type=Path, default=Path.home())
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--state-dir", type=Path)
    parser.add_argument("--apply", action="store_true", help="write settings, endpoint config, and LaunchAgent")
    parser.add_argument("--load-agent", action="store_true", help="also bootstrap the LaunchAgent after --apply")
    args = parser.parse_args(argv)
    if args.load_agent and not args.apply:
        parser.error("--load-agent requires --apply")
    try:
        plan = build_plan(repo_root=args.repo_root, home=args.home, endpoint=args.endpoint, state_dir=args.state_dir)
        if not args.apply:
            print(json.dumps({
                "status": "dry-run",
                "endpoint": plan["endpoint"],
                "settings": os.fspath(plan["settings_path"]),
                "spool": os.fspath(plan["spool"]),
                "endpoint_config": os.fspath(plan["config"]),
                "launch_agent": os.fspath(plan["plist"]),
                "status_command": plan["status_command"],
            }, sort_keys=True))
        else:
            apply_plan(plan, load_agent=args.load_agent)
        return 0
    except Exception as exc:
        print(f"lifeos Claude usage installer unavailable: {exc}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
