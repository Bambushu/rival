#!/usr/bin/env bash
set -uo pipefail

# rival-discover.sh — Discover best available free models on OpenRouter
# Queries the model list, filters for :free with sufficient context,
# ranks by parameter count, health-checks the top candidates,
# and writes a ranked roster to ~/.rival/models.json
#
# Usage: rival-discover.sh [--force]
#   --force: skip cache age check, always rediscover

CACHE_DIR="$HOME/.rival"
CACHE_FILE="$CACHE_DIR/models.json"
TTL_HOURS=24
MIN_CONTEXT=32768
MIN_PARAMS_B=7        # Exclude tiny models useless for code review
PING_TIMEOUT=12       # Free tier can be slow to respond
PING_DELAY=8          # Seconds between health-check pings (free tier needs breathing room)
MIN_HEALTHY=3         # Stop pinging once we have this many healthy diverse-family models
MAX_CANDIDATES=8

FORCE=false
[[ "${1:-}" == "--force" ]] && FORCE=true

# Check dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed" >&2; exit 1; }

# Source API key
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  OPENROUTER_API_KEY=$(bash -lc 'echo "$OPENROUTER_API_KEY"' 2>/dev/null) || true
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.profile" "$HOME/.env"; do
    if [[ -f "$f" ]] && grep -q OPENROUTER_API_KEY "$f" 2>/dev/null; then
      OPENROUTER_API_KEY=$(grep 'OPENROUTER_API_KEY' "$f" | head -1 | sed 's/.*=["'"'"']\{0,1\}//' | sed 's/["'"'"']\{0,1\}$//')
      [[ -n "$OPENROUTER_API_KEY" ]] && break
    fi
  done
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "Error: OPENROUTER_API_KEY not set." >&2
  exit 1
fi

# Check cache freshness (skip if --force)
if [[ "$FORCE" == "false" && -f "$CACHE_FILE" ]]; then
  cache_age=$(( ( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ) / 3600 ))
  if [[ "$cache_age" -lt "$TTL_HOURS" ]]; then
    echo "Cache is ${cache_age}h old (TTL: ${TTL_HOURS}h). Use --force to refresh." >&2
    exit 0
  fi
fi

mkdir -p "$CACHE_DIR"

echo "Discovering free models on OpenRouter..." >&2

# Fetch all models
models_raw=$(curl -s --connect-timeout 10 --max-time 30 \
  "https://openrouter.ai/api/v1/models" \
  -H "Authorization: Bearer ${OPENROUTER_API_KEY}") || {
  echo "Error: failed to fetch model list" >&2
  exit 1
}

