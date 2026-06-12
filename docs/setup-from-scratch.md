# Setup from scratch

Complete guide to run **ccproxy** — CLIProxyAPI + Cursor shim on a VPS with a stable HTTPS URL for Cursor IDE.

Target outcome: Cursor → `https://cliproxy.yourdomain.com/v1` → Claude via subscription OAuth.

---

## Prerequisites

### On your machine (deploy workstation)

- `git`, `ssh`, `rsync`
- SSH key access to your VPS (`ssh your-vps` works)
- Optional: working Claude OAuth on Mac in `~/.cli-proxy-api/claude-*.json` (speeds up first deploy)

### On the VPS

- Linux with **Docker** and **Docker Compose** v2+
- **Traefik** (via [Dokploy](https://dokploy.com) or standalone) terminating HTTPS
- A domain **A record** pointing to the VPS public IP (e.g. `cliproxy.yourdomain.com` → `203.0.113.10`)
- Outbound HTTPS to Anthropic API

### Accounts

- **Claude** subscription (Claude Pro/Max) for OAuth login
- **Cursor** with ability to set OpenAI API override

---

## Step 1 — Clone and configure environment

```bash
git clone https://github.com/HatriGt/ccproxy.git
cd ccproxy
cp .env.example .env
```

Edit `.env` — minimum required changes:

| Variable | Example | Notes |
|----------|---------|-------|
| `PUBLIC_HOSTNAME` | `cliproxy.yourdomain.com` | DNS A record to VPS |
| `PUBLIC_URL` | `https://cliproxy.yourdomain.com` | |
| `CURSOR_BASE_URL` | `https://cliproxy.yourdomain.com/v1` | Cursor uses this |
| `VPS_SSH_HOST` | `your-vps` | SSH config host alias or `user@ip` |
| `VPS_DEPLOY_DIR` | `/opt/ccproxy` | Remote install path |
| `VPS_PUBLIC_IP` | `203.0.113.10` | For DNS verification |
| `CLIPROXY_API_KEY` | `dummy` or a long random string | Cursor “OpenAI API Key” |

Optional but recommended before public exposure:

- Change `api-keys` in `config/config.yaml` to match `CLIPROXY_API_KEY`
- Set `remote-management.secret-key` in `config/config.yaml` (see [CLIProxyAPI docs](https://help.router-for.me/docker/docker-compose))

Load env in shell:

```bash
source scripts/load-env.sh
```

---

## Step 2 — DNS

Create an **A record**:

```
cliproxy.yourdomain.com  →  <VPS_PUBLIC_IP>
```

Wait for propagation, then verify:

```bash
dig +short "$PUBLIC_HOSTNAME"
```

---

## Step 3 — Deploy to VPS

```bash
./scripts/deploy-to-vps.sh
```

This script:

1. Rsyncs the repo to `$VPS_DEPLOY_DIR`
2. Builds Docker images on the VPS (`ccproxy-cli-proxy-api`, `ccproxy-cursor-shim`)
3. Starts `docker compose up -d`
4. Updates Traefik to route `$PUBLIC_HOSTNAME` → host port `8320`
5. Stops legacy Mac SSH relay bridge if present
6. Copies `~/.cli-proxy-api/claude-*.json` from Mac if found
7. Runs health check against `$CURSOR_BASE_URL`

### Expected output

```
OK: /v1/models
OK: /v1/chat/completions → ok
DEPLOY OK
```

If step 4 fails with **auth** (exit code 1), continue to Step 4.

---

## Step 4 — Claude OAuth (first login)

Choose **one**:

### A) Re-login on VPS (recommended)

From your Mac:

```bash
./scripts/claude-relogin.sh
```

1. Terminal prints an OAuth URL
2. Open in browser, sign in to Claude
3. Paste authorization code back into terminal
4. Stack restarts and health check runs

### B) Copy token from Mac

If you already use VibeProxy/CLIProxyAPI on Mac with valid tokens:

```bash
./scripts/copy-auth-from-mac.sh
```

### C) On VPS directly

```bash
ssh "$VPS_SSH_HOST"
cd /opt/ccproxy
./scripts/claude-login.sh
```

Verify:

```bash
./scripts/auth-status.sh remote
./scripts/health-check.sh "$CURSOR_BASE_URL"
```

---

## Step 5 — Configure Cursor

See [cursor-configuration.md](./cursor-configuration.md).

Summary:

| Setting | Value |
|---------|--------|
| Override OpenAI Base URL | `https://cliproxy.yourdomain.com/v1` |
| OpenAI API Key | value of `CLIPROXY_API_KEY` (default `dummy`) |
| Anthropic API Key | **OFF** |

Reload Cursor: `Cmd+Shift+P` → **Developer: Reload Window**.

---

## Step 6 — Dokploy (optional UI)

If you use Dokploy instead of manual Traefik files:

1. Create project → **Docker Compose**
2. Compose path: `/opt/ccproxy`
3. Domain: `$PUBLIC_HOSTNAME` → service **`cursor-shim`** → port **`8320`**

Manual Traefik snippet: [dokploy-traefik.md](./dokploy-traefik.md).

---

## Local development paths

### Mac + VibeProxy only (no VPS)

```bash
# VibeProxy listening on 8318, then:
./scripts/start-local-shim.sh
```

Note: Cursor **Agent mode blocks localhost** — use VPS HTTPS for agent.

### Local Docker smoke test

```bash
./scripts/build.sh
docker compose -f docker-compose.yml -f docker-compose.local.yml up -d
./scripts/health-check.sh http://127.0.0.1:8320/v1
```

---

## AI agent checklist

When automating this setup, verify in order:

- [ ] `.env` exists with real `PUBLIC_HOSTNAME`, `VPS_SSH_HOST`, `CURSOR_BASE_URL`
- [ ] DNS A record resolves to VPS IP
- [ ] `ssh $VPS_SSH_HOST` succeeds
- [ ] `docker compose version` works on VPS
- [ ] `./scripts/deploy-to-vps.sh` completes
- [ ] If health check exit `1`: run `./scripts/claude-relogin.sh` (requires interactive OAuth)
- [ ] `./scripts/health-check.sh "$CURSOR_BASE_URL"` exit `0`
- [ ] Document `CURSOR_BASE_URL` and `CLIPROXY_API_KEY` for Cursor settings

---

## Related docs

- [architecture.md](./architecture.md)
- [claude-oauth.md](./claude-oauth.md)
- [operations.md](./operations.md)
