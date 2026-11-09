#!/usr/bin/env bash
# Step 2 - Create the schema objects and PL/SQL packages as TELCO_OWNER.
source "$(dirname "$0")/lib.sh"

S="$ROOT_DIR/sql/01_schema"
log "DLM infrastructure (config, log, control totals)"
run_sql_owner "$S/01_dlm_infrastructure.sql" "as_of_month=$AS_OF_MONTH"
log "Reference data ($CUSTOMERS customers)"
run_sql_owner "$S/02_reference_data.sql" "customers=$CUSTOMERS"
log "Billing tables (baseline + partitioned + archive)"
run_sql_owner "$S/03_billing_tables.sql" "data_start=${DATA_START_MONTH}-01"
log "Data generator"
run_sql_owner "$S/04_datagen.sql"
log "DLM package"
run_sql_owner "$S/05_dlm_pkg.sql"
log "Baseline package"
run_sql_owner "$S/06_baseline_pkg.sql"
log "Grants"
run_sql_owner "$S/07_grants.sql"

log "Checking for invalid objects"
run_sql_owner "$ROOT_DIR/sql/03_tests/00_check_invalid_objects.sql"
log "Schema ready"
