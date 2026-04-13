# FEC Patient Health Monitoring (3-System LAN Deployment)

Fog-Edge-Cloud patient monitoring system deployed across three different systems in the same LAN:

- System 1: Fog service on k3d (Kubernetes)
- System 2: Edge service(s) in Docker
- System 3: IoT simulator generating patient vitals

Cloud integrations:

- Fog writes readings and alerts to AWS S3
- Fog invokes AWS Lambda for notifications
- Lambda reads Twilio secrets from AWS SSM Parameter Store and sends SMS and call

Frontend:

- Vite + React dashboard consumes Fog API over CORS

## Deployment Topology

```text
System 3 (IoT)                    System 2 (Edge Docker)                    System 1 (Fog k3d)
----------------                  -----------------------                    -------------------
iot/device.py  --HTTP /ingest-->  edge-a or edge-b  --HTTP /data-->         fog-service (NodePort 30445)
                                                                          |-> /alerts /logs /stats /health
                                                                          |-> S3 logging
                                                                          |-> Lambda invoke -> Twilio call/SMS
```

## Project Layout

```text
fec-patient-monitor/
  edge-a/
  edge-b/
  fog/
  iot/
  dashboard/
    src/
    package.json
  lambda/notifier/
    lambda_function.py
    requirements.txt
    build-package.sh
  k8s/
    fog-deployment.yaml
    fog-service.yaml
  scripts/
    run-fog-http.sh
    run-edge-a-http.sh
    run-edge-b-http.sh
    run-iot-http.sh
    run-dashboard.sh
    trigger-manual-alert.sh
  .env
```

## Prerequisites

System 1 (Fog):

- Docker Desktop
- k3d
- kubectl

System 2 (Edge):

- Docker

System 3 (IoT):

- Python 3.11+
- uv (recommended)

Dashboard host (can be any system):

- Node.js 18+
- npm

## System 1: Run Fog on k3d

From repository root:

```bash
cd fec-patient-monitor

# Create cluster once (if not already created)
k3d cluster list | grep -q '^fec ' || k3d cluster create fec --port "30445:30445@loadbalancer"

# Start cluster
k3d cluster start fec

# Build and import fog image
docker build -t fec-fog:latest ./fog
k3d image import fec-fog:latest -c fec

# Deploy fog
kubectl apply -f k8s/fog-deployment.yaml
kubectl apply -f k8s/fog-service.yaml
kubectl rollout status deployment/fog-service --timeout=180s

# Verify
kubectl get pods -l app=fog-service
curl http://localhost:30445/health
```

Fog API base URL for other systems:

- http://<sys1-lan-ip>:8080

## System 2: Run Edge in Docker

Edge-A example:

```bash
cd fec-patient-monitor
docker build -t fec-edge-a ./edge-a

docker run -d --name edge-a --restart unless-stopped \
  -p 8081:8081 \
  -e PORT=8081 \
  -e FOG_URL=http://<sys1-lan-ip>:30445/data \
  fec-edge-a
```

Edge-B example:

```bash
cd fec-patient-monitor
docker build -t fec-edge-b ./edge-b

docker run -d --name edge-b --restart unless-stopped \
  -p 8082:8082 \
  -e PORT=8082 \
  -e FOG_URL=http://<sys1-lan-ip>:30445/data \
  fec-edge-b
```

Verify from System 2:

```bash
curl http://localhost:8081/health
```

## System 3: Run IoT Simulator

Send data to System 2 Edge-A:

```bash
cd fec-patient-monitor
uv run --project iot iot/device.py \
  --device-id device_001 \
  --edge-url http://<sys2-lan-ip>:8081/ingest \
  --interval 1
```

## Dashboard (Vite React + CORS)

Run from any system that can reach System 1 Fog API:

```bash
cd fec-patient-monitor/dashboard
npm install
VITE_API_BASE_URL=http://<sys1-lan-ip>:30445 npm run dev -- --host
```

Open browser:

- http://<dashboard-host-ip>:5173

Dashboard reads:

- /stats
- /alerts
- /logs
- /config

## Manual Alert Trigger

You can force an alert using abnormal vitals from any machine:

```bash
cd fec-patient-monitor
EDGE_URL=http://<sys2-lan-ip>:8081/ingest \
FOG_ALERTS_URL=http://<sys1-lan-ip>:30445/alerts \
./scripts/trigger-manual-alert.sh
```

## Lambda Notifier Setup

Location:

- lambda/notifier/lambda_function.py

Handler:

- lambda_function.lambda_handler

Build package:

```bash
cd lambda/notifier
chmod +x build-package.sh
./build-package.sh
```

Upload notifier.zip to Lambda and set environment variables to SSM parameter keys:

- TWILIO_ACCOUNT_SID_PARAM=/fec/twilio/account-sid
- TWILIO_AUTH_TOKEN_PARAM=/fec/twilio/auth-token
- TWILIO_PHONE_NUMBER_PARAM=/fec/twilio/phone-number
- ALERT_RECIPIENT_PHONE_PARAM=/fec/twilio/recipient-phone

Minimum recommended Lambda timeout:

- 15 seconds

## AWS IAM Requirements

Fog execution identity:

- s3:PutObject on target bucket
- lambda:InvokeFunction on notifier Lambda

Lambda execution role:

- ssm:GetParameters
- kms:Decrypt (if SecureString uses customer-managed KMS key)

## Fog API Reference

- POST /data
- GET /alerts (type, pseudo_id, severity, limit)
- GET /logs (kind, pseudo_id, type, limit)
- GET /readings (pseudo_id, limit)
- GET /stats
- GET /config
- GET /health

## Security Note

If any real AWS or Twilio credentials were exposed during development, rotate them immediately and keep only secure references in SSM Parameter Store.