#!/usr/bin/env bash
# Stops the background port forward. With --all, also stops Jenkins and Minikube
# (nothing is deleted: cluster data and Jenkins jobs come back with dev-up.sh).
set -euo pipefail

PIDFILE="$HOME/.inventory-port-forward.pid"
if [ -f "$PIDFILE" ] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
  PID="$(cat "$PIDFILE")"
  kill -- -"$PID" 2>/dev/null || { pkill -P "$PID" || true; kill "$PID"; }
  echo "Port forward stopped."
fi
rm -f "$PIDFILE"

if [ "${1:-}" = "--all" ]; then
  docker stop jenkins >/dev/null 2>&1 && echo "Jenkins stopped." || true
  minikube stop
fi
