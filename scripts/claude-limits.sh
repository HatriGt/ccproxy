#!/usr/bin/env bash
# Show Claude plan usage limits (5-hour + weekly) per OAuth account.
# Runs fetch on the VPS so tokens never leave the server.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${LIMITS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
FETCH="${ROOT}/scripts/claude_limits_fetch.py"

echo "==> Claude plan limits (${TARGET})"
echo ""

case "$TARGET" in
  remote)
    ssh -o LogLevel=ERROR "$VPS_HOST" python3 - <"$FETCH"
    ;;
  local)
    python3 "$FETCH"
    ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
