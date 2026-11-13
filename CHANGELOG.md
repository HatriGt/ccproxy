# Changelog

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
