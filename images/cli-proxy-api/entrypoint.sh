#!/bin/sh
# Render config.yaml from the env-templated version, then start CLIProxyAPI.
# Logging/telemetry knobs are driven by .env so they can be toggled without
# editing config files (request/file logs eat disk, so they default OFF).
set -e

# Defaults (space-saving): only usage-statistics stays on for token tracking.
export CCPROXY_DEBUG="${CCPROXY_DEBUG:-false}"
export CCPROXY_LOGGING_TO_FILE="${CCPROXY_LOGGING_TO_FILE:-false}"
export CCPROXY_REQUEST_LOG="${CCPROXY_REQUEST_LOG:-false}"
export CCPROXY_USAGE_STATS="${CCPROXY_USAGE_STATS:-true}"

# Remote management: needed so the usage-tracker sidecar can read the queue.
# Falls back to CLIPROXY_MGMT_KEY (the existing plaintext mgmt key) if a
# dedicated secret wasn't provided; it is bcrypt-hashed by the app on startup.
export CCPROXY_ALLOW_REMOTE_MGMT="${CCPROXY_ALLOW_REMOTE_MGMT:-true}"
export CCPROXY_MGMT_SECRET_KEY="${CCPROXY_MGMT_SECRET_KEY:-${CLIPROXY_MGMT_KEY:-}}"

TEMPLATE="/CLIProxyAPI/config.yaml.template"
TARGET="/CLIProxyAPI/config.yaml"

# Persistent model aliases (survive redeploys). Seed from the baked default on
# first start; thereafter managed live via `ccproxy add-model`/`remove-model`.
ALIAS_STORE="/data/models/aliases.yaml"
ALIAS_DEFAULT="/CLIProxyAPI/model-aliases.default.yaml"
mkdir -p /data/models
if [ ! -s "$ALIAS_STORE" ] && [ -f "$ALIAS_DEFAULT" ]; then
  cp "$ALIAS_DEFAULT" "$ALIAS_STORE"
  echo "[entrypoint] seeded model aliases -> $ALIAS_STORE"
fi

if [ -f "$TEMPLATE" ]; then
  # Substitute only our known vars (avoid clobbering other ${...} in the file).
  sed \
    -e "s|\${CCPROXY_DEBUG}|${CCPROXY_DEBUG}|g" \
    -e "s|\${CCPROXY_LOGGING_TO_FILE}|${CCPROXY_LOGGING_TO_FILE}|g" \
    -e "s|\${CCPROXY_REQUEST_LOG}|${CCPROXY_REQUEST_LOG}|g" \
    -e "s|\${CCPROXY_USAGE_STATS}|${CCPROXY_USAGE_STATS}|g" \
    -e "s|\${CCPROXY_ALLOW_REMOTE_MGMT}|${CCPROXY_ALLOW_REMOTE_MGMT}|g" \
    -e "s|\${CCPROXY_MGMT_SECRET_KEY}|${CCPROXY_MGMT_SECRET_KEY}|g" \
    "$TEMPLATE" > "$TARGET"

  # Inject the alias list under oauth-model-alias.claude, indented 4 spaces.
  if [ -s "$ALIAS_STORE" ]; then
    # Build an indented copy, then splice it in at the placeholder with sed's
    # `r` (read file) command (portable; no multi-line awk var).
    indented="/tmp/aliases.indented"
    sed 's/^/    /' "$ALIAS_STORE" > "$indented"
    sed -e "/@@MODEL_ALIASES@@/r $indented" -e "/@@MODEL_ALIASES@@/d" "$TARGET" > "${TARGET}.tmp"
    mv "${TARGET}.tmp" "$TARGET"
    rm -f "$indented"
    alias_count=$(grep -c 'alias:' "$ALIAS_STORE" 2>/dev/null || echo 0)
    echo "[entrypoint] injected ${alias_count} model alias(es) from $ALIAS_STORE"
  else
    # No aliases: drop the placeholder line so YAML stays valid.
    sed -i '/@@MODEL_ALIASES@@/d' "$TARGET"
  fi

  echo "[entrypoint] config rendered: debug=${CCPROXY_DEBUG} logging-to-file=${CCPROXY_LOGGING_TO_FILE} request-log=${CCPROXY_REQUEST_LOG} usage-statistics=${CCPROXY_USAGE_STATS}"
else
  echo "[entrypoint] WARN: template not found, using existing config.yaml"
fi

exec ./CLIProxyAPI
