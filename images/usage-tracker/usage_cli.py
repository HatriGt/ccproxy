#!/usr/bin/env python3
"""Day-wise token usage report from the usage-tracker SQLite store.

Examples:
  usage-cli                       # last 7 days, per day x user
  usage-cli --days 30             # last 30 days
  usage-cli --from 2026-07-01 --to 2026-07-06
  usage-cli --by-model            # per day x user x model
  usage-cli --json                # machine-readable
"""
import argparse
import datetime as dt
import json
import os
import sqlite3

DB_PATH = os.environ.get("USAGE_DB_PATH", "/data/usage/usage.db")


def parse_args():
    p = argparse.ArgumentParser(description="Day-wise ccproxy token usage")
    p.add_argument("--days", type=int, default=7, help="last N days (default 7)")
    p.add_argument("--from", dest="date_from", help="start date YYYY-MM-DD")
    p.add_argument("--to", dest="date_to", help="end date YYYY-MM-DD")
    p.add_argument("--by-model", action="store_true", help="break down by model too")
    p.add_argument("--user", help="filter to one user (source)")
    p.add_argument("--json", action="store_true", help="JSON output")
    p.add_argument("--db", default=DB_PATH, help="SQLite path")
    return p.parse_args()


def date_range(args):
    if args.date_from:
        start = args.date_from
    else:
        start = (dt.date.today() - dt.timedelta(days=args.days - 1)).isoformat()
    end = args.date_to or dt.date.today().isoformat()
    return start, end


def query(conn, args, start, end):
    cols = "day, source" + (", model" if args.by_model else "")
    where = ["day >= ?", "day <= ?"]
    params = [start, end]
    if args.user:
        where.append("source = ?")
        params.append(args.user)
    sql = f"""
        SELECT {cols},
               SUM(input_tokens)  AS input_tokens,
               SUM(output_tokens) AS output_tokens,
               SUM(reasoning_tokens) AS reasoning_tokens,
               SUM(cached_tokens) AS cached_tokens,
               SUM(total_tokens)  AS total_tokens,
               COUNT(*)           AS requests,
               SUM(failed)        AS failed
        FROM usage
        WHERE {' AND '.join(where)}
        GROUP BY {cols}
        ORDER BY day DESC, total_tokens DESC
    """
    conn.row_factory = sqlite3.Row
    return [dict(r) for r in conn.execute(sql, params).fetchall()]


def human(n):
    return f"{n:,}"


def print_table(rows, by_model):
    if not rows:
        print("No usage recorded for this range.")
        return
    if by_model:
        header = f"{'DATE':<11} {'USER':<28} {'MODEL':<26} {'IN':>10} {'OUT':>10} {'TOTAL':>12} {'REQ':>6}"
    else:
        header = f"{'DATE':<11} {'USER':<28} {'IN':>10} {'OUT':>10} {'TOTAL':>12} {'REQ':>6}"
    print(header)
    print("-" * len(header))
    tot = {"input": 0, "output": 0, "total": 0, "req": 0}
    for r in rows:
        tot["input"] += r["input_tokens"]
        tot["output"] += r["output_tokens"]
        tot["total"] += r["total_tokens"]
        tot["req"] += r["requests"]
        if by_model:
            print(f"{r['day']:<11} {r['source'][:28]:<28} {(r['model'] or '-')[:26]:<26} "
                  f"{human(r['input_tokens']):>10} {human(r['output_tokens']):>10} "
                  f"{human(r['total_tokens']):>12} {r['requests']:>6}")
        else:
            print(f"{r['day']:<11} {r['source'][:28]:<28} "
                  f"{human(r['input_tokens']):>10} {human(r['output_tokens']):>10} "
                  f"{human(r['total_tokens']):>12} {r['requests']:>6}")
    print("-" * len(header))
    label = "TOTAL"
    pad = 40 if not by_model else 66
    print(f"{label:<{pad}} {human(tot['input']):>10} {human(tot['output']):>10} "
          f"{human(tot['total']):>12} {tot['req']:>6}")


def main():
    args = parse_args()
    start, end = date_range(args)
    if not os.path.exists(args.db):
        print(f"No usage DB yet at {args.db} (tracker may not have run).")
        return
    conn = sqlite3.connect(args.db)
    rows = query(conn, args, start, end)
    if args.json:
        print(json.dumps({"from": start, "to": end, "rows": rows}, indent=2))
    else:
        print(f"ccproxy token usage  {start} -> {end}\n")
        print_table(rows, args.by_model)


if __name__ == "__main__":
    main()
