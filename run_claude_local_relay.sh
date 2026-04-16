#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v claude >/dev/null 2>&1; then
  echo "Claude CLI was not found. Install Claude Code first."
  exit 1
fi

if [ ! -f ".env" ]; then
  cp .env.example .env
  echo "Created .env from .env.example"
fi

set -a
source .env
set +a

BASE_URL="http://${LISTEN_HOST:-127.0.0.1}:${LISTEN_PORT:-4000}"
HEALTH_URL="${BASE_URL}/healthz"
LMS_BIN=""
STABLE_MODEL_KEY="${STABLE_MODEL_KEY:-google/gemma-3n-e4b}"
STABLE_MODEL_IDENTIFIER="${STABLE_MODEL_IDENTIFIER:-gemma-3n-e4b-it-local}"
FAST_MODEL_KEY="${FAST_MODEL_KEY:-google/gemma-3n-e4b}"
BALANCED_MODEL_KEY="${BALANCED_MODEL_KEY:-google/gemma-4-e4b}"
QUALITY_MODEL_KEY="${QUALITY_MODEL_KEY:-google/gemma-4-31b}"
MODEL_LOAD_LOG="/tmp/claude-local-relay-model-load.log"
RELAY_HEALTH_JSON="/tmp/claude-local-relay-health.json"
RELAY_GATEWAY_LOG="/tmp/claude-local-relay-gateway.log"

LOCAL_CONTEXT_LENGTH="${LOCAL_CONTEXT_LENGTH:-16384}"
MIN_SAFE_CONTEXT_LENGTH="${MIN_SAFE_CONTEXT_LENGTH:-8192}"

RELAY_COMPAT_SYSTEM_PROMPT_DEFAULT="Reply directly in the user's language using plain natural text. Keep responses concise by default unless the user asks for depth. Treat minor user typos as intent-preserving (for example, Vietnamese keyboard slips like 'cao' vs 'chao'). Do not output raw JSON/YAML/XML, internal protocol payloads, or tool schema objects. Use tools only when truly necessary, then return a normal user-facing answer."
RELAY_COMPAT_SYSTEM_PROMPT="${RELAY_COMPAT_SYSTEM_PROMPT:-$RELAY_COMPAT_SYSTEM_PROMPT_DEFAULT}"
RELAY_FAST_BARE_MODE="${RELAY_FAST_BARE_MODE:-true}"
RELAY_EXCLUDE_DYNAMIC_PROMPT="${RELAY_EXCLUDE_DYNAMIC_PROMPT:-true}"
AUTO_SELECT_MODEL="${AUTO_SELECT_MODEL:-true}"
RELAY_MODEL_PROFILE="${RELAY_MODEL_PROFILE:-balanced}"
AUTO_DOWNLOAD_RECOMMENDED_MODEL="${AUTO_DOWNLOAD_RECOMMENDED_MODEL:-false}"
RELAY_LOCAL_EFFORT="${RELAY_LOCAL_EFFORT:-low}"

if ! [[ "$LOCAL_CONTEXT_LENGTH" =~ ^[0-9]+$ ]]; then
  echo "Invalid LOCAL_CONTEXT_LENGTH='${LOCAL_CONTEXT_LENGTH}'. It must be an integer."
  exit 1
fi

if ! [[ "$MIN_SAFE_CONTEXT_LENGTH" =~ ^[0-9]+$ ]]; then
  echo "Invalid MIN_SAFE_CONTEXT_LENGTH='${MIN_SAFE_CONTEXT_LENGTH}'. It must be an integer."
  exit 1
fi

if [ "$LOCAL_CONTEXT_LENGTH" -lt "$MIN_SAFE_CONTEXT_LENGTH" ]; then
  echo "LOCAL_CONTEXT_LENGTH=${LOCAL_CONTEXT_LENGTH} is below MIN_SAFE_CONTEXT_LENGTH=${MIN_SAFE_CONTEXT_LENGTH}. Upgrading automatically."
  LOCAL_CONTEXT_LENGTH="$MIN_SAFE_CONTEXT_LENGTH"
fi

json_get_field() {
  local field="$1"
  python3 -c '
import json
import sys

field = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

value = payload.get(field, "")
if value is None:
    value = ""
print(value)
' "$field"
}

lms_ps_json() {
  "$LMS_BIN" ps --json 2>/dev/null | sed -n '/^\[/,$p'
}

lms_ls_json() {
  "$LMS_BIN" ls --json 2>/dev/null | sed -n '/^\[/,$p'
}

