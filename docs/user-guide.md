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
| `ccproxy models` | List model aliases |
| `ccproxy add-model` | Add/update alias (`--help` shows examples) |
| `ccproxy remove-model` | Remove an alias |
| `ccst` | Token usage stats |
| `ccl` | Live request logs |

## Model aliases & effort

```bash
ccproxy models
ccproxy add-model ak-claude-opus-4.9 claude-opus-4-9
ccproxy add-model ak-claude-opus-4.9-low claude-opus-4-9   # auto effort=low
ccproxy add-model --help   # usage + effort examples
```

Alias suffix `-low` / `-medium` / `-high` (pattern `ak-claude-*-…`) auto-sets Claude adaptive effort. Always use a plain upstream id (e.g. `claude-opus-4-9`), never `claude-opus-4-9(low)`.

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
