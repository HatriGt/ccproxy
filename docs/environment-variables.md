# Environment variables

All variables live in **`.env`** (gitignored). Copy from `.env.example`.

Scripts auto-load via `scripts/load-env.sh`.

## Docker Compose

| Variable | Default | Description |
|----------|---------|-------------|
| `COMPOSE_PROJECT_NAME` | `ccproxy` | Docker Compose project name |
| `CLIPROXY_IMAGE_TAG` | `v7.1.63` | Upstream `eceasy/cli-proxy-api` tag |
| `CLIPROXY_API_IMAGE` | `ccproxy-cli-proxy-api:local` | Built API image name |
| `CURSOR_SHIM_IMAGE` | `ccproxy-cursor-shim:local` | Built shim image name |

## Public URL (Cursor)

| Variable | Description |
|----------|-------------|
| `PUBLIC_HOSTNAME` | e.g. `cliproxy.yourdomain.com` |
| `PUBLIC_URL` | `https://$PUBLIC_HOSTNAME` |
| `CURSOR_BASE_URL` | `https://$PUBLIC_HOSTNAME/v1` — **Cursor OpenAI override** |

## API authentication

| Variable | Default | Description |
|----------|---------|-------------|
| `CLIPROXY_API_KEY` | `dummy` | Bearer token Cursor sends; must match `api-keys` in `config/config.yaml` |
| `CLIPROXY_MGMT_KEY` | — | Plain key for management API (if enabled) |
| `CLIPROXY_REMOTE_MGMT_SECRET_KEY` | — | Bcrypt/plain secret in `config/config.yaml` `remote-management.secret-key` |

## Logging / telemetry

Rendered into `config.yaml` at container start by `images/cli-proxy-api/entrypoint.sh`
(from `config/config.yaml.template`). Flip to `true` only when debugging — request
and file logs grow fast on disk.

| Variable | Default | Description |
|----------|---------|-------------|
| `CCPROXY_DEBUG` | `false` | Verbose debug logging |
| `CCPROXY_LOGGING_TO_FILE` | `false` | Write logs to files (disk-heavy) |
| `CCPROXY_REQUEST_LOG` | `false` | Per-request logs (disk-heavy) |
| `CCPROXY_USAGE_STATS` | `true` | Publish usage to the queue (needed for token tracking) |

## Usage tracking (per-user token stats)

The `usage-tracker` sidecar drains `/v0/management/usage-queue` into SQLite so the
`usage-cli` can report day-wise, per-user token consumption. Requires remote
management (internal-only; port 8318 is never published to the host).

| Variable | Default | Description |
|----------|---------|-------------|
| `CCPROXY_ALLOW_REMOTE_MGMT` | `true` | Enable mgmt API for the sidecar (compose-network only) |
| `CCPROXY_MGMT_SECRET_KEY` | `$CLIPROXY_MGMT_KEY` | Mgmt secret in config; falls back to `CLIPROXY_MGMT_KEY` |
| `USAGE_TRACKER_IMAGE` | `ccproxy-usage-tracker:local` | Built tracker image name |
| `USAGE_POLL_SECS` | `15` | Queue drain interval |
| `USAGE_BATCH` | `200` | Records per drain call |

**Read the report** (SQLite lives in the `cliproxy-usage` volume):

```bash
# last 7 days, per day x user
docker compose exec usage-tracker usage-cli
docker compose exec usage-tracker usage-cli --days 30
docker compose exec usage-tracker usage-cli --by-model
docker compose exec usage-tracker usage-cli --from 2026-07-01 --to 2026-07-06
docker compose exec usage-tracker usage-cli --user a.ravichandran --json
```

## Service ports (Docker)

| Variable | Default | Description |
|----------|---------|-------------|
| `CLIPROXY_PORT` | `8318` | CLIProxyAPI internal port |
| `CURSOR_SHIM_PORT` | `8320` | Shim port (published on VPS host) |
| `CURSOR_SHIM_HOST` | `0.0.0.0` | Shim bind address in container |
| `CLIPROXY_UPSTREAM` | `http://cli-proxy-api:8318` | Shim → API URL inside compose |

## Mac local shim

| Variable | Default |
|----------|---------|
| `CLIPROXY_UPSTREAM_LOCAL` | `http://127.0.0.1:8318` |
| `CURSOR_SHIM_HOST_LOCAL` | `127.0.0.1` |

## VPS deploy

| Variable | Default | Description |
|----------|---------|-------------|
| `VPS_SSH_HOST` | — | SSH host (`~/.ssh/config` alias or `user@ip`) |
| `CLIPROXY_VPS_SSH_HOST` | same as above | Alias used by some scripts |
| `VPS_PUBLIC_IP` | — | For DNS docs / verification |
| `VPS_DEPLOY_DIR` | `/opt/ccproxy` | Remote repo path |
| `CLIPROXY_VPS_BRIDGE_PORT` | `18320` | Legacy socat port (unused after Docker deploy) |
| `CLIPROXY_VPS_TUNNEL_PORT` | `18321` | Legacy SSH tunnel port |
| `CLIPROXY_VPS_TRAEFIK_FILE` | `cliproxy-cursor.yml` | Traefik dynamic config filename |

## Health checks

| Variable | Default |
|----------|---------|
| `CLIPROXY_TEST_MODEL` | `ak-claude-sonnet-4.6` |
| `CLIPROXY_TEST_RETRIES` | `20` |
| `CLIPROXY_TEST_RETRY_SECS` | `3` |
| `CURSOR_CLAUDE_WAIT_SECS` | `45` |

## Mac-only (optional legacy)

| Variable | Purpose |
|----------|---------|
| `CLIPROXY_TUNNEL_MODE` | `vps` \| `quick` \| `named` |
| `CLIPROXY_AUTH_DIR` | `~/.cli-proxy-api` — source for `copy-auth-from-mac.sh` |
| `CLIPROXY_CONFIG` | VibeProxy merged config path |
| `CLIPROXY_TUNNEL_URL_FILE` | Saved public URL file |

See `.env.example` for the full list.
