#!/usr/bin/env bash
# Step 1 - DBA setup: tablespaces (with size caps) and least-privilege accounts.
source "$(dirname "$0")/lib.sh"

log "Creating tablespaces and capping UNDO/TEMP"
run_sql_sysdba "$ROOT_DIR/sql/00_admin/01_tablespaces.sql" "datafile_dir=$DATAFILE_DIR"

log "Creating project accounts"
run_sql_sysdba "$ROOT_DIR/sql/00_admin/02_users.sql" \
  "owner_pw=$TELCO_OWNER_PASSWORD" \
  "app_pw=$TELCO_APP_PASSWORD" \
  "analyst_pw=$TELCO_ANALYST_PASSWORD"

log "Database setup done"
