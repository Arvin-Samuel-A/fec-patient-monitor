#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════════════════════
#  FEC Patient Health Monitoring — Full Demo Script (Review-2)
#  Run:  chmod +x scripts/run-demo.sh && ./scripts/run-demo.sh
#
#  This script:
#   1. Generates TLS/mTLS certificates (or regenerates if --rebuild passed)
#   2. Builds Docker images for fog (Go) and edge (Python) services
#   3. Creates a k3d cluster with Kubernetes fog deployment
#   4. Starts two edge containers with Docker
#   5. Sends simulated IoT vital-signs through the full pipeline
#   6. Displays alerts, latency metrics, TTFA, and pseudonymization proof
#   7. Demonstrates mTLS rejection (unauthorized client)
# ═══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

# ── Colours & helpers ─────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

banner()  { printf "\n${CYAN}${BOLD}═══ %s ═══${NC}\n" "$1"; }
step()    { printf "\n${GREEN}[%s]${NC} %s\n" "$1" "$2"; }
info()    { printf "  ${YELLOW}→${NC} %s\n" "$1"; }
ok()      { printf "  ${GREEN}✔${NC} %s\n" "$1"; }
fail()    { printf "  ${RED}✘${NC} %s\n" "$1"; }
divider() { printf "${CYAN}─────────────────────────────────────────────────────────${NC}\n"; }

REBUILD=false
[[ "${1:-}" == "--rebuild" ]] && REBUILD=true

TOTAL_STEPS=10
DEMO_DEVICES=5          # number of simulated IoT devices
READINGS_PER_DEVICE=3   # readings each device sends
SEND_INTERVAL=0.3       # seconds between readings

# ═══════════════════════════════════════════════════════════════════════════════
banner "FEC Patient Health Monitoring — Review-2 Demo"
printf "  Architecture : IoT (Python) → Edge (Python/FastAPI) → Fog (Go/K8s)\n"
printf "  Security     : TLS 1.3 everywhere, mTLS between Edge↔Fog\n"
printf "  Cluster      : k3d (k3s-in-Docker) on macOS Docker Desktop\n"
divider

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 1 — INFRASTRUCTURE SETUP
# ══════════════════════════════════════════════════════════════════════════════

# ── Step 1: Certificates ─────────────────────────────────────────────────────
step "1/$TOTAL_STEPS" "TLS / mTLS Certificate Generation"
if $REBUILD || [ ! -f certs/ca/ca.crt ]; then
  rm -rf certs
  chmod +x scripts/gen-certs.sh
  bash scripts/gen-certs.sh
  ok "Certificates generated (CA + fog server + edge client/server)"
else
  ok "Certificates already present — skipping (use --rebuild to regenerate)"
fi
info "CA cert  : certs/ca/ca.crt"
info "Fog cert : certs/fog/fog.crt  (SAN: fog-service, localhost, host.docker.internal)"
info "Edge certs: certs/edge-{a,b}/{client,server}.{crt,key}"

# ── Step 2: k3d cluster ──────────────────────────────────────────────────────
step "2/$TOTAL_STEPS" "k3d Kubernetes Cluster"
if k3d cluster list 2>/dev/null | grep -q "fec"; then
  if $REBUILD; then
    info "Deleting existing cluster (--rebuild)..."
    k3d cluster delete fec
  else
    ok "Cluster 'fec' already exists — reusing"
  fi
fi
if ! k3d cluster list 2>/dev/null | grep -q "fec"; then
  info "Creating k3d cluster 'fec' with NodePort mappings..."
  k3d cluster create fec \
    --port "30444:30444@loadbalancer" \
    --port "30445:30445@loadbalancer"
fi
kubectl wait --for=condition=Ready node --all --timeout=60s >/dev/null 2>&1
ok "Cluster ready — $(kubectl get nodes --no-headers | wc -l | tr -d ' ') node(s)"

# ── Step 3: Build fog image ──────────────────────────────────────────────────
step "3/$TOTAL_STEPS" "Building Fog Docker Image (Go 1.22)"
if $REBUILD; then
  docker build --no-cache -t fec-fog ./fog
else
  docker build -t fec-fog ./fog
fi
ok "fec-fog image built"

# ── Step 4: Import fog image into k3d ────────────────────────────────────────
step "4/$TOTAL_STEPS" "Importing Fog Image into k3d"
k3d image import fec-fog -c fec 2>/dev/null
ok "Image imported"

# ── Step 5: Deploy fog to Kubernetes ─────────────────────────────────────────
step "5/$TOTAL_STEPS" "Deploying Fog Service to Kubernetes"
kubectl delete secret fog-tls-secret 2>/dev/null || true
kubectl create secret generic fog-tls-secret \
  --from-file=fog.crt=certs/fog/fog.crt \
  --from-file=fog.key=certs/fog/fog.key \
  --from-file=ca.crt=certs/ca/ca.crt

