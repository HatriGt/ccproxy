#!/usr/bin/env python3
"""Pause / resume Claude OAuth accounts in CLIProxyAPI round-robin.

Runs ON the VPS (ssh host python3 - < thisfile). Uses the management API
PATCH /v0/management/auth-files/status — sets auth JSON "disabled", which
excludes the account from routing until resumed. Survives container restarts.

Usage:
  account_route.py list
  account_route.py pause <email-or-substring>
  account_route.py resume <email-or-substring>
"""
from __future__ import annotations

import json
import subprocess
import sys
import urllib.error
import urllib.request


def sh(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def find_container(needle: str) -> str:
    out = sh("docker", "ps", "--format", "{{.Names}}")
    for name in out.splitlines():
        if needle in name:
            return name
    raise SystemExit(f"ERROR: container matching {needle!r} not found.")


def mgmt_key(api: str) -> str:
    env = sh("docker", "inspect", api, "--format", "{{range .Config.Env}}{{println .}}{{end}}")
    for line in env.splitlines():
        if line.startswith("CLIPROXY_MGMT_KEY="):
            return line.split("=", 1)[1]
    raise SystemExit("ERROR: CLIPROXY_MGMT_KEY not set on api container.")


def api_call(tracker: str, key: str, method: str, path: str, body: dict | None = None) -> dict:
    payload = {
        "key": key,
        "method": method,
        "path": path,
        "body": body,
    }
    # Run HTTP from usage-tracker (has Python + Docker network to api).
    code = r"""
import json, os, urllib.request, urllib.error, sys
cfg = json.loads(sys.stdin.read())
url = "http://cli-proxy-api:8318/v0/management" + cfg["path"]
data = None if cfg["body"] is None else json.dumps(cfg["body"]).encode()
req = urllib.request.Request(
    url,
    data=data,
    headers={"Authorization": "Bearer " + cfg["key"], "Content-Type": "application/json"},
    method=cfg["method"],
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode() or "{}"
        print(raw)
except urllib.error.HTTPError as e:
    err = e.read().decode()
    print(json.dumps({"error": True, "status": e.code, "body": err}), file=sys.stderr)
    sys.exit(1)
"""
    proc = subprocess.run(
        ["docker", "exec", "-i", tracker, "python3", "-c", code],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        msg = (proc.stderr or proc.stdout or "request failed").strip()
        raise SystemExit(f"ERROR: management API failed — {msg}")
    return json.loads(proc.stdout or "{}")


def list_files(tracker: str, key: str) -> list[dict]:
    data = api_call(tracker, key, "GET", "/auth-files")
    return list(data.get("files") or [])


def resolve(files: list[dict], query: str) -> dict:
    q = query.strip().lower()
    if not q:
        raise SystemExit("ERROR: empty account query.")
    hits = []
    for f in files:
        email = (f.get("email") or "").lower()
        name = (f.get("name") or "").lower()
        if q == email or q in email or q in name or q == name:
            hits.append(f)
    # Prefer exact email match if multiple substring hits
    exact = [f for f in hits if (f.get("email") or "").lower() == q]
    if len(exact) == 1:
        return exact[0]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        emails = ", ".join(sorted(f.get("email") or f.get("name") or "?" for f in files))
        raise SystemExit(f"ERROR: no account matching {query!r}. Known: {emails}")
    emails = ", ".join(sorted(f.get("email") or "?" for f in hits))
    raise SystemExit(f"ERROR: ambiguous match for {query!r}: {emails}\nBe more specific.")


def print_list(files: list[dict]) -> None:
    print(f"{'ACCOUNT':<34} {'ROUTE':<8} {'FILE'}")
    print("-" * 78)
    active = paused = 0
    for f in sorted(files, key=lambda x: (x.get("email") or "")):
        email = f.get("email") or "?"
        name = f.get("name") or "?"
        disabled = bool(f.get("disabled"))
        route = "PAUSED" if disabled else "ACTIVE"
        if disabled:
            paused += 1
        else:
            active += 1
        print(f"{email:<34} {route:<8} {name}")
    print("-" * 78)
    print(f"Routing: {active} active, {paused} paused")
    if paused:
        print("Resume:  ccproxy resume <email-or-substring>")


def set_disabled(tracker: str, key: str, name: str, disabled: bool) -> dict:
    return api_call(
        tracker,
        key,
        "PATCH",
        "/auth-files/status",
        {"name": name, "disabled": disabled},
    )


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(__doc__.strip())
        raise SystemExit(0 if len(sys.argv) > 1 else 2)

    action = sys.argv[1].lower()
    query = " ".join(sys.argv[2:]).strip() if len(sys.argv) > 2 else ""

    api = find_container("cli-proxy-api")
    tracker = find_container("usage-tracker")
    key = mgmt_key(api)
    files = list_files(tracker, key)

    if action in ("list", "ls", "status"):
        print_list(files)
        return

    if action not in ("pause", "resume", "enable", "disable"):
        raise SystemExit(f"ERROR: unknown action {action!r}. Use list|pause|resume")

    if not query:
        raise SystemExit(f"ERROR: usage: account_route.py {action} <email-or-substring>")

    # Aliases
    want_disabled = action in ("pause", "disable")
    target = resolve(files, query)
    email = target.get("email") or "?"
    name = target.get("name") or ""
    was = bool(target.get("disabled"))

    if was == want_disabled:
        state = "paused (excluded from round-robin)" if was else "active (in round-robin)"
        print(f"No change: {email} is already {state}")
        return

    result = set_disabled(tracker, key, name, want_disabled)
    if result.get("status") != "ok" and "disabled" not in result:
        raise SystemExit(f"ERROR: unexpected response: {result}")

    if want_disabled:
        print(f"Paused {email}")
        print("Excluded from round-robin until: ccproxy resume " + (email.split("@")[0] if "@" in email else email))
    else:
        print(f"Resumed {email}")
        print("Back in round-robin.")


if __name__ == "__main__":
    main()
