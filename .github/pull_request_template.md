## Summary

-

## Root Problem

-

## Implementation

-

## Validation

```bash
bash -n relay
bash -n run_claude_local_relay.sh
bash -n start_relay_gateway.sh
bash -n setup_unix.sh
python3 -m py_compile claude_local_relay_gateway.py
./relay run --version
curl -s http://127.0.0.1:4000/healthz | jq
```

## Remaining Risks

-
