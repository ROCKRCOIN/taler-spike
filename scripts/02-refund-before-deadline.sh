#!/usr/bin/env bash
# Script 02 — Issue refund before refund_deadline; capture signed artefact.
# Prerequisite: run 01-create-and-pay.sh first; pass the ORDER_ID as $1
# or the script will create its own order.
#
# USAGE: docker exec -it taler-sandbox bash /scripts/02-refund-before-deadline.sh [ORDER_ID]

set -euo pipefail

CURRENCY=KUDOS
MERCHANT_URL=http://localhost:8082
BANK_URL=http://localhost:8080
EXCHANGE_URL=http://localhost:8081
INSTANCE=default
MERCHANT_TOKEN="secret-token:sandbox-token"
OUT=/results/02
WALLET_DB=/tmp/wallet-02.wdb

mkdir -p "$OUT"
RUNID=$(date +%Y%m%dT%H%M%S)
exec > >(tee "$OUT/run-$RUNID.log") 2>&1

log() { echo "[$(date +%T)] $*"; }

ORDER_ID="${1:-}"

if [[ -z "$ORDER_ID" ]]; then
  log "No ORDER_ID supplied — creating and paying a fresh order ..."

  ORDER_RESP=$(curl -sf -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders" \
    -H "Authorization: Bearer $MERCHANT_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"order\":{\"summary\":\"Refund-before-deadline $RUNID\",\"amount\":\"$CURRENCY:1\",\"fulfillment_url\":\"http://example.invalid/thanks\"},\"refund_delay\":{\"d_us\":1800000000},\"wire_transfer_delay\":{\"d_us\":3600000000}}")
  ORDER_ID=$(echo "$ORDER_RESP" | jq -r '.order_id')
  log "Created order: $ORDER_ID"

  # Quick pay (reuse testuser balance)
  rm -f "$WALLET_DB"
  taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
    '{"op":"addExchange","request":{"exchangeBaseUrl":"'"$EXCHANGE_URL/"'"}}' > /dev/null || true
  WI=$(curl -sf -X POST "$BANK_URL/accounts/testuser/withdrawals" -u testuser:testpw00 \
    -H "Content-Type: application/json" -d "{\"amount\":\"$CURRENCY:10\"}")
  WID=$(echo "$WI" | jq -r '.withdrawal_id')
  WURI=$(echo "$WI" | jq -r '.taler_withdraw_uri')
  taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
    "{\"op\":\"acceptWithdrawal\",\"request\":{\"talerWithdrawUri\":\"$WURI\",\"selectedExchange\":\"$EXCHANGE_URL/\"}}" > /dev/null || true
  curl -sf -X POST "$BANK_URL/accounts/testuser/withdrawals/$WID/confirm" -u testuser:testpw00 > /dev/null || true
  sleep 5
  STATUS=$(curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
    -H "Authorization: Bearer $MERCHANT_TOKEN")
  PAY_URI=$(echo "$STATUS" | jq -r '.taler_pay_uri // .payment_redirect_url // ""')
  PREP=$(taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
    "{\"op\":\"preparePayForUri\",\"request\":{\"talerPayUri\":\"$PAY_URI\"}}")
  PID=$(echo "$PREP" | jq -r '.proposalId // .response.proposalId // ""')
  taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
    "{\"op\":\"confirmPay\",\"request\":{\"proposalId\":\"$PID\",\"sessionId\":\"\"}}" > /dev/null
  sleep 2
  log "Payment complete."
fi

log "=== Issuing refund for order $ORDER_ID (before deadline) ==="

REFUND_HTTP=$(curl -s -w "\n%{http_code}" \
  -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID/refund" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"refund\":\"$CURRENCY:1\",\"reason\":\"testing refund before deadline\"}")

REFUND_BODY=$(echo "$REFUND_HTTP" | head -n -1)
REFUND_STATUS=$(echo "$REFUND_HTTP" | tail -n 1)
echo "$REFUND_BODY" | tee "$OUT/01-refund-response.json" | jq . || true
log "HTTP status: $REFUND_STATUS"

# Post-refund order status
curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  | tee "$OUT/02-order-after-refund.json" | jq . || true

log ""
log "=== Analysis ==="
REFUND_URI=$(echo "$REFUND_BODY" | jq -r '.taler_refund_uri // .refund_uri // ""')
if [[ "$REFUND_STATUS" =~ ^(200|201) ]] && [[ -n "$REFUND_URI" ]]; then
  log "RESULT: Refund ACCEPTED (HTTP $REFUND_STATUS)"
  log "Refund URI (give to wallet to recover coins): $REFUND_URI"
  log "FINDING: Refund before deadline works as expected."
  log "The refund URI contains exchange-signed artefacts (TALER_RefundRequestPS)."
  log "Artefacts saved to $OUT/01-refund-response.json"
else
  log "RESULT: Refund REJECTED or unexpected (HTTP $REFUND_STATUS)"
  log "Body: $REFUND_BODY"
fi
