#!/usr/bin/env python3
"""5-hour plan-limit auto-hold for opted-in Claude accounts.

Separate from manual pause/resume (`disabled` as a high-level gate):
- Opt-in flag lives in SQLite (`account_guard.enabled`).
- When 5-hour utilization >= threshold, set CLIProxyAPI `disabled=true`
  and mark `auto_held=1` (shown as HOLD).
- When utilization falls back below threshold (window reset), clear
  `disabled` only if we auto-held it — never resume a manual pause.
"""
from __future__ import annotations

import json
import os
import sqlite3
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
HEADERS_EXTRA = {
    "Content-Type": "application/json",
    "Accept": "application/json",
    "anthropic-beta": "oauth-2025-04-20",
}

AUTH_DIR = Path(os.environ.get("CLIPROXY_AUTH_DIR", "/data/auth"))
UPSTREAM = os.environ.get("CLIPROXY_UPSTREAM", "http://cli-proxy-api:8318").rstrip("/")
MGMT_KEY = os.environ.get("CLIPROXY_MGMT_KEY", "")
THRESHOLD = float(os.environ.get("GUARD_FIVEHOUR_PCT", "92"))
POLL_SECS = int(os.environ.get("GUARD_POLL_SECS", "60"))


def log(msg: str) -> None:
    print(f"[fivehour-guard] {msg}", flush=True)


