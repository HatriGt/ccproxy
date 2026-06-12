# ccproxy documentation

Setup and operations guides for humans and AI agents.

| Doc | Purpose |
|-----|---------|
| [setup-from-scratch.md](./setup-from-scratch.md) | **Start here** — full greenfield setup |
| [architecture.md](./architecture.md) | Components, ports, request flow |
| [environment-variables.md](./environment-variables.md) | Every `.env` variable |
| [cursor-configuration.md](./cursor-configuration.md) | Cursor IDE settings |
| [claude-oauth.md](./claude-oauth.md) | Login, re-login, token copy |
| [dokploy-traefik.md](./dokploy-traefik.md) | VPS routing with Dokploy/Traefik |
| [operations.md](./operations.md) | Deploy, health checks, troubleshooting |
| [user-guide.md](./user-guide.md) | **Daily use** — zsh shortcuts (`cch`, `ccr`, …) |

## One-command deploy (after prerequisites)

```bash
cp .env.example .env   # edit hostname, VPS SSH host, secrets
./scripts/deploy-to-vps.sh
./scripts/claude-relogin.sh   # if auth not copied from Mac
```

## Success criteria

```bash
./scripts/health-check.sh "$CURSOR_BASE_URL"
# Exit 0 + "OK: /v1/chat/completions"
```

Cursor Agent mode must use a **public HTTPS** base URL (not `localhost`).
