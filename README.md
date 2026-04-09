# FEC Patient Health Monitoring (LAN HTTP Mode)

Fog-Edge-Cloud patient monitoring system for LAN deployment:

- IoT -> Edge over HTTP
- Edge -> Fog over HTTP
- Fog writes readings and alerts to AWS S3
- Fog invokes AWS Lambda on alert
- Lambda reads Twilio credentials from AWS SSM Parameter Store and sends SMS/call
- Fog emits local buzzer alert
- Built-in web dashboard for logs, alerts, and basic filtering

## Architecture

```text
IoT Device(s) (Python)
        |
        | HTTP POST /ingest
        v
Edge Node A/B (FastAPI)
  - validates + noise filters + pseudonymizes
        |
        | HTTP POST /data
        v
Fog Node (Go)
  - alert detection + in-memory logs + dashboard API
  - writes JSON records to S3
  - invokes Lambda for alert notifications
  - local buzzer sound
        |
        +--> Web dashboard at /
        +--> API: /alerts, /logs, /readings, /stats
```

## Project Layout

```text
fec-patient-monitor/
  edge-a/
  edge-b/
  fog/
    dashboard/index.html
  iot/
  lambda/notifier/
    handler.py
    requirements.txt
  scripts/
    run-fog-http.sh
    run-edge-a-http.sh
    run-edge-b-http.sh
    run-iot-http.sh
  .env
```

## Key Features Implemented

1. HTTP-only data path for LAN systems (no TLS/mTLS required)
2. S3 logging from Fog for readings, alerts, and log events
3. Lambda invocation from Fog for every alert
4. Lambda Twilio notifier using SSM parameter keys
5. Local buzzer on Fog alert
6. Web dashboard with filter controls:
   - pseudo_id filter
   - alert type filter
   - severity filter
   - log kind filter
   - row limit

## Environment Variables

The system uses `.env` at repository root.

### Fog runtime

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `S3_BUCKET_NAME`
- `ENABLE_S3_LOGGING=true|false`
- `LAMBDA_FUNCTION_NAME`
- `ENABLE_LAMBDA_NOTIFICATIONS=true|false`
- `ENABLE_AUDIO_ALERTS=true|false`
- `HTTP_PORT` or `PORT`
- `REFRESH_INTERVAL_SECONDS`

### LAN routing helpers

- `FOG_HOST`
- `FOG_PORT`
- `FOG_URL`
- `EDGE_A_PORT`
- `EDGE_B_PORT`
- `EDGE_A_URL`
- `EDGE_B_URL`

### Lambda SSM parameter-key env vars

These values are parameter names, not secrets:

- `TWILIO_ACCOUNT_SID_PARAM=/fec/twilio/account-sid`
- `TWILIO_AUTH_TOKEN_PARAM=/fec/twilio/auth-token`
- `TWILIO_PHONE_NUMBER_PARAM=/fec/twilio/phone-number`
- `ALERT_RECIPIENT_PHONE_PARAM=/fec/twilio/recipient-phone`

## Run on 3 Different LAN Systems

### System 1: Fog

```bash
cd fec-patient-monitor
./scripts/run-fog-http.sh
```

Fog endpoints:

- `http://<fog-ip>:<HTTP_PORT>/health`
- `http://<fog-ip>:<HTTP_PORT>/alerts`
- `http://<fog-ip>:<HTTP_PORT>/logs`
- `http://<fog-ip>:<HTTP_PORT>/` (dashboard)

### System 2: Edge (A or B)

Set `FOG_URL` to fog machine address, for example:

```bash
export FOG_URL=http://192.168.1.10:8080/data
./scripts/run-edge-a-http.sh
```

or

```bash
export FOG_URL=http://192.168.1.10:8080/data
./scripts/run-edge-b-http.sh
```

### System 3: IoT

Point IoT to edge node address:

```bash
cd fec-patient-monitor
uv run --project iot iot/device.py \
  --device-id device_001 \
  --edge-url http://192.168.1.11:8081/ingest \
  --interval 1
```

## Dashboard

Open in browser:

```text
http://<fog-ip>:<HTTP_PORT>/
```

It shows:

- Total readings, alerts, uptime, API status
- Alerts table
- Logs table
- Filter controls
- Auto refresh based on `REFRESH_INTERVAL_SECONDS`

## Lambda Notifier Setup

Location: `lambda/notifier/handler.py`

1. Create Lambda function (Python 3.11)
2. Upload code + `twilio` dependency (`requirements.txt`)
3. Set handler to:

```text
handler.lambda_handler
```

4. Configure Lambda environment variables with SSM parameter keys:

- `TWILIO_ACCOUNT_SID_PARAM`
- `TWILIO_AUTH_TOKEN_PARAM`
- `TWILIO_PHONE_NUMBER_PARAM`
- `ALERT_RECIPIENT_PHONE_PARAM`
- Optional: `ENABLE_TWILIO_CALL=true`

5. Lambda IAM permissions:

- `ssm:GetParameters`
- `kms:Decrypt` (if SecureString uses customer-managed key)

## AWS IAM Notes for Fog Host

Fog host credentials/role must allow:

- `s3:PutObject` on your bucket
- `lambda:InvokeFunction` for your notifier Lambda

## API Reference (Fog)

- `POST /data` : ingest edge reading
- `GET /alerts` : list alerts
  - query: `type`, `pseudo_id`, `severity`, `limit`
- `GET /logs` : list log events
  - query: `kind`, `pseudo_id`, `type`, `limit`
- `GET /readings` : list readings
  - query: `pseudo_id`, `limit`
- `GET /stats` : runtime stats
- `GET /config` : dashboard refresh config
- `GET /health` : health

## Development Validation

Fog build and scripts were validated with:

- `go build ./...` in `fog/`
- shell syntax checks for all new scripts

## Important Security Note

If any real AWS or Twilio secrets were exposed previously, rotate them immediately and keep only secret references in Parameter Store.
