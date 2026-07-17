# CLAUDE.md — Project context for Claude Code

## What this is
A local **MySQL** medallion pipeline that ingests the **Synthea** synthetic EHR
CSV sample, **de-identifies** it (HIPAA Safe Harbor), and runs **data-quality**
checks pre- and post-transform, orchestrated via **stored procedures** with a
control/audit trail. Portfolio project; no cloud, no real PHI.

## Environment (verified)
- MySQL **9.2.0** (Homebrew), service: `brew services start mysql`.
- Connect: `mysql -u root` (no password), socket `/tmp/mysql.sock` / TCP `127.0.0.1:3306`.
- `LOAD DATA LOCAL INFILE` needs `--local-infile=1` on the client **and**
  `SET GLOBAL local_infile=1` on the server (done at the top of `sql/00_databases.sql`).
- Raw CSVs: `~/Downloads/synthea_sample_data_csv_latest/` (18 files; we use 12).
  **Never commit CSVs** — `run.sh` substitutes the path placeholder `__CSV_DIR__`.

## Schemas
- `ehr_bronze` — raw, all-`VARCHAR`, 1:1 with CSVs + `load_batch_id`, `loaded_at`.
- `ehr_control` — **sensitive**: `patient_crosswalk`, `token_vault` (reversible),
  `pipeline_run_log`, `dq_results`, `deid_audit`.
- `ehr_silver` — de-identified tables.
- `ehr_gold` — `patient_summary` analytics fact table.

## Run order (also the git-commit milestones)
`sql/00_databases.sql` → `01_bronze_ddl.sql` → `02_control_ddl.sql` →
`03_load_bronze.sql` → `04_predq.sql` → `05_crosswalk.sql` →
`06_silver_deid.sql` → `07_postdq.sql` → `08_gold.sql` → `09_orchestrator.sql`.

Run all: `./run.sh`. Single file: `./run.sh sql/<file>.sql`.
Full pipeline proc: `CALL ehr_control.sp_pipeline_run_all('<salt>');`

## Conventions
- Table/column names: lower snake_case; source `PATIENT`/`PATIENTID` → `patient_id`.
- Stored procs named `sp_<layer>_<action>`; every proc writes to `pipeline_run_log`.
- DQ checks log one row per check to `dq_results` (never ad-hoc SELECTs).
- De-id techniques logged to `deid_audit` (DATE_SHIFT/HASH/GENERALIZE/SUPPRESS/BUCKET).
- Dates: bronze keeps raw strings; silver parses (`STR_TO_DATE`, strip `T`/`Z`) and
  applies the per-patient offset via `DATE_ADD`.

## MySQL gotchas to remember
- `LOAD DATA` filename can't be a proc variable → load runs from `.sql`, not a proc.
- Synthea timestamps look like `2016-01-30T22:47:14Z` — not native datetime.
- Empty CSV fields load as `''` (not NULL); handle in silver.
- No Python/scripting in procs; dynamic table names need `PREPARE`/`EXECUTE`.

## Git workflow
- Public repo: `The-sunny/PatientHealthDMS`, branch `main`.
- Commit + push **after each pipeline layer** verifies.
- Commit messages end with the required `Co-Authored-By` trailer.
