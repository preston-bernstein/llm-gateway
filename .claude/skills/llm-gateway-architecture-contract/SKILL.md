---
name: llm-gateway-architecture-contract
description: >
  The load-bearing design decisions of llm-gateway and WHY each was made, plus
  the invariants that must never be violated and the known weak points. Load
  this skill BEFORE making any design-level change to this repo or the live
  deployment (new provider, new model route, config restructure, systemd unit
  edit, moving secrets, changing ports or api_base values), when answering
  "why is X built this way" / "why a proxy at all" / "why does the gateway not
  do cascades", when a proposed change might violate an invariant (e.g. adding
  an api_key to config.yaml, pointing at Ollama :11434, running something as
  preston), or when deciding whether repo config or live config is the source
  of truth. Not for step-by-step install/debug procedures — see the "When NOT
  to use this skill" section.
---

# llm-gateway — Architecture Contract

This skill is the design constitution for `/Users/prestonbernstein/dev/llm-gateway`
(public repo, github.com/preston-bernstein/llm-gateway) and its live deployment
on the desktop `multimedia` (LAN 10.0.0.243). Read it before proposing or making
any design-level change. If your change contradicts a decision or invariant
below, stop and route it through change control (`llm-gateway-change-control`).

**Jargon, defined once:**

- **LiteLLM** — an open-source proxy that exposes one OpenAI-compatible HTTP API
  and translates requests to many provider backends (Gemini, Anthropic, Ollama,
  any OpenAI-compatible server). This repo deploys it as a systemd service on
  port 4000.
- **FrugalGPT** — a cost-reduction pattern (from the FrugalGPT paper): try a
  cheap model first, verify the output with a quality gate, escalate to a more
  expensive tier only on failure.
- **EnvironmentFile** — a systemd directive that injects `KEY=value` lines from
  a root-owned file into the service's environment at start. Here:
  `/etc/litellm/litellm.env` (mode 600).
- **StateDirectory** — a systemd directive that creates and owns a writable
  directory under `/var/lib/` for the service (here `/var/lib/litellm`), which
  is otherwise blocked by `ProtectSystem=strict`.
- **resource broker** — the `resource-broker` service on the same box
  that arbitrates the shared GPU. It fronts raw Ollama on ports 11435
  (interactive), 11436 (batch), 11437/jobs (durable jobs). Nothing may call raw
  Ollama `:11434` directly.
- **claude-cli-server** — a small FastAPI shim at `127.0.0.1:4002` (NOT in this
  repo; lives at `/opt/claude-cli-server/server.py` on the desktop) that wraps
  the `claude` CLI (`claude -p --dangerously-skip-permissions`) so
  subscription-billed Claude looks like an OpenAI-compatible endpoint.

---

## Decision 1 — One proxy in front of all providers, not per-service API calls

Every service on the LAN calls `http://10.0.0.243:4000` in OpenAI format with
one internal master key. The gateway translates to each provider's wire format
and auth. Four reasons (from `README.md`):

| Reason | What it buys | Status (2026-07-02) |
|---|---|---|
| **Key management** | Provider API keys live in exactly one file (`/etc/litellm/litellm.env`); services carry no credentials | Working |
| **Visibility** | One place to see every call: model, tokens, latency, cost | **PARTIALLY BROKEN** — see below |
| **Provider abstraction** | Swap a backend by editing one `config.yaml` alias + restart; no service changes | Working (this is exactly how claude-* was rerouted to :4002) |
| **FrugalGPT compatibility** | Services implement tier cascades against stable model names; gateway handles per-tier auth/format differences | Working |

