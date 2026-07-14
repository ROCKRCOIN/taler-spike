# Taler Spike — Sandbox Setup & Adversarial Test Recipe

**Spike:** F1.1 Taler Escrow Feasibility  
**Phase:** 2 — Sandbox  
**Status:** Bring-up recipe (fill in Friction Log below during execution)

---

## Prerequisites

| Tool | Minimum version | Notes |
|---|---|---|
| Docker Desktop | 4.24 | WSL2 backend required (not Hyper-V) |
| WSL2 kernel | 5.15+ | Ships with Docker Desktop ≥ 4.24 |
| Available ports | 8080, 8081, 8082 | Check with `netstat -ano \| findstr :808` |
| Free disk | ~3 GB | Debian base + Taler packages |

> **Windows note:** Docker Desktop's WSL2 backend does not support systemd
> in containers. This compose file avoids systemd entirely — services run
> as background processes in the entrypoint. If a process dies silently,
> the health-loop in entrypoint.sh will exit and Docker will show the
> container as stopped.

---

## Stack Layout

```
taler-db         postgres:16     ports: (none exposed)
taler-sandbox    Debian trixie   ports: 8080 (bank), 8081 (exchange), 8082 (merchant)
```

Everything inside `taler-sandbox` communicates on `localhost`.  
The PostgreSQL DB is in a separate container reachable as `db` from the sandbox.

