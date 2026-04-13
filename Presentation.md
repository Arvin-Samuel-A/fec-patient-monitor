# Review Presentation (10 Slides)

## Slide 1 - Project Title and One-Line Pitch

FEC Patient Health Monitoring System

Objective:
- Introduce the project clearly in under 20 seconds.

Key points:
- Architecture style: Fog-Edge-Cloud pipeline for healthcare telemetry.
- Deployment style: 3 independent machines in one LAN (Sys1 Fog, Sys2 Edge, Sys3 IoT).
- Outcome: real-time anomaly detection with both local and cloud notifications.

Speaker notes:
- "This system demonstrates how patient vitals can be processed close to the source at the edge and fog, while still integrating with cloud services for persistence and escalation."

## Slide 2 - Problem Statement and Constraints

Objective:
- Explain why this architecture is needed, not just what was built.

Key points:
- Clinical operations need near real-time visibility into critical vitals.
- Delayed or lost alerts can cause severe response gaps.
- Single-node prototypes are not enough; real deployments involve multiple machines and network boundaries.
- The project had to run in LAN mode over HTTP for practical multi-system testing.

Scope constraints addressed:
- Fast end-to-end signal path from device data to actionable alert.
- Isolation of roles: IoT generation, Edge preprocessing, Fog decisioning.
- Operational observability: logs, stats, health checks, and dashboard views.

Speaker notes:
- "Our design target was low latency and high operational clarity, even before adding advanced features like ML or hospital EHR integration."

## Slide 3 - Requirement-to-Solution Mapping

Objective:
- Show explicit traceability from requirements to implemented components.

Requirement mapping:
- Requirement: ingest patient vitals continuously.
- Solution: IoT simulator posts readings to Edge `/ingest` endpoint.
- Requirement: perform local preprocessing before central decisioning.
- Solution: Edge validates ranges, filters noise spikes, pseudonymizes patient ID, forwards to Fog `/data`.
- Requirement: trigger alerts for abnormal conditions.
- Solution: Fog threshold engine classifies anomalies and stores alert records.
- Requirement: notify stakeholders locally and remotely.
- Solution: Fog buzzer for immediate local alarm + Lambda/Twilio for cloud escalation.
- Requirement: monitor system behavior in real time.
- Solution: Vite React dashboard reads Fog APIs (`/stats`, `/alerts`, `/logs`, `/config`).

Speaker notes:
- "This slide is useful during review because each requirement is directly paired with a concrete implementation unit."

## Slide 4 - Architecture and Network Flow

Objective:
- Clarify the 3-system topology and traffic direction.

System roles:
- System 3 (IoT): sends vitals payloads over HTTP.
- System 2 (Edge-A or Edge-B, Docker): first-stage processing and forwarding.
- System 1 (Fog on k3d): centralized rule evaluation, logging, cloud integration, dashboard API.

Network path summary:
- IoT (Sys3) -> Edge (Sys2) via LAN HTTP.
- Edge (Sys2) -> Fog NodePort (Sys1:30445) via LAN HTTP.
- Fog (Sys1) -> AWS S3 and AWS Lambda (internet/cloud path).
- Dashboard client -> Fog API with CORS enabled.

Why this split matters:
- Matches realistic distributed deployment.
- Keeps heavier processing and integrations away from device layer.
- Makes fault isolation easier during troubleshooting.

Speaker notes:
- "By separating responsibilities physically, we can test true network behavior, not just function calls inside one host."

## Slide 5 - Data Model and Processing Pipeline

Objective:
- Detail what a reading looks like and how it changes per stage.

Typical vital fields:
- `patient_id`, `heart_rate`, `spo2`, `temperature`, `timestamp`.

Processing stages:
- Stage 1 (IoT): generate periodic vital records.
- Stage 2 (Edge):
  - sanity check ranges,
  - remove obvious spikes,
  - pseudonymize identity,
  - add forwarding metadata.
- Stage 3 (Fog):
  - persist reading/log events,
  - evaluate thresholds,
  - produce structured alert objects,
  - trigger local and cloud actions.

Data quality benefits:
- Noise reduction before central decisions.
- Identity protection using pseudonymous IDs.
- Cleaner alert stream with less false-positive risk from raw spikes.

Speaker notes:
- "The Edge stage is intentionally lightweight but critical: it prevents bad input from polluting Fog analytics and alerting."

## Slide 6 - Alert Logic and Local Safety Action

Objective:
- Explain exactly when and how alerts are generated.

