#!/usr/bin/env bash
# Creates the database Secret in the cluster WITHOUT writing the password to any file.
# - Generates a strong random password.
# - Safe to run twice: if the Secret already exists it is left untouched,
#   because PostgreSQL keeps the password it was first initialized with.
set -euo pipefail

NAMESPACE="inventory"
SECRET="inventory-secrets"

if kubectl get secret "$SECRET" -n "$NAMESPACE" >/dev/null 2>&1; then
  echo "Secret '$SECRET' already exists in namespace '$NAMESPACE' - nothing to do."
  exit 0
fi

PASSWORD="$(openssl rand -hex 24)"

# Values go through a pipe (stdin), not command-line arguments visible in "ps"
printf 'POSTGRES_PASSWORD=%s\nDATABASE_URL=postgresql://inventory:%s@postgres:5432/inventory\n' \
  "$PASSWORD" "$PASSWORD" \
  | kubectl create secret generic "$SECRET" -n "$NAMESPACE" --from-env-file=/dev/stdin

echo "Secret '$SECRET' created. The password is stored only inside the cluster."
