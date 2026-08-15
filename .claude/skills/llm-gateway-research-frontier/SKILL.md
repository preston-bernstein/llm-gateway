---
name: llm-gateway-research-frontier
description: >
  Load this skill when proposing new capabilities for llm-gateway, evaluating
  "should we build X" for this stack, writing ANYTHING public about this project
  (README claims, blog posts, repo descriptions, resume lines), or designing an
  experiment/spike against the gateway. Covers three merged areas: external
  positioning (what this repo genuinely is vs. what must not be oversold), the
  open-problem inventory (observability, in-gateway cascade, health-aware
  routing, RunPod MID tier, claude-cli-server hardening), and the research
  methodology / evidence bar for adopting any conclusion here. Also load before
  labeling anything "novel", "implemented", or "production-ready" in prose
  about this project.
---

# llm-gateway — Research Frontier, Methodology, and External Positioning

**Scope note:** this one skill merges three categories — research-frontier
(open problems), research-methodology (evidence bar), and external-positioning
(honest public claims). For a repo this small (4 commits, config + scripts +
docs, no application code), splitting them into three skills would create more
cross-reference overhead than content. They live together here deliberately.

**Audience:** a zero-context engineer or Claude session deciding what to build
next, what to claim publicly, or how to run an experiment against this stack.
Volatile facts below are date-stamped **2026-07-02**. Anything not yet proven
is labeled **CANDIDATE** or **OPEN** — treat those labels as binding.

---

## Part 1 — External positioning: what is genuinely here

### What this repo IS (safe to claim)

- A **clean, hardened deployment of LiteLLM** (v1.90.1 live as of 2026-07-02)
  as a systemd service: dedicated nologin service user, `ProtectSystem=strict`,
  `ProtectHome=true`, `PrivateTmp=true`, secrets isolated in a root-only
  `EnvironmentFile`, no secrets in git. One OpenAI-compatible endpoint
  (`:4000`) fronting Gemini, Claude, and local Ollama models via a resource
  broker.
- A **FrugalGPT-style tier CONTRACT** (`ROUTING.md`). FrugalGPT here means
  Chen/Zaharia/Zou 2023 — the LLM-cascade cost-reduction paper: try cheap
  models first, escalate past a quality gate only on failure. This repo adopts
  the paper's *tiering economics* as a shared vocabulary (LOCAL / FAST / MID /
  FRONTIER) that services agree on.
- A working **install story**: `scripts/install.sh` creates the user, venv,
  config, env file, and unit in one root-only run.

### What this repo is NOT (never claim these)

| Overclaim | Reality (2026-07-02) |
|---|---|
| "Implements FrugalGPT" | It does NOT implement FrugalGPT's learned router/scorer. There is no learned component anywhere. Services hand-roll their own cascade policy (reference: algo-factory's `ModelRouter`). The gateway owns only the model catalog and auth translation. Say "FrugalGPT-style tier contract", never "FrugalGPT implementation". |
| "Every call is logged with cost/tokens/latency" | FALSE today. There is ZERO spend/usage logging. `database_url` was removed because DB-backed logging needs the prisma client (Incident 1 — see llm-gateway-failure-archaeology). The README "Spend tracking" section and the logging sentence in ROUTING.md are STALE. Do not repeat them in anything public until Open Problem A is closed. |
| "Production-ready subscription-wrapper for Claude" | The claude-cli-server pattern (below) is live but unversioned, runs as the wrong user, and has sharp edges. Not claimable as a deliverable. |
| "Tested / CI'd" | No tests, no CI, no build system. "Testing" = curl smoke checks + `journalctl`. |

### The one novel-ish thing — and why it is not yet claimable

The **claude-cli-server subscription-wrapper pattern**: routing an
OpenAI-compatible proxy (LiteLLM) at a local FastAPI shim that wraps the
`claude` CLI, so `claude-*` model names resolve against a Claude subscription
instead of API-key billing. Pointing a standard proxy at a CLI wrapper is a
genuinely interesting deployment trick and worth writing up honestly — but as
of 2026-07-02 it fails the evidence bar on every axis:

- **Unversioned**: `/opt/claude-cli-server/server.py` lives on the desktop
  with no repo of its own; it is not in this repo either (it is a live-only
  overlay — see llm-gateway-architecture-contract for the drift picture).
