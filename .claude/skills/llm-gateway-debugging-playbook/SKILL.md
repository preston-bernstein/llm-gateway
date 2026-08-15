---
name: llm-gateway-debugging-playbook
description: >
  Symptom-to-triage playbook for the llm-gateway LiteLLM proxy (port 4000 on the
  home-lab desktop, 10.0.0.243). Load this skill when ANY gateway call fails or
  errors: service won't start, journalctl -u litellm shows errors, HTTP
  400/429/500/502 from :4000, error body "No connected db." (= wrong master
  key, HTTP 400 — NOT a database outage), a bare 500 "Internal server error"
  from /v1/models (= missing Authorization header), "Invalid model name passed
  in" (HTTP 400 catalog miss), "model 'X' not found" (HTTP 500 OllamaException
  on a listed ollama/* model), claude-* calls hang or time out
  (APITimeoutError), a model missing from /v1/models, latency is anomalous
  (calls taking minutes), or a response clearly came from the wrong model.
  Gives the first command to run for each symptom, expected output, and
  interpretation branches. For the KNOWN standing claude-*/:4002 300 s timeout
  problem and repo/live drift reconciliation, load
  llm-gateway-timeout-and-drift-campaign instead. Debugging here is read-only;
  fixes route to llm-gateway-change-control.
---

# llm-gateway debugging playbook

Symptom → triage for the LiteLLM gateway's real failure modes, with the
discriminating experiment for each. Every command is verified runnable
(2026-07-02). Facts marked "live" describe the deployed host, not the repo.

## Vocabulary (defined once)

| Term | Meaning |
|---|---|
| **gateway** | LiteLLM proxy, systemd unit `litellm`, port **4000** on the desktop (hostname `multimedia`, LAN 10.0.0.243). Config: `/etc/litellm/config.yaml` (live) vs `config/config.yaml` (repo — they DIFFER, see Drift). |
| **claude-cli-server** (the "shim") | FastAPI service at `/opt/claude-cli-server/server.py`, port **127.0.0.1:4002** (localhost-only — NOT reachable from the Mac directly). Wraps the `claude` CLI so claude-* gateway models run on Preston's Claude subscription. Not in this repo. |
| **broker** | resource-broker: **:11435** interactive lane, **:11436** batch lane, **:11437/jobs** durable jobs. Arbitrates GPU shared with gaming/Plex. Raw Ollama :11434 is FORBIDDEN — never test against it. |
| **master key** | `LITELLM_MASTER_KEY` in `/etc/litellm/litellm.env` (root-only, chmod 600). **Never print, echo, or copy its value.** Use it inline via the sudo-pipe pattern below. |
| **Drift** | Live config routes all claude-* models to the shim (`openai/<model>` → `api_base: http://localhost:4002/v1`); the repo config routes them to `anthropic/` API keys. Live is AHEAD of repo. `scripts/update.sh` clobbers live with repo — see Traps. |

## Ground rules

- **Debugging is read-only by default.** `systemctl status`, `journalctl`, `ls`,
  `sudo cat`, and curl GETs/POSTs to health/model endpoints are fine — plus at
  most ONE inference smoke per diagnosis when a triage row calls for it
  (a smoke consumes quota/subscription, not state — cost classes:
  **llm-gateway-validation-and-qa**). Anything
  that restarts, edits config, or reinstalls → follow
  **llm-gateway-change-control**, execute per **llm-gateway-install-and-operate**.
- Run commands from the Mac via `ssh desktop-agent '...'` (agent user,
  NOPASSWD sudo). On-desktop forms are the same minus the ssh wrapper.
  **:4002 and journalctl are only reachable via ssh**; :4000 and broker lanes
  are also reachable from the Mac directly at `10.0.0.243`.
- Never touch the master key value. The safe pattern (verified — prints models,
  not the key):

```bash
# From the Mac (note the escaped \$2 — required inside the ssh single quotes):
ssh desktop-agent 'KEY=$(sudo awk -F= "/^LITELLM_MASTER_KEY=/{print \$2}" /etc/litellm/litellm.env); curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models'

# On the desktop:
KEY=$(sudo awk -F= '/^LITELLM_MASTER_KEY=/{print $2}' /etc/litellm/litellm.env)
curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models
```

