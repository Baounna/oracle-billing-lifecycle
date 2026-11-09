#!/usr/bin/env bash
# Live demonstration, one step at a time. Needs a freshly loaded dataset
# (steps 0 and 4-6 change data). See docs/demo.md for the storyline.
#   scripts/06_demo.sh 0   PREPARE (before the defense): apply last month's policy
#   scripts/06_demo.sh 1   state of the tiers and sizes
#   scripts/06_demo.sh 2   business query: baseline vs partitioned (+ plans)
#   scripts/06_demo.sh 3   lifecycle dry run
#   scripts/06_demo.sh 4   incident: crash while archiving 2023-10 + recovery
#   scripts/06_demo.sh 5   monthly lifecycle run + guard + integrity proof
#   scripts/06_demo.sh 6   security: what the billing application cannot do
if [[ ! "${1:-}" =~ ^[0-6]$ ]]; then sed -n '2,10p' "$0"; exit 1; fi
source "$(dirname "$0")/lib.sh"
D="$ROOT_DIR/sql/04_demo"
case "$1" in
  0) run_sql_owner "$D/00_prepare.sql" ;;
  1) run_sql_owner "$D/01_state.sql" ;;
  2) run_sql_owner "$D/02_queries.sql" ;;
  3) run_sql_owner "$D/03_dry_run.sql" ;;
  4) run_sql_owner "$D/04_incident.sql" ;;
  5) run_sql_owner "$D/05_lifecycle.sql"; run_sql_owner "$D/01_state.sql" ;;
  6) run_sql_as TELCO_APP TELCO_APP_PASSWORD "$ROOT_DIR/sql/03_tests/02_security_app.sql" ;;
esac 2>&1 | grep -vE '^$'
