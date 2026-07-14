#!/usr/bin/env bash
# Codex-specific ccproxy commands (desktop + CLI via same public /v1).
#
# Usage:
#   ccproxy codex                              # help
#   ccproxy codex helper-model                 # show OpenAI helper → Claude mapping
#   ccproxy codex helper-model <alias|upstream># set helper model (restarts api)
#   ccproxy codex helpers                      # list OpenAI IDs that get remapped
#   ccproxy codex config                       # print ~/.codex setup (desktop + CLI)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"
BASE_URL="${CURSOR_BASE_URL:-https://${PUBLIC_HOSTNAME:-cliproxy.yourdomain.com}/v1}"
BASE_URL="${BASE_URL%/}"
API_KEY="${CLIPROXY_API_KEY:-dummy}"

# Codex Desktop side-calls these even when main model is ak-claude-*.
HELPER_OPENAI_IDS=(
  gpt-5.4-mini
  gpt-5.4
  gpt-5.5-mini
  gpt-5-mini
  gpt-4.1-mini
  gpt-4o-mini
  o4-mini
  o3-mini
)

DEFAULT_HELPER_ALIAS="ak-claude-haiku-4.5"

usage() {
  cat <<EOF
ccproxy codex — Codex desktop/CLI helpers for this proxy

Usage: ccproxy codex <subcommand>

Subcommands:
  helper-model [model]  Show or set Claude model used for OpenAI helper IDs
                        (gpt-5.4-mini, o4-mini, …). Default: ${DEFAULT_HELPER_ALIAS}
  helpers               List OpenAI/Codex helper IDs that get remapped
  config                Print ~/.codex config for same endpoint as Cursor
  help                  This help

Examples:
  ccproxy codex helper-model
  ccproxy codex helper-model ak-claude-haiku-4.5
  ccproxy codex helper-model ak-claude-sonnet-4.6
  ccproxy codex helpers
  ccproxy codex config

Cursor/Codex share: ${BASE_URL}
EOF
}

_helper_ids() {
  echo "OpenAI / Codex helper IDs remapped by \`ccproxy codex helper-model\`:"
  for id in "${HELPER_OPENAI_IDS[@]}"; do
    echo "  $id"
  done
}

