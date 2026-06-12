# Cursor IDE configuration

## Required settings

Open **Cursor → Settings → Models** (or **Cursor Settings → Models**).

| Setting | Value |
|---------|--------|
| **OpenAI API Key** | Value of `CLIPROXY_API_KEY` from `.env` (default: `dummy`) |
| **Override OpenAI Base URL** | `CURSOR_BASE_URL` e.g. `https://cliproxy.yourdomain.com/v1` |
| **Anthropic API Key** | **Disabled / OFF** |

## After changing settings

1. `Cmd+Shift+P` (macOS) or `Ctrl+Shift+P` (Windows/Linux)
2. **Developer: Reload Window**

## Verify from terminal

```bash
source scripts/load-env.sh
curl -s "$CURSOR_BASE_URL/models" -H "Authorization: Bearer $CLIPROXY_API_KEY" | head -c 500
```

Should list models including `ak-claude-*` aliases.

## Common mistakes

| Problem | Fix |
|---------|-----|
| Agent mode fails, chat works | Base URL must be **public HTTPS**, not `http://127.0.0.1:8320` |
| `401` / invalid key | `CLIPROXY_API_KEY` must match `api-keys` in `config/config.yaml` |
| `auth_unavailable` in chat | Claude OAuth expired — [claude-oauth.md](./claude-oauth.md) |
| Tool/format errors without shim | Ensure traffic hits **cursor-shim:8320**, not raw cli-proxy-api:8318 |

## Model selection in Cursor

Use OpenAI-compatible model names exposed by the proxy:

- `ak-claude-sonnet-4.6`
- `ak-claude-opus-4.7`
- etc. (see `oauth-model-alias` in `config/config.yaml`)
