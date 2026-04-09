#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

CLI_PORT="${PORT:-}"
CLI_FOG_URL="${FOG_URL:-}"

if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi

if [ -n "$CLI_PORT" ]; then
  export PORT="$CLI_PORT"
else
  export PORT="${EDGE_B_PORT:-8082}"
fi

if [ -n "$CLI_FOG_URL" ]; then
  export FOG_URL="$CLI_FOG_URL"
else
  export FOG_URL="${FOG_URL:-http://${FOG_HOST:-127.0.0.1}:${FOG_PORT:-8080}/data}"
fi

echo "Starting Edge-B on port ${PORT}"
echo "Forwarding to Fog URL: ${FOG_URL}"

uv run --project edge-b uvicorn main:app --host 0.0.0.0 --port "${PORT}" --app-dir edge-b
