---
name: claude-local-relay-troubleshooting
description: Diagnoses runtime failures such as ECONNREFUSED, model runtime mismatch, or context-length errors. Use when the relay is running but responses fail or degrade.
---

# Process

1. Check relay health:
   - UNIX: `./relay health | jq`
   - Windows: `.\relay.ps1 health`
2. Check LM Studio models:
   - `curl -s http://127.0.0.1:1234/v1/models | jq`
3. Inspect loaded model state:
   - `lms ps --json | sed -n '/^\\[/,$p' | jq`
4. Inspect gateway logs:
   - `tail -n 200 /tmp/claude-local-relay-gateway.log`
5. If needed, increase context:
   - set `LOCAL_CONTEXT_LENGTH=32768` and run relay again.

# Common fixes

- `ECONNREFUSED`: relay or LM Studio server is not running.
- `torchSafetensors runtime` errors: selected model format is incompatible.
- `tokens to keep > context length`: context is too small.
