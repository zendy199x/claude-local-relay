---
name: claude-local-relay-operations
description: Covers daily operations for Claude Local Relay (run, model switch, health checks, logs). Use when operating the relay day to day.
---

# Process

1. Start runtime:
   - UNIX: `./relay run`
   - Windows: `.\relay.ps1 run`
2. Switch model:
   - UNIX: `./relay set-model <model-id>`
   - Windows: `.\relay.ps1 set-model <model-id>`
3. Check health:
   - UNIX: `./relay health | jq`
   - Windows: `.\relay.ps1 health`
4. Check logs:
   - `tail -n 120 /tmp/claude-local-relay-gateway.log`

# Verification

- `local_server_reachable` is `true`
- `local_model_override` matches desired model
