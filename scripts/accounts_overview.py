#!/usr/bin/env python3
"""Combined Claude account status + plan limits (no day-wise token table).

Runs ON the VPS (e.g. ssh host python3 - < thisfile). Merges what
`ccproxy accounts` and the limits half of `ccproxy stats` show into one table.
Never prints tokens.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
HEADERS_EXTRA = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "anthropic-beta": "oauth-2025-04-20",
}


def sh(*args: str) -> str:
    return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()


def find_api() -> str:
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
            if "cli-proxy-api" in name:
                return name
    out = sh("docker", "ps", "--format", "{{.Names}}")
    for name in out.splitlines():
        if "ccproxy" in name and "cli-proxy-api" in name:
            return name
    raise SystemExit("ERROR: cli-proxy-api container not found.")


def auth_files(api: str) -> list[str]:
    try:
        out = sh("docker", "exec", api, "sh", "-c", "ls /data/auth/claude-*.json 2>/dev/null")
    except subprocess.CalledProcessError:
        return []
    return [p for p in out.split() if p]


def load_auth(api: str, path: str) -> dict:
    raw = sh("docker", "exec", api, "cat", path)
    return json.loads(raw)


def fetch_usage(token: str) -> tuple[int, dict]:
    req = urllib.request.Request(
        USAGE_URL,
        headers={"Authorization": f"Bearer {token}", **HEADERS_EXTRA},
        method="GET",
    )
    last_code, last_body = 0, {"error": {"message": "unknown"}}
    for attempt in range(3):
        try:
            with urllib.request.urlopen(req, timeout=20) as resp:
                return resp.status, json.loads(resp.read().decode())
        except urllib.error.HTTPError as e:
            try:
                body = json.loads(e.read().decode())
            except Exception:
                body = {"error": {"message": str(e)}}
            last_code, last_body = e.code, body
            if e.code == 429 and attempt < 2:
                time.sleep(1.5 * (attempt + 1))
                continue
            return e.code, body
        except Exception as e:
            return 0, {"error": {"message": str(e)}}
    return last_code, last_body


def token_mins(exp) -> float | None:
    if not exp:
        return None
    try:
        e = datetime.fromisoformat(exp)
        if e.tzinfo is None:
            e = e.replace(tzinfo=timezone.utc)
        return (e - datetime.now(timezone.utc)).total_seconds() / 60
    except Exception:
        return None


def account_status(disabled: bool, mins: float | None, auto_held: bool = False) -> tuple[str, str]:
    if auto_held:
        return "HOLD", "5h limit auto-hold (guard)"
    if disabled:
        return "PAUSED", "excluded from round-robin"
    if mins is None:
        return "UNKNOWN", "check manually"
    if mins < 0:
        return "EXPIRED", "needs re-login"
    if mins < 30:
        return "EXPIRING", "refresh soon"
    return "ACTIVE", "in round-robin"


def load_guards() -> dict[str, dict]:
    """Read opt-in / auto-HOLD flags from usage-tracker SQLite (same host)."""
    import sqlite3

    project = os.environ.get("CCPROXY_PROJECT", "")
    try:
        if project:
            out = sh(
                "docker",
                "ps",
                "--filter",
                f"label=com.docker.compose.project={project}",
                "--format",
                "{{.Names}}",
            )
        else:
            out = sh("docker", "ps", "--format", "{{.Names}}")
    except Exception:
        return {}
    tracker = ""
    for name in out.splitlines():
        if "usage-tracker" in name:
            tracker = name
            break
    if not tracker:
        return {}
    code = (
        "import json,os,sqlite3\n"
        "db=os.environ.get('USAGE_DB_PATH','/data/usage/usage.db')\n"
        "try:\n"
        " c=sqlite3.connect(db)\n"
        " rows=c.execute('SELECT email,enabled,auto_held FROM account_guard').fetchall()\n"
        " print(json.dumps({r[0].lower():{'enabled':bool(r[1]),'auto_held':bool(r[2])} for r in rows}))\n"
        "except Exception:\n"
        " print('{}')\n"
    )
    try:
        raw = subprocess.check_output(
            ["docker", "exec", tracker, "python3", "-c", code],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        return json.loads(raw or "{}")
    except Exception:
        return {}

def human_mins(mins: float | None) -> str:
    if mins is None:
        return "-"
    if mins < 0:
        h = -mins / 60
        return f"expired {h:.0f}h ago" if h >= 1 else f"expired {-mins:.0f}m ago"
    if mins < 60:
        return f"{mins:.0f}m left"
    return f"{mins / 60:.1f}h left"


def token_group(mins: float | None) -> int:
    # Valid tokens first, unknown middle, expired last.
    if mins is None:
        return 1
    if mins < 0:
        return 2
    return 0


def pct(v) -> str:
    if v is None:
        return "-"
    try:
        return f"{int(round(float(v)))}%"
    except Exception:
        return "-"


def mark(util) -> str:
    try:
        u = float(util)
    except Exception:
        return " "
    if u >= 90:
        return "!"
    if u >= 75:
        return "~"
    return " "


def reset_human(iso: str | None) -> str:
    if not iso:
        return "-"
    try:
        ts = datetime.fromisoformat(iso.replace("Z", "+00:00"))
    except Exception:
        return iso
    now = datetime.now(timezone.utc)
    if ts.tzinfo is None:
        ts = ts.replace(tzinfo=timezone.utc)
    secs = int((ts - now).total_seconds())
    if secs <= 0:
        return "reset due"
    h, rem = divmod(secs, 3600)
    m = rem // 60
    if h >= 48:
        return f"resets {ts.strftime('%a %H:%M')} UTC"
    if h >= 24:
        return f"resets in {h // 24}d {h % 24}h"
    if h > 0:
        return f"resets in {h}h {m}m"
    return f"resets in {m}m"


def main() -> int:
    api = find_api()
    files = auth_files(api)
    if not files:
        print("No Claude auth files found in /data/auth.")
        return 0

    guards = load_guards()
    rows: list[dict] = []
    for path in files:
        data = load_auth(api, path)
        email = data.get("email") or "?"
        disabled = bool(data.get("disabled", False))
        mins = token_mins(data.get("expired") or data.get("expires_at"))
        g = guards.get(email.lower())
        # Missing row = guard ON by default
        guard_on = True if g is None else bool(g.get("enabled"))
        auto_held = bool(g.get("auto_held")) if g else False
        status, action = account_status(disabled, mins, auto_held)
        token = data.get("access_token") or ""
        if not token:
            code, body = 0, {"error": {"message": "missing access_token"}}
        else:
            code, body = fetch_usage(token)
            time.sleep(0.35)
        rows.append(
            {
                "email": email,
                "status": status,
                "action": action,
                "mins": mins,
                "code": code,
                "body": body,
                "guard_on": guard_on,
                "auto_held": auto_held,
            }
        )

    header = (
        f"{'ACCOUNT':<34} {'STATUS':<9} {'TOKEN':<16} "
        f"{'5-HOUR':<8} {'5H RESET':<22} {'WEEKLY':<8} {'WEEK RESET / NOTE'}"
    )
    print(header)
    print("-" * len(header))

    need_relogin: list[str] = []
    paused: list[str] = []
    held: list[str] = []
    guarded: list[str] = []
    auth_fail: list[str] = []

    for r in sorted(rows, key=lambda x: (token_group(x["mins"]), (x["email"] or "").lower())):
        email = r["email"]
        if r.get("auto_held"):
            held.append(email)
        elif r["status"] == "PAUSED":
            paused.append(email)
        if r.get("guard_on"):
            guarded.append(email)
        if r["status"] == "EXPIRED" or r["action"] == "needs re-login":
            need_relogin.append(email)

        code, body = r["code"], r["body"]
        if code != 200:
            err = (body.get("error") or {}).get("message") or f"HTTP {code}"
            print(
                f"{email:<34} {r['status']:<9} {human_mins(r['mins']):<16} "
                f"{'ERR':<8} {err[:60]}"
            )
            if code in (401, 403) or "expired" in err.lower() or "re-authenticate" in err.lower():
                auth_fail.append(email)
            continue

        five = body.get("five_hour") or {}
        week = body.get("seven_day") or {}
        f_col = f"{pct(five.get('utilization'))}{mark(five.get('utilization'))}"
        w_col = f"{pct(week.get('utilization'))}{mark(week.get('utilization'))}"
        print(
            f"{email:<34} {r['status']:<9} {human_mins(r['mins']):<16} "
            f"{f_col:<8} {reset_human(five.get('resets_at')):<22} "
            f"{w_col:<8} {reset_human(week.get('resets_at'))}"
        )

        for lim in body.get("limits") or []:
            if lim.get("kind") != "weekly_scoped":
                continue
            scope = ((lim.get("scope") or {}).get("model") or {}).get("display_name") or "scoped"
            p = lim.get("percent")
            if p is None:
                continue
            note = f"weekly - {scope}"
            if lim.get("resets_at"):
                note += f" ({reset_human(lim.get('resets_at'))})"
            p_col = f"{pct(p)}{mark(p)}"
            print(
                f"{'':<34} {'':<9} {'':<16} "
                f"{'':<8} {'':<22} {p_col:<8} {note}"
            )

    print("-" * len(header))
    print("STATUS/TOKEN = OAuth account routing + access-token TTL (~8h, auto-refreshed).")
    print("5-HOUR/WEEKLY = Anthropic plan usage (same as Claude Settings → Usage).")
    print("High-level PAUSED (ccproxy pause) = never in round-robin.")
    print("Inner GUARD ON (default) = auto-HOLD at 5h>=92%; off via: ccproxy guard off.")
    print("~ = >=75%   ! = >=90%")
    print("Day-wise tokens: ccproxy stats")

    if guarded:
        print("\n🛡  Guard ON: " + ", ".join(guarded))
    if held:
        print("\n⏳ Auto-HOLD (back when 5h resets): " + ", ".join(held))
    if paused:
        print("\n⏸  Paused (high-level; never in round-robin): " + ", ".join(paused))
        print("   Resume:  ccproxy resume <email-or-substring>")
    if need_relogin or auth_fail:
        uniq = sorted(set(need_relogin + auth_fail))
        print("\n⚠️  Needs re-login: " + ", ".join(uniq))
        print("   Run:  ccproxy relogin")
    elif not paused and not held:
        print("\n✅ All accounts active in round-robin.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