- **Wrong user**: runs as `User=preston`, violating the house rule that all
  desktop services run under dedicated nologin service users.
- **Sharp edges** (full shim contract: litellm-routing-reference §5): 60–120 s
  floor latency even on trivial prompts; silent fable→sonnet aliasing; the
  streaming path has **no timeout at all**; sustained use self-rate-limits
  the shared subscription.

**Rule: no external claim about this pattern until Open Problem E is done and
the result reproduces.** Writing it up in a private note is fine; publishing
requires the fix-first discipline below.

### Reproducibility standard for ANY external claim

Nothing about this project is claimable in public until a **fresh-machine
install via `scripts/install.sh` reaches the golden checklist** defined in
llm-gateway-validation-and-qa. "It works on the current live box" does not
count — the live box carries hand-edited config drift (see
llm-gateway-architecture-contract). A claim is real when a stranger can clone,
install, and verify it.

---

## Part 2 — Open problems inventory

Summary table; each problem gets a full entry below. Status labels:
**OPEN** = problem confirmed, no adopted solution. **CANDIDATE** = a proposed
mechanism, unverified. Adoption of any solution goes through
llm-gateway-change-control.

| # | Problem | Why current state fails | This project's specific asset | Result when… |
|---|---|---|---|---|
| A | Spend/usage observability | ZERO logging exists; README spend section is false | Single choke point for ALL LLM traffic; SQLite-friendly single host | Every request in a queryable store with model/tokens/latency/cost; README spend section true again |
| B | In-gateway cascade/verifier | Every service re-implements escalation | Gateway already owns the catalog; one reference implementation exists to compare against | One service deletes its cascade code with equal-or-better quality-gate outcomes, measured |
| C | Latency/health-aware routing & fallbacks | Static routing → 300 s deaths when a backend stalls | Broker GPU contention + :4002 slowness make the failure visible and inducible on demand | Induced :4002 outage degrades claude-* calls to a defined fallback instead of 300 s deaths, demonstrated |
| D | Activate RunPod MID tier | MID tier is half-real: template commented out | Template already written in config.yaml; tier contract already names it | `runpod/qwen2.5-72b` passes the smoke checklist at declared cost |
| E | Harden claude-cli-server | Unversioned, wrong user, no streaming timeout | The pattern already works end-to-end in production traffic | It passes the same install/verify discipline as the gateway itself |

### A. Restore spend/usage observability

- **Why current state fails:** `database_url` was dropped from config.yaml
  after it broke startup (Incident 1 — full story:
  llm-gateway-failure-archaeology), trading a startup failure for total
  observability blindness. `/var/lib/litellm/` contains only home-dir
  skeleton dotfiles, no `litellm.db` (verified 2026-07-02);
  `config/config.example.yaml` STILL carries the bad line.
- **This project's asset:** the gateway is a single choke point — every LLM
  call in the whole home-lab stack already flows through :4000, so one fix
  observes everything. And it is a single Linux host, ideal for SQLite.
- **First three steps in this repo:**
  1. Read Incident 1 in llm-gateway-failure-archaeology so you don't re-break
     startup the same way.
  2. **CANDIDATE path 1 — install prisma properly:** verify against LiteLLM
     1.90.1 docs what `database_url` + prisma actually requires (`pip install
     prisma` in `/opt/litellm/venv`, `prisma generate`, migration step, and
     whether the `litellm` user can write the DB under
     `StateDirectory=litellm`). Do NOT assume; the last person who assumed got
     Incident 1.
  3. **CANDIDATE path 2 — `success_callback` to a lightweight local logger:**
     verify against LiteLLM 1.90.1 docs whether `litellm_settings:
     success_callback` supports a custom/local callback that can append
     model/tokens/latency/cost to a local SQLite or JSONL file without
     prisma. Spike whichever path survives doc verification, with predicted
     numbers (Part 3).
- **You have a result when:** every request through :4000 appears in a
  queryable store with model, tokens, latency, and cost — and the README
  "Spend tracking" section can be made TRUE again (its `sqlite3` query, or a
  corrected equivalent, returns real rows).

### B. In-gateway cascade/verifier

- **Why current state fails:** today every service re-implements LOCAL→FAST→
  MID→FRONTIER escalation and its quality gate (valid-JSON check etc.). That
  is duplicated logic, duplicated bugs, and inconsistent gates across
  services.
