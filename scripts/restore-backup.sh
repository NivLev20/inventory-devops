#!/usr/bin/env bash
# Restores the database from a backup created by the postgres-backup CronJob.
#   ./scripts/restore-backup.sh                         -> list available backups
#   ./scripts/restore-backup.sh inventory-XXXX.sql.gz   -> restore that backup
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
case "$FILE" in
  inventory-*.sql.gz) ;;
  *) echo "Expected a file name like inventory-20261107-020000.sql.gz"; exit 1 ;;
esac

read -r -p "This REPLACES the current database with $FILE. Type 'yes' to continue: " ANSWER
[ "$ANSWER" = "yes" ] || { echo "Cancelled."; exit 1; }

run_in_cluster "set -e; test -f /backups/$FILE; \
psql -v ON_ERROR_STOP=1 -c 'DROP SCHEMA public CASCADE; CREATE SCHEMA public;'; \
gunzip -c /backups/$FILE | psql -v ON_ERROR_STOP=1 --quiet; echo Restored $FILE"

echo "Restarting backend pods so they reconnect to the restored database..."
kubectl rollout restart deployment/backend -n "$NS"
