#!/usr/bin/env bash
# Step 3 - Generate the billing history (baseline) and migrate it to the
#          partitioned design. Checks host disk space first.
source "$(dirname "$0")/lib.sh"
check_host_disk

D="$ROOT_DIR/sql/02_data"
log "Generating history: $DATA_MONTHS months x ~$ROWS_PER_MONTH rows"
run_sql_owner "$D/01_generate_history.sql" \
  "data_start=${DATA_START_MONTH}-01" "data_months=$DATA_MONTHS" \
  "rows_per_month=$ROWS_PER_MONTH" "as_of=${AS_OF_MONTH}-01" | tee "$LOG_DIR/load_history.log"

check_host_disk
log "Building the partitioned copy"
run_sql_owner "$D/02_build_partitioned.sql" | tee "$LOG_DIR/load_partitioned.log"

log "Data load complete - host free disk: $(host_free_gb) GB"
