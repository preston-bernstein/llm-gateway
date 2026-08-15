---
name: litellm-routing-reference
description: >
  Domain reference for the llm-gateway LiteLLM proxy — for UNDERSTANDING, not
  editing (edits → llm-gateway-config-and-flags + llm-gateway-change-control).
  Covers: how LiteLLM's config model works (model_list, model_name vs
  litellm_params.model, provider prefixes gemini//anthropic//ollama//openai/,
  os.environ secrets, general_settings, litellm_settings), the FrugalGPT tier
  contract (LOCAL/FAST/MID/FRONTIER — source of truth is ROUTING.md; this
  skill carries the annotated working copy), the claude-cli-server shim
  contract on :4002 (this skill is the shim contract's one home), and the
  resource-broker lanes (:11435/:11436/:11437). Load this when you need
  to understand what a config.yaml entry means, choose a model or tier for a
  workload, wire a new service to the gateway, decide whether a job belongs on
  LOCAL vs a cloud tier, or are confused by model_name vs model / why claude-*
  points at localhost:4002.
---

# LiteLLM routing reference — llm-gateway

Zero-context domain reference for the LiteLLM proxy on the home-lab desktop
(`multimedia`, 10.0.0.243, port 4000). This skill explains the *concepts and
contracts*: what LiteLLM is, how its config maps public model names to
backends, the FrugalGPT tier contract every service should follow, the
claude-cli-server shim, and the Ollama broker lanes. It does **not** walk you
through editing config or restarting the service — see "When NOT to use this
skill".

All volatile facts below verified **2026-07-02** (direct repo reads + read-only
SSH to the live host).

---

## 1. What LiteLLM is

[LiteLLM](https://github.com/BerriAI/litellm) is an open-source
**OpenAI-compatible proxy**: it exposes the standard OpenAI REST API
(`/v1/chat/completions` etc.) on one port and translates each request to
whatever provider actually serves the model — Google AI Studio, Anthropic,
a local Ollama server, or any other OpenAI-compatible endpoint. Clients speak
one wire format and hold one key (the gateway's master key); the proxy holds
the real provider keys and does the auth/format translation.

- Live version on the desktop: **LiteLLM 1.90.1** (as of 2026-07-02), Python
  3.12 venv at `/opt/litellm/venv`, systemd service `litellm`, listening on
  `0.0.0.0:4000`.
- Config lives at `/etc/litellm/config.yaml` on the box; the git-tracked
  version is `config/config.yaml` in this repo. **These two currently differ**
  — see §3 "Repo vs live drift".

### Key endpoints

| Endpoint | Auth | Purpose |
|---|---|---|
| `POST /v1/chat/completions` | `Authorization: Bearer <LITELLM_MASTER_KEY>` | The main inference endpoint (OpenAI format) |
| `GET /v1/models` | Bearer master key required | Lists every `model_name` the gateway serves |
| `GET /health/liveliness` | **No auth** | Cheap "is the proxy up" probe — use in scripts/monitors |

The master key's *value* lives only in `/etc/litellm/litellm.env` on the
desktop (root-only, mode 600). Never copy it into configs, docs, or skills —
reference the location.

---

## 2. The config model

A LiteLLM config has three top-level blocks used here: `model_list`,
`general_settings`, `litellm_settings`.

### 2.1 `model_list`: `model_name` vs `litellm_params.model`

Each entry maps a **public alias** to a **provider-prefixed backend**:

```yaml
- model_name: gemini-2.5-flash          # public alias — what clients send as "model"
  litellm_params:
    model: gemini/gemini-2.5-flash      # provider-prefixed backend LiteLLM calls
    api_key: os.environ/GEMINI_API_KEY  # secret by reference, never by value
```

- **`model_name`** — the name clients put in the `model` field of their
  OpenAI-format request. It is an arbitrary alias; it appears in `/v1/models`.
- **`litellm_params.model`** — where the request actually goes. The prefix
  before the first `/` selects the provider adapter; the rest is the
  provider's model id.

This indirection is the whole point: you can repoint an alias at a different
backend (different provider, different model, different host) without any
client changing a line. That is exactly what happened to the `claude-*`
aliases (§3).

### 2.2 Provider prefixes as used HERE

| Prefix | Means | Used here for |
|---|---|---|
| `gemini/` | Google AI Studio API (Gemini) | `gemini-2.5-flash`, `gemini-2.5-pro` |
| `anthropic/` | Anthropic's native API (API-key billing) | `claude-*` **in the repo config** (currently non-functional — API account out of credits) |
| `ollama/` | An Ollama server at the entry's `api_base` | All `ollama/*` aliases, pointed at the resource broker on `127.0.0.1:11435`/`:11436` (§6) |
| `openai/` | **Any OpenAI-compatible server** at the entry's `api_base` | Two uses: (a) the **live overlay** routes `claude-*` to the local claude-cli-server at `http://localhost:4002/v1` (§5); (b) the dormant RunPod serverless-vLLM template in `config/config.yaml` (commented out, NOT active) |

The `openai/` prefix is the escape hatch: anything that speaks the OpenAI wire
format can sit behind an alias. The live box exploits this to swap Anthropic
API billing for a local shim without clients noticing.

### 2.3 Secrets: `os.environ/<VAR>`

`api_key: os.environ/ANTHROPIC_API_KEY` tells LiteLLM to read the key from the
process environment at request time. The environment is injected by systemd
via `EnvironmentFile=/etc/litellm/litellm.env`. **No secret value ever appears
in config.yaml, the unit file, or logs** — house rule, non-negotiable. The
live claude-* overlay entries use `api_key: "none"` (literal placeholder)
because the local shim requires no key.

### 2.4 `general_settings`

| Setting | Value here | What it does |
|---|---|---|
| `master_key` | `os.environ/LITELLM_MASTER_KEY` | The single bearer token all clients on the LAN use. Generated by `scripts/install.sh` (`sk-litellm-` + random hex). |
| `disable_master_key_return` | `true` | Stops the proxy from echoing the master key back in API responses. |

Note: `config/config.example.yaml` still contains
`database_url: "sqlite:////var/lib/litellm/litellm.db"`. That line **breaks
startup** (DB spend-logging needs the prisma client, which isn't installed —
Incident 1) and was removed from config.yaml. Do not copy the example
verbatim; there is currently **no spend/usage logging** despite what
README.md's stale "Spend tracking" section says. Full story:
`llm-gateway-failure-archaeology`.

### 2.5 `litellm_settings`

| Setting | Repo / Live | Semantics |
|---|---|---|
| `request_timeout` | `120` repo / **`300` live** (2026-07-02) | Caps the **entire upstream call** — connection + full generation. If the backend hasn't finished in that many seconds, LiteLLM raises `APITimeoutError` and the client gets an error, regardless of what the backend is still doing. This is one of **three unaligned timeout layers** on the claude path (§5) — the full layer table lives in `llm-gateway-config-and-flags`. |
| `drop_params` | `true` | When a client sends an OpenAI parameter the target provider doesn't support, silently drop it instead of erroring. Why it exists here: keeps Ollama-bound clients compatible — tools emit OpenAI-isms (e.g. `frequency_penalty`, tool fields) that Ollama models don't accept; without this, valid requests would 400. Trade-off: unsupported params are ignored silently, so a "temperature isn't doing anything" mystery may be `drop_params` at work. |
| `redact_user_api_key_info` | `true` | Keeps key material out of proxy logs. |

---

## 3. Repo vs live drift (you must know this before trusting config.yaml)

As of 2026-07-02, `/etc/litellm/config.yaml` on the live host is **ahead of**
the repo's `config/config.yaml` in 3 known ways — in one line: `claude-*` →
the local claude-cli-server shim on `:4002` (§5) instead of the repo's
credit-less `anthropic/` routing, a live-only `claude-fable-5`, and
`request_timeout: 300` vs repo `120`. The enumerated delta list lives in
`llm-gateway-config-and-flags` (drift section).

**Safety-critical warning:** `scripts/update.sh` copies the repo config over
`/etc/litellm/config.yaml` **unconditionally** and restarts the service.
Running `sudo bash scripts/update.sh` today would silently revert claude-*
traffic to the credit-less Anthropic API (all claude-* calls fail) and drop
`claude-fable-5`. ASSUMPTION (coordinator-endorsed, 2026-07-02): the live
:4002 routing is a **local overlay**; whether it becomes canonical in the
(public) repo is an **open decision** — do not decide it in passing.
Reconciliation options: `llm-gateway-timeout-and-drift-campaign`; change
procedure: `llm-gateway-change-control`.

---

## 4. The FrugalGPT tier contract (source of truth: ROUTING.md — this skill carries the annotated working copy)

"FrugalGPT" = Chen, Zaharia, Zou 2023 — a paper showing LLM cost can drop
dramatically by **cascading**: try a cheap model first, verify the answer, and
escalate to a stronger model only on failure. This repo implements the
**routing substrate** for that idea (a shared model catalog with tier-shaped
names), *not* the paper's learned router or scoring model. Don't oversell it:
the gateway does no cascading itself.

### Division of responsibility

- **Services own the cascade policy**: which tier to try first, when to
  escalate, and the **quality gate** — a verifier such as a
  valid-JSON-of-the-right-shape check or a self-consistency check. A cheap
  model "wins" only if its output passes the gate; otherwise the service
  re-issues the request one tier up.
- **The gateway owns only the model catalog and auth translation.** It has no
  idea a cascade is happening; it just serves whatever `model_name` arrives.

Reference implementation: algo-factory's `ModelRouter`
(`src/algo_factory/agents/router.py` in that repo) — per-task `RoutePolicy`
(mode `cascade`|`best` + tier chain), JSON-gated escalation. New services
should reuse these tier names so policies stay consistent across the stack.

### The tier table (annotated copy — ROUTING.md is the source of truth; on conflict, ROUTING.md wins and this copy gets updated)

| Tier | Gateway model_name(s) | Intended use |
|---|---|---|
| **LOCAL** | `ollama/batch/qwen3-vl:30b` — the only currently serveable entry. Also cataloged but **LISTED BUT NOT SERVEABLE (model not pulled, 2026-07-02)**: `ollama/interactive/qwen2.5`, `ollama/batch/qwen2.5:3b`, `ollama/batch/qwen2.5:7b` — calls return HTTP 500 (known defect: `llm-gateway-diagnostics-and-tooling`; Incident 8 in `llm-gateway-failure-archaeology`) | Free, private. Bulk/simple: classify, extract, embeddings |
| **FAST** | `gemini-2.5-flash` | Cheap fast cloud — first cloud escalation |
| **MID** | `claude-sonnet-4-6`, (`runpod/qwen2.5-72b` — template only, **NOT active**) | Strong reasoning at mid cost |
| **FRONTIER** | `claude-opus-4-8`, `gemini-2.5-pro` | Maximum accuracy — hard reasoning / judgment |

(`claude-haiku-4-5` and `claude-fable-5` are also served but sit outside the
ROUTING.md table; treat haiku as a cheap claude option and note fable-5's
silent-sonnet caveat in §5.)

### Doctrine

- **Bulk/simple work** → start LOCAL; escalate only on quality-gate failure.
  Most calls should never leave the free tier.
- **Accuracy-critical work** → skip the cascade entirely, go straight to
  FRONTIER. Don't pay in errors to save pennies where correctness matters.
- **Middling work** → cascade MID → FRONTIER.

### Empirical overlay (learned the hard way, as of 2026-07-02)

The clean tier table above meets reality as follows:

| Tier | Reality check |
|---|---|
| **FAST** | **Quota-fragile.** Gemini billing is OFF; the free tier 429s under bulk load (hit during LightRAG extraction, 2026-07-01/02). Fine for occasional escalations; do not plan bulk work here. |
| **MID / FRONTIER (claude-\*)** | Currently served by the claude-cli-server subscription path (§5): **60–120 s even for trivial calls**, and sustained use self-rate-limits Preston's Claude account (shared with his live Claude Code sessions). **Low-volume only.** |
| **LOCAL** | **The real bulk workhorse — but only `ollama/batch/qwen3-vl:30b` is serveable today** (the three `qwen2.5*` entries are dead — model not pulled, 2026-07-02). Free, no quota, no shared-account risk. The tier contract's "most calls never leave the free tier" is enforced by economics, not just principle — a bulk-extraction job that tried claude-haiku via :4002 was abandoned for exactly these reasons and moved to the broker batch lane. |

One-line rule of thumb: **bulk → LOCAL; occasional escalation → FAST (watch
for 429); careful low-volume judgment calls → MID/FRONTIER; anything
accuracy-critical and low-volume → straight to FRONTIER.**

Incident details behind this table: `llm-gateway-failure-archaeology`.

---

## 5. The claude-cli-server shim contract (as of 2026-07-02)

**This section is the shim contract's one home — sibling skills cite it in
one line, they do not retell it.** Not in this repo (no repo of its own
found). It is a 186-line FastAPI +
uvicorn app at `/opt/claude-cli-server/server.py` on the desktop, unit
`/etc/systemd/system/claude-cli-server.service`, listening on
**127.0.0.1:4002**. It exposes an OpenAI-compatible `/v1/chat/completions`
and fulfils each request by shelling out to
`claude -p --dangerously-skip-permissions` — i.e., it spends Preston's Claude
**subscription**, not API credits. The live gateway overlay points all
`claude-*` aliases here via the `openai/` prefix (§3).

Contract details (verified against the live server.py, 2026-07-02):

| Aspect | Behavior |
|---|---|
| Model mapping | Substring match on the incoming model name → CLI alias: contains `haiku` → `haiku`; `opus` → `opus`; `fable` → **`sonnet`** ("fable not a CLI alias yet" — so `claude-fable-5` via the gateway **silently runs sonnet**); anything else → `sonnet` (default). |
| Prompt delivery | Fed via **STDIN** (`subprocess.run(..., input=prompt)`). This is the Incident-3 fix — prompts were originally passed as argv, and prompts starting `---Task---` were parsed as CLI flags → 502s. |
| Non-streaming timeout | Per-request `timeout` body param, **default 180 s** in the handler (the `_run_claude` function signature defaults to 600, but the handler's 180 wins). Enforced as the `subprocess.run` timeout. |
| Streaming | `Popen` — **no timeout at all**. |
| Runs as | `User=preston` — **violates** the house rule that services run under dedicated nologin users. Known weak point / open item; do not silently "fix" without change control. |
| Environment | `CLAUDE_BIN = "/home/preston/.local/bin/claude"` is a hardcoded constant in server.py (line 23), NOT a unit `Environment=` line; the unit sets only `Environment=HOME=/home/preston`. |

**The timeout stack is unaligned** (open problem, 2026-07-02): LiteLLM
`request_timeout` (live 300) → shim body-param timeout (default 180) →
subprocess timeout, and no timeout on the streaming path. Live journal shows
claude-* calls dying at the full 300 s. The authoritative timeout-layer table
and tuning guidance live in `llm-gateway-config-and-flags`; the fix campaign
in `llm-gateway-timeout-and-drift-campaign`.

---

## 6. The resource-broker lanes

House rule (non-negotiable): **never point anything at raw Ollama on
`:11434`.** All local inference goes through the resource-broker
(repo: `~/dev/resource-broker` on the desktop). The GPU is shared with
gaming and Plex; the broker arbitrates, so calls may **queue** — a slow
response is often the broker holding your request while the GPU is busy, not
a failure.

| Port | Lane | Use |
|---|---|---|
| `11435` | Interactive | Chat, real-time, long-running prompts |
| `11436` | Batch | Embeddings, enrichment, short vision classification |
| `11437/jobs` | Durable jobs | Long batch, vision scoring — job API, not a chat endpoint |

From the gateway box itself (where the LiteLLM service runs), use
`127.0.0.1:11435` / `:11436` exactly as config.yaml does — same box, no LAN
hop. From other machines, `10.0.0.243:<port>`. The gateway's `ollama/*`
entries only use lanes 11435/11436; 11437 is a jobs API that services call
directly, not through this proxy.

---

## When NOT to use this skill

- **Editing config.yaml, adding/renaming a model entry, changing settings** →
  `llm-gateway-config-and-flags` (field-by-field mechanics, timeout-layer
  table) and `llm-gateway-change-control` (procedure, backups, the update.sh
  clobber protocol).
- **Why the architecture is shaped this way** (proxy-vs-direct, hardening
  rationale) → `llm-gateway-architecture-contract`.
- **What broke and why** (full incident narratives: database_url, permissions,
  argv 502, quota wall, bulk abandonment, timeout mismatch) →
  `llm-gateway-failure-archaeology`.
- **Installing, starting, restarting, updating the service** →
  `llm-gateway-install-and-operate`.
- **Diagnosing a live failure right now** → `llm-gateway-debugging-playbook`
  and `llm-gateway-diagnostics-and-tooling`.
- **Fixing the drift / timeout stack** →
  `llm-gateway-timeout-and-drift-campaign`.

---

## Provenance and maintenance

Facts verified 2026-07-02 via direct repo reads and read-only SSH
(`ssh desktop-agent`). Re-verify before trusting anything marked volatile:

- Live LiteLLM version:
  `ssh desktop-agent '/opt/litellm/venv/bin/pip show litellm | grep -i version'`
- Proxy up (no auth):
  `curl -s -o /dev/null -w "%{http_code}\n" http://10.0.0.243:4000/health/liveliness`
- Served model list (needs master key from `/etc/litellm/litellm.env` on the box):
  `curl -s http://10.0.0.243:4000/v1/models -H "Authorization: Bearer $LITELLM_MASTER_KEY"`
- Live vs repo config drift (run from the repo root; `-` = live-only, `+` = repo-only):
  `ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - config/config.yaml`
- Ollama serveability vs catalog (Incident 8):
  `ssh desktop-agent 'curl -s -m 20 http://127.0.0.1:11436/api/tags'`
- Shim alias map + timeouts:
  `ssh desktop-agent 'grep -n "haiku\|opus\|fable\|sonnet\|timeout" /opt/claude-cli-server/server.py'`
- Shim liveness:
  `ssh desktop-agent 'curl -s http://127.0.0.1:4002/v1/models'`
- Tier contract source of truth: `ROUTING.md` in this repo; repo model list:
  `config/config.yaml`.

Volatile items most likely to drift: live LiteLLM version, the claude-*
overlay (whether :4002 routing became canonical), `request_timeout` values,
Gemini billing status, RunPod activation, the fable→sonnet fallback, the
dead-ollama-entries defect (pulled models or removed entries).
