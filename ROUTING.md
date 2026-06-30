# Model routing — the right model for the job (FrugalGPT)

The gateway serves a catalog of models; **services own the cascade policy** (which
tier to try, when to escalate). The shared tier contract:

| Tier | Gateway model_name | Use |
|---|---|---|
| **LOCAL** | `ollama/interactive/qwen2.5`, `ollama/batch/*` | free, private, bulk/simple (classify, extract, embeddings) |
| **FAST** | `gemini-2.5-flash` | cheap, fast cloud — first cloud escalation |
| **MID** | `claude-sonnet-4-6`, `runpod/qwen2.5-72b` | strong reasoning at mid cost |
| **FRONTIER** | `claude-opus-4-8`, `gemini-2.5-pro` | maximum accuracy — hard reasoning / judgment |

## FrugalGPT principle (accuracy-first)

- **Bulk/simple work** → start LOCAL, escalate only if the cheap model fails a
  quality gate (e.g. invalid JSON). Most calls never leave the free tier.
- **Accuracy-critical work** → skip the cascade, go straight to FRONTIER. Don't
  pay in errors to save pennies where correctness matters.
- **Middling work** → cascade MID → FRONTIER.

The cascade's quality gate is a verifier (valid JSON of the right shape, a
self-consistency check, etc.). A cheap model only "wins" if it passes; otherwise
the request escalates. Every call (tier, tokens, latency, cost) is logged by the
LiteLLM proxy — one `SELECT` to see what each task actually cost.

## Reference implementation

`algo-factory`'s `ModelRouter` (`src/algo_factory/agents/router.py`) implements
this: per-task `RoutePolicy` (mode `cascade`|`best` + tier chain), JSON-gated
escalation, all calls through this gateway. Other services should follow the same
tier names so policies stay consistent across the stack.

## RunPod

`runpod/*` entries point at a serverless vLLM endpoint (OpenAI-compatible) — big
open-weights on demand, a cost/capability point between the local broker and the
frontier APIs. Set the endpoint id in `config.yaml` and `RUNPOD_API_KEY` in the
env file.
