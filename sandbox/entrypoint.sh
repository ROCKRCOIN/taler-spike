#!/usr/bin/env bash
# Sandbox entrypoint v2 — corrected for Taler 1.6.x package layout.
#
# Changes from v1:
#  - Uses package config paths (/etc/taler-exchange, /etc/taler-merchant)
#    via taler-exchange-config -r / taler-merchant-config -r
#  - taler-exchange-offline ceremony: setup → enable-account → wire-fee →
#    global-fee → download → sign → upload  (sign-denomination removed in 1.6)
#  - Starts secmod helpers (secmod-eddsa, secmod-rsa, secmod-cs) before httpd
#  - libeufin-bank configured at /etc/libeufin/libeufin-bank.conf
#    (DB section: [LIBEUFIN-BANKDB-POSTGRES] CONFIG=...)
#  - taler-wallet-cli API: `api <operation> '<json>'` not `{"op":...}` JSON body
#
# Services (all on localhost):
#   :8080  libeufin-bank
#   :8081  taler-exchange-httpd
#   :8082  taler-merchant-httpd
#
# taler-exchange-aggregator and taler-exchange-transfer are NOT started.
# Script 06 fires them on-demand with -t.

set -euo pipefail

CURRENCY="${TALER_CURRENCY:-KUDOS}"
EXCHANGE_CONFIG=/etc/taler-exchange/taler-exchange.conf
MERCHANT_CONFIG=/etc/taler-merchant/taler-merchant.conf
BANK_CONFIG=/etc/libeufin/libeufin-bank.conf
RUNTIME_DIR=/var/lib/taler-exchange-runtime
INIT_FLAG=$RUNTIME_DIR/.initialized
KEYS_FLAG=$RUNTIME_DIR/.keys-enabled
INSTANCE_FLAG=$RUNTIME_DIR/.instance-created

log()  { echo "[$(date +%T)] $*"; }
die()  { echo "[FATAL] $*" >&2; exit 1; }
warn() { echo "[WARN]  $*"; }

xconf()  { taler-exchange-config -c "$EXCHANGE_CONFIG" -r -s "$1" -o "$2" -V "$3"; }
mconf()  { taler-merchant-config -c "$MERCHANT_CONFIG" -r -s "$1" -o "$2" -V "$3"; }

wait_http() {
  local url=$1 label=$2 tries=${3:-30}
  log "Waiting for $label ($url) ..."
  for i in $(seq 1 $tries); do
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo 000)
    [[ "$code" =~ ^[2-4] ]] && { log "$label ready (HTTP $code)"; return 0; }
    sleep 2
  done
  die "$label did not become ready after ${tries}×2s. See logs."
}

mkdir -p "$RUNTIME_DIR"

# ============================================================
# ONE-TIME INITIALIZATION
# ============================================================
if [[ ! -f $INIT_FLAG ]]; then
  log "====== FIRST BOOT: initializing Taler 1.6 sandbox ======"

  # --- PostgreSQL ---
  log "Waiting for PostgreSQL ..."
  until pg_isready -h "$PGHOST" -U "$PGUSER" -q; do sleep 2; done

  for dbname in exchange merchant bank; do
    PGPASSWORD="$PGPASSWORD" psql -h "$PGHOST" -U "$PGUSER" -d postgres \
      -c "CREATE DATABASE $dbname;" 2>/dev/null \
      && log "Created DB: $dbname" || log "DB '$dbname' already exists."
  done

  # --- LibEufin Bank config ---
  log "Configuring libeufin-bank ..."
  # libeufin uses its own config format (not GNUnet INI exactly).
  # We write directly since libeufin-bank has no 'config set' command.
  cat > "$BANK_CONFIG" <<EOF
[libeufin-bank]
CURRENCY = $CURRENCY
SERVE = tcp
PORT = 8080
BASE_URL = http://localhost:8080/
WIRE_TYPE = x-taler-bank
DEFAULT_CUSTOMER_DEBT_LIMIT = ${CURRENCY}:200
DEFAULT_ADMIN_DEBT_LIMIT = ${CURRENCY}:1000000
ALLOW_REGISTRATION = YES