**Why single sandbox container?**  
The Taler exchange master key must be known before the merchant can be
configured (merchant config references the exchange's master public key).
Running everything in one container avoids the key-bootstrapping dance
across containers. For production: use the official sandcastle-ng approach
(single-container with systemd on Linux).

---

## Build & Start

```powershell
# From taler-spike/ directory on Windows host
docker compose build         # ~5–10 min first time (apt downloads)
docker compose up -d

# Watch initialisation (takes ~30–60 s after db is healthy)
docker compose logs -f sandbox
```

Healthy output ends with:
```
[HH:MM:SS] ====== Taler sandbox stack running ======
[HH:MM:SS]   LibEufin Bank:    http://localhost:8080
[HH:MM:SS]   Taler Exchange:   http://localhost:8081
[HH:MM:SS]   Taler Merchant:   http://localhost:8082
```

If you see `[WARN] Key ceremony had errors`, see §Friction → Key Ceremony below.

---

## Quick Smoke Test

```powershell
# Exchange is up and serving denominations
curl http://localhost:8081/keys | python -m json.tool | Select-String currency, master

# Bank is up
curl http://localhost:8080/config

# Merchant is up with default instance
curl http://localhost:8082/instances
```

---

## Running the Adversarial Test (Script 06 — PRIORITY)

```powershell
docker exec -it taler-sandbox bash /scripts/06-adversarial-aggregation.sh
```

Output lands in `./results/06/` on the host (volume-mounted).  
The verdict file is `results/06/verdict-<TIMESTAMP>.txt`.

**What the script does:**
1. Creates an order: `refund_deadline = 2 min`, `wire_deadline = 3 min`
2. Simulates wallet payment via `taler-wallet-cli`
3. Immediately fires `taler-exchange-aggregator -t` and `taler-exchange-transfer -t`
4. At T+~15s (well inside the 2-min window) attempts a refund
5. Prints a plain-text verdict with escrow implications

**Expected outcomes:**

| Outcome | Meaning |
|---|---|
| Refund HTTP 200/201 | Wire firing does NOT block refunds. Hold/reverse composes. |
| Refund HTTP 409 | Wire firing blocks refunds. Critical escrow failure mode. |

---

## Running the Other Scripts

```powershell
# All scripts run inside the container:
docker exec -it taler-sandbox bash /scripts/01-create-and-pay.sh
docker exec -it taler-sandbox bash /scripts/02-refund-before-deadline.sh
docker exec -it taler-sandbox bash /scripts/03-refund-after-deadline.sh
docker exec -it taler-sandbox bash /scripts/04-idempotency.sh <ORDER_ID>
docker exec -it taler-sandbox bash /scripts/05-artefact-capture.sh <ORDER_ID>
```

Scripts write to `./results/0N/` on the host.

---

## Credentials

| Service | Username | Password | Endpoint |
|---|---|---|---|
| Exchange | — | — | `http://localhost:8081` |
| Bank (exchange) | `exchange` | `exchangepw` | wire-gateway API |
| Bank (merchant) | `merchant` | `merchantpw` | revenue API |
| Bank (test user) | `testuser` | `testpw` | withdrawal API |
| Merchant management | — | `secret-token:sandbox-token` | Bearer token |

---

## Manual Aggregator Control

The aggregator is intentionally NOT running as a daemon:

```bash
# Inside container — fires aggregator once and exits
docker exec -it taler-sandbox \
  taler-exchange-aggregator -c /etc/taler/taler-exchange.conf -t

# Wire transfer (runs after aggregator prepares transfers)
docker exec -it taler-sandbox \
  taler-exchange-transfer -c /etc/taler/taler-exchange.conf -t
```

---

## Friction Log

*Running log from Phase 2 execution session (2026-07-14). Each entry is a
confirmed finding, not a hypothesis. Survives context compaction — a fresh
session can pick this up and continue.*

---

### FL-1 · Build succeeded cleanly ✓

`docker compose build` completed without errors. All packages resolved from
`deb.taler.net/apt/debian trixie main`.

**Installed versions (confirmed inside container):**

| Package | Version |
|---|---|
| `taler-exchange` | 1.6.6-0+trixie |
| `taler-exchange-offline` | 1.6.6-0+trixie (separate package — see FL-2) |
| `taler-exchange-database` | 1.6.6-0+trixie |
| `taler-merchant` | 1.6.9-0+trixie |
| `libeufin-bank` | 1.6.6-0+trixie |
| `taler-harness` | 1.6.4-0+trixie |
| `taler-wallet-cli` | 1.6.4-0+trixie |

Build time: ~5 minutes. No Windows/Docker Desktop issues at build stage.

---

### FL-2 · `taler-exchange-offline` is a SEPARATE package ✓ FIXED

**Finding:** `taler-exchange-offline` is NOT included in the `taler-exchange`
package. It is a separate Debian package: `taler-exchange-offline — air-gapped
signing tool for the GNU Taler exchange master key`.

**Fix applied:** Added `taler-exchange-offline` and `taler-exchange-database`
to the `apt-get install` line in `Dockerfile.sandbox`.

---

### FL-3 · Taler 1.6 config paths differ from our initial design ✓ FIXED

The packages install their own config trees. Original entrypoint used
`/etc/taler/` for everything. Corrected to use:

| Service | Config root | Main file |
|---|---|---|
| Exchange | `/etc/taler-exchange/` | `taler-exchange.conf` |
| Merchant | `/etc/taler-merchant/` | `taler-merchant.conf` |
| LibEufin Bank | `/etc/libeufin/` | `libeufin-bank.conf` |

Config is modified at runtime by `taler-exchange-config -r` and
`taler-merchant-config -r` (both support `-s SECTION -o OPTION -V VALUE -r`).

The exchange config uses GNUnet's `@inline-matching@ conf.d/*.conf` and
`@inline-secret@` directives. These are NOT the same as our original `@INLINE@`
but work correctly with the package paths.

**The Manual Aggregator Control section above still references the OLD path**
`/etc/taler/taler-exchange.conf` — use `/etc/taler-exchange/taler-exchange.conf`
in all commands until that section is updated.

---

### FL-4 · Exchange default SERVE=unix; must override to tcp ✓ FIXED

Package default config has `SERVE = unix` (Unix domain socket).
The merchant package default has `SERVE = systemd`.

Both overridden in entrypoint v2 via `-r` flag:
```bash
taler-exchange-config -c /etc/taler-exchange/taler-exchange.conf \
  -r -s exchange -o SERVE -V tcp
taler-merchant-config -c /etc/taler-merchant/taler-merchant.conf \
  -r -s merchant -o SERVE -V tcp
```

---

### FL-5 · `taler-exchange-offline` ceremony: corrected subcommand sequence ✓

**The `sign-denomination`, `sign-wire-accounts`, and `enable-denomination`
subcommands DO NOT EXIST in v1.6.** Full supported subcommand list (confirmed):

```
setup                — generate master key; prints public key to stdout
download             — fetch unsigned future keys from running exchange
show                 — display downloaded keys for human review
sign                 — sign downloaded keys with master key
revoke-denomination  — revoke a denom key by hash
revoke-signkey       — revoke an online signing key
enable-auditor       — enable an auditor
disable-auditor      — disable an auditor
enable-account       — sign and register wire account (payto URI as arg)
disable-account      — disable wire account
wire-fee             — sign wire fees (YEAR METHOD WIRE-FEE CLOSING-FEE)
global-fee           — sign global fees (YEAR HIST-FEE ACCT-FEE PURSE-FEE
                       PURSE-TIMEOUT HISTORY-EXPIRATION PURSE-ACCOUNT-LIMIT)
drain                — drain profits to operator account
add-partner          — P2P exchange partner registration
aml-enable/disable   — AML staff management
upload               — upload signed artifacts to running exchange
```

**Correct ceremony sequence** (all in one invocation after exchange httpd is up):
```bash
taler-exchange-offline -c /etc/taler-exchange/taler-exchange.conf \
  enable-account "payto://x-taler-bank/localhost:8080/exchange" \
  wire-fee $(date +%Y) x-taler-bank KUDOS:0 KUDOS:0 \
  global-fee $(date +%Y) KUDOS:0 KUDOS:0 KUDOS:0 1h 1y 0 \
  download \
  sign \
  upload
```

**Master key:** `taler-exchange-offline setup` prints the public key to stdout.
Private key stored at `/var/lib/taler-exchange/offline/master.priv`.

---

### FL-6 · Exchange needs secmod helpers started BEFORE httpd ✓ FIXED

The exchange httpd in v1.6 delegates all signing to three helper processes:
- `taler-exchange-secmod-eddsa` — online signing keys
- `taler-exchange-secmod-rsa` — RSA denomination keys
- `taler-exchange-secmod-cs` — CS (Blind Schnorr) denomination keys

These must be started first and given ~3s to generate initial key material
before the httpd starts. Entrypoint v2 starts them in this order.

---

### FL-7 · `psql` needs `-d postgres` to avoid "database taler does not exist" ✗ NOT YET FIXED IN CODE

**Finding (confirmed by running test):** The Docker Compose PostgreSQL image
creates user `taler` with password `taler` and default DB `postgres`.  
`psql -h db -U taler` without `-d` tries to connect to a DB named `taler`
(same as username) which does NOT exist → `FATAL: database "taler" does not exist`.

All CREATE DATABASE commands in `entrypoint.sh` must add `-d postgres`:
```bash
# WRONG:
psql -h "$PGHOST" -U "$PGUSER" -c "CREATE DATABASE bank;"
# CORRECT:
psql -h "$PGHOST" -U "$PGUSER" -d postgres -c "CREATE DATABASE bank;"
```

**This is the root cause of the current bring-up failure.** Until fixed, all
three databases (exchange, merchant, bank) fail to be created, causing all
downstream dbinit calls to fail.

**Status: needs one-line fix in entrypoint.sh before next run.**

---

### FL-8 · LibEufin bank connection URL — JDBC vs libpq, status PARTIALLY CONFIRMED

**Finding:** `libeufin-bank` is a JVM/Kotlin application. It may use JDBC
rather than the C libpq library for PostgreSQL connections. The `CONFIG` value
in `[LIBEUFIN-BANKDB-POSTGRES]` is:

- Default (from package): `postgres:///libeufin` (local socket, relies on env vars)
- What we wrote: `postgres://taler:taler@db:5432/bank`

The libeufin dbinit error was "The connection attempt failed.: taler:taler@db".
DNS resolution confirmed working (`db` → `172.19.0.2`). The failure is likely
because the `bank` database did not exist (FL-7 was root cause), NOT because
of a URL format issue.

**Hypothesis to verify next run:** Once FL-7 is fixed and the `bank` DB exists,
`postgres://taler:taler@db:5432/bank` may work correctly. If it still fails,
fall back to JDBC format: `jdbc:postgresql://db:5432/bank?user=taler&password=taler`.

**Also try:** `postgres:///bank` with `PGHOST=db PGPORT=5432 PGUSER=taler
PGPASSWORD=taler` set in the compose env — libpq picks up these env vars and
libeufin may forward them.

**Status: VERIFY on next run after FL-7 fix.**

---

### FL-9 · LibEufin requires `WIRE_TYPE = x-taler-bank` ✓ FIXED IN ENTRYPOINT

**Finding:** libeufin-bank emits this warning without the setting:
> `Missing payment target type option 'wire_type' in section 'libeufin-bank'
> defaulting to 'iban' but will fail in a future update`

For our x-taler-bank setup (not IBAN), the config must include:
```ini
[libeufin-bank]
WIRE_TYPE = x-taler-bank
```

Added to the `cat > "$BANK_CONFIG"` block in entrypoint v2.

---

### FL-10 · `taler-harness deployment provision-bank-account` replaces JSON create-account ✓

**Finding:** `libeufin-bank create-account` takes a JSON body. The sandcastle
uses `taler-harness deployment provision-bank-account` instead, which calls the
bank's REST API. This is the correct tool for our setup.

**Confirmed syntax:**
```bash
taler-harness deployment provision-bank-account \
  "http://localhost:8080/" \
  --exchange --login exchange --name "Taler Exchange" --password exchangepw

taler-harness deployment provision-bank-account \
  "http://localhost:8080/" \
  --login merchant --name "Test Merchant" --password merchantpw

taler-harness deployment provision-bank-account \
  "http://localhost:8080/" \
  --login testuser --name "Test User" --password testpw
```

The `--exchange` flag marks the account as `is_taler_exchange=true`, enabling
the wire-gateway API at `/accounts/exchange/taler-wire-gateway/`.

**VERIFY on next run:** whether provision-bank-account handles a 409 (already
exists) gracefully or errors out — entrypoint catches `|| warn`.

---

### FL-11 · `taler-wallet-cli api` uses POSITIONAL operation argument ✓ FIXED IN SCRIPTS

**Finding:** In v1.6.4, the wallet CLI API takes the operation name as a
positional argument, NOT as a JSON `op` field.

```bash
# WRONG (original scripts):
taler-wallet-cli api '{"op":"addExchange","request":{...}}'

# CORRECT (v1.6.4):
taler-wallet-cli api addExchange '{...}'
```

All six scripts updated to use the positional form.

**Also required:** `--no-http` flag (in addition to `--no-throttle`) for
plain HTTP exchanges (our local exchange is http://, not https://).

**VERIFY on next run:** exact operation name for accepting a withdrawal.
Script 06 tries `acceptBankIntegratedWithdrawal` first, then falls back to
`acceptWithdrawal`. The correct name needs to be confirmed and hardcoded.

---

### FL-12 · `AGGREGATOR_IDLE_SLEEP_INTERVAL` confirmed in default config ✓

**Finding:** From `/usr/share/taler-exchange/config.d/exchange.conf`:
```
AGGREGATOR_IDLE_SLEEP_INTERVAL = 60 s
WIREWATCH_IDLE_SLEEP_INTERVAL  = 1 s
TRANSFER_IDLE_SLEEP_INTERVAL   = 60 s
```

These are the daemon sleep intervals when idle. The `-t` flag on both
`taler-exchange-aggregator` and `taler-exchange-transfer` overrides this and
makes them run once then exit — this is the mechanism for the adversarial test.

**Confirmed:** The aggregator CAN be triggered manually and deterministically
via `-t`, giving us exact control over timing in the adversarial test.

---

### FL-13 · Merchant config needs AUTH_TOKEN in secrets/merchant.conf

**Finding:** The merchant auth token for the management API (`/management/instances`)
is set in `/etc/taler-merchant/secrets/merchant.conf`:
```ini
[merchant]
AUTH_TOKEN = secret-token:sandbox-token
```

The bearer token used in `Authorization: Bearer secret-token:sandbox-token`
must match this value. Entrypoint v2 writes this file.

**VERIFY on next run:** whether the management API requires this token or is
open by default in dev builds.

---

### FL-14 · `taler-exchange-offline` `wire-fee` argument format ✓

**Confirmed syntax** (from error message):
```
wire-fee YEAR METHOD WIRE-FEE CLOSING-FEE
```
Example: `wire-fee 2026 x-taler-bank KUDOS:0 KUDOS:0`

**`global-fee` argument format** (from error message):
```
global-fee YEAR HISTORY-FEE ACCOUNT-FEE PURSE-FEE PURSE-TIMEOUT
           HISTORY-EXPIRATION PURSE-ACCOUNT-LIMIT
```
Example: `global-fee 2026 KUDOS:0 KUDOS:0 KUDOS:0 1h 1y 0`

---

### FL-15 · Key ceremony vs. `/keys` chicken-and-egg — FIXED

**Problem:**  
`wait_http` was polling `http://localhost:8081/keys`. But the exchange refuses to
generate a valid `/keys` response until wire accounts are uploaded by the key
ceremony (`enable-account … upload`). And the key ceremony can only run after
`wait_http` clears. Deadlock: `/keys` needs the ceremony; the ceremony waits for
`/keys`.

**Secondary complication:**  
Even after switching to `/config` (which the httpd serves immediately), on the
very first boot the exchange httpd took >60 seconds to bind its port. Root cause:
`secmod-rsa` must generate RSA 2048-bit denomination keys for all 14 coin types
before the httpd accepts connections, and key generation took ~75s in the container.

**Fix applied (entrypoint.sh):**

1. Changed `wait_http` target from `/keys` to `/config`:
   ```bash
   # Before:
   wait_http "http://localhost:8081/keys" "taler-exchange-httpd"
   # After:
   wait_http "http://localhost:8081/config" "taler-exchange-httpd" 60
   ```
   `/config` responds 200 once the httpd is listening, regardless of whether
   wire accounts or denominations are uploaded.

2. Increased retries from default 30 (60 s) to 60 (120 s) to cover RSA key
   generation time on first boot.

3. Added retry loop (3 attempts, 10 s apart) around the key ceremony itself
   in case secmods are still generating keys when `download` is first called.

**Verification:**  
After fix, `curl http://localhost:8081/keys` returns `"denominations": [14 items]`
and `"wire_fees": {"x-taler-bank": [...]}`. Key ceremony log shows clean exit.

---

### FL-16 · Merchant instance has no bank accounts attached

**Symptom:**  
`POST /instances/default/private/orders` returns error 2500:
`"The merchant instance has no active bank accounts configured."`  
This happens even though the instance was created with `"payto_uris": [...]`.

**Root cause:**  
In taler-merchant 1.6, the `payto_uris` field in `POST /management/instances`
does **not** attach bank accounts. Bank accounts must be registered separately via
a dedicated endpoint after instance creation.

**Fix to apply in entrypoint.sh** (inside the `INSTANCE_FLAG` block, after the
instance is successfully created):

```bash
# Add bank account to default merchant instance
ACCT_STATUS=$(curl -s -w "%{http_code}" -o /tmp/acct-resp.json \
  -X POST http://localhost:8082/management/instances/default/accounts \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer secret-token:sandbox-token" \
  -d "{
    \"payto_uri\": \"payto://x-taler-bank/localhost:8080/merchant?receiver-name=Merchant\",
    \"credit_facade_url\": \"http://localhost:8080/accounts/merchant/taler-wire-gateway/\",
    \"credit_facade_credentials\": {
      \"type\": \"basic\",
      \"username\": \"merchant\",
      \"password\": \"merchantpw\"
    }
  }" 2>/dev/null || echo 000)
log "Merchant bank account registration: HTTP $ACCT_STATUS"
```

**Note:** The exact JSON payload above was not empirically confirmed — the
`credit_facade_*` fields are inferred from taler-merchant 1.6 source/docs. If
they are wrong, try omitting `credit_facade_credentials` first (basic auth may be
automatic for x-taler-bank), then try without `credit_facade_url` (merchant may
discover it from the payto_uri). Check `/tmp/acct-resp.json` for error details.

**Auth prerequisite:** FL-17 must be applied first — the management endpoint
returns 2015 if `AUTH_TOKEN` is not set.

---

### FL-17 · Merchant management AUTH_TOKEN not set in config

**Symptom:**  
`GET /management/instances` and `POST /management/instances/default/accounts`
return HTTP 2015: `"The merchant refused the request due to lack of authorization."`
The merchant log shows: `"Credentials provided are 0 which are insufficient for
access to 'instances-write'"`.

**Root cause:**  
The secrets-file approach (`/etc/taler-merchant/secrets/merchant.conf`) was used
to set `AUTH_TOKEN`, but taler-merchant 1.6 package config does not include that
secrets directory — the same failure mode as the exchange DB config (FL-7/FL-8).
Result: the `[merchant]` section has no `AUTH_TOKEN`, so the management API has
no trusted token and rejects all management calls.

**Fix to apply in entrypoint.sh** (in the merchant config section, replace the
secrets-file block):

```bash
# Before (not working — secrets file not included by package config):
cat > /etc/taler-merchant/secrets/merchant.conf <<EOF
[merchant]
AUTH_TOKEN = secret-token:sandbox-token
EOF

# After (sets token directly in the package config):
mconf merchant AUTH_TOKEN "secret-token:sandbox-token"
```

**Order of application:** Apply FL-17 before FL-16 in the entrypoint. The
`mconf` call writes to `/etc/taler-merchant/taler-merchant.conf` at init time,
before the merchant httpd starts, so the token is active when the accounts
endpoint is called.

---

### Next Session: Minimal Fix Checklist

**Status as of end of session 2:** Stack boots cleanly on first cold start
(FL-7 through FL-15 all resolved and applied). `curl http://localhost:8081/keys`
returns 14 denominations and x-taler-bank wire fees. Merchant instance "default"
is created (HTTP 204). The **only two remaining fixes** before script 06 can run:

1. **FL-17 first** — replace the `secrets/merchant.conf` block with:
   ```bash
   mconf merchant AUTH_TOKEN "secret-token:sandbox-token"
   ```
   in the merchant config section of `sandbox/entrypoint.sh` (around line 190,
   in the `if [[ ! -f $INIT_FLAG ]]` block).

2. **FL-16 second** — add the bank account registration curl call inside the
   `if [[ ! -f $INSTANCE_FLAG ]]` block (around line 295), immediately after the
   `case "$HTTP_STATUS" in 200|201|204)` success branch. Use the payload shown
   in FL-16 above; adjust if the fields are wrong by inspecting
   `/tmp/acct-resp.json` in the running container.

3. **Rebuild:** `docker compose down -v && docker compose build && docker compose up -d`

4. **Verify merchant has accounts:**
   ```bash
   docker exec taler-sandbox bash -c "curl -s \
     http://localhost:8082/management/instances/default/accounts \
     -H 'Authorization: Bearer secret-token:sandbox-token'"
   ```

5. **Run script 06:**
   ```bash
   docker exec taler-sandbox bash -c "bash /scripts/06-adversarial-aggregation.sh"
   ```
   Verdict is in `/results/06/verdict-*.txt`.

### Windows Port Conflicts
If `docker compose up` fails with port-in-use errors:
- 8080 is commonly taken by IIS or other services.
- Change port mappings in `docker-compose.yml` (host side only — container side stays the same).

---

## Stopping and Cleaning Up

```powershell
docker compose down          # stops containers, keeps volumes
docker compose down -v       # wipes volumes (forces re-initialization next time)
docker rmi taler-spike-sandbox   # removes the built image
```

---

## Architecture Notes for FINDINGS.md

The key architectural choice that this sandbox exercises:

> `taler-exchange-aggregator` has a `-t` (test/one-shot) flag that causes it
> to process all pending deposits and exit. This means aggregation timing is
> **fully controllable in a test environment**: you can trigger it 1 second
> after payment, which is impossible in production but lets us empirically
> determine whether the exchange's refund logic is wire-status-aware or
> purely deadline-aware.

If the exchange checks wire status before allowing refunds, this matters
in production because:
- A high-volume merchant may trigger aggregation very quickly
- The `default_wire_transfer_delay` can be set to `> refund_deadline` in
  config, but the aggregator *may* fire early if enough deposits accumulate
- Need to verify: does the exchange batch by wall-clock time, or by count?
