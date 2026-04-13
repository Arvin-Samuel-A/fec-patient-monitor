# FEC Patient Health Monitoring System

## Submission Report

Prepared for: Project Review and Academic Submission  
Project Type: Fog-Edge-Cloud Healthcare Telemetry Platform  
Date: 13 April 2026

---

## 1. Executive Summary

This report presents a complete implementation of a distributed patient health monitoring system deployed across three different LAN-connected devices. The design uses a Fog-Edge-Cloud model to combine low-latency local alerting with cloud-backed persistence and escalation.

Core outcomes:
- Real-time ingestion and processing of simulated vital signs.
- Local anomaly detection at Fog with immediate on-site alarm.
- Cloud escalation to AWS Lambda and Twilio for SMS and phone call notifications.
- Compliance-oriented structured logging to AWS S3.
- Operator-facing React dashboard for alert and log visibility.

The system demonstrates practical viability for healthcare telemetry scenarios where both fast local response and cloud traceability are required.

---

## 2. Problem Statement and Motivation

Healthcare monitoring pipelines must satisfy four critical needs:
1. Low-latency detection of abnormal patient vitals.
2. Reliable local alerting even when cloud calls are delayed.
3. Auditable logging for compliance and post-incident analysis.
4. Real-time operational observability for staff.

Single-host prototypes are insufficient for realistic deployment validation. This project therefore enforces a three-device LAN setup to test true network boundaries, distributed runtime behavior, and cross-system fault handling.

---

## 3. Requirements and Coverage Matrix

### 3.1 Mandatory Requirements

Requirement 1:
Fog in k3d, Edge in Docker, IoT simulator in terminal, all on three different LAN devices.

Coverage:
- Fog deployed as Kubernetes Deployment + NodePort on System 1.
- Edge service containerized and run on System 2.
- IoT simulator executed as terminal process on System 3.

Requirement 2:
On alert, Fog alarm must trigger, then AWS Lambda, Twilio SMS and call must execute.

Coverage:
- Fog threshold engine creates alert objects.
- Fog triggers local buzzer loop for immediate local warning.
- Fog invokes Lambda asynchronously per alert.
- Lambda uses Twilio to send SMS and place voice call.

Requirement 3:
Usual logging to S3 for compliance.

Coverage:
- Fog writes readings, alerts, and log events to S3 as JSON objects.
- Object structure supports traceability and retention workflows.

Requirement 4:
React dashboard for viewing alerts and logs.

Coverage:
- Vite + React dashboard reads Fog APIs for stats, alerts, logs, and config.
- Dashboard supports filtering by pseudo ID, type, severity, and log kind.
- Startup behavior loads existing logs for complete initial visibility.

Requirement 5:
Include latency reduction and real-world usability metrics, plus other necessary metrics.

Coverage:
- Defined metric model for latency, reliability, throughput, availability, observability, and usability.
- Included formulas, instrumentation sources, and evaluation protocol.

---

## 4. System Architecture

### 4.1 Deployment Topology

System 1 (Fog):
- k3d-based Kubernetes cluster.
- Fog service exposed via NodePort 30445.
- Hosts API endpoints and cloud integration logic.

System 2 (Edge):
- Dockerized Edge service (Edge-A or Edge-B).
- Receives IoT data, validates and preprocesses, forwards to Fog.

System 3 (IoT):
- Terminal-based simulator generating periodic vital readings.
- Sends payloads to Edge over HTTP.

Cloud Services:
- AWS S3 for immutable-style log persistence.
- AWS Lambda for notification workflow.
- Twilio for SMS and voice call delivery.
- AWS SSM Parameter Store for secure Twilio credential retrieval.

Dashboard:
- Vite + React client application.
- Reads Fog APIs using CORS.

### 4.2 Logical Data Flow

1. IoT simulator generates a reading with timestamp and vitals.
2. Edge receives reading on ingest endpoint.
3. Edge validates physiological ranges and applies noise filtering.
4. Edge pseudonymizes device identity.
5. Edge forwards sanitized payload to Fog.
6. Fog stores in-memory reading and log event.
7. Fog evaluates threshold rules and creates alerts if violated.
8. Fog triggers local audio alarm.
9. Fog writes reading, alert, and log records to S3.
10. Fog invokes Lambda asynchronously.
11. Lambda resolves Twilio secrets via SSM keys.
12. Lambda attempts SMS and voice call notifications.
13. Dashboard continuously renders stats, alerts, and logs.

