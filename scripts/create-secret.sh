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

kubectl create secret generic "$SECRET" -n "$NAMESPACE" \
  --from-literal=POSTGRES_PASSWORD="$PASSWORD" \
  --from-literal=DATABASE_URL="postgresql://inventory:${PASSWORD}@postgres:5432/inventory"

echo "Secret '$SECRET' created. The password is stored only inside the cluster."
