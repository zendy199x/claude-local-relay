# Agent Playbook: Claude Local Relay

This document defines how coding agents should work in this repository.

## Mission

- Keep the cloud-to-local relay stable and predictable.
- Keep the default UX simple: one command for daily use.
- Protect user data and avoid secret leaks.

## Core files

- `claude_local_relay_gateway.py`: FastAPI gateway and fallback logic.
- `run_claude_local_relay.sh`: UNIX runtime orchestration.
- `start_relay_gateway.sh`: Starts gateway on UNIX.
- `setup_unix.sh`: Setup helper for macOS and Linux.
- `set_relay_model.sh`: Updates `LOCAL_MODEL` on UNIX.
- `relay`: Public CLI entrypoint on UNIX.
- `relay.ps1`: Public CLI entrypoint on Windows.
- `run_claude_local_relay.ps1`: Runtime orchestration on Windows.
- `setup_windows.ps1`: Setup helper on Windows.

## Change rules

1. Do not break existing `.env` keys unless migration is provided.
2. Do not hard-code API keys or secrets.
3. Update `README.md` for any user-visible behavior change.
4. Keep shell scripts syntax-clean (`bash -n`).
5. Keep logs actionable and concise.

## Validation before completion

1. `bash -n run_claude_local_relay.sh`
2. `bash -n start_relay_gateway.sh`
3. `bash -n setup_unix.sh`
4. `python3 -m py_compile claude_local_relay_gateway.py`
5. `./relay run --version`
6. `curl -s http://127.0.0.1:4000/healthz | jq`

## Commit convention

- `feat:` new feature
- `fix:` bug fix
- `docs:` documentation update
- `chore:` maintenance change
