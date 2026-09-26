#!/usr/bin/env bash
# Show Claude OAuth health (remote VPS or local).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

# Disambiguates the api/shim container when several compose stacks exist.
export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

TARGET="${1:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
BASE_URL="${CURSOR_BASE_URL:-https://${PUBLIC_HOSTNAME}/v1}"

echo "==> Claude auth / API check (${TARGET})"

if [[ "$TARGET" == "remote" ]]; then
  echo ""
  echo "--- Auth files in container volume ---"
  ssh "$VPS_HOST" "CCPROXY_PROJECT='$CCPROXY_PROJECT' bash -s" <<'REMOTE' || true
set -euo pipefail
if [ -n "${CCPROXY_PROJECT:-}" ]; then
  # Pin to the compose project — several stacks can match the name grep.
  api=$(docker ps --filter "label=com.docker.compose.project=${CCPROXY_PROJECT}" \
        --format '{{.Names}}' | grep -E 'cli-proxy-api' | head -1)
else
  api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
fi
if [ -z "$api" ]; then echo "(cli-proxy-api not running)"; exit 0; fi
docker exec "$api" ls -la /data/auth/ 2>/dev/null || true
REMOTE
  echo ""
  echo "--- Live API test ---"
  "${ROOT}/scripts/health-check.sh" "$BASE_URL" && exit 0
  HC=$?
  if [[ "$HC" == "1" ]]; then
    echo ""
    echo "Auth expired or in cooldown. Run: ccproxy relogin"
    exit 1
  fi
  exit "$HC"
fi

echo ""
echo "--- Local docker volume ---"
cd "$ROOT"
if [ -n "${CCPROXY_PROJECT:-}" ]; then
  # Pin to the compose project — several stacks can match the name grep.
  api=$(docker ps --filter "label=com.docker.compose.project=${CCPROXY_PROJECT}" \
        --format '{{.Names}}' | grep -E 'cli-proxy-api' | head -1 || true)
else
  api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1 || true)
fi
if [ -n "$api" ]; then
  docker exec "$api" ls -la /data/auth/ 2>/dev/null || true
else
  docker compose exec -T cli-proxy-api ls -la /data/auth/ 2>/dev/null || echo "(stack not running)"
fi
echo ""
"${ROOT}/scripts/health-check.sh" "http://127.0.0.1:8320/v1"
