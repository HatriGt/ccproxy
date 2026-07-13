# Claude OAuth

CLIProxyAPI uses **Claude subscription OAuth** (not a static Anthropic API key). Tokens are stored as JSON files in the auth directory.

## Where tokens live

| Environment | Path |
|-------------|------|
| VPS Docker | Volume `ccproxy_cliproxy-auth` → `/data/auth/claude-*.json` |
| Mac (VibeProxy) | `~/.cli-proxy-api/claude-*.json` |

## Login / re-login

Same OAuth flow for both:

```bash
ccproxy login      # or: ccproxy relogin / ccr
```

Flow:

1. Script SSHs to the VPS and runs `--claude-login` inside the api container
2. Open the printed URL in your browser → sign in to Claude
3. Browser fails on `localhost:54545` (expected) — copy the **full callback URL**
   from the address bar (`http://localhost:54545/callback?code=...&state=...`)
   and paste it at the prompt
4. Containers restart; script waits until `/v1/models` is ready, then health-checks

Symptoms that you need to re-login:

- `ccproxy health` exits **1**
- Error: `auth_unavailable` or `Invalid authentication credentials`

Other options:

```bash
ccproxy copy-auth   # copy fresh token from Mac VibeProxy
ccproxy status      # auth files + health
ccproxy accounts    # per-account status
```

## Cooldown behavior

After repeated auth failures, CLIProxyAPI sets `next_retry_after` on the account. Wait until that time, then re-login:

```bash
ccproxy relogin
```

## Headless OAuth reference

Inside the `cli-proxy-api` container ([CLIProxyAPI docs](https://help.router-for.me/docker/docker-compose)):

```bash
docker exec -it "$(docker ps --format '{{.Names}}' | grep cli-proxy-api | head -1)" \
  /CLIProxyAPI/CLIProxyAPI \
  -config /CLIProxyAPI/config.yaml \
  -no-browser \
  --claude-login
```

## Security notes

- Never commit `claude-*.json` or `.env` to git
- OAuth files grant access to your Claude subscription
- Rotate `CLIPROXY_API_KEY` if the public proxy URL is exposed
