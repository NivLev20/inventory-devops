#!/usr/bin/env bash
# API test against a live deployment, through the Ingress. Covers every endpoint in the brief.
#   ./scripts/smoke-test.sh http://192.168.49.2 [inventory.local]
# Uses a temporary product and removes it at the end. The store simulator is paused during
# the test (so its random sales cannot change the numbers being checked) and restored after.
set -euo pipefail

BASE="${1:?usage: smoke-test.sh <base-url> [host]}"
HOST="${2:-inventory.local}"
SKU="SMOKE-$(date +%s)"

call() {  # call METHOD PATH [JSON] -> prints body, fails on HTTP errors
  curl -fsS --max-time 10 -X "$1" -H "Host: $HOST" -H "Content-Type: application/json" \
    ${3:+-d "$3"} "$BASE$2"
}
status() {  # status METHOD PATH [JSON] -> prints only the HTTP code
  curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X "$1" -H "Host: $HOST" \
    -H "Content-Type: application/json" ${3:+-d "$3"} "$BASE$2"
}
field() { python3 -c "import json,sys; print(json.load(sys.stdin)['$1'])"; }
contains_id() { python3 -c "import json,sys; sys.exit(0 if any(r.get('$1') == $2 for r in json.load(sys.stdin)) else 1)"; }
check() { [ "$2" = "$3" ] || { echo "FAIL: $1 - expected $3, got $2"; exit 1; }; echo "ok   $1"; }

# Right after a rollout, the Ingress and Services may still route to pods that are gone
# for a few seconds. Wait for 5 consecutive good answers before changing any data.
echo "== waiting for the API behind the Ingress to be stable"
OK=0
for i in $(seq 1 60); do
  if call GET /api/products/analytics >/dev/null 2>&1; then OK=$((OK + 1)); else OK=0; fi
  [ "$OK" -ge 5 ] && break
  [ "$i" -eq 60 ] && { echo "API not stable at $BASE"; exit 1; }
  sleep 1
done

SIM_WAS="$(call GET /api/simulation | field enabled | tr 'A-Z' 'a-z')"
ID=""
cleanup() {
  [ -n "$ID" ] && call DELETE "/api/products/$ID" >/dev/null 2>&1 || true
  call PUT /api/simulation "{\"enabled\": $SIM_WAS}" >/dev/null 2>&1 || true
}
trap cleanup EXIT
call PUT /api/simulation '{"enabled": false}' >/dev/null
sleep 3  # let a simulator run that already started finish

echo "== product lifecycle"
ID="$(call POST /api/products "{\"name\":\"Smoke test item\",\"sku\":\"$SKU\",\"stock\":10,\"min_stock\":2}" | field id)"
check "POST /api/products creates the product" "$(call GET "/api/products/$ID" | field sku)" "$SKU"
call GET /api/products | contains_id id "$ID" || { echo "FAIL: GET /api/products does not list it"; exit 1; }
echo "ok   GET /api/products lists it"

check "PUT /api/products/<id> updates it" \
  "$(call PUT "/api/products/$ID" '{"name":"Smoke test item (renamed)"}' | field name)" "Smoke test item (renamed)"

check "POST .../sell takes stock" "$(call POST "/api/products/$ID/sell" '{"quantity":3}' | field stock)" "7"
check "overselling is rejected" "$(status POST "/api/products/$ID/sell" '{"quantity":100}')" "409"

check "POST .../restock adds stock" "$(call POST "/api/products/$ID/restock" '{"quantity":5,"note":"smoke"}' | field stock)" "12"
call GET /api/restocks | contains_id product_id "$ID" || { echo "FAIL: delivery missing from /api/restocks"; exit 1; }
echo "ok   GET /api/restocks shows the delivery"

call PUT "/api/products/$ID" '{"stock":1}' >/dev/null
call GET /api/products/low-stock | contains_id id "$ID" || { echo "FAIL: product missing from /low-stock"; exit 1; }
echo "ok   GET /api/products/low-stock includes it"
check "GET /api/products/analytics answers" "$(status GET /api/products/analytics)" "200"

check "DELETE /api/products/<id> removes it" "$(status DELETE "/api/products/$ID")" "200"
check "a deleted product is gone" "$(status GET "/api/products/$ID")" "404"
ID=""

echo "SMOKE TEST PASSED"