- **The tension — read this before building anything:** moving cascade policy
  into the gateway **directly contradicts the doctrine in `ROUTING.md`**:
  "services own the cascade policy; the gateway owns only the model catalog
  and auth translation." This is an **architecture-contract change**, not a
  feature. It must be gated through llm-gateway-change-control and must update
  the contract in llm-gateway-architecture-contract if adopted. Do not sneak
  it in as config.
- **This project's asset:** a named reference implementation to measure
  against — algo-factory's `ModelRouter` (`src/algo_factory/agents/router.py`
  in that repo): per-task RoutePolicy, JSON-gated escalation, all calls
  through this gateway. That gives a before/after comparison target.
- **First three steps in this repo:**
  1. Write the contract-change proposal (what the gateway would own, what
     services keep) and take it through llm-gateway-change-control BEFORE any
     config work.
  2. **CANDIDATE:** verify against LiteLLM 1.90.1 docs whether its router
     supports fallback chains with a post-response hook usable as a quality
     gate/verifier — or whether this needs a custom callback. Unverified;
     do not design on top of an assumed feature.
  3. Pick ONE consumer (algo-factory's ModelRouter is the obvious one) and
     define the measurement: its current quality-gate pass/escalation rates on
     a fixed task set, recorded before any migration.
- **You have a result when:** one service deletes its cascade code and gets
  equal-or-better quality-gate outcomes through the gateway — *measured*
  against the pre-migration baseline, not asserted.

### C. Latency/health-aware routing & fallbacks

- **Why current state fails:** routing is fully static. When the :4002
  claude-cli-server backend stalls, claude-* calls sit for the entire LiteLLM
  `request_timeout` and die — `journalctl` on 2026-07-02 shows repeated
  `APITimeoutError ... timeout value=300.0, time taken=300.0 seconds`. Raising
  the ceiling 120→300 did not fix it (see the worked example in Part 3, and
  llm-gateway-timeout-and-drift-campaign for the active remediation).
- **The tension — read this before building anything:** exactly like Problem
  B, configuring gateway-side `fallbacks`/health-aware routing moves
  escalation policy INTO the gateway, which **directly contradicts
  ROUTING.md's doctrine** ("services own the cascade policy") and
  architecture-contract Decision 2's design rule ("do not add
  retry/fallback/escalation logic to the gateway config as a convenience").
  This is an **architecture-contract change**, not a feature: gate the
  proposal through llm-gateway-change-control and update
  llm-gateway-architecture-contract if adopted. Do not sneak it in as config.
- **This project's asset:** most labs have to *simulate* backend degradation;
  this one gets it for free. Broker GPU contention (the GPU is shared with
  gaming/Plex) and :4002's 60–120 s floor make static routing *visibly*
  suboptimal here, and an outage is trivially inducible for testing (in a
  change-controlled window — stopping claude-cli-server is a mutation, so it
  goes through llm-gateway-change-control, not ad hoc).
- **First three steps in this repo:**
  1. **CANDIDATE:** spike LiteLLM's `fallbacks` / routing-strategy config
     against 1.90.1 docs — confirm which of fallback lists, cooldowns, and
     latency-based routing exist and work in this version before designing
     around them.
  2. Define the fallback policy per tier as a table (e.g. what should a
     `claude-sonnet-4-6` call do when :4002 is down — fail fast? degrade to
     `gemini-2.5-flash`? to LOCAL?). This is tier doctrine, so the decision
     lands in litellm-routing-reference once made; the experiment lives here.
  3. Write the induced-outage test plan with predicted numbers (Part 3): stop
     :4002 in a controlled window, fire N claude-* calls, predict fallback
     latency and success count before running.
- **You have a result when:** an induced :4002 outage causes claude-* calls to
  degrade to the defined fallback (or fail fast per policy) instead of 300 s
  deaths — demonstrated in a recorded test, not reasoned about.

### D. Activate the RunPod MID tier

- **Why current state fails:** the tier contract (`ROUTING.md`) names
  `runpod/qwen2.5-72b` in the MID tier, but the config block is commented out
  ("NOT ACTIVE: template only", commit `42ca4bc`). The MID tier as documented
  is half-real: only `claude-sonnet-4-6` backs it, and that currently rides
  the fragile :4002 path.
- **This project's asset:** the template already exists in
  `config/config.yaml` — a serverless vLLM endpoint (OpenAI-compatible) needs
  only an endpoint ID in the `api_base` and `RUNPOD_API_KEY` in
  `/etc/litellm/litellm.env` (reference the variable, never the value).
- **First three steps in this repo:**
  1. Deploy a RunPod serverless vLLM endpoint for qwen2.5-72b-instruct and
     record its per-token/per-second pricing — the "declared cost" the result
     is measured against.
  2. Uncomment and fill the config block; add `RUNPOD_API_KEY` to the env
     file. Config change + restart → llm-gateway-change-control discipline;
     beware the update.sh clobber trap (see llm-gateway-architecture-contract)
     when reconciling repo vs live config.
  3. Run the smoke checklist from llm-gateway-validation-and-qa against the
     new model name.
- **You have a result when:** `runpod/qwen2.5-72b` passes the smoke checklist
  at the declared cost — and the ROUTING.md MID row stops being aspirational.

### E. Harden claude-cli-server into a real service

- **Why current state fails (all verified 2026-07-02):** the service is a
  single 186-line `server.py` at `/opt/claude-cli-server/` with no git repo,
  no version pinning, running as `User=preston` (house-rule violation: desktop
  services run under dedicated nologin users), with a silent fable→sonnet
  alias, a misaligned timeout stack (LiteLLM 300 s → shim body default 180 s →
  subprocess), and **no timeout on the streaming path** — an abandoned
  streaming client can pin a subscription-billed `claude` process forever.
- **This project's asset:** the pattern already carries real production
  traffic and survived one real fix cycle (the argv→STDIN 502 fix, Incident 3
  in llm-gateway-failure-archaeology). It works; it just isn't *engineering*
  yet.
- **First three steps in this repo (and its future repo):**
  1. Give it a repo: import `/opt/claude-cli-server/server.py` + its unit file
     into version control with an install script modeled on this repo's
     `scripts/install.sh`. (Whether that repo is public is Preston's call —
     it wraps `--dangerously-skip-permissions` and a personal subscription;
     flag, don't decide.)
  2. Create a dedicated nologin service user per the house rule and move the
     unit to it — note this interacts with `CLAUDE_BIN=/home/preston/.local/
     bin/claude` and `HOME=/home/preston`, so the CLI install/auth location
     must move too. Mutation → change control.
  3. Add a streaming timeout and align the three timeout layers into one
     documented ordering (the layer table lives in
     llm-gateway-config-and-flags; the active campaign is
     llm-gateway-timeout-and-drift-campaign). Fix or document the fable alias
     so nothing is silent.
- **You have a result when:** claude-cli-server passes the same
  install/verify discipline as the gateway itself — fresh-machine install
  from its repo, service-user compliant, golden-checklist-style smoke
  verification. That is also the unlock condition for any external write-up
  of the pattern (Part 1).

---

## Part 3 — Research methodology: the evidence bar for this stack

These rules exist because this project already paid for them once each.

### Rule 1: a mechanism must explain ALL observations, including the negatives

**Worked example from this project's history (2026-07-02):** claude-* calls
were dying at the LiteLLM timeout. The obvious mechanism — "the ceiling is too
low, raise `request_timeout`" — was tried: 120→300. Calls **still died at
exactly 300.0 s**. The proposed mechanism failed its own test, because it
explained only the deaths, not the rest of the data. The correct mechanism has
to explain BOTH observations: (a) even *trivial* prompts through :4002 take
60–120 s (a backend floor latency, inherent to spawning the `claude` CLI), and
(b) some requests run unbounded (streaming path has no timeout; non-streaming
layers are misaligned) and will consume ANY ceiling you set. Ceiling-raising
predicts trivial calls should be fast — they aren't — so it was never the
mechanism. Before adopting any explanation here, list every observation
(especially the ones that *didn't* fail) and check the mechanism predicts each
one.

### Rule 2: predict numbers BEFORE running

A spike without a prediction is a demo, not an experiment. Before running,
write down expected latency, count, or rate ("with fallbacks configured, an
induced :4002 outage should make 10/10 claude-* test calls return via
gemini-2.5-flash in <15 s each"). Then measure. A match is evidence; a miss is
information about your model of the system — either way you learn. "It seemed
to work" is not a result on this stack, where a 60 s floor can masquerade as
"working" and a quota wall can masquerade as "broken".

### Rule 3: one adversarial-refutation pass before adopting a conclusion

Before writing "root cause found" or "fix verified" anywhere, spend one
explicit pass trying to break your own explanation: what observation would
falsify it? Does the timeline actually fit? Would the fix have prevented the
original incident, or just the reproduction? The 120→300 episode would have
died at this step — "if the ceiling were the problem, why is a trivial call
taking 90 s?"

### Rule 4: the idea lifecycle

Every idea moves through named states; skipping a state is how stale claims
(like the README spend section) get minted.

1. **Open problem** — documented here (Part 2), with failure mode and asset.
2. **CANDIDATE** — a proposed mechanism/solution, explicitly labeled,
   unverified. Candidates may appear in skills and docs ONLY with the label.
3. **Spike with predicted numbers** — Rule 2, run in a change-controlled
   window if it mutates anything (llm-gateway-change-control).
4. **Adoption or retirement** — adoption is gated through
   llm-gateway-change-control (and llm-gateway-architecture-contract if it
   touches an invariant); a failed candidate is documented in
   llm-gateway-failure-archaeology so the next session doesn't re-run it.

### Rule 5: know where good ideas came from here

Historically in this project, every doctrine-grade insight came from
**incidents and economics, not whiteboards**: the Gemini free-tier quota wall
(Incident 4) and the subscription self-rate-limiting of bulk claude-cli work
(Incident 5) are what actually forged the LOCAL-first doctrine — "most calls
never leave the free tier" is enforced by economics, not principle. The
prisma startup failure (Incident 1) is what defines Open Problem A. When
hunting for the next thing to build, read llm-gateway-failure-archaeology
before brainstorming: the incident log is this project's idea generator.

---

## When NOT to use this skill

- **Executing the tier contract** (which model_name for which job) →
  litellm-routing-reference.
- **What the invariants are / what the drift is** →
  llm-gateway-architecture-contract.
- **Getting approval for a mutation** (config edit, restart, new service) →
  llm-gateway-change-control.
- **Full incident narratives** → llm-gateway-failure-archaeology (this skill
  cites incidents in one line only).
- **The golden checklist / smoke tests** → llm-gateway-validation-and-qa.
- **Timeout-layer details and config flags** → llm-gateway-config-and-flags;
  the live timeout remediation → llm-gateway-timeout-and-drift-campaign.
- **Installing/operating/debugging the running service** →
  llm-gateway-install-and-operate, llm-gateway-debugging-playbook,
  llm-gateway-diagnostics-and-tooling.
- Day-to-day work that proposes nothing new and publishes nothing — you don't
  need the research frontier to restart a service.

## Provenance and maintenance

Facts verified 2026-07-02 against the repo and read-only SSH to the live host
(`ssh desktop-agent`). CANDIDATE items are unverified by definition. Re-verify
before trusting:

- Repo config still routes claude-* to `anthropic/` (drift baseline):
  `grep -n "anthropic/" /Users/prestonbernstein/dev/llm-gateway/config/config.yaml`
- RunPod block still commented out:
  `grep -n "runpod" /Users/prestonbernstein/dev/llm-gateway/config/config.yaml`
- README spend section still stale (Problem A open):
  `grep -n "litellm.db" /Users/prestonbernstein/dev/llm-gateway/README.md`
- Example config still carries the Incident-1 trap:
  `grep -n "database_url" /Users/prestonbernstein/dev/llm-gateway/config/config.example.yaml`
- Logging still absent on live host (Problem A open):
  `ssh desktop-agent 'ls -la /var/lib/litellm/'`
- Live LiteLLM version (doc-verification target for CANDIDATE paths):
  `ssh desktop-agent '/opt/litellm/venv/bin/litellm --version'`
- claude-cli-server still unhardened (Problem E open):
  `ssh desktop-agent 'grep -n "^User=" /etc/systemd/system/claude-cli-server.service'`
- Tier doctrine wording (Problem B tension source):
  `grep -n "services own the cascade" /Users/prestonbernstein/dev/llm-gateway/ROUTING.md`

If any of these change, update the corresponding problem status here and route
the change through llm-gateway-change-control.
