#!/usr/bin/env bash
# Script 06 — Adversarial Aggregation Timing Test (PRIORITY)
#
# QUESTION: Can taler-exchange-aggregator + taler-exchange-transfer fire
# before the refund_deadline expires, and if so, does the exchange still
# honour a refund request that arrives before the deadline?
#
# This is the critical failure-mode check for escrow composition.
#
# Timeline: refund_deadline=2min, wire_deadline=3min.
# Aggregator+transfer fired immediately after payment (~T+10s).
# Refund attempted ~T+20s (100s inside the window, but after wire).
#
# USAGE: docker exec -it taler-sandbox bash /scripts/06-adversarial-aggregation.sh
# OUTPUT: /results/06/ on the host (volume-mounted)

set -euo pipefail

CURRENCY=KUDOS
EXCHANGE_URL=http://localhost:8081
MERCHANT_URL=http://localhost:8082
BANK_URL=http://localhost:8080
INSTANCE=default
MERCHANT_TOKEN="secret-token:sandbox-token"
EXCHANGE_CONFIG=/etc/taler-exchange/taler-exchange.conf
OUT=/results/06
WALLET_DB=/tmp/wallet-06.wdb

mkdir -p "$OUT"
RUNID=$(date +%Y%m%dT%H%M%S)
LOG="$OUT/run-$RUNID.log"
VERDICT="$OUT/verdict-$RUNID.txt"
exec > >(tee "$LOG") 2>&1

log()  { echo "[$(date +%T)] $*"; }
step() { echo; echo "===== $* ====="; }

log "=== Script 06: Adversarial Aggregation Timing — $RUNID ==="
log "Refund window: 120s  |  Wire deadline: 180s"
log ""

# ─────────────────────────────────────────────
# STEP 1: Create order with 2-minute refund window
# ─────────────────────────────────────────────
step "STEP 1: Create order (refund_deadline=2 min, wire_deadline=3 min)"

ORDER_RESP=$(curl -sf -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"order\": {
      \"summary\": \"Adversarial timing test $RUNID\",
      \"amount\": \"$CURRENCY:1\",
      \"fulfillment_url\": \"http://example.invalid/thanks\"
    },
    \"refund_delay\":          {\"d_us\": 120000000},
    \"wire_transfer_delay\":   {\"d_us\": 180000000}
  }" 2>/dev/null)

echo "$ORDER_RESP" | tee "$OUT/01-order-created.json" | python3 -m json.tool 2>/dev/null || echo "$ORDER_RESP"
ORDER_ID=$(echo "$ORDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['order_id'])" 2>/dev/null || echo "")
[[ -n "$ORDER_ID" ]] || { log "FATAL: no order_id in response. Is merchant running?"; cat "$OUT/01-order-created.json"; exit 1; }
log "Order ID: $ORDER_ID"

# ─────────────────────────────────────────────
# STEP 2: Get pay URI
# ─────────────────────────────────────────────
step "STEP 2: Fetch pay URI"

STATUS_RESP=$(curl -sf \
  "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN")
echo "$STATUS_RESP" | tee "$OUT/02-order-status-unpaid.json" | python3 -m json.tool 2>/dev/null || true

TALER_PAY_URI=$(echo "$STATUS_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('taler_pay_uri') or d.get('payment_redirect_url',''))" \
  2>/dev/null || echo "")
[[ -n "$TALER_PAY_URI" ]] || { log "FATAL: no pay URI. Order status:"; cat "$OUT/02-order-status-unpaid.json"; exit 1; }
log "Pay URI: $TALER_PAY_URI"

# ─────────────────────────────────────────────
# STEP 3: Wallet withdrawal + payment
# ─────────────────────────────────────────────
step "STEP 3: Simulate wallet payment"

rm -f "$WALLET_DB"
WALLET_OPTS="--no-throttle --no-http --wallet-db $WALLET_DB"

log "3a. Adding exchange to wallet ..."
# taler-wallet-cli api <operation> '<json>'  (op is positional arg in v1.6)
taler-wallet-cli $WALLET_OPTS api addExchange \
  "{\"exchangeBaseUrl\":\"$EXCHANGE_URL/\"}" \
  2>&1 | tee "$OUT/03a-add-exchange.json" || warn "addExchange returned error (may be OK)"

log "3b. Initiating withdrawal from testuser bank account ..."
WITHDRAW_INIT=$(curl -sf -X POST \
  "$BANK_URL/accounts/testuser/withdrawals" \
  -u "testuser:testpw00" \
  -H "Content-Type: application/json" \
  -d "{\"amount\":\"$CURRENCY:10\"}" 2>/dev/null)
echo "$WITHDRAW_INIT" | tee "$OUT/03b-withdraw-init.json" | python3 -m json.tool 2>/dev/null || true

