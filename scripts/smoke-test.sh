#!/usr/bin/env bash
# API test against a live deployment, through the Ingress.
#   ./scripts/smoke-test.sh http://192.168.49.2 [inventory.local]
# Creates a temporary product, sells part of it, checks the stock, then deletes it.
set -euo pipefail

BASE="${1:?usage: smoke-test.sh <base-url> [host]}"
HOST="${2:-inventory.local}"
SKU="SMOKE-$(date +%s)"

api() {
  curl -fsS --max-time 10 -H "Host: $HOST" -H "Content-Type: application/json" "$@"
}
field() {
  python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"
}

# Right after a rollout, the Ingress and Services may still route to pods that are gone
# for a few seconds. Wait for 5 consecutive good answers before changing any data.
echo "== waiting for the API behind the Ingress to be stable"
OK=0
for i in $(seq 1 60); do
  if api "$BASE/api/products/analytics" >/dev/null 2>&1; then OK=$((OK + 1)); else OK=0; fi
  [ "$OK" -ge 5 ] && break
  [ "$i" -eq 60 ] && { echo "API not stable at $BASE"; exit 1; }
  sleep 1
done

ID=""
cleanup() { [ -n "$ID" ] && api -X DELETE "$BASE/api/products/$ID" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "== create product $SKU (stock 10)"
ID="$(api -X POST "$BASE/api/products" \
  -d "{\"name\":\"Smoke test item\",\"sku\":\"$SKU\",\"stock\":10,\"min_stock\":2}" | field id)"

echo "== sell 3 units"
STOCK="$(api -X POST "$BASE/api/products/$ID/sell" -d '{"quantity":3}' | field stock)"
[ "$STOCK" -eq 7 ] || { echo "expected stock 7, got $STOCK"; exit 1; }

echo "== overselling must be rejected (HTTP 409)"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $HOST" -H "Content-Type: application/json" \
  -X POST "$BASE/api/products/$ID/sell" -d '{"quantity":100}')"
[ "$CODE" -eq 409 ] || { echo "expected 409, got $CODE"; exit 1; }

echo "SMOKE TEST PASSED"
