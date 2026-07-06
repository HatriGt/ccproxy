#!/usr/bin/env bash
# Stream live request logs (including prompts) from CLIProxyAPI on the VPS.
#
# Temporarily enables request-log via the management API, tails new per-request
# log files under the auth volume, then restores the previous setting on exit
# (unless --keep). Disk-heavy — use only when debugging.
#
# Usage:
#   live-logs.sh              # prompts + request info (default)
#   live-logs.sh --full       # entire log file per request
#   live-logs.sh --keep       # leave request-log enabled after exit
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${LIVE_LOGS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
MGMT_KEY="${CLIPROXY_MGMT_KEY:-}"
MODE="summary"
KEEP=false

while (($# > 0)); do
  case "$1" in
    --full) MODE="full" ;;
    --keep) KEEP=true ;;
    --summary) MODE="summary" ;;
    -h|--help)
      cat <<EOF
Usage: ccproxy live [--full] [--keep]

  --summary   Show request info + REQUEST BODY (default)
  --full      Print entire per-request log files
  --keep      Do not disable request-log on exit (uses disk)
EOF
      exit 0
      ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

_remote_script() {
  cat <<'REMOTE'
set -euo pipefail
MODE="$1"
KEEP="$2"
MGMT_KEY="$3"

api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
if [[ -z "$api" ]]; then
  echo "ERROR: cli-proxy-api container not found." >&2
  exit 1
fi

api_ip=$(docker inspect "$api" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
vol=$(docker inspect "$api" --format '{{range .Mounts}}{{if eq .Destination "/data/auth"}}{{.Name}}{{end}}{{end}}')
if [[ -z "$vol" ]]; then
  echo "ERROR: cliproxy-auth volume not found." >&2
  exit 1
fi
logdir=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')/logs
mkdir -p "$logdir"

mgmt() {
  local method="$1" path="$2" body="${3:-}"
  if [[ -n "$body" ]]; then
    curl -sf -X "$method" \
      -H "Authorization: Bearer ${MGMT_KEY}" \
      -H "Content-Type: application/json" \
      -d "$body" \
      "http://${api_ip}:8318/v0/management/${path}"
  else
    curl -sf \
      -H "Authorization: Bearer ${MGMT_KEY}" \
      "http://${api_ip}:8318/v0/management/${path}"
  fi
}

was_enabled=false
if mgmt GET request-log | grep -q '"request-log":true'; then
  was_enabled=true
fi

if [[ "$was_enabled" == false ]]; then
  echo "==> Enabling request-log (prompts will be written to disk; restored on exit unless --keep)"
  mgmt PATCH request-log '{"value":true}' >/dev/null
  enabled_by_us=true
else
  echo "==> request-log already enabled"
  enabled_by_us=false
fi

cleanup() {
  if [[ "$KEEP" == true || "$was_enabled" == true || "${enabled_by_us:-false}" == false ]]; then
    return 0
  fi
  echo ""
  echo "==> Disabling request-log"
  mgmt PATCH request-log '{"value":false}' >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

echo "==> Watching ${logdir} (new requests only)"
echo "    Press Ctrl+C to stop"
echo ""

seen_file="${logdir}/.ccproxy-live-seen"
touch "$seen_file"
shopt -s nullglob
for f in "$logdir"/v1-chat-completions-*.log "$logdir"/graphql-*.log; do
  [[ -f "$f" ]] && grep -qxF "$(basename "$f")" "$seen_file" 2>/dev/null || echo "$(basename "$f")" >> "$seen_file"
done

print_summary() {
  awk '
    BEGIN { show=0; inbody=0 }
    /^=== REQUEST INFO ===/ { show=1 }
    show && /^Version:|^URL:|^Method:|^Timestamp:/ { print }
    /^=== REQUEST BODY ===/ { print; inbody=1; next }
    inbody && /^=== / { inbody=0; show=0; print ""; next }
    inbody { print }
    /^Auth: provider=/ { print }
  '
}

watch_logs() {
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -m -e close_write --format '%f' "$logdir" 2>/dev/null | while read -r file; do
      case "$file" in
        v1-chat-completions-*|graphql-*)
          echo "──────────────── ${file} ────────────────"
          if [[ "$MODE" == "full" ]]; then
            cat "${logdir}/${file}"
          else
            print_summary < "${logdir}/${file}"
          fi
          echo ""
          ;;
      esac
    done
  else
    while true; do
      shopt -s nullglob
      for f in "$logdir"/v1-chat-completions-*.log "$logdir"/graphql-*.log; do
        base=$(basename "$f")
        grep -qxF "$base" "$seen_file" 2>/dev/null && continue
        echo "$base" >> "$seen_file"
        echo "──────────────── ${base} ────────────────"
        if [[ "$MODE" == "full" ]]; then
          cat "$f"
        else
          print_summary < "$f"
        fi
        echo ""
      done
      sleep 1
    done
  fi
}

watch_logs
REMOTE
}

_run_remote() {
  if [[ -z "$MGMT_KEY" ]]; then
    echo "ERROR: CLIPROXY_MGMT_KEY not set in .env" >&2
    exit 1
  fi
  # shellcheck disable=SC2016
  ssh -t "$VPS_HOST" "bash -s" "$MODE" "$KEEP" "$MGMT_KEY" <<<"$(_remote_script)"
}

_run_local() {
  LIVE_LOGS_TARGET=local MODE="$MODE" KEEP="$KEEP" MGMT_KEY="$MGMT_KEY" \
    bash -c "$(_remote_script)" _ "$MODE" "$KEEP" "$MGMT_KEY"
}

case "$TARGET" in
  local) _run_local ;;
  remote) _run_remote ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
