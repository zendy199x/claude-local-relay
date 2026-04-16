# GitHub Copilot Instructions

You are assisting on **Claude Local Relay**, a local-first gateway that keeps Claude workflows running when cloud quota or rate-limit issues occur.

## Intent

- Keep `./relay` as the public command entrypoint.
- Preserve cloud-first + local-fallback behavior.
- Preserve local-only mode for privacy-sensitive tasks.

## Rules

1. Prefer small, focused changes.
2. Keep shell scripts Bash-safe and readable.
3. Never print or hard-code secrets.
4. Update README for user-visible behavior changes.
5. Keep `.env` keys backward-compatible where possible.

## Required checks before completion

```bash
bash -n relay
bash -n run_claude_local_relay.sh
bash -n start_relay_gateway.sh
bash -n setup_unix.sh
python3 -m py_compile claude_local_relay_gateway.py
./relay run --version
curl -s http://127.0.0.1:4000/healthz | jq
```

## Review focus

- fallback correctness
- model load/reload flow
- context-length handling
- troubleshooting clarity
