---
name: claude-local-relay-security
description: Applies security hardening for Claude Local Relay (secret handling, local-only guarantees, and safe upstream forwarding). Use when reviewing or hardening production usage.
---

# Process

1. Ensure no real secrets are committed.
2. Verify logs never print API keys.
3. Confirm header forwarding is minimal and intentional.
4. Confirm local-only mode has cloud providers disabled.

# Verification

- `cloud_anthropic_enabled` is `false` in local-only mode.
- Relay responses still work via local models.
