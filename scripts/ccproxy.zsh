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
alias ccr='ccproxy relogin'     # Claude OAuth login / re-login
alias ccd='ccproxy deploy'      # redeploy VPS
alias ccu='ccproxy url'         # print Cursor base URL
alias cce='ccproxy env'         # show settings
alias cca='ccproxy accounts'    # Claude account status
alias ccst='ccproxy stats'      # token usage + Claude plan limits
alias ccl='ccproxy live'        # live request logs + prompts
alias ccpause='ccproxy pause'   # exclude account from round-robin
alias ccresume='ccproxy resume' # put account back in round-robin
alias cccodex='ccproxy codex'   # Codex helpers (helper model / config)

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
      'accounts:Claude account status'
      'pause:Exclude account from round-robin'
      'resume:Put account back in round-robin'
      'limits:Claude plan limits per account'
      'models:List model aliases'
      'add-model:Add a model alias'
      'remove-model:Remove a model alias'
      'codex:Codex helper model + config'
      'stats:Day-wise token usage per user'
      'live:Live request logs with prompts'
      'logs:Docker stdout logs on VPS'
      'ssh:SSH to VPS'
      'restart:Restart VPS stack'
      'help:Show help'
    )
    _describe 'ccproxy command' cmds
  }
  compdef _ccproxy_commands ccproxy ccp 2>/dev/null || true
fi
