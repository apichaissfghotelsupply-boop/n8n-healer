# n8n-healer

A tiny watchdog that keeps a self-hosted **n8n** instance alive.

The instance occasionally becomes a "zombie" (returns `503` / `Database is not
ready`) after an internal network hiccup and does not recover until it is
restarted. This repository runs a scheduled GitHub Actions job that:

1. Checks the n8n URL every ~5 minutes (retried 3× to ignore transient blips).
2. If it is genuinely down, triggers a **Railway** redeploy of the service.
3. Waits ~2 minutes and re-checks.
4. Optionally pushes the result to a **LINE** group.

## No secrets in this repo

Every identifying value is stored in **GitHub → Settings → Secrets and
variables → Actions**, never in the code:

| Secret | Required | Purpose |
| --- | --- | --- |
| `N8N_URL` | ✅ | Public URL of the n8n instance to health-check |
| `RAILWAY_TOKEN` | ✅ | Railway **Project** token (uses the `Project-Access-Token` header) |
| `RAILWAY_SERVICE_ID` | ✅ | ID of the n8n service |
| `RAILWAY_ENVIRONMENT_ID` | ✅ | ID of the `production` environment |
| `LINE_CHANNEL_ID` | optional | LINE OA channel ID (Provider → Channel → Basic settings) |
| `LINE_CHANNEL_SECRET` | optional | LINE OA channel secret (same page) |
| `ADMIN_GROUP_ID` | optional | LINE group ID to notify (needs all three LINE secrets) |

The healer fetches a channel access token fresh on every run via LINE's
`client_credentials` OAuth flow, so no long-lived token needs to be
managed here.

## Running it

- **Automatic:** every 5 minutes via the `schedule` trigger.
- **Manual:** Actions tab → *n8n-healer* → **Run workflow**.

## Notes

- GitHub cron is best-effort, so real detection latency is typically **5–15
  minutes**, not exactly 5.
- A `keepalive` step pushes an empty commit if the repo has been idle for 45+
  days, so GitHub does not auto-disable the scheduled workflow after 60 days.
- A run is marked **failed (red)** only when n8n did **not** come back after a
  restart — an at-a-glance signal that something needs a human.
