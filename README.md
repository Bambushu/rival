<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://img.shields.io/badge/%F0%9F%A5%8A-rival-a855f7?style=for-the-badge&labelColor=1a1a2e&color=a855f7">
    <img alt="rival" src="https://img.shields.io/badge/%F0%9F%A5%8A-rival-a855f7?style=for-the-badge&labelColor=f5f5f5&color=a855f7">
  </picture>
</p>

<p align="center">
  <strong>Adversarial code review by models that think another AI wrote your code.</strong><br>
  One model reviews. Three models chain their findings. All of them are in a bad mood. Zero cost.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Claude_Code-v2.1.80+-blue?style=flat-square" alt="Claude Code v2.1.80+">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT License">
  <img src="https://img.shields.io/badge/via-OpenRouter_free_tier-a855f7?style=flat-square" alt="Via OpenRouter free tier">
  <img src="https://img.shields.io/badge/local-Ollama_supported-orange?style=flat-square" alt="Ollama supported">
</p>

---

## The problem

Code review inside the same conversation context is not really review. Claude has all the surrounding context: the plan, the intent, the constraints you gave it. That shared context actively suppresses objections.

**rival** routes your code to models that have none of that context. They see only the diff. They have no obligation to like it.

But context isolation alone isn't enough. Models default to being polite. So rival does something else: it tells each reviewer that the code was written by *a different AI model*. This triggers a natural competitive stance - models are measurably more critical when they know they're reviewing another model's work. Add a "bad mood" framing and an explicit mandate to detect AI slop (over-abstraction, cargo-cult patterns, unnecessary error handling), and you get reviews that actually hurt.

## What it looks like

Four modes depending on how much scrutiny you want:

**Single** - one model, fast, honest second opinion:
```
/rival
```

**Panel** - three models in a chain, each building on the last:
```
/rival --panel
```

**Parallel** - three models blind, results merged:
```
/rival --panel-parallel
```

**Local** - same review, no internet needed:
```
/rival --local
```

---

## Dynamic model discovery

rival automatically finds the best available free models on OpenRouter. No hardcoded model IDs that break when OpenRouter changes their roster.

### How it works

1. **Discover** - queries OpenRouter's model API, filters for `:free` models with 32k+ context and 7B+ parameters
2. **Rank** - sorts by parameter count (bigger = better reasoning for code review)
3. **Diversify** - ensures panel models come from different families (nvidia, openai, google, meta, qwen)
4. **Health-check** - pings top candidates with a real request, retries once on 429, drops persistent failures
5. **Early exit** - stops pinging once 3+ healthy models from 2+ families are found (saves rate limit budget)
6. **Cache** - writes survivors to `~/.rival/models.json`, valid for 24 hours

Discovery runs automatically when the cache is missing or stale. You can also trigger it manually:

```
/rival --discover
```

### What typically gets selected

The free-tier landscape changes, but as of writing the discovery process usually selects models like:

| Rank | Example model | Why |
|------|--------------|-----|
| #1 | Nemotron 120B or GPT-OSS 120B | Largest available, most capable |
| #2 | Next largest from a different family | Different perspective |
| #3 | Gemma 4 31B or similar | Third family, still strong |

You never need to think about this. rival picks the best available models automatically.

### Pinning paid models (optional)

If you have OpenRouter credits and want to lead with specific paid models — for example a tri-corpus chain (xAI + DeepSeek + OpenAI) for maximum training-diversity — drop their IDs into `~/.rival/pinned.txt`, one per line. Pinned models bypass the `:free` filter, are health-checked, and always rank first in pin-file order.

```
mkdir -p ~/.rival
cp ~/.claude/plugins/cache/bambushu-rival/rival/*/pinned.txt.example ~/.rival/pinned.txt
$EDITOR ~/.rival/pinned.txt
```

`--auto 1` and the lead slot of `--panel` will then use your first pin. If `pinned.txt` is missing or empty, rival behaves exactly as before — free-tier discovery only.

