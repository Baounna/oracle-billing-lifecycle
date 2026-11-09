#!/usr/bin/env bash
# Step 5 - Run the benchmark from the tools container and build the report.
# DESTRUCTIVE: applies the retention policy. Reload data to run again.
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
# Data is already loaded; the benchmark itself adds ~3-4 GB (archive copies, undo).
check_host_disk 10

log "Building tools image (first run only)"
docker compose --env-file "$ENV_FILE" build tools

log "Running benchmark (this takes a while)"
docker compose --env-file "$ENV_FILE" run --rm tools python -m bench.run_benchmark "$@" | tee "$LOG_DIR/benchmark.log"

log "Generating report"
docker compose --env-file "$ENV_FILE" run --rm tools python -m bench.report
log "Done: results/summary.md and results/charts/"
