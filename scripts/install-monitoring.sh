#!/usr/bin/env bash
# Installs or upgrades Prometheus + Grafana (kube-prometheus-stack) and the project's
# ServiceMonitor, Grafana Ingress and dashboard. Used by the Jenkins "Monitoring" stage; safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."

NS="monitoring"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"

# Grafana admin password: random, created once, stored only in the cluster
if ! kubectl get secret grafana-admin -n "$NS" >/dev/null 2>&1; then
  kubectl create secret generic grafana-admin -n "$NS" \
    --from-literal=admin-user=admin \
    --from-literal=admin-password="$(openssl rand -hex 16)"
  echo "Grafana admin secret created."
fi

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update >/dev/null

# Keep the chart version fixed: a new major version can change the values format and
# break an upgrade in the middle of a pipeline run. Order: CHART_VERSION from the
# environment, else the version already installed, else the newest (first install only).
CHART_VERSION="${CHART_VERSION:-$(helm list -n "$NS" -f '^monitoring$' -o json \
  | python3 -c 'import json,sys; r=json.load(sys.stdin); print(r[0]["chart"].rsplit("-",1)[1] if r else "")')}"
VERSION_ARGS=()
if [ -n "$CHART_VERSION" ]; then
  VERSION_ARGS=(--version "$CHART_VERSION")
  echo "kube-prometheus-stack version: $CHART_VERSION"
else
  echo "First install: using the newest kube-prometheus-stack (later runs keep that version)"
fi

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n "$NS" -f monitoring/values.yaml ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} --wait --timeout 20m

kubectl apply -f monitoring/manifests/

# Grafana dashboard as code: the JSON file is kept readable in Git and packed into a
# ConfigMap here. The Grafana sidecar loads every ConfigMap labelled grafana_dashboard=1.
kubectl create configmap dashboard-smart-retail-inventory -n "$NS" \
  --from-file=monitoring/dashboards/smart-retail-inventory.json \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f -
echo "Monitoring is up."
