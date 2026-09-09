from __future__ import annotations

import os
import re
import sys
from functools import lru_cache
from pathlib import Path

import pytest


REPO_ROOT = Path(__file__).resolve().parents[2]
PROJECT_FILE = Path("ios/LifeOS.xcodeproj/project.pbxproj")
ROOT_DESIGN_FILE = Path("design.md")
HISTORICAL_PATHS = frozenset({
    Path("tasks/design-overhaul-plan.md"),
    Path("tasks/todo.md"),
    Path("tasks/visual-overhaul-plan.md"),
})
# These are prose-only planning/history paths. The root design contract is
# the one explicit product-document exception; every live source, config,
# route, provider, secret, intent, and test path remains in the scan.
DOCUMENTATION_ALLOWLIST = frozenset((*HISTORICAL_PATHS, ROOT_DESIGN_FILE))
# Coordination and artifacts contain recorded prose/logs. Only those prose
# extensions are allowlisted there; a source or config file in either tree
# remains auditable so the historical exception cannot hide live code.
HISTORICAL_ROOTS = (Path("Coordination"), Path("artifacts"))
HISTORICAL_PROSE_EXTENSIONS = frozenset({".log", ".md", ".txt"})
GENERATED_PARTS = frozenset({
    ".git",
    ".pytest_cache",
    ".mypy_cache",
    ".ruff_cache",
    ".build",
    "node_modules",
    "dist",
    "build",
    "bin",
    "obj",
    "publish",
    "coverage",
    "deriveddata",
    "sourcepackages",
    "testresults",
    "xcuserdata",
    "index.noindex",
    "logs",
    "__pycache__",
    "pods",
    "carthage",
    "vendor",
    "venv",
    ".venv",
})
APP_ROOTS = (Path("ios/LifeOS"), Path("ios/LifeOSMac"), Path("ios/Shared"))
WIDGET_ROOTS = (Path("ios/LifeOSWidget"), Path("ios/LifeOSMacWidget"))
SCANNABLE_EXTENSIONS = frozenset({
    ".bash",
    ".c",
    ".cc",
    ".cfg",
    ".cpp",
    ".cs",
    ".css",
    ".csproj",
    ".entitlements",
    ".h",
    ".html",
    ".ini",
    ".js",
    ".json",
    ".jsx",
    ".m",
    ".md",
    ".mm",
    ".mjs",
    ".pbxproj",
    ".plist",
    ".props",
    ".ps1",
    ".psm1",
    ".py",
    ".pyi",
    ".resolved",
    ".sh",
    ".sql",
    ".strings",
    ".stringsdict",
    ".swift",
    ".swiftinterface",
    ".targets",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".xcconfig",
    ".xcscheme",
    ".xctestplan",
    ".xml",
    ".yaml",
    ".yml",
})
SCANNABLE_BASENAMES = frozenset({".env"})
MAX_SCANNED_FILES = 4096
MAX_TEXT_FILE_BYTES = 1_048_576
BINARY_PREFIX_BYTES = 4096
ROLE_STYLES = {
    "pageTitle": {"size": 28, "weight": "bold", "monospaced": False},
    "sectionTitle": {"size": 20, "weight": "semibold", "monospaced": False},
    "cardTitle": {"size": 17, "weight": "semibold", "monospaced": False},
    "body": {"size": 17, "weight": "regular", "monospaced": False},
    "label": {"size": 15, "weight": "medium", "monospaced": False},
    "metadata": {"size": 13, "weight": "regular", "monospaced": False},
    "metric": {"size": 36, "weight": "semibold", "monospaced": True},
    "metricCompact": {"size": 24, "weight": "semibold", "monospaced": True},
    "button": {"size": 15, "weight": "semibold", "monospaced": False},
}
CUSTOM_FONT_PATTERNS = (
    re.compile(r"(?<![A-Za-z0-9_])Font\s*\.\s*custom\s*\("),
    re.compile(r"(?<![A-Za-z0-9_])\.custom\s*\("),
)


class SourceScanLimitExceeded(RuntimeError):
    """Raised instead of silently omitting source from a bounded audit."""


def _is_generated_part(part: str) -> bool:
    normalized = part.lower()
    return normalized in GENERATED_PARTS or normalized.startswith("lifeos-derived-")


