---
name: llm-gateway-config-and-flags
description: >
  Complete configuration reference for the llm-gateway LiteLLM proxy — every
  setting across all four config axes (config.yaml, /etc/litellm/litellm.env,
  systemd/litellm.service, install-script constants), repo-vs-live drift, and
  THE canonical timeout-layers table. Load this skill whenever you are: reading
  or editing config/config.yaml or /etc/litellm/config.yaml; touching
  /etc/litellm/litellm.env or .env.example; reading or editing
  systemd/litellm.service; adding, renaming, or removing a model entry;
  changing any timeout (request_timeout, shim timeout, client timeout);
  activating the RunPod block; changing the gateway port; or answering "what
  does setting X do / what is its current value?"
---

# llm-gateway — Configuration and Flags

**What this system is (one paragraph of context):** `llm-gateway` deploys a
LiteLLM proxy — an off-the-shelf Python server that presents one
OpenAI-compatible HTTP endpoint and fans requests out to many model providers —
as a hardened systemd service on the home-lab desktop (host `multimedia`,
LAN IP `10.0.0.243`, port `4000`). The repo at
`/Users/prestonbernstein/dev/llm-gateway` (public GitHub:
`preston-bernstein/llm-gateway`) contains only config, install scripts, a
systemd unit, and docs — no application code. This skill is the single
authoritative inventory of every configuration knob and where it lives.

**Volatile facts in this file are date-stamped 2026-07-02** (verified by direct
repo reads + read-only SSH to the live host). Re-verify with the commands in
"Provenance and maintenance" before acting on them.

## The one fact you must not get wrong: CONFIG DRIFT

The live config `/etc/litellm/config.yaml` on the desktop is **AHEAD of** the
repo config `config/config.yaml`. **This section is the enumerated delta
list's one home — sibling skills cite "the 3 known deltas" and point here.**
As of 2026-07-02 the live file differs in three ways:

1. All four `claude-*` entries route to `openai/<name>` with
   `api_base: http://localhost:4002/v1` (the local **claude-cli-server**, a
   FastAPI shim that wraps the `claude` CLI using Preston's Claude
   subscription). The repo routes them to `anthropic/<name>` with
   `os.environ/ANTHROPIC_API_KEY` (API-key billing — **that account is out of
   credits**, so the repo routing does not work today).
2. Live adds `claude-fable-5` (not in the repo config at all).
3. Live `request_timeout: 300`; repo says `120`.

ASSUMPTION (coordinator-endorsed, 2026-07-02): the live `:4002` routing is a
**local overlay**; whether it becomes canonical in the public repo is an OPEN
decision reserved for Preston (decision menu:
`llm-gateway-timeout-and-drift-campaign` §2.2). Do not decide repo policy
yourself.

**Always check both files before reasoning about "the config".** Drift-check
one-liner (run from the Mac; read-only; `-` lines = live-only, `+` lines =
repo-only, same orientation as `config-drift.sh`):

```bash
ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' \
  | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml \
  && echo "NO DRIFT" || echo "DRIFT — live differs from repo (expected as of 2026-07-02)"
```

Caution: `NO DRIFT` while the overlay policy is active means the live config
was probably CLOBBERED (see the safety warning below) — verify the claude-*
routing lines before treating it as good news.

**SAFETY-CRITICAL — update.sh clobbers the live config.**
`scripts/update.sh` runs `cp "$REPO_DIR/config/config.yaml"
"$CONFIG_DIR/config.yaml"` **unconditionally**, then restarts the service.
Running `sudo bash scripts/update.sh` today would silently revert all
`claude-*` traffic to the credit-less Anthropic API (every claude call fails),
drop `claude-fable-5`, and lower `request_timeout` back to 120. Never run it
without the guarded procedure in `llm-gateway-install-and-operate` (back up
live config, diff, reconcile first).

## The four configuration axes

