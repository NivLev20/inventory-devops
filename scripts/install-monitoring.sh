#!/usr/bin/env bash
# Installs or upgrades Prometheus + Grafana (kube-prometheus-stack) and the project's
# ServiceMonitor and dashboard. Used by the Jenkins "Monitoring" stage; safe to re-run.
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
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  -n "$NS" -f monitoring/values.yaml --wait --timeout 20m

kubectl apply -f monitoring/manifests/
echo "Monitoring is up."
