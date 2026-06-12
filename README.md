<div align="center">

# ccproxy

### Use Cursor with your Claude Code account

A one-command, self-hosted bridge that lets **Cursor IDE** run on your **Claude Pro/Max subscription** — the same account you use in Claude.ai and Claude Code.

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Built on CLIProxyAPI](https://img.shields.io/badge/built%20on-CLIProxyAPI-blue)](https://github.com/router-for-me/CLIProxyAPI)
[![Docker](https://img.shields.io/badge/deploy-Docker%20Compose-2496ED?logo=docker&logoColor=white)](./docker-compose.yml)
[![Cursor](https://img.shields.io/badge/client-Cursor%20IDE-000000)](https://cursor.com)
[![Claude](https://img.shields.io/badge/models-Claude%20Sonnet%20%7C%20Opus-D97757)](https://www.anthropic.com)

```
Cursor  →  https://your-domain/v1  →  Claude (your subscription)
```

[Quick start](#quick-start) · [How to use](#how-to-use) · [Architecture](#under-the-hood) · [Docs](./docs/README.md)

</div>

---

## Overview

Cursor lets you point its model provider at any OpenAI-compatible endpoint. ccproxy is that endpoint — deployed on your own VPS — translating Cursor's requests and authenticating with **Claude OAuth** instead of a pay-per-token API key.

Deploy it once, point Cursor at the URL, and use Claude models in Agent and chat with no further setup.

| | |
|---|---|
| **Outcome** | Cursor (Agent + chat) running on your Claude subscription |
| **Endpoint** | A stable HTTPS URL you set once in Cursor |
| **Hosting** | Two small Docker containers on any VPS |
| **Maintenance** | Re-login when OAuth expires (`ccr`); otherwise hands-off |

---

## Quick start

```bash
git clone https://github.com/HatriGt/ccproxy.git
cd ccproxy
cp .env.example .env          # set your domain and VPS SSH host
./scripts/install-shell.sh    # installs the `ccproxy` CLI + shortcuts
source ~/.zshrc

ccproxy deploy                # build + start the stack on your VPS
ccproxy relogin               # sign in to Claude (one time)
ccu                           # prints the URL for Cursor
```

Full walkthrough: **[docs/setup-from-scratch.md](./docs/setup-from-scratch.md)**

---

## How to use

### 1. Configure Cursor (once)

**Cursor → Settings → Models:**

| Setting | Value |
|---------|-------|
| Override OpenAI Base URL | output of `ccu` (e.g. `https://cliproxy.yourdomain.com/v1`) |
| OpenAI API Key | `dummy` (or your own secret) |
| Anthropic API Key | **Off** |

Reload the window (`Cmd/Ctrl+Shift+P` → *Developer: Reload Window*), then select a model such as `ak-claude-sonnet-4.6` or `ak-claude-opus-4.7`.

### 2. Work

Open Cursor and use it normally — the server stays online without your machine.

### 3. Maintain

| Command | When to run |
|---------|-------------|
| `cch` | Verify the endpoint is healthy |
| `ccr` | Chat fails or reports `auth_unavailable` |
| `ccu` | Need the URL again for Cursor |
| `ccs` | Inspect Claude auth status |
| `ccd` | Redeploy after pulling updates |

Daily reference: **[docs/user-guide.md](./docs/user-guide.md)**

---

## Under the hood

ccproxy runs a two-service stack behind your domain:

```
┌────────────┐   HTTPS    ┌─────────────────┐   :8320   ┌──────────────┐   :8318   ┌──────────────┐
│ Cursor IDE │ ─────────► │ Traefik (Dokploy)│ ────────► │  cursor-shim │ ────────► │ CLIProxyAPI  │ ──► Claude
│  /v1/*     │            │   your domain    │           │ (format fix) │           │ (OAuth)      │
└────────────┘            └─────────────────┘           └──────────────┘           └──────────────┘
```

| Component | Responsibility |
|-----------|----------------|
| **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** | Authenticates with your Claude account via OAuth, manages token refresh and model aliases, serves `/v1/chat/completions` |
| **cursor-shim** | Translates Cursor Agent's Anthropic-style tool blocks (`tool_use` / `tool_result`) into the OpenAI shape CLIProxyAPI expects |
| **Traefik / Dokploy** | Terminates TLS and routes your domain to the shim (Cursor Agent requires public HTTPS, not `localhost`) |
| **Docker Compose** | Runs and supervises both containers; OAuth tokens persist in a named volume |

Deep dive: **[docs/architecture.md](./docs/architecture.md)**

---

## Requirements

- A **VPS** with Docker and Docker Compose v2+ (tested with [Dokploy](https://dokploy.com) + Traefik)
- A **domain** with an A record pointing to the VPS
- A **Claude Pro/Max** subscription
- **Cursor** with the OpenAI provider override

---

## Documentation

| Guide | Purpose |
|-------|---------|
| [setup-from-scratch.md](./docs/setup-from-scratch.md) | End-to-end install (humans & AI agents) |
| [user-guide.md](./docs/user-guide.md) | Daily commands and shortcuts |
| [architecture.md](./docs/architecture.md) | Components, ports, request flow |
| [cursor-configuration.md](./docs/cursor-configuration.md) | Cursor IDE settings and troubleshooting |
| [claude-oauth.md](./docs/claude-oauth.md) | Login, re-login, token handling |
| [dokploy-traefik.md](./docs/dokploy-traefik.md) | Routing and TLS on the VPS |
| [operations.md](./docs/operations.md) | Scripts, health checks, troubleshooting |
| [environment-variables.md](./docs/environment-variables.md) | Full `.env` reference |

---

## Repository layout

```
ccproxy/
├── bin/ccproxy            # CLI entrypoint (ccproxy <command>)
├── packages/cursor-shim/  # Request format translator (Node.js)
├── images/                # Dockerfiles for proxy and shim
├── config/                # CLIProxyAPI config, model aliases, API keys
├── scripts/               # deploy, health-check, oauth, install-shell
├── deploy/                # Traefik / Cloudflare reference configs
├── docs/                  # Documentation
└── docker-compose.yml     # VPS stack definition
```

---

## Security

- `.env` and `claude-*.json` are gitignored — never commit credentials.
- Keep `remote-management.allow-remote: false` in `config/config.yaml`.
- Set a strong `CLIPROXY_API_KEY` before exposing the endpoint publicly.
- OAuth tokens grant access to your Claude subscription; treat the VPS accordingly.

---

## License

MIT (this repository). Built on [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) using the [eceasy/cli-proxy-api](https://hub.docker.com/r/eceasy/cli-proxy-api) image. Use in accordance with Anthropic's subscription terms.