detect_total_ram_gb() {
  local ram_gb=0
  case "$(uname -s)" in
    Darwin)
      local bytes
      bytes="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
      if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ]; then
        ram_gb="$((bytes / 1024 / 1024 / 1024))"
      fi
      ;;
    Linux)
      local kb
      kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
      if [[ "$kb" =~ ^[0-9]+$ ]] && [ "$kb" -gt 0 ]; then
        ram_gb="$((kb / 1024 / 1024))"
      fi
      ;;
    *)
      ram_gb=0
      ;;
  esac
  echo "${ram_gb:-0}"
}

recommended_model_key_from_profile() {
  local profile="$1"
  local ram_gb="$2"

  if [ "$profile" = "stable" ] || [ "$profile" = "auto" ]; then
    echo "$STABLE_MODEL_KEY"
    return
  fi

  if [ "$profile" = "fast" ]; then
    echo "$FAST_MODEL_KEY"
    return
  fi

  if [ "$profile" = "balanced" ]; then
    if [ "$ram_gb" -ge 24 ]; then
      echo "$BALANCED_MODEL_KEY"
    else
      echo "$FAST_MODEL_KEY"
    fi
    return
  fi

  if [ "$profile" = "quality" ]; then
    if [ "$ram_gb" -ge 48 ]; then
      echo "$QUALITY_MODEL_KEY"
    elif [ "$ram_gb" -ge 24 ]; then
      echo "$BALANCED_MODEL_KEY"
    else
      echo "$FAST_MODEL_KEY"
    fi
    return
  fi

  echo "$STABLE_MODEL_KEY"
}

pick_installed_model_key() {
  local preferred_key="$1"

  local selected=""
  selected="$(lms_ls_json | python3 -c '
import json
import sys

preferred = sys.argv[1].strip()

try:
    payload = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

keys = []
for item in payload if isinstance(payload, list) else []:
    key = (item.get("modelKey") or "").strip()
    if key:
        keys.append(key)

if not keys:
    print("")
    raise SystemExit(0)

# Prefer explicitly requested/recommended key if already installed.
if preferred and preferred in keys:
    print(preferred)
    raise SystemExit(0)

# If preferred is from a Gemma family, try matching within family first.
pref_lower = preferred.lower()
if "gemma-4" in pref_lower:
    gemma4 = [k for k in keys if "gemma-4" in k.lower()]
    if gemma4:
        for hint in ("31b", "27b", "12b", "e4b"):
            for k in gemma4:
                if hint in k.lower():
                    print(k)
                    raise SystemExit(0)
        print(gemma4[0])
        raise SystemExit(0)

if "gemma-3n" in pref_lower:
    for k in keys:
        if "gemma-3n-e4b" in k.lower():
            print(k)
            raise SystemExit(0)

# Otherwise pick a lightweight Gemma if present.
for k in keys:
    if "gemma-3n-e4b" in k.lower():
        print(k)
        raise SystemExit(0)

for k in keys:
    if "gemma" in k.lower():
        print(k)
        raise SystemExit(0)

print(keys[0])
' "$preferred_key")"

  echo "$selected"
}

ensure_lms_cli() {
  if command -v lms >/dev/null 2>&1; then
    LMS_BIN="$(command -v lms)"
    return 0
  fi

  if [ -x "$HOME/.lmstudio/bin/lms" ]; then
    LMS_BIN="$HOME/.lmstudio/bin/lms"
    export PATH="$HOME/.lmstudio/bin:$PATH"
    return 0
  fi

  echo "LM Studio CLI (lms) was not found. Installing..."
  curl -fsSL https://lmstudio.ai/install.sh | bash
  export PATH="$HOME/.lmstudio/bin:$PATH"
  if command -v lms >/dev/null 2>&1; then
    LMS_BIN="$(command -v lms)"
    return 0
  fi

  echo "Automatic LM Studio CLI installation failed."
  echo "Install manually: curl -fsSL https://lmstudio.ai/install.sh | bash"
  exit 1
}

ensure_lm_server() {
  if ! "$LMS_BIN" daemon status --json --quiet 2>/dev/null | grep -q '"status":"running"'; then
    echo "Starting LM Studio daemon..."
    "$LMS_BIN" daemon up >/dev/null
  fi

  if ! "$LMS_BIN" server status --json --quiet 2>/dev/null | grep -q '"running":true'; then
    echo "Starting LM Studio local server..."
    "$LMS_BIN" server start >/dev/null
  fi
}

is_model_loaded() {
  local identifier="$1"
  lms_ps_json | grep -q "\"identifier\":\"${identifier}\""
}

