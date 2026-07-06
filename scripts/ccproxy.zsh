# ccproxy zsh shortcuts — source from ~/.zshrc (see scripts/install-shell.sh)
[[ -n "${CCPROXY_HOME:-}" ]] || export CCPROXY_HOME="${HOME}/ProjectsRepo/ccproxy"

if [[ ! -x "${CCPROXY_HOME}/bin/ccproxy" ]]; then
  # Fallback if repo moved: use PATH binary
  if ! command -v ccproxy >/dev/null 2>&1; then
    return 0
  fi
fi

# Main CLI (on PATH via ~/.local/bin/ccproxy)
alias ccp='ccproxy'

# Daily shortcuts
alias cch='ccproxy health'      # health check
alias ccs='ccproxy status'      # auth + API status
alias ccr='ccproxy relogin'     # Claude OAuth re-login
alias ccd='ccproxy deploy'      # redeploy VPS
alias ccu='ccproxy url'         # print Cursor base URL
alias cce='ccproxy env'         # show settings
alias ccst='ccproxy stats'      # token usage per user

# Optional: tab-complete subcommands
if [[ -n "${ZSH_VERSION:-}" ]] && command -v compdef >/dev/null 2>&1; then
  _ccproxy_commands() {
    local -a cmds
    cmds=(
      'health:Test models + chat'
      'status:Auth files + health on VPS'
      'relogin:Claude OAuth on VPS'
      'copy-auth:Copy token from Mac'
      'deploy:Redeploy to VPS'
      'build:Build Docker images'
      'url:Print Cursor base URL'
      'env:Show key settings'
      'stats:Day-wise token usage per user'
      'ssh:SSH to VPS'
      'logs:Docker logs on VPS'
      'restart:Restart VPS stack'
      'help:Show help'
    )
    _describe 'ccproxy command' cmds
  }
  compdef _ccproxy_commands ccproxy ccp 2>/dev/null || true
fi