| Axis | File | Lives where | Deployed how |
|---|---|---|---|
| 1. Model catalog + LiteLLM settings | `config/config.yaml` (repo) → `/etc/litellm/config.yaml` (live) | repo + desktop | `install.sh` copies only if absent; `update.sh` copies unconditionally (clobber) |
| 2. Secrets | `/etc/litellm/litellm.env` (shape documented by `.env.example`) | desktop only, never in git | generated once by `install.sh`; hand-edited after |
| 3. Service definition | `systemd/litellm.service` → `/etc/systemd/system/litellm.service` | repo + desktop | copied by both scripts + `systemctl daemon-reload` |
| 4. Filesystem layout constants | hardcoded at the top of `scripts/install.sh` / `scripts/update.sh` | repo | take effect at install time |

---

## Axis 1: config.yaml — full settings inventory

### model_list (2026-07-02)

Each entry maps a public `model_name` (what callers put in the `model` field)
to `litellm_params` (real provider, backend URL, key reference). "Backend"
below = `model:` prefix + `api_base`/`api_key`.

| model_name | Repo backend | Live backend (2026-07-02) | Status |
|---|---|---|---|
| `gemini-2.5-flash` | `gemini/gemini-2.5-flash`, `os.environ/GEMINI_API_KEY` | same | Production. FAST tier. Free-tier quota — 429s under bulk load (see `llm-gateway-failure-archaeology`, Incident 4) |
| `gemini-2.5-pro` | `gemini/gemini-2.5-pro`, `os.environ/GEMINI_API_KEY` | same | Production. FRONTIER tier |
| `claude-sonnet-4-6` | `anthropic/claude-sonnet-4-6`, `os.environ/ANTHROPIC_API_KEY` | `openai/claude-sonnet-4-6`, `api_base: http://localhost:4002/v1`, `api_key: "none"` | Active via live overlay (Incident 6 OPEN). MID tier |
| `claude-haiku-4-5` | `anthropic/claude-haiku-4-5-20251001` (note: repo pins the dated snapshot), `os.environ/ANTHROPIC_API_KEY` | `openai/claude-haiku-4-5` (undated), `api_base: http://localhost:4002/v1`, `api_key: "none"` | Active via live overlay (Incident 6 OPEN) |
| `claude-opus-4-8` | `anthropic/claude-opus-4-8`, `os.environ/ANTHROPIC_API_KEY` | `openai/claude-opus-4-8`, `api_base: http://localhost:4002/v1`, `api_key: "none"` | Active via live overlay (Incident 6 OPEN). FRONTIER tier |
| `claude-fable-5` | **absent from repo** | `openai/claude-fable-5`, `api_base: http://localhost:4002/v1`, `api_key: "none"` | **Live-only.** WARNING: the :4002 shim has no `fable` CLI alias — it silently runs **sonnet** for this name (verified 2026-07-02, principal) |
| `runpod/qwen2.5-72b` | commented out in both repo and live | commented out | **Dormant template.** See "Activating RunPod" below |
| `ollama/interactive/qwen2.5` | `ollama/qwen2.5`, `api_base: http://127.0.0.1:11435` | same | **LISTED BUT NOT SERVEABLE (model not pulled, 2026-07-02)** — calls return HTTP 500 `model not found`. LOCAL tier, broker interactive lane. Known defect: `llm-gateway-diagnostics-and-tooling` / Incident 8 |
| `ollama/batch/qwen2.5:3b` | `ollama/qwen2.5:3b`, `api_base: http://127.0.0.1:11436` | same | **LISTED BUT NOT SERVEABLE (model not pulled, 2026-07-02)**. LOCAL tier, broker batch lane |
| `ollama/batch/qwen2.5:7b` | `ollama/qwen2.5:7b`, `api_base: http://127.0.0.1:11436` | same | **LISTED BUT NOT SERVEABLE (model not pulled, 2026-07-02)** |
| `ollama/batch/qwen3-vl:30b` | `ollama/qwen3-vl:30b`, `api_base: http://127.0.0.1:11436` | same | Production — the only serveable `ollama/*` entry (2026-07-02). Vision |

