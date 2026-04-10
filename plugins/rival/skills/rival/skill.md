---
name: rival
description: Adversarial code review and general task delegation via OpenRouter. Smart routing: review requests get adversarial treatment, other tasks get forwarded directly. Supports --panel (sequential chain) and --panel-parallel (blind parallel) modes. Use /rival to invoke.
user-invocable: true
---

# Rival — Adversarial Review

Get a critical second opinion from structurally different model families.

## When invoked

1. **Gather the target code.** Determine what to review:
   - If the user specified a file or code block: use that
   - If there are uncommitted changes: run `git diff` to get the current diff
   - If neither: ask the user what to review

2. **Detect intent.** Determine if the user wants:
   - **Review mode** (default when no clear intent): adversarial code review — proceed to step 3 (panel check)
   - **Task mode**: general delegation — the user asked rival to help with a task, answer a question, implement something, or do non-review work. In this case, forward the user's request directly to rival-rescue agent (Agent tool with `subagent_type: "rival:rival-rescue"`) WITHOUT the adversarial system prompt. Just pass the user's request as-is. Do not wrap it in a review prompt.

   Signals for task mode: "help with", "do", "implement", "fix", "build", "answer", "explain", "outstanding tasks", "use rival for", or any request that is clearly not about reviewing existing code.

3. **Check for panel mode.** If the user passed `--panel` or `--panel-parallel`:
   - `--panel` (or `--panel N`): sequential chained review (default, recommended)
   - `--panel-parallel` (or `--panel-parallel N`): blind parallel review (faster, less deep)
   - Default panel size is 3 models if no number given
   - Jump to the appropriate Panel Mode section below

4. **Send to rival model (single mode).** Use the rival-rescue agent (Agent tool with `subagent_type: "rival:rival-rescue"`) with this prompt structure:

   ```
   Review this code as an adversarial critic. Your job is to find problems, not praise.

   Focus on:
   - Bugs, logic errors, off-by-one mistakes
   - Security vulnerabilities (injection, auth bypass, data exposure)
   - Performance issues (N+1 queries, unnecessary allocations, blocking calls)
   - Edge cases not handled
   - Incorrect assumptions about data or state

   Be specific: cite line numbers, explain the impact, suggest the fix.
   Skip style nits and formatting — focus on things that break.

   Code to review:
   [THE CODE/DIFF]
   ```

5. **Present the findings.** Show the rival model's response with a header indicating which model reviewed it.

## Panel Mode (sequential chained multi-model review)

When `--panel` is used, send the code through multiple models **sequentially**, where each model builds on the previous model's findings. This avoids free-tier rate limits and produces deeper, layered analysis.

### Model selection (automatic)

Models are selected dynamically via `--auto N` which reads from a discovery cache (`~/.rival/models.json`). The cache ranks models by parameter count with family diversity enforced. If the cache is stale (>24h) or missing, discovery runs automatically.

To manually refresh the model roster: run `rival-discover.sh --force`

### Default panel (3 models):
1. `--auto 1` — top-ranked model, first pass
2. `--auto 2` — second-ranked model (different family), reviews code + first model's findings
3. `--auto 3` — third-ranked model (different family), validates + fills gaps

### Panel with 2 models (`--panel 2`):
1. `--auto 1`
2. `--auto 2`

If a model fails after retries, skip it and continue with remaining models.

### Sequential execution flow:

**IMPORTANT: Free-tier rate limit handling.** Between each panel request, pass `--delay 8` to rival-companion.sh. This spaces out requests to avoid 429 rate limits on OpenRouter's free tier. The delay is only added for the 2nd and 3rd models (the first fires immediately).

**Step 1 — First model:**
Send to rival-rescue with `--auto 1`:
```
Review this code as an adversarial critic. Your job is to find problems, not praise.
Focus on: bugs, logic errors, security vulnerabilities, performance issues, edge cases, incorrect assumptions.
Be specific: cite line numbers, explain the impact, suggest the fix.
Skip style nits — focus on things that break.

Code to review:
[THE CODE/DIFF]
```
Save the response as `findings_1`.

