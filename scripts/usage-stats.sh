#!/usr/bin/env bash
# Day-wise per-user token usage from the usage-tracker sidecar.
# Usage: usage-stats.sh [--days N] [--by-model] [--from DATE] [--to DATE] [--user EMAIL] [--json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${USAGE_STATS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-akvps}}"

# Default: last 7 days if no range flags passed.
ARGS=("$@")
has_range=false
for a in "${ARGS[@]}"; do
  [[ "$a" == "--days" || "$a" == "--from" || "$a" == "--to" ]] && has_range=true
done
[[ "$has_range" == true || ${#ARGS[@]} -gt 0 ]] || ARGS=(--days 7)

_find_tracker() {
  docker ps --format '{{.Names}}' | grep -E 'ccproxy.*usage-tracker' | head -1
}

_run_local() {
  local tracker
  tracker="$(_find_tracker)"
  if [[ -z "$tracker" ]]; then
    cd "$ROOT"
    if docker compose ps usage-tracker 2>/dev/null | grep -q running; then
      exec docker compose exec -T usage-tracker usage-cli "${ARGS[@]}"
    fi
    echo "ERROR: usage-tracker container not running locally." >&2
    exit 1
  fi
  exec docker exec "$tracker" usage-cli "${ARGS[@]}"
}

_run_remote() {
  local quoted=""
  for a in "${ARGS[@]}"; do quoted+=" $(printf '%q' "$a")"; done
  ssh "$VPS_HOST" "tracker=\$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*usage-tracker' | head -1); \
    if [ -z \"\$tracker\" ]; then echo 'ERROR: usage-tracker container not found on VPS.' >&2; exit 1; fi; \
    docker exec \"\$tracker\" usage-cli${quoted}"
}

echo "==> Token usage (${TARGET})"
echo ""

case "$TARGET" in
  local) _run_local ;;
  remote) _run_remote ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
