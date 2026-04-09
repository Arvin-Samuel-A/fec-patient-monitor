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
DEVICE_ID="${DEVICE_ID:-device_001}"
INTERVAL="${INTERVAL:-1}"


echo "Starting IoT simulator"
echo "Device ID: ${DEVICE_ID}"
echo "Target Edge URL: ${EDGE_URL}"

uv run --project iot iot/device.py \
  --device-id "${DEVICE_ID}" \
  --edge-url "${EDGE_URL}" \
  --interval "${INTERVAL}"