def init_guard_db(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS account_guard (
            email       TEXT PRIMARY KEY,
            enabled     INTEGER NOT NULL DEFAULT 0,
            auto_held   INTEGER NOT NULL DEFAULT 0,
            held_at     TEXT,
            last_util   REAL,
            last_check  TEXT,
            updated_at  TEXT
        )
        """
    )
    conn.commit()


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def list_guards(conn: sqlite3.Connection) -> list[dict]:
    rows = conn.execute(
        "SELECT email, enabled, auto_held, held_at, last_util, last_check FROM account_guard ORDER BY email"
    ).fetchall()
    return [
        {
            "email": r[0],
            "enabled": bool(r[1]),
            "auto_held": bool(r[2]),
            "held_at": r[3],
            "last_util": r[4],
            "last_check": r[5],
        }
        for r in rows
    ]


def set_guard(conn: sqlite3.Connection, email: str, enabled: bool) -> None:
    email = email.strip().lower()
    now = _now()
    conn.execute(
        """
        INSERT INTO account_guard (email, enabled, auto_held, updated_at)
        VALUES (?, ?, 0, ?)
        ON CONFLICT(email) DO UPDATE SET
          enabled=excluded.enabled,
          updated_at=excluded.updated_at
        """,
        (email, 1 if enabled else 0, now),
    )
    conn.commit()


def set_auto_held(conn: sqlite3.Connection, email: str, held: bool, util: float | None = None) -> None:
    email = email.strip().lower()
    now = _now()
    row = conn.execute(
        "SELECT enabled, held_at FROM account_guard WHERE email=?", (email,)
    ).fetchone()
    enabled = int(row[0]) if row else 1
    held_at = (row[1] if row and row[1] else now) if held else None
    conn.execute(
        """
        INSERT INTO account_guard (email, enabled, auto_held, held_at, last_util, last_check, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(email) DO UPDATE SET
          auto_held=excluded.auto_held,
          held_at=excluded.held_at,
          last_util=excluded.last_util,
          last_check=excluded.last_check,
          updated_at=excluded.updated_at
        """,
        (email, enabled, 1 if held else 0, held_at, util, now, now),
    )
    conn.commit()


def clear_auto_held(conn: sqlite3.Connection, email: str) -> None:
    """Used when the operator manually pause/resumes — hand control back."""
    email = email.strip().lower()
    conn.execute(
        "UPDATE account_guard SET auto_held=0, held_at=NULL, updated_at=? WHERE email=?",
        (_now(), email),
    )
    conn.commit()


def touch_check(conn: sqlite3.Connection, email: str, util: float | None) -> None:
    conn.execute(
        """
        UPDATE account_guard
           SET last_util=?, last_check=?, updated_at=?
         WHERE email=?
        """,
        (util, _now(), _now(), email.strip().lower()),
    )
    conn.commit()


def mgmt(method: str, path: str, body: dict | None = None) -> dict:
    url = f"{UPSTREAM}/v0/management{path}"
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(
        url,
        data=data,
        headers={
            "Authorization": f"Bearer {MGMT_KEY}",
            "Content-Type": "application/json",
        },
        method=method,
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        raw = resp.read().decode() or "{}"
        return json.loads(raw)


def auth_files_api() -> list[dict]:
    data = mgmt("GET", "/auth-files")
    return list(data.get("files") or [])


def set_disabled(name: str, disabled: bool) -> None:
    mgmt("PATCH", "/auth-files/status", {"name": name, "disabled": disabled})


def load_token(name: str) -> str:
    path = AUTH_DIR / name
    if not path.is_file():
        # Fallback: scan by filename suffix
        for p in AUTH_DIR.glob("claude-*.json"):
            if p.name == name or p.name.endswith(name):
                path = p
                break
        else:
            return ""
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return ""
    return data.get("access_token") or ""


def fetch_fivehour_util(token: str) -> float | None:
    req = urllib.request.Request(
        USAGE_URL,
        headers={"Authorization": f"Bearer {token}", **HEADERS_EXTRA},
        method="GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            body = json.loads(resp.read().decode())
    except urllib.error.HTTPError as e:
        try:
            err = json.loads(e.read().decode())
        except Exception:
            err = {"error": {"message": str(e)}}
        msg = (err.get("error") or {}).get("message") or f"HTTP {e.code}"
        raise RuntimeError(msg) from e
    five = body.get("five_hour") or {}
    util = five.get("utilization")
    if util is None:
        return None
    return float(util)


def resolve_file(files: list[dict], email: str) -> dict | None:
    email = email.lower()
    for f in files:
        if (f.get("email") or "").lower() == email:
            return f
    # substring fallback
    hits = [f for f in files if email in (f.get("email") or "").lower()]
    return hits[0] if len(hits) == 1 else None


def tick(conn: sqlite3.Connection) -> None:
    if not MGMT_KEY:
        return
    if not AUTH_DIR.is_dir():
        log(f"auth dir missing ({AUTH_DIR}); skip tick")
        return

    guards = [g for g in list_guards(conn) if g["enabled"] or g["auto_held"]]
    if not guards:
        return

    try:
        files = auth_files_api()
    except Exception as e:
        log(f"auth-files list failed: {e}")
        return

    for g in guards:
        email = g["email"]
        f = resolve_file(files, email)
        if not f:
            log(f"{email}: auth file not found; skip")
            continue
        name = f.get("name") or ""
        disabled = bool(f.get("disabled"))
        auto_held = bool(g["auto_held"])

        token = load_token(name)
        if not token:
            log(f"{email}: no access_token; skip")
            continue

        try:
            util = fetch_fivehour_util(token)
        except Exception as e:
            log(f"{email}: usage fetch failed: {e}")
            continue

        touch_check(conn, email, util)
        if util is None:
            log(f"{email}: no five_hour utilization; skip")
            time.sleep(0.35)
            continue

        over = util >= THRESHOLD
        if over:
            if auto_held:
                log(f"{email}: HOLD stays (5h={util:.0f}% >= {THRESHOLD:.0f}%)")
            elif disabled:
                # Manual pause is the high-level gate — do not take ownership.
                log(f"{email}: over limit but manually PAUSED; leave alone")
            else:
                try:
                    set_disabled(name, True)
                    set_auto_held(conn, email, True, util)
                    log(f"{email}: HOLD on (5h={util:.0f}% >= {THRESHOLD:.0f}%)")
                except Exception as e:
                    log(f"{email}: failed to HOLD: {e}")
        else:
            if auto_held:
                try:
                    set_disabled(name, False)
                    set_auto_held(conn, email, False, util)
                    log(f"{email}: HOLD off (5h={util:.0f}% < {THRESHOLD:.0f}%) — back in round-robin")
                except Exception as e:
                    log(f"{email}: failed to release HOLD: {e}")
            elif g["enabled"]:
                log(f"{email}: ok (5h={util:.0f}%)")

        time.sleep(0.35)


def guard_enabled() -> bool:
    return os.environ.get("GUARD_ENABLED", "true").lower() not in ("0", "false", "no", "off")
