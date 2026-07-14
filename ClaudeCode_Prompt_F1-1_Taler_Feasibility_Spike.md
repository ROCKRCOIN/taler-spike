# Claude Code Prompt — F1.1 Taler Escrow Feasibility Spike (Plan Mode / Investigation Only)

**Workstream:** Taler Atomic Escrow, milestone M1 groundwork — PRIVATE pre-submission work **Date:** July 2026 **Mode:** Investigation and report ONLY. No production code. No publication. No commits to any ROCKR repository.

---

## Context

I am preparing a grant proposal (NGI TALER open call, deadline 1 August 2026\) to build a free-software escrow layer on GNU Taler: a service exposing **hold / confirm-of-hold / release / reverse-on-timeout / dispute-hook** operations, composed from Taler's stock deposit and refund primitives, for use as the fiat leg of an atomic fiat↔digital-asset exchange.

This spike answers ONE question before submission: **can a conditional hold-and-release be composed from the stock GNU Taler merchant backend, without modifying Taler's core?**

This is a private feasibility study. Everything produced here stays local. Do not create any public repository, do not post to any forum, do not reference ROCKR or ROCKRCOIN in any artefact you create.

## Working environment

- Create and work entirely inside a NEW scratch directory: `~/Documents/"Git Hub"/taler-spike` (note the space in "Git Hub" — quote it in all shell commands). Do NOT touch `ROCKRLite-MVP` or any other existing repository.  
- Host is Windows; use Docker Desktop for the Taler stack. If any component resists Windows/Docker, document the friction precisely (it feeds the infrastructure decision) and fall back to a documented workaround rather than fighting it.  
- A local git repo in the scratch directory is fine for your own checkpointing. No remote.

## Phase 1 — Research (before touching Docker)

Read, in this order, and summarise what matters for the questions in Phase 3:

1. GNU Taler documentation (docs.taler.net): system overview; **merchant backend operator manual**; **merchant HTTP API reference** — especially order creation, payment status polling/webhooks, refunds (including `refund_deadline` semantics), and any payout/transfer mechanics.  
2. Taler exchange documentation as needed to understand: how settled deposits reach the merchant's bank account (aggregation/wire transfer timing), and what signed artefacts exist as proof of payment/deposit.  
3. Taler's **peer-to-peer payment (push/pull) capabilities** in wallet-core, if documented as stable — assess whether they offer an alternative release path to the merchant-account route.  
4. Any documentation of **KYC/AML threshold behaviour** on receivers.

Produce a short written summary of findings BEFORE proposing the sandbox plan. Stop and present the plan for approval before Phase 2\.

## Phase 2 — Sandbox (after plan approval)

Bring up a minimal local Taler stack via Docker (exchange, bank/libeufin, merchant backend) with a test currency. Document the exact bring-up as a runnable recipe (`SANDBOX.md` \+ compose file) — this becomes M2's F2.1 starting point later, so make it reproducible, but do not polish it.

Then exercise, with throwaway scripts only (any language; do not build a service):

1. Create an order; pay it with a test wallet; observe exactly when and how the merchant backend reports the deposit as settled.  
2. Execute a refund before the refund deadline; observe the payer-side result.  
3. Attempt a refund after the deadline; document the failure mode.  
4. Repeat/retry the same refund and status calls; document idempotency behaviour.  
5. Identify every signed artefact the operator could show a third party as **proof that funds are held** (deposit confirmations, order status, exchange signatures) and capture examples.  
6. If P2P push payments are available in the stack: exercise one, and note whether it could serve as the release-to-beneficiary leg.

## Phase 3 — Questions the report must answer

1. **Hold:** Can "funds are held" be established on stock components — i.e., payment settled to an escrow-operator merchant account with a refund window still open? What configuration controls the window's length, and what is its maximum?  
2. **Confirm-of-hold:** What cryptographic or API evidence can the operator hand the counterparty that the hold is real? Is it independently verifiable against the exchange, or only trust-the-operator?  
3. **Release:** What does releasing to the beneficiary actually map to? Candidate routes to assess: (a) operator's merchant account receives, then onward wire to the beneficiary via the bank layer; (b) P2P push payment to the beneficiary's wallet; (c) anything better the docs reveal. For each: custody implications (does the operator ever beneficially hold the funds?), latency, and failure modes.  
4. **Reverse:** Does the refund mechanism give a clean timeout-reversal path? What happens to the reversal guarantee if the refund deadline and the exchange's wire-aggregation timing interact badly (i.e., can money reach the operator's bank before the escrow window closes, and does that break refundability)? This interaction is the most likely place the whole composition fails — investigate it specifically.  
5. **KYC boundary:** At what points would receiver-side KYC thresholds trigger for (a) the operator and (b) the beneficiary, and are they configurable in a deployment?  
6. **Verdict:** One of — **composes cleanly on stock components** / **composes with stated caveats** / **requires upstream changes** (specify exactly which, and whether they are plausible upstream requests).

## Report format

A single `FINDINGS.md` in the scratch directory containing: Phase 1 summary; the sandbox recipe reference; numbered answers to the six questions with evidence (API responses, config excerpts); the verdict; a list of questions worth raising at the NLnet office hour on 29 July; and a revised confidence note on the \~185h estimate for the reference implementation (higher/lower/unchanged, and why).

## Rules

- Plan mode first: after Phase 1, stop and present the Phase 2 plan for approval before executing.  
- Read-only posture toward the outside world: no accounts created on public services, no posts, no issues filed upstream. If a question cannot be answered locally, list it as an open question rather than asking publicly.  
- Throwaway scripts stay throwaway: no abstractions, no service skeletons, no premature M2 work.  
- Time-box: if the stack bring-up exceeds one working session of effort, stop and report the friction rather than persisting — the friction finding is itself valuable (it decides the OVH-vs-local infrastructure question).