[libeufin-bankdb-postgres]
CONFIG = jdbc:postgresql://db:5432/bank?user=taler&password=taler
EOF

  libeufin-bank dbinit -c "$BANK_CONFIG" \
    || die "libeufin-bank dbinit failed"

  # Start bank temporarily to create accounts
  log "Starting libeufin-bank for account provisioning ..."
  libeufin-bank serve -c "$BANK_CONFIG" > /var/log/taler/bank.log 2>&1 &
  BANK_PID=$!
  wait_http "http://localhost:8080/config" "libeufin-bank (provisioning)"

  log "Creating bank accounts ..."
  taler-harness deployment provision-bank-account \
    "http://localhost:8080/" \
    --exchange --login exchange --name "Taler Exchange" --password exchangepw \
    || warn "Exchange bank account provision failed — may already exist"

  taler-harness deployment provision-bank-account \
    "http://localhost:8080/" \
    --login merchant --name "Test Merchant" --password merchantpw \
    || warn "Merchant bank account provision failed"

  taler-harness deployment provision-bank-account \
    "http://localhost:8080/" \
    --login testuser --name "Test User" --password testpw00 \
    || warn "testuser provision failed"

  kill "$BANK_PID" 2>/dev/null; wait "$BANK_PID" 2>/dev/null || true
  log "Bank provisioning done."

  # --- Exchange configuration via taler-exchange-config -r ---
  log "Configuring exchange ..."

  # Switch from unix socket to TCP
  xconf exchange SERVE tcp
  xconf exchange PORT 8081
  xconf exchange BASE_URL "http://localhost:8081/"
  xconf exchange CURRENCY "$CURRENCY"
  xconf exchange CURRENCY_ROUND_UNIT "${CURRENCY}:0.01"
  xconf exchange TINY_AMOUNT "${CURRENCY}:0.01"
  xconf exchange AML_THRESHOLD "${CURRENCY}:1000000"
  xconf exchange ENABLE_KYC NO
  xconf exchange ATTRIBUTE_ENCRYPTION_KEY "$(openssl rand -hex 32)"
  # Fastest possible aggregation for adversarial test
  xconf exchange AGGREGATOR_IDLE_SLEEP_INTERVAL "60 s"

  # DB connection — set directly so package-default URL is overridden
  xconf exchangedb-postgres CONFIG "postgresql://taler:taler@db:5432/exchange"

  # Wire account (enable existing [exchange-account-1] section)
  xconf exchange-account-1 PAYTO_URI "payto://x-taler-bank/localhost:8080/exchange?receiver-name=Exchange"
  xconf exchange-account-1 ENABLE_CREDIT YES
  xconf exchange-account-1 ENABLE_DEBIT YES

  # Wire account credentials
  xconf exchange-accountcredentials-1 WIRE_GATEWAY_AUTH_METHOD basic
  xconf exchange-accountcredentials-1 USERNAME exchange
  xconf exchange-accountcredentials-1 PASSWORD exchangepw
  xconf exchange-accountcredentials-1 WIRE_GATEWAY_URL "http://localhost:8080/accounts/exchange/taler-wire-gateway/"

  # --- Denomination keys ---
  log "Generating $CURRENCY denomination config ..."
  taler-harness deployment gen-coin-config \
    --min-amount "${CURRENCY}:0.01" \
    --max-amount "${CURRENCY}:100" \
    --no-fees \
    >> "$EXCHANGE_CONFIG" \
    || die "gen-coin-config failed"

  # Terms of service (required by exchange, can be minimal)
  mkdir -p /var/lib/taler-exchange/terms
  echo "Test exchange - no ToS" > /var/lib/taler-exchange/terms/exchange-tos-v0.en.txt
  echo "Test exchange - no PP"  > /var/lib/taler-exchange/terms/exchange-pp-v0.en.txt

  # --- Generate master key ---
  log "Generating exchange master key ..."
  mkdir -p /var/lib/taler-exchange/offline
  MASTER_PUB=$(taler-exchange-offline -c "$EXCHANGE_CONFIG" setup 2>/dev/null) \
    || die "taler-exchange-offline setup failed"
  [[ -n "$MASTER_PUB" ]] || die "Empty master public key from setup"
  log "Master public key: $MASTER_PUB"

  # Write to exchange config
  xconf exchange MASTER_PUBLIC_KEY "$MASTER_PUB"
  # Also write to runtime dir so scripts can read it
  echo "$MASTER_PUB" > "$RUNTIME_DIR/master.pub"

  # --- Exchange DB init ---
  log "Initializing exchange database schema ..."
  mkdir -p /run/taler-exchange /var/lib/taler-exchange/{keys,revocations}
  taler-exchange-dbinit -c "$EXCHANGE_CONFIG" \
    || die "taler-exchange-dbinit failed"

  # --- Merchant configuration ---
  log "Configuring merchant ..."
  mconf merchant SERVE tcp
  mconf merchant PORT 8082
  mconf merchant BASE_URL "http://localhost:8082/"
  mconf merchant CURRENCY "$CURRENCY"

  # DB
  mconf merchantdb-postgres CONFIG "postgresql://taler:taler@db:5432/merchant"

  # Exchange reference — add a new section for our exchange
  cat >> /etc/taler-merchant/taler-merchant.conf <<EOF

