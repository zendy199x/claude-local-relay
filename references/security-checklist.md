# Security Checklist

1. Do not commit real `.env` secrets.
2. Do not print API keys in logs.
3. Do not forward auth headers to unintended upstreams.
4. In local-only mode, cloud providers must be disabled.
5. Error messages should avoid sensitive internals.
