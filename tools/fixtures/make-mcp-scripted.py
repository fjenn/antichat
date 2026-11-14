#!/usr/bin/env python3
"""M7.T06 (AT-081, journey 12): fixtures/web/mcp/scripted-server.jsonl, the recorded MCP session the in-process
ScriptedMCPTransport replays. Synthetic (CC0): a "Team Chat" server speaking 2025-11-25 with a read tool
(`search_messages`, readOnlyHint) and a write tool (`send_message`, destructiveHint). One JSON object per line:
{"method": …, "result": …} (+ "tool" for tools/call). Run: python3 -I tools/fixtures/make-mcp-scripted.py <fixtures>"""
import json
import sys
from pathlib import Path

TOOLS = [
    {"name": "search_messages", "description": "Search the team's messages by words.",
     "inputSchema": {"type": "object", "properties": {"query": {"type": "string"}}, "required": ["query"]},
     "annotations": {"title": "Search messages", "readOnlyHint": True, "openWorldHint": False}},
    {"name": "send_message", "description": "Send a message to a channel.",
     "inputSchema": {"type": "object", "properties": {"channel": {"type": "string"}, "text": {"type": "string"}},
                     "required": ["channel", "text"]},
     "annotations": {"title": "Send message", "readOnlyHint": False, "destructiveHint": True}},
]

LINES = [
    {"method": "initialize", "result": {"protocolVersion": "2025-11-25",
                                         "capabilities": {"tools": {"listChanged": True}},
                                         "serverInfo": {"name": "team-chat", "version": "1.4.0"}}},
    {"method": "tools/list", "result": {"tools": TOOLS}},
    {"method": "tools/call", "tool": "search_messages",
     "result": {"content": [{"type": "text", "text": "#general 09:12 Ana: the launch moved to Thursday."}], "isError": False}},
    {"method": "tools/call", "tool": "send_message",
     "result": {"content": [{"type": "text", "text": "Sent to #general."}], "isError": False}},
]


def main() -> None:
    out = Path(sys.argv[1]) / "web/mcp/scripted-server.jsonl"
    out.write_text("".join(json.dumps(l, sort_keys=True, separators=(",", ":")) + "\n" for l in LINES))
    print(out)


if __name__ == "__main__":
    main()