---

## The chain in practice

This is the hero feature. Here is what `--panel` actually produces:

```
/rival --panel

  +-----------------------------------------------------------------------+
  |  Model #1  .  Round 1 of 3  .  "a different AI wrote this"             |
  +-----------------------------------------------------------------------+
  |                                                                         |
  |  [BUG-1]  Missing argument validation - if $1 is empty, the script    |
  |           continues silently and writes garbage to the output file.    |
  |           Classic AI slop: the model that wrote this assumed inputs    |
  |           would always be valid.                                        |
  |                                                                         |
  |  [BUG-2]  No curl timeout flag. On a hung connection this blocks      |
  |           indefinitely with no feedback to the caller.                 |
  |                                                                         |
  |  [BUG-3]  Dead code: the $FALLBACK_MODEL branch on line 47 can never  |
  |           be reached - the condition above it is always true.          |
  |                                                                         |
  +-----------------------------------------------------------------------+
                    |
                    |  Findings passed to Model #2 (10s spacing)
                    v
  +-----------------------------------------------------------------------+
  |  Model #2  .  Round 2 of 3  .  "the first reviewer was too soft"       |
  +-----------------------------------------------------------------------+
  |                                                                         |
  |  [CONFIRM]  BUG-1 confirmed. Agree this will silently corrupt output.  |
  |                                                                         |
  |  [CONFIRM]  BUG-2 confirmed. Add --max-time 30 at minimum.             |
  |                                                                         |
  |  [DISPUTE]  BUG-3: the dead code branch IS reachable - first model     |
  |             missed that $FALLBACK_MODEL can be set externally via env.  |
  |             Sloppy analysis.                                            |
  |                                                                         |
  |  [NEW]      Critical: set -e at the top silently kills the retry       |
  |             loop on any non-zero curl exit. How did both the author    |
  |             AND the first reviewer miss this?                          |
  |                                                                         |
  |  [SLOP]     The retry logic is cargo-cult: looks sophisticated but     |
  |             can never fire because set -e exits first.                 |
  |                                                                         |
  +-----------------------------------------------------------------------+
                    |
                    |  All findings + dispute passed to Model #3 (10s spacing)
                    v
  +-----------------------------------------------------------------------+
  |  Model #3  .  Round 3 of 3  .  "I trust nobody"                        |
  +-----------------------------------------------------------------------+
  |                                                                         |
  |  VERDICT on BUG-3 dispute: Model #2 is correct. The env-set path is   |
  |  valid. Model #1's analysis was incomplete.                            |
  |                                                                         |
  |  PRIORITY ORDER:                                                        |
  |  1. CRITICAL: set -e / retry conflict - breaks core functionality      |
  |  2. HIGH: Missing arg validation - data corruption risk                |
  |  3. MEDIUM: No curl timeout - reliability issue                        |
  |  4. LOW: Cargo-cult retry (consequence of #1, resolves with fix)       |
  |                                                                         |
  +-----------------------------------------------------------------------+
                    |
                    v
         Summary merged back into Claude
           3 bugs confirmed . 1 dispute resolved . 1 AI slop pattern flagged
```

This is not three separate reports you have to reconcile. It is a conversation among three reviewers who have actually read each other's work. The third model acts as arbiter. You get a verdict, not a list.

---

## The chain vs parallel question

### Parallel review (what most people expect)

Three models see the same code, independently, and you get three separate reports. You then have to read all three and figure out what matters. Disagreements are invisible.

### Sequential chain review (what --panel actually does)

The chain is different. Each model receives not only the code but the full findings of every model that reviewed it before. The second model reads the first model's output and responds to it - agreeing, extending, disputing. The third model reads both.

This mirrors how a real code review meeting works. Parallel review is silent polling. The chain is a meeting. For adversarial review specifically, you want the meeting.

---

## Modes at a glance

