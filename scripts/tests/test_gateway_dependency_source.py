"""Static checks for dependencies required by the gateway import boundary."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
REQUIREMENTS = ROOT / "services" / "gateway" / "requirements.txt"
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
    assert re.fullmatch(r"tzdata>=2024\.1,<2027", tzdata_requirements[0])


def test_timezone_dependency_protects_the_existing_europe_berlin_import_gate() -> None:
    source = ENABLE_BANKING.read_text(encoding="utf-8")

    assert "from zoneinfo import ZoneInfo" in source
    assert 'BUSINESS_TIME_ZONE = ZoneInfo("Europe/Berlin")' in source
