---
name: rival
description: Adversarial code review via OpenRouter. Sends current diff or specified code to rival models for a critical second opinion. Supports --panel (sequential chain) and --panel-parallel (blind parallel) modes. Use /rival to invoke.
user-invocable: true
---

# Rival — Adversarial Review

Get a critical second opinion from structurally different model families.

## When invoked

1. **Gather the target code.** Determine what to review:
   - If the user specified a file or code block: use that
   - If there are uncommitted changes: run `git diff` to get the current diff
   - If neither: ask the user what to review

2. **Check for panel mode.** If the user passed `--panel` or `--panel-parallel`:
   - `--panel` (or `--panel N`): sequential chained review (default, recommended)
   - `--panel-parallel` (or `--panel-parallel N`): blind parallel review (faster, less deep)
   - Default panel size is 3 models if no number given
   - Jump to the appropriate Panel Mode section below

3. **Send to rival model (single mode).** Use the rival-rescue agent (Agent tool with `subagent_type: "rival:rival-rescue"`) with this prompt structure:

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

4. **Present the findings.** Show the rival model's response with a header indicating which model reviewed it.

## Panel Mode (sequential chained multi-model review)

When `--panel` is used, send the code through multiple models **sequentially**, where each model builds on the previous model's findings. This avoids free-tier rate limits and produces deeper, layered analysis.

### Default panel (3 models):
1. `qwen/qwen3.6-plus:free` — first pass, finds initial issues
2. `google/gemma-3-27b-it:free` — second pass, reviews code + Qwen's findings
3. `meta-llama/llama-3.3-70b-instruct:free` — final pass, validates + fills gaps

### Panel with 2 models (`--panel 2`):
1. `qwen/qwen3.6-plus:free`
2. `google/gemma-3-27b-it:free`

### Fallback models (if a panel member returns error after retries):
- `qwen/qwen3-coder:free`
- `nvidia/nemotron-3-super-120b-a12b:free`
- `nousresearch/hermes-3-llama-3.1-405b:free`

If a model fails, try the next fallback. If all fallbacks fail for that slot, skip it and continue with remaining models.

### Sequential execution flow:

**Step 1 — First model (Qwen):**
Send to rival-rescue with `--model qwen/qwen3.6-plus:free`:
```
Review this code as an adversarial critic. Your job is to find problems, not praise.
Focus on: bugs, logic errors, security vulnerabilities, performance issues, edge cases, incorrect assumptions.
Be specific: cite line numbers, explain the impact, suggest the fix.
Skip style nits — focus on things that break.

Code to review:
[THE CODE/DIFF]
```
Save the response as `findings_1`.

**Step 2 — Second model (Gemma):**
Send to rival-rescue with `--model google/gemma-3-27b-it:free`:
```
You are the second reviewer in a chained adversarial code review.
A previous reviewer (Qwen) already found these issues:

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

**Step 3 — Third model (Llama):**
Send to rival-rescue with `--model meta-llama/llama-3.3-70b-instruct:free`:
```
You are the final reviewer in a 3-model chained adversarial code review.

Previous findings:
--- Reviewer 1 (Qwen) ---
[findings_1]

--- Reviewer 2 (Gemma) ---
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

Models: Qwen 3.6+ → Gemma 3 27B → Llama 3.3 70B

[findings_3 — the consolidated summary from the final reviewer]

---
<details>
<summary>Individual reviewer outputs</summary>

### Reviewer 1: Qwen 3.6+
[findings_1]

### Reviewer 2: Gemma 3 27B
[findings_2]
</details>
```

The individual outputs go in a collapsed details block so the user sees the clean consolidated view first but can drill into each model's raw output.

## Parallel Panel Mode (--panel-parallel)

When `--panel-parallel` is used, send the SAME code to multiple models **in parallel** using separate Agent calls in a single message. Each agent gets a different `--model` flag. Models review independently without seeing each other's findings.

Use the same model set and fallbacks as sequential mode.

Send each model the same adversarial review prompt (the single-mode prompt from step 3). Launch all agents in a single message for true parallelism.

### Presenting parallel panel results:

After all agents return, present a merged review:

```
## Rival Panel Review (3 models, parallel blind)

### Consensus (found by 2+ models)
- [findings that overlap across models]

### Qwen 3.6+ only
- [unique findings from Qwen]

### Gemma 3 27B only
- [unique findings from Gemma]

### Llama 3.3 70B only
- [unique findings from Llama]

### Disagreements
- [where models contradict each other — flag for human judgment]
```

Consensus findings are highest priority. Unique findings from a single model are lower confidence but worth checking.

**Note:** Parallel mode is faster but less thorough than sequential. It's also more likely to hit free-tier rate limits. Use when speed matters more than depth.

## Model override

The user can specify a model: `/rival --model deepseek/deepseek-r1:free`

Pass the `--model` flag through to the rival-rescue agent. Model override is for single mode only — panel mode uses its own model set.

## Example usage

```
/rival                              # single review with Qwen 3.6+
/rival src/auth.ts                  # review specific file
/rival --model deepseek             # use DeepSeek instead
/rival --panel                      # 3-model sequential chain (recommended)
/rival --panel 2                    # 2-model sequential chain
/rival --panel-parallel             # 3-model blind parallel (faster)
/rival --panel-parallel 2           # 2-model blind parallel
/rival --panel src/auth.ts          # panel review of specific file
```
