// antichat-bench (M1.T05; architecture §2 executables). Talks to the real AntiChatEngine.xpc through the app-side
// EngineClient only (never links AntiChatEngines). One file per subcommand: `chat` (M1.T05), `tools` (M1.T13),
// `launch` / `idle` (M1.T26).
//
//   antichat-bench chat --model <key> --cap <tier> --via xpc --runs N --json <out> [--app build/AntiChat.app]
//                       [--prompt TEXT] [--max-tokens 256] [--batch 16:8]
//   antichat-bench load --model <key> --cap <tier> --runs N --json <out> [--purge]                  (M2.T12, NFR-M1)
//   antichat-bench u3 --model <key> --cap <tier> --runs N --json <out> [--purge]                    (M9.T05, NFR-U3)
//   antichat-bench modeswap --normal <key> --evil <key|llama:key> --cap <tier> [--warm] --runs N --json <out>  (M2.T15, NFR-C7)
//   antichat-bench router [--runs N] [--dump --set calib|test|all] --cap <tier> --json <out>      (M2.T22/T23, R-235)
//   antichat-bench files-pagecite --fixture fixtures/docs/pagecite-100.jsonl --tier T1 --out <json>   (M6.T02, AT-270 4b)
//   antichat-bench project-qa --fixture fixtures/projects/qa-50 --tier T1 --out <json>          (M8.T05, AT-245)
//   antichat-bench files-warm --doc fixtures/docs/warm-10k.pdf --followups <jsonl> --tier T2 --runs 20 --out <json> (M6.T03)
//   antichat-bench search-availability --fixture <jsonl> --block <engine> [--replay <serp-snapshots>] --out <json> (M7.T01)
//   antichat-bench skills-activation --skills <dir> --fixture <jsonl> --tier T0|T1 --out <json> [--theta θ --m M]  (M7.T13, AT-263)
//   antichat-bench tools --model <key> --cap <tier> --set <rows.jsonl> --json <out> [--limit N]   (M1.T13, AT-231)
//
// An XPC service is reachable only from processes of its containing bundle, so when started outside an app
// bundle the tool copies itself to `<app>/Contents/MacOS/antichat-bench` and re-executes from there (A-M1-T05a).
import Foundation

let argv = Array(CommandLine.arguments.dropFirst())
guard let cmd = argv.first else {
    FileHandle.standardError.write(Data("usage: antichat-bench chat --model <key> --cap <tier> --via xpc --runs N --json <out>\n".utf8))
    exit(64)
}
let args = BenchArgs(Array(argv.dropFirst()))
BundleRelocation.ensureInsideApp(args: args)

switch cmd {
case "chat":
    runAsync { try await ChatBench.run(args) }
case "prefix":  // M1.T14 / A-M0-11: prefix-cache TTFT scenarios (PrefixBench.swift)
    runAsync { try await PrefixBench.run(args) }
case "tools":
    runAsync { try await ToolEvalBench.run(args) }
case "soak":  // M2.T13: mini-soak (SoakBench.swift, tools/soak/mini-soak.sh)
    runAsync { try await SoakBench.run(args) }
case "pressure":  // M2.T14: NFR-M4 WARNING release time (PressureBench.swift)
    runAsync { try await PressureBench.run(args) }
case "modeswap":  // M2.T15: NFR-C7 Normal → Evil switch to first token (ModeSwapBench.swift)
    runAsync { try await ModeSwapBench.run(args) }
case "router":  // M2.T22/T23: pre-router latency and score dumps (RouterBench.swift)
    runAsync { try await RouterBench.run(args) }
case "files-pagecite":  // M6.T02: AT-270 check 4b (FilesPagecite.swift)
    runAsync { try await FilesPagecite.run(args) }
case "caption-fallback":  // M6.T06: AT-237 real leg (CaptionFallback.swift)
    runAsync { try await CaptionFallback.run(args) }
case "vision-qa":  // M6.T05: AT-021 check 2 (VisionQA.swift)
    runAsync { try await VisionQA.run(args) }
case "sheet-qa":  // M6.T08: AT-272 checks 3a/3b (SheetQA.swift)
    runAsync { try await SheetQA.run(args) }
case "sheet-chart":  // M6.T12: AT-274 check 3 (SheetChart.swift)
    runAsyncApp { try await SheetChart.run(args) }
case "fileout-golden":  // M6.T10/T11: AT-273 check 5, AT-275 1c (FileoutGolden.swift)
    runAsyncApp { try await FileoutGolden.run(args) }
case "import-perf":  // M8.T06: AT-092 AC2 (ImportPerf.swift), release
    runAsync { try await ImportPerf.run(args) }
case "project-qa":  // M8.T05: AT-245 (ProjectQA.swift)
    runAsync { try await ProjectQA.run(args) }
case "files-warm":  // M6.T03: AT-279 (FilesWarm.swift)
    runAsync { try await FilesWarm.run(args) }
case "search-availability":  // M7.T01: AT-248 c3 (SearchAvailability.swift); no XPC
    runAsync { try await SearchAvailability.run(args) }
case "citations":  // M7.T03: AT-250 c2 (Citations.swift)
    runAsync { try await Citations.run(args) }
case "search-e2e":  // M7.T03: AT-248 c1, AT-254 (SearchE2E.swift); live engines + real model
    runAsync { try await SearchE2E.run(args) }
case "fresh-hint":  // M7.T05: AT-NFR-U12 (FreshHint.swift); no network
    runAsync { try await FreshHint.run(args) }
case "skills-activation":  // M7.T13: AT-263 (SkillsActivation.swift); real tier model + embed helper
    runAsync { try await SkillsActivation.run(args) }
case "tool-select":  // M7.T14: AT-266 c1/c2 (ToolSelect.swift); local embed model only
    runAsync { try await ToolSelect.run(args) }
case "load":  // M2.T12: NFR-M1 cold load through the scheduler (LoadBench.swift)
    runAsync { try await LoadBench.run(args) }
case "u3":  // M9.T05: AT-NFR-U3 message sent while the model loads (U3Bench.swift)
    runAsync { try await U3Bench.run(args) }
default:
    FileHandle.standardError.write(Data("antichat-bench: unknown subcommand \(cmd)\n".utf8))
    exit(64)
}
