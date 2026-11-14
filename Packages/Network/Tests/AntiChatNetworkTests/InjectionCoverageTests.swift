// AT-297 (R-297 AC1; D-026/B1: replaces the ObjC swizzle): every dependency in Package.resolved whose shipped
// sources create a URLSession is listed with the hook that puts it behind the gate, and the hook is proven
// present in our code (or the session-creating library is proven unlinked / uncalled). A new dependency that
// creates a session fails this test until it gets a hook here; one that cannot be injected brings the swizzle
// back (M11.md §M2.T02).
import Foundation
import Testing

let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

@Suite("InjectionCoverageTests") struct InjectionCoverageTests {
    /// How each session-creating dependency is gated. `required`: a regex that must match in our sources;
    /// `forbidden`: a regex that must not (the session-creating API is never called).
    struct Hook { var how: String; var required: [String] = []; var forbidden: [String] = [] }

    static let hooks: [String: Hook] = [
        // M2.T08: the app fetches model files itself (DownloadCoordinator → TransferEngine lanes on gated `.models`
        // sessions); HubClient remains only in catalog-tool (a build tool), anonymous.
        "swift-huggingface": Hook(how: "app: TransferEngine on NetworkGate .models; catalog-tool: HubClient(session:, tokenProvider: .none)",
                                  required: [#"HubClient\(session: session,.*tokenProvider: \.none"#,
                                             #"NetworkGate\.session\(for: \.models, delegate:"#],
                                  forbidden: [#"HubClient\((?!session:)"#, #"InferenceClient\("#]),
        "swift-sdk": Hook(how: "HTTPClientTransport(configuration: NetworkGate.configuration(for: .mcp))",
                          required: [#"HTTPClientTransport\(endpoint: endpoint, configuration: NetworkGate\.configuration"#],
                          forbidden: [#"HTTPClientTransport\(endpoint: [^,)]+\)"#,
                                      // M7.T07: the flow's `perform` and the SDK `OAuthAuthorizer` build an ungated
                                      // no-redirect URLSession; only its pure helpers (buildURL, extractCode) are used.
                                      #"\.perform\(authorizationURL:"#, #"OAuthAuthorizer\(configuration:"#]),
        "eventsource": Hook(how: "EventSource(request:configuration: NetworkGate.configuration) or parser only",
                            required: [#"EventSource\(request: NetworkGate\.tag"#],
                            forbidden: [#"EventSource\(request: (?!NetworkGate)"#]),
        "fluidaudio": Hook(how: "ModelHub.offlineMode = true in the helper (D-11); models arrive through the store",
                           required: [#"ModelHub\.offlineMode = true"#], forbidden: [#"ModelRegistry\.(download|fetch)"#]),
        "sparkle": Hook(how: "SPUUpdaterDelegate gate (UpdateGateDelegate: mayPerform / shouldProceedWithUpdate)",
                        required: [#"func updater\(_ updater: SPUUpdater, mayPerform updateCheck"#, #"policy\.isEnabled\(\.updates\)"#]),
        "swift-transformers": Hook(how: "Hub downloads never called: tokenizers load from a local folder only",
                                   required: [#"AutoTokenizer\.from\(modelFolder:"#],
                                   forbidden: [#"AutoTokenizer\.from\(pretrained:"#, #"HubApi\("#, #"\.snapshot\(from:"#]),
        // M3.T01: WhisperKit (M3.T05) only from the model store; its Downloader / HubApi sessions are never reached.
        "argmax-oss-swift": Hook(how: "WhisperKitLocal.config: local modelFolder + tokenizerFolder, download: false",
                                 required: [#"tokenizerFolder: tokenizerFolder \?\? modelFolder"#, #"download: false\)"#],  // M3.T05: or stt-multi-tok
                                 forbidden: [#"WhisperKit\.download\("#, #"download: tru[e]\b"#]),
        "markdownview": Hook(how: "remote images never fetched: NoFetchImageRenderer registered for http and https",
                             required: [#"\.image\(NoFetchImageRenderer\(\), urlScheme: "http"\)"#,
                                        #"\.image\(NoFetchImageRenderer\(\), urlScheme: "https"\)"#],
                             forbidden: [#"NetworkMarkdownImageRenderer"#]),
        // M6.T07: the only session is DuckDBPlayground.playground (not a package target, never built); the engine
        // runs with enable_external_access=false (DuckDBStoreTests: no httpfs, no URL reads).
        "duckdb-swift": Hook(how: "only DuckDBPlayground.playground creates a session; never built; external access off",
                             required: [#"\("enable_external_access", "false"\)"#],
                             forbidden: [#"INSTALL httpfs\b(?!.*must fail)"#]),
        "mlx-swift-lm": Hook(how: "only BenchmarkHelpers/IntegrationTestHelpers create sessions; never linked",
                             forbidden: [#"import (BenchmarkHelpers|IntegrationTestHelpers)"#, #"product\(name: \"(BenchmarkHelpers|IntegrationTestHelpers)\""#]),
    ]

    static var sessionPattern: Regex<AnyRegexOutput> { try! Regex(#"URLSession\(|URLSession\.shared|URLSessionConfiguration\.(default|ephemeral|background)|sessionWithConfiguration:|\[NSURLSession sharedSession\]"#) }

    func pins() throws -> [String] {
        struct R: Decodable { struct P: Decodable { var identity: String }; var pins: [P] }
        return try JSONDecoder().decode(R.self, from: Data(contentsOf: repoRoot.appendingPathComponent("Package.resolved"))).pins.map(\.identity)
    }

    /// Shipped source files of a checkout (tests, examples, benchmarks, CLIs and demos excluded).
    func sources(_ dir: URL, ours: Bool = false) -> [URL] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let skip = ours ? ["/Tests/", "/UITests/", "/IntegrationTests/"]
            : ["/Tests/", "/Test/", "/Example", "/Demo", "/Benchmarks/", "CLI/", "/Tools/", "/TestApp", "/UITests", "/fuzz", "/Package.swift"]
        return e.compactMap { $0 as? URL }.filter { u in
            ["swift", "m"].contains(u.pathExtension) && !skip.contains { u.path.contains($0) }
        }
    }

    func ourSources() -> String {
        var all = ""
        for sub in ["Packages", "App", "tools", "Package.swift"] {
            let u = repoRoot.appendingPathComponent(sub)
            let files = sub == "Package.swift" ? [u] : sources(u, ours: true)
            for f in files { all += (try? String(contentsOf: f, encoding: .utf8)) ?? "" }
        }
        return all
    }

    @Test func everySessionCreatingDependencyIsGated() throws {
        let checkouts = repoRoot.appendingPathComponent(".build/checkouts")
        let dirs = try FileManager.default.contentsOfDirectory(atPath: checkouts.path)
        var creators: [String: [String]] = [:]
        for id in try pins() {
            guard let d = dirs.first(where: { $0.lowercased() == id }) else { Issue.record("no checkout for \(id)"); continue }
            for f in sources(checkouts.appendingPathComponent(d)) {
                guard let text = try? String(contentsOf: f, encoding: .utf8), text.contains(Self.sessionPattern) else { continue }
                creators[id, default: []].append(f.lastPathComponent)
            }
        }
        #expect(creators.count >= 5, "the scan found too few session creators; is .build/checkouts complete?")
        let ours = ourSources()
        print("AT-297 injection coverage:")
        for (id, files) in creators.sorted(by: { $0.key < $1.key }) {
            guard let hook = Self.hooks[id] else {
                Issue.record("\(id) creates a URLSession (\(files.joined(separator: ", "))) and has no gate hook")
                continue
            }
            for r in hook.required {
                #expect(ours.contains(try Regex(r)), "\(id): hook missing: /\(r)/")
            }
            for r in hook.forbidden {
                #expect(!ours.contains(try Regex(r)), "\(id): ungated call present: /\(r)/")
            }
            print("  \(id): \(hook.how) [\(files.count) file(s)]")
        }
    }
}