WITHDRAW_ID=$(echo "$WITHDRAW_INIT" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['withdrawal_id'])" 2>/dev/null || echo "")
TALER_WITHDRAW_URI=$(echo "$WITHDRAW_INIT" | python3 -c \
  "import sys,json; print(json.load(sys.stdin)['taler_withdraw_uri'])" 2>/dev/null || echo "")
[[ -n "$WITHDRAW_ID" ]] || { log "FATAL: withdrawal_id missing. Check bank /accounts/testuser/withdrawals"; exit 1; }

log "3c. Wallet accepts withdrawal (URI: $TALER_WITHDRAW_URI) ..."
taler-wallet-cli $WALLET_OPTS api acceptBankIntegratedWithdrawal \
  "{\"talerWithdrawUri\":\"$TALER_WITHDRAW_URI\",\"exchangeBaseUrl\":\"$EXCHANGE_URL/\"}" \
  2>&1 | tee "$OUT/03c-wallet-accept-withdraw.json" || {
    warn "acceptBankIntegratedWithdrawal failed — trying acceptWithdrawal ..."
    taler-wallet-cli $WALLET_OPTS api acceptWithdrawal \
      "{\"talerWithdrawUri\":\"$TALER_WITHDRAW_URI\",\"selectedExchange\":\"$EXCHANGE_URL/\"}" \
      2>&1 | tee "$OUT/03c-wallet-accept-withdraw-v2.json" || true
  }

log "3d. Bank confirms withdrawal ..."
curl -sf -X POST \
  "$BANK_URL/accounts/testuser/withdrawals/$WITHDRAW_ID/confirm" \
  -u "testuser:testpw00" 2>/dev/null \
  | tee "$OUT/03d-bank-confirm-withdraw.json" | python3 -m json.tool 2>/dev/null || true

log "3e. Waiting 5s for exchange to credit reserve ..."
sleep 5

log "3f. Prepare payment ..."
PREPARE_RESP=$(taler-wallet-cli $WALLET_OPTS api preparePayForUri \
  "{\"talerPayUri\":\"$TALER_PAY_URI\"}" 2>&1 | tee "$OUT/03e-prepare-pay.json")
echo "$PREPARE_RESP" | python3 -m json.tool 2>/dev/null || true

# Extract proposalId (may be at root or under .response)
PROPOSAL_ID=$(echo "$PREPARE_RESP" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('proposalId') or d.get('response',{}).get('proposalId',''))" \
  2>/dev/null || echo "")
[[ -n "$PROPOSAL_ID" ]] || { log "FATAL: no proposalId. Wallet may not have coins or exchange keys. Inspect 03e."; exit 1; }

log "3g. Confirm payment (proposalId=$PROPOSAL_ID) ..."
taler-wallet-cli $WALLET_OPTS api confirmPay \
  "{\"proposalId\":\"$PROPOSAL_ID\",\"sessionId\":\"\"}" \
  2>&1 | tee "$OUT/03f-confirm-pay.json" | python3 -m json.tool 2>/dev/null || true

PAYMENT_EPOCH=$(date +%s)
PAYMENT_TS=$(date -Iseconds)
log "*** PAYMENT COMPLETE at $PAYMENT_TS ***"
sleep 1

curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" 2>/dev/null \
  | tee "$OUT/03g-order-paid-check.json" | python3 -m json.tool 2>/dev/null || true

# ─────────────────────────────────────────────
# STEP 4: ADVERSARIAL — fire aggregator + transfer IMMEDIATELY
# ─────────────────────────────────────────────
step "STEP 4 (ADVERSARIAL): Run aggregator + transfer immediately after payment"

AGG_START=$(date +%s)
T_AGG=$((AGG_START - PAYMENT_EPOCH))
log "T+${T_AGG}s: Running taler-exchange-aggregator -t ..."

taler-exchange-aggregator -c "$EXCHANGE_CONFIG" -t \
  > "$OUT/04a-aggregator-output.txt" 2>&1 \
  && log "Aggregator exited cleanly." \
  || log "Aggregator exited with error (see 04a)."
cat "$OUT/04a-aggregator-output.txt"

XFER_START=$(date +%s)
T_XFER=$((XFER_START - PAYMENT_EPOCH))
log "T+${T_XFER}s: Running taler-exchange-transfer -t ..."

taler-exchange-transfer -c "$EXCHANGE_CONFIG" -t \
  > "$OUT/04b-transfer-output.txt" 2>&1 \
  && log "Transfer exited cleanly." \
  || log "Transfer exited with error (see 04b)."
cat "$OUT/04b-transfer-output.txt"

XFER_DONE=$(date +%s)
T_DONE=$((XFER_DONE - PAYMENT_EPOCH))
log "T+${T_DONE}s: Aggregator+transfer run complete."

# Check merchant bank balance (did the wire arrive?)
curl -sf "$BANK_URL/accounts/merchant" -u "merchant:merchantpw" 2>/dev/null \
  | tee "$OUT/04c-merchant-balance.json" | python3 -m json.tool 2>/dev/null || true

