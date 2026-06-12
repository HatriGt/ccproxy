#!/usr/bin/env bash
# Source repo .env from bash or zsh:
#   source scripts/load-env.sh
#
# Does not enable set -u/set -e in your interactive shell (safe to source in zsh).

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _ccproxy_script_dir="$(cd "$(dirname "${(%):-%x}")" && pwd)"
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _ccproxy_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _ccproxy_script_dir="$(cd "$(dirname "$0")" && pwd)"
fi

ROOT="$(cd "${_ccproxy_script_dir}/.." && pwd)"
ENV_FILE="${CCPROXY_ENV_FILE:-${ROOT}/.env}"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "WARN: missing ${ENV_FILE} — copy from .env.example" >&2
  return 0 2>/dev/null || exit 0
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

unset _ccproxy_script_dir
