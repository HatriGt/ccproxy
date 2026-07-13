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

# Important: do NOT feed the remote side via a heredoc — that steals stdin and
# breaks `ssh -t` / `docker exec -it` (OAuth needs an interactive TTY to paste
# the code). Pass a one-liner so your local terminal is forwarded.
ssh -t "$VPS_HOST" \
  'api=$(docker ps --format "{{.Names}}" | grep -E "ccproxy.*cli-proxy-api" | head -1)
   if [ -z "$api" ]; then echo "ERROR: cli-proxy-api container not found." >&2; exit 1; fi
   echo "Using container: $api"
   echo ""
   docker exec -it "$api" /CLIProxyAPI/CLIProxyAPI -config /CLIProxyAPI/config.yaml -no-browser --claude-login'

echo ""
echo "==> Restarting api (+ shim)..."
ssh "$VPS_HOST" \
  'api=$(docker ps --format "{{.Names}}" | grep -E "ccproxy.*cli-proxy-api" | head -1)
   shim=$(docker ps --format "{{.Names}}" | grep -E "ccproxy.*cursor-shim" | head -1 || true)
   [ -n "$api" ] && docker restart "$api" >/dev/null && echo "Restarted $api"
   [ -n "$shim" ] && docker restart "$shim" >/dev/null && echo "Restarted $shim"'

echo ""
echo "==> Health check..."
"${ROOT}/scripts/health-check.sh" "${CURSOR_BASE_URL:-https://${PUBLIC_HOSTNAME}/v1}"
