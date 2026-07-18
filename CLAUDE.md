# CLAUDE.md — Project context for Claude Code

## What this is
A local **PostgreSQL** medallion pipeline that ingests the **Synthea** synthetic
EHR CSV sample, **de-identifies** it (HIPAA Safe Harbor), and runs
**data-quality** checks pre- and post-transform, orchestrated via **stored
procedures** with a control/audit trail. Portfolio project; no cloud, no real PHI.

## Environment (verified)
- PostgreSQL **16.14** (Homebrew `postgresql@16`), service:
  `brew services start postgresql@16`.
- Database: `patienthealthdms`. Connect: `psql -h 127.0.0.1 -d patienthealthdms`
  as local user `sunny` (trust auth, no password).
- Extension: `pgcrypto` (enabled) — provides `gen_random_uuid()` and `digest()`
  for tokenization.
- Raw CSVs: `./synthea_sample_data_csv_latest/` at the repo root (18 files; we
  use 12), gitignored (`synthea*/`). **Never commit CSVs** — `run.sh`
  substitutes the path placeholder `__CSV_DIR__`.
- MySQL 9.2 is also installed/running locally from an earlier iteration of this
  project but is **not used** — this project is Postgres-only now.

## Schemas (all in the single `patienthealthdms` database)
- `bronze` — raw, all-`TEXT`, 1:1 with CSVs + `load_batch_id`, `loaded_at`.
- `control` — **sensitive**: `patient_crosswalk`, `token_vault` (reversible),
  `pipeline_run_log`, `dq_results`, `deid_audit`.
- `silver` — de-identified tables.
- `gold` — `patient_summary` analytics fact table.

## Run order (also the git-commit milestones)
`sql/00_schemas.sql` → `01_bronze_ddl.sql` → `02_control_ddl.sql` →
`03_load_bronze.sql` → `04_predq.sql` → `05_crosswalk.sql` →
`06_silver_deid.sql` → `07_postdq.sql` → `08_gold.sql` → `09_orchestrator.sql`.

Run all: `./run.sh`. Single file: `./run.sh sql/<file>.sql`.
Full pipeline proc: `CALL control.sp_pipeline_run_all('<salt>');`

## Conventions
- Table/column names: lower snake_case (Postgres folds unquoted identifiers to
  lowercase automatically); source `PATIENT`/`PATIENTID` → `patient_id`.
- Stored procs named `sp_<layer>_<action>`, implemented as PL/pgSQL
  **procedures** (`CREATE PROCEDURE` + `CALL`, not functions) so they can commit
  internally; every proc writes to `control.pipeline_run_log`.
- DQ checks log one row per check to `dq_results` (never ad-hoc SELECTs).
- De-id techniques logged to `deid_audit` (DATE_SHIFT/HASH/GENERALIZE/SUPPRESS/BUCKET).
- Dates: bronze keeps raw text; silver casts directly to `timestamptz`/`date`
  (Postgres parses ISO `...Z` timestamps natively, no string surgery) and applies
  the per-patient offset via interval arithmetic.

## PostgreSQL gotchas to remember
- Bulk load uses `\copy` (psql client meta-command, streams from the client
  filesystem — the analog of MySQL's `LOAD DATA LOCAL INFILE`), run directly from
  `run.sh`/psql. **`\copy` cannot be called from inside a procedure** — only
  server-side `COPY` can, and that needs superuser/file privileges we're avoiding.
- Empty CSV fields load as `''` (not NULL); handle with `NULLIF(col, '')` in silver.
- Use `%I`/`%L` in `format()` for any dynamic SQL (`EXECUTE format(...)`) —
  identifier vs literal quoting, injection-safe.
- Hashing/UUIDs require `pgcrypto`: `gen_random_uuid()`, `digest(x, 'sha256')`
  (returns `bytea` — wrap in `encode(..., 'hex')` for a text token).

## Git workflow
- Public repo: `The-sunny/PatientHealthDMS`, branch `main`.
- Commit + push **after each pipeline layer** verifies.
- Commit messages end with the required `Co-Authored-By` trailer.
