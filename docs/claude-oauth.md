# Claude OAuth

CLIProxyAPI uses **Claude subscription OAuth** (not a static Anthropic API key). Tokens are stored as JSON files in the auth directory.

## Where tokens live

| Environment | Path |
|-------------|------|
| VPS Docker | Volume `ccproxy_cliproxy-auth` → `/data/auth/claude-*.json` |
| Mac (VibeProxy) | `~/.cli-proxy-api/claude-*.json` |

## First-time login

After deploy, if health check reports `auth_unavailable`:

```bash
./scripts/claude-relogin.sh
```

Flow:

1. SSH to VPS, `docker compose exec` runs CLIProxyAPI with `--claude-login -no-browser`
2. Open printed URL in browser → sign in to Claude
3. Paste authorization code in terminal
4. Containers restart automatically

Alternative on VPS:

```bash
ssh $VPS_SSH_HOST
cd /opt/ccproxy
./scripts/claude-login.sh
```

## Re-login (token expired / cooldown)

Symptoms:

- `./scripts/health-check.sh` exits **1**
- Error: `auth_unavailable` or `Invalid authentication credentials`

Commands (pick one):

```bash
# Interactive from Mac
./scripts/claude-relogin.sh

# Copy fresh token from Mac VibeProxy
./scripts/copy-auth-from-mac.sh

# Check status
./scripts/auth-status.sh remote
```

## Cooldown behavior

After repeated auth failures, CLIProxyAPI sets `next_retry_after` on the account. Wait until that time, then re-login and restart:

```bash
ssh $VPS_SSH_HOST "cd /opt/ccproxy && docker compose restart cli-proxy-api cursor-shim"
```

## Headless OAuth reference

Inside the `cli-proxy-api` container ([CLIProxyAPI docs](https://help.router-for.me/docker/docker-compose)):

```bash
docker compose exec -it cli-proxy-api \
  /CLIProxyAPI/CLIProxyAPI \
  -config /CLIProxyAPI/config.yaml \
  -no-browser \
  --claude-login
```

## Security notes

- Never commit `claude-*.json` or `.env` to git
- OAuth files grant access to your Claude subscription
- Rotate `CLIPROXY_API_KEY` if the public proxy URL is exposed
