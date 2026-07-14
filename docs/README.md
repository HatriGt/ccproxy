# ccproxy documentation

Setup and operations for **Cursor** and **Codex** on one Claude OAuth proxy.

| Doc | Purpose |
|-----|---------|
| [setup-from-scratch.md](./setup-from-scratch.md) | **Start here** — full greenfield setup |
| [architecture.md](./architecture.md) | Components, ports, Cursor + Codex request flow |
| [environment-variables.md](./environment-variables.md) | Every `.env` variable |
| [cursor-configuration.md](./cursor-configuration.md) | Cursor IDE settings |
| [codex-configuration.md](./codex-configuration.md) | Codex desktop + CLI (same URL) |
| [claude-oauth.md](./claude-oauth.md) | Login, re-login, accounts, pause |
| [dokploy-traefik.md](./dokploy-traefik.md) | VPS routing with Dokploy/Traefik |
| [operations.md](./operations.md) | Deploy, health checks, troubleshooting |
| [user-guide.md](./user-guide.md) | **Daily use** — zsh shortcuts + `ccproxy codex` |

## Clients

```
Cursor  →  /v1/chat/completions  (shim converts tool blocks)
Codex   →  /v1/responses         (shim passthrough)
         same HTTPS base URL (ccu)
```

## One-command deploy (after prerequisites)

```bash
cp .env.example .env   # edit hostname, VPS SSH host, secrets
./scripts/deploy-to-vps.sh
./scripts/claude-relogin.sh   # if auth not copied from Mac
```

## Success criteria

```bash
./scripts/health-check.sh "$CURSOR_BASE_URL"
# Exit 0 + OK on models / chat

ccproxy codex helper-model    # helpers mapped (Codex desktop)
```

Cursor Agent and Codex Desktop both need a **public HTTPS** base URL (not `localhost`).
