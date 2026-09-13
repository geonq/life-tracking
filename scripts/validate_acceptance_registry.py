#!/usr/bin/env python3
"""Validate and score the LifeOS acceptance registry.

The human-readable tables in ``docs/LIFEOS_ACCEPTANCE_REGISTRY.md`` remain useful
for review, but the JSON block in that file is the machine contract.  The
validator materialises the table rows and the explicitly atomised split rows
into one list of scored leaves.  It deliberately does not infer a pass from a
source file, a fixture, or a test runner that did not execute any tests.

Usage::

    python3 scripts/validate_acceptance_registry.py
    python3 scripts/validate_acceptance_registry.py --score  # FROZEN only
    python3 scripts/validate_acceptance_registry.py --json

The module has no third-party dependencies so it can run before the app's
dependency graph is installed.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
from collections import Counter, defaultdict
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable, Mapping, Sequence


REGISTRY_PATH = Path(__file__).resolve().parents[1] / "docs" / "LIFEOS_ACCEPTANCE_REGISTRY.md"

ALLOWED_STATUSES = frozenset({"missing", "foundation", "blocked-external", "accepted"})
ALLOWED_EVIDENCE_TYPES = frozenset(
    {
        "source",
        "unit",
        "integration",
        "ui-runtime",
        "device",
        "milestone-visual",
        "security-negative",
        "operator",
        "live-readonly",
        "performance",
        "release-signature",
    }
)
ALLOWED_SEVERITIES = frozenset({"P0", "P1"})
ALLOWED_CLAIM_KINDS = frozenset({"live", "interaction", "operator", "layout-only"})
ID_RE = re.compile(r"^[A-Z][A-Z0-9]{1,7}-[A-Z0-9]+(?:[.-][A-Z0-9]+)*$")
SHA_RE = re.compile(r"^[0-9a-fA-F]{7,64}$")
SHA256_RE = re.compile(r"^[0-9a-fA-F]{64}$")
TABLE_ID_RE = re.compile(r"^[A-Z]{2,8}-\d{1,5}$")
SOURCE_LOCATOR_RE = re.compile(r"^(?:design|repo|coord|https)://.+$")
EVIDENCE_LOCATOR_RE = re.compile(r"^repo://[^\s]+$")

# These are deliberately code-owned rather than read from the registry.  A
# registry author may describe a claim, but may not weaken the evidence needed
# to accept it by editing the data file.
CLAIM_KIND_EVIDENCE_MATRIX: dict[str, dict[str, tuple[frozenset[str], ...] | frozenset[str]]] = {
    "live": {
        "alternatives": (
            frozenset({"integration"}),
            frozenset({"device"}),
            frozenset({"live-readonly"}),
        ),
        "accepted_forbidden": frozenset(),
    },
    "interaction": {
        "alternatives": (
            frozenset({"integration"}),
            frozenset({"ui-runtime"}),
            frozenset({"device"}),
        ),
        "accepted_forbidden": frozenset(),
    },
    "operator": {
        "alternatives": (
            frozenset({"operator"}),
            frozenset({"device", "release-signature"}),
            frozenset({"device", "security-negative"}),
        ),
        "accepted_forbidden": frozenset(),
    },
    "layout-only": {
        "alternatives": (frozenset({"milestone-visual"}), frozenset({"ui-runtime"})),
        "accepted_forbidden": frozenset({"live-readonly"}),
    },
}

# Performance/layout interaction rows are allowed to opt into one of these
# narrow, validator-owned contracts.  They cannot broaden the default
# interaction contract by inventing arbitrary evidence combinations.
EVIDENCE_PROFILES: dict[str, tuple[str, frozenset[str]]] = {
    "interaction-performance": ("interaction", frozenset({"performance"})),
    "interaction-layout": ("interaction", frozenset({"milestone-visual"})),
}

# ``visual`` exists in the early human tables.  It is never accepted as a
# machine evidence type; it is normalised while importing those legacy cells.
LEGACY_EVIDENCE_TYPES = {"visual": "milestone-visual"}

CANCELED_MARKERS = (
    "cancelled",
    "canceled",
    "zero-test",
    "zero test",
    "0 tests",
    "no tests ran",
    "did not run",
)
FIXTURE_MARKERS = (
    "fixture-only",
    "fixture only",
    "fixtures/",
    "/fixtures/",
    "demo fixtures",
    "demo-only",
    "demo only",
)
ACCEPTED_RESULT_MARKERS = frozenset({"passed", "verified", "succeeded", "success", "accepted"})


class RegistryError(ValueError):
    """Raised for a malformed or non-scorable registry."""


@dataclass(frozen=True)
class ValidationReport:
    """Deterministic validation result suitable for CLI or tests."""

    rows: tuple[dict[str, Any], ...]
    aliases: tuple[dict[str, Any], ...]
    errors: tuple[str, ...]
    warnings: tuple[str, ...]
    state: str
    registry_hash: str
    validated_payload_sha256: str
    git_verified: bool
    registry_blob_verified: bool

    @property
    def leaf_count(self) -> int:
        return len(self.rows)

    @property
    def alias_count(self) -> int:
        return len(self.aliases)

    @property
    def accepted_count(self) -> int:
        return sum(row.get("status") == "accepted" for row in self.rows)

    def counts_by_workstream(self) -> dict[str, dict[str, int]]:
        result: dict[str, dict[str, int]] = defaultdict(lambda: {"accepted": 0, "leaves": 0})
        for row in self.rows:
            workstream = str(row.get("workstream", "<missing>"))
            result[workstream]["leaves"] += 1
            result[workstream]["accepted"] += row.get("status") == "accepted"
        return dict(result)


def _nonempty(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _split_table_row(line: str) -> list[str]:
    # Registry cells intentionally do not contain literal unescaped pipes.  A
    # small parser is preferable to depending on a Markdown package here.
    cells = line.strip().strip("|").split("|")
    return [cell.strip().replace("\\|", "|") for cell in cells]


def _normalise_evidence_types(value: Any, *, legacy: bool = False) -> list[str]:
    if isinstance(value, str):
        values = re.split(r"\s*\+\s*|,", value)
    elif isinstance(value, Sequence) and not isinstance(value, (bytes, bytearray)):
        values = list(value)
    else:
        return []
    result: list[str] = []
    for item in values:
        if not isinstance(item, str):
            result.append(str(item))
            continue
        token = item.strip()
        if legacy:
            token = LEGACY_EVIDENCE_TYPES.get(token, token)
        if token and token not in result:
            result.append(token)
    return result


def _parse_human_tables(markdown: str) -> list[dict[str, Any]]:
    """Read the original compact tables into base rows.

    This parser intentionally only accepts rows with an ID cell and the five
    binding columns.  It will not silently treat prose or an arbitrary table as
    acceptance data.
    """

    lines = markdown.splitlines()
    rows: list[dict[str, Any]] = []
    index = 0
    while index + 1 < len(lines):
        header = lines[index]
        if not (header.startswith("|") and "ID" in header and "Severity" in header):
            index += 1
            continue
        headers = [cell.lower() for cell in _split_table_row(header)]
        separator = lines[index + 1]
        if not separator.startswith("|") or not all("-" in cell for cell in _split_table_row(separator)):
            index += 1
            continue
        try:
            id_index = headers.index("id")
            # The widget catalog names its binding outcome ``Widget / aliases``
            # rather than repeating the longer column heading used elsewhere.
            outcome_index = (
                headers.index("binding outcome")
                if "binding outcome" in headers
                else headers.index("widget / aliases")
            )
            severity_index = headers.index("severity")
            status_index = headers.index("current")
            evidence_index = headers.index("required evidence")
        except ValueError:
            index += 1
            continue
        index += 2
        while index < len(lines) and lines[index].startswith("|"):
            cells = _split_table_row(lines[index])
            index += 1
            if len(cells) <= max(id_index, outcome_index, severity_index, status_index, evidence_index):
                continue
            row_id = cells[id_index]
            if not TABLE_ID_RE.fullmatch(row_id):
                continue
            rows.append(
                {
                    "id": row_id,
                    "acceptance": cells[outcome_index],
                    "severity": cells[severity_index],
                    "status": cells[status_index],
                    "evidence_types": _normalise_evidence_types(cells[evidence_index], legacy=True),
                    "_from_human_table": True,
                }
            )
    return rows


def _extract_machine_block(markdown: str) -> dict[str, Any]:
    start_marker = "<!-- acceptance-registry:data:start -->"
    end_marker = "<!-- acceptance-registry:data:end -->"
    start = markdown.find(start_marker)
    end = markdown.find(end_marker)
    if start < 0 or end < 0 or end <= start:
        raise RegistryError("missing acceptance-registry JSON block markers")
    body = markdown[start + len(start_marker) : end]
    match = re.search(r"```json\s*(.*?)\s*```", body, flags=re.DOTALL)
    if not match:
        raise RegistryError("acceptance-registry JSON block must be a fenced json object")
    try:
        data = json.loads(match.group(1))
    except json.JSONDecodeError as exc:
        raise RegistryError(f"invalid acceptance-registry JSON: {exc}") from exc
    if not isinstance(data, dict):
        raise RegistryError("acceptance-registry JSON root must be an object")
    return data


def _lookup_prefix(mapping: Mapping[str, Any], row_id: str) -> Any:
    prefix = row_id.split("-", 1)[0]
    return mapping.get(prefix)


def _source_for(row_id: str, metadata: Mapping[str, Any]) -> list[str]:
    explicit = metadata.get("source_by_id", {})
    if row_id in explicit:
        value = explicit[row_id]
        return list(value) if isinstance(value, list) else [str(value)]
    template = _lookup_prefix(metadata.get("source_templates", {}), row_id)
    if template is None:
        return []
    templates = template if isinstance(template, list) else [template]
    digits = row_id.split("-", 1)[1]
    return [str(item).replace("{id}", row_id).replace("{digits}", digits) for item in templates]


def _producing_sha_default(metadata: Mapping[str, Any]) -> str | None:
    """Return the audited implementation SHA used for provisional rows.

    The implementation baseline and the tracked commit containing the registry
    are intentionally separate. Before accepted evidence exists, provisional
    rows point at the audited implementation baseline. Each accepted row later
    records its own evidence-producing commit; normal CI does not overwrite it
    with the current HEAD.
    """

    value = metadata.get("implementation_baseline_commit")
    if value is None:
        # Backwards-compatible input for focused callers constructing a small
        # registry object by hand.
        value = metadata.get("current_commit")
    return str(value) if value is not None else None


def _default_for(row_id: str, metadata: Mapping[str, Any], key: str) -> Any:
    defaults = metadata.get("prefix_defaults", {})
    prefix = row_id.split("-", 1)[0]
    prefix_default = defaults.get(prefix, {})
    if isinstance(prefix_default, Mapping) and key in prefix_default:
        return copy.deepcopy(prefix_default[key])
    return None


def _row_from_base(base: Mapping[str, Any], metadata: Mapping[str, Any]) -> dict[str, Any]:
    row_id = str(base.get("id", ""))
    defaults = metadata.get("defaults", {})
    row: dict[str, Any] = {
        "id": row_id,
        "aliases": [],
        "workstream": _default_for(row_id, metadata, "workstream"),
        "owner": _default_for(row_id, metadata, "owner"),
        "severity": base.get("severity"),
        "source": _source_for(row_id, metadata),
        "acceptance": base.get("acceptance"),
        "evidence_types": list(base.get("evidence_types", [])),
        "evidence_path": None,
        "evidence_sha256": None,
        "evidence_result": None,
        "test_count": None,
        "claim_kind": _default_for(row_id, metadata, "claim_kind") or "live",
        "evidence_profile": None,
        "producing_sha": _producing_sha_default(metadata),
        "threshold": defaults.get(
            "threshold",
            "All required evidence types pass at the producing commit; no canceled, zero-test, or fixture-only result.",
        ),
        "blocker": _blocker_for_status(str(base.get("status", "")), metadata),
        "status": base.get("status"),
        "atomic_key": row_id,
    }
    overrides = metadata.get("row_overrides", {})
    if row_id in overrides:
        row.update(copy.deepcopy(overrides[row_id]))
    return row


def _blocker_for_status(status: str, metadata: Mapping[str, Any]) -> str:
    mapping = metadata.get("blocker_by_status", {})
    if isinstance(mapping, Mapping) and status in mapping:
        return str(mapping[status])
    return {
        "foundation": "acceptance evidence incomplete",
        "missing": "implementation incomplete",
        "blocked-external": "external input or signed-device/operator gate",
        "accepted": "none",
    }.get(status, "status is invalid")


def _extra_rows(metadata: Mapping[str, Any]) -> list[dict[str, Any]]:
    """Expand compact, explicit split definitions into full rows."""

    output: list[dict[str, Any]] = []
    split_groups = metadata.get("split_groups", {})
    if not isinstance(split_groups, Mapping):
        return output
    for source_id, children in split_groups.items():
        if not isinstance(children, Sequence) or isinstance(children, (str, bytes, bytearray)):
            continue
        parent_status = None
        for child in children:
            if not isinstance(child, Mapping):
                continue
            child_id = str(child.get("id", ""))
            row = {
                "id": child_id,
                "aliases": list(child.get("aliases", [])),
                "workstream": child.get("workstream") or _default_for(child_id, metadata, "workstream"),
                "owner": child.get("owner") or _default_for(child_id, metadata, "owner"),
                "severity": child.get("severity", "P0"),
                "source": list(child.get("source", _source_for(source_id, metadata))),
                "acceptance": child.get("acceptance"),
                "evidence_types": _normalise_evidence_types(child.get("evidence_types", [])),
                "evidence_path": child.get("evidence_path"),
                "evidence_sha256": child.get("evidence_sha256"),
                "evidence_result": child.get("evidence_result"),
                "test_count": child.get("test_count"),
                "claim_kind": child.get(
                    "claim_kind",
                    _default_for(child_id, metadata, "claim_kind") or "live",
                ),
                "evidence_profile": child.get("evidence_profile"),
                "producing_sha": child.get("producing_sha", _producing_sha_default(metadata)),
                "threshold": child.get(
                    "threshold",
                    metadata.get("defaults", {}).get(
                        "threshold",
                        "All required evidence types pass at the producing commit; no canceled, zero-test, or fixture-only result.",
                    ),
                ),
                "blocker": child.get("blocker"),
                "status": child.get("status"),
                "atomic_key": child.get("atomic_key", child_id),
                "split_from": source_id,
            }
            if row["status"] is None:
                # Parent status is filled after the human table is known.
                row["status"] = "foundation"
            if row["blocker"] is None:
                row["blocker"] = _blocker_for_status(str(row["status"]), metadata)
            output.append(row)
    return output


def materialise_registry(data: Mapping[str, Any], markdown: str | None = None) -> dict[str, Any]:
    """Return a copy with a single explicit ``rows`` array.

    A future frozen registry may store ``rows`` directly.  The current T0 file
    stores the compact human tables plus split definitions so that reviewers do
    not have to maintain two 200-row representations by hand.
    """

    result = copy.deepcopy(dict(data))
    if isinstance(result.get("rows"), list):
        result["rows"] = [dict(row) for row in result["rows"] if isinstance(row, Mapping)]
        return result
    if markdown is None:
        raise RegistryError("registry has no rows and no Markdown source was supplied")
    base_rows = _parse_human_tables(markdown)
    metadata = result
    split_groups = metadata.get("split_groups", {})
    split_sources = set(split_groups) if isinstance(split_groups, Mapping) else set()
    rows = [_row_from_base(row, metadata) for row in base_rows if row["id"] not in split_sources]
    status_by_id = {row["id"]: row["status"] for row in base_rows}
    for row in _extra_rows(metadata):
        parent_status = status_by_id.get(row.get("split_from"))
        if parent_status is not None and row.get("status") == "foundation":
            row["status"] = parent_status
            row["blocker"] = _blocker_for_status(parent_status, metadata)
        rows.append(row)
    result["rows"] = rows
    result["source_table_row_ids"] = [row["id"] for row in base_rows]
    result["split_source_ids"] = sorted(split_sources)
    return result


def _canonical_hash_payload(data: Mapping[str, Any]) -> bytes:
    """Hash the frozen definition without mutable completion evidence.

    Status and evidence must change as work is accepted. Including them would
    make the supposedly frozen denominator change on every legitimate pass.
    """

    stable_row_keys = (
        "id", "aliases", "workstream", "owner", "severity", "source",
        "acceptance", "evidence_types", "claim_kind", "evidence_profile",
        "threshold", "atomic_key", "split_from", "platform",
    )
    raw_rows = data.get("rows", [])
    payload = {
        "schema_version": data.get("schema_version"),
        "rows": [
            {key: copy.deepcopy(row.get(key)) for key in stable_row_keys if key in row}
            for row in raw_rows
            if isinstance(row, Mapping)
        ],
        "aliases": copy.deepcopy(data.get("aliases", [])),
        "non_overlap_groups": copy.deepcopy(data.get("non_overlap_groups", [])),
        "claim_kinds": copy.deepcopy(data.get("claim_kinds")),
        "claim_kind_evidence_matrix": copy.deepcopy(data.get("claim_kind_evidence_matrix")),
        "evidence_profiles": copy.deepcopy(data.get("evidence_profiles")),
    }
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")


def registry_hash(data: Mapping[str, Any]) -> str:
    return hashlib.sha256(_canonical_hash_payload(data)).hexdigest()


def _validated_payload_sha256(data: Mapping[str, Any]) -> str:
    """Bind a validation report to the complete materialised registry state."""

    payload = json.dumps(data, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def _evidence_path_value(row: Mapping[str, Any]) -> Any:
    if "evidence_path" in row:
        return row.get("evidence_path")
    evidence = row.get("evidence")
    return evidence.get("path") if isinstance(evidence, Mapping) else None


def _evidence_result_value(row: Mapping[str, Any]) -> Any:
    if "evidence_result" in row:
        return row.get("evidence_result")
    evidence = row.get("evidence")
    if isinstance(evidence, Mapping):
        return evidence.get("result", evidence.get("status"))
    return None


def _test_count_value(row: Mapping[str, Any]) -> Any:
    if "test_count" in row:
        return row.get("test_count")
    evidence = row.get("evidence")
    return evidence.get("test_count") if isinstance(evidence, Mapping) else None


def _evidence_types_value(row: Mapping[str, Any]) -> list[str]:
    if "evidence_types" in row:
        return _normalise_evidence_types(row.get("evidence_types"))
    if "evidence_type" in row:
        return _normalise_evidence_types(row.get("evidence_type"))
    evidence = row.get("evidence")
    if isinstance(evidence, Mapping):
        return _normalise_evidence_types(evidence.get("types", evidence.get("type")))
    return []


def _has_marker(value: Any, markers: Iterable[str]) -> bool:
    marker_values = tuple(markers)
    if isinstance(value, str):
        lowered = value.lower()
        return any(marker in lowered for marker in marker_values)
    if isinstance(value, Mapping):
        return any(_has_marker(key, marker_values) or _has_marker(item, marker_values) for key, item in value.items())
    if isinstance(value, Sequence) and not isinstance(value, (bytes, bytearray)):
        return any(_has_marker(item, marker_values) for item in value)
    return False


def _git_repository_available(repo_root: Path | None) -> bool:
    """Return whether ``repo_root`` is an actual usable Git worktree.

    Checking only for a ``.git`` directory is gameable (and does not support
    linked worktrees, where ``.git`` is a file).  Frozen validation depends on
    Git object identity, so probe Git itself before accepting any immutable
    claim.
    """

    if repo_root is None:
        return False
    try:
        subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--git-dir"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return True


def _resolve_commit_reference(value: Any, repo_root: Path | None) -> str | None:
    """Resolve a CLI commit SHA or symbolic ref without shell interpolation."""

    if not _nonempty(value):
        return None
    reference = str(value).strip()
    if SHA_RE.fullmatch(reference) and not _git_repository_available(repo_root):
        return reference.lower()
    if not _git_repository_available(repo_root):
        return None
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--verify", f"{reference}^{{commit}}"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return None
    resolved = result.stdout.strip()
    return resolved.lower() if SHA_RE.fullmatch(resolved) else None


def _git_commit_exists(sha: Any, repo_root: Path | None) -> bool | None:
    """Return commit existence, or ``None`` when no repository is available."""

    if not _git_repository_available(repo_root):
        return None
    if not isinstance(sha, str) or not SHA_RE.fullmatch(sha):
        return False
    try:
        subprocess.run(
            ["git", "-C", str(repo_root), "cat-file", "-e", f"{sha}^{{commit}}"],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return True


def _safe_repo_relative_path(locator: Any, repo_root: Path | None) -> Path | None:
    """Return a lexical repository-relative path with no symlink component."""

    if not isinstance(locator, str) or not locator.startswith("repo://") or repo_root is None:
        return None
    raw = locator.removeprefix("repo://")
    if not raw or "?" in raw or "#" in raw:
        return None
    relative = Path(raw)
    if relative.is_absolute() or any(part in {"", ".", ".."} for part in relative.parts):
        return None
    cursor = repo_root.resolve()
    for part in relative.parts:
        cursor = cursor / part
        if cursor.is_symlink():
            return None
    return relative


def _safe_repo_path(locator: Any, repo_root: Path | None) -> Path | None:
    """Resolve a repo:// locator without permitting path escape.

    ``repo://`` is a repository-relative locator, not a disguised filesystem
    path.  Reject absolute paths, traversal, query/fragment suffixes, and
    symlink escapes before touching the filesystem.
    """

    relative = _safe_repo_relative_path(locator, repo_root)
    if relative is None or repo_root is None:
        return None
    return repo_root.resolve() / relative


def _git_path_is_tracked(path: Path, repo_root: Path | None) -> bool | None:
    """Return whether a path is tracked, or ``None`` without a usable repo."""

    if not _git_repository_available(repo_root):
        return None
    assert repo_root is not None
    root = repo_root.resolve()
    try:
        relative = path.absolute().relative_to(root)
    except ValueError:
        return False
    if _safe_repo_relative_path("repo://" + relative.as_posix(), root) is None:
        return False
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "--error-unmatch", "--", relative.as_posix()],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError):
        return False
    return bool(result.stdout.strip())


def _path_exists(path_value: Any, repo_root: Path | None) -> bool:
    if not isinstance(path_value, str) or not path_value.strip():
        return False
    stable_path = path_value.strip()
    if stable_path.startswith("repo://"):
        path = _safe_repo_path(stable_path, repo_root)
        return path is not None and path.exists()
    path = Path(stable_path)
    if not path.is_absolute() and repo_root is not None:
        path = repo_root / path
    return path.exists()


def _evidence_digest_value(row: Mapping[str, Any]) -> Any:
    if "evidence_sha256" in row:
        return row.get("evidence_sha256")
    evidence = row.get("evidence")
    if isinstance(evidence, Mapping):
        return evidence.get("sha256", evidence.get("digest"))
    return None


def _sha256_path(path: Path) -> str | None:
    """Hash one path deterministically; accepted evidence requires a file.

    The directory branch remains useful to non-acceptance callers, but accepted
    evidence is deliberately restricted to one tracked regular manifest/archive
    so Git can bind the exact bytes at the producing commit.
    """

    if path.is_symlink() or not path.exists():
        return None
    digest = hashlib.sha256()
    if path.is_file():
        try:
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        except OSError:
            return None
        return digest.hexdigest()
    if not path.is_dir():
        return None
    try:
        all_entries = sorted(path.rglob("*"))
        if any(item.is_symlink() for item in all_entries):
            return None
        entries = [item for item in all_entries if not item.is_dir()]
        for item in entries:
            if not item.is_file():
                return None
            relative = item.relative_to(path).as_posix().encode("utf-8")
            digest.update(relative)
            digest.update(b"\0")
            with item.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
            digest.update(b"\0")
    except OSError:
        return None
    return digest.hexdigest()


def _validate_evidence_locator(
    row_id: str,
    evidence_path: Any,
    evidence_sha256: Any,
    *,
    repo_root: Path | None,
    producing_sha: Any,
    errors: list[str],
) -> None:
    """Validate the immutable artifact contract for an accepted row."""

    if not isinstance(evidence_path, str) or not EVIDENCE_LOCATOR_RE.fullmatch(evidence_path.strip()):
        errors.append(
            f"{row_id}: accepted evidence path must be a tracked repo:// artifact"
        )
        return
    if not isinstance(evidence_sha256, str) or not SHA256_RE.fullmatch(evidence_sha256.strip()):
        errors.append(f"{row_id}: accepted evidence requires a 64-character evidence_sha256")
        return
    expected_digest = evidence_sha256.strip().lower()
    locator = evidence_path.strip()
    if locator.startswith("repo://"):
        path = _safe_repo_path(locator, repo_root)
        if path is None:
            if repo_root is None:
                errors.append(f"{row_id}: accepted repo:// evidence cannot be resolved without a repository")
            else:
                errors.append(f"{row_id}: accepted repo:// evidence path is unsafe: {locator}")
            return
        if not path.exists():
            errors.append(f"{row_id}: accepted evidence path does not exist: {locator}")
            return
        if path.is_symlink() or not path.is_file():
            errors.append(f"{row_id}: accepted evidence must be one tracked regular file: {locator}")
            return
        tracked = _git_path_is_tracked(path, repo_root)
        if tracked is not True:
            errors.append(f"{row_id}: accepted repo:// evidence is not a tracked artifact: {locator}")
            return
        actual_digest = _sha256_path(path)
        if actual_digest is None:
            errors.append(f"{row_id}: accepted evidence artifact is not hashable: {locator}")
        elif actual_digest != expected_digest:
            errors.append(f"{row_id}: accepted evidence_sha256 does not match artifact: {locator}")
        committed_digest = _git_blob_sha256_at_commit(locator, producing_sha, repo_root)
        if committed_digest is None:
            errors.append(f"{row_id}: accepted evidence does not exist at producing commit: {locator}")
        elif committed_digest != expected_digest:
            errors.append(f"{row_id}: accepted evidence_sha256 does not match producing commit: {locator}")
        return
    # EVIDENCE_LOCATOR_RE intentionally makes this branch unreachable. Keep a
    # defensive failure here so a future locator-regex change cannot re-enable
    # self-attested remote evidence accidentally.
    errors.append(f"{row_id}: remote evidence is not accepted; use a tracked repo:// artifact")


def _validate_repo_source_locator(
    row_id: str,
    locator: Any,
    *,
    repo_root: Path | None,
    errors: list[str],
    label: str = "source",
) -> None:
    """Resolve repository sources and require tracked immutable files."""

    if not isinstance(locator, str) or not locator.startswith("repo://") or repo_root is None:
        return
    path = _safe_repo_path(locator, repo_root)
    if path is None:
        errors.append(f"{row_id}: {label} repo:// locator is unsafe: {locator}")
        return
    if not path.exists():
        errors.append(f"{row_id}: {label} repo:// path does not exist: {locator}")
    elif not path.is_file():
        errors.append(f"{row_id}: {label} repo:// path must be one regular file: {locator}")
    elif _git_path_is_tracked(path, repo_root) is not True:
        errors.append(f"{row_id}: {label} repo:// path is not tracked: {locator}")


def _git_path_exists_at_commit(locator: Any, commit: Any, repo_root: Path | None) -> bool | None:
    """Resolve a repository locator against the row's immutable evidence commit."""

    relative = _safe_repo_relative_path(locator, repo_root)
    if relative is None or repo_root is None:
        return False if repo_root is not None else None
    resolved_commit = _resolve_commit_reference(commit, repo_root)
    if resolved_commit is None:
        return False
    try:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "ls-tree", resolved_commit, "--", relative.as_posix()],
            check=True,
            capture_output=True,
            text=True,
        )
    except (OSError, subprocess.CalledProcessError, ValueError):
        return False
    fields = result.stdout.strip().split(None, 3)
    return len(fields) == 4 and fields[0] in {"100644", "100755"} and fields[1] == "blob"


