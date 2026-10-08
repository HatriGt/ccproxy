#!/usr/bin/env bash
# Combined Claude account status + plan limits (no day-wise token table).
# Usage: accounts-overview.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

# Disambiguates the api container when several compose stacks exist.
export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

TARGET="${OVERVIEW_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
FETCH="${ROOT}/scripts/accounts_overview.py"

echo "==> Claude accounts + plan limits (${TARGET})"
echo ""

case "$TARGET" in
  remote)
    ssh -o LogLevel=ERROR "$VPS_HOST" "CCPROXY_PROJECT='$CCPROXY_PROJECT' python3 -" <"$FETCH"
    ;;
  local)
    python3 "$FETCH"
    ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
