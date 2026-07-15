# Taler Spike — F1.1 Escrow Feasibility: Findings

**Spike:** F1.1 Taler Escrow Feasibility
**Phase:** 2 — Sandbox
**Date:** 2026-07-15
**Status:** BLOCKED — critical test (script 06) did not run

---

## Verdict

**INCONCLUSIVE — sandbox blocked before the adversarial aggregation test could execute.**

None of the three anticipated verdict categories (composes cleanly / composes
with caveats / requires upstream changes) apply yet, because the empirical
question — *does `taler-exchange-aggregator` firing before `refund_deadline`
block the refund?* — was never reached. Order creation itself fails, which
is a step upstream of payment, aggregation, or refund.

This is **not** evidence of an upstream Taler defect. All blockers found so
far are sandbox bring-up/configuration issues in our own `entrypoint.sh`, not
in Taler's exchange/merchant logic. The exchange itself (`taler-exchange-httpd`)
is confirmed healthy and correctly serving `/keys` with valid denominations
and signing keys (verified via direct `curl` from inside the container).

---

## What was fixed this session

1. **FL-17** — merchant `AUTH_TOKEN` wasn't taking effect (wrong config
   mechanism: secrets-file approach doesn't work in the 1.6 package layout).
   Fixed via `mconf merchant AUTH_TOKEN ...` writing directly to the package
   config. Confirmed: management API now accepts the bearer token.

2. **FL-16** — bank account registration used a nonexistent management
   endpoint (`/management/instances/default/accounts` → HTTP 404). The
   payload was correct; only the path was wrong. Corrected to the private
   API path (`/instances/default/private/accounts`). Confirmed: HTTP 200,
   account appears in `GET /instances/default/private/accounts`.

3. **FL-18** — merchant was validating orders against the *production/demo*
   Taler exchanges (`exchange.demo.taler.net`, `exchange.taler-ops.ch`)
   instead of the local sandbox exchange. Root cause: `entrypoint.sh` wrote
   the trusted-exchange override using the wrong config key (`URL` instead
   of `EXCHANGE_BASE_URL`), so the package's built-in demo-exchange default
   was never overridden. Fixed and confirmed: the merchant now targets
   `http://localhost:8081/` (visible in `exchange_rejections` after the fix).

Full root-cause detail, evidence, and exact diffs for each are in
`SANDBOX.md` under the Friction Log.

## What remains blocked

**FL-19 (unresolved, investigated over two sessions)** — even after FL-18,
order creation still fails (HTTP 451, code 2513: "exceeds hard legal
transaction limits"). The merchant's own log shows it cannot download
`/keys` from the local exchange (`Failed to download
http://localhost:8081/keys`), despite that exact URL returning a valid,
well-formed `/keys` response when curled directly from inside the same
container. The failure is therefore in the merchant httpd's outbound HTTP
client behavior toward a plain-HTTP (non-TLS) local exchange, not in the
exchange itself.

Two cheap hypotheses were tested and **ruled out**: IPv4/IPv6 resolution
mismatch (exchange binds both stacks; manual curl succeeds over both; a
live-patched `127.0.0.1` config still fails identically) and startup-order
backoff (fresh merchant restarts against a long-healthy exchange fail
immediately and consistently across 2 minutes of polling). A third
hypothesis — the merchant defaulting to HTTPS-only trust, the same pattern
seen with the wallet CLI's `--no-http` requirement (FL-11) — is **not
confirmed but also not refuted**: the same underlying HTTP client library
successfully fetched `/keys` from this same plain-HTTP URL during the key
ceremony (FL-5), which argues against a blanket restriction, but the actual
libcurl-level error code was not obtained (debug/verbose logging attempts
did not surface it). Full diagnostic detail and next steps are in
`SANDBOX.md` under FL-19.

---

## Architecture note (unchanged, still the key question for next session)

> `taler-exchange-aggregator -t` gives full manual control over aggregation
> timing in a test environment, which is what makes it possible to
> empirically determine whether the exchange's refund logic is
> wire-status-aware or purely deadline-aware. This is still the central
> question script 06 is designed to answer — it simply hasn't run yet.

---

## Recommendation

Continue Phase 2 in a follow-up session focused solely on FL-19 (merchant →
exchange `/keys` fetch failure over plain HTTP). This looks like a narrow,
mechanical fix (config flag or URL scheme issue) rather than a structural
problem — the exchange, bank, and merchant auth/account plumbing are all
independently confirmed working. Once FL-19 is resolved, script 06 should be
immediately runnable and this document should be updated with the actual
refund HTTP status (200/201 vs 409) and a real verdict.
