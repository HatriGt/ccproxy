# Architecture

## Production (VPS / Docker)

```
┌─────────┐     HTTPS      ┌──────────────────┐     HTTP      ┌──────────────┐
│ Cursor  │ ──────────────►│ Traefik (Dokploy)│ ────────────►│ cursor-shim  │
│   IDE   │  :443 /v1/*    │  your domain     │  :8320 host  │  (Node.js)   │
└─────────┘                └──────────────────┘               └──────┬───────┘
                                                                     │
                                                              Docker network
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

## Components

| Component | Image / binary | Port | Role |
|-----------|----------------|------|------|
| **cursor-shim** | `ccproxy-cursor-shim:local` | 8320 (published on host) | Converts Cursor Agent’s Anthropic-style tool blocks to OpenAI format for CLIProxyAPI |
| **cli-proxy-api** | `ccproxy-cli-proxy-api:local` (from [eceasy/cli-proxy-api](https://hub.docker.com/r/eceasy/cli-proxy-api)) | 8318 (internal) | Claude OAuth, model aliases, `/v1/chat/completions` |
| **Traefik** | Dokploy-managed | 443 | TLS + route to `172.17.0.1:8320` |

## Why the shim exists

Cursor Agent sends **Anthropic-native** message blocks (`tool_use`, `tool_result`) to OpenAI-compatible `/v1/chat/completions`. CLIProxyAPI’s OpenAI translator rejects those unless normalized. The shim fixes this without patching upstream.

Source: `packages/cursor-shim/shim.mjs`

## Data persistence

| Data | Location |
|------|----------|
| Claude OAuth tokens | Docker volume `ccproxy_cliproxy-auth` → `/data/auth` in container |
| Config | `config/config.yaml` (bind-mounted read-only) |

## Legacy Mac relay (deprecated)

Previously: Mac shim → SSH reverse tunnel → VPS socat → Traefik.

`deploy-to-vps.sh` stops `cliproxy-relay-bridge.service` and points Traefik directly at Docker port `8320`.

## Model aliases

Live aliases live in the `cliproxy-models` volume (`/data/models/aliases.yaml`),
seeded from `config/model-aliases.default.yaml` and injected under
`oauth-model-alias.claude` at container start. Manage with:

```bash
ccproxy models
ccproxy add-model <alias> <upstream-name>
ccproxy remove-model <alias>
```

Cursor typically uses:

- `ak-claude-sonnet-4.6` (default health-check model)
- `ak-claude-opus-4.8`, `ak-claude-opus-4.7`, etc.
- Effort variants: `ak-claude-opus-4.8-low` / `-medium` / `-high`

Mapped to Anthropic model IDs via CLIProxyAPI. Effort suffixes match wildcard
`payload.override` rules in `config/config.yaml.template` (`ak-claude-*-low` →
`output_config.effort: low`, etc.). Upstream `name` must stay plain (no
`(low)` parentheses).
