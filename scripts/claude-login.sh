#!/usr/bin/env bash
# Alias for claude-relogin.sh — login and relogin are the same OAuth flow.
set -euo pipefail
exec "$(cd "$(dirname "$0")" && pwd)/claude-relogin.sh" login "$@"
