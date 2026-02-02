import json
import os
import time
import boto3
from pydantic import BaseModel
from typing import Any, Optional, Dict
from bedrock_agentcore import BedrockAgentCoreApp

app = BedrockAgentCoreApp()

ddb = boto3.client("dynamodb")
sfn = boto3.client("stepfunctions")

TABLE = os.environ["DDB_TABLE_NAME"]
SFN_ARN = os.environ["SFN_ARN"]
ENV = os.getenv("ENV", "dev")

class ChatRequest(BaseModel):
    msg: Optional[str] = None
    warmup: Optional[bool] = False
    sessionId: Optional[str] = None
    clientMessageId: Optional[str] = None  # add later; optional for tiny demo

class ChatResponse(BaseModel):
    ok: bool = True
    sessionId: str
    nextStage: str
    assistantMessage: str
    uiHints: Dict[str, Any] = {}

def now_iso() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

def ddb_get(session_id: str) -> Dict[str, Any]:
    res = ddb.get_item(
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
    ddb.put_item(TableName=TABLE, Item=item)

@app.entrypoint
def invoke(request: dict[str, Any], context=None) -> str:
    req = ChatRequest.model_validate(request)

    # warmup support (your React already does this)
    if req.warmup:
        return json.dumps({"ok": True, "message": "warmed"})

    session_id = req.sessionId or "demo-session"  # keep tiny; replace with UUID later

    # load current stage from DDB
    item = ddb_get(session_id)
    current_stage = (item.get("stage", {}) or {}).get("S", "ENQUIRY")

    # call SFN synchronously (authoritative one-step advance)
    sfn_in = {
        "sessionId": session_id,
        "currentStage": current_stage,
        "message": req.msg or "",
        "nlu": {}  # add Bedrock assist later
    }

    exec_res = sfn.start_sync_execution(
        stateMachineArn=SFN_ARN,
        input=json.dumps(sfn_in),
    )
    out = json.loads(exec_res["output"])

    next_stage = out.get("nextStage", current_stage)
    assistant = out.get("assistantMessage", "OK")
    ui_hints = out.get("uiHints", {})

    # persist updated stage
    ddb_put_state(session_id, next_stage, {"lastMessage": req.msg or ""})

    return ChatResponse(
        sessionId=session_id,
        nextStage=next_stage,
        assistantMessage=assistant,
        uiHints=ui_hints,
    ).model_dump_json()
