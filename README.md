# ROCKR × GNU Taler — F1.1 feasibility spike

A sandbox and friction log for one empirical question about atomic escrow
between a ROCKR settlement and a GNU Taler payment: **if the Taler exchange's
aggregator fires before an order's refund deadline, does the refund still go
through?** — that is, is Taler's refund logic wire-status-aware or purely
deadline-aware. The answer decides whether a ROCKR entitlement release and a
Taler payment can be made to succeed or fail together without upstream changes.

**Status (last session 15 July 2026): BLOCKED — verdict inconclusive.** The
adversarial aggregation test (script 06) has not yet run. Order creation fails
upstream of payment, aggregation and refund (FL-19, unresolved), so none of the
three anticipated verdicts — composes cleanly / composes with caveats / requires
upstream changes — can be given. Nothing found so far is evidence of a defect in
Taler; every blocker to date has been a bring-up or configuration issue in our
own sandbox.

## What is confirmed working

- The Taler exchange (`taler-exchange-httpd`) is healthy and serves `/keys` with
  valid denominations and signing keys (verified by `curl` inside the container).
- Bank, merchant authentication and merchant account registration all work
  (FL-16, FL-17 fixed this session).
- The merchant now targets the local sandbox exchange rather than the public
  demo exchanges (FL-18 fixed; root cause was a wrong config key in
  `entrypoint.sh`).

## What is blocked

**FL-19.** Order creation returns HTTP 451 (code 2513, "exceeds hard legal
transaction limits") because the merchant httpd cannot download `/keys` from the
local exchange over plain HTTP — the same URL that returns a valid `/keys` when
curled directly. IPv4/IPv6 mismatch and startup-order backoff have been ruled
out; an HTTPS-only trust default in the merchant's HTTP client is suspected but
not confirmed (the libcurl error code has not been surfaced). Details and next
steps in `SANDBOX.md` under FL-19. This looks like a narrow configuration fix,
not a structural problem.

## What is here

- `FINDINGS.md` — verdict, what was fixed, what remains blocked, recommendation
- `SANDBOX.md` — how the sandbox is put together; the friction log FL-1–19 with
  root causes, evidence and diffs
- `docker-compose.yml`, `Dockerfile.sandbox` — the environment (PostgreSQL,
  LibEufin Bank, Taler exchange and merchant in one container)
- `scripts/` — session scripts, bind-mounted read-only into the container
- `results/` — outputs written from inside the container (session 06 latest)
- `ClaudeCode_Prompt_F1-1_Taler_Feasibility_Spike.md` — the brief the spike
  was run against

## Run

    docker compose build      # first build ~5–10 min: installs Taler packages from deb.taler.net
    docker compose up -d      # brings up the sandbox container and its database
    docker exec -it taler-sandbox bash /scripts/06-adversarial-aggregation.sh   # currently fails at FL-19

Ports: bank 8080 · exchange 8081 · merchant 8082. Currency defaults to KUDOS
(`TALER_CURRENCY` in `docker-compose.yml`). The aggregator and transfer daemons
are deliberately not started by compose; script 06 fires them by hand with `-t`
to control timing. The official Taler Docker images have been abandoned, so the
sandbox installs Debian packages at build time. On Windows this needs Docker
Desktop 4.24 or later with the WSL2 backend.

## Next step

A session on FL-19 alone. Once order creation succeeds, script 06 is
immediately runnable and `FINDINGS.md` gets a real verdict: the refund's actual
HTTP status (200/201 or 409) when the aggregator has already fired.

## Funding and provenance

This work is the subject of an application to the NGI TALER programme (NLnet
Foundation), reference 2026-08-0ed, made by ROCKR — David Clancy,
micro-entreprise, SIREN 383 374 873 (France). Nothing has been awarded; nothing
is payable by anyone unless it is. The repository is hosted in the ROCKRCOIN
organisation.

The spike was carried out with AI assistance (Claude Code) under written
prompts; each session's findings were checked by the author against the running
sandbox.

## Licence

Apache License 2.0 — see `LICENSE` and `NOTICE`. Part of the ROCKR programme:
rockrcoin.org · rockrprooflabs.org