_helper_remote() {
  local target="${1:-}"
  local ids_b64 target_b64 default_b64
  ids_b64=$(printf '%s\n' "${HELPER_OPENAI_IDS[@]}" | base64 | tr -d '\n')
  target_b64=$(printf '%s' "$target" | base64 | tr -d '\n')
  default_b64=$(printf '%s' "$DEFAULT_HELPER_ALIAS" | base64 | tr -d '\n')

  ssh -o LogLevel=ERROR "$VPS_HOST" \
    IDS_B64="$ids_b64" TARGET_B64="$target_b64" DEFAULT_B64="$default_b64" \
    'bash -s' <<'REMOTE'
set -euo pipefail
IDS=$(printf '%s' "$IDS_B64" | base64 -d)
TARGET=$(printf '%s' "${TARGET_B64:-}" | base64 -d)
DEFAULT_ALIAS=$(printf '%s' "$DEFAULT_B64" | base64 -d)

api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
if [ -z "$api" ]; then echo "ERROR: api container not found." >&2; exit 1; fi
vol=$(docker inspect "$api" --format '{{range .Mounts}}{{if eq .Destination "/data/models"}}{{.Name}}{{end}}{{end}}')
if [ -z "$vol" ]; then echo "ERROR: cliproxy-models volume not found." >&2; exit 1; fi
mp=$(docker volume inspect "$vol" --format '{{.Mountpoint}}')
store="$mp/aliases.yaml"
meta="$mp/codex-helper.yaml"
# legacy name from earlier fallback-model command
legacy="$mp/fallback.yaml"
mkdir -p "$mp"
touch "$store"
if [ ! -f "$meta" ] && [ -f "$legacy" ]; then
  cp "$legacy" "$meta"
fi

_resolve_upstream() {
  local want="$1" upstream=""
  upstream=$(awk -v a="$want" '
    $1=="-" && $2=="alias:" && $3==a { want=1; next }
    want && $1=="name:" { print $2; exit }
  ' "$store")
  if [ -n "$upstream" ]; then
    echo "$upstream"
    return 0
  fi
  case "$want" in
    claude-*) echo "$want"; return 0 ;;
  esac
  echo ""
  return 1
}

_drop_alias() {
  awk -v a="$1" '
    $1=="-" && $2=="alias:" && $3==a { skip_name=1; next }
    skip_name && $1=="name:" { skip_name=0; next }
    { print }
  ' "$store" > "$store.tmp" && mv "$store.tmp" "$store"
}

_show() {
  echo "Codex helper model (OpenAI side-call IDs → Claude)"
  echo ""
  if [ -f "$meta" ]; then
    echo "State:"
    cat "$meta"
    echo ""
  else
    echo "(not set yet — run: ccproxy codex helper-model ${DEFAULT_ALIAS})"
    echo ""
  fi
  echo "Mapped helper IDs:"
  while IFS= read -r id; do
    [ -z "$id" ] && continue
    name=$(awk -v a="$id" '
      $1=="-" && $2=="alias:" && $3==a { want=1; next }
      want && $1=="name:" { print $2; exit }
    ' "$store")
    if [ -n "$name" ]; then
      printf "  %-18s -> %s\n" "$id" "$name"
    else
      printf "  %-18s -> (not mapped)\n" "$id"
    fi
  done <<EOF
$IDS
EOF
}

if [ -z "$TARGET" ]; then
  _show
  exit 0
fi

upstream=$(_resolve_upstream "$TARGET" || true)
if [ -z "$upstream" ]; then
  echo "ERROR: cannot resolve helper model '$TARGET'." >&2
  echo "Use an existing alias (e.g. $DEFAULT_ALIAS) or a claude-* upstream id." >&2
  echo "See: ccproxy models" >&2
  exit 2
fi

echo "Helper model: $TARGET"
echo "Upstream:     $upstream"
echo "Remapping Codex OpenAI helper IDs…"

while IFS= read -r id; do
  [ -z "$id" ] && continue
  _drop_alias "$id"
  printf -- "- alias: %s\n  name: %s\n" "$id" "$upstream" >> "$store"
  printf "  %s -> %s\n" "$id" "$upstream"
done <<EOF
$IDS
EOF

cat > "$meta" <<EOF
# Managed by: ccproxy codex helper-model
# Last updated: $(date -u +%Y-%m-%dT%H:%M:%SZ)
helper: $TARGET
upstream: $upstream
EOF
# keep legacy filename in sync if present from older installs
cp "$meta" "$legacy" 2>/dev/null || true

docker restart "$api" >/dev/null
echo "Restarted $api."
echo ""
_show
REMOTE
}

_config_print() {
  cat <<EOF
# Codex — same public endpoint as Cursor (${BASE_URL})
# Desktop: set these in ~/.codex/config.toml then quit & reopen Codex
# CLI:     codex -p ccproxy   (uses ~/.codex/ccproxy.config.toml)

model = "ak-claude-opus-4.8"
model_provider = "ccproxy"

[model_providers.ccproxy]
name = "ccproxy"
base_url = "${BASE_URL}"
wire_api = "responses"
requires_openai_auth = true
supports_websockets = false
experimental_bearer_token = "${API_KEY}"

# Helper side-calls (gpt-5.4-mini, …) are remapped server-side:
#   ccproxy codex helper-model
#   ccproxy codex helper-model ak-claude-haiku-4.5
#
# Switch back to ChatGPT GPT models (CLI):
#   codex -p chatgpt
EOF
}

sub="${1:-help}"
shift || true

case "$sub" in
  help|-h|--help)
    usage
    ;;
  helper-model)
    _helper_remote "${1:-}"
    ;;
  helpers|helper-ids)
    _helper_ids
    ;;
  config|cfg)
    _config_print
    ;;
  *)
    echo "Unknown: ccproxy codex ${sub}" >&2
    echo "" >&2
    usage >&2
    exit 2
    ;;
esac
