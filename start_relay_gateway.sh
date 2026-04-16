#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if [ ! -f ".env" ]; then
  cp .env.example .env
  echo "Created .env from .env.example"
  echo "Edit .env before first run (set CLOUD_ANTHROPIC_API_KEY and LOCAL_MODEL)."
fi

if [ ! -d ".venv" ]; then
  PYTHON_BIN="${PYTHON_BIN:-}"
  if [ -z "$PYTHON_BIN" ]; then
    if command -v python3.11 >/dev/null 2>&1; then
      PYTHON_BIN="python3.11"
    else
      PYTHON_BIN="python3"
    fi
  fi
  "$PYTHON_BIN" -m venv .venv
fi

source .venv/bin/activate
python -m pip install --upgrade pip >/dev/null
python -m pip install -r requirements.txt >/dev/null

set -a
source .env
set +a

if [ -z "${LOCAL_MODEL:-}" ] && [ -n "${RELAY_RUNTIME_LOCAL_MODEL:-}" ]; then
  LOCAL_MODEL="$RELAY_RUNTIME_LOCAL_MODEL"
  export LOCAL_MODEL
  echo "Using runtime-selected local model override: ${LOCAL_MODEL}"
fi

echo "Starting Claude Local Relay gateway on ${LISTEN_HOST:-127.0.0.1}:${LISTEN_PORT:-4000}"
exec uvicorn claude_local_relay_gateway:app --host "${LISTEN_HOST:-127.0.0.1}" --port "${LISTEN_PORT:-4000}"
