---
name: claude-local-relay-setup
description: Sets up Claude Local Relay end-to-end on macOS, Linux, or Windows. Use when preparing a new machine or repairing a broken local environment.
---

# Overview

This skill handles first-time setup and baseline verification.

# Process

1. Run setup:
   - macOS/Linux: `./setup_unix.sh --install-lmstudio --install-claude`
   - Windows: `.\setup_windows.ps1 -InstallLMStudio -InstallClaude`
2. Ensure `.env` exists and model settings are valid.
3. Start via:
   - macOS/Linux: `./relay bootstrap`
   - Windows: `.\relay.ps1 bootstrap`
4. Validate with `healthz`.

# Verification

```bash
./relay run --version
curl -s http://127.0.0.1:4000/healthz | jq
```
