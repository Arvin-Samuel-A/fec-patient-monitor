#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi

EDGE_URL="${EDGE_URL:-${EDGE_A_URL:-http://127.0.0.1:8081/ingest}}"
FOG_ALERTS_URL="${FOG_ALERTS_URL:-http://${FOG_HOST:-127.0.0.1}:${HTTP_PORT:-${FOG_PORT:-3000}}/alerts}"

DEVICE_ID="${DEVICE_ID:-manual_alert_001}"
HEART_RATE="${HEART_RATE:-170.0}"
SPO2="${SPO2:-85.0}"
TEMPERATURE="${TEMPERATURE:-39.4}"
TIMESTAMP="${TIMESTAMP:-$(date -u +"%Y-%m-%dT%H:%M:%SZ")}"

payload=$(cat <<JSON
{"device_id":"$DEVICE_ID","timestamp":"$TIMESTAMP","heart_rate":$HEART_RATE,"spo2":$SPO2,"temperature":$TEMPERATURE}
JSON
)

echo "Sending abnormal test reading to: $EDGE_URL"
echo "Payload: $payload"

response=$(curl -sS -X POST "$EDGE_URL" \
  -H "Content-Type: application/json" \
  -d "$payload" \
  -w "\nHTTP_STATUS:%{http_code}")

status=$(printf "%s\n" "$response" | awk -F: '/HTTP_STATUS/{print $2}')
body=$(printf "%s\n" "$response" | sed '/HTTP_STATUS:/d')

echo
echo "Edge response status: $status"
echo "Edge response body: $body"

if [ "$status" != "200" ]; then
  echo "Alert trigger request failed."
  exit 1
fi

echo
echo "Latest alerts from Fog: $FOG_ALERTS_URL?limit=5"
curl -sS "$FOG_ALERTS_URL?limit=5"
echo