Notes:

- The `api_key: "none"` on live claude entries is a literal placeholder — the
  `openai/` provider path requires *some* api_key value; the :4002 shim
  ignores it. It is not a secret.
- Ollama entries use `127.0.0.1` because the gateway runs on the same box as
  the **resource-broker** (`:11435` interactive, `:11436` batch).
  House rule: never point anything at raw Ollama `:11434`.
- Tier assignments (LOCAL/FAST/MID/FRONTIER) and provider-prefix theory
  (`gemini/` vs `anthropic/` vs `openai/` vs `ollama/`) are owned by
  `litellm-routing-reference` — this table only records what is configured.

### general_settings

| Key | Value (repo and live identical) | Effect |
|---|---|---|
| `master_key` | `os.environ/LITELLM_MASTER_KEY` | Bearer token every caller must send (`Authorization: Bearer sk-litellm-...`). The `os.environ/` prefix tells LiteLLM to read the value from the environment (injected by systemd `EnvironmentFile`) — never a literal key in YAML |
| `disable_master_key_return` | `true` | Prevents LiteLLM from echoing the master key back in API responses (key-management endpoints) |

### litellm_settings

| Key | Repo | Live (2026-07-02) | Effect |
|---|---|---|---|
| `request_timeout` | `120` | **`300`** | Seconds LiteLLM waits for the upstream provider before raising `litellm.exceptions.Timeout` (surfaces as an APITimeoutError in `journalctl -u litellm`). Live was raised 120→300 as a mitigation for slow claude-cli-server calls; still being hit — see timeout table below |
| `drop_params` | `true` | `true` | Silently drops request params the target provider does not support instead of erroring. Keeps Ollama clients compatible. **Caveat:** a typo'd or unsupported param fails *silently* — never conclude a param "worked" just because the call returned 200 |
| `redact_user_api_key_info` | `true` | `true` | Redacts API-key info from LiteLLM's logs |

### config.example.yaml — do NOT copy verbatim

`config/config.example.yaml` still contains
`database_url: "sqlite:////var/lib/litellm/litellm.db"` — that line breaks
startup (Incident 1 — full story in `llm-gateway-failure-archaeology`). No
spend/usage DB exists today (`/var/lib/litellm/` contains only home-dir
skeleton dotfiles, no `litellm.db`); README.md's "Spend tracking" section is
stale. The example also lacks `disable_master_key_return` and has the RunPod
block uncommented.

---

## Axis 2: environment file — /etc/litellm/litellm.env

Real file lives only on the desktop at `/etc/litellm/litellm.env`
(root-owned, `chmod 600`, never committed; `.gitignore` excludes `*.env`).
`.env.example` in the repo documents its shape. **Never reproduce the file's
contents or paste key values anywhere — reference the location only.**

