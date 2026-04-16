# CLAUDE.md - Claude Local Relay

## Project

Repository: `claude-local-relay`

Goal: provide a simple local-first relay so Claude can continue working when cloud quota/rate-limit issues happen.

## Priorities

1. Reliability in local-only mode.
2. Smooth one-command user experience.
3. Clear troubleshooting and recovery flow.

## Do

- Keep scripts idempotent when possible.
- Prefer targeted edits in orchestration scripts.
- Keep README and setup instructions aligned with real behavior.

## Do not

- Expose secrets in logs.
- Remove env keys without migration notes.
- Change default ports without a clear reason.

## Quick checks

```bash
bash -n relay
bash -n run_claude_local_relay.sh
bash -n setup_unix.sh
python3 -m py_compile claude_local_relay_gateway.py
./relay run --version
curl -s http://127.0.0.1:4000/healthz | jq
```