def _git_blob_sha256_at_commit(locator: Any, commit: Any, repo_root: Path | None) -> str | None:
    """Hash a regular evidence file exactly as stored at its evidence commit."""

    relative = _safe_repo_relative_path(locator, repo_root)
    resolved_commit = _resolve_commit_reference(commit, repo_root)
    if relative is None or repo_root is None or resolved_commit is None:
        return None
    try:
        object_entry = subprocess.run(
            ["git", "-C", str(repo_root), "ls-tree", resolved_commit, "--", relative.as_posix()],
            check=True,
            capture_output=True,
            text=True,
        )
        fields = object_entry.stdout.strip().split(None, 3)
        if len(fields) != 4 or fields[0] not in {"100644", "100755"} or fields[1] != "blob":
            return None
        result = subprocess.run(
            ["git", "-C", str(repo_root), "show", f"{resolved_commit}:{relative.as_posix()}"],
            check=True,
            capture_output=True,
        )
    except (OSError, subprocess.CalledProcessError, ValueError):
        return None
    blob = result.stdout.encode("utf-8") if isinstance(result.stdout, str) else result.stdout
    return hashlib.sha256(blob).hexdigest()


def _git_registry_blob_matches_head(path: Path, repo_root: Path | None) -> bool:
    """Return whether the scored registry is the exact tracked HEAD blob."""

    if not _git_repository_available(repo_root) or repo_root is None:
        return False
    try:
        relative = path.resolve().relative_to(repo_root.resolve()).as_posix()
        subprocess.run(
            ["git", "-C", str(repo_root), "ls-files", "--error-unmatch", "--", relative],
            check=True,
            capture_output=True,
        )
        committed = subprocess.run(
            ["git", "-C", str(repo_root), "show", f"HEAD:{relative}"],
            check=True,
            capture_output=True,
        )
        return path.read_bytes() == committed.stdout
    except (OSError, subprocess.CalledProcessError, ValueError):
        return False


