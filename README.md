<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/%F0%9F%A5%8A-rival-a855f7?style=for-the-badge&labelColor=1a1a2e&color=a855f7">
    <img alt="rival" src="https://img.shields.io/badge/%F0%9F%A5%8A-rival-a855f7?style=for-the-badge&labelColor=f5f5f5&color=a855f7">
  </picture>
</p>

<p align="center">
  <strong>Adversarial code review and task delegation — powered by free OpenRouter models.</strong><br>
  One model reviews your code. Three models chain their findings. Zero cost.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-v2.1.80+-blue?style=flat-square" alt="Claude Code v2.1.80+">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/via-OpenRouter_free_tier-a855f7?style=flat-square" alt="Via OpenRouter free tier">
</p>

---

## The problem

Code review inside the same conversation context is not really review. Claude has all the surrounding context: the plan, the intent, the constraints you gave it. That shared context actively suppresses objections.

**rival** routes your code to models that have none of that context. They see only the diff. They have no obligation to like it.

## What it looks like

Three modes depending on how much scrutiny you want:

**Single** — one model, fast, honest second opinion:
```
/rival
```

**Panel** — three models in a chain, each building on the last:
```
/rival --panel
```

**Parallel** — three models blind, results merged:
```
/rival --panel-parallel
```

---

## The chain vs parallel question

This is worth explaining properly because the answer is not obvious.

### Parallel review (what most people expect)

Three models see the same code, independently, and you get three separate reports. You then have to read all three and figure out what matters. Disagreements are invisible — you just get three opinions with no synthesis. If two models miss the same bug, you learn nothing from the third seeing it.

### Sequential chain review (what --panel actually does)

The chain is different. Each model receives not only the code but the full findings of every model that reviewed it before. The second model reads the first model's output and responds to it — agreeing, extending, disputing. The third model reads both.

```
Your code
    │
    ▼
┌───────────────────────────────┐
│   Qwen 3.6+ (first reviewer) │
│   No prior findings           │
│   Focus: initial pass         │
└───────────────┬───────────────┘
                │ findings
                ▼
┌───────────────────────────────┐
│   Gemma 3 27B (second)        │
│   Sees: code + Qwen findings  │
│   Focus: confirm, extend,     │
│   dispute                     │
└───────────────┬───────────────┘
                │ findings + disputes
                ▼
┌───────────────────────────────┐
│   Llama 3.3 70B (third)       │
│   Sees: code + all prior      │
│   Focus: resolve conflicts,   │
│   surface what was missed     │
└───────────────┬───────────────┘
                │
                ▼
         Final summary
         (merged back into Claude)
```

This mirrors how a real code review meeting works. The first reviewer says "I'm worried about the locking strategy." The second reviewer either backs that up or pushes back with evidence. The third one looks at the dispute and makes a call. The output is a conversation, not a list.

Parallel review is silent polling. The chain is a meeting. For adversarial review specifically, you want the meeting.

---

## Modes at a glance

```
/rival
  │
  └── single model (Qwen 3.6+)
        reviews your current file or selection
        returns findings directly

/rival --panel
  │
  ├── Qwen 3.6+ ──► findings
  ├── Gemma 3 27B ──► builds on Qwen findings
  └── Llama 3.3 70B ──► resolves + synthesizes
        returns chained summary

/rival --panel-parallel
  │
  ├── Qwen 3.6+ ─────┐
  ├── Gemma 3 27B ────┤ blind, simultaneous
  └── Llama 3.3 70B ──┘
        merged: consensus / unique findings / disagreements
```

---

## Requirements

