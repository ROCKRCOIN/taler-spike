#!/usr/bin/env bash
# Script 01 — Create order, pay with test wallet, observe settlement status.
# Captures deposit confirmation artefacts for Phase 3 Q2 (confirm-of-hold).
#
# USAGE: docker exec -it taler-sandbox bash /scripts/01-create-and-pay.sh

set -euo pipefail

CURRENCY=KUDOS
MERCHANT_URL=http://localhost:8082
EXCHANGE_URL=http://localhost:8081
BANK_URL=http://localhost:8080
INSTANCE=default
MERCHANT_TOKEN="secret-token:sandbox-token"
OUT=/results/01
WALLET_DB=/tmp/wallet-01.wdb

mkdir -p "$OUT"
RUNID=$(date +%Y%m%dT%H%M%S)
exec > >(tee "$OUT/run-$RUNID.log") 2>&1

log() { echo "[$(date +%T)] $*"; }

log "=== Script 01: Create and Pay ==="

# --- Create order (30-min refund window, normal production-like delay) ---
ORDER_RESP=$(curl -sf -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"order\": {
      \"summary\": \"Test order $RUNID\",
      \"amount\": \"$CURRENCY:1\",
      \"fulfillment_url\": \"http://example.invalid/thanks\"
    },
    \"refund_delay\":        {\"d_us\": 1800000000},
    \"wire_transfer_delay\": {\"d_us\": 3600000000}
  }")
echo "$ORDER_RESP" | tee "$OUT/01-order-created.json" | jq .
ORDER_ID=$(echo "$ORDER_RESP" | jq -r '.order_id')
log "Order ID: $ORDER_ID"

# --- Get pay URI ---
STATUS=$(curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" | tee "$OUT/02-order-unpaid.json")
echo "$STATUS" | jq .
TALER_PAY_URI=$(echo "$STATUS" | jq -r '.taler_pay_uri // .payment_redirect_url // ""')
log "Pay URI: $TALER_PAY_URI"

# --- Wallet withdrawal ---
rm -f "$WALLET_DB"
taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
  '{"op":"addExchange","request":{"exchangeBaseUrl":"'"$EXCHANGE_URL/"'"}}' \
  > "$OUT/03-add-exchange.json" || true

WITHDRAW_INIT=$(curl -sf -X POST "$BANK_URL/accounts/testuser/withdrawals" \
  -u "testuser:testpw00" -H "Content-Type: application/json" \
  -d "{\"amount\":\"$CURRENCY:10\"}" | tee "$OUT/04-withdraw-init.json")
echo "$WITHDRAW_INIT" | jq .

WITHDRAW_ID=$(echo "$WITHDRAW_INIT" | jq -r '.withdrawal_id')
TALER_WITHDRAW_URI=$(echo "$WITHDRAW_INIT" | jq -r '.taler_withdraw_uri')

taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
  "{\"op\":\"acceptWithdrawal\",\"request\":{\"talerWithdrawUri\":\"$TALER_WITHDRAW_URI\",\"selectedExchange\":\"$EXCHANGE_URL/\"}}" \
  > "$OUT/05-wallet-accept-withdraw.json" || true

curl -sf -X POST "$BANK_URL/accounts/testuser/withdrawals/$WITHDRAW_ID/confirm" \
  -u "testuser:testpw00" > "$OUT/06-bank-confirm.json" || true

log "Waiting 5s for reserve credit ..."
sleep 5

# --- Payment ---
PREPARE=$(taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
  "{\"op\":\"preparePayForUri\",\"request\":{\"talerPayUri\":\"$TALER_PAY_URI\"}}" \
  | tee "$OUT/07-prepare-pay.json")
echo "$PREPARE" | jq .
PROPOSAL_ID=$(echo "$PREPARE" | jq -r '.proposalId // .response.proposalId // ""')

taler-wallet-cli --no-throttle --wallet-db "$WALLET_DB" api \
  "{\"op\":\"confirmPay\",\"request\":{\"proposalId\":\"$PROPOSAL_ID\",\"sessionId\":\"\"}}" \
  > "$OUT/08-confirm-pay.json"
log "Payment sent."

sleep 2

# --- Post-payment order status (shows refund_deadline, wire info) ---
curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  | tee "$OUT/09-order-paid.json" | jq .

# --- Exchange keys snapshot (proves denomination validity chain) ---
curl -sf "$EXCHANGE_URL/keys" | tee "$OUT/10-exchange-keys.json" | jq '{version,currency,master_public_key,denominations:.denominations|length}' || true

# --- Exchange deposit status (what signed artefacts does the exchange expose?) ---
# VERIFY: exact endpoint for querying deposit/aggregation status
# The exchange /deposits/{H_contract_terms}/{merchant_pub} endpoint may exist
# The merchant order status is the primary proof available without exchange internals.

log "=== Script 01 complete. Artefacts in $OUT/ ==="
log "Key artefacts for Phase 3 Q2 (confirm-of-hold):"
log "  10-exchange-keys.json  — master_public_key, denomination keys"
log "  09-order-paid.json     — refund_deadline, wire_transfer_deadline visible"
log "  08-confirm-pay.json    — payment confirmation from wallet"
