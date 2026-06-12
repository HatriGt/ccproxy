#!/usr/bin/env bash
# Run cursor shim on Mac against local VibeProxy (port 8318). No Docker required.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

PORT="${CURSOR_SHIM_PORT:-8320}"
UPSTREAM="${CLIPROXY_UPSTREAM_LOCAL:-http://127.0.0.1:8318}"

if ! lsof -i ":8318" >/dev/null 2>&1; then
  echo "ERROR: Nothing on 8318. Open VibeProxy or start cli-proxy-api first." >&2
  exit 1
fi

export CURSOR_SHIM_HOST="${CURSOR_SHIM_HOST_LOCAL:-127.0.0.1}"
export CURSOR_SHIM_PORT="$PORT"
export CLIPROXY_UPSTREAM="$UPSTREAM"

echo "Shim: http://127.0.0.1:${PORT}/v1 → ${UPSTREAM}"
exec node "${ROOT}/packages/cursor-shim/shim.mjs"
