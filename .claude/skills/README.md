# llm-gateway skill library — map

Eleven skills covering the LiteLLM proxy on the home-lab desktop
(`multimedia`, 10.0.0.243:4000) and its live overlay. Written 2026-07-02.

**Publication flag:** these skills document the live :4002 subscription-shim
overlay. Whether `.claude/skills/` is ever pushed to the PUBLIC remote is an
OPEN decision reserved for Preston — commit locally if instructed, do NOT
push without his sign-off (see `llm-gateway-change-control`).

## Start here

| Situation | Load |
|---|---|
| New to the project / "why is X built this way" | `llm-gateway-architecture-contract` (the constitution) |
| Something is failing right now | `llm-gateway-debugging-playbook` (symptom → triage) |
| About to change ANYTHING (config, live file, scripts, docs, skills) | `llm-gateway-change-control` — it pulls in `llm-gateway-install-and-operate` (mechanics) + `llm-gateway-validation-and-qa` (post-change checklist); this trio is the minimum kit for any live change |
| claude-* timeouts (APITimeoutError at 300 s) or repo↔live drift work | `llm-gateway-timeout-and-drift-campaign` (the active workstream) |

## All eleven, one line each

- `litellm-routing-reference` — the only one WITHOUT the `llm-gateway-` prefix: LiteLLM config concepts, tier contract (annotated copy of ROUTING.md), shim contract (§5 is its one home), broker lanes. Understanding, not editing.
- `llm-gateway-architecture-contract` — load-bearing design decisions, invariants, known weak points.
- `llm-gateway-change-control` — change classification, the pre-deploy diff gate, non-negotiables, docs-of-record discipline.
- `llm-gateway-config-and-flags` — every config knob on all four axes; THE drift delta list; THE timeout-layers table.
- `llm-gateway-debugging-playbook` — symptom → first command → interpretation branches, for live failures.
- `llm-gateway-diagnostics-and-tooling` — the four read-only scripts (health, drift, log triage, smoke) + the dead-ollama-entries KNOWN DEFECT.
- `llm-gateway-failure-archaeology` — full incident narratives, Incidents 1–8. Check here before "fixing" anything that looks odd.
- `llm-gateway-install-and-operate` — install/update/restart mechanics; THE guarded-update ritual; key rotation; port change.
- `llm-gateway-research-frontier` — open problems, evidence bar, and external positioning: **anything public (README claims, blog posts, resume lines) goes through this skill.**
- `llm-gateway-timeout-and-drift-campaign` — the phased plan for the standing 300 s timeout + drift problem; owns the reconciliation decision menu (reserved for Preston).
- `llm-gateway-validation-and-qa` — evidence tiers, THE post-change checklist, golden inventory, smoke tests, cost classes.
