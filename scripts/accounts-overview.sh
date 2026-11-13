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
ARGS=""
WATCH=0
for a in "$@"; do
  case "$a" in
    --live|-l) ARGS="--live" ;;
    --watch|-w) ARGS="--live"; WATCH=1 ;;
  esac
done
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
FETCH="${ROOT}/scripts/accounts_overview.py"

run() {
echo "==> Claude accounts + plan limits (${TARGET}${ARGS:+, live})"
echo ""

case "$TARGET" in
  remote)
    ssh -o LogLevel=ERROR "$VPS_HOST" "CCPROXY_PROJECT='$CCPROXY_PROJECT' python3 - $ARGS" <"$FETCH"
    ;;
  local)
    python3 "$FETCH" $ARGS
    ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
}

if [ "$WATCH" = 1 ]; then
  while true; do
    out="$(run 2>&1)"; clear; echo "$out"; echo; echo "(refreshing every 15s - Ctrl+C to stop)"; sleep 15
  done
else
  run
fi
