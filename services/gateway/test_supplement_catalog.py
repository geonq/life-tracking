import sqlite3

import pytest

from supplement_catalog import (
    SupplementCatalogInvalidQuery,
    SupplementCatalogService,
    SupplementCatalogUnavailable,
)


def catalog(tmp_path):
    path = tmp_path / "supplements.sqlite3"
    connection = sqlite3.connect(path)
    connection.executescript(
        """
        CREATE TABLE supplement_entries (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            brand TEXT NOT NULL,
            product_identifier TEXT,
            form TEXT NOT NULL,
            serving_unit TEXT NOT NULL,
            source TEXT NOT NULL,
            source_date TEXT NOT NULL
        );
        CREATE TABLE supplement_nutrients (
            entry_id TEXT NOT NULL,
            nutrient_id TEXT NOT NULL,
            nutrient_name TEXT NOT NULL,
            amount_per_unit REAL NOT NULL,
            unit TEXT NOT NULL,
            label_basis_units INTEGER,
            nrv_percent REAL,
            PRIMARY KEY (entry_id, nutrient_id)
        );
        INSERT INTO supplement_entries VALUES
          ('natural-elements-folate', 'Folic acid', 'natural elements', NULL, 'tablet', 'tablet', 'package_label', '2026-08-26'),
          ('natural-elements-b-complex', 'B Complex', 'natural elements', 'NEE1010', 'capsule', 'capsule', 'package_label', '2026-08-26');
        INSERT INTO supplement_nutrients VALUES
          ('natural-elements-folate', 'vitamin-b9', 'Folic acid (Vitamin B9)', 0.4, 'mg', 1, 200),
          ('natural-elements-b-complex', 'vitamin-b1', 'Vitamin B1', 40, 'mg', 1, 3636),
          ('natural-elements-b-complex', 'vitamin-b9', 'Folic acid (Vitamin B9)', 0.4, 'mg', 1, 200);
        """
    )
    connection.close()
    return SupplementCatalogService(path)


def test_catalog_search_returns_exact_label_facts_without_writes(tmp_path):
    service = catalog(tmp_path)
    result = service.search("folic acid")

    assert result["schemaVersion"] == 1
    assert result["query"] == "folic acid"
    assert result["entries"][0]["id"] == "natural-elements-folate"
    assert result["entries"][0]["nutrients"] == [{
        "nutrientID": "vitamin-b9",
        "name": "Folic acid (Vitamin B9)",
        "amountPerUnit": 0.4,
        "unit": "mg",
        "labelBasisUnits": 1,
        "nrvPercent": 200.0,
    }]

    connection = sqlite3.connect(service.path)
    assert connection.execute("SELECT COUNT(*) FROM supplement_entries").fetchone()[0] == 2
    connection.close()


def test_catalog_search_matches_nutrient_and_applies_limit(tmp_path):
    service = catalog(tmp_path)
    result = service.search("vitamin b9", "1")
    assert len(result["entries"]) == 1
    assert result["entries"][0]["nutrients"][0]["nutrientID"] == "vitamin-b9"


def test_catalog_rejects_unbounded_queries_and_missing_database(tmp_path):
    service = catalog(tmp_path)
    with pytest.raises(SupplementCatalogInvalidQuery):
        service.search(" ")
    with pytest.raises(SupplementCatalogInvalidQuery):
        service.search("x" * 121)
    with pytest.raises(SupplementCatalogUnavailable):
        SupplementCatalogService(tmp_path / "missing.sqlite3").search("calcium")

