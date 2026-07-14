#!/usr/bin/env bash
# Script 05 — Capture and annotate all signed artefacts available to the operator.
# Answers Phase 3 Q2: what cryptographic evidence can be shown to a counterparty
# that the hold is real and independently verifiable?
#
# Requires a PAID order to exist. Supply ORDER_ID as $1, or run 01 first.
#
# USAGE: docker exec -it taler-sandbox bash /scripts/05-artefact-capture.sh ORDER_ID

set -euo pipefail

CURRENCY=KUDOS
EXCHANGE_URL=http://localhost:8081
MERCHANT_URL=http://localhost:8082
INSTANCE=default
MERCHANT_TOKEN="secret-token:sandbox-token"
OUT=/results/05

ORDER_ID="${1:-}"
[[ -n "$ORDER_ID" ]] || { echo "Usage: $0 ORDER_ID"; exit 1; }

mkdir -p "$OUT"
RUNID=$(date +%Y%m%dT%H%M%S)
exec > >(tee "$OUT/run-$RUNID.log") 2>&1

log()    { echo "[$(date +%T)] $*"; }
section(){ echo; echo "══ $* ══"; }

log "=== Script 05: Artefact Capture — ORDER $ORDER_ID ==="

# ── 1. Exchange master key & denomination chain ────────────────────────────
section "1. Exchange /keys (master key + denomination validity)"
curl -sf "$EXCHANGE_URL/keys" | tee "$OUT/01-exchange-keys.json" | \
  jq '{
    master_public_key,
    currency,
    version,
    auditors:           (.auditors        | map({auditor_pub,url})),
    denomination_count: (.denominations   | length),
    first_denom_hash:   (.denominations[0].dh // .denominations[0].denom_hash)
  }' || true

log "ARTEFACT 1: Exchange /keys"
log "  Proves: master public key, denomination keys signed by master."
log "  Independently verifiable: YES — any wallet can fetch /keys and verify."
log "  Signed by: exchange master key (EdDSA)."

# ── 2. Exchange /wire (wire account signed by master key) ──────────────────
section "2. Exchange /wire (wire account signatures)"
curl -sf "$EXCHANGE_URL/wire" | tee "$OUT/02-exchange-wire.json" | jq . || true

log "ARTEFACT 2: Exchange /wire"
log "  Proves: the exchange's wire account (payto URI) signed by master key."
log "  Independently verifiable: YES — verifiable against master_public_key from /keys."

# ── 3. Order status (merchant-signed payment commitment) ──────────────────
section "3. Merchant order status for $ORDER_ID"
curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/orders/$ORDER_ID" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  | tee "$OUT/03-order-status.json" | jq . || true

log "ARTEFACT 3: Merchant order status"
log "  Proves: order amount, refund_deadline, wire_transfer_deadline, payment status."
log "  Independently verifiable: PARTIAL — requires trusting the merchant backend."
log "  The refund_deadline here reflects what was signed in TALER_DepositRequestPS"
log "  at pay time; the exchange independently holds the same value."

# ── 4. Exchange deposit lookup ─────────────────────────────────────────────
section "4. Exchange deposit confirmation lookup"
# The merchant backend has the h_contract_terms and coin_pubs from the payment.
# The exchange /deposits/{h_contract_terms}/{merchant_pub}/{coin_pub} endpoint
# returns the exchange's signed deposit confirmation.
# VERIFY: extract h_contract_terms and merchant_pub from order status.
H_CONTRACT=$(cat "$OUT/03-order-status.json" | \
  jq -r '.order.h_contract_terms // .contract_terms_hash // ""' 2>/dev/null || true)
MERCHANT_PUB=$(cat "$OUT/03-order-status.json" | \
  jq -r '.merchant_pub // ""' 2>/dev/null || true)
COIN_PUB=$(cat "$OUT/03-order-status.json" | \
  jq -r '.wire_transfer_id // .coin_pub // (.coins[0].coin_pub // "")' 2>/dev/null || true)

log "h_contract_terms: $H_CONTRACT"
log "merchant_pub:      $MERCHANT_PUB"
log "coin_pub:          $COIN_PUB (first coin)"

if [[ -n "$H_CONTRACT" && -n "$MERCHANT_PUB" && -n "$COIN_PUB" ]]; then
  curl -sf "$EXCHANGE_URL/deposits/$H_CONTRACT/$MERCHANT_PUB/$COIN_PUB" \
    | tee "$OUT/04-exchange-deposit-confirmation.json" | jq . || true
  log "ARTEFACT 4: Exchange deposit confirmation"
  log "  Proves: exchange confirms it received the coin for this contract."
  log "  Independently verifiable: YES — signed by exchange online signing key,"
  log "  which is itself signed by master key from /keys."
else
  log "ARTEFACT 4: Could not extract identifiers for deposit lookup."
  log "  Field names may differ from expected — inspect 03-order-status.json."
fi

# ── 5. Wire transfer tracking ──────────────────────────────────────────────
section "5. Wire transfer tracking"
# VERIFY: the merchant can query /private/transfers for wire transfer status.
curl -sf "$MERCHANT_URL/instances/$INSTANCE/private/transfers" \
  -H "Authorization: Bearer $MERCHANT_TOKEN" \
  | tee "$OUT/05-merchant-transfers.json" | jq . || true

log "ARTEFACT 5: Merchant wire transfer records"
log "  Proves: whether exchange has wired funds and the WTID (wire transfer ID)."
log "  Independently verifiable: PARTIAL — WTID can be looked up on the exchange."

# ── 6. Aggregation status on exchange ─────────────────────────────────────
section "6. Exchange aggregation tracking (if available)"
# VERIFY: /tracking/transaction or /tracking/transfer endpoint
WTID=$(cat "$OUT/05-merchant-transfers.json" | jq -r '.[0].wtid // ""' 2>/dev/null || true)
if [[ -n "$WTID" ]]; then
  curl -sf "$EXCHANGE_URL/tracking/transfer?wtid=$WTID&receiver_wire_details=$(cat "$OUT/02-exchange-wire.json" | jq -r '.[0].payto_uri // ""')" \
    | tee "$OUT/06-exchange-wire-tracking.json" | jq . || true
fi

# ── Summary ────────────────────────────────────────────────────────────────
section "ARTEFACT SUMMARY FOR PHASE 3 Q2"
cat <<'EOF'
┌─────────────────────────────────────────────────────────────────────┐
│ Artefact                  │ Signed by        │ Indep. verifiable?   │
├─────────────────────────────────────────────────────────────────────┤
│ /keys                     │ Exchange master  │ YES                  │
│ /wire                     │ Exchange master  │ YES                  │
│ Deposit confirmation      │ Exchange online  │ YES (via /keys)      │
│ TALER_DepositRequestPS    │ Wallet + merchant│ YES (embedded in pay)│
│ Merchant order status     │ Merchant backend │ NO (trust merchant)  │
│ Wire transfer record      │ Merchant backend │ PARTIAL (WTID lookup)│
│ "Settlement complete"     │ (not issued)     │ NOT AVAILABLE        │
└─────────────────────────────────────────────────────────────────────┘

Gap: No exchange-signed artefact proves that the wire transfer has
completed to the merchant's bank account. The operator must assert this
via their bank statement; a counterparty cannot independently verify it
against the Taler exchange.
EOF

log "=== Script 05 complete. Artefacts in $OUT/ ==="
