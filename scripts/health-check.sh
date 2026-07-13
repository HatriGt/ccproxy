#!/usr/bin/env bash
# End-to-end health check: /v1/models + /v1/chat/completions
# Exit: 0=OK, 1=auth needed, 2=other failure
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

BASE="${1:-${CURSOR_BASE_URL:-http://127.0.0.1:8320/v1}}"
API_KEY="${CLIPROXY_API_KEY:-dummy}"
TEST_MODEL="${CLIPROXY_TEST_MODEL:-ak-claude-sonnet-4.6}"

BASE="${BASE%/}"
[[ "$BASE" == */v1 ]] || BASE="${BASE}/v1"

fail() {
  echo "FAIL: $*" >&2
  exit 2
}

# Optional retries (used after container restart to avoid race).
RETRIES="${CLIPROXY_TEST_RETRIES:-1}"
RETRY_SECS="${CLIPROXY_TEST_RETRY_SECS:-2}"

echo "==> Testing ${BASE}"
echo "    [1/2] GET /v1/models ..."

MODELS=""
models_ok=0
for attempt in $(seq 1 "$RETRIES"); do
  if MODELS=$(curl -fsS -m 30 "${BASE}/models" -H "Authorization: Bearer ${API_KEY}" 2>&1); then
    models_ok=1
    break
  fi
  if [ "$attempt" -lt "$RETRIES" ]; then
    sleep "$RETRY_SECS"
  fi
done
[ "$models_ok" = "1" ] || fail "models: ${MODELS}"

if echo "$MODELS" | grep -q 'auth_unavailable'; then
  echo "AUTH: models endpoint reports auth_unavailable" >&2
  exit 1
fi

if ! echo "$MODELS" | grep -q 'ak-claude'; then
  fail "models list missing ak-claude aliases"
fi

echo "OK: /v1/models"
echo "    [2/2] POST /v1/chat/completions ..."

CHAT=$(curl -fsS -m 60 "${BASE}/chat/completions" \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"say ok\"}],\"max_tokens\":10}" 2>&1) || {
  if echo "$CHAT" | grep -qE 'auth_unavailable|authentication_error'; then
    echo "AUTH: chat endpoint reports auth_unavailable" >&2
    exit 1
  fi
  fail "chat: ${CHAT}"
}

if echo "$CHAT" | grep -q '"choices"'; then
  PREVIEW=$(echo "$CHAT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('content','')[:80])" 2>/dev/null || echo ok)
  echo "OK: /v1/chat/completions → ${PREVIEW}"
  exit 0
fi

echo "$CHAT" | head -c 400 >&2
fail "unexpected chat response"
