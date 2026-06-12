#!/usr/bin/env bash
# Point Traefik at Docker-published shim (8320) instead of Mac SSH relay (18320).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-akvps}}"
HOSTNAME="${PUBLIC_HOSTNAME:-cliproxy.ajeethkumar.dev}"
SHIM_PORT="${CURSOR_SHIM_PORT:-8320}"
TRAEFIK_FILE="${CLIPROXY_VPS_TRAEFIK_FILE:-cliproxy-cursor.yml}"

echo "==> Updating Traefik on ${VPS_HOST} → 172.17.0.1:${SHIM_PORT}"

ssh "$VPS_HOST" "HOSTNAME='${HOSTNAME}' SHIM_PORT='${SHIM_PORT}' TRAEFIK_FILE='${TRAEFIK_FILE}' bash -s" <<'REMOTE'
set -euo pipefail
DEST="/etc/dokploy/traefik/dynamic/${TRAEFIK_FILE}"
cat >"$DEST" <<YAML
http:
  routers:
    cliproxy-cursor-router-http:
      rule: Host(\`${HOSTNAME}\`)
      service: cliproxy-cursor-service
      middlewares:
        - redirect-to-https
      entryPoints:
        - web
    cliproxy-cursor-router-https:
      rule: Host(\`${HOSTNAME}\`)
      service: cliproxy-cursor-service
      entryPoints:
        - websecure
      tls:
        certResolver: letsencrypt
  services:
    cliproxy-cursor-service:
      loadBalancer:
        servers:
          - url: http://172.17.0.1:${SHIM_PORT}
        passHostHeader: true
YAML
chmod 644 "$DEST"
echo "    Wrote $DEST"

# Stop legacy Mac SSH relay bridge (no longer needed)
if systemctl is-active cliproxy-relay-bridge.service >/dev/null 2>&1; then
  systemctl stop cliproxy-relay-bridge.service
  systemctl disable cliproxy-relay-bridge.service
  echo "    Stopped cliproxy-relay-bridge.service"
fi
REMOTE

echo "OK: Traefik routes ${HOSTNAME} → docker shim :${SHIM_PORT}"
