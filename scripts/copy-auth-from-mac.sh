#!/usr/bin/env bash
# Copy working Claude OAuth token(s) from Mac ~/.cli-proxy-api into VPS docker volume.
#
# Relogins happen on the VPS (`ccproxy relogin`), so the VPS — not the Mac — is
# the source of truth for auth. This step exists to seed a fresh volume, not to
# push the Mac's copy over a newer one. It therefore skips a file when:
#
#   * the Mac token has already expired, or
#   * the VPS already holds a credential for that email with a newer refresh.
#
# It also matches on the email inside the file rather than the filename, because
# CLIProxyAPI >= v7.3 writes new records as claude-<account-uuid>-<email>.json
# while refreshing pre-existing records in place under their original name. A
# filename-only copy therefore lands a second file for an account that already
# has one, and `ccproxy accounts` then reports the same address twice.
#
# Usage:
#   copy-auth-from-mac.sh            # skip stale / superseded files
#   copy-auth-from-mac.sh --force    # copy everything (deliberate restore)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

# Disambiguates the api container when several compose stacks exist.
export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-akvps}}"
REMOTE_DIR="${VPS_DEPLOY_DIR:-/opt/ccproxy}"
AUTH_DIR="${CLIPROXY_AUTH_DIR:-${HOME}/.cli-proxy-api}"

FORCE=0
[[ "${1:-}" == "--force" ]] && FORCE=1

shopt -s nullglob
FILES=("${AUTH_DIR}"/claude-*.json)
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "ERROR: No claude-*.json in ${AUTH_DIR}" >&2
  exit 1
fi

# Remote inventory: one "path|email|last_refresh|expired" line per stored
# credential. Deliberately prints no token material.
_vps_inventory() {
  ssh -o LogLevel=ERROR "$VPS_HOST" \
    CCPROXY_PROJECT="$CCPROXY_PROJECT" python3 - <<'PY' 2>/dev/null || true
import json, os, subprocess

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout

project = os.environ.get("CCPROXY_PROJECT", "")
api = ""
if project:
    for n in sh("docker", "ps", "--filter",
                f"label=com.docker.compose.project={project}",
                "--format", "{{.Names}}").splitlines():
        if "cli-proxy-api" in n:
            api = n
            break
if not api:
    for n in sh("docker", "ps", "--format", "{{.Names}}").splitlines():
        if "ccproxy" in n and "cli-proxy-api" in n:
            api = n
            break
if not api:
    raise SystemExit(0)

try:
    listing = sh("docker", "exec", api, "sh", "-c",
                 "ls /data/auth/claude-*.json 2>/dev/null")
except subprocess.CalledProcessError:
    raise SystemExit(0)

for path in listing.split():
    try:
        d = json.loads(sh("docker", "exec", api, "cat", path))
    except Exception:
        continue
    print("|".join([path, d.get("email", ""),
                    d.get("last_refresh", ""), d.get("expired", "")]))
PY
}

echo "==> Checking VPS auth inventory..."
INVENTORY="$(_vps_inventory)"

# Decide per file. Emits "action<TAB>source<TAB>target<TAB>reason".
PLAN="$(
  INVENTORY="$INVENTORY" FORCE="$FORCE" python3 - "${FILES[@]}" <<'PY'
import json, os, sys
from datetime import datetime, timezone

def parse(ts):
    if not ts:
        return None
    try:
        d = datetime.fromisoformat(ts)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)

force = os.environ.get("FORCE") == "1"
now = datetime.now(timezone.utc)

remote = []
for line in os.environ.get("INVENTORY", "").splitlines():
    parts = line.split("|")
    if len(parts) == 4:
        remote.append({"path": parts[0], "email": parts[1],
                       "last_refresh": parse(parts[2]), "expired": parse(parts[3])})

