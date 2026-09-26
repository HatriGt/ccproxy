#!/usr/bin/env bash
# Claude OAuth on VPS (login / relogin — same flow).
# Run from Mac: open printed URL → sign in → paste callback URL when prompted.
# Dokploy-aware: finds ccproxy-*-cli-proxy-api by name (no /opt/ccproxy).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

# Disambiguates the api/shim container when several compose stacks exist.
export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
BASE_URL="${CURSOR_BASE_URL:-https://${PUBLIC_HOSTNAME}/v1}"
LABEL="${1:-login}"
case "$LABEL" in
  login|relogin) ;;
  *) LABEL=login ;;
esac

echo "ccproxy ${LABEL} — Claude OAuth on ${VPS_HOST}"
echo ""
echo "  1. Open the URL printed below in your browser and sign in"
echo "  2. Browser will fail on localhost:54545 — that's expected"
echo "  3. Copy the full callback URL from the address bar"
echo "     (http://localhost:54545/callback?code=...&state=...)"
echo "  4. Paste it at the prompt"
echo ""
read -r -p "Continue? [Y/n] " ans
[[ "${ans:-Y}" =~ ^[Yy]$ ]] || exit 0
echo ""

# Do NOT use a heredoc for the interactive step — it steals stdin and breaks TTY.
ssh -t "$VPS_HOST" \
  'api=$(docker ps --filter "label=com.docker.compose.project='"$CCPROXY_PROJECT"'" --format "{{.Names}}" | grep -E "cli-proxy-api" | head -1)
   [ -n "$api" ] || api=$(docker ps --format "{{.Names}}" | grep -E "ccproxy.*cli-proxy-api" | head -1)
   if [ -z "$api" ]; then echo "ERROR: cli-proxy-api container not found." >&2; exit 1; fi
   echo "Container: $api"
   echo ""
   docker exec -it "$api" /CLIProxyAPI/CLIProxyAPI -config /CLIProxyAPI/config.yaml -no-browser --claude-login'

# CLIProxyAPI >= v7.3 writes a new record as claude-<uuid>-<email>.json rather
# than overwriting an existing claude-<email>.json, so a relogin can leave two
# files for one account. Collapse them before the restart.
echo ""
"${ROOT}/scripts/normalize-auth.sh" \
  || echo "WARN: auth normalisation failed — run: ccproxy normalize-auth" >&2

echo ""
echo "Restarting api + shim..."
ssh "$VPS_HOST" \
  'api=$(docker ps --filter "label=com.docker.compose.project='"$CCPROXY_PROJECT"'" --format "{{.Names}}" | grep -E "cli-proxy-api" | head -1)
   [ -n "$api" ] || api=$(docker ps --format "{{.Names}}" | grep -E "ccproxy.*cli-proxy-api" | head -1)
   shim=$(docker ps --filter "label=com.docker.compose.project='"$CCPROXY_PROJECT"'" --format "{{.Names}}" | grep -E "cursor-shim" | head -1 || true)
   [ -n "$shim" ] || shim=$(docker ps --format "{{.Names}}" | grep -E "ccproxy.*cursor-shim" | head -1 || true)
   if [ -n "$api" ]; then docker restart "$api" >/dev/null; echo "  restarted $api"; fi
   if [ -n "$shim" ]; then docker restart "$shim" >/dev/null; echo "  restarted $shim"; fi'

# Race fix: wait until public /v1/models responds before health-check.
echo "Waiting for API..."
BASE_URL="${BASE_URL%/}"
[[ "$BASE_URL" == */v1 ]] || BASE_URL="${BASE_URL}/v1"
API_KEY="${CLIPROXY_API_KEY:-dummy}"
ready=0
for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w "%{http_code}" -m 5 \
    "${BASE_URL}/models" -H "Authorization: Bearer ${API_KEY}" || echo 000)
  if [ "$code" = "200" ]; then
    ready=1
    echo "  API ready (~$((i * 2))s)"
    break
  fi
  sleep 2
done
if [ "$ready" != "1" ]; then
  echo "WARNING: API not ready after ~60s (last HTTP ${code:-?}). Running health check anyway..." >&2
fi

echo ""
"${ROOT}/scripts/health-check.sh" "$BASE_URL"