- **Claude Code** v2.1.80+
- **OpenRouter API key** — free at [openrouter.ai](https://openrouter.ai)
- **jq** (`brew install jq`)
- **curl**

---

## Installation

### 1. Add the marketplace and install

```bash
claude plugin marketplace add https://github.com/bambushu/rival
claude plugin install rival@bambushu
```

### 2. Add your OpenRouter key

```bash
echo 'export OPENROUTER_API_KEY="sk-or-..."' >> ~/.zshrc
source ~/.zshrc
```

### 3. Verify

```bash
claude plugin list
# rival@bambushu should appear as enabled

/rival
# should prompt for a file or use the current editor context
```

---

## Usage

### Single model review

```
/rival
```

Reviews the current file or selection using Qwen 3.6+ (default). Returns findings inline.

### Override the model

```
/rival --model google/gemma-3-27b-it:free
/rival --model meta-llama/llama-3.3-70b-instruct:free
```

Any model from the OpenRouter free tier works here.

### Sequential panel review

```
/rival --panel
```

Runs Qwen → Gemma → Llama in sequence. Each model receives prior findings. Returns a synthesized summary with disputed points flagged.

### Parallel panel review

```
/rival --panel-parallel
```

Runs all three models blind, in parallel. Results merged into:
- **Consensus** — all models flagged this
- **Unique** — only one model flagged this
- **Disagreements** — models reached opposite conclusions

### Task delegation via rival-rescue

For general delegation (not just review), the `rival:rival-rescue` agent routes tasks to the companion script:

```
rival:rival-rescue(refactor the payment module to handle idempotency)
```

Use this anywhere Claude Code accepts agent calls.

---

## Available free models

| Model | ID | Best for |
|-------|----|----------|
| Qwen 3.6+ (default) | `qwen/qwen3.6-plus:free` | General review, fast |
| Qwen 3 Coder | `qwen/qwen3-coder:free` | Code-heavy review |
| Gemma 3 27B | `google/gemma-3-27b-it:free` | Instruction following, clarity |
| Llama 3.3 70B | `meta-llama/llama-3.3-70b-instruct:free` | Reasoning, synthesis |
| Nemotron 120B | `nvidia/nemotron-3-super-120b-a12b:free` | Deep analysis, complex tasks |
| Hermes 3 405B | `nousresearch/hermes-3-llama-3.1-405b:free` | High-stakes review |

All of these are zero-cost on the OpenRouter free tier.

---

## Technical details

### scripts/rival-companion.sh

The companion script handles all OpenRouter communication:
- Sources `~/.zshrc` via a login subshell for env var inheritance — your `OPENROUTER_API_KEY` is available even in hook contexts where env isn't loaded
- Uses `stdin` for the curl request body to avoid `ARG_MAX` limits on large code inputs
- Retries on `429` and `503` with exponential backoff (1s, 2s, 4s — then gives up)
- Validates `jq` and `curl` are present before attempting any API call
- Falls back to `OPENROUTER_API_KEY` env var if not already set

### agents/rival-rescue.md

Defines the `rival:rival-rescue` agent that forwards general delegation tasks to the companion script. Works like codex-rescue but routes to OpenRouter instead of Codex.

### skills/rival/skill.md

Defines the `/rival` skill and all panel modes. No hooks needed — rival is on-demand only. No background processes, no flag files, no persistent state.

---

## Files

```
plugins/rival/
  .claude-plugin/plugin.json        # Plugin manifest
  scripts/rival-companion.sh        # OpenRouter API caller with retry + env
  agents/rival-rescue.md            # General task delegation agent
  skills/rival/skill.md             # /rival skill — single, panel, panel-parallel
  LICENSE                           # MIT
```

---

## What we learned building this

A few things worth noting for anyone building OpenRouter-backed Claude Code plugins:

1. **Env vars don't survive hooks** — the companion script has to source `~/.zshrc` via `bash -l` (login shell). Otherwise `OPENROUTER_API_KEY` is empty inside Claude Code's hook context, which produces a silent 401 and nothing else.
2. **Large code inputs break `$()` substitution** — bash command substitution has an ARG_MAX ceiling. Feeding the curl body via stdin sidesteps this entirely. For small files it doesn't matter; for a 500-line module it does.
3. **Sequential chain output needs structure** — early versions just concatenated model outputs. The chain only becomes useful when each model is explicitly told "here are the prior findings — address them." The prompt contract matters more than model selection.
4. **Free tier models are rate-limited, not throttled** — you won't get degraded quality at peak times, you just get a 429. The retry logic handles this without requiring any user action.
5. **Parallel review sounds better than it is** — three independent opinions with no synthesis forces the human to do the reconciliation work. The sequential chain shifts that work to the models, where it belongs.

---

## The story behind this

I kept running into a version of the same problem: after a long Claude Code session building something, I'd ask Claude to review it and get back a polished endorsement of everything it had just written.

That's not review. That's confirmation.

The obvious fix is to use a completely different model with no context. OpenRouter makes that free. But a single free model giving a single pass still misses things — not because the model is bad, but because any single reviewer has blind spots.

The chain idea came from thinking about how actual code review works on good teams. The first reviewer does the initial pass. The second reviewer reads that first pass before looking at the code — they come in knowing what to focus on and what's already been covered. The third reviewer resolves disputes. Three reviewers who have actually talked to each other are worth more than three reviewers who submit separate reports.

Building that into a bash script took about a day. Getting the prompt contracts right — so each model in the chain actually responds to prior findings rather than starting fresh — took another day.

The result is something that costs nothing and tells you things Claude won't.

---

## Contributing

Open issues and PRs at [github.com/bambushu/rival](https://github.com/bambushu/rival).

Ideas for future versions:
- Configurable chain composition (pick your own three models)
- Severity scoring per finding across the chain
- `--focus` flag to target specific concerns (security, performance, style)
- `--file` override to review a specific path rather than current context
- Output as a structured JSON report for downstream tooling

---

## License

MIT - Bambushu
