#!/usr/bin/env bash
set -uo pipefail
# NOTE: no -e — we handle errors explicitly so retry logic works on curl failures

# rival-companion.sh — OpenRouter API wrapper for the rival plugin
# Usage: rival-companion.sh [--model MODEL] [--system SYSTEM_PROMPT] TASK_TEXT
# Default model: qwen/qwen3.6-plus:free

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

MODEL="qwen/qwen3.6-plus:free"
SYSTEM_PROMPT=""
TASK_TEXT=""
MAX_RETRIES=3
RETRY_DELAY=2

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

if [[ -z "$TASK_TEXT" ]]; then
  echo "Error: no task text provided" >&2
  exit 1
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

# Call OpenRouter with retry logic for transient failures
attempt=0
while true; do
  attempt=$((attempt + 1))

  response=$(curl -s --connect-timeout 10 --max-time 120 -w "\n%{http_code}" \
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
      sleep "$RETRY_DELAY"
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
