#!/usr/bin/env bash
# One-command install of the whole system on a fresh machine (no Jenkins needed).
#
#   ./scripts/bootstrap.sh                 # latest published images, with monitoring
#   ./scripts/bootstrap.sh --tag 1a2b3c4   # a specific release
#   ./scripts/bootstrap.sh --no-monitoring # skip Prometheus/Grafana (saves ~1.5 GB RAM)
#
# Requirements: Docker, Minikube, kubectl, curl, python3, openssl (and Helm for monitoring).
set -euo pipefail
cd "$(dirname "$0")/.."

DOCKERHUB_USER="nivlev20"
TAG=""
MONITORING=true
while [ $# -gt 0 ]; do
  case "$1" in
    --tag) TAG="$2"; shift 2 ;;
    --no-monitoring) MONITORING=false; shift ;;
    *) echo "Unknown option: $1"; exit 2 ;;
  esac
done

step() { printf '\n== %s\n' "$1"; }

step "Checking tools"
for tool in docker minikube kubectl curl python3 openssl; do
  command -v "$tool" >/dev/null || { echo "Missing: $tool"; exit 1; }
done
if $MONITORING && ! command -v helm >/dev/null; then
  echo "Helm not found - install it (https://helm.sh/docs/intro/install/) or use --no-monitoring"
  exit 1
fi

step "Starting Minikube"
if ! minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  minikube start --driver=docker --memory=4096 --cpus=2
fi
minikube addons enable ingress
minikube addons enable metrics-server

step "Choosing the release"
if [ -z "$TAG" ]; then
  # Newest backend tag published by the pipeline (the pipeline always pushes backend and frontend together)
  TAG="$(curl -fsS "https://hub.docker.com/v2/repositories/${DOCKERHUB_USER}/inventory-backend/tags?page_size=1&ordering=last_updated" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["name"])')"
fi
echo "Release: $TAG"

step "Waiting for the Ingress controller"
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=300s

step "Deploying the application"
./scripts/deploy.sh "$TAG"

if $MONITORING; then
  step "Installing monitoring (first run downloads ~1 GB of images)"
  ./scripts/install-monitoring.sh
fi

step "Opening access on port 8080"
./scripts/dev-up.sh >/dev/null

cat <<EOF

Done. Add this line to the hosts file once
(Windows: C:\\Windows\\System32\\drivers\\etc\\hosts, Linux/macOS: /etc/hosts):

  127.0.0.1 inventory.local grafana.local

  App:      http://inventory.local:8080
  API docs: http://inventory.local:8080/api/docs
EOF
if $MONITORING; then
  cat <<'EOF'
  Grafana:  http://grafana.local:8080  (user: admin)
            password: kubectl get secret grafana-admin -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d
EOF
fi
