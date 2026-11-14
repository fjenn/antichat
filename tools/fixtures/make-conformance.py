#!/usr/bin/env python3
"""M1.T13 conformance case lists (AT-229): tools-50, thinking-20, cancel-10 (JSONL, one case per line).

Every row cites the upstream test it comes from (`source.file` + `source.line`, found by an anchor string that must
exist in the pinned checkout, so a pin bump that moves or drops a case fails here instead of silently drifting):
  mlx-swift-lm @ f5b0677  Tests/MLXLMTests/{TextToolCallRecoveryTests,ToolCallFormatInferenceTests,
                          NamedJSONToolCallTests,CancellationTests,ReasoningConfigTests}.swift
  llama.cpp    @ 620d222  tools/server/tests/unit/{test_tool_call,test_chat_completion}.py
Rows marked `derived: true` are AntiChat variants of the cited upstream case (same tool, new argument value or
phrasing) so each engine x family row gets 50 tool cases; `kind` is single | multiple | parallel | no_call | recovery.
`recovery` rows are parser-level (raw model text through the family's native parser + RawToolSyntaxScrubber, no
model); the others are prompts for a real model. Licences: both upstreams MIT (case text quoted under MIT notice).

Usage: python3 -I tools/fixtures/make-conformance.py --mlx-swift-lm <checkout> --llama-cpp <checkout> --out <dir>
Stdlib only, deterministic (no randomness, sorted keys).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

MLX_SHA = "f5b0677f6b52b81d068871611cfcb82d1e7a0005"
LLAMA_SHA = "620d2225cc436ab0b001e3200e590e3b286ef9ab"
TT = "tools/server/tests/unit/test_tool_call.py"
TC = "tools/server/tests/unit/test_chat_completion.py"
REC = "Tests/MLXLMTests/TextToolCallRecoveryTests.swift"
NJ = "Tests/MLXLMTests/NamedJSONToolCallTests.swift"
FI = "Tests/MLXLMTests/ToolCallFormatInferenceTests.swift"
CAN = "Tests/MLXLMTests/CancellationTests.swift"
RCF = "Tests/MLXLMTests/ReasoningConfigTests.swift"

ROOTS: dict[str, Path] = {}


def src(repo: str, file: str, anchor: str) -> dict:
    root = ROOTS[repo]
    lines = (root / file).read_text(encoding="utf-8").splitlines()
    for i, line in enumerate(lines, 1):
        if anchor in line:
            sha = MLX_SHA if repo == "mlx-swift-lm" else LLAMA_SHA
            return {"repo": f"{'ml-explore/mlx-swift-lm' if repo == 'mlx-swift-lm' else 'ggml-org/llama.cpp'}@{sha[:7]}",
                    "file": file, "line": i, "anchor": anchor}
    sys.exit(f"anchor not found in {repo}:{file}: {anchor!r}")


def fn(name, desc, props, required):
    return {"type": "function", "function": {"name": name, "description": desc,
            "parameters": {"type": "object", "properties": props, "required": required}}}


# Tools quoted from llama.cpp test_tool_call.py (TEST_TOOL :46, PYTHON_TOOL :64, WEATHER_TOOL :82, calculate :488).
TEST_TOOL = fn("test", "", {"success": {"type": "boolean", "const": True}}, ["success"])
PYTHON_TOOL = fn("python", "Runs code in an ipython interpreter and returns the result of the execution after 60 seconds.",
                 {"code": {"type": "string", "description": "The code to run in the ipython interpreter."}}, ["code"])
WEATHER_TOOL = fn("get_current_weather", "Get the current weather in a given location",
                  {"location": {"type": "string", "description": "The city and country/state, e.g. 'San Francisco, CA', or 'Paris, France'"}},
                  ["location"])
CALC_TOOL = fn("calculate", "A calculator function that computes values of arithmetic expressions in the Python syntax",
               {"expression": {"type": "string", "description": "An arithmetic expression to compute the value of (Python syntad, assuming all floats)"}},
               ["expression"])
# mlx-swift-lm TextToolCallRecoveryTests.swift:10-16 declares `weather` with a `city` argument.
MLX_WEATHER = fn("weather", "Get the weather for a city.", {"city": {"type": "string"}}, ["city"])

SYS_TOOLS = "You are a chatbot that uses tools/functions. Dont overthink things."  # test_tool_call.py:406
SYS_CODE = "You are a coding assistant."  # test_tool_call.py:104


def msgs(user, system=SYS_TOOLS):
    m = [{"role": "system", "content": system}] if system else []
    return m + [{"role": "user", "content": user}]


def tool_cases() -> list[dict]:
    rows: list[dict] = []
    weather_src = src("llama.cpp", TT, '"What is the weather in Istanbul?"')
    python_src = src("llama.cpp", TT, '"say hello world with python"')
    calc_src = src("llama.cpp", TT, '"name":"calculate"')
    test_src = src("llama.cpp", TT, "TEST_TOOL = ToolDefinition(")
    mlxw_src = src("mlx-swift-lm", REC, '"name": "weather"')

    def add(kind, cid, source, user, tools, expect, system=SYS_TOOLS, derived=False, tool_choice=None):
        r = {"id": cid, "kind": kind, "source": source, "derived": derived, "messages": msgs(user, system),
             "tools": tools, "expect": expect}
        if tool_choice:
            r["tool_choice"] = tool_choice
        rows.append(r)

    # single (16)
    add("single", "t-single-01", weather_src, "What is the weather in Istanbul?", [WEATHER_TOOL],
        {"calls": ["get_current_weather"], "args_contains": {"location": "istanbul"}})
    add("single", "t-single-02", python_src, "say hello world with python", [PYTHON_TOOL],
        {"calls": ["python"], "args_contains": {"code": "hello"}}, system=SYS_CODE)
    for i, city in enumerate(["Paris, France", "Tokyo", "San Francisco, CA", "Lisbon", "Nairobi", "Buenos Aires"], 3):
        add("single", f"t-single-{i:02d}", weather_src, f"What is the weather in {city}?", [WEATHER_TOOL],
            {"calls": ["get_current_weather"], "args_contains": {"location": city.split(",")[0].lower()}}, derived=True)
    for i, (ask, needle) in enumerate([
        ("print the first 10 prime numbers with python", "prime|print"),
        ("use python to compute 2**100", "2"),
        ("run python code that reverses the string 'hello'", "hello"),
        ("with python, sort the list [3, 1, 2] and print it", "sort"),
    ], 9):
        add("single", f"t-single-{i:02d}", python_src, ask, [PYTHON_TOOL],
            {"calls": ["python"], "args_contains": {"code": needle}}, system=SYS_CODE, derived=True)
    add("single", "t-single-13", calc_src, "Use the calculator to compute 12.5 * 8.", [CALC_TOOL],
        {"calls": ["calculate"], "args_contains": {"expression": "12"}}, derived=True)
    add("single", "t-single-14", calc_src, "Use the calculator: what is sin(30 * pi / 180)?", [CALC_TOOL],
        {"calls": ["calculate"], "args_contains": {"expression": "sin"}}, derived=True)
    add("single", "t-single-15", test_src, "Call the test tool to report success.", [TEST_TOOL],
        {"calls": ["test"], "args_contains": {}}, derived=True)
    add("single", "t-single-16", mlxw_src, "What's the weather in Paris?", [MLX_WEATHER],
        {"calls": ["weather"], "args_contains": {"city": "paris"}}, derived=True)

    # multiple (10): several tools offered, the right one must be chosen.
    multi = [WEATHER_TOOL, PYTHON_TOOL, CALC_TOOL]
    for i, (ask, name, arg, needle) in enumerate([
        ("What is the weather in Istanbul?", "get_current_weather", "location", "istanbul"),
        ("What is the weather in Berlin right now?", "get_current_weather", "location", "berlin"),
        ("Is it raining in Seattle, WA?", "get_current_weather", "location", "seattle"),
        ("say hello world with python", "python", "code", "hello"),
        ("Write and run python code that prints the current year.", "python", "code", "print|year|date"),
        ("Run a python snippet that counts the vowels in 'banana'.", "python", "code", "banana"),
        ("Use the calculator to compute 1234 * 5678.", "calculate", "expression", "1234"),
        ("Calculate (17 + 25) / 6 with the calculator.", "calculate", "expression", "17"),
        ("Use the calculator: what is 2 ** 16?", "calculate", "expression", "2"),
        ("What's the weather like in Cape Town?", "get_current_weather", "location", "cape"),
    ], 1):
        s = weather_src if name == "get_current_weather" else python_src if name == "python" else calc_src
        add("multiple", f"t-multi-{i:02d}", s, ask, multi, {"calls": [name], "args_contains": {arg: needle}},
            derived=i != 1 and i != 4)

    # parallel (4): two independent calls in one turn.
    for i, (a, b) in enumerate([("Paris", "Tokyo"), ("Istanbul", "Madrid"), ("Oslo", "Rome"), ("Lima", "Cairo")], 1):
        add("parallel", f"t-par-{i:02d}", weather_src, f"What is the weather in {a} and in {b}? Look up both.", [WEATHER_TOOL],
            {"calls": ["get_current_weather", "get_current_weather"], "args_contains": {}}, derived=True)

    # no_call (10): test_completion_without_tool_call (:290-310: no tools; TEST_TOOL; PYTHON_TOOL + tool_choice none),
    # test_thoughts (:550 sum of 102 and 7, no tools), test_chat_completion :229 greeting.
    noc = src("llama.cpp", TT, "def do_test_completion_without_tool_call(")
    sumsrc = src("llama.cpp", TT, '"What\'s the sum of 102 and 7?"')
    hi = src("llama.cpp", TC, '"Hi there"')
    add("no_call", "t-none-01", noc, "say hello world with python", [], {"calls": []}, system=SYS_CODE)
    add("no_call", "t-none-02", noc, "say hello world with python", [PYTHON_TOOL], {"calls": []}, system=SYS_CODE,
        tool_choice="none")
    add("no_call", "t-none-03", sumsrc, "What's the sum of 102 and 7?", [], {"calls": []}, system=None)
    add("no_call", "t-none-04", hi, "Hi there", [WEATHER_TOOL], {"calls": []}, derived=True)
    for i, (ask, tools) in enumerate([
        ("What is the capital of France? Answer in one word.", [WEATHER_TOOL]),
        ("Write a two-line poem about autumn leaves.", [WEATHER_TOOL]),
        ("Translate 'thank you' into Spanish.", [PYTHON_TOOL]),
        ("Who wrote Romeo and Juliet?", [CALC_TOOL]),
        ("Say hello in French.", [WEATHER_TOOL, PYTHON_TOOL, CALC_TOOL]),
        ("Name three primary colors.", [TEST_TOOL]),
    ], 5):
        add("no_call", f"t-none-{i:02d}", noc, ask, tools, {"calls": []}, derived=True)

    # recovery (10): raw model text through the family's native parser (mlx-swift-lm ToolCallProcessor) +
    # RawToolSyntaxScrubber. `native` = the family renders it in its own dialect (the evaluator picks the
    # rendering for qwen35 / gemma4 / json); explicit `text` rows are dialect-independent upstream strings.
    rec = [
        ("t-rec-01", src("mlx-swift-lm", REC, "func promotesAlternateDialects"), {"native": "weather", "args": {"city": "Paris"}},
         {"calls": ["weather"], "args_contains": {"city": "paris"}}),
        ("t-rec-02", src("mlx-swift-lm", REC, "func everyStreamingBoundary"),
         {"native": "weather", "args": {"city": "Paris"}, "split_every_boundary": True},
         {"calls": ["weather"], "args_contains": {"city": "paris"}}),
        ("t-rec-03", src("mlx-swift-lm", REC, "func nativeFrameIsOpaque"),
         {"native": "weather", "args": {"city": "literal <function=fake> and weather[ARGS]{}"}},
         {"calls": ["weather"], "args_contains": {"city": "literal <function=fake>"}}),
        ("t-rec-04", src("mlx-swift-lm", REC, "func reasoningCannotDispatchNativeCall"),
         {"native": "weather", "args": {"city": "Paris"}, "inside_reasoning": True}, {"calls": []}),
        ("t-rec-05", src("mlx-swift-lm", REC, "func ordinaryJSONIsOpaque"),
         {"text": '{"example":"weather[ARGS]{\\"city\\":\\"Paris\\"}"}'}, {"calls": []}),
        ("t-rec-06", src("mlx-swift-lm", REC, 'let undeclared = #"other[ARGS]'),
         {"native": "other", "args": {"city": "Paris"}}, {"calls": [], "rejected_ok": True}),
        ("t-rec-07", src("mlx-swift-lm", REC, '#"<tool_call>{"name":"weather","arguments":{}}</tool_call>"#'),
         {"native": "weather", "args": {}}, {"calls": ["weather"], "args_contains": {}}),
        ("t-rec-08", src("mlx-swift-lm", NJ, "func trailingTextAndSecondCall"),
         {"native": "weather", "args": {"city": "Paris"}, "second": {"city": "Rome"}},
         {"calls": ["weather", "weather"], "args_contains": {}}),
        ("t-rec-09", src("mlx-swift-lm", NJ, "func precedingTextIsPreserved"),
         {"native": "weather", "args": {"city": "Paris"}, "prefix": "Let me check. "},
         {"calls": ["weather"], "args_contains": {"city": "paris"}, "text_contains": "Let me check."}),
        ("t-rec-10", src("mlx-swift-lm", REC, "hugeValue"), {"native": "weather", "args": {"city": "P" * 8192}},
         {"calls": ["weather"], "args_contains": {"city": "pppp"}}),
    ]
    for cid, s, raw, expect in rec:
        rows.append({"id": cid, "kind": "recovery", "source": s, "derived": False, "raw": raw, "tools": [MLX_WEATHER],
                     "expect": expect})
    assert len(rows) == 50, len(rows)
    return rows


def thinking_cases() -> list[dict]:
    # test_thoughts (:532-560 "What's the sum of 102 and 7?" with reasoning separated into reasoning_content) and
    # mlx-swift-lm ReasoningConfigTests (enable_thinking on/off honoured). 10 prompts x {on, off}.
    s_sum = src("llama.cpp", TT, "def test_thoughts(")
    s_on = src("mlx-swift-lm", RCF, "func templateFlagThinkingOn")
    s_off = src("mlx-swift-lm", RCF, "func templateFlagThinkingOff")
    prompts = [
        "What's the sum of 102 and 7?",
        "What is the best book",
        "Is 91 a prime number?",
        "How many r's are in the word 'strawberry'?",
        "If a train leaves at 3pm and travels 2 hours, when does it arrive?",
        "What is 15% of 80?",
        "Which is heavier, a kilogram of feathers or a kilogram of steel?",
        "Name a word that rhymes with 'orange', or say if none exists.",
        "What day of the week comes two days after Friday?",
        "Sort these numbers: 5, 2, 9, 1.",
    ]
    rows = []
    for i, p in enumerate(prompts, 1):
        for on in (True, False):
            rows.append({"id": f"th-{i:02d}-{'on' if on else 'off'}", "source": s_sum if i == 1 else (s_on if on else s_off),
                         "derived": i != 1, "messages": [{"role": "user", "content": p}], "reasoning": on,
                         "expect": {"reasoning_nonempty": on, "no_reasoning": not on, "no_think_tags_in_text": True}})
    assert len(rows) == 20
    return rows


def cancel_cases() -> list[dict]:
    s_stream = src("mlx-swift-lm", CAN, "func testGenerateTaskSettlesAfterStreamCancellation")
    s_imm = src("mlx-swift-lm", CAN, "func testGenerateTaskSettlesAfterImmediateCancellation")
    s_reason = src("mlx-swift-lm", CAN, "func testGenerateTaskReportsCancelledStopReason")
    s_prog = src("llama.cpp", TC, "def test_return_progress(")
    long_doc = "Summarise the following notes in detail.\n" + ("The committee reviewed the harbour budget, the ferry " \
        "timetable and the lighthouse repairs, and asked for a second estimate. " * 160)
    rows = [
        {"id": "c-prefill-01", "phase": "prefill", "source": s_prog, "cancel_at": {"after_ms": 15}, "prompt": long_doc},
        {"id": "c-prefill-02", "phase": "prefill", "source": s_imm, "cancel_at": {"after_ms": 0}, "prompt": long_doc},
        {"id": "c-prefill-03", "phase": "prefill", "source": s_prog, "cancel_at": {"on_lifecycle": "prefillProgress"}, "prompt": long_doc},
        {"id": "c-reason-01", "phase": "reasoning", "source": s_reason, "reasoning": True, "cancel_at": {"on_event": "reasoningDelta"},
         "prompt": "Think carefully: how many weekdays are there in a leap year?"},
        {"id": "c-reason-02", "phase": "reasoning", "source": s_reason, "reasoning": True, "cancel_at": {"on_event": "reasoningDelta", "skip": 3},
         "prompt": "Reason step by step: what is 17 * 23?"},
        {"id": "c-tool-01", "phase": "tool_args", "source": s_stream, "tools": [PYTHON_TOOL],
         "cancel_at": {"in_tool_span_ms": 120},
         "prompt": "Use python to write and run a 60-line program that prints a multiplication table from 1 to 12 with comments on every line."},
        {"id": "c-tool-02", "phase": "tool_args", "source": s_stream, "tools": [PYTHON_TOOL],
         "cancel_at": {"in_tool_span_ms": 250},
         "prompt": "Use python to write and run a long, well-commented program that simulates a bank account with deposits and withdrawals."},
        {"id": "c-text-01", "phase": "text", "source": s_stream, "cancel_at": {"on_event": "textDelta"},
         "prompt": "Tell me a long story about a lighthouse keeper."},
        {"id": "c-text-02", "phase": "text", "source": s_stream, "cancel_at": {"on_event": "textDelta", "skip": 10},
         "prompt": "Write a long essay about the history of maps."},
        {"id": "c-text-03", "phase": "text", "source": s_stream, "cancel_at": {"on_event": "textDelta", "skip": 40},
         "prompt": "List one hundred animals, one per line."},
    ]
    return rows


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--mlx-swift-lm", required=True, type=Path)
    ap.add_argument("--llama-cpp", required=True, type=Path)
    ap.add_argument("--out", required=True, type=Path)
    a = ap.parse_args()
    ROOTS["mlx-swift-lm"] = a.mlx_swift_lm
    ROOTS["llama.cpp"] = a.llama_cpp
    a.out.mkdir(parents=True, exist_ok=True)
    for name, rows in (("tools-50", tool_cases()), ("thinking-20", thinking_cases()), ("cancel-10", cancel_cases())):
        with open(a.out / f"{name}.jsonl", "w", encoding="utf-8") as f:
            for r in rows:
                f.write(json.dumps(r, sort_keys=True, ensure_ascii=False) + "\n")
        print(f"{name}.jsonl: {len(rows)} rows")


if __name__ == "__main__":
    main()