loaded_context_length() {
  local identifier="$1"
  lms_ps_json | python3 -c '
import json
import sys

identifier = sys.argv[1]
try:
    payload = json.load(sys.stdin)
except Exception:
    print(0)
    raise SystemExit(0)

if not isinstance(payload, list):
    print(0)
    raise SystemExit(0)

for item in payload:
    if item.get("identifier") == identifier:
        print(int(item.get("contextLength") or 0))
        raise SystemExit(0)

print(0)
' "$identifier"
}

try_load_model() {
  local model_key="$1"
  local identifier="$2"
  if "$LMS_BIN" load "$model_key" \
      --identifier "$identifier" \
      --context-length "$LOCAL_CONTEXT_LENGTH" \
      -y >"$MODEL_LOAD_LOG" 2>&1; then
    return 0
  fi
  return 1
}

ensure_preferred_model() {
  local preferred_identifier="${LOCAL_MODEL:-}"
  local preferred_model_key=""

  if [ "$AUTO_SELECT_MODEL" = "true" ] && [ -z "$preferred_identifier" ]; then
    local ram_gb
    ram_gb="$(detect_total_ram_gb)"
    local recommended
    recommended="$(recommended_model_key_from_profile "$RELAY_MODEL_PROFILE" "$ram_gb")"
    local installed_choice
    installed_choice="$(pick_installed_model_key "$recommended")"

    if [ -n "$installed_choice" ]; then
      preferred_model_key="$installed_choice"
    else
      if [ "$AUTO_DOWNLOAD_RECOMMENDED_MODEL" = "true" ]; then
        preferred_model_key="$recommended"
      else
        preferred_model_key="$STABLE_MODEL_KEY"
      fi
    fi

    if [ -z "$preferred_model_key" ]; then
      preferred_model_key="$STABLE_MODEL_KEY"
    fi

    if [ "$preferred_model_key" = "$STABLE_MODEL_KEY" ]; then
      preferred_identifier="$STABLE_MODEL_IDENTIFIER"
    else
      preferred_identifier="$preferred_model_key"
    fi

    echo "Auto-selected model profile: profile=${RELAY_MODEL_PROFILE}, ram=${ram_gb}GB, key=${preferred_model_key}, identifier=${preferred_identifier}"
  fi

  if [ -z "$preferred_identifier" ]; then
    preferred_identifier="$STABLE_MODEL_IDENTIFIER"
  fi

  # Always publish the effective runtime model so gateway startup can bind
  # LOCAL_MODEL even when the model was already loaded before this run.
  export RELAY_RUNTIME_LOCAL_MODEL="$preferred_identifier"

  if is_model_loaded "$preferred_identifier"; then
    local current_ctx
    current_ctx="$(loaded_context_length "$preferred_identifier")"
    if [ "$current_ctx" -ge "$LOCAL_CONTEXT_LENGTH" ]; then
      return 0
    fi
    echo "Model '${preferred_identifier}' is loaded with context ${current_ctx}. Reloading with ${LOCAL_CONTEXT_LENGTH}."
    "$LMS_BIN" unload "$preferred_identifier" >/dev/null 2>&1 || true
  fi

  echo "Loading preferred local model: ${preferred_identifier}"
  local preferred_loaded=false

  if [ "$preferred_identifier" = "$STABLE_MODEL_IDENTIFIER" ]; then
    if try_load_model "$STABLE_MODEL_KEY" "$STABLE_MODEL_IDENTIFIER"; then
      preferred_loaded=true
    fi
  else
    local load_key="$preferred_identifier"
    if [ -n "$preferred_model_key" ]; then
      load_key="$preferred_model_key"
    fi
    if try_load_model "$load_key" "$preferred_identifier"; then
      preferred_loaded=true
    fi
  fi

  if [ "$preferred_loaded" = true ]; then
    export RELAY_RUNTIME_LOCAL_MODEL="$preferred_identifier"
    return 0
  fi

  echo "Preferred model '${preferred_identifier}' failed to load."
  echo "Falling back to stable model '${STABLE_MODEL_KEY}'..."

  if ! "$LMS_BIN" ls --json 2>/dev/null | grep -q "\"modelKey\":\"${STABLE_MODEL_KEY}\""; then
    echo "Downloading fallback model (first run may take a while): ${STABLE_MODEL_KEY}"
    if ! "$LMS_BIN" get "$STABLE_MODEL_KEY" --yes --mlx >/dev/null 2>&1; then
      "$LMS_BIN" get "$STABLE_MODEL_KEY" --yes --gguf >/dev/null 2>&1
    fi
  fi

  if ! try_load_model "$STABLE_MODEL_KEY" "$STABLE_MODEL_IDENTIFIER"; then
    echo "Failed to load fallback model."
    echo "Last model load log:"
    tail -n 120 "$MODEL_LOAD_LOG" || true
    exit 1
  fi

  ./set_relay_model.sh "$STABLE_MODEL_IDENTIFIER" >/dev/null
  export LOCAL_MODEL="$STABLE_MODEL_IDENTIFIER"
  export RELAY_RUNTIME_LOCAL_MODEL="$STABLE_MODEL_IDENTIFIER"
  echo "Updated LOCAL_MODEL to ${LOCAL_MODEL}"
}

