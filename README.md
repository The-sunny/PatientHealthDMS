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
- Synthea CSV sample unzipped locally (default `~/Downloads/synthea_sample_data_csv_latest`).

## How to run
```bash
# Point at your CSV folder if different from the default:
export CSV_DIR="$HOME/Downloads/synthea_sample_data_csv_latest"

./run.sh                 # run every sql/ file in order (full pipeline)
./run.sh sql/01_bronze_ddl.sql   # or run a single stage
```
See `sql/` for the per-layer scripts and `CLAUDE.md` for build conventions.
