# services/python/stage-handler/handler.py
import json

def handler(event, context):
    # event will contain sessionId, currentStage, message, nlu, etc.
    current = event.get("currentStage", "ENQUIRY")

    # minimal "one step forward" demo
    order = ["ENQUIRY", "LOAN_INFO", "LOAN_OPTIONS", "APPLICATION_START"]
    try:
        i = order.index(current)
        next_stage = order[min(i + 1, len(order) - 1)]
    except ValueError:
        next_stage = "ENQUIRY"

    return {
        "nextStage": next_stage,
        "assistantMessage": f"Moved from {current} to {next_stage}",
        "updatedState": {
            "lastUserMessage": event.get("message", "")
        },
        "uiHints": {
            "buttons": ["Continue"],
            "form": None
        }
    }