start_gateway_background() {
  nohup "$SCRIPT_DIR/start_relay_gateway.sh" >"$RELAY_GATEWAY_LOG" 2>&1 &
}

wait_gateway_up() {
  for _ in $(seq 1 30); do
    if curl -fsS "$HEALTH_URL" >"$RELAY_HEALTH_JSON" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

gateway_model_override() {
  if [ ! -f "$RELAY_HEALTH_JSON" ]; then
    echo ""
    return
  fi
  cat "$RELAY_HEALTH_JSON" | json_get_field "local_model_override"
}

ensure_gateway() {
  local expected_model_override="${LOCAL_MODEL:-${RELAY_RUNTIME_LOCAL_MODEL:-}}"
  if curl -fsS "$HEALTH_URL" >/dev/null 2>&1; then
    curl -fsS "$HEALTH_URL" >"$RELAY_HEALTH_JSON" 2>/dev/null || true
    local override
    override="$(gateway_model_override)"
    if [ -n "$expected_model_override" ] && [ "$override" != "$expected_model_override" ]; then
      echo "Gateway model override is '${override}', expected '${expected_model_override}'. Restarting gateway."
      pkill -f 'uvicorn claude_local_relay_gateway:app' >/dev/null 2>&1 || true
    else
      return 0
    fi
  fi

  echo "Gateway not reachable at ${BASE_URL}. Starting in background..."
  start_gateway_background

  if wait_gateway_up; then
    echo "Gateway is ready at ${BASE_URL}"
    return 0
  fi

  echo "Failed to start gateway at ${BASE_URL}."
  echo "Last logs from ${RELAY_GATEWAY_LOG}:"
  tail -n 80 "$RELAY_GATEWAY_LOG" || true
  exit 1
}

ensure_lms_cli
ensure_lm_server
ensure_preferred_model
ensure_gateway

export ANTHROPIC_BASE_URL="$BASE_URL"
unset ANTHROPIC_AUTH_TOKEN
export ANTHROPIC_API_KEY="${PROXY_CLIENT_TOKEN:-claude-local-relay}"

echo "Claude is now pointed to Claude Local Relay at ${ANTHROPIC_BASE_URL}"

cloud_enabled=false
if [ "${ENABLE_CLOUD_ANTHROPIC:-true}" = "true" ] && [ -n "${CLOUD_ANTHROPIC_API_KEY:-}" ]; then
  cloud_enabled=true
fi

has_system_prompt_arg=false
has_bare_arg=false
has_exclude_dynamic_arg=false
has_effort_arg=false
for arg in "$@"; do
  if [ "$arg" = "--append-system-prompt" ] || [ "$arg" = "--system-prompt" ]; then
    has_system_prompt_arg=true
  fi
  if [ "$arg" = "--bare" ]; then
    has_bare_arg=true
  fi
  if [ "$arg" = "--exclude-dynamic-system-prompt-sections" ]; then
    has_exclude_dynamic_arg=true
  fi
  if [ "$arg" = "--effort" ]; then
    has_effort_arg=true
  fi
done

CLAUDE_ARGS=("$@")
if [ "$cloud_enabled" = false ] && [ "$has_system_prompt_arg" = false ]; then
  echo "Local-only mode detected: injecting compatibility prompt."
  CLAUDE_ARGS+=(--append-system-prompt "$RELAY_COMPAT_SYSTEM_PROMPT")
fi

if [ "$cloud_enabled" = false ] && [ "$RELAY_FAST_BARE_MODE" = "true" ] && [ "$has_bare_arg" = false ]; then
  echo "Local-only mode: enabling --bare for lower prompt overhead."
  CLAUDE_ARGS+=(--bare)
fi

if [ "$cloud_enabled" = false ] && [ "$RELAY_EXCLUDE_DYNAMIC_PROMPT" = "true" ] && [ "$has_exclude_dynamic_arg" = false ]; then
  CLAUDE_ARGS+=(--exclude-dynamic-system-prompt-sections)
fi

if [ "$cloud_enabled" = false ] && [ -n "$RELAY_LOCAL_EFFORT" ] && [ "$has_effort_arg" = false ]; then
  CLAUDE_ARGS+=(--effort "$RELAY_LOCAL_EFFORT")
fi

exec claude "${CLAUDE_ARGS[@]}"
