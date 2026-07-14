#!/usr/bin/env bash
# Script 03 — Attempt refund AFTER refund_deadline; document failure mode.
# Creates an order with the shortest viable refund window, pays it,
# waits for deadline to expire, then attempts the refund.
#
# Short deadline chosen: 65 seconds (just above 1 minute; the minimum the
# exchange will accept is unknown — if 65s is rejected at order creation,
# try 120s, 300s, etc. and document the minimum found).
#
# USAGE: docker exec -it taler-sandbox bash /scripts/03-refund-after-deadline.sh

set -euo pipefail

CURRENCY=KUDOS
MERCHANT_URL=http://localhost:8082
BANK_URL=http://localhost:8080
EXCHANGE_URL=http://localhost:8081
INSTANCE=default
MERCHANT_TOKEN="secret-token:sandbox-token"
OUT=/results/03
WALLET_DB=/tmp/wallet-03.wdb

# Shortest refund window to test. Reduce until the exchange rejects at creation.
# Document the minimum in findings.
REFUND_DELAY_US=65000000    # 65 seconds
WIRE_DELAY_US=130000000     # 130 seconds (must be > refund_delay)

mkdir -p "$OUT"
RUNID=$(date +%Y%m%dT%H%M%S)
exec > >(tee "$OUT/run-$RUNID.log") 2>&1

log() { echo "[$(date +%T)] $*"; }

log "=== Script 03: Refund After Deadline ==="
log "Refund window: ${REFUND_DELAY_US}µs ($(( REFUND_DELAY_US / 1000000 ))s)"

# --- Create order ---
ORDER_CREATE_HTTP=$(curl -s -w "\n%{http_code}" \
  -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"order\":{
      \"summary\":\"Refund-after-deadline $RUNID\",
      \"amount\":\"$CURRENCY:1\",
      \"fulfillment_url\":\"http://example.invalid/thanks\"
    },
    \"refund_delay\":{\"d_us\":$REFUND_DELAY_US},
    \"wire_transfer_delay\":{\"d_us\":$WIRE_DELAY_US}
  }")

ORDER_BODY=$(echo "$ORDER_CREATE_HTTP" | head -n -1)
ORDER_HTTP_STATUS=$(echo "$ORDER_CREATE_HTTP" | tail -n 1)
echo "$ORDER_BODY" | tee "$OUT/01-order-create.json" | jq . || true
log "Order create HTTP: $ORDER_HTTP_STATUS"

if [[ ! "$ORDER_HTTP_STATUS" =~ ^(200|201) ]]; then
  log "FINDING: Exchange rejected order creation with refund_delay=${REFUND_DELAY_US}µs."
  log "This establishes the minimum refund_deadline floor (above this value)."
  log "HTTP $ORDER_HTTP_STATUS — body: $ORDER_BODY"
  log "Try larger values and re-run."
  exit 0
fi

ORDER_ID=$(echo "$ORDER_BODY" | jq -r '.order_id')
log "Order created: $ORDER_ID"

# --- Pay ---
STATUS=$(curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN")
PAY_URI=$(echo "$STATUS" | jq -r '.taler_pay_uri // .payment_redirect_url // ""')

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

PREP=$(taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
  "{\"op\":\"preparePayForUri\",\"request\":{\"talerPayUri\":\"$PAY_URI\"}}")
PID=$(echo "$PREP" | jq -r '.proposalId // .response.proposalId // ""')
taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
  "{\"op\":\"confirmPay\",\"request\":{\"proposalId\":\"$PID\",\"sessionId\":\"\"}}" > /dev/null

PAYMENT_EPOCH=$(date +%s)
log "Payment complete at $PAYMENT_EPOCH. Refund window: $(( REFUND_DELAY_US / 1000000 ))s."

WAIT_SECS=$(( REFUND_DELAY_US / 1000000 + 5 ))
log "Waiting ${WAIT_SECS}s for refund deadline to expire ..."
sleep "$WAIT_SECS"

# --- Attempt refund AFTER deadline ---
log "Attempting refund now (deadline should be expired) ..."
REFUND_HTTP=$(curl -s -w "\n%{http_code}" \
  -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID/refund" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"refund\":\"$CURRENCY:1\",\"reason\":\"post-deadline attempt\"}")

REFUND_BODY=$(echo "$REFUND_HTTP" | head -n -1)
REFUND_STATUS=$(echo "$REFUND_HTTP" | tail -n 1)
echo "$REFUND_BODY" | tee "$OUT/02-refund-after-deadline.json" | jq . || true

log ""
log "=== Result ==="
log "HTTP: $REFUND_STATUS"
log "Body: $(echo "$REFUND_BODY" | jq -c .)"

EC=$(echo "$REFUND_BODY" | jq -r '.code // "none"')
log "Error code: $EC"
log ""
log "FINDING: Document exact HTTP status and error code here for FINDINGS.md."
log "Expected: 409 Conflict with exchange-level error code."
log "Actual:   HTTP $REFUND_STATUS, code $EC"
