#!/usr/bin/env bash
# Full deploy: rsync → build → traefik → copy auth → health check
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-akvps}}"
REMOTE_DIR="${VPS_DEPLOY_DIR:-/opt/ccproxy}"
HOSTNAME="${PUBLIC_HOSTNAME:-cliproxy.ajeethkumar.dev}"
BASE_URL="${CURSOR_BASE_URL:-https://${HOSTNAME}/v1}"

die() { echo "ERROR: $*" >&2; exit 1; }

echo "==> [1/6] Deploying ccproxy to ${VPS_HOST}:${REMOTE_DIR}"
ssh -o ConnectTimeout=15 "$VPS_HOST" "mkdir -p '${REMOTE_DIR}'" || die "SSH failed"

rsync -avz --delete \
  --exclude '.git' \
  --exclude 'auth-export' \
  --exclude 'auth-import' \
  --exclude 'data' \
  "${ROOT}/" "${VPS_HOST}:${REMOTE_DIR}/"

echo ""
echo "==> [2/6] Building and starting Docker stack on VPS..."
ssh "$VPS_HOST" "cd '${REMOTE_DIR}' && docker compose build && docker compose up -d"

echo ""
echo "==> [3/6] Wiring Traefik → docker shim (stop Mac SSH relay)..."
"${ROOT}/scripts/setup-vps-traefik.sh"

echo ""
echo "==> [4/6] Importing Claude OAuth from Mac (if available)..."
if [[ -d "${CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}" ]] && compgen -G "${CLIPROXY_AUTH_DIR:-$HOME/.cli-proxy-api}/claude-*.json" >/dev/null; then
  "${ROOT}/scripts/copy-auth-from-mac.sh" || echo "WARN: auth copy failed — run ./scripts/claude-relogin.sh"
else
  echo "    No local claude-*.json — run: ./scripts/claude-relogin.sh"
fi

echo ""
echo "==> [5/6] Waiting for services..."
sleep 5

echo ""
echo "==> [6/6] Health check..."
if "${ROOT}/scripts/health-check.sh" "$BASE_URL"; then
  echo ""
  echo "=============================================="
  echo "  DEPLOY OK"
  echo "  Cursor Base URL: ${BASE_URL}"
  echo "  API key:         ${CLIPROXY_API_KEY:-dummy}"
  echo "=============================================="
else
  HC=$?
  echo ""
  if [[ "$HC" == "1" ]]; then
    echo "=============================================="
    echo "  Deploy up but Claude auth needed."
    echo "  Run:  ./scripts/claude-relogin.sh"
    echo "=============================================="
    exit 1
  fi
  die "Health check failed (exit ${HC})"
fi