def _claim_alternatives(row: Mapping[str, Any], errors: list[str]) -> tuple[frozenset[str], ...]:
    """Return the bounded evidence alternatives for one claim kind."""

    claim_kind = row.get("claim_kind")
    matrix_entry = CLAIM_KIND_EVIDENCE_MATRIX.get(str(claim_kind))
    if matrix_entry is None:
        return ()
    alternatives = tuple(matrix_entry["alternatives"])  # type: ignore[index]
    profile = row.get("evidence_profile")
    if profile is None:
        return alternatives
    profile_contract = EVIDENCE_PROFILES.get(str(profile))
    if profile_contract is None:
        errors.append(f"{row.get('id', '<missing>')}: unknown evidence profile {profile!r}")
        return alternatives
    profile_claim_kind, profile_evidence = profile_contract
    if claim_kind != profile_claim_kind:
        errors.append(
            f"{row.get('id', '<missing>')}: evidence profile {profile!r} is not valid for claim kind {claim_kind!r}"
        )
        return alternatives
    return alternatives + (profile_evidence,)


def _expected_matrix_contract() -> dict[str, Any]:
    return {
        claim_kind: {
            "alternatives": [sorted(alternative) for alternative in entry["alternatives"]],  # type: ignore[index]
            "accepted_forbidden": sorted(entry["accepted_forbidden"]),  # type: ignore[index]
        }
        for claim_kind, entry in CLAIM_KIND_EVIDENCE_MATRIX.items()
    }


