#!/usr/bin/env bash
# Brings the local environment back after a reboot and exposes it on port 8080.
#   http://inventory.local:8080   app
#   http://grafana.local:8080     Grafana
#   http://localhost:8081         Jenkins
# Safe to run again at any time.
set -euo pipefail

PIDFILE="$HOME/.inventory-port-forward.pid"
LOG="$HOME/.inventory-port-forward.log"

if ! minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  echo "Starting Minikube (existing cluster and data are kept)..."
  minikube start
fi

if [ "$(docker inspect -f '{{.State.Running}}' jenkins 2>/dev/null)" != "true" ]; then
  docker start jenkins >/dev/null
  echo "Jenkins started."
fi

echo "Waiting for the Ingress controller..."
kubectl rollout status deployment/ingress-nginx-controller -n ingress-nginx --timeout=180s >/dev/null

if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  echo "Port forward already running."
else
  # kubectl port-forward exits whenever the Ingress pod restarts, so keep it in a retry loop.
  # setsid gives the loop its own process group, so dev-down.sh can stop it cleanly.
  setsid bash -c 'while true; do
      kubectl port-forward -n ingress-nginx service/ingress-nginx-controller 8080:80
      sleep 2
    done' >"$LOG" 2>&1 </dev/null &
  echo $! > "$PIDFILE"
  echo "Port forward started in the background (log: $LOG)."
fi

echo
echo "App:      http://inventory.local:8080"
echo "Grafana:  http://grafana.local:8080"
echo "Jenkins:  http://localhost:8081"
