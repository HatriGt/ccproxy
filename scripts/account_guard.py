#!/usr/bin/env python3
"""5-hour auto-hold flag (inner gate). Manual pause is the high-level gate.

- Guard is ON by default for every account.
- `guard off` removes the flag (no auto-HOLD).
- `guard on` turns it back on.
- Manual `pause` always wins: PAUSED accounts never enter round-robin.

Usage:
  account_guard.py limits                 show hold limits
  account_guard.py set <what> <percent>   what = 5h | weekly | model | 5h-buffer | weekly-buffer
  account_guard.py reset                  back to defaults
  account_guard.py list
  account_guard.py on  <email-or-substring>
  account_guard.py off <email-or-substring>
"""
from __future__ import annotations

import json
import os
import subprocess
import sys


def sh(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def find_container(needle: str) -> str:
    project = os.environ.get("CCPROXY_PROJECT", "")
    if project:
        out = sh(
            "docker",
            "ps",
            "--filter",
            f"label=com.docker.compose.project={project}",
            "--format",
            "{{.Names}}",
        )
        for name in out.splitlines():
            if needle in name:
                return name
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
    payload = {"key": key, "method": method, "path": path, "body": body}
    code = r"""
import json, urllib.request, urllib.error, sys
cfg = json.loads(sys.stdin.read())
url = "http://cli-proxy-api:8318/v0/management" + cfg["path"]
data = None if cfg["body"] is None else json.dumps(cfg["body"]).encode()
req = urllib.request.Request(
    url, data=data,
    headers={"Authorization": "Bearer " + cfg["key"], "Content-Type": "application/json"},
    method=cfg["method"],
)
try:
    with urllib.request.urlopen(req, timeout=20) as resp:
        print(resp.read().decode() or "{}")
except urllib.error.HTTPError as e:
    print(json.dumps({"error": True, "status": e.code, "body": e.read().decode()}), file=sys.stderr)
    sys.exit(1)
"""
    proc = subprocess.run(
        ["docker", "exec", "-i", tracker, "python3", "-c", code],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"ERROR: management API failed — {(proc.stderr or proc.stdout).strip()}")
    return json.loads(proc.stdout or "{}")


def db_call(tracker: str, payload: dict) -> dict:
    script = r'''
import json, sqlite3, sys, os
from datetime import datetime, timezone
cfg = json.loads(sys.stdin.read())
db = os.environ.get("USAGE_DB_PATH", "/data/usage/usage.db")
conn = sqlite3.connect(db)
conn.executescript("""
CREATE TABLE IF NOT EXISTS account_guard (
    email TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL DEFAULT 1,
    auto_held INTEGER NOT NULL DEFAULT 0,
    held_at TEXT,
    last_util REAL,
    last_check TEXT,
    updated_at TEXT
);
""")
op = cfg["op"]
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
if op == "seed":
    for email in cfg.get("emails") or []:
        email = (email or "").lower().strip()
        if not email:
            continue
        conn.execute(
            "INSERT INTO account_guard (email, enabled, auto_held, updated_at) VALUES (?, 1, 0, ?) "
            "ON CONFLICT(email) DO NOTHING",
            (email, now),
        )
    conn.commit()
    rows = conn.execute(
        "SELECT email, enabled, auto_held, last_util, held_at, last_check FROM account_guard"
    ).fetchall()
    print(json.dumps([
        {"email": r[0], "enabled": bool(r[1]), "auto_held": bool(r[2]),
         "last_util": r[3], "held_at": r[4], "last_check": r[5]}
        for r in rows
    ]))
elif op == "list":
    rows = conn.execute(
        "SELECT email, enabled, auto_held, last_util, held_at, last_check FROM account_guard"
    ).fetchall()
    print(json.dumps([
        {"email": r[0], "enabled": bool(r[1]), "auto_held": bool(r[2]),
         "last_util": r[3], "held_at": r[4], "last_check": r[5]}
        for r in rows
    ]))
elif op == "set":
    email = cfg["email"].lower()
    enabled = 1 if cfg["enabled"] else 0
    conn.execute(
        "INSERT INTO account_guard (email, enabled, auto_held, updated_at) VALUES (?, ?, "
        "COALESCE((SELECT auto_held FROM account_guard WHERE email=?), 0), ?) "
        "ON CONFLICT(email) DO UPDATE SET enabled=excluded.enabled, updated_at=excluded.updated_at",
        (email, enabled, email, now),
    )
    row = conn.execute("SELECT enabled, auto_held FROM account_guard WHERE email=?", (email,)).fetchone()
    conn.commit()
    print(json.dumps({"email": email, "enabled": bool(row[0]), "auto_held": bool(row[1])}))
elif op == "settings":
    conn.execute("CREATE TABLE IF NOT EXISTS guard_settings (key TEXT PRIMARY KEY, value REAL NOT NULL)")
    if cfg.get("reset"):
        conn.execute("DELETE FROM guard_settings")
    if cfg.get("key"):
        conn.execute("INSERT INTO guard_settings (key, value) VALUES (?, ?) "
                     "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (cfg["key"], float(cfg["value"])))
    conn.commit()
    saved = dict(conn.execute("SELECT key, value FROM guard_settings").fetchall())
    env = {"5h": os.environ.get("GUARD_FIVEHOUR_PCT", "85"), "weekly": os.environ.get("GUARD_WEEKLY_PCT", "95"),
           "model": os.environ.get("GUARD_SCOPED_PCT", "95"), "5h-buffer": os.environ.get("GUARD_FAILSAFE_MARGIN", "10"),
           "weekly-buffer": os.environ.get("GUARD_WEEKLY_MARGIN", "3")}
    print(json.dumps({k: [float(saved.get(k, v)), k in saved] for k, v in env.items()}))
elif op == "clear_hold":
    email = cfg["email"].lower()
    conn.execute(
        "UPDATE account_guard SET auto_held=0, held_at=NULL, updated_at=? WHERE email=?",
        (now, email),
    )
    conn.commit()
    print(json.dumps({"email": email, "auto_held": False}))
else:
    print(json.dumps({"error": "unknown op"})); sys.exit(1)
'''
    proc = subprocess.run(
        ["docker", "exec", "-i", tracker, "python3", "-c", script],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
    )
    if proc.returncode != 0:
        raise SystemExit(f"ERROR: guard db failed — {(proc.stderr or proc.stdout).strip()}")
    return json.loads(proc.stdout or "{}")


def list_auth(tracker: str, key: str) -> list[dict]:
    return list(api_call(tracker, key, "GET", "/auth-files").get("files") or [])


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
    exact = [f for f in hits if (f.get("email") or "").lower() == q]
    if len(exact) == 1:
        return exact[0]
    if len(hits) == 1:
        return hits[0]
    if not hits:
        emails = ", ".join(sorted(f.get("email") or "?" for f in files))
        raise SystemExit(f"ERROR: no account matching {query!r}. Known: {emails}")
    emails = ", ".join(sorted(f.get("email") or "?" for f in hits))
    raise SystemExit(f"ERROR: ambiguous match for {query!r}: {emails}")


def print_list(guards: list[dict], files: list[dict]) -> None:
    by_email = {g["email"].lower(): g for g in guards}
    print(f"{'ACCOUNT':<34} {'GUARD':<8} {'HOLD':<6} {'LAST 5H':<8} {'ROUTE'}")
    print("-" * 78)
    for f in sorted(files, key=lambda x: (x.get("email") or "").lower()):
        email = f.get("email") or "?"
        g = by_email.get(email.lower())
        # Missing row = default ON
        guard_on = True if g is None else bool(g.get("enabled"))
        auto_held = bool(g.get("auto_held")) if g else False
        guard = "ON" if guard_on else "OFF"
        hold = "YES" if auto_held else "-"
        util = g.get("last_util") if g else None
        util_s = f"{util:.0f}%" if isinstance(util, (int, float)) else "-"
        if f.get("disabled") and not auto_held:
            route = "PAUSED"
        elif auto_held:
            route = "HOLD"
        else:
            route = "ACTIVE"
        print(f"{email:<34} {guard:<8} {hold:<6} {util_s:<8} {route}")
    print("-" * 78)
    print("High-level: PAUSED (ccproxy pause) = never in round-robin.")
    print("Inner:      GUARD ON (default) = auto-HOLD when 5h >= 85% or weekly >= 85%; back when windows reset.")
    print("            GUARD OFF = no auto-HOLD for that account.")
    print("Toggle:     ccproxy guard on|off <email>")


def print_limits(cfg: dict) -> None:
    v = {k: x[0] for k, x in cfg.items()}
    star = {k: (" *" if x[1] else "") for k, x in cfg.items()}
    print("Guard limits")
    print(f"  5-hour usage        hold at {v['5h']:g}%{star['5h']}")
    print(f"  weekly usage        hold at {v['weekly']:g}%{star['weekly']}")
    print(f"  one model's weekly  block that model at {v['model']:g}%{star['model']}")
    print()
    print("Safety buffer (hold stays on until usage drops below this):")
    print(f"  5-hour              {v['5h'] - v['5h-buffer']:g}%  (buffer {v['5h-buffer']:g}){star['5h-buffer']}")
    print(f"  weekly / model      {v['weekly'] - v['weekly-buffer']:g}% / {v['model'] - v['weekly-buffer']:g}%  (buffer {v['weekly-buffer']:g}){star['weekly-buffer']}")
    print()
    print("Change:  ccproxy guard set 5h 90 | set weekly 95 | set model 95 | set 5h-buffer 10 | set weekly-buffer 3")
    print("Reset:   ccproxy guard reset        (* = changed from default)")


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] in ("-h", "--help", "help"):
        print(__doc__.strip())
        raise SystemExit(0 if len(sys.argv) > 1 else 2)

    action = sys.argv[1].lower()
    query = " ".join(sys.argv[2:]).strip() if len(sys.argv) > 2 else ""

    if action in ("limits", "set", "reset"):
        tracker = find_container("usage-tracker")
        payload = {"op": "settings"}
        if action == "set":
            keys = ("5h", "weekly", "model", "5h-buffer", "weekly-buffer")
            if len(sys.argv) != 4 or sys.argv[2].lower() not in keys:
                raise SystemExit("usage: ccproxy guard set <5h|weekly|model|5h-buffer|weekly-buffer> <percent>")
            try:
                val = float(sys.argv[3].rstrip("%"))
            except ValueError:
                raise SystemExit("ERROR: percent must be a number, e.g. 90")
            if not 0 <= val <= 100:
                raise SystemExit("ERROR: percent must be 0-100")
            payload.update(key=sys.argv[2].lower(), value=val)
        if action == "reset":
            payload["reset"] = True
        print_limits(db_call(tracker, payload))
        if action != "limits":
            print("\nSaved. The guard picks this up within ~15 seconds (no redeploy).")
        return

    api = find_container("cli-proxy-api")
    tracker = find_container("usage-tracker")
    key = mgmt_key(api)
    files = list_auth(tracker, key)

    emails = [(f.get("email") or "").lower() for f in files if f.get("email")]
    # Seed defaults (ON) for any account missing a row.
    seeded = db_call(tracker, {"op": "seed", "emails": emails})
    if isinstance(seeded, dict) and seeded.get("error"):
        raise SystemExit(seeded["error"])
    guards = seeded if isinstance(seeded, list) else []

    if action in ("list", "ls", "status"):
        print_list(guards, files)
        return

    if action not in ("on", "enable", "off", "disable"):
        raise SystemExit("ERROR: use list|on|off")

    if not query:
        raise SystemExit(f"ERROR: usage: account_guard.py {action} <email-or-substring>")

    target = resolve(files, query)
    email = (target.get("email") or "").lower()
    name = target.get("name") or ""
    want_on = action in ("on", "enable")

    prev = next((g for g in guards if g["email"].lower() == email), {})
    # Missing row counted as ON (default)
    was_on = True if not prev else bool(prev.get("enabled"))
    was_held = bool(prev.get("auto_held"))

    result = db_call(tracker, {"op": "set", "email": email, "enabled": want_on})

    if not want_on and was_held:
        # Only release routing if this was our HOLD, not a manual pause.
        if not bool(target.get("disabled")) or was_held:
            api_call(tracker, key, "PATCH", "/auth-files/status", {"name": name, "disabled": False})
        db_call(tracker, {"op": "clear_hold", "email": email})
        print(f"Guard OFF for {email} (released HOLD -> eligible for round-robin)")
        print("Note: manual PAUSE still blocks round-robin until: ccproxy resume ...")
    elif want_on and was_on:
        print(f"No change: guard already ON for {email}")
    elif want_on:
        print(f"Guard ON for {email}")
        print("Inner gate: auto-HOLD when 5-hour or weekly usage reaches 85%.")
    else:
        print(f"Guard OFF for {email} (no auto-HOLD; pause/resume still apply)")

    _ = result


if __name__ == "__main__":
    main()