---

## 5. Detailed Module Design

### 5.1 IoT Simulator

Responsibilities:
- Generate synthetic but realistic vital signs.
- Emit periodic data frames with UTC timestamps.

Typical generated ranges:
- Heart rate: 55 to 130 bpm.
- SpO2: 88 to 100 percent.
- Temperature: 36.0 to 39.5 C.

Operational properties:
- Configurable interval.
- Timeout-protected HTTP post.
- Basic console latency print per transmission.

### 5.2 Edge Service

Responsibilities:
- Input validation.
- Lightweight anomaly/noise rejection.
- Pseudonymization and forwarding.

Validation rules:
- Heart rate must be within 20 to 250.
- SpO2 must be within 50 to 100.
- Temperature must be within 30 to 45.

Noise filtering:
- Drops implausible inter-sample heart-rate jump greater than 60.

Pseudonymization:
- SHA-256 hash of salt + device ID, truncated for compact pseudo ID.

Forwarding model:
- Sends sanitized payload to Fog over HTTP with timeout handling.
- Returns explicit upstream failure when Fog is unreachable.

### 5.3 Fog Service

Responsibilities:
- API hosting and CORS handling.
- Real-time threshold evaluation.
- In-memory storage for recent readings, alerts, and events.
- S3 logging and Lambda invocation.
- Local buzzer activation.

Alert thresholds:
- HIGH_HEART_RATE when heart rate greater than 100.
- LOW_SPO2 when SpO2 less than 94.
- HIGH_TEMPERATURE when temperature greater than 38.

Severity escalation examples:
- HIGH_HEART_RATE with value 130 or above marked HIGH.
- LOW_SPO2 with value 90 or below marked HIGH.
- HIGH_TEMPERATURE with value 39 or above marked HIGH.

Latency instrumentation:
- Fog computes alert latency in milliseconds using edge_recv_ts.

Operational endpoints:
- POST /data
- GET /alerts
- GET /logs
- GET /readings
- GET /stats
- GET /config
- GET /health

### 5.4 Lambda Notifier

Responsibilities:
- Receive alert payload.
- Fetch Twilio settings from SSM parameter keys.
- Send SMS and initiate voice call.
- Return detailed success/failure status.

Resilience behaviors:
- SMS and call handled independently.
- Partial failure reporting supported.
- Error details include Twilio status/code when available.

Known operational tuning point:
- Lambda timeout must be sufficient for outbound Twilio calls.
- A 3000 ms timeout can cause call workflow failures; 15 seconds or higher is recommended.

### 5.5 React Dashboard

Responsibilities:
- Real-time observability of system health and events.
- Filtered exploration of alerts and logs.

Data sources:
- Stats from /stats.
- Alerts from /alerts.
- Logs from /logs.
- Refresh policy from /config.

Key UI capabilities:
- API status indicator (UP, DEGRADED, DOWN).
- Filter controls for pseudo ID, alert type, severity, and log kind.
- Adjustable row limits.
- Startup load behavior to fetch all existing logs before regular interval polling.

---

## 6. Deployment and Operations

### 6.1 System 1: Fog on k3d Kubernetes

Operational sequence:
1. Create or start k3d cluster.
2. Build Fog container image.
3. Import image into k3d cluster.
4. Apply Kubernetes deployment and service manifests.
5. Validate pod readiness and health endpoint.

Runtime exposure:
- Fog NodePort 30445 used by Edge and Dashboard clients.

### 6.2 System 2: Edge on Docker

Operational sequence:
1. Build Edge container image.
2. Run container with appropriate Fog URL environment variable.
3. Validate health endpoint.

### 6.3 System 3: IoT Simulator in Terminal

Operational sequence:
1. Start simulator with device ID and Edge ingest URL.
2. Verify successful post status and periodic transmission.

### 6.4 Dashboard Operation

Operational sequence:
1. Set Fog API base URL using Vite environment variable.
2. Start development server or production build server.
3. Validate live rendering of stats, alerts, and logs.

---

## 7. Compliance Logging and Data Governance

### 7.1 Why S3 Logging is Required