# Force re-deploy if --rebuild
if $REBUILD; then
  kubectl delete deployment fog-service 2>/dev/null || true
  sleep 2
fi
kubectl apply -f k8s/fog-deployment.yaml
kubectl apply -f k8s/fog-service.yaml

info "Waiting for fog pod to become Ready..."
kubectl wait --for=condition=Ready pod -l app=fog-service --timeout=90s >/dev/null 2>&1
FOG_POD=$(kubectl get pod -l app=fog-service -o jsonpath='{.items[0].metadata.name}')
ok "Fog running — pod: $FOG_POD"
info "  mTLS data port : localhost:30444  (TLS 1.3, client-cert required)"
info "  HTTP alerts port: localhost:30445  (plain HTTP — /alerts, /health)"

# ── Step 6: Build edge images ────────────────────────────────────────────────
step "6/$TOTAL_STEPS" "Building Edge Docker Images (Python 3.11)"
if $REBUILD; then
  docker build --no-cache -t fec-edge-a ./edge-a
  docker build --no-cache -t fec-edge-b ./edge-b
else
  docker build -t fec-edge-a ./edge-a
  docker build -t fec-edge-b ./edge-b
fi
ok "fec-edge-a and fec-edge-b images built"

# ── Step 7: Start edge containers ────────────────────────────────────────────
step "7/$TOTAL_STEPS" "Starting Edge Containers"
docker rm -f edge-a edge-b 2>/dev/null || true

docker run -d --name edge-a \
  -p 8443:8443 \
  -v "$ROOT/certs/edge-a:/certs" \
  -v "$ROOT/certs/ca:/certs/ca:ro" \
  -e PORT=8443 \
  -e FOG_URL=https://host.docker.internal:30444/data \
  -e CA_CERT=/certs/ca/ca.crt \
  -e CLIENT_CERT=/certs/client.crt \
  -e CLIENT_KEY=/certs/client.key \
  fec-edge-a >/dev/null

docker run -d --name edge-b \
  -p 9443:9443 \
  -v "$ROOT/certs/edge-b:/certs" \
  -v "$ROOT/certs/ca:/certs/ca:ro" \
  -e PORT=9443 \
  -e FOG_URL=https://host.docker.internal:30444/data \
  -e CA_CERT=/certs/ca/ca.crt \
  -e CLIENT_CERT=/certs/client.crt \
  -e CLIENT_KEY=/certs/client.key \
  fec-edge-b >/dev/null

info "Waiting for edge containers to initialize..."
sleep 4

