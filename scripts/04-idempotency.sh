#!/usr/bin/env bash
# Script 04 — Idempotency: repeat refund and status calls; document behaviour.
# Prerequisite: run 01 first; supply ORDER_ID as $1 (must be a PAID order
# with refund still available, i.e. before its deadline).
#
# Tests:
#  a) Same refund call issued 3× — are all responses identical?
#  b) Same GET /private/orders/$id issued 3× — are responses stable?
#  c) Refund issued, then issued again for same amount — conflict or accepted?
#
# USAGE: docker exec -it taler-sandbox bash /scripts/04-idempotency.sh ORDER_ID

set -euo pipefail

CURRENCY=KUDOS
MERCHANT_URL=http://localhost:8082
INSTANCE=default
MERCHANT_TOKEN="secret-token:sandbox-token"
OUT=/results/04

ORDER_ID="${1:-}"
[[ -n "$ORDER_ID" ]] || { echo "Usage: $0 ORDER_ID"; exit 1; }

mkdir -p "$OUT"
RUNID=$(date +%Y%m%dT%H%M%S)
exec > >(tee "$OUT/run-$RUNID.log") 2>&1

log() { echo "[$(date +%T)] $*"; }

log "=== Script 04: Idempotency — ORDER $ORDER_ID ==="

# --- a) GET order status x3 ---
log "--- a) GET order status × 3 ---"
for i in 1 2 3; do
  curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
    -H "Authorization: Bearer $MERCHANT_TOKEN" \
    | tee "$OUT/a${i}-order-status.json" | jq -c '{order_status,refunded,refund_deadline}' || true
  sleep 1
done
log "Checking whether GET responses are identical ..."
if diff -q "$OUT/a1-order-status.json" "$OUT/a2-order-status.json" > /dev/null 2>&1 \
  && diff -q "$OUT/a2-order-status.json" "$OUT/a3-order-status.json" > /dev/null 2>&1; then
  log "FINDING: GET order status is stable across repeated calls."
else
  log "FINDING: GET order status DIFFERS between calls — investigate."
  diff "$OUT/a1-order-status.json" "$OUT/a2-order-status.json" || true
fi

# --- b) POST refund x3 (same amount each time) ---
log "--- b) POST refund × 3 (same amount $CURRENCY:1) ---"
for i in 1 2 3; do
  HTTP=$(curl -s -w "\n%{http_code}" \
    -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID/refund" \
    -H "Authorization: Bearer $MERCHANT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"refund\":\"$CURRENCY:1\",\"reason\":\"idempotency test\"}")
  BODY=$(echo "$HTTP" | head -n -1)
  STATUS=$(echo "$HTTP" | tail -n 1)
  echo "$BODY" | tee "$OUT/b${i}-refund.json" | jq -c '.' || true
  log "Attempt $i: HTTP $STATUS"
  sleep 1
done

log "Comparing refund responses ..."
IDENTICAL=true
for pair in "b1 b2" "b2 b3"; do
  f1=$(echo "$pair" | awk '{print $1}')
  f2=$(echo "$pair" | awk '{print $2}')
  diff -q "$OUT/${f1}-refund.json" "$OUT/${f2}-refund.json" > /dev/null 2>&1 \
    || { IDENTICAL=false; log "Differ: $f1 vs $f2"; diff "$OUT/${f1}-refund.json" "$OUT/${f2}-refund.json" || true; }
done
$IDENTICAL && log "FINDING: Repeated refund POST is idempotent (responses identical)." \
           || log "FINDING: Repeated refund POST returns DIFFERENT responses — inspect b1/b2/b3."

# --- c) Attempt to refund more than total order value ---
log "--- c) Over-refund attempt ($CURRENCY:2 on a $CURRENCY:1 order) ---"
HTTP=$(curl -s -w "\n%{http_code}" \
  -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID/refund" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"refund\":\"$CURRENCY:2\",\"reason\":\"over-refund test\"}")
BODY=$(echo "$HTTP" | head -n -1)
STATUS=$(echo "$HTTP" | tail -n 1)
echo "$BODY" | tee "$OUT/c1-over-refund.json" | jq . || true
log "Over-refund HTTP: $STATUS — $(echo "$BODY" | jq -r '.code // "no code"')"

log "=== Script 04 complete. Artefacts in $OUT/ ==="
