"""Least-privilege gateway adapter used by the Windows service host.

The adapter owns the process boundary: it validates the path-only deployment
config and private Tailscale Serve route, derives the local Tailscale login at
runtime, sets the gateway's data/secret environment, then imports the reviewed
FastAPI module and runs it through uvicorn.  It never prints config, identity,
or secret material.
"""

from __future__ import annotations

import argparse
import importlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
from typing import Any


EXPECTED_FIELDS = {
    "bindHost",
    "port",
    "apiBaseUrl",
    "dataDirectory",
    "calendarPath",
    "documentsPath",
    "claudeSecretPath",
    "tailscaleServePort",
    "funnel",
}
PRIVATE_PROXY = "http://127.0.0.1:8421"


def _safe_path(value: Any, *, file: bool, directory: bool) -> Path:
    if not isinstance(value, str) or not value or not Path(value).is_absolute() or "\x00" in value:
        raise RuntimeError("invalid deployment path")
    path = Path(value)
    for component in (path, *path.parents):
        if component.exists() and component.is_symlink():
            raise RuntimeError("reparse deployment path")
    if file and not path.is_file():
        raise RuntimeError("required deployment file is missing")
    if directory and not path.is_dir():
        raise RuntimeError("required deployment directory is missing")
    return path


def _read_config(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError("gateway config invalid") from exc
    if not isinstance(value, dict) or set(value) != EXPECTED_FIELDS:
        raise RuntimeError("gateway config fields invalid")
    if value["bindHost"] != "127.0.0.1" or type(value["port"]) is not int or value["port"] != 8421 or type(value["tailscaleServePort"]) is not int or value["tailscaleServePort"] != 8420 or type(value["funnel"]) is not bool or value["funnel"] is not False:
        raise RuntimeError("gateway config is not loopback-only")
    if value["apiBaseUrl"] != "http://127.0.0.1:8787":
        raise RuntimeError("gateway API is not loopback-only")
    value["dataDirectory"] = str(_safe_path(value["dataDirectory"], directory=True))
    value["calendarPath"] = str(_safe_path(value["calendarPath"], file=False, directory=False))
    value["documentsPath"] = str(_safe_path(value["documentsPath"], file=False, directory=True))
    value["claudeSecretPath"] = str(_safe_path(value["claudeSecretPath"], file=True, directory=False))
    secret_path = Path(value["claudeSecretPath"])
    if secret_path.stat().st_size > 4096:
        raise RuntimeError("gateway secret is oversized")
    secret = secret_path.read_bytes().decode("ascii")
    if not 32 <= len(secret) <= 256 or not re.fullmatch(r"[\x21-\x7e]+", secret):
        raise RuntimeError("gateway secret invalid")
    return value


def _run_tailscale(executable: Path, *args: str) -> dict[str, Any]:
    try:
        result = subprocess.run([str(executable), *args], check=True, capture_output=True, text=True, shell=False, timeout=8)
        if len(result.stdout) > 65536:
            raise RuntimeError("tailscale response oversized")
        parsed = json.loads(result.stdout)
    except Exception as exc:
        raise RuntimeError("tailscale query failed") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("tailscale response invalid")
    return parsed


def _truthy_private_flags(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if key in {"Funnel", "AllowFunnel"} and child is True:
                found.append(key)
            found.extend(_truthy_private_flags(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(_truthy_private_flags(child))
    return found


def _proxy_targets(value: Any) -> list[str]:
    if isinstance(value, dict):
        targets: list[str] = []
        for key, child in value.items():
            if key == "Proxy" and isinstance(child, str):
                targets.append(child)
            targets.extend(_proxy_targets(child))
        return targets
    if isinstance(value, list):
        targets = []
        for child in value:
            targets.extend(_proxy_targets(child))
        return targets
    return []


def _serve_is_exact(status: dict[str, Any]) -> bool:
    if _truthy_private_flags(status):
        return False
    if _proxy_targets(status).count(PRIVATE_PROXY) != 1:
        return False
    # Serve's contract is Web -> HTTPS endpoint -> Handlers -> "/" -> Proxy.
    # Accept the equivalent TCP map only when its 8420 key is present.
    web = status.get("Web")
    if isinstance(web, dict):
        for endpoint, config in web.items():
            if isinstance(endpoint, str) and ":8420" in endpoint and isinstance(config, dict):
                handlers = config.get("Handlers")
                if isinstance(handlers, dict) and isinstance(handlers.get("/"), dict) and handlers["/"].get("Proxy") == PRIVATE_PROXY:
                    return True
    tcp = status.get("TCP")
    if isinstance(tcp, dict) and isinstance(tcp.get("8420"), dict):
        return _proxy_targets(tcp["8420"]).count(PRIVATE_PROXY) == 1
    return False


def _tailscale_login(executable: Path, status: dict[str, Any]) -> str:
    self_node = status.get("Self")
    login = None
    if isinstance(self_node, dict):
        users = status.get("User")
        user_id = self_node.get("UserID")
        profile = users.get(str(user_id)) if isinstance(users, dict) and user_id is not None else None
        if isinstance(profile, dict):
            login = profile.get("LoginName")
        if not isinstance(login, str) or not login:
            profile = self_node.get("UserProfile")
            if isinstance(profile, dict):
                login = profile.get("LoginName")
        addresses = self_node.get("TailscaleIPs")
        if not isinstance(login, str) or not login:
            if isinstance(addresses, list) and addresses and isinstance(addresses[0], str):
                whois = _run_tailscale(executable, "whois", "--json", addresses[0])
                profile = whois.get("UserProfile")
                if isinstance(profile, dict):
                    login = profile.get("LoginName")
    if not isinstance(login, str) or not login or len(login) > 256 or re.search(r"[\x00-\x1f\x7f]", login):
        raise RuntimeError("tailscale login unavailable")
    return login


def run(config_path: Path, entry_point: Path, tailscale: Path) -> int:
    config = _read_config(config_path)
    status = _run_tailscale(tailscale, "serve", "status", "--json")
    if not _serve_is_exact(status):
        raise RuntimeError("private Serve mapping invalid")
    login = _tailscale_login(tailscale, status)
    data_dir = Path(config["dataDirectory"])
    os.environ.update(
        {
            "LIFEOS_DATA_DIR": str(data_dir),
            "LIFEOS_CALENDAR_PATH": config["calendarPath"],
            "LIFEOS_DOCUMENTS_DIR": config["documentsPath"],
            "CLAUDE_INGEST_SECRET_FILE": config["claudeSecretPath"],
            "LIFEOS_CLAUDE_SECRET_FILE": config["claudeSecretPath"],
            "LIFEOS_TAILSCALE_ALLOWED_LOGIN": login,
            "LIFEOS_GATEWAY_CONFIG_PATH": str(config_path),
            "PORT": "8421",
        }
    )
    sys.path.insert(0, str(entry_point.parent))
    module = importlib.import_module(entry_point.stem)
    app = getattr(module, "app", None)
    if app is None:
        raise RuntimeError("gateway app missing")
    # Reviewed gateway modules may expose these constants.  Set them after
    # import as a defence-in-depth bridge while retaining the env contract.
    for name in ("DATA_DIR", "LIFEOS_DATA_DIR"):
        if hasattr(module, name):
            setattr(module, name, data_dir)
    for name in ("CLAUDE_SECRET_PATH", "CLAUDE_INGEST_SECRET_FILE", "LIFEOS_CLAUDE_SECRET_FILE", "CLAUDE_INGEST_SECRET_FILENAME"):
        if hasattr(module, name):
            setattr(module, name, Path(config["claudeSecretPath"]))
    for name in ("_ingest_secret_path", "ingest_secret_path", "_claude_secret_path", "claude_secret_path"):
        resolver = getattr(module, name, None)
        if callable(resolver):
            setattr(module, name, lambda _resolver=None, path=Path(config["claudeSecretPath"]): path)
    for name in ("CALENDAR_PATH", "LIFEOS_CALENDAR_PATH"):
        if hasattr(module, name):
            setattr(module, name, Path(config["calendarPath"]))
            if Path(getattr(module, name)) != Path(config["calendarPath"]):
                raise RuntimeError("calendar path contract mismatch")
    for name in ("DOCUMENTS_DIR", "LIFEOS_DOCUMENTS_DIR"):
        if hasattr(module, name):
            setattr(module, name, Path(config["documentsPath"]))
            if Path(getattr(module, name)) != Path(config["documentsPath"]):
                raise RuntimeError("documents path contract mismatch")
    uvicorn = importlib.import_module("uvicorn")
    server = uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=8421, log_level="warning"))

    def stop_on_stdin_eof() -> None:
        try:
            sys.stdin.buffer.read()
        except Exception:
            pass
        server.should_exit = True

    threading.Thread(target=stop_on_stdin_eof, name="lifeos-stdin-stop", daemon=True).start()
    server.run()
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--config", required=True)
    parser.add_argument("--entry-point", required=True)
    parser.add_argument("--tailscale", required=True)
    args = parser.parse_args()
    try:
        return run(Path(args.config), Path(args.entry_point), Path(args.tailscale))
    except Exception:
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
