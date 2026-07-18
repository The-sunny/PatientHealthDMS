-- 00_schemas.sql
-- Medallion schemas within the single patienthealthdms database, plus the
-- pgcrypto extension used throughout (gen_random_uuid(), digest()).

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS bronze;
CREATE SCHEMA IF NOT EXISTS control;
CREATE SCHEMA IF NOT EXISTS silver;
CREATE SCHEMA IF NOT EXISTS gold;
