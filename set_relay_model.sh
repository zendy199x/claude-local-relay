#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".env" ]; then
  cp .env.example .env
fi

MODEL_ID="${1:-}"

if [ -z "$MODEL_ID" ]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required. Install it with your package manager and retry."
    exit 1
  fi

  if ! RAW="$(curl -sS http://127.0.0.1:1234/v1/models 2>/dev/null)"; then
    echo "Cannot reach LM Studio on 127.0.0.1:1234."
    echo "Start LM Studio server first, then run this again."
    exit 1
  fi

  MODELS=()
  while IFS= read -r line; do
    [ -n "$line" ] && MODELS+=("$line")
  done <<EOF
$(printf '%s' "$RAW" | jq -r '.data[].id // empty')
EOF

  if [ "${#MODELS[@]}" -eq 0 ]; then
    echo "No models found. Load a model in LM Studio first."
    exit 1
  fi

  if [ "${#MODELS[@]}" -eq 1 ]; then
    MODEL_ID="${MODELS[0]}"
  else
    echo "Multiple models found. Pass one explicitly:"
    printf '  %s\n' "${MODELS[@]}"
    echo "Usage: $0 <model-id>"
    exit 1
  fi
fi

if grep -q '^LOCAL_MODEL=' .env; then
  if sed --version >/dev/null 2>&1; then
    sed -i "s|^LOCAL_MODEL=.*|LOCAL_MODEL=${MODEL_ID}|g" .env
  else
    sed -i '' "s|^LOCAL_MODEL=.*|LOCAL_MODEL=${MODEL_ID}|g" .env
  fi
else
  echo "LOCAL_MODEL=${MODEL_ID}" >> .env
fi

echo "Updated .env -> LOCAL_MODEL=${MODEL_ID}"
