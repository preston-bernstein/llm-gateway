---
name: llm-gateway-change-control
description: >
  Change control for the llm-gateway repo and the live LiteLLM service on the
  desktop (10.0.0.243:4000). Load this skill BEFORE making ANY change to
  config/config.yaml, config/config.example.yaml, scripts/, systemd/litellm.service,
  README.md, ROUTING.md, or the live files under /etc/litellm on the desktop.
  Load it when asked to deploy, "sync config", run scripts/update.sh or
  scripts/install.sh, restart litellm after a config change, edit the live
  config, or update project docs. It defines the change classification table,
  the mandatory pre-deploy live-vs-repo diff gate, the update.sh clobber
  warning, the backup procedure, the non-negotiable rules, and the docs-of-record
  discipline.
---

# llm-gateway change control

**Minimum kit for any live change: this skill (gates) +
llm-gateway-install-and-operate (mechanics) + llm-gateway-validation-and-qa
(post-change checklist).**

How changes to this project are classified, gated, and reviewed. This project is
config + scripts + docs deploying a **LiteLLM proxy** (an OpenAI-compatible HTTP
gateway that fronts multiple LLM providers) as a systemd service on the home-lab
desktop (`multimedia`, 10.0.0.243, port 4000). There is no application code, no
tests, no CI — discipline lives in this procedure, not in a pipeline.

Terms used once, defined once:

- **Repo** — `/Users/prestonbernstein/dev/llm-gateway` on the Mac. Public GitHub
  repo (`github.com/preston-bernstein/llm-gateway`).
- **Live box / live config** — the desktop, reached via `ssh desktop-agent`
  (agent user, NOPASSWD sudo). Live config is `/etc/litellm/config.yaml`,
  secrets in `/etc/litellm/litellm.env` (root-only, 600 — never read its values
  into any file or chat).
- **Drift** — the live config is intentionally AHEAD of the repo in 3 known
  ways (verified 2026-07-02; enumerated delta list:
  **llm-gateway-config-and-flags**, drift section — in one line: claude-* →
  the :4002 shim, live-only `claude-fable-5`, `request_timeout` 300 vs 120).
  ASSUMPTION (coordinator-endorsed, 2026-07-02): the live :4002 routing is a
  LOCAL OVERLAY; whether it becomes canonical in the public repo is an OPEN
  decision reserved for Preston. Full remediation menu:
  **llm-gateway-timeout-and-drift-campaign**.
- **Broker** — the resource-broker; the only allowed path to local
  Ollama inference (ports 11435 interactive / 11436 batch; `127.0.0.1` from
  the gateway box itself).

## THE ONE RULE THAT PREVENTS AN OUTAGE

> **NEVER run `scripts/update.sh` without first diffing live vs repo.**
> `update.sh` copies `config/config.yaml` over `/etc/litellm/config.yaml`
> **unconditionally** (`cp "$REPO_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"`,
> line 16), then restarts the service. As of 2026-07-02 that overwrite would
> silently revert all `claude-*` traffic to Anthropic API-key billing — an
> account with **no credits**, so every claude-* call fails — and would drop
> the `claude-fable-5` model and lower `request_timeout` 300→120.
> `install.sh` is safer (it skips config copy if the file exists), but the
> same diff gate applies before any deploy.

## Change classification

Classify every change before touching anything. "Touches live" means the change
alters behavior on the desktop (immediately, or at next deploy).

| Change | Risk | Touches live? | Required verification |
|---|---|---|---|
| Add/remove/rename a model in `config/config.yaml` | Medium | At next deploy | Pre-deploy diff gate (below); after deploy, `/v1/models` + smoke call per **llm-gateway-validation-and-qa** |
| Change `litellm_settings` (e.g. `request_timeout`, `drop_params`) | High | At next deploy | Diff gate; understand the 3-layer timeout stack first (**llm-gateway-config-and-flags**); post-change smoke + `journalctl` watch |
| Change `general_settings` (e.g. `master_key` ref, `database_url`) | High | At next deploy | Diff gate; check non-negotiables table — `database_url` is a known startup-killer (Incident 1) |
| Edit `scripts/install.sh` / `scripts/update.sh` | High | Only when run | Read the full script after editing; `bash -n script.sh` syntax check; never "test" by running on the live box without the diff gate |
| Edit `systemd/litellm.service` | High | At next deploy (update.sh resyncs unit + `daemon-reload` + restart) | Diff gate; keep `StateDirectory=litellm` (required by `ProtectSystem=strict` for writable /var paths — comment in the unit); post-restart `systemctl status` |
| Live-only overlay edit (hand-edit `/etc/litellm/config.yaml` on the desktop) | High | Immediately (after restart) | Backup first (procedure below); restart per **llm-gateway-install-and-operate**; note that this WIDENS drift — record what/why so the drift stays intentional |
| Edit `config/config.example.yaml` or `.env.example` | Medium | No | Ensure the example doesn't reintroduce known traps — the example currently still carries the `database_url` line that breaks startup (see non-negotiables); never put real key values in examples |
| Edit `/etc/litellm/litellm.env` / rotate the master key | High | Immediately (after restart) | Backup rationale n/a (never copy the file); rotation procedure: **llm-gateway-install-and-operate** §4; run the FULL post-change checklist from **llm-gateway-validation-and-qa**; update every LAN caller. Never read or reproduce the file's values |
| Docs change (`README.md`, `ROUTING.md`) | Low | No | Accuracy check against repo + live reality; see docs-of-record discipline below |
| Edit `.claude/skills/` (any skill file or script) | Low | No | Accuracy check against repo + live reality; commit attributed to Preston. **FLAG: pushing `.claude/skills/` (and any overlay details they contain) to the PUBLIC remote is an OPEN decision reserved for Preston** — the skills document the :4002 subscription-shim overlay. Skills may live locally uncommitted/unpushed until he decides; do NOT push without his sign-off |