```
/rival
  |
  +-- best available model (auto-selected)
        reviews your current file or selection
        returns findings directly

/rival --panel
  |
  +-- Model #1 --> findings
  +-- Model #2 --> builds on prior findings, disputes where wrong
  +-- Model #3 --> resolves disputes, prioritizes, synthesizes
        returns chained summary with verdict
        (10s spacing between models for free-tier rate limits)
        degrades gracefully if fewer models available

/rival --panel-parallel
  |
  +-- Model #1 --+
  +-- Model #2 --| independent, spaced 10s apart
  +-- Model #3 --+
        merged: consensus / unique findings / disagreements

/rival --local
  |
  +-- local Ollama model (default: qwen2.5-coder:32b)
        same review behavior, zero network dependency
        override model: /rival --local deepseek-r1:32b
```

---

## Requirements

- **Claude Code** v2.1.80+
- **jq** (`brew install jq`)
- **curl**
- **python3** (for timing during discovery health checks)

For OpenRouter mode (default):
- **OpenRouter API key** - free at [openrouter.ai](https://openrouter.ai)

For local mode (`--local`):
- **Ollama** - [ollama.com](https://ollama.com) (`brew install ollama`)
- A pulled model (e.g., `ollama pull qwen2.5-coder:32b`)

---

## Installation

### 1. Add the marketplace and install

```bash
claude plugin marketplace add https://github.com/bambushu/rival
claude plugin install rival@bambushu-rival
```

### 2. Add your OpenRouter key

```bash
echo 'export OPENROUTER_API_KEY="sk-or-..."' >> ~/.zshrc
source ~/.zshrc
```

### 3. Verify

```bash
claude plugin list
# rival@bambushu-rival should appear as enabled

/rival
# should prompt for a file or use the current editor context
```

---

## Usage

### Single model review

```
/rival
```

Reviews the current file or selection using the best available free model. Returns findings inline.

### Override the model

```
/rival --model nvidia/nemotron-3-super-120b-a12b:free
/rival --model google/gemma-4-31b-it:free
```

Any model from the OpenRouter free tier works here.

### Sequential panel review

```
/rival --panel
```

Runs three models in sequence with 10s spacing. Each model receives prior findings. Returns a synthesized summary with disputed points flagged.

### Parallel panel review

```
/rival --panel-parallel
```

Runs three models independently (spaced, not simultaneous - free tier requires it). Results merged into:
- **Consensus** - all models flagged this
- **Unique** - only one model flagged this
- **Disagreements** - models reached opposite conclusions

### Local mode (Ollama)

```
/rival --local
```

Routes the review to a local Ollama model instead of OpenRouter. No API key needed, works offline, zero cost. Default model: `qwen2.5-coder:32b`.

Override the local model:

```
/rival --local deepseek-r1:32b
/rival --local llama3.1:70b
```

Local mode uses the same adversarial review prompt and produces the same output format. The only difference is where the inference runs.

When to use local vs OpenRouter:
- **Local**: offline work, privacy-sensitive code, OpenRouter rate-limited, quick first-pass
- **OpenRouter**: larger models (120B+), panel mode with diverse families, production reviews

### Refresh model roster

```
/rival --discover
```

Manually re-runs model discovery. Useful after OpenRouter adds new free models.

### Task delegation via rival-rescue

For general delegation (not just review), the `rival:rival-rescue` agent routes tasks to the companion script:

```
rival:rival-rescue(refactor the payment module to handle idempotency)
```

Use this anywhere Claude Code accepts agent calls.

---

## Rate limit handling

Free-tier models on OpenRouter have rate limits (~20 req/min, ~200 req/day). rival handles this automatically:

- **Discovery** health-checks models before adding them to the roster, retries once on 429, and stops early once enough healthy models are found
- **Minimum parameter filter** (7B+) excludes tiny models that waste rate limit budget on useless reviews
- **Panel spacing** adds 10s between requests to avoid back-to-back 429s
- **Retry logic** with 5 attempts, exponential backoff (5s base), and `Retry-After` header parsing
- **Model fallback** when a model exhausts all retries on 429, automatically falls back to the next ranked model in the discovery cache
- **Graceful panel degradation** if fewer models are available than requested, panel size reduces automatically

If you're hitting limits consistently, run `/rival --discover` to refresh - models that were congested earlier may have freed up. Or use `--local` to bypass OpenRouter entirely.

---

## Technical details

### scripts/rival-discover.sh

The discovery script:
- Queries OpenRouter `/api/v1/models` for all free-tier models
- Filters: must end in `:free`, context length >= 32k, parameter count >= 7B
- Parses parameter count from model ID (e.g., "120b" -> 120)
- Selects top 8 candidates with family diversity (prefers different model families)
- Health-checks each with a "Say OK" ping (12s timeout, 8s spacing between pings)
- Retries each ping once on 429 before marking as failed
- Stops early once 3+ healthy models from 2+ families are found (preserves rate limit budget)
- Writes survivors ranked by param count to `~/.rival/models.json`
- Cache TTL: 24 hours (configurable in script)

### scripts/rival-companion.sh

The companion script handles all OpenRouter and Ollama communication:
- `--auto [N]` picks the Nth model from the discovery cache (default: 1)
- `--delay N` waits N seconds before making the request (panel spacing)
- `--model ID` overrides auto-selection with a specific model
- `--local [MODEL]` routes to local Ollama (default: qwen2.5-coder:32b)
- Auto-triggers discovery when cache is missing or stale
- Sources `~/.zshrc` for env var inheritance in hook contexts
- Uses stdin for curl body to avoid ARG_MAX limits on large inputs
- Retries on 429/503 with exponential backoff and Retry-After header support
- Falls back to next ranked model when retries are exhausted on 429

### agents/rival-rescue.md

Defines the `rival:rival-rescue` agent that forwards general delegation tasks to the companion script. Works like codex-rescue but routes to OpenRouter instead of Codex.

### skills/rival/skill.md

Defines the `/rival` skill and all panel modes. No hooks needed - rival is on-demand only. No background processes, no flag files, no persistent state.

---

## Files

```
plugins/rival/
  .claude-plugin/plugin.json        # Plugin manifest
  scripts/rival-companion.sh        # OpenRouter API caller with retry + auto-select
  scripts/rival-discover.sh         # Model discovery + health check + cache
  agents/rival-rescue.md            # General task delegation agent
  skills/rival/skill.md             # /rival skill - single, panel, panel-parallel
  LICENSE                           # MIT
```

---

## What we learned building this

A few things worth noting for anyone building OpenRouter-backed Claude Code plugins:

1. **Free models disappear** - OpenRouter's free-tier roster changes without notice. Hardcoded model IDs broke within weeks. Dynamic discovery with health-check pings is the only reliable approach.
2. **Env vars don't survive hooks** - the companion script has to source `~/.zshrc` via `bash -l` (login shell). Otherwise `OPENROUTER_API_KEY` is empty inside Claude Code's hook context.
3. **Large code inputs break `$()` substitution** - bash command substitution has an ARG_MAX ceiling. Feeding the curl body via stdin sidesteps this entirely.
4. **Sequential chain output needs structure** - early versions just concatenated model outputs. The chain only becomes useful when each model is explicitly told "here are the prior findings - address them."
5. **Free tier models are rate-limited, not throttled** - you won't get degraded quality at peak times, you just get a 429. Spacing requests 10s apart plus retry logic handles this without user action.
6. **`set -e` and retry loops do not mix** - `set -e` causes the script to exit immediately on any non-zero exit code, which means a retry loop only retries on HTTP errors (where curl exits 0). Network failures kill the script before any retry condition is evaluated.
7. **Not all free models are equal** - some (Nemotron, GPT-OSS) respond instantly while others (Qwen, Llama) are heavily congested. Discovery health-checks solve this by testing reality, not assumptions.
8. **Family diversity matters for adversarial review** - three models from the same family (e.g., all Qwen variants) tend to have correlated blind spots. Mixing families (nvidia + openai + google) produces genuinely independent perspectives.
9. **Tiny models waste rate limit budget** - a 1.2B model passing discovery health-checks means it occupies a cache slot that could have gone to a useful model. The 7B minimum parameter filter prevents this.
10. **Discovery pings need breathing room** - 2s between health-check pings caused cascading 429s for later candidates. 8s spacing with a single retry per model catches models that were temporarily rate-limited without burning the budget on permanently congested ones.
11. **Model fallback beats retry escalation** - retrying the same rate-limited model 5 times with exponential backoff wastes 30+ seconds. Falling back to the next ranked model after exhausting retries gets a response faster.
12. **Local models are competitive for code review** - a 32B code-specialized local model (Qwen 2.5 Coder) produces comparable review quality to 120B general-purpose remote models for most code tasks. Domain specialization closes the parameter gap.
13. **"Another AI wrote this" unlocks real criticism** - models are measurably more critical when they believe they're reviewing another model's output. Neutral prompts ("find problems") produce hedged, diplomatic reviews. Telling the model it's reviewing a rival's work triggers competitive instincts that bypass the default politeness.
14. **Bad mood framing reduces hedging** - "you're in a bad mood" is a simple prompt addition that eliminates the "this could potentially be an issue" language. Reviews become direct and specific.
15. **AI slop is a real review category** - models are good at recognizing patterns that other models produce: over-abstraction nobody asked for, error handling for impossible scenarios, cargo-cult code that looks sophisticated but does nothing. Making this an explicit review target catches things human reviewers would flag but polite AI reviewers ignore.
16. **Panel aggression should escalate** - the first reviewer finds issues, the second reviewer distrusts the first, the third trusts nobody. This mirrors how real adversarial review works: each layer strips away more politeness and finds what the previous layers were too diplomatic to flag.

---

## The story behind this

I kept running into a version of the same problem: after a long Claude Code session building something, I'd ask Claude to review it and get back a polished endorsement of everything it had just written.

That's not review. That's confirmation.

The obvious fix is to use a completely different model with no context. OpenRouter makes that free. But a single free model giving a single pass still misses things - not because the model is bad, but because any single reviewer has blind spots.

The chain idea came from thinking about how actual code review works on good teams. The first reviewer does the initial pass. The second reviewer reads that first pass before looking at the code - they come in knowing what to focus on and what's already been covered. The third reviewer resolves disputes. Three reviewers who have actually talked to each other are worth more than three reviewers who submit separate reports.

rival was built iteratively in a single session. Once the core was working, the first real test was running `/rival --panel` on rival's own source code. The chain found real bugs - including the critical `set -e` vs retry loop conflict that silently defeated the entire retry mechanism.

Three rounds of review. Each caught something the previous missed. All of the findings were real bugs that got fixed.

Getting the prompt contracts right - so each model in the chain actually responds to prior findings rather than starting fresh - was the hardest part.

The "bad mood" prompting came later. Early versions used neutral adversarial prompts ("find problems, not praise") and the results were... diplomatic. Models would hedge. "This could potentially be an issue in some edge cases." Useless. Telling them the code was written by another AI and that they should assume it cut corners changed the tone completely. The reviews got specific, the hedging disappeared, and a new category emerged: AI slop detection. Models are surprisingly good at recognizing patterns that other models produce - over-abstraction, unnecessary error handling for impossible cases, cargo-cult code that looks sophisticated but does nothing.

The result is something that costs nothing and tells you things Claude won't.

---

## Contributing

Open issues and PRs at [github.com/bambushu/rival](https://github.com/bambushu/rival).

Ideas for future versions:
- `--focus` flag to target specific concerns (security, performance, style)
- `--file` override to review a specific path rather than current context
- Output as a structured JSON report for downstream tooling
- Multi-provider support (Groq, Together AI as backup providers)
- Local panel mode (chain multiple Ollama models for offline panel review)

---

## License

MIT - Bambushu
