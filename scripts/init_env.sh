#!/usr/bin/env bash
# Create .env from .env.example with freshly generated random passwords.
# Safe to re-run: an existing .env is never overwritten.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  echo ".env already exists - keeping it."
  exit 0
fi

# Oracle passwords must start with a letter; alphanumerics avoid quoting issues.
gen_pw() { echo "Tl$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 18)9"; }

# Private from the first byte (umask), written to a temp file then renamed, so
# an interrupted run never leaves a partial .env behind.
umask 077
TMP_FILE="$(mktemp "$ROOT_DIR/.env.XXXXXX")"
trap 'rm -f "$TMP_FILE"' EXIT
sed -e "s/^TELCO_OWNER_PASSWORD=.*/TELCO_OWNER_PASSWORD=$(gen_pw)/" \
    -e "s/^TELCO_APP_PASSWORD=.*/TELCO_APP_PASSWORD=$(gen_pw)/" \
    -e "s/^TELCO_ANALYST_PASSWORD=.*/TELCO_ANALYST_PASSWORD=$(gen_pw)/" \
    "$ROOT_DIR/.env.example" > "$TMP_FILE"
mv "$TMP_FILE" "$ENV_FILE"
trap - EXIT
echo "Created $ENV_FILE with random passwords (mode 600)."
