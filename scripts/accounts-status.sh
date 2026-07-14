#!/usr/bin/env bash
# Show Claude OAuth account status (active / expired / needs re-login) on the VPS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

TARGET="${ACCOUNTS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

# Remote-side script: find the api container, read each claude-*.json, and print
# a status line per account (parsed on-VPS to avoid shipping token files around).
_remote() {
  cat <<'REMOTE'
set -euo pipefail
api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
if [[ -z "$api" ]]; then
  echo "ERROR: cli-proxy-api container not found." >&2
  exit 1
fi
files=$(docker exec "$api" sh -c 'ls /data/auth/claude-*.json 2>/dev/null' || true)
if [[ -z "$files" ]]; then
  echo "No Claude auth files found in /data/auth."
  exit 0
fi
for path in $files; do
  docker exec "$api" cat "$path" 2>/dev/null
  echo "@@SEP@@"
done
REMOTE
}

_render() {
  # Buffer stdin to a temp file, then run the parser via a heredoc (keeps
  # single quotes usable in the Python without clashing with -c quoting).
  local tmp
  tmp="$(mktemp)"
  cat > "$tmp"
  ACCT_DATA_FILE="$tmp" python3 <<'PY'
import os, sys, json, datetime

now = datetime.datetime.now(datetime.timezone.utc)
with open(os.environ["ACCT_DATA_FILE"]) as fh:
    raw = fh.read()
blobs = [b.strip() for b in raw.split("@@SEP@@") if b.strip()]

rows = []
for b in blobs:
    try:
        d = json.loads(b)
    except Exception:
        continue
    email = d.get("email", "?")
    disabled = bool(d.get("disabled", False))
    exp = d.get("expired") or d.get("expires_at")
    last = d.get("last_refresh", "-")
    mins = None
    if exp:
        try:
            e = datetime.datetime.fromisoformat(exp)
            mins = (e - now).total_seconds() / 60
        except Exception:
            pass
    rows.append((email, disabled, mins, last))

if not rows:
    print("No parseable Claude accounts.")
    sys.exit(0)

def status(disabled, mins):
    # disabled = manually paused from round-robin (ccproxy pause), not OAuth failure
    if disabled:
        return "PAUSED     ", "excluded from round-robin"
    if mins is None:
        return "UNKNOWN    ", "check manually"
    if mins < 0:
        return "EXPIRED    ", "needs re-login"
    if mins < 30:
        return "EXPIRING   ", "refresh soon"
    return "ACTIVE     ", "in round-robin"

def human_mins(mins):
    if mins is None:
        return "-"
    if mins < 0:
        h = -mins / 60
        return f"expired {h:.0f}h ago" if h >= 1 else f"expired {-mins:.0f}m ago"
    if mins < 60:
        return f"{mins:.0f}m left"
    return f"{mins/60:.1f}h left"

print(f"{'ACCOUNT':<34} {'STATUS':<11} {'TOKEN':<18} {'ACTION'}")
print("-" * 82)
need = []
paused = []
for email, disabled, mins, last in sorted(rows):
    st, action = status(disabled, mins)
    if action == "needs re-login":
        need.append(email)
    if disabled:
        paused.append(email)
    print(f"{email:<34} {st:<11} {human_mins(mins):<18} {action}")
print("-" * 82)
print("TOKEN = OAuth access-token TTL (~8h, auto-refreshed). Not plan usage. Relogin only if EXPIRED.")
if paused:
    print("\n⏸  Paused (not used in round-robin): " + ", ".join(paused))
    print("   Resume:  ccproxy resume <email-or-substring>")
if need:
    print("\n⚠️  Needs re-login: " + ", ".join(need))
    print("   Run:  ccproxy relogin   (interactive Claude OAuth on the VPS)")
elif not paused:
    print("\n✅ All accounts active in round-robin.")
elif not need:
    print("\n✅ Token OK on remaining accounts.")
PY
  rm -f "$tmp"
}

echo "==> Claude accounts (${TARGET})"
echo ""

case "$TARGET" in
  remote) ssh -o LogLevel=ERROR "$VPS_HOST" "bash -s" <<<"$(_remote)" | _render ;;
  local)  bash -c "$(_remote)" | _render ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
