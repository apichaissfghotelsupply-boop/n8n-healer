#!/usr/bin/env bash
#
# n8n Auto-Healer
# ----------------
# Watches an n8n instance. If it has become a "zombie" (503 / "Database is not
# ready" / unreachable), it triggers a Railway redeploy of the service, waits,
# re-checks, and (optionally) notifies a LINE group with the result.
#
# ALL identifying values come from environment variables (GitHub Secrets).
# Nothing sensitive is hard-coded here.
#
#   Required : N8N_URL, RAILWAY_TOKEN, RAILWAY_SERVICE_ID, RAILWAY_ENVIRONMENT_ID
#   Optional : LINE_TOKEN, ADMIN_GROUP_ID   (both must be set to enable LINE push)
#
# Exit code: 0 = healthy or recovered, 1 = still down after restart attempt.

set -uo pipefail

GRAPHQL="https://backboard.railway.com/graphql/v2"

log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }

: "${N8N_URL:?N8N_URL is required}"

# probe: returns 0 if healthy, 1 if unhealthy. Exports HTTP_CODE for logging.
# Healthy = HTTP 200 AND body does not contain "Database is not ready".
probe() {
  local body_file code
  body_file="$(mktemp)"
  code="$(curl -s -o "$body_file" -w '%{http_code}' -L --max-time 20 "$N8N_URL" 2>/dev/null)"
  HTTP_CODE="${code:-000}"
  if [ "$code" = "200" ] && ! grep -qi "Database is not ready" "$body_file"; then
    rm -f "$body_file"
    return 0
  fi
  rm -f "$body_file"
  return 1
}

# ---------------------------------------------------------------------------
# Phase 1 — health check (retried 3x to avoid restarting on a transient blip)
# ---------------------------------------------------------------------------
healthy=1
for attempt in 1 2 3; do
  if probe; then
    healthy=0
    log "probe #$attempt: healthy (HTTP $HTTP_CODE)"
    break
  else
    log "probe #$attempt: UNHEALTHY (HTTP $HTTP_CODE)"
    [ "$attempt" -lt 3 ] && sleep 10
  fi
done

if [ "$healthy" = "0" ]; then
  log "n8n is healthy — nothing to do."
  exit 0
fi

log "n8n confirmed DOWN after 3 probes — triggering Railway redeploy."

# ---------------------------------------------------------------------------
# Phase 2 — restart via Railway serviceInstanceRedeploy
# ---------------------------------------------------------------------------
: "${RAILWAY_TOKEN:?RAILWAY_TOKEN is required}"
: "${RAILWAY_SERVICE_ID:?RAILWAY_SERVICE_ID is required}"
: "${RAILWAY_ENVIRONMENT_ID:?RAILWAY_ENVIRONMENT_ID is required}"

redeploy_resp="$(curl -s --max-time 30 -X POST "$GRAPHQL" \
  -H 'Content-Type: application/json' \
  -H "Project-Access-Token: $RAILWAY_TOKEN" \
  --data "{\"query\":\"mutation r(\$s:String!,\$e:String!){serviceInstanceRedeploy(serviceId:\$s,environmentId:\$e)}\",\"variables\":{\"s\":\"$RAILWAY_SERVICE_ID\",\"e\":\"$RAILWAY_ENVIRONMENT_ID\"}}")"

if echo "$redeploy_resp" | grep -q '"serviceInstanceRedeploy":true'; then
  log "redeploy accepted by Railway."
else
  log "WARNING: redeploy call did not return true. Response: $redeploy_resp"
fi

# ---------------------------------------------------------------------------
# Phase 3 — wait, then re-check whether it came back
# ---------------------------------------------------------------------------
log "waiting 120s for n8n to come back..."
sleep 120

recovered=1
for attempt in 1 2 3 4 5 6; do
  if probe; then
    recovered=0
    log "recheck #$attempt: healthy (HTTP $HTTP_CODE)"
    break
  else
    log "recheck #$attempt: still down (HTTP $HTTP_CODE)"
    [ "$attempt" -lt 6 ] && sleep 15
  fi
done

if [ "$recovered" = "0" ]; then
  STATUS_TH="ฟื้นแล้ว ✅"
  log "n8n RECOVERED after restart."
else
  STATUS_TH="ยังไม่ฟื้น ❌ (ต้องเข้าไปดูเอง)"
  log "n8n STILL DOWN after restart."
fi

# ---------------------------------------------------------------------------
# Phase 4 — LINE notification (only if both LINE secrets are set)
# ---------------------------------------------------------------------------
if [ -n "${LINE_TOKEN:-}" ] && [ -n "${ADMIN_GROUP_ID:-}" ]; then
  MSG="⚠️ n8n สะดุด — ยามสั่ง restart อัตโนมัติแล้ว
สถานะ: ${STATUS_TH}
เวลา: $(date -u '+%Y-%m-%d %H:%M') UTC"
  push_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST https://api.line.me/v2/bot/message/push \
    -H "Authorization: Bearer $LINE_TOKEN" \
    -H 'Content-Type: application/json' \
    --data "$(jq -n --arg to "$ADMIN_GROUP_ID" --arg text "$MSG" \
              '{to:$to, messages:[{type:"text", text:$text}]}')")"
  log "LINE push HTTP: $push_code"
else
  log "LINE secrets not set — skipping notification."
fi

# Fail the run (visible red X in Actions) if it did not recover.
[ "$recovered" = "0" ]
