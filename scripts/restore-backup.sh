#!/usr/bin/env bash
# Restores the database from a backup created by the postgres-backup CronJob.
#   ./scripts/restore-backup.sh                         -> list available backups
#   ./scripts/restore-backup.sh inventory-20261108-020000.sql.gz   -> restore that backup
# WARNING: a restore REPLACES all current data in the database.
#
# How it works: a short-lived pod mounts the backups volume and pipes the dump into
# PostgreSQL over the cluster network. The password comes from the Secret, never from this script.
set -euo pipefail
NS="inventory"

run_in_cluster() {
  local script="$1"
  kubectl run backup-restore -n "$NS" --rm -i --restart=Never --quiet \
    --image=postgres:16-alpine \
    --overrides="$(cat <<JSON
{
  "spec": {
    "volumes": [{"name": "backups", "persistentVolumeClaim": {"claimName": "postgres-backups"}}],
    "containers": [{
      "name": "backup-restore",
      "image": "postgres:16-alpine",
      "command": ["sh", "-c", "$script"],
      "env": [
        {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "inventory-secrets", "key": "POSTGRES_PASSWORD"}}},
        {"name": "PGUSER", "valueFrom": {"configMapKeyRef": {"name": "inventory-config", "key": "POSTGRES_USER"}}},
        {"name": "PGDATABASE", "valueFrom": {"configMapKeyRef": {"name": "inventory-config", "key": "POSTGRES_DB"}}},
        {"name": "PGHOST", "value": "postgres"}
      ],
      "volumeMounts": [{"name": "backups", "mountPath": "/backups"}]
    }]
  }
}
JSON
)"
}

if [ $# -eq 0 ]; then
  echo "Available backups (newest first):"
  run_in_cluster "ls -1t /backups"
  exit 0
fi

FILE="$1"
# Strict name check: the name ends up inside a shell command in the helper pod
[[ "$FILE" =~ ^inventory-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]] \
  || { echo "Expected a file name like inventory-20261107-020000.sql.gz"; exit 1; }

read -r -p "This REPLACES the current database with $FILE. Type 'yes' to continue: " ANSWER
[ "$ANSWER" = "yes" ] || { echo "Cancelled."; exit 1; }

# Stop everything that writes to the database while it is being replaced
echo "Pausing writers (backend and simulator)..."
kubectl patch cronjob simulate-sales simulate-new-products -n "$NS" -p '{"spec":{"suspend":true}}' >/dev/null
kubectl patch hpa backend -n "$NS" -p '{"spec":{"minReplicas":1}}' >/dev/null
kubectl scale deployment/backend -n "$NS" --replicas=0
kubectl wait --for=delete pod -l app=backend -n "$NS" --timeout=120s || true

resume_writers() {
  echo "Resuming writers..."
  kubectl scale deployment/backend -n "$NS" --replicas=2
  kubectl patch hpa backend -n "$NS" -p '{"spec":{"minReplicas":2}}' >/dev/null
  kubectl patch cronjob simulate-sales simulate-new-products -n "$NS" -p '{"spec":{"suspend":false}}' >/dev/null
}
trap resume_writers EXIT

# One transaction (-1): if anything fails, PostgreSQL rolls back and the old data stays
run_in_cluster "set -e; test -f /backups/$FILE; \
{ echo 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'; gunzip -c /backups/$FILE; } \
| psql -1 -v ON_ERROR_STOP=1 --quiet; echo Restored $FILE"
