# PatientHealthDMS — EHR De-Identification & Data-Quality Pipeline

A portfolio project that mirrors a realistic, **medallion-style EHR data pipeline**
on a purely local **PostgreSQL** server. It ingests the [Synthea](https://synthetichealth.github.io/synthea/)
synthetic patient dataset, **de-identifies** it following HIPAA Safe Harbor logic,
and runs **data-quality checks before and after** the transformation — all
orchestrated through **stored procedures** with a full control/audit trail.

> Data is 100% synthetic (Synthea). No real PHI is involved. Raw CSVs are **never**
> committed to this repo — they are read by absolute path at load time.

## Architecture (Postgres schemas standing in for cloud storage stages)

One database (`patienthealthdms`), four schemas:

| Schema | Role |
|--------|------|
| *filesystem* | Raw Synthea CSVs sit untouched in a local folder before load. |
| `bronze` | Raw tables, 1:1 with source CSVs, all `TEXT`, no transformation. Audit columns `load_batch_id`, `loaded_at`. |
| `control` | **Sensitive.** Crosswalk (`original → surrogate` + date offset), reversible token vault, run log, DQ results, de-id audit. The only thing that can re-link the data. |
| `silver` | De-identified tables. Consistent per-patient ID swap + date shift applied across every patient-linked table. |
| `gold` | Cohort-ready analytics (`patient_summary` fact table). |

## De-identification (HIPAA Safe Harbor)
- Consistent **per-patient date shifting** (preserves clinical time-gaps between events).
- **Tokenize** direct identifiers (name, SSN, license, passport, device UDI) via
  salted SHA-256 (`pgcrypto`), with a reversible vault in `control`.
- **Generalize**: ZIP → 3-digit, ages **90+ bucketed**.
- **Suppress** rare / small-cell values.

## Data quality
- **Pre-transform (bronze):** null-rate on key fields, referential integrity on
  `patient_id`, duplicate detection, code-format sanity (SNOMED/LOINC).
- **Post-transform (silver):** RI survived the ID swap, inter-event date deltas
  preserved, row counts match bronze, leaked-identifier scan.
- Every check logs pass/fail to `control.dq_results`.

## Scope
Clinical-core **12 tables**: patients, encounters, conditions, medications,
procedures, observations, immunizations, allergies, careplans, devices,
imaging_studies, supplies.

## Prerequisites
- PostgreSQL 16 running locally (`brew services start postgresql@16`), database
  `patienthealthdms` with the `pgcrypto` extension enabled.
- Synthea CSV sample unzipped into `./synthea_sample_data_csv_latest` next to this
  repo (gitignored — never committed). Override with `CSV_DIR` if it lives elsewhere.

## How to run
```bash
# Only needed if your CSVs aren't at ./synthea_sample_data_csv_latest:
export CSV_DIR="/path/to/synthea_sample_data_csv_latest"

./run.sh                        # run every sql/NN_*.sql file in order (full pipeline)
./run.sh sql/01_bronze_ddl.sql   # or run a single stage
```

Once bronze is loaded (`./run.sh sql/03_load_bronze.sql`, needed once per fresh load
since `\copy` can't run inside a stored procedure), the rest of the pipeline —
pre-DQ, crosswalk, de-identification, post-DQ, gold — can be re-run in one call:
```sql
CALL control.sp_pipeline_run_all('<any-salt-string>');
```
This aborts with an exception if either DQ gate fails (see `control.dq_results` for
the failing check). Inspect results with:
```sql
SELECT * FROM control.pipeline_run_log ORDER BY run_id DESC;
SELECT * FROM control.deid_audit ORDER BY audit_id DESC;
SELECT * FROM gold.patient_summary LIMIT 10;
```

See `sql/` for the per-layer scripts and `CLAUDE.md` for build conventions.