**Step 2 — Second model:**
Send to rival-rescue with `--auto 2 --delay 10`:
```
You are the second reviewer in a chained adversarial code review.
A previous reviewer already found these issues:

[findings_1]

Your job:
1. Review the ORIGINAL code independently — do NOT just agree with the first reviewer
2. Flag anything the first reviewer missed
3. If you disagree with any finding, explain why
4. Add any new issues you find

Original code:
[THE CODE/DIFF]
```
Save the response as `findings_2`.

**Step 3 — Third model:**
Send to rival-rescue with `--auto 3 --delay 10`:
```
You are the final reviewer in a 3-model chained adversarial code review.

Previous findings:
--- Reviewer 1 ---
[findings_1]

--- Reviewer 2 ---
[findings_2]

Your job:
1. Validate or dispute each finding from both reviewers
2. Add any issues both reviewers missed
3. Produce a FINAL consolidated summary with severity ratings:
   - CRITICAL: will break in production
   - HIGH: significant bug or security issue
   - MEDIUM: edge case or reliability concern
   - LOW: minor improvement

Original code:
[THE CODE/DIFF]
```
Save the response as `findings_3`.

### Presenting panel results:

Present the final model's consolidated summary as the primary output, prefixed with:

```
## Rival Panel Review (3 models, sequential chain)

Models: [model 1 name] → [model 2 name] → [model 3 name]

[findings_3 — the consolidated summary from the final reviewer]

---
<details>
<summary>Individual reviewer outputs</summary>

### Reviewer 1: [model 1 name]
[findings_1]

### Reviewer 2: [model 2 name]
[findings_2]
</details>
```

Note: The model names come from the `--auto` stderr output ("Auto-selected model #N: ..."). Include them in the header so the user knows which models reviewed.

The individual outputs go in a collapsed details block so the user sees the clean consolidated view first but can drill into each model's raw output.

## Parallel Panel Mode (--panel-parallel)

When `--panel-parallel` is used, send the SAME adversarial review prompt to multiple models **sequentially with spacing** (not truly parallel — free-tier rate limits make simultaneous requests unreliable). Each model reviews independently without seeing the others' findings.

Use the same model set and fallbacks as sequential mode.

Send each model the same adversarial review prompt (the single-mode prompt from step 4). Send them one at a time using rival-rescue agents:
- Model 1: `--auto 1`
- Model 2: `--auto 2 --delay 10`
- Model 3: `--auto 3 --delay 10`

### Presenting parallel panel results:

After all models return, present a merged review:

```
## Rival Panel Review (3 models, independent blind)

### Consensus (found by 2+ models)
- [findings that overlap across models]

### [Model 1 name] only
- [unique findings]

### [Model 2 name] only
- [unique findings]

### [Model 3 name] only
- [unique findings]

### Disagreements
- [where models contradict each other — flag for human judgment]
```

Consensus findings are highest priority. Unique findings from a single model are lower confidence but worth checking.

**Note:** Parallel mode is faster than sequential chain (no cross-referencing of findings) but less thorough. Requests are spaced 10s apart to respect free-tier rate limits.

## Model override

The user can specify a model: `/rival --model deepseek/deepseek-r1:free`

Pass the `--model` flag through to the rival-rescue agent. Model override is for single mode only — panel mode uses `--auto`.

When no `--model` is specified in single mode, use `--auto` (picks the top-ranked model from discovery cache).

## Example usage

```
/rival                              # single review with best available model
/rival src/auth.ts                  # review specific file
/rival --model deepseek/deepseek-r1:free  # use specific model
/rival --panel                      # 3-model sequential chain (recommended)
/rival --panel 2                    # 2-model sequential chain
/rival --panel-parallel             # 3-model independent review (spaced)
/rival --panel-parallel 2           # 2-model independent review
/rival --panel src/auth.ts          # panel review of specific file
/rival --discover                   # refresh model roster manually
```
