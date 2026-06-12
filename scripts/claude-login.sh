#!/usr/bin/env bash
# Run Claude OAuth inside the cli-proxy-api container (copy URL → browser → paste code).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

echo "==> Claude OAuth login (CLIProxyAPI container)"
echo "    Open the URL in your browser, sign in, paste the code back."
echo ""

docker compose exec -it cli-proxy-api \
  /CLIProxyAPI/CLIProxyAPI \
  -config /CLIProxyAPI/config.yaml \
  -no-browser \
  --claude-login

echo ""
echo "==> Restarting stack to pick up fresh tokens..."
docker compose restart cli-proxy-api cursor-shim
