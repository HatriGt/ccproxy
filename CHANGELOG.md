# Changelog

## 2026-11-15 — per-model blocks, live overview, upgrade

- **Per-model weekly limits block only that model** on the account (via the
  account's `excluded_models`, e.g. `*fable*`); other models keep working.
- **Weekly and per-model weekly thresholds default to 95%** (5-hour stays 85%).
  Defaults live in `docker-compose.yml`, so redeploys that rewrite `.env` keep them.
- **Only Anthropic `rejected` status forces a hold.** `allowed_warning` (sent from
  75% weekly) and `Overage-Status: rejected` (paid overage off) are ignored.
- **`ccproxy overview --live`** shows live usage from proxied responses with no
  usage-API calls; **`--watch`** refreshes it with a countdown
  (`OVERVIEW_WATCH_SECS`, default 5).
- CLIProxyAPI upstream bumped to **v8.0.72**.
- **Smaller weekly safety margin (3 points, `GUARD_WEEKLY_MARGIN`)**: with the old
  10-point margin, an account at 86% weekly against a 95% limit stayed held until
  the weekly reset. The 5-hour margin stays 10.

### How a hold happens

1. **Every request** — the proxy picks an account (round-robin). Anthropic's
   response carries that account's current 5-hour and weekly usage, which the
   proxy remembers.
2. **Every 15s the guard checks each account**
   - Manually paused → ignored.
   - Fresh usage from a recent response → used (fastest source).
   - No recent traffic → asks the usage API every 1–5 min (also the only source
     of per-model numbers).
   - Sudden token spike → checks immediately.
3. **Compare to limits**

   | Reading | Limit | Result |
   |---|---|---|
   | 5-hour usage | 85% | whole account on HOLD |
   | Weekly usage | 95% | whole account on HOLD |
   | One model's weekly (e.g. Fable) | 95% | only that model blocked on the account |
   | Anthropic status `rejected` | — | whole account on HOLD |

4. **Usage can't be read** (rate-limited) → HOLD to be safe if the last reading
   was near a limit (5-hour within 10 points, weekly within 3) or a big token spike happened since; otherwise retry later.
5. **While held** — the account is out of rotation; other accounts take traffic.
6. **Release** — only after a successful reading below the safety margin
   (5-hour < 75%, weekly < 92%). A failed check never releases a hold.

## 2026-11-13 — usage guard hardening

- **Thresholds**: auto-hold now triggers at 85% (default) for the 5-hour window, the
  weekly window, and per-model weekly limits (`GUARD_FIVEHOUR_PCT`,
  `GUARD_WEEKLY_PCT`, `GUARD_SCOPED_PCT`).
- **Hysteresis**: a hold is released only when every limit is at least 10% below its
  threshold, so accounts don't flap back in mid-burst.
- **Live readings**: the guard reads CLIProxyAPI's per-account quota snapshot
  (Anthropic `anthropic-ratelimit-unified-*` response headers) on every tick
  (`GUARD_TICK_SECS`, default 15s). A `rejected` / `allowed_warning` status holds
  immediately. The OAuth usage endpoint is only a fallback.
- **Rate-limit-safe polling**: per-account poll schedule (fast near a limit, slow
  otherwise) with exponential backoff that honours `Retry-After`.
- **Fail-safes**: when usage can't be read, hold if the last reading was close to a
  limit, or if the account served a large token burst since then
  (`GUARD_BURST_POLL_TOKENS`, `GUARD_BURST_HOLD_TOKENS`).
- **Persisted readings**: last reading per account is stored in `account_guard`
  and reloaded after restarts.
- Quieter logs for manually paused accounts.
