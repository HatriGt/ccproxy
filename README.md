# ccproxy

Always-on **[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI)** + **Cursor shim** — use Claude subscription OAuth in Cursor via a stable public HTTPS URL.

```
Cursor → https://cliproxy.yourdomain.com/v1
       → cursor-shim (Anthropic → OpenAI tool format)
       → cli-proxy-api (Claude OAuth)
       → Anthropic API
```

## Documentation

**[docs/setup-from-scratch.md](./docs/setup-from-scratch.md)** — full greenfield setup (humans & AI agents)

| Doc | Topic |
|-----|--------|
| [docs/README.md](./docs/README.md) | Index |
| [docs/architecture.md](./docs/architecture.md) | Components & ports |
| [docs/environment-variables.md](./docs/environment-variables.md) | `.env` reference |
| [docs/cursor-configuration.md](./docs/cursor-configuration.md) | Cursor IDE settings |
| [docs/claude-oauth.md](./docs/claude-oauth.md) | Login & re-login |
| [docs/dokploy-traefik.md](./docs/dokploy-traefik.md) | VPS routing |
| [docs/operations.md](./docs/operations.md) | Deploy, troubleshoot |

## Shell shortcuts (zsh)

```bash
./scripts/install-shell.sh   # once: adds ccproxy + aliases to ~/.zshrc
source ~/.zshrc

cch      # health check
ccs      # status
ccr      # Claude re-login
ccd      # redeploy
ccu      # print Cursor URL
```

See [docs/user-guide.md](./docs/user-guide.md).

## Quick start

```bash
git clone https://github.com/HatriGt/ccproxy.git
cd ccproxy
cp .env.example .env    # edit hostname, VPS SSH, secrets
./scripts/install-shell.sh
ccproxy deploy
ccproxy relogin         # if OAuth not copied from Mac
```

**Cursor:** Override OpenAI Base URL = `$CURSOR_BASE_URL`, API key = `$CLIPROXY_API_KEY`, Anthropic OFF.

## Repo layout

```
ccproxy/
├── docs/                   # Setup & operations guides
├── config/                 # CLIProxyAPI YAML
├── packages/cursor-shim/   # Node shim
├── images/                 # Dockerfiles
├── scripts/                # deploy, health-check, oauth
├── docker-compose.yml
└── .env.example
```

## License

MIT (see upstream CLIProxyAPI license for bundled proxy)
