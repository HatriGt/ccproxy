#!/usr/bin/env bash
# Pause / resume Claude accounts in round-robin (CLIProxyAPI disabled flag).
# Usage:
#   account-route.sh list
#   account-route.sh pause <email-or-substring>
#   account-route.sh resume <email-or-substring>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${ROUTE_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
SCRIPT="${ROOT}/scripts/account_route.py"

if [[ $# -lt 1 ]]; then
  echo "Usage: ccproxy pause|resume <email-or-substring>" >&2
  echo "       ccproxy accounts   # see ACTIVE / PAUSED" >&2
  exit 2
fi

case "$TARGET" in
  remote)
    ssh -o LogLevel=ERROR "$VPS_HOST" python3 - "$@" <"$SCRIPT"
    ;;
  local)
    python3 "$SCRIPT" "$@"
    ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
