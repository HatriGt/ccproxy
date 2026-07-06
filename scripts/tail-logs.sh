#!/usr/bin/env bash
# Tail docker stdout logs from ccproxy services (Dokploy-safe).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${TAIL_LOGS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
TAIL="${TAIL_LINES:-100}"

_stream() {
  local api shim
  api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
  shim=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cursor-shim' | head -1)
  if [[ -z "$api" && -z "$shim" ]]; then
    echo "ERROR: no ccproxy api/shim containers running." >&2
    exit 1
  fi
  trap 'kill 0 2>/dev/null' EXIT INT TERM
  if [[ -n "$api" ]]; then
    docker logs -f --tail="$TAIL" "$api" 2>&1 | sed -u 's/^/[api] /' &
  fi
  if [[ -n "$shim" ]]; then
    docker logs -f --tail="$TAIL" "$shim" 2>&1 | sed -u 's/^/[shim] /' &
  fi
  wait
}

case "$TARGET" in
  remote)
    ssh -t "$VPS_HOST" "TAIL_LINES=$TAIL bash -s" <<'REMOTE'
set -euo pipefail
api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
shim=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cursor-shim' | head -1)
if [[ -z "$api" && -z "$shim" ]]; then
  echo "ERROR: no ccproxy api/shim containers running." >&2
  exit 1
fi
trap 'kill 0 2>/dev/null' EXIT INT TERM
if [[ -n "$api" ]]; then
  docker logs -f --tail="${TAIL_LINES:-100}" "$api" 2>&1 | sed -u 's/^/[api] /' &
fi
if [[ -n "$shim" ]]; then
  docker logs -f --tail="${TAIL_LINES:-100}" "$shim" 2>&1 | sed -u 's/^/[shim] /' &
fi
wait
REMOTE
    ;;
  local) _stream ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
