import json
import logging
import os
from typing import Any, Dict

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

_ssm = boto3.client("ssm")


def _env(name: str, default: str) -> str:
    value = os.getenv(name, "").strip()
    return value if value else default


def _env_bool(name: str, default: bool) -> bool:
    raw = os.getenv(name, "").strip().lower()
    if raw == "":
        return default
    return raw in {"1", "true", "yes", "on"}


def _mask_phone(number: str) -> str:
    cleaned = number.strip()
    if len(cleaned) <= 4:
        return "****"
    return ("*" * max(0, len(cleaned) - 4)) + cleaned[-4:]


def _twilio_error_details(exc: Exception) -> str:
    code = getattr(exc, "code", None)
    status = getattr(exc, "status", None)
    parts = [str(exc)]
    if code is not None:
        parts.append(f"code={code}")
    if status is not None:
        parts.append(f"status={status}")
    return " | ".join(parts)


def _load_twilio_values_from_ssm() -> Dict[str, str]:
    """
    Lambda environment variables store SSM parameter keys (names), not secrets.
    """
    param_keys = {
        "account_sid": _env("TWILIO_ACCOUNT_SID_PARAM", "/fec/twilio/account-sid"),
        "auth_token": _env("TWILIO_AUTH_TOKEN_PARAM", "/fec/twilio/auth-token"),
        "from_phone": _env("TWILIO_PHONE_NUMBER_PARAM", "/fec/twilio/phone-number"),
        "to_phone": _env("ALERT_RECIPIENT_PHONE_PARAM", "/fec/twilio/recipient-phone"),
    }

    response = _ssm.get_parameters(Names=list(param_keys.values()), WithDecryption=True)
    values_by_name = {item["Name"]: item["Value"] for item in response.get("Parameters", [])}

    missing = [name for name in param_keys.values() if name not in values_by_name]
    if missing:
        raise RuntimeError("Missing SSM parameters: " + ", ".join(missing))

    return {
        "account_sid": values_by_name[param_keys["account_sid"]],
        "auth_token": values_by_name[param_keys["auth_token"]],
        "from_phone": values_by_name[param_keys["from_phone"]],
        "to_phone": values_by_name[param_keys["to_phone"]],
    }


def _get_twilio_client_class():
    try:
        from twilio.rest import Client
    except Exception as exc:
        raise RuntimeError(
            "Twilio package is missing in Lambda artifact. Build and upload notifier.zip."
        ) from exc
    return Client


def _normalize_alert(event: Any) -> Dict[str, Any]:
    payload: Any = event
    if isinstance(event, str):
        try:
            payload = json.loads(event)
        except json.JSONDecodeError:
            payload = {}

    if not isinstance(payload, dict):
        return {}

    alert = payload.get("alert")
    if isinstance(alert, dict):
        return alert

    return payload


def _build_message(alert: Dict[str, Any]) -> str:
    return (
        "FEC ALERT\n"
        f"Type: {alert.get('alert_type', 'UNKNOWN')}\n"
        f"Severity: {alert.get('severity', 'UNKNOWN')}\n"
        f"Pseudo ID: {alert.get('pseudo_id', '-')}\n"
        f"Value: {alert.get('value', '-')} (threshold {alert.get('threshold', '-')})\n"
        f"Latency: {alert.get('latency_ms', '-')} ms\n"
        f"Time: {alert.get('timestamp', '-')}"
    )


def _send_voice_call(client, from_phone: str, to_phone: str) -> str:
    twiml = (
        "<Response>"
        "<Say voice='alice'>"
        "Critical patient alert detected. Please check the dashboard now."
        "</Say>"
        "</Response>"
    )
    call = client.calls.create(twiml=twiml, from_=from_phone, to=to_phone)
    return call.sid


def lambda_handler(event, context):
    try:
        settings = _load_twilio_values_from_ssm()
        alert = _normalize_alert(event)
        message_body = _build_message(alert)

        Client = _get_twilio_client_class()
        twilio_client = Client(settings["account_sid"], settings["auth_token"])

        sms_enabled = _env_bool("ENABLE_TWILIO_SMS", True)
        call_enabled = _env_bool("ENABLE_TWILIO_CALL", True)

        logger.info(
            "Notifier start sms_enabled=%s call_enabled=%s from=%s to=%s alert_type=%s",
            sms_enabled,
            call_enabled,
            _mask_phone(settings["from_phone"]),
            _mask_phone(settings["to_phone"]),
            alert.get("alert_type", "UNKNOWN"),
        )

        sms_sid = None
        sms_error = None
        call_sid = None
        call_error = None

        if sms_enabled:
            try:
                sms = twilio_client.messages.create(
                    body=message_body,
                    from_=settings["from_phone"],
                    to=settings["to_phone"],
                )
                sms_sid = sms.sid
            except Exception as exc:
                sms_error = _twilio_error_details(exc)
                logger.exception("Twilio SMS failed: %s", sms_error)

        if call_enabled:
            try:
                call_sid = _send_voice_call(
                    twilio_client,
                    from_phone=settings["from_phone"],
                    to_phone=settings["to_phone"],
                )
            except Exception as exc:
                call_error = _twilio_error_details(exc)
                logger.exception("Twilio voice call failed: %s", call_error)

        logger.info(
            "Notifier result sms_sid=%s call_sid=%s sms_error=%s call_error=%s",
            sms_sid,
            call_sid,
            sms_error,
            call_error,
        )

        success = bool(sms_sid or call_sid)
        status_code = 200 if success else 500

        return {
            "statusCode": status_code,
            "body": json.dumps(
                {
                    "status": "ok" if success else "error",
                    "sms_sid": sms_sid,
                    "call_sid": call_sid,
                    "sms_error": sms_error,
                    "call_error": call_error,
                }
            ),
        }
    except Exception as exc:
        logger.exception("Notifier failure: %s", exc)
        return {
            "statusCode": 500,
            "body": json.dumps({"status": "error", "message": str(exc)}),
        }
