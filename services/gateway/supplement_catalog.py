"""Read-only, parameterized supplement catalog access for the Windows gateway.

The catalog is reference data, not a recommendation service and not personal
health data.  SQLite is used because it is already available in the Python
standard library and gives the Windows data host indexed, exact searches
without exposing a database file to the iPhone.  The gateway returns only the
small validated result envelope; it never accepts catalog writes over HTTP.
"""

from __future__ import annotations

import re
import sqlite3
from datetime import datetime
from pathlib import Path


class SupplementCatalogUnavailable(Exception):
    """The configured catalog is missing, unreadable, or has the wrong schema."""


class SupplementCatalogInvalidQuery(ValueError):
    """The caller supplied a query outside the bounded search contract."""


class SupplementCatalogService:
    MAX_QUERY_LENGTH = 120
    MAX_RESULTS = 20
    MAX_NUTRIENTS_PER_ENTRY = 64
    DATE_PATTERN = re.compile(r"^\d{4}-\d{2}-\d{2}$")
    SAFE_UNITS = {"g", "mg", "µg", "mcg", "ml", "IU", "kcal"}

    def __init__(self, path: Path | str) -> None:
        self.path = Path(path)

    @staticmethod
    def _escape_like(value: str) -> str:
        return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")

    @staticmethod
    def _nutrient_identifier_query(value: str) -> str:
        """Map a human nutrient query to the catalog's stable slug form."""
        return re.sub(r"[^a-z0-9]+", "-", value.casefold()).strip("-")

    @classmethod
    def _query_value(cls, value: str | None) -> str:
        if value is None:
            return ""
        if not isinstance(value, str):
            raise SupplementCatalogInvalidQuery("query must be text")
        query = " ".join(value.split())
        if not query or len(query) > cls.MAX_QUERY_LENGTH:
            raise SupplementCatalogInvalidQuery("query is empty or too long")
        return query

    @classmethod
    def _limit_value(cls, value: str | None) -> int:
        if value is None or value == "":
            return cls.MAX_RESULTS
        try:
            limit = int(value)
        except (TypeError, ValueError) as exc:
            raise SupplementCatalogInvalidQuery("limit must be an integer") from exc
        if not 1 <= limit <= cls.MAX_RESULTS:
            raise SupplementCatalogInvalidQuery("limit is out of bounds")
        return limit

    @classmethod
    def _validate_text(cls, value: object, maximum: int) -> str:
        if not isinstance(value, str):
            raise SupplementCatalogUnavailable("catalog text is invalid")
        value = " ".join(value.split())
        if not value or len(value) > maximum:
            raise SupplementCatalogUnavailable("catalog text is invalid")
        return value

    @classmethod
    def _validate_entry(cls, row: sqlite3.Row, nutrients: list[dict]) -> dict:
        entry_id = cls._validate_text(row["id"], 128)
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})?", entry_id):
            raise SupplementCatalogUnavailable("catalog identifier is invalid")
        source_date = cls._validate_text(row["source_date"], 10)
        if not cls.DATE_PATTERN.fullmatch(source_date):
            raise SupplementCatalogUnavailable("catalog source date is invalid")
        try:
            datetime.strptime(source_date, "%Y-%m-%d")
        except ValueError as exc:
            raise SupplementCatalogUnavailable("catalog source date is invalid") from exc
        form = cls._validate_text(row["form"], 32)
        if form not in {"capsule", "tablet", "powder", "liquid", "softgel", "other"}:
            raise SupplementCatalogUnavailable("catalog form is invalid")
        source = cls._validate_text(row["source"], 128)
        if source not in {"manual", "package_label", "imported"}:
            raise SupplementCatalogUnavailable("catalog source is invalid")
        return {
            "id": entry_id,
            "name": cls._validate_text(row["name"], 160),
            "brand": cls._validate_text(row["brand"], 120),
            "productIdentifier": cls._optional_text(row["product_identifier"], 128),
            "form": form,
            "servingUnit": cls._validate_text(row["serving_unit"], 32),
            "source": source,
            "sourceDate": source_date,
            "nutrients": nutrients,
        }

    @classmethod
    def _optional_text(cls, value: object, maximum: int) -> str | None:
        if value is None:
            return None
        return cls._validate_text(value, maximum)

    @classmethod
    def _validate_nutrient(cls, row: sqlite3.Row) -> dict:
        nutrient_id = cls._validate_text(row["nutrient_id"], 128)
        if not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9_-]{0,127})?", nutrient_id):
            raise SupplementCatalogUnavailable("catalog nutrient identifier is invalid")
        try:
            amount = float(row["amount_per_unit"])
        except (TypeError, ValueError) as exc:
            raise SupplementCatalogUnavailable("catalog nutrient amount is invalid") from exc
        if not 0 < amount <= 1_000_000:
            raise SupplementCatalogUnavailable("catalog nutrient amount is invalid")
        unit = cls._validate_text(row["unit"], 8)
        if unit not in cls.SAFE_UNITS:
            raise SupplementCatalogUnavailable("catalog nutrient unit is invalid")
        basis = row["label_basis_units"]
        if basis is not None and (isinstance(basis, bool) or not isinstance(basis, int) or not 1 <= basis <= 1_000_000):
            raise SupplementCatalogUnavailable("catalog nutrient label basis is invalid")
        nrv = row["nrv_percent"]
        if nrv is not None:
            try:
                nrv = float(nrv)
            except (TypeError, ValueError) as exc:
                raise SupplementCatalogUnavailable("catalog nutrient NRV is invalid") from exc
            if not 0 <= nrv <= 10_000:
                raise SupplementCatalogUnavailable("catalog nutrient NRV is invalid")
        result = {
            "nutrientID": nutrient_id,
            "name": cls._validate_text(row["nutrient_name"], 120),
            "amountPerUnit": amount,
            "unit": unit,
        }
        if basis is not None:
            result["labelBasisUnits"] = basis
        if nrv is not None:
            result["nrvPercent"] = nrv
        return result

    def search(self, query: str | None, limit: str | None = None) -> dict:
        normalized_query = self._query_value(query)
        result_limit = self._limit_value(limit)
        if not self.path.is_file() or self.path.is_symlink():
            raise SupplementCatalogUnavailable("catalog is not available")

        term = f"%{self._escape_like(normalized_query.casefold())}%"
        exact_term = normalized_query.casefold()
        nutrient_identifier = self._nutrient_identifier_query(normalized_query)
        connection: sqlite3.Connection | None = None
        try:
            # `Path.as_uri()` matters on Windows: a raw `C:\\...` path is not
            # a valid SQLite URI and can silently resolve to the wrong file.
            connection = sqlite3.connect(
                f"{self.path.resolve().as_uri()}?mode=ro",
                uri=True,
                timeout=1,
            )
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA query_only = ON")
            entries = connection.execute(
                """
                SELECT e.id, e.name, e.brand, e.product_identifier, e.form,
                       e.serving_unit, e.source, e.source_date
                FROM supplement_entries AS e
                WHERE lower(e.name) LIKE ? ESCAPE '\\'
                   OR lower(e.brand) LIKE ? ESCAPE '\\'
                   OR lower(COALESCE(e.product_identifier, '')) LIKE ? ESCAPE '\\'
                   OR EXISTS (
                       SELECT 1
                       FROM supplement_nutrients AS n
                       WHERE n.entry_id = e.id
                         AND (lower(n.nutrient_name) LIKE ? ESCAPE '\\'
                              OR lower(n.nutrient_id) LIKE ? ESCAPE '\\')
                   )
                ORDER BY
                    CASE
                        WHEN lower(e.name) = ? THEN 0
                        WHEN lower(e.brand) = ?
                          OR lower(COALESCE(e.product_identifier, '')) = ? THEN 1
                        WHEN EXISTS (
                            SELECT 1
                            FROM supplement_nutrients AS exact_n
                            WHERE exact_n.entry_id = e.id
                              AND (lower(exact_n.nutrient_name) = ?
                                   OR lower(exact_n.nutrient_id) = ?)
                        ) THEN 2
                        ELSE 3
                    END,
                    (SELECT COUNT(*) FROM supplement_nutrients AS count_n
                     WHERE count_n.entry_id = e.id),
                    lower(e.name), lower(e.brand), e.id
                LIMIT ?
                """,
                (
                    term,
                    term,
                    term,
                    term,
                    term,
                    exact_term,
                    exact_term,
                    exact_term,
                    exact_term,
                    nutrient_identifier,
                    result_limit,
                ),
            ).fetchall()
            nutrients_by_entry: dict[str, list[dict]] = {row["id"]: [] for row in entries}
            if entries:
                placeholders = ",".join("?" for _ in entries)
                nutrient_rows = connection.execute(
                    f"""
                    SELECT entry_id, nutrient_id, nutrient_name, amount_per_unit,
                           unit, label_basis_units, nrv_percent
                    FROM supplement_nutrients
                    WHERE entry_id IN ({placeholders})
                    ORDER BY entry_id, nutrient_id
                    """,
                    tuple(row["id"] for row in entries),
                ).fetchall()
                for nutrient_row in nutrient_rows:
                    entry_id = nutrient_row["entry_id"]
                    if entry_id not in nutrients_by_entry:
                        raise SupplementCatalogUnavailable("catalog nutrient reference is invalid")
                    nutrients = nutrients_by_entry[entry_id]
                    if len(nutrients) >= self.MAX_NUTRIENTS_PER_ENTRY:
                        raise SupplementCatalogUnavailable("catalog nutrient count is too large")
                    nutrients.append(self._validate_nutrient(nutrient_row))
            payload = {
                "schemaVersion": 1,
                "query": normalized_query,
                "entries": [self._validate_entry(row, nutrients_by_entry[row["id"]]) for row in entries],
            }
            return payload
        except SupplementCatalogUnavailable:
            raise
        except (OSError, sqlite3.Error, KeyError, TypeError, ValueError) as exc:
            raise SupplementCatalogUnavailable("catalog could not be read") from exc
        finally:
            if connection is not None:
                connection.close()