For compliance and auditability, event evidence must survive process restarts and support downstream retention/legal workflows. In-memory only logs are insufficient for healthcare-adjacent operational review.

### 7.2 Logged Artifacts

Fog writes JSON objects under logical prefixes:
- readings
- alerts
- logs

Each object contains timestamped, structured data suitable for:
- incident timeline reconstruction,
- external auditing,
- policy-based retention,
- offline analytics.

### 7.3 Recommended Compliance Controls

Recommended controls for production hardening:
- S3 versioning and lifecycle policies.
- KMS encryption at rest.
- Bucket policy with least privilege.
- Access logging and CloudTrail integration.
- Documented retention windows aligned to institutional policy.

---

## 8. Alerting and Escalation Behavior

### 8.1 Local First Safety Response

On threshold breach:
- Fog immediately creates alert record.
- Fog triggers local buzzer pattern (10 repeats).

This ensures local staff awareness even if cloud notification path is delayed.

### 8.2 Cloud Escalation Sequence

After local action:
- Fog invokes Lambda asynchronously.
- Lambda sends SMS and voice call via Twilio.
- Logs include message and call result identifiers or error details.

### 8.3 Practical Reliability Insight

Observed during testing:
- Notification path can fail when Lambda timeout is too low.
- Increasing timeout significantly improves completion probability for external API calls.

---

## 9. Metrics and Performance Evaluation

This section provides both measured signal sources and submission-ready metric definitions.

### 9.1 Primary Metric: Local Alert Latency

Definition:
- Time from Edge receive timestamp to Fog alert creation timestamp.

Source:
- Alert field latency_ms generated in Fog.

Interpretation:
- Lower values indicate faster local detection and response.

### 9.2 Latency Reduction Metric

Goal:
- Quantify reduction achieved by local Fog alerting versus cloud-only detection model.

Formula:
- Reduction percent = ((T_cloud_only - T_fog_local) / T_cloud_only) x 100

Where:
- T_fog_local is median local alert latency from latency_ms.
- T_cloud_only is baseline measured from direct-cloud detection path.

Submission note:
- In current architecture, local alarm and dashboard alert occur before Twilio completion, demonstrating practical latency advantage for on-site response.

### 9.3 Notification Reliability Metrics

Metrics:
- Lambda invoke success rate.
- SMS success rate.
- Voice call success rate.
- Partial success rate (SMS succeeds while call fails, or vice versa).

Collection source:
- Lambda logs and returned status payload fields.

### 9.4 Data Quality Metrics

Metrics:
- Edge rejection rate for invalid vitals.
- Noise filter drop rate.
- Duplicate or malformed payload rate.

Collection source:
- Edge logs and ingestion status distribution.

### 9.5 Throughput and Capacity Metrics

Metrics:
- Readings per second accepted by Fog.
- Alerts per minute under stress profiles.
- In-memory queue occupancy against configured limits.

Collection source:
- Fog stats endpoint plus controlled load runs.

### 9.6 Availability and Resilience Metrics

Metrics:
- API uptime percentage based on health probes.
- Mean time to recovery after service restart.
- Degraded mode duration when one dependency is down.

Collection source:
- Health checks, dashboard status transitions, and orchestration logs.

### 9.7 Compliance Completeness Metrics

Metrics:
- S3 write success ratio.
- Missing object ratio for alert events.
- End-to-end traceability coverage from alert to notification attempt.

Collection source:
- Fog warning logs plus S3 object count audits.

### 9.8 Real-World Usability Metrics

Metrics:
- Time to recognize critical patient state from dashboard.
- Time to acknowledge and communicate alert to caregiver.
- Operator task completion rate in scripted response drills.
- Alert clarity rating and perceived confidence (questionnaire-based).

Practical acceptance criterion example:
- Staff should identify and confirm a critical alert in less than 10 seconds under normal LAN conditions.

---

## 10. Test and Validation Plan

### 10.1 Functional Tests

Test F1:
- Input: normal vitals.
- Expected: reading logged, no alert.

Test F2:
- Input: high heart rate sample.
- Expected: alert created, buzzer activated, dashboard entry visible.

Test F3:
- Input: low SpO2 sample.
- Expected: LOW_SPO2 alert and cloud escalation attempt.

Test F4:
- Input: malformed reading.
- Expected: Edge validation rejection.

### 10.2 Integration Tests

