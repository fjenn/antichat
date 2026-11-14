// M7.T03 test plumbing (DEBUG only, compiled out of Release): `-ScriptedWebSearch YES` replaces the web tools' network
// half with fixed results, so the window legs of AT-080 / AT-250 c1 are deterministic and offline: `web_search`
// returns nine sources of which 1–4 are fetched (in the evidence) and 5–9 are not; `read_url` returns the given page
// as source 1. Everything after the tool result (the untrusted block, numbering, provenance, pills, the Sources panel)
// is the production path. The pipeline (engines, fetch, extraction, ranking) is covered by its unit tests and by the
// live AT-248 / AT-249 runs.
#if DEBUG || ANTICHAT_PERF_HARNESS
import AntiChatFoundation
import AntiChatTools
import Foundation

enum ScriptedWebSearch {
    /// A 32 × 32 PNG (the favicon of source 1, so the hover card / Sources panel draw a real icon). The former 16 × 16
    /// one had a bad zlib checksum, so it never decoded: a sliver in light, nothing in dark (M10 visual QA, S-10).
    static let icon = "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAAYklEQVR42mNgwANUk1//pwZmIAVQy1KyHENry/E6gl6WY3UEvS3HcMTIdsBAWQ53xJBwALlg+DhgNA2MOmA0F4ymgVEHUCvBDV0HDO80MNomHBQOGPCOyaDomg2KzulAdM8BSVuAlIBEoI8AAAAASUVORK5CYII="

    /// Nine made-up pages about the question web-search.jsonl answers (reserved `.example` domains, M10 visual QA:
    /// the former "Source n" / "Snippet n" placeholders read as broken content in the S-10 shots).
    static let pages: [(site: String, path: String, title: String, snippet: String)] = [
        ("macreleasenotes.example", "macos-27", "macOS 27 release notes",
         "macOS 27 is the current version of the Mac operating system, with the update rolling out to supported Macs now."),
        ("desktopweekly.example", "news/macos-27-available", "macOS 27 is out: what changed",
         "The new release arrived this autumn after a summer of public betas."),
        ("techdigest.example", "2026/macos-27-review", "macOS 27 review",
         "A closer look at this autumn's macOS update, from the redesigned Settings to the new window tiling."),
        ("machelp.example", "compatibility/macos-27", "Which Macs can run macOS 27?",
         "The full list of supported Mac models, and how to check which one you have."),
        ("rumourmill.example", "next-macos", "What to expect from the next macOS",
         "Early reports on the release after macOS 27."),
        ("appleforum.example", "threads/next-version", "Forum: guesses for the next version",
         "Readers share what they hope comes next."),
        ("dailymac.example", "roadmap", "The macOS roadmap, as far as we know",
         "What has been announced and what is still speculation."),
        ("macblog.example", "posts/after-27", "After macOS 27",
         "A short opinion piece on where the Mac is heading."),
        ("newsbrief.example", "tech/macos", "macOS news in brief",
         "This week's Mac headlines in one page."),
    ]

    static func results(queries: [String]) -> WebResults {
        let sources = pages.enumerated().map { i, p in
            let n = i + 1
            return WebSource(n: n, url: "https://\(p.site)/\(p.path)", title: p.title, site: p.site,
                             date: n == 1 ? "2026-10-28" : nil, snippet: p.snippet, fetched: n <= 4,
                             faviconData: n == 1 ? icon : nil)
        }
        let evidence = sources.filter(\.fetched).map {
            EvidenceChunk(source: $0.n, url: URL(string: $0.url)!, site: $0.site, title: $0.title,
                          // Q-015 r6: the evidence states every claim web-search.jsonl cites (R-250 AC2's grounding
                          // removed the markers of "It shipped this autumn [2][3]" / "Apple lists the supported Macs
                          // [4]" against the old one-claim text, so the window showed one pill, "+1").
                          text: "Source \($0.n) says the latest macOS is macOS 27. It shipped this autumn. "
                              + "Apple lists the supported Macs (fixture).", ordinal: 0)
        }
        return WebResults(queries: queries, sources: sources, evidence: evidence, evidenceTokens: 80, failed: nil)
    }

    static func page(_ url: URL) -> WebResults {
        let s = WebSource(n: 1, url: url.absoluteString, title: "The pasted page", site: url.host() ?? "", date: nil,
                          snippet: "", fetched: true, faviconData: icon)
        let c = EvidenceChunk(source: 1, url: url, site: s.site, title: s.title, text: "The pasted page says hello (fixture).", ordinal: 0)
        return WebResults(queries: [url.absoluteString], sources: [s], evidence: [c], evidenceTokens: 20, failed: nil)
    }

    /// Registers both and keeps their availability in step with the switch / Offline only / path (like the real ones).
    static func install(into registry: ToolRegistry, availability: WebSearchAvailability = WebSearchAvailability(),
                        sources: TurnWebSources = .shared) -> [NSObjectProtocol] {
        let refresh: @Sendable () -> Void = { register(into: registry, available: availability.isAvailable, sources: sources) }
        refresh()
        return WebSearchAvailability.observe(refresh)
    }

    static func register(into registry: ToolRegistry, available: Bool, sources: TurnWebSources) {
        let state: ToolAvailability = available ? .available : .unavailable(reason: "offline")
        registry.register(RegisteredTool(
            name: "web_search", description: "Search the web for current information.", parametersJSON: WebSearchTools.webSearchParameters,
            sideEffect: .read, availability: state, outputIsUntrusted: true) { args in
            let plan = SearchPlan.make(arguments: args, maxQueries: 3, fallback: "query")
            // VQ-M11 S-10: `ANTICHAT_SCRIPTED_SEARCH_HOLD_MS` keeps the step in its Searching state that long, so the
            // vq-chat leg can capture it (the fixed results otherwise return within one frame).
            if let ms = Int(ProcessInfo.processInfo.environment["ANTICHAT_SCRIPTED_SEARCH_HOLD_MS"] ?? ""), ms > 0 {
                try? await Task.sleep(for: .milliseconds(min(ms, 20_000)))
            }
            return WebResultsBlock.render(sources.record(results(queries: plan?.queries ?? []), turn: TurnContext.requestID ?? "-"))
        })
        registry.register(RegisteredTool(
            name: "read_url", description: "Read the page at a URL the user gave and answer from it.", parametersJSON: WebSearchTools.readURLParameters,
            sideEffect: .read, availability: state, outputIsUntrusted: true) { args in
            struct A: Decodable { var url: String }
            guard let a = try? JSONDecoder().decode(A.self, from: Data(args.utf8)), let u = URL(string: a.url) else {
                throw ToolRunError("read_url needs {\"url\": \"https://…\"}.")
            }
            return WebResultsBlock.render(sources.record(page(u), turn: TurnContext.requestID ?? "-"))
        })
    }
}
#endif
