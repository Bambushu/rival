#!/usr/bin/env bash
set -uo pipefail
# NOTE: no -e — we handle errors explicitly so retry logic works on curl failures

# rival-companion.sh — OpenRouter API wrapper for the rival plugin
# Usage: rival-companion.sh [--model MODEL] [--system SYSTEM_PROMPT] TASK_TEXT
# Default model: nvidia/nemotron-3-super-120b-a12b:free

# Check dependencies
command -v jq >/dev/null 2>&1 || { echo "Error: jq is required but not installed" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "Error: curl is required but not installed" >&2; exit 1; }

# Source env if key not already set (fixes subagent inheritance)
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  # Try login shell
  OPENROUTER_API_KEY=$(bash -lc 'echo "$OPENROUTER_API_KEY"' 2>/dev/null) || true
fi
if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  # Try sourcing common dotfiles directly
  for f in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.zprofile" "$HOME/.profile" "$HOME/.env"; do
    if [[ -f "$f" ]] && grep -q OPENROUTER_API_KEY "$f" 2>/dev/null; then
      OPENROUTER_API_KEY=$(grep 'OPENROUTER_API_KEY' "$f" | head -1 | sed 's/.*=["'"'"']\{0,1\}//' | sed 's/["'"'"']\{0,1\}$//')
      [[ -n "$OPENROUTER_API_KEY" ]] && break
    fi
  done
fi

