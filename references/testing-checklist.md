# Testing Checklist

## Syntax and compile

1. `bash -n run_claude_local_relay.sh`
2. `bash -n start_relay_gateway.sh`
3. `bash -n setup_unix.sh`
4. `python3 -m py_compile claude_local_relay_gateway.py`

## Runtime

1. `./relay run --version`
2. `./relay health | jq`
3. `curl -s http://127.0.0.1:1234/v1/models | jq`

## Runtime (Windows)

1. `.\relay.ps1 run --version`
2. `.\relay.ps1 health`

## Regression

1. Local-only mode works.
2. Cloud-first fallback still works with a cloud key.
3. Context-length reload behavior still works.