| Variable | Consumed by | Provisioning |
|---|---|---|
| `LITELLM_MASTER_KEY` | `general_settings.master_key` | Generated by `install.sh` as `sk-litellm-$(openssl rand -hex 16)` — only if the file does not already exist |
| `GEMINI_API_KEY` | both `gemini/*` entries | Blank line written by `install.sh`; filled by hand |
| `ANTHROPIC_API_KEY` | repo `anthropic/*` claude entries | Blank line written by `install.sh`; filled by hand. **Unused by the live overlay** (claude-* goes to :4002); the Anthropic API account is out of credits (2026-07-02) |
| `RUNPOD_API_KEY` | dormant RunPod entry | Listed in `.env.example` but **NOT written by `install.sh`** (the script's heredoc only emits the three above) — activating RunPod means adding this line by hand |

Delivery mechanism: the systemd unit's `EnvironmentFile=/etc/litellm/litellm.env`
directive injects these into the process environment. systemd (running as
root) reads the file, so the `litellm` service user never needs filesystem
read access to it — that is why `600 root:root` works. The config dir itself
is `750 root:litellm` and `config.yaml` is `640 root:litellm` so the service
user *can* read the YAML (this exact split was Incident 2 — dir was once
`root:root` and the service could not start).

Rotating the master key = edit `litellm.env`, restart the service, update
every caller (change-control applies — see `llm-gateway-change-control`).

---

## Axis 3: systemd unit — litellm.service, every directive

Repo `systemd/litellm.service` and live
`/etc/systemd/system/litellm.service` are **identical** as of 2026-07-02 (no
drift on this axis).

| Directive | Value | Effect |
|---|---|---|
| `Description` / `Documentation` | LiteLLM AI Gateway / repo URL | cosmetic |
| `After=` / `Wants=network-online.target` | — | start only once the network is up |
| `Type=simple` | — | ExecStart is the main process, no forking |
| `User=` / `Group=litellm` | `litellm` | runs as the dedicated nologin service user (house rule: all desktop services do) |
| `EnvironmentFile` | `/etc/litellm/litellm.env` | injects API keys (Axis 2) |
| `ExecStart` | `/opt/litellm/venv/bin/litellm --config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0` | **Port and bind address live HERE, not in config.yaml.** `--host 0.0.0.0` = listen on all interfaces (LAN-reachable at 10.0.0.243:4000). Changing the port = edit `--port` in the unit and redeploy (per README) — but redeploying touches `update.sh`/copy steps, so follow the guarded procedure in `llm-gateway-install-and-operate` and remember every caller hardcodes `:4000` |
| `Restart=always` / `RestartSec=5` | — | auto-restart on any exit, 5 s backoff. Side effect: a crash-looping config change shows repeated restarts in `journalctl`, not a single clean failure |
| `StateDirectory=litellm` | — | systemd creates `/var/lib/litellm` owned by the service user, **and carves it out as writable despite `ProtectSystem=strict`** |
| `WorkingDirectory` | `/var/lib/litellm` | process cwd |
| `NoNewPrivileges=true` | — | process and children can never gain privileges |
| `ProtectSystem=strict` | — | entire filesystem read-only to the service **except** paths whitelisted by directives like `StateDirectory`. Interaction to remember: any new writable path under `/var` needs a `StateDirectory` (or equivalent) entry, or writes will fail with EROFS — the unit file's own comment says exactly this |
| `ProtectHome=true` | — | `/home`, `/root` invisible to the service |
| `PrivateTmp=true` | — | private `/tmp` namespace |
| `WantedBy=multi-user.target` | — | enabled at normal boot |

---

## Axis 4: install-script constants

Hardcoded at the top of `scripts/install.sh` (update.sh repeats `VENV` and
`CONFIG_DIR`):

| Constant | Value | Meaning |
|---|---|---|
| `VENV` | `/opt/litellm/venv` | Python venv holding `litellm[proxy]` (live version 1.90.1, Python 3.12, 2026-07-02) |
| `CONFIG_DIR` | `/etc/litellm` | config.yaml + litellm.env |
| `DATA_DIR` | `/var/lib/litellm` | service user's home / StateDirectory (contains only home-dir skeleton dotfiles — no `litellm.db`, no DB; see Incident 1) |
| `SERVICE_USER` | `litellm` | nologin system user, home `DATA_DIR` |
| `PORT` | `4000` | **display-only** in install.sh (used in the final banner). The port that actually binds comes from `--port 4000` in the unit's ExecStart. Change one without the other and the install banner lies |

Also on the live box as of 2026-07-02: two manual backups sit in
`/etc/litellm/` — `config.yaml.bak.1782940343` and a file literally named
`config.yaml.bak.$(date +%s)` (someone single-quoted the command substitution;
harmless, but don't be confused by it — and don't mistake either for the live
config).

---

## THE TIMEOUT LAYERS TABLE (canonical home — other skills link here)

A request to a `claude-*` model traverses up to four independent timeouts.
They are **not aligned** (open problem, 2026-07-02). Path:
caller → LiteLLM :4000 → claude-cli-server shim :4002
(`/opt/claude-cli-server/server.py`, not in this repo) → `claude` CLI
subprocess.

| # | Layer | Where set | Value (2026-07-02) | Applies to |
|---|---|---|---|---|
| 0 | Client timeout | caller's HTTP client (OpenAI SDK `timeout=`, httpx, curl `--max-time`) | caller-defined; many SDKs default to several hundred seconds | every request |
| 1 | LiteLLM `request_timeout` | `litellm_settings` in `/etc/litellm/config.yaml` | **live 300 / repo 120** | every model, streaming and non-streaming |
| 2 | Shim per-request `timeout` body param | JSON body of the request the shim receives | **default 180**; caller-overridable per request | `claude-*` **non-streaming only** |
| 3 | Shim subprocess timeout | `subprocess.run(..., timeout=...)` in server.py | = layer 2's value (the `_run_claude` signature default of 600 is always overridden by the handler's 180 body default) | `claude-*` non-streaming |
| 4 | Streaming path | `Popen` in server.py | **NONE — unbounded** | `claude-*` streaming |

