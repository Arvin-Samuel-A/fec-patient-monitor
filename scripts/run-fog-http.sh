#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

if [ -f "$ROOT/.env" ]; then
  set -a
  . "$ROOT/.env"
  set +a
fi

export HTTP_PORT="${HTTP_PORT:-${FOG_PORT:-8080}}"

echo "Starting Fog HTTP service on port ${HTTP_PORT}"
echo "S3 logging: ${ENABLE_S3_LOGGING:-false}, bucket: ${S3_BUCKET_NAME:-unset}"
echo "Lambda notifications: ${ENABLE_LAMBDA_NOTIFICATIONS:-false}, function: ${LAMBDA_FUNCTION_NAME:-unset}"

cd "$ROOT/fog"
go run .