def _expected_evidence_profiles() -> dict[str, Any]:
    return {
        profile: {"claim_kind": claim_kind, "required_all": sorted(evidence)}
        for profile, (claim_kind, evidence) in EVIDENCE_PROFILES.items()
    }


def _validate_freeze_manifest(data: Mapping[str, Any], rows: Sequence[Mapping[str, Any]], aliases: Sequence[Mapping[str, Any]], errors: list[str]) -> None:
    if str(data.get("state", "")).upper() != "FROZEN":
        return
    manifest = data.get("freeze_manifest")
    if not isinstance(manifest, Mapping):
        errors.append("FROZEN registry requires freeze_manifest")
        return
    current_ids = sorted(str(row.get("id")) for row in rows)
    frozen_ids = sorted(str(item) for item in manifest.get("leaf_ids", [])) if isinstance(manifest.get("leaf_ids"), list) else []
    if current_ids != frozen_ids:
        errors.append("mutable split/merge: frozen leaf_ids do not match current scored leaves")
    current_aliases = {
        str(alias.get("alias")): str(alias.get("leaf_id", alias.get("alias_of", "")))
        for alias in aliases
        if isinstance(alias, Mapping)
    }
    frozen_aliases = manifest.get("aliases", {})
    if not isinstance(frozen_aliases, Mapping) or dict(frozen_aliases) != current_aliases:
        errors.append("mutable split/merge: frozen alias map does not match current aliases")
    current_splits: dict[str, list[str]] = defaultdict(list)
    for row in rows:
        if row.get("split_from"):
            current_splits[str(row["split_from"])].append(str(row.get("id")))
    normalised_splits = {key: sorted(value) for key, value in current_splits.items()}
    frozen_splits = manifest.get("split_map", {})
    if not isinstance(frozen_splits, Mapping) or dict(frozen_splits) != normalised_splits:
        errors.append("mutable split/merge: frozen split_map does not match current split groups")
    current_atomic_keys = {str(row.get("id")): str(row.get("atomic_key", "")) for row in rows}
    frozen_atomic_keys = manifest.get("atomic_keys", {})
    if not isinstance(frozen_atomic_keys, Mapping) or dict(frozen_atomic_keys) != current_atomic_keys:
        errors.append("mutable split/merge: frozen atomic_keys do not match current leaves")
    current_non_overlap = data.get("non_overlap_groups", [])
    if not isinstance(current_non_overlap, list):
        current_non_overlap = []
    if manifest.get("non_overlap_groups") != current_non_overlap:
        errors.append("mutable split/merge: frozen non_overlap_groups do not match current mapping")
    current_workstreams = {
        key: value["leaves"] for key, value in _workstream_counts(rows).items()
    }
    frozen_workstreams = manifest.get("workstream_leaf_counts", {})
    if not isinstance(frozen_workstreams, Mapping) or dict(frozen_workstreams) != current_workstreams:
        errors.append("mutable split/merge: frozen workstream_leaf_counts do not match current leaves")
    current_workstream_map = {
        str(row.get("id")): str(row.get("workstream", "")) for row in rows
    }
    frozen_workstream_map = manifest.get("workstream_map", {})
    if not isinstance(frozen_workstream_map, Mapping) or dict(frozen_workstream_map) != current_workstream_map:
        errors.append("mutable split/merge: frozen workstream_map does not match current leaves")


