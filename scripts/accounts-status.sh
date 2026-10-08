#!/usr/bin/env bash
# Show Claude OAuth account status (active / expired / needs re-login) on the VPS.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

# Disambiguates the api/shim container when several compose stacks exist.
export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

TARGET="${ACCOUNTS_TARGET:-remote}"
VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

# Remote-side script: find the api container, read each claude-*.json, and print
# a status line per account (parsed on-VPS to avoid shipping token files around).
_remote() {
  cat <<'REMOTE'
set -euo pipefail
if [ -n "${CCPROXY_PROJECT:-}" ]; then
  # Pin to the compose project — several stacks can match the name grep.
  api=$(docker ps --filter "label=com.docker.compose.project=${CCPROXY_PROJECT}" \
        --format '{{.Names}}' | grep -E 'cli-proxy-api' | head -1)
else
  api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
fi
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
# Auto-HOLD emails (5h guard) — separate from manual pause.
if [ -n "${CCPROXY_PROJECT:-}" ]; then
  tracker=$(docker ps --filter "label=com.docker.compose.project=${CCPROXY_PROJECT}" \
            --format '{{.Names}}' | grep -E 'usage-tracker' | head -1)
else
  tracker=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*usage-tracker' | head -1)
fi
echo "@@GUARD@@"
if [[ -n "${tracker:-}" ]]; then
  docker exec "$tracker" python3 -c 'import json,os,sqlite3
db=os.environ.get("USAGE_DB_PATH","/data/usage/usage.db")
try:
 c=sqlite3.connect(db)
 rows=c.execute("SELECT email,enabled,auto_held FROM account_guard").fetchall()
 print(json.dumps([{"email":r[0],"enabled":bool(r[1]),"auto_held":bool(r[2])} for r in rows]))
except Exception:
 print("[]")'
else
  echo "[]"
fi
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
parts = raw.split("@@GUARD@@", 1)
auth_raw = parts[0]
guard_map = {}
if len(parts) > 1:
    try:
        for g in json.loads(parts[1].strip() or "[]"):
            guard_map[(g.get("email") or "").lower()] = g
    except Exception:
        pass
blobs = [b.strip() for b in auth_raw.split("@@SEP@@") if b.strip()]

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
    g = guard_map.get(email.lower(), {})
    rows.append((email, disabled, mins, last, bool(g.get("auto_held")), bool(g.get("enabled"))))

if not rows:
    print("No parseable Claude accounts.")
    sys.exit(0)

def status(disabled, mins, auto_held):
    # HOLD = temporary 5h auto-exclude (guard). PAUSED = manual high-level gate.
    if auto_held:
        return "HOLD       ", "5h limit auto-hold (guard)"
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

def token_group(mins):
    # Valid tokens first, unknown middle, expired last; email tie-break.
    if mins is None:
        return 1
    if mins < 0:
        return 2
    return 0

print(f"{'ACCOUNT':<34} {'STATUS':<11} {'TOKEN':<18} {'ACTION'}")
print("-" * 82)
need = []
paused = []
held = []
guarded = []
for email, disabled, mins, last, auto_held, guard_on in sorted(
    rows, key=lambda r: (token_group(r[2]), (r[0] or "").lower())
):
    st, action = status(disabled, mins, auto_held)
    if action == "needs re-login":
        need.append(email)
    if auto_held:
        held.append(email)
    elif disabled:
        paused.append(email)
    if guard_on:
        guarded.append(email)
    print(f"{email:<34} {st:<11} {human_mins(mins):<18} {action}")
print("-" * 82)
print("TOKEN = OAuth access-token TTL (~8h, auto-refreshed). Not plan usage. Relogin only if EXPIRED.")
print("HOLD = temporary 5h auto-exclude (ccproxy guard). PAUSED = manual gate (ccproxy pause).")
if guarded:
    print("\n🛡  Guard ON (auto-HOLD at 5h≥92%): " + ", ".join(guarded))
if held:
    print("\n⏳ Auto-HOLD (back when 5h resets): " + ", ".join(held))
if paused:
    print("\n⏸  Paused (not used in round-robin): " + ", ".join(paused))
    print("   Resume:  ccproxy resume <email-or-substring>")
if need:
    print("\n⚠️  Needs re-login: " + ", ".join(need))
    print("   Run:  ccproxy relogin   (interactive Claude OAuth on the VPS)")
elif not paused and not held:
    print("\n✅ All accounts active in round-robin.")
elif not need:
    print("\n✅ Token OK on remaining accounts.")
PY
  rm -f "$tmp"
}

echo "==> Claude accounts (${TARGET})"
echo ""

case "$TARGET" in
  remote) ssh -o LogLevel=ERROR "$VPS_HOST" "CCPROXY_PROJECT='$CCPROXY_PROJECT' bash -s" <<<"$(_remote)" | _render ;;
  local)  bash -c "$(_remote)" | _render ;;
  *) echo "Unknown target: $TARGET" >&2; exit 2 ;;
esac