# Filter: :free suffix, context >= MIN_CONTEXT, params >= MIN_PARAMS_B
# Extract param count from model ID heuristics (e.g., "120b", "31b", "70b")
candidates=$(echo "$models_raw" | jq --argjson min_ctx "$MIN_CONTEXT" --argjson min_params "$MIN_PARAMS_B" '
  [.data[]
   | select(.id | endswith(":free"))
   | select(.context_length >= $min_ctx)
   | {
       id: .id,
       context: .context_length,
       family: (.id | split("/")[0]),
       params_b: (
         (.id | capture("(?<p>[0-9]+)[bB]") | .p | tonumber) // 0
       )
     }
   | select(.params_b >= $min_params)
  ]
  | sort_by(-.params_b)
')

total=$(echo "$candidates" | jq 'length')
echo "Found $total free models with >= ${MIN_CONTEXT} context." >&2

if [[ "$total" -eq 0 ]]; then
  echo "Error: no eligible models found" >&2
  exit 1
fi

# Select top free candidates with family diversity.
# Take up to MAX_CANDIDATES, preferring different families.
# Tag each with pinned:false so the merged list + health check + cache can distinguish
# discovered free models from user-pinned paid models.
free_selected=$(echo "$candidates" | jq --argjson max "$MAX_CANDIDATES" '
  reduce .[] as $m (
    {picked: [], families_used: []};
    if (.picked | length) >= $max then .
    elif (.families_used | index($m.family)) != null and (.picked | length) >= 3 then .
    else .picked += [$m + {pinned: false}] | .families_used += [$m.family]
    end
  ) | .picked
')

# Read user-pinned paid models from ~/.rival/pinned.txt (one OpenRouter ID per line; #-comments ok).
# Pinned models bypass the :free filter and always go first in the ranked cache (pin-file order),
# so panel mode's --auto 1 picks the first pinned model as lead reviewer.
PINNED_FILE="$CACHE_DIR/pinned.txt"
pinned_ids_json="[]"
if [[ -f "$PINNED_FILE" ]]; then
  pinned_ids_json=$(grep -v '^[[:space:]]*#' "$PINNED_FILE" 2>/dev/null \
    | grep -v '^[[:space:]]*$' \
    | sed 's/[[:space:]]//g' \
    | jq -R . | jq -s .)
  num_pinned_req=$(echo "$pinned_ids_json" | jq 'length')
  if [[ "$num_pinned_req" -gt 0 ]]; then
    echo "Pinned models requested ($num_pinned_req): $(echo "$pinned_ids_json" | jq -r 'join(", ")')" >&2
  fi
fi

# Extract pinned model data from the already-fetched catalog (bypass :free filter).
# Still enforce MIN_CONTEXT — pinning a tiny-context model would break panel reviews anyway.
pinned_selected=$(jq -n \
  --argjson all "$models_raw" \
  --argjson ids "$pinned_ids_json" \
  --argjson min_ctx "$MIN_CONTEXT" '
  $ids | map(. as $id |
    ($all.data[] | select(.id == $id)) |
    select(.context_length >= $min_ctx) |
    {
      id: .id,
      context: .context_length,
      family: (.id | split("/")[0]),
      params_b: ((.id | capture("(?<p>[0-9]+)[bB]") | .p | tonumber) // 0),
      pinned: true
    })
')

# Warn on pinned IDs that failed to resolve (absent from catalog, or below MIN_CONTEXT)
num_pinned_resolved=$(echo "$pinned_selected" | jq 'length')
num_pinned_requested=$(echo "$pinned_ids_json" | jq 'length')
if [[ "$num_pinned_resolved" -lt "$num_pinned_requested" ]]; then
  resolved_ids=$(echo "$pinned_selected" | jq '[.[].id]')
  missing=$(jq -n --argjson req "$pinned_ids_json" --argjson got "$resolved_ids" \
    '[$req[] | select(. as $id | $got | index($id) == null)]')
  echo "Warning: pinned model(s) not resolvable (missing from catalog or ctx < ${MIN_CONTEXT}): $(echo "$missing" | jq -r 'join(", ")')" >&2
fi

# Combine: pinned first (pin-file order), then free (dedupe by id — pinned wins on collision).
selected=$(jq -n --argjson pinned "$pinned_selected" --argjson free "$free_selected" '
  $pinned + [$free[] | select(.id as $id | $pinned | map(.id) | index($id) == null)]
')

num_selected=$(echo "$selected" | jq 'length')
num_free=$((num_selected - num_pinned_resolved))
echo "Selected $num_selected candidates for health check ($num_pinned_resolved pinned + $num_free free):" >&2
echo "$selected" | jq -r '.[] | "  \(.id) (\(.params_b)B, \(.context/1024|floor)k ctx\(if .pinned then ", pinned" else "" end))"' >&2

# Health-check: ping each candidate with a simple prompt
echo "Running health checks (${PING_TIMEOUT}s timeout each)..." >&2

healthy="[]"
for i in $(seq 0 $((num_selected - 1))); do
  model_id=$(echo "$selected" | jq -r ".[$i].id")
  params_b=$(echo "$selected" | jq -r ".[$i].params_b")
  context=$(echo "$selected" | jq -r ".[$i].context")
  family=$(echo "$selected" | jq -r ".[$i].family")
  pinned=$(echo "$selected" | jq -r ".[$i].pinned // false")

  # Ping with minimal prompt (retry once on 429)
  # max_tokens=16 because Azure-routed OpenAI models (GPT-5/o-series) reject anything below 16
  ping_body=$(jq -n --arg model "$model_id" '{
    "model": $model,
    "messages": [{"role": "user", "content": "Say OK"}],
    "max_tokens": 16
  }')

  ping_ok=false
  for ping_attempt in 1 2; do
    start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
    ping_response=$(curl -s --connect-timeout 5 --max-time "$PING_TIMEOUT" \
      -w "\n%{http_code}" \
      -X POST "https://openrouter.ai/api/v1/chat/completions" \
      -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "HTTP-Referer: https://github.com/bambushu/rival" \
      -H "X-Title: rival-discover" \
      -d "$ping_body") || true
    end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

    ping_code="${ping_response##*$'\n'}"
    ping_ms=$(( end_ms - start_ms ))

    if [[ "$ping_code" == "200" ]]; then
      ping_ok=true
      break
    elif [[ "$ping_code" == "429" && "$ping_attempt" -eq 1 ]]; then
      echo "  429  $model_id — retrying after ${PING_DELAY}s..." >&2
      sleep "$PING_DELAY"
    fi
  done

  if [[ "$ping_ok" == "true" ]]; then
    echo "  OK  $model_id (${ping_ms}ms)" >&2
    healthy=$(echo "$healthy" | jq \
      --arg id "$model_id" --argjson p "$params_b" --argjson c "$context" \
      --arg fam "$family" --argjson ms "$ping_ms" --argjson pin "$pinned" \
      '. + [{"id": $id, "params_b": $p, "context": $c, "family": $fam, "ping_ms": $ms, "pinned": $pin}]')
  else
    echo "  FAIL $model_id (HTTP ${ping_code:-timeout})" >&2
  fi

  # Early exit: if we have enough healthy models from diverse families, stop burning rate limit
  num_healthy_so_far=$(echo "$healthy" | jq 'length')
  healthy_families=$(echo "$healthy" | jq '[.[].family] | unique | length')
  if [[ "$num_healthy_so_far" -ge "$MIN_HEALTHY" && "$healthy_families" -ge 2 ]]; then
    echo "  Reached $num_healthy_so_far healthy models from $healthy_families families — stopping early." >&2
    break
  fi

  # Breathing room between pings — free tier rate limits are aggressive
  sleep "$PING_DELAY"
done

num_healthy=$(echo "$healthy" | jq 'length')

if [[ "$num_healthy" -eq 0 ]]; then
  echo "Error: no models passed health check" >&2
  exit 1
fi

# Rank: pinned first (preserve pin-file order), then free models by params_b desc, ping_ms asc.
# This makes --auto 1 always return the first pinned model when pins are configured,
# and --auto 2/3 fall back to the strongest family-diverse free models.
ranked=$(echo "$healthy" | jq '
  [.[] | select(.pinned == true)]
  + ([.[] | select(.pinned != true)] | sort_by(-.params_b, .ping_ms))
')

# Write cache
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg ts "$now" \
  --argjson ttl "$TTL_HOURS" \
  --argjson models "$ranked" \
  '{
    "discovered_at": $ts,
    "ttl_hours": $ttl,
    "models": $models
  }' > "$CACHE_FILE"

echo "" >&2
echo "Discovery complete. $num_healthy models available:" >&2
echo "$ranked" | jq -r '.[] | "  #\(. as $m | input_line_number // 0) \(.id) (\(.params_b)B, \(.ping_ms)ms)"' 2>/dev/null >&2 || \
echo "$ranked" | jq -r '.[] | "  \(.id) (\(.params_b)B, \(.ping_ms)ms)"' >&2
echo "Cache written to $CACHE_FILE" >&2