for src in sys.argv[1:]:
    base = os.path.basename(src)
    try:
        with open(src) as fh:
            d = json.load(fh)
    except Exception as e:
        print(f"skip\t{src}\t-\tunreadable ({e.__class__.__name__})")
        continue

    email = d.get("email", "")
    mac_refresh = parse(d.get("last_refresh"))
    mac_expiry = parse(d.get("expired"))

    if not force and mac_expiry and mac_expiry <= now:
        age = int((now - mac_expiry).total_seconds() // 3600)
        print(f"skip\t{src}\t-\texpired {age}h ago")
        continue

    # An account can hold more than one file (a pre-v7.3 record plus the
    # prefixed one a later relogin wrote). Compare against the freshest, so the
    # decision does not depend on directory order.
    candidates = [r for r in remote if r["email"] and r["email"] == email]
    match = max(
        candidates,
        key=lambda r: r["last_refresh"] or datetime.min.replace(tzinfo=timezone.utc),
    ) if candidates else None

    if match and not force:
        rr, mr = match["last_refresh"], mac_refresh
        if rr and (not mr or rr >= mr):
            print(f"skip\t{src}\t-\tVPS copy is newer ({os.path.basename(match['path'])})")
            continue

    # Land on the name the VPS already uses for this account, so a refreshed
    # record is updated rather than duplicated under a second filename.
    target = os.path.basename(match["path"]) if match else base
    reason = "seeds new account" if not match else "newer than VPS copy"
    print(f"copy\t{src}\t{target}\t{reason}")
PY
)"

printf '%s\n' "$PLAN" | while IFS=$'\t' read -r action src target reason; do
  [[ -z "${action:-}" ]] && continue
  if [[ "$action" == "skip" ]]; then
    printf '    skip  %-45s %s\n' "$(basename "$src")" "$reason"
  else
    printf '    copy  %-45s -> %s (%s)\n' "$(basename "$src")" "$target" "$reason"
  fi
done

COPIES="$(printf '%s\n' "$PLAN" | awk -F'\t' '$1=="copy"' || true)"
if [[ -z "$COPIES" ]]; then
  echo "OK: nothing to copy — VPS auth is current."
  exit 0
fi

COUNT="$(printf '%s\n' "$COPIES" | grep -c . || true)"
echo "==> Copying ${COUNT} file(s) to ${VPS_HOST}..."
ssh -o LogLevel=ERROR "$VPS_HOST" "mkdir -p '${REMOTE_DIR}/auth-import'"

while IFS=$'\t' read -r _ src target _; do
  [[ -z "${src:-}" ]] && continue
  scp -q "$src" "${VPS_HOST}:${REMOTE_DIR}/auth-import/${target}"
done <<<"$COPIES"

ssh -o LogLevel=ERROR "$VPS_HOST" \
  CCPROXY_PROJECT="$CCPROXY_PROJECT" REMOTE_DIR="$REMOTE_DIR" 'bash -s' <<'REMOTE'
set -euo pipefail
if [ -n "${CCPROXY_PROJECT:-}" ]; then
  # Pin to the compose project — several stacks can match the name grep.
  api=$(docker ps --filter "label=com.docker.compose.project=${CCPROXY_PROJECT}" \
        --format '{{.Names}}' | grep -E 'cli-proxy-api' | head -1)
  shim=$(docker ps --filter "label=com.docker.compose.project=${CCPROXY_PROJECT}" \
         --format '{{.Names}}' | grep -E 'cursor-shim' | head -1 || true)
else
  api=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cli-proxy-api' | head -1)
  shim=$(docker ps --format '{{.Names}}' | grep -E 'ccproxy.*cursor-shim' | head -1 || true)
fi
if [ -z "$api" ]; then echo "ERROR: api container not found." >&2; exit 1; fi

for f in "${REMOTE_DIR}"/auth-import/claude-*.json; do
  [ -e "$f" ] || continue
  docker cp "$f" "$api:/data/auth/$(basename "$f")"
  rm -f "$f"
done

docker restart "$api" >/dev/null && echo "  restarted $api"
[ -n "$shim" ] && docker restart "$shim" >/dev/null && echo "  restarted $shim"
REMOTE

echo "OK: auth copied and stack restarted"
