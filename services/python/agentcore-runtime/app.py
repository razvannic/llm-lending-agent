import os
import time
from typing import Any, Optional, Dict
import json
import traceback

import boto3
from pydantic import BaseModel
from bedrock_agentcore import BedrockAgentCoreApp

app = BedrockAgentCoreApp()

TABLE = os.getenv("DDB_TABLE_NAME", "")
SFN_ARN = os.getenv("SFN_ARN", "")
ENV = os.getenv("ENV", "dev")

# Lazily initialized clients (avoid import-time failures if region/env isn't ready yet)
_ddb = None
_sfn = None

def ddb():
    global _ddb
    if _ddb is None:
        _ddb = boto3.client("dynamodb")
    return _ddb

def sfn():
    global _sfn
    if _sfn is None:
        _sfn = boto3.client("stepfunctions")
    return _sfn


class ChatRequest(BaseModel):
    msg: Optional[str] = None
    warmup: Optional[bool] = False
    sessionId: Optional[str] = None
    clientMessageId: Optional[str] = None


def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def ddb_get(session_id: str) -> Dict[str, Any]:
    res = ddb().get_item(
        TableName=TABLE,
        Key={"PK": {"S": f"SESSION#{session_id}"}, "SK": {"S": "STATE"}},
    )
    return res.get("Item") or {}


def ddb_put_state(session_id: str, stage: str, extra: Dict[str, Any]):
    item = {
        "PK": {"S": f"SESSION#{session_id}"},
        "SK": {"S": "STATE"},
        "env": {"S": ENV},
        "stage": {"S": stage},
        "updatedAt": {"S": now_iso()},
    }
    for k, v in extra.items():
        item[k] = {"S": str(v)}
    ddb().put_item(TableName=TABLE, Item=item)


@app.entrypoint
def invoke(request: Dict[str, Any], context=None) -> Dict[str, Any]:
    if not TABLE or not SFN_ARN:
        return {
            "ok": False,
            "error": "missing_env",
            "detail": f"DDB_TABLE_NAME or SFN_ARN not set. DDB_TABLE_NAME={'set' if TABLE else 'missing'}, SFN_ARN={'set' if SFN_ARN else 'missing'}"
        }
    try:
        req = ChatRequest.model_validate(request)

        if req.warmup:
            return {"ok": True, "message": "warmed"}

        session_id = req.sessionId or "demo-session"

        item = ddb_get(session_id)
        current_stage = (item.get("stage", {}) or {}).get("S", "ENQUIRY")

        sfn_in = {
            "sessionId": session_id,
            "currentStage": current_stage,
            "message": req.msg or "",
            "nlu": {},
        }

        exec_res = sfn().start_sync_execution(
            stateMachineArn=SFN_ARN,
            input=json.dumps(sfn_in),
        )

        out = json.loads(exec_res["output"])

        next_stage = out.get("nextStage", current_stage)
        assistant = out.get("assistantMessage", "OK")
        ui_hints = out.get("uiHints", {})

        ddb_put_state(session_id, next_stage, {"lastMessage": req.msg or ""})

        return {
            "ok": True,
            "sessionId": session_id,
            "nextStage": next_stage,
            "assistantMessage": assistant,
            "uiHints": ui_hints,
        }

    except Exception as e:
        # This prints to stdout/stderr -> should show in AgentCore logs once enabled/visible
        print("ERROR in runtime invoke:", repr(e))
        print(traceback.format_exc())
        return {
            "ok": False,
            "error": "runtime_exception",
            "detail": str(e),
        }

if __name__ == "__main__":
    # Critical: keeps the container alive and exposes the AgentCore endpoints.
    app.run()
