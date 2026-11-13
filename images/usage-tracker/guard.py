#!/usr/bin/env python3
"""5-hour plan-limit auto-hold (inner gate), under manual pause (high-level).

Layers:
1. High-level: `ccproxy pause` / `resume` — if PAUSED, never in round-robin.
2. Inner: guard flag (ON by default for every account) — when ON, if 5h
   utilization >= threshold (or weekly utilization >= weekly threshold) then
   temporary HOLD; when the window(s) reset,
   back in round-robin. `ccproxy guard off` removes the flag.

HOLD never overrides a manual PAUSE; pause/resume clears auto-HOLD ownership.
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
THRESHOLD = float(os.environ.get("GUARD_FIVEHOUR_PCT", "85"))
WEEKLY_THRESHOLD = float(os.environ.get("GUARD_WEEKLY_PCT", "85"))
SCOPED_THRESHOLD = float(os.environ.get("GUARD_SCOPED_PCT", "85"))
POLL_SECS = int(os.environ.get("GUARD_POLL_SECS", "60"))
# Anthropic rate-limits the usage endpoint, so each account is polled on its own
# schedule: often when close to a limit, rarely when far from it, with backoff on
# errors. While reads fail, the last good reading decides (fail-safe hold).
SLOW_POLL_SECS = int(os.environ.get("GUARD_SLOW_POLL_SECS", "300"))
MAX_BACKOFF_SECS = int(os.environ.get("GUARD_MAX_BACKOFF_SECS", "900"))
FAILSAFE_MARGIN = float(os.environ.get("GUARD_FAILSAFE_MARGIN", "10"))
FAILSAFE_MAX_AGE_SECS = int(os.environ.get("GUARD_FAILSAFE_MAX_AGE_SECS", "3600"))

# Burst trigger: between polls, watch this account's own traffic in the usage
# table. Weighted tokens = input + 5*output + 0.1*cache-read (roughly cost).
# A Fable/Opus agent loop can burn ~60% of a 5h window in 3 minutes, so a big
# burst forces an early poll; a huge one with no usable reading forces a hold.
BURST_POLL_TOKENS = int(os.environ.get("GUARD_BURST_POLL_TOKENS", "60000"))
BURST_HOLD_TOKENS = int(os.environ.get("GUARD_BURST_HOLD_TOKENS", "400000"))
MIN_POLL_GAP_SECS = int(os.environ.get("GUARD_MIN_POLL_GAP_SECS", "20"))


def _parse_ts(ts: str) -> float | None:
    import re
    from datetime import datetime
    ts = re.sub(r"(\.\d{6})\d+", r"\1", ts.replace("Z", "+00:00"))
    try:
        return datetime.fromisoformat(ts).timestamp()
    except ValueError:
        return None


def burst_tokens(conn: sqlite3.Connection, email: str, since: float) -> float:
    """Weighted tokens this account served since epoch `since`."""
    total = 0.0
    rows = conn.execute(
        "SELECT ts, input_tokens, output_tokens, cached_tokens FROM usage "
        "WHERE source = ? ORDER BY rowid DESC LIMIT 5000",
        (email,),
    )
    for ts, inp, out, cached in rows:
        t = _parse_ts(ts or "")
        if t is None or t < since:
            break
        total += (inp or 0) + 5 * (out or 0) + 0.1 * (cached or 0)
    return total


def signals_reading(f: dict):
    """((5h, 7d, [(window, pct)]), observed_epoch, hard) from CLIProxyAPI's
    per-auth quota snapshot, or None if there is no usable snapshot."""
    q = f.get("quota") or {}
    sig = {k.lower(): str(v) for k, v in (q.get("signals") or {}).items()}
    obs = _parse_ts(q.get("observed_at") or "")
    if not sig or not obs or obs < 1e9:
        return None
    pre = "anthropic-ratelimit-unified-"
    util = week = None
    scoped: list[tuple[str, float]] = []
    hard = False
    for k, v in sig.items():
        if not k.startswith(pre):
            continue
        rest = k[len(pre):]
        if rest.endswith("-status") or rest == "status":
            if v.strip().lower() in ("rejected", "allowed_warning"):
                hard = True
        if not rest.endswith("-utilization"):
            continue
        win = rest[: -len("-utilization")]
        try:
            pct = float(v) * 100
        except ValueError:
            continue
        if win == "5h":
            util = pct
        elif win == "7d":
            week = pct
        else:
            scoped.append((win, pct))
    if util is None and week is None and not scoped:
        return None
    return (util, week, scoped), obs, hard


# email -> {"next": epoch, "backoff": secs, "last": Usage, "last_ts": epoch}
_STATE: dict[str, dict] = {}
_PAUSED_LOGGED: set[str] = set()


def log(msg: str) -> None:
    print(f"[fivehour-guard] {msg}", flush=True)


def init_guard_db(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS account_guard (
            email       TEXT PRIMARY KEY,
            enabled     INTEGER NOT NULL DEFAULT 1,
            auto_held   INTEGER NOT NULL DEFAULT 0,
            held_at     TEXT,
            last_util   REAL,
            last_check  TEXT,
            updated_at  TEXT
        )
        """
    )
    # Last good usage reading, so the fail-safe survives restarts.
    for col, typ in (("last_reading", "TEXT"), ("last_reading_ts", "REAL")):
        try:
            conn.execute(f"ALTER TABLE account_guard ADD COLUMN {col} {typ}")
        except sqlite3.OperationalError:
            pass  # already exists
    conn.commit()