## Gating procedure (before ANY deploy or live edit)

Run these steps in order. Do not skip step 1 even for a "trivial" change.

1. **Diff live config vs repo** (run from the repo root on the Mac; the pipe
   and diff run locally):

   ```bash
   cd /Users/prestonbernstein/dev/llm-gateway
   ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - config/config.yaml
   ```

   Reading the output: `-` lines exist only in the LIVE config; `+` lines
   exist only in the REPO config (same orientation as `config-drift.sh` in
   **llm-gateway-diagnostics-and-tooling**). Exit code 0 = identical, 1 =
   drift. As of 2026-07-02 this shows the 3 known deltas on the live side —
   that is the expected, intentional drift.

2. **Branch on the diff — neither outcome green-lights a blind `update.sh`.**
   - **Non-empty diff → STOP before `update.sh`.** Either the drift is
     intentional (today's case — do not clobber it; deploy nothing that
     reverts it) or it is unexplained (investigate via
     **llm-gateway-timeout-and-drift-campaign** before proceeding).
     `update.sh` is only safe when the diff shows nothing you are not
     deliberately replacing.
   - **EMPTY diff while the overlay policy is active = NOT safe — it means
     the live config was already clobbered** (claude-* reverted to the
     credit-less `anthropic/` routing). Check the live claude-* routing lines
     (`ssh desktop-agent 'sudo grep -n 4002 /etc/litellm/config.yaml'` —
     expect `:4002` hits); if reverted, restore the overlay from the newest
     sane backup FIRST, per **llm-gateway-timeout-and-drift-campaign** Phase
     0.3. An empty diff is only "safe" after Preston's reconciliation
     decision lands.

3. **Back up the live config before any live edit** (quoting trap — full
   explanation: **llm-gateway-install-and-operate** §3 step 2):

   ```bash
   ssh desktop-agent 'sudo cp /etc/litellm/config.yaml /etc/litellm/config.yaml.bak.$(date +%s)'
   ```

   Confirm the new backup name carries a real epoch number, not a literal
   `$(date +%s)`.

4. **Make the change** — repo file for canonical changes, live file for
   overlay-only changes (and record the overlay change somewhere findable, e.g.
   a comment block at the top of the live config, as the current overlay does).

5. **Deploy/restart** using the mechanics in **llm-gateway-install-and-operate**
   (not improvised commands).

6. **Verify.** Post-change verification is mandatory, never optional — run the
   checklist in **llm-gateway-validation-and-qa** (health endpoint, `/v1/models`,
   smoke completion, `journalctl -u litellm` scan).

7. **Update docs of record** if the change made `README.md` or `ROUTING.md`
   stale (see below). Doc updates are part of the change, not a follow-up.

8. **Commit** (repo changes only), attributed to Preston — see non-negotiables.

## Non-negotiables

Each rule earned its place. One-line incident cites here; full narratives live
in **llm-gateway-failure-archaeology**.

| Rule | Rationale | History |
|---|---|---|
| No `database_url` in config unless the prisma client is installed, generated, and migrated in the venv | LiteLLM's DB-backed spend logging needs prisma; without it the proxy fails to start. `config/config.example.yaml` line 36 still carries the bad `sqlite:////var/lib/litellm/litellm.db` line — copying the example verbatim reproduces the failure | Incident 1, 2026-06-30, fixed in commit `27b1fa0` |
| `/etc/litellm` perms exactly: dir `root:litellm` 750, `config.yaml` `root:litellm` 640, `litellm.env` root-only 600 | The `litellm` service user must traverse the dir and read config; it must NOT read the env file — systemd (root) injects it via `EnvironmentFile` | Incident 2, same commit: dir was `root:root` 750 and the service user couldn't read its own config |
| Secrets appear ONLY as `os.environ/<VAR>` references — never key values in `config.yaml`, the unit file, logs, docs, or skills | Public repo; `redact_user_api_key_info: true` backs this at the log layer. Key values live solely in `/etc/litellm/litellm.env` | House rule; standing |
| Local inference goes through the broker only — `127.0.0.1:11435` (interactive) / `:11436` (batch) from the gateway box — NEVER raw Ollama `:11434` | The GPU is shared (gaming/Plex); the broker arbitrates. Any config/suggestion pointing at `:11434` is wrong | House rule; standing |
| Desktop services run under dedicated nologin service users | `litellm` complies (created by `install.sh` with `-s /usr/sbin/nologin`). The adjacent claude-cli-server runs as `preston` — a KNOWN open item; do not "fix" it silently, that is its own change through this process | House rule; open item noted 2026-07-02 |
| Commits and PRs are attributed to Preston only — never to Claude, no co-author trailers naming Claude | Owner's standing rule for all repos | House rule; standing |
| Post-change verification is mandatory | A config typo takes the whole gateway down for every consumer (`Restart=always` will loop a broken config). Checklist: **llm-gateway-validation-and-qa** | Standing; Incidents 1–2 were both caught only at start/verify time |

