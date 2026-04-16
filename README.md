# Claude Local Relay

Run Claude Code with a smart local fallback, so your workflow keeps moving when cloud quota, billing, or rate limits get in the way.

Claude Local Relay routes requests through a local gateway:

- cloud-first when cloud is available
- local model fallback when cloud fails
- local-only mode when privacy is required

---

## Why This Exists

When you are in the middle of coding, quota failures are expensive.

Claude Local Relay gives you a resilient runtime path:

- keep using Claude Code UX
- avoid dead stops from cloud outages or quota limits
- switch to local inference automatically

---

## Highlights

- One-command onboarding for each platform
- Smart model selection based on machine profile
- Automatic model load + context-length safety checks
- Cloud-first routing with local fallback policy
- Local-only mode support
- Smart context mode for long chats on local models
- Cross-platform entrypoints:
  - macOS / Linux: `./relay ...`
  - Windows: `.\relay.ps1 ...`

---

## One-Command Setup (From Scratch)

### macOS / Linux

```bash
./relay bootstrap
```

### Windows (PowerShell)

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\relay.ps1 bootstrap
```

`bootstrap` performs end-to-end setup:

1. installs platform prerequisites
2. prepares Python virtual environment
3. installs runtime dependencies
4. installs LM Studio tooling (best effort)
5. installs Claude CLI (best effort)
6. starts LM Studio daemon/server
7. auto-selects a suitable model profile
8. starts relay gateway
9. launches Claude through the relay

---

## Daily Usage

### macOS / Linux

```bash
./relay run
```

### Windows

```powershell
.\relay.ps1 run
```

---

## CLI Commands

### macOS / Linux

```bash
./relay bootstrap [claude args...]
./relay run [claude args...]
./relay setup
./relay gateway
./relay set-model <model-id>
./relay health
./relay doctor
./relay help
```

### Windows

```powershell
.\relay.ps1 bootstrap [claude args...]
.\relay.ps1 run [claude args...]
.\relay.ps1 setup
.\relay.ps1 gateway
.\relay.ps1 set-model <model-id>
.\relay.ps1 health
.\relay.ps1 doctor
.\relay.ps1 help
```

---

## Smart Model Selection

If `LOCAL_MODEL` is already set, Relay uses it.

If `LOCAL_MODEL` is empty and `AUTO_SELECT_MODEL=true`, Relay will:

1. detect machine memory profile
2. inspect installed LM Studio models
3. prefer stronger installed Gemma variants on larger machines
4. fallback to stable default (`google/gemma-3n-e4b`) when uncertain

This behavior is controlled by:

- `AUTO_SELECT_MODEL=true|false`
- `RELAY_MODEL_PROFILE=auto|stable|fast|balanced|quality`
- `FAST_MODEL_KEY`
- `BALANCED_MODEL_KEY`
- `QUALITY_MODEL_KEY`
- `AUTO_DOWNLOAD_RECOMMENDED_MODEL=true|false` (default: `false`)
- `RELAY_LOCAL_EFFORT=low|medium|high`

---

## Configuration

Start with:

```bash
cp .env.example .env
```

Key variables:

- `LOCAL_MODEL`
- `AUTO_SELECT_MODEL`
- `RELAY_MODEL_PROFILE`
- `AUTO_DOWNLOAD_RECOMMENDED_MODEL`
- `LOCAL_CONTEXT_LENGTH`
- `MIN_SAFE_CONTEXT_LENGTH`
- `LOCAL_MAX_TOKENS_CAP`
- `ENABLE_CLOUD_ANTHROPIC`
- `CLOUD_ANTHROPIC_API_KEY`
- `ENABLE_CLOUD_OPENAI`
- `SMART_CONTEXT_ENABLED`
- `SMART_CONTEXT_STORE_PATH`
- `SMART_CONTEXT_KEEP_RECENT_MESSAGES`
- `SMART_CONTEXT_MAX_SUMMARY_CHARS`
- `SMART_CONTEXT_MAX_TURN_CHARS`
- `SMART_CONTEXT_INJECT_SUMMARY`

### Smart context mode

When enabled, Relay keeps a lightweight per-session summary and compacts older turns while preserving recent messages.

This helps local models handle longer sessions by reducing context window pressure while retaining key prior context.

```env
SMART_CONTEXT_ENABLED=true
SMART_CONTEXT_STORE_PATH=/tmp/claude-local-relay-context.json
SMART_CONTEXT_KEEP_RECENT_MESSAGES=12
SMART_CONTEXT_MAX_SUMMARY_CHARS=6000
SMART_CONTEXT_MAX_TURN_CHARS=1200
SMART_CONTEXT_INJECT_SUMMARY=true
```

### Modes

#### Local-only mode

```env
ENABLE_CLOUD_ANTHROPIC=false
ENABLE_CLOUD_OPENAI=false
```

#### Cloud-first + local fallback

```env
ENABLE_CLOUD_ANTHROPIC=true
CLOUD_ANTHROPIC_API_KEY=your_key_here
```

---

## Architecture

```text
Claude CLI
   -> Claude Local Relay Gateway (FastAPI, :4000)
      -> Cloud upstream (optional, first attempt)
      -> LM Studio local server (:1234, fallback)
