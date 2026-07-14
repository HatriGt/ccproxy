# Codex configuration (desktop + CLI)

ccproxy is the **same public OpenAI-compatible endpoint** for:

| Client | Protocol | Path |
|--------|----------|------|
| **Cursor** | Chat Completions (+ shim for tool blocks) | `POST /v1/chat/completions` |
| **Codex** (desktop / CLI) | Responses API | `POST /v1/responses` |

Both use `CURSOR_BASE_URL` (e.g. `https://cliproxy.yourdomain.com/v1`) and the same Claude OAuth accounts.

## One-time desktop setup

```bash
ccproxy codex config          # print ready-to-paste snippet
```

Put that into `~/.codex/config.toml` (or merge provider block), then **fully quit and reopen** Codex.

Essential keys:

```toml
model = "ak-claude-opus-4.8"
model_provider = "ccproxy"

[model_providers.ccproxy]
name = "ccproxy"
base_url = "https://cliproxy.yourdomain.com/v1"   # same as `ccu`
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
experimental_bearer_token = "dummy"               # your CLIPROXY_API_KEY
```

CLI profile (optional, non-default):

```bash
codex -p ccproxy
# ~/.codex/ccproxy.config.toml
```

Escape hatch back to ChatGPT GPT models:

```bash
codex -p chatgpt
```

## Models

Use **aliases** from `ccproxy models` (plain Anthropic ids like `claude-opus-4-8` may 502):

- `ak-claude-opus-4.8`, `ak-claude-opus-4.8-low` / `-medium` / `-high`
- `ak-claude-sonnet-4.6`, `ak-claude-haiku-4.5`, …

## Helper model (OpenAI side-calls)

Codex Desktop often also calls OpenAI helper IDs (`gpt-5.4-mini`, `o4-mini`, …).
Those are remapped server-side to a low Claude model:

```bash
ccproxy codex helper-model                         # show mapping
ccproxy codex helper-model ak-claude-haiku-4.5     # default (cheap/fast)
ccproxy codex helper-model ak-claude-sonnet-4.6    # optional
ccproxy codex helpers                              # list OpenAI IDs remapped
```

Main agent model stays whatever you pick in Codex (`ak-claude-opus-4.8`, …).

## Checklist

1. `ccproxy health` — endpoint up  
2. `ccproxy codex helper-model` — helpers mapped (no 502 on `gpt-5.4-mini`)  
3. Codex model picker → `ak-claude-opus-4.8` (or Sonnet)  
4. New chat → short “Hi” should return 200 on `/v1/responses` (no flood of 502s)

## Related

- [cursor-configuration.md](./cursor-configuration.md) — Cursor IDE settings  
- [user-guide.md](./user-guide.md) — daily CLI (`ccproxy codex …`)  
- [claude-oauth.md](./claude-oauth.md) — accounts / pause / re-login  
