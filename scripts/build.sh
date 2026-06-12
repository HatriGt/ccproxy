#!/usr/bin/env bash
# Build ccproxy Docker images (cli-proxy-api + cursor-shim).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

echo "==> Building ccproxy images..."
docker compose build

echo ""
echo "Built:"
docker images --format '  {{.Repository}}:{{.Tag}}' | grep -E 'ccproxy-' || docker compose images
