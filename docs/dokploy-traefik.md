# Dokploy & Traefik

## Recommended: automated Traefik update

`./scripts/deploy-to-vps.sh` calls `scripts/setup-vps-traefik.sh`, which writes:

```
/etc/dokploy/traefik/dynamic/cliproxy-cursor.yml
```

Route: `Host(\`$PUBLIC_HOSTNAME\`)` → `http://172.17.0.1:8320`

Docker publishes **cursor-shim** on host port `8320`; Traefik reaches it via the Docker bridge gateway `172.17.0.1`.

## Dokploy UI setup

If you prefer Dokploy’s domain wizard:

1. **Project** → Add **Docker Compose**
2. Compose file path: `/opt/ccproxy/docker-compose.yml`
3. **Domains** → Add domain:
   - Host: `$PUBLIC_HOSTNAME`
   - Service: `cursor-shim`
   - Port: `8320`
   - HTTPS: enabled (Let’s Encrypt)

Do **not** route to `cli-proxy-api:8318` — Cursor needs the shim on `8320`.

## Manual Traefik snippet

See `deploy/traefik-cliproxy.yml` in the repo (legacy relay port documented in comments).

## TLS

Dokploy Traefik uses `certResolver: letsencrypt`. Ensure:

- Port 80/443 open on VPS
- DNS A record correct
- No conflicting CNAME to Cloudflare tunnel unless that tunnel is active

## Disable legacy Mac relay

After Docker deploy, these are obsolete:

- `cliproxy-relay-bridge.service` (socat on port 18320)
- Mac `cliproxy-vps-relay.sh` SSH tunnel
- `cursor-claude` one-shot startup on Mac

`setup-vps-traefik.sh` stops and disables the bridge service automatically.