Test I1:
- Trigger manual abnormal payload.
- Verify full chain: Edge to Fog to S3 to Lambda to Twilio.

Test I2:
- Simulate cloud delay.
- Verify local alarm still triggers immediately.

Test I3:
- Restart dashboard.
- Verify all existing logs displayed at startup.

### 10.3 Non-Functional Tests

Test N1:
- Sustained ingest over extended duration.
- Verify stable memory limits and endpoint responsiveness.

Test N2:
- Temporary network interruption between Edge and Fog.
- Verify controlled failure handling and recovery.

Test N3:
- Lambda timeout stress.
- Confirm improved outcomes after timeout increase.

---

## 11. Security, Privacy, and Ethical Considerations

### 11.1 Privacy Controls

- Device identifiers are pseudonymized before Fog ingestion.
- Twilio secrets are not hardcoded in Lambda source.
- Sensitive values are retrieved from SSM parameter names.

### 11.2 Security Controls

- IAM least privilege required for Fog and Lambda identities.
- S3 and Lambda access should be scoped to project resources only.

### 11.3 Remaining Gaps

- LAN-mode HTTP transport is suitable for controlled demo labs but not for production clinical environments.
- API authentication and authorization are currently minimal.

### 11.4 Ethics and Safety

- Alerts are decision-support signals and not standalone clinical diagnosis.
- Human oversight is mandatory for patient-facing intervention decisions.

---

## 12. Limitations

1. Fog keeps operational state in memory; restart clears local history unless persisted externally.
2. Advanced analytics (trend prediction, anomaly forecasting) are not yet integrated.
3. Dashboard is operationally strong but not yet role-based.
4. Twilio delivery depends on external network and account limits.

---

## 13. Future Work

Priority roadmap:
1. Add API and dashboard authentication with role-based access.
2. Reintroduce encrypted transport for production lanes.
3. Add durable operational datastore for long-lived query history.
4. Build automated CI/CD and deployment promotion workflow.
5. Add retry/backoff and dead-letter architecture for notifications.
6. Add trend analytics and triage prioritization models.

---

## 14. Reproducibility Checklist

Checklist for evaluators:
- Three LAN devices are available and mutually reachable.
- Fog on k3d is up and health endpoint responds.
- Edge container can reach Fog NodePort endpoint.
- IoT simulator posts to Edge successfully.
- Manual abnormal payload produces alert and buzzer.
- S3 objects appear for readings/alerts/logs.
- Lambda logs show notification attempts.
- Dashboard renders stats, alerts, and full startup logs.

---

## 15. Conclusion

The project successfully delivers a distributed Fog-Edge-Cloud monitoring pipeline with strong practical behavior for real-time alerting, cloud escalation, and compliance logging. The three-device LAN deployment validates realistic integration boundaries, while the dashboard and metric framework provide operational transparency suitable for technical review and submission.

Most importantly, the architecture provides a clinically relevant safety pattern: immediate local alarm at Fog, followed by cloud-backed escalation and auditable storage. This balance between responsiveness and traceability is the central technical contribution of the system.

---

## 16. Appendix A: Suggested Submission Artifacts

Attach the following with this report:
1. Deployment screenshots from each of the three systems.
2. Dashboard screenshots showing alerts and logs.
3. CloudWatch excerpts for Lambda invocation and Twilio status.
4. S3 object listing snapshots for compliance evidence.
5. Test execution table with pass/fail and timestamps.

---

## 17. Appendix B: API Contracts and Example Payloads

### 17.1 Edge Ingest Input

Sample request body sent from IoT to Edge:

~~~json
{
	"device_id": "device_001",
	"timestamp": "2026-04-13T10:15:22.154Z",
	"heart_rate": 128.4,
	"spo2": 91.2,
	"temperature": 38.7
}
~~~

### 17.2 Fog Data Input (Forwarded by Edge)

Sample request body sent from Edge to Fog:

~~~json
{
	"pseudo_id": "ab3cf0d9d1f1c9a1",
	"timestamp": "2026-04-13T10:15:22.154Z",
	"heart_rate": 128.4,
	"spo2": 91.2,
	"temperature": 38.7,
	"edge_recv_ts": 1713003322.556
}
~~~

### 17.3 Fog Alert Output Example

Sample item from alerts API:

~~~json
{
	"pseudo_id": "ab3cf0d9d1f1c9a1",
	"alert_type": "LOW_SPO2",
	"value": 91.2,
	"threshold": 94,
	"timestamp": "2026-04-13T10:15:22Z",
	"latency_ms": 83,
	"severity": "HIGH",
	"triggered_by": "spo2",
	"reading_at_fog": "2026-04-13T10:15:22Z"
}
~~~

### 17.4 Lambda Event Shape

Fog invokes Lambda with this structure:

~~~json
{
	"source": "fog-service",
	"alert": {
		"pseudo_id": "ab3cf0d9d1f1c9a1",
		"alert_type": "HIGH_HEART_RATE",
		"value": 132,
		"threshold": 100,
		"severity": "HIGH"
	}
}
~~~

---

## 18. Appendix C: Command Runbook (Submission Reproduction)

### 18.1 Fog Host (System 1)

~~~bash
cd fec-patient-monitor
k3d cluster list | grep -q '^fec ' || k3d cluster create fec --port "30445:30445@loadbalancer"
k3d cluster start fec
docker build -t fec-fog:latest ./fog
k3d image import fec-fog:latest -c fec
kubectl apply -f k8s/fog-deployment.yaml
kubectl apply -f k8s/fog-service.yaml
kubectl rollout status deployment/fog-service --timeout=180s
curl http://localhost:30445/health
~~~

### 18.2 Edge Host (System 2)

~~~bash
cd fec-patient-monitor
docker build -t fec-edge-a ./edge-a
docker run -d --name edge-a --restart unless-stopped \
	-p 8081:8081 \
	-e PORT=8081 \
	-e FOG_URL=http://<sys1-lan-ip>:30445/data \
	fec-edge-a
curl http://localhost:8081/health
~~~

### 18.3 IoT Host (System 3)

~~~bash
cd fec-patient-monitor
uv run --project iot iot/device.py \
	--device-id device_001 \
	--edge-url http://<sys2-lan-ip>:8081/ingest \
	--interval 1
~~~

### 18.4 Dashboard Host

~~~bash
cd fec-patient-monitor/dashboard
npm install
VITE_API_BASE_URL=http://<sys1-lan-ip>:30445 npm run dev -- --host
~~~

### 18.5 Trigger Controlled Alert

~~~bash
cd fec-patient-monitor
EDGE_URL=http://<sys2-lan-ip>:8081/ingest \
FOG_ALERTS_URL=http://<sys1-lan-ip>:30445/alerts \
./scripts/trigger-manual-alert.sh
~~~

---

## 19. Appendix D: Metrics Collection Procedure

### 19.1 Fog API Snapshots

Collect API evidence during run:

~~~bash
curl -sS http://<sys1-lan-ip>:30445/stats
curl -sS "http://<sys1-lan-ip>:30445/alerts?limit=200"
curl -sS "http://<sys1-lan-ip>:30445/logs?limit=500"
~~~

### 19.2 Compute Median Local Alert Latency

Procedure:
1. Save alerts API response to a JSON file.
2. Extract latency_ms values.
3. Compute median and p95.

### 19.3 Evaluate Notification Reliability

Procedure:
1. Count Lambda invocations for test window.
2. Count SMS success events and call success events.
3. Report separate success rates and combined success rate.

### 19.4 S3 Compliance Audit

Procedure:
1. List objects under readings, alerts, and logs prefixes.
2. Verify expected object count growth for test duration.
3. Randomly sample objects to confirm schema completeness.

---

## 20. Appendix E: Risk Register and Mitigation

Risk R1: Cloud notification delay
- Impact: late caregiver escalation.
- Mitigation: local buzzer-first policy and Lambda timeout tuning.

Risk R2: Unauthorized data access
- Impact: privacy and compliance violation.
- Mitigation: IAM least privilege, encrypted storage, secret indirection via SSM.

Risk R3: False alarms due to noisy input
- Impact: alarm fatigue.
- Mitigation: Edge noise filtering and threshold calibration by domain experts.

Risk R4: Service outage on one node
- Impact: temporary loss of telemetry path.
- Mitigation: health probes, restart policies, and clear recovery runbook.

Risk R5: In-memory data loss on Fog restart
- Impact: short-term observability gap.
- Mitigation: S3 persistence, optional durable datastore in next iteration.
