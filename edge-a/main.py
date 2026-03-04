"""
Edge service: validates, noise-filters, pseudonymizes, forwards to Fog via mTLS.
"""
import os, ssl, hashlib, time, logging
from fastapi import FastAPI, HTTPException, Request
from pydantic import BaseModel, field_validator
import httpx

logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')
log = logging.getLogger(__name__)

app = FastAPI(title="FEC Edge Service")

# ── Config from environment ──────────────────────────────────────────────────
# FOG_URL uses host.docker.internal because on macOS Docker Desktop,
# 127.0.0.1 inside a container refers to the container itself, not the Mac host.
FOG_URL        = os.getenv("FOG_URL",        "https://host.docker.internal:30444/data")
CA_CERT        = os.getenv("CA_CERT",        "/certs/ca/ca.crt")
CLIENT_CERT    = os.getenv("CLIENT_CERT",    "/certs/client.crt")
CLIENT_KEY     = os.getenv("CLIENT_KEY",     "/certs/client.key")
PSEUDONYM_SALT = os.getenv("PSEUDONYM_SALT", "fec-secret-salt-2024")


# ── Input model ──────────────────────────────────────────────────────────────
class VitalPayload(BaseModel):
    device_id:   str
    timestamp:   str
    heart_rate:  float
    spo2:        float
    temperature: float

    @field_validator('heart_rate')
    @classmethod
    def check_hr(cls, v):
        if not (20 <= v <= 250):
            raise ValueError('heart_rate out of physiological range')
        return v

    @field_validator('spo2')
    @classmethod
    def check_spo2(cls, v):
        if not (50 <= v <= 100):
            raise ValueError('spo2 out of range')
        return v

    @field_validator('temperature')
    @classmethod
    def check_temp(cls, v):
        if not (30 <= v <= 45):
            raise ValueError('temperature out of range')
        return v


# ── Pseudonymization ─────────────────────────────────────────────────────────
def pseudonymize(device_id: str) -> str:
    return hashlib.sha256(f"{PSEUDONYM_SALT}:{device_id}".encode()).hexdigest()[:16]


# ── Noise filter: discard implausible inter-sample deltas ────────────────────
_last: dict = {}

def noise_filter(device_id: str, payload: VitalPayload) -> bool:
    prev = _last.get(device_id)
    if prev:
        if abs(payload.heart_rate - prev['heart_rate']) > 60:
            log.warning(f"Noise spike dropped for {device_id}: HR delta > 60")
            return False
    _last[device_id] = {'heart_rate': payload.heart_rate, 'spo2': payload.spo2}
    return True


# ── mTLS client (TLS 1.3 requires post_handshake_auth for client certs) ────────
def _build_mtls_ssl_context() -> ssl.SSLContext:
    ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    ctx.minimum_version = ssl.TLSVersion.TLSv1_3
    ctx.load_verify_locations(CA_CERT)           # verify fog server cert
    ctx.load_cert_chain(CLIENT_CERT, CLIENT_KEY) # present edge client cert
    ctx.post_handshake_auth = True               # required for TLS 1.3 mTLS
    return ctx

def get_mtls_client() -> httpx.Client:
    return httpx.Client(
        verify=_build_mtls_ssl_context(),
        timeout=5.0
    )


# ── Endpoints ─────────────────────────────────────────────────────────────────
@app.post("/ingest")
async def ingest(payload: VitalPayload, request: Request):
    recv_time = time.time()
    if not noise_filter(payload.device_id, payload):
        raise HTTPException(status_code=422, detail="Noise filtered")

    sanitized = {
        "pseudo_id":    pseudonymize(payload.device_id),
        "timestamp":    payload.timestamp,
        "heart_rate":   payload.heart_rate,
        "spo2":         payload.spo2,
        "temperature":  payload.temperature,
        "edge_recv_ts": recv_time,
    }
    log.info(f"Forwarding to fog: pseudo_id={sanitized['pseudo_id']}")

    try:
        with get_mtls_client() as client:
            resp = client.post(FOG_URL, json=sanitized)
            resp.raise_for_status()
    except Exception as e:
        log.error(f"Fog forward failed: {e}")
        raise HTTPException(status_code=502, detail="Fog unreachable")

    return {"status": "forwarded", "pseudo_id": sanitized['pseudo_id']}


@app.get("/health")
async def health():
    return {"status": "ok"}
