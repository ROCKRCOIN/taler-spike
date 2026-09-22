# ROCKR × GNU Taler — F1.1 feasibility spike

A working sandbox and friction log for atomic escrow between a ROCKR settlement
and a GNU Taler payment: can a Taler payment and a ROCKR entitlement release be
made to succeed or fail together?

**Status (September 2026).** Sandbox running — PostgreSQL, LibEufin Bank, Taler
exchange and Taler merchant in one container; friction log FL-1 to FL-19 recorded;
findings in `FINDINGS.md`. This is a feasibility spike: exploratory, not production
code.

## What is here

- `SANDBOX.md` — how the sandbox is put together and the session walkthrough
- `FINDINGS.md` — what worked, what did not, and the friction log (FL-1–19)
- `docker-compose.yml`, `Dockerfile.sandbox` — the environment
- `scripts/` — session scripts, bind-mounted read-only into the container
- `results/` — outputs written from inside the container (session 06 is the latest)
- `ClaudeCode_Prompt_F1-1_Taler_Feasibility_Spike.md` — the brief the spike was run against

## Run

    docker compose build      # first build ~5–10 min: installs Taler packages from deb.taler.net
    docker compose up -d      # brings up the sandbox container and its database
    docker exec -it taler-sandbox bash /scripts/06-adversarial-aggregation.sh

Ports: bank 8080 · exchange 8081 · merchant 8082. Currency defaults to KUDOS
(`TALER_CURRENCY` in `docker-compose.yml`). The aggregator and transfer daemons
are deliberately not started by compose; script 06 fires them by hand to control
timing. On Windows this needs Docker Desktop 4.24 or later with the WSL2 backend.

Two things a reader should know first: the official Taler Docker images were
abandoned, so the sandbox installs Debian packages at build time; and the
exchange master key and flags persist in a named volume, so a clean run means
removing the volumes.

## Funding and provenance

This work is the subject of an application to the NGI TALER programme (NLnet
Foundation), reference 2026-08-0ed, made by ROCKR — David Clancy,
micro-entreprise, SIREN 383 374 873 (France). Nothing has been awarded; nothing
is payable by anyone unless it is. The repository is hosted in the ROCKRCOIN
organisation.

The spike was carried out with AI assistance (Claude
