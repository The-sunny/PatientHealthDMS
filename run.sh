#!/usr/bin/env bash
#
# run.sh — execute the pipeline SQL against local MySQL with LOCAL INFILE enabled.
#
#   ./run.sh                      # run every sql/*.sql in order (full pipeline)
#   ./run.sh sql/01_bronze_ddl.sql  # run a single stage
#
# Env overrides:
#   MYSQL_USER   (default: root)
#   MYSQL_HOST   (default: 127.0.0.1)
#   MYSQL_PWD    (default: empty / no password)
#   CSV_DIR      (default: ~/Downloads/synthea_sample_data_csv_latest)
#
# The placeholder __CSV_DIR__ in any .sql file is substituted with $CSV_DIR at run
# time, so raw CSV paths never live in the committed SQL.
set -euo pipefail

MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_HOST="${MYSQL_HOST:-127.0.0.1}"
CSV_DIR="${CSV_DIR:-$HOME/Downloads/synthea_sample_data_csv_latest}"
SQL_DIR="$(cd "$(dirname "$0")" && pwd)/sql"

mysql_args=(--local-infile=1 -u "$MYSQL_USER" -h "$MYSQL_HOST")
[[ -n "${MYSQL_PWD:-}" ]] && mysql_args+=(-p"$MYSQL_PWD")

run_file() {
  local f="$1"
  echo ">>> running ${f#"$SQL_DIR"/}"
  sed "s|__CSV_DIR__|${CSV_DIR}|g" "$f" | mysql "${mysql_args[@]}"
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