Configured threshold rules:
- `HIGH_HEART_RATE`: heart rate > 100 bpm.
- `LOW_SPO2`: SpO2 < 94%.
- `HIGH_TEMPERATURE`: temperature > 38 C.

Alert lifecycle in Fog:
- Evaluate every forwarded reading against thresholds.
- Create alert record with type, severity, pseudo ID, and timestamp.
- Store alert/log data for dashboard visibility.
- Trigger buzzer pattern locally for immediate on-site awareness.

Local action:
- Buzzer repeats 10 times to make critical events obvious in demonstrations and lab environments.

Speaker notes:
- "Local audio signaling is important because it works even if external cloud notification is delayed."

## Slide 7 - Cloud Path: S3 + Lambda + Twilio

Objective:
- Show cloud escalation pipeline and operational caveats.

Cloud sequence:
- Fog writes reading/alert/log objects to S3 for durable audit history.
- Fog invokes Lambda asynchronously for each alert.
- Lambda reads Twilio configuration from SSM parameter keys.
- Lambda attempts SMS and voice call delivery.

Operational note from testing:
- A key failure observed was Lambda timeout at 3000 ms.
- Mitigation: increase Lambda timeout (for example 15 seconds or higher) to allow outbound Twilio API calls to complete reliably.

Value added by cloud integration:
- Durable history in object storage.
- Decoupled notification worker via Lambda.
- Extensible path for future integrations (email, webhook, incident systems).

Speaker notes:
- "The architecture already supports escalation fan-out; Twilio is the first notification backend, not the last."

## Slide 8 - Dashboard (Vite + React + CORS)

Objective:
- Demonstrate runtime observability and review usability.

Dashboard capabilities:
- Polls/queries Fog API endpoints:
  - `/stats` for aggregate counters,
  - `/alerts` for active/recent anomalies,
  - `/logs` for event timeline,
  - `/config` for runtime settings.
- Filtering controls:
  - pseudo ID,
  - alert type,
  - severity,
  - log kind,
  - row limit.

Why React app instead of static file:
- Better dev workflow and modular UI growth.
- Cleaner environment configuration via `VITE_API_BASE_URL`.
- CORS-friendly interaction with Fog API across machines.

Speaker notes:
- "During the demo, this is the primary observability surface: it proves data intake, alerting, and logging together."

## Slide 9 - Live Demo Plan (Operator Runbook)

Objective:
- Provide a repeatable, reviewer-friendly execution flow.

Demo sequence:
1. On Sys1 (Fog host), deploy/start Fog on k3d and confirm health endpoint.
2. On Sys2 (Edge host), run Edge container with Fog URL pointing to Sys1 NodePort `30445`.
3. On Sys3 (IoT host), start simulator and verify readings reach Edge.
4. On Sys1 or any client machine, start dashboard and set `VITE_API_BASE_URL` to Fog endpoint.
5. Trigger controlled abnormal reading using `scripts/trigger-manual-alert.sh`.
6. Validate outcomes across all layers:
   - alert appears in dashboard,
   - buzzer sounds locally,
   - S3 object appears,
   - Lambda logs show notification attempts.

Command references used in repo:
- `scripts/run-fog-http.sh`
- `scripts/run-edge-a-http.sh` or `scripts/run-edge-b-http.sh`
- `scripts/run-iot-http.sh`
- `scripts/run-dashboard.sh`
- `scripts/trigger-manual-alert.sh`

Speaker notes:
- "This scripted flow reduces demo risk and ensures every subsystem is evidenced, not just assumed."

## Slide 10 - Results, Risks, and Next Iteration

Objective:
- Close with measured achievements and realistic roadmap.

Current outcomes:
- End-to-end 3-system LAN pipeline is operational.
- Alert generation and local buzzer behavior are validated.
- Cloud path (S3 + Lambda invocation) is integrated.
- Dashboard provides practical operations view for review/demo.

Known limitations:
- Notification reliability depends on Lambda timeout and external API response times.
- Security hardening is minimal in LAN demo mode.
- Historical analytics are basic and not yet trend-centric.

Next iteration plan:
- Add authn/authz for API and dashboard.
- Add richer trend charts and patient history exploration.
- Add notification retry strategy and dead-letter handling.
- Add CI/CD for Fog image, manifests, and dashboard release pipeline.

Speaker notes:
- "The system is now demo-stable and architecture-complete; the next sprint should focus on production hardening and resilience." 