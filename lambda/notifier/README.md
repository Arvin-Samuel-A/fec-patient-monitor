# Lambda Twilio Notifier (Recreated)

This Lambda receives alert payloads from Fog, reads Twilio secrets from AWS SSM Parameter Store, then sends SMS and optional voice call.

## Runtime

- Python 3.11

## Handler

- lambda_function.lambda_handler

## Environment Variables (values are SSM parameter keys)

- TWILIO_ACCOUNT_SID_PARAM=/fec/twilio/account-sid
- TWILIO_AUTH_TOKEN_PARAM=/fec/twilio/auth-token
- TWILIO_PHONE_NUMBER_PARAM=/fec/twilio/phone-number
- ALERT_RECIPIENT_PHONE_PARAM=/fec/twilio/recipient-phone
- ENABLE_TWILIO_CALL=true

Optional toggles:

- ENABLE_TWILIO_SMS=true
- ENABLE_TWILIO_CALL=true

## Build Deployment Artifact

1. cd lambda/notifier
2. chmod +x build-package.sh
3. ./build-package.sh

This creates: lambda/notifier/notifier.zip

## Deploy

1. Upload notifier.zip to Lambda function fec-alert-notifier.
2. Ensure handler is exactly lambda_function.lambda_handler.
3. Ensure Lambda IAM has:
   - ssm:GetParameters
   - kms:Decrypt (if SecureString uses customer managed KMS key)

## If SMS works but call does not

Check CloudWatch logs for "Twilio voice call failed". The notifier logs Twilio code/status now.

Common causes:

- Twilio number does not have voice capability
- Destination number is not verified (trial account)
- Twilio geo permissions for destination country are disabled
- Invalid E.164 formatting in SSM value (must be like +9198...)
- Account restrictions/balance issues

## Test Payload Example

{
  "source": "fog-service",
  "alert": {
    "pseudo_id": "abc123",
    "alert_type": "HIGH_HEART_RATE",
    "severity": "HIGH",
    "value": 160,
    "threshold": 100,
    "timestamp": "2026-04-09T02:00:00Z",
    "latency_ms": 20
  }
}
