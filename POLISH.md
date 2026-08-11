# Codebase polish — 2026-08-11

Automated elegance/DRY/observability pass over this repo. Deterministic
tooling first, then three parallel LLM lenses (elegance/architecture/DRY,
dead-code/duplication, observability), then auto-apply, then an independent
correctness safety-net review of the resulting diff.

## Deterministic signal

This repo is bash + YAML + docs, no TS/JS and no Python source — `fallow`
(TS/JS-only) and `vulture`/`slopo` (Python) don't apply. `shellcheck` ran
against both scripts and returned zero findings at every severity level,
before and after this pass's edits.

## Standards brief

- Live `/advisor` sweep, 2026-08-11 (REFRESH of `Development/Research/codebase-quality-polish-skill.md`,
  same-day baseline) — all four lanes (experts/apps/github/gists) returned
  `NO CHANGE` or minor version bumps to tools that don't apply to this repo
  (fallow-rs is TS/JS-only). No shift in grounding since the baseline sweep.
- Google eng-practices review standard (health over perfectionism).
- YAGNI / Fowler's "speculative generality" guardrail.
- This repo's own `.claude/skills/` knowledge base (11 skill files) — an
  unusually thorough internal audit trail already tracking config/live drift.
  Cross-referencing it directly against the current repo state is what
  surfaced most of the real findings below; several were things the repo
  had been *documenting as known problems for over a month* without ever
  fixing (see `database_url`, `RUNPOD_API_KEY` below).

## Applied

### Elegance / architecture / DRY
- `config/config.example.yaml:36` — removed `database_url: "sqlite:////var/lib/litellm/litellm.db"`.
  Documented (README.md, and repeated across 8+ files in `.claude/skills/`) as
  a startup-breaking landmine from Incident 1 (commit `27b1fa0` removed it
  from the real `config.yaml` on 2026-06-30 but never from the example) —
  never actually fixed until now.
- `config/config.example.yaml:37` — added `disable_master_key_return: true`
  to match `config.yaml`.
- `config/config.example.yaml` — commented out the RunPod block (it was
  live/uncommented with an unfillable `RUNPOD_ENDPOINT_ID` placeholder,
  inconsistent with `config.yaml`'s own commented-template convention for
  the same block).
- `config/config.example.yaml:30` — renamed `ollama/qwen2.5` →
  `ollama/interactive/qwen2.5` to match the live config and ROUTING.md's
  tier contract.
- `config/config.yaml` — deleted the stale, commented-out RunPod template
  block (lines 96-104); `config.example.yaml` is now the single template
  source instead of two independently-drifting copies. Added a real
  `── RunPod (serverless vLLM) — active deployments ──` header above the
  two genuinely-active RunPod entries, which previously sat unlabeled under
  the `── Gemini ──` header.
- `config/config.yaml` — shrank the duplicated Prometheus metric-name
  mapping (README.md already has the full table) to a one-line pointer, so
  a future litellm upgrade only needs updating in one place.
- `ROUTING.md` — MID tier row now reads `runpod/qwen2.5-72b — template
  only, **not active**`, matching the phrasing the repo's own
  `.claude/skills/litellm-routing-reference` already uses internally.
  (Confirmed `qwen72b`, the actually-active 72B RunPod backend, is
  deliberately treated as a special-purpose extraction backend for
  algo-corpus rather than a general tier member — see Escalated below.)

*Comment/formatting-only changes to `config/config.yaml` — verified with a
structural YAML diff (old vs. new parsed objects) that `model_list`,
`litellm_settings`, and `general_settings` are unchanged.*

### Dead code & duplication triage
- `scripts/install.sh` — added `RUNPOD_API_KEY=` to the generated
  `litellm.env` heredoc and the `secrets.incomplete` message. Two active
  `config.yaml` deployments (`runpod-qwen32b`, `qwen72b` ×2) read
  `os.environ/RUNPOD_API_KEY`; a fresh install left them permanently
  unauthenticatable with no signal pointing at why. `.env.example` already
  had this line — the two env templates were themselves out of sync.
- `scripts/install.sh` — removed the redundant `mkdir -p`/`chown` of
  `$DATA_DIR`: `useradd -m` already creates and owns it on first install,
  and `systemd`'s `StateDirectory=litellm` recreates/owns it on every
  service start regardless. Verified nothing between that line and the
  service install needs `$DATA_DIR` to exist early.