```

Main gateway file:

- `claude_local_relay_gateway.py`

---

## Script Map (No Dead Scripts)

All scripts in this repo are active and used:

- `relay` (UNIX CLI entrypoint)
- `relay.ps1` (Windows CLI entrypoint)
- `setup_unix.sh` (UNIX setup)
- `setup_windows.ps1` (Windows setup)
- `run_claude_local_relay.sh` (UNIX runtime)
- `run_claude_local_relay.ps1` (Windows runtime)
- `start_relay_gateway.sh` (UNIX gateway launcher)
- `start_relay_gateway.ps1` (Windows gateway launcher)
- `set_relay_model.sh` / `set_relay_model.ps1` (model override helpers)

---

## Health and Validation

### Health check

```bash
./relay health | jq
```

Expected:

- `"ok": true`
- `"local_server_reachable": true`

### Validation (UNIX)

```bash
bash -n relay
bash -n run_claude_local_relay.sh
bash -n start_relay_gateway.sh
bash -n setup_unix.sh
bash -n set_relay_model.sh
python3 -m py_compile claude_local_relay_gateway.py
```

---

## Troubleshooting

### `ECONNREFUSED`

Relay or LM Studio server is not running.

Run:

```bash
./relay run
```

### `No LM Runtime found for model format 'torchSafetensors'`

The selected model format is incompatible with local runtime.

Use a runtime-compatible model in LM Studio, then set it:

```bash
./relay set-model <compatible-model-id>
```

### `There's an issue with the selected model (claude-sonnet-4-6)`

This happens when the client-selected Claude model ID is not recognized by your local runtime model list.

Relay now injects Claude-compatible model aliases into `/v1/models`, and maps runtime requests to your selected local model.

If you still see this after upgrading:

```bash
pkill -f 'uvicorn claude_local_relay_gateway:app' || true
./relay run
```

### `tokens to keep ... greater than context length`

Increase context safety values in `.env`:

```env
LOCAL_CONTEXT_LENGTH=16384
MIN_SAFE_CONTEXT_LENGTH=8192
```

### Local responses are too slow

Use the fast profile defaults:

```env
RELAY_MODEL_PROFILE=fast
LOCAL_MAX_TOKENS_CAP=256
RELAY_LOCAL_EFFORT=low
```

---

## Security Notes

- Do not commit real `.env` secrets.
- Relay strips unsupported local fields before local inference.
- In local-only mode, cloud providers can be fully disabled.

---

## Contributing

1. Keep changes focused.
2. Keep docs aligned with behavior.
3. Run validation checks before opening PR.
4. Use conventional commits (`feat`, `fix`, `docs`, `chore`).

---

## If You Find This Useful

Open an issue with your platform/model profile and results.  
That helps improve model auto-selection heuristics for everyone.

---

## License

This project is licensed under the [MIT License](./LICENSE).
