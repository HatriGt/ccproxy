#!/usr/bin/env bash
# Re-login Claude OAuth on VPS (run from Mac — opens URL, you paste code via SSH).
# Works with Dokploy-named compose (ccproxy-mp763t-*) — does not require /opt/ccproxy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

echo "=============================================="
echo "  Claude re-login on ${VPS_HOST}"
echo "=============================================="
echo ""
echo "This runs headless OAuth inside the cli-proxy-api container."
echo "You will get a URL → sign in in browser → paste the code in terminal."
echo ""
read -r -p "Continue? [Y/n] " ans
[[ "${ans:-Y}" =~ ^[Yy]$ ]] || exit 0

# Discover the running Dokploy container (project name is randomized).
ssh -t "$VPS_HOST" 'bash -s' <<'REMOTE'
set -euo pipefail
api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
if [ -z "$api" ]; then
  echo "ERROR: cli-proxy-api container not found (is ccproxy deployed?)." >&2
  exit 1
fi
echo "Using container: $api"
echo ""
docker exec -it "$api" \
  /CLIProxyAPI/CLIProxyAPI -config /CLIProxyAPI/config.yaml -no-browser --claude-login
echo ""
echo "Restarting $api ..."
docker restart "$api" >/dev/null
shim=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cursor-shim' | head -1 || true)
if [ -n "$shim" ]; then
  docker restart "$shim" >/dev/null
  echo "Restarted $shim"
fi
echo "Done."
REMOTE

echo ""
echo "==> Health check..."
"${ROOT}/scripts/health-check.sh" "${CURSOR_BASE_URL:-https://${PUBLIC_HOSTNAME}/v1}"
