# User guide — daily commands

## One-time install (zsh shortcuts)

```bash
cd /path/to/ccproxy
./scripts/install-shell.sh
source ~/.zshrc
```

Adds `ccproxy` to `~/.local/bin` and short aliases to your shell.

## Shortcuts

| Command | What it does |
|---------|----------------|
| `cch` | Health check (models + chat) |
| `ccs` | Auth status on VPS |
| `ccr` | Claude re-login on VPS |
| `ccd` | Redeploy to VPS |
| `ccu` | Print Cursor base URL |
| `cce` | Show key env settings |
| `ccp help` | Full command list |

## Without aliases

```bash
ccproxy health
ccproxy relogin
ccproxy status
```

## Cursor settings (set once)

| Setting | Value |
|---------|--------|
| Override OpenAI Base URL | output of `ccu` |
| OpenAI API Key | `dummy` (or `cce` → `CLIPROXY_API_KEY`) |
| Anthropic API Key | OFF |

No daily startup — VPS Docker stack runs 24/7.
