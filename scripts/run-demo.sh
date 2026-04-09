#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

cat <<'EOF'
FEC Patient Monitoring now runs in LAN HTTP mode.

Run components on separate systems:

1) Fog system
   ./scripts/run-fog-http.sh

2) Edge system (A or B)
   export FOG_URL=http://<fog-ip>:<fog-port>/data
   ./scripts/run-edge-a-http.sh
   # or ./scripts/run-edge-b-http.sh

3) IoT system
   uv run --project iot iot/device.py \
     --device-id device_001 \
     --edge-url http://<edge-ip>:<edge-port>/ingest \
     --interval 1

Dashboard:
   http://<fog-ip>:<fog-port>/

Fog APIs:
   /alerts /logs /readings /stats /health
EOF
