# Operations

## Scripts reference

| Script | Purpose |
|--------|---------|
| `scripts/deploy-to-vps.sh` | Full deploy: rsync, build, traefik, auth copy, health check |
| `scripts/build.sh` | Build Docker images locally |
| `scripts/health-check.sh` | Test `/v1/models` + `/v1/chat/completions` |
| `scripts/auth-status.sh` | List auth files + run health check (`remote` or `local`) |
| `scripts/claude-relogin.sh` | OAuth re-login from Mac via SSH |
| `scripts/claude-login.sh` | OAuth on machine where compose runs |
| `scripts/copy-auth-from-mac.sh` | SCP `claude-*.json` from Mac to VPS volume |
| `scripts/setup-vps-traefik.sh` | Point Traefik at Docker shim |
| `scripts/start-local-shim.sh` | Mac dev shim → local VibeProxy |
| `scripts/load-env.sh` | Source `.env` |

## Redeploy after code changes

```bash
./scripts/deploy-to-vps.sh
```

## VPS manual commands

```bash
ssh $VPS_SSH_HOST
cd /opt/ccproxy

docker compose ps
docker compose logs -f cursor-shim
docker compose logs -f cli-proxy-api
docker compose restart
```

## Health check exit codes

| Code | Meaning |
|------|---------|
| `0` | Models + chat OK |
| `1` | Auth needed (`auth_unavailable`) |
| `2` | Tunnel/DNS/other failure |

```bash
./scripts/health-check.sh "$CURSOR_BASE_URL"
echo $?
```

## Troubleshooting

### `GET /v1/models` fails

- Check DNS: `dig +short $PUBLIC_HOSTNAME`
- Check shim: `ssh VPS 'curl -s http://127.0.0.1:8320/health'`
- Check containers: `docker compose ps`

### `auth_unavailable` on chat

→ [claude-oauth.md](./claude-oauth.md)

### 502 from Traefik

- Shim not listening: `docker compose up -d`
- Wrong upstream port in Traefik (must be **8320**, not 8318 or 18320)
- Re-run `./scripts/setup-vps-traefik.sh`

### Cursor agent tool errors

- Confirm URL is shim endpoint (`/v1` on port 8320 path), not raw API
- Check shim logs for parse errors

### Upgrade CLIProxyAPI version

1. Set `CLIPROXY_IMAGE_TAG` in `.env` (e.g. `v7.1.66`)
2. `./scripts/deploy-to-vps.sh`

## Backup OAuth tokens

```bash
ssh $VPS_SSH_HOST "cd /opt/ccproxy && docker compose exec -T cli-proxy-api tar -cC /data/auth ." | tar -xC ./auth-backup
```

Restore via `copy-auth-from-mac.sh` pattern or manual `docker compose cp`.
