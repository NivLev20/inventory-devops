#!/usr/bin/env bash
# Deploys the application with a given image tag and waits until it is healthy.
#   ./scripts/deploy.sh <tag>
# Used by Jenkins (deploy and rollback) and by bootstrap.sh. The manifests are rendered
# into a temporary copy with the tag; the files in Git are never modified.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: deploy.sh <image-tag>}"
[[ "$TAG" =~ ^[0-9a-f]{7,40}$ ]] || { echo "Invalid image tag: $TAG"; exit 2; }
NS="inventory"

kubectl apply -f k8s/00-namespace.yaml
./scripts/create-secret.sh

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cp k8s/*.yaml "$WORK/"
sed -i -E "s#(inventory-(backend|frontend)):[0-9a-f]{7,40}#\1:${TAG}#" "$WORK"/*.yaml

# Right after a cluster start the Ingress admission webhook can reject requests briefly
for attempt in 1 2 3 4 5 6; do
  if kubectl apply -f "$WORK/"; then break; fi
  [ "$attempt" -eq 6 ] && { echo "kubectl apply kept failing"; exit 1; }
  echo "Retrying in 10s..."; sleep 10
done

kubectl rollout status statefulset/postgres -n "$NS" --timeout=300s
kubectl rollout status deployment/backend  -n "$NS" --timeout=180s
kubectl rollout status deployment/frontend -n "$NS" --timeout=120s
echo "Deployed $TAG"