Which layer fires first, by scenario:

- **Non-streaming claude-*, defaults everywhere:** shim's 180 s (layers 2/3)
  fires first — the subprocess is killed at 180 and the shim returns an error
  before LiteLLM's 300 s is reached.
- **Non-streaming claude-* with body `timeout` raised above 300:** LiteLLM's
  300 s (layer 1) fires first; the CLI subprocess on :4002 keeps running as an
  orphan doing unusable work.
- **Streaming claude-*:** the shim has no timeout at all (layer 4), so
  LiteLLM's 300 s is the only server-side bound.
- **Gemini / Ollama models:** only layers 0 and 1 exist — live 300 s, or the
  client's own timeout if smaller.
- **Client timeout smaller than everything:** caller aborts first, but the
  backend work continues to burn until a server-side layer kills it.

**The 2026-07-02 incident:** `journalctl -u litellm` (error cluster
~08:01–09:22) shows
repeated `litellm.exceptions.Timeout: APITimeoutError ... timeout value=300.0,
time taken=300.0 seconds` on the aiohttp transport. That is **layer 1 —
LiteLLM's live 300 s — firing** on claude-* calls that sat the full duration
(consistent with the streaming/no-shim-timeout path, since a default
non-streaming call would have died at 180 s first). Root cause is OPEN; the
120→300 raise was a mitigation that still gets hit. Incident narrative:
`llm-gateway-failure-archaeology`. Remediation/alignment options:
`llm-gateway-timeout-and-drift-campaign`. Background: even trivial prompts
through the CLI shim take 60–120 s, so these budgets are tight by design
reality, not misconfiguration alone.

If you change any timeout value, update this table and the live config (via
change control) — and the repo config ONLY IF the new value is canonical. A
live-only (overlay) timeout change does NOT get synced into the repo — that
would pre-decide the reserved reconciliation question; instead it widens the
documented drift and gets recorded in the drift record (see
`llm-gateway-timeout-and-drift-campaign`, Phase 2). A change to only one
layer with no record is how this mismatch happened.

---

## Procedure: adding a new model entry

1. **Pick the provider prefix** for `litellm_params.model` (`gemini/`,
   `anthropic/`, `openai/` + `api_base` for any OpenAI-compatible server,
   `ollama/` + broker `api_base`). Prefix semantics and tier placement:
   `litellm-routing-reference`. House rule: local models use broker ports
   `127.0.0.1:11435` (interactive) or `:11436` (batch) — never raw `:11434`.
2. **Edit the repo file** `config/config.yaml` (for a CANONICAL model
   addition, never hand-edit only the live file — that widens the drift;
   overlay-only changes are a separate, gated change class — see
   `llm-gateway-change-control`'s classification table. And never edit only
   the repo and run update.sh — that clobbers the overlay). Keys must be `os.environ/<VAR>` references; if
   a new env var is needed, add it to `.env.example` (name only) and to the
   live `/etc/litellm/litellm.env` by hand on the desktop.