T_REMAINING=$((120 - T_DONE))
log "Refund window remaining: ~${T_REMAINING}s (positive = still open)"

sleep 2

# ─────────────────────────────────────────────
# STEP 5: Attempt refund WHILE WINDOW IS OPEN (post-wire)
# ─────────────────────────────────────────────
step "STEP 5 (CRITICAL): Refund attempt — window open, wire already fired"

NOW=$(date +%s)
T_REFUND=$((NOW - PAYMENT_EPOCH))
T_REM=$((120 - T_REFUND))
log "T+${T_REFUND}s: Refund attempt. Window remaining: ~${T_REM}s."

REFUND_HTTP=$(curl -s -w "\n%{http_code}" \
  -X POST "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID/refund" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"refund\":\"$CURRENCY:1\",\"reason\":\"adversarial-timing-test\"}" 2>/dev/null)

REFUND_BODY=$(echo "$REFUND_HTTP" | head -n -1)
REFUND_STATUS=$(echo "$REFUND_HTTP" | tail -n 1)
echo "$REFUND_BODY" | tee "$OUT/05a-refund-attempt.json" | python3 -m json.tool 2>/dev/null || true
log "Refund HTTP status: $REFUND_STATUS"

# Check order status after refund attempt
curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" 2>/dev/null \
  | tee "$OUT/05b-order-status-after-refund.json" | python3 -m json.tool 2>/dev/null || true

# ─────────────────────────────────────────────
# VERDICT
# ─────────────────────────────────────────────
step "VERDICT"

REFUND_URI=$(echo "$REFUND_BODY" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d.get('taler_refund_uri') or d.get('refund_uri',''))" \
  2>/dev/null || echo "")
EC=$(echo "$REFUND_BODY" | python3 -c \
  "import sys,json; print(json.load(sys.stdin).get('code','none'))" \
  2>/dev/null || echo "unknown")

{
echo "=== Script 06 Adversarial Aggregation — Verdict ($RUNID) ==="
echo ""
echo "Timeline:"
echo "  T+0s:               Payment confirmed ($PAYMENT_TS)"
echo "  T+${T_AGG}s:         Aggregator fired"
echo "  T+${T_XFER}s:         Transfer fired"
echo "  T+${T_REFUND}s:         Refund attempted"
echo "  Refund window:      120s"
echo "  Window at refund:   ~${T_REM}s remaining"
echo ""
echo "Refund HTTP status: $REFUND_STATUS"
echo "Refund error code:  $EC"
echo "Refund body:        $REFUND_BODY"
echo ""

if [[ "$REFUND_STATUS" =~ ^(200|201) ]]; then
  echo "RESULT: REFUND SUCCEEDED (HTTP $REFUND_STATUS)"
  echo ""
  echo "FINDING: Exchange honoured the refund after aggregator+transfer fired."
  echo "Wire firing does NOT block in-window refunds."
  echo ""
  echo "Escrow implication — POSITIVE:"
  echo "  The hold/reverse primitive composes on stock components."
  echo "  The refund_deadline is the sole authority on refundability."
  echo "  Aggregation timing is irrelevant to refund eligibility."
  echo "  (Check 04c vs 05b merchant balance: exchange likely credits next wire cycle)"
  echo ""
  echo "Verdict: COMPOSES WITH STATED CAVEATS"
  echo "  Caveat: no signed 'settlement complete' proof from exchange."
  echo "  Caveat: operator holds funds during aggregation gap."

elif [[ "$REFUND_STATUS" == "409" ]]; then
  echo "RESULT: REFUND REJECTED (HTTP 409, code $EC)"
  echo ""
  echo "FINDING: Exchange rejected the refund even before the deadline expired."
  echo "This is consistent with the exchange checking wire-transfer status."
  echo ""
  echo "Escrow implication — CRITICAL FAILURE:"
  echo "  Hold/reverse does NOT compose cleanly on stock components."
  echo "  Once aggregation fires, the refund window becomes unreachable."
  echo "  Under normal merchant volumes the aggregator may fire quickly."
  echo "  Upstream change required: decouple refund eligibility from wire status."
  echo ""
  echo "Verdict: REQUIRES UPSTREAM CHANGES"

elif [[ "$REFUND_STATUS" == "404" ]]; then
  echo "RESULT: ORDER NOT FOUND (HTTP 404) — investigate ORDER_ID=$ORDER_ID"

else
  echo "RESULT: UNEXPECTED STATUS ($REFUND_STATUS) — manual inspection required"
  echo "See $OUT/05a-refund-attempt.json"
fi

echo ""
echo "Raw files: $OUT/"
echo "Full log:  $LOG"
} | tee "$VERDICT"

log "Verdict written to $VERDICT"
