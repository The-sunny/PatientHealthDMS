#!/usr/bin/env bash
#
# run.sh — execute the pipeline SQL against local PostgreSQL.
#
#   ./run.sh                        # run every sql/NN_*.sql in order (full pipeline)
#   ./run.sh sql/01_bronze_ddl.sql  # run a single stage
#
# Env overrides:
#   PGHOST   (default: 127.0.0.1)
#   PGUSER   (default: current unix user, trust auth)
#   PGDATABASE (default: patienthealthdms)
#   CSV_DIR  (default: ./synthea_sample_data_csv_latest next to this script)
#
# The placeholder __CSV_DIR__ in any .sql file (used by \copy statements) is
# substituted with $CSV_DIR at run time, so raw CSV paths never live in the
# committed SQL.
set -euo pipefail

export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGDATABASE="${PGDATABASE:-patienthealthdms}"
SQL_DIR="$(cd "$(dirname "$0")" && pwd)/sql"
CSV_DIR="${CSV_DIR:-$(dirname "$SQL_DIR")/synthea_sample_data_csv_latest}"

run_file() {
  local f="$1"
  echo ">>> running ${f#"$SQL_DIR"/}"
  sed "s|__CSV_DIR__|${CSV_DIR}|g" "$f" | psql -v ON_ERROR_STOP=1
}

if [[ $# -ge 1 ]]; then
  run_file "$1"
else
  shopt -s nullglob
  files=("$SQL_DIR"/[0-9][0-9]_*.sql)
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "No sql/NN_*.sql files found in $SQL_DIR" >&2
    exit 1
  fi
  for f in "${files[@]}"; do
    run_file "$f"
  done
fi

echo "Done."