## OPEN decision — canonicalize the :4002 overlay?

**Status: OPEN (2026-07-02), reserved for Preston. This skill does not carry
the option menu** — the full reconciliation decision menu (Options A/B/C with
costs and theory obligations) lives ONLY in
**llm-gateway-timeout-and-drift-campaign** §2.2. Do not decide the question
in passing, and do not reconstruct the options here.

Until decided: treat the live config as the operational source of truth for
claude-* routing, the repo as the source of truth for everything else, and
the diff gate (gating step 1) as the boundary enforcement.

## Docs-of-record discipline

`README.md` and `ROUTING.md` are the documents of record: README owns
install/operate/security claims, ROUTING.md owns the tier contract
(**litellm-routing-reference** carries only an annotated COPY of the tier
table — on a tier change, edit ROUTING.md first, then refresh the copy).
Rules:

- **When a change makes them stale, updating them is part of the change.**
  Same commit, or the change is not done.
- **Most dangerous observed staleness (2026-07-02): README's "Updating"
  section** instructs a bare `git pull` + `sudo bash scripts/update.sh` — the
  exact ungated run that THE ONE RULE above forbids. A reader following the
  README literally triggers the clobber. Fixing it is a Preston-attributed
  docs change.
- Cautionary example (stale as of 2026-07-02): README's "Spend tracking"
  section claims every request is logged to `/var/lib/litellm/litellm.db` and
  gives a `sqlite3` query. That DB does not exist — `database_url` was removed
  in Incident 1 and never re-enabled; `/var/lib/litellm/` contains no
  `litellm.db` (verified 2026-07-02; only the service user's home-dir skeleton
  files live there). The README's "Visibility" bullet and ROUTING.md's "every call
  ... is logged" line repeat the same dead claim. Nobody updated the docs when
  the feature was cut, and the lie has now outlived the feature by two days.
- Second observed staleness (2026-07-02): README's Security section says
  `/etc/litellm/` is "chmod 750 root:root"; the actual (and correct, per
  Incident 2) ownership is `root:litellm` — `install.sh` sets it and the live
  box matches.
- Fixing either stale section is itself a docs change: Low risk, no live
  impact, still commit-attributed to Preston.
- House style for both docs: short, concrete, no oversell. State what exists;
  label anything unproven as planned/open instead of describing it as working
  (the spend-tracking section is exactly what violating this looks like).

## When NOT to use this skill

- Full incident narratives and root-cause stories → **llm-gateway-failure-archaeology**
- Post-change verification checklist details → **llm-gateway-validation-and-qa**
- Deploy/restart/install mechanics (what update.sh and install.sh actually do, step by step) → **llm-gateway-install-and-operate**
- Drift remediation campaign and the reconciliation decision menu → **llm-gateway-timeout-and-drift-campaign**
- What each config flag/timeout layer means → **llm-gateway-config-and-flags**
- Tier table and cascade doctrine → **litellm-routing-reference**
- System boundaries and ownership contract → **llm-gateway-architecture-contract**
- Live debugging of a broken gateway → **llm-gateway-debugging-playbook**
- Log/diagnostic tooling → **llm-gateway-diagnostics-and-tooling**
- Forward-looking research → **llm-gateway-research-frontier**

## Provenance and maintenance

Facts verified 2026-07-02 against the repo files and read-only SSH to the live
box. Volatile facts (drift contents, backup files, stale README sections) are
date-stamped above; re-verify before relying on them:

- Drift still present / contents: `cd /Users/prestonbernstein/dev/llm-gateway && ssh desktop-agent 'sudo cat /etc/litellm/config.yaml' | diff -u - config/config.yaml` (`-` = live-only, `+` = repo-only)
- update.sh still clobbers unconditionally: `grep -n 'cp .*config.yaml' ~/dev/llm-gateway/scripts/update.sh` (look for an unguarded `cp` to `$CONFIG_DIR/config.yaml`)
- Live perms + backup artifacts: `ssh desktop-agent 'sudo ls -la /etc/litellm/'`
- Example still carries the database_url trap: `grep -n database_url ~/dev/llm-gateway/config/config.example.yaml`
- README spend-tracking still stale: `grep -n litellm.db ~/dev/llm-gateway/README.md` then `ssh desktop-agent 'sudo ls -la /var/lib/litellm/'`
- Repo timeout value: `grep -n request_timeout ~/dev/llm-gateway/config/config.yaml`
- Commit history baseline (4 commits as of 2026-07-02): `git -C ~/dev/llm-gateway log --oneline`
