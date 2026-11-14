#!/usr/bin/env python3
"""M7.T10 (AT-255): fixtures/web/mcp/composio-gmail-readonly.jsonl and composio-gmail-send.jsonl.

Synthetic (CC0) JSON-RPC sessions of a Composio ToolRouter MCP endpoint (Streamable HTTP, MCP 2025-11-25), replayed
by relay/test/mock-composio.ts behind the relay's /v1/mcp pass-through. Tool results follow the response shapes of
@composio/core 0.27.0 `src/types/toolRouter.types.ts` (ToolRouterSessionSearchResponseSchema,
ToolRouterSessionExecuteResponseSchema; tag hints readOnlyHint/createHint/updateHint/destructiveHint). Fake people and
addresses only (example.com / example.org, RFC 2606). No real data.

One JSON object per line: {"request": <JSON-RPC request or notification>, "response": <JSON-RPC response> | null}.
The mock matches a request by `method` (+ `params.name` for tools/call, + the first tool_slug inside
COMPOSIO_MULTI_EXECUTE_TOOL) and answers with `response`, the id rewritten to the caller's id. `response: null` = a
notification (HTTP 202, no body).

Run: python3 -I tools/fixtures/make-composio-fixtures.py <fixtures-dir>
"""
import json
import sys
from pathlib import Path

PROTOCOL = "2025-11-25"
SESSION = "trs_fixture000001"
NOW = "2026-11-07T09:00:00Z"
EPOCH = 1794042000


