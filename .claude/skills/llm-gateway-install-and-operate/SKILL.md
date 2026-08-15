---
name: llm-gateway-install-and-operate
description: >
  Install, update, and operate the llm-gateway LiteLLM proxy (systemd service
  "litellm", port 4000, host "multimedia" / 10.0.0.243). Load this skill when
  installing from scratch, running or reasoning about scripts/install.sh or
  scripts/update.sh, deploying config changes, restarting/starting/stopping the
  service, reading journalctl logs, rotating the master key, changing the port,
  or asking "where does X live on disk". This is the ONE home for deploy
  mechanics, including the mandatory guarded-update procedure that prevents
  update.sh from clobbering the live config.
---

# llm-gateway — Install and Operate

Runbook for making the gateway exist and keeping it running. The gateway is a
LiteLLM proxy running as the hardened systemd service `litellm` on the home-lab
desktop (hostname `multimedia`, LAN `10.0.0.243`), serving one
OpenAI-compatible endpoint on port **4000**. This repo contains no application
code — only config, installer scripts, a systemd unit, and docs.

Operate the desktop from the Mac via `ssh desktop-agent` (the `agent` user,
NOPASSWD sudo). Never SSH as `preston@` unless explicitly asked.

> **SAFETY-CRITICAL, read before any deploy (verified 2026-07-02):** the live
> `/etc/litellm/config.yaml` is AHEAD of the repo copy. `scripts/update.sh`
> copies the repo config over it **unconditionally** and restarts. A blind
> `update.sh` run today breaks all `claude-*` traffic. Never run `update.sh`
> without the guarded procedure in section 3.

---

## 1. Where everything lives on disk

| Path | What | Owner / mode |
|---|---|---|
| `/opt/litellm/venv/` | Python venv with `litellm[proxy]` (live: LiteLLM 1.90.1, Python 3.12, verified 2026-07-02) | `litellm:litellm` |
| `/etc/litellm/` | Config directory | `root:litellm`, `750` |
| `/etc/litellm/config.yaml` | Live model-routing config (hand-edited, currently ahead of repo — see section 3) | `root:litellm`, `640` |
| `/etc/litellm/litellm.env` | All secrets: `LITELLM_MASTER_KEY`, `GEMINI_API_KEY`, `ANTHROPIC_API_KEY`. Values NEVER leave this file — never paste them into configs, docs, skills, or logs. Delivered to the service via systemd `EnvironmentFile` (read by root systemd, not by the service user). | root-only, `600` |
| `/var/lib/litellm/` | Service user's home / `StateDirectory`. Contains only the service user's home-dir skeleton dotfiles (`.bashrc`, `.profile`, `.cache/`, etc.) — **no `litellm.db`, no SQLite DB**; spend tracking is disabled (see install trap A). The README's "Spend tracking" section is stale. | `litellm:litellm` |
| `/etc/systemd/system/litellm.service` | The unit (copy of `systemd/litellm.service` in the repo) | root |

Unit essentials (from `systemd/litellm.service`): `User=litellm`,
`EnvironmentFile=/etc/litellm/litellm.env`,
`ExecStart=/opt/litellm/venv/bin/litellm --config /etc/litellm/config.yaml
--port 4000 --host 0.0.0.0`, `Restart=always`, `RestartSec=5`,
`StateDirectory=litellm`, `WorkingDirectory=/var/lib/litellm`, plus hardening
(`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome=true`,
`PrivateTmp=true`). Note the unit's own comment: `ProtectSystem=strict`
requires `StateDirectory` for any writable path under `/var`.

---

## 2. From-scratch install runbook

### Prerequisites

- Linux with systemd
- Python 3.10+
- `openssl` (master-key generation)
- Root access

### Procedure

1. Clone and run the installer **as root on the target machine**:

   ```bash
   git clone https://github.com/preston-bernstein/llm-gateway
   cd llm-gateway
   sudo bash scripts/install.sh
   ```

2. What `install.sh` does, step by step (verified against the script 2026-07-02):

   1. Refuses to run unless EUID 0; requires `python3` on PATH.
   2. Creates system user `litellm` (`useradd -r -s /usr/sbin/nologin -d
      /var/lib/litellm -m`) if absent. Complies with the house rule that all
      desktop services run under dedicated nologin service users.
   3. Creates `/opt/litellm`, `/etc/litellm`, `/var/lib/litellm`. Ownership:
      `/opt/litellm` and `/var/lib/litellm` → `litellm:litellm`;
      `/etc/litellm` → `root:litellm` with mode `750`.
   4. Creates the venv at `/opt/litellm/venv` as the `litellm` user and pip
      installs `litellm[proxy]` (upgrading pip first).
   5. Copies `config/config.yaml` → `/etc/litellm/config.yaml` **only if
      absent** (`root:litellm`, `640`). If a config already exists it is left
      alone ("diff manually if needed").
   6. Generates `/etc/litellm/litellm.env` **only if absent**, with
      `LITELLM_MASTER_KEY=sk-litellm-$(openssl rand -hex 16)` and empty
      `GEMINI_API_KEY=` / `ANTHROPIC_API_KEY=` lines, `chmod 600`. Caution:
      the script echoes the generated master key to stdout — clear your
      terminal scrollback after install if others can see it.
   7. Copies `systemd/litellm.service` → `/etc/systemd/system/`,
      `systemctl daemon-reload`, `systemctl enable litellm.service`. It does
      **not** start the service.

