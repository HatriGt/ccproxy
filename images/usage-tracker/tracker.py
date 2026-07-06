#!/usr/bin/env python3
"""Drain CLIProxyAPI's usage-queue and persist per-request token usage to SQLite.

The upstream /v0/management/usage-queue endpoint POPs records (they're gone once
read), so this sidecar continuously drains them into a durable store that the
`usage-cli` reads for day-wise, per-user reporting.
"""
import json
import os
import sqlite3
import sys
import time
import urllib.error
import urllib.request

UPSTREAM = os.environ.get("CLIPROXY_UPSTREAM", "http://cli-proxy-api:8318").rstrip("/")
MGMT_KEY = os.environ.get("CLIPROXY_MGMT_KEY", "")
DB_PATH = os.environ.get("USAGE_DB_PATH", "/data/usage/usage.db")
POLL_SECS = int(os.environ.get("USAGE_POLL_SECS", "15"))
BATCH = int(os.environ.get("USAGE_BATCH", "200"))

QUEUE_URL = f"{UPSTREAM}/v0/management/usage-queue?count={BATCH}"


def log(msg):
    print(f"[usage-tracker] {msg}", flush=True)


def init_db(conn):
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS usage (
            request_id       TEXT PRIMARY KEY,
            ts               TEXT NOT NULL,
            day              TEXT NOT NULL,
            source           TEXT NOT NULL,
            provider         TEXT,
            model            TEXT,
            alias            TEXT,
            input_tokens     INTEGER DEFAULT 0,
            output_tokens    INTEGER DEFAULT 0,
            reasoning_tokens INTEGER DEFAULT 0,
            cached_tokens    INTEGER DEFAULT 0,
            total_tokens     INTEGER DEFAULT 0,
            failed           INTEGER DEFAULT 0,
            latency_ms       INTEGER DEFAULT 0
        )
        """
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_day ON usage(day)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_usage_src ON usage(source)")
    conn.commit()


def fetch_batch():
    req = urllib.request.Request(QUEUE_URL, headers={"Authorization": f"Bearer {MGMT_KEY}"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read().decode("utf-8") or "[]")


def store(conn, records):
    n = 0
    for r in records:
        tokens = r.get("tokens") or {}
        ts = r.get("timestamp") or ""
        day = ts[:10] if len(ts) >= 10 else time.strftime("%Y-%m-%d")
        rid = r.get("request_id") or f"{ts}|{r.get('source','')}|{r.get('model','')}|{tokens.get('total_tokens',0)}"
        conn.execute(
            """
            INSERT OR IGNORE INTO usage (request_id, ts, day, source, provider, model,
                alias, input_tokens, output_tokens, reasoning_tokens, cached_tokens,
                total_tokens, failed, latency_ms)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            (
                rid, ts, day,
                r.get("source") or "unknown",
                r.get("provider"), r.get("model"), r.get("alias"),
                int(tokens.get("input_tokens", 0)),
                int(tokens.get("output_tokens", 0)),
                int(tokens.get("reasoning_tokens", 0)),
                int(tokens.get("cached_tokens", 0)),
                int(tokens.get("total_tokens", 0)),
                1 if r.get("failed") else 0,
                int(r.get("latency_ms", 0)),
            ),
        )
        n += conn.total_changes and 1 or 0
    conn.commit()
    return len(records)


def main():
    if not MGMT_KEY:
        log("ERROR: CLIPROXY_MGMT_KEY not set; cannot read usage queue. Exiting.")
        sys.exit(1)
    os.makedirs(os.path.dirname(DB_PATH), exist_ok=True)
    conn = sqlite3.connect(DB_PATH)
    init_db(conn)
    log(f"started: upstream={UPSTREAM} db={DB_PATH} poll={POLL_SECS}s batch={BATCH}")
    while True:
        try:
            drained = 0
            # Drain until the queue is empty, then sleep.
            while True:
                records = fetch_batch()
                if not records:
                    break
                store(conn, records)
                drained += len(records)
                if len(records) < BATCH:
                    break
            if drained:
                log(f"stored {drained} record(s)")
        except urllib.error.URLError as e:
            log(f"upstream not ready ({e}); retrying")
        except Exception as e:  # keep the sidecar alive
            log(f"error: {e}")
        time.sleep(POLL_SECS)


if __name__ == "__main__":
    main()
