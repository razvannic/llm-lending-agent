import os
import json
import base64
import boto3
import hashlib
import logging

log = logging.getLogger()
log.setLevel(logging.INFO)

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
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()

def _read_stream(maybe_stream) -> bytes:
    if maybe_stream is None:
        return b""
    if hasattr(maybe_stream, "read"):
        return maybe_stream.read()
    if isinstance(maybe_stream, (bytes, bytearray)):
        return bytes(maybe_stream)
    # last resort
    return str(maybe_stream).encode("utf-8")

def handler(event, context):
    body = _json_body_from_apigw(event)

    session_id = body.get("sessionId") or "demo-session"
    runtime_session_id = normalize_runtime_session_id(session_id)

    payload_bytes = json.dumps(body).encode("utf-8")

    try:
        resp = client.invoke_agent_runtime(
            agentRuntimeArn=AGENT_RUNTIME_ARN,
            qualifier=QUALIFIER,
            runtimeSessionId=runtime_session_id,
            payload=payload_bytes,
            contentType="application/json",
            accept="application/json",
        )

        status = resp.get("statusCode")
        log.info("invoke_agent_runtime response keys: %s", list(resp.keys()))
        log.info("AgentCore statusCode=%s traceId=%s", status, resp.get("traceId"))

        # IMPORTANT: the body is in `response`, not `payload`
        out_bytes = _read_stream(resp.get("response"))
        out_text = out_bytes.decode("utf-8", errors="replace")

        # If runtime returned an error, propagate it (don’t pretend 200)
        if status and int(status) >= 400:
            return {
                "statusCode": int(status),
                "headers": {"content-type": resp.get("contentType", "application/json")},
                "body": out_text or json.dumps({
                    "error": "InvokeAgentRuntime failed",
                    "statusCode": status,
                    "traceId": resp.get("traceId")
                })
            }

        return {
            "statusCode": 200,
            "headers": {"content-type": resp.get("contentType", "application/json")},
            "body": out_text
        }

    except Exception as e:
        log.exception("ClientError invoking AgentCore: %s", e)
        return {
            "statusCode": 502,
            "headers": {"content-type": "application/json"},
            "body": json.dumps({
                "error": "InvokeAgentRuntime failed",
                "type": e.__class__.__name__,
                "detail": str(e),
            })
        }