**Visibility caveat (do not repeat the README's claim):** the README's "Spend
tracking" section says every request is logged to `/var/lib/litellm/litellm.db`.
That is stale. `database_url` was removed from `config/config.yaml` because
DB-backed spend logging requires the prisma client, which was not installed —
the proxy failed to start (Incident 1, commit `27b1fa0`; full story in
**llm-gateway-failure-archaeology**). Verified 2026-07-02 by direct SSH:
`/var/lib/litellm/` contains only the service user's home-dir skeleton
dotfiles — no `litellm.db`. **No spend/usage logging exists today.** Any
design that assumes "we can query the spend DB" is building on nothing.
`config/config.example.yaml` still carries the bad `database_url` line —
copying it verbatim reproduces the startup failure.

## Decision 2 — Services own cascade policy; gateway owns catalog + auth translation

Doctrine from `ROUTING.md`: the gateway serves a **catalog** of model names in
tiers (LOCAL / FAST / MID / FRONTIER) and does auth translation. It does NOT
decide when to escalate. Each service implements its own cascade (try cheap,
verify with a quality gate, escalate on failure). Reference implementation:
algo-factory's `ModelRouter` (`src/algo_factory/agents/router.py` in that repo).

Why this split:

- Escalation criteria are task-specific (valid-JSON gates, self-consistency
  checks) — the gateway cannot know them.
- Keeping the gateway policy-free keeps it a dumb, stable dependency; services
  can change cascade logic without a gateway deploy.
- Shared tier NAMES across services keep policies comparable stack-wide.

**Design rule:** do not add retry/fallback/escalation logic to the gateway
config as a "convenience." That moves policy into the wrong layer. Tier table
details → **litellm-routing-reference**.

## Decision 3 — No secrets in config; os.environ refs + EnvironmentFile

`config/config.yaml` contains only `api_key: os.environ/<VAR>` references
(LiteLLM resolves these from the process environment). Real values live only in
`/etc/litellm/litellm.env` (root-owned, mode 600, git-ignored), injected via
systemd `EnvironmentFile=`. The env file is read by root systemd, not by the
`litellm` service user, so the service never needs filesystem access to it.
`disable_master_key_return: true` and `redact_user_api_key_info: true` keep the
master key out of responses and logs.

Why: the repo is **public**. Any key in `config.yaml`, the unit file, or a
committed doc is an immediate leak. This also makes key rotation a
one-file-edit-plus-restart operation.

**Design rule:** never put a literal key in any file in this repo, any skill,
or any log excerpt you paste. Reference the location (`/etc/litellm/litellm.env`),
never the value. (Incident 2 — the /etc/litellm permissions fix that makes this
layout work — is in **llm-gateway-failure-archaeology**.)

## Decision 4 — Hardened systemd unit

From `systemd/litellm.service`, each directive and its purpose:

| Directive | Why |
|---|---|
| `User=litellm` / `Group=litellm` | Dedicated nologin system user (house rule: no desktop service runs as preston). Created by `scripts/install.sh` with home `/var/lib/litellm`. |
| `EnvironmentFile=/etc/litellm/litellm.env` | Secrets injected by root systemd (Decision 3). |
| `NoNewPrivileges=true` | Process and children can never gain privileges (no setuid escalation). |
| `ProtectSystem=strict` | Entire filesystem read-only to the service except explicitly allowed paths. Limits blast radius of a compromised proxy. |
| `ProtectHome=true` | `/home`, `/root` invisible — the proxy has no business reading user files. |
| `PrivateTmp=true` | Private `/tmp`; no tmp-based cross-service snooping or races. |
| `StateDirectory=litellm` | THE writable escape hatch: creates `/var/lib/litellm` owned by the service user. |
| `WorkingDirectory=/var/lib/litellm` | cwd is the one writable place. |
| `Restart=always` / `RestartSec=5` | Self-healing on crash. |

**The StateDirectory / ProtectSystem=strict interaction (load-bearing):**
`ProtectSystem=strict` mounts `/var` read-only for this service. Any writable
path under `/var` must be declared via `StateDirectory` — the unit file's own
comment says exactly this. If you ever add a file/DB/log the proxy must write
(e.g. re-enabling spend logging), it must live under `/var/lib/litellm` or you
must add another `StateDirectory`/`ReadWritePaths` entry; otherwise the proxy
gets EROFS and fails at runtime, not at start.

## Decision 5 — Colocation on one box → localhost api_base values

The gateway, the resource broker, and claude-cli-server all run on the same
desktop. Therefore `config.yaml` uses loopback addresses:

- `api_base: http://127.0.0.1:11435` (broker interactive lane) and
  `http://127.0.0.1:11436` (broker batch lane) for the `ollama/*` models.
- Live overlay: `api_base: http://localhost:4002/v1` for `claude-*`
  (claude-cli-server; see Decision 6).

Why: loopback traffic never touches the LAN (no exposure of the broker or the
shim beyond the box), and there is no dependency on LAN IP stability. The
claude-cli-server binds only to 127.0.0.1 — the gateway's master key is
effectively the only LAN-facing gate in front of it.

**Design rule:** if the gateway ever moves off this box, every localhost
`api_base` breaks; that is a design-level change requiring this skill plus
change control, not a quick edit.

## Decision 6 — Repo-config-canonical vs live-overlay (ARCHITECTURAL TENSION, OPEN)

The repo's stated model: `config/config.yaml` in git is canonical;
`scripts/update.sh` copies it over `/etc/litellm/config.yaml` **unconditionally**
and restarts.

The live reality (verified 2026-07-02 by direct SSH): the live config is AHEAD
of the repo in 3 known ways (enumerated delta list:
**llm-gateway-config-and-flags**, drift section) — claude-* → the
claude-cli-server shim on `:4002` (subscription billing; the repo's
`anthropic/` API account is out of credits), a live-only `claude-fable-5`,
and `request_timeout: 300` vs repo `120`.

**SAFETY-CRITICAL WARNING: running `sudo bash scripts/update.sh` today silently
clobbers the live config** — claude-* traffic reverts to the credit-less API
key (all claude calls fail) and `claude-fable-5` disappears. This warning may
be repeated in any skill that mentions update.sh.

**Status: OPEN decision.** Per the coordinator (ASSUMPTION-level policy): the
:4002 routing is a LOCAL OVERLAY; whether it becomes canonical in the public
repo is undecided (public-repo exposure of the subscription-wrapping shim is
part of the tension). **Do not decide this policy in any skill or change.** The
reconciliation decision menu lives in **llm-gateway-timeout-and-drift-campaign**.

---

## Invariants — must ALWAYS hold

Check every proposed change against this list. A change that violates one is
wrong until change control says otherwise.

- [ ] **Master key gates LAN access.** Every gateway endpoint except
      `/health/liveliness` requires `Authorization: Bearer <LITELLM_MASTER_KEY>`.
      Never disable `master_key` or expose an unauthenticated route.
- [ ] **No service carries provider credentials.** Services get the gateway URL
      + master key only. Provider keys exist solely in `/etc/litellm/litellm.env`.
- [ ] **Local inference only via broker ports** (127.0.0.1:11435 interactive,
      :11436 batch; LAN 10.0.0.243 equivalents from other boxes) — **never raw
      Ollama :11434**. The GPU is shared with gaming/Plex; the broker arbitrates.
- [ ] **Service users are dedicated and nologin.** `litellm` complies.
      (claude-cli-server does not — known weak point below; do not silently
      "fix" it without change control.)
- [ ] **Secrets never appear in git, config.yaml, unit files, logs, or skills.**
      Only `os.environ/<VAR>` references; `redact_user_api_key_info: true`
      stays on.

## Known weak points — stated plainly (as of 2026-07-02)

1. **Repo↔live config drift + update.sh clobber.** Live config is ahead of the
   repo and `update.sh` overwrites it unconditionally (Decision 6). The single
   most dangerous command in this repo right now is `sudo bash scripts/update.sh`.
2. **claude-cli-server runs as `User=preston`** (verified via
   `systemctl show claude-cli-server -p User`), violating the service-user
   house rule, and wraps `claude -p --dangerously-skip-permissions` with
   Preston's personal subscription and HOME. Open item; needs change control.
   (Full shim contract: **litellm-routing-reference** §5.)
3. **No spend/usage logging exists.** The visibility pillar of Decision 1 is
   partially broken; README's spend section is stale (Incident 1).
4. **Shim streaming path has no timeout** — a hung CLI call hangs forever
   (timeout layer table → **llm-gateway-config-and-flags**; shim contract →
   **litellm-routing-reference** §5).
5. **`claude-fable-5` silently aliases to sonnet** in the shim — no error, no
   warning (shim contract → **litellm-routing-reference** §5).
6. **Gemini free tier is quota-fragile.** Billing is off on the Gemini account;
   `gemini-2.5-flash` 429s under bulk load. The FAST tier is not a bulk lane
   (Incident 4 → **llm-gateway-failure-archaeology**).
7. **README spend section is stale** (subset of point 3, listed separately
   because it actively misleads new readers into querying a DB that does not
   exist).

## When NOT to use this skill

- Full incident narratives and root-cause stories → **llm-gateway-failure-archaeology**
- Tier table and per-model routing details → **litellm-routing-reference**
- Timeout layer table and every config flag's meaning → **llm-gateway-config-and-flags**
- Install/update/rotate procedures and operational permissions → **llm-gateway-install-and-operate**
- The drift/timeout remediation plan and reconciliation decision menu → **llm-gateway-timeout-and-drift-campaign**
- Live debugging of a failing call → **llm-gateway-debugging-playbook**
- Proposing/approving a change (process, not rationale) → **llm-gateway-change-control**

## Provenance and maintenance

Sources: direct reads of `README.md`, `ROUTING.md`, `config/config.yaml`,
`config/config.example.yaml`, `scripts/install.sh`, `scripts/update.sh`,
`systemd/litellm.service` in this repo, plus read-only SSH to the live host,
all on 2026-07-02. Live-host facts re-verified directly (drift, empty
`/var/lib/litellm`, `User=preston` on claude-cli-server); remaining
context (incident details, coordinator policy) per the principal's ground-truth
brief, verified 2026-07-02 (principal).

Volatile facts — re-verify before relying on them:

| Fact | One-line re-check |
|---|---|
| Repo↔live config drift | see the drift command block below this table |
| Spend logging still absent | `ssh desktop-agent 'sudo ls -la /var/lib/litellm/'` (skeleton dotfiles only, no `litellm.db` ⇒ still no DB) |
| claude-cli-server still runs as preston | `ssh desktop-agent 'systemctl show claude-cli-server -p User'` |
| claude-* still routed to :4002 live | `ssh desktop-agent 'sudo grep -n "4002" /etc/litellm/config.yaml'` |
| Live request_timeout value | `ssh desktop-agent 'sudo grep -n request_timeout /etc/litellm/config.yaml'` |
| Service healthy | `ssh desktop-agent 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:4000/health/liveliness'` |
| example config still carries bad database_url | `grep -n database_url /Users/prestonbernstein/dev/llm-gateway/config/config.example.yaml` |
| fable→sonnet aliasing in shim | `ssh desktop-agent 'grep -n -i fable /opt/claude-cli-server/server.py'` |

Drift re-check (run from the Mac; the pipe runs locally — `-` lines =
live-only, `+` lines = repo-only, same orientation as `config-drift.sh`):

```bash
ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml
```