def obj_schema(props: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": props, "required": required}


META_TOOLS = [
    {"name": "COMPOSIO_SEARCH_TOOLS",
     "description": "Find the tools that fit a use case across the toolkits enabled for this session.",
     "inputSchema": obj_schema({"queries": {"type": "array", "items": obj_schema(
         {"use_case": {"type": "string"}}, ["use_case"])}, "session": obj_schema({"id": {"type": "string"}}, [])},
         ["queries"]),
     "annotations": {"title": "Search tools", "readOnlyHint": True, "openWorldHint": True}},
    {"name": "COMPOSIO_GET_TOOL_SCHEMAS",
     "description": "Return the full input schemas of tools found by COMPOSIO_SEARCH_TOOLS.",
     "inputSchema": obj_schema({"tool_slugs": {"type": "array", "items": {"type": "string"}}}, ["tool_slugs"]),
     "annotations": {"title": "Get tool schemas", "readOnlyHint": True}},
    {"name": "COMPOSIO_MANAGE_CONNECTIONS",
     "description": "Check or start the connection of a toolkit for this user.",
     "inputSchema": obj_schema({"toolkits": {"type": "array", "items": {"type": "string"}}}, ["toolkits"]),
     "annotations": {"title": "Manage connections", "readOnlyHint": False, "openWorldHint": True}},
    {"name": "COMPOSIO_MULTI_EXECUTE_TOOL",
     "description": "Execute one or more tools found by COMPOSIO_SEARCH_TOOLS, in parallel.",
     "inputSchema": obj_schema({"tools": {"type": "array", "items": obj_schema(
         {"tool_slug": {"type": "string"}, "arguments": {"type": "object"}}, ["tool_slug", "arguments"])},
         "sync_response_to_workbench": {"type": "boolean"}}, ["tools"]),
     "annotations": {"title": "Execute tools", "readOnlyHint": False, "destructiveHint": True, "openWorldHint": True}},
]


def rpc(id_: int, method: str, params: dict | None = None) -> dict:
    d = {"jsonrpc": "2.0", "id": id_, "method": method}
    if params is not None:
        d["params"] = params
    return d


def ok(id_: int, result: dict) -> dict:
    return {"jsonrpc": "2.0", "id": id_, "result": result}


def text_result(payload: dict) -> dict:
    return {"content": [{"type": "text", "text": json.dumps(payload, sort_keys=True, separators=(",", ":"))}],
            "isError": False}


def search_payload(use_case: str, slugs: list[tuple[str, str, str]]) -> dict:
    """ToolRouterSessionSearchResponseSchema (camelCase, as the SDK types it)."""
    return {
        "success": True,
        "error": None,
        "results": [{"index": 1, "useCase": use_case, "primaryToolSlugs": [s for s, _, _ in slugs],
                     "relatedToolSlugs": [], "toolkits": ["gmail"], "difficulty": "easy", "error": None,
                     "recommendedPlanSteps": ["Call the primary tool once."], "knownPitfalls": []}],
        "toolSchemas": {s: {"toolSlug": s, "toolkit": "gmail", "description": d, "hasFullSchema": True,
                            "inputSchema": obj_schema({}, [])} for s, d, _ in slugs},
        "toolkitConnectionStatuses": [{"toolkit": "gmail", "description": "Gmail", "hasActiveConnection": True,
                                       "statusMessage": "Connected as reader@example.com"}],
        "nextStepsGuidance": ["Use COMPOSIO_MULTI_EXECUTE_TOOL with the primary tool."],
        "session": {"id": SESSION, "generateId": False, "instructions": "Reuse this session id."},
        "timeInfo": {"currentTimeUtc": NOW, "currentTimeUtcEpochSeconds": EPOCH, "message": "Current time."},
    }


def execute_payload(slug: str, data: dict, log_id: str) -> dict:
    """COMPOSIO_MULTI_EXECUTE_TOOL result: one ToolRouterSessionExecuteResponseSchema entry per tool."""
    return {"data": {"results": [{"tool_slug": slug, "index": 0,
                                  "response": {"data": data, "error": None, "logId": log_id,
                                               "resultType": "completed"}}],
                     "total_count": 1, "success_count": 1, "error_count": 0},
            "error": None, "logId": log_id, "resultType": "completed"}


def preamble() -> list[dict]:
    return [
        {"request": rpc(1, "initialize", {"protocolVersion": PROTOCOL, "capabilities": {},
                                          "clientInfo": {"name": "AntiChat", "version": "0.7.0"}}),
         "response": ok(1, {"protocolVersion": PROTOCOL, "capabilities": {"tools": {"listChanged": False}},
                            "serverInfo": {"name": "composio-tool-router", "version": "3.1.0"},
                            "instructions": "Search first, then execute."})},
        {"request": {"jsonrpc": "2.0", "method": "notifications/initialized"}, "response": None},
        {"request": rpc(2, "tools/list", {}), "response": ok(2, {"tools": META_TOOLS})},
    ]


FETCH_DATA = {"messages": [
    {"messageId": "18f0a1b2c3d4e5f6", "threadId": "18f0a1b2c3d4e5f6", "sender": "Mara Quill <mara.quill@example.com>",
     "to": "reader@example.com", "subject": "Quarterly garden plan draft",
     "messageTimestamp": "2026-11-06T16:20:00Z", "labelIds": ["INBOX", "UNREAD"],
     "preview": {"body": "Bring the blue folder to the Tuesday review, the tulip budget is attached."}},
    {"messageId": "18f0a1b2c3d4e5f7", "threadId": "18f0a1b2c3d4e5f7", "sender": "Ilo Fenwick <ilo@example.org>",
     "to": "reader@example.com", "subject": "Lantern parade volunteers",
     "messageTimestamp": "2026-11-05T08:02:00Z", "labelIds": ["INBOX"],
     "preview": {"body": "Seven volunteers signed up for the lantern parade on Friday."}},
], "nextPageToken": None, "resultSizeEstimate": 2}

SEND_DATA = {"id": "18f0b9c8d7e6f5a4", "threadId": "18f0b9c8d7e6f5a4", "labelIds": ["SENT"]}


def readonly() -> list[dict]:
    use_case = "find my unread emails from this week"
    return preamble() + [
        {"request": rpc(3, "tools/call", {"name": "COMPOSIO_SEARCH_TOOLS",
                                          "arguments": {"queries": [{"use_case": use_case}]}}),
         "response": ok(3, text_result(search_payload(use_case, [
             ("GMAIL_FETCH_EMAILS", "Fetch a list of email messages.", "readOnlyHint")])))},
        {"request": rpc(4, "tools/call", {"name": "COMPOSIO_MULTI_EXECUTE_TOOL", "arguments": {"tools": [
            {"tool_slug": "GMAIL_FETCH_EMAILS", "arguments": {"query": "is:unread newer_than:7d", "max_results": 10}}]}}),
         "response": ok(4, text_result(execute_payload("GMAIL_FETCH_EMAILS", FETCH_DATA, "log_fx_fetch_0001")))},
    ]


def send() -> list[dict]:
    use_case = "send an email"
    return preamble() + [
        {"request": rpc(3, "tools/call", {"name": "COMPOSIO_SEARCH_TOOLS",
                                          "arguments": {"queries": [{"use_case": use_case}]}}),
         "response": ok(3, text_result(search_payload(use_case, [
             ("GMAIL_SEND_EMAIL", "Send an email message.", "createHint")])))},
        {"request": rpc(4, "tools/call", {"name": "COMPOSIO_MULTI_EXECUTE_TOOL", "arguments": {"tools": [
            {"tool_slug": "GMAIL_SEND_EMAIL", "arguments": {
                "recipient_email": "reader@example.com", "subject": "Moss sample results",
                "body": "The moss sample from the north wall came back healthy."}}]}}),
         "response": ok(4, text_result(execute_payload("GMAIL_SEND_EMAIL", SEND_DATA, "log_fx_send_0001")))},
    ]


def write(path: Path, lines: list[dict]) -> None:
    path.write_text("".join(json.dumps(l, sort_keys=True, separators=(",", ":")) + "\n" for l in lines))
    print(path)


def main() -> None:
    out = Path(sys.argv[1]) / "web/mcp"
    out.mkdir(parents=True, exist_ok=True)
    write(out / "composio-gmail-readonly.jsonl", readonly())
    write(out / "composio-gmail-send.jsonl", send())


if __name__ == "__main__":
    main()
