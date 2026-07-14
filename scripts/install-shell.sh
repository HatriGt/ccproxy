#!/usr/bin/env bash
# Install ccproxy CLI on PATH + zsh shortcuts in ~/.zshrc
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN_DIR="${HOME}/.local/bin"
ZSHRC="${HOME}/.zshrc"
MARKER="# ccproxy CLI"

chmod +x "${ROOT}/bin/ccproxy"

mkdir -p "$BIN_DIR"
ln -sf "${ROOT}/bin/ccproxy" "${BIN_DIR}/ccproxy"
echo "==> Linked ${BIN_DIR}/ccproxy → ${ROOT}/bin/ccproxy"

BLOCK=$(cat <<EOF

${MARKER}
export CCPROXY_HOME="${ROOT}"
[[ -f "\$CCPROXY_HOME/scripts/ccproxy.zsh" ]] && source "\$CCPROXY_HOME/scripts/ccproxy.zsh"
EOF
)

if [[ -f "$ZSHRC" ]] && grep -qF "$MARKER" "$ZSHRC"; then
  echo "==> ~/.zshrc already has ccproxy block"
else
  printf '%s\n' "$BLOCK" >>"$ZSHRC"
  echo "==> Appended ccproxy block to ~/.zshrc"
fi

echo ""
echo "Done. Open a new terminal or run:"
echo "  source ~/.zshrc"
echo ""
echo "Shortcuts:"
echo "  cch    health check"
echo "  ccs    status"
echo "  ccr    relogin"
echo "  ccd    deploy"
echo "  ccu    print Cursor URL"
echo "  ccpause / ccresume  round-robin pause"
echo "  ccproxy help"