def _is_excluded(relative: Path) -> bool:
    if relative in DOCUMENTATION_ALLOWLIST:
        return True
    if any(_is_generated_part(part) for part in relative.parts):
        return True
    if any(relative == root or root in relative.parents for root in HISTORICAL_ROOTS):
        return relative.suffix.lower() in HISTORICAL_PROSE_EXTENSIONS
    return False


def _is_scannable_file(relative: Path) -> bool:
    return (
        relative.name in SCANNABLE_BASENAMES
        or relative.name.startswith(".env.")
        or relative.suffix.lower() in SCANNABLE_EXTENSIONS
    )


@lru_cache(maxsize=1)
def _repository_files() -> tuple[tuple[Path, Path], ...]:
    files: list[tuple[Path, Path]] = []
    for directory_name, directory_names, file_names in os.walk(
        REPO_ROOT, topdown=True, followlinks=False
    ):
        directory = Path(directory_name)
        relative_directory = directory.relative_to(REPO_ROOT)
        directory_names[:] = [
            name for name in directory_names
            if not (directory / name).is_symlink()
            and not _is_excluded(relative_directory / name)
        ]
        for name in file_names:
            relative = relative_directory / name
            if _is_excluded(relative) or not _is_scannable_file(relative):
                continue
            path = directory / name
            if path.is_symlink() or not path.is_file():
                continue
            if len(files) >= MAX_SCANNED_FILES:
                raise SourceScanLimitExceeded(
                    f"source scan file count exceeded {MAX_SCANNED_FILES}"
                )
            try:
                file_size = path.stat().st_size
            except OSError as error:
                raise SourceScanLimitExceeded(
                    f"could not inspect source file: {relative}"
                ) from error
            if file_size > MAX_TEXT_FILE_BYTES:
                raise SourceScanLimitExceeded(
                    f"text file exceeds {MAX_TEXT_FILE_BYTES} bytes: {relative}"
                )
            files.append((path, relative))
    return tuple(files)


def _text_files() -> tuple[tuple[Path, Path], ...]:
    return _repository_files()


def _read(path: Path) -> str | None:
    """Read one bounded UTF-8 source file; binary payloads are ignored."""
    try:
        file_size = path.stat().st_size
    except OSError as error:
        raise SourceScanLimitExceeded(f"could not inspect source file: {path}") from error
    if file_size > MAX_TEXT_FILE_BYTES:
        raise SourceScanLimitExceeded(
            f"text file exceeds {MAX_TEXT_FILE_BYTES} bytes: {path}"
        )

    read_limit = MAX_TEXT_FILE_BYTES + 1
    with path.open("rb") as handle:
        data = handle.read(min(BINARY_PREFIX_BYTES, read_limit))
        if b"\x00" not in data:
            remaining = read_limit - len(data)
            if remaining > 0:
                data += handle.read(remaining)
    if len(data) > MAX_TEXT_FILE_BYTES:
        raise SourceScanLimitExceeded(
            f"decoded text file exceeds {MAX_TEXT_FILE_BYTES} bytes: {path}"
        )
    if b"\x00" in data:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def _matches(patterns: tuple[re.Pattern[str], ...], value: str) -> bool:
    return any(pattern.search(value) for pattern in patterns)


def _removed_identifier_patterns() -> tuple[tuple[str, re.Pattern[str]], ...]:
    # Keep each spelling independently assembled so this test cannot pass
    # merely because one broad substring was removed. The root pattern has no
    # identifier boundary: it must catch names that embed the removed surface.
    root = "Ad" + "visor"
    identifiers = (
        root,
        root + "View",
        root + "HistoryStore",
        "ad" + "visorProvider",
        "create" + root + "Provider",
        "LIFEOS_" + root.upper() + "_ENABLED",
        "LIFEOS_" + root.upper() + "_SECRET_FILE",
        "ad" + "visor" + "-gemini",
    )
    return tuple((
        identifier,
        re.compile(re.escape(identifier), re.IGNORECASE),
    ) for identifier in identifiers)