3. Post-install — fill in API keys (values live only in this file, never
   anywhere else):

   ```bash
   sudo nano /etc/litellm/litellm.env
   # fill GEMINI_API_KEY and/or ANTHROPIC_API_KEY
   ```

4. Start and verify:

   ```bash
   sudo systemctl start litellm
   sudo systemctl status litellm
   curl -s http://127.0.0.1:4000/health/liveliness   # 200, no auth needed
   ```

   Authenticated check without printing the key:

   ```bash
   curl -s -H "Authorization: Bearer $(sudo grep '^LITELLM_MASTER_KEY=' /etc/litellm/litellm.env | cut -d= -f2)" \
     http://127.0.0.1:4000/v1/models
   ```

   Run the full post-change checklist from **llm-gateway-validation-and-qa**.

### Known install traps

- **Trap A — `database_url` crashes startup.** `config/config.example.yaml`
  still carries the `database_url:` line that breaks startup — copying the
  example verbatim reproduces Incident 1 (full story:
  **llm-gateway-failure-archaeology**). The real `config/config.yaml` has no
  `database_url`; there is no spend/usage DB today (`/var/lib/litellm/` holds
  only skeleton dotfiles, no `litellm.db`).
- **Trap B — `/etc/litellm` permissions.** The directory was once `root:root
  750`, which blocked the `litellm` user from traversing to read config.yaml
  (Incident 2, same commit). Correct end state: `/etc/litellm` `root:litellm
  750`; `config.yaml` `root:litellm 640`; `litellm.env` root-only `600`.
  Verify after any manual fiddling:

  ```bash
  ssh desktop-agent 'sudo ls -la /etc/litellm/'
  ```

---

## 3. THE GUARDED UPDATE PROCEDURE (mandatory before update.sh)

`scripts/update.sh` (root-only) does three things: pip-upgrades
`litellm[proxy]`, **unconditionally `cp`s the repo `config/config.yaml` over
`/etc/litellm/config.yaml`** (and resyncs the unit file + daemon-reload), then
`systemctl restart litellm`. There is no diff, no backup, no prompt.

### Why that is dangerous right now (state as of 2026-07-02)

The live config is ahead of the repo in 3 known ways (enumerated delta list:
**llm-gateway-config-and-flags**, drift section) — in one line: `claude-*` →
the local claude-cli-server on `:4002` (the Anthropic API account is out of
credits), a live-only `claude-fable-5`, and `request_timeout: 300` vs repo
`120`.

A blind `update.sh` run silently reverts `claude-*` to API-key billing (no
credits → every claude call fails) and drops `claude-fable-5`. ASSUMPTION
(coordinator-endorsed, 2026-07-02): the :4002 routing is a LOCAL OVERLAY;
whether it becomes canonical in the (public) repo is an OPEN decision
reserved for Preston — do not decide it here; see
**llm-gateway-change-control** and the reconciliation menu in
**llm-gateway-timeout-and-drift-campaign** §2.2.

### The ritual — never skip a step

1. **Diff live vs repo.** From the Mac (`-` lines = live-only, `+` lines =
   repo-only — same orientation as `config-drift.sh`):

   ```bash
   ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' \
     | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml
   ```

   On the desktop itself (substitute your clone path for `<repo>`):

   ```bash
   sudo diff -u /etc/litellm/config.yaml <repo>/config/config.yaml
   ```

   Branch on what you see:

   - **Non-empty diff** → steps 2–3 first.
   - **EMPTY diff is NOT a green light while the overlay policy is active —
     it means the live config was already clobbered** back to the repo state
     (claude-* reverted to the credit-less `anthropic/` routing). Check the
     live claude-* routing lines
     (`ssh desktop-agent 'sudo grep -n 4002 /etc/litellm/config.yaml'` —
     expect `:4002` hits); if they are gone, restore the overlay from the
     newest sane backup FIRST, per
     **llm-gateway-timeout-and-drift-campaign** Phase 0.3. An empty diff is
     only "safe to proceed" after Preston's reconciliation decision lands.