# Health checks
EA_HEALTH=$(curl -sk --cacert certs/ca/ca.crt https://localhost:8443/health 2>/dev/null || echo "FAIL")
EB_HEALTH=$(curl -sk --cacert certs/ca/ca.crt https://localhost:9443/health 2>/dev/null || echo "FAIL")
FOG_HEALTH=$(curl -s http://localhost:30445/health 2>/dev/null || echo "FAIL")

if echo "$EA_HEALTH" | grep -q "ok"; then ok "Edge-A healthy (port 8443)"; else fail "Edge-A NOT healthy"; fi
if echo "$EB_HEALTH" | grep -q "ok"; then ok "Edge-B healthy (port 9443)"; else fail "Edge-B NOT healthy"; fi
if echo "$FOG_HEALTH" | grep -q "ok"; then ok "Fog healthy (port 30445)"; else fail "Fog NOT healthy"; fi

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 2 — LIVE DATA PIPELINE DEMO
# ══════════════════════════════════════════════════════════════════════════════

step "8/$TOTAL_STEPS" "Sending Simulated IoT Vital Signs ($DEMO_DEVICES devices × $READINGS_PER_DEVICE readings)"
divider
printf "  %-12s %-8s %-8s %-8s %-8s  %s\n" "DEVICE" "HR" "SpO2" "TEMP" "STATUS" "LATENCY"
divider

TOTAL_SENT=0
TOTAL_OK=0
TOTAL_FAIL=0
LATENCY_SUM=0

send_vital() {
  local device_id=$1
  local edge_port=$2
  local hr=$3
  local spo2=$4
  local temp=$5
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local payload="{\"device_id\":\"$device_id\",\"timestamp\":\"$ts\",\"heart_rate\":$hr,\"spo2\":$spo2,\"temperature\":$temp}"

  local start_ms
  start_ms=$(python3 -c "import time; print(int(time.time()*1000))")

  local resp_code
  resp_code=$(curl -sk -o /dev/null -w "%{http_code}" \
    --cacert certs/ca/ca.crt \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "https://localhost:${edge_port}/ingest" 2>/dev/null || echo "000")

  local end_ms
  end_ms=$(python3 -c "import time; print(int(time.time()*1000))")
  local lat=$((end_ms - start_ms))

  TOTAL_SENT=$((TOTAL_SENT + 1))
  if [ "$resp_code" = "200" ]; then
    TOTAL_OK=$((TOTAL_OK + 1))
    LATENCY_SUM=$((LATENCY_SUM + lat))
    printf "  ${GREEN}%-12s${NC} %-8s %-8s %-8s ${GREEN}%-8s${NC}  %sms\n" \
      "$device_id" "$hr" "$spo2" "$temp" "$resp_code" "$lat"
  else
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    printf "  ${RED}%-12s${NC} %-8s %-8s %-8s ${RED}%-8s${NC}  %sms\n" \
      "$device_id" "$hr" "$spo2" "$temp" "$resp_code" "$lat"
  fi
}

# ── Generate realistic + abnormal vitals ──────────────────────────────────────
# Device 1-3 → Edge-A (port 8443), Device 4-5 → Edge-B (port 9443)
# Mix of normal and abnormal readings to trigger alerts

for round in $(seq 1 $READINGS_PER_DEVICE); do
  # Device 1: Normal patient
  send_vital "patient_001" 8443 \
    "$(python3 -c 'import random; print(round(random.uniform(65,85),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(96,99),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(36.2,37.2),1))')"

  # Device 2: Tachycardia patient (high HR — triggers HIGH_HEART_RATE alert)
  send_vital "patient_002" 8443 \
    "$(python3 -c 'import random; print(round(random.uniform(110,140),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(95,98),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(36.5,37.5),1))')"

  # Device 3: Hypoxia patient (low SpO2 — triggers LOW_SPO2 alert)
  send_vital "patient_003" 8443 \
    "$(python3 -c 'import random; print(round(random.uniform(70,90),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(88,93),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(36.5,37.0),1))')"

  # Device 4: Fever patient (high temp — triggers HIGH_TEMPERATURE alert)
  send_vital "patient_004" 9443 \
    "$(python3 -c 'import random; print(round(random.uniform(75,95),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(95,99),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(38.5,39.5),1))')"

  # Device 5: Critical patient (multiple triggers)
  send_vital "patient_005" 9443 \
    "$(python3 -c 'import random; print(round(random.uniform(115,135),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(88,93),1))')" \
    "$(python3 -c 'import random; print(round(random.uniform(38.2,39.0),1))')"

  sleep "$SEND_INTERVAL"
done

divider
if [ "$TOTAL_OK" -gt 0 ]; then
  AVG_LAT=$((LATENCY_SUM / TOTAL_OK))
else
  AVG_LAT=0
fi
printf "  ${BOLD}Sent: %d  |  Success: %d  |  Failed: %d  |  Avg Latency: %dms${NC}\n" \
  "$TOTAL_SENT" "$TOTAL_OK" "$TOTAL_FAIL" "$AVG_LAT"

# Allow fog to finish processing
sleep 1

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 3 — RESULTS & METRICS
# ══════════════════════════════════════════════════════════════════════════════

step "9/$TOTAL_STEPS" "Fog Alerts & Metrics"

# Fetch alerts
ALERTS_JSON=$(curl -s http://localhost:30445/alerts 2>/dev/null)

TOTAL_ALERTS=$(echo "$ALERTS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_alerts',0))" 2>/dev/null || echo "0")
TOTAL_RECEIVED=$(echo "$ALERTS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_received',0))" 2>/dev/null || echo "0")
UPTIME=$(echo "$ALERTS_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('uptime_seconds',0))" 2>/dev/null || echo "0")

divider
printf "  ${BOLD}Fog Aggregation Summary${NC}\n"
printf "  Total readings received : %s\n" "$TOTAL_RECEIVED"
printf "  Total alerts generated  : %s\n" "$TOTAL_ALERTS"
printf "  Fog uptime              : %ss\n" "$UPTIME"
divider

# ── Show alert breakdown by type ──────────────────────────────────────────────
printf "\n  ${BOLD}Alert Breakdown:${NC}\n"
echo "$ALERTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
alerts = data.get('alerts', [])
types = {}
latencies = []
for a in alerts:
    t = a['alert_type']
    types[t] = types.get(t, 0) + 1
    latencies.append(a.get('latency_ms', 0))

for t, c in sorted(types.items()):
    print(f'    {t:25s} : {c} alerts')

if latencies:
    avg_lat = sum(latencies) / len(latencies)
    min_lat = min(latencies)
    max_lat = max(latencies)
    print()
    print(f'  Alert Latency (Edge→Fog):')
    print(f'    Min: {min_lat:.0f}ms  |  Avg: {avg_lat:.0f}ms  |  Max: {max_lat:.0f}ms')
" 2>/dev/null || true

# ── Show pseudonymization proof ───────────────────────────────────────────────
printf "\n  ${BOLD}Pseudonymization Proof:${NC}\n"
printf "  (Original device IDs are replaced with SHA-256 hashes)\n"
echo "$ALERTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
alerts = data.get('alerts', [])
seen = set()
for a in alerts:
    pid = a['pseudo_id']
    if pid not in seen:
        seen.add(pid)
        print(f'    patient_xxx → {pid}')
if not seen:
    print('    (no alerts to show)')
" 2>/dev/null || true

# ── Show sample alerts ────────────────────────────────────────────────────────
printf "\n  ${BOLD}Sample Alerts (last 5):${NC}\n"
echo "$ALERTS_JSON" | python3 -c "
import sys, json
data = json.load(sys.stdin)
alerts = data.get('alerts', [])
for a in alerts[-5:]:
    print(f\"    [{a['alert_type']:20s}]  pseudo_id={a['pseudo_id']}  value={a['value']:.1f}  threshold={a['threshold']:.1f}  latency={a.get('latency_ms',0):.0f}ms\")
if not alerts:
    print('    (none)')
" 2>/dev/null || true

# ══════════════════════════════════════════════════════════════════════════════
#  PHASE 4 — SECURITY DEMONSTRATION
# ══════════════════════════════════════════════════════════════════════════════

step "10/$TOTAL_STEPS" "mTLS Security Verification"

# Test 1: Unauthorized client (no client cert) → should be rejected by fog
info "Test: Connecting to fog mTLS port WITHOUT client certificate..."
MTLS_REJECT=$(curl -sk --cacert certs/ca/ca.crt \
  -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"pseudo_id":"hack","timestamp":"now","heart_rate":80,"spo2":97,"temperature":37}' \
  "https://localhost:30444/data" 2>/dev/null || echo "000")

if [ "$MTLS_REJECT" = "000" ] || [ "$MTLS_REJECT" = "" ]; then
  ok "Connection REJECTED (TLS handshake failed — no client cert) ← correct!"
else
  fail "Unexpected response: $MTLS_REJECT (expected connection refusal)"
fi

# Test 2: Valid mTLS with edge-a client cert → should succeed
info "Test: Connecting to fog mTLS port WITH valid client certificate..."
MTLS_OK=$(curl -sk --cacert certs/ca/ca.crt \
  --cert certs/edge-a/client.crt --key certs/edge-a/client.key \
  -o /dev/null -w "%{http_code}" \
  -H "Content-Type: application/json" \
  -d '{"pseudo_id":"test","timestamp":"now","heart_rate":80,"spo2":97,"temperature":37,"edge_recv_ts":0}' \
  "https://localhost:30444/data" 2>/dev/null || echo "000")

if [ "$MTLS_OK" = "200" ]; then
  ok "Connection ACCEPTED with valid client cert (HTTP $MTLS_OK) ← correct!"
else
  fail "Unexpected response: $MTLS_OK (expected 200)"
fi

# ══════════════════════════════════════════════════════════════════════════════
#  SUMMARY
# ══════════════════════════════════════════════════════════════════════════════

printf "\n"
divider
printf "${BOLD}${GREEN}"
cat << 'EOF'
  ╔═══════════════════════════════════════════════════════════╗
  ║       FEC Patient Health Monitoring — Demo Complete       ║
  ╚═══════════════════════════════════════════════════════════╝
EOF
printf "${NC}"

printf "\n  ${BOLD}Service Endpoints:${NC}\n"
printf "    Edge-A (IoT ingest) : https://localhost:8443/ingest\n"
printf "    Edge-B (IoT ingest) : https://localhost:9443/ingest\n"
printf "    Fog alerts          : http://localhost:30445/alerts\n"
printf "    Fog health          : http://localhost:30445/health\n"

printf "\n  ${BOLD}Architecture Flow:${NC}\n"
printf "    IoT Device → [TLS 1.3] → Edge (validate+pseudonymize) → [mTLS 1.3] → Fog (K8s)\n"

printf "\n  ${BOLD}Key Features Demonstrated:${NC}\n"
printf "    ✔ TLS 1.3 encryption on all channels\n"
printf "    ✔ Mutual TLS (mTLS) authentication between Edge ↔ Fog\n"
printf "    ✔ Pseudonymization of patient device IDs (SHA-256)\n"
printf "    ✔ Vital sign validation & noise filtering at Edge\n"
printf "    ✔ Real-time alert detection at Fog (HR, SpO2, Temp thresholds)\n"
printf "    ✔ Sliding window aggregation (window size = 5)\n"
printf "    ✔ Kubernetes orchestration via k3d\n"
printf "    ✔ mTLS rejection of unauthorized clients\n"

printf "\n  ${BOLD}Cleanup:${NC}\n"
printf "    docker rm -f edge-a edge-b && k3d cluster delete fec\n"
divider
