---
description: Run relay validation checks and report outcomes.
---

Run and report:

```bash
bash -n run_claude_local_relay.sh
bash -n start_relay_gateway.sh
python3 -m py_compile claude_local_relay_gateway.py
./relay run --version
curl -s http://127.0.0.1:4000/healthz | jq
```

Include:

1. Pass/fail per command
2. Root cause for failures
3. Remaining risks
