#!/usr/bin/env bash
# Web dashboard: the demonstration steps as buttons (http://localhost:8501).
#   scripts/07_dashboard.sh           start (or restart) the dashboard
#   scripts/07_dashboard.sh --fresh   reload the full dataset and prepare the demo
#                                     (reset + setup + schema + load + demo step 0,
#                                     about 10 minutes), then start
#   scripts/07_dashboard.sh --stop    stop the dashboard
source "$(dirname "$0")/lib.sh"
cd "$ROOT_DIR"
compose() { docker compose --env-file "$ENV_FILE" "$@"; }

case "${1:-}" in
  "") ;;
  --stop) compose rm -sf dashboard; exit 0 ;;
  --fresh)
    scripts/reset.sh --yes
    scripts/01_setup_db.sh
    scripts/02_create_schema.sh
    scripts/03_load_data.sh
    scripts/06_demo.sh 0 ;;
  *) sed -n '2,7p' "$0"; exit 1 ;;
esac

compose up -d --build dashboard
url="http://localhost:8501"
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "$url/_stcore/health" 2>/dev/null && break
  sleep 1
done
log "Dashboard running: $url  (stop: scripts/07_dashboard.sh --stop)"
command -v open >/dev/null && open "$url" || true
