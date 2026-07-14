# Architecture

## Production (VPS / Docker)

```
┌────────────┐
│ Cursor IDE │──┐
└────────────┘  │   HTTPS        ┌──────────────────┐     HTTP      ┌──────────────┐
                ├───────────────►│ Traefik (Dokploy)│──────────────►│ gateway shim │
┌────────────┐  │  :443 /v1/*    │  your domain     │  :8320 host  │  (Node.js)   │
│ Codex      │──┘                └──────────────────┘               └──────┬───────┘
│ desktop/CLI│                                                              │
└────────────┘                                                       Docker network
                                                                            │
                                                                     ┌──────▼───────┐
                                                                     │ cli-proxy-api│
                                                                     │ (Go / OAuth) │
                                                                     └──────┬───────┘
                                                                            │
                                                                     ┌──────▼───────┐
                                                                     │  Claude API  │
                                                                     └──────────────┘
```

**Same base URL** (`CURSOR_BASE_URL`, e.g. `https://cliproxy.yourdomain.com/v1`) for both clients:

| Client | Path | Shim behavior |
|--------|------|----------------|
| Cursor | `POST /v1/chat/completions` | Convert Anthropic-style tool blocks → OpenAI tools |
| Codex | `POST /v1/responses` | Transparent proxy to CLIProxyAPI |
| Both | `GET /v1/models` | Passthrough (aliases + helper OpenAI IDs) |

## Components

| Component | Image / binary | Port | Role |
|-----------|----------------|------|------|
| **gateway shim** (`cursor-shim`) | `ccproxy-cursor-shim:local` | 8320 (published) | Cursor tool conversion + Codex Responses passthrough |
| **cli-proxy-api** | `ccproxy-cli-proxy-api:local` (CLIProxyAPI) | 8318 (internal) | Claude OAuth, aliases, chat + responses |
| **usage-tracker** | sidecar | — | Drains usage queue → SQLite |
| **Traefik** | Dokploy-managed | 443 | TLS → `172.17.0.1:8320` |

## Why the shim exists

1. **Cursor Agent** sends Anthropic-native blocks (`tool_use`, `tool_result`) on OpenAI `/v1/chat/completions`. CLIProxyAPI’s OpenAI translator rejects those unless normalized.
2. **Codex** needs `/v1/responses` on the **same** public hostname. The shim already pass-throughs non-chat paths to CLIProxyAPI (no second Traefik service).

Source: `packages/cursor-shim/shim.mjs`

## Data persistence

| Data | Location |
|------|----------|
| Claude OAuth tokens | Volume → `/data/auth/claude-*.json` |
| Model aliases | Volume → `/data/models/aliases.yaml` |
| Codex helper mapping state | Volume → `/data/models/codex-helper.yaml` |
| Usage SQLite | Volume → `/data/usage` |
| Config template | `config/config.yaml.template` (rendered at start) |

## Model aliases

Live aliases: `/data/models/aliases.yaml`, seeded from `config/model-aliases.default.yaml`.

```bash
ccproxy models
ccproxy add-model <alias> <upstream-name>
ccproxy remove-model <alias>
ccproxy codex helper-model [alias]   # remap gpt-5.4-mini etc. → low Claude
```

Typical names: `ak-claude-sonnet-4.6`, `ak-claude-opus-4.8`, effort variants `…-low` / `…-medium` / `…-high`.

## Round-robin / pause

Multiple Claude OAuth accounts are load-balanced. Temporarily exclude one near plan limits:

```bash
ccproxy pause <email-or-substring>
ccproxy resume <email-or-substring>
ccproxy accounts
```
