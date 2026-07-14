#!/usr/bin/env bash
# Day-wise per-user token usage from the usage-tracker sidecar.
# Usage: usage-stats.sh [--days N] [--by-model] [--from DATE] [--to DATE] [--user EMAIL] [--json]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${USAGE_STATS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

# Default: last 7 days if no args passed.
ARGS=("$@")
has_range=false
if ((${#ARGS[@]} > 0)); then
  for a in "${ARGS[@]}"; do
    [[ "$a" == "--days" || "$a" == "--from" || "$a" == "--to" ]] && has_range=true
  done
fi
if [[ "$has_range" == false && ${#ARGS[@]} -eq 0 ]]; then
  ARGS=(--days 7)
fi

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
  remote)
    _run_remote
    # After token table, also show live Claude plan limits (skip for --json).
    show_limits=true
    for a in "${ARGS[@]}"; do
      [[ "$a" == "--json" ]] && show_limits=false
    done
    if [[ "$show_limits" == true ]]; then
      echo ""
      LIMITS_TARGET=remote bash "${ROOT}/scripts/claude-limits.sh"
    fi
    ;;
  *)
    echo "Unknown target: $TARGET (use local|remote)" >&2
    exit 2
    ;;
esac
