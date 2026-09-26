#!/usr/bin/env bash
# Collapse duplicate Claude auth records and restore canonical filenames.
#
# CLIProxyAPI >= v7.3 writes a newly authorised account as
# claude-<account-uuid>-<email>.json, but refreshes a pre-existing record in
# place under whatever name it already had. A relogin for an account that was
# first authorised under the older scheme therefore leaves two files for one
# address, and `ccproxy accounts` lists it twice — once ACTIVE, once EXPIRED.
#
# For each email this keeps the freshest record, deletes the superseded ones,
# and renames the survivor to claude-<email>.json. That name is stable: the
# binary updates an existing file in place rather than re-minting the prefixed
# form, so normalising once holds across refreshes.
#
# Usage:
#   normalize-auth.sh              # apply
#   normalize-auth.sh --dry-run    # report only, change nothing
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "${ROOT}/scripts/load-env.sh"

# Disambiguates the api container when several compose stacks exist.
export CCPROXY_PROJECT="${COMPOSE_PROJECT_NAME:-}"

VPS_HOST="${VPS_SSH_HOST:-${CLIPROXY_VPS_SSH_HOST:-hostbrr}}"

DRY=0
[[ "${1:-}" == "--dry-run" ]] && DRY=1

[[ "$DRY" == "1" ]] && echo "==> Normalising Claude auth files (dry run)" \
                    || echo "==> Normalising Claude auth files"

ssh -o LogLevel=ERROR "$VPS_HOST" \
  CCPROXY_PROJECT="$CCPROXY_PROJECT" DRY="$DRY" python3 - <<'PY'
import json, os, subprocess, sys
from datetime import datetime, timezone

def sh(*a):
    return subprocess.run(a, capture_output=True, text=True, check=True).stdout

def parse(ts):
    if not ts:
        return None
    try:
        d = datetime.fromisoformat(ts)
    except ValueError:
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)

dry = os.environ.get("DRY") == "1"
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
    print("ERROR: cli-proxy-api container not found.", file=sys.stderr)
    sys.exit(1)

try:
    listing = sh("docker", "exec", api, "sh", "-c",
                 "ls /data/auth/claude-*.json 2>/dev/null").split()
except subprocess.CalledProcessError:
    listing = []

if not listing:
    print("  no auth files found.")
    sys.exit(0)

records = []
for path in listing:
    try:
        d = json.loads(sh("docker", "exec", api, "cat", path))
    except Exception:
        print(f"  skip  {os.path.basename(path)} (unreadable)")
        continue
    email = d.get("email", "")
    if not email:
        print(f"  skip  {os.path.basename(path)} (no email field)")
        continue
    records.append({"path": path, "email": email,
                    "refresh": parse(d.get("last_refresh"))})

EPOCH = datetime.min.replace(tzinfo=timezone.utc)
by_email = {}
for r in records:
    by_email.setdefault(r["email"], []).append(r)

changed = 0
for email, group in sorted(by_email.items()):
    group.sort(key=lambda r: r["refresh"] or EPOCH, reverse=True)
    keep, drop = group[0], group[1:]

    for r in drop:
        stamp = r["refresh"].isoformat() if r["refresh"] else "unknown"
        print(f"  remove  {os.path.basename(r['path'])}  (superseded, refreshed {stamp})")
        if not dry:
            sh("docker", "exec", api, "rm", "-f", r["path"])
        changed += 1

    canonical = f"/data/auth/claude-{email}.json"
    if keep["path"] != canonical:
        # A dropped file may have occupied the canonical name; it is gone by now.
        print(f"  rename  {os.path.basename(keep['path'])} -> {os.path.basename(canonical)}")
        if not dry:
            sh("docker", "exec", api, "mv", keep["path"], canonical)
        changed += 1

if changed == 0:
    print("  already canonical — nothing to do.")
elif dry:
    print(f"  {changed} change(s) would be made. Re-run without --dry-run to apply.")
else:
    print(f"  {changed} change(s) applied.")
    sh("docker", "restart", api)
    print(f"  restarted {api}")
PY