## First 60 seconds — health sweep

Run this before anything else; it localizes the fault to a layer.

```bash
ssh desktop-agent 'systemctl status litellm --no-pager | head -5; curl -s -o /dev/null -w "gateway:%{http_code}\n" http://127.0.0.1:4000/health/liveliness; curl -s -o /dev/null -w "shim:%{http_code}\n" http://127.0.0.1:4002/v1/models; curl -s http://127.0.0.1:11435/api/version; echo " (interactive lane)"; curl -s http://127.0.0.1:11436/api/version; echo " (batch lane)"'
```

Healthy baseline (verified 2026-07-02): `Active: active (running)`,
`gateway:200`, `shim:200`, and `{"version":"0.16.3"}` from both broker lanes.
`/health/liveliness` needs no auth. Any deviation → jump to the matching
triage row.

## Triage table

| # | Symptom | First command | Points to |
|---|---|---|---|
| 1 | Service won't start / restart-looping | `ssh desktop-agent 'sudo journalctl -u litellm -n 50 --no-pager'` | database_url without prisma (Incident 1), config perms (Incident 2), YAML syntax |
| 2 | Auth error from gateway (400/500 with no useful body — this deployment never returns a clean 401) | Re-run request with the sudo-pipe key pattern above | Missing vs wrong master key (see row detail) |
| 3 | claude-* call fails or times out | `ssh desktop-agent 'curl -s http://127.0.0.1:4002/v1/models'` | Direct works → timeout stack; direct fails → shim or claude CLI |
| 4 | 429 on gemini-2.5-flash | Read the 429 body; check volume of recent calls in journal | Free-tier quota wall (Incident 4). Do NOT retry-hammer |
| 5 | ollama/* model errors | `ssh desktop-agent 'curl -s http://127.0.0.1:11435/api/version; curl -s http://127.0.0.1:11436/api/version'` | HTTP 500 "model 'X' not found" = dead catalog entry (KNOWN DEFECT — see row detail); else broker lane down, or GPU yielded to gaming |
| 6 | 502 from :4002 | `ssh desktop-agent 'sudo grep -n "input=" /opt/claude-cli-server/server.py'` | Historical argv-prompt bug (Incident 3) — confirm STDIN feed still present |
| 7 | "Invalid model name" / model missing | Auth'd `GET /v1/models` (pattern above) | Client model string vs live config `model_name` mismatch; or update.sh clobbered live config |
| 8 | Response from the wrong model | Ask the model to identify itself; check shim mapping | claude-fable-5 silently runs sonnet in the shim — not a client bug |

## Row details

### 1. Service won't start

```bash
ssh desktop-agent 'sudo journalctl -u litellm -n 50 --no-pager'
ssh desktop-agent 'systemctl status litellm --no-pager'
```

Interpretation branches:

- **Prisma / database errors at startup** → someone reintroduced
  `database_url` into `/etc/litellm/config.yaml`. LiteLLM's DB-backed spend
  logging needs the prisma client (generate + migrate), which is not installed;
  with `database_url` present the proxy fails to start. This is **Incident 1**
  (commit `27b1fa0` removed the line). Trap: `config/config.example.yaml` in
  the repo STILL contains `database_url: "sqlite:////var/lib/litellm/litellm.db"`
  — copying the example verbatim reproduces the failure. Full story:
  **llm-gateway-failure-archaeology**.
- **Permission denied reading config** → check perms. Correct state
  (verified live 2026-07-02): `/etc/litellm` is `root:litellm 750`,
  `config.yaml` is `root:litellm 640`, `litellm.env` is `root:root 600`
  (delivered via systemd `EnvironmentFile`, read by root, not the service
  user). `root:root` on the dir or config breaks the `litellm` user —
  **Incident 2** (same commit).

  ```bash
  ssh desktop-agent 'sudo ls -la /etc/litellm/'
  ```

- **YAML parse error** → validate the live config without editing it:

  ```bash
  ssh desktop-agent 'sudo cat /etc/litellm/config.yaml | python3 -c "import sys,yaml; yaml.safe_load(sys.stdin); print(\"yaml OK\")"'
  ```

  Prints `yaml OK` on the current live config (verified 2026-07-02); a
  traceback pinpoints the bad line.

- Also note `Restart=always` / `RestartSec=5` in the unit: a crash-looping
  service shows repeated start attempts every ~5 s in the journal.

Fixing any of these means editing config or restarting →
**llm-gateway-change-control** first.

### 2. Auth errors (the "401" that isn't a 401)

Live observed behavior (verified 2026-07-02) — because there is no database
(Incident 1 side effect), LiteLLM cannot look up virtual keys, so auth
failures do NOT return a clean 401:

| Request | HTTP | Body |
|---|---|---|
| No `Authorization` header | **500** | `{"error":{"message":"Internal server error","type":"internal_server_error"}}` |
| Wrong key (`Bearer sk-wrong`) | **400** | `{"error":{"message":"No connected db.","type":"no_db_connection",...}}` |
| Correct master key | 200 | model list |

So: **"No connected db." means "your key is wrong", not "the DB is broken."**
There is intentionally no DB. And a bare 500 on `/v1/models` usually means the
client sent no auth header at all.

Discriminating experiment — run the same request with the known-good key via
the sudo-pipe pattern (top of this doc). If that succeeds, the client's key is
wrong or missing; fix the client, not the gateway. The key lives only in
`/etc/litellm/litellm.env` on the desktop — never print it; if a client needs
it, have Preston provision it out-of-band.

### 3. claude-* fails or times out

The discriminating experiment — direct shim vs via gateway:

```bash
# Direct to the shim (only works on the desktop / via ssh — :4002 is localhost-bound):
ssh desktop-agent 'curl -s http://127.0.0.1:4002/v1/models'
# Expected: JSON list including claude-haiku-4-5, claude-sonnet-4-6,
# claude-opus-4-8, claude-fable-5 (verified 2026-07-02).

# Via the gateway (same model, auth'd — ONE inference call, consumes the shared subscription):
ssh desktop-agent 'KEY=$(sudo awk -F= "/^LITELLM_MASTER_KEY=/{print \$2}" /etc/litellm/litellm.env); curl -s -m 360 -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" -d "{\"model\":\"claude-haiku-4-5\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with the single word ok\"}]}" http://127.0.0.1:4000/v1/chat/completions'
```

Branches:

- **Direct :4002 fails or refuses connection** → the shim or the claude CLI is
  the problem. Check `systemctl status claude-cli-server --no-pager` and its
  journal. The shim runs `claude -p` as `User=preston`; the CLI path is the
  hardcoded constant `CLAUDE_BIN = "/home/preston/.local/bin/claude"` at
  server.py line 23 (not a unit `Environment=` line). Full shim contract:
  **litellm-routing-reference** §5.
- **Direct works, gateway path dies with a timeout** → it's the timeout stack.
  Signature in the journal (verbatim, observed 2026-07-02, cluster ~08:01–09:22):
  `litellm.Timeout: APITimeoutError - Request timed out. ... timeout value=300.0, time taken=300.0 seconds`
  — an error at **exactly** the `request_timeout` value means LiteLLM gave up
  waiting on :4002. Three misaligned timeout layers exist: LiteLLM
  `request_timeout` (live **300**, repo 120) → shim per-request `timeout` body
  param (default 180) → subprocess timeout; the shim's streaming path has no
  timeout at all. Authoritative layer table: **llm-gateway-config-and-flags**.
  This is Incident 6, still OPEN — remediation plan lives in
  **llm-gateway-timeout-and-drift-campaign**.
- **Slow but succeeding is NORMAL.** Expected baseline: even trivial claude-*
  calls take **60–120 s** through the CLI. Do not treat 90 s as a failure. Do
  not use claude-* for bulk work — sustained use rate-limits Preston's shared
  Claude subscription (Incident 5); bulk goes LOCAL via the broker.
- **All claude-* suddenly failing with API-key/credit errors** → suspect an
  update.sh clobber reverted the live config to `anthropic/` API routing (the
  Anthropic API account has no credits). Confirm with:

  ```bash
  ssh desktop-agent 'sudo grep -A3 "model_name: claude-sonnet" /etc/litellm/config.yaml'
  # Healthy live state shows: model: openai/claude-sonnet-4-6,
  # api_base: http://localhost:4002/v1  (verified 2026-07-02)
  # anthropic/claude-sonnet-4-6 + ANTHROPIC_API_KEY means the repo config clobbered live.
  ```

### 4. 429 on gemini-2.5-flash

Free-tier quota wall (**Incident 4**, 2026-07-01/02): gemini-2.5-flash 429s
under bulk load; billing is currently OFF on the Gemini account (as of
2026-07-02). Interpretation: this is a quota policy fact, not a gateway bug.

- **Do NOT retry-hammer.** Retries burn the remaining quota and fix nothing.
- Route bulk work to the LOCAL tier (`ollama/batch/*` via the broker) — that
  is the tier contract's bulk workhorse (see `ROUTING.md` and
  **litellm-routing-reference**).
- If a one-off interactive call 429s, wait for the quota window to reset.

### 5. ollama/* model errors

```bash
ssh desktop-agent 'curl -s http://127.0.0.1:11435/api/version; echo; curl -s http://127.0.0.1:11436/api/version; echo'
# Both lanes returned {"version":"0.16.3"} on 2026-07-02.
# From the Mac directly: curl -s http://10.0.0.243:11435/api/version
```

Branches:

- **HTTP 500 `model '<name>' not found` (OllamaException) on a model that IS
  in /v1/models** → the KNOWN DEFECT (2026-07-02, open): 3 of the 4 `ollama/*`
  catalog entries (`ollama/interactive/qwen2.5`, `ollama/batch/qwen2.5:3b`,
  `ollama/batch/qwen2.5:7b`) point at Ollama models that were never pulled —
  catalog presence ≠ serveability. Only `ollama/batch/qwen3-vl:30b` serves.
  Do NOT chase this as a broker or gateway regression. Re-check what Ollama
  actually serves and see the full KNOWN DEFECT note in
  **llm-gateway-diagnostics-and-tooling**; incident record: Incident 8 in
  **llm-gateway-failure-archaeology**. Fixing it (pull models or re-point/
  remove entries) → **llm-gateway-change-control**.
- **Lane unreachable** → broker problem; broker repo is
  `~/dev/resource-broker` on the desktop. Check its service status
  (read-only) before anything else.
- **Lane up but calls stall/queue** → the GPU may be yielded to gaming or
  Plex; the broker arbitrates and this is by design. Wait or use the durable
  jobs lane (:11437/jobs) for long batch work.
- **NEVER test against raw Ollama :11434.** House rule. A "successful" :11434
  test proves nothing about the supported path and bypasses arbitration.
- Gateway config maps `ollama/interactive/*` → `127.0.0.1:11435` and
  `ollama/batch/*` → `127.0.0.1:11436` (localhost because gateway and broker
  share the box).

### 6. 502 from :4002

Historical cause (**Incident 3**, fixed 2026-07-02): the shim originally
passed the prompt as a CLI argument; prompts starting with `---Task---` were
parsed as CLI flags → 502. The fix feeds the prompt via **STDIN**. If 502s
recur, first confirm the fix is still in place:

```bash
ssh desktop-agent 'sudo grep -n "input=" /opt/claude-cli-server/server.py'
# Expect subprocess.run(..., input=prompt) — STDIN feed present.
```

If STDIN feed is present and 502s persist, check the shim's own journal for
the underlying CLI failure (exit code, stderr). Full incident narrative:
**llm-gateway-failure-archaeology**.

### 7. Model name not found

Error shape from the gateway (verified 2026-07-02, HTTP 400):
`"Invalid model name passed in model=<name>. Call /v1/models to view available models for your key."`

```bash
ssh desktop-agent 'KEY=$(sudo awk -F= "/^LITELLM_MASTER_KEY=/{print \$2}" /etc/litellm/litellm.env); curl -s -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models'
```

Live catalog (2026-07-02): `gemini-2.5-flash`, `gemini-2.5-pro`,
`claude-sonnet-4-6`, `claude-haiku-4-5`, `claude-opus-4-8`, `claude-fable-5`,
`ollama/interactive/qwen2.5`, `ollama/batch/qwen2.5:3b`,
`ollama/batch/qwen2.5:7b`, `ollama/batch/qwen3-vl:30b`. (Caveat: the three
`qwen2.5*` ollama entries are listed but NOT serveable — row 5's known
defect.)

Branches:

- **Client typo / stale name** → fix the client to use an exact `model_name`
  from the list. Names are exact strings including the `ollama/...` prefixes.
- **A model that used to exist is gone** (especially `claude-fable-5`, which
  exists ONLY in the live config, not the repo) → strong signal that
  `update.sh` clobbered the live config. Verify per row 3's grep. Restoring it
  is a config change → **llm-gateway-change-control**.

### 8. Response came from the wrong model

Known, by design (verified in `/opt/claude-cli-server/server.py`,
2026-07-02): the shim maps model name → claude CLI alias by substring —
haiku→haiku, opus→opus, **fable→sonnet** ("fable" is not a CLI alias yet),
anything else→sonnet. So `claude-fable-5` through the gateway **silently runs
sonnet**. This is not a bug in your client and not a gateway routing error.
If exact-model fidelity matters for a task, do not use `claude-fable-5` via
this gateway. Changing the mapping is a shim change (outside this repo) —
route through **llm-gateway-change-control**.

## Traps that cost real time

One-liners only — full stories in **llm-gateway-failure-archaeology**.

- **argv 502**: shim passed prompts as CLI args; `---Task---` prompts parsed
  as flags → 502s until the STDIN fix (Incident 3).
- **database_url startup failure**: one config line (`database_url:` sqlite)
  killed startup because prisma wasn't installed; the bad line STILL sits in
  `config/config.example.yaml` waiting to be copied (Incident 1).
- **update.sh clobber**: `scripts/update.sh` copies the repo config over
  `/etc/litellm/config.yaml` **unconditionally** and restarts. Running it
  today reverts claude-* to credit-less API billing (all claude-* calls fail)
  and deletes `claude-fable-5`. Diff before ever running it — see
  **llm-gateway-change-control**.
- **`config.yaml.bak.$(date +%s)`**: `/etc/litellm/` contains a backup file
  literally named with an unexpanded `$(date +%s)` (someone single-quoted the
  command substitution). Harmless, but it confuses directory listings and
  shell globs — it is a filename, not an injection.
- **"No connected db." on auth failure**: reads like a database outage; it
  actually means "wrong key, and there is no DB to look up virtual keys in"
  (row 2).

## When NOT to use this skill

- **Making any fix** (edit config, restart, reinstall, rotate keys) →
  **llm-gateway-change-control** for the discipline,
  **llm-gateway-install-and-operate** for the commands.
- **What the flags/timeouts mean and their authoritative values** →
  **llm-gateway-config-and-flags**.
- **Full incident narratives and root-cause history** →
  **llm-gateway-failure-archaeology**.
- **Latency/throughput measurement scripts** →
  **llm-gateway-diagnostics-and-tooling**.
- **The plan to fix the timeout stack and repo/live drift** →
  **llm-gateway-timeout-and-drift-campaign**.
- **Which model/tier to pick for a workload** → **litellm-routing-reference**
  and `ROUTING.md`.
- **System boundaries / what owns what** → **llm-gateway-architecture-contract**.

## Provenance and maintenance

Written 2026-07-02 from direct repo reads and live read-only SSH verification
of every command above (service status, journal signatures, all HTTP status
codes and bodies quoted). Volatile facts (live config drift, model catalog,
timeout values, Gemini billing OFF, broker version 0.16.3) are date-stamped
2026-07-02 — re-verify before trusting:

- Service + version: `ssh desktop-agent 'systemctl status litellm --no-pager | head -5'`
- Live model catalog: auth'd `GET /v1/models` (sudo-pipe pattern, top of doc)
- Drift still present: `ssh desktop-agent 'sudo grep -A3 "model_name: claude-sonnet" /etc/litellm/config.yaml'` (expect `api_base: http://localhost:4002/v1`)
- Live timeout: `ssh desktop-agent 'sudo grep request_timeout /etc/litellm/config.yaml'` (was 300)
- Shim STDIN fix: `ssh desktop-agent 'sudo grep -n "input=" /opt/claude-cli-server/server.py'`
- Broker lanes: `ssh desktop-agent 'curl -s http://127.0.0.1:11435/api/version; curl -s http://127.0.0.1:11436/api/version'`
- Auth error shapes: repeat row 2's no-header / wrong-key curls (expect 500 / 400 "No connected db." while the no-DB state persists)
