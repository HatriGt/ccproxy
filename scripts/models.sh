#!/usr/bin/env bash
# Manage Claude model aliases live on the VPS (persistent volume, survives
# redeploys). Edits the alias store on the volume's host mountpoint, then
# restarts the api container to apply.
#
# Usage:
#   models.sh list                         # show current aliases
#   models.sh add <alias> <upstream-name>  # add/update an alias, restart api
#   models.sh remove <alias>               # remove an alias, restart api
#
# Upstream name may include a thinking/effort suffix, e.g.:
#   models.sh add ak-claude-opus-4.8-low 'claude-opus-4-8(low)'
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

sub="${1:-list}"
shift || true

# Remote helper: locates the api container + its model volume mountpoint, then
# runs the requested action. Args: <action> [alias] [name]
# Values are base64-encoded so parentheses in names (effort suffixes) survive SSH.
_remote() {
  local action="$1" alias="${2:-}" name="${3:-}"
  local action_b64 alias_b64 name_b64
  action_b64=$(printf '%s' "$action" | base64 | tr -d '\n')
  alias_b64=$(printf '%s' "$alias" | base64 | tr -d '\n')
  name_b64=$(printf '%s' "$name" | base64 | tr -d '\n')
  ssh -o LogLevel=ERROR "$VPS_HOST" \
    ACTION_B64="$action_b64" ALIAS_B64="$alias_b64" NAME_B64="$name_b64" \
    'bash -s' <<'REMOTE'
set -euo pipefail
ACTION=$(printf '%s' "$ACTION_B64" | base64 -d)
ALIAS=$(printf '%s' "${ALIAS_B64:-}" | base64 -d)
NAME=$(printf '%s' "${NAME_B64:-}" | base64 -d)

api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
if [ -z "$api" ]; then echo "ERROR: api container not found." >&2; exit 1; fi
vol=$(docker inspect "$api" --format '{{range .Mounts}}{{if eq .Destination "/data/models"}}{{.Name}}{{end}}{{end}}')
if [ -z "$vol" ]; then echo "ERROR: cliproxy-models volume not found (redeploy needed)." >&2; exit 1; fi
mp=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')
store="$mp/aliases.yaml"
mkdir -p "$mp"; touch "$store"

# Drop a matching alias block (alias line + following name line only).
_drop_alias() {
  awk -v a="$1" '
    $1=="-" && $2=="alias:" && $3==a { skip_name=1; next }
    skip_name && $1=="name:" { skip_name=0; next }
    { print }
  ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
}

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
    _drop_alias "$ALIAS"
    printf -- "- alias: %s\n  name: %s\n" "$ALIAS" "$NAME" >> "$store"
    echo "Added/updated: $ALIAS -> $NAME"
    docker restart "$api" >/dev/null
    echo "Restarted $api."
    ;;
  remove)
    if [ -z "$ALIAS" ]; then echo "ERROR: alias required." >&2; exit 2; fi
    _drop_alias "$ALIAS"
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
      echo "Effort:  ccproxy add-model ak-claude-opus-4.9-low claude-opus-4-9" >&2
      echo "         (alias suffix -low/-medium/-high auto-sets output_config.effort)" >&2
      exit 2
    fi
    case "$alias" in
      *-low|*-medium|*-high)
        if [[ "$name" == *'('* ]]; then
          echo "ERROR: do not put (effort) in the upstream name; use a plain model id." >&2
          echo "  right: ccproxy add-model ${alias} claude-opus-4-9" >&2
          echo "  wrong: ccproxy add-model ${alias} 'claude-opus-4-9(low)'" >&2
          exit 2
        fi
        ;;
    esac
    _remote add "$alias" "$name"
    echo "==> Verify: ccproxy models   (and check https://<host>/v1/models)"
    case "$alias" in
      *-low)    echo "==> Effort: low (ak-claude-*-low wildcard)" ;;
      *-medium) echo "==> Effort: medium (ak-claude-*-medium wildcard)" ;;
      *-high)   echo "==> Effort: high (ak-claude-*-high wildcard)" ;;
    esac
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