3. **Pass change-control gates** — `llm-gateway-change-control` (this is a
   shared production service; algo-factory and the financial pipeline call it).
4. **Deploy via the guarded procedure** in `llm-gateway-install-and-operate`
   (back up live config → apply reconciled config → restart). Do NOT run bare
   `sudo bash scripts/update.sh` while the drift exists.
5. **Verify** per `llm-gateway-validation-and-qa`: the new name appears in
   `/v1/models` and a one-shot completion succeeds.
6. **drop_params caveat:** because `drop_params: true`, a wrong or
   unsupported `litellm_params` extra won't necessarily error — validate by
   observing actual behavior (latency, output), not just HTTP 200.

## Procedure: activating the dormant RunPod block

The RunPod entry (`runpod/qwen2.5-72b`) is commented out in both repo and live
configs — a template only. To activate: deploy a RunPod serverless vLLM
endpoint, uncomment the block, replace `RUNPOD_ENDPOINT_ID` in the `api_base`
URL, add `RUNPOD_API_KEY=<key>` to `/etc/litellm/litellm.env` (install.sh does
not create that line), then follow steps 3–5 above. Until all of that is done,
`runpod/*` names in ROUTING.md's MID tier are aspirational — calls to them
fail.

---

## When NOT to use this skill

- **Why the tiers exist / which model a service should call / provider-prefix
  theory** → `litellm-routing-reference`
- **Install/uninstall steps, restart discipline, the guarded deploy procedure,
  full update.sh clobber remediation** → `llm-gateway-install-and-operate`
- **What gates a change must pass before touching production** →
  `llm-gateway-change-control`
- **Full incident narratives (database_url startup failure, permissions,
  argv-prompt 502, quota wall, timeout incident story)** →
  `llm-gateway-failure-archaeology`
- **Fixing the timeout mismatch / reconciling repo↔live drift (decision
  menu)** → `llm-gateway-timeout-and-drift-campaign`
- **Live debugging of a failing request right now** →
  `llm-gateway-debugging-playbook`
- **System boundaries and what the gateway does/doesn't own** →
  `llm-gateway-architecture-contract`
- **Smoke tests and health checks** → `llm-gateway-validation-and-qa`

## Provenance and maintenance

All facts verified 2026-07-02 by direct repo reads plus read-only SSH
(`ssh desktop-agent`) to the live host. Key values were never read or copied —
only variable names and file locations. Re-verify each volatile axis before
relying on it:

- **Repo↔live config drift** (`-` = live-only, `+` = repo-only):
  `ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml`
- **Live config fingerprint (quick change detection):**
  `ssh desktop-agent 'sudo sha256sum /etc/litellm/config.yaml && sudo stat -c "%y" /etc/litellm/config.yaml'`
- **Live request_timeout value:**
  `ssh desktop-agent 'sudo grep -n request_timeout /etc/litellm/config.yaml'`
- **Served model list (uses the key without displaying it):**
  `ssh desktop-agent 'sudo bash -c "set -a; . /etc/litellm/litellm.env; curl -s -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" http://127.0.0.1:4000/v1/models" | python3 -c "import sys,json;[print(m[\"id\"]) for m in json.load(sys.stdin)[\"data\"]]"'`
- **Unit-file drift:**
  `ssh desktop-agent 'cat /etc/systemd/system/litellm.service' | diff /Users/prestonbernstein/dev/llm-gateway/systemd/litellm.service -`
- **Live LiteLLM version:**
  `ssh desktop-agent 'sudo -u litellm /opt/litellm/venv/bin/litellm --version'`
- **Shim timeout defaults (layers 2–4):**
  `ssh desktop-agent 'grep -n "timeout" /opt/claude-cli-server/server.py'`
- **Ollama entries still unserveable (Incident 8):**
  `ssh desktop-agent 'curl -s -m 20 http://127.0.0.1:11436/api/tags'` — compare against the `ollama/*` model_list rows
