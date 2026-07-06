#!/usr/bin/env bash
# Manage Claude model aliases live on the VPS (persistent volume, survives
# redeploys). Edits the alias store on the volume's host mountpoint, then
# restarts the api container to apply.
#
# Usage:
#   models.sh list                         # show current aliases
#   models.sh add <alias> <upstream-name>  # add/update an alias, restart api
#   models.sh remove <alias>               # remove an alias, restart api
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

sub="${1:-list}"
shift || true

# Remote helper: locates the api container + its model volume mountpoint, then
# runs the requested action. Args: <action> [alias] [name]
_remote() {
  ssh -o LogLevel=ERROR "$VPS_HOST" ACTION="$1" ALIAS="${2:-}" NAME="${3:-}" 'bash -s' <<'REMOTE'
set -euo pipefail
api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
if [ -z "$api" ]; then echo "ERROR: api container not found." >&2; exit 1; fi
vol=$(docker inspect "$api" --format '{{range .Mounts}}{{if eq .Destination "/data/models"}}{{.Name}}{{end}}{{end}}')
if [ -z "$vol" ]; then echo "ERROR: cliproxy-models volume not found (redeploy needed)." >&2; exit 1; fi
mp=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')
store="$mp/aliases.yaml"
mkdir -p "$mp"; touch "$store"

case "$ACTION" in
  list)
    echo "Current model aliases:"
    echo ""
    awk '/alias:/{a=$3} /name:/{printf "  %-30s -> %s\n", a, $2}' "$store"
    [ -s "$store" ] || echo "  (none)"
    ;;
  add)
    if [ -z "$ALIAS" ] || [ -z "$NAME" ]; then
      echo "ERROR: alias and name required." >&2; exit 2
    fi
    # Drop any existing 2-line block for this alias, then append fresh.
    awk -v a="$ALIAS" '
      $1=="-" && $2=="alias:" && $3==a { skip=2; next }
      skip>0 { skip--; next }
      { print }
    ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
    printf -- "- alias: %s\n  name: %s\n" "$ALIAS" "$NAME" >> "$store"
    echo "Added/updated: $ALIAS -> $NAME"
    docker restart "$api" >/dev/null
    echo "Restarted $api."
    ;;
  remove)
    if [ -z "$ALIAS" ]; then echo "ERROR: alias required." >&2; exit 2; fi
    awk -v a="$ALIAS" '
      $1=="-" && $2=="alias:" && $3==a { skip=2; next }
      skip>0 { skip--; next }
      { print }
    ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
    echo "Removed: $ALIAS"
    docker restart "$api" >/dev/null
    echo "Restarted $api."
    ;;
esac
REMOTE
}

case "$sub" in
  list|ls)
    _remote list
    ;;
  add)
    alias="${1:-}"; name="${2:-}"
    if [ -z "$alias" ] || [ -z "$name" ]; then
      echo "Usage: ccproxy add-model <alias> <upstream-model-name>" >&2
      echo "Example: ccproxy add-model ak-claude-opus-4.9 claude-opus-4-9" >&2
      exit 2
    fi
    _remote add "$alias" "$name"
    echo "==> Verify: ccproxy models   (and check https://<host>/v1/models)"
    ;;
  remove|rm)
    alias="${1:-}"
    if [ -z "$alias" ]; then echo "Usage: ccproxy remove-model <alias>" >&2; exit 2; fi
    _remote remove "$alias"
    echo "==> Verify: ccproxy models"
    ;;
  *)
    echo "Usage: ccproxy models | add-model <alias> <name> | remove-model <alias>" >&2
    exit 2
    ;;
esac
