#!/usr/bin/env bash
# Copy working Claude OAuth token(s) from Mac ~/.cli-proxy-api into VPS docker volume.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-akvps}}"
REMOTE_DIR="${VPS_DEPLOY_DIR:-/opt/ccproxy}"
AUTH_DIR="${CLIPROXY_AUTH_DIR:-${HOME}/.cli-proxy-api}"

shopt -s nullglob
FILES=("${AUTH_DIR}"/claude-*.json)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: No claude-*.json in ${AUTH_DIR}" >&2
  exit 1
fi

echo "==> Copying Claude auth to ${VPS_HOST} (${#FILES[@]} file(s))..."
ssh "$VPS_HOST" "mkdir -p '${REMOTE_DIR}/auth-import'"

for f in "${FILES[@]}"; do
  scp "$f" "${VPS_HOST}:${REMOTE_DIR}/auth-import/"
done

ssh "$VPS_HOST" "cd '${REMOTE_DIR}' && \
  docker compose up -d cli-proxy-api && \
  for f in auth-import/claude-*.json; do \
    docker compose cp \"\$f\" cli-proxy-api:/data/auth/; \
  done && \
  docker compose restart cli-proxy-api cursor-shim"

echo "OK: auth copied and stack restarted"