2. **Back up the live config with a timestamp — quoting matters.** The live
   box already has a file literally named `config.yaml.bak.$(date +%s)`
   because the command substitution was quoted once. Correct forms:

   On the desktop:

   ```bash
   sudo cp /etc/litellm/config.yaml /etc/litellm/config.yaml.bak.$(date +%s)
   ```

   From the Mac (single quotes are correct here — they defer expansion to the
   remote shell, which then expands `$(date +%s)` normally):

   ```bash
   ssh desktop-agent 'sudo cp /etc/litellm/config.yaml /etc/litellm/config.yaml.bak.$(date +%s)'
   ```

   Wrong (creates the literal filename): quoting the substitution inside the
   remote command, e.g. `sudo cp ... 'config.yaml.bak.$(date +%s)'`. Confirm
   the backup name looks like `config.yaml.bak.1782940343` before continuing.

3. **Preserve the overlay consciously.** Classify and gate the change per
   **llm-gateway-change-control**. Only overlay-preserving paths are allowed:
   either (a) plan to re-apply the live-only overlay lines immediately after
   update.sh's config copy (from the step-2 backup), or (b) skip update.sh's
   config-copy portion entirely (run the pip upgrade / unit resync steps
   manually and leave `/etc/litellm/config.yaml` untouched). Do NOT port the
   live-only lines into the repo config — that executes the reserved
   reconciliation Option B; porting into the repo happens only after Preston
   decides (menu: **llm-gateway-timeout-and-drift-campaign** §2.2). Never let
   update.sh be the thing that "decides".

4. **Run the update** (root, on the desktop, from the repo clone):

   ```bash
   sudo bash scripts/update.sh
   ```

   It ends with a restart and prints the first 10 lines of
   `systemctl status`.

5. **Verify.** Run the post-change checklist from
   **llm-gateway-validation-and-qa** — at minimum liveliness, `/v1/models`
   (confirm every expected model, including `claude-fable-5` if you kept the
   overlay), and one cheap completion per routing family.

---

## 4. Day-2 operations

All commands shown in both forms where relevant. Restarting the service is a
normal-operations action — see section 5 for who may do it and under what
discipline.

### Status / start / stop / restart

On the desktop:

```bash
sudo systemctl status litellm
sudo systemctl start litellm
sudo systemctl stop litellm
sudo systemctl restart litellm
```

From the Mac:

```bash
ssh desktop-agent 'sudo systemctl status litellm --no-pager'
ssh desktop-agent 'sudo systemctl restart litellm'
```

The unit has `Restart=always` / `RestartSec=5`, so a crashing proxy loops
every 5 seconds — check the journal, not just `status`, when diagnosing.

### Logs

```bash
ssh desktop-agent 'sudo journalctl -u litellm -n 100 --no-pager'   # last 100 lines
ssh desktop-agent 'sudo journalctl -u litellm --since "1 hour ago" --no-pager'
ssh desktop-agent sudo journalctl -u litellm -f                    # follow (Ctrl-C to stop)
```

Interpreting what you find there → **llm-gateway-debugging-playbook**; known
error signatures (e.g. the `APITimeoutError ... timeout value=300.0` storm of
2026-07-02) → **llm-gateway-failure-archaeology**.

### Master-key rotation

Rotation is a High-risk live mutation: gate it per
**llm-gateway-change-control** (it has a litellm.env row in the
classification table) and finish with the FULL post-change checklist from
**llm-gateway-validation-and-qa** — not just the single /v1/models check.

1. Edit the key in place (never echo or copy the value anywhere):

   ```bash
   ssh desktop-agent 'sudo sed -i "s/^LITELLM_MASTER_KEY=.*/LITELLM_MASTER_KEY=sk-litellm-$(openssl rand -hex 16)/" /etc/litellm/litellm.env'
   ```

   (Or `sudo nano /etc/litellm/litellm.env` on the desktop.)

2. Restart: `ssh desktop-agent 'sudo systemctl restart litellm'`.
3. **Update every client that holds the old key** — anything on the LAN
   pointing `OPENAI_API_BASE`/`base_url` at `http://10.0.0.243:4000`. The old
   key is dead the moment the service restarts. **Rotated-out clients do NOT
   see a 401** on this deployment: a stale/wrong key gets HTTP 400
   `"No connected db."` and a missing key gets HTTP 500 "Internal server
   error" (no-DB side effect of Incident 1 — see
   **llm-gateway-debugging-playbook** row 2). Inventory your callers before
   rotating, not after.
4. Verify with the authenticated `/v1/models` check from section 2 step 4,
   then run the full **llm-gateway-validation-and-qa** checklist.

### Port change