def test_source_scan_exclusions_are_deliberate() -> None:
    assert _is_excluded(Path("Coordination/HANDOFF.md"))
    assert _is_excluded(Path("Coordination/archive/old-decision.md"))
    assert _is_excluded(Path("tasks/design-overhaul-plan.md"))
    assert _is_excluded(Path("tasks/visual-overhaul-plan.md"))
    assert _is_excluded(Path("artifacts/apple-validation/old-build.log"))
    assert _is_excluded(Path("ios/build/old-project-metadata.json"))
    assert _is_excluded(ROOT_DESIGN_FILE)
    assert not _is_excluded(Path("docs/recorded-state.md"))
    assert _is_scannable_file(PROJECT_FILE)
    assert _is_scannable_file(Path("services/api/.env.local"))
    assert not _is_scannable_file(
        Path("ios/Shared/Resources/Fonts/") / ("In" + "ter-VariableFont.ttf")
    )
    assert not _is_scannable_file(Path("artifacts/old-build.zip"))
    assert not _is_excluded(PROJECT_FILE)
    assert not _is_excluded(Path("services/api/src/server.ts"))


def test_removed_product_surface_has_no_live_references() -> None:
    patterns = _removed_identifier_patterns()

    for path, relative in _text_files():
        for identifier, pattern in patterns:
            assert not pattern.search(relative.as_posix()), (identifier, relative)
        text = _read(path)
        if text is None:
            continue
        for identifier, pattern in patterns:
            assert not pattern.search(text), (identifier, relative)


def test_removed_identifier_guard_rejects_embedded_names() -> None:
    root = "Ad" + "visor"
    samples = (
        root + "View",
        root + "HistoryStore",
        "ad" + "visorProvider",
        "LIFEOS_" + root.upper() + "_ENABLED",
        "create" + root + "Provider",
    )
    patterns = _removed_identifier_patterns()
    for sample in samples:
        assert _matches(tuple(pattern for _, pattern in patterns), sample), sample


def test_removed_identifier_guard_only_exempts_documentation_paths(tmp_path, monkeypatch) -> None:
    token = "let " + "ad" + "visorProvider = 1"
    paths = {
        ROOT_DESIGN_FILE: token,
        Path("tasks/design-overhaul-plan.md"): token,
        Path("docs/recorded-state.md"): token,
        Path("docs/design.md"): token,
        Path("Coordination/live.swift"): token,
        Path("ios/Live.swift"): token,
    }
    for relative, contents in paths.items():
        destination = tmp_path / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(contents, encoding="utf-8")

    monkeypatch.setattr(sys.modules[__name__], "REPO_ROOT", tmp_path)
    _repository_files.cache_clear()
    try:
        scanned = {relative for _, relative in _text_files()}
        assert ROOT_DESIGN_FILE not in scanned
        assert Path("tasks/design-overhaul-plan.md") not in scanned
        assert Path("docs/recorded-state.md") in scanned
        assert Path("docs/design.md") in scanned
        assert Path("Coordination/live.swift") in scanned
        assert Path("ios/Live.swift") in scanned
        patterns = _removed_identifier_patterns()
        for path, relative in _text_files():
            if relative in {
                Path("docs/recorded-state.md"),
                Path("docs/design.md"),
                Path("Coordination/live.swift"),
                Path("ios/Live.swift"),
            }:
                assert _matches(tuple(pattern for _, pattern in patterns), _read(path) or "")
    finally:
        _repository_files.cache_clear()


def test_source_scan_prunes_and_skips_non_source_files(tmp_path, monkeypatch) -> None:
    safe_source = tmp_path / "ios" / "Live.swift"
    safe_source.parent.mkdir(parents=True)
    safe_source.write_text("let value = 1", encoding="utf-8")
    project_metadata = tmp_path / "ios" / "project.pbxproj"
    project_metadata.write_text("PBXProject = {};", encoding="utf-8")
    token = ("Ad" + "visor") + "View"
    secret_config = tmp_path / "services" / "api" / ".env.local"
    secret_config.parent.mkdir(parents=True)
    secret_config.write_text(token, encoding="utf-8")
    for directory_name in ("build", "node_modules", "lifeos-derived-cache", "bin", "obj", "publish"):
        generated = tmp_path / directory_name
        generated.mkdir()
        (generated / "live.swift").write_text(token, encoding="utf-8")
    artifact_build = tmp_path / "artifacts" / "apple-validation" / "DerivedData"
    artifact_build.mkdir(parents=True)
    (artifact_build / "manifest.json").write_text(token, encoding="utf-8")
    (tmp_path / "font.ttf").write_bytes(token.encode("utf-8") + b"\x00")
    (tmp_path / "archive.zip").write_bytes(token.encode("utf-8"))

    monkeypatch.setattr(sys.modules[__name__], "REPO_ROOT", tmp_path)
    _repository_files.cache_clear()
    try:
        scanned = {relative for _, relative in _text_files()}
        assert Path("ios/Live.swift") in scanned
        assert Path("ios/project.pbxproj") in scanned
        assert Path("services/api/.env.local") in scanned
        assert not any(relative.parts[0] in {
            "artifacts", "build", "node_modules", "bin", "obj", "publish"
        }
                       for relative in scanned)
        assert Path("font.ttf") not in scanned
        assert Path("archive.zip") not in scanned
    finally:
        _repository_files.cache_clear()