### Observability
- `scripts/install.sh`, `scripts/update.sh` — added
  `trap '... ERR' ...` right after the `log()`/`die()` definitions. Every
  step past the preflight checks (useradd, venv creation, pip install,
  config copy, systemd calls) relied solely on bare `set -euo pipefail`;
  a real failure exited with the underlying tool's raw stderr instead of a
  structured JSON `critical` event, breaking this repo's own JSON-log
  contract exactly when an operator needs it most. Verified (via isolated
  bash reproduction, not just inspection) that the trap doesn't
  double-fire on `die()`'s explicit `exit 1`, and correctly stays silent
  inside the existing `if`/`until`/`||`-guarded checks.
- `scripts/install.sh` — the `litellm --version` check after install now
  distinguishes success from failure explicitly and logs a `critical`
  event with the captured error on failure, instead of silently logging
  `"installed litellm unknown"` at the same `info` severity as a healthy
  install.
- `scripts/update.sh` — now logs the post-upgrade litellm version
  (`litellm.upgrade.completed`), mirroring what `install.sh` already does.
  Previously there was no way to tell from the JSON log history which
  litellm version was running after a given update.
- `scripts/install.sh` — added an `openssl` preflight check (README lists
  it as a hard requirement; it's used at heredoc-generation time, deep in
  the script, so a missing binary previously wasn't caught until after the
  full venv+pip sequence had already run).
