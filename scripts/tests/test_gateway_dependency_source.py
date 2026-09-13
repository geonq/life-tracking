"""Static checks for dependencies required by the gateway import boundary."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
REQUIREMENTS = ROOT / "services" / "gateway" / "requirements.txt"
LOCK = ROOT / "services" / "gateway" / "requirements.lock"
ENABLE_BANKING = ROOT / "services" / "gateway" / "enablebanking.py"


def _requirement_lines() -> list[str]:
    return [
        line.split("#", 1)[0].strip()
        for line in REQUIREMENTS.read_text(encoding="utf-8").splitlines()
        if line.split("#", 1)[0].strip()
    ]


def test_gateway_declares_bounded_timezone_database_dependency() -> None:
    tzdata_requirements = [
        line for line in _requirement_lines() if line.casefold().startswith("tzdata")
    ]

    assert len(tzdata_requirements) == 1
    assert re.fullmatch(r"tzdata==2026\.3", tzdata_requirements[0])


def test_gateway_requirements_are_exactly_pinned() -> None:
    assert _requirement_lines() == [
        "fastapi==0.141.1",
        "httpx==0.28.1",
        "PyJWT[crypto]==2.13.0",
        "python-multipart==0.0.32",
        "starlette==0.51.0",
        "tzdata==2026.3",
        "uvicorn==0.52.4",
        "httptools==0.8.0",
        "websockets==17.1",
    ]


def test_windows_lock_has_one_sha256_hash_for_every_inventory_package() -> None:
    lines = [line.strip() for line in LOCK.read_text(encoding="utf-8").splitlines() if line.strip() and not line.lstrip().startswith("#")]
    assert len(lines) == 25
    assert all(re.search(r"==[^ ]+ --hash=sha256:[0-9a-f]{64}(?:\s+# .+)?$", line) for line in lines)
    assert {line.split("==", 1)[0].casefold() for line in lines} == {
        "annotated-doc", "annotated-types", "anyio", "certifi", "cffi", "click", "cryptography",
        "fastapi", "h11", "httpcore", "httptools", "httpx", "idna", "pycparser", "pydantic",
        "pydantic_core", "pyjwt", "python-multipart", "sniffio", "starlette", "typing-inspection",
        "typing_extensions", "tzdata", "uvicorn", "websockets",
    }


def test_timezone_dependency_protects_the_existing_europe_berlin_import_gate() -> None:
    source = ENABLE_BANKING.read_text(encoding="utf-8")

    assert "from zoneinfo import ZoneInfo" in source
    assert 'BUSINESS_TIME_ZONE = ZoneInfo("Europe/Berlin")' in source
