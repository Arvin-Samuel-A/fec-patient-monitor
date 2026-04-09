"""
Simulated IoT medical device.
Usage: uv run device.py --device-id device_001 --edge-url http://192.168.1.21:8081/ingest --interval 1
"""
import argparse, random, time, requests
from datetime import datetime, timezone


def generate_vitals(device_id: str) -> dict:
    return {
        "device_id":   device_id,
        "timestamp":   datetime.now(timezone.utc).isoformat(),
        "heart_rate":  round(random.uniform(55, 130), 1),
        "spo2":        round(random.uniform(88, 100), 1),
        "temperature": round(random.uniform(36.0, 39.5), 1),
    }


def run(device_id, edge_url, interval, ca_cert):
    print(f"[{device_id}] Starting. Target: {edge_url}, interval: {interval}s")
    sent = 0
    is_https = edge_url.lower().startswith("https://")
    while True:
        payload = generate_vitals(device_id)
        try:
            t0 = time.time()
            req_kwargs = {"json": payload, "timeout": 5}
            if is_https:
                req_kwargs["verify"] = ca_cert
            resp = requests.post(
                edge_url,
                **req_kwargs,
            )
            latency_ms = (time.time() - t0) * 1000
            sent += 1
            print(f"[{device_id}] #{sent} sent | status={resp.status_code} | latency={latency_ms:.1f}ms")
        except Exception as e:
            print(f"[{device_id}] ERROR: {e}")
        time.sleep(interval)


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--device-id",  required=True)
    # Pass Edge LAN endpoint, e.g. http://192.168.1.21:8081/ingest
    p.add_argument("--edge-url",   required=True)
    p.add_argument("--interval",   type=float, default=1.0)
    # Used only when edge-url uses HTTPS.
    p.add_argument("--ca-cert",    default="../certs/ca/ca.crt")
    args = p.parse_args()
    run(args.device_id, args.edge_url, args.interval, args.ca_cert)
