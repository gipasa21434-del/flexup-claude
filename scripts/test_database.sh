#!/usr/bin/env bash
# Applies the Supabase migration to a throw-away PostgreSQL database (with a tiny Supabase stub)
# and runs the RLS/behaviour test suite. Requires: psql + a reachable Postgres (PG* env vars).
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${TEST_DB:-flexup_test}
PSQL="psql -v ON_ERROR_STOP=1 -X -q -t -A"
export PGOPTIONS="-c client_min_messages=warning"
$PSQL -d postgres -c "drop database if exists $DB" -c "create database $DB"
$PSQL -d "$DB" -f supabase/tests/00_supabase_stub.sql
for f in supabase/migrations/*.sql; do
  echo "→ applying $f"
  $PSQL -d "$DB" -f "$f"
done
PGOPTIONS="-c client_min_messages=notice" $PSQL -d "$DB" -f supabase/tests/01_rls_test.sql 2>&1 \
  | sed -e 's/^psql:[^ ]* NOTICE:  /  /' -e '/^$/d' -e '/^CONTEXT:/d'
# psql exits non-zero on the first failed assertion (ON_ERROR_STOP), which fails CI.
exit "${PIPESTATUS[0]}"
