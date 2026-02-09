import os
import json
import base64
import boto3
import hashlib
from botocore.exceptions import ClientError

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


def _read_resp_payload(resp: dict) -> str:
    """
    AgentCore invoke responses can differ by SDK/version.
    Try common keys, handle StreamingBody / bytes / str.
    """
    # Log keys once so we learn the real shape in your environment
    print("invoke_agent_runtime response keys:", list(resp.keys()))

    payload_obj = None
    for key in ("payload", "Payload", "body", "Body"):
        if key in resp:
            payload_obj = resp[key]
            break

    if payload_obj is None:
        # Return a helpful error rather than KeyError
        raise KeyError(f"No payload field found in response. Keys: {list(resp.keys())}")

    # StreamingBody-like
    if hasattr(payload_obj, "read"):
        out_bytes = payload_obj.read()
        if isinstance(out_bytes, bytes):
            return out_bytes.decode("utf-8")
        return str(out_bytes)

    # Bytes
    if isinstance(payload_obj, (bytes, bytearray)):
        return bytes(payload_obj).decode("utf-8")

    # Already string or JSON-ish
    if isinstance(payload_obj, str):
        return payload_obj

    # Fallback (dict, list etc.)
    return json.dumps(payload_obj)


def handler(event, context):
    # Expecting React body like: { "msg": "...", "sessionId": "...", "clientMessageId": "..." }
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
        out_text = _read_resp_payload(resp)

        return {
            "statusCode": 200,
            "headers": {"content-type": "application/json"},
            "body": out_text,
        }

    except ClientError as e:
        # AWS-side error (permissions, invalid runtime arn, etc.)
        print("ClientError invoking AgentCore:", str(e))
        return {
            "statusCode": 502,
            "headers": {"content-type": "application/json"},
            "body": json.dumps({
                "error": "InvokeAgentRuntime failed",
                "type": "ClientError",
                "detail": str(e),
            }),
        }

    except Exception as e:
        # Runtime 502, parsing issues, etc.
        print("Unexpected error invoking AgentCore:", repr(e))
        return {
            "statusCode": 502,
            "headers": {"content-type": "application/json"},
            "body": json.dumps({
                "error": "AgentCore runtime returned an error",
                "type": e.__class__.__name__,
                "detail": str(e),
            }),
        }