[merchant-exchange-kudos]
URL = http://localhost:8081/
MASTER_KEY = $MASTER_PUB
CURRENCY = $CURRENCY
EOF

  # Merchant admin auth token
  cat > /etc/taler-merchant/secrets/merchant.conf <<EOF
[merchant]
AUTH_TOKEN = secret-token:sandbox-token
EOF

  # Merchant DB init
  taler-merchant-dbinit -c "$MERCHANT_CONFIG" \
    || die "taler-merchant-dbinit failed"

  touch "$INIT_FLAG"
  log "====== Database and config initialization complete ======"
fi

# ============================================================
# START SERVICES
# ============================================================

log "Ensuring runtime directories exist ..."
mkdir -p /run/taler-exchange /run/taler-merchant \
         /var/lib/taler-exchange/{keys,revocations,offline} \
         /var/log/taler

# --- LibEufin Bank ---
log "Starting libeufin-bank (port 8080) ..."
libeufin-bank serve -c "$BANK_CONFIG" > /var/log/taler/bank.log 2>&1 &
BANK_PID=$!
wait_http "http://localhost:8080/config" "libeufin-bank"

# --- Exchange secmod helpers (must start before httpd) ---
log "Starting exchange secmod helpers ..."
taler-exchange-secmod-eddsa -c "$EXCHANGE_CONFIG" > /var/log/taler/secmod-eddsa.log 2>&1 &
EDDSA_PID=$!
taler-exchange-secmod-rsa  -c "$EXCHANGE_CONFIG" > /var/log/taler/secmod-rsa.log 2>&1 &
RSA_PID=$!
taler-exchange-secmod-cs   -c "$EXCHANGE_CONFIG" > /var/log/taler/secmod-cs.log 2>&1 &
CS_PID=$!
sleep 10  # give secmods time to generate initial denomination keys

# --- Exchange httpd ---
log "Starting taler-exchange-httpd (port 8081) ..."
taler-exchange-httpd -c "$EXCHANGE_CONFIG" > /var/log/taler/exchange.log 2>&1 &
EXCHANGE_PID=$!
wait_http "http://localhost:8081/config" "taler-exchange-httpd" 60

# ============================================================
# OFFLINE KEY CEREMONY (once, after exchange httpd is running)
# Chains: enable-account, wire-fee, global-fee, download, sign, upload
# ============================================================
if [[ ! -f $KEYS_FLAG ]]; then
  log "Running offline key ceremony ..."
  YEAR=$(date +%Y)

  for attempt in 1 2 3; do
    log "Key ceremony attempt $attempt ..."
    taler-exchange-offline -c "$EXCHANGE_CONFIG" \
      enable-account "payto://x-taler-bank/localhost:8080/exchange?receiver-name=Exchange" \
      wire-fee "$YEAR" x-taler-bank "${CURRENCY}:0" "${CURRENCY}:0" \
      global-fee "$YEAR" "${CURRENCY}:0" "${CURRENCY}:0" "${CURRENCY}:0" 1h 1y 0 \
      download \
      sign \
      upload \
      > /var/log/taler/key-ceremony.log 2>&1 \
      && { touch "$KEYS_FLAG"; log "Key ceremony complete."; break; } \
      || {
        warn "Key ceremony attempt $attempt failed:"
        cat /var/log/taler/key-ceremony.log
        [[ $attempt -lt 3 ]] && { log "Waiting 10s before retry ..."; sleep 10; }
      }
  done
  [[ -f $KEYS_FLAG ]] || warn "Key ceremony failed after 3 attempts — /keys may be incomplete."
