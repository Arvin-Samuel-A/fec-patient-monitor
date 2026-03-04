# FEC Patient Health Monitoring System

> **Fog–Edge–Cloud architecture** for real-time patient vital-sign monitoring with TLS 1.3 encryption, mutual TLS authentication, and Kubernetes orchestration.

---

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Data Flow](#data-flow)
- [Project Structure](#project-structure)
- [Technology Stack](#technology-stack)
- [Security Model](#security-model)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Component Details](#component-details)
  - [IoT Layer](#iot-layer-python)
  - [Edge Layer](#edge-layer-pythonfastapi)
  - [Fog Layer](#fog-layer-gokubernetes)
- [Alert System](#alert-system)
- [Certificate Infrastructure](#certificate-infrastructure)
- [Kubernetes Deployment](#kubernetes-deployment)
- [Running the Demo](#running-the-demo)
- [Manual Testing](#manual-testing)
- [Cleanup](#cleanup)
- [Troubleshooting](#troubleshooting)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        macOS Host Machine                          │
│                                                                     │
│  ┌──────────┐    TLS 1.3     ┌──────────┐    mTLS 1.3    ┌──────┐ │
│  │ IoT      │───────────────▶│ Edge-A   │────────────────▶│      │ │
│  │ Devices  │  :8443/ingest  │ (Docker) │  :30444/data   │      │ │
│  │ (Python) │                └──────────┘                │ Fog  │ │
│  │          │    TLS 1.3     ┌──────────┐    mTLS 1.3    │ (k3d │ │
│  │          │───────────────▶│ Edge-B   │────────────────▶│  K8s)│ │
│  │          │  :9443/ingest  │ (Docker) │  :30444/data   │      │ │
│  └──────────┘                └──────────┘                │      │ │
│                                                           │ :30445│ │
│                              ┌──────────┐  HTTP /alerts  │/alerts│ │
│                              │ Dashboard│◀───────────────│      │ │
│                              │ /Browser │                │      │ │
│                              └──────────┘                └──────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

## Data Flow

```
1. IoT Device generates vital signs (HR, SpO2, Temperature)
          │
          ▼  HTTPS (TLS 1.3, CA-verified)
2. Edge Service receives, validates, and filters data
   ├── Input validation (physiological range checks)
   ├── Noise filtering (inter-sample delta detection)
   └── Pseudonymization (SHA-256 hash of device_id)
          │
          ▼  HTTPS (mTLS 1.3, mutual certificate authentication)
3. Fog Service (Kubernetes) processes and aggregates
   ├── Sliding window aggregation (window size = 5)
   ├── Threshold-based alert detection
   ├── Latency tracking (Edge → Fog)
   └── Time-to-First-Alert (TTFA) measurement
          │
          ▼  HTTP (plain, internal)
4. Alert API (/alerts) exposes results for monitoring
```

## Project Structure

```
fec-patient-monitor/
├── iot/                          # IoT device simulator
│   ├── device.py                 # Simulates medical devices, sends vitals
│   └── pyproject.toml            # Python dependencies (requests)
│
├── edge-a/                       # Edge node A
│   ├── main.py                   # FastAPI: validate → filter → pseudonymize → forward
│   ├── Dockerfile                # Python 3.11-slim + uv
│   └── pyproject.toml            # Dependencies (fastapi, uvicorn, httpx)
│
├── edge-b/                       # Edge node B (identical logic, different port)
│   ├── main.py
│   ├── Dockerfile
│   └── pyproject.toml
│
├── fog/                          # Fog aggregation service
│   ├── main.go                   # Go: dual-port server (mTLS + HTTP)
│   ├── Dockerfile                # Multi-stage Go 1.22 build
│   └── go.mod                    # Go module definition
│
├── k8s/                          # Kubernetes manifests
│   ├── fog-deployment.yaml       # Fog pod with cert volume mounts
│   └── fog-service.yaml          # NodePort service (30444, 30445)
│
├── scripts/
│   ├── gen-certs.sh              # Generates all TLS/mTLS certificates
│   └── run-demo.sh               # Full automated demo script
│
├── certs/                        # Generated certificates (git-ignored)
│   ├── ca/                       # CA cert + key
│   ├── fog/                      # Fog server cert
│   ├── edge-a/                   # Edge-A client + server certs
│   └── edge-b/                   # Edge-B client + server certs
│
├── .gitignore
└── README.md
```

## Technology Stack

| Layer      | Technology              | Purpose                                        |
|------------|-------------------------|-------------------------------------------------|
| **IoT**    | Python 3.11+, requests  | Simulates medical devices, sends vitals via TLS |
| **Edge**   | Python 3.11, FastAPI    | Validation, noise filtering, pseudonymization   |
|            | httpx                   | mTLS HTTP client with TLS 1.3 support           |
|            | uvicorn                 | ASGI server with TLS termination                |
| **Fog**    | Go 1.22                 | High-performance alert detection & aggregation   |
|            | net/http + crypto/tls   | Dual-port server (mTLS + plain HTTP)             |
| **Infra**  | Docker                  | Containerization for Edge and Fog services       |
|            | k3d (k3s-in-Docker)    | Lightweight Kubernetes for Fog deployment        |
|            | kubectl                 | Kubernetes management                            |
| **Certs**  | OpenSSL                 | X.509v3 certificate generation with extensions   |

## Security Model

### TLS 1.3 Everywhere

All network communication is encrypted using **TLS 1.3**, the latest version of the Transport Layer Security protocol.

- **IoT → Edge**: TLS 1.3 with CA verification (IoT devices verify Edge server certificates against the trusted CA)
- **Edge → Fog**: **Mutual TLS (mTLS)** — both sides authenticate with certificates
- **Fog Alerts API**: Plain HTTP on a separate port (internal monitoring only)

### Mutual TLS (mTLS)

The Edge-to-Fog channel uses mutual TLS authentication:

1. **Fog presents its server certificate** — Edge verifies it against the CA
2. **Edge presents its client certificate** — Fog verifies it against the CA
3. Connections without valid client certificates are **rejected at the TLS handshake**

> **TLS 1.3 Compatibility Note**: TLS 1.3 uses post-handshake authentication for client certificates. The Edge's Python `ssl.SSLContext` is configured with `post_handshake_auth = True` to ensure client certificates are properly sent during the TLS 1.3 handshake.

### Pseudonymization

Patient device IDs are replaced with SHA-256 hashes at the Edge layer before data reaches the Fog:

```
device_id: "patient_001" → pseudo_id: "a3f8c9b2e1d74..."  (first 16 hex chars)
```

The pseudonymization uses a configurable salt (`PSEUDONYM_SALT` env var) and is irreversible — the Fog layer never sees original device IDs.

### Noise Filtering

Edge services detect and drop implausible data spikes:
- Heart rate delta > 60 BPM between consecutive readings from the same device → dropped
- Prevents medical false alarms from sensor glitches

## Prerequisites

| Tool          | Version  | Install                                |
|---------------|----------|----------------------------------------|
| Docker Desktop| 4.x+     | [docker.com](https://docker.com)       |
| k3d           | 5.x+     | `brew install k3d`                     |
| kubectl       | 1.28+    | `brew install kubectl`                 |
| OpenSSL       | 3.x+     | Pre-installed on macOS                 |
| Python        | 3.11+    | For running IoT simulator on host      |
| uv (optional) | Latest   | `curl -LsSf https://astral.sh/uv/install.sh \| sh` |

> Make sure **Docker Desktop is running** before executing the demo.

## Quick Start

```bash
# Clone the repository
git clone https://github.com/Arvin-Samuel-A/fec-patient-monitor.git
cd fec-patient-monitor

# Run the full demo (builds, deploys, sends data, shows results)
chmod +x scripts/run-demo.sh
./scripts/run-demo.sh
```

The demo script handles everything automatically:
1. Generates TLS/mTLS certificates
2. Creates a k3d Kubernetes cluster
3. Builds and deploys the Fog service to Kubernetes
4. Builds and starts Edge containers
5. Sends simulated vital signs from 5 IoT devices
6. Displays alerts, latency metrics, and pseudonymization proof
7. Demonstrates mTLS rejection of unauthorized clients

Use `--rebuild` to force-regenerate everything from scratch:
```bash
./scripts/run-demo.sh --rebuild
```

## Component Details

### IoT Layer (Python)

**File**: `iot/device.py`

Simulates medical devices that generate vital signs and send them to Edge services via HTTPS.

```bash
# Run a single IoT device manually
cd iot
uv run device.py \
  --device-id patient_001 \
  --edge-url https://localhost:8443/ingest \
  --interval 1 \
  --ca-cert ../certs/ca/ca.crt
```

**Generated vital ranges**:
| Metric      | Range            | Unit |
|-------------|------------------|------|
| Heart Rate  | 55 – 130        | BPM  |
| SpO2        | 88 – 100        | %    |
| Temperature | 36.0 – 39.5     | °C   |

### Edge Layer (Python/FastAPI)

**Files**: `edge-a/main.py`, `edge-b/main.py`

FastAPI services that sit between IoT devices and the Fog:

| Endpoint      | Method | Purpose                           |
|---------------|--------|-----------------------------------|
| `/ingest`     | POST   | Receives vitals from IoT devices  |
| `/health`     | GET    | Health check                      |

**Processing pipeline**:
1. **Validate** — Pydantic model checks physiological ranges:
   - Heart rate: 20–250 BPM
   - SpO2: 50–100%
   - Temperature: 30–45°C
2. **Noise filter** — Drops readings with HR delta > 60 from previous
3. **Pseudonymize** — SHA-256 hash replaces device_id
4. **Forward** — Sends to Fog via mTLS-authenticated HTTPS

**Ports**: Edge-A listens on `:8443`, Edge-B on `:9443`

### Fog Layer (Go/Kubernetes)

**File**: `fog/main.go`

Go service deployed on Kubernetes (via k3d) with two HTTP servers:

| Port  | Protocol  | Endpoints | Purpose                        |
|-------|-----------|-----------|--------------------------------|
| 8444  | mTLS 1.3  | `/data`   | Receives data from Edge nodes  |
| 8445  | HTTP      | `/alerts`, `/health` | Monitoring & probes |

**Processing**:
- **Sliding window aggregation**: Maintains last 5 readings per pseudo_id
- **Threshold-based alert detection**:

| Alert Type         | Condition           | Threshold |
|--------------------|---------------------|-----------|
| HIGH_HEART_RATE    | heart_rate > 100    | 100 BPM   |
| LOW_SPO2           | spo2 < 94           | 94%       |
| HIGH_TEMPERATURE   | temperature > 38    | 38°C      |

- **Latency tracking**: Measures Edge→Fog delivery time per reading
- **TTFA**: Logs Time-to-First-Alert from service start

## Alert System

The Fog service exposes alerts via the `/alerts` endpoint:

```bash
curl http://localhost:30445/alerts | python3 -m json.tool
```

**Response format**:
```json
{
  "total_alerts": 42,
  "total_received": 15,
  "uptime_seconds": 120,
  "alerts": [
    {
      "pseudo_id": "a3f8c9b2e1d74f06",
      "alert_type": "HIGH_HEART_RATE",
      "value": 125.3,
      "threshold": 100.0,
      "timestamp": "2025-01-15T10:30:00Z",
      "latency_ms": 45.0
    }
  ]
}
```

## Certificate Infrastructure

All certificates are generated by `scripts/gen-certs.sh` using OpenSSL with proper X.509v3 extensions:

```
CA (Root Certificate Authority)
├── keyUsage: keyCertSign, cRLSign
│
├── Fog Server Cert
│   ├── extendedKeyUsage: serverAuth
│   └── SAN: DNS:fog-service, DNS:localhost, DNS:host.docker.internal, IP:127.0.0.1
│
├── Edge-A Client Cert (for mTLS to Fog)
│   └── extendedKeyUsage: clientAuth
│
├── Edge-A Server Cert (for IoT→Edge TLS)
│   ├── extendedKeyUsage: serverAuth
│   └── SAN: DNS:localhost, IP:127.0.0.1
│
├── Edge-B Client Cert
│   └── extendedKeyUsage: clientAuth
│
└── Edge-B Server Cert
    ├── extendedKeyUsage: serverAuth
    └── SAN: DNS:localhost, IP:127.0.0.1
```

> **Why `host.docker.internal` in Fog SAN?**
> On macOS Docker Desktop, containers cannot use `localhost` to reach the host. Edge containers connect to the Fog Kubernetes NodePort via `host.docker.internal:30444`, so the Fog server certificate must include this hostname in its SAN.

## Kubernetes Deployment

The Fog service runs in a k3d (k3s-in-Docker) Kubernetes cluster:

```
k3d cluster "fec"
│
├── Deployment: fog-service
│   ├── Image: fec-fog:latest (imported via k3d image import)
│   ├── Ports: 8444 (mTLS), 8445 (HTTP)
│   ├── Certs: Mounted from K8s Secret (fog-tls-secret)
│   ├── Liveness Probe: GET /health on port 8445
│   └── Readiness Probe: GET /health on port 8445
│
└── Service: fog-service (NodePort)
    ├── 30444 → 8444 (mTLS data ingestion)
    └── 30445 → 8445 (HTTP alerts/health)
```

> **Why do probes use port 8445?**
> Kubernetes liveness/readiness probes cannot present mTLS client certificates. The Fog runs a separate plain HTTP server on port 8445 specifically for health checks and the alerts API.

## Running the Demo

### Automated (Recommended)

```bash
./scripts/run-demo.sh
```

The demo script runs 10 steps:

| Step | Action                                              |
|------|-----------------------------------------------------|
| 1    | Generate TLS/mTLS certificates                     |
| 2    | Create k3d Kubernetes cluster                       |
| 3    | Build Fog Docker image (Go)                         |
| 4    | Import Fog image into k3d                           |
| 5    | Deploy Fog to Kubernetes (Secret + Deployment)      |
| 6    | Build Edge Docker images (Python)                   |
| 7    | Start Edge containers + health checks               |
| 8    | Send 15 simulated vital-sign readings (5 devices)   |
| 9    | Display alerts, latency metrics, pseudonymization   |
| 10   | Demonstrate mTLS security (rejection test)          |

### Expected Demo Output

```
═══ FEC Patient Health Monitoring — Review-2 Demo ═══
  Architecture : IoT (Python) → Edge (Python/FastAPI) → Fog (Go/K8s)
  Security     : TLS 1.3 everywhere, mTLS between Edge↔Fog

[1/10] TLS / mTLS Certificate Generation
  ✔ Certificates generated

[8/10] Sending Simulated IoT Vital Signs (5 devices × 3 readings)
  DEVICE       HR       SpO2     TEMP     STATUS    LATENCY
  patient_001  72.3     98.1     36.8     200       125ms
  patient_002  128.5    96.2     37.1     200       130ms  ← triggers HR alert
  patient_003  82.1     91.3     36.7     200       128ms  ← triggers SpO2 alert
  ...

[9/10] Fog Alerts & Metrics
  Total readings received : 15
  Total alerts generated  : 18
  Alert Breakdown:
    HIGH_HEART_RATE           : 6 alerts
    HIGH_TEMPERATURE          : 6 alerts
    LOW_SPO2                  : 6 alerts

  Alert Latency (Edge→Fog):
    Min: 32ms  |  Avg: 89ms  |  Max: 210ms

  Pseudonymization Proof:
    patient_xxx → a3f8c9b2e1d74f06
    patient_xxx → 7c2e91d8f3a64b12
    ...

[10/10] mTLS Security Verification
  ✔ Connection REJECTED (no client cert) ← correct!
  ✔ Connection ACCEPTED with valid client cert (HTTP 200) ← correct!
```

### Manual Testing

```bash
# Send a single vital reading to Edge-A
curl -sk --cacert certs/ca/ca.crt \
  -H "Content-Type: application/json" \
  -d '{"device_id":"test_001","timestamp":"2025-01-15T10:00:00Z","heart_rate":120,"spo2":91,"temperature":38.5}' \
  https://localhost:8443/ingest

# Check fog alerts
curl -s http://localhost:30445/alerts | python3 -m json.tool

# Check service health
curl -sk --cacert certs/ca/ca.crt https://localhost:8443/health
curl -sk --cacert certs/ca/ca.crt https://localhost:9443/health
curl -s http://localhost:30445/health

# View fog logs
kubectl logs -l app=fog-service -f

# View edge logs
docker logs edge-a -f
docker logs edge-b -f
```

## Cleanup

```bash
# Stop and remove edge containers
docker rm -f edge-a edge-b

# Delete k3d cluster (removes fog pod, service, and all k8s resources)
k3d cluster delete fec

# Remove generated certificates
rm -rf certs/

# Remove Docker images
docker rmi fec-edge-a fec-edge-b fec-fog
```

## Troubleshooting

### Edge container fails to start
```bash
docker logs edge-a
```
- Check that certificates exist in `certs/edge-a/`
- Ensure ports 8443/9443 are not already in use

### Fog pod stuck in CrashLoopBackOff
```bash
kubectl logs -l app=fog-service
kubectl describe pod -l app=fog-service
```
- Check that `fog-tls-secret` contains the correct cert files
- Verify fog image was imported: `k3d image import fec-fog -c fec`

### mTLS connection refused (Edge → Fog)
- Ensure `host.docker.internal` is in the Fog cert SAN
- Verify Edge containers have `post_handshake_auth = True` in SSL context
- Check both client cert and CA cert are mounted in Edge container

### TLS handshake errors on Python 3.14+
Python 3.14 requires the `keyUsage` extension on CA certificates. The `gen-certs.sh` script generates the CA cert with proper `v3_ca` extensions including `keyUsage = critical,keyCertSign,cRLSign`.

### k3d NodePort not reachable
k3d requires ports to be declared at cluster creation time:
```bash
k3d cluster create fec \
  --port "30444:30444@loadbalancer" \
  --port "30445:30445@loadbalancer"
```
If ports were not mapped, delete and recreate the cluster.

---