A port change is a High-risk unit edit + restart: gate it per
**llm-gateway-change-control** and finish with the FULL
**llm-gateway-validation-and-qa** checklist (every LAN caller hardcodes
`:4000`).

1. Edit `--port` in the `ExecStart` line of `systemd/litellm.service` in the
   repo (default 4000).
2. Redeploy the unit **manually** — do not use update.sh just for this, or
   you take the config-clobber risk of section 3 along for the ride:

   ```bash
   sudo cp <repo>/systemd/litellm.service /etc/systemd/system/litellm.service
   sudo systemctl daemon-reload
   sudo systemctl restart litellm
   ```

3. Update every client base URL, then run the full validation checklist.

---

## 5. Operational permissions

Stated explicitly (assumption endorsed by the project owner-side coordinator,
2026-07-02):

- **Normal operations:** future maintainer sessions (Claude Code or human)
  with `ssh desktop-agent` + NOPASSWD sudo **MAY restart, reconfigure, and
  modify the litellm service**, provided they follow
  **llm-gateway-change-control** gating and run the
  **llm-gateway-validation-and-qa** checks afterward.
- **Documentation-only tasks** (skill authoring, README edits, audits) must
  **NOT** touch live services — read-only SSH (`systemctl status`,
  `journalctl`, `ls`, `cat`, curl GETs) only.

If you are unsure which mode you are in, you are in documentation mode.

---

## 6. Adjacent services the gateway depends on (status checks only)

The gateway is only as healthy as its backends. Check them; operating them is
out of scope here.

| Service | Role | Status check (from the Mac) |
|---|---|---|
| `claude-cli-server` (`:4002`, unit `claude-cli-server.service`) | Live overlay target for all `claude-*` models (2026-07-02); wraps the Claude CLI. Not in this repo. | `ssh desktop-agent 'sudo systemctl status claude-cli-server --no-pager'` |
| Ollama resource broker — interactive lane | Backend for `ollama/interactive/*` (`127.0.0.1:11435` from the gateway box) | `ssh desktop-agent 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:11435/api/version'` |
| Ollama resource broker — batch lane | Backend for `ollama/batch/*` (`127.0.0.1:11436`) | `ssh desktop-agent 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:11436/api/version'` |

House rule: never point anything at raw Ollama `:11434` — broker lanes only.
Architecture and contracts for these services →
**llm-gateway-architecture-contract**; their failure modes →
**llm-gateway-failure-archaeology**.

---

## When NOT to use this skill

- **What a config option means** (`request_timeout`, `drop_params`, timeout
  layers, `os.environ/` references) → **llm-gateway-config-and-flags**.
- **Whether/how a change is allowed**, risk classification, approval gates →
  **llm-gateway-change-control**.
- **Post-change verification checklist** (this skill only points at it) →
  **llm-gateway-validation-and-qa**.
- **Full incident stories** (database_url, permissions, argv-prompt 502,
  timeout storm) → **llm-gateway-failure-archaeology**; this skill cites them
  in one line only.
- **Health-check scripts and tooling** → **llm-gateway-diagnostics-and-tooling**.
- **Live debugging of a failing request** → **llm-gateway-debugging-playbook**.
- **Which model/tier a workload should use** → **litellm-routing-reference**.
- **Resolving the config drift / timeout campaign as a project decision** →
  **llm-gateway-timeout-and-drift-campaign**.

---

## Provenance and maintenance

Written 2026-07-02 from direct reads of `scripts/install.sh`,
`scripts/update.sh`, `systemd/litellm.service`, `config/config.yaml`,
`config/config.example.yaml`, `.env.example`, and `README.md`, plus live-host
facts verified 2026-07-02 by the retiring principal (read-only SSH). Volatile
facts (drift contents, LiteLLM 1.90.1, DB-less `/var/lib/litellm`, stray
backup filenames) are date-stamped above — re-verify before relying on them:

- Drift still present? `ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - /Users/prestonbernstein/dev/llm-gateway/config/config.yaml` (`-` = live-only, `+` = repo-only)
- Scripts unchanged? `git -C /Users/prestonbernstein/dev/llm-gateway log --oneline -3 -- scripts/ systemd/`
- Service healthy? `ssh desktop-agent 'sudo systemctl status litellm --no-pager | head -5'`
- Example config still carries the bad line? `grep database_url /Users/prestonbernstein/dev/llm-gateway/config/config.example.yaml`
- Perms correct? `ssh desktop-agent 'sudo ls -la /etc/litellm/'`
- LiteLLM version? `ssh desktop-agent '/opt/litellm/venv/bin/litellm --version'`

If `update.sh` ever grows a diff/backup step, or the drift is reconciled into
the repo, rewrite section 3 accordingly.
