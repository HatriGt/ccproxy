#!/usr/bin/env bash
# Opt accounts into 5-hour auto-hold (separate from manual pause).
# Usage:
#   account-guard.sh list
#   account-guard.sh on  <email-or-substring>
#   account-guard.sh off <email-or-substring>
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

TARGET="${GUARD_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
SCRIPT="${ROOT}/scripts/account_guard.py"

if [[ $# -lt 1 ]]; then
  echo "Usage: ccproxy guard list|on|off [email-or-substring]" >&2
  exit 2
fi

case "$TARGET" in
  remote)
    ssh -o LogLevel=ERROR "$VPS_HOST" "CCPROXY_PROJECT='$CCPROXY_PROJECT' python3 -" "$@" <"$SCRIPT"
    ;;
  local)
    python3 "$SCRIPT" "$@"
    ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
