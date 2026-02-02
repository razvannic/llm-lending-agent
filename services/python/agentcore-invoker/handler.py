import os
import json
import base64
import boto3
import hashlib

client = boto3.client("bedrock-agentcore")

AGENT_RUNTIME_ARN = os.environ["AGENTCORE_RUNTIME_ARN"]
QUALIFIER = os.getenv("AGENTCORE_QUALIFIER", "DEFAULT")

def _json_body_from_apigw(event):
    body = event.get("body") or ""
    if event.get("isBase64Encoded"):
        body = base64.b64decode(body).decode("utf-8")
    if not body:
        return {}
    return json.loads(body)

def normalize_runtime_session_id(raw: str) -> str:
    # stable, deterministic, always 64 chars
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()

def handler(event, context):
    # Expecting React body like: { "msg": "...", "sessionId": "...", "clientMessageId": "..." }
    body = _json_body_from_apigw(event)

    # keep it minimal for now
    session_id = body.get("sessionId") or "demo-session"
    runtime_session_id = normalize_runtime_session_id(session_id)

    payload_bytes = json.dumps(body).encode("utf-8")

    resp = client.invoke_agent_runtime(
        agentRuntimeArn=AGENT_RUNTIME_ARN,
        qualifier=QUALIFIER,
        runtimeSessionId=runtime_session_id,
        payload=payload_bytes,
        contentType="application/json",
        accept="application/json",
    )

    # boto3 returns payload as bytes stream-ish; handle robustly
    payload = resp["payload"]
    if hasattr(payload, "read"):
        out_bytes = payload.read()
    else:
        out_bytes = payload

    out_text = out_bytes.decode("utf-8")

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": out_text
    }
