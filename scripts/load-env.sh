#!/usr/bin/env bash
# Source repo .env (expands $HOME in values when needed).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${CCPROXY_ENV_FILE:-${ROOT}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "WARN: missing ${ENV_FILE} — copy from .env.example" >&2
  return 0 2>/dev/null || exit 0
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
