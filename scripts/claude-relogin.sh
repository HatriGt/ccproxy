#!/usr/bin/env bash
# Re-login Claude OAuth on VPS (run from Mac — opens URL, you paste code via SSH).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-akvps}}"
REMOTE_DIR="${VPS_DEPLOY_DIR:-/opt/ccproxy}"

echo "=============================================="
echo "  Claude re-login on ${VPS_HOST}"
echo "=============================================="
echo ""
echo "This runs headless OAuth inside the cli-proxy-api container."
echo "You will get a URL → sign in in browser → paste the code in terminal."
echo ""
read -r -p "Continue? [Y/n] " ans
[[ "${ans:-Y}" =~ ^[Yy]$ ]] || exit 0

ssh -t "$VPS_HOST" "cd '${REMOTE_DIR}' && docker compose exec -it cli-proxy-api \
  /CLIProxyAPI/CLIProxyAPI -config /CLIProxyAPI/config.yaml -no-browser --claude-login"

echo ""
echo "==> Restarting stack..."
ssh "$VPS_HOST" "cd '${REMOTE_DIR}' && docker compose restart cli-proxy-api cursor-shim"

echo ""
echo "==> Health check..."
"${ROOT}/scripts/health-check.sh" "${CURSOR_BASE_URL:-https://${PUBLIC_HOSTNAME}/v1}"
