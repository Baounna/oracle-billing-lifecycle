#!/usr/bin/env bash
# Drop every project object (users + tablespaces + datafiles) to start over.
# Usage: scripts/reset.sh --yes
source "$(dirname "$0")/lib.sh"

if [[ "${1:-}" != "--yes" ]]; then
  echo "This drops TELCO_OWNER, TELCO_APP, TELCO_ANALYST and the TELCO_* tablespaces."
  echo "Re-run with --yes to confirm."
  exit 1
fi
log "Tearing down project objects"
run_sql_sysdba "$ROOT_DIR/sql/00_admin/99_teardown.sql"
log "Reset complete"