def save_reading(conn: sqlite3.Connection, email: str, reading: tuple, ts: float) -> None:
    util, week, scoped = reading
    conn.execute(
        "UPDATE account_guard SET last_reading=?, last_reading_ts=? WHERE email=?",
        (json.dumps({"five_hour": util, "seven_day": week, "scoped": scoped}), ts, email),
    )
    conn.commit()


def load_reading(conn: sqlite3.Connection, email: str) -> tuple[tuple | None, float]:
    row = conn.execute(
        "SELECT last_reading, last_reading_ts FROM account_guard WHERE email=?", (email,)
    ).fetchone()
    if not row or not row[0]:
        return None, 0.0
    try:
        d = json.loads(row[0])
        scoped = [(m, float(p)) for m, p in d.get("scoped") or []]
        return (d.get("five_hour"), d.get("seven_day"), scoped), float(row[1] or 0)
    except Exception:
        return None, 0.0


def ensure_default_guards(conn: sqlite3.Connection, emails: list[str]) -> None:
    """Every known account gets guard ON unless explicitly turned off."""
    now = _now()
    for email in emails:
        email = (email or "").strip().lower()
        if not email:
            continue
        conn.execute(
            """
            INSERT INTO account_guard (email, enabled, auto_held, updated_at)
            VALUES (?, 1, 0, ?)
            ON CONFLICT(email) DO NOTHING
            """,
            (email, now),
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


class RateLimited(RuntimeError):
    def __init__(self, msg: str, retry_after: float | None):
        super().__init__(msg)
        self.retry_after = retry_after


def fetch_util(token: str) -> tuple[float | None, float | None, list[tuple[str, float]]]:
    """Return (five_hour, seven_day, [(model, pct)...] per-model weekly limits)."""
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
        if e.code == 429:
            ra = e.headers.get("retry-after") if e.headers else None
            try:
                ra_secs = float(ra) if ra else None
            except ValueError:
                ra_secs = None
            raise RateLimited(msg, ra_secs) from e
        raise RuntimeError(msg) from e
    def pct(key: str) -> float | None:
        v = (body.get(key) or {}).get("utilization")
        return None if v is None else float(v)

    scoped = []
    for lim in body.get("limits") or []:
        if lim.get("kind") != "weekly_scoped" or lim.get("percent") is None:
            continue
        model = ((lim.get("scope") or {}).get("model") or {}).get("display_name") or "scoped"
        scoped.append((model, float(lim["percent"])))
    return pct("five_hour"), pct("seven_day"), scoped


def hold_reasons(util, week, scoped) -> list[str]:
    reasons = []
    if util is not None and util >= THRESHOLD:
        reasons.append(f"5h={util:.0f}% >= {THRESHOLD:.0f}%")
    if week is not None and week >= WEEKLY_THRESHOLD:
        reasons.append(f"7d={week:.0f}% >= {WEEKLY_THRESHOLD:.0f}%")
    for model, p in scoped:
        if p >= SCOPED_THRESHOLD:
            reasons.append(f"7d {model}={p:.0f}% >= {SCOPED_THRESHOLD:.0f}%")
    return reasons


def headroom(util, week, scoped) -> float:
    """Smallest gap (in %) between any reading and its threshold."""
    gaps = []
    if util is not None:
        gaps.append(THRESHOLD - util)
    if week is not None:
        gaps.append(WEEKLY_THRESHOLD - week)
    gaps += [SCOPED_THRESHOLD - p for _, p in scoped]
    return min(gaps) if gaps else 100.0


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

    try:
        files = auth_files_api()
    except Exception as e:
        log(f"auth-files list failed: {e}")
        return

    emails = [(f.get("email") or "").lower() for f in files if f.get("email")]
    ensure_default_guards(conn, emails)
    by_email = {g["email"].lower(): g for g in list_guards(conn)}

    for f in files:
        email = (f.get("email") or "").lower()
        if not email:
            continue
        g = by_email.get(email) or {
            "email": email,
            "enabled": True,
            "auto_held": False,
        }
        # Guard OFF and not currently auto-held → skip (inner flag removed).
        # Still process auto_held rows so a stuck HOLD can release.
        if not g.get("enabled") and not g.get("auto_held"):
            continue

        name = f.get("name") or ""
        disabled = bool(f.get("disabled"))
        auto_held = bool(g.get("auto_held"))

        # High-level PAUSE: never touch routing; do not convert to HOLD.
        if disabled and not auto_held:
            if email not in _PAUSED_LOGGED:
                log(f"{email}: manually PAUSED (high-level); guard skips")
                _PAUSED_LOGGED.add(email)
            time.sleep(0.2)
            continue

        _PAUSED_LOGGED.discard(email)
        st = _STATE.get(email)
        if st is None:
            last, last_ts = load_reading(conn, email)
            st = _STATE[email] = {"next": 0.0, "backoff": 0.0, "last": last, "last_ts": last_ts, "tried": 0.0}
        now = time.time()
        burst = 0.0
        if st["last_ts"]:
            try:
                burst = burst_tokens(conn, email, st["last_ts"])
            except Exception as e:
                log(f"{email}: burst check failed: {e}")
        # Huge burst since the last good reading and still not polled: hold first.
        if burst >= BURST_HOLD_TOKENS and not auto_held and now - st["last_ts"] >= MIN_POLL_GAP_SECS and st["backoff"]:
            try:
                set_disabled(name, True)
                set_auto_held(conn, email, True, st["last"][0] if st["last"] else None)
                auto_held = True
                log(f"{email}: HOLD on (fail-safe: {burst:,.0f} weighted tokens since last reading, usage unreadable)")
            except Exception as e:
                log(f"{email}: failed to HOLD: {e}")
        # Live reading: CLIProxyAPI records Anthropic's anthropic-ratelimit-unified-*
        # headers from every response it proxies. Fresh, free, no usage-API call.
        live = signals_reading(f)
        if live and live[1] > st["last_ts"] + 0.5:
            (util, week, scoped), now, hard = live
            if not scoped and st["last"]:
                scoped = st["last"][2]  # headers lack per-model weekly; keep the API's
            src = "live"
            st["next"] = max(st["next"], time.time() + SLOW_POLL_SECS)
        else:
            hard, src = False, "api"
            if now < st["next"]:
                if burst < BURST_POLL_TOKENS or now - st["tried"] < MIN_POLL_GAP_SECS:
                    continue
                log(f"{email}: burst {burst:,.0f} weighted tokens since last reading; polling early")
            st["tried"] = now

            token = load_token(name)
            if not token:
                log(f"{email}: no access_token; skip")
                continue

            try:
                util, week, scoped = fetch_util(token)
            except Exception as e:
                base = e.retry_after if isinstance(e, RateLimited) and e.retry_after else 0
                st["backoff"] = min(max(st["backoff"] * 2, POLL_SECS * 2, base), MAX_BACKOFF_SECS)
                st["next"] = now + st["backoff"]
                last, age = st["last"], now - st["last_ts"]
                # Fail-safe: we can't see usage. If the last good reading was close to a
                # limit (or we already hold), keep/apply the hold rather than fly blind.
                if last and age <= FAILSAFE_MAX_AGE_SECS and headroom(*last) <= FAILSAFE_MARGIN:
                    if not auto_held:
                        try:
                            set_disabled(name, True)
                            set_auto_held(conn, email, True, last[0])
                            log(f"{email}: HOLD on (fail-safe: usage read failed, last reading within {FAILSAFE_MARGIN:.0f}% of a limit)")
                        except Exception as e2:
                            log(f"{email}: failed to HOLD: {e2}")
                    else:
                        log(f"{email}: HOLD stays (usage read failed: {e}; retry in {st['backoff']:.0f}s)")
                else:
                    log(f"{email}: usage fetch failed: {e}; retry in {st['backoff']:.0f}s")
                continue

        st["backoff"] = 0.0
        st["last"], st["last_ts"] = (util, week, scoped), now
        save_reading(conn, email, st["last"], now)
        if src == "api":
            gap = headroom(util, week, scoped)
            st["next"] = now + (SLOW_POLL_SECS if gap > 30 else POLL_SECS)

        touch_check(conn, email, util)
        if util is None and week is None and not scoped:
            log(f"{email}: no utilization data; skip")
            time.sleep(0.35)
            continue

        reasons = hold_reasons(util, week, scoped)
        if hard:
            reasons.append("Anthropic status warning/rejected")
        why = ", ".join(reasons)
        state = f"5h={util if util is not None else 0:.0f}%, 7d={week if week is not None else 0:.0f}%" + "".join(
            f", 7d {m}={p:.0f}%" for m, p in scoped
        )

        if reasons:
            if auto_held:
                log(f"{email}: HOLD stays ({why})")
            else:
                try:
                    set_disabled(name, True)
                    set_auto_held(conn, email, True, util)
                    log(f"{email}: HOLD on ({why})")
                except Exception as e:
                    log(f"{email}: failed to HOLD: {e}")
        elif auto_held and headroom(util, week, scoped) <= FAILSAFE_MARGIN:
            # Hysteresis: don't release while still near a limit (e.g. 7d Fable 82%).
            log(f"{email}: HOLD stays (near a limit: {state})")
        else:
            if auto_held:
                try:
                    set_disabled(name, False)
                    set_auto_held(conn, email, False, util)
                    log(f"{email}: HOLD off ({state}) - back in round-robin")
                except Exception as e:
                    log(f"{email}: failed to release HOLD: {e}")
            elif g.get("enabled") and (src == "api" or st.get("logged") != state):
                log(f"{email}: ok ({state}) [{src}]")
                st["logged"] = state

        time.sleep(0.35)


def guard_enabled() -> bool:
    return os.environ.get("GUARD_ENABLED", "true").lower() not in ("0", "false", "no", "off")
