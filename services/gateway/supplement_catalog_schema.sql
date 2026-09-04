-- Windows reference-data schema for the read-only /supplements/catalog route.
-- Populate from reviewed package labels or an approved reference import. Do
-- not store personal dose instructions, medical recommendations, or photos in
-- this database.

CREATE TABLE IF NOT EXISTS supplement_entries (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    brand TEXT NOT NULL,
    product_identifier TEXT,
    form TEXT NOT NULL CHECK (form IN ('capsule', 'tablet', 'powder', 'liquid', 'softgel', 'other')),
    serving_unit TEXT NOT NULL,
    source TEXT NOT NULL CHECK (source IN ('manual', 'package_label', 'imported')),
    source_date TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS supplement_nutrients (
    entry_id TEXT NOT NULL REFERENCES supplement_entries(id) ON DELETE CASCADE,
    nutrient_id TEXT NOT NULL,
    nutrient_name TEXT NOT NULL,
    amount_per_unit REAL NOT NULL,
    unit TEXT NOT NULL CHECK (unit IN ('g', 'mg', 'µg', 'mcg', 'ml', 'IU', 'kcal')),
    label_basis_units INTEGER,
    nrv_percent REAL,
    PRIMARY KEY (entry_id, nutrient_id)
);

CREATE INDEX IF NOT EXISTS supplement_entries_name_idx
    ON supplement_entries (name COLLATE NOCASE, brand COLLATE NOCASE);
CREATE INDEX IF NOT EXISTS supplement_nutrients_name_idx
    ON supplement_nutrients (nutrient_name COLLATE NOCASE, nutrient_id COLLATE NOCASE);