MODEL="nvidia/nemotron-3-super-120b-a12b:free"
SYSTEM_PROMPT=""
TASK_TEXT=""
MAX_RETRIES=5
RETRY_DELAY=5
INITIAL_DELAY=0
AUTO_RANK=0
USE_LOCAL=false
LOCAL_MODEL="qwen2.5-coder:32b"
OLLAMA_BASE="${OLLAMA_HOST:-http://localhost:11434}"
CACHE_FILE="$HOME/.rival/models.json"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --model)
      [[ $# -ge 2 ]] || { echo "Error: --model requires a value" >&2; exit 1; }
      MODEL="$2"
      shift 2
      ;;
    --system)
      [[ $# -ge 2 ]] || { echo "Error: --system requires a value" >&2; exit 1; }
      SYSTEM_PROMPT="$2"
      shift 2
      ;;
    --delay)
      [[ $# -ge 2 ]] || { echo "Error: --delay requires a value in seconds" >&2; exit 1; }
      INITIAL_DELAY="$2"
      shift 2
      ;;
    --local)
      USE_LOCAL=true
      # Optional local model override: --local deepseek-r1:32b
      # Model names contain ":" or "/" — anything else is task text
      if [[ $# -ge 2 && "$2" =~ [:\/] && ! "$2" =~ ^-- ]]; then
        LOCAL_MODEL="$2"
        shift 2
      else
        shift
      fi
      ;;
    --auto)
      # --auto or --auto N (default N=1)
      if [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]]; then
        AUTO_RANK="$2"
        shift 2
      else
        AUTO_RANK=1
        shift
      fi
      ;;
    *)
      if [[ -z "$TASK_TEXT" ]]; then
        TASK_TEXT="$1"
      else
        TASK_TEXT="$TASK_TEXT $1"
      fi
      shift
      ;;
  esac
done

# Handle --auto: pick model from discovery cache
if [[ "$AUTO_RANK" -gt 0 ]]; then
  # Auto-trigger discovery if cache is missing or stale
  needs_discovery=false
  if [[ ! -f "$CACHE_FILE" ]]; then
    needs_discovery=true
  else
    cache_age=$(( ( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || stat -c %Y "$CACHE_FILE" 2>/dev/null || echo 0) ) / 3600 ))
    ttl=$(jq -r '.ttl_hours // 24' "$CACHE_FILE" 2>/dev/null || echo 24)
    [[ "$cache_age" -ge "$ttl" ]] && needs_discovery=true
  fi

  if [[ "$needs_discovery" == "true" ]]; then
    echo "Model cache stale/missing. Running discovery..." >&2
    bash "$SCRIPT_DIR/rival-discover.sh" --force >&2 || true
  fi

  # Read model from cache by rank (1-indexed)
  if [[ -f "$CACHE_FILE" ]]; then
    idx=$((AUTO_RANK - 1))
    auto_model=$(jq -r ".models[$idx].id // empty" "$CACHE_FILE" 2>/dev/null)
    if [[ -n "$auto_model" ]]; then
      MODEL="$auto_model"
      echo "Auto-selected model #$AUTO_RANK: $MODEL" >&2
    else
      echo "Warning: rank $AUTO_RANK not in cache (only $(jq '.models | length' "$CACHE_FILE") models). Using default." >&2
    fi
  else
    echo "Warning: discovery failed, using default model." >&2
  fi
fi

if [[ -z "$TASK_TEXT" ]]; then
  echo "Error: no task text provided" >&2
  exit 1
fi

# --local: route to Ollama instead of OpenRouter
if [[ "$USE_LOCAL" == "true" ]]; then
  if ! curl -s --connect-timeout 2 --max-time 3 "${OLLAMA_BASE}/api/tags" >/dev/null 2>&1; then
    echo "Error: Ollama not reachable at ${OLLAMA_BASE}. Start with: brew services start ollama" >&2
    exit 1
  fi
  MODEL="$LOCAL_MODEL"
  echo "Local mode: ${MODEL} via Ollama" >&2

  if [[ -n "$SYSTEM_PROMPT" ]]; then
    messages=$(jq -n --arg sys "$SYSTEM_PROMPT" --arg usr "$TASK_TEXT" \
      '[{"role":"system","content":$sys},{"role":"user","content":$usr}]')
  else
    messages=$(jq -n --arg usr "$TASK_TEXT" '[{"role":"user","content":$usr}]')
  fi

  body=$(jq -n --arg model "$MODEL" --argjson messages "$messages" \
    '{"model": $model, "messages": $messages, "max_tokens": 16384, "stream": false}')

  response=$(curl -s --connect-timeout 5 --max-time 300 \
    -w "\n%{http_code}" \
    -X POST "${OLLAMA_BASE}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d @- <<< "$body") || { echo "Error: Ollama request failed" >&2; exit 1; }

  http_code="${response##*$'\n'}"
  response_body="${response%$'\n'*}"

  if [[ "$http_code" -ne 200 ]]; then
    echo "Ollama error (HTTP $http_code):" >&2
    echo "$response_body" | jq -r '.error // .' 2>/dev/null >&2
    exit 1
  fi

  content=$(echo "$response_body" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  echo "${content:-No response content}"
  exit 0
fi

if [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "Error: OPENROUTER_API_KEY not set. Add it to ~/.zshrc or export it." >&2
  exit 1
fi

# Build messages array
if [[ -n "$SYSTEM_PROMPT" ]]; then
  messages=$(jq -n \
    --arg sys "$SYSTEM_PROMPT" \
    --arg usr "$TASK_TEXT" \
    '[{"role":"system","content":$sys},{"role":"user","content":$usr}]')
else
  messages=$(jq -n \
    --arg usr "$TASK_TEXT" \
    '[{"role":"user","content":$usr}]')
fi

# Build request body
body=$(jq -n \
  --arg model "$MODEL" \
  --argjson messages "$messages" \
  '{
    "model": $model,
    "messages": $messages,
    "max_tokens": 16384
  }')

# Honour --delay for panel mode spacing (avoids back-to-back free-tier hits)
if [[ "$INITIAL_DELAY" -gt 0 ]]; then
  echo "Waiting ${INITIAL_DELAY}s before request (panel spacing)..." >&2
  sleep "$INITIAL_DELAY"
fi

# Temp file for response headers (cleaned up on exit)
header_file=$(mktemp)
trap 'rm -f "$header_file"' EXIT

# Call OpenRouter with retry logic for transient failures
attempt=0
while true; do
  attempt=$((attempt + 1))

  response=$(curl -s --connect-timeout 10 --max-time 120 \
    -D "$header_file" -w "\n%{http_code}" \
    -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://github.com/bambushu/rival" \
    -H "X-Title: rival-plugin" \
    -d @- <<< "$body") || true

  # Split response body and status code safely
  http_code="${response##*$'\n'}"
  response_body="${response%$'\n'*}"

  # Guard: if http_code isn't numeric, curl failed entirely
  if ! [[ "$http_code" =~ ^[0-9]+$ ]]; then
    if [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
      echo "Curl failed (attempt $attempt/$MAX_RETRIES), retrying in ${RETRY_DELAY}s..." >&2
      sleep "$RETRY_DELAY"
      RETRY_DELAY=$((RETRY_DELAY * 2))
      continue
    fi
    echo "Error: curl failed after $attempt attempts (no HTTP status received)" >&2
    exit 1
  fi

  # Retry on 429 (rate limit) or 503 (service unavailable)
  if [[ "$http_code" -eq 429 || "$http_code" -eq 503 ]]; then
    if [[ "$attempt" -lt "$MAX_RETRIES" ]]; then
      # Respect Retry-After header if present (seconds or HTTP-date)
      retry_after=$(grep -i '^retry-after:' "$header_file" 2>/dev/null | head -1 | sed 's/[^0-9]//g')
      if [[ -n "$retry_after" && "$retry_after" -gt 0 ]] 2>/dev/null; then
        wait_time="$retry_after"
      else
        wait_time="$RETRY_DELAY"
      fi
      echo "Rate limited (attempt $attempt/$MAX_RETRIES), waiting ${wait_time}s..." >&2
      sleep "$wait_time"
      RETRY_DELAY=$((RETRY_DELAY * 2))
      continue
    fi
  fi

  break
done

if [[ "$http_code" -ne 200 ]]; then
  echo "OpenRouter API error (HTTP $http_code) after $attempt attempt(s):" >&2
  echo "$response_body" | jq -r '.error.message // .error // .' 2>/dev/null >&2
  exit 1
fi

# Extract and print the response content
content=$(echo "$response_body" | jq -r '.choices[0].message.content // empty' 2>/dev/null) || {
  echo "Error: failed to parse API response" >&2
  echo "$response_body" >&2
  exit 1
}
echo "${content:-No response content}"