def test_source_scan_file_count_cap_fails_closed(tmp_path, monkeypatch) -> None:
    for index in range(3):
        destination = tmp_path / f"source-{index}.swift"
        destination.write_text("let value = 1", encoding="utf-8")
    monkeypatch.setattr(sys.modules[__name__], "REPO_ROOT", tmp_path)
    monkeypatch.setattr(sys.modules[__name__], "MAX_SCANNED_FILES", 2)
    _repository_files.cache_clear()
    try:
        with pytest.raises(SourceScanLimitExceeded, match="file count"):
            _repository_files()
    finally:
        _repository_files.cache_clear()


def test_source_scan_size_cap_fails_closed_but_prunes_oversized_output(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(sys.modules[__name__], "REPO_ROOT", tmp_path)
    monkeypatch.setattr(sys.modules[__name__], "MAX_TEXT_FILE_BYTES", 32)
    safe_source = tmp_path / "safe.swift"
    safe_source.write_text("let value = 1", encoding="utf-8")
    generated = tmp_path / "build"
    generated.mkdir()
    (generated / "oversized.swift").write_text("x" * 128, encoding="utf-8")
    _repository_files.cache_clear()
    try:
        assert {relative for _, relative in _repository_files()} == {Path("safe.swift")}
        oversized = tmp_path / "oversized.swift"
        oversized.write_text("x" * 128, encoding="utf-8")
        _repository_files.cache_clear()
        with pytest.raises(SourceScanLimitExceeded, match="text file"):
            _repository_files()
    finally:
        _repository_files.cache_clear()


def test_product_typography_uses_the_system_facade() -> None:
    swift_and_project_files = [
        (path, relative)
        for path, relative in _text_files()
        if relative.parts[0] == "ios"
        and (
            path.suffix.lower() in {".swift", ".plist", ".yml", ".pbxproj"}
            or relative == PROJECT_FILE
        )
    ]
    assert any(relative == PROJECT_FILE for _, relative in swift_and_project_files)

    legacy_api = "LifeOS" + "Font"
    registrar = "register" + "BundledFonts"
    app_fonts_key = "UI" + "AppFonts"
    legacy_families = (
        "Space" + "Grotesk",
        "Man" + "rope",
        "In" + "ter-VariableFont",
    )
    removed_font_filenames = (
        "In" + "ter-VariableFont.ttf",
        "In" + "ter-VariableFont_wght.ttf",
        "Man" + "rope-VariableFont_wght.ttf",
        "Space" + "Grotesk-VariableFont_wght.ttf",
    )
    standalone_inter = re.compile(r"(?<![A-Za-z])" + "In" + "ter" + r"(?![A-Za-z])")

    for path, relative in _text_files():
        text = _read(path)
        if text is None:
            continue
        assert not any(
            filename in relative.name or filename in text
            for filename in removed_font_filenames
        ), relative

    for path, relative in swift_and_project_files:
        text = _read(path)
        assert legacy_api not in text, relative
        assert registrar not in text, relative
        assert app_fonts_key not in text, relative
        assert not any(family in text for family in legacy_families), relative
        assert not any(filename in text for filename in removed_font_filenames), relative
        if path.suffix.lower() == ".swift":
            assert not standalone_inter.search(text), relative
            assert not _matches(CUSTOM_FONT_PATTERNS, text), relative

    typography = _read(REPO_ROOT / "ios/Shared/Typography.swift")
    for role in ROLE_STYLES:
        assert f"public static func {role}" in typography


def test_app_typography_uses_exact_system_role_contract() -> None:
    typography = _read(REPO_ROOT / "ios/Shared/Typography.swift")
    assert typography.count("systemFont(size:") == len(ROLE_STYLES)
    assert ".system(size: size, weight: weight, design: .default)" in typography
    assert ".system(textStyle" not in typography
    assert "relativeTo: role.dynamicTypeAnchor" in typography
    assert "Font.custom" not in typography
    for role, contract in ROLE_STYLES.items():
        signature = (
            f"public static func {role}(weight: Font.Weight = .{contract['weight']}) -> Font"
        )
        assert signature in typography
        start = typography.index(signature)
        next_role = typography.find("\n    public static func ", start + len(signature))
        body = typography[start: next_role if next_role >= 0 else typography.rfind("\n}")]
        assert f"systemFont(size: {contract['size']}, weight: weight)" in body
        if contract["monospaced"]:
            assert ".monospacedDigit()" in body
        else:
            assert ".monospacedDigit()" not in body

    # The facade has an explicit base size because its existing public shape
    # returns a Font value rather than a View that can consume a SwiftUI
    # environment. Accessibility layouts must therefore be handled by their
    # surrounding containers; no call site may silently substitute a custom
    # font or a second typography facade.
    for root in APP_ROOTS:
        for path, relative in _text_files():
            if path.suffix.lower() != ".swift" or not (
                relative == root or root in relative.parents
            ):
                continue
            text = _read(path)
            if text is None:
                continue
            assert not _matches(CUSTOM_FONT_PATTERNS, text), path
            for match in re.finditer(
                r"LifeOSTypography\.(?:pageTitle|sectionTitle|cardTitle|body|label|metadata|metricCompact|metric|button)\(\s*([^)]*)\)",
                text,
            ):
                arguments = match.group(1).strip()
                assert arguments == "" or arguments.startswith("weight:"), path
    widget_text = []
    for path, relative in _text_files():
        if path.suffix.lower() != ".swift" or not any(
            relative == root or root in relative.parents for root in WIDGET_ROOTS
        ):
            continue
        text = _read(path)
        if text is not None:
            widget_text.append(text)
    assert any(
        ".system(size:" in text for text in widget_text
    )

    font_directory = REPO_ROOT / "ios/Shared/Resources/Fonts"
    assert not font_directory.exists() or not list(font_directory.iterdir())


def test_selected_navigation_palette_is_exact_for_both_appearances() -> None:
    tokens = _read(REPO_ROOT / "ios/Shared/DesignTokens.swift")

    expected = {
        "darkForegroundHex": "B8D5FE",
        "darkBackgroundHex": "011E47",
        "lightForegroundHex": "0244A2",
        "lightBackgroundHex": "E6F0FF",
    }
    for name, value in expected.items():
        assert f"static let {name}: UInt32 = 0x{value}" in tokens

    assert "dark: LifeOSSelectedNavigationPalette.darkBackgroundHex" in tokens
    assert "light: LifeOSSelectedNavigationPalette.lightBackgroundHex" in tokens
    assert "dark: LifeOSSelectedNavigationPalette.darkForegroundHex" in tokens
    assert "light: LifeOSSelectedNavigationPalette.lightForegroundHex" in tokens
    assert "lifeOSSelectedNavigationFill = lifeOSAdaptiveHex(" in tokens
    assert "lifeOSSelectedNavigationText = lifeOSAdaptiveHex(" in tokens


def test_shared_component_and_icon_contracts_are_explicit() -> None:
    components = _read(REPO_ROOT / "ios/Shared/LifeOSComponents.swift")
    icon = _read(REPO_ROOT / "ios/Shared/LifeOSIcon.swift")
    assert components is not None
    assert icon is not None

    assert components.count("ViewThatFits(in: .horizontal)") >= 2
    assert components.count("dynamicTypeSize.isAccessibilitySize") >= 2
    assert "compact: Bool = false" in components
    assert "lifeOSTypography(compact ? .metricCompact : .metric)" in components
    assert "Text(unit)" in components
    assert "lifeOSTypography(.metadata)" in components

    assert ".font(.system(size: 17, weight: .medium, design: .default))" in icon
    assert ".resizable()" not in icon
    assert ".scaledToFit()" not in icon