- `scripts/install.sh` — the closing "next steps" banner now has a
  fallback for `hostname -I` returning nothing, and the fixed-width ASCII
  box (which went ragged for any IP/port length it wasn't hand-fitted to)
  was replaced with plain unboxed text.

### CI
- `.github/workflows/ci.yml` — added a `yaml-syntax` job that parses both
  `config/*.yaml` files. Previously CI only shellchecked the two scripts;
  the YAML configs — the source of the Incident 1 landmine class — had no
  automated check at all.
- `.github/workflows/ci.yml` — relaxed `shellcheck -S error` to the
  default severity floor (catches style issues too); both scripts still
  pass clean.

**Regression safety net**: an independent sonnet review of this diff (not
the same agent that made the edits) re-ran `bash -n`, `shellcheck`, and a
structural YAML diff, and specifically stress-tested the new ERR-trap
semantics and the `$DATA_DIR` removal in isolated bash reproductions. No
correctness bugs found.

## Escalated items — resolved 2026-08-11 (follow-up pass)

All four items below were escalated in the initial pass rather than
auto-applied, then resolved in a follow-up after explicit direction to fix
everything and deploy:

- **README.md's "Anthropic API" framing.** Preston chose to rewrite it
  accurately: README's architecture diagram, intro, Requirements,
  Installation, and Usage sections now describe the real
  `claude-cli-server` (`localhost:4002`) subscription shim instead of a
  direct Anthropic API. `install.sh`'s generated `litellm.env` no longer
  presents `ANTHROPIC_API_KEY` as required — it's now a commented-out,
  clearly-labeled optional line for anyone who switches `config.yaml`'s
  `claude-*` entries away from the shim (`config/config.example.yaml`
  still documents that direct-API path). `claude-cli-server` itself is
  out of scope for this repo — README now names it as a hard runtime
  dependency without fabricating its own setup instructions, since this
  repo doesn't own that service.
- **`config/config.yaml:126` `ollama/cpu/bge-m3`** now points at
  `http://127.0.0.1:11436` (the broker's batch port, matching its sibling
  GPU `ollama/batch/bge-m3` embedding entry) instead of raw Ollama
  `:11434`, with a comment citing the house rule it was violating.
- **ROUTING.md's tier table** now includes `claude-haiku-4-5` (FAST) and
  `runpod-qwen32b` (MID) — both cleanly fit the existing tiers. `gemini-embed`
  and `ollama/batch/qwen3-vl:30b` are documented in a new note as
  special-purpose (embeddings/vision, not general reasoning) rather than
  forced into a tier. `qwen72b` and `claude-fable-5` are explicitly called
  out as active-but-unassigned — `qwen72b` because the household's own
  internal reference deliberately treats it as a dedicated
  `algo-corpus`-extraction backend, not a general route; `claude-fable-5`
  because its intended tier genuinely isn't decided yet and guessing
  wrong in a document other services treat as a contract seemed worse
  than flagging it explicitly.
- **Post-upgrade metric-name drift risk.** `scripts/update.sh` now curls
  `/metrics` (with the master key read locally from `litellm.env`, never
  echoed) after a successful restart, as a safety net instead of pinning
  litellm's version. The check went through two live-discovered bugs
  before it was actually correct — see below.

Everything above was validated with `shellcheck`, `bash -n`, and a YAML
parse before commit. See "Deploy" below for the live rollout, and the two
bugs the deploy itself caught in the new metrics check.

### The metrics check's first two versions were both wrong

The first deploy of the new post-restart `/metrics` check (see above) fired
`critical` twice, for two different reasons — both root-caused and fixed
before this pass finished, not left as follow-ups:

1. **Redirect not followed.** LiteLLM's `/metrics` (no trailing slash)
   returns an HTTP `307` to `/metrics/`. The check used `curl -fsS` without
   `-L`, so it silently got an empty redirect body instead of the real
   metrics — a curl-flag bug, fixed by adding `-L`.
2. **Wrong assumption about what "present" means.** The four series names
   the check originally looked for
   (`litellm_proxy_total_requests_metric`, `litellm_deployment_successful_fallbacks`,
   `litellm_deployment_cooled_down`, `litellm_spend_metric`) are all
   Prometheus counters scoped to specific request/fallback/cooldown labels
   — the client library doesn't emit a labeled series until that exact
   label combination has actually occurred at least once. Immediately
   after a fresh restart with zero traffic, all four are legitimately
   absent — not broken, just never triggered yet. The original check would
   have logged a false "critical" on *every single deploy*, which is worse
   than no check at all (alert fatigue trains an operator to ignore it).
   Confirmed live: right after restart, `/metrics` only exported
   unlabeled gauges (`litellm_active_users`, `litellm_in_flight_requests`,
   etc.) — none of the four target counters, despite nothing being wrong.
   Fixed by redesigning the check to a shallower, reliable one: confirm
   `/metrics` is reachable and exports *some* `litellm_`-prefixed series
   at all (catches the callback breaking entirely — auth change,
   dependency removed, exposition format changed) rather than asserting
   on event-driven data that doesn't exist yet. Verified passing against
   the live instance before the final commit.

## Original escalation reasoning (superseded above)

- **README.md's "Anthropic API" framing.** Since commit `c6c31a4`, every
  `claude-*` model actually routes through a local `claude-cli-server`
  shim (`localhost:4002`) using Preston's Claude subscription — not the
  Anthropic API with `ANTHROPIC_API_KEY` as README's architecture diagram
  and prose describe. This repo has a public GitHub remote and a
  dedicated internal skill (`llm-gateway-research-frontier`) whose stated
  job is gating exactly this class of change ("anything public — README
  claims, blog posts, resume lines — goes through this skill"). Given
  that explicit gate, I did not rewrite README's public-facing framing or
  touch `ANTHROPIC_API_KEY` in `install.sh`'s heredoc — that's a
  deliberate public-disclosure decision, not a drift bug to auto-fix.
- **`config/config.yaml:134` `ollama/cpu/bge-m3` → `http://127.0.0.1:11434`.**
  This repo's own `.claude/skills/llm-gateway-change-control` documents a
  standing house rule: "Local inference goes through the broker only —
  never raw Ollama `:11434` — GPU is shared with gaming/Plex... any
  config/suggestion pointing at `:11434` is wrong." This entry currently
  violates that rule with no comment explaining why. It's possible this
  is a deliberate CPU-only exception (no GPU contention to arbitrate) that
  was never documented as such, or it's a real bug. Either way, fixing the
  `api_base` changes live routing behavior for a shared production
  service — that's outside what a repo-local polish pass should decide
  unilaterally. Needs Preston to confirm intent (deliberate exception →
  add an explanatory comment; bug → repoint at a broker port) and, if it's
  a real fix, run it through the deploy + verification checklist this
  repo already has (`llm-gateway-change-control` / `llm-gateway-validation-and-qa`).
- **ROUTING.md's tier table is missing several actively-served models**
  (`qwen72b`, `runpod-qwen32b`, `claude-haiku-4-5`, `claude-fable-5`,
  `gemini-embed`, `ollama/batch/qwen3-vl:30b`). Real gap, but assigning
  each the correct tier requires domain judgment I don't have enough
  evidence for — `qwen72b` in particular is deliberately excluded from the
  household's own annotated tier reference despite being the most
  heavily-engineered route in the file (dedicated fallback + retry tuning
  for one specific pipeline), which reads as intentional rather than an
  oversight. Recommend a follow-up pass with Preston to assign tiers.
- **Post-upgrade metric-name drift risk.** `litellm[proxy]` and
  `prometheus_client` are installed/upgraded unpinned in both scripts, but
  the entire Observability section depends on specific metric series
  names verified against one specific litellm version (1.93.0,
  2026-08-01). `update.sh`'s health check only confirms the proxy is
  *alive*, never that `/metrics` still exposes the documented series names
  after an upgrade. A real fix (either pin the version deliberately, or
  add an authenticated post-restart `/metrics` grep) requires reading the
  master key from `/etc/litellm/litellm.env` inside `update.sh` — a
  secret-handling change with its own review bar, deferred rather than
  auto-applied.
- **`scripts/install.sh` vs `scripts/update.sh` config-sync policy** —
  considered, not applied. `install.sh` skips copying `config.yaml` if one
  already exists; `update.sh` always overwrites it. Initially flagged as
  an inconsistency, but this is deliberate: install protects a
  possibly-hand-placed config on first bootstrap, while update
  intentionally treats the repo as the source of truth on every
  subsequent sync — and this repo's own change-control docs already have
  an explicit process for tracking intentional live-only drift. No change
  needed.

## Not touched

`.claude/skills/` — a separate Claude-agent knowledge base explicitly
gated by this repo's own README as "whether it's ever pushed to the
public remote is an open decision reserved for Preston." Out of scope for
a code-health pass. Worth noting for a future session: this library
(written 2026-07-02) now describes README.md's "Spend tracking" section
and ROUTING.md's "logging sentence" as stale — but both were already
corrected on 2026-08-02 (commit "Add metrics and structured logging..."),
so the skill library's own claims about those two files are now the
out-of-date thing, not the docs it's describing. Not fixed here (out of
scope), just flagged.

## Deploy

Pushed to `origin/main` (`git@github.com:preston-bernstein/llm-gateway.git`)
across three commits (`f4f16c5`, `01d0e1c`, merge `656de99`), then a
fourth (`8241231`) fixing two bugs the first live deploy itself
surfaced in the new metrics check (see above). A concurrent unrelated
commit landed on GitHub directly during this pass (`42ad749`, redacting
the LAN IP from README) — reconciled with a merge, no conflicts.

Deployed to the live instance (desktop, `agent@10.0.0.243`,
`/home/agent/dev/llm-gateway`) via the repo's own documented procedure:
`git pull --ff-only` + `sudo bash scripts/update.sh`, run twice (once
before the metrics-check fix, once after, to verify the fix live rather
than just in review).

**Post-deploy verification:**
- `systemctl status litellm` — active, healthy, restarted cleanly both times.
- `update.sh`'s own liveliness poll — passed in 4s both runs.
- `update.sh`'s new `/metrics` check — failed on the first run (the two
  bugs above), passed cleanly on the second (`metrics.check_passed`)
  after the fix was deployed.
- Deployed `/etc/litellm/config.yaml` spot-checked directly: `ollama/cpu/bge-m3`
  now has `api_base: http://127.0.0.1:11436` (the broker-port fix landed for
  real, not just in the repo); the stale commented-out RunPod template
  block is gone from the live file too.
- `GET /v1/models` — all 15 expected model IDs present, including the
  ROUTING.md tier-table additions.
- Real smoke test: a `gemini-2.5-flash` chat completion through the live
  gateway returned the expected content end-to-end.

Litellm was upgraded 1.9x → **1.96.0** as a side effect of `update.sh`'s
normal unpinned-upgrade behavior (unrelated to this pass's changes,
already the documented behavior of `scripts/update.sh`).