def _workstream_counts(rows: Sequence[Mapping[str, Any]]) -> dict[str, dict[str, int]]:
    result: dict[str, dict[str, int]] = defaultdict(lambda: {"accepted": 0, "leaves": 0})
    for row in rows:
        workstream = str(row.get("workstream", "<missing>"))
        result[workstream]["leaves"] += 1
        result[workstream]["accepted"] += row.get("status") == "accepted"
    return dict(result)


def validate_registry(
    data: Mapping[str, Any],
    *,
    repo_root: Path | None = None,
    check_evidence_paths: bool = False,
    expected_commit: str | None = None,
    registry_path: Path | None = None,
) -> ValidationReport:
    """Validate a materialised registry without permitting score gaming."""

    materialised = dict(data)
    rows_raw = materialised.get("rows")
    aliases_raw = materialised.get("aliases", [])
    errors: list[str] = []
    warnings: list[str] = []
    resolved_expected_commit: str | None = None
    if expected_commit is not None:
        resolved_expected_commit = _resolve_commit_reference(expected_commit, repo_root)
        if resolved_expected_commit is None:
            errors.append(f"expected commit does not resolve to a commit: {expected_commit!r}")
    commit_existence_cache: dict[str, bool | None] = {}
    if resolved_expected_commit is not None and repo_root is not None:
        expected_key = resolved_expected_commit.lower()
        commit_existence_cache[expected_key] = _git_commit_exists(expected_key, repo_root)
        if commit_existence_cache[expected_key] is False:
            errors.append(f"expected commit does not resolve to a commit: {expected_commit!r}")
    if not isinstance(rows_raw, list):
        errors.append("registry rows must be a list")
        rows_raw = []
    if not isinstance(aliases_raw, list):
        errors.append("registry aliases must be a list")
        aliases_raw = []

    rows = tuple(row for row in rows_raw if isinstance(row, Mapping))
    aliases = tuple(alias for alias in aliases_raw if isinstance(alias, Mapping))
    if len(rows) != len(rows_raw):
        errors.append("registry rows must contain only objects")
    if len(aliases) != len(aliases_raw):
        errors.append("registry aliases must contain only objects")

    declared_claim_kinds = materialised.get("claim_kinds")
    if declared_claim_kinds is not None:
        if not isinstance(declared_claim_kinds, Mapping):
            errors.append("claim_kinds must be an object")
        elif set(declared_claim_kinds) != set(ALLOWED_CLAIM_KINDS):
            errors.append("claim_kinds must declare exactly the allowed claim-kind enum")
    declared_matrix = materialised.get("claim_kind_evidence_matrix")
    if declared_matrix is not None:
        expected_matrix = _expected_matrix_contract()
        if declared_matrix != expected_matrix:
            errors.append("claim_kind_evidence_matrix must match the validator-owned compatibility matrix")
    declared_profiles = materialised.get("evidence_profiles")
    if declared_profiles is not None and declared_profiles != _expected_evidence_profiles():
        errors.append("evidence_profiles must match the validator-owned profile enum")

    row_ids = [str(row.get("id", "")) for row in rows]
    duplicate_ids = sorted(key for key, count in Counter(row_ids).items() if count > 1 or not key)
    for duplicate in duplicate_ids:
        errors.append(f"duplicate or empty leaf ID: {duplicate!r}")
    for row in rows:
        row_id = str(row.get("id", ""))
        if not ID_RE.fullmatch(row_id):
            errors.append(f"invalid stable leaf ID: {row_id!r}")
        if not _nonempty(row.get("workstream")):
            errors.append(f"{row_id}: missing workstream")
        if not _nonempty(row.get("owner")):
            errors.append(f"{row_id}: missing owner")
        if row.get("severity") not in ALLOWED_SEVERITIES:
            errors.append(f"{row_id}: unknown severity {row.get('severity')!r}")
        source = row.get("source")
        if not isinstance(source, list) or not source or not all(_nonempty(item) for item in source):
            errors.append(f"{row_id}: source must contain one or more exact paths")
        else:
            for source_locator in source:
                if not SOURCE_LOCATOR_RE.fullmatch(str(source_locator)):
                    errors.append(
                        f"{row_id}: source must use a stable design://, repo://, coord://, or https:// locator: {source_locator!r}"
                    )
                _validate_repo_source_locator(
                    row_id,
                    source_locator,
                    repo_root=repo_root,
                    errors=errors,
                )
        if not _nonempty(row.get("acceptance")):
            errors.append(f"{row_id}: missing exact acceptance statement")
        types = _evidence_types_value(row)
        if not types:
            errors.append(f"{row_id}: missing evidence type")
        for evidence_type in types:
            if evidence_type not in ALLOWED_EVIDENCE_TYPES:
                errors.append(f"{row_id}: unknown evidence type {evidence_type!r}")
        claim_kind = row.get("claim_kind")
        status = row.get("status")
        if claim_kind not in ALLOWED_CLAIM_KINDS:
            errors.append(f"{row_id}: unknown claim kind {claim_kind!r}")
        elif claim_kind == "layout-only" and "live-readonly" in types:
            errors.append(f"{row_id}: layout-only claim cannot use live-readonly evidence")
        alternatives = _claim_alternatives(row, errors)
        state = str(materialised.get("state", "")).upper()
        enforce_claim_contract = status == "accepted" or state == "FROZEN"
        if enforce_claim_contract and claim_kind in ALLOWED_CLAIM_KINDS and alternatives:
            if not any(alternative.issubset(set(types)) for alternative in alternatives):
                rendered = " OR ".join("+".join(sorted(alternative)) for alternative in alternatives)
                errors.append(
                    f"{row_id}: {claim_kind} claim requires one compatible evidence contract: {rendered}"
                )
            matrix_entry = CLAIM_KIND_EVIDENCE_MATRIX.get(str(claim_kind))
            if matrix_entry is not None:
                forbidden = sorted(matrix_entry["accepted_forbidden"] & set(types))  # type: ignore[operator,index]
                if forbidden:
                    errors.append(
                        f"{row_id}: {claim_kind} claim cannot use evidence type(s): "
                        + ", ".join(forbidden)
                    )
        if not _nonempty(row.get("threshold")):
            errors.append(f"{row_id}: missing threshold")
        elif str(materialised.get("state", "")).upper() == "FROZEN" and "UNRESOLVED" in str(row.get("threshold")):
            errors.append(f"{row_id}: unresolved threshold cannot be frozen")
        if "blocker" not in row or not _nonempty(row.get("blocker")):
            errors.append(f"{row_id}: missing blocker")
        atomic_key = row.get("atomic_key")
        if not _nonempty(atomic_key):
            errors.append(f"{row_id}: missing atomic_key")
        if status not in ALLOWED_STATUSES:
            errors.append(f"{row_id}: unknown status {status!r}")
        producing_sha = row.get("producing_sha")
        if producing_sha is not None and not SHA_RE.fullmatch(str(producing_sha)):
            errors.append(f"{row_id}: invalid producing SHA {producing_sha!r}")
        if producing_sha is None:
            errors.append(f"{row_id}: missing producing SHA")
        elif SHA_RE.fullmatch(str(producing_sha)) and repo_root is not None:
            producing_key = str(producing_sha).lower()
            if producing_key not in commit_existence_cache:
                commit_existence_cache[producing_key] = _git_commit_exists(producing_key, repo_root)
            if commit_existence_cache[producing_key] is False:
                errors.append(f"{row_id}: producing SHA does not resolve to a commit: {producing_sha}")

        evidence_path = _evidence_path_value(row)
        evidence_result = _evidence_result_value(row)
        test_count = _test_count_value(row)
        evidence_sha256 = _evidence_digest_value(row)
        if evidence_sha256 is not None and (
            not isinstance(evidence_sha256, str) or not SHA256_RE.fullmatch(evidence_sha256.strip())
        ):
            errors.append(f"{row_id}: evidence_sha256 must be a 64-character hexadecimal digest")
        if _has_marker(evidence_result, CANCELED_MARKERS):
            errors.append(f"{row_id}: canceled/zero-test evidence cannot be recorded as acceptance evidence")
        if isinstance(test_count, (int, float)) and test_count < 0:
            errors.append(f"{row_id}: test_count cannot be negative")
        if isinstance(test_count, (int, float)) and test_count == 0:
            errors.append(f"{row_id}: zero-test evidence cannot be recorded")
        fixture_evidence = _has_marker(evidence_result, FIXTURE_MARKERS) or _has_marker(
            str(evidence_path), FIXTURE_MARKERS
        )
        if fixture_evidence and claim_kind != "layout-only":
            errors.append(f"{row_id}: fixture/demo evidence requires claim_kind layout-only")
        if status == "accepted":
            if state != "FROZEN":
                errors.append(f"{row_id}: accepted rows require a FROZEN registry")
            normalised_result = str(evidence_result).strip().lower() if evidence_result is not None else ""
            if normalised_result not in ACCEPTED_RESULT_MARKERS:
                errors.append(
                    f"{row_id}: accepted row requires an explicit passed/verified evidence result"
                )
            if not isinstance(test_count, int) or isinstance(test_count, bool) or test_count < 1:
                errors.append(f"{row_id}: accepted row requires a positive integer test_count")
            if not _nonempty(evidence_path):
                errors.append(f"{row_id}: accepted row has no evidence path")
            else:
                # This check is intentionally unconditional.  The historical
                # --check-evidence-paths flag remains accepted for callers but
                # can no longer disable immutable-artifact validation.
                _validate_evidence_locator(
                    row_id,
                    evidence_path,
                    evidence_sha256,
                    repo_root=repo_root,
                    producing_sha=producing_sha,
                    errors=errors,
                )
            producing_identity = _resolve_commit_reference(producing_sha, repo_root)
            if producing_identity is None:
                errors.append(f"{row_id}: accepted row producing_sha does not resolve to a commit")
            elif resolved_expected_commit is not None and producing_identity != resolved_expected_commit:
                errors.append(f"{row_id}: accepted row evidence is not at the explicit expected commit")
            for source_locator in row.get("source", []):
                if isinstance(source_locator, str) and source_locator.startswith("repo://"):
                    source_at_commit = _git_path_exists_at_commit(source_locator, producing_identity, repo_root)
                    if source_at_commit is not True:
                        errors.append(
                            f"{row_id}: repo:// source does not exist at accepted producing commit: {source_locator}"
                        )
            if _has_marker(evidence_result, ("failed", "failure", "error")):
                errors.append(f"{row_id}: failed evidence cannot be accepted")
            if row.get("blocker") not in ("none", ""):
                warnings.append(f"{row_id}: accepted row retains blocker {row.get('blocker')!r}")

    alias_names: list[str] = []
    alias_map: dict[str, str] = {}
    for alias in aliases:
        name = str(alias.get("alias", ""))
        target = str(alias.get("leaf_id", alias.get("alias_of", "")))
        if not _nonempty(name) or not _nonempty(target):
            errors.append("alias entries require non-empty alias and leaf_id")
            continue
        if name in alias_map:
            errors.append(f"duplicate alias: {name}")
        alias_names.append(name)
        alias_map[name] = target
        if target not in row_ids:
            errors.append(f"alias {name} points to unknown leaf {target}")
        if name in row_ids:
            errors.append(f"alias {name} is also a scored leaf; aliases cannot increase denominator")
        if name == target:
            errors.append(f"alias {name} cannot point to itself")
        alias_source = alias.get("source")
        if not _nonempty(alias_source):
            errors.append(f"alias {name} is missing its exact source path")
        elif not SOURCE_LOCATOR_RE.fullmatch(str(alias_source)):
            errors.append(f"alias {name} source must use a stable source locator")
        else:
            _validate_repo_source_locator(
                name,
                alias_source,
                repo_root=repo_root,
                errors=errors,
                label="alias source",
            )

    # A second alias cannot target an alias: this would make provenance and
    # denominator accounting ambiguous.
    for name, target in alias_map.items():
        if target in alias_map:
            errors.append(f"alias {name} targets alias {target}; aliases must target scored leaves")

    atomic_keys = [str(row.get("atomic_key", "")) for row in rows]
    duplicate_atomic_keys = sorted(
        key for key, count in Counter(atomic_keys).items() if key and count > 1
    )
    for atomic_key in duplicate_atomic_keys:
        errors.append(f"duplicate atomic/non-overlap key: {atomic_key}")

    non_overlap_groups = materialised.get("non_overlap_groups", [])
    if not isinstance(non_overlap_groups, list):
        errors.append("non_overlap_groups must be a list")
    else:
        seen_group_ids: set[str] = set()
        seen_group_members: dict[str, str] = {}
        known_ids = set(row_ids)
        for group in non_overlap_groups:
            if not isinstance(group, Mapping):
                errors.append("non_overlap_groups must contain objects")
                continue
            group_id = str(group.get("id", ""))
            members = group.get("leaves")
            boundary = group.get("boundary")
            if not _nonempty(group_id) or group_id in seen_group_ids:
                errors.append(f"duplicate or empty non-overlap group ID: {group_id!r}")
            seen_group_ids.add(group_id)
            if not isinstance(members, list) or len(members) < 2 or len(set(members)) != len(members):
                errors.append(f"non-overlap group {group_id}: leaves must contain two or more unique IDs")
            elif any(member not in known_ids for member in members):
                errors.append(f"non-overlap group {group_id}: unknown scored leaf")
            else:
                for member in members:
                    previous_group = seen_group_members.get(str(member))
                    if previous_group is not None:
                        errors.append(
                            f"non-overlap leaf {member} appears in groups {previous_group} and {group_id}"
                        )
                    seen_group_members[str(member)] = group_id
            if not _nonempty(boundary):
                errors.append(f"non-overlap group {group_id}: missing ownership boundary")

    declared_workstreams = materialised.get("workstream_leaf_counts")
    if declared_workstreams is not None:
        actual_workstreams = {key: value["leaves"] for key, value in _workstream_counts(rows).items()}
        if not isinstance(declared_workstreams, Mapping) or dict(declared_workstreams) != actual_workstreams:
            errors.append("workstream_leaf_counts do not match materialised scored leaves")

    _validate_freeze_manifest(materialised, rows, aliases, errors)
    actual_hash = registry_hash({**materialised, "rows": list(rows), "aliases": list(aliases)})
    state = str(materialised.get("state", ""))
    if state not in {"UNFROZEN", "FROZEN"}:
        errors.append(f"unknown registry state {state!r}")
    baseline_commit = materialised.get("implementation_baseline_commit")
    if baseline_commit is not None and not SHA_RE.fullmatch(str(baseline_commit)):
        errors.append(f"invalid implementation baseline commit {baseline_commit!r}")
    current_commit = materialised.get("current_commit")
    if current_commit is not None and not SHA_RE.fullmatch(str(current_commit)):
        errors.append(f"invalid current commit {current_commit!r}")
    producing_commit = materialised.get("registry_producing_commit")
    if producing_commit is not None and not SHA_RE.fullmatch(str(producing_commit)):
        errors.append(f"invalid legacy registry-producing commit {producing_commit!r}")
    if state == "FROZEN":
        unresolved = materialised.get("unresolved_scope_decisions")
        if not isinstance(unresolved, list) or unresolved:
            errors.append("FROZEN registry requires an explicit empty unresolved_scope_decisions list")
        if not _git_repository_available(repo_root):
            errors.append("FROZEN registry requires a real Git repository for immutable verification")
        frozen_hash = materialised.get("frozen_registry_sha256")
        if not isinstance(frozen_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", frozen_hash):
            errors.append("FROZEN registry requires a lowercase frozen_registry_sha256")
        elif frozen_hash != actual_hash:
            errors.append("frozen registry hash does not match registry contents")
    elif materialised.get("frozen_registry_sha256") not in (None, "UNFROZEN", ""):
        warnings.append("UNFROZEN registry has a provisional frozen_registry_sha256")

    registry_blob_verified = bool(
        state == "FROZEN"
        and registry_path is not None
        and _git_registry_blob_matches_head(registry_path, repo_root)
    )
    if state == "FROZEN" and registry_path is not None and not registry_blob_verified:
        errors.append("FROZEN registry file must exactly match its tracked HEAD blob")

    return ValidationReport(
        rows=tuple(dict(row) for row in rows),
        aliases=tuple(dict(alias) for alias in aliases),
        errors=tuple(errors),
        warnings=tuple(warnings),
        state=state,
        registry_hash=actual_hash,
        validated_payload_sha256=_validated_payload_sha256(materialised),
        git_verified=_git_repository_available(repo_root),
        registry_blob_verified=registry_blob_verified,
    )


def load_registry(
    path: Path = REGISTRY_PATH,
    *,
    check_evidence_paths: bool = False,
    expected_commit: str | None = None,
) -> tuple[dict[str, Any], ValidationReport]:
    markdown = path.read_text(encoding="utf-8")
    data = _extract_machine_block(markdown)
    materialised = materialise_registry(data, markdown)
    report = validate_registry(
        materialised,
        repo_root=path.resolve().parents[1],
        check_evidence_paths=check_evidence_paths,
        expected_commit=expected_commit,
        registry_path=path,
    )
    return materialised, report


def score_registry(data: Mapping[str, Any], report: ValidationReport | None = None) -> dict[str, Any]:
    """Return a score only for a valid, frozen registry."""

    report = report or validate_registry(data)
    if report.validated_payload_sha256 != _validated_payload_sha256(data):
        raise RegistryError("score report does not belong to the supplied registry data")
    if report.errors:
        raise RegistryError("cannot score invalid registry:\n" + "\n".join(report.errors))
    if report.state != "FROZEN":
        raise RegistryError("UNFROZEN registry: scoring is prohibited until the registry is frozen")
    if not report.git_verified:
        raise RegistryError("scoring requires a registry report verified in a real Git repository")
    if not report.registry_blob_verified:
        raise RegistryError("scoring requires a clean registry file committed at HEAD")
    p0 = [row for row in report.rows if row.get("severity") == "P0"]
    p0_accepted = sum(row.get("status") == "accepted" for row in p0)
    by_workstream = report.counts_by_workstream()
    workstream_percent = {
        key: (value["accepted"] / value["leaves"] if value["leaves"] else 0.0)
        for key, value in by_workstream.items()
    }
    overall = report.accepted_count / report.leaf_count if report.leaf_count else 0.0
    if p0_accepted != len(p0):
        raise RegistryError("score gate failed: every P0 leaf must be accepted")
    if overall < 0.95:
        raise RegistryError(f"score gate failed: {overall:.2%} accepted, need at least 95%")
    below = sorted(key for key, value in workstream_percent.items() if value < 0.90)
    if below:
        raise RegistryError("score gate failed: workstream(s) below 90%: " + ", ".join(below))
    return {
        "state": report.state,
        "accepted": report.accepted_count,
        "leaves": report.leaf_count,
        "aliases": report.alias_count,
        "percentage": overall,
        "p0": {"accepted": p0_accepted, "leaves": len(p0)},
        "workstreams": workstream_percent,
    }


def _print_report(report: ValidationReport, *, json_output: bool = False, score: Mapping[str, Any] | None = None) -> None:
    summary = {
        "state": report.state,
        "valid": not report.errors,
        "leaves": report.leaf_count,
        "aliases": report.alias_count,
        "accepted": report.accepted_count,
        "registry_hash": report.registry_hash,
        "errors": list(report.errors),
        "warnings": list(report.warnings),
        "workstreams": report.counts_by_workstream(),
    }
    if score is not None:
        summary["score"] = score
    if json_output:
        print(json.dumps(summary, indent=2, sort_keys=True))
        return
    print(
        f"registry: {report.state}; {'valid' if not report.errors else 'INVALID'}; "
        f"{report.leaf_count} scored leaves, {report.alias_count} aliases, "
        f"{report.accepted_count} accepted; hash {report.registry_hash}"
    )
    for warning in report.warnings:
        print(f"warning: {warning}")
    for error in report.errors:
        print(f"error: {error}")
    if score is not None:
        print(f"score: {score['accepted']}/{score['leaves']} ({score['percentage']:.2%})")


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--registry", type=Path, default=REGISTRY_PATH)
    parser.add_argument("--score", action="store_true", help="apply the frozen score gates")
    parser.add_argument(
        "--score-if-frozen",
        action="store_true",
        help="validate while UNFROZEN; apply all score gates automatically once FROZEN",
    )
    parser.add_argument("--json", action="store_true", dest="json_output")
    parser.add_argument(
        "--check-evidence-paths",
        action="store_true",
        help="legacy compatibility flag; accepted evidence is always verified",
    )
    parser.add_argument(
        "--expected-commit",
        default=None,
        help="expected producing commit SHA or symbolic ref (for example HEAD); optional outside CI",
    )
    args = parser.parse_args(argv)
    try:
        data, report = load_registry(
            args.registry,
            check_evidence_paths=args.check_evidence_paths,
            expected_commit=args.expected_commit,
        )
        if report.errors:
            _print_report(report, json_output=args.json_output)
            return 1
        if args.score or (args.score_if_frozen and report.state == "FROZEN"):
            score = score_registry(data, report)
            _print_report(report, json_output=args.json_output, score=score)
            return 0
        _print_report(report, json_output=args.json_output)
        return 0
    except (OSError, RegistryError) as exc:
        if args.json_output:
            print(json.dumps({"valid": False, "errors": [str(exc)]}, indent=2))
        else:
            print(f"error: {exc}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
