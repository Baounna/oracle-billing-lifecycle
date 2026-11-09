#!/usr/bin/env bash
# Step 4 - Functional + security tests on a freshly loaded SMOKE dataset.
# DESTRUCTIVE (applies the lifecycle): the SQL refuses to run on a dataset larger
# than 2 M rows, so the benchmark data cannot be destroyed by mistake.
source "$(dirname "$0")/lib.sh"
T="$ROOT_DIR/sql/03_tests"
OUT="$ROOT_DIR/results/tests"
mkdir -p "$OUT"
rm -f "$OUT"/*.txt   # never leave results of an earlier run next to a failed one

log "Functional tests (lifecycle, guards, incident recovery, integrity)"
run_sql_owner "$T/01_functional_tests.sql" | grep -vE '^Elapsed|^$' | tee "$OUT/functional_tests.txt"

log "Security tests - TELCO_APP"
run_sql_as TELCO_APP TELCO_APP_PASSWORD "$T/02_security_app.sql" \
  | grep -vE '^Elapsed|^$' | tee "$OUT/security_app.txt"

log "Security tests - TELCO_ANALYST"
run_sql_as TELCO_ANALYST TELCO_ANALYST_PASSWORD "$T/03_security_analyst.sql" \
  | grep -vE '^Elapsed|^$' | tee "$OUT/security_analyst.txt"

log "Test outputs saved in results/tests/"
