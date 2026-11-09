#!/usr/bin/env bash
# Shared helpers sourced by every script:
#   - loads .env (credentials never appear in scripts or on the command line)
#   - runs SQL*Plus inside the Oracle container, feeding SQL through stdin
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"  # override to run e.g. a small smoke test
# absolute path, exported: bash scripts and docker compose read the same file
[[ "$ENV_FILE" = /* ]] || ENV_FILE="$PWD/$ENV_FILE"
export ENV_FILE
LOG_DIR="$ROOT_DIR/logs"
mkdir -p "$LOG_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE - run scripts/init_env.sh first (or fix ENV_FILE)." >&2
  exit 1
fi
set -a; source "$ENV_FILE"; set +a

log() { echo "[$(date '+%F %T')] $*"; }

# SQL*Plus preamble: stop on first error, never echo substitution values
# (they may contain passwords).
_sql_header() {
  cat <<EOF
whenever oserror exit failure
whenever sqlerror exit failure rollback
set verify off echo off feedback on serveroutput on size unlimited
set lines 200 pages 200 trimspool on timing on
EOF
}

# _defines k=v k=v ...  ->  SQL*Plus DEFINE statements
_defines() {
  local kv
  for kv in "$@"; do
    echo "define ${kv%%=*} = \"${kv#*=}\""
  done
}

# run_sql_sysdba <file.sql> [name=value ...]
# Connects with OS authentication inside the container (no SYS password needed)
# and switches to the project PDB.
run_sql_sysdba() {
  local file="$1"; shift
  { _sql_header
    echo "alter session set container = ${ORACLE_PDB};"
    _defines "$@"
    cat "$file"
    echo "exit"
  } | docker exec -i -e ORACLE_SID="$ORACLE_CDB_SID" "$ORACLE_CONTAINER" sqlplus -s -L / as sysdba
}

# run_sql_as <USER> <PASSWORD_VAR_NAME> <file.sql> [name=value ...]
# The password is read from .env and sent through stdin, so it never shows up
# in `ps` output or shell history.
run_sql_as() {
  local user="$1" pw_var="$2" file="$3"; shift 3
  local pw="${!pw_var}"
  { _sql_header
    echo "connect ${user}/\"${pw}\"@//localhost:1521/${ORACLE_PDB_SERVICE}"
    _defines "$@"
    cat "$file"
    echo "exit"
  } | docker exec -i "$ORACLE_CONTAINER" sqlplus -s -L /nolog
}

run_sql_owner() { local f="$1"; shift; run_sql_as TELCO_OWNER TELCO_OWNER_PASSWORD "$f" "$@"; }

# Free space (GB) on the disk that stores Docker data (POSIX df: macOS + Linux).
# Linux: Docker's root dir (e.g. /var/lib/docker) is visible on the host.
# Docker Desktop: it lives inside the VM disk image, stored under $HOME.
host_free_gb() {
  local dir
  dir="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)"
  [[ -n "$dir" && -d "$dir" ]] || dir="$HOME"
  df -Pk "$dir" | awk 'NR==2 {print int($4 / 1048576)}'
}

# check_host_disk [min_gb]  (default MIN_HOST_FREE_GB from .env, else 10)
check_host_disk() {
  local free min="${1:-${MIN_HOST_FREE_GB:-10}}"; free="$(host_free_gb)"
  log "Host free disk: ${free} GB (minimum ${min} GB)"
  if (( free < min )); then
    echo "Not enough free disk on the host - aborting to protect the laptop." >&2
    exit 1
  fi
}
