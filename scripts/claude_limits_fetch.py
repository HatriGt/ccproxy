#!/usr/bin/env python3
"""Fetch Claude OAuth plan limits for all auth files on this VPS.

Designed to run ON the VPS (e.g. ssh host python3 - < thisfile).
Reads tokens from the ccproxy cli-proxy-api container; never prints tokens.
"""
from __future__ import annotations

import json
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


def load_auth(api: str, path: str) -> tuple[str, str]:
    raw = sh("docker", "exec", api, "cat", path)
    data = json.loads(raw)
    return data.get("email") or "?", data.get("access_token") or ""


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

    rows: list[tuple[str, int, dict]] = []
    for path in files:
        email, token = load_auth(api, path)
        if not token:
            rows.append((email, 0, {"error": {"message": "missing access_token"}}))
            continue
        code, body = fetch_usage(token)
        rows.append((email, code, body))
        time.sleep(0.35)

    print(f"{'ACCOUNT':<34} {'5-HOUR':<8} {'RESET':<22} {'WEEKLY':<8} {'RESET / NOTE'}")
    print("-" * 100)
    warn: list[str] = []

    for email, code, body in sorted(rows, key=lambda r: r[0]):
        if code != 200:
            err = (body.get("error") or {}).get("message") or f"HTTP {code}"
            print(f"{email:<34} ERR      {err[:50]}")
            if code in (401, 403):
                warn.append(email)
            continue

        five = body.get("five_hour") or {}
        week = body.get("seven_day") or {}
        f_col = f"{pct(five.get('utilization'))}{mark(five.get('utilization'))}"
        w_col = f"{pct(week.get('utilization'))}{mark(week.get('utilization'))}"
        print(
            f"{email:<34} {f_col:<8} {reset_human(five.get('resets_at')):<22} "
            f"{w_col:<8} {reset_human(week.get('resets_at'))}"
        )

        for lim in body.get("limits") or []:
            if lim.get("kind") != "weekly_scoped":
                continue
            scope = ((lim.get("scope") or {}).get("model") or {}).get("display_name") or "scoped"
            p = lim.get("percent")
            if p is None:
                continue
            note = f"weekly · {scope}"
            if lim.get("resets_at"):
                note += f" ({reset_human(lim.get('resets_at'))})"
            p_col = f"{pct(p)}{mark(p)}"
            print(f"{'':<34} {'':<8} {'':<22} {p_col:<8} {note}")

    print("-" * 100)
    print("Source: Anthropic OAuth usage API (same as Claude Settings → Usage).")
    print("~ = ≥75%   ! = ≥90%")
    if warn:
        print("⚠️  Auth failed for: " + ", ".join(warn) + " — run: ccproxy relogin")
    return 0


if __name__ == "__main__":
    sys.exit(main())