fi

# --- Merchant httpd ---
log "Starting taler-merchant-httpd (port 8082) ..."
taler-merchant-httpd -c "$MERCHANT_CONFIG" > /var/log/taler/merchant.log 2>&1 &
MERCHANT_PID=$!
wait_http "http://localhost:8082/config" "taler-merchant-httpd"

# ============================================================
# CREATE DEFAULT MERCHANT INSTANCE (once)
# ============================================================
if [[ ! -f $INSTANCE_FLAG ]]; then
  log "Creating default merchant instance ..."
  HTTP_STATUS=$(curl -s -w "%{http_code}" -o /tmp/instance-resp.json \
    -X POST http://localhost:8082/management/instances \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer secret-token:sandbox-token" \
    -d "{
      \"id\": \"default\",
      \"name\": \"Sandbox Merchant\",
      \"payto_uris\": [\"payto://x-taler-bank/localhost:8080/merchant?receiver-name=Merchant\"],
      \"address\": {},
      \"jurisdiction\": {},
      \"use_stefan\": false,
      \"default_refund_delay\": {\"d_us\": 3600000000},
      \"default_wire_transfer_delay\": {\"d_us\": 7200000000},
      \"auth\": {\"method\": \"token\", \"token\": \"secret-token:sandbox-token\"}
    }" 2>/dev/null || echo 000)

  case "$HTTP_STATUS" in
    200|201|204) touch "$INSTANCE_FLAG"; log "Merchant instance created (HTTP $HTTP_STATUS)." ;;
    409)         touch "$INSTANCE_FLAG"; log "Merchant instance already exists (HTTP 409)." ;;
    *)  warn "Instance creation: HTTP $HTTP_STATUS"
        warn "Response: $(cat /tmp/instance-resp.json 2>/dev/null)"
        ;;
  esac
fi

# ============================================================
# STACK READY
# ============================================================
log ""
log "====== Taler sandbox stack READY ======"
log "  LibEufin Bank:    http://localhost:8080"
log "  Taler Exchange:   http://localhost:8081"
log "  Taler Merchant:   http://localhost:8082"
log "  Merchant token:   secret-token:sandbox-token"
log "  Master pub key:   $(cat $RUNTIME_DIR/master.pub 2>/dev/null || echo UNKNOWN)"
log ""
log "  Aggregator NOT running — fire with:"
log "    docker exec -it taler-sandbox taler-exchange-aggregator -c $EXCHANGE_CONFIG -t"
log ""
log "  Priority test:"
log "    docker exec -it taler-sandbox bash /scripts/06-adversarial-aggregation.sh"
log ""

# Keep alive; exit if any critical service dies
ALL_PIDS="$BANK_PID $EDDSA_PID $RSA_PID $CS_PID $EXCHANGE_PID $MERCHANT_PID"
declare -A PID_LABELS=(
  [$BANK_PID]=bank [$EDDSA_PID]=secmod-eddsa [$RSA_PID]=secmod-rsa
  [$CS_PID]=secmod-cs [$EXCHANGE_PID]=exchange [$MERCHANT_PID]=merchant
)
while true; do
  for pid in $ALL_PIDS; do
    if ! kill -0 "$pid" 2>/dev/null; then
      die "${PID_LABELS[$pid]:-pid=$pid} exited. Check /var/log/taler/${PID_LABELS[$pid]:-unknown}.log"
    fi
  done
  sleep 10
done
