# ROCKR × GNU Taler — F1.1 feasibility spike

A working sandbox and friction log for atomic escrow between a ROCKR settlement
and a GNU Taler payment: can a Taler payment and a ROCKR entitlement release be
made to succeed or fail together?

**Status (September 2026).** Sandbox running (exchange, merchant, wallet CLI, in
Docker); friction log FL-1 to FL-19 recorded; findings in `FINDINGS.md`. This is
a feasibility spike — exploratory, not production code.

## What is here

- `SANDBOX.md` — how the sandbox is put together and how to bring it up
- `FINDINGS.md` — what worked, what did not, and the friction log (FL-1–19)
- `docker-compose.yml`, `Dockerfile.sandbox`, `scripts/`, `sandbox/` — the environment
- `results/` — session outputs
- `ClaudeCode_Prompt_F1-1_Taler_Feasibility_Spike.md` — the brief the spike was run against

## Run

    docker compose up   # see SANDBOX.md for the session walkthrough

## Funding and provenance

This work is the subject of an application to the NGI TALER programme
(NLnet Foundation), reference 2026-08-0ed, made by ROCKR — David Clancy,
micro-entreprise, SIREN 383 374 873 (France). Nothing has been awarded;
nothing is payable by anyone unless it is. The repository is hosted in the
ROCKRCOIN organisation.

The spike was carried out with AI assistance (Claude Code) under written
prompts; each session's findings were checked by the author against the
running sandbox.

## Licence

Outputs are released under a free and open licence (Apache License 2.0 — see
`LICENSE`). Part of the ROCKR programme: rockrcoin.org · rockrprooflabs.org
