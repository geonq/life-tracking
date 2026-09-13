-- Reviewed facts transcribed from the package-label photos supplied for the
-- LifeOS supplement flow. This is reference data only: it is not a dosage
-- recommendation and it must be reviewed before running on the Windows host.
-- Run after the schema has been applied, for example:
--   sqlite3 C:\\ProgramData\\LifeOS\\data\\supplements.sqlite3 ".read supplement_catalog_schema.sql" ".read supplement_catalog_seed.sql"

PRAGMA foreign_keys = ON;

BEGIN IMMEDIATE;

INSERT INTO supplement_entries
    (id, name, brand, product_identifier, form, serving_unit, source, source_date)
VALUES
    ('natural-elements-folic-acid-400ug', 'Folic acid (Vitamin B9) 400 µg', 'natural elements', '400 tablets', 'tablet', 'tablet', 'package_label', '2026-08-27'),
    ('natural-elements-b-vitamin-complex', 'Vitamin B complex', 'natural elements', '180 capsules', 'capsule', 'capsule', 'package_label', '2026-08-27'),
    ('natural-elements-calcium-800mg-daily', 'Calcium 800 mg daily dose', 'natural elements', '180 tablets', 'tablet', 'tablet', 'package_label', '2026-08-27'),
    ('horbaach-electrolyte-complex-930mg', 'Electrolyte Complex 930 mg', 'Horbäach', '180 vegan tablets', 'tablet', 'tablet', 'package_label', '2026-08-27')
ON CONFLICT(id) DO UPDATE SET
    name = excluded.name,
    brand = excluded.brand,
    product_identifier = excluded.product_identifier,
    form = excluded.form,
    serving_unit = excluded.serving_unit,
    source = excluded.source,
    source_date = excluded.source_date;

INSERT INTO supplement_nutrients
    (entry_id, nutrient_id, nutrient_name, amount_per_unit, unit, label_basis_units, nrv_percent)
VALUES
    ('natural-elements-folic-acid-400ug', 'folic-acid', 'Folic acid (Vitamin B9)', 400, 'µg', 1, 200),
    ('natural-elements-b-vitamin-complex', 'vitamin-b1', 'Vitamin B1', 40, 'mg', 1, 3636),
    ('natural-elements-b-vitamin-complex', 'vitamin-b2', 'Vitamin B2', 15, 'mg', 1, 1071),
    ('natural-elements-b-vitamin-complex', 'niacin-b3', 'Niacin (Vitamin B3)', 110, 'mg', 1, 688),
    ('natural-elements-b-vitamin-complex', 'pantothenic-acid-b5', 'Pantothensäure (Vitamin B5)', 100, 'mg', 1, 1667),
    ('natural-elements-b-vitamin-complex', 'vitamin-b6', 'Vitamin B6', 20, 'mg', 1, 1429),
    ('natural-elements-b-vitamin-complex', 'biotin-b7', 'Biotin (Vitamin B7)', 400, 'µg', 1, 800),
    ('natural-elements-b-vitamin-complex', 'folic-acid', 'Folic acid (Vitamin B9)', 400, 'µg', 1, 200),
    ('natural-elements-b-vitamin-complex', 'vitamin-b12', 'Vitamin B12', 500, 'µg', 1, 20000),
    ('natural-elements-calcium-800mg-daily', 'calcium', 'Calcium', 400, 'mg', 2, 100)
ON CONFLICT(entry_id, nutrient_id) DO UPDATE SET
    nutrient_name = excluded.nutrient_name,
    amount_per_unit = excluded.amount_per_unit,
    unit = excluded.unit,
    label_basis_units = excluded.label_basis_units,
    nrv_percent = excluded.nrv_percent;

-- The electrolyte photo exposes the combined front-label amount and the
-- nutrient names, but not the per-tablet split. Deliberately leave its
-- nutrient rows empty rather than inventing calcium/magnesium values.

COMMIT;
