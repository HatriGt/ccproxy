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
| `ccr` | Claude login / re-login on VPS |
| `ccproxy login` | Same as `ccproxy relogin` |
| `ccd` | Redeploy to VPS |
| `ccu` | Print Cursor base URL |
| `cce` | Show key env settings |
| `ccp help` | Full command list |
| `ccproxy models` | List model aliases |
| `ccproxy add-model` | Add/update alias (`--help` shows examples) |
| `ccproxy remove-model` | Remove an alias |
| `ccst` | Token usage + Claude plan limits (5h / weekly) |
| `ccproxy limits` | Claude plan limits only (per account) |
| `ccproxy pause <who>` | Exclude that Claude account from round-robin |
| `ccproxy resume <who>` | Put it back in round-robin |
| `ccl` | Live request logs |

## Model aliases & effort

```bash
ccproxy models
ccproxy add-model ak-claude-opus-4.9 claude-opus-4-9
ccproxy add-model ak-claude-opus-4.9-low claude-opus-4-9   # auto effort=low
ccproxy add-model --help   # usage + effort examples
```

Alias suffix `-low` / `-medium` / `-high` (pattern `ak-claude-*-…`) auto-sets Claude adaptive effort. Always use a plain upstream id (e.g. `claude-opus-4-9`), never `claude-opus-4-9(low)`.

## Claude plan limits (5-hour / weekly)

Same numbers as Claude Settings → Usage. Per OAuth account on the VPS:

```bash
ccproxy limits                 # plan limits only
ccproxy stats                  # token usage table, then plan limits
ccst                           # shortcut for stats
```

## Account status & when to re-login

```bash
ccproxy accounts               # ACTIVE / PAUSED / EXPIRED
```

The **TOKEN** column is the current OAuth **access** token TTL (usually ~8h).
CLIProxyAPI auto-refreshes it — you do **not** re-login every 8 hours. Relogin
only when STATUS is **EXPIRED**. Plan usage is `ccproxy limits` / `ccproxy stats`,
not this column. Details: [claude-oauth.md](./claude-oauth.md#account-status-ccproxy-accounts).

## Pause an account near its limit (round-robin)

When one Claude account is about to hit 5h/weekly limits, exclude it from
routing so traffic uses the others. Uses CLIProxyAPI's durable `disabled`
flag (survives restarts).

```bash
ccproxy accounts               # ACTIVE / PAUSED / EXPIRED
ccproxy pause harish           # substring or full email
ccproxy resume harish
# shortcuts: ccpause / ccresume (after install-shell)
```

Paused ≠ expired OAuth. Resume when the limit window resets.

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